#!/bin/sh
# =============================================================================
# SeaweedFS Database Initialization Script
# =============================================================================
# Creates the seaweedfs database and user in PostgreSQL
# SeaweedFS filer auto-creates the filemeta table on first connection
# Idempotent - safe to run multiple times
# =============================================================================

set -e

echo "=== SeaweedFS Database Initialization ==="

# Read passwords from Docker secrets
export PGPASSWORD=$(cat /run/secrets/pg_superuser_password)
SEAWEEDFS_PASS=$(cat /run/secrets/seaweedfs_db_password)

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL at ${PGHOST}:${PGPORT}..."
until pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER"; do
  echo "PostgreSQL not ready, waiting..."
  sleep 5
done
echo "PostgreSQL is ready!"

# Create user if not exists, or update password
echo "Creating/updating seaweedfs user..."
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" <<EOSQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'seaweedfs') THEN
    CREATE USER seaweedfs WITH PASSWORD '${SEAWEEDFS_PASS}';
    RAISE NOTICE 'User seaweedfs created';
  ELSE
    ALTER USER seaweedfs WITH PASSWORD '${SEAWEEDFS_PASS}';
    RAISE NOTICE 'User seaweedfs password updated';
  END IF;
END
\$\$;
EOSQL

# Create database if not exists
echo "Creating seaweedfs database..."
if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -tc "SELECT 1 FROM pg_database WHERE datname = 'seaweedfs'" | grep -q 1; then
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -c "CREATE DATABASE seaweedfs OWNER seaweedfs"
  echo "Database created"
else
  echo "Database already exists"
fi

# Grant privileges
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -c "GRANT ALL PRIVILEGES ON DATABASE seaweedfs TO seaweedfs"

echo "=== Database initialization complete! ==="
echo "SeaweedFS filer will auto-create the filemeta table on first connection."
