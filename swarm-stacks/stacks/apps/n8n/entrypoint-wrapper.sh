#!/bin/sh
# =============================================================================
# n8n Entrypoint Wrapper
# =============================================================================
# Reads Docker Secrets and exports DB_POSTGRESDB_PASSWORD + N8N_ENCRYPTION_KEY
# before starting n8n.
#
# Why a wrapper? n8n reads credentials from env vars, but Docker Swarm secrets
# are files under /run/secrets/. This bridge script converts file-based secrets
# to environment variables.
# =============================================================================

set -e

# ---------------------------------------------------------------------------
# Set PostgreSQL password from secret
# ---------------------------------------------------------------------------
export DB_POSTGRESDB_PASSWORD=$(cat /run/secrets/n8n_db_password)

# ---------------------------------------------------------------------------
# Set encryption key from secret (encrypts credentials stored in DB)
# ---------------------------------------------------------------------------
export N8N_ENCRYPTION_KEY=$(cat /run/secrets/n8n_encryption_key)

# ---------------------------------------------------------------------------
# Start n8n
# ---------------------------------------------------------------------------
exec n8n
