#!/bin/bash
set -euo pipefail

# =============================================================================
# PBS Backup Client Entrypoint
# =============================================================================
# Modes:
#   cron     - Run backups on a schedule (default: every 2 hours)
#   backup   - Run a single backup and exit
#   restore  - Restore from a specific snapshot (requires RESTORE_SNAPSHOT env)
# =============================================================================

BACKUP_SOURCE="${BACKUP_SOURCE:-/backup-source}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 */2 * * *}"
PBS_REPOSITORY="${PBS_REPOSITORY:?PBS_REPOSITORY environment variable is required}"

# Read PBS password from Docker secret
if [ -f /run/secrets/pbs_password ]; then
    export PBS_PASSWORD
    PBS_PASSWORD=$(cat /run/secrets/pbs_password)
else
    echo "ERROR: /run/secrets/pbs_password not found"
    exit 1
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

run_backup() {
    log "Starting backup of ${BACKUP_SOURCE} to ${PBS_REPOSITORY}"

    if [ ! -d "${BACKUP_SOURCE}" ]; then
        log "ERROR: Backup source directory ${BACKUP_SOURCE} does not exist"
        return 1
    fi

    local file_count
    file_count=$(find "${BACKUP_SOURCE}" -type f 2>/dev/null | wc -l)
    log "Found ${file_count} files in ${BACKUP_SOURCE}"

    if [ "${file_count}" -eq 0 ]; then
        log "WARNING: No files found in ${BACKUP_SOURCE}, skipping backup"
        return 0
    fi

    proxmox-backup-client backup \
        "swarm-state.pxar:${BACKUP_SOURCE}" \
        --repository "${PBS_REPOSITORY}" \
        2>&1

    local rc=$?
    if [ ${rc} -eq 0 ]; then
        log "Backup completed successfully"
    else
        log "ERROR: Backup failed with exit code ${rc}"
    fi
    return ${rc}
}

run_restore() {
    local snapshot="${RESTORE_SNAPSHOT:?RESTORE_SNAPSHOT required for restore mode}"
    local restore_target="${RESTORE_TARGET:-/restore}"

    log "Restoring snapshot ${snapshot} to ${restore_target}"
    mkdir -p "${restore_target}"

    proxmox-backup-client restore \
        "${snapshot}" \
        "swarm-state.pxar" \
        "${restore_target}" \
        --repository "${PBS_REPOSITORY}" \
        2>&1

    log "Restore completed to ${restore_target}"
}

run_cron() {
    log "Starting cron mode with schedule: ${BACKUP_SCHEDULE}"
    log "PBS repository: ${PBS_REPOSITORY}"
    log "Backup source: ${BACKUP_SOURCE}"

    # Run an initial backup on startup
    log "Running initial backup..."
    run_backup || log "Initial backup failed, will retry on schedule"

    # Write cron job — export env vars so cron subprocess inherits them
    local cron_file="/etc/cron.d/pbs-backup"
    cat > "${cron_file}" <<CRON
# PBS backup of Docker Swarm CephFS state
PBS_REPOSITORY=${PBS_REPOSITORY}
PBS_PASSWORD=${PBS_PASSWORD}
BACKUP_SOURCE=${BACKUP_SOURCE}

${BACKUP_SCHEDULE} root /usr/local/bin/entrypoint.sh backup >> /proc/1/fd/1 2>&1
CRON
    chmod 0644 "${cron_file}"

    log "Cron job installed, starting cron daemon..."
    exec cron -f
}

# =============================================================================
# Main
# =============================================================================
MODE="${1:-cron}"

case "${MODE}" in
    cron)
        run_cron
        ;;
    backup)
        run_backup
        ;;
    restore)
        run_restore
        ;;
    *)
        echo "Usage: $0 {cron|backup|restore}"
        exit 1
        ;;
esac
