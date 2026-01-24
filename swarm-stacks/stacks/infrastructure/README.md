# PostgreSQL HA + SeaweedFS Infrastructure Stack

Production-grade high-availability infrastructure for Docker Swarm with:
- **PostgreSQL HA Cluster**: 3 nodes with Patroni + etcd (RPO=0, RTO~30s)
- **SeaweedFS HA Cluster**: 3 masters, 3 volumes, 3 filers (active-active), 3 FUSE mounts

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Docker Swarm Cluster                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐             │
│  │ docker-infra-1  │  │ docker-infra-2  │  │ docker-infra-3  │             │
│  │ 192.168.12.40   │  │ 192.168.12.41   │  │ 192.168.12.42   │             │
│  ├─────────────────┤  ├─────────────────┤  ├─────────────────┤             │
│  │ etcd-1          │  │ etcd-2          │  │ etcd-3          │             │
│  │ postgres-1      │  │ postgres-2      │  │ postgres-3      │             │
│  │ master-1        │  │ master-2        │  │ master-3        │             │
│  │ volume-1        │  │ volume-1        │  │ volume-1        │             │
│  │ filer-1         │  │ filer-2         │  │ filer-3         │             │
│  │ mount-1         │  │ mount-2         │  │ mount-3         │             │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘             │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────┐          │
│  │                    Shared Components                          │          │
│  │  • PgBouncer (connection pooling) - port 6432                │          │
│  │  • postgres_exporter (Prometheus metrics) - port 9187        │          │
│  └──────────────────────────────────────────────────────────────┘          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key HA Features

| Component | HA Mechanism | Failover Time |
|-----------|--------------|---------------|
| PostgreSQL | Patroni + etcd Raft | ~30 seconds |
| SeaweedFS Masters | Raft consensus | ~10 seconds |
| SeaweedFS Filers | Active-active (PostgreSQL metadata) | Instant |
| SeaweedFS Volumes | Replication 001 (2 copies) | Instant |

### Network Layout

| VLAN | Purpose | Subnet |
|------|---------|--------|
| VLAN 4 | Cluster/Application access | 192.168.4.0/24 |
| VLAN 12 | Storage/Replication traffic | 192.168.12.0/24 |

### Port Assignments

| Service | Port | Protocol | Access |
|---------|------|----------|--------|
| etcd client | 2379 | TCP | VLAN 12 only |
| etcd peer | 2380 | TCP | VLAN 12 only |
| PostgreSQL | 5432 | TCP | VLAN 12 only |
| Patroni API | 8008 | TCP | VLAN 12 only |
| PgBouncer | 6432 | TCP | VLAN 4 (apps) |
| postgres_exporter | 9187 | TCP | Prometheus |
| SeaweedFS Master | 9333 | TCP | VLAN 12 only |
| SeaweedFS Volume | 8080 | TCP | VLAN 12 only |
| SeaweedFS Filer | 8888 | TCP | VLAN 4 (apps) |
| SeaweedFS S3 | 8333 | TCP | VLAN 4 (apps) |

---

## Prerequisites

### 1. Docker Swarm Cluster

- Docker Swarm initialized with manager nodes
- Infrastructure nodes joined as workers
- Overlay network encryption enabled

### 2. Terraform Infrastructure

The `docker-swarm.tf` in the parent terraform directory provisions:
- 3 infrastructure VMs with dual VLAN networking
- Data disks (scsi1) attached to each node
- Correct static IPs configured

### 3. Required Secrets in Portainer

Create these secrets in Portainer **before** deploying the stacks:

| Secret Name | Description | Used By |
|-------------|-------------|---------|
| `pg_superuser_password` | PostgreSQL postgres user password | Patroni, PgBouncer, postgres_exporter |
| `pg_replication_password` | Replication user password | Patroni |
| `pg_admin_password` | Admin user password | Patroni |
| `seaweedfs_db_password` | SeaweedFS filer DB user password | Filer containers |

**Creating secrets via CLI:**
```bash
# On a swarm manager node
echo "your-secure-password" | docker secret create pg_superuser_password -
echo "your-replication-pass" | docker secret create pg_replication_password -
echo "your-admin-pass" | docker secret create pg_admin_password -
echo "your-seaweedfs-pass" | docker secret create seaweedfs_db_password -
```

---

## Deployment Guide

### Phase 1: Prepare Infrastructure Nodes (Ansible)

```bash
cd swarm-stacks/ansible

# Verify connectivity
ansible -i inventory.ini all -m ping

# Prepare nodes (install packages, mount disks, set labels)
ansible-playbook -i inventory.ini prepare-infra-nodes.yml
```

This playbook:
- Installs required packages (fuse3, xfsprogs, lvm2)
- Partitions and mounts data disks to `/srv/data`
- Creates SeaweedFS and PostgreSQL directories
- Sets Docker Swarm node labels for placement constraints

### Phase 2: Deploy PostgreSQL HA Cluster

```bash
cd swarm-stacks/stacks/infrastructure/postgres-ha

# Build Patroni image (on a manager node with Docker)
docker build -t patroni-postgres:16 ./docker/

# Push to registry if using one
# docker tag patroni-postgres:16 registry.example.com/patroni-postgres:16
# docker push registry.example.com/patroni-postgres:16

# Deploy the stack
docker stack deploy -c postgres-ha-stack.yml postgres
```

**Wait for cluster initialization (~2-3 minutes):**
```bash
# Watch service status
docker service ls | grep postgres

# Check Patroni cluster status
docker exec $(docker ps -qf "name=postgres_postgres-1" | head -1) patronictl list
```

Expected output:
```
+ Cluster: postgres-cluster -----+---------+---------+----+-----------+
| Member     | Host          | Role    | State   | TL | Lag in MB |
+------------+---------------+---------+---------+----+-----------+
| postgres-1 | 192.168.12.40 | Leader  | running |  1 |           |
| postgres-2 | 192.168.12.41 | Replica | running |  1 |         0 |
| postgres-3 | 192.168.12.42 | Replica | running |  1 |         0 |
+------------+---------------+---------+---------+----+-----------+
```

### Phase 3: Create SeaweedFS Database

```bash
cd swarm-stacks/stacks/infrastructure/seaweedfs-ha

# Make script executable
chmod +x create-seaweedfs-db.sh

# Run database setup (will prompt for passwords)
./create-seaweedfs-db.sh 192.168.12.40
```

This script:
- Creates the `seaweedfs` user and database
- Creates the `filemeta` table for filer metadata
- Grants necessary permissions

### Phase 4: Deploy SeaweedFS HA Cluster

```bash
cd swarm-stacks/stacks/infrastructure/seaweedfs-ha

# Create filer config
docker config create filer_config filer.toml

# Deploy the stack
docker stack deploy -c seaweedfs-ha-stack.yml seaweedfs
```

**Verify deployment:**
```bash
# Check all services running
docker service ls | grep seaweedfs

# Check master cluster status
curl -s http://192.168.12.40:9333/cluster/status | jq .

# Check volume servers
curl -s http://192.168.12.40:9333/dir/status | jq .WritableVolumeCount

# Check filer health
curl -s http://192.168.12.40:8888/
curl -s http://192.168.12.41:8888/
curl -s http://192.168.12.42:8888/
```

---

## Verification Checklist

### PostgreSQL HA

```bash
# etcd cluster health
docker exec $(docker ps -qf "name=postgres_etcd-1" | head -1) etcdctl endpoint health

# Patroni cluster status
docker exec $(docker ps -qf "name=postgres_postgres-1" | head -1) patronictl list

# Test database connection via PgBouncer
psql -h 192.168.4.30 -p 6432 -U postgres -c "SELECT pg_is_in_recovery();"

# Check replication lag
docker exec $(docker ps -qf "name=postgres_postgres-1" | head -1) \
  psql -U postgres -c "SELECT client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;"
```

### SeaweedFS HA

```bash
# Master cluster status (should show leader + 2 peers)
curl -s http://192.168.12.40:9333/cluster/status | jq .

# Volume server count (should show 3)
curl -s http://192.168.12.40:9333/dir/status | jq '.Topology.DataCenters[].Racks[].DataNodes | length'

# Filer health check
for ip in 192.168.12.40 192.168.12.41 192.168.12.42; do
  echo "Filer $ip: $(curl -s -o /dev/null -w '%{http_code}' http://$ip:8888/)"
done

# S3 API test (requires aws cli)
aws s3 --endpoint-url http://192.168.12.40:8333 ls

# Test file upload via filer
curl -F "file=@/etc/hostname" http://192.168.12.40:8888/test/
curl http://192.168.12.40:8888/test/hostname

# FUSE mount test (on infra nodes)
ls -la /mnt/seaweedfs/
```

---

## Failover Testing

### PostgreSQL Failover

```bash
# Identify current leader
docker exec $(docker ps -qf "name=postgres_postgres-1" | head -1) patronictl list

# Trigger manual failover
docker exec $(docker ps -qf "name=postgres_postgres-1" | head -1) \
  patronictl switchover --leader postgres-1 --candidate postgres-2 --force

# Verify new leader
docker exec $(docker ps -qf "name=postgres_postgres-1" | head -1) patronictl list
```

### SeaweedFS Master Failover

```bash
# Check current master leader
curl -s http://192.168.12.40:9333/cluster/status | jq .Leader

# Stop leader container (Swarm will restart it)
docker service scale seaweedfs_master-1=0

# Check new leader elected
curl -s http://192.168.12.41:9333/cluster/status | jq .Leader

# Restore original master
docker service scale seaweedfs_master-1=1
```

### SeaweedFS Filer Failover

```bash
# All 3 filers are active-active, test by stopping one
docker service scale seaweedfs_filer-1=0

# Verify other filers still serve requests
curl http://192.168.12.41:8888/
curl http://192.168.12.42:8888/

# Restore filer
docker service scale seaweedfs_filer-1=1
```

---

## Monitoring

### Prometheus Metrics Endpoints

| Service | Endpoint | Metrics |
|---------|----------|---------|
| postgres_exporter | `http://<manager>:9187/metrics` | PostgreSQL stats |
| SeaweedFS Master | `http://<node>:9333/metrics` | Master metrics |
| SeaweedFS Volume | `http://<node>:8080/metrics` | Volume metrics |
| SeaweedFS Filer | `http://<node>:8888/metrics` | Filer metrics |

### Key Metrics to Monitor

**PostgreSQL:**
- `pg_up` - Database availability
- `pg_stat_replication_pg_wal_lsn_diff` - Replication lag
- `pg_settings_max_connections` - Connection limits

**SeaweedFS:**
- `seaweedfs_master_volumes_total` - Total volumes
- `seaweedfs_filer_request_total` - Filer requests
- `seaweedfs_volume_disk_usage_bytes` - Disk usage

---

## Troubleshooting

### PostgreSQL Issues

**Cluster stuck in "starting":**
```bash
# Check etcd health first
docker exec $(docker ps -qf "name=postgres_etcd-1" | head -1) etcdctl endpoint health

# Check Patroni logs
docker service logs postgres_postgres-1 --tail 100
```

**Replication lag increasing:**
```bash
# Check network between nodes
ping -c 3 192.168.12.41

# Check PostgreSQL logs
docker exec $(docker ps -qf "name=postgres_postgres-1" | head -1) \
  tail -100 /var/lib/postgresql/data/log/postgresql-*.log
```

### SeaweedFS Issues

**Masters not forming cluster:**
```bash
# Check master logs
docker service logs seaweedfs_master-1 --tail 100

# Verify network connectivity on VLAN 12
docker exec $(docker ps -qf "name=seaweedfs_master-1" | head -1) \
  wget -q -O- http://192.168.12.41:9333/cluster/status
```

**Filer not connecting to PostgreSQL:**
```bash
# Check filer logs
docker service logs seaweedfs_filer-1 --tail 100

# Verify PostgreSQL is accessible
docker exec $(docker ps -qf "name=seaweedfs_filer-1" | head -1) \
  nc -zv 192.168.12.40 5432

# Verify seaweedfs database exists
psql -h 192.168.12.40 -U seaweedfs -d seaweedfs -c "SELECT count(*) FROM filemeta;"
```

**FUSE mount not working:**
```bash
# Check mount service logs
docker service logs seaweedfs_weed-mount-1 --tail 100

# Verify FUSE module loaded on host
lsmod | grep fuse

# Check mount point permissions
ls -la /mnt/seaweedfs/
```

---

## File Structure

```
swarm-stacks/
├── stacks/
│   └── infrastructure/
│       ├── README.md                    # This file
│       ├── postgres-ha/
│       │   ├── postgres-ha-stack.yml    # PostgreSQL + etcd + PgBouncer stack
│       │   ├── create-secrets.sh        # Docker secrets creation script
│       │   └── docker/
│       │       ├── Dockerfile           # Patroni PostgreSQL image
│       │       └── entrypoint.sh        # Patroni configuration generator
│       └── seaweedfs-ha/
│           ├── seaweedfs-ha-stack.yml   # SeaweedFS full stack
│           ├── filer.toml               # Filer PostgreSQL configuration
│           └── create-seaweedfs-db.sh   # Database setup script
└── ansible/
    ├── inventory.ini                    # Node inventory
    └── prepare-infra-nodes.yml          # Node preparation playbook
```

---

## Portainer GitOps Integration

After pushing to GitHub, configure Portainer GitOps:

1. Navigate to **Stacks → Add Stack → Repository**
2. Enter repository URL: `https://github.com/your-org/swarm-stacks`
3. Configure stack files:
   - `stacks/infrastructure/postgres-ha/postgres-ha-stack.yml`
   - `stacks/infrastructure/seaweedfs-ha/seaweedfs-ha-stack.yml`
4. Enable **Auto-update** for GitOps continuous deployment
5. Set update interval (e.g., 5 minutes)

**Important:** Ensure all secrets are created in Portainer before stack deployment.

---

## Backup & Recovery

### PostgreSQL Backup

The Patroni cluster supports point-in-time recovery. Configure WAL archiving:

```bash
# Manual backup
docker exec $(docker ps -qf "name=postgres_postgres-1" | head -1) \
  pg_basebackup -D /backup -Ft -z -Xs -P -U replicator
```

### SeaweedFS Backup

SeaweedFS data is replicated across volume servers. For additional backup:

```bash
# Export filer metadata
curl "http://192.168.12.40:8888/?pretty=y" > filer-metadata.json

# Volume data is on /srv/data/seaweedfs on each node
```

---

## Security Considerations

1. **Network Isolation**: Storage traffic (VLAN 12) is isolated from application traffic (VLAN 4)
2. **Encrypted Overlay**: Docker Swarm overlay network encryption enabled
3. **Secrets Management**: All passwords stored as Docker secrets, not in stack files
4. **Minimal Exposure**: Internal services (etcd, PostgreSQL) only accessible on VLAN 12
5. **Non-root Containers**: Services run as non-root where possible

---

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review service logs: `docker service logs <service_name>`
3. Verify network connectivity between nodes
4. Check Prometheus metrics for anomalies
