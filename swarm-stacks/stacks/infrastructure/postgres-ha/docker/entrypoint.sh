#!/bin/bash
# =============================================================================
# Patroni PostgreSQL Entrypoint Script
# =============================================================================
# Generates patroni.yml from environment variables and starts Patroni
# =============================================================================

set -e

# =============================================================================
# Read secrets from files (Docker secrets pattern)
# =============================================================================
if [ -n "$PATRONI_SUPERUSER_PASSWORD_FILE" ] && [ -f "$PATRONI_SUPERUSER_PASSWORD_FILE" ]; then
    export PATRONI_SUPERUSER_PASSWORD=$(cat "$PATRONI_SUPERUSER_PASSWORD_FILE")
fi

if [ -n "$PATRONI_REPLICATION_PASSWORD_FILE" ] && [ -f "$PATRONI_REPLICATION_PASSWORD_FILE" ]; then
    export PATRONI_REPLICATION_PASSWORD=$(cat "$PATRONI_REPLICATION_PASSWORD_FILE")
fi

if [ -n "$PATRONI_ADMIN_PASSWORD_FILE" ] && [ -f "$PATRONI_ADMIN_PASSWORD_FILE" ]; then
    export PATRONI_ADMIN_PASSWORD=$(cat "$PATRONI_ADMIN_PASSWORD_FILE")
fi

# Generate Patroni configuration from environment variables
cat > /etc/patroni/patroni.yml << EOF
scope: ${PATRONI_SCOPE:-postgres-cluster}
name: ${PATRONI_NAME:-$(hostname)}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${PATRONI_RESTAPI_CONNECT_ADDRESS:-$(hostname):8008}

etcd3:
  hosts: ${PATRONI_ETCD3_HOSTS:-etcd-1:2379,etcd-2:2379,etcd-3:2379}

bootstrap:
  dcs:
    ttl: ${PATRONI_TTL:-30}
    loop_wait: ${PATRONI_LOOP_WAIT:-10}
    retry_timeout: ${PATRONI_RETRY_TIMEOUT:-10}
    maximum_lag_on_failover: ${PATRONI_MAXIMUM_LAG_ON_FAILOVER:-1048576}
    synchronous_mode: ${PATRONI_SYNCHRONOUS_MODE:-true}
    synchronous_mode_strict: ${PATRONI_SYNCHRONOUS_MODE_STRICT:-false}
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_connections: ${PATRONI_MAX_CONNECTIONS:-200}
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: ${PATRONI_WAL_KEEP_SIZE:-1GB}
        hot_standby_feedback: "on"
        archive_mode: "on"
        archive_command: 'cp %p /var/lib/postgresql/wal_archive/%f && find /var/lib/postgresql/wal_archive/ -type f -mtime +7 -delete'
        shared_buffers: ${PATRONI_SHARED_BUFFERS:-256MB}
        effective_cache_size: ${PATRONI_EFFECTIVE_CACHE_SIZE:-1GB}
        work_mem: ${PATRONI_WORK_MEM:-16MB}
        maintenance_work_mem: ${PATRONI_MAINTENANCE_WORK_MEM:-128MB}
        synchronous_commit: ${PATRONI_SYNCHRONOUS_COMMIT:-on}
        tcp_keepalives_idle: 30
        tcp_keepalives_interval: 10
        tcp_keepalives_count: 5
        statement_timeout: 3600000
        idle_in_transaction_session_timeout: 3600000

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    # Patroni requires localhost access for health checks and management
    - local all all peer
    - host all all 127.0.0.1/32 scram-sha-256
    - host replication replicator 127.0.0.1/32 scram-sha-256
    # Replication: infra nodes on VLAN 12 only
    - host replication replicator 192.168.12.40/32 scram-sha-256
    - host replication replicator 192.168.12.41/32 scram-sha-256
    - host replication replicator 192.168.12.42/32 scram-sha-256
    # App connections via HAProxy (overlay network)
    - host all all 10.0.20.0/24 scram-sha-256
    # Direct from infra nodes (pg_rewind, monitoring, db-init)
    - host all all 192.168.12.0/24 scram-sha-256

  users:
    admin:
      password: ${PATRONI_ADMIN_PASSWORD}
      options:
        - createrole
        - createdb
    replicator:
      password: ${PATRONI_REPLICATION_PASSWORD}
      options:
        - replication

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${PATRONI_POSTGRESQL_CONNECT_ADDRESS:-$(hostname):5432}
  data_dir: ${PATRONI_POSTGRESQL_DATA_DIR:-/var/lib/postgresql/data}
  bin_dir: /usr/local/bin
  authentication:
    superuser:
      username: postgres
      password: ${PATRONI_SUPERUSER_PASSWORD}
    replication:
      username: replicator
      password: ${PATRONI_REPLICATION_PASSWORD}

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

# Ensure data directory permissions
mkdir -p "${PATRONI_POSTGRESQL_DATA_DIR:-/var/lib/postgresql/data}"
chmod 700 "${PATRONI_POSTGRESQL_DATA_DIR:-/var/lib/postgresql/data}"

# Start Patroni
exec "$@"
