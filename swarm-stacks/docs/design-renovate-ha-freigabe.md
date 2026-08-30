# Design: Renovate-Update-Freigabe über Home Assistant

**Status:** Entwurf / Recherche-Ergebnis — es wurde NICHTS deployt, kein Token erstellt, keine Produktionssysteme verändert.
**Datum:** 2026-08-30
**Vision des Betreibers:** „n8n → Repair-Issue nach Home Assistant → dort Freigabe" — Renovate-PRs im Repo `thorstenhornung1/swarm-stacks` sollen als quittierbare Meldungen in HA erscheinen; die Freigabe in HA merged den PR, GitOps deployt automatisch.

---

## 0. TL;DR — Empfehlung

**Echte HA-„Repairs" sind von extern nicht erzeugbar** (bestätigt, Details in §1). Die Vision wird aber besser — nicht schlechter — durch **MQTT-Discovery-Update-Entities** erfüllt: Jeder Renovate-PR erscheint in HA als natives **Update-Objekt** („n8n 2.36.8 → 2.37.4", mit Release-Link und **Installieren**-Button). Der Install-Button ist die Freigabe: HA publiziert per MQTT an n8n, n8n merged den PR (Squash, SHA-abgesichert), `deploy-stacks.yml` deployt, n8n meldet Fortschritt und Ergebnis zurück in dieselbe Entity. Semantisch ist das sogar treffender als ein „Repair": Ein anstehendes Update ist kein Defekt — HA hat dafür eine eigene, native UX (Einstellungen → Updates), inklusive „Überspringen" als Quittierung.

- **Backbone:** n8n-**Reconciler per Polling** (alle 15 min gegen die GitHub-API) statt Webhook — idempotent, selbstheilend nach n8n-/HA-Ausfällen. GitHub-Webhook nur als optionale Latenz-Optimierung (mit HMAC-Prüfung).
- **Kein HA-Token in n8n, kein n8n-Zugriff für HA** — die gesamte Kopplung läuft über den vorhandenen MQTT-Broker (192.168.2.5:1883, von Frigate bereits genutzt) mit eigenem Broker-User + ACL.
- **Nur `minor`/`patch`/`digest`-PRs** laufen über diesen Weg. Majors bleiben hinter dem bereits konfigurierten Renovate-Dashboard-Approval (verifiziert in `.github/renovate.json5`) und werden zusätzlich im n8n-Filter ausgeschlossen.

---

## 1. Kernfrage: Können externe Systeme HA-Repairs erzeugen?

**Kurzantwort: Nein — die Vermutung des Betreibers ist korrekt.**

### 1.1 Befund (Stand 2026-08-30)

| Weg | Erzeugen? | Was geht stattdessen |
|---|---|---|
| **REST API** (`/api/...`) | ❌ keine Route zum Erzeugen | `POST /api/services/<domain>/<service>` kann nur *vorhandene* Actions aufrufen |
| **WebSocket API** | ❌ kein `create`-Kommando | `repairs/list_issues` (lesen), `repairs/ignore_issue` (quittieren/ignorieren); Fix-Flows werden über `POST /api/repairs/issues/fix` gestartet — aber nur für Issues, die eine Integration mit `repairs.py`-Plattform registriert hat |
| **Python in-process** | ✅ `ir.async_create_issue(hass, domain, issue_id, ...)` aus `homeassistant.helpers.issue_registry` | Der einzige offizielle Erzeugungsweg — nur Integrationen (und HA Core selbst) |
| **AppDaemon** | ❌ | Läuft **out-of-process** und spricht nur die (create-lose) API — kann *keine* Repairs erzeugen. Häufiges Missverständnis. |
| **pyscript** (HACS) | ⚠️ technisch ja | Läuft in-process; mit `hass_is_global: true` erreichbar. Ungestützter Hack, bricht gern bei HA-Upgrades — nicht empfohlen |
| **Spook** (HACS, frenck) | ✅ via Action `repairs.create` | Spook registriert eine Action, die extern per REST aufrufbar ist (`POST /api/services/repairs/create`). **Aber:** die erzeugten Issues sind **reine Anzeige** — es gibt keinen Fix-Flow und keinen Rückkanal. Aktiv gepflegt (v5.2.0 vom 30.08.2026). Schema: `title` (Pflicht), `description` (Pflicht, Markdown-fähig), `issue_id` (optional, gleiche ID = Update), `domain` (optional), `severity` (`warning`/`error`/`critical`), `persistent` (bool). `repairs.remove` löscht nur Spook-eigene Issues. |

Quellen: [HA Developer Docs — Repairs](https://developers.home-assistant.io/docs/core/platform/repairs/), [HA Community: How to access repairs via API](https://community.home-assistant.io/t/how-to-access-repairs-issues-issue-registry-via-api/757734), [Spook — Repairs](https://spook.boo/repairs/), [Spook Releases](https://github.com/frenck/spook/releases), [HA WebSocket API](https://developers.home-assistant.io/docs/api/websocket/).

### 1.2 Konsequenz für die Vision

Selbst wenn man Repairs erzeugen kann (Spook / eigene Custom Integration): **Repairs sind als Freigabe-UI ungeeignet**, denn

1. Ohne eigene `repairs.py`-Fix-Flow-Implementierung gibt es **keinen Button, der etwas auslöst** — nur „Ignorieren".
2. Ein eigener Fix-Flow bedeutet eine **vollwertige Custom Integration** (Python, `config_flow`, HA-Release-Tretmühle) für einen einzigen Zweck.
3. Repairs sind unter *Einstellungen → System → Reparaturen* **nur für Admins** sichtbar und für „Ein Update wartet" semantisch falsch (Repairs = Defekte/Handlungsbedarf wegen Problemen).

**Was der Vision am nächsten kommt und nativ existiert:** die **Update-Entity**. HA rendert Update-Entities prominent (Einstellungen-Seite zeigt „Updates"-Sektion mit Badge, eigene Karte fürs Dashboard), mit Titel, alt→neu, Release-Notes-Link, **Installieren**- und **Überspringen**-Button. Genau das ist „quittierbare Meldung + Freigabe". Und via **MQTT Discovery** kann ein externes System (n8n) solche Entities ohne jede HA-seitige Codezeile erzeugen, aktualisieren und entfernen.

---

## 2. Alternativen-Vergleich

| Kriterium | (a) Custom Integration / Spook / pyscript | (b) Actionable Notifications (Companion) | (c) HA-Entities (todo / input_button) | **(d) MQTT-Discovery Update-Entities** ⭐ |
|---|---|---|---|---|
| **Nähe zur „Repair"-Vision** | Nur mit eigener Integration + Fix-Flow „echt" (sehr hoch), Spook allein: Anzeige ohne Freigabe-Button | Mittel — Push mit Buttons, aber keine persistente Liste in HA | Niedrig — generische Buttons/Listen, kein Update-Kontext | **Hoch** — native „Update verfügbar"-UX mit Install/Skip, Release-Link, Versionsanzeige |
| **Wartungsaufwand** | Hoch (eigene Integration: Python, HA-Breaking-Changes) bzw. Spook-Abhängigkeit (großes, invasives Toolbox-Addon für einen Mini-Zweck) | Niedrig (2 Automationen YAML) | Mittel — Helper sind statisch; dynamische Anlage pro PR braucht wieder API+Token | **Niedrig–Mittel** — 2 n8n-Workflows, 1–2 HA-Automationen, kein HA-Custom-Code |
| **Sicherheit** | HA-Long-lived-Token in n8n nötig (HA-Tokens sind **nicht scope-bar** = Vollzugriff des Users!) | Kein HA-Token nötig, wenn Rückkanal über MQTT/Webhook+Secret läuft | HA-Token in n8n nötig (Entity-Anlage/REST) | **Kein HA-Token, kein n8n-Secret in HA** — nur Broker-User mit Topic-ACL |
| **Robustheit (HA-/n8n-Neustart)** | Repairs mit `persistent: true` überleben HA-Neustart; n8n-Ausfall: Spook-Issue veraltet still | Push ist flüchtig; Tap während HA down geht verloren; keine Wiedervorlage | Helper überleben Neustart, aber Zustand ≠ GitHub-Wahrheit (Drift) | **Hoch** — retained MQTT-Messages: Entity + Zustand überleben HA-Neustart; Reconciler heilt jede Drift beim nächsten Lauf |
| **Mehrbenutzer** | Repairs: nur Admins, keine Aktion | Pro Gerät explizit konfiguriert; „first tap wins" muss n8n dedupen | Dashboard für alle sichtbar/bedienbar | Updates-Seite: Admins; **Dashboard-Karte für beliebige Nutzer** möglich; HA-eigener Bestätigungsdialog vor Install |

**Empfehlung: (d) als Freigabe-UI**, ergänzt um Bausteine aus (b) und (a):

- **(b) als Hinweis-Kanal:** Companion-Push „Update wartet auf Freigabe" mit Link — die Freigabe selbst bleibt in der HA-UI (ein einziger Freigabepfad = ein einziger Audit-Punkt). Optional können die Push-Buttons zusätzlich freigeben (Automation publiziert dann auf dasselbe MQTT-Topic — kein zweiter Rückkanal nötig).
- **(a)/Spook nur für Fehlerzustände (optional):** „Deploy fehlgeschlagen nach Merge von PR #x" ist ein *echtes Problem* — dafür wäre ein Repair semantisch korrekt. Da das aber ein HA-Token in n8n erfordert, tut es in v1 eine `persistent_notification` bzw. der Push; Spook bleibt als Ausbaustufe notiert.

---

## 3. Architektur (empfohlene Variante)

```
                 GitHub (swarm-stacks)                       Homelab
  ┌──────────────────────────────────────┐   ┌──────────────────────────────────────────┐
  │ Renovate-GHA (täglich 04:30 lokal)   │   │                                          │
  │   → PRs: labels dependencies,        │   │  n8n (Swarm, n8n.hornung-bn.de)          │
  │     renovate [, major]               │   │  ┌────────────────────────────────────┐  │
  │     Branch renovate/*                │◄──┼──┤ WF-A „Reconciler" (Cron */15)      │  │
  │                                      │   │  │  GitHub-API: offene Renovate-PRs   │  │
  │  PUT /pulls/{n}/merge (squash+sha) ◄─┼───┼──┤ WF-B „Freigabe" (MQTT-Trigger)     │  │
  │        │                             │   │  │  + Deploy-Watch (Actions-API)      │  │
  │        ▼ push auf main               │   │  └───────┬──────────────▲─────────────┘  │
  │  deploy-stacks.yml                   │   │          │ publiziert   │ Install-Cmd    │
  │  (self-hosted Runner LXC 4303,       │   │          ▼ (retained)   │                │
  │   Konvergenz-Gate, rot bei Fehler)   │   │   MQTT-Broker 192.168.2.5:1883           │
  │        │                             │   │   Topics: homeassistant/update/…/config  │
  │        ▼                             │   │           renovate/swarm-stacks/…        │
  │  Docker Swarm Deploy                 │   │          │ Discovery    ▲                │
  └──────────────────────────────────────┘   │          ▼              │ update.install │
                                             │   Home Assistant (VM 100)                │
                                             │   • Update-Entity je PR (nativ)          │
                                             │   • Automation: Push via Companion-App   │
                                             │   • Freigabe = „Installieren"-Klick      │
                                             └──────────────────────────────────────────┘
```

**Zustandsphilosophie:** GitHub ist die einzige Quelle der Wahrheit (der PR-Zustand), der MQTT-Broker (retained) ist der Spiegel für HA, der Reconciler gleicht beide ab. Dadurch gibt es keinen verlorenen Zustand: Nach jedem Ausfall (n8n, HA, Broker) stellt der nächste Reconciler-Lauf den korrekten Anzeigestand wieder her.

### 3.1 Verifizierte Ist-Fakten (Repo/Infra), auf denen das Design aufbaut

| Fakt | Quelle | Design-Konsequenz |
|---|---|---|
| Renovate läuft **täglich 04:30 lokal** (Cron `30 2 * * *` UTC), self-hosted GHA mit fine-grained PAT `RENOVATE_TOKEN` | `.github/workflows/renovate.yml` | PR-Autor ist **`thorstenhornung1`, NICHT `renovate[bot]`** → Filter über Labels + Branch-Präfix, nie über Autor |
| Labels `dependencies`+`renovate`, Majors zusätzlich `major` **und** hinter `dependencyDashboardApproval`; n8n selbst hat `minimumReleaseAge: 10 days`; eigene Images/Taiga/LightRAG disabled; Meilisearch approval-gated | `.github/renovate.json5` | Major-Schutz existiert bereits zweifach; n8n-Flow filtert Majors trotzdem zusätzlich aus |
| Branch-Präfix der Renovate-PRs: `renovate/…` | `gh pr list` (PR #133–#135) | Filterkriterium |
| Repo erlaubt merge/squash/rebase; `squash_merge_commit_title = COMMIT_OR_PR_TITLE` | `gh api repos/...` | **Squash-Merge** → Commit-Message = PR-Titel (`chore(deps): …`), saubere Historie, `git revert`-freundlich |
| **Keine Branch-Protection möglich** (privates Repo, Free-Plan, HTTP 403) | `gh api .../branches/main/protection` | Es gibt **kein Pre-Merge-CI-Gate** — das Gate ist der post-merge Deploy-Workflow (Konvergenz-Gate, `failure_action: pause`, roter Run). Der Freigabe-Klick ist damit die Deploy-Entscheidung. |
| `deploy-stacks.yml`: Trigger `push: main, paths: stacks/**`; self-hosted Runner (LXC 4303); Timeout 35 min; Konvergenz-Gate macht Fehlschläge LOUD rot | Workflow-Datei + n8n-Stack-Kommentare | Merge per **PAT** (nicht `GITHUB_TOKEN`) löst den Deploy aus (im Repo bereits so dokumentiert); n8n überwacht den Run bis zu 40 min |
| MQTT-Broker existiert: **192.168.2.5:1883**, Auth per User/Passwort (Frigate nutzt ihn aus VLAN 4 heraus → Inter-VLAN-Routing funktioniert) | `swarm-stacks/stacks/apps/frigate/config.yml` | Kein neuer Broker nötig; eigener User + ACL für n8n |
| n8n 2.36.8, 1 Replica, `WEBHOOK_URL=https://n8n.hornung-bn.de/`, Traefik-Router **ohne SSO-Middleware** (nur TLS) | `swarm-stacks/stacks/apps/n8n/n8n-stack.yml` | Webhook-Pfade sind öffentlich erreichbar → falls Webhook-Trigger genutzt wird: HMAC-Prüfung Pflicht (§4.4) |

---

## 4. Detail-Design

### 4.1 Workflow A — „Reconciler" (n8n, Schedule-Trigger)

**Trigger:** Cron alle 15 min zwischen 04:15 und 23:00 (Renovate läuft 04:30; nachts ist niemand da, der freigibt — spart Ausführungen; `EXECUTIONS_DATA_PRUNE` ist eh aktiv).

**Warum Polling statt Webhook als Backbone:** Renovate-PRs sind keine flüchtigen Ereignisse — der PR-Zustand in GitHub *ist* der Zustand. Ein Webhook, der während eines n8n-Neustarts (stop-first-Updates!) eintrifft, ist unwiederbringlich verloren; ein Reconciler holt denselben Zustand 15 min später einfach ab. Zusätzlich deckt der Reconciler Fälle ab, für die man sonst je einen Webhook-Handler bräuchte: PR von Renovate aktualisiert (neue Version im selben PR), PR anderweitig gemerged/geschlossen, Label nachträglich geändert. Bei einem täglichen Renovate-Lauf ist die Webhook-Latenz-Ersparnis irrelevant.

**Schritte:**

1. **GitHub-Node / HTTP Request:** `GET /repos/thorstenhornung1/swarm-stacks/pulls?state=open&per_page=50` (Credential: fine-grained PAT, §5.1).
2. **Filter (Code-Node):**
   ```
   behalten wenn:
     head.ref beginnt mit "renovate/"
     UND labels enthält "dependencies" UND "renovate"
     UND labels enthält NICHT "major"
     UND head.ref != "renovate/pin-dependencies"   // Pin-Wellen sind Review-Sache
     UND draft == false
   ```
3. **Anreicherung pro PR** (`GET /pulls/{n}` für `mergeable_state`, Body-Parsing):
   - `update_type`: bevorzugt aus dem Label `update:patch|minor|digest` (kleine Renovate-Config-Ergänzung, §6 Schritt 2); Fallback: Regex auf die Renovate-Body-Tabelle (`\|\s*(patch|minor|digest|pin)\s*\|`).
   - `alt → neu`: Regex auf die „Change"-Spalte des PR-Bodys (z. B. `` `2.36.8` -> `2.37.4` ``); Fallback: nur `neu` aus dem PR-Titel (`… to v2.37.4`).
   - `head_sha` = `head.sha` — wird zum **Freigabe-Pfand** (§4.2).
   - `mergeable_state` (`clean`/`behind`/`dirty`/`unstable`/`blocked`).
4. **MQTT publizieren pro PR** (MQTT-Node, Credential: Broker-User `n8n-renovate`, alles **retained**, QoS 1):

   *Discovery-Config* — Topic `homeassistant/update/renovate_pr_135/config`:
   ```json
   {
     "name": "n8n 2.36.8 → 2.37.4",
     "unique_id": "renovate_swarm_stacks_pr_135",
     "state_topic": "renovate/swarm-stacks/pr/135/state",
     "command_topic": "renovate/swarm-stacks/pr/135/install",
     "payload_install": "4f9c1e7a…<head_sha>",
     "qos": 1,
     "release_url": "https://github.com/thorstenhornung1/swarm-stacks/pull/135",
     "device": {
       "identifiers": ["renovate-swarm-stacks"],
       "name": "Renovate swarm-stacks",
       "manufacturer": "Renovate (self-hosted GHA)",
       "model": "GitOps-Update-Freigabe"
     }
   }
   ```
   > **Kernkniff:** `payload_install` ist der **Head-SHA des PRs**. Drückt jemand „Installieren", publiziert HA genau diesen SHA. n8n merged mit `sha`-Guard — die Freigabe gilt damit *exakt für den Stand, der angezeigt wurde*. Pusht Renovate zwischenzeitlich eine neue Version, schlägt der Merge mit 409 fehl statt blind etwas anderes zu deployen; der nächste Reconciler-Lauf aktualisiert Anzeige + SHA.

   *State* — Topic `renovate/swarm-stacks/pr/135/state`:
   ```json
   {
     "installed_version": "2.36.8",
     "latest_version": "2.37.4",
     "title": "docker.n8n.io/n8nio/n8n (minor)",
     "release_summary": "minor · PR #135 · mergeable: clean",
     "release_url": "https://github.com/thorstenhornung1/swarm-stacks/pull/135",
     "in_progress": false
   }
   ```
   (`release_summary` max. 255 Zeichen; bei `mergeable_state: dirty` → `"⚠ Merge-Konflikt — Freigabe wird fehlschlagen, Renovate rebast i. d. R. selbst"`.)

5. **Neue PRs melden:** Für PRs, die in diesem Lauf erstmals gesehen wurden (Abgleich mit `workflowStaticData.knownPrs`), zusätzlich ein *nicht-retained* Event publizieren — Topic `renovate/swarm-stacks/events/new_pr`:
   ```json
   {"pr": 135, "title": "n8n 2.36.8 → 2.37.4", "update_type": "minor",
    "release_url": "https://github.com/thorstenhornung1/swarm-stacks/pull/135"}
   ```
   → HA-Automation macht daraus den Companion-Push (§4.3). Dedupe-Zustand liegt in n8n-StaticData; geht er verloren, ist die Folge nur ein doppelter Push — harmlos.
6. **Aufräumen:** Für jeden PR in `knownPrs`, der nicht mehr offen ist bzw. nicht mehr durchs Filter kommt:
   - gemerged → State mit `installed_version = latest_version` publizieren (Entity zeigt kurz „aktuell"), nach 1 h bzw. im Folgelauf: **leere retained Payload** auf `config`- und `state`-Topic → Entity verschwindet sauber aus HA;
   - geschlossen/major-gelabelt → sofort leere Payloads.

### 4.2 Workflow B — „Freigabe" (n8n, MQTT-Trigger)

**Trigger:** MQTT-Trigger-Node, Topic `renovate/swarm-stacks/pr/+/install` (Wildcard), QoS 1.

**Schritte:**

1. **Parsen:** PR-Nummer aus dem Topic, freigegebener `head_sha` aus der Payload. Payload-Sanity: `^[0-9a-f]{40}$`, sonst verwerfen (Broker-ACL macht Fremd-Publishes zwar schon unmöglich, aber defense-in-depth).
2. **Vorab-Check (GitHub):** `GET /pulls/{n}` → noch offen? Labels unverändert (kein `major` nachträglich)? Wenn nicht: Abbruch + Fehler-Event (Schritt 6).
3. **Sofort-Feedback:** State-Topic mit `"in_progress": true` publizieren → die Update-Entity zeigt in HA unmittelbar „Wird installiert…".
4. **Merge:**
   ```
   PUT https://api.github.com/repos/thorstenhornung1/swarm-stacks/pulls/135/merge
   Authorization: Bearer <fine-grained PAT>          (n8n-Credential-Store)
   Accept: application/vnd.github+json
   X-GitHub-Api-Version: 2022-11-28

   {"merge_method": "squash", "sha": "<head_sha aus Payload>"}
   ```
   - `200` → weiter mit Schritt 5 (`merge_commit_sha` merken).
   - `409 Conflict` („head branch was modified") → Renovate hat zwischen Anzeige und Klick gepusht. Kein Retry! State zurücksetzen (`in_progress: false`, Summary „Stand veraltet — Anzeige aktualisiert sich, bitte erneut freigeben"), Reconciler sofort anstoßen (n8n Sub-Workflow-Call).
   - `405 Method Not Allowed` („not mergeable") → Konflikt oder bereits gemerged. `GET /pulls/{n}` unterscheiden: `merged: true` → still OK (Doppelklick/zweiter Nutzer, idempotent beenden); sonst Fehler-Event.
5. **Deploy-Watch:** Der Merge (per PAT!) triggert `deploy-stacks.yml`. Polling-Loop (alle 60 s, max. 40 min — Workflow-Timeout ist 35 min):
   ```
   GET /repos/thorstenhornung1/swarm-stacks/actions/workflows/deploy-stacks.yml/runs?head_sha=<merge_commit_sha>
   ```
   - `conclusion: success` → State final: `installed_version = latest_version`, `in_progress: false`, Summary „✅ deployt <timestamp>"; Erfolgs-Event auf `renovate/swarm-stacks/events/result` (nicht-retained) → HA-Push „✅ n8n 2.37.4 deployt".
   - `conclusion: failure/cancelled` → State: `in_progress: false`, Summary „❌ Deploy fehlgeschlagen — Actions-Log prüfen; Rollback = git revert"; Fehler-Event → HA-Push mit `critical`-Anmutung + `persistent_notification` (Ausbaustufe: Spook-Repair, §2). **Kein Auto-Revert** — bei `failure_action: pause` ist manuelle Inspektion gewollt (siehe n8n-Stack-Kommentare zu Schema-Migrationen).
   - Kein Run gefunden nach 5 min → Fehler-Event „Deploy nicht angelaufen — Runner LXC 4303 prüfen" (bekannter Modus: steht der Runner, hängt jeder Deploy in `queued`).
6. **Fehler-Event-Format** (`renovate/swarm-stacks/events/result`):
   ```json
   {"pr": 135, "ok": false, "phase": "deploy", "message": "deploy-stacks run #812 failed",
    "url": "https://github.com/thorstenhornung1/swarm-stacks/actions/runs/…"}
   ```

### 4.3 Home-Assistant-Seite

**Voraussetzungen (zu verifizieren, §7):** MQTT-Integration verbunden mit 192.168.2.5, Discovery aktiv (Default-Präfix `homeassistant`), Companion-App registriert.

Die Update-Entities entstehen **ohne jede HA-Konfiguration** per Discovery. Zusätzlich zwei Automationen:

```yaml
# automation: Push bei neuem Renovate-PR (Hinweis, KEINE Freigabe im Push — Single Path)
- alias: "Renovate: Update wartet auf Freigabe"
  triggers:
    - trigger: mqtt
      topic: renovate/swarm-stacks/events/new_pr
  actions:
    - action: notify.mobile_app_ALLE_ADMIN_GERAETE   # verifizieren: echte notify-Ziele
      data:
        title: "Container-Update wartet auf Freigabe"
        message: >-
          {{ trigger.payload_json.title }} ({{ trigger.payload_json.update_type }})
        data:
          url: "/config/updates"          # iOS: öffnet HA-Updates-Seite
          clickAction: "/config/updates"  # Android
          tag: "renovate-pr-{{ trigger.payload_json.pr }}"   # ersetzt statt stapelt

# automation: Ergebnis-Meldung nach Freigabe
- alias: "Renovate: Deploy-Ergebnis"
  triggers:
    - trigger: mqtt
      topic: renovate/swarm-stacks/events/result
  actions:
    - action: notify.mobile_app_ALLE_ADMIN_GERAETE
      data:
        title: >-
          {{ '✅ Update deployt' if trigger.payload_json.ok else '❌ Deploy-Problem' }}
        message: "PR #{{ trigger.payload_json.pr }}: {{ trigger.payload_json.message }}"
        data:
          url: "{{ trigger.payload_json.url }}"
    - if: "{{ not trigger.payload_json.ok }}"
      then:
        - action: persistent_notification.create
          data:
            notification_id: "renovate-fail-{{ trigger.payload_json.pr }}"
            title: "Renovate-Deploy fehlgeschlagen"
            message: >-
              PR #{{ trigger.payload_json.pr }} — {{ trigger.payload_json.message }}.
              [Actions-Log]({{ trigger.payload_json.url }}) · Rollback: `git revert`.
```

**Optionale Erweiterung — Freigabe direkt aus dem Push (Variante b als Zusatzpfad):**
```yaml
# im new_pr-Push zusätzlich:
          actions:
            - action: "RENOVATE_MERGE_{{ trigger.payload_json.pr }}_{{ trigger.payload_json.head_sha }}"
              title: "Freigeben & deployen"

# zweite Automation:
- alias: "Renovate: Freigabe aus Notification"
  triggers:
    - trigger: event
      event_type: mobile_app_notification_action
  conditions:
    - condition: template
      value_template: "{{ trigger.event.data.action.startswith('RENOVATE_MERGE_') }}"
  actions:
    - action: mqtt.publish
      data:
        topic: >-
          renovate/swarm-stacks/pr/{{ trigger.event.data.action.split('_')[2] }}/install
        payload: "{{ trigger.event.data.action.split('_')[3] }}"
        qos: 1
```
Beide Pfade münden im selben MQTT-Topic → ein einziger Freigabe-Handler in n8n, idempotent.

**Dashboard (optional):** Eine `update`-Karten-Sektion bzw. Auto-Entities-Karte über das Gerät „Renovate swarm-stacks" macht die Freigabe auch für Nicht-Admins am Wandtablet möglich — bewusst entscheiden, wer deployen darf (HA hat keine feingranulare Rechtevergabe pro Aktion; wer die Entity sieht, kann installieren).

### 4.4 Trigger-Alternative: GitHub-Webhook (optionale Latenz-Optimierung)

Wenn Sofort-Anzeige gewünscht: GitHub-Webhook (`pull_request`, Actions `opened/synchronize/closed/labeled`) auf einen n8n-Webhook. **Sicherheitslage:** `n8n.hornung-bn.de` hängt ohne SSO-Middleware am öffentlichen Traefik; n8n-Webhook-Pfade (`/webhook/…`) sind grundsätzlich unauthentifiziert erreichbar. Deshalb zwingend:

1. **Webhook-Secret** setzen und **HMAC prüfen**: GitHub signiert den Body mit `X-Hub-Signature-256: sha256=<hmac>`. n8n hat seit 2026 automatische Signaturprüfung im GitHub-Trigger-Node ([Commit](https://github.com/n8n-io/n8n/commit/64c9148e1d65ad9e666bf37cf71720b876b58926)) — **verifizieren, ob in 2.36.8 enthalten**; sonst: Webhook-Node mit „Raw Body" + Crypto-Node (HMAC-SHA256) + constant-time Vergleich, bei Mismatch 401 ([Muster-Workflow](https://n8n.io/workflows/8906-secure-github-webhooks-with-hmac256-signature-validation/)).
2. Der Webhook-Handler ruft nur den Reconciler auf (kein eigener Zustandspfad) — so bleibt Polling die einzige Wahrheitsquelle und der Webhook ein reiner Beschleuniger.
3. Alternativ Traefik-seitig: eigener Router `n8n.hornung-bn.de/webhook/github-renovate` mit IP-Allowlist der [GitHub-Hook-Ranges](https://api.github.com/meta) — Wartungsaufwand (Ranges ändern sich), daher nur nice-to-have.

**Für v1: weglassen.** Der Reconciler alle 15 min genügt für einen 04:30-Renovate-Lauf vollständig.

---

## 5. Sicherheit

### 5.1 GitHub-Token (Merge)

- **Eigenes** fine-grained PAT `n8n-swarm-stacks-merge` — **nicht** das `RENOVATE_TOKEN` wiederverwenden (Trennung: Wer PRs erzeugt ≠ wer sie merged; Widerruf trifft nur einen Pfad).
- Scope: **nur Repository `swarm-stacks`**; Permissions: `Contents: Read/Write` + `Pull requests: Read/Write`. **Kein** `Workflows`-Scope (Renovate ändert mit `enabledManagers: [docker-compose]` nie Workflow-Dateien; sollte ein PR doch `.github/workflows/**` anfassen, schlägt der Merge fehl — gewollt).
- Ablauf 90 Tage + Erinnerung; Ablage **ausschließlich im n8n-Credential-Store** (verschlüsselt mit `n8n_encryption_key`, liegt als Docker Secret vor) — nie in Workflow-JSON/Env.
- Wichtig (im Repo bereits dokumentiert): Merge per PAT ist Voraussetzung dafür, dass `deploy-stacks.yml` überhaupt triggert — `GITHUB_TOKEN`-Events starten keine Folge-Workflows.

### 5.2 MQTT

- Eigener Broker-User `n8n-renovate` mit ACL:
  ```
  user n8n-renovate
  topic readwrite renovate/swarm-stacks/#
  topic write     homeassistant/update/renovate_pr_+/config
  ```
  Frigate-Credentials **nicht** mitbenutzen. HA behält seinen bestehenden Broker-User.
- Wirkung der ACL: Niemand außer n8n kann Discovery-Configs für `renovate_pr_*` setzen; niemand außer HA/n8n schreibt auf die `install`-Topics (HA-User ggf. ebenfalls per ACL auf `renovate/#` + Discovery-Read einschränken — nur falls der Broker fremd genutzt wird).
- Der SHA-als-`payload_install`-Mechanismus macht ein nachgemachtes „install"-Publish zusätzlich wertlos, solange der Angreifer den aktuellen Head-SHA nicht kennt — Sicherheitsanker bleibt aber die Broker-Auth + ACL.

### 5.3 Kein HA-Token, keine offenen Rückkanäle

- n8n authentifiziert sich **nirgends** gegen HA; HA kennt **keine** n8n-URL. Ein kompromittiertes HA kann schlimmstenfalls offene minor/patch-PRs mergen (die ein Mensch ohnehin mergen würde) — es kann keine PRs erzeugen, keine Inhalte ändern, keine Majors freigeben (n8n prüft Labels serverseitig erneut, Schritt B-2).
- HA-Long-lived-Tokens wären Vollzugriff (nicht scope-bar) — genau deshalb ist die MQTT-Kopplung der REST-Kopplung vorzuziehen. Erst die optionale Spook-Ausbaustufe bräuchte einen (dann: dedizierter Nicht-Admin-HA-User nur dafür).
- Der Merge-Pfad prüft in n8n **serverseitig** alle Bedingungen erneut (offen, Labels, kein major, SHA) — die HA-Seite ist reine UI, keine Autorität.

---

## 6. Fehlerpfade & Robustheit

| Szenario | Verhalten | Maßnahme im Design |
|---|---|---|
| **Merge-Konflikt** (`mergeable_state: dirty`) | Renovate rebast Konflikt-PRs i. d. R. selbst beim nächsten Lauf | Reconciler schreibt Warnung in `release_summary`; Freigabe-Versuch → 405 → Fehler-Push, kein Retry |
| **Renovate pusht neue Version nach Anzeige** | Freigabe bezieht sich auf alten Stand | `sha`-Guard im Merge-Call → 409 → „bitte erneut freigeben", Reconciler aktualisiert Anzeige + neuen SHA |
| **CI/Deploy rot** (Konvergenz-Gate, `failure_action: pause`) | Merge ist durch, Deploy hängt/failt | Deploy-Watch → ❌-Push + persistente HA-Notification mit Log-Link; Rollback bleibt bewusst manuell (`git revert`), weil z. B. DB-Migrationen nicht automatisch reversibel sind (dokumentierter n8n-Stack-Fall) |
| **Deploy startet gar nicht** | Self-hosted Runner (LXC 4303) steht → alles `queued` | Watch-Timeout 5 min ohne Run → gezielter Hinweis „Runner prüfen" |
| **HA offline / Neustart** | Keine Anzeige währenddessen | Retained Config+State → Entities stehen nach Reboot sofort wieder; verpasste `new_pr`-Pushes holt niemand nach (bewusst — die Updates-Seite zeigt den Bestand) |
| **n8n offline / stop-first-Update** | Install-Klick geht ins Leere | QoS 1 + retained State: Entity bleibt korrekt; Klick ohne `in_progress`-Feedback binnen ~1 min → erneut klicken (idempotent: bereits gemerged ⇒ stiller Erfolg). Verifikationspunkt: Persistent-Session-Verhalten des n8n-MQTT-Triggers (§7) — falls sauber, puffert der Broker den Klick sogar |
| **Broker offline** | Weder Anzeige-Updates noch Freigaben | Deckt das bestehende Monitoring ab (Frigate hängt am selben Broker → Ausfall fällt ohnehin auf); optional `availability_topic` mit Heartbeat des Reconcilers |
| **Doppel-Freigabe** (zwei Nutzer/Geräte) | Zwei Install-Publishes | Merge idempotent: zweiter Call → `merged: true` → stiller Erfolg |
| **Timeout / niemand reagiert** | PR bleibt offen; Renovate hält ihn aktuell; Entity bleibt stehen | Kein Zwang. „Überspringen" in HA blendet die aktuelle Version aus (rein lokal, bis zur nächsten). Optional: wöchentliche Sammel-Erinnerung (HA-Automation zählt Entities des Renovate-Geräts im Zustand `on`) |
| **Ablehnen** | Gewollt: Update nicht einspielen | **Soft (Standard):** HA „Überspringen" — PR bleibt offen, kein GitHub-Effekt. **Hard (optional, v2):** zusätzliche MQTT-Button-Entity „PR schließen" je Gerät → n8n schließt PR mit Kommentar; Renovate merkt sich geschlossene PRs und schlägt dieselbe Version nicht erneut vor (bleibt im Dependency-Dashboard #136 sichtbar) |
| **Major rutscht durch** | Dürfte nicht passieren | Dreifach: Renovate-`dependencyDashboardApproval` (Major-PR entsteht erst nach Dashboard-Haken) → Label-Filter im Reconciler → Label-Recheck im Freigabe-Workflow |

---

## 7. Offene Verifikationspunkte am realen System

**Home Assistant (VM 100 — Annahmen markiert, nichts davon wurde geprüft/verändert):**
1. HA-Version (Annahme: aktuelles 2026.x — MQTT-Update-Discovery gibt es seit 2022, unkritisch) und Erreichbarkeit/IP der Instanz.
2. **MQTT-Integration:** Ist HA mit 192.168.2.5:1883 verbunden? Discovery aktiv, Präfix `homeassistant`? (Sehr wahrscheinlich ja — Frigate-HA-Kopplung läuft klassisch über genau diesen Broker.)
3. **Wo läuft der Broker?** 192.168.2.5 ist laut Infra-Notizen auch ein Technitium-DNS-Host — Mosquitto-Standalone oder HA-Add-on? Wie werden User/ACLs gepflegt (Add-on-UI vs. `mosquitto.conf`)?
4. **Companion-App:** im Einsatz? Exakte `notify.mobile_app_*`-Ziele; iOS vs. Android (beeinflusst `url` vs. `clickAction`).
5. Sichtbarkeit/Bedienbarkeit der Update-Entities für Nicht-Admin-Nutzer (falls Wandtablet-Dashboards existieren): bewusst entscheiden, wer freigeben darf.

**n8n:**
6. MQTT-Trigger-Node in 2.36.8: QoS-1-Verhalten und Clean-Session-Flag (bestimmt, ob Klicks während n8n-Downtime nachgeliefert werden).
7. Nur falls Webhook-Pfad gewünscht: automatische GitHub-Signaturprüfung im GitHub-Trigger vorhanden?
8. Netzweg n8n-Container (VLAN 4, Overlay) → 192.168.2.5:1883 (Frigate beweist VLAN4→.2.5:1883 generell, aber vom Swarm-Overlay aus testen).

**GitHub/Renovate:**
9. `renovate.json5`-Ergänzung `addLabels` je Update-Typ (Schritt 2 unten) — bewusst als PR, nicht direkt auf main.
10. Verhalten von Renovate nach Squash-Merge (Branch-Cleanup übernimmt Renovate selbst; `delete_branch_on_merge` ist aus — beobachten).

---

## 8. Umsetzungsliste (Schritt für Schritt)

> Reihenfolge so gewählt, dass jeder Schritt einzeln testbar ist und der scharfe Merge-Pfad als Letztes aktiviert wird.

1. **Verifikationen §7.1–7.5 am HA erledigen** (nur lesen/anschauen).
2. **Renovate-Config ergänzen** (PR ins `swarm-stacks`-Repo; Achtung nested git — in beiden Repos committen):
   ```json5
   // .github/renovate.json5 → packageRules ergänzen:
   { matchUpdateTypes: ['patch'],  addLabels: ['update:patch']  },
   { matchUpdateTypes: ['minor'],  addLabels: ['update:minor']  },
   { matchUpdateTypes: ['digest'], addLabels: ['update:digest'] },
   ```
3. **Mosquitto:** User `n8n-renovate` + ACL (§5.2) anlegen (Betreiber; Passwort direkt in den n8n-Credential-Store).
4. **GitHub:** fine-grained PAT `n8n-swarm-stacks-merge` erstellen (Betreiber, §5.1), in n8n als Credential hinterlegen.
5. **n8n Workflow A (Reconciler)** bauen — zunächst mit Topic-Präfix `renovate-test/` und ohne HA-Wirkung (Discovery-Präfix weglassen), Ausgaben per `mosquitto_sub` kontrollieren.
6. **Discovery scharf schalten** (echtes `homeassistant/update/...`-Präfix) → Update-Entities erscheinen in HA unter Einstellungen → Updates; Anzeige mit den aktuell offenen PRs (#133–#135) validieren — *ohne* Freigabe-Workflow kann noch nichts passieren.
7. **HA-Automationen** (Push new_pr / result) anlegen; Push-Test über manuelles `mosquitto_pub` auf das Event-Topic.
8. **n8n Workflow B (Freigabe)** bauen — erste Stufe **Dry-Run**: statt Merge nur PR-Kommentar „✅ Freigabe aus HA empfangen (dry-run)". Einen Install-Klick durchspielen.
9. **Scharfschalten** des Merge-Calls; ersten echten Durchlauf mit einem risikoarmen Patch-/Digest-PR machen und den Deploy-Watch beobachten.
10. **Fehlerpfade durchspielen:** (a) Klick auf veralteten SHA (Reconciler-Lauf abwarten, alten SHA manuell publizieren → 409-Pfad), (b) n8n während eines Klicks gestoppt, (c) Ergebnis-Push bei absichtlich falscher `head_sha`-Query (kein Run gefunden).
11. **Betriebsregeln dokumentieren** (im swarm-stacks-Repo): Majors nie über HA; Deploy-rot ⇒ erst Log, dann `git revert`; Token-Rotation 90 d; „Überspringen" = nur ausblenden, PR lebt weiter.
12. **Optional v2:** „PR schließen"-Button je Update, Spook-Repair für Deploy-Fehler, GitHub-Webhook als Beschleuniger (§4.4).

---

## 9. Quellen

- [HA Developer Docs — Repairs (Erzeugung nur via `ir.async_create_issue`)](https://developers.home-assistant.io/docs/core/platform/repairs/)
- [HA Developer Docs — WebSocket API](https://developers.home-assistant.io/docs/api/websocket/) · [HA Community: Repairs via API nur über WebSocket lesbar](https://community.home-assistant.io/t/how-to-access-repairs-issues-issue-registry-via-api/757734)
- [Spook — Repairs-Actions (`repairs.create`/`repairs.remove`)](https://spook.boo/repairs/) · [Spook Releases (v5.2.0, 30.08.2026)](https://github.com/frenck/spook/releases)
- [HA — MQTT Update-Entity (Schema, `payload_install`, `release_summary` ≤ 255)](https://www.home-assistant.io/integrations/update.mqtt/)
- [n8n — MQTT-Trigger-Node](https://docs.n8n.io/integrations/builtin/trigger-nodes/n8n-nodes-base.mqtttrigger/) · [n8n-Commit: automatische GitHub-Webhook-Signaturprüfung](https://github.com/n8n-io/n8n/commit/64c9148e1d65ad9e666bf37cf71720b876b58926) · [Muster: HMAC-Validierung im Webhook-Node](https://n8n.io/workflows/8906-secure-github-webhooks-with-hmac256-signature-validation/)
- Repo-Fakten verifiziert via `gh api`: `.github/workflows/renovate.yml`, `.github/renovate.json5`, `.github/workflows/deploy-stacks.yml`, Repo-Merge-Settings, PR-Liste #130–#135; lokal: `swarm-stacks/stacks/apps/n8n/n8n-stack.yml`, `swarm-stacks/stacks/apps/frigate/config.yml`.
