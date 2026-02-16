#!/bin/bash
# =============================================================================
# Selective Portainer Stack Redeployment
# =============================================================================
# Called by adnanh/webhook when a GitHub push event is received.
# Parses the payload to determine which stack files changed,
# then triggers only the affected Portainer stack webhooks.
#
# Config: /config/webhooks.conf (mounted from CephFS)
#   Format per line: stacks/apps/uptime-kuma-stack.yml=<portainer-webhook-uuid>
# =============================================================================
set -euo pipefail

WEBHOOKS_CONF="${WEBHOOKS_CONF:-/config/webhooks.conf}"
PORTAINER_URL="${PORTAINER_URL:-https://portainer.hornung-bn.de}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- Payload parsen -----------------------------------------------------------
if [[ -z "${GITHUB_PAYLOAD:-}" || ! -f "${GITHUB_PAYLOAD}" ]]; then
  log "ERROR: No payload file (GITHUB_PAYLOAD env var)"
  exit 1
fi

PUSHER=$(jq -r '.pusher.name // "unknown"' "$GITHUB_PAYLOAD")
COMMIT=$(jq -r '.after // "unknown"' "$GITHUB_PAYLOAD" | head -c 7)
log "Push by $PUSHER (${COMMIT})"

# Alle geaenderten Dateien aus allen Commits extrahieren
CHANGED_FILES=$(jq -r '
  [.commits[]? | (.added[]?, .modified[]?, .removed[]?)]
  | unique | .[]
' "$GITHUB_PAYLOAD" 2>/dev/null || echo "")

# --- Config pruefen ----------------------------------------------------------
if [[ ! -f "$WEBHOOKS_CONF" ]]; then
  log "WARN: $WEBHOOKS_CONF not found — nothing to trigger"
  exit 0
fi

# --- Broadcast vs Selective ---------------------------------------------------
if [[ -z "$CHANGED_FILES" ]]; then
  log "No file list in payload — broadcasting to ALL stacks"
  while IFS='=' read -r path uuid; do
    [[ "$path" =~ ^[[:space:]]*#.*$ || -z "$path" ]] && continue
    path=$(echo "$path" | xargs)
    uuid=$(echo "$uuid" | xargs)
    log "  -> $path"
    curl -sf -X POST "${PORTAINER_URL}/api/stacks/webhooks/${uuid}" \
      || log "  WARN: webhook failed for $path"
  done < "$WEBHOOKS_CONF"
  exit 0
fi

log "Changed files:"
echo "$CHANGED_FILES" | while read -r f; do log "  $f"; done

TRIGGERED=0
while IFS='=' read -r path uuid; do
  [[ "$path" =~ ^[[:space:]]*#.*$ || -z "$path" ]] && continue
  path=$(echo "$path" | xargs)
  uuid=$(echo "$uuid" | xargs)

  # Verzeichnis des Stack-Compose-Files
  stack_dir=$(dirname "$path")

  # Pruefen ob eine geaenderte Datei in diesem Stack-Verzeichnis liegt
  if echo "$CHANGED_FILES" | grep -qE "^${stack_dir}/|^${path}$"; then
    log "MATCH: $path"
    if curl -sf -X POST "${PORTAINER_URL}/api/stacks/webhooks/${uuid}"; then
      log "  OK: Portainer webhook triggered"
      TRIGGERED=$((TRIGGERED + 1))
    else
      log "  WARN: Portainer webhook call failed"
    fi
  fi
done < "$WEBHOOKS_CONF"

log "Done — triggered $TRIGGERED stack(s)"
