# Migrationsplan: Patroni-3-Node → Single-PostgreSQL-VM + Proxmox-HA

> Status: **PLAN** (2026-06-14). Entscheidung getroffen nach einstimmigem Verdict von 3 Spezialisten-
> Agenten (DBA, Architektur-Review, Research). Noch nichts ausgeführt — pro Schritt freigeben.

## 1. Warum (Begründung)

Live erhoben: Der Patroni-Cluster ist auf **Timeline 205 — ~28 Failover/Divergenzen in 7 Tagen**
für eine **nur 5–7 GB große DB**. Die Instabilität ist **strukturell**, nicht wegtunbar, weil dieses
Substrat drei Patroni-Grundvoraussetzungen verletzt:
1. **Geteiltes 1GbE** (corosync+Ceph+Backup+VM) → DCS-Heartbeat-Jitter → Lease-Failover **ohne** echten DB-Fehler.
2. **RAM-Enge** (Nodes 7–8 GB, pve03 overcommit) → OOM = dokumentierter Divergenz-Trigger.
3. **Korrelierte Failure-Domains** (alle 3 PG auf denselben 3 Hosts/Link/Ceph) → echter HA-Gewinn ≈ 0,
   volle Komplexität importiert.

Plus Betriebslast: reinit-EBUSY (PGDATA=Mount-Root), WAL-Bloat (18 GB lokales Archiv) → Disk-Full →
Emergency-Boot, HAProxy-Failover-500-Kaskaden (App-seitiges Patroni-safe-Pattern als Pflicht).

**Zielbild:** Eine einzelne PG-VM auf shared Ceph-RBD unter Proxmox-HA. RPO ≈ 0 (RBD size=3 +
`synchronous_commit=on`, Crash-Recovery wie nach Stromausfall), RTO ~3–5 min (vollautomatisch, DB winzig),
**Split-Brain/Divergenz unmöglich**, drastisch weniger Komplexität, freiwerdendes RAM beseitigt den
OOM-Druck. Trade-off bewusst: ~3–5 min RTO statt theoretischer Sekunden (die hier real manuell sind).

## 2. Zielarchitektur

- **1× VM `postgres-prod`** (PostgreSQL 16 + pgvector). RAM 6–8 GB (DB ist 5–7 GB), 4 vCPU.
- **Disk auf `tank` (lokales ZFS, NVMe) + `pvesr`-ZFS-Replikation** aufs HA-Failover-Ziel.
  **ENTSCHEIDUNG 2026-06-14 nach Research:** Ceph RBD wurde VERWORFEN — PG-fsync/Commit wartet bei RBD
  synchron auf OSD-Acks über das **geteilte 1GbE** (~20–30 fsync-IOPS auf kleinem Cluster vs. sub-ms
  lokale NVMe); unter openarchiver-Bulk-WAL-Last sättigt Ceph-Replikation den Link → Commits stallen.
  Kein RBD-Tuning kompensiert das (writeback hilft bei fsync nicht). Zudem sind die RBD-Pools nur size=2.
  ZFS lokal hat KEINEN Netz-Roundtrip im Commit-Pfad. Bewährtes Muster hier (vm:103 läuft so).
  - **ZFS-Tuning fürs PG-Dataset:** `recordsize=16k`, `logbias=latency`, `compression=lz4`, `atime=off`,
    `primarycache=all`, `xattr=sa`.
  - **Trade-off RPO:** pvesr ist async → RPO-Gap = Replikationsintervall (`*/1` = bis ~1 min Verlust bei
    Total-Node-Ausfall). Für die Apps akzeptabel. Echtes RPO≈0 nur via PG-Streaming/WAL-Archiving auf
    2. Node (App-Layer, optional Phase 2).
- **Primär-Node pve02** (32 GB, meiste Reserve); HA-Migrationsziel mit pvesr-Replikat — RAM-Headroom
  gegen die pve02-RAM-Limit-Regel prüfen. (Bei tank/pvesr muss das Replikat-Dataset auf dem Zielnode
  liegen → Replikationsziel = ein konkreter Node, nicht „beliebig" wie bei shared storage.)
- **Proxmox HA:** `ha-manager add vm:<id> --state started`, Software-Watchdog aktiv (✓ fencing armed,
  3-Node-Quorum vorhanden), HA-Gruppe passend zum pvesr-Replikationsziel. **Fencing-Test vor Go-Live**
  (Host hart aus → RTO real messen).
- **Endpoint:** stabile VM-IP, DNS `postgres.hornung-bn.de` → VM-IP (Technitium **pro-Node** pflegen!).
  Apps von `pg-haproxy:5433` auf den neuen Endpoint umstellen. Patroni-safe-Pool-Pattern bleibt drin
  (übersteht die HA-Failover-Lücke graceful).
- **Backup/PITR: pgBackRest**, Repo **off-node** (CephFS/NFS/PBS), echte Retention (z.B. 7d full+incr
  + WAL). Ersetzt das fragile `cp`+`find -mtime`. **Restore monatlich testen = realer RTO.**

## 3. Vorab klären / Sofort (unabhängig)

- [ ] **`homeassistant`-DB im Patroni-Cluster** (7,7 MB) verifizieren — Kontext sagt „HA hat separate
      lokale PG". Zweitnutzung? Altbestand? → Migrationsumfang festlegen.
- [ ] **WAL-18GB-Bloat** entschärft (Retention 7→3d) — verhindert Disk-Full vor der Migration.
- [ ] DB-/App-Inventar: welche DBs (paperless, authentik, immich/pgvector, reisekosten/steuer, n8n, …),
      welche Apps mit welchen Connection-Strings auf `pg-haproxy:5433`.
- [ ] pgvector-`-march`-Lektion (AVX-512/SIGILL, Issue #9) ins Ziel-Image/Paket übernehmen.

## 4. Migrationsschritte (inkrementell, pro Schritt freigeben)

1. **Snapshot-Pflicht** vor jeder destruktiven Aktion (CLAUDE.md DR-Rule).
2. **Ziel-VM bauen** (PG16+pgvector, **tank/ZFS-Disk + pvesr-Replikation**, HA-Gruppe). Terraform-Ressource
   + cloud-init (LDAP/SSSD/rsyslog→Loki/APT-Proxy gem. Standard-VM-Pattern). ZFS-Dataset-Tuning s.o.
3. **pgBackRest aufsetzen** auf der Ziel-VM (Repo off-node). Erster Full-Backup.
4. **Proxmox-HA aktivieren** + **Fencing-/Failover-Test** (Host hart aus) → RTO messen, BEVOR Last drauf.
5. **Daten-Cutover je Stack** (nicht Big-Bang), Reihenfolge nach Kritikalität:
   - Pro App: kurzes Wartungsfenster → `pg_dump` (Cluster ist 5–7 GB → Minuten) → Restore in Ziel-VM →
     Connection-String umstellen → verifizieren → nächste App.
   - `homeassistant`-DB: GEKLÄRT — leer (0 Tabellen, Altbestand), wird NICHT migriert, entfällt einfach.
     (HAs echte ltss-DB ist separat lokal in der HA-VM und bleibt dort.)
6. **Cutover-Endpoint:** DNS `postgres.hornung-bn.de` → Ziel-VM (pro Technitium-Node). Apps umbiegen.
7. **Patroni + etcd-4/5 abbauen** (nach Verifikation): `docker stack rm postgres-ha-stack`,
   etcd-LXC aus `etcd-cluster.tf` entfernen → **RAM-Gewinn** auf pve02/pve03 (entschärft den OOM-Druck).
8. **Monitoring umstellen:** postgres-exporter direkt gegen die VM; Uptime-Kuma von Patroni-`/health`
   auf `pg_isready`/TCP. Grafana-PG-HA-Alerts (patroni-no-leader etc.) entfernen/ersetzen.

## 5. Risiken / Caveats

- **VM-Disk-Cache:** Default (`none`/writethrough) lassen, fsync in PG an (Default). **Kein `cache=unsafe`.**
- **RPO-Gap durch async pvesr** (s. Abschnitt 2) — bei Total-Node-Ausfall bis ~1 min Verlust. Bewusst akzeptiert.
- **pvesr-Replikationsziel ist ein KONKRETER Node** (anders als shared storage): HA-Gruppe so setzen, dass
  das Failover-Ziel = der Node mit dem aktuellen ZFS-Replikat ist, sonst muss HA erst voll replizieren.
- **Single-VM = kein Live-Replikat** → Backup/PITR-Restore-Test wird WICHTIGER (monatlich).
- **Ziel-Node-RAM** für HA-Migration gegenrechnen (pve02-RAM-Limit-Memory-Note).
- **Optional Phase 2** (Komfort, NICHT zum Start): PG-Streaming-Warm-Standby auf 2. Node für RPO≈0 +
  Schutz gegen Daten-Level-Schäden (versehentliches DROP). Erst nach stabilem Single-VM-HA.

## 6. Was wegfällt (der Gewinn)
etcd-5-Quorum-Pflege · Patroni-Failover-Tuning (ttl/loop_wait) · reinit-EBUSY-Prozeduren ·
Timeline-Divergenz-Recovery · WAL-Slot-Bloat · HAProxy-Failover-Churn + 500-Kaskaden ·
Custom-Image-Zwang (pgvector `-march`) · ~2/3 PG-RAM + etcd-RAM → Headroom auf den engen Nodes.

## 7. Bewusst akzeptierter Trade-off
~3–5 min RTO bei Host-Ausfall (statt theoretischer ~30s). Bei Nicht-Finanz-Workloads (Paperless,
Authentik, Reisekosten, Immich) und „RTO von Minuten akzeptabel" der richtige Tausch. RPO bleibt ≈0
für bestätigte Transaktionen. **Backups/PITR sind Pflicht — die hat Patroni nie ersetzt.**

---
*Quellen: 3 Agenten-Reports (DBA/Architektur/Research) dieser Session; Live-Daten von infra-2 (Leader)
2026-06-14. Verwandt: [[project_patroni_postgres_ha]], [[feedback_patroni_divergence_oom]],
[[project_pve_memory_topology]].*
