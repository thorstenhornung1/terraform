#!/bin/bash
# =============================================================================
# Technitium DNS Setup Script for LXC Containers
# =============================================================================
# Rendered by Terraform templatefile() — do NOT edit directly.
# Installs: APT proxy, SSSD/LDAP, rsyslog → Loki, Technitium DNS Server
#
# Container: Ubuntu 24.04 LXC (unprivileged)
# Purpose:   Authoritative + recursive DNS with cluster support
# =============================================================================

set -euo pipefail

HOSTNAME="${hostname}"
IP="${ip}"

echo "=== Setting up Technitium DNS on $HOSTNAME ($IP) ==="

# =============================================================================
# 1. APT Proxy (apt-cacher-ng)
# =============================================================================
# All nodes use the central APT cache to save bandwidth and speed up installs.
# DNS resolution for apt-cacher.hornung-bn.de is provided by var.dns_servers.

cat > /etc/apt/apt.conf.d/01proxy << 'EOF'
Acquire::http::Proxy "http://apt-cacher.hornung-bn.de:3142";
EOF

echo "[1/8] APT proxy configured"

# =============================================================================
# 2. Install required packages (minimal set only)
# =============================================================================

apt-get update -qq
apt-get install -y -qq \
  curl \
  ca-certificates \
  gnupg \
  sssd \
  sssd-ldap \
  libnss-sss \
  libpam-sss \
  > /dev/null 2>&1

echo "[2/8] Base packages installed"

# =============================================================================
# 3. SSSD/LDAP Configuration
# =============================================================================
# Central LDAP (ldap.hornung-bn.de) provides user authentication.
# Same config as all other infra nodes (Docker Swarm VMs, etcd LXC, etc.)

cat > /etc/sssd/sssd.conf << 'SSSD_EOF'
[sssd]
domains = default
config_file_version = 2
services = nss, pam

[domain/default]
id_provider = ldap
auth_provider = ldap
ldap_uri = ldap://ldap.hornung-bn.de
ldap_search_base = dc=ldap,dc=hornung-bn,dc=de
ldap_default_bind_dn = uid=root,cn=users,dc=ldap,dc=hornung-bn,dc=de
ldap_default_authtok = jyFD6gS1eyWAYCOe

ldap_tls_reqcert = never

cache_credentials = true
enumerate = true
entry_cache_timeout = 300

ldap_id_mapping = false
ldap_user_uid_number = uidNumber
ldap_user_gid_number = gidNumber
ldap_group_gid_number = gidNumber

ldap_user_search_base = cn=users,dc=ldap,dc=hornung-bn,dc=de
ldap_group_search_base = cn=groups,dc=ldap,dc=hornung-bn,dc=de

override_homedir = /home/%u
default_shell = /bin/bash
fallback_homedir = /home/%u

ldap_pwd_policy = none
SSSD_EOF

chmod 600 /etc/sssd/sssd.conf

echo "[3/8] SSSD/LDAP configured"

# =============================================================================
# 4. NSSwitch for LDAP name resolution
# =============================================================================

cat > /etc/nsswitch.conf << 'NSS_EOF'
passwd:         files sss systemd
group:          files sss systemd
shadow:         files sss
gshadow:        files
hosts:          files dns
networks:       files
protocols:      db files
services:       db files sss
ethers:         db files
rpc:            db files
netgroup:       nis sss
automount:      sss
NSS_EOF

echo "[4/8] NSSwitch configured"

# =============================================================================
# 5. PAM mkhomedir for LDAP users
# =============================================================================

cat > /etc/pam.d/common-session << 'PAM_EOF'
session [default=1]   pam_permit.so
session requisite     pam_deny.so
session required      pam_permit.so
session optional      pam_umask.so
session required      pam_unix.so
session optional      pam_sss.so
session required      pam_mkhomedir.so skel=/etc/skel umask=0022
session optional      pam_systemd.so
PAM_EOF

echo "[5/8] PAM mkhomedir configured"

# =============================================================================
# 6. rsyslog → Loki/Promtail
# =============================================================================
# Forward all syslog to central Loki instance for aggregated logging.
# TCP (@@) for reliability, UDP (@) as fallback.

cat > /etc/rsyslog.d/60-loki.conf << 'LOKI_EOF'
# Forward all logs to Loki/Promtail syslog receiver
# Using TCP for reliability
*.* @@loki.hornung-bn.de:1514

# Also send via UDP as backup
*.* @loki.hornung-bn.de:1514
LOKI_EOF

echo "[6/8] rsyslog → Loki configured"

# =============================================================================
# 7. Enable and start base services
# =============================================================================

systemctl enable sssd
systemctl restart sssd
systemctl restart rsyslog

echo "[7/8] SSSD and rsyslog started"

# =============================================================================
# 8. Install Technitium DNS Server
# =============================================================================
# Official installer handles:
#   - ASP.NET Core Runtime installation (from Microsoft repos)
#   - Technitium DNS binary download
#   - systemd service creation (service name: dns)
#   - Ports: 53 (DNS), 5380 (HTTP UI), 53443 (HTTPS UI)

echo "Installing Technitium DNS Server..."
curl -sSL https://download.technitium.com/dns/install.sh | bash

echo ""
echo "=== Technitium DNS setup complete on $HOSTNAME ==="
echo "WebUI:  https://$IP:53443"
echo "DNS:    $IP:53"
echo ""
echo "NEXT STEPS:"
echo "  1. Access WebUI at https://$IP:53443"
echo "  2. Set admin password on first login"
echo "  3. Configure upstream forwarders"
echo "  4. Initialize or join DNS cluster"
