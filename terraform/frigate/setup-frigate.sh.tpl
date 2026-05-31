#!/bin/bash
# =============================================================================
# Frigate Production Setup Script for LXC Container
# =============================================================================
# Rendered by Terraform templatefile() — do NOT edit directly.
# Installs: APT proxy, SSSD/LDAP, rsyslog -> Loki, Docker CE, Intel GPU Runtime,
#           Ceph client + CephFS/RBD mounts, Traefik config, Docker Compose project
#
# Container: Ubuntu 24.04 LXC (privileged, /dev/dri passthrough)
# Purpose:   Production Frigate NVR at frigate.hornung-bn.de
# =============================================================================

set -euo pipefail

HOSTNAME="${hostname}"
IP_VLAN4="${ip_vlan4}"
IP_VLAN12="${ip_vlan12}"
CEPH_MON="${ceph_mon_addresses}"
CEPH_CLIENT="${ceph_client_name}"
CEPH_KEY="${ceph_client_key}"
CEPH_FSID="${ceph_fsid}"

echo "=== Setting up Frigate Production on $HOSTNAME ($IP_VLAN4 / $IP_VLAN12) ==="

# =============================================================================
# 1. APT Proxy (apt-cacher-ng)
# =============================================================================

cat > /etc/apt/apt.conf.d/01proxy << 'EOF'
Acquire::http::Proxy "http://apt-cacher.hornung-bn.de:3142";
Acquire::https::Proxy "DIRECT";
EOF

echo "[1/16] APT proxy configured"

# =============================================================================
# 2. Install base packages
# =============================================================================

apt-get update -qq
apt-get install -y -qq \
  curl \
  ca-certificates \
  gnupg \
  lsb-release \
  sssd \
  sssd-ldap \
  libnss-sss \
  libpam-sss \
  jq

echo "[2/16] Base packages installed"

# =============================================================================
# 3. SSSD/LDAP Configuration
# =============================================================================

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

echo "[3/16] SSSD/LDAP configured"

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

echo "[4/16] NSSwitch configured"

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

echo "[5/16] PAM mkhomedir configured"

# =============================================================================
# 6. rsyslog -> Loki/Promtail
# =============================================================================

cat > /etc/rsyslog.d/60-loki.conf << 'LOKI_EOF'
# Forward all logs to Loki/Promtail syslog receiver
*.* @@loki.hornung-bn.de:1514
*.* @loki.hornung-bn.de:1514
LOKI_EOF

echo "[6/16] rsyslog -> Loki configured"

# =============================================================================
# 7. Enable and start base services
# =============================================================================

systemctl enable sssd
systemctl restart sssd
systemctl restart rsyslog

echo "[7/16] SSSD and rsyslog started"

# =============================================================================
# 8. VLAN 12 static IP (Ceph Storage Network)
# =============================================================================

cat > /etc/systemd/network/10-eth1.network << NETEOF
[Match]
Name=eth1

[Network]
Address=$IP_VLAN12/24
NETEOF

systemctl restart systemd-networkd || true

echo "[8/16] VLAN 12 network configured"

# =============================================================================
# 9. Install Docker CE (Ubuntu repository)
# =============================================================================

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-compose-plugin

echo "[9/16] Docker CE installed"

# =============================================================================
# 10. Install Intel GPU Runtime for OpenVINO
# =============================================================================

apt-get install -y -qq intel-opencl-icd clinfo

echo "[10/16] Intel GPU runtime installed"

# =============================================================================
# 11. Install Ceph Client + Configuration
# =============================================================================

apt-get install -y -qq ceph-common ceph-fuse

# Ceph configuration
cat > /etc/ceph/ceph.conf << CEPH_CONF_EOF
[global]
fsid = $CEPH_FSID
mon host = $CEPH_MON
auth cluster required = cephx
auth service required = cephx
auth client required = cephx
CEPH_CONF_EOF

# Client keyring
# Note: Only swarm-volumes pool needed (for RBD DB).
# Recordings are on local ZFS, not Ceph RBD.
cat > /etc/ceph/ceph.client.$CEPH_CLIENT.keyring << KEYRING_EOF
[client.$CEPH_CLIENT]
    key = $CEPH_KEY
    caps mon = "allow r"
    caps osd = "allow rw pool=swarm-volumes"
    caps mds = "allow rw"
KEYRING_EOF

chmod 600 /etc/ceph/ceph.client.$CEPH_CLIENT.keyring

echo "[11/16] Ceph client configured"

# =============================================================================
# 12. CephFS systemd mount — /mnt/cephfs (ceph-fuse)
# =============================================================================

mkdir -p /mnt/cephfs

# NOTE: ceph-fuse ignores "id=..." as a mount option in older systemd versions.
# Use "ceph.id=..." and Type=fuse.ceph instead of fuse.ceph-fuse.
cat > /etc/systemd/system/mnt-cephfs.mount << MOUNT_EOF
[Unit]
Description=CephFS Mount (swarm-shared) via ceph-fuse
After=network-online.target
Wants=network-online.target

[Mount]
What=none
Where=/mnt/cephfs
Type=fuse.ceph
Options=ceph.id=$CEPH_CLIENT,ceph.conf=/etc/ceph/ceph.conf,_netdev

[Install]
WantedBy=multi-user.target
MOUNT_EOF

systemctl daemon-reload
systemctl enable mnt-cephfs.mount
systemctl start mnt-cephfs.mount || echo "WARNING: CephFS mount failed — may need manual retry after Ceph pool/client is created"

echo "[12/16] CephFS ceph-fuse mount configured"

# =============================================================================
# 13. Host bind-mount directories — ZFS recordings + RBD DB
# =============================================================================
# Storage is managed on the pve03 HOST and bind-mounted into LXC via mp0:/mp1:
#   mp0: /tank/frigate-recordings → /mnt/frigate-recordings (ZFS, local)
#   mp1: /mnt/rbd/frigate-prod-db → /mnt/rbd/frigate-db (Ceph RBD, replica 3)
# LXC containers don't have rbd kernel module — all RBD mapping on host.
# =============================================================================

mkdir -p /mnt/frigate-recordings /mnt/rbd/frigate-db

echo "[13/16] Storage mount directories created (bind-mounted from host)"

# =============================================================================
# 14. Docker drop-in — wait for Ceph mounts before Docker starts
# =============================================================================

mkdir -p /etc/systemd/system/docker.service.d

cat > /etc/systemd/system/docker.service.d/wait-for-ceph.conf << 'DOCKER_DROP'
[Unit]
After=mnt-cephfs.mount
Wants=mnt-cephfs.mount
DOCKER_DROP

systemctl daemon-reload
systemctl enable docker
systemctl start docker

echo "[14/16] Docker configured with Ceph dependencies"

# =============================================================================
# 15. Traefik Configuration
# =============================================================================

mkdir -p /opt/frigate/traefik
mkdir -p /opt/frigate/secrets
mkdir -p /opt/frigate/compose

cat > /opt/frigate/traefik/traefik.yml << 'TRAEFIK_EOF'
# Traefik v3 — Frigate Production Reverse Proxy
# Let's Encrypt DNS-01 challenge via Cloudflare
# (frigate.hornung-bn.de is private DNS — DNS-01 works without public A record)

ping: {}

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

providers:
  docker:
    exposedByDefault: false

# Frigate 0.17 nginx on port 8971 uses self-signed TLS internally.
# Traefik must skip certificate verification when proxying to the backend.
serversTransport:
  insecureSkipVerify: true

certificatesResolvers:
  dns:
    acme:
      email: admin@hornung-bn.de
      storage: /letsencrypt/acme.json
      dnsChallenge:
        provider: cloudflare
        delayBeforeCheck: 10
        resolvers:
          - "1.1.1.1:53"
          - "8.8.8.8:53"
TRAEFIK_EOF

echo "[15/16] Traefik configured"

# =============================================================================
# 15b. Remove AppArmor (cannot manage profiles inside LXC)
# =============================================================================

apt-get remove -y apparmor 2>/dev/null || true

echo "[15b/18] AppArmor removed (LXC limitation)"

# =============================================================================
# 16. Frigate secrets — boot-time copy from CephFS
# =============================================================================

mkdir -p /etc/frigate
chmod 700 /etc/frigate

# Placeholder secrets.env (Frigate starts, cameras will fail until real secrets arrive)
cat > /etc/frigate/secrets.env << 'PLACEHOLDER_EOF'
# Placeholder — will be populated from CephFS after sync-frigate-secrets.sh runs
PLACEHOLDER=true
PLACEHOLDER_EOF
chmod 600 /etc/frigate/secrets.env

# Boot-copy script: CephFS -> local (fail-safe)
cat > /usr/local/sbin/frigate-secrets-copy << 'COPY_SCRIPT'
#!/bin/sh
SRC="/mnt/cephfs/swarm-state/stack-frigate/secrets.env"
DST="/etc/frigate/secrets.env"

if [ -f "$SRC" ]; then
  cp "$SRC" "$DST"
  chmod 600 "$DST"
  echo "frigate-secrets-copy: copied $(grep -c '=' "$DST") keys from CephFS"
else
  echo "frigate-secrets-copy: $SRC not found, keeping existing $DST"
fi
COPY_SCRIPT
chmod 755 /usr/local/sbin/frigate-secrets-copy

# systemd oneshot: runs before Docker starts
cat > /etc/systemd/system/frigate-secrets-copy.service << 'SVC'
[Unit]
Description=Copy Frigate secrets from CephFS to local
# CephFS ends up as a direct kernel mount in production and the
# mnt-cephfs.mount systemd unit gets masked; a hard Requires= on it makes this
# oneshot FAIL ("Unit mnt-cephfs.mount is masked"), so secrets never re-sync
# from CephFS — root cause of the 2026-05-31 frigate cert near-expiry, where
# CF_DNS_API_TOKEN never propagated to the Traefik sidecar. Gate on the source
# file instead: works whether CephFS is a mount unit, kernel mount, or bind.
ConditionPathExists=/mnt/cephfs/swarm-state/stack-frigate/secrets.env
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/frigate-secrets-copy

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable frigate-secrets-copy.service

echo "[16/18] Frigate secrets boot-copy configured"

# =============================================================================
# 18. GPU Verification + Status
# =============================================================================

echo "[18/18] GPU verification:"
if [ -e /dev/dri/renderD128 ]; then
  echo "  OK /dev/dri/renderD128 exists"
  ls -la /dev/dri/
else
  echo "  WARN /dev/dri/renderD128 NOT FOUND — iGPU passthrough may have failed"
fi

echo ""
echo "==========================================================="
echo " Frigate Production Setup Complete on $HOSTNAME"
echo "==========================================================="
echo ""
echo " IP (VLAN 4):  $IP_VLAN4"
echo " IP (VLAN 12): $IP_VLAN12"
echo ""
echo " Mounts:"
echo "   CephFS:     /mnt/cephfs (config, clips, exports)"
echo "   ZFS Rec:    /mnt/frigate-recordings (host bind-mount from tank/frigate-recordings)"
echo "   RBD DB:     /mnt/rbd/frigate-db (host bind-mount from Ceph RBD)"
echo ""
echo " Next steps:"
echo "   1. Create RBD image on Ceph: rbd create swarm-volumes/frigate-prod-db --size 10240"
echo "   2. Create host-side RBD map+mount systemd unit for DB on pve03"
echo "   3. Add LXC bind-mounts to 4502.conf:"
echo "      mp0: /tank/frigate-recordings,mp=/mnt/frigate-recordings,backup=0"
echo "      mp1: /mnt/rbd/frigate-prod-db,mp=/mnt/rbd/frigate-db,backup=0"
echo "   4. Restart LXC (pct stop/start 4502)"
echo "   5. Create CephFS dirs: /mnt/cephfs/swarm-state/stack-frigate/{config,clips,exports}"
echo "   6. Copy secrets.env from stack-frigate-prod to stack-frigate"
echo "   7. Run /usr/local/sbin/frigate-secrets-copy (copies CephFS -> local)"
echo "   8. Set up ZFS replication: zfs send/recv to pve01 + pve02 (smaller quotas)"
echo "   9. Push stack files to git -> pipeline deploys automatically"
echo ""
