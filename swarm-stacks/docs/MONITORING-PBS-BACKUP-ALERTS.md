# PBS Backup-Age Alerts — Namespace-basierte Exclusion

**Status:** aktiv seit Commit `dc33e18` (2026-04-19)
**Scope:** Grafana Alerting (VictoriaMetrics-Backend), PBS-Snapshot-Metriken
**Betroffene Regeln:** `pbs-backup-stale` (48h), `pbs-backup-missed-daily` (26h)

---

## 1. Problem

Auf dem Proxmox Backup Server (`pbs.hornung-bn.de`) existiert der Namespace
`Backup` auf Datastore `pbsdata` als **Archiv** für retirte VMs. Beispiel:
VM 101 (HAOS) wurde ausgemustert, die letzten 13 Snapshots liegen im Namespace
`Backup` und warten auf das Pruning.

Da retirte VMs per Definition keine neuen Snapshots mehr bekommen, feuert die
Regel `pbs-backup-stale` dauerhaft:

> 🔴 ALARM Backup older than 48h
> Backup >48h: HAOS (101)

Frühere Fixes haben versucht, `vm_name` oder `vm_id` im Selector zu excludieren
(siehe `f3474f0`, `681f64b`), was aber brüchig ist: Sobald die VM-ID
wiederverwendet wird, muss der Filter manuell zurückgenommen werden — was in
der Praxis vergessen wird.

---

## 2. Design

### Kernidee
Der Filter hängt an einer **Eigenschaft des PBS-Datastore-Layouts** (Namespace),
nicht an der VM-Identität. Damit sind Archiv und Produktion logisch getrennt.

### Selector
Beide Alert-Regeln in `stacks/monitoring/alerting/alert-rules.yml` enthalten
im PromQL-Selector jetzt:

```promql
pbs_snapshot_vm_last_timestamp{
  namespace!="Backup",
  vm_name!~"haos-2025-10|haos12.2|seaweed3|swarmpit|ubuntusetup|VM 999|dock02|ARCHIVED.*|infisical-bootstrap",
  vm_id!~"frigate-recordings-archive|swarm-backup-client|9000"
}
```

### Tradeoffs
| Variante | Vorteil | Nachteil |
|---|---|---|
| `vm_id!="101"` | einfach | muss bei VM-ID-Recycling manuell entfernt werden |
| `namespace=""` (positiv) | explizit | Silent-Failure bei fehlendem Label (Exporter-Upgrade) |
| **`namespace!="Backup"`** | robust, Archiv-agnostisch | matcht auch Series ohne Label → Filter inaktiv bei Exporter-Regression, aber **kein Silent-Failure** |

Gewählt: **`namespace!="Backup"`** — robuster gegen Exporter-Upgrades und
automatisches Re-Enable bei VM-ID-Recycling.

---

## 3. Voraussetzungen

1. **PBS-Exporter mit Namespace-Label**
   `ghcr.io/natrontech/pbs-exporter:v0.4.0` oder neuer (aktuell deployed: `v0.8.0`).
   Definiert in `stacks/monitoring/monitoring-stack.yml`, Service `pbs-exporter`.

2. **PBS-Namespace `Backup` existiert**
   Prüfen:
   ```bash
   ssh root@pbs.hornung-bn.de \
     'curl -sk -H "Authorization: PBSAPIToken=<token>" \
      https://localhost:8007/api2/json/admin/datastore/pbsdata/namespace'
   ```
   Erwartet:
   ```json
   {"data":[{"ns":""},{"ns":"Backup"}]}
   ```

3. **VictoriaMetrics/Grafana-Alerting läuft**
   Stack: `monitoring` (via SSH-Deploy Pipeline in `webhooks.conf`).
   Alert-Datasource UID: `victoriametrics`.

---

## 4. Reproduktion auf anderen Maschinen

### 4.1 PBS-Namespace anlegen (falls neu)

```bash
ssh root@<pbs-host> \
  "proxmox-backup-client namespace create <datastore>/<ns-name> \
     --repository <token-user>@pbs@localhost:<datastore>"
```

Oder via PBS-Web-UI: *Datastore → Namespaces → Create*.

### 4.2 Retirte VMs in den Namespace verschieben

Alte Snapshots lassen sich nicht umhängen — stattdessen:
- **Option A:** Letzten Backup-Job so konfigurieren, dass Zielnamespace `Backup`
  ist (in Proxmox VE: *Datacenter → Backup → Edit Job → PBS Namespace*).
- **Option B:** Snapshots per `proxmox-backup-client snapshot forget` aus Root-NS
  löschen, nachdem ein Archiv-Snapshot im neuen NS erstellt wurde.

### 4.3 Exporter-Label verifizieren

VictoriaMetrics-Query (Grafana Explore → Datasource `VictoriaMetrics`):

```promql
pbs_snapshot_vm_last_timestamp{vm_id="101"}
```

Erwartete Labels in der Antwort:
```
{datastore="pbsdata", instance="pbs", job="pbs-exporter",
 namespace="Backup", vm_id="101", vm_name="HAOS"}
```

Wenn `namespace` fehlt → Exporter-Version zu alt (Minimum v0.4.0).

### 4.4 Alert-Regeln patchen

In `stacks/monitoring/alerting/alert-rules.yml` den Selector in **beiden** Regeln
(`pbs-backup-stale`, `pbs-backup-missed-daily`) ergänzen:

```yaml
expr: |
  (time() - pbs_snapshot_vm_last_timestamp{namespace!="Backup", …}) > 172800
```

(`172800` = 48h, `93600` = 26h).

### 4.5 Deploy

Content-Hash-Pipeline in diesem Repo:

```bash
git add stacks/monitoring/alerting/alert-rules.yml
git commit -m "fix(alerting): Exclude PBS Archive-NS 'Backup' …"
git push
```

GitHub Actions triggert SSH-Deploy zum Swarm-Manager. Der Hash der geänderten
Datei wird exportiert, Docker Config heißt danach
`alerting_rules_<new-hash>`, `docker stack deploy --prune` lädt sie in Grafana.

**Kein** manuelles `docker stack rm` nötig (Content-Hash-Naming).

---

## 5. Verifikation nach Deploy

### 5.1 Grafana Alerting UI
- https://grafana.hornung-bn.de → *Alerting → Alert Rules → Backups*
- `pbs-backup-stale` und `pbs-backup-missed-daily` müssen **Normal** zeigen
- Keine aktiven Instanzen für `vm_id=101`

### 5.2 PromQL-Check (manuell)
```promql
# Welche Series sind durch den Filter ausgeschlossen?
pbs_snapshot_vm_last_timestamp{namespace="Backup"}

# Welche Series werden noch alertiert?
(time() - pbs_snapshot_vm_last_timestamp{namespace!="Backup"}) > 172800
```

### 5.3 Telegram
- Der nächste 🔴 ALARM für `HAOS (101)` muss **ausbleiben**
- Andere Backup-Alerts (z.B. produktive VMs) müssen weiter funktionieren

---

## 6. Re-Aktivierung bei VM-ID-Recycling

**Automatisch!** Szenario: Du legst eine neue VM mit ID 101 an (z.B.
`k3s-master-neu`). Backup-Job schreibt in Root-Namespace (`namespace=""`):

- Die neue Series `pbs_snapshot_vm_last_timestamp{vm_id="101",namespace=""}`
  hat `namespace != "Backup"` → **Filter matcht**, Alerts aktiv.
- Die alten Archiv-Series mit `namespace="Backup"` bleiben weiter stumm.

Kein Code-Change, kein Revert, kein Deploy nötig.

---

## 7. Troubleshooting

### Alert bleibt stumm, obwohl VM produktiv ist
→ Prüfen, ob der Backup-Job in den richtigen Namespace schreibt:
```bash
ssh root@<pbs> 'curl -sk -H "Authorization: PBSAPIToken=…" \
  https://localhost:8007/api2/json/admin/datastore/pbsdata/snapshots?backup-type=vm&backup-id=<id>'
```
Jeder Eintrag hat ein `ns`-Feld. Wenn `ns="Backup"` und VM produktiv ist:
Job umkonfigurieren oder Filter-Wert anpassen.

### Alert feuert weiter für HAOS (101)
→ VictoriaMetrics cached Metriken. Nach Deploy 5-10 min warten, dann:
- Grafana: *Alerting → Alert Rules → Pause Evaluation / Resume* (erzwingt Re-Eval)
- Falls Label `namespace` bei `vm_id="101"` fehlt: Exporter-Upgrade nötig

### Label `namespace` nicht vorhanden
→ `natrontech/pbs-exporter` Version prüfen:
```bash
docker service inspect monitoring_pbs-exporter \
  --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'
```
Minimum: `v0.4.0`. Aktuell im Repo: `v0.8.0`.

### Push läuft, aber Alerts bleiben alt
→ GitHub Actions Run prüfen: https://github.com/thorstenhornung1/swarm-stacks/actions
- SSH-Deploy darf nicht fehlschlagen (Tailscale, SSH-Key korrekt?)
- Content-Hash muss sich geändert haben (sonst lädt Docker Config nicht neu)

### RESOLVED-Telegram zeigt Template-Literale (`{{ $labels.vm_name }}`)
→ **Bekanntes Grafana-Verhalten**, **bewusst nicht gefixt**.

**Wann es auftritt:** Eine Series verschwindet komplett aus dem Query-Result
(z.B. Filter-Änderung wie `namespace!="Backup"`, VM-Löschung, Scrape-Target
offline) — statt dass der Wert nur unter den Threshold fällt. Grafana sendet
RESOLVED, kann aber zur Render-Zeit keine `$labels` mehr befüllen → Template-
Variable bleibt im Notifier-Payload als Literal stehen.

**Warum kein Fix:** Der naheliegende Workaround "bei RESOLVED die Annotation
weglassen" wurde getestet (Commit `91b2a9f`) und in `7019e8a` **wieder
zurückgenommen**. Grund: Im **Normalfall** (Value unterschreitet Threshold)
ist die Series weiterhin da, `$labels` werden korrekt gefüllt, und die
RESOLVED-Nachricht liefert die nützliche Info *welche* Instance sich erholt
hat (z.B. "✅ RESOLVED Daily backup missed — Backup >26h: dns2 (4101)"). Das
generelle Verstummen der Annotation nur wegen des Sonderfalls "Series
disappeared" würde jedes Resolve auf den bloßen `alertname` reduzieren —
falscher Tradeoff.

**Akzeptierte Konsequenz:** Bei Filter-Deploys (wie diesem PBS-Namespace-Fix)
oder VM-Decommissions kann die einmalige RESOLVED-Benachrichtigung ein
Template-Literal enthalten. Das ist kosmetisch, tritt einmalig beim Deploy
auf und betrifft keine Folge-Alerts.

**Wenn es stört:** Option wäre `$labels` in allen 15 Alert-Rule-Annotations
mit `{{ with $labels.xxx }}{{ . }}{{ else }}fallback{{ end }}` defensiv zu
machen. Aufwand: hoch, Nutzen: minimal. Bisher nicht umgesetzt.

---

## 8. Verweise

- **Alert-Rules:** `stacks/monitoring/alerting/alert-rules.yml` (uids
  `pbs-backup-stale`, `pbs-backup-missed-daily`)
- **PBS-Exporter Service:** `stacks/monitoring/monitoring-stack.yml` (Zeilen
  292–321)
- **Scrape-Job:** `stacks/monitoring/prometheus-scrape.yml` (`pbs-exporter`)
- **Deploy-Pipeline:** `.github/workflows/deploy-stacks.yml` + `webhooks.conf`
- **Exporter-Upstream:** https://github.com/natrontech/pbs-exporter (Labels:
  `datastore`, `namespace`, `vm_id`, `vm_name`)
- **PBS-Namespace-Doku:** https://pbs.proxmox.com/docs/storage.html#backup-namespaces

## 9. Änderungshistorie

| Commit | Datum | Änderung |
|---|---|---|
| `f3474f0` | 2025-11 | Erste HAOS-Exclusion via `vm_name!~"HAOS"` (brüchig) |
| `681f64b` | 2025-12 | Revert + PBS-Retention-Erhöhung als Workaround |
| `dc33e18` | 2026-04-19 | **Namespace-basierter Filter** (diese Doku) |
