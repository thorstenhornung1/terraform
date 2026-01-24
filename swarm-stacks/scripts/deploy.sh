#!/bin/bash
# =============================================================================
# Docker Swarm Stack Deployment Script
# =============================================================================
# Usage:
#   ./deploy.sh <stack_name>              Deploy a stack
#   ./deploy.sh <stack_name> --remove     Remove a stack
#   ./deploy.sh --list                    List all available stacks
#   ./deploy.sh --status                  Show deployed stacks
#
# Examples:
#   ./deploy.sh portainer
#   ./deploy.sh traefik --remove
# =============================================================================

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
STACKS_DIR="$REPO_ROOT/stacks"
SWARM_MANAGER="${SWARM_MANAGER:-192.168.4.30}"
SWARM_USER="${SWARM_USER:-ansible}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_header() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

# =============================================================================
# Helper Functions
# =============================================================================

ssh_swarm() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SWARM_USER}@${SWARM_MANAGER}" "$@"
}

find_stack_file() {
    local stack_name="$1"
    local stack_dir="$STACKS_DIR/$stack_name"

    if [ -d "$stack_dir" ]; then
        # Look for stack file in directory
        for pattern in "${stack_name}-stack.yml" "${stack_name}.yml" "docker-compose.yml" "stack.yml"; do
            if [ -f "$stack_dir/$pattern" ]; then
                echo "$stack_dir/$pattern"
                return 0
            fi
        done
    fi

    return 1
}

# =============================================================================
# Commands
# =============================================================================

cmd_list() {
    log_header "Available Stacks"

    for dir in "$STACKS_DIR"/*/; do
        if [ -d "$dir" ]; then
            stack_name=$(basename "$dir")
            stack_file=$(find_stack_file "$stack_name" 2>/dev/null || echo "")

            if [ -n "$stack_file" ]; then
                echo -e "  ${GREEN}●${NC} $stack_name"
                echo -e "    └── $(basename "$stack_file")"
            else
                echo -e "  ${YELLOW}○${NC} $stack_name (no stack file found)"
            fi
        fi
    done
}

cmd_status() {
    log_header "Deployed Stacks"

    ssh_swarm "docker stack ls" 2>/dev/null || {
        log_error "Cannot connect to Swarm manager at $SWARM_MANAGER"
        exit 1
    }

    echo ""
    log_header "Services"
    ssh_swarm "docker service ls"
}

cmd_deploy() {
    local stack_name="$1"

    log_header "Deploying: $stack_name"

    # Find stack file
    local stack_file
    stack_file=$(find_stack_file "$stack_name") || {
        log_error "Stack '$stack_name' not found in $STACKS_DIR"
        log_info "Available stacks:"
        cmd_list
        exit 1
    }

    log_info "Stack file: $stack_file"

    # Test SSH connection
    log_info "Connecting to Swarm manager: $SWARM_MANAGER"
    ssh_swarm "docker node ls" > /dev/null 2>&1 || {
        log_error "Cannot connect to Swarm manager"
        log_error "Ensure SSH access: ssh ${SWARM_USER}@${SWARM_MANAGER}"
        exit 1
    }

    # Copy and deploy
    log_info "Copying stack file to manager..."
    cat "$stack_file" | ssh_swarm "cat > /tmp/${stack_name}-stack.yml"

    log_info "Deploying stack..."
    ssh_swarm "docker stack deploy -c /tmp/${stack_name}-stack.yml $stack_name --prune"

    # Wait and show status
    sleep 3
    log_header "Deployment Status"
    ssh_swarm "docker stack services $stack_name"

    log_info "Deployment complete!"
}

cmd_remove() {
    local stack_name="$1"

    log_header "Removing: $stack_name"

    log_warn "This will remove all services in stack '$stack_name'"
    read -p "Continue? [y/N] " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted"
        exit 0
    fi

    ssh_swarm "docker stack rm $stack_name"

    log_info "Stack removed"
    log_warn "Note: Volumes were NOT removed"
}

cmd_logs() {
    local stack_name="$1"
    local service="$2"

    if [ -z "$service" ]; then
        # Show all services in stack
        log_info "Services in $stack_name:"
        ssh_swarm "docker stack services $stack_name --format '{{.Name}}'"
        log_info "Use: ./deploy.sh logs $stack_name <service_name>"
    else
        ssh_swarm "docker service logs -f ${stack_name}_${service}"
    fi
}

# =============================================================================
# Main
# =============================================================================

show_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  <stack_name>              Deploy a stack"
    echo "  <stack_name> --remove     Remove a stack"
    echo "  --list                    List available stacks"
    echo "  --status                  Show deployed stacks"
    echo "  logs <stack> [service]    View service logs"
    echo ""
    echo "Environment:"
    echo "  SWARM_MANAGER=$SWARM_MANAGER"
    echo "  SWARM_USER=$SWARM_USER"
    echo ""
    echo "Examples:"
    echo "  $0 portainer              # Deploy portainer stack"
    echo "  $0 portainer --remove     # Remove portainer stack"
    echo "  $0 --list                 # List all stacks"
    echo "  $0 logs portainer agent   # View portainer agent logs"
}

main() {
    case "${1:-}" in
        --list|-l)
            cmd_list
            ;;
        --status|-s)
            cmd_status
            ;;
        --help|-h|"")
            show_usage
            ;;
        logs)
            cmd_logs "${2:-}" "${3:-}"
            ;;
        *)
            if [ "${2:-}" == "--remove" ] || [ "${2:-}" == "-r" ]; then
                cmd_remove "$1"
            else
                cmd_deploy "$1"
            fi
            ;;
    esac
}

main "$@"
