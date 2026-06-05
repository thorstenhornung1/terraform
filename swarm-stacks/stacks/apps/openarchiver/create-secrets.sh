#!/bin/bash
# =============================================================================
# Create Docker Swarm Secrets for Open Archiver
# =============================================================================
# Run this on a Swarm manager node BEFORE deploying the openarchiver stack.
#
# Creates:
#   - openarchiver_db_password       (32-char alphanumeric, URL-safe)
#   - openarchiver_jwt_secret        (64-char hex, JWT signing)
#   - openarchiver_encryption_key    (64-char hex, DB-field encryption)
#   - openarchiver_meili_master_key  (32-char alphanumeric)
#
# Mail-Blobs liegen im Ceph RGW S3 (STORAGE_TYPE=s3) im Klartext (Homelab: Pool
# 3x repliziert) — kein openarchiver_storage_encryption_key.
#
# Die S3-Zugangsdaten (openarchiver_s3_access_key/_secret_key) sind EXTERNE
# Secrets (RGW-User, separat angelegt) und werden hier NICHT erzeugt.
#
# Idempotent: skips secrets that already exist (never overwrites — rotating the
# DB password is done by updating the same-named secret + redeploying postgres-ha,
# see db-init.sh / swarm-stacks#37).
# =============================================================================

set -euo pipefail

create_secret() {
  local name="$1"
  local value="$2"

  if docker secret inspect "$name" >/dev/null 2>&1; then
    echo "SECRET EXISTS: $name (skipping)"
    return 0
  fi

  printf '%s' "$value" | docker secret create "$name" -
  echo "SECRET CREATED: $name"
}

echo "=== Creating Open Archiver Docker Secrets ==="

# DB password: 32-char alphanumeric only (no URL-encoding needed in DATABASE_URL)
DB_PASSWORD=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)
# JWT signing key
JWT_SECRET=$(openssl rand -hex 32)
# AES-256 key (32 bytes = 64 hex chars) — verschlüsselt DB-Felder (Mailbox-Creds)
ENCRYPTION_KEY=$(openssl rand -hex 32)
# Meilisearch master key (shared between meili service and the app)
MEILI_MASTER_KEY=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)

create_secret "openarchiver_db_password" "$DB_PASSWORD"
create_secret "openarchiver_jwt_secret" "$JWT_SECRET"
create_secret "openarchiver_encryption_key" "$ENCRYPTION_KEY"
create_secret "openarchiver_meili_master_key" "$MEILI_MASTER_KEY"

echo ""
echo "=== Done ==="
echo ""
echo "############################################################################"
echo "# Hinweis: ENCRYPTION_KEY sichern (Passwortmanager).                        #"
echo "# Er verschlüsselt die in der DB gespeicherten Mailbox-/Graph-Zugänge.      #"
echo "# Bei Verlust bleibt das Archiv lesbar — nur die Ingestion-Quellen müssen   #"
echo "# neu verbunden werden. (Rotation: ./rotate-encryption-keys.sh)            #"
echo "#                                                                          #"
echo "#   ENCRYPTION_KEY = $ENCRYPTION_KEY"
echo "############################################################################"
echo ""
echo "Next steps:"
echo "  1. S3-Bucket:          aws --endpoint http://s3-rgw s3 mb s3://openarchiver  (oder s3cmd)"
echo "  2. CephFS dirs:        mkdir -p /mnt/cephfs/swarm-state/stack-openarchiver/{import,valkey,meili}"
echo "  3. Add init_app block to postgres-ha/db-init.sh → redeploy postgres-ha"
echo "  4. Add DNS:            archive.hornung-bn.de -> 192.168.4.40 (dns1+dns2+dns3 EINZELN)"
echo "  5. git push → GitOps deploys via ssh-deploy"
