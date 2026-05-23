#!/bin/sh
# =============================================================================
# Grafana Entrypoint Wrapper — Read Docker Secrets into Environment Variables
# =============================================================================
# Grafana provisioning supports $VAR substitution in YAML files, but Docker
# secrets are files at /run/secrets/*. This wrapper reads them into env vars
# so contact-points.yml can use ${TELEGRAM_BOT_TOKEN} and ${TELEGRAM_CHAT_ID}.
# =============================================================================

# Read Telegram secrets if they exist
if [ -f /run/secrets/grafana_telegram_bot_token ]; then
  export TELEGRAM_BOT_TOKEN="$(cat /run/secrets/grafana_telegram_bot_token)"
fi

if [ -f /run/secrets/grafana_telegram_chat_id ]; then
  export TELEGRAM_CHAT_ID="$(cat /run/secrets/grafana_telegram_chat_id)"
fi

# Fall back to placeholder if secrets not mounted (avoids Grafana startup crash)
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-PLACEHOLDER_CREATE_DOCKER_SECRET}"
export TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-0}"

# Hand off to Grafana's original entrypoint
exec /run.sh "$@"
