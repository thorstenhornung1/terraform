# SeaweedFS HA Cluster

Production-grade distributed object storage deployed on Docker Swarm with full high availability across three infrastructure nodes on VLAN 12.

---

## Table of Contents

- [Architecture](#architecture)
- [Components](#components)
- [Design Decisions](#design-decisions)
- [Files](#files)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
- [Access Endpoints](#access-endpoints)
- [S3 Usage](#s3-usage)
- [POSIX Mount](#posix-mount-outside-swarm)
- [Replication](#replication)
- [Prometheus Metrics](#prometheus-metrics)
- [Health Checks](#health-checks)
- [Backup and Recovery](#backup-and-recovery)
- [Configuration Changes](#configuration-changes)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Architecture

```
+-----------------------------------------------------------------------------+
|                          SeaweedFS HA Cluster (VLAN 12)                      |
+-----------------------------------------------------------------------------+
|                                                                             |
|  docker-infra-1 (192.168.12.40)                                            |
|  +-- master-1 -----+                                                       |
|  +-- volume-1       | Raft Consensus                                       |
|  +-- filer-1 -------+--> pg-haproxy:5433 --> PostgreSQL HA (Patroni)       |
|                     |                                                       |
|  docker-infra-2 (192.168.12.41)                                            |
|  +-- master-2 ------+                                                       |
|  +-- volume-2       |                                                       |
|  +-- filer-2 -------+--> pg-haproxy:5433 --> PostgreSQL HA (Patroni)       |
|                     |                                                       |
|  docker-infra-3 (192.168.12.42)                                            |
|  +-- master-3 ------+                                                       |
|  +-- volume-3                                                               |
|  +-- filer-3 ----------> pg-haproxy:5433 --> PostgreSQL HA (Patroni)       |
|                                                                             |
|  db-init (one-shot) --> pg-haproxy:5433 --> Creates user + database         |
|                                                                             |
+-----------------------------------------------------------------------------+
```

All components are pinned to specific infrastructure nodes via Docker Swarm placement constraints using the `infra_node` label.

| Node | IP Address | Services |
|------|------------|----------|
| docker-infra-1 | 192.168.12.40 | master-1, volume-1, filer-1 |
| docker-infra-2 | 192.168.12.41 | master-2, volume-2, filer-2 |
| docker-infra-3 | 192.168.12.42 | master-3, volume-3, filer-3 |

---

## Components

| Component | Replicas | Purpose | Fault Tolerance |
|-----------|----------|---------|-----------------|
| Masters | 3 | Cluster coordination, volume assignment (Raft consensus) | Tolerates 1 failure (requires 2/3 quorum) |
| Volumes | 3 | Data storage with `001` replication (2 copies per file) | Tolerates 1 failure without data loss |
| Filers | 3 | S3 API, HTTP API, PostgreSQL metadata (active-active) | Tolerates 2 failures (any filer can serve requests) |
| db-init | 1 | One-shot database initialization | Runs once, then exits |

### Resource Allocations

| Component | CPU Limit | Memory Limit | CPU Reserved | Memory Reserved |
|-----------|-----------|--------------|--------------|-----------------|
| Master | 1 core | 1 GB | 0.25 core | 256 MB |
| Volume | 2 cores | 2 GB | 0.5 core | 512 MB |
| Filer | 2 cores | 2 GB | 0.5 core | 512 MB |
| db-init | 0.5 core | 256 MB | -- | -- |

---

## Design Decisions

### 1. PostgreSQL Metadata via HAProxy

Filers connect to PostgreSQL through HAProxy (`pg-haproxy:5433`) on the `postgres-ha-stack` overlay network. HAProxy routes traffic to the current Patroni primary automatically via REST API health checks. This approach eliminates hardcoded IPs and handles primary failovers transparently.

### 2. Password Injection via Entrypoint Wrapper

SeaweedFS `filer.toml` does not support `passwordFile` directives. To avoid embedding plaintext passwords in configuration, the filer containers use a custom entrypoint that:

1. Reads the database password from the Docker secret at `/run/secrets/seaweedfs_db_password`.
2. Uses `sed` to inject the password into a runtime copy of `filer.toml`.
3. The config file is mounted read-only at `/docker-config/filer.toml` (template). The runtime copy is written to `/etc/seaweedfs/filer.toml`.

### 3. Cross-Stack Networking

The SeaweedFS stack references `postgres-ha-stack_postgres-network` as an external overlay network. This allows filers and the db-init service to resolve `pg-haproxy` via Docker DNS without exposing PostgreSQL ports externally.

### 4. Docker Swarm Config Versioning

Docker Swarm configs are immutable. When `filer.toml` or `db-init.sh` changes, the config name must be bumped (for example, `filer_config_v3` to `filer_config_v4`) to force Swarm to recreate the config object. See [Configuration Changes](#configuration-changes) for the full procedure.

**Current versions:**
- `filer_config_v3` -- filer.toml
- `db_init_script_v2` -- db-init.sh

### 5. postgres2 SQL Templates

SeaweedFS's `postgres2` metadata store requires explicit `createTable` and `upsertQuery` SQL templates in `filer.toml` with `%s` placeholders for the table name. Without these templates, the internal `fmt.Sprintf("", tableName)` call produces invalid SQL and the filer crashes on startup.

---

## Files

| File | Purpose |
|------|---------|
| `seaweedfs-ha-stack.yml` | Docker Swarm stack definition (all services, networks, volumes, configs, secrets) |
| `filer.toml` | Filer configuration template (password placeholder injected at runtime) |
| `db-init.sh` | Idempotent database initialization script (creates user and database via HAProxy) |
| `README.md` | This documentation |

---

## Prerequisites

Before deploying the SeaweedFS stack, ensure the following are in place.

### 1. PostgreSQL HA Cluster

The `postgres-ha-stack` must be deployed and healthy. SeaweedFS depends on the PostgreSQL overlay network and HAProxy service.

```bash
docker service ls | grep postgres-ha-stack
docker network ls | grep postgres-ha-stack_postgres-network
```

### 2. Docker Swarm Secrets

Create the following secrets in Portainer (or via CLI):

| Secret Name | Description |
|-------------|-------------|
| `pg_superuser_password` | PostgreSQL superuser password (shared with postgres-ha-stack) |
| `seaweedfs_db_password` | Password for the `seaweedfs` database user |

```bash
# CLI alternative (if not using Portainer)
echo "superuser-password" | docker secret create pg_superuser_password -
echo "seaweedfs-password" | docker secret create seaweedfs_db_password -
```

### 3. Node Labels

Each infrastructure node must have the `infra_node` label set:

```bash
docker node update --label-add infra_node=1 docker-infra-1
docker node update --label-add infra_node=2 docker-infra-2
docker node update --label-add infra_node=3 docker-infra-3
```

### 4. Volume Directories

Create the volume data directory on each infrastructure node:

```bash
sudo mkdir -p /srv/seaweedfs/volumes
sudo chown -R 1000:1000 /srv/seaweedfs
```

---

## Deployment

### Via Portainer GitOps (Recommended)

The stack is deployed via Portainer GitOps from the following repository:

- **Repository:** `https://github.com/thorstenhornung1/swarm-stacks.git`
- **Branch:** `main`
- **Stack name in Portainer:** `seaweedfs`
- **Poll interval:** 5 minutes

Portainer automatically detects changes pushed to the repository and redeploys the stack.

**Steps:**

1. Ensure all secrets exist in Portainer.
2. Add or update the stack from the Git repository.
3. The `db-init` service runs automatically on first deploy, creates the database user and database, then exits.

### Manual Deployment

```bash
docker stack deploy -c seaweedfs-ha-stack.yml seaweedfs
```

### Verify Deployment

```bash
# Check all services are running
docker service ls | grep seaweedfs

# Expected output: 9 services running (3 masters, 3 volumes, 3 filers)
# The db-init service shows 0/1 replicas after successful completion (one-shot)

# Check db-init completed successfully
docker service logs seaweedfs_db-init

# Check master cluster status
curl -s http://192.168.12.40:9333/cluster/status | python3 -m json.tool
```

---

## Access Endpoints

All three nodes expose identical endpoints. Replace `.40` with `.41` or `.42` to access other nodes.

| Interface | URL | Purpose |
|-----------|-----|---------|
| Master UI | `http://192.168.12.40:9333` | Cluster overview, topology, volume assignment |
| Filer UI | `http://192.168.12.40:8888` | File browser, directory listing |
| S3 API | `http://192.168.12.40:8333` | S3-compatible object storage |
| HAProxy Stats | `http://192.168.12.40:7000` | PostgreSQL routing health dashboard |

### Port Reference

| Port | Protocol | Component | Purpose |
|------|----------|-----------|---------|
| 9333 | TCP | Master | HTTP API and Web UI |
| 19333 | TCP | Master | gRPC |
| 8080 | TCP | Volume | HTTP API |
| 18080 | TCP | Volume | gRPC |
| 8888 | TCP | Filer | HTTP API and Web UI |
| 18888 | TCP | Filer | gRPC |
| 8333 | TCP | Filer | S3 API |

---

## S3 Usage

The S3 API has no authentication enabled by default. Any client with network access can read and write data.

### aws-cli Examples

```bash
# Create a bucket
aws s3 mb s3://my-bucket --endpoint-url http://192.168.12.40:8333

# Upload a file
aws s3 cp file.txt s3://my-bucket/ --endpoint-url http://192.168.12.40:8333

# List all buckets
aws s3 ls --endpoint-url http://192.168.12.40:8333

# List bucket contents
aws s3 ls s3://my-bucket/ --endpoint-url http://192.168.12.40:8333

# Download a file
aws s3 cp s3://my-bucket/file.txt ./downloaded.txt --endpoint-url http://192.168.12.40:8333
```

### Enabling S3 Authentication

To enable authentication, create an `s3.json` configuration and mount it into the filer containers:

```json
{
  "identities": [
    {
      "name": "admin",
      "credentials": [
        {
          "accessKey": "your-access-key",
          "secretKey": "your-secret-key"
        }
      ],
      "actions": ["Admin", "Read", "Write"]
    }
  ]
}
```

---

## POSIX Mount (Outside Swarm)

Docker Swarm does not support privileged containers, so FUSE-based mounts must run outside the Swarm stack. Run the mount container directly on any host that needs POSIX filesystem access:

```bash
# Create the mount point
sudo mkdir -p /mnt/seaweedfs

# Run the mount container
docker run -d \
  --name seaweedfs-mount \
  --restart unless-stopped \
  --privileged \
  --device /dev/fuse \
  -v /mnt/seaweedfs:/mnt/seaweedfs:shared \
  chrislusf/seaweedfs:3.79 mount \
  -filer=192.168.12.40:8888,192.168.12.41:8888,192.168.12.42:8888 \
  -dir=/mnt/seaweedfs \
  -filer.path=/ \
  -allowOthers=true \
  -cacheDir=/tmp/seaweedfs-cache \
  -cacheCapacityMB=1024
```

### Alternative: s3fs-fuse

```bash
# Install s3fs
apt-get install s3fs

# Mount a bucket via the S3 API
s3fs mybucket /mnt/seaweedfs \
  -o url=http://192.168.12.40:8333 \
  -o use_path_request_style
```

---

## Replication

| Setting | Value |
|---------|-------|
| Default replication | `001` (1 additional copy on a different rack) |
| Volume size limit | 30 GB |
| Garbage collection threshold | 30% |
| Volume preallocate | Disabled |
| Compaction speed | 50 MB/s |
| Minimum free space | 5 GB per volume server |

### Replication Codes

SeaweedFS uses a 3-digit replication code representing copies across data centers, racks, and servers:

| Code | Description |
|------|-------------|
| `000` | No replication (single copy) |
| `001` | 1 additional copy on a different rack |
| `010` | 1 additional copy in a different data center |
| `100` | 1 additional copy on a different server (same rack) |
| `110` | 1 copy on a different rack + 1 in a different data center |

The current topology assigns each volume server to a separate rack (`rack1`, `rack2`, `rack3`) within `dc1`, so the `001` replication code ensures every file exists on two different physical nodes.

---

## Prometheus Metrics

All components expose Prometheus-compatible metrics endpoints.

| Component | Metrics Port | Example Scrape Target |
|-----------|--------------|----------------------|
| Masters | 9324 | `192.168.12.40:9324/metrics` |
| Volumes | 9325 | `192.168.12.40:9325/metrics` |
| Filers | 9326 | `192.168.12.40:9326/metrics` |

---

## Health Checks

All services include built-in Docker health checks with the following parameters:

| Parameter | Value |
|-----------|-------|
| Interval | 15 seconds |
| Timeout | 10 seconds |
| Retries | 3 |
| Start period | 20-30 seconds |

### Manual Health Verification

```bash
# Master cluster status
curl -s http://192.168.12.40:9333/cluster/status

# Volume server status
curl -s http://192.168.12.40:8080/status

# Filer status
curl -s http://192.168.12.40:8888/

# Docker service status
docker service ls | grep seaweedfs
```

---

## Backup and Recovery

### Metadata Backup (PostgreSQL)

Filer metadata is stored in the PostgreSQL HA cluster. It is backed up automatically by the `postgres-ha-stack` backup mechanisms. No additional metadata backup configuration is required for SeaweedFS.

### Volume Data Backup

```bash
# Export all data via the filer backup command
weed filer.backup -filer=192.168.12.40:8888 -target=/backup/path

# Alternative: sync via S3 API
aws s3 sync s3://bucket /backup/path --endpoint-url http://192.168.12.40:8333
```

### Master Raft State

Master Raft state is stored in Docker-managed named volumes (`master-data-1`, `master-data-2`, `master-data-3`). These are automatically recreated when the cluster forms, but retaining them avoids unnecessary re-election delays on restart.

---

## Configuration Changes

Docker Swarm configs are immutable. Any change to `filer.toml` or `db-init.sh` requires a version bump.

### Updating filer.toml

1. Edit `filer.toml` with the desired changes.
2. Bump the config version in `seaweedfs-ha-stack.yml`:
   - In the `configs:` section at the bottom of the file: rename `filer_config_v3` to `filer_config_v4`.
   - In every filer service's `configs:` block: update `source: filer_config_v3` to `source: filer_config_v4`.
3. Commit and push to the `swarm-stacks` Git repository.
4. Redeploy in Portainer, or wait for the GitOps poll (5 minutes).

### Updating db-init.sh

Follow the same procedure, bumping `db_init_script_v2` to `db_init_script_v3` (or the next version).

### Important Notes

- Forgetting to bump the version results in Swarm error: `only updates to Labels are allowed`.
- Both the `configs:` definition and all `source:` references must use the new version name.
- The db-init service has `restart_policy: condition: none`, so it will not re-run automatically. To re-run it after a config change, remove and redeploy the stack, or scale the service manually.

---

## Troubleshooting

### Check Service Status

```bash
# List all SeaweedFS services
docker service ls | grep seaweedfs

# View logs for a specific service
docker service logs seaweedfs_master-1
docker service logs seaweedfs_filer-1
docker service logs seaweedfs_volume-1
docker service logs seaweedfs_db-init
```

### Common Issues

#### 1. Filers crash with "password authentication failed"

**Cause:** The `seaweedfs_db_password` Docker secret does not match the password stored in PostgreSQL.

**Resolution:**
- Verify the Docker secret value matches what PostgreSQL expects.
- On the Patroni primary, update the password if needed:
  ```sql
  ALTER USER seaweedfs WITH PASSWORD 'correct-password';
  ```
- Redeploy the filer services after correcting the secret.

#### 2. Filers crash with `pq: syntax error at or near "%!"`

**Cause:** Missing `createTable` and `upsertQuery` SQL templates in `filer.toml`. The `postgres2` store requires these templates with `%s` placeholders for the table name. Without them, `fmt.Sprintf("", tableName)` produces invalid SQL.

**Resolution:**
Ensure `filer.toml` includes both templates under the `[postgres2]` section:
```toml
createTable = """
  CREATE TABLE IF NOT EXISTS "%s" (
    dirhash   BIGINT,
    name      VARCHAR(65535),
    directory VARCHAR(65535),
    meta      bytea,
    PRIMARY KEY (dirhash, name)
  )
"""

upsertQuery = """
  INSERT INTO "%s" (dirhash, name, directory, meta)
  VALUES ($1, $2, $3, $4)
  ON CONFLICT (dirhash, name)
  DO UPDATE SET directory = EXCLUDED.directory, meta = EXCLUDED.meta
"""
```

#### 3. Config update fails with "only updates to Labels are allowed"

**Cause:** Docker Swarm configs are immutable and cannot be updated in place.

**Resolution:**
Bump the config name version (for example, `filer_config_v3` to `filer_config_v4`) in both the `configs:` section and all `source:` references in the stack YAML. See [Configuration Changes](#configuration-changes).

#### 4. db-init fails with "read-only transaction"

**Cause:** The db-init service connected to a PostgreSQL replica instead of the primary.

**Resolution:**
- The db-init service must connect through HAProxy (`pg-haproxy:5433`), which routes to the Patroni primary automatically.
- Never connect directly to a node IP, as it may be a read-only replica.
- Verify the postgres-network is attached: check that `postgres-ha-stack_postgres-network` appears in the service's network list.

#### 5. Filers cannot resolve pg-haproxy

**Cause:** The external overlay network from the PostgreSQL stack does not exist or is not properly referenced.

**Resolution:**
1. Verify the network exists:
   ```bash
   docker network ls | grep postgres-ha-stack_postgres-network
   ```
2. If the network does not exist, the `postgres-ha-stack` must be deployed first.
3. Ensure the `seaweedfs-ha-stack.yml` references it correctly:
   ```yaml
   postgres-network:
     external: true
     name: postgres-ha-stack_postgres-network
   ```

#### 6. Volume servers not joining the cluster

```bash
# Check master logs for volume registration
docker service logs seaweedfs_master-1 2>&1 | grep -i volume

# Verify volume directory exists and has correct permissions
ls -la /srv/seaweedfs/volumes/
```

#### 7. Verify Database and Table Existence

```bash
# Check that the seaweedfs database exists
docker exec -it $(docker ps -q -f name=patroni-1) \
  psql -U postgres -c "\l" | grep seaweedfs

# Check that the filemeta table was auto-created by the filer
docker exec -it $(docker ps -q -f name=patroni-1) \
  psql -U seaweedfs -d seaweedfs -c "\dt"
```

---

## References

- [SeaweedFS Documentation](https://github.com/seaweedfs/seaweedfs/wiki)
- [SeaweedFS S3 API](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)
- [Filer Store PostgreSQL](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Stores#postgresql)
- [SeaweedFS Replication](https://github.com/seaweedfs/seaweedfs/wiki/Replication)
- [Docker Swarm Configs](https://docs.docker.com/engine/swarm/configs/)
