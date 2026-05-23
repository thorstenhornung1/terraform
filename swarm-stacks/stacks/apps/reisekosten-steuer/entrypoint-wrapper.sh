#!/bin/sh
# =============================================================================
# Entrypoint wrapper for Reisekosten-Steuer container
# =============================================================================
# Reads Docker secrets from /run/secrets/, assembles DATABASE_URL and
# SECRET_KEY env-vars, then execs the gunicorn server (the image CMD).
#
# Required secrets:
#   /run/secrets/reisekosten_steuer_db_password — Postgres pw, user 'reisekosten_steuer'
#   /run/secrets/reisekosten_steuer_secret_key   — Flask session signing key
# =============================================================================

set -eu

if [ ! -r /run/secrets/reisekosten_steuer_db_password ]; then
    echo "FATAL: /run/secrets/reisekosten_steuer_db_password not readable" >&2
    exit 1
fi
if [ ! -r /run/secrets/reisekosten_steuer_secret_key ]; then
    echo "FATAL: /run/secrets/reisekosten_steuer_secret_key not readable" >&2
    exit 1
fi

DB_PASSWORD="$(cat /run/secrets/reisekosten_steuer_db_password)"
SECRET_KEY="$(cat /run/secrets/reisekosten_steuer_secret_key)"

# OIDC secrets are optional — if both present, the app enables Authentik
# login. If either is missing, the app runs open (useful for emergency
# fallback or local debugging).
if [ -r /run/secrets/reisekosten_steuer_oidc_client_id ] && [ -r /run/secrets/reisekosten_steuer_oidc_client_secret ]; then
    AUTHENTIK_CLIENT_ID="$(cat /run/secrets/reisekosten_steuer_oidc_client_id)"
    AUTHENTIK_CLIENT_SECRET="$(cat /run/secrets/reisekosten_steuer_oidc_client_secret)"
    export AUTHENTIK_CLIENT_ID AUTHENTIK_CLIENT_SECRET
    echo "[entrypoint] OIDC enabled (Authentik client_id configured)" >&2
else
    echo "[entrypoint] OIDC disabled (oidc_client_id/_secret missing — open mode)" >&2
fi

# Postgres connection target: HAProxy primary port (5433) on the
# postgres-ha-stack overlay network. App retries if HAProxy is mid-failover.
DB_HOST="${POSTGRES_HOST:-pg-haproxy}"
DB_PORT="${POSTGRES_PORT:-5433}"
DB_NAME="${POSTGRES_DB:-reisekosten_steuer}"
DB_USER="${POSTGRES_USER:-reisekosten_steuer}"

export DATABASE_URL="postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export SECRET_KEY

# Drop the bare password from the environment we exec into (DATABASE_URL
# still contains it, but it isn't a separate variable).
unset DB_PASSWORD

# Pre-flight DB auth check before handing off to gunicorn — turns the easy
# class of bugs (wrong password / host / firewall) into a clear log line
# instead of an opaque app-side hang. 5 s timeout.
echo "[entrypoint] testing Postgres auth (target: ${DB_HOST}:${DB_PORT}/${DB_NAME} user=${DB_USER})..." >&2
if ! python3 - <<'PYEOF'
import os, sys, psycopg
url = os.environ["DATABASE_URL"]
try:
    psycopg.connect(url, connect_timeout=5).close()
    print("[entrypoint] auth OK", file=sys.stderr, flush=True)
except Exception as e:
    print(f"[entrypoint] auth FAILED: {type(e).__name__}: {str(e)[:300]}", file=sys.stderr, flush=True)
    sys.exit(1)
PYEOF
then
    echo "[entrypoint] aborting startup due to auth failure" >&2
    exit 1
fi

# Hand off to CMD — typically `gunicorn -c gunicorn.conf.py app:app`.
exec "$@"
