#!/bin/sh
# =============================================================================
# Central Database Initialization Script
# =============================================================================
# Creates application databases and users in the PostgreSQL HA cluster.
# Idempotent AND non-destructive - safe to run on every Patroni restart.
# A working role password is NEVER overwritten (see init_app, #37).
#
# Reads superuser password from: /run/secrets/pg_superuser_password
# Reads app passwords from:      /run/secrets/<app>_db_password
#
# SECRET NAMING CONVENTION (swarm-stacks#37 — single source of truth):
#   The Docker secret read here as /run/secrets/<app>_db_password MUST be
#   the SAME external secret the app's stack references. The external
#   Docker secret name MUST be exactly `<app>_db_password` with NO
#   version suffix (_v2/_v3/_v5...). To rotate a password: update the
#   VALUE of the same-named secret in Portainer and redeploy postgres-ha
#   (db-init detects the drift and re-sets the role). Never introduce
#   versioned secret aliases for DB passwords again — that is precisely
#   how the app/db-init desync (#37) was created.
#
# Currently managed databases:
#   - homeassistant (user: homeassistant, db: homeassistant)
#   - vaultwarden   (user: vaultwarden,   db: vaultwarden)
#   - n8n           (user: n8n,           db: n8n)
#   - authentik     (user: authentik,     db: authentik)
#   - paperless     (user: paperless,     db: paperless)
#   - taiga         (user: taiga,         db: taiga)
#
# To add a new application:
#   1. Add a Docker secret: <app>_db_password
#   2. Add an init_app block below
#   3. Add the secret to postgres-ha-stack.yml (db-init service)
# =============================================================================

set -e

echo "=== Central Database Initialization ==="

# Read superuser password from Docker secret
export PGPASSWORD=$(cat /run/secrets/pg_superuser_password)

# ---------------------------------------------------------------------------
# Wait for PostgreSQL primary to be ready (via HAProxy)
# ---------------------------------------------------------------------------
echo "Waiting for PostgreSQL at ${PGHOST}:${PGPORT}..."
until pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER"; do
  echo "PostgreSQL not ready, waiting..."
  sleep 5
done
echo "PostgreSQL is ready!"

# ---------------------------------------------------------------------------
# Helper: create or update a user + database
# Usage: init_app <username> <password> <database>
# ---------------------------------------------------------------------------
init_app() {
  _user="$1"
  _pass="$2"
  _db="$3"

  echo "--- Initializing app: ${_user} / ${_db} ---"

  # -------------------------------------------------------------------------
  # Drift-aware, NON-DESTRUCTIVE password management (swarm-stacks#37)
  #
  # Previous behaviour: this ran `ALTER USER ... WITH PASSWORD` on EVERY
  # db-init run (i.e. every Patroni (re)start, including every swarm_os
  # maintenance reboot). That makes db-init the authoritative password
  # owner and silently overwrites the role password on each restart.
  # If an app's Docker secret ever drifts from the secret db-init reads,
  # the next maintenance reboot resets the role password out from under
  # the running app -> FATAL: password authentication failed -> crashloop
  # -> Traefik 404. This is exactly what took down reisekosten (#37).
  #
  # New behaviour: only touch the password when it is actually necessary:
  #   - role missing            -> CREATE USER with the secret password
  #   - secret password fails   -> ALTER USER (genuine drift / first set)
  #   - secret password works   -> DO NOTHING (idempotent, non-destructive)
  #
  # A working password is never overwritten. A maintenance reboot can no
  # longer desync a healthy app from its DB role.
  # -------------------------------------------------------------------------
  _role_exists=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -tAc \
    "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '${_user}'" 2>/dev/null || true)

  if [ "$_role_exists" != "1" ]; then
    echo "Role ${_user} missing -> creating"
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
      -c "CREATE USER ${_user} WITH PASSWORD '${_pass}'"
  else
    # Probe whether the secret's password already authenticates as this
    # role (connect to the maintenance DB 'postgres' to avoid depending
    # on the app DB existing yet). No password VALUE is ever printed.
    if PGPASSWORD="$_pass" psql -h "$PGHOST" -p "$PGPORT" \
         -U "$_user" -d postgres -tAc "SELECT 1" >/dev/null 2>&1; then
      echo "Role ${_user} password already valid -> no change (non-destructive)"
    else
      echo "Role ${_user} password drift/invalid -> resetting from secret"
      psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
        -c "ALTER USER ${_user} WITH PASSWORD '${_pass}'"
    fi
  fi

  # Create database if not exists
  if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -tc \
    "SELECT 1 FROM pg_database WHERE datname = '${_db}'" | grep -q 1; then
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
      -c "CREATE DATABASE ${_db} OWNER ${_user}"
    echo "Database ${_db} created"
  else
    echo "Database ${_db} already exists"
  fi

  # Ensure ownership and privileges
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
    -c "ALTER DATABASE ${_db} OWNER TO ${_user}"
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
    -c "GRANT ALL PRIVILEGES ON DATABASE ${_db} TO ${_user}"

  echo "--- Done: ${_user} / ${_db} ---"
}

# ===========================================================================
# Application databases
# ===========================================================================

# --- Home Assistant Recorder ---
HA_PASS=$(cat /run/secrets/ha_recorder_db_password)
init_app "homeassistant" "$HA_PASS" "homeassistant"

# --- Vaultwarden (Password Manager) ---
VW_PASS=$(cat /run/secrets/vaultwarden_db_password)
init_app "vaultwarden" "$VW_PASS" "vaultwarden"

# --- n8n (Workflow Automation) ---
N8N_PASS=$(cat /run/secrets/n8n_db_password)
init_app "n8n" "$N8N_PASS" "n8n"

# --- Authentik (SSO / Identity Provider) ---
AUTHENTIK_PASS=$(cat /run/secrets/authentik_db_password)
init_app "authentik" "$AUTHENTIK_PASS" "authentik"

# --- Paperless-ngx (Document Management) ---
PAPERLESS_PASS=$(cat /run/secrets/paperless_db_password)
init_app "paperless" "$PAPERLESS_PASS" "paperless"

# --- Taiga (Project Management) ---
TAIGA_PASS=$(cat /run/secrets/taiga_db_password)
init_app "taiga" "$TAIGA_PASS" "taiga"

# --- Immich (Photo Management) ---
IMMICH_PASS=$(cat /run/secrets/immich_db_password)
init_app "immich" "$IMMICH_PASS" "immich"

# Enable pgvector extension for Immich (vector search, face recognition)
echo "--- Enabling pgvector for immich ---"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d immich \
  -c "CREATE EXTENSION IF NOT EXISTS vector"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d immich \
  -c "CREATE EXTENSION IF NOT EXISTS earthdistance CASCADE"
echo "--- pgvector extensions enabled ---"

# --- Reisekostenabrechnung (Travel Expense Management) ---
REISEKOSTEN_PASS=$(cat /run/secrets/reisekosten_db_password)
init_app "reisekosten" "$REISEKOSTEN_PASS" "reisekosten"

# --- Reisekosten-Steuer (Tax-Year Document Collection) ---
REISEKOSTEN_STEUER_PASS=$(cat /run/secrets/reisekosten_steuer_db_password)
init_app "reisekosten_steuer" "$REISEKOSTEN_STEUER_PASS" "reisekosten_steuer"

# --- Add future applications here ---

echo "=== Central database initialization complete! ==="
