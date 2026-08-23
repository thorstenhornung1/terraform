#!/bin/sh
# paperless-ai-entrypoint.sh
# Injiziert den Paperless-API-Token aus dem Docker-Secret in die Env
# (clusterzx/paperless-ai kennt KEINE _FILE-Konvention) und exec't dann den
# originalen Image-Start: CMD ["./start-services.sh"], WORKDIR /app.
set -e
if [ -f /run/secrets/paperless_ai_api_token ]; then
  PAPERLESS_API_TOKEN="$(cat /run/secrets/paperless_ai_api_token)"
  export PAPERLESS_API_TOKEN
fi
cd /app
exec ./start-services.sh
