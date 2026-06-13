# RCA + Remediation: Corosync-Flapping → CephFS-Stale-Kaskade (2026-06-13)

> Status: **RCA abgeschlossen, Remediation gated** (User-Entscheidung „Erst Plan, dann
> entscheiden"). Sofort-Fix `recover_session=clean` ist bereits on-disk/IaC ausgerollt
> (Live-Aktivierung im nächsten Reboot/Wartungsfenster). **Corosync-Layer noch NICHT angefasst.**

## 1. Symptomkette (beobachtet)

```
Corosync link down (1GbE überbucht)
  → TOTEM token timeout (~3.6s) → neue Membership (Members left/joined)
  → Ceph-MON Re-Election
  → MDS session_timeout → Blocklist der CephFS-Kernel-Clients
  → recover_session=no ⇒ Mount bleibt DAUERHAFT stale (EACCES als root)
  → App-Ausfall (Open Archiver, reisekosten, Authentik, Paperless-OIDC …)
```

Wiederkehrende User-Incidents („✅ RESOLVED Open Archiver unreachable", reisekosten down,
Authentik-504) waren alle **Folgen** dieser einen Wurzel.

## 2. Root Cause (verifiziert, read-only)

**Alle 3 PVE-Nodes haben physisch nur EINE 1GbE-NIC** (User-bestätigt 2026-06-13):

| Node  | NIC      | Speed   |
|-------|----------|---------|
| pve01 | eno1     | 1000 Mb/s |
| pve02 | enp2s0   | 1000 Mb/s |
| pve03 | eno1     | 1000 Mb/s (wlp1s0 = WLAN, kein Carrier) |

Über dieses **eine** `vmbr0`-Bridge-Interface laufen **gleichzeitig**:
- **corosync ring0** (VLAN2, 192.168.2.x) — latenz-kritisch, Token muss in ~3 s ankommen
- **Ceph public+cluster** (VLAN12, 192.168.12.x = nur ein **VLAN-Tag auf demselben eno1**,
  *nicht* echtes 10GbE — die frühere Annahme „Ceph auf 10GbE" ist für diese Hardware falsch)
- **vzdump → PBS** (Backup-Bursts)
- **sämtlicher VM/LXC-Traffic** (fwpr*/veth* Bridges)

→ Sobald Ceph rebalanced/recovered **oder** ein Backup läuft, sättigt der 1GbE-Link;
corosync-Token verspätet sich über das Timeout → `link down` → Re-Membership → Kaskade.

**Flap-Rate (letzte 24 h, live):** pve01 **147**, pve02 **89**, pve03 **81** Events.
Das Flapping ist **aktuell und permanent**, nicht historisch.

### 2a. Verstärker (kein Disk-Defekt!)
BlueStore slow-ops auf osd.1 (pve03) / osd.2 (pve01) → SMART-Check beider NVMe:
`SMART overall-health: PASSED`, Available Spare 100 %, 5 % used = **gesund**. Slow-ops sind
**Last-/Netz-induziert** (1GbE-Sättigung), kein Hardware-Tausch nötig.

## 3. Zwei latente Landminen (separat, beim Graben gefunden)

### 3a. 🔴 Corosync-Config-Divergenz (HIGH — „läuft nur per Glück")
- **Aktiv laufend** `/etc/corosync/corosync.conf` (lokal, alle 3 Nodes): **config_version 9**,
  korrekte IPs `.10/.11/.12`.
- **pmxcfs-Master** `/etc/pve/corosync.conf`: **config_version 8**, **falsche** IPs
  `pve02=192.168.2.15`, `pve03=192.168.2.16` (Phantom — existieren auf keinem Node).

Fingerabdruck einer **Notfall-Recovery**: pmxcfs wurde mit falschen IPs editiert → Cluster brach
→ lokale Confs wurden per PVE-Notfallprozedur gefixt (v9, korrekte IPs) → **pmxcfs-Master nie
korrigiert**. Solange pmxcfs-Version (8) < lokal (9), überschreibt es nicht. Aber **jede** normale
Cluster-Änderung (GUI, Node-Add) oder ein pmxcfs-Versions-Bump rollt `.15/.16` aus → **sofortiger
Cluster-Split**. Muss gefixt werden, **unabhängig** vom Flapping.

### 3b. ⚠️ Watchdog-Cron Anti-Pattern
`/etc/cron.d/corosync-watchdog` (alle 3 Nodes, seit 2026-03-05):
```
*/5 * * * * root systemctl is-active --quiet corosync || (systemctl start corosync && logger ...)
```
Probleme: (1) maskiert echte corosync-Fehler statt sie sichtbar zu machen; (2) ein Blind-Restart
unter Flapping verschlimmert die Membership-Churn; (3) **gefährlich in Kombination mit 3a** — ein
Watchdog-Restart nach pmxcfs-Sync würde corosync auf den FALSCHEN `.15/.16` hochziehen. corosync
hat bereits systemd `Restart=on-failure` → der Cron ist überflüssig und riskant. **Entfernen.**

## 4. Remediation-Optionen (single-1GbE-Realität)

Da **kein** zweiter physischer Link existiert, ist ein dedizierter/redundanter Ring ohne neue
Hardware unmöglich. Die realistischen Hebel:

| # | Hebel | Wirkung | Risiko | Repo |
|---|-------|---------|--------|------|
| A | **`recover_session=clean`** (CephFS-Mounts) | bricht die Kaskade *downstream*: blocklisteter Client reconnected selbst statt stale | niedrig | ansible ✅ **on-disk/IaC done**, live = Wartungsfenster |
| B | **Corosync token-Timeout erhöhen** (`token: 3000→10000`, `token_retransmits_before_loss_const`) | corosync deklariert bei transienter 1GbE-Sättigung **kein** link-down mehr → Flaps ↓ drastisch | niedrig (trägeres echtes Failover, für 3-Node-LAN ok) | pmxcfs corosync.conf |
| C | **Ceph Recovery/Backfill drosseln** (`osd_max_backfills=1`, `osd_recovery_max_active=1`, `osd_recovery_op_priority=1`) | reduziert den größten bursty 1GbE-Konsumenten | niedrig (Recovery dauert länger) | ceph config |
| D | **QoS/`tc` auf eno1** — corosync UDP 5405 strikt priorisieren | echte Priorisierung ohne HW, „virtueller dedizierter Ring" | mittel (tc auf Bridge-Member fragil) | ansible |
| E | **Config-Divergenz fixen** (3a) — pmxcfs corosync.conf auf korrekte IPs + version ≥10 | beseitigt die Cluster-Split-Zeitbombe | mittel (corosync.conf-Edit, sorgfältig) | pmxcfs |
| F | **Watchdog-Cron entfernen** (3b) | beseitigt riskantes Blind-Restart-Pattern | niedrig | ansible/host |
| G | **vzdump bwlimit** zusätzlich zur Kadenz (6h schon done) | Backup-Burst auf dem 1GbE deckeln | niedrig | jobs.cfg / vzdump.conf |

### Empfohlene Reihenfolge (sichere Hebel zuerst)
1. **A** (schon staged) live ziehen im nächsten Wartungsfenster — Kaskaden-Stopper.
2. **B + C** zusammen: corosync toleranter **und** weniger Ceph-Burst → größter Flap-Rückgang
   ohne Hardware. Beide reversibel.
3. **F** (Watchdog-Cron weg) — schnell, risikoarm.
4. **E** (Divergenz-Fix) — eigenständige Sicherheits-Pflicht, sorgfältig (lokale Confs sind die
   gute Quelle; pmxcfs auf `.10/.11/.12` + version 10 angleichen).
5. **D / G** optional, falls B+C nicht reichen.

### Die echte Langfrist-Lösung
Eine **zweite physische NIC pro Node** (oder USB-2.5GbE) für einen **dedizierten corosync-Ring** —
das ist die einzige strukturelle Trennung von Cluster-Heartbeat und Bulk-Storage. Bis dahin sind
B+C+A die belastbare Brücke.

## 5. Verifikation (nach Apply)
- `corosync-cfgtool -s` / journal: Flap-Events/24h → gegen 0.
- `ceph -s`: HEALTH_OK, keine slow-ops unter Backup-Last.
- CephFS-Mounts überleben eine MON-Re-Election ohne stale (recover_session greift nach Remount).
- `diff <(grep config_version /etc/corosync/corosync.conf) <(grep config_version /etc/pve/corosync.conf)`
  → identisch (nach E).
- Self-Heal-Detektor-Log: keine `stale-cephfs`-Signatur mehr.

## 6. Ausgeführt am 2026-06-13 (User-Freigabe B + C + E)

| Hebel | Aktion | Verifiziert |
|-------|--------|-------------|
| **A** `recover_session=clean` | ansible-Template + on-disk-Unit aller 3 Nodes | ✅ on-disk/IaC; **live = nächster Reboot/Wartungsfenster** (Remount nötig) |
| **E** Config-Divergenz | `/etc/pve/corosync.conf` neu geschrieben aus laufender guter Config: v9→**v10**, korrekte IPs `.10/.11/.12`, Phantom `.15/.16` entfernt | ✅ pmxcfs==lokal v10 auf allen 3, Phantom-count 0, corosync `Config reload requested` ohne Fehler |
| **B** Token-Tuning | `token: 10000` in `totem` (gleicher Write wie E) | ✅ Runtime-Token **3650→10650 ms** (10000 + 650 Koeffizient) auf allen 3, **Quorum nie verloren**, kein Restart |
| **C** Ceph-Drosselung | `ceph config set osd osd_mclock_profile high_client_ops` (squid nutzt mclock → Legacy-`osd_max_backfills` wird ignoriert) | ✅ cluster-weit + per-OSD `high_client_ops`, kein Recovery-Sturm |

**Backups vor dem Eingriff:** `/root/corosync.conf.{local,pmxcfs}.bak-20260613-2018` auf allen 3 Nodes.

### Nicht ausgeführt (bewusst)
- **F** Watchdog-Cron-Entfernung: User hat F nicht gewählt → `/etc/cron.d/corosync-watchdog` bleibt
  (durch E-Fix jetzt ungefährlicher, da pmxcfs korrekte IPs hat). Empfehlung steht weiter.
- **A live ziehen:** braucht Remount + Restart der CephFS-Bind-Container → Wartungsfenster.

### Follow-up / Monitoring
- **Flap-Rate über 24–48 h beobachten** (`journalctl -u corosync | grep 'link.*down'`) → sollte mit
  token=10650 + gedrosseltem Ceph drastisch fallen (Baseline 147/89/81 in 24 h).
- Sticky `BLUESTORE_SLOW_OP` auf osd.1/osd.2 ggf. via `systemctl restart ceph-osd@N` (noout-geschützt)
  clearen — separat, kein Disk-Tausch (NVMe SMART PASSED).
- Bei Bedarf eskalieren: **D** (`tc`-QoS auf eno1) oder **G** (vzdump bwlimit).
- Strukturell langfristig: 2. NIC pro Node (oder USB-2.5GbE) für dedizierten corosync-Ring.

> Uncommitted: dieser Doc + ansible `templates/ceph/mnt-cephfs.mount.j2`. Commit/Push auf Anfrage.
