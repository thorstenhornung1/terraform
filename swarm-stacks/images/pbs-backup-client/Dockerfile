# =============================================================================
# PBS Backup Client for Docker Swarm CephFS State
# =============================================================================
# Backs up /mnt/cephfs/swarm-state/ to Proxmox Backup Server.
#
# Image: ghcr.io/thorstenhornung1/swarm-stacks/pbs-backup-client:latest
#
# Environment:
#   PBS_REPOSITORY    - PBS repo (e.g. backup-swarm@pbs@pbs.hornung-bn.de:swarm-datastore)
#   BACKUP_SCHEDULE   - Cron expression for scheduled backups (default: every 2h)
#
# Secrets:
#   /run/secrets/pbs_password - PBS user password or API token
#
# Volumes (mount as /backup-<name> — each becomes a separate pxar archive):
#   /backup-swarm-state:ro  - CephFS swarm-state directory
#   /backup-frigate-config:ro - Ceph RBD frigate /config (DB + model cache)
# =============================================================================

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        gnupg2 \
        ca-certificates \
        cron \
        curl \
        && \
    # Add Proxmox PBS client repository
    wget -qO /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg \
        https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg && \
    echo "deb http://download.proxmox.com/debian/pbs-client bookworm main" \
        > /etc/apt/sources.list.d/pbs-client.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends proxmox-backup-client && \
    # Clean up
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
