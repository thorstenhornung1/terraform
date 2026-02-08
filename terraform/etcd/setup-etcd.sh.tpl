#!/bin/bash
# =============================================================================
# etcd Installation Script for Dedicated LXC Containers
# =============================================================================
# Rendered by Terraform templatefile() — do NOT edit directly.
# Installs etcd as a native systemd service (immune to Docker Swarm rollbacks).
#
# After running this script, the etcd service is ENABLED but NOT STARTED.
# Start manually AFTER registering the member with etcdctl member add.
# =============================================================================

set -euo pipefail

ETCD_VERSION="${etcd_version}"
ETCD_NAME="${etcd_name}"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_LISTEN_IP="${listen_ip}"
ETCD_INITIAL_CLUSTER="${initial_cluster}"
ETCD_CLUSTER_TOKEN="${cluster_token}"
ETCD_INITIAL_CLUSTER_STATE="${initial_cluster_state}"

echo "=== Installing etcd $ETCD_VERSION for member $ETCD_NAME ==="

# =============================================================================
# 1. Create etcd user and group
# =============================================================================
groupadd --system etcd 2>/dev/null || true
useradd --system --no-create-home --shell /usr/sbin/nologin -g etcd etcd 2>/dev/null || true

# =============================================================================
# 2. Download and install etcd binaries
# =============================================================================
DOWNLOAD_URL="https://github.com/etcd-io/etcd/releases/download/$ETCD_VERSION/etcd-$ETCD_VERSION-linux-amd64.tar.gz"
TMPDIR=$(mktemp -d)

echo "Downloading etcd $ETCD_VERSION..."
apt-get update -qq && apt-get install -y -qq curl ca-certificates > /dev/null 2>&1

curl -fsSL "$DOWNLOAD_URL" -o "$TMPDIR/etcd.tar.gz"
tar xzf "$TMPDIR/etcd.tar.gz" -C "$TMPDIR" --strip-components=1 --no-same-owner

install -m 0755 "$TMPDIR/etcd" /usr/local/bin/etcd
install -m 0755 "$TMPDIR/etcdctl" /usr/local/bin/etcdctl
install -m 0755 "$TMPDIR/etcdutl" /usr/local/bin/etcdutl

rm -rf "$TMPDIR"

echo "etcd version: $(/usr/local/bin/etcd --version | head -1)"

# =============================================================================
# 3. Create data directory
# =============================================================================
mkdir -p "$ETCD_DATA_DIR"
chown etcd:etcd "$ETCD_DATA_DIR"
chmod 700 "$ETCD_DATA_DIR"

# =============================================================================
# 4. Create systemd service unit
# =============================================================================
cat > /etc/systemd/system/etcd.service << 'UNIT_EOF'
[Unit]
Description=etcd distributed key-value store
Documentation=https://etcd.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=etcd
Group=etcd

ExecStart=/usr/local/bin/etcd \
  --name=${etcd_name} \
  --data-dir=/var/lib/etcd \
  --listen-client-urls=http://0.0.0.0:2379 \
  --advertise-client-urls=http://${listen_ip}:2379 \
  --listen-peer-urls=http://0.0.0.0:2380 \
  --initial-advertise-peer-urls=http://${listen_ip}:2380 \
  --initial-cluster=${initial_cluster} \
  --initial-cluster-state=${initial_cluster_state} \
  --initial-cluster-token=${cluster_token} \
  --enable-v2=false \
  --heartbeat-interval=250 \
  --election-timeout=1250

Restart=always
RestartSec=10
LimitNOFILE=65536

Environment=ETCD_UNSUPPORTED_ARCH=

[Install]
WantedBy=multi-user.target
UNIT_EOF

# =============================================================================
# 5. Enable service (do NOT start — wait for etcdctl member add)
# =============================================================================
systemctl daemon-reload
systemctl enable etcd

echo "=== etcd $ETCD_VERSION installed successfully ==="
echo "Member name:  $ETCD_NAME"
echo "Listen IP:    $ETCD_LISTEN_IP"
echo "Cluster:      $ETCD_INITIAL_CLUSTER"
echo ""
echo "NEXT STEPS (do NOT skip!):"
echo "  1. On an existing etcd member, run:"
echo "     etcdctl member add $ETCD_NAME --peer-urls=http://$ETCD_LISTEN_IP:2380"
echo "  2. Then start this member:"
echo "     systemctl start etcd"
echo "  3. Verify:"
echo "     etcdctl endpoint status --cluster -w table"
