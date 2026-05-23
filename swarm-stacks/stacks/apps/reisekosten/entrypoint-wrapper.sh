#!/bin/sh
# =============================================================================
# Entrypoint wrapper for Reisekostenabrechnung container
# =============================================================================
# Reads Docker secrets from /run/secrets/, assembles DATABASE_URL and
# SECRET_KEY env-vars, then execs the gunicorn server (via the image's
# default CMD).
#
# Required secrets:
#   /run/secrets/reisekosten_db_password — Postgres password for user 'reisekosten'
#   /run/secrets/reisekosten_secret_key   — Flask session signing key
# =============================================================================

set -eu

if [ ! -r /run/secrets/reisekosten_db_password ]; then
    echo "FATAL: /run/secrets/reisekosten_db_password not readable" >&2
    exit 1
fi
if [ ! -r /run/secrets/reisekosten_secret_key ]; then
    echo "FATAL: /run/secrets/reisekosten_secret_key not readable" >&2
    exit 1
fi

DB_PASSWORD="$(cat /run/secrets/reisekosten_db_password)"
SECRET_KEY="$(cat /run/secrets/reisekosten_secret_key)"

# OIDC secrets are optional — if both are present, the app enables
# Authentik login. If either is missing, the app stays in legacy single-
# user mode (useful for emergency fallback or local debugging).
if [ -r /run/secrets/reisekosten_oidc_client_id ] && [ -r /run/secrets/reisekosten_oidc_client_secret ]; then
    export AUTHENTIK_CLIENT_ID="$(cat /run/secrets/reisekosten_oidc_client_id)"
    export AUTHENTIK_CLIENT_SECRET="$(cat /run/secrets/reisekosten_oidc_client_secret)"
    echo "[entrypoint] OIDC enabled (Authentik client_id configured)" >&2
else
    echo "[entrypoint] OIDC disabled (oidc_client_id/_secret missing — legacy mode)" >&2
fi

# SCIM 2.0 provisioning bearer token — optional, same model as OIDC above.
# Present  -> /scim/v2 surface goes live. Absent -> stays fail-closed (404).
# Server-to-server only; never reaches the browser (#90).
if [ -r /run/secrets/REISEKOSTEN_SCIM_BEARER_TOKEN ]; then
    export SCIM_BEARER_TOKEN="$(cat /run/secrets/REISEKOSTEN_SCIM_BEARER_TOKEN)"
    echo "[entrypoint] SCIM 2.0 enabled (bearer token configured) — /scim/v2 live" >&2
else
    echo "[entrypoint] SCIM 2.0 disabled (REISEKOSTEN_SCIM_BEARER_TOKEN missing — /scim/v2 stays 404)" >&2
fi

# Postgres connection target: HAProxy primary port (5433) on the
# postgres-ha-stack overlay network. App will retry if HAProxy is mid-failover.
DB_HOST="${POSTGRES_HOST:-pg-haproxy}"
DB_PORT="${POSTGRES_PORT:-5433}"
DB_NAME="${POSTGRES_DB:-reisekosten}"
DB_USER="${POSTGRES_USER:-reisekosten}"

export DATABASE_URL="postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export SECRET_KEY

# Drop the password from the environment we'll exec into (DATABASE_URL still
# contains it, but at least the bare password isn't a separate variable).
unset DB_PASSWORD

# Pre-flight DB auth check before handing off to gunicorn. Catches the
# easy class of bugs (wrong password / wrong host / firewall) with a clear
# log line instead of an opaque app-side hang. 5 s timeout — should be
# subsecond in a healthy cluster.
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

# Hand off to whatever was passed as CMD/args — typically `gunicorn -c gunicorn.conf.py app:app`.
exec "$@"
