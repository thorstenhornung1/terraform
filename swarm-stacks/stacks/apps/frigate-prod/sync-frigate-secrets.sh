#!/bin/bash
# =============================================================================
# Frigate Secrets Sync — Docker Swarm Secrets -> CephFS secrets.env
# =============================================================================
# Auto-discovers ALL frigate_* Docker Secrets in the Swarm, creates a
# temporary one-shot service that reads them and writes a KEY=VALUE .env
# file to CephFS. The Frigate LXC copies this file at boot time.
#
# Usage:  Run on any Swarm manager node:
#           ./sync-frigate-secrets.sh
#
# Prerequisites:
#   - Docker Swarm manager access
#   - CephFS mounted at /mnt/cephfs
#   - frigate_* secrets already created in Docker Swarm
#
# Output: /mnt/cephfs/swarm-state/stack-frigate-prod/secrets.env (0600)
# =============================================================================

set -euo pipefail

OUTPUT_DIR="/mnt/cephfs/swarm-state/stack-frigate-prod"
OUTPUT_FILE="$OUTPUT_DIR/secrets.env"
SERVICE_NAME="frigate-secrets-writer"

log()     { echo "$(date '+%Y-%m-%d %H:%M:%S') [sync-frigate-secrets] $*"; }
log_err() { echo "$(date '+%Y-%m-%d %H:%M:%S') [sync-frigate-secrets] ERROR: $*" >&2; }

# -------------------------------------------------------------------------
# 1. Validate prerequisites
# -------------------------------------------------------------------------
if ! docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
  log_err "Not a Swarm manager or Swarm is inactive"
  exit 1
fi

if [ ! -d "$OUTPUT_DIR" ]; then
  log "Creating output directory: $OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"
  chmod 700 "$OUTPUT_DIR"
fi

# -------------------------------------------------------------------------
# 2. Auto-discover all frigate_* secrets
# -------------------------------------------------------------------------
SECRETS=$(docker secret ls --format '{{.Name}}' | grep '^frigate_' | sort)

if [ -z "$SECRETS" ]; then
  log_err "No frigate_* secrets found in Docker Swarm"
  exit 1
fi

COUNT=$(echo "$SECRETS" | wc -l | tr -d ' ')
log "Found $COUNT frigate_* secrets:"
echo "$SECRETS" | sed 's/^/  /'

# -------------------------------------------------------------------------
# 3. Build --secret flags dynamically
# -------------------------------------------------------------------------
SECRET_FLAGS=""
for name in $SECRETS; do
  SECRET_FLAGS="$SECRET_FLAGS --secret $name"
done

# -------------------------------------------------------------------------
# 4. Clean up stale service (if previous run was interrupted)
# -------------------------------------------------------------------------
docker service rm "$SERVICE_NAME" 2>/dev/null || true
sleep 1

# -------------------------------------------------------------------------
# 5. Create temporary one-shot service
# -------------------------------------------------------------------------
log "Creating one-shot secrets-writer service..."

# shellcheck disable=SC2086
docker service create \
  --detach \
  --name "$SERVICE_NAME" \
  --restart-condition none \
  --constraint 'node.role == manager' \
  --mount type=bind,source="$OUTPUT_DIR",target=/output \
  $SECRET_FLAGS \
  alpine:3.21 sh -c '
    TMP="/output/secrets.env.tmp"
    echo "# Frigate secrets — written $(date -Iseconds)" > "$TMP"
    echo "# Source: Docker Swarm secrets (auto-discovered frigate_*)" >> "$TMP"
    echo "# DO NOT EDIT — regenerate with sync-frigate-secrets.sh" >> "$TMP"
    echo "" >> "$TMP"
    COUNT=0
    for f in /run/secrets/frigate_*; do
      [ -f "$f" ] || continue
      key=$(basename "$f" | tr "[:lower:]" "[:upper:]")
      val=$(cat "$f")
      echo "${key}=${val}" >> "$TMP"
      COUNT=$((COUNT + 1))
    done
    chmod 600 "$TMP"
    mv "$TMP" "/output/secrets.env"
    echo "Wrote $COUNT secrets to /output/secrets.env"
  '

# -------------------------------------------------------------------------
# 6. Wait for service completion (max 60s)
# -------------------------------------------------------------------------
log "Waiting for secrets-writer to complete..."
TIMEOUT=60
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
  # Get the desired state + current state of the most recent task
  DESIRED=$(docker service ps "$SERVICE_NAME" --format '{{.DesiredState}}' 2>/dev/null | head -1)
  CURRENT=$(docker service ps "$SERVICE_NAME" --format '{{.CurrentState}}' 2>/dev/null | head -1)

  case "$DESIRED" in
    Shutdown)
      case "$CURRENT" in
        Complete*)
          log "Service completed successfully"
          break
          ;;
        Failed*|Rejected*)
          log_err "Service failed! State: $CURRENT"
          docker service logs "$SERVICE_NAME" 2>/dev/null || true
          docker service rm "$SERVICE_NAME" 2>/dev/null || true
          exit 1
          ;;
      esac
      ;;
  esac

  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  log_err "Timeout waiting for service (${TIMEOUT}s)"
  docker service ps "$SERVICE_NAME" --no-trunc 2>/dev/null || true
  docker service rm "$SERVICE_NAME" 2>/dev/null || true
  exit 1
fi

# -------------------------------------------------------------------------
# 7. Show logs and clean up
# -------------------------------------------------------------------------
docker service logs "$SERVICE_NAME" 2>/dev/null || true
docker service rm "$SERVICE_NAME"

# -------------------------------------------------------------------------
# 8. Verify output
# -------------------------------------------------------------------------
if [ -f "$OUTPUT_FILE" ]; then
  WRITTEN=$(grep -c '=' "$OUTPUT_FILE" 2>/dev/null || echo 0)
  log "Done. $WRITTEN secrets written to $OUTPUT_FILE"
else
  log_err "Output file not found after service completed"
  exit 1
fi
