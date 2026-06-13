# Grafana SQLite: CephFS → Ceph RBD — Cutover-Runbook

**Ziel:** Grafanas SQLite (`grafana.db`) von CephFS auf ein exclusive-lock RBD
(lokales ext4, natives File-Locking) migrieren. Behebt die CephFS-SQLite-
Fragilität (B-15: `start-first`-Updates scheiterten an „database is locked").

**Muster:** spiegelt openarchiver-meili (RBD + Auto-Failover-Watchdog).
**Artefakte:** `ansible/rbd-mount-grafana.yml`, `ansible/files/grafana-rbd-failover.sh`,
Compose-Änderung in `stacks/monitoring/monitoring-stack.yml` (Volume → `/mnt/rbd/grafana`,
constraint → `node.labels.grafana-rbd == active`, `max_replicas_per_node: 1`).

> ⚠️ **Reihenfolge ist kritisch.** Die Compose-Änderung (constraint `grafana-rbd==active`)
> erst in **Schritt 6** deployen — vorher trägt kein Node das Label → Grafana unschedulbar.
> ⚠️ **Datenverlust-Schutz (CLAUDE.md):** Schritt 3 (Backup) ist Pflicht vor Schritt 4/5.

Downtime: ~1–2 min (Schritt 4–6). Pool `swarm-volumes`, Image `grafana-data` (8 GiB).

---

## Schritt 1 — RBD-Maschinerie deployen (idempotent, KEINE Daten berührt)
Erstellt+formatiert das RBD-Image (nur wenn leer), deployt Units+Script, startet
den Watchdog. Der Watchdog wählt einen Node, mappt+mountet `/mnt/rbd/grafana` (leer)
und setzt `grafana-rbd=active`.
```bash
cd ~/Documents/projects/ansible
ANSIBLE_CONFIG=.ansible.cfg ansible-playbook -i inventory-local.ini rbd-mount-grafana.yml
```

## Schritt 2 — Aktiven Node + leeren Mount verifizieren (read-only)
```bash
ssh root@192.168.4.40 'for n in $(docker node ls -q); do docker node inspect $n --format "{{.Description.Hostname}} grafana-rbd={{index .Spec.Labels \"grafana-rbd\"}}"; done'
# -> ACTIVE = docker-infra-N (IP 192.168.4.4X). Dann:
ssh root@192.168.4.4X 'mountpoint /mnt/rbd/grafana && ls -la /mnt/rbd/grafana'
```

## Schritt 3 — Backup grafana.db (PFLICHT, bleibt auf CephFS)
```bash
ssh root@192.168.4.40 'cp -a /mnt/cephfs/swarm-state/stack-monitoring/grafana/grafana.db \
  /mnt/cephfs/swarm-state/stack-monitoring/grafana.db.bak-$(date +%Y%m%d-%H%M%S) && \
  ls -la /mnt/cephfs/swarm-state/stack-monitoring/grafana.db.bak-*'
```

## Schritt 4 — Grafana stoppen (Downtime beginnt, SQLite-Konsistenz)
```bash
ssh root@192.168.4.40 'docker service scale monitoring_grafana=0'
```

## Schritt 5 — Daten migrieren CephFS → RBD (auf dem ACTIVE-Node aus Schritt 2)
```bash
ssh root@192.168.4.4X 'rsync -aHAX /mnt/cephfs/swarm-state/stack-monitoring/grafana/ /mnt/rbd/grafana/ && \
  echo "--- verify ---" && ls -la /mnt/rbd/grafana/grafana.db && du -sh /mnt/rbd/grafana'
```

## Schritt 6 — Compose-Änderung deployen (Volume+Placement → RBD)
`monitoring-stack.yml` ist bereits geändert (Volume `/mnt/rbd/grafana`, constraint
`grafana-rbd==active`, `max_replicas_per_node: 1`). Jetzt committen + pushen → GitOps
deployt; `replicas: 1` überschreibt das scale=0; Grafana startet auf dem active-Node
und liest `grafana.db` vom RBD.
```bash
cd ~/tmp/terraform/swarm-stacks
git add stacks/monitoring/monitoring-stack.yml && git commit -m "monitoring: Grafana SQLite auf RBD (CephFS-Locking-Fix B-15)"
git push origin main   # + terraform-Sync
```

## Schritt 7 — Verifizieren
```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://grafana.hornung-bn.de/api/health   # 200
ssh root@192.168.4.40 'docker service ps monitoring_grafana --format "{{.CurrentState}}"'
# Grafana-UI: Dashboards/Users/Datasources vorhanden? (= grafana.db korrekt migriert)
```
Failover-Drill (optional): `GRAFANA_FAILOVER_FORCE_TAKEOVER=1 /usr/local/bin/grafana-rbd-failover.sh`
auf einem anderen Node (nach `ceph osd blocklist add <holder-watcher>`).

## Schritt 8 — Cleanup (NACH einigen Tagen stabilem Betrieb)
Alte CephFS-Daten + Backup entfernen, wenn RBD bewährt:
```bash
# ssh root@192.168.4.40 'rm -rf /mnt/cephfs/swarm-state/stack-monitoring/grafana'   # erst wenn sicher!
```

---

## Rollback (falls etwas schiefgeht)
1. Compose-Change zurücknehmen (Volume → CephFS, constraint → `app==true`), pushen.
2. Grafana läuft wieder auf CephFS+`grafana.db.bak-*` (Backup zurückkopieren falls nötig).
3. RBD-Watchdog stoppen: `systemctl disable --now grafana-rbd-failover.timer` auf allen Nodes.
