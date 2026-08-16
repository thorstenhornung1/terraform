# Wallos — Abo-/Subscription-Tracker

**URL:** https://abo.hornung-bn.de
**Version:** 5.4.2 (Tag-gepinnt, nicht `latest`)
**Node:** docker-infra-2 (Daten liegen dort lokal)
**SSO:** Authentik OIDC, Discovery-basiert

---

## Storage — die zentrale Entscheidung

Wallos nutzt **SQLite**. Daraus folgt alles Weitere:

| Option | Bewertung |
|---|---|
| CephFS | ❌ SQLite mmap()t im WAL-Modus die `-shm`-Datei. Upstream: *"WAL does not work over a network filesystem."* Timeouts und Korruption drohen. |
| Ceph RBD | ⚠️ Technisch korrekt, aber der komplette Failover-Apparat (systemd map/mount + Watchdog-Timer auf drei Nodes, Label-Verschiebung) ist für eine Abo-Verwaltung überzogen. |
| **Lokal auf einem Node** | ✅ **Gewählt.** `/srv/data/wallos` auf docker-infra-2. Kein Netzwerk-Dateisystem, kein mmap-Problem, kein Apparat. |

**Der Preis:** Fällt docker-infra-2 aus, ist Wallos offline und die Daten sind
bis zur Rückkehr des Nodes nicht erreichbar. Das ist bewusst akzeptiert — eine
Abo-Übersicht rechtfertigt keinen Failover-Aufbau.

**Die Absicherung:** Der Backup-Sidecar zieht alle 6 Stunden per
`sqlite3 .backup` eine konsistente Kopie nach
`/mnt/cephfs/swarm-state/stack-wallos/db-backup/`. Von dort erfasst sie das
PBS-Backup. Jede Kopie durchläuft ein `PRAGMA integrity_check`; besteht sie ihn
nicht, wird sie verworfen statt als gültiges Backup liegen zu bleiben.
Aufbewahrung: 14 Tage.

---

## Inbetriebnahme

### 1. Verzeichnisse (einmalig, erledigt)

```bash
ssh root@192.168.4.41 "mkdir -p /srv/data/wallos/{db,logos}"
ssh root@192.168.4.40 "mkdir -p /mnt/cephfs/swarm-state/stack-wallos/db-backup"
```

Die Rechte setzt Wallos beim Start selbst: `startup.sh` macht
`chown -R www-data:www-data /var/www/html` (UID/GID 82).

### 2. DNS-Eintrag — durch einen Menschen

`abo.hornung-bn.de` → Traefik-VIP, angelegt in Technitium **ausschließlich auf
dns1** (192.168.4.2); dns2/dns3 sind read-only Secondaries.

### 3. Authentik-Provider — in der UI

**Providers → Create → OAuth2/OpenID Provider**

| Feld | Wert |
|---|---|
| Name | `wallos` |
| Client type | Confidential |
| Redirect URI | `https://abo.hornung-bn.de/` |
| Signing Key | vorhandenes Zertifikat |
| Scopes | `openid`, `profile`, `email` |

Danach **Applications → Create**, Slug **`wallos`** (der Slug bestimmt die
Issuer-URL und muss exakt so lauten), Provider zuordnen.

Der resultierende Issuer ist
`https://auth.hornung-bn.de/application/o/wallos` — im Stack **ohne** Slash am
Ende eingetragen, weil Wallos `/.well-known/openid-configuration` direkt
anhängt (`includes/oidc_settings.php:99`). Ein Trailing-Slash ergäbe einen
doppelten und damit einen 404 bei der Discovery.

### 4. Docker Secrets — über die Portainer-UI

Nicht per `docker secret create` anlegen (Trailing-Newlines,
Manager-Lesbarkeit):

| Secret | Inhalt |
|---|---|
| `wallos_oidc_client_id` | Client ID aus dem Authentik-Provider |
| `wallos_oidc_client_secret` | Client Secret aus dem Authentik-Provider |

**Fehlen die Secrets, startet Wallos trotzdem** — dann ohne SSO, mit lokalem
Login. Der Stack ist also deploybar, bevor Authentik konfiguriert ist.

### 5. Deploy

Push auf `main` → `deploy-stacks.yml` → SSH-Deploy. Manuelles
`docker stack deploy` umgeht die Pipeline und erzeugt Drift.

### 6. Erster Benutzer

Wallos startet mit aktivem Passwort-Login (`OIDC_DISABLE_PASSWORD_LOGIN=false`).
Ersten Benutzer über die Registrierung anlegen, dann per SSO anmelden. Der
lokale Login bleibt bewusst als Rückfallebene bestehen, falls Authentik
ausfällt — er kann nach dem ersten erfolgreichen SSO-Login abgeschaltet werden.

---

## Betrieb

### Zustand prüfen

```bash
ssh root@192.168.4.40 "docker service ls --filter name=wallos"
ssh root@192.168.4.40 "docker service ps wallos_wallos --no-trunc"
```

### Backups ansehen

```bash
ssh root@192.168.4.40 "ls -lt /mnt/cephfs/swarm-state/stack-wallos/db-backup/ | head"
ssh root@192.168.4.40 "docker service logs wallos_wallos-backup --tail 20"
```

### Restore

```bash
# 1. Wallos stoppen (SQLite: kein Schreiber während des Restores!)
ssh root@192.168.4.40 "docker service scale wallos_wallos=0"

# 2. Kopie zurückspielen
ssh root@192.168.4.41 "cp /mnt/cephfs/swarm-state/stack-wallos/db-backup/wallos-<TS>.db \
                          /srv/data/wallos/db/wallos.db"

# 3. Wieder hochfahren (Wallos chownt beim Start selbst)
ssh root@192.168.4.40 "docker service scale wallos_wallos=1"
```

---

## Fallstricke

- **`order: stop-first` ist bei diesem Stack Pflicht.** `start-first` ließe
  zwei Container gleichzeitig auf dieselbe `wallos.db` schreiben — der direkte
  Weg in eine korrupte Datenbank. Kurze Downtime beim Deploy ist der Preis.
- **`SSRF_ALLOWLIST` ist nicht optional — und betrifft mehr als OIDC.** Wallos
  blockt jeden Zugriff auf private Netze an *zwei unabhängigen* Stellen
  (`includes/ssrf_helper.php`):
  `validate_oidc_endpoint_url()` für die Discovery und `validate_smtp_host()`
  für den Mailversand. Fehlt der Mail-Relay auf der Liste, meldet die
  SMTP-Maske *"Security Error: SMTP host must not target link-local or loopback
  addresses"*.
  Der Abgleich ist ein **exaktes `in_array()`** über `host`, `ip`, `host:port`
  und `ip:port` — keine Wildcards, kein CIDR. Und die Env-Variable
  **überschreibt** die in der Admin-UI gepflegte Liste vollständig: Jeder neue
  Zielhost muss in den Stack, sonst verschwindet er beim nächsten Deploy.
  Nebenbedingung: Interne Adressen darf ohnehin nur Benutzer 1 verwenden
  (`Security Block: Standard users are not permitted…`).

## SMTP

**Nur über die Admin-UI konfigurierbar** — Wallos wertet dafür keine
Env-Variablen aus. Die Werte landen in der SQLite-DB und werden damit vom
Backup-Sidecar erfasst, sind aber **nicht** GitOps-verwaltet.

| Feld | Wert |
|---|---|
| SMTP Adresse | `192.168.4.71` (Mail-Relay, LXC 4505) |
| Port | `25` |
| Verschlüsselung | **Keine** |
| Benutzername / Passwort | *leer* |
| Absender | **`homelab@hornung-bn.de`** — nicht frei wählbar, siehe unten |

### ⚠️ Der Absender ist nicht frei wählbar

Der Relay stellt über die **Microsoft-Graph-API** zu, die per
`/users/{absender}/sendMail` versendet. Der Absender muss deshalb eine
**existierende Mailbox im Tenant** sein; jede andere Adresse quittiert Graph
mit `404 ErrorInvalidUser`.

Belegt am 2026-08-16: `wallos@wallosapp.com` (Wallos-Default) und
`abo@hornung-bn.de` wurden beide abgelehnt, `homelab@hornung-bn.de` stellt zu.

**Die Falle dabei:** `ALLOW_EMPTY_SENDER_DOMAINS=true` lässt Postfix jeden
Absender annehmen und mit `250 OK` quittieren — die sendende Anwendung meldet
also **Erfolg**. Abgewiesen wird erst eine Station weiter, und die daraufhin
erzeugte Bounce-Mail scheitert ebenfalls (ihr leerer Absender `<>` ist erst
recht keine Mailbox). Ergebnis: Der Test in der Oberfläche ist grün, und es
kommt trotzdem nichts an. Im Zweifel immer gegenprüfen:

```bash
ssh root@192.168.4.71 "docker logs mailrelay-postfix-1 --since 15m | grep -E 'status=(sent|bounced)'"
ssh root@192.168.4.71 "docker logs mailrelay-smtp-oauth-relay-1 --since 15m | grep -A2 'Failed to send'"
```

Keine Zugangsdaten nötig, weil das Relay nach Herkunft entscheidet:
`mynetworks` enthält `192.168.4.0/24`, und der Wallos-Container erscheint dort
mit der Node-IP (NAT über die docker_gwbridge), greift also über
`permit_mynetworks`.

Keine Verschlüsselung, weil das Relay STARTTLS zwar anbietet
(`smtpd_tls_security_level = may`), aber mit `ssl-cert-snakeoil.pem` — einem
selbstsignierten Zertifikat, an dem PHPMailers Zertifikatsprüfung scheitert.

Der Relay stellt über einen `smtp-oauth-relay` per Microsoft Graph zu.
`ALLOW_EMPTY_SENDER_DOMAINS=true` heißt, Postfix nimmt jeden Absender an — ob
Graph eine Adresse außerhalb des OAuth-Kontos akzeptiert, zeigt erst der
Versand.
- **Env schlägt Admin-UI.** Per Env gesetzte OIDC-Felder markiert Wallos als
  `managed_fields` und sperrt sie in der Oberfläche. Änderungen gehören in die
  Stack-Datei, nicht in die UI — sonst entsteht Drift, die beim nächsten Deploy
  stillschweigend zurückgesetzt wird.
- **Der Placement-Constraint ist keine Optimierung**, sondern die Zuordnung zum
  lokalen Bind-Mount. Wer die Daten verschiebt, muss `node.hostname` in
  **beiden** Services mitziehen (App und Sidecar).
- **Der Sidecar muss den Healthcheck des Images abschalten** (`test: ["NONE"]`).
  `bellamy/wallos` bringt `HEALTHCHECK curl -fsS http://127.0.0.1/health.php`
  mit; ein Sidecar aus demselben Image **erbt ihn**, hat aber keinen nginx.
  Folge (beobachtet beim Erst-Deploy am 2026-08-16): Exit 7, nach drei
  Versuchen unhealthy, Swarm startet endlos neu — und der GitOps-Job bleibt
  im Konvergenz-Gate hängen, obwohl der Sidecar seine Backups korrekt zog.
  Der Fehler ist besonders tückisch, weil `docker service logs` beim
  dauernd neu gestarteten Task leer bleibt: Man sieht die funktionierende
  Arbeit erst über `docker logs <container-id>` direkt auf dem Node.
- **`login.php` leitet auf `registration.php` um, solange kein Benutzer
  existiert.** Der OIDC-Button erscheint deshalb erst nach der Anlage des
  ersten Kontos — die Registrierungsseite selbst bietet keinen SSO-Weg.

## Admin-Rechte

Wallos hat **kein Rollenmodell**. `includes/header.php:54`:

```php
$isAdmin = $_SESSION['userId'] == 1;
```

Admin ist schlicht **Benutzer-ID 1**, der zuerst angelegte Account. Eine
Zuweisung über Authentik-Gruppen ist nicht möglich — der OIDC-Callback wertet
Gruppen gar nicht aus, er liest nur `sub`, `email`, `email_verified`,
`preferred_username` und `name`.

**Der Admin kann sich trotzdem per SSO anmelden:** Der Callback verknüpft einen
bestehenden Account über die **E-Mail-Adresse** und setzt dabei `oidc_sub`
(`includes/oidc/handle_oidc_callback.php`). Benutzer 1 behält seine Rechte.

⚠️ **Der erste Login entscheidet, wer Admin wird.** Mit
`OIDC_AUTO_CREATE_USER=true` bekommt derjenige ID 1, der sich als Erster
anmeldet — auch per SSO. Deshalb zuerst selbst registrieren, mit derselben
E-Mail wie in Authentik.

### `OIDC_REQUIRE_EMAIL_VERIFIED=false` — warum das nötig ist

Beim ersten SSO-Versuch am 2026-08-16 scheiterte der Login mit
*"Ihre E-Mail-Adresse wurde vom Identitätsanbieter nicht verifiziert"*
(`?error=oidc_email_not_verified`).

Ursache ist das **Standard-Scope-Mapping dieser Authentik-Version**
(*authentik default OAuth Mapping: OpenID 'email'*), das den Wert hart
verdrahtet liefert:

```python
return {
    "email": request.user.email,
    "email_verified": False
}
```

Authentik führt selbst keine E-Mail-Verifizierung durch und meldet das ehrlich;
Wallos prüft ebenso korrekt. Beide Seiten verhalten sich richtig — die
Vertrauensentscheidung muss trotzdem jemand treffen.

**Sie wurde bewusst auf der Wallos-Seite getroffen, nicht in Authentik.** Das
Mapping ist das *geteilte* Standard-Mapping aller OIDC-Anwendungen (Paperless,
Immich, Taiga …). Ein `True` dort würde eine Verifizierung behaupten, die nie
stattgefunden hat, und das für jeden Consumer gleichzeitig. Die Env-Variable
wirkt dagegen nur auf Wallos.

Das Risiko, das der Schutz adressiert, beschreibt Wallos im Quelltext selbst
als *"account takeover […] at a permissive or attacker-controlled IdP"*. Der
IdP ist hier das eigene Authentik im eigenen Netz.

> Wer das anders lösen will: ein **eigenes** Scope-Mapping nur für den
> Wallos-Provider anlegen (nicht das Standard-Mapping ändern) und dort
> `email_verified: True` setzen. Dann kann die Env-Variable entfallen.
