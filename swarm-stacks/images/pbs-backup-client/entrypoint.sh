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

# log() must be defined first — any early ERROR path uses it.
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 */2 * * *}"
PBS_REPOSITORY="${PBS_REPOSITORY:?PBS_REPOSITORY environment variable is required}"

# Read PBS password from Docker secret
if [ -f /run/secrets/pbs_password ]; then
    export PBS_PASSWORD
    PBS_PASSWORD=$(cat /run/secrets/pbs_password)
else
    log "ERROR: /run/secrets/pbs_password not found"
    exit 1
fi

# Write PBS fingerprint to config (required for self-signed certs)
if [ -n "${PBS_FINGERPRINT:-}" ]; then
    mkdir -p /root/.config/proxmox-backup
    PBS_SERVER=$(echo "${PBS_REPOSITORY}" | sed 's/.*@\([^:]*\):.*/\1/')
    cat > /root/.config/proxmox-backup/config.json <<FPEOF
{
    "default-server": "${PBS_SERVER}",
    "fingerprints": {
        "${PBS_SERVER}": "${PBS_FINGERPRINT}"
    }
}
FPEOF
    log "PBS fingerprint configured for ${PBS_SERVER}"
fi

run_backup() {
    # Build pxar arguments from all /backup-* mount points
    local pxar_args=()
    for dir in /backup-*; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir" | sed 's/^backup-//')
        local file_count
        file_count=$(find "$dir" -type f 2>/dev/null | wc -l)
        log "Source ${dir} (${name}): ${file_count} files"
        if [ "${file_count}" -gt 0 ]; then
            pxar_args+=("${name}.pxar:${dir}")
        else
            log "WARNING: Skipping empty source ${dir}"
        fi
    done

    if [ ${#pxar_args[@]} -eq 0 ]; then
        log "ERROR: No backup sources found (mount volumes as /backup-<name>)"
        return 1
    fi

    log "Starting backup of ${#pxar_args[@]} source(s) to ${PBS_REPOSITORY}"
    proxmox-backup-client backup \
        "${pxar_args[@]}" \
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
    for dir in /backup-*; do
        [ -d "$dir" ] && log "Backup source: ${dir}"
    done

    # Run an initial backup on startup
    log "Running initial backup..."
    run_backup || log "Initial backup failed, will retry on schedule"

    # Write cron job — export env vars so cron subprocess inherits them
    local cron_file="/etc/cron.d/pbs-backup"
    cat > "${cron_file}" <<CRON
# PBS backup of Docker Swarm state (CephFS + RBD volumes)
PBS_REPOSITORY=${PBS_REPOSITORY}
PBS_PASSWORD=${PBS_PASSWORD}
PBS_FINGERPRINT=${PBS_FINGERPRINT:-}

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
