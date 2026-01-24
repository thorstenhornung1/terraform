#!/bin/bash
# =============================================================================
# Create SeaweedFS Database in PostgreSQL Cluster
# =============================================================================
# Run this script after PostgreSQL HA cluster is deployed and healthy
#
# Prerequisites:
#   - PostgreSQL cluster running (postgres stack)
#   - Access to primary PostgreSQL node
#
# Usage:
#   ./create-seaweedfs-db.sh [POSTGRES_HOST]
# =============================================================================

set -e

# Configuration
POSTGRES_HOST="${1:-192.168.12.40}"
POSTGRES_PORT="5432"
POSTGRES_ADMIN_USER="postgres"
SEAWEEDFS_USER="seaweedfs"
SEAWEEDFS_DB="seaweedfs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}SeaweedFS Database Setup${NC}"
echo "==========================================="
echo "PostgreSQL Host: ${POSTGRES_HOST}:${POSTGRES_PORT}"
echo ""

# Prompt for passwords
read -sp "PostgreSQL admin (postgres) password: " POSTGRES_ADMIN_PASSWORD
echo ""

read -sp "New SeaweedFS user password: " SEAWEEDFS_PASSWORD
echo ""

# Verify password is not empty
if [[ -z "$SEAWEEDFS_PASSWORD" ]]; then
    echo -e "${RED}Error: SeaweedFS password cannot be empty${NC}"
    exit 1
fi

# Export for psql
export PGPASSWORD="$POSTGRES_ADMIN_PASSWORD"

echo ""
echo -e "${YELLOW}Connecting to PostgreSQL...${NC}"

# Check connection
if ! psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_ADMIN_USER" -c "SELECT 1;" >/dev/null 2>&1; then
    echo -e "${RED}Error: Cannot connect to PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT}${NC}"
    echo "Make sure the PostgreSQL cluster is running and accessible."
    exit 1
fi

echo -e "${GREEN}Connected successfully!${NC}"

# Create user and database
echo ""
echo -e "${YELLOW}Creating SeaweedFS user and database...${NC}"

psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_ADMIN_USER" << EOF
-- Create user if not exists
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${SEAWEEDFS_USER}') THEN
        CREATE USER ${SEAWEEDFS_USER} WITH PASSWORD '${SEAWEEDFS_PASSWORD}';
        RAISE NOTICE 'User ${SEAWEEDFS_USER} created';
    ELSE
        ALTER USER ${SEAWEEDFS_USER} WITH PASSWORD '${SEAWEEDFS_PASSWORD}';
        RAISE NOTICE 'User ${SEAWEEDFS_USER} password updated';
    END IF;
END
\$\$;

-- Create database if not exists
SELECT 'CREATE DATABASE ${SEAWEEDFS_DB} OWNER ${SEAWEEDFS_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${SEAWEEDFS_DB}')\gexec

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE ${SEAWEEDFS_DB} TO ${SEAWEEDFS_USER};
EOF

echo -e "${GREEN}User and database created!${NC}"

# Create the filemeta table (required by SeaweedFS filer)
echo ""
echo -e "${YELLOW}Creating filemeta table...${NC}"

export PGPASSWORD="$SEAWEEDFS_PASSWORD"

psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$SEAWEEDFS_USER" -d "$SEAWEEDFS_DB" << 'EOF'
-- SeaweedFS filer metadata table
CREATE TABLE IF NOT EXISTS filemeta (
    dirhash     BIGINT,
    name        VARCHAR(65535),
    directory   VARCHAR(65535),
    meta        BYTEA,
    PRIMARY KEY (dirhash, name)
);

-- Create index for directory lookups
CREATE INDEX IF NOT EXISTS idx_filemeta_directory ON filemeta (directory);

-- Verify table exists
SELECT 'filemeta table ready' AS status
FROM information_schema.tables
WHERE table_name = 'filemeta';
EOF

echo -e "${GREEN}Database setup complete!${NC}"

echo ""
echo "==========================================="
echo -e "${GREEN}SeaweedFS Database Ready${NC}"
echo ""
echo "Connection details:"
echo "  Host:     ${POSTGRES_HOST}"
echo "  Port:     ${POSTGRES_PORT}"
echo "  Database: ${SEAWEEDFS_DB}"
echo "  User:     ${SEAWEEDFS_USER}"
echo "  Password: (as entered)"
echo ""
echo "Update filer.toml with the password:"
echo "  password = \"${SEAWEEDFS_PASSWORD}\""
echo ""
echo "Or create Docker config with updated filer.toml:"
echo "  docker config create filer_config filer.toml"
echo ""
