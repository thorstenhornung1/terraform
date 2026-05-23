# =============================================================================
# Samba File Server — Minimal Image with NT-Hash Sync
# =============================================================================
# Provides Samba file server with:
#   - Local user/group management (no SSSD, no LDAP dependency)
#   - tdbsam for NT-Hash authentication (synced from Authentik API)
#   - Cron-based periodic sync of NT-Hashes from Authentik
#
# Samba starts and serves files even when Authentik is offline.
# Only password sync requires Authentik API connectivity.
#
# Image: ghcr.io/thorstenhornung1/swarm-stacks/samba-authentik:latest
# =============================================================================

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    samba \
    samba-common-bin \
    samba-vfs-modules \
    curl \
    jq \
    cron \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
COPY sync-samba-users.sh /usr/local/bin/sync-samba-users.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/sync-samba-users.sh

EXPOSE 445

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=30s \
    CMD bash -c 'echo > /dev/tcp/127.0.0.1/445' || exit 1

ENTRYPOINT ["/entrypoint.sh"]
