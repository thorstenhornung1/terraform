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
# 2026-06-15: Migriert von Patroni (pg-haproxy:5433) auf Single-PG-VM
# postgres-prod (postgres.hornung-bn.de:5432) — Patroni→Single-VM-HA-Migration.
export DATABASE_URL="postgresql://vaultwarden:${DB_PASS}@postgres.hornung-bn.de:5432/vaultwarden"
unset DB_PASS

# ---------------------------------------------------------------------------
# Set admin token from secret
# ---------------------------------------------------------------------------
export ADMIN_TOKEN=$(cat /run/secrets/vaultwarden_admin_token)

# ---------------------------------------------------------------------------
# Start Vaultwarden
# ---------------------------------------------------------------------------
exec /start.sh
