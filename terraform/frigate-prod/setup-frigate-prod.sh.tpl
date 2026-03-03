#!/bin/bash
# =============================================================================
# Frigate Production Setup Script for LXC Container
# =============================================================================
# Rendered by Terraform templatefile() — do NOT edit directly.
# Installs: APT proxy, SSSD/LDAP, rsyslog → Loki, Docker CE, Intel GPU Runtime,
#           Ceph client + CephFS/RBD mounts, Traefik config, Docker Compose project
#
# Container: Ubuntu 24.04 LXC (privileged, /dev/dri passthrough)
# Purpose:   Production Frigate NVR with OpenVINO iGPU + Ceph storage
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
# 6. rsyslog → Loki/Promtail
# =============================================================================

cat > /etc/rsyslog.d/60-loki.conf << 'LOKI_EOF'
# Forward all logs to Loki/Promtail syslog receiver
*.* @@loki.hornung-bn.de:1514
*.* @loki.hornung-bn.de:1514
LOKI_EOF

echo "[6/16] rsyslog → Loki configured"

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

apt-get install -y -qq ceph-common

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
cat > /etc/ceph/ceph.client.$CEPH_CLIENT.keyring << KEYRING_EOF
[client.$CEPH_CLIENT]
    key = $CEPH_KEY
    caps mon = "allow r"
    caps osd = "allow rw pool=frigate-recordings, allow rw pool=swarm-volumes"
    caps mds = "allow rw"
KEYRING_EOF

chmod 600 /etc/ceph/ceph.client.$CEPH_CLIENT.keyring

echo "[11/16] Ceph client configured"

# =============================================================================
# 12. CephFS systemd mount — /mnt/cephfs
# =============================================================================

mkdir -p /mnt/cephfs

cat > /etc/systemd/system/mnt-cephfs.mount << MOUNT_EOF
[Unit]
Description=CephFS Mount (swarm-shared)
After=network-online.target
Wants=network-online.target

[Mount]
What=$CEPH_CLIENT@.$CEPH_FSID=/
Where=/mnt/cephfs
Type=ceph
Options=name=$CEPH_CLIENT,secretfile=/etc/ceph/ceph.client.$CEPH_CLIENT.keyring,_netdev

[Install]
WantedBy=multi-user.target
MOUNT_EOF

# Create secret file for CephFS mount (fstab-compatible format)
echo "$CEPH_KEY" > /etc/ceph/ceph.client.$CEPH_CLIENT.secret
chmod 600 /etc/ceph/ceph.client.$CEPH_CLIENT.secret

# Fix mount options to use secret file directly
cat > /etc/systemd/system/mnt-cephfs.mount << MOUNT_EOF2
[Unit]
Description=CephFS Mount (swarm-shared)
After=network-online.target
Wants=network-online.target

[Mount]
What=$CEPH_MON:/
Where=/mnt/cephfs
Type=ceph
Options=name=$CEPH_CLIENT,secret=$CEPH_KEY,_netdev

[Install]
WantedBy=multi-user.target
MOUNT_EOF2

systemctl daemon-reload
systemctl enable mnt-cephfs.mount
systemctl start mnt-cephfs.mount || echo "WARNING: CephFS mount failed — may need manual retry after Ceph pool/client is created"

echo "[12/16] CephFS mount configured"

# =============================================================================
# 13. RBD systemd mounts — /mnt/rbd/frigate-recordings + /mnt/rbd/frigate-db
# =============================================================================

mkdir -p /mnt/rbd/frigate-recordings /mnt/rbd/frigate-db

# --- RBD Map Service: frigate-recordings (1 TB, replica 1) ---
cat > /etc/systemd/system/rbd-map-frigate-recordings.service << 'RBD_REC_SVC'
[Unit]
Description=Map Ceph RBD frigate-recordings
After=network-online.target
Wants=network-online.target
Before=mnt-rbd-frigate\x2drecordings.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/rbd map frigate-recordings/frigate-recordings --id frigate-prod
ExecStop=/usr/bin/rbd unmap /dev/rbd/frigate-recordings/frigate-recordings

[Install]
WantedBy=multi-user.target
RBD_REC_SVC

# --- RBD Mount: frigate-recordings ---
cat > '/etc/systemd/system/mnt-rbd-frigate\x2drecordings.mount' << 'RBD_REC_MNT'
[Unit]
Description=Mount Ceph RBD frigate-recordings
After=rbd-map-frigate-recordings.service
Requires=rbd-map-frigate-recordings.service

[Mount]
What=/dev/rbd/frigate-recordings/frigate-recordings
Where=/mnt/rbd/frigate-recordings
Type=ext4
Options=noatime,defaults

[Install]
WantedBy=multi-user.target
RBD_REC_MNT

# --- RBD Map Service: frigate-db (10 GB, on swarm-volumes pool = 3x replicated) ---
cat > /etc/systemd/system/rbd-map-frigate-db.service << 'RBD_DB_SVC'
[Unit]
Description=Map Ceph RBD frigate-db
After=network-online.target
Wants=network-online.target
Before=mnt-rbd-frigate\x2ddb.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/rbd map swarm-volumes/frigate-db --id frigate-prod
ExecStop=/usr/bin/rbd unmap /dev/rbd/swarm-volumes/frigate-db

[Install]
WantedBy=multi-user.target
RBD_DB_SVC

# --- RBD Mount: frigate-db ---
cat > '/etc/systemd/system/mnt-rbd-frigate\x2ddb.mount' << 'RBD_DB_MNT'
[Unit]
Description=Mount Ceph RBD frigate-db (SQLite)
After=rbd-map-frigate-db.service
Requires=rbd-map-frigate-db.service

[Mount]
What=/dev/rbd/swarm-volumes/frigate-db
Where=/mnt/rbd/frigate-db
Type=ext4
Options=noatime,defaults

[Install]
WantedBy=multi-user.target
RBD_DB_MNT

systemctl daemon-reload

# Enable all RBD units (actual start happens after RBD images exist)
systemctl enable rbd-map-frigate-recordings.service
systemctl enable 'mnt-rbd-frigate\x2drecordings.mount'
systemctl enable rbd-map-frigate-db.service
systemctl enable 'mnt-rbd-frigate\x2ddb.mount'

# Try to start (will fail gracefully if pools/images don't exist yet)
systemctl start rbd-map-frigate-recordings.service 2>/dev/null && \
  systemctl start 'mnt-rbd-frigate\x2drecordings.mount' 2>/dev/null || \
  echo "INFO: RBD frigate-recordings not available yet — will mount after pool/image creation"

systemctl start rbd-map-frigate-db.service 2>/dev/null && \
  systemctl start 'mnt-rbd-frigate\x2ddb.mount' 2>/dev/null || \
  echo "INFO: RBD frigate-db not available yet — will mount after pool/image creation"

echo "[13/16] RBD systemd mounts configured"

# =============================================================================
# 14. Docker drop-in — wait for Ceph mounts before Docker starts
# =============================================================================

mkdir -p /etc/systemd/system/docker.service.d

cat > /etc/systemd/system/docker.service.d/wait-for-ceph.conf << 'DOCKER_DROP'
[Unit]
After=mnt-cephfs.mount
After=mnt-rbd-frigate\x2drecordings.mount
After=mnt-rbd-frigate\x2ddb.mount
Wants=mnt-cephfs.mount
Wants=mnt-rbd-frigate\x2drecordings.mount
Wants=mnt-rbd-frigate\x2ddb.mount
DOCKER_DROP

systemctl daemon-reload
systemctl enable docker
systemctl start docker

echo "[14/16] Docker configured with Ceph dependencies"

# =============================================================================
# 15. Traefik Configuration
# =============================================================================

mkdir -p /opt/frigate-prod/traefik
mkdir -p /opt/frigate-prod/secrets
mkdir -p /opt/frigate-prod/compose

cat > /opt/frigate-prod/traefik/traefik.yml << 'TRAEFIK_EOF'
# Traefik v3 — Frigate Production Reverse Proxy
# Let's Encrypt HTTP-01 challenge for TLS certificates
# DNS entry managed in Technitium (frigate.beta.hornung-bn.de → 192.168.4.61)

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

certificatesResolvers:
  http:
    acme:
      email: thorsten@hornung-bn.de
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web
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
# Secrets are managed as Docker Swarm secrets (frigate_*) and synced to CephFS
# by sync-frigate-secrets.sh on the Swarm manager. This section sets up a
# boot-time copy from CephFS to /etc/frigate/secrets.env (fail-safe: local
# copy survives CephFS outages and reboots).
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
SRC="/mnt/cephfs/swarm-state/stack-frigate-prod/secrets.env"
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
After=mnt-cephfs.mount
Requires=mnt-cephfs.mount
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
echo "   CephFS:     /mnt/cephfs"
echo "   RBD Rec:    /mnt/rbd/frigate-recordings"
echo "   RBD DB:     /mnt/rbd/frigate-db"
echo ""
echo " Next steps:"
echo "   1. Create Ceph pool + RBD images (Phase 1 in plan)"
echo "   2. Restart RBD mounts: systemctl start rbd-map-frigate-*.service"
echo "   3. Copy config + entrypoint to /mnt/cephfs/swarm-state/stack-frigate-prod/config/"
echo "   4. Run sync-frigate-secrets.sh on Swarm manager (writes secrets.env to CephFS)"
echo "   5. Run /usr/local/sbin/frigate-secrets-copy on LXC (copies CephFS -> local)"
echo "   6. Place docker-compose.yml in /opt/frigate-prod/compose/"
echo "   7. docker compose -f /opt/frigate-prod/compose/docker-compose.yml up -d"
echo ""
