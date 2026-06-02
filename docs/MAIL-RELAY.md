# Homelab Mail Sending — Mail-Relay (Variante C)

**Stand:** 2026-06-02 · **Relay:** `relay` @ `192.168.4.71` (LXC VM 4505, pve01) · **Mailbox:** `homelab@hornung-bn.de`

Zentraler Mailversand fürs Homelab. Apps liefern **ohne Zugangsdaten** ins LAN ein; der
Relay authentifiziert sich app-only via Microsoft Graph an M365. Das **einzige Secret**
(Entra Client Secret) liegt nur auf dem Relay-LXC.

---

## TL;DR — wie eine App Mails verschickt

Auf den Relay zeigen, **keine** Credentials:

| Feld | Wert |
|---|---|
| SMTP-Host / Server | `192.168.4.71` |
| Port | `587` (auch `25`) |
| Authentifizierung | **keine** |
| Verschlüsselung / TLS | **keine** (LAN-intern) |
| **Absender (From)** | **`homelab@hornung-bn.de`** ⚠️ Pflicht |

> ⚠️ Das `From` **muss** `homelab@hornung-bn.de` sein. Der Relay sendet via Graph als die
> Mailbox aus der From-Adresse; eine andere Adresse lehnt die ApplicationAccessPolicy ab
> (Graph: „access denied"). Es werden **keine** Docker-Secrets/Passwörter in den Apps benötigt.

---

## Architektur

```
App ──SMTP :587, KEINE Auth (mynetworks)──▶ Postfix (boky, host-net, Queue)
                                                  │ SASL LOGIN + STARTTLS (intern, self-signed)
                                                  ▼
                                           smtp-oauth-relay :8025 (nur 127.0.0.1)
                                                  │ OAuth2 Client Credentials (Client Secret)
                                                  ▼
                                           Graph /users/{id}/sendMail ──▶ Microsoft 365
```

- **Postfix** (`boky/postfix`, `network_mode: host`) nimmt unauthentifiziert aus dem LAN an,
  queued, reicht per SASL+STARTTLS an den Relay weiter. `host-net` → Postfix sieht die
  **echten** Quell-IPs (kein Docker-NAT) → `mynetworks` greift auf IP-Ebene.
- **smtp-oauth-relay** (`ghcr.io/justiniven/smtp-oauth-relay`) lauscht nur auf `127.0.0.1:8025`,
  holt mit `tenant_id@client_id` + Client Secret ein OAuth2-Token und ruft Graph `sendMail`.

---

## Wer darf einliefern (`POSTFIX_mynetworks`)

`127.0.0.0/8, 192.168.4.0/24, 192.168.2.7/32 (PBS), 192.168.2.10/11/12/32 (3 PVEs)`

- **VLAN 4** (`192.168.4.0/24`) deckt alle Swarm-Nodes, LXCs und Apps ab (Swarm-Container
  egress'en über die Node-IP `.40/.41/.42`).
- **PVE/PBS** liefern über ihre Management-IPs ein (pve03 über `.4.16`, von VLAN4 gedeckt).
- Andere Quelle → Postfix antwortet `554 5.7.1 Relay access denied`.
- **Erweitern:** `var.mailrelay_trusted_networks` in `terraform.tfvars`/`mailrelay-lxc.tf` anpassen
  → `terraform apply` (re-provisioniert + `docker compose up -d`).

---

## App-Wiring (Copy-Paste, ohne Secrets)

### Grafana (`stacks/monitoring/monitoring-stack.yml`, Listen-Stil `- GF_…`)
Env beim `grafana`-Service ergänzen:
```yaml
      - GF_SMTP_ENABLED=true
      - GF_SMTP_HOST=192.168.4.71:587
      - GF_SMTP_FROM_ADDRESS=homelab@hornung-bn.de
      - GF_SMTP_FROM_NAME=Grafana Homelab
      - GF_SMTP_SKIP_VERIFY=true
```
Zusätzlich einen **email-Contact-Point** in `stacks/monitoring/alerting/contact-points.yml`
ergänzen (sonst routet nichts dorthin — aktuell nur Telegram):
```yaml
    - orgId: 1
      name: email-homelab
      receivers:
        - uid: email-homelab-1
          type: email
          settings:
            addresses: thorsten@hornung-bn.de
          disableResolveMessage: false
```

### Authentik (`stacks/apps/authentik/authentik-stack.yml`, Map-Stil) — bei **server UND worker**
```yaml
      AUTHENTIK_EMAIL__HOST: "192.168.4.71"
      AUTHENTIK_EMAIL__PORT: "587"
      AUTHENTIK_EMAIL__USE_TLS: "false"
      AUTHENTIK_EMAIL__USE_SSL: "false"
      AUTHENTIK_EMAIL__TIMEOUT: "10"
      AUTHENTIK_EMAIL__FROM: "homelab@hornung-bn.de"
```

### Paperless (`stacks/apps/paperless/paperless-stack.yml`, Swarm-Instanz)
```yaml
      PAPERLESS_EMAIL_HOST: "192.168.4.71"
      PAPERLESS_EMAIL_PORT: "587"
      PAPERLESS_EMAIL_USE_TLS: "false"
      PAPERLESS_EMAIL_USE_SSL: "false"
      PAPERLESS_EMAIL_FROM: "homelab@hornung-bn.de"
```
> Hinweis: Es gibt ein **zweites** Paperless **standalone auf dock01** (192.168.2.14) — das wird
> NICHT über diesen Stack konfiguriert, sondern in seinem eigenen Compose auf dock01.

### Taiga (`stacks/apps/taiga/taiga-stack.yml`) — bei **taiga-back UND taiga-async**
Den `console.EmailBackend` durch SMTP ersetzen + From auf `homelab@`:
```yaml
      EMAIL_BACKEND: "django.core.mail.backends.smtp.EmailBackend"
      EMAIL_HOST: "192.168.4.71"
      EMAIL_PORT: "587"
      EMAIL_USE_TLS: "False"
      EMAIL_USE_SSL: "False"
      DEFAULT_FROM_EMAIL: "homelab@hornung-bn.de"
```

### DocuSeal — **NICHT** per Stack/Env, sondern in der Web-UI
DocuSeal liest SMTP nicht aus Env, sondern speichert es in der DB. In der DocuSeal-Oberfläche:
**Settings → Email** → Host `192.168.4.71`, Port `587`, keine Auth/TLS, From `homelab@hornung-bn.de`.

### Generische App
Irgendein SMTP-Client: Server `192.168.4.71`, Port `587`, **kein** User/Passwort, **keine**
Verschlüsselung, From `homelab@hornung-bn.de`.

---

## Proxmox VE / PBS Notifications

Natives PVE `smtp`-Target (cluster-weit), **keine Auth** — leitet u.a. Backup-Fehler voll per
Mail (der Telegram-Webhook ist wg. 4096-Zeichen-Limit nur Kurz-Alert):
```bash
pvesh create /cluster/notifications/endpoints/smtp --name o365-relay \
  --server 192.168.4.71 --port 587 --mode insecure \
  --from-address homelab@hornung-bn.de --mailto thorsten@hornung-bn.de --author "Proxmox VE"
pvesh set /cluster/notifications/matchers/default-matcher --target telegram-backup --target o365-relay
```
(bereits eingerichtet — `o365-relay` ist im `default-matcher`, severity `error`).

---

## Verifikation / Test (vom LAN, ohne Auth)

```bash
# swaks (falls vorhanden):
swaks --server 192.168.4.71 --port 587 --from homelab@hornung-bn.de \
      --to thorsten@hornung-bn.de --h-Subject "mailrelay test"

# oder python3 (auf jedem Host ohne extra Tool):
python3 - <<'PY'
import smtplib
from email.message import EmailMessage
m=EmailMessage(); m["From"]="homelab@hornung-bn.de"; m["To"]="thorsten@hornung-bn.de"
m["Subject"]="mailrelay test"; m.set_content("test")
s=smtplib.SMTP("192.168.4.71",587,timeout=20); s.send_message(m); s.quit()
PY
```
Erfolg: Relay-Log `Email sent successfully!`, Postfix `status=sent`, `postqueue -p` leer, Mail
kommt mit Absender `homelab@hornung-bn.de` an.

---

## Troubleshooting

| Symptom | Ursache | Fix |
|---|---|---|
| `554 5.7.1 Relay access denied` | Quell-IP nicht in `mynetworks` | echte Egress-IP prüfen (`ip route get 192.168.4.71`); CIDR zu `mailrelay_trusted_networks` |
| Postfix nimmt an, aber Mail kommt nicht | Graph `sendMail` failt | `docker compose logs smtp-oauth-relay`: `401/403`=Secret/Consent, „denied"=From ≠ homelab@ |
| Mail bleibt in Queue (`postqueue -p`) | Relay/Graph nicht erreichbar | Relay-Logs; Egress zu `graph.microsoft.com:443` vom LXC |
| Graph lehnt ab obwohl Secret stimmt | ApplicationAccessPolicy / fehlende From | From MUSS `homelab@`; Policy: `Test-ApplicationAccessPolicy` |
| `AADSTS7000215` im Relay-Log | Client Secret abgelaufen/falsch | neues Entra-Secret → `terraform.tfvars` → `terraform apply` |

---

## Betrieb

- **Secret-Rotation:** neues Client Secret in Entra → `mailrelay_client_secret` in
  `terraform.tfvars` → `terraform apply` (re-provisioniert `/opt/mailrelay/secrets/relay_client_secret`).
  Eine Stelle, keine App anfassen.
- **M365/Entra-Prereqs:** App `smtp-relay-graph` (Mail.Send Application + Admin-Consent),
  Shared Mailbox `homelab@`, `New-ApplicationAccessPolicy RestrictAccess` (App nur als homelab@).
  EXO-PowerShell auf Mac: `brew install --cask powershell@preview` → `pwsh-preview` →
  `Connect-ExchangeOnline -Device` (interaktiver Browser-Login scheitert auf neuem macOS).
- **DKIM:** für `hornung-bn.de` ist DKIM `none` — für **interne** Empfänger (gleicher Tenant)
  egal; bei **externen** Empfängern DKIM in M365 aktivieren.
- **Limits (M365):** ~30 Nachrichten/Min, 10.000 Empfänger/Tag pro Postfach — fürs Homelab unkritisch.

---

## Referenzen

- IaC: `mailrelay-lxc.tf` + `terraform/mailrelay/setup-mailrelay.sh.tpl`
- On-Host: `/opt/mailrelay/docker-compose.yml` (relay 192.168.4.71)
- Plan: `~/.claude/plans/wir-w-rde-hiermit-arbeiten-eventual-deer.md`
