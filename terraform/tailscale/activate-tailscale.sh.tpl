#!/bin/bash
# =============================================================================
# Tailscale + FRR Activation Script
# =============================================================================
# Rendered by Terraform templatefile() and placed at:
#   /usr/local/bin/activate-tailscale.sh
#
# Prerequisites:
#   - /etc/tailscale/secrets.env must exist (deployed from CephFS)
#   - Tailscale + FRR must be installed (setup-tailscale.sh)
#
# This script:
#   1. Reads secrets from /etc/tailscale/secrets.env
#   2. Enables and starts FRR (BGP + BFD)
#   3. Starts Tailscale with auth key and subnet routing
# =============================================================================

set -euo pipefail

SECRETS_FILE="/etc/tailscale/secrets.env"

echo "=== Activating Tailscale + FRR on $(hostname) ==="

# =============================================================================
# 1. Check secrets file
# =============================================================================

if [ ! -f "$SECRETS_FILE" ]; then
    echo "ERROR: $SECRETS_FILE not found!"
    echo "Deploy secrets from CephFS first:"
    echo "  ssh root@192.168.4.40 'cat /mnt/cephfs/swarm-state/stack-tailscale/secrets.env' | ssh root@$(hostname -I | awk '{print $1}') 'mkdir -p /etc/tailscale && cat > /etc/tailscale/secrets.env && chmod 600 /etc/tailscale/secrets.env'"
    exit 1
fi

# =============================================================================
# 2. Source secrets
# =============================================================================

# shellcheck source=/dev/null
source "$SECRETS_FILE"

if [ -z "$${TAILSCALE_AUTH_KEY:-}" ]; then
    echo "ERROR: TAILSCALE_AUTH_KEY not set in $SECRETS_FILE"
    exit 1
fi

echo "[1/3] Secrets loaded"

# =============================================================================
# 3. Enable and start FRR (BGP + BFD)
# =============================================================================

systemctl enable frr
systemctl start frr

echo "[2/3] FRR started (BGP + BFD)"

# =============================================================================
# 4. Start Tailscale with subnet routing
# =============================================================================

tailscale up \
    --authkey="$TAILSCALE_AUTH_KEY" \
    --advertise-routes=${advertise_routes} \
    --accept-routes=false \
    --hostname=${hostname}

echo "[3/3] Tailscale started (hostname=${hostname}, routes=${advertise_routes})"

echo ""
echo "=== Activation complete ==="
echo "Tailscale: $(tailscale status --self | head -1)"
echo "FRR: $(systemctl is-active frr)"
echo ""
echo "NEXT STEPS:"
echo "  1. Configure BGP on UniFi UDM-Pro"
echo "  2. Verify: vtysh -c 'show ip bgp summary'"
echo "  3. Approve subnet routes in Tailscale Admin Console"
echo "     https://login.tailscale.com/admin/machines"
