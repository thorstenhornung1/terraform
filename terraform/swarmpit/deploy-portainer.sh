#!/bin/bash
# =============================================================================
# Portainer CE Deployment Script for Docker Swarm
# =============================================================================
# Purpose: Deploy Portainer CE with agent on all nodes, server pinned to swarmpit
# Usage: ./deploy-portainer.sh [--remove]
#
# Requirements:
# - Docker Swarm must be initialized
# - Must be run from a Swarm manager node
# - swarmpit node must be part of the Swarm
# =============================================================================

set -e

# Configuration
STACK_NAME="portainer"
COMPOSE_FILE="$(dirname "$0")/portainer-stack.yml"
TARGET_NODE="swarmpit-mgmt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# Pre-flight Checks
# =============================================================================

check_swarm() {
    if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
        log_error "This node is not part of an active Docker Swarm."
        log_error "Initialize Swarm first: docker swarm init"
        exit 1
    fi

    if ! docker node ls &>/dev/null; then
        log_error "This node is not a Swarm manager. Run this script from a manager node."
        exit 1
    fi

    log_info "Docker Swarm is active and this is a manager node."
}

check_target_node() {
    if ! docker node ls --format '{{.Hostname}}' | grep -q "^${TARGET_NODE}$"; then
        log_error "Target node '${TARGET_NODE}' not found in Swarm."
        log_error "Available nodes:"
        docker node ls --format '  - {{.Hostname}} ({{.Status}}, {{.Availability}})'
        exit 1
    fi

    # Check if node is available
    local node_status=$(docker node ls --filter "name=${TARGET_NODE}" --format '{{.Status}}')
    local node_availability=$(docker node ls --filter "name=${TARGET_NODE}" --format '{{.Availability}}')

    if [ "$node_status" != "Ready" ] || [ "$node_availability" != "Active" ]; then
        log_error "Target node '${TARGET_NODE}' is not ready/active."
        log_error "Status: ${node_status}, Availability: ${node_availability}"
        exit 1
    fi

    log_info "Target node '${TARGET_NODE}' is ready and active."
}

check_compose_file() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "Stack file not found: $COMPOSE_FILE"
        exit 1
    fi
    log_info "Using stack file: $COMPOSE_FILE"
}

# =============================================================================
# Label Management
# =============================================================================

set_node_label() {
    local node_id=$(docker node ls --filter "name=${TARGET_NODE}" --format '{{.ID}}')

    # Check if label already exists
    local existing_label=$(docker node inspect "$node_id" --format '{{index .Spec.Labels "portainer.data"}}' 2>/dev/null || echo "")

    if [ "$existing_label" == "true" ]; then
        log_info "Label 'portainer.data=true' already set on ${TARGET_NODE}."
    else
        log_info "Setting label 'portainer.data=true' on ${TARGET_NODE}..."
        docker node update --label-add portainer.data=true "$node_id"
        log_info "Label set successfully."
    fi
}

# =============================================================================
# Stack Operations
# =============================================================================

deploy_stack() {
    log_info "Deploying Portainer CE stack..."
    docker stack deploy -c "$COMPOSE_FILE" "$STACK_NAME" --prune

    log_info "Waiting for services to start..."
    sleep 5

    # Check deployment status
    log_info "Service status:"
    docker stack services "$STACK_NAME" --format "  {{.Name}}: {{.Replicas}}"
}

remove_stack() {
    log_warn "Removing Portainer CE stack..."
    docker stack rm "$STACK_NAME"

    log_info "Waiting for services to stop..."
    sleep 10

    log_warn "Stack removed. Note: Volume 'portainer_portainer_data' was NOT removed."
    log_warn "To remove data: docker volume rm portainer_portainer_data"
}

show_status() {
    echo ""
    echo "==========================================="
    echo "  Portainer CE Deployment Status"
    echo "==========================================="
    echo ""
    docker stack services "$STACK_NAME" --format "table {{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}" 2>/dev/null || log_warn "Stack not deployed yet"
    echo ""

    # Get swarmpit IP
    local target_ip=$(docker node inspect "$TARGET_NODE" --format '{{range .Status.Addr}}{{.}}{{end}}' 2>/dev/null || echo "192.168.4.50")

    echo "-------------------------------------------"
    echo "  Access URLs:"
    echo "-------------------------------------------"
    echo "  HTTPS UI:  https://${target_ip}:9443"
    echo "  HTTP UI:   http://${target_ip}:9000"
    echo ""
    echo "  First login: Create admin account"
    echo "-------------------------------------------"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "==========================================="
    echo "  Portainer CE Deployment for Docker Swarm"
    echo "==========================================="
    echo ""

    # Handle --remove flag
    if [ "$1" == "--remove" ] || [ "$1" == "-r" ]; then
        check_swarm
        remove_stack
        exit 0
    fi

    # Handle --status flag
    if [ "$1" == "--status" ] || [ "$1" == "-s" ]; then
        show_status
        exit 0
    fi

    # Pre-flight checks
    check_swarm
    check_target_node
    check_compose_file

    # Set persistence label
    set_node_label

    # Deploy
    deploy_stack

    # Show access info
    show_status

    log_info "Deployment complete!"
}

main "$@"
