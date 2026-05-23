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

# Patch: add gssencmode=disable to Django DATABASES OPTIONS.
# HAProxy cannot handle the GSSAPI encryption handshake from libpq,
# causing indefinite connection timeouts during migrate.
# The PGGSSENCMODE env var is not honoured by all libpq versions,
# so we inject the parameter directly into the psycopg2 OPTIONS dict.
sed -i "s/'OPTIONS': {'sslmode'/'OPTIONS': {'gssencmode': 'disable', 'sslmode'/" \
  /taiga-back/settings/config.py

# Ensure correct working directory (image WORKDIR = /taiga-back)
cd /taiga-back

if [ $# -gt 0 ]; then
  # taiga-async: celery command passed via 'command:' in compose
  exec "$@"
else
  # taiga-back: run original image entrypoint (Django/Gunicorn)
  exec /taiga-back/docker/entrypoint.sh
fi
