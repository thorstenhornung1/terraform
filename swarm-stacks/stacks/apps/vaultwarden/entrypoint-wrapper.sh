#!/bin/sh
# =============================================================================
# Vaultwarden Entrypoint Wrapper
# =============================================================================
# Reads Docker Secrets and exports DATABASE_URL + ADMIN_TOKEN before starting
# the official Vaultwarden entrypoint.
#
# Why a wrapper? Vaultwarden reads DATABASE_URL from env vars, but Docker Swarm
# secrets are files under /run/secrets/. This bridge script converts file-based
# secrets to environment variables.
# =============================================================================

set -e

# ---------------------------------------------------------------------------
# Build DATABASE_URL from secret
# ---------------------------------------------------------------------------
# Password is restricted to [a-zA-Z0-9] by create-secrets.sh, so no URL
# encoding needed. If you change the password generation, add encoding here.
DB_PASS=$(cat /run/secrets/vaultwarden_db_password)
export DATABASE_URL="postgresql://vaultwarden:${DB_PASS}@pg-haproxy:5433/vaultwarden"
unset DB_PASS

# ---------------------------------------------------------------------------
# Set admin token from secret
# ---------------------------------------------------------------------------
export ADMIN_TOKEN=$(cat /run/secrets/vaultwarden_admin_token)

# ---------------------------------------------------------------------------
# Start Vaultwarden
# ---------------------------------------------------------------------------
exec /start.sh
