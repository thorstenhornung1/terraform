#!/bin/bash
# =============================================================================
# Create Docker Swarm Secrets for Taiga
# =============================================================================
# Run this on a Swarm manager node BEFORE deploying the Taiga stack.
#
# Creates:
#   - taiga_db_password           (32-char alphanumeric, URL-safe)
#   - taiga_secret_key            (64-char hex, Django SECRET_KEY)
#   - taiga_openid_client_secret  (placeholder — replace with Authentik value)
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

echo "=== Creating Taiga Docker Secrets ==="

# DB password: 32-char alphanumeric only (safe for connection strings)
DB_PASSWORD=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)

# Django SECRET_KEY: 64-char hex
SECRET_KEY=$(openssl rand -hex 32)

# OpenID client secret: placeholder (must be replaced with value from Authentik)
OPENID_SECRET="REPLACE_WITH_AUTHENTIK_CLIENT_SECRET"

create_secret "taiga_db_password" "$DB_PASSWORD"
create_secret "taiga_secret_key" "$SECRET_KEY"
create_secret "taiga_openid_client_secret" "$OPENID_SECRET"

echo ""
echo "=== Done ==="
echo ""
echo "IMPORTANT:"
echo "  1. The taiga_openid_client_secret is a PLACEHOLDER!"
echo "     After creating the Authentik OIDC provider, update it:"
echo "     docker secret rm taiga_openid_client_secret"
echo "     printf '<real-secret>' | docker secret create taiga_openid_client_secret -"
echo ""
echo "  2. Save the DB password for the postgres-ha db-init secret:"
echo "     printf '$DB_PASSWORD' | docker secret create taiga_db_password -"
echo "     (already created above — use same value in postgres-ha stack)"
echo ""
echo "Next steps:"
echo "  1. Redeploy postgres-ha stack (db-init creates taiga DB)"
echo "  2. mkdir -p /mnt/cephfs/swarm-state/stack-taiga/{media,static,rabbitmq}"
echo "  3. Add DNS: taiga.hornung-bn.de -> Traefik VIP"
echo "  4. Configure Authentik OIDC provider"
echo "  5. Update taiga_openid_client_secret with real value"
echo "  6. Deploy:"
echo "     export TAIGA_GATEWAY_HASH=\$(sha256sum taiga-gateway.conf | cut -c1-8)"
echo "     export ENTRYPOINT_WRAPPER_HASH=\$(sha256sum entrypoint-wrapper.sh | cut -c1-8)"
echo "     docker stack deploy -c taiga-stack.yml --resolve-image always taiga"
echo ""
