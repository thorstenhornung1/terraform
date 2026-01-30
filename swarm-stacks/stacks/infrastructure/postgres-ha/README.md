# PostgreSQL HA Cluster (Patroni + etcd)

Production-grade PostgreSQL 16 high-availability cluster running on Docker Swarm with automatic failover, synchronous replication, and transparent connection routing.

**Key guarantees:**
- **RPO = 0** -- Zero data loss via synchronous replication
- **RTO ~ 30s** -- Automatic failover with HAProxy session teardown
- **Quorum-based** -- etcd 3-node consensus prevents split-brain

---

## Table of Contents

- [Architecture](#architecture)
- [Components](#components)
- [Files](#files)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
- [Access Endpoints](#access-endpoints)
- [Connecting from Other Stacks](#connecting-from-other-stacks)
- [Creating New Databases](#creating-new-databases)
- [PostgreSQL Tuning](#postgresql-tuning)
- [Patroni Settings](#patroni-settings)
- [Failover Behavior](#failover-behavior)
- [Monitoring](#monitoring)
- [Resource Allocation](#resource-allocation)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Architecture

A 3-node PostgreSQL 16 cluster with automatic failover using Patroni for HA orchestration and etcd for distributed consensus. HAProxy provides transparent connection routing to the current primary and replicas.

```
                        Clients / Other Swarm Stacks
                                  |
                          +-------+-------+
                          |   HAProxy x2  |
                          | (Swarm ingress)|
                          +---+-------+---+
                              |       |
                     RW :5433 |       | RO :5434
                              |       |
          +-------------------+-------+-------------------+
          |                   |                           |
  +-------+--------+  +------+---------+  +---------+--------+
  | docker-infra-1 |  | docker-infra-2 |  | docker-infra-3   |
  | 192.168.12.40  |  | 192.168.12.41  |  | 192.168.12.42    |
  |                |  |                |  |                  |
  | etcd-1         |  | etcd-2         |  | etcd-3           |
  | postgres-1     |  | postgres-2     |  | postgres-3       |
  | (Patroni)      |  | (Patroni)      |  | (Patroni)        |
  +----------------+  +----------------+  +------------------+
```

All nodes run on **VLAN 12** (192.168.12.0/24), the dedicated storage and replication network. The overlay network `postgres-ha-stack_postgres-network` (encrypted, subnet 10.0.20.0/24) connects all services and is shared with other stacks.

---

## Components

| Component | Replicas | Image | Purpose |
|---|---|---|---|
| etcd-1, etcd-2, etcd-3 | 1 each (pinned per node) | `quay.io/coreos/etcd:v3.5.15` | Distributed consensus for Patroni leader election |
| postgres-1, postgres-2, postgres-3 | 1 each (pinned per node) | `patroni-postgres:16` (custom) | PostgreSQL 16 with Patroni HA orchestration |
| haproxy | 2 (manager nodes) | `haproxy:2.9-alpine` | Automatic primary/replica routing via Patroni REST API |
| db-init | 1 (one-shot) | `postgres:16-alpine` | Creates application databases and users idempotently |
| pgbouncer | 0 (disabled) | `edoburu/pgbouncer:1.23.1` | Connection pooling (optional, enable by setting replicas > 0) |
| postgres-exporter | 1 (manager node) | `prometheuscommunity/postgres-exporter:v0.15.0` | Prometheus metrics exporter |

### Design Decisions

1. **Patroni orchestration.** Each PostgreSQL node runs Patroni, which manages replication topology, automatic failover, and replica recovery. Patroni uses etcd3 as its Distributed Configuration Store (DCS) for leader election.

2. **Synchronous replication (RPO=0).** With `synchronous_mode: true`, at least one replica must confirm every write before it is acknowledged to the client. The setting `synchronous_mode_strict: false` allows a fallback to asynchronous replication if all replicas become unavailable, preventing a complete write outage.

3. **HAProxy for transparent routing.** HAProxy performs HTTP health checks against the Patroni REST API (`/primary` and `/replica` on port 8008) to detect the current cluster topology. Port 5433 always routes to the primary (read-write), and port 5434 load-balances across replicas (read-only). The `on-marked-down shutdown-sessions` directive ensures clients are immediately disconnected on failover so they reconnect to the new primary.

4. **Custom Docker image.** The `patroni-postgres:16` image is built from `postgres:16-alpine` with Patroni 3.3.2, py3-psycopg2, curl, jq, and etcd3 client support. The entrypoint script generates `patroni.yml` from environment variables at container start.

5. **Docker secrets for credentials.** Passwords are stored as Docker Swarm secrets and mounted at `/run/secrets/`. The entrypoint reads `PATRONI_SUPERUSER_PASSWORD_FILE`, `PATRONI_REPLICATION_PASSWORD_FILE`, and `PATRONI_ADMIN_PASSWORD_FILE` -- passwords never appear in environment variables or container inspect output.

6. **WAL archiving.** WAL files are archived to `/var/lib/postgresql/wal_archive` on each node for point-in-time recovery. `pg_rewind` is enabled for fast replica resynchronization after failover without requiring a full re-clone.

7. **Cross-stack networking.** The overlay network is attachable, encrypted, and uses subnet 10.0.20.0/24. Other Swarm stacks (such as SeaweedFS) can join via Docker's external network mechanism. HAProxy is reachable at the DNS alias `pg-haproxy` within this network.

---

## Files

| File | Purpose |
|---|---|
| `postgres-ha-stack.yml` | Docker Swarm stack definition (all services, networks, volumes, secrets) |
| `haproxy.cfg` | HAProxy configuration -- primary routing on 5433, replica routing on 5434, stats on 7000 |
| `db-init.sh` | Central database initialization -- creates application users and databases idempotently |
| `create-secrets.sh` | Script to create Docker secrets (run once on a Swarm manager before first deploy) |
| `docker/Dockerfile` | Custom image definition: PostgreSQL 16 Alpine + Patroni 3.3.2 + etcd3 support |
| `docker/entrypoint.sh` | Generates `patroni.yml` from environment variables, reads passwords from secret files |

---

## Prerequisites

Before deploying the stack, ensure the following requirements are met.

### 1. Docker Swarm Cluster

A Docker Swarm cluster must be initialized with at least three nodes.

### 2. Node Labels

Each infrastructure node must be labeled so services are pinned to the correct host:

```bash
docker node update --label-add infra_node=1 docker-infra-1
docker node update --label-add infra_node=2 docker-infra-2
docker node update --label-add infra_node=3 docker-infra-3
```

### 3. Custom Patroni Image

Build the custom image on all infrastructure nodes (or push to a shared registry):

```bash
docker build -t patroni-postgres:16 ./docker/
```

### 4. Docker Secrets

Create the required secrets using the provided script:

```bash
# Auto-generate secure random passwords
./create-secrets.sh --generate

# Or enter passwords interactively
./create-secrets.sh
```

Alternatively, create secrets through Portainer.

**Required secrets:**

| Secret Name | Description |
|---|---|
| `pg_superuser_password` | PostgreSQL superuser (`postgres`) password |
| `pg_replication_password` | Replication user (`replicator`) password |
| `pg_admin_password` | Admin user with `CREATEDB` and `CREATEROLE` privileges |
| `ha_recorder_db_password` | Home Assistant recorder database user password (used by db-init) |

---

## Deployment

### Via Portainer GitOps (recommended)

The stack is deployed through Portainer GitOps from:

- **Repository:** `https://github.com/thorstenhornung1/swarm-stacks.git`
- **Branch:** `main`
- **Stack name:** `postgres-ha-stack`
- **Compose file path:** `stacks/infrastructure/postgres-ha/postgres-ha-stack.yml`

### Via CLI

```bash
docker stack deploy -c postgres-ha-stack.yml postgres-ha-stack
```

### Verify Deployment

```bash
# Check all services are running
docker stack services postgres-ha-stack

# Expected output: all services with desired replicas matching current replicas
# etcd-1/2/3: 1/1, postgres-1/2/3: 1/1, haproxy: 2/2, postgres-exporter: 1/1
```

---

## Access Endpoints

| Interface | Port | Protocol | Purpose |
|---|---|---|---|
| HAProxy Primary (RW) | 5433 | TCP (ingress) | Routed to current Patroni leader |
| HAProxy Replicas (RO) | 5434 | TCP (ingress) | Load-balanced across standby nodes |
| HAProxy Stats | 7000 | HTTP (ingress) | Health dashboard at `http://<any-node>:7000` |
| PostgreSQL Direct | 5432 | TCP (host mode) | Direct node access (not recommended for applications) |
| Patroni REST API | 8008 | HTTP (host mode) | Health checks: `/primary`, `/replica`, `/health`, `/cluster` |
| PgBouncer | 6432 | TCP (ingress) | Connection pooling (disabled by default, replicas: 0) |
| Prometheus Metrics | 9187 | HTTP (ingress) | postgres-exporter scrape endpoint |

---

## Connecting from Other Stacks

Other Docker Swarm stacks can connect to PostgreSQL through HAProxy by joining the shared overlay network.

### Step 1: Declare the External Network

Add the following to your stack YAML:

```yaml
networks:
  postgres-network:
    external: true
    name: postgres-ha-stack_postgres-network
```

### Step 2: Attach Services

Reference the network in your service definition:

```yaml
services:
  my-app:
    image: my-app:latest
    networks:
      - postgres-network
    environment:
      DATABASE_URL: postgres://myuser:mypassword@pg-haproxy:5433/mydb
```

### Connection Strings

| Use Case | Host | Port | Notes |
|---|---|---|---|
| Read-write (primary) | `pg-haproxy` | 5433 | Always reaches the current leader |
| Read-only (replicas) | `pg-haproxy` | 5434 | Load-balanced across standbys |

---

## Creating New Databases

Application databases are managed automatically by the **db-init** one-shot service. On every stack deploy, `db-init` connects to the primary via HAProxy and idempotently creates all configured users and databases.

### Managed Databases

| User | Database | Secret |
|---|---|---|
| `homeassistant` | `homeassistant` | `ha_recorder_db_password` |

### Adding a New Application Database

1. Create a Docker secret for the app password (via Portainer or CLI):
   ```bash
   echo "secure-password" | docker secret create myapp_db_password -
   ```

2. Edit `db-init.sh` -- add a block at the end:
   ```sh
   MYAPP_PASS=$(cat /run/secrets/myapp_db_password)
   init_app "myapp" "$MYAPP_PASS" "myapp"
   ```

3. Edit `postgres-ha-stack.yml` -- add the new secret to the `db-init` service:
   ```yaml
   secrets:
     - pg_superuser_password
     - ha_recorder_db_password
     - myapp_db_password      # <-- add
   ```

   And register it in the top-level `secrets:` section:
   ```yaml
   secrets:
     myapp_db_password:
       external: true
   ```

4. Redeploy the stack. The `db-init` service will create the user and database, then exit (0/1 replicas).

### Manual Database Creation

For ad-hoc databases not managed by db-init, connect to the primary via HAProxy:

```bash
psql -h pg-haproxy -p 5433 -U postgres
```

```sql
CREATE USER myapp WITH PASSWORD 'secure-password';
CREATE DATABASE myapp OWNER myapp;
GRANT ALL PRIVILEGES ON DATABASE myapp TO myapp;
```

All DDL changes made on the primary are automatically replicated to standby nodes.

---

## PostgreSQL Tuning

The following parameters are configured via Patroni environment variables and applied at cluster bootstrap.

| Parameter | Value | Description |
|---|---|---|
| `shared_buffers` | 512MB | Shared memory for caching data pages |
| `effective_cache_size` | 1536MB | Planner estimate of OS cache available |
| `work_mem` | 16MB | Memory per sort/hash operation |
| `maintenance_work_mem` | 128MB | Memory for VACUUM, CREATE INDEX |
| `max_connections` | 200 | Maximum concurrent connections |
| `wal_keep_size` | 2GB | Minimum WAL retained for streaming replication |
| `synchronous_commit` | on | Writes wait for sync replica confirmation |
| `wal_level` | replica | WAL detail level for replication |
| `hot_standby` | on | Allow read queries on standbys |
| `archive_mode` | on | Enable WAL archiving for PITR |
| `max_wal_senders` | 10 | Maximum replication connections |
| `max_replication_slots` | 10 | Maximum replication slots |

---

## Patroni Settings

| Setting | Value | Description |
|---|---|---|
| `ttl` | 30s | Leader lease time-to-live in etcd |
| `loop_wait` | 10s | Patroni main loop interval |
| `retry_timeout` | 10s | Timeout for DCS and PostgreSQL operations |
| `maximum_lag_on_failover` | 1048576 (1MB) | Maximum replication lag (bytes) to allow failover promotion |
| `synchronous_mode` | true | At least one replica must confirm writes synchronously |
| `synchronous_mode_strict` | false | Allow fallback to async if no sync replicas are available |
| `use_pg_rewind` | true | Enable pg_rewind for fast replica recovery |
| `use_slots` | true | Use replication slots to prevent WAL removal |

---

## Failover Behavior

When the primary node fails or becomes unreachable:

1. **Detection (~10-15s).** Patroni on each node continuously checks etcd. When the leader key expires (TTL = 30s, loop_wait = 10s), replicas detect the vacancy.

2. **Election.** The replica with the least replication lag (under `maximum_lag_on_failover` = 1MB) is promoted to primary by Patroni via etcd consensus.

3. **Promotion.** The elected replica is promoted to read-write mode. Patroni updates the leader key in etcd.

4. **HAProxy rerouting.** HAProxy health checks detect the new primary within 3 seconds (check interval). The `on-marked-down shutdown-sessions` directive immediately terminates existing client connections to the old primary.

5. **Client reconnection.** Clients reconnect through HAProxy and are transparently routed to the new primary.

6. **Old primary recovery.** When the former primary comes back online, Patroni uses `pg_rewind` to resynchronize it as a replica without requiring a full base backup.

### Summary

| Metric | Value |
|---|---|
| Recovery Time Objective (RTO) | ~30 seconds |
| Recovery Point Objective (RPO) | 0 (synchronous replication) |
| Split-brain prevention | etcd quorum (2 of 3 nodes required) |
| Replica resync method | pg_rewind (fast, no full re-clone) |

---

## Monitoring

### HAProxy Stats Dashboard

Available at `http://<any-swarm-node>:7000`. Shows real-time backend health for both the primary and replica listeners, including connection counts, response times, and server states (UP/DOWN).

### Patroni REST API

Query any PostgreSQL node directly to inspect the cluster state:

```bash
# Full cluster state (all members, roles, lag)
curl -s http://192.168.12.40:8008/cluster | jq .

# Check if a node is the primary (returns 200 on leader, 503 otherwise)
curl -s -o /dev/null -w "%{http_code}" http://192.168.12.40:8008/primary

# Check if a node is a replica (returns 200 on standby, 503 otherwise)
curl -s -o /dev/null -w "%{http_code}" http://192.168.12.40:8008/replica

# General health check (returns 200 if PostgreSQL is running)
curl -s http://192.168.12.40:8008/health | jq .
```

### Prometheus Metrics

The postgres-exporter service exposes PostgreSQL metrics at:

```
http://<any-swarm-node>:9187/metrics
```

Configure your Prometheus instance to scrape this endpoint. Auto-discovery is enabled for all databases (excluding `template0` and `template1`).

### Replication Status via SQL

Connect to the primary and query replication state:

```sql
-- View connected replicas and their lag
SELECT
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    sync_state
FROM pg_stat_replication;

-- Check synchronous standby names
SHOW synchronous_standby_names;
```

---

## Resource Allocation

| Component | CPU Limit | Memory Limit | CPU Reserve | Memory Reserve |
|---|---|---|---|---|
| etcd (per node) | 0.5 | 512M | 0.1 | 128M |
| postgres (per node) | 2.0 | 2G | 0.5 | 512M |
| haproxy (per replica) | 0.5 | 256M | 0.1 | 64M |
| db-init (one-shot) | 0.5 | 256M | 0.1 | 64M |
| pgbouncer (disabled) | 0.5 | 256M | 0.1 | 64M |
| postgres-exporter | 0.25 | 128M | 0.05 | 32M |

**Total per infrastructure node:** 2.5 CPU / 2.5 GB memory (limits), 0.6 CPU / 640 MB memory (reservations).

---

## Troubleshooting

### All postgres services show 0/1 after deploy or redeploy

**Cause:** A ghost overlay network from a previous failed deployment may conflict with the new stack.

**Fix:**

```bash
# Check for existing postgres networks
docker network ls | grep postgres

# If a conflicting network exists, remove the stack first
docker stack rm postgres-ha-stack

# Wait for all containers to stop, then redeploy
docker stack deploy -c postgres-ha-stack.yml postgres-ha-stack
```

### HAProxy shows all backends as DOWN

**Cause:** Patroni is not running or cannot reach etcd.

**Diagnosis:**

```bash
# Check Patroni health on each node
curl http://192.168.12.40:8008/health
curl http://192.168.12.41:8008/health
curl http://192.168.12.42:8008/health

# Check etcd cluster health
etcdctl endpoint health --endpoints=http://192.168.12.40:2379,http://192.168.12.41:2379,http://192.168.12.42:2379

# Check Patroni logs
docker service logs postgres-ha-stack_postgres-1 --tail 50
```

### Replication lag increasing

**Cause:** Network issues, slow disk I/O, or long-running transactions on the primary.

**Diagnosis:**

```bash
# Check lag via Patroni API
curl -s http://192.168.12.40:8008/cluster | jq '.members[] | {name, role, lag}'

# Check via SQL on the primary
psql -h pg-haproxy -p 5433 -U postgres -c \
  "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;"
```

### HAProxy config changes not taking effect

**Cause:** Docker Swarm configs are immutable. You cannot update a config in-place.

**Fix:** Create a new config version and update the stack definition:

1. Rename the config reference in `postgres-ha-stack.yml`:
   ```yaml
   configs:
     haproxy_config:
       file: ./haproxy.cfg
       name: haproxy_config_v2  # Increment version
   ```
2. Redeploy the stack.

### etcd cluster loses quorum

**Cause:** Two or more etcd nodes are down simultaneously.

**Impact:** Patroni cannot perform leader election. The existing primary continues serving but no failover is possible.

**Fix:**

```bash
# Check which etcd nodes are healthy
etcdctl endpoint health --endpoints=http://192.168.12.40:2379,http://192.168.12.41:2379,http://192.168.12.42:2379

# Restart failed etcd services
docker service update --force postgres-ha-stack_etcd-1
```

### Secrets need to be rotated

**Cause:** Periodic credential rotation or compromise.

**Process:** Docker Swarm secrets are immutable. To rotate:

1. Create new secrets with updated names (e.g., `pg_superuser_password_v2`).
2. Update `postgres-ha-stack.yml` to reference the new secret names.
3. Redeploy the stack. Patroni will pick up the new passwords from `/run/secrets/`.
4. Remove the old secrets: `docker secret rm pg_superuser_password`.

---

## References

- [Patroni Documentation](https://patroni.readthedocs.io/)
- [etcd Documentation](https://etcd.io/docs/)
- [HAProxy Documentation](https://www.haproxy.org/)
- [PostgreSQL 16 Documentation](https://www.postgresql.org/docs/16/)
- [Docker Swarm Secrets](https://docs.docker.com/engine/swarm/secrets/)
- [postgres-exporter](https://github.com/prometheus-community/postgres_exporter)
