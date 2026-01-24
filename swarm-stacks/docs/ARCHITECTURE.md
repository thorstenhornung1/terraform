# Cluster Architecture

## Overview

This Docker Swarm cluster runs on a 3-node Proxmox virtualization cluster with dedicated VMs for different workload types.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         PROXMOX CLUSTER                                  │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐                │
│  │     pve01     │  │     pve02     │  │     pve03     │                │
│  │   (Primary)   │  │  (Secondary)  │  │  (Secondary)  │                │
│  └───────┬───────┘  └───────┬───────┘  └───────┬───────┘                │
└──────────┼──────────────────┼──────────────────┼────────────────────────┘
           │                  │                  │
           ▼                  ▼                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      DOCKER SWARM (7 Nodes)                              │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                      MANAGER NODES (Raft)                        │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │    │
│  │  │docker-app-1 │  │docker-app-2 │  │docker-app-3 │              │    │
│  │  │ Reachable   │  │   Leader    │  │ Reachable   │              │    │
│  │  │192.168.4.30 │  │192.168.4.31 │  │192.168.4.32 │              │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘              │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                       WORKER NODES (4)                           │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │    │
│  │  │docker-infra-1│  │docker-infra-2│  │docker-infra-3│           │    │
│  │  │ 192.168.4.40 │  │ 192.168.4.41 │  │ 192.168.4.42 │           │    │
│  │  │    pve01     │  │    pve02     │  │    pve03     │           │    │
│  │  └──────────────┘  └──────────────┘  └──────────────┘           │    │
│  │                                                                  │    │
│  │                    ┌──────────────┐                              │    │
│  │                    │swarmpit-mgmt │                              │    │
│  │                    │ 192.168.4.50 │                              │    │
│  │                    │  Management  │                              │    │
│  │                    └──────────────┘                              │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Node Types

### Manager Nodes (3x)

Application workload nodes that also participate in Swarm consensus.

| Node | IP | Proxmox Host | Resources |
|------|-----|--------------|-----------|
| docker-app-1 | 192.168.4.30 | pve01 | 4 CPU, 8GB RAM, 50GB |
| docker-app-2 | 192.168.4.31 | pve02 | 4 CPU, 8GB RAM, 50GB |
| docker-app-3 | 192.168.4.32 | pve03 | 4 CPU, 8GB RAM, 50GB |

**Purpose:**
- Run application containers (web apps, APIs)
- Maintain Swarm consensus (Raft)
- Handle `docker stack deploy` commands

### Infrastructure Workers (3x)

Dedicated nodes for infrastructure services.

| Node | IP | Proxmox Host | Resources | Storage |
|------|-----|--------------|-----------|---------|
| docker-infra-1 | 192.168.4.40 | pve01 | 4 CPU, 8GB RAM, 30GB + 50GB | ZFS (tank) |
| docker-infra-2 | 192.168.4.41 | pve02 | 4 CPU, 8GB RAM, 30GB + 100GB | local-lvm |
| docker-infra-3 | 192.168.4.42 | pve03 | 4 CPU, 8GB RAM, 30GB + 200GB | ZFS (tank) |

**Purpose:**
- Storage services (SeaweedFS planned)
- Database services (PostgreSQL/Patroni planned)
- Heavy I/O workloads

**Note:** docker-infra-2 uses local-lvm instead of ZFS tank due to storage constraints on pve02.

### Management Worker (1x)

Dedicated node for management UIs with persistent data.

| Node | IP | Proxmox Host | Resources |
|------|-----|--------------|-----------|
| swarmpit-mgmt | 192.168.4.50 | pve01 | 4 CPU, 6GB RAM, 30GB |

**Purpose:**
- Portainer CE (pinned here)
- Swarmpit (optional)
- Management dashboards
- Persistent data (BoltDB, CouchDB)

**Labels:**
- `portainer.data=true`

---

## Network Architecture

### VLAN Layout

| VLAN | Subnet | Purpose |
|------|--------|---------|
| VLAN 4 | 192.168.4.0/24 | Cluster network (management, apps) |
| VLAN 12 | 192.168.12.0/24 | Storage network (replication) |

### Docker Networks

| Network | Type | Purpose |
|---------|------|---------|
| ingress | overlay | Swarm routing mesh (automatic) |
| docker_gwbridge | bridge | Container-to-host communication |
| portainer_agent_network | overlay | Portainer agent communication |

### Port Exposure

Swarm uses **routing mesh** - services exposed on any node are accessible via any node's IP.

```
Client → 192.168.4.30:9443 → Routing Mesh → swarmpit-mgmt:9443 (Portainer)
Client → 192.168.4.31:9443 → Routing Mesh → swarmpit-mgmt:9443 (Portainer)
```

---

## High Availability

### Swarm Manager HA

- 3 managers = tolerates 1 failure
- Raft consensus ensures consistency
- Leader election automatic

```
Managers: 3
Quorum: 2 (majority)
Fault tolerance: 1 node failure
```

### Service HA

- Services with `replicas > 1` spread across nodes
- Failed containers auto-restart
- Failed nodes trigger rescheduling

### Data Persistence

| Service | Strategy | Location |
|---------|----------|----------|
| Portainer | Pinned to swarmpit-mgmt | Local volume |
| Databases | Pinned + Backup | NFS/S3 backup |
| Stateless apps | Any node | No persistence |

---

## Placement Strategy

### Use Cases

```yaml
# Stateless apps - spread across managers
deploy:
  replicas: 3
  placement:
    constraints:
      - node.role == manager

# Infrastructure services - workers only
deploy:
  placement:
    constraints:
      - node.role == worker

# Persistent services - pin to specific node
deploy:
  placement:
    constraints:
      - node.hostname == swarmpit-mgmt

# Using labels for flexibility
deploy:
  placement:
    constraints:
      - node.labels.storage == ssd
```

---

## Resource Allocation

### Total Cluster Resources

| Resource | Total | Manager Nodes | Worker Nodes |
|----------|-------|---------------|--------------|
| CPU Cores | 28 | 12 (3x4) | 16 (4x4) |
| RAM | 54 GB | 24 GB (3x8) | 30 GB (3x8 + 6) |
| Boot Storage | 240 GB | 150 GB | 90 GB |
| Data Storage | 350 GB | - | 350 GB (infra nodes) |

### Recommended Limits

```yaml
# Small service
resources:
  limits:
    cpus: '0.25'
    memory: 256M

# Medium service
resources:
  limits:
    cpus: '0.5'
    memory: 512M

# Large service
resources:
  limits:
    cpus: '1.0'
    memory: 1G
```

---

## External Dependencies

| Service | URL | Purpose |
|---------|-----|---------|
| Proxmox API | https://pve01:8006 | VM management |
| DNS (Pi-hole) | 192.168.2.4, 192.168.4.5/6 | Name resolution |
| NFS Storage | 192.168.2.3 | Persistent volumes |
| APT Cache | apt-cacher.hornung-bn.de:3142 | Package caching |

---

## Security Considerations

### Network Security

- All nodes on dedicated VLAN (4)
- Storage traffic isolated on VLAN 12
- No direct internet exposure
- Reverse proxy (Traefik) for external access

### Access Control

- SSH key-only authentication
- Portainer with authentication
- Docker socket protected (root only)

### Secrets Management

- Docker Swarm secrets for sensitive data
- External secrets via Infisical (planned)
- No secrets in stack files

---

## Disaster Recovery

### Swarm Recovery

```bash
# If 1 manager fails - automatic recovery
# If 2 managers fail - force new cluster
docker swarm init --force-new-cluster
```

### Data Recovery

| Data | Backup Location | Recovery |
|------|-----------------|----------|
| Portainer | swarmpit-mgmt:/var/lib/docker/volumes | Restore volume |
| Stack definitions | This Git repo | Re-deploy |
| Application data | NFS/S3 | Restore from backup |

---

## Monitoring (Planned)

```
┌────────────┐     ┌────────────┐     ┌────────────┐
│ Prometheus │ ──▶ │  Grafana   │ ──▶ │   Alerts   │
└────────────┘     └────────────┘     └────────────┘
      │
      ▼
┌────────────┐
│  Node      │
│  Exporter  │ (on each node)
└────────────┘
```
