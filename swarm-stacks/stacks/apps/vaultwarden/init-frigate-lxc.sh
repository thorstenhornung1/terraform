#!/bin/bash
# =============================================================================
# Bootstrap Frigate-LXC Secrets from Vaultwarden
# =============================================================================
# Run this on a Swarm manager node AFTER Vaultwarden is configured:
#   - Organisation + Collection "frigate" exists
#   - Machine user svc-frigate has access to the collection
#   - API key generated (client_id + client_secret)
#   - Frigate secrets stored as Login items in the collection
#
# This script:
#   1. Reads Vaultwarden API credentials interactively (not via CLI args)
#   2. SSHs to the Frigate-LXC and writes /etc/frigate/bw-api.env
#   3. Runs the first secrets sync
#   4. Starts the daily sync timer
#
# Prerequisites:
#   - SSH key access to 192.168.4.61 as root
#   - bw CLI installed on Frigate-LXC (via setup-frigate-prod.sh.tpl)
#   - frigate-secrets-sync script deployed on Frigate-LXC
# =============================================================================

set -euo pipefail

FRIGATE_HOST="192.168.4.61"

echo "=== Bootstrapping Frigate-LXC Secrets ==="
echo ""
echo "Enter Vaultwarden API credentials for svc-frigate machine user."
echo "(These are stored on the LXC at /etc/frigate/bw-api.env, 0600 root:root)"
echo ""

# Read credentials interactively (not as CLI arguments = /proc-safe)
read -rp  "BW_CLIENTID (user.xxx-xxx): " BW_CLIENTID
read -rsp "BW_CLIENTSECRET: " BW_CLIENTSECRET; echo
read -rsp "BW_PASSWORD (master password): " BW_PASSWORD; echo

# Validate inputs
if [ -z "$BW_CLIENTID" ] || [ -z "$BW_CLIENTSECRET" ] || [ -z "$BW_PASSWORD" ]; then
  echo "ERROR: All three credentials are required."
  exit 1
fi

echo ""
echo "[1/3] Writing API credentials to Frigate-LXC..."

# SSH and write credentials via heredoc (no echo, no /proc leak)
# set +x prevents trace output of sensitive values
set +x 2>/dev/null
ssh -o StrictHostKeyChecking=accept-new root@$FRIGATE_HOST bash <<REMOTE_EOF
mkdir -p /etc/frigate && chmod 700 /etc/frigate
cat > /etc/frigate/bw-api.env <<'INNER_EOF'
BW_CLIENTID=${BW_CLIENTID}
BW_CLIENTSECRET=${BW_CLIENTSECRET}
BW_PASSWORD=${BW_PASSWORD}
INNER_EOF
chmod 600 /etc/frigate/bw-api.env
echo "bw-api.env written ($(wc -c < /etc/frigate/bw-api.env) bytes)"
REMOTE_EOF

echo "[2/3] Running first secrets sync..."
ssh root@$FRIGATE_HOST "/usr/local/sbin/frigate-secrets-sync"

echo "[3/3] Starting daily sync timer..."
ssh root@$FRIGATE_HOST "systemctl enable --now frigate-secrets-sync.timer"

KEY_COUNT=$(ssh root@$FRIGATE_HOST "wc -l < /etc/frigate/secrets.env 2>/dev/null || echo 0")

echo ""
echo "=== Bootstrap complete ==="
echo "  Keys synced: $KEY_COUNT"
echo "  Timer:       $(ssh root@$FRIGATE_HOST 'systemctl is-active frigate-secrets-sync.timer')"
echo ""
echo "Next: Update frigate-prod docker-compose.yml env_file and redeploy."
