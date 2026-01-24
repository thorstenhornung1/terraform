#!/bin/bash
# =============================================================================
# Create Docker Secrets for PostgreSQL HA Cluster
# =============================================================================
# Run this script on a Swarm manager node before deploying the stack
#
# Usage: ./create-secrets.sh [--generate]
#   --generate: Auto-generate secure random passwords
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}PostgreSQL HA Secrets Setup${NC}"
echo "==========================================="

# Check if we should auto-generate passwords
GENERATE=false
if [[ "$1" == "--generate" ]]; then
    GENERATE=true
    echo -e "${YELLOW}Auto-generating secure passwords...${NC}"
fi

# Function to generate secure password
generate_password() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24
}

# Function to create or update secret
create_secret() {
    local name=$1
    local value=$2

    # Check if secret exists
    if docker secret inspect "$name" >/dev/null 2>&1; then
        echo -e "${YELLOW}Secret '$name' already exists. Skipping...${NC}"
        echo "  To update, first remove: docker secret rm $name"
        return 0
    fi

    echo "$value" | docker secret create "$name" -
    echo -e "${GREEN}Created secret: $name${NC}"
}

# Generate or prompt for passwords
if $GENERATE; then
    PG_SUPERUSER_PASSWORD=$(generate_password)
    PG_REPLICATION_PASSWORD=$(generate_password)
    PG_ADMIN_PASSWORD=$(generate_password)

    echo ""
    echo -e "${YELLOW}Generated passwords (save these securely!):${NC}"
    echo "  pg_superuser_password: $PG_SUPERUSER_PASSWORD"
    echo "  pg_replication_password: $PG_REPLICATION_PASSWORD"
    echo "  pg_admin_password: $PG_ADMIN_PASSWORD"
    echo ""
else
    echo "Enter passwords for PostgreSQL cluster:"
    echo ""

    read -sp "PostgreSQL superuser (postgres) password: " PG_SUPERUSER_PASSWORD
    echo ""

    read -sp "Replication user password: " PG_REPLICATION_PASSWORD
    echo ""

    read -sp "Admin user password: " PG_ADMIN_PASSWORD
    echo ""
fi

# Validate passwords
if [[ -z "$PG_SUPERUSER_PASSWORD" || -z "$PG_REPLICATION_PASSWORD" || -z "$PG_ADMIN_PASSWORD" ]]; then
    echo -e "${RED}Error: All passwords are required${NC}"
    exit 1
fi

# Create secrets
echo ""
echo "Creating Docker secrets..."
create_secret "pg_superuser_password" "$PG_SUPERUSER_PASSWORD"
create_secret "pg_replication_password" "$PG_REPLICATION_PASSWORD"
create_secret "pg_admin_password" "$PG_ADMIN_PASSWORD"

echo ""
echo -e "${GREEN}Secrets created successfully!${NC}"
echo ""
echo "Next steps:"
echo "  1. Build Patroni image: docker build -t patroni-postgres:16 ./docker/"
echo "  2. Deploy stack: docker stack deploy -c postgres-ha-stack.yml postgres"
echo "  3. Check status: docker service ls | grep postgres"
echo ""

# Verify secrets
echo "Verifying secrets..."
docker secret ls | grep -E "pg_superuser|pg_replication|pg_admin" || echo "No matching secrets found"
