# VM-Recreate Runbook (via `qm clone`, without Terraform)

> **Closes**: [#6 — docs: Runbook für VM-Recreate via qm clone (ohne terraform)](https://github.com/thorstenhornung1/swarm-stacks/issues/6)

For DR scenarios where a single Swarm-infra VM is broken beyond repair
(corrupted Docker daemon, runaway dpkg state, ZFS corruption) and a clean
**VM-recreate** is the answer. This path bypasses Terraform/`bpg/proxmox`
to dodge plugin bugs — direct `qm clone` from the Ubuntu cloud-init
template is faster, more predictable, and uses primitives that are already
trusted (PVE itself).

## When to use this runbook

- Single `docker-infra-N` node broken (Docker daemon refuses to start,
  unfixable apt/dpkg state, filesystem corruption)
- Direct VM-clone path needed because Terraform refuses to re-apply
  cleanly (bpg/proxmox state-drift, refer Issue #3)
- You can afford to lose that node's local state — replicated services
  (Patroni, etcd, CephFS) will heal once it's back

## When NOT to use this runbook

- Multiple nodes broken simultaneously → see [DISASTER-RECOVERY-RUNBOOK.md](DISASTER-RECOVERY-RUNBOOK.md)
- Node still partially functional → fix in-place (less risk)
- Stateful local data on the VM that's not replicated elsewhere → snapshot
  first, then decide

## Phase 1 — Pre-flight (5 min)

Verify cluster health BEFORE making it worse:

```bash
# On the swarm leader (any working docker-infra-*)
docker node ls          # Confirm the bad node, identify leader
docker service ls       # Note which services depend on infra_node=<N>

# Patroni — must have leader + at least one streaming replica before we remove a node
curl -sf http://localhost:8008/cluster | jq '.members[] | {name, role, state}'

# etcd quorum — 5-node cluster tolerates 2 losses, but check we're not already degraded
docker exec etcd etcdctl endpoint status --cluster --write-out=table
```

**Abort criteria:**
- Patroni already lacks streaming replica → fix replication first
- etcd quorum already at minimum (3/5) → stabilize before removing more
- Active GitOps deploy in flight → wait for it (`/mnt/cephfs/swarm-state/.swarm-maintenance.lock`)

## Phase 2 — Drain the failing node from Swarm (3 min)

```bash
# Replace <BAD> with hostname (e.g. docker-infra-1)
docker node update --availability drain <BAD>

# Wait for tasks to leave
watch -n 2 'docker node ps <BAD>'   # Until empty (ignore Shutdown tasks)
```

If the daemon won't respond to `update --availability drain`, skip to Phase 3 — `docker node rm --force` will handle it.

## Phase 3 — Patroni / etcd / Swarm cleanup (5 min)

```bash
# Demote from Swarm
docker node demote <BAD>           # If still a manager
docker node rm --force <BAD>       # Force-remove (node won't be reachable)

# Remove from etcd cluster (5-node)
docker exec etcd etcdctl member list
docker exec etcd etcdctl member remove <MEMBER_ID>

# Patroni: if the bad node was hosting a replica, no action needed —
# Patroni-bootstrap on the new VM will re-join cleanly. If it was the
# leader, a failover already happened; verify:
curl -sf http://localhost:8008/cluster | jq '.members[] | select(.role=="leader")'
```

## Phase 4 — MANDATORY snapshot before destroy

Per [CLAUDE.md disaster-recovery rule](https://github.com/thorstenhornung1/terraform/blob/main/.claude/CLAUDE.md):

```bash
# SSH to the PVE host that holds the bad VM (typically pve01/02/03 ↔ infra-1/2/3)
PVE=pve02   # adapt
ssh root@$PVE "qm snapshot <VMID> pre-recreate-$(date +%Y%m%d-%H%M%S)"
ssh root@$PVE "qm listsnapshot <VMID>"
```

**Do not skip even if the VM is unreachable** — the snapshot is a
last-line ZFS rollback if Phase 5 goes wrong.

## Phase 5 — Destroy + Recreate via `qm clone`

```bash
# Template VMID 9000 lives on pve01 (Ubuntu 24.04 cloud-init template)
TEMPLATE=9000
NEW_VMID=4200      # e.g. docker-infra-1 = 4200, infra-2 = 4201, infra-3 = 4202
TARGET=pve01

# Destroy the broken VM
ssh root@$TARGET "qm stop <BAD_VMID> --skiplock || true; qm destroy <BAD_VMID>"

# Clone from template (cross-node clone if needed)
ssh root@pve01 "qm clone $TEMPLATE $NEW_VMID --target $TARGET --name docker-infra-N --full"

# Resize disk to match production (template is small)
ssh root@$TARGET "qm resize $NEW_VMID scsi0 +20G"
```

## Phase 6 — Cloud-init snippet (manually)

The cloud-init snippet lives on **Diskstation-NFS** (per CLAUDE.md storage rules — cloud-init is the ONLY allowed Synology usage):

```bash
# Edit the cloud-init user-data file
nano /mnt/pve/Diskstation-NFS/snippets/docker-infra-N-user.yaml

# Apply to the new VM
ssh root@$TARGET "qm set $NEW_VMID --cicustom 'user=Diskstation-NFS:snippets/docker-infra-N-user.yaml'"
ssh root@$TARGET "qm set $NEW_VMID --ipconfig0 'ip=192.168.4.4N/24,gw=192.168.4.1'"   # 4N = 40/41/42
ssh root@$TARGET "qm set $NEW_VMID --net0 'virtio,bridge=vmbr0,tag=4'"               # VLAN 4
```

## Phase 7 — Start + re-integrate (10 min)

```bash
# Start VM, watch console for cloud-init completion
ssh root@$TARGET "qm start $NEW_VMID"

# SSH in (cloud-init handles user setup)
ssh root@192.168.4.4N    # IP per ipconfig0 above

# Inside the new VM:
docker swarm join --token <WORKER_OR_MANAGER_TOKEN> 192.168.4.40:2377

# Re-add etcd member (from EXISTING etcd container)
docker exec etcd etcdctl member add docker-infra-N \
  --peer-urls=http://192.168.4.4N:2380

# Then on the new node, start etcd container with --initial-cluster-state=existing
# (see project_etcd_5node_cluster.md memory pin — initial-cluster must match CURRENT membership)
```

## Phase 8 — Restore labels (CRITICAL)

Labels are NOT replicated automatically. Apply per [SWARM-NODE-LABELS.md](SWARM-NODE-LABELS.md):

```bash
# From any working docker-infra-* node
docker node update --label-add app=true \
                   --label-add database=patroni \
                   --label-add "infra_node=N" \
                   docker-infra-N
```

## Phase 9 — Force re-deploy services

```bash
# Stacks that have constraints like node.labels.infra_node==N will not
# reschedule until labels are set. Trigger after Phase 8:
docker service ls -q | xargs -L1 docker service update --force
```

## Phase 10 — Verify

```bash
docker node ls                                            # 3 healthy nodes
curl -sf http://localhost:8008/cluster | jq '.members'    # Patroni: 3 members
docker exec etcd etcdctl endpoint status --cluster        # etcd: 5 healthy
docker service ls --filter "mode=replicated"              # all 1/1 or N/N
```

## Related

- [DISASTER-RECOVERY-RUNBOOK.md](DISASTER-RECOVERY-RUNBOOK.md) — multi-node failures
- [SWARM-NODE-LABELS.md](SWARM-NODE-LABELS.md) — label SSoT (Phase 8)
- [LIVE-MIGRATION-RUNBOOK.md](LIVE-MIGRATION-RUNBOOK.md) — for planned moves between PVE hosts (no VM-recreate needed)
- CLAUDE.md disaster-recovery rule — mandatory snapshot before destroy
