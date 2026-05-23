#!/usr/bin/env bash
# ============================================================================
# Reisekosten-Steuer — Härtungsprogramm als GitHub-Milestones + Issues
# Quelle: Multi-Agent-Review 2026-05-18 (Security/Arch/Code/QA/Deploy)
# Maßstab: Reisekosten (Reisekostenabrechnung) v2.6.0
#
# IDEMPOTENT: Mehrfachlauf legt keine Duplikate an (Milestones/Issues werden
#             per Titel geprüft, Labels via --force).
#
# Ausführen:  ./create-hardening-issues.sh
#             (oder im Claude-Prompt:  ! ./create-hardening-issues.sh )
# Voraussetzung: gh ist authentifiziert (gh auth status).
# Aufräumen danach optional:  rm create-hardening-issues.sh
# ============================================================================
set -uo pipefail

R="thorstenhornung1/Reisekosten-Steuer"
SWARM="thorstenhornung1/swarm-stacks"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --- Labels (idempotent via --force) ---------------------------------------
say "Labels in $R"
gh label create hardening    -R "$R" -c 5319e7 -d "Härtungsprogramm (Review 2026-05-18)" --force
gh label create security     -R "$R" -c b60205 -d "Sicherheitsrelevant" --force
gh label create architecture -R "$R" -c 1d76db -d "Architektur/Struktur" --force
gh label create code-quality -R "$R" -c 0e8a16 -d "Code-Qualität/Wartbarkeit" --force
gh label create testing      -R "$R" -c fbca04 -d "Test/QA-Abdeckung" --force
gh label create quick-win    -R "$R" -c c2e0c6 -d "Geringer Aufwand, hoher Hebel" --force
gh label create "sev:high"   -R "$R" -c d93f0b -d "Severity High" --force
gh label create "sev:medium" -R "$R" -c fbca04 -d "Severity Medium" --force
gh label create "sev:low"    -R "$R" -c bfdadc -d "Severity Low" --force
gh label create convergent   -R "$R" -c 5319e7 -d "Von >=3 Review-Agenten unabhängig bestätigt" --force

# --- Milestones (idempotent: nur anlegen wenn Titel fehlt) ------------------
ensure_milestone() {
  local title="$1" desc="$2"
  if gh api "repos/$R/milestones?state=all" --jq '.[].title' 2>/dev/null | grep -qxF "$title"; then
    echo "  = Milestone existiert: $title"
  else
    gh api --method POST "repos/$R/milestones" -f title="$title" -f description="$desc" \
      --jq '"  + Milestone #\(.number): \(.title)"'
  fi
}
say "Milestones in $R"
ensure_milestone "Härtung Phase 1 — Security Quick-Wins" \
  "1:1-Ports aus Reisekosten v2.6.0: No-500-Handler+Fuzz, WeasyPrint-url_fetcher, Size-Caps, Fail-fast, logging, AGENTS.md. Lokal via Podman verifizierbar."
ensure_milestone "Härtung Phase 2 — Security Substanz" \
  "CSRF, ACL-/Routen-Klassifizierungs-Guard, Auth/OIDC-Callback-Tests, requirements pinnen + pip-audit/bandit-Gate."
ensure_milestone "Härtung Phase 3 — Struktur-Refactor" \
  "store.py-Dekomposition (Welle 1+2, pool-Injektion), Row->Model-Mapper, create_app->Blueprints, Tests fuer convert_*/paperless. Erst nach Phase-1-Sicherheitsnetz."
ensure_milestone "Härtung Phase 4 — Prozessreife" \
  "devel-Branch + CI-Trigger, Coverage-Ratchet 40->50, e2e-Harness, Self-hosted-Runner (Kostenopt., nicht dringend)."

# --- Issues (idempotent: skip wenn exakter Titel schon offen/geschlossen) ---
EXISTING_TITLES="$(gh issue list -R "$R" --state all --limit 200 --json title --jq '.[].title' 2>/dev/null)"

mk() { # mk <repo> <title> <milestone|""> <labels-csv> <body>
  local repo="$1" title="$2" ms="$3" labels="$4" body="$5"
  if printf '%s\n' "$EXISTING_TITLES" | grep -qxF "$title"; then
    echo "  = existiert, skip: $title"; return 0
  fi
  local args=(-R "$repo" --title "$title" --body "$body")
  [ -n "$ms" ] && args+=(--milestone "$ms")
  [ -n "$labels" ] && args+=(--label "$labels")
  gh issue create "${args[@]}" | sed 's/^/  + /'
}

M1="Härtung Phase 1 — Security Quick-Wins"
M2="Härtung Phase 2 — Security Substanz"
M3="Härtung Phase 3 — Struktur-Refactor"
M4="Härtung Phase 4 — Prozessreife"

say "Issues in $R"

# ---------------- Phase 1 ----------------
mk "$R" "Globaler Error-Handler — No-500-Invariante portieren" "$M1" "hardening,security,sev:high,convergent,quick-win" \
'**Phase 1 · Severity High · Konfidenz ⊕ (Security S-01 / Arch / Code F5 / QA #1 — alle 4 Agenten unabhängig)**

### Problem
Reisekosten-Steuer hat **keinen** globalen `@app.errorhandler`. `store.py:117/338/432/524` werfen roh `KeyError`/`ValueError` → ungefangene 500 mit potenziellem Traceback-/`str(exc)`-Leak. Die No-500-Invariante der Referenz-App fehlt strukturell.

### Beleg
- `Reisekosten-Steuer@feat/postgres-swarm-v1:app.py` — kein `@app.errorhandler` (grep leer)
- nur lokale `except Exception` (`app.py:632,828,877,983,1559,1646`)

### Referenz-Fix (1:1 portierbar)
`Reisekostenabrechnung/app.py:805-828` — `_handle_http_exception` + `_handle_unexpected_exception` + `_wants_json()` (JSON für `/api/*`, kein `str(exc)`, `app.logger.exception` server-seitig).

### Akzeptanz
- [ ] Globaler HTTPException- + Exception-Handler aktiv
- [ ] `/api/*` → JSON-Fehler ohne Traceback; sonst Fehlerseite
- [ ] kein `str(exc)`/Stacktrace im Response-Body
- [ ] Voraussetzung für #Fuzz-Test und Phase 3 (Refactor-Sicherheitsnetz)'

mk "$R" "No-500-Fuzz-Test portieren (Route × Hostile-Body)" "$M1" "hardening,security,testing,sev:high,convergent" \
'**Phase 1 · Severity High · Konfidenz ⊕ (Security S-06 / Arch AP4 / QA #1)**

### Problem
Keine Fuzz-Invariante, die mutierende Routen gegen 5xx bei bösartigem Input pinnt. Ohne sie ist der Error-Handler nicht regressionsgesichert und Phase 3 (store.py-Refactor) ungeschützt.

### Referenz-Fix
`Reisekostenabrechnung/tests/test_no500_fuzz.py` — iteriert `app.url_map`, alle mutierenden Routen × 9 bösartige Bodies, assert `< 500`. Mechanik direkt portierbar; Param-Filler an Steuer-Routen anpassen (`year_id`,`yi_id`,`doc_id`,`node_id`).

### Akzeptanz
- [ ] `tests/test_no500_fuzz.py` vorhanden, grün (nach Error-Handler-Issue)
- [ ] deckt automatisch jede neue mutierende Route ab
- [ ] Teil der regulären `pytest tests/`-Suite'

mk "$R" "WeasyPrint url_fetcher härten — SSRF/LFI im PDF-Renderer" "$M1" "hardening,security,sev:high,quick-win" \
'**Phase 1 · Severity High (Security S-03)**

### Problem
`print_renderer.py:160` nutzt WeasyPrint mit `default_url_fetcher` (ungefiltert). Print-Templates rendern Werte aus DB/Paperless-Titeln → `<img src="http://169.254.169.254/...">`-Injektion (SSRF) bzw. `file://`-LFI real möglich.

### Referenz-Fix
`Reisekostenabrechnung/print_renderer.py:184-198` — custom `_url_fetcher`: nur `file://` innerhalb `template_dir`; blockt `http(s)://`, `data:`, `ftp:`. An `HTML(...).write_pdf(url_fetcher=self._url_fetcher)` binden.

### Akzeptanz
- [ ] custom `url_fetcher` aktiv, externe Schemes geblockt
- [ ] Regressionstest: `http://`/`file://`-Außerhalb wird abgewiesen'

mk "$R" "Request-Size-Caps setzen (MAX_CONTENT_LENGTH / MAX_FORM_MEMORY_SIZE)" "$M1" "hardening,security,sev:medium,quick-win" \
'**Phase 1 · Severity Medium (Security S-04)**

### Problem
`create_app()` setzt keine Request-Size-Limits → Memory/Storage-Exhaustion via Multi-GB-Body, auch auf `request.get_json()`-Endpoints.

### Referenz-Fix
`Reisekostenabrechnung/app.py:776-786` — `MAX_CONTENT_LENGTH=25*1024*1024`, `MAX_FORM_MEMORY_SIZE=1*1024*1024` in `app.config.update(...)`.

### Akzeptanz
- [ ] beide Limits in `create_app()` gesetzt
- [ ] Überschreitung → 413 statt OOM'

mk "$R" "Fail-fast statt unsicherer Defaults (SECRET_KEY / Prod-OIDC-Assertion)" "$M1" "hardening,security,sev:medium,quick-win" \
'**Phase 1 · Severity Medium/Low (Security S-08/S-09)**

### Problem
- `app.py:589` Fallback `app.secret_key = ... or "dev-insecure-change-me"` → signierte Session-Cookies trivial fälschbar wenn `SECRET_KEY` fehlt.
- `app.py:2113-2125` Legacy-No-OIDC-Mode läuft komplett offen, kein Boot-Gate → versehentliches Offen-Deployen möglich.

### Maßnahme (Referenz: `Reisekostenabrechnung/app.py:760` raise statt Fallback)
- [ ] `SECRET_KEY` fehlt + OIDC aktiv → `sys.exit`/`raise` (kein unsicherer Default)
- [ ] Prod-Marker erzwingt gesetztes `AUTHENTIK_CLIENT_ID` → sonst Boot-Abbruch
- [ ] Dev-Wert nur explizit via Env'

mk "$R" "AGENTS.md aktualisieren — beschreibt fälschlich SQLite" "$M1" "hardening,documentation,sev:medium,convergent,quick-win" \
'**Phase 1 · Severity Medium · Konfidenz ⊕ (Arch / Code)**

### Problem
`AGENTS.md` dokumentiert „store.py: SQLite access", „migrations/: SQLite schema", „Run: python app.py" — widerspricht der deployten Postgres/Patroni/Swarm-Realität. Doku-Drift maskiert die echte Architektur für jeden Folge-Contributor/Agenten.

### Akzeptanz
- [ ] AGENTS.md spiegelt Postgres + Patroni-Pool (`db.py`) + Swarm-Deploy + Branch-Modell wider
- [ ] kein „SQLite"-Verweis mehr'

mk "$R" "logging einführen + stille except-Blöcke sichtbar machen" "$M1" "hardening,code-quality,sev:medium,quick-win" \
'**Phase 1 · Severity Medium (Code F9/F10/F13)**

### Problem
0 Logging projektweit (`getLogger` = 0 Treffer). Teardown `app.py:632-636` und 6 Paperless-`except Exception` schlucken Fehler ohne Spur → Prod-Debugging blind, stille Datenausfälle im Nightly-Refresh.

### Referenz
`Reisekostenabrechnung` nutzt `_boot(msg)`-Boot-Logger + `app.logger`.

### Akzeptanz
- [ ] `logging.getLogger(__name__)` etabliert
- [ ] Boot-Schritte (migrate.run, advisory lock) geloggt
- [ ] alle geschluckten `except` → mind. `logger.warning` (Control-Flow unverändert)'

# ---------------- Phase 2 ----------------
say "Phase-2-Issues"
mk "$R" "CSRF-Schutz für mutierende Routen" "$M2" "hardening,security,sev:high" \
'**Phase 2 · Severity High (Security S-02)**

### Problem
Kein CSRF-Schutz auf `@app.post`/`@app.patch` (`app.py:1004,1145,1764,1832,1851,1873,1931,1988,2068`). Single-User mindert das nicht (Form- + JSON-fetch-CSRF bleiben Vektor).

### Referenz-Fix
`Reisekostenabrechnung/app.py:770-771` — `CSRFProtect(app)`, AJAX via `X-CSRFToken` + `<meta csrf-token>`.

### Akzeptanz
- [ ] `Flask-WTF` in requirements, `CSRFProtect(app)` aktiv
- [ ] alle Forms + fetch-POST/PATCH senden Token
- [ ] `/healthz`, `/auth/callback` exempt'

mk "$R" "ACL-/Routen-Klassifizierungs-Guard (fail-closed)" "$M2" "hardening,security,testing,sev:medium,convergent" \
'**Phase 2 · Severity Medium · Konfidenz ⊕ (Security / QA #4)**

### Problem
Kein CI-Guard, der jede Route zwingt klassifiziert zu werden → künftige Features führen leicht versehentlich ungeschützte Routen ein. Wichtigster *struktureller* Schutz für Weiterentwicklung.

### Referenz
`Reisekostenabrechnung` `test_every_expense_endpoint_classified` (fail-closed `_ACL_REQUIRED`-Map).

### Akzeptanz
- [ ] Test iteriert `url_map`, jede Route muss in Public/Protected-Map stehen, sonst rot
- [ ] neue Route ohne Klassifizierung → CI fail'

mk "$R" "Auth/OIDC-Callback-Tests + OIDC-an-Fixture" "$M2" "hardening,security,testing,sev:high" \
'**Phase 2 · Severity High (QA #2/#3)**

### Problem
0 Tests berühren `auth.py`; `conftest` schaltet OIDC bewusst ab → gesamter Auth-Pfad untestbar. `auth.py:91-129` (`authorize_access_token` OAuthError, `preferred_username` missing→502) ungetestet.

### Referenz
`Reisekostenabrechnung/tests/test_auth.py`, `test_auth_callback.py`, `conftest.py` (Fixtures `oidc_app`,`as_user`,`seed_user`).

### Akzeptanz
- [ ] „OIDC-an"-Fixture in conftest
- [ ] OAuthError → Redirect Login (kein 500); `preferred_username` fehlt → 502
- [ ] `require_login`-Gate + Public-Allowlist (`/healthz`,`/auth/callback`) getestet'

mk "$R" "requirements.txt pinnen + pip-audit + bandit CI-Gate" "$M2" "hardening,security,sev:medium" \
'**Phase 2 · Severity Medium (Security S-05 / QA)**

### Problem
0 Deps exakt gepinnt (`==`) → kein deterministisches Audit. Kein `pip-audit`-Gate. `bandit` liegt ungenutzt in `requirements-test.txt`.

### Akzeptanz
- [ ] `requirements.txt` exakt gepinnt (`==`)
- [ ] `pip-audit`-Step in `.github/workflows/tests.yml` (erst `continue-on-error`, dann blockierend)
- [ ] `bandit -r . -x ./tests`-Step (erst `continue-on-error`)
- [ ] Floors/Ausnahmen dokumentiert (analog Reisekosten #82/#98)'

# ---------------- Phase 3 ----------------
say "Phase-3-Issues"
mk "$R" "store.py-Dekomposition Welle 1 (data_migration / settings / tax_year)" "$M3" "hardening,architecture,sev:medium" \
'**Phase 3 · (Arch AP5 / Code F2) · setzt Phase-1-Sicherheitsnetz voraus**

### Problem
`store.py` = 2488 Z., eine `Store`-Gott-Klasse (~70-82 Methoden, 146× `self.conn`). Referenz: 9+ fokussierte Stores.

### Schnitt Welle 1 (behaviour-neutral, je 1 PR, risikoarm zuerst)
1. `data_migration.py` (Boot/Einmal-Code, kein Request-Pfad, ~330 Z.)
2. `settings_store.py` (~150 Z.)
3. `tax_year_store.py` (~95 Z.)

### Akzeptanz
- [ ] 3 Module herausgelöst, Verhalten unverändert (Fuzz/Tests grün)
- [ ] Splitting-Muster dokumentiert (Vorlage `Reisekostenabrechnung/expense_store.py:5-13`)'

mk "$R" "Row→Model-Mapper konsolidieren (Spalten-Drift-Risiko)" "$M3" "hardening,code-quality,sev:medium,quick-win" \
'**Phase 3 · (Code F3) · S, hoher Hebel**

### Problem
~216 manuelle `row[...]`-Zugriffe; SELECT+`Model(...)`-Block je Entität 2-3-fach kopiert (z.B. `store.py:245-333` TaxYear-Trio). Neues Feld muss in bis zu 3 Methoden synchron → stiller Daten-Bug bei Vergessen.

### Akzeptanz
- [ ] je Entität genau ein `_row_to_<x>(row)` + `_SELECT_<x>`-Konstante
- [ ] alle Reader umgestellt; ~600 Z. reduziert; Tests grün'

mk "$R" "store.py Welle 2 + pool-Injektion (autocommit-Altlast abbauen)" "$M3" "hardening,architecture,sev:medium" \
'**Phase 3 · (Arch AP6 / Code F2) · L · nach Welle 1**

### Schnitt Welle 2
`document_store.py` → `catalog_store.py` → `template_store.py` + `year_structure_store.py` (größte/verflochtenste Cluster zuletzt).

### Strukturprinzip
Jede neue Klasse nimmt `pool` (nicht `conn`), borgt per Methode `with self.pool.connection()` → beseitigt `db.py:22-33` `autocommit=False`-Divergenz **strukturell** statt per Workaround.

### Akzeptanz
- [ ] Welle-2-Module herausgelöst, `pool`-injiziert
- [ ] `autocommit=False`-Sonderpfad entfernt; Failover-Test grün'

mk "$R" "create_app() entzerren — Pure-Closures auf Modul-Level + Blueprints" "$M3" "hardening,architecture,code-quality,sev:medium" \
'**Phase 3 · (Code F1/F11) · M**

### Problem
`app.py:579` `create_app()` = 1556 Z., 33 Routes + ~40 Helper als Closures. `create_hierarchy()` 265 Z. Action-Dispatcher. Nichts isoliert testbar.

### Maßnahme
- [ ] reine Closures (`parse_iso_date`,`sort_docs`,`is_html_response`,`sniff_image_mimetype`,`build_year_document_groups`,`build_template_hierarchy`) → Modul/`view_models.py` (unit-testbar)
- [ ] Routes in Blueprints (`hierarchy`,`paperless`,`year`,`settings`)
- [ ] `_parse_optional_int`-Helper für dupliziertes sort_key-Parsing
- [ ] Verhalten unverändert (Fuzz grün)'

mk "$R" "Tests: convert_*_to_period + upsert_paperless_document" "$M3" "hardening,testing,sev:medium" \
'**Phase 3 · (QA #5/#6 / Code) · riskantester neuer Codepfad**

### Problem
`store.py:1243-1536` (`convert_template_to_period`/`convert_institution_to_period`/`convert_period_to_template`) und `store.py:2206` (`upsert_paperless_document` ON CONFLICT) — komplexer Datenumbau ohne dediziertes Store-Level-Test.

### Akzeptanz
- [ ] Roundtrip-/Idempotenz-/Integritätstests für die 3 convert_*
- [ ] upsert/unlink_paperless Doppel-Link/Re-Link/Unlink-Idempotenz getestet'

# ---------------- Phase 4 ----------------
say "Phase-4-Issues"
mk "$R" "devel-Integrationsbranch + CI-Trigger (vor 1. Release)" "$M4" "hardening,architecture,sev:medium" \
'**Phase 4 · (Arch AP2 / QA)**

### Problem
`tests.yml`/`build.yml` triggern nur auf `main`; kein `devel`-Konzept; release-please-manifest steht auf `0.0.0`. Jeder main-Merge würde Teil-Release triggern (Reisekosten-Lehre: Milestone = vollständiges Release).

### Akzeptanz
- [ ] `devel`-Branch etabliert, CI auf `devel`+`main`
- [ ] Branch-/Release-Disziplin in AGENTS.md dokumentiert (analog Reisekosten CLAUDE.md)'

mk "$R" "Coverage-Ratchet 40 → 50" "$M4" "hardening,testing,sev:low" \
'**Phase 4 · (QA / Arch AP3)**

### Problem
`tests.yml --cov-fail-under=40` vs. Referenz 50. Kommentar sieht Ratchet bereits vor, Plan fehlt konkret.

### Akzeptanz
- [ ] nach Phase-1/2-Test-Paketen Gate auf 50 (CI-paritätisch)
- [ ] Ratchet-Plan in AGENTS.md verankert; nie senken ohne Review-Diff'

mk "$R" "e2e-Harness analog Reisekosten (tests/e2e + run-local.sh)" "$M4" "hardening,testing,sev:low" \
'**Phase 4 · (QA #9 / Arch AP7) · nach Store-Stabilisierung**

### Akzeptanz
- [ ] `tests/e2e/` + `run-local.sh` gegen `steuer`-Test-Stack (CSRF, echtes OIDC, Live-Patroni)
- [ ] separater/nightly Workflow, nicht in Unit-CI'

# ---------------- Infra-Issue (swarm-stacks, privat) ----------------
say "Infra-Issue in $SWARM"
SWARM_TITLES="$(gh issue list -R "$SWARM" --state all --limit 200 --json title --jq '.[].title' 2>/dev/null)"
ST="Self-hosted GitHub Actions Runner (Homelab) — Kostenoptimierung"
if printf '%s\n' "$SWARM_TITLES" | grep -qxF "$ST"; then
  echo "  = existiert, skip: $ST"
else
  gh issue create -R "$SWARM" --title "$ST" --label "enhancement" --body \
'**Nicht dringend** — GitHub-Budget wurde wiederhergestellt, Actions laufen wieder. Dies ist geplante Kostenoptimierung, kein Notfall mehr.

### Nutzen
- 0 Actions-Minuten dauerhaft (private Repos: self-hosted = kostenlos), kein erneuter Budget-Stop
- eliminiert die `-march=native`/AVX-512-Falle strukturell (Runner-i5 == Target-i5)
- schnellere Builds (lokaler Layer-Cache), entkoppelt von TS_AUTHKEY-Expiry (statisches Tailscale im LXC)

### Plan (Agent-Review 2026-05-18, Details siehe Konversation)
1. LXC `gha-runner` auf **pve02** (local-lvm, 4 vCPU/6 GB/40 GB, VLAN 4) — Terraform analog `swarmpit.tf`
2. Runner-Image bestücken (Python 3.12, WeasyPrint-Libs, Docker/Buildx, gh, Node20, Tailscale)
3. **User**: fine-grained PAT (`administration:write`, 3 private Repos) → LXC-`.env`
4. myoung34 **ephemeral** Runner, zuerst auf `swarm-stacks` registriert
5. `runs-on` umstellen: `deploy-stacks.yml:42` + `build-{patroni-postgres,pbs-client,samba}.yml`, `build-taiga-openid.yml` (2 Jobs) → `[self-hosted,linux,x64,homelab]` (Dual-Repo-Commit: terraform + swarm-stacks Remote)
6. Verifikation deploy-stacks self-hosted → Tailscale → SSH .40 → grün
7. dann Runner für Reisekostenabrechnung + Reisekosten-Steuer (`feat/postgres-swarm-v1`)

### Sicherheit
Alle 3 Repos mit Workflows sind **privat** (kein Fork-PR-RCE). Public `terraform`-Repo hat keine Workflows → bekommt nie einen Runner. **Dauerregel:** niemals `runs-on: self-hosted` in einem public Repo.

### Betrieb
ephemeral + auto-reregister, wöchentl. Image-Pull-Cron, Stale-Runner-Cleanup, Monitoring an VictoriaMetrics/Telegram ("kein swarm-stacks-Runner > 10 min").' | sed 's/^/  + /'
fi

say "Fertig."
echo "Übersicht:  gh issue list -R $R --label hardening --limit 50"
echo "Milestones: gh api repos/$R/milestones --jq '.[]|\"\\(.title): \\(.open_issues) offen\"'"
