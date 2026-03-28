# =============================================================================
# Samba + Authentik LDAP — Custom Docker Image
# =============================================================================
# Provides Samba file server with LDAP user provisioning from Authentik.
# Standard Samba images lack ldap-utils needed for Authentik LDAP queries.
#
# Image: ghcr.io/thorstenhornung1/swarm-stacks/samba-authentik:latest
# =============================================================================

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    samba \
    samba-common-bin \
    ldap-utils \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 445

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=30s \
    CMD smbclient -L localhost -N || exit 1

ENTRYPOINT ["/entrypoint.sh"]
