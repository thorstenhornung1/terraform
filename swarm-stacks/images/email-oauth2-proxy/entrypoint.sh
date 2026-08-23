#!/bin/sh
# =============================================================================
# entrypoint: generiert emailproxy.config aus Secret + ENV, startet headless
# =============================================================================
# Die emailproxy.config enthält das client_secret UND wird vom Proxy zur Laufzeit
# beschrieben (Token-Cache). Wir trennen beides: die Config wird hier aus dem
# Docker-Secret + ENV nach /tmp generiert (nie auf Platte/Git), der Token-Cache
# geht via --cache-store nach /cache (bei CCG transient).
#
# CCG (client_credentials) ist app-only → KEIN interaktiver Authorize-Schritt;
# der Proxy holt den Token beim ersten IMAP-Request automatisch per client_secret.
# =============================================================================
set -eu

if [ ! -r /run/secrets/oa_oauth_imap ]; then
  echo "FATAL: /run/secrets/oa_oauth_imap not readable" >&2; exit 1
fi
CLIENT_SECRET="$(cat /run/secrets/oa_oauth_imap)"

: "${O365_CLIENT_ID:?O365_CLIENT_ID required}"
: "${O365_TENANT_ID:?O365_TENANT_ID required}"
: "${O365_MAILBOXES:?O365_MAILBOXES required (comma-separated mailbox addresses)}"
PROXY_PORT="${PROXY_PORT:-1993}"

CONF="$(mktemp /tmp/emailproxy.XXXXXX.config)"

# --- Server-Section: ein lokaler IMAP-Listener (Port = Name-Suffix) ---
{
  printf '[IMAP-%s]\n' "$PROXY_PORT"
  printf 'server_address = outlook.office365.com\n'
  printf 'server_port = 993\n'
  printf 'local_address = 0.0.0.0\n\n'
} > "$CONF"

# --- Pro Postfach ein [account]-Block (gleiche App, CCG/app-only) ---
OLDIFS=$IFS; IFS=','
for mbox in $O365_MAILBOXES; do
  mbox=$(printf '%s' "$mbox" | tr -d ' ')
  [ -z "$mbox" ] && continue
  {
    printf '[%s]\n' "$mbox"
    printf 'token_url = https://login.microsoftonline.com/%s/oauth2/v2.0/token\n' "$O365_TENANT_ID"
    printf 'oauth2_scope = https://outlook.office365.com/.default\n'
    printf 'oauth2_flow = client_credentials\n'
    printf 'client_id = %s\n' "$O365_CLIENT_ID"
    printf 'client_secret = %s\n\n' "$CLIENT_SECRET"
  } >> "$CONF"
done
IFS=$OLDIFS

echo "[entrypoint] config generiert ($PROXY_PORT, $(printf '%s' "$O365_MAILBOXES" | tr ',' ' ')); starte emailproxy headless" >&2

exec python -m emailproxy --no-gui --config-file "$CONF" --cache-store /cache/credstore.config
