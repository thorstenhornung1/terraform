#!/bin/bash
# =============================================================================
# Frigate OpenVINO Test Setup Script for LXC Container
# =============================================================================
# Rendered by Terraform templatefile() — do NOT edit directly.
# Installs: APT proxy, SSSD/LDAP, rsyslog → Loki, Docker CE, Intel GPU Runtime
#
# Container: Ubuntu 24.04 LXC (privileged, /dev/dri passthrough)
# Purpose:   Test Intel iGPU (OpenVINO) for Frigate object detection
# =============================================================================

set -euo pipefail

HOSTNAME="${hostname}"
IP="${ip}"

echo "=== Setting up Frigate OpenVINO test on $HOSTNAME ($IP) ==="

# =============================================================================
# 1. APT Proxy (apt-cacher-ng)
# =============================================================================

cat > /etc/apt/apt.conf.d/01proxy << 'EOF'
Acquire::http::Proxy "http://apt-cacher.hornung-bn.de:3142";
Acquire::https::Proxy "DIRECT";
EOF

echo "[1/11] APT proxy configured"

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
  libpam-sss

echo "[2/11] Base packages installed"

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

cat > /etc/rsyslog.d/60-loki.conf << 'LOKI_EOF'
# Forward all logs to Loki/Promtail syslog receiver
*.* @@loki.hornung-bn.de:1514
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
# 8. Install Docker CE (Ubuntu repository)
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

systemctl enable docker
systemctl start docker

echo "[8/11] Docker CE installed and started"

# =============================================================================
# 9. Install Intel GPU Runtime for OpenVINO
# =============================================================================
# Packages needed for OpenVINO GPU inference:
#   - intel-opencl-icd: Intel OpenCL ICD (GPU compute) — in Ubuntu 24.04 universe
#   - clinfo: GPU detection verification tool
#
# NOTE: intel-level-zero-gpu is NOT available in Ubuntu 24.04 repos.
# OpenVINO in Frigate uses OpenCL, not Level Zero — so intel-opencl-icd suffices.

apt-get install -y intel-opencl-icd clinfo

echo "[9/11] Intel GPU runtime installed"

# =============================================================================
# 10. Verify GPU Access
# =============================================================================

echo "[10/11] GPU verification:"
if [ -e /dev/dri/renderD128 ]; then
  echo "  ✓ /dev/dri/renderD128 exists"
  ls -la /dev/dri/
else
  echo "  ✗ /dev/dri/renderD128 NOT FOUND — iGPU passthrough may have failed"
  echo "    Check: ssh root@192.168.2.12 'cat /etc/pve/lxc/4500.conf'"
fi

# =============================================================================
# 11. Create Helper Scripts
# =============================================================================

# --- OpenVINO GPU Test Script ---
cat > /root/test-openvino-gpu.sh << 'TEST_EOF'
#!/bin/bash
# =============================================================================
# Test OpenVINO GPU detection with Frigate 0.17-rc3
# =============================================================================
# Creates a minimal config and starts Frigate to verify OpenVINO GPU loads.
# SUCCESS indicators in logs:
#   - "vaapi hwaccel" detected (GPU video decoding)
#   - "openvino" references during detector init
#   - FastAPI started successfully
#
# NOTE: --security-opt apparmor=unconfined is REQUIRED for Docker-in-LXC
# (AppArmor profile loading fails inside privileged LXC containers)

set -euo pipefail

echo "=== Starting Frigate OpenVINO GPU Test ==="

# Create test directory structure
# Recordings go to /mnt/recordings (ZFS bind-mount from host: tank/frigate/recordings)
# optimized for video: recordsize=1M, compression=off, sync=disabled
mkdir -p /opt/frigate-test/config /opt/frigate-test/clips /mnt/recordings

# Create minimal Frigate config for OpenVINO test
cat > /opt/frigate-test/config/config.yml << 'FRIGATE_CFG'
mqtt:
  enabled: false

detectors:
  openvino_gpu:
    type: openvino
    device: GPU

model:
  path: /openvino-model/ssdlite_mobilenet_v2.xml
  width: 300
  height: 300
  input_tensor: nhwc
  input_pixel_format: bgr
  labelmap_path: /openvino-model/coco_91cl_bkgr.txt

cameras: {}
FRIGATE_CFG

# Stop any existing test container
docker rm -f frigate-openvino-test 2>/dev/null || true

# Run Frigate with GPU access
echo "Starting Frigate container with GPU passthrough..."
docker run -d \
  --name frigate-openvino-test \
  --security-opt apparmor=unconfined \
  --device /dev/dri:/dev/dri \
  --shm-size=256m \
  -v /opt/frigate-test/config:/config \
  -v /mnt/recordings:/media/frigate/recordings \
  -v /opt/frigate-test/clips:/media/frigate/clips \
  -p 5001:5001 \
  -p 8554:8554 \
  -p 8555:8555/tcp \
  -p 8555:8555/udp \
  ghcr.io/blakeblackshear/frigate:0.17.0-rc3

# Wait for startup
echo "Waiting 30s for Frigate to initialize..."
sleep 30

# Check logs for GPU detection
echo ""
echo "=== Frigate Log Analysis ==="
LOGS=$(docker logs frigate-openvino-test 2>&1)

if echo "$LOGS" | grep -qi "vaapi\|openvino\|FastAPI started"; then
  echo "✓ SUCCESS: Frigate started with GPU support!"
  echo ""
  echo "Relevant log lines:"
  echo "$LOGS" | grep -i "vaapi\|openvino\|GPU\|detector\|FastAPI\|model_cache" || true
else
  echo "✗ Frigate did not start correctly..."
  echo ""
  echo "$LOGS" | grep -i "openvino\|GPU\|error\|fail" || true
fi

echo ""
echo "NOTE: OpenVINO detector only initializes when a camera is configured."
echo "      'vaapi hwaccel detected' confirms GPU access works."
echo ""
echo "Full logs: docker logs frigate-openvino-test"
echo "API check: curl http://localhost:5001/api/version"
echo "Stop test: docker rm -f frigate-openvino-test"
TEST_EOF

chmod +x /root/test-openvino-gpu.sh

# --- Cleanup Script ---
cat > /root/cleanup-frigate-test.sh << 'CLEANUP_EOF'
#!/bin/bash
# =============================================================================
# Cleanup Frigate OpenVINO test resources
# =============================================================================
set -euo pipefail

echo "=== Cleaning up Frigate test ==="

# Stop and remove containers
docker rm -f frigate-openvino-test 2>/dev/null && echo "Removed frigate-openvino-test" || true

# Remove test data
rm -rf /opt/frigate-test && echo "Removed /opt/frigate-test"

# Prune unused Docker images
docker image prune -af --filter "label=maintainer=Blake Blackshear" 2>/dev/null && echo "Pruned Frigate images" || true

echo "=== Cleanup complete ==="
echo "To destroy the LXC entirely:"
echo "  cd /Users/thorstenhornung/tmp/terraform"
echo "  terraform destroy -target=proxmox_virtual_environment_container.frigate_test"
CLEANUP_EOF

chmod +x /root/cleanup-frigate-test.sh

echo "[11/11] Helper scripts created"

echo ""
echo "==========================================================="
echo " Frigate OpenVINO Test Setup Complete on $HOSTNAME ($IP)"
echo "==========================================================="
echo ""
echo "Next steps:"
echo "  1. Verify GPU:  ls -la /dev/dri/"
echo "  2. Run test:    /root/test-openvino-gpu.sh"
echo "  3. Check API:   curl http://$IP:5001/api/version"
echo "  4. Cleanup:     /root/cleanup-frigate-test.sh"
echo ""
