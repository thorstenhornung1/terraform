#!/bin/bash
# =============================================================================
# Create Docker Swarm Secrets for Vaultwarden
# =============================================================================
# Run this on a Swarm manager node BEFORE deploying the Vaultwarden stack.
#
# Creates:
#   - vaultwarden_admin_token  (64-char hex token for /admin panel)
#   - vaultwarden_db_password  (32-char alphanumeric, URL-safe)
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

echo "=== Creating Vaultwarden Docker Secrets ==="

# Admin token: 64-char hex (used for /admin panel access)
ADMIN_TOKEN=$(openssl rand -hex 32)

# DB password: 32-char alphanumeric only (no URL encoding needed)
DB_PASSWORD=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)

create_secret "vaultwarden_admin_token" "$ADMIN_TOKEN"
create_secret "vaultwarden_db_password" "$DB_PASSWORD"

echo ""
echo "=== Done ==="
echo ""
echo "IMPORTANT: Save the admin token — you need it for https://vault.hornung-bn.de/admin"
echo "Admin Token: $ADMIN_TOKEN"
echo ""
echo "Next steps:"
echo "  1. Redeploy postgres-ha stack (db-init creates vaultwarden DB)"
echo "  2. mkdir -p /mnt/cephfs/swarm-state/stack-vaultwarden/data"
echo "  3. Add DNS: vault.hornung-bn.de -> Traefik VIP"
echo "  4. docker stack deploy -c vaultwarden-stack.yml vaultwarden"
