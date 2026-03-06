# Frigate Dual-Router — Viewer (HA Dashboard) + Admin (BasicAuth)

**Datum:** 2026-03-06
**Frigate:** 0.17.0-rc3 auf LXC 4502 (192.168.4.70, pve03)
**Traefik:** v3.6 als Sidecar mit Let's Encrypt DNS-01 (Cloudflare)

## Architektur

```
HA Dashboard (iframe)
  -> https://frigate.hornung-bn.de
    -> Traefik Router "frigate-viewer"
      -> Middleware: IP-Whitelist (192.168.0.0/16) + Header-Inject (Remote-User: homeassistant)
      -> Backend: frigate:8971 (nginx -> FastAPI Proxy-Auth -> Viewer-Rolle)

Admin (Browser direkt)
  -> https://admin.frigate.hornung-bn.de
    -> Traefik Router "frigate-admin"
      -> Middleware: BasicAuth + Header-Inject (Remote-User: homeassistant, Remote-Groups: admin)
      -> Backend: frigate:8971 (nginx -> FastAPI Proxy-Auth -> Admin-Rolle)
```

Beide Router zeigen auf Port **8971** (nginx mit Rollen-Enforcement).
Port 5000 (intern, unauthentifiziert) wird NICHT exponiert.

## Zugriff

| URL | Auth | Rolle | Zweck |
|-----|------|-------|-------|
| `https://frigate.hornung-bn.de` | IP-Whitelist (internes Netz) | viewer | HA Dashboard iframe |
| `https://admin.frigate.hornung-bn.de` | BasicAuth (admin/pw) | admin | Konfiguration, User-Management |

**Admin-Credentials:** Username `admin`, Passwort in `docker-compose.yml` (htpasswd bcrypt Hash).

## Konfiguration

### config.yml (Frigate)

```yaml
auth:
  enabled: false               # MUSS false sein fuer Proxy-Auth
  trusted_proxies:
    - 172.16.0.0/12            # Docker Bridge-Netzwerke (Traefik -> Frigate)

proxy:
  header_map:
    user: Remote-User          # Traefik setzt diesen Header
    role: Remote-Groups        # NICHT Remote-Role (nginx Whitelist!)
  default_role: viewer         # Ohne explizite Rolle -> Viewer
```

### docker-compose.yml (Traefik Labels)

**Viewer-Router:**
- `Host(frigate.hornung-bn.de)` auf `websecure` Entrypoint
- Middlewares: `viewer-ipwhitelist` (192.168.0.0/16, 172.16.0.0/12, 10.0.0.0/8) + `viewer-headers` (Remote-User: homeassistant)

**Admin-Router:**
- `Host(admin.frigate.hornung-bn.de)` auf `websecure` Entrypoint
- Middlewares: `admin-basicauth` (htpasswd) + `admin-headers` (Remote-User: homeassistant, Remote-Groups: admin)

**Shared Service:**
- `frigate-backend` auf Port 8971 mit HTTPS-Backend-Schema

### DNS

- `frigate.hornung-bn.de` -> 192.168.4.70 (A-Record, Technitium)
- `admin.frigate.hornung-bn.de` -> 192.168.4.70 (A-Record, Technitium)

## Auth-Flow im Detail

```
1. Request an frigate.hornung-bn.de
2. Traefik: IP-Whitelist prueft Source-IP (nur internes Netz)
3. Traefik: viewer-headers Middleware injiziert Remote-User: homeassistant
4. Traefik -> nginx:8971 (HTTPS)
5. nginx: auth_request Subrequest an FastAPI /auth (127.0.0.1:5001)
   - proxy_trusted_headers.conf leitet Remote-User weiter
   - FastAPI prueft: auth.enabled=false -> Proxy-Auth aktiv
   - FastAPI liest Remote-User aus header_map.user
   - Keine Remote-Groups -> default_role: viewer
6. FastAPI antwortet 202 mit remote-user: homeassistant, remote-role: viewer
7. nginx leitet Request an FastAPI Backend weiter (mit Rolle)
8. Frigate UI laedt als Viewer (kein Login-Prompt)
```

## Gotchas und Lessons Learned

### 1. auth.enabled MUSS false sein

`auth.enabled: true` aktiviert Frigates eigenes Login-System und **blockiert Proxy-Auth komplett**.
Proxy-Auth funktioniert NUR mit `auth.enabled: false`.

### 2. Remote-Role wird von nginx gedroppt

Frigates nginx hat eine Header-Whitelist (`proxy_trusted_headers.conf`) fuer die Auth-Subrequest
an FastAPI. Folgende Headers werden weitergeleitet:

- `Remote-User`, `Remote-Groups`, `Remote-Email`, `Remote-Name`
- `X-Forwarded-User`, `X-Forwarded-Groups`, `X-Forwarded-Email`
- `X-Auth-Request-*`, `X-authentik-*`

**`Remote-Role` ist NICHT in der Liste!** Deshalb `Remote-Groups` fuer Rollen-Mapping verwenden:
```yaml
proxy:
  header_map:
    role: Remote-Groups    # NICHT Remote-Role
```

### 3. BasicAuth htpasswd in Docker Labels

Dollar-Zeichen im bcrypt Hash muessen in Docker Compose Labels **verdoppelt** werden:
```yaml
- "traefik.http.middlewares.admin-basicauth.basicauth.users=admin:$$2y$$05$$..."
#                                                                ^^ ^^ ^^
```

### 4. Frigate User werden automatisch erstellt

Wenn Proxy-Auth einen unbekannten `Remote-User` sendet, erstellt Frigate den User automatisch
mit der `default_role` (viewer). Kein manuelles User-Setup noetig.

### 5. Bestehende User-Datenbank bleibt erhalten

Das Umschalten von `auth.enabled: true` auf `false` loescht KEINE bestehenden User
aus `frigate.db`. Die DB liegt auf Ceph RBD (`/db/frigate.db`) und ist persistent.

## Verifikation

```bash
# Viewer: 200 ohne Login
curl -sk https://frigate.hornung-bn.de/api/config | head -1

# Admin ohne Auth: 401
curl -sk -o /dev/null -w '%{http_code}' https://admin.frigate.hornung-bn.de/api/config

# Admin mit Auth: 200 + Admin-Rolle
curl -sk -u 'admin:PASSWORD' https://admin.frigate.hornung-bn.de/api/users

# Proxy-Auth Debug (innerhalb Container)
docker exec frigate curl -s -D- \
  -H 'Remote-User: homeassistant' \
  -H 'Remote-Groups: admin' \
  -H 'X-Original-URL: https://admin.frigate.hornung-bn.de/' \
  -H 'X-Server-Port: 8971' \
  http://127.0.0.1:5001/auth
# -> 202 Accepted, remote-role: admin
```

## Dateien

| Datei | Beschreibung |
|-------|-------------|
| `stacks/apps/frigate/config.yml` | Frigate Config mit auth + proxy Abschnitt |
| `stacks/apps/frigate/docker-compose.yml` | Traefik Labels (2 Router, 4 Middlewares) |
| `stacks/apps/frigate/traefik.yml` | Traefik static Config (unveraendert) |
| `docs/FRIGATE-DUAL-ROUTER.md` | Diese Dokumentation |

## Passwort aendern

```bash
# Neuen htpasswd Hash generieren
htpasswd -nbB admin NEUES_PASSWORT

# Hash in docker-compose.yml ersetzen ($ verdoppeln!)
# Dann: deploy
scp docker-compose.yml root@192.168.4.70:/opt/frigate/compose/
ssh root@192.168.4.70 "cd /opt/frigate/compose && docker compose up -d --force-recreate"
```
