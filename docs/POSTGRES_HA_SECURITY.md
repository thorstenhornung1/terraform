# PostgreSQL HA Security Hardening

Security configuration for the PostgreSQL HA cluster, covering network access control at the PostgreSQL, Docker Swarm, and Proxmox firewall layers.

**Date:** 2026-01-30
**Status:** Active, all layers deployed

---

## Architecture Overview

```
Home Assistant (192.168.2.5, VLAN 2)
  → router → VLAN 4
  → any app node (192.168.4.30-32):5433  [Swarm ingress mesh]
  → HAProxy → overlay network (10.0.20.0/24)
  → Patroni leader on VLAN 12

Swarm services
  → overlay network (10.0.20.0/24)
  → pg-haproxy:5433
  → Patroni leader on VLAN 12
```

PostgreSQL sees overlay IPs (10.0.20.x) for all connections routed through HAProxy, not the original client IP. This is why `pg_hba.conf` does not need a rule for Home Assistant's IP directly.

---

## Layer 1: pg_hba.conf (PostgreSQL Authentication)

**File:** `docker/entrypoint.sh` (generates `patroni.yml` at container start)
**Live config:** Applied to DCS via Patroni REST API (auto-propagated to all nodes)

### Rules

| Type | Database | User | Source CIDR | Auth Method | Purpose |
|------|----------|------|-------------|-------------|---------|
| local | all | all | — | peer | Patroni health checks and management |
| host | all | all | 127.0.0.1/32 | scram-sha-256 | Patroni localhost connections |
| host | replication | replicator | 192.168.12.40/32 | scram-sha-256 | Replication from infra-1 |
| host | replication | replicator | 192.168.12.41/32 | scram-sha-256 | Replication from infra-2 |
| host | replication | replicator | 192.168.12.42/32 | scram-sha-256 | Replication from infra-3 |
| host | all | all | 10.0.20.0/24 | scram-sha-256 | App connections via HAProxy overlay |
| host | all | all | 192.168.12.0/24 | scram-sha-256 | Direct infra access (pg_rewind, monitoring, db-init) |

### What changed

- **Before:** `0.0.0.0/0` — any IP could authenticate
- **After:** Only localhost (for Patroni), VLAN 12 infra nodes, and the Docker overlay network
- **2026-02-02 fix:** Added `local` and `127.0.0.1/32` rules — Patroni requires localhost access for health checks, leader election, and pg_rewind. Without these rules, no node can become leader and the entire cluster stays dead.

### Applying changes to a running cluster

```bash
# Patch via Patroni REST API (apply to any node, auto-propagates)
curl -s -XPATCH http://192.168.12.41:8008/config -d '{
  "postgresql": {
    "pg_hba": [
      "local all all peer",
      "host all all 127.0.0.1/32 scram-sha-256",
      "host replication replicator 192.168.12.40/32 scram-sha-256",
      "host replication replicator 192.168.12.41/32 scram-sha-256",
      "host replication replicator 192.168.12.42/32 scram-sha-256",
      "host all all 10.0.20.0/24 scram-sha-256",
      "host all all 192.168.12.0/24 scram-sha-256"
    ]
  }
}'

# Verify
curl -s http://192.168.12.40:8008/config | jq '.postgresql.pg_hba'
```

---

## Layer 2: HAProxy Hardening

**File:** `postgres-ha-stack.yml`

### Changes

| Change | Before | After |
|--------|--------|-------|
| Stats port 7000 | Published on all Swarm nodes via ingress | Removed from published ports |
| Admin password | `${PATRONI_ADMIN_PASSWORD:-admin}` (defaults to "admin") | `${PATRONI_ADMIN_PASSWORD}` (fails if unset) |

### Accessing HAProxy stats without published port

```bash
# Via docker exec on a manager node
docker exec $(docker ps -q -f name=haproxy) sh -c 'wget -qO- http://127.0.0.1:7000/'
```

---

## Layer 3: Proxmox VM Firewall

**Primary security layer.** Proxmox firewall rules are enforced at the hypervisor level, outside the VM. Even if the VM is compromised, the firewall rules cannot be modified from inside.

### Firewall Configuration

All 6 VMs have:
- `firewall=1` on both NICs (VLAN 4 and VLAN 12)
- `policy_in=DROP` — all inbound traffic dropped unless explicitly allowed
- `policy_out=ACCEPT` — all outbound traffic allowed

### App Node Rules (VM 4100, 4101, 4102)

| # | Direction | Action | Source | Port | Proto | Purpose |
|---|-----------|--------|--------|------|-------|---------|
| 0 | IN | ACCEPT | 192.168.2.0/24 | 22 | tcp | SSH from management VLAN |
| 1 | IN | ACCEPT | 192.168.2.5 | 5433 | tcp | Home Assistant → HAProxy RW |
| 2 | IN | ACCEPT | 192.168.2.5 | 5434 | tcp | Home Assistant → HAProxy RO |
| 3 | IN | ACCEPT | 192.168.4.0/24 | 2377 | tcp | Swarm management |
| 4 | IN | ACCEPT | 192.168.4.0/24 | 7946 | tcp | Swarm gossip TCP |
| 5 | IN | ACCEPT | 192.168.4.0/24 | 7946 | udp | Swarm gossip UDP |
| 6 | IN | ACCEPT | 192.168.4.0/24 | 4789 | udp | Swarm VXLAN overlay |
| 7 | IN | ACCEPT | 192.168.12.0/24 | 7946 | tcp | Swarm gossip TCP (VLAN 12) |
| 8 | IN | ACCEPT | 192.168.12.0/24 | 7946 | udp | Swarm gossip UDP (VLAN 12) |
| 9 | IN | ACCEPT | 192.168.12.0/24 | 4789 | udp | Swarm VXLAN (VLAN 12) |
| * | IN | **DROP** | * | * | * | Default policy |

### Infra Node Rules (VM 4200, 4201, 4202)

All app node rules PLUS:

| # | Direction | Action | Source | Port | Proto | Purpose |
|---|-----------|--------|--------|------|-------|---------|
| 10 | IN | ACCEPT | 192.168.12.0/24 | 5432 | tcp | PostgreSQL direct (HAProxy + replication) |
| 11 | IN | ACCEPT | 192.168.12.0/24 | 8008 | tcp | Patroni REST API (health checks) |
| 12 | IN | ACCEPT | 192.168.12.0/24 | 2379 | tcp | etcd client port |
| 13 | IN | ACCEPT | 192.168.12.0/24 | 2380 | tcp | etcd peer port |
| 14 | IN | ACCEPT | 192.168.4.0/24 | 9187 | tcp | Prometheus exporter metrics |
| * | IN | **DROP** | * | * | * | Default policy |

### Why 192.168.12.0/24 covers HAProxy→Patroni traffic

HAProxy runs on app nodes (VLAN 4: 192.168.4.30-32), but also has VLAN 12 IPs (192.168.12.30-32). HAProxy health checks against Patroni (port 8008) and forwards connections to PostgreSQL (port 5432) via the VLAN 12 addresses configured in `haproxy.cfg`. So `192.168.12.0/24` as source covers both inter-infra and app→infra traffic.

---

## Management Operations

### Rollback firewall (disable per VM)

```bash
# Via Proxmox API
pvesh set /nodes/<pve-node>/qemu/<vmid>/firewall/options --enable 0

# Examples
pvesh set /nodes/pve01/qemu/4100/firewall/options --enable 0  # app-1
pvesh set /nodes/pve01/qemu/4200/firewall/options --enable 0  # infra-1
```

### Check firewall status

```bash
# Per-VM status
pvesh get /nodes/pve01/qemu/4100/firewall/options --output-format json

# List rules
pvesh get /nodes/pve01/qemu/4100/firewall/rules --output-format json-pretty
```

### Ansible playbook

An Ansible playbook is provided at `swarm-stacks/playbooks/configure-proxmox-firewall.yml` for declarative management. It uses the Proxmox REST API and processes VMs one at a time (`serial: 1`).

```bash
# Apply rules (requires PROXMOX_API_PASSWORD or API token)
ansible-playbook -i swarm-stacks/ansible/inventory.ini \
  swarm-stacks/playbooks/configure-proxmox-firewall.yml

# Disable firewall (rollback)
ansible-playbook -i swarm-stacks/ansible/inventory.ini \
  swarm-stacks/playbooks/configure-proxmox-firewall.yml \
  --extra-vars "firewall_enabled=false"
```

---

## Verification Checklist

| Test | Command | Expected |
|------|---------|----------|
| Patroni cluster | `curl -s http://192.168.12.40:8008/cluster \| jq .` | 1 leader + 2 replicas |
| HAProxy RW | `psql -h 192.168.4.30 -p 5433 -U homeassistant -d homeassistant` from 192.168.2.5 | Connection succeeds |
| HAProxy RO | `psql -h 192.168.4.30 -p 5434 -U homeassistant -d homeassistant` from 192.168.2.5 | Connection succeeds |
| Swarm overlay | From a Swarm service: `psql -h pg-haproxy -p 5433` | Connection succeeds |
| Block test | `psql -h 192.168.4.30 -p 5433` from unauthorized IP | Connection timeout (DROP) |
| Patroni blocked externally | `curl http://192.168.12.40:8008` from 192.168.2.5 | Timeout |
| etcd blocked externally | `curl http://192.168.12.40:2379` from 192.168.2.5 | Timeout |
| Stats port removed | `curl http://192.168.4.30:7000` | Timeout |

---

## DNS Setup (Phase 1 — Manual)

Add A records in Pi-hole (192.168.2.4) for HA round-robin:

```
postgres.hornung-bn.de  →  192.168.4.30
postgres.hornung-bn.de  →  192.168.4.31
postgres.hornung-bn.de  →  192.168.4.32
```

Add via Pi-hole web UI: **Local DNS > DNS Records**, or edit `/etc/pihole/custom.list`.

### Home Assistant recorder configuration

```yaml
recorder:
  db_url: postgresql://homeassistant:<password>@postgres.hornung-bn.de:5433/homeassistant
```

---

## Files

| File | Purpose |
|------|---------|
| `docker/entrypoint.sh` | Generates patroni.yml with hardened pg_hba rules |
| `postgres-ha-stack.yml` | Stack definition (port 7000 removed from HAProxy) |
| `docker-swarm.tf` | Terraform: `firewall = true` on all VM NICs |
| `swarm-stacks/playbooks/configure-proxmox-firewall.yml` | Ansible playbook for Proxmox firewall rules |
| `swarm-stacks/playbooks/tasks/configure-vm-firewall.yml` | Task file for per-VM rule application |
| `docs/POSTGRES_HA_SECURITY.md` | This document |
