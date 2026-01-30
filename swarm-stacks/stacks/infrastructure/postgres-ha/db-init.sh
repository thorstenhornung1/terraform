#!/bin/sh
# =============================================================================
# Central Database Initialization Script
# =============================================================================
# Creates application databases and users in the PostgreSQL HA cluster.
# Idempotent - safe to run multiple times (creates or updates).
#
# Reads superuser password from: /run/secrets/pg_superuser_password
# Reads app passwords from:      /run/secrets/<app>_db_password
#
# Currently managed databases:
#   - homeassistant (user: homeassistant, db: homeassistant)
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

  # Create user if not exists, or update password
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" <<EOSQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${_user}') THEN
    CREATE USER ${_user} WITH PASSWORD '${_pass}';
    RAISE NOTICE 'User ${_user} created';
  ELSE
    ALTER USER ${_user} WITH PASSWORD '${_pass}';
    RAISE NOTICE 'User ${_user} password updated';
  END IF;
END
\$\$;
EOSQL

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

# --- Add future applications here ---
# MYAPP_PASS=$(cat /run/secrets/myapp_db_password)
# init_app "myapp" "$MYAPP_PASS" "myapp"

echo "=== Central database initialization complete! ==="
