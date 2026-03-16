#!/bin/sh
# =============================================================================
# Taiga Entrypoint Wrapper
# =============================================================================
# Reads Docker Secrets and exports them as environment variables before
# starting the Taiga backend (Django/Gunicorn) or Celery worker.
# =============================================================================

set -e

export POSTGRES_PASSWORD=$(cat /run/secrets/taiga_db_password)
export TAIGA_SECRET_KEY=$(cat /run/secrets/taiga_secret_key)
export OPENID_CLIENT_SECRET=$(cat /run/secrets/taiga_openid_client_secret)

# Ensure correct working directory (image WORKDIR = /taiga-back)
cd /taiga-back

if [ $# -gt 0 ]; then
  # taiga-async: celery command passed via 'command:' in compose
  exec "$@"
else
  # taiga-back: run original image entrypoint (Django/Gunicorn)
  exec /taiga-back/docker/entrypoint.sh
fi
