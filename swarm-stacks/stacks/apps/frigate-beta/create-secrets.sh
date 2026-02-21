#!/bin/bash
# =============================================================================
# Create Docker Secrets for Frigate Beta
# =============================================================================
# Run this script on a Swarm manager node before deploying the stack.
#
# Camera credentials are stored as a single key=value file.
# Edit the file below to match your cameras, then run this script.
#
# Usage: ./create-secrets.sh
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Frigate Beta Secrets Setup${NC}"
echo "==========================================="

# Function to create or skip existing secret
create_secret() {
    local name=$1
    local value=$2

    if docker secret inspect "$name" >/dev/null 2>&1; then
        echo -e "${YELLOW}Secret '$name' already exists. Skipping...${NC}"
        echo "  To update, first remove: docker secret rm $name"
        return 0
    fi

    echo "$value" | docker secret create "$name" -
    echo -e "${GREEN}Created secret: $name${NC}"
}

# --- Camera credentials (key=value file) ---
echo ""
echo -e "${YELLOW}Camera credentials secret (frigate_camera_credentials)${NC}"
echo "  This is a key=value file with one line per camera password."
echo "  Example:"
echo "    FRIGATE_CAM_FRONT_DOOR_PW=password1"
echo "    FRIGATE_CAM_GARAGE_PW=password2"
echo ""

CREDS_FILE=$(mktemp)
trap "rm -f $CREDS_FILE" EXIT

if docker secret inspect "frigate_camera_credentials" >/dev/null 2>&1; then
    echo -e "${YELLOW}Secret 'frigate_camera_credentials' already exists. Skipping...${NC}"
    echo "  To update: docker secret rm frigate_camera_credentials && re-run"
else
    echo "Enter camera credentials (one VAR=VALUE per line, empty line to finish):"
    while true; do
        read -p "  > " line
        [[ -z "$line" ]] && break
        echo "$line" >> "$CREDS_FILE"
    done

    if [[ ! -s "$CREDS_FILE" ]]; then
        echo -e "${RED}Error: No camera credentials entered${NC}"
        exit 1
    fi

    docker secret create "frigate_camera_credentials" "$CREDS_FILE"
    echo -e "${GREEN}Created secret: frigate_camera_credentials${NC}"
fi

# --- MQTT credentials ---
echo ""
read -p "MQTT username (e.g. frigate): " MQTT_USER
read -sp "MQTT password: " MQTT_PW
echo ""

create_secret "frigate_mqtt_user" "$MQTT_USER"
create_secret "frigate_mqtt_password" "$MQTT_PW"

echo ""
echo -e "${GREEN}Secrets created successfully!${NC}"
echo ""
echo "Next steps:"
echo "  1. Create CephFS directories:"
echo "     mkdir -p /mnt/cephfs/swarm-state/stack-frigate-beta/{db,model-cache}"
echo "  2. Verify NFS mount on docker-infra-3:"
echo "     mount | grep frigate-recordings"
echo "  3. Deploy stack via Portainer (Repository mode)"
echo ""

docker secret ls | grep -E "frigate_" || echo "No matching secrets found"
