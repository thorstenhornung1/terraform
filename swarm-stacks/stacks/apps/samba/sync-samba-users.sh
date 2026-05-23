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
#   AUTHENTIK_URL        — Authentik base URL (e.g. https://auth.hornung-bn.de)
#   AUTHENTIK_TOKEN_FILE — Path to file containing Authentik API token
#   FAMILY_GID           — GID for family group (default: 2000)
#
# The Expression Policy 'samba-nt-hash-sync' in Authentik computes the NT-Hash
# on every password change and stores it as user.attributes.sambaNTPassword.
# This script reads that attribute and writes it into Samba's tdbsam.
# =============================================================================
set -euo pipefail

AUTHENTIK_URL="${AUTHENTIK_URL:-https://auth.hornung-bn.de}"
AUTHENTIK_TOKEN=$(cat "${AUTHENTIK_TOKEN_FILE}")
FAMILY_GID="${FAMILY_GID:-2000}"

# Fetch all users from Authentik API, filter for sambaNTPassword client-side
response=$(curl -ksf --max-time 10 -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
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
  # User should already exist from entrypoint.sh, this is a safety net
  if ! id "$username" >/dev/null 2>&1; then
    useradd -M -s /usr/sbin/nologin -G family "$username" 2>/dev/null || true
  fi

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
