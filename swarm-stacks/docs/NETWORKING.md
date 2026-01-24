# Network Architecture

## VLAN Layout

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           PHYSICAL NETWORK                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  VLAN 2 (Management)          192.168.2.0/24                            │
│  ├── Proxmox Hosts            pve01, pve02, pve03                       │
│  ├── NAS                      192.168.2.3                               │
│  └── DNS Primary              192.168.2.4                               │
│                                                                          │
│  VLAN 4 (Cluster)             192.168.4.0/24                            │
│  ├── Swarm Managers           192.168.4.30-32                           │
│  ├── Swarm Workers            192.168.4.40-50                           │
│  ├── DNS Cluster              192.168.4.5, 192.168.4.6                  │
│  └── Gateway                  192.168.4.1                               │
│                                                                          │
│  VLAN 12 (Storage)            192.168.12.0/24                           │
│  ├── Infra Nodes              192.168.12.40, 192.168.12.42              │
│  └── Replication Traffic      SeaweedFS, Patroni                        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## IP Address Allocation

### VLAN 4 - Cluster Network

| IP Range | Purpose |
|----------|---------|
| 192.168.4.1 | Gateway |
| 192.168.4.5-6 | DNS (Pi-hole cluster) |
| 192.168.4.20-29 | Reserved (Bootstrap, misc) |
| 192.168.4.30-39 | Application nodes (Swarm managers) |
| 192.168.4.40-49 | Infrastructure nodes (Swarm workers) |
| 192.168.4.50-59 | Management nodes |
| 192.168.4.100-199 | Load balancer VIPs (future) |

### Node IP Assignments

| Node | VLAN 4 IP | VLAN 12 IP | Role |
|------|-----------|------------|------|
| docker-app-1 | 192.168.4.30 | 192.168.12.30 | Manager |
| docker-app-2 | 192.168.4.31 | 192.168.12.31 | Manager |
| docker-app-3 | 192.168.4.32 | 192.168.12.32 | Manager |
| docker-infra-1 | 192.168.4.40 | 192.168.12.40 | Worker |
| docker-infra-2 | 192.168.4.41 | 192.168.12.41 | Worker |
| docker-infra-3 | 192.168.4.42 | 192.168.12.42 | Worker |
| swarmpit-mgmt | 192.168.4.50 | - | Worker |

---

## Docker Swarm Networking

### Built-in Networks

| Network | Driver | Scope | Purpose |
|---------|--------|-------|---------|
| ingress | overlay | swarm | Routing mesh for published ports |
| docker_gwbridge | bridge | local | Container-to-host communication |
| bridge | bridge | local | Default for standalone containers |

### Routing Mesh

Swarm's routing mesh allows accessing any published port from any node:

```
                    ┌─────────────────────────────────┐
                    │         ROUTING MESH            │
                    │                                 │
Client ──────────▶  │  ANY NODE:9443                 │
                    │       │                         │
                    │       ▼                         │
                    │  ┌─────────┐                   │
                    │  │ ingress │ (overlay network) │
                    │  │ network │                   │
                    │  └────┬────┘                   │
                    │       │                         │
                    │       ▼                         │
                    │  swarmpit-mgmt:9443            │
                    │  (Portainer container)         │
                    └─────────────────────────────────┘
```

**Example:**
- Portainer runs on `swarmpit-mgmt`
- Published on port 9443
- Accessible via ANY node: `192.168.4.30:9443`, `192.168.4.31:9443`, etc.

### Custom Overlay Networks

Create isolated networks for service-to-service communication:

```yaml
networks:
  frontend:
    driver: overlay
    attachable: true
  backend:
    driver: overlay
    attachable: true
    internal: true  # No external access
```

---

## Port Allocation

### Reserved System Ports

| Port | Service | Node(s) |
|------|---------|---------|
| 22 | SSH | All |
| 2377 | Swarm cluster management | Managers |
| 7946 | Swarm node communication | All |
| 4789/udp | Overlay network traffic | All |

### Application Ports

| Port | Service | Notes |
|------|---------|-------|
| 80 | HTTP (Traefik) | Planned |
| 443 | HTTPS (Traefik) | Planned |
| 8000 | Portainer Edge | All nodes |
| 9000 | Portainer HTTP | All nodes |
| 9443 | Portainer HTTPS | All nodes |
| 888 | Swarmpit | Planned |

### Port Allocation Strategy

| Range | Purpose |
|-------|---------|
| 80, 443 | Public web traffic |
| 3000-3999 | Web applications |
| 5000-5999 | APIs |
| 8000-8999 | Management UIs |
| 9000-9999 | Monitoring |

---

## DNS Configuration

### Internal DNS (Pi-hole)

| Server | IP | Priority |
|--------|-----|----------|
| Primary | 192.168.2.4 | 1 |
| Cluster 1 | 192.168.4.5 | 2 |
| Cluster 2 | 192.168.4.6 | 3 |

### Local DNS Entries

Configured in Pi-hole for internal resolution:

| Hostname | IP |
|----------|-----|
| docker-app-1.hornung-bn.de | 192.168.4.30 |
| docker-app-2.hornung-bn.de | 192.168.4.31 |
| docker-app-3.hornung-bn.de | 192.168.4.32 |
| swarmpit-mgmt.hornung-bn.de | 192.168.4.50 |
| portainer.hornung-bn.de | 192.168.4.30 |

### Docker DNS

Swarm provides automatic DNS for services:

```
<service_name>              → Load balanced across all tasks
tasks.<service_name>        → Round-robin to individual tasks
<service_name>.<network>    → Qualified name on specific network
```

---

## Firewall Rules

### Required for Swarm

```bash
# Manager nodes
ufw allow 2377/tcp  # Cluster management
ufw allow 7946/tcp  # Node communication
ufw allow 7946/udp  # Node communication
ufw allow 4789/udp  # Overlay network

# All nodes (if using encrypted overlay)
ufw allow 50/esp    # IPSec ESP
```

### Current Status

Firewall is **disabled** on all Swarm nodes (trusted VLAN).

---

## Load Balancing (Future)

### Planned: Traefik Ingress

```
                    Internet
                        │
                        ▼
              ┌─────────────────┐
              │   Traefik LB    │
              │ (Swarm Service) │
              └────────┬────────┘
                       │
         ┌─────────────┼─────────────┐
         ▼             ▼             ▼
    ┌─────────┐  ┌─────────┐  ┌─────────┐
    │  App 1  │  │  App 2  │  │  App 3  │
    └─────────┘  └─────────┘  └─────────┘
```

Features:
- Automatic service discovery
- Let's Encrypt TLS
- HTTP/2 support
- Middleware (auth, rate limiting)

---

## Troubleshooting

### Test connectivity between nodes

```bash
# From any node
docker run --rm --net host alpine ping 192.168.4.31
```

### Check overlay network

```bash
# List networks
docker network ls

# Inspect network
docker network inspect ingress

# Check connected containers
docker network inspect <network> --format '{{range .Containers}}{{.Name}} {{end}}'
```

### Debug DNS resolution

```bash
# Inside a container
docker run --rm --net <overlay_network> alpine nslookup <service_name>
```

### Check published ports

```bash
# List all listening ports
docker service ls --format '{{.Name}}: {{.Ports}}'

# Check specific service
docker service inspect <service> --format '{{.Endpoint.Ports}}'
```
