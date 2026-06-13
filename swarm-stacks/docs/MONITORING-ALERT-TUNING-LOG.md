# Monitoring Alert-Tuning — Arbeits-Log

> Systematisches Logbuch zur Sanierung des Grafana-Alert-Flappings/-Spams.
> Angelegt 2026-06-13. Bezug: Plan „Grafana Alert-Flapping & Spam".
> Schwesterdok: `docs/MONITORING-PBS-BACKUP-ALERTS.md`.

Stack: Grafana 11.4.0 Unified Alerting · Datasource VictoriaMetrics · Telegram-Contact-Points.
Provisioning: `stacks/monitoring/alerting/{contact-points,notification-policies,alert-rules,mute-times}.yml`
als Docker-`configs` (Content-Hash) → Änderung ⇒ Stack-Redeploy via GitOps `ssh-deploy`.

---

## 1. Baseline (Flap-Frequenz)

**Status: OFFEN — Grounding blockiert.**

Geplant war, die echte Flap-Frequenz pro `rule_uid` aus Loki (Grafana-State-Transitions)
zu ziehen. **Loki ist leer** (siehe Befund B-07): kein Grounding über Logs möglich.

Offene Grounding-Optionen (Entscheidung User):
- [ ] SSH-Freigabe für einmaliges `docker service logs <grafana>` auf Swarm-Manager (192.168.4.40)
- [ ] Grafana-API-Token / Admin-Passwort → Alert-State-History via API
- [ ] Config-basiert weiterarbeiten (statische Analyse, siehe Backlog) ohne Ist-Frequenz

| rule_uid | Transitions/24h | Quelle | Datum |
|---|---|---|---|
| _noch nicht erhoben_ | | | |

---

## 2. Befund-Backlog

Status: `offen` · `getunt` (deployt, Wirkung ausstehend) · `beobachten` · `erledigt`

| ID | Komponente / rule_uid | Symptom | Root-Cause | Geplanter Fix | Self-Heal? | Status |
|----|----|----|----|----|----|----|
| B-01 | `swarm-node-oom-kill` (:302), `frigate-lxc-oom` (:1411) | feuert sofort & ggf. wiederholt bei Memory-Druck | `for: 0s`, kein Entprellen | `keep_firing_for: 30m` | nein (OOM = echt) | offen |
| B-02 | `ceph-health-error` (:351) | flappt bei Rebalance/transienten OSD-Stalls | Enum-Metrik (`>=2`) + nur `for: 2m` | `for: 5m` | nein | offen |
| B-03 | `frigate-camera-no-detection` (:1370) | FPS==0 bei RTSP-/Netz-Stottern | Roh-FPS am Threshold + `for: 5m` | `avg_over_time(...[5m])` oder `for: 10m` | nein | offen |
| B-04 | `patroni-no-leader` (:516), `etcd-no-leader` (:828) | flappt bei Leader-Election/Netz-Partition | Konsens-Metrik + nur `for: 2m` | `for: 3–5m` | bedingt | offen |
| B-05 | `patroni-replica-not-streaming` (:651) | oszilliert um 16 MB WAL-Gap | Roh-Gap + `for: 3m` | `for: 5m` oder `min_over_time` | nein | offen |
| B-06 | `vm-memory-high` (:1237) | GC-Zyklen kreuzen 1,5 GB-Threshold | Instant-Memory am Rand | `avg_over_time(...[5m])` | nein | offen |
| B-07 | **Loki** (loki.hornung-bn.de:3100, v2.9.2) | **0 streams/bytes über 30 Tage** — Grafana-Loki-Datasource zeigt auf leeres Loki | Docker-Container-Log-Shipping landet nicht in diesem Loki (nur LXC-rsyslog→:1514 laut Memory, schlägt hier nicht durch) | Log-Pipeline prüfen (Promtail/Alloy/Logging-Driver). **Observability-Lücke**: Vorfälle nicht nachträglich über Logs analysierbar | n/a | offen |
| B-08 | Contact-Points (alle) | jeder Flap = 2 Telegrams (ALARM+RESOLVED) | `disableResolveMessage: false` überall | warning/info → `true`; critical behält Entwarnung | n/a | **getunt** (Phase 1) |
| B-09 | Routing critical | enger Wiederhol-Takt | `group_interval 2m` + `repeat_interval 1h` | 5m / 4h | n/a | **getunt** (Phase 1) |
| B-10 | Routing warning/info | Pro-Event-Spam | keine Bündelung / kein Digest | mute außerhalb 08:00–08:15 / 18:00–18:15 + `group_by [grafana_folder]` | n/a | **getunt** (Phase 1) |
| B-11 | `pbs-exporter` scrape | false „target down", Datenlücken | `scrape_timeout 10s` ≪ `interval 120s`, schwere API-Queries | job-lokal `scrape_timeout: 30s` | n/a | **getunt** (Phase 3) |
| B-12 | `homeassistant` scrape | flappt bei langsamer TLS/UI-Antwort | `scrape_timeout 20s` / `interval 30s` (66 %) | `scrape_timeout: 25s` | n/a | **getunt** (Phase 3) |
| B-13 | `blackbox-tika` scrape | stille 60 s-Lücken nach Reschedule | `scrape_interval 60s` auf interner Service-Discovery | `30s` | ggf. (stale VIP) | **getunt** (Phase 3) |
| B-14 | Transiente Infra-Flaps | „Flapping" das echt ist & wiederkehrt | stale CephFS-Mount / stale Service-VIP / totes Node-Mesh | Self-Heal-Detektor (Phase 4) | **ja** | offen |

**Bewusst NICHT angefasst** (bereits gut geglättet): PBS-/TLS-/Backup-/Disk-Zeitmetriken,
`ceph-health-warning` (15m `min_over_time`), `frigate-down`/`paperless-down`/`openarchiver-down`
(`min_over_time[5m]` + `for: 5m`).

---

## 3. Change-Historie

### 2026-06-13 — Phase 1: Sofort-Spam-Dämpfung (Routing + Resolved + Digest)
**Dateien:** `alerting/notification-policies.yml`, `alerting/contact-points.yml`,
neu `alerting/mute-times.yml`, `monitoring-stack.yml` (Config-Def + Mount).

| Was | Alt | Neu | Erwartete Wirkung |
|---|---|---|---|
| Resolved warning/info (`telegram-default`) | `false` | `true` | Flap-Verdopplung entfällt für nicht-kritische Alerts |
| Resolved critical (`telegram-critical`) | `false` | `false` (unverändert) | Entwarnung bleibt für echte Notlagen |
| Digest-Fenster warning/info | — | `mute_time_intervals: [outside-digest-windows]` (08:00–08:15 / 18:00–18:15) | warning/info nur 2×/Tag statt pro Event |
| Bündelung warning/info | `group_by [grafana_folder, alertname]` (Root) | `group_by [grafana_folder]` | ein Telegram je Ordner/Fenster |
| critical `repeat_interval` | `1h` | `4h` | Dauer-Alarm wiederholt nicht stündlich |
| critical `group_interval` | `2m` | `5m` | weniger Re-Grouping-Pings |

**Gemessene Wirkung (nach Deploy + 48 h):** _ausstehend_

### 2026-06-13 — Phase 3: Scrape/Probe-Timeouts
**Datei:** `prometheus-scrape.yml`.

| Job | Alt | Neu | Grund |
|---|---|---|---|
| `pbs-exporter` | timeout 10s (global), interval 120s | `scrape_timeout: 30s` | schwere PBS-API-Queries timeouten sonst → false pbs-down |
| `homeassistant` | timeout 20s / interval 30s | `scrape_timeout: 25s` | 66 %-Auslastung riss bei langsamer Antwort `up=0` |
| `blackbox-tika` | interval 60s | `scrape_interval: 30s` | schnellere Erkennung verwaister Service-Discovery |

**Gemessene Wirkung:** _ausstehend_ (in VM prüfen: keine Scrape-Lücken mehr in `up{job=...}`).

**Deploy-Hinweis:** `MUTE_TIMES_HASH` wird vom Deploy-Workflow automatisch aus `mute-times.yml`
berechnet (globstar-Scan + Basename→HASH). Vor erstem Push verifizieren, dass ein Change im
`alerting/`-Unterordner den GitOps-Run auslöst (`webhooks.conf` triggert auf
`monitoring-stack.yml`); sonst Redeploy durch Mit-Anfassen der `monitoring-stack.yml` erzwingen
(hier ohnehin geändert ✓).

---

## 4. Self-Heal-Logbuch

**Status: noch nicht implementiert (Phase 4).** Detektor läuft erst log-only („WOULD HEAL").

| Datum | Signatur | Node/Service | Erkannt | Aktion (geplant) | Scharf? |
|---|---|---|---|---|---|
| _–_ | | | | | nein |

Bekannte Signaturen & Fixes (Quelle: Projekt-Memory):
- stale CephFS-Mount (`permission denied` auf `/mnt/cephfs`-Root als root) → `systemctl restart mnt-cephfs.mount` + `docker service update --force <svc>`
- stale Service-Discovery (`ENOTFOUND` trotz gültiger VIP) → `docker service update --force <svc>`
- totes Node-Mesh (mehrere tote VIPs auf einem Node) → `systemctl restart docker` auf dem Node
