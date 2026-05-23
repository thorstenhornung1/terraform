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
# - pgvector extension for IMMICH vector search
# =============================================================================

FROM postgres:16-alpine

LABEL maintainer="infrastructure@hornung-bn.de"
LABEL description="PostgreSQL 16 with Patroni for HA clustering"

# Install build dependencies, Patroni, and pgvector
RUN apk update && apk add --no-cache \
    python3 \
    py3-pip \
    py3-psycopg2 \
    curl \
    jq \
    && pip3 install --no-cache-dir --break-system-packages \
       patroni[etcd3]==3.3.2 \
    && rm -rf /var/cache/apk/*

# Install pgvector v0.8.0 (separate layer for caching)
# OPTFLAGS=-march=x86-64-v3: pgvector's Makefile defaults to -march=native, which
# on GitHub Actions ubuntu-latest runners (Xeon w/ AVX-512) bakes AVX-512 SIMD
# instructions into vector.so. Homelab CPUs (Skylake/Kaby Lake/Coffee Lake i5)
# lack AVX-512 → SIGILL on pg_get_indexdef() against HNSW indexes. v3 baseline
# (Haswell+: AVX2+FMA+BMI2) matches what the target CPUs actually support.
# See swarm-stacks issue #9.
RUN apk add --no-cache build-base postgresql-dev git clang19 llvm19-dev \
    && cd /tmp \
    && git clone --branch v0.8.0 --depth 1 https://github.com/pgvector/pgvector.git \
    && cd pgvector \
    && make OPTFLAGS="-march=x86-64-v3" \
    && make OPTFLAGS="-march=x86-64-v3" install \
    && cd / && rm -rf /tmp/pgvector \
    && apk del build-base postgresql-dev git clang19 llvm19-dev \
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
