# Swarm Node Labels — Single Source of Truth

> **Closes**: [#5 — ops: Label-Schema-Konsolidierung für Swarm Manager Nodes](https://github.com/thorstenhornung1/swarm-stacks/issues/5)

This is the **authoritative label schema** for the 3 `docker-infra-*` Swarm
manager nodes. Memory snapshots have drifted in the past (`app=true` vs
`app=1`, lingering `storage=seaweedfs` after the SeaweedFS removal). If
this file and reality disagree, **this file wins** — reconcile reality.

## Current state (verified 2026-05-29)

```
docker-infra-1   app=true database=patroni infra_node=1
docker-infra-2   app=true database=patroni infra_node=2
docker-infra-3   app=true database=patroni infra_node=3
```

## Label semantics

| Label | Type | Purpose | Consumers |
|---|---|---|---|
| `app=true` | Boolean | Generic application-tier placement (gha-runner, valkey, reisekosten, etc.) | Most stacks under `stacks/apps/` and `stacks/infrastructure/` use `node.labels.app == true` |
| `database=patroni` | Keyword | Patroni HA Postgres placement | `stacks/infrastructure/postgres-ha/postgres-ha-stack.yml`, `stacks/infrastructure/pg-backup/` |
| `infra_node=<1\|2\|3>` | Identifier | Per-node anti-affinity (e.g. spread etcd, Patroni-replicas, Frigate-recorders across nodes) | Stacks with `node.labels.infra_node == <N>` constraints |

## Removed labels (historic — DO NOT re-add)

| Label | Removed because |
|---|---|
| `storage=seaweedfs` | SeaweedFS was removed from the cluster. Replaced by CephFS (mounted on all 3 nodes via `swarm-shared` PVE storage). CephFS does not need a label gate. |

## Setting labels manually (until #5 Phase 2 lands)

When labels are lost (Swarm-Manager rebuild, VM-recreate via runbook, `docker swarm leave` accident):

```bash
# Run on any swarm-manager (any docker-infra-*)
for i in 1 2 3; do
  HOST="docker-infra-$i"
  docker node update --label-add app=true \
                     --label-add database=patroni \
                     --label-add "infra_node=$i" \
                     "$HOST"
done

# Verify
docker node ls --format '{{.Hostname}}' | while read N; do
  printf '%-18s' "$N:"
  docker node inspect "$N" --format '{{range $k,$v := .Spec.Labels}}{{$k}}={{$v}} {{end}}'
  echo
done
```

This block can be copy-pasted into `swarm-os-maintenance.yml`'s Pre-flight
play if/when label-drift recurs without VM-recreate as cause.

## Phase 2 plan (Ansible playbook)

Issue #5 originally proposed a declarative `configure-swarm-labels.yml`
playbook analogous to the K3s `configure-node-labels.yml`. That's the
right long-term shape — turns this Markdown file into the source of truth
for an idempotent rollout:

```yaml
# ansible playbook (sketch — not yet implemented)
- hosts: docker_swarm_infra[0]
  vars:
    swarm_node_labels:
      docker-infra-1: { app: 'true', database: patroni, infra_node: 1 }
      docker-infra-2: { app: 'true', database: patroni, infra_node: 2 }
      docker-infra-3: { app: 'true', database: patroni, infra_node: 3 }
  tasks:
    - name: Apply Swarm node labels
      ansible.builtin.shell: |
        docker node update --label-add 'app={{ item.value.app }}' \
          --label-add 'database={{ item.value.database }}' \
          --label-add 'infra_node={{ item.value.infra_node }}' \
          '{{ item.key }}'
      loop: "{{ swarm_node_labels | dict2items }}"
```

Until that lands, this Markdown + the shell block above are the
operational SSoT.

## Related

- [docs/ARCHITECTURE.md](ARCHITECTURE.md) — overall swarm topology
- [docs/DISASTER-RECOVERY-RUNBOOK.md](DISASTER-RECOVERY-RUNBOOK.md) — full-cluster DR
- [docs/VM-RECREATE-RUNBOOK.md](VM-RECREATE-RUNBOOK.md) — single-node recreate (where labels must be re-applied after step 7)
