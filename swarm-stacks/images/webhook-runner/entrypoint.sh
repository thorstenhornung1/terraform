#!/bin/bash
set -euo pipefail

# Read Docker secrets into environment variables
if [[ -f /run/secrets/github_webhook_secret ]]; then
  export GITHUB_WEBHOOK_SECRET=$(cat /run/secrets/github_webhook_secret)
else
  echo "WARN: No github_webhook_secret found — HMAC validation will fail"
fi

exec webhook \
  -hooks /etc/webhook/hooks.json \
  -verbose \
  -template \
  -hotreload
