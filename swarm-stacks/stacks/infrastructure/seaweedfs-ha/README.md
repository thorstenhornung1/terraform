# SeaweedFS HA Cluster

Production-grade distributed object storage with high availability.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          SeaweedFS HA Cluster                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  docker-infra-1 (192.168.12.40)                                            │
│  ├── master-1 ──────┐                                                       │
│  ├── volume-1       │ Raft                                                  │
│  └── filer-1 ───────┼──► PostgreSQL HA                                     │
│                     │                                                       │
│  docker-infra-2 (192.168.12.41)                                            │
│  ├── master-2 ──────┤                                                       │
│  ├── volume-2       │                                                       │
│  └── filer-2 ───────┼──► PostgreSQL HA                                     │
│                     │                                                       │
│  docker-infra-3 (192.168.12.42)                                            │
│  ├── master-3 ──────┘                                                       │
│  ├── volume-3                                                               │
│  └── filer-3 ───────────► PostgreSQL HA                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Components

| Component | Replicas | Purpose |
|-----------|----------|---------|
| **Masters** | 3 | Cluster coordination, volume assignment (Raft consensus) |
| **Volumes** | 3 | Data storage with 001 replication (2 copies per file) |
| **Filers** | 3 | S3 API + HTTP API, PostgreSQL metadata (active-active) |
| **db-init** | 1 | One-shot database initialization |

## Prerequisites

1. **PostgreSQL HA cluster deployed** (postgres stack)
2. **Docker Swarm secrets created:**
   - `pg_superuser_password` - PostgreSQL superuser (from postgres stack)
   - `seaweedfs_db_password` - SeaweedFS database user password
3. **Node labels set:**
   ```bash
   docker node update --label-add infra_node=1 docker-infra-1
   docker node update --label-add infra_node=2 docker-infra-2
   docker node update --label-add infra_node=3 docker-infra-3
   ```
4. **Volume directories created on each node:**
   ```bash
   sudo mkdir -p /srv/seaweedfs/volumes
   sudo chown -R 1000:1000 /srv/seaweedfs
   ```

## Deployment

### Via Portainer GitOps (Recommended)

1. Ensure secrets exist in Portainer
2. Add stack from Git repository
3. Stack will auto-deploy and db-init creates the database

### Manual Deployment

```bash
docker stack deploy -c seaweedfs-ha-stack.yml seaweedfs
```

## Access Endpoints

| Service | URL | Purpose |
|---------|-----|---------|
| **S3 API** | `http://192.168.12.40:8333` | S3-compatible object storage |
| **Filer HTTP** | `http://192.168.12.40:8888` | File browser and HTTP API |
| **Master API** | `http://192.168.12.40:9333` | Cluster management |

All three nodes provide the same endpoints - use any IP or load balance.

## S3 Configuration

### Default Credentials

SeaweedFS S3 API uses no authentication by default. To enable auth, configure `s3.json`:

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

### S3 Client Example (aws-cli)

```bash
# Configure endpoint
aws configure set default.s3.endpoint_url http://192.168.12.40:8333

# Create bucket
aws s3 mb s3://my-bucket

# Upload file
aws s3 cp myfile.txt s3://my-bucket/

# List buckets
aws s3 ls
```

## POSIX Mount (Outside Swarm)

Docker Swarm doesn't support privileged containers. For POSIX access, run the mount container directly on each host:

```bash
# Create mount point
sudo mkdir -p /mnt/seaweedfs

# Run mount container (on each node that needs POSIX access)
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

# Mount via S3 API
s3fs mybucket /mnt/seaweedfs \
  -o url=http://192.168.12.40:8333 \
  -o use_path_request_style
```

## Replication

- **Default replication:** `001` (1 copy on same rack, 1 copy on different rack)
- **Volume size limit:** 30GB per volume
- **Garbage collection threshold:** 30%

### Replication Codes

| Code | Description |
|------|-------------|
| `000` | No replication (single copy) |
| `001` | 1 copy on different rack |
| `010` | 1 copy on different data center |
| `100` | 1 copy on different server (same rack) |
| `110` | 1 copy on different rack + 1 on different DC |

## Monitoring

### Health Checks

```bash
# Master cluster status
curl http://192.168.12.40:9333/cluster/status

# Volume server status
curl http://192.168.12.40:8080/status

# Filer status
curl http://192.168.12.40:8888/
```

### Prometheus Metrics

| Component | Metrics Port |
|-----------|--------------|
| Masters | 9324 |
| Volumes | 9325 |
| Filers | 9326 |

## Troubleshooting

### Check Service Status

```bash
docker service ls | grep seaweedfs
docker service logs seaweedfs_master-1
docker service logs seaweedfs_filer-1
```

### Database Connection Issues

```bash
# Check db-init logs
docker service logs seaweedfs_db-init

# Verify database exists
docker exec -it postgres_patroni-1 psql -U postgres -c "\l" | grep seaweedfs
```

### Volume Server Not Joining

```bash
# Check master logs for volume registration
docker service logs seaweedfs_master-1 2>&1 | grep -i volume

# Verify volume directory permissions
ls -la /srv/seaweedfs/volumes/
```

### Filer Metadata Issues

```bash
# Check filer connection to PostgreSQL
docker service logs seaweedfs_filer-1 2>&1 | grep -i postgres

# Verify filemeta table (auto-created by filer)
docker exec -it postgres_patroni-1 psql -U seaweedfs -d seaweedfs -c "\dt"
```

## Backup & Recovery

### Metadata Backup (PostgreSQL)

The filer metadata is stored in PostgreSQL. Use the postgres stack's backup mechanisms.

### Volume Data Backup

```bash
# Export all data via filer
weed filer.backup -filer=192.168.12.40:8888 -target=/backup/path

# Or use S3 sync
aws s3 sync s3://bucket /backup/path --endpoint-url http://192.168.12.40:8333
```

## Files

| File | Purpose |
|------|---------|
| `seaweedfs-ha-stack.yml` | Main Docker Swarm stack |
| `filer.toml` | Filer configuration (PostgreSQL connection) |
| `db-init.sh` | Database initialization script |

## References

- [SeaweedFS Documentation](https://github.com/seaweedfs/seaweedfs/wiki)
- [SeaweedFS S3 API](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)
- [Filer Store PostgreSQL](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Stores#postgresql)
