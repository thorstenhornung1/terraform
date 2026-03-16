#!/bin/bash
# =============================================================================
# Create Docker Swarm Secrets for n8n
# =============================================================================
# Run this on a Swarm manager node BEFORE deploying the n8n stack.
#
# Creates:
#   - n8n_db_password      (32-char alphanumeric, URL-safe)
#   - n8n_encryption_key   (64-char hex, used to encrypt credentials in DB)
#
# Idempotent: skips secrets that already exist.
# =============================================================================

set -euo pipefail

create_secret() {
  local name="$1"
  local value="$2"

  if docker secret inspect "$name" >/dev/null 2>&1; then
    echo "SECRET EXISTS: $name (skipping)"
    return 0
  fi

  printf '%s' "$value" | docker secret create "$name" -
  echo "SECRET CREATED: $name"
}

echo "=== Creating n8n Docker Secrets ==="

# DB password: 32-char alphanumeric only (no URL encoding needed)
DB_PASSWORD=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)

# Encryption key: 64-char hex (encrypts workflow credentials in PostgreSQL)
ENCRYPTION_KEY=$(openssl rand -hex 32)

create_secret "n8n_db_password" "$DB_PASSWORD"
create_secret "n8n_encryption_key" "$ENCRYPTION_KEY"

echo ""
echo "=== Done ==="
echo ""
echo "IMPORTANT: Save the encryption key — losing it means all stored"
echo "           workflow credentials become unreadable!"
echo "Encryption Key: $ENCRYPTION_KEY"
echo ""
echo "Next steps:"
echo "  1. Redeploy postgres-ha stack (db-init creates n8n DB)"
echo "  2. mkdir -p /mnt/cephfs/swarm-state/stack-n8n/files"
echo "  3. Add DNS: n8n.hornung-bn.de -> Traefik VIP"
echo "  4. ENTRYPOINT_WRAPPER_HASH=\$(sha256sum entrypoint-wrapper.sh | cut -c1-12) \\"
echo "     docker stack deploy -c n8n-stack.yml n8n"
