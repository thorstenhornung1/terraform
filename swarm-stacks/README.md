# Docker Swarm GitOps Stacks

Production-ready Docker Swarm stack definitions managed via GitOps.

## Quick Start

### Prerequisites

- SSH access to a Swarm manager node (see [Access](#access))
- Basic Docker Swarm knowledge

### Deploy a Stack

```bash
# 1. Clone this repo
git clone git@github.com:thorstenhornung1/swarm-stacks.git
cd swarm-stacks

# 2. Copy stack to manager and deploy
scp stacks/portainer/portainer-stack.yml manager:~/
ssh manager "docker stack deploy -c portainer-stack.yml portainer"
```

### Using Portainer GitOps (Recommended)

1. Open Portainer: https://192.168.4.30:9443
2. Go to **Stacks** → **Add Stack** → **Repository**
3. Enter this repo URL and stack path
4. Portainer auto-deploys on git push

---

## Access

| Service | URL | Notes |
|---------|-----|-------|
| Portainer | https://192.168.4.30:9443 | Swarm Management UI |
| SSH Manager | `ssh ansible@192.168.4.30` | Primary manager node |

### SSH Config (recommended)

Add to `~/.ssh/config`:

```
Host swarm
    HostName 192.168.4.30
    User ansible
    IdentityFile ~/.ssh/id_ed25519
```

Then use: `ssh swarm`

---

## Repository Structure

```
swarm-stacks/
├── README.md                 # This file
├── docs/
│   ├── ARCHITECTURE.md       # Cluster architecture overview
│   ├── NETWORKING.md         # Network topology & VLANs
│   └── ONBOARDING.md         # New developer guide
├── scripts/
│   └── deploy.sh             # Deployment helper script
└── stacks/
    ├── portainer/            # Swarm management UI
    │   └── portainer-stack.yml
    ├── traefik/              # Reverse proxy & TLS
    │   └── traefik-stack.yml
    ├── monitoring/           # Prometheus, Grafana, etc.
    └── apps/                 # Application stacks
```

---

## Stack Deployment

### Manual Deployment

```bash
# Deploy
docker stack deploy -c stacks/portainer/portainer-stack.yml portainer

# Check status
docker stack services portainer

# Remove
docker stack rm portainer
```

### Via Deploy Script

```bash
./scripts/deploy.sh portainer          # Deploy
./scripts/deploy.sh portainer --remove # Remove
./scripts/deploy.sh --list             # List all stacks
```

---

## Environment Details

| Component | Value |
|-----------|-------|
| Swarm Managers | 3 (docker-app-1, docker-app-2, docker-app-3) |
| Swarm Workers | 4 (docker-infra-1/2/3, swarmpit-mgmt) |
| Total Nodes | 7 |
| Docker Version | 29.1.5 |
| Network | VLAN 4 (192.168.4.0/24) |
| Management Node | swarmpit-mgmt (192.168.4.50) |

### Node Roles

| Node | Role | Purpose | IP |
|------|------|---------|-----|
| docker-app-1 | Manager | Application workloads | 192.168.4.30 |
| docker-app-2 | Manager (Leader) | Application workloads | 192.168.4.31 |
| docker-app-3 | Manager | Application workloads | 192.168.4.32 |
| docker-infra-1 | Worker | Infrastructure services | 192.168.4.40 |
| docker-infra-2 | Worker | Infrastructure services | 192.168.4.41 |
| docker-infra-3 | Worker | Infrastructure services | 192.168.4.42 |
| swarmpit-mgmt | Worker | Management UIs (Portainer) | 192.168.4.50 |

---

## Creating a New Stack

1. Create directory: `stacks/myapp/`
2. Create stack file: `myapp-stack.yml`
3. Add placement constraints if needed
4. Test locally, then commit & push
5. Deploy via Portainer GitOps or manually

### Stack Template

```yaml
version: '3.8'

services:
  app:
    image: myapp:latest
    ports:
      - "8080:8080"
    networks:
      - app_network
    deploy:
      replicas: 2
      placement:
        constraints:
          - node.role == worker
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
      update_config:
        parallelism: 1
        delay: 10s
        failure_action: rollback

networks:
  app_network:
    driver: overlay
    attachable: true
```

---

## Placement Constraints Reference

```yaml
# Run only on managers
- node.role == manager

# Run only on workers
- node.role == worker

# Pin to specific node
- node.hostname == swarmpit-mgmt

# Use node labels
- node.labels.tier == frontend
- node.labels.storage == ssd
```

### Current Node Labels

| Node | Labels |
|------|--------|
| swarmpit-mgmt | `portainer.data=true` |

---

## Troubleshooting

### Stack won't deploy

```bash
# Check service status
docker service ls
docker service ps <service_name> --no-trunc

# Check logs
docker service logs <service_name>
```

### Node not available

```bash
# Check node status
docker node ls

# Inspect node
docker node inspect <node_name>
```

### Network issues

```bash
# List networks
docker network ls

# Inspect overlay network
docker network inspect <network_name>
```

---

## Contributing

1. Create feature branch: `git checkout -b feature/my-stack`
2. Add/modify stack files
3. Test deployment manually first
4. Create PR with description
5. After merge, Portainer GitOps auto-deploys (if configured)

---

## Related Repositories

| Repo | Purpose |
|------|---------|
| [terraform](https://github.com/thorstenhornung1/terraform) | Infrastructure as Code (Proxmox VMs, LXC) |

---

## Support

- Check `docs/` for detailed documentation
- Review existing stacks for patterns
- Open an issue for questions
