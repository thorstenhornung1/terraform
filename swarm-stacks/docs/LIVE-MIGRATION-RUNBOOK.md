# Live-Migration Runbook (HA-VMs, LXCs, special cases)

> **Closes**: [#14 — Test live-migration runbook for current HA workloads](https://github.com/thorstenhornung1/swarm-stacks/issues/14)

For **planned** migrations between Proxmox hosts (`pve01`/`pve02`/`pve03`)
during maintenance, hardware-replacement, or load-rebalancing. For
**unplanned** node failure, see [DISASTER-RECOVERY-RUNBOOK.md](DISASTER-RECOVERY-RUNBOOK.md).
For broken-single-VM replacement, see [VM-RECREATE-RUNBOOK.md](VM-RECREATE-RUNBOOK.md).

## Current HA-managed inventory (verified 2026-05-29)

```
service vm:100  dock01           started on pve02   (CT manager / generic ops, 6 GB RAM)
service vm:103  homeassistant    started on pve02   (Home Assistant OS, 10 GB RAM)
```

Both are under `ha-manager` control → **never use `qm shutdown` or `qm stop`**
directly. The HA-CRM will fight you and restart them.

## Cluster RAM topology (constraint check before any migration)

```
pve01    ~14 GB usable    (Tailscale, dns1, docker-infra-1, gha-runner-equiv)
pve02    ~31 GB usable    (workhorse — most VMs live here today)
pve03    ~15 GB usable    (constrained — Frigate-LXC holds 12 GB hard)
```

**Migration pre-check**: target must have free RAM ≥ migrating VM's
allocation. Specifically, `vm:103 homeassistant (10 GB)` cannot land on
pve03 while Frigate-LXC is up (Frigate is hard-pinned to pve03, see
constraints below). Realistic placement: pve02 ⇄ pve01 only.

## Workload class A — HA-managed KVM VMs (vm:100, vm:103)

### Procedure for `vm:103 homeassistant` (PostgreSQL inside, dirties RAM fast)

```bash
# 1. Pre-flight: free RAM on target?
ssh root@pve01 'free -h'   # at least 12 GB free for the 10 GB VM
ssh root@pve02 'free -h'

# 2. Stop Home-Assistant recorder BEFORE migrate (memory-pin
#    feedback_ha_recorder_migration.md):
#    HA recorder dirties pages too fast for live-migrate convergence.
#    Disable via Developer Tools → Services or via API:
curl -X POST 'https://homeassistant.hornung-bn.de/api/services/recorder/disable' \
  -H "Authorization: Bearer $HA_TOKEN" -H "Content-Type: application/json" -d '{}'

# 3. HA-aware live-migrate (NOT qm migrate — ha-manager handles HA state)
ha-manager migrate vm:103 pve01

# 4. Watch convergence
watch -n 1 'qm list | grep 103; ha-manager status | grep vm:103'

# 5. After migration, re-enable recorder
curl -X POST 'https://homeassistant.hornung-bn.de/api/services/recorder/enable' \
  -H "Authorization: Bearer $HA_TOKEN" -H "Content-Type: application/json" -d '{}'
```

### Procedure for `vm:100 dock01`

Currently `started`. Memory used to mark it as "stopped memory buffer" —
that's no longer true (live state 2026-05-29: started on pve02). Treat as
standard HA-VM:

```bash
ssh root@<target> 'free -h'
ha-manager migrate vm:100 pve01    # or pve03 (it's only 6 GB)
```

### HA-aware shutdown (NOT covered by ha-manager migrate)

If you need to STOP an HA VM (not migrate), use:

```bash
# Tells the CRM "intentionally stopped — don't restart"
ha-manager set vm:103 --state stopped

# When ready to bring back:
ha-manager set vm:103 --state started
```

`qm shutdown vm:103` would trigger an HA-restart cycle (memory pin
feedback_ha_aware_shutdown.md).

## Workload class B — LXC containers (Technitium DNS, etcd-4/5, Tailscale, gha-runner)

LXC live-migration via `pct migrate --online`. Works for any LXC that
doesn't have hardware passthrough or strict node-affinity.

### Currently live-migrate-able LXCs

| LXC | VMID | Current node | Service-impact |
|---|---|---|---|
| dns1 | 4100 | pve01 | Technitium DNS — clients failover to dns2/dns3 |
| dns2 | 4101 | pve02 | same |
| dns3 | 4102 | pve03 | same |
| etcd-4 | 4301 | pve02 | etcd — 5-node tolerates 2 losses, migrate one at a time |
| etcd-5 | 4302 | pve03 | same |
| gha-runner | 4303 | pve02 | CI runners — accept brief downtime during cycle |
| tailscale-1 | 4503 | pve01 | BGP HA pair — backup takes over via BFD ~450ms |
| tailscale-2 | 4504 | pve02 | same |

### Procedure

```bash
# 1. Verify quorum (etcd specifically — single-node migration during a 5-node etcd is fine,
#    but never two simultaneously)
ssh root@pve02 'docker exec etcd etcdctl endpoint status --cluster --write-out=table'

# 2. Pre-check target RAM
ssh root@<target> 'free -h'

# 3. Live-migrate
ssh root@<current> 'pct migrate <VMID> <target> --online'

# 4. Verify
ssh root@<target> "pct list | grep <VMID>"
```

## Workload class C — Special case: Frigate-LXC (4502 on pve03)

**Live-migration is NOT possible** for this LXC. Constraints (memory pin
feedback_frigate_migration_constraints.md):

1. **iGPU passthrough** — Frigate uses OpenVINO on the pve03 Intel iGPU.
   The device-mapping is host-specific; the LXC's iGPU paths break on
   migration.
2. **Local ZFS `tank` storage** — Frigate config + clips are on local-ZFS
   without replication. Cannot just appear on pve01/02.
3. **RBD/NFS hostspezifische Mounts** — Recordings on Synology NFS via
   pve03-specific mount config.

### Offline-migration procedure (planned outage window only)

```bash
# 1. Stop Frigate-LXC
ssh root@pve03 'pct stop 4502'

# 2. Backup
ssh root@pve03 'vzdump 4502 --storage <PBS> --compress zstd'

# 3. On the target host (e.g. pve02):
#    - Configure equivalent iGPU passthrough in /etc/pve/lxc/4502.conf
#    - Mount equivalent local storage path
#    - Set up NFS mounts identically
#    - Restore from backup
ssh root@pve02 'pct restore 4502 <BACKUP_FILE> --storage tank-pve02'

# 4. Reconfigure VLAN + IP if changed
# 5. Test camera streams, recordings, face-detection before declaring success
```

**Expected downtime**: 30–60 min including backup + restore + verify.
Plan this around camera-event-likelihood (avoid night-time).

## Pre-flight checklist (any migration class)

- [ ] Target node has free RAM ≥ source-VM RAM allocation (`free -h`)
- [ ] No active GitOps deploy in flight (`/mnt/cephfs/swarm-state/.swarm-maintenance.lock` absent or stale)
- [ ] If migrating an etcd member: no other etcd member is being migrated simultaneously
- [ ] If migrating vm:103: recorder is disabled
- [ ] ZFS replication for the source disk is up to date (`zfs list -t snapshot | grep <VM-id>`)
- [ ] (For HA VMs) Used `ha-manager migrate` NOT `qm migrate`
- [ ] (For HA stops) Used `ha-manager set vm:N --state stopped` NOT `qm shutdown`

## WoL caveat

If a node is fully off and needs to come up to receive migrations, WoL
**must be sent from the dns2 LXC** (VLAN 4) — not from a PVE host on VLAN 2.
See memory pin `feedback_wol_vlan4.md`. The Python UDP-broadcast script
lives in the dns2 LXC.

## Related

- [VM-RECREATE-RUNBOOK.md](VM-RECREATE-RUNBOOK.md) — when migrate is the wrong tool
- [DISASTER-RECOVERY-RUNBOOK.md](DISASTER-RECOVERY-RUNBOOK.md) — multi-node failure
- [SWARM-NODE-LABELS.md](SWARM-NODE-LABELS.md) — label SSoT
- CLAUDE.md HA VM Protection — never `qm stop`/`qm shutdown`, always `ha-manager migrate`
