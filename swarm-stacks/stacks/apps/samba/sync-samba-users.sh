#!/bin/bash
# =============================================================================
# Authentik → Samba tdbsam NT-Hash Sync
# =============================================================================
# Reads users with sambaNTPassword attribute from Authentik API and syncs
# their NT-Hashes into Samba's local tdbsam database via pdbedit.
#
# Run via cron every 5 minutes or manually on container start.
#
# Required env vars:
#   AUTHENTIK_URL        — Authentik base URL (e.g. http://authentik-server:9000)
#   AUTHENTIK_TOKEN_FILE — Path to file containing Authentik API token
#   PAPERLESS_GID        — GID for paperless group (default: 1000)
# =============================================================================
set -euo pipefail

AUTHENTIK_URL="${AUTHENTIK_URL:-http://authentik-server:9000}"
AUTHENTIK_TOKEN=$(cat "${AUTHENTIK_TOKEN_FILE}")
PAPERLESS_GID="${PAPERLESS_GID:-1000}"

# Fetch all users from Authentik API, filter for sambaNTPassword client-side
response=$(curl -ksf -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
  "${AUTHENTIK_URL}/api/v3/core/users/?page_size=100") || {
  echo "[sync] ERROR: Failed to fetch users from Authentik API"
  exit 1
}

users=$(echo "$response" \
  | jq -r '.results[] | select(.attributes.sambaNTPassword != null) | "\(.username):\(.attributes.sambaNTPassword)"')

synced=0
for entry in $users; do
  username="${entry%%:*}"
  nt_hash="${entry##*:}"

  # Ensure local Linux user exists (needed for pdbedit)
  useradd -M -s /usr/sbin/nologin -g "$PAPERLESS_GID" "$username" 2>/dev/null || true

  # Create or update Samba tdbsam entry with NT hash
  if pdbedit -L "$username" &>/dev/null; then
    pdbedit -r -u "$username" --set-nt-hash="$nt_hash" 2>/dev/null
  else
    # New user: create with dummy password, then set NT hash
    (echo "dummy"; echo "dummy") | pdbedit -a -u "$username" -t 2>/dev/null
    pdbedit -r -u "$username" --set-nt-hash="$nt_hash" 2>/dev/null
  fi
  synced=$((synced + 1))
done

echo "[sync] $(date '+%Y-%m-%d %H:%M:%S') — Synced $synced users from Authentik to Samba tdbsam"
