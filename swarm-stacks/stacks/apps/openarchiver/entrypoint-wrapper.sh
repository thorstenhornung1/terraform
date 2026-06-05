#!/bin/sh
# =============================================================================
# Entrypoint wrapper for Open Archiver
# =============================================================================
# Open Archiver liest seine Konfiguration ausschließlich aus reinen ENV-Vars
# (keine *_FILE-Konvention). Dieser Wrapper übersetzt die Docker-Secrets aus
# /run/secrets/ in ENV-Vars und übergibt dann an das image-eigene Entrypoint
# (docker-entrypoint.sh), das `pnpm db:migrate` ausführt und die App startet.
#
# Aufrufkette zur Laufzeit:
#   /bin/sh /entrypoint-wrapper.sh docker-entrypoint.sh pnpm docker-start:oss
#   └─ Secrets→ENV laden ─→ exec docker-entrypoint.sh pnpm docker-start:oss
#                            └─ pnpm install --prod → pnpm db:migrate → exec app
#
# Required secrets:
#   openarchiver_db_password       — Postgres password (user 'openarchiver')
#   openarchiver_jwt_secret        — JWT signing key (sessions/API)
#   openarchiver_encryption_key    — DB-field encryption (Mailbox-Credentials)
#   openarchiver_meili_master_key  — Meilisearch master key (shared w/ meili svc)
#   openarchiver_s3_access_key     — Ceph RGW S3 access key  (Mail-Blob-Storage)
#   openarchiver_s3_secret_key     — Ceph RGW S3 secret key
#
# Hinweis: STORAGE_ENCRYPTION_KEY (Mail-Blob-Verschlüsselung) wird bewusst NICHT
# gesetzt — im Homelab liegen die Blobs im Klartext im Ceph-RGW-S3-Pool (3x
# repliziert). Open Archiver deaktiviert die Storage-Verschlüsselung dann.
# =============================================================================

set -eu

for s in \
  openarchiver_db_password \
  openarchiver_jwt_secret \
  openarchiver_encryption_key \
  openarchiver_meili_master_key \
  openarchiver_s3_access_key \
  openarchiver_s3_secret_key
do
  if [ ! -r "/run/secrets/$s" ]; then
    echo "FATAL: /run/secrets/$s not readable" >&2
    exit 1
  fi
done

DB_PASSWORD="$(cat /run/secrets/openarchiver_db_password)"
export JWT_SECRET="$(cat /run/secrets/openarchiver_jwt_secret)"
export ENCRYPTION_KEY="$(cat /run/secrets/openarchiver_encryption_key)"
export MEILI_MASTER_KEY="$(cat /run/secrets/openarchiver_meili_master_key)"

# Ceph RGW S3 credentials (Mail-Blob-Storage; STORAGE_TYPE=s3 im Stack).
# Open Archiver nutzt eigene STORAGE_S3_*-Namen (nicht die AWS-SDK-Defaults).
export STORAGE_S3_ACCESS_KEY_ID="$(cat /run/secrets/openarchiver_s3_access_key)"
export STORAGE_S3_SECRET_ACCESS_KEY="$(cat /run/secrets/openarchiver_s3_secret_key)"

# Postgres target: HAProxy primary port (5433) on the postgres-ha overlay.
# db:migrate (im image-Entrypoint) wird gegen diese URL laufen — fungiert damit
# als lauter Pre-Flight-Check, der bei falschem Passwort/Host klar abbricht.
DB_HOST="${POSTGRES_HOST:-pg-haproxy}"
DB_PORT="${POSTGRES_PORT:-5433}"
DB_NAME="${POSTGRES_DB:-open_archive}"
DB_USER="${POSTGRES_USER:-openarchiver}"

# Passwort ist alphanumerisch (create-secrets.sh) → kein URL-Encoding nötig.
export DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
unset DB_PASSWORD

echo "[entrypoint] secrets loaded (db=${DB_HOST}:${DB_PORT}/${DB_NAME} user=${DB_USER}); handing off to image entrypoint" >&2

# Hand off to the image's own entrypoint + CMD (passed as args).
exec "$@"
