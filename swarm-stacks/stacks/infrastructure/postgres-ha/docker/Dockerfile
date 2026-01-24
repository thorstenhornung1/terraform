# =============================================================================
# Patroni PostgreSQL 16 Docker Image
# =============================================================================
# Custom image with Patroni for HA PostgreSQL clustering
# Based on official PostgreSQL 16 Alpine image
#
# Features:
# - Patroni 3.3.x for HA orchestration
# - etcd3 DCS support
# - pg_rewind for fast replica recovery
# - Synchronous replication support
# =============================================================================

FROM postgres:16-alpine

LABEL maintainer="infrastructure@hornung-bn.de"
LABEL description="PostgreSQL 16 with Patroni for HA clustering"

# Install build dependencies and Patroni
RUN apk update && apk add --no-cache \
    python3 \
    py3-pip \
    py3-psycopg2 \
    curl \
    jq \
    && pip3 install --no-cache-dir --break-system-packages \
       patroni[etcd3]==3.3.2 \
    && rm -rf /var/cache/apk/*

# Create Patroni configuration directory
RUN mkdir -p /etc/patroni /var/lib/postgresql/wal_archive \
    && chown -R postgres:postgres /etc/patroni /var/lib/postgresql

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

# Patroni REST API port
EXPOSE 8008
# PostgreSQL port
EXPOSE 5432

USER postgres

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["patroni", "/etc/patroni/patroni.yml"]
