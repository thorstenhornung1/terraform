#!/bin/bash
# =============================================================================
# Tailscale HA Subnet Router Setup Script for LXC Containers
# =============================================================================
# Rendered by Terraform templatefile() — do NOT edit directly.
# Installs: APT proxy, SSSD/LDAP, rsyslog → Loki, Tailscale, FRR (BGP+BFD)
#
# Container: Ubuntu 24.04 LXC (privileged — /dev/net/tun required)
# Purpose:   HA Subnet Router with FRR BGP failover
#
# NOTE: This script does NOT start Tailscale or FRR.
#       Activation happens via /usr/local/bin/activate-tailscale.sh
#       after secrets are deployed from CephFS.
# =============================================================================

set -euo pipefail

HOSTNAME="${hostname}"
IP="${ip}"

echo "=== Setting up Tailscale HA Subnet Router on $HOSTNAME ($IP) ==="

# =============================================================================
# 1. APT Proxy (apt-cacher-ng)
# =============================================================================
# All nodes use the central APT cache to save bandwidth and speed up installs.
# DNS resolution for apt-cacher.hornung-bn.de is provided by var.dns_servers.

cat > /etc/apt/apt.conf.d/01proxy << 'EOF'
Acquire::http::Proxy "http://apt-cacher.hornung-bn.de:3142";
EOF

echo "[1/11] APT proxy configured"

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
  frr \
  frr-pythontools \
  > /dev/null 2>&1

echo "[2/11] Base packages installed (incl. FRR)"

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

echo "[3/11] SSSD/LDAP configured"

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

echo "[4/11] NSSwitch configured"

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

echo "[5/11] PAM mkhomedir configured"

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

echo "[6/11] rsyslog → Loki configured"

# =============================================================================
# 7. Enable and start base services
# =============================================================================

systemctl enable sssd
systemctl restart sssd
systemctl restart rsyslog

echo "[7/11] SSSD and rsyslog started"

# =============================================================================
# 8. Install Tailscale
# =============================================================================

echo "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

echo "[8/11] Tailscale installed"

# =============================================================================
# 9. IP Forwarding (required for subnet routing)
# =============================================================================

cat > /etc/sysctl.d/99-tailscale.conf << 'SYSCTL_EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL_EOF

sysctl -p /etc/sysctl.d/99-tailscale.conf

echo "[9/11] IP forwarding enabled"

# =============================================================================
# 10. FRR Configuration (BGP + BFD)
# =============================================================================
# FRR provides BGP peering with UniFi UDM-Pro for route-based failover.
# BFD (Bidirectional Forwarding Detection) enables sub-second failure detection.
#
# Blackhole route for 100.64.0.0/10:
#   FRR's `network` command requires the prefix to exist in the kernel RIB
#   (bgp network import-check). Tailscale installs its routes in table 52,
#   not the main table — so we add a blackhole route. This does NOT affect
#   actual traffic because Tailscale's policy routing takes precedence.

# Enable BGP and BFD daemons
cat > /etc/frr/daemons << 'DAEMONS_EOF'
bgpd=yes
bfdd=yes
zebra=yes
staticd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
pim6d=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
vrrpd=no
pathd=no
DAEMONS_EOF

# FRR unified configuration
cat > /etc/frr/frr.conf << 'FRR_EOF'
frr version 10.0
frr defaults traditional
hostname ${hostname}
log syslog informational
service integrated-vtysh-config

ip route 100.64.0.0/10 blackhole

bfd
 profile fast-failover
  receive-interval 150
  transmit-interval 150
  detect-multiplier 3
 !
 peer ${bgp_peer_ip}
  profile fast-failover
  no shutdown
 !
!

route-map SET-MED permit 10
 set metric ${bgp_med}
!

router bgp ${asn}
 bgp router-id ${ip}
 no bgp ebgp-requires-policy
 bgp log-neighbor-changes
 neighbor ${bgp_peer_ip} remote-as ${bgp_asn_unifi}
 neighbor ${bgp_peer_ip} description UniFi-UDM-Pro
 neighbor ${bgp_peer_ip} soft-reconfiguration inbound
 neighbor ${bgp_peer_ip} bfd profile fast-failover
 !
 address-family ipv4 unicast
  network 100.64.0.0/10
  neighbor ${bgp_peer_ip} activate
  neighbor ${bgp_peer_ip} route-map SET-MED out
 exit-address-family
!

line vty
!
FRR_EOF

echo "[10/11] FRR configured (BGP AS ${asn}, MED ${bgp_med}, BFD enabled)"

# =============================================================================
# 11. Deploy activate script
# =============================================================================
# This script is run after secrets are copied from CephFS.
# It reads /etc/tailscale/secrets.env and starts both FRR and Tailscale.

cat > /usr/local/bin/activate-tailscale.sh << 'ACTIVATE_EOF'
${activate_script}
ACTIVATE_EOF

chmod +x /usr/local/bin/activate-tailscale.sh

echo "[11/11] Activate script deployed to /usr/local/bin/activate-tailscale.sh"

echo ""
echo "=== Tailscale setup complete on $HOSTNAME ==="
echo "IP: $IP"
echo "BGP AS: ${asn} | MED: ${bgp_med} | Peer: ${bgp_peer_ip} (AS ${bgp_asn_unifi})"
echo ""
echo "NEXT STEPS:"
echo "  1. Deploy secrets from CephFS: /etc/tailscale/secrets.env"
echo "  2. Run: /usr/local/bin/activate-tailscale.sh"
echo "  3. Configure BGP on UniFi UDM-Pro"
echo "  4. Approve subnet routes in Tailscale Admin Console"
