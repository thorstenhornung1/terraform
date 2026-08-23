# email-oauth2-proxy — O365 OAuth2 ⇄ plain-IMAP Bridge

Brücke, damit **Open Archiver** O365-Postfächer per **OAuth (app-only)** ziehen kann,
obwohl M365 Basic-Auth-IMAP tenant-weit blockiert. Der Proxy spricht O365 per
**Client-Credentials-Grant** an (outbound IMAPS, kein eingehender Port / keine fixe
öffentliche IP) und bietet intern plain-IMAP an.

- **Image:** `ghcr.io/thorstenhornung1/swarm-stacks/email-oauth2-proxy` (GHA-Build aus `images/email-oauth2-proxy/`)
- **Upstream:** [simonrob/email-oauth2-proxy](https://github.com/simonrob/email-oauth2-proxy) (Apache-2.0)
- **Overlay:** `email-oauth2-proxy_imap-network` (attachable) → OA joint extern
- **Endpoint (intern):** `email-oauth2-proxy:1993` — Login = Postfach-Adresse

## Warum das den per-Person-Zugriff in OA löst

OAs RBAC ist **ownership-basiert**: ein End-User sieht nur Mails aus Quellen, die ihm
gehören. Die M365-Multi-Mailbox-Quelle (holt alle Postfächer) passt dazu nicht. Dieser
Proxy macht aus O365 ein **single-mailbox plain-IMAP pro Postfach** → in OA legt man
**pro Person eine Generic-IMAP-Quelle** an (Ownership = Person, Rolle „End user") →
jede:r sieht nur sein Postfach, Admin/Auditor alles.

## Voraussetzungen (M365, einmalig)

1. Azure-App-Registrierung mit **`Office 365 Exchange Online → IMAP.AccessAsApp`** (Application) + Admin-Consent
2. Client-Secret → Docker-Secret `oa_oauth_imap`
3. EXO-PowerShell:
   ```powershell
   New-ServicePrincipal -AppId <client-id> -ObjectId <ENTERPRISE-APP-Object-ID> -DisplayName "OpenArchiver IMAP Pull"
   Add-MailboxPermission -Identity <postfach> -User <client-id> -AccessRights FullAccess   # je Postfach
   Test-ApplicationAccessPolicy -Identity <postfach> -AppId <client-id>   # = Granted
   ```
   ⚠️ `IMAP.AccessAsApp` liegt unter „Office 365 Exchange Online" (App-ID `00000002-0000-0ff1-ce00-000000000000`), **nicht** Graph.
   ⚠️ IMAP-Token-Scope ist `https://outlook.office365.com/.default` — Graph-Token funktioniert für IMAP nicht.

## Config

- `O365_CLIENT_ID`, `O365_TENANT_ID`: nicht geheim → ENV im Stack
- `O365_MAILBOXES`: comma-separiert, je ein `[account]`-Block
- `oa_oauth_imap` (Secret): client_secret
- entrypoint generiert `emailproxy.config` aus Secret+ENV nach `/tmp` (nie auf Platte/Git);
  Token-Cache via `--cache-store /cache` (tmpfs, transient)

## Open Archiver Quelle (pro Person)

In OA als **End-User**-Account → Ingestion → **Generic IMAP**:
- Server: `email-oauth2-proxy`, Port `1993`, **kein** SSL (intern plain)
- Username: die Postfach-Adresse (z.B. `thorsten@hornung-bn.de`)
- Passwort: beliebig/Dummy (der Proxy nutzt OAuth, ignoriert das Client-Passwort)

## Deployment

GitOps: `git push` → GHA baut Image (falls geändert) + `deploy-stacks.yml` (ssh-deploy).
Reihenfolge: erst Image bauen lassen, dann Stack deployen.
