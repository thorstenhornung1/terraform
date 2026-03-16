# Platform Extension Requirements — Stack Deployment

**Scope:** Docker Swarm Stack-Definitionen fuer Authentik (SSO/IdP), Paperless-ngx
(Dokumentenmanagement) und Valkey (Redis-kompatibler Cache-Cluster). Alle Services
nutzen die bestehende Infrastruktur (Patroni PostgreSQL, Traefik, CephFS).

**Erstellt:** 2026-03-07
**Status:** Requirements — bereit fuer Implementierung

---

## Deployment-Reihenfolge (STRIKT)

```
Phase 1: postgres-ha-stack erweitern (DB-Secrets + db-init.sh)
Phase 2: Valkey-Cluster deployen (eigener Stack)
Phase 3: Authentik Stack deployen + Web-UI Setup
Phase 4: Paperless-ngx Stack deployen + Superuser anlegen
Phase 5: ForwardAuth aktivieren (Paperless Middleware-Label einkommentieren)
```

Jede Phase haengt von der vorherigen ab. Nicht parallelisieren.

---

## Phase 1: postgres-ha-stack Erweiterung

### Neue Docker Secrets erstellen (Portainer UI)

| Secret-Name | Zweck |
|-------------|-------|
| `paperless_db_password` | PostgreSQL Passwort fuer Paperless-ngx |
| `authentik_db_password` | PostgreSQL Passwort fuer Authentik |
| `authentik_secret_key` | Authentik interner Secret Key (mind. 50 Zeichen) |

Secrets werden in Portainer unter "Secrets" angelegt (Swarm-weite Secrets).

### db-init.sh erweitern

Datei: `stacks/infrastructure/postgres-ha/db-init.sh`

Neue Eintraege nach den bestehenden `init_app` Aufrufen (nach `vaultwarden`):

```bash
# --- Paperless-ngx ---
init_app "paperless" "/run/secrets/paperless_db_password"

# --- Authentik ---
init_app "authentik" "/run/secrets/authentik_db_password"
```

### postgres-ha-stack.yml erweitern

Datei: `stacks/infrastructure/postgres-ha/postgres-ha-stack.yml`

1. **Neue Secrets** im `secrets:`-Block (Top-Level):
   ```yaml
   secrets:
     # ... bestehende Secrets ...
     paperless_db_password:
       external: true
     authentik_db_password:
       external: true
   ```

2. **db-init Service** — neue Secrets mounten:
   ```yaml
   db-init:
     # ... bestehende Config ...
     secrets:
       - pg_superuser_password
       - ha_recorder_db_password
       - vaultwarden_db_password
       - paperless_db_password      # NEU
       - authentik_db_password       # NEU
   ```

3. **Stack neu deployen** (Portainer oder manuell):
   ```bash
   docker stack deploy -c postgres-ha-stack.yml postgres-ha-stack
   ```
   Der db-init Service laeuft als One-Shot und erstellt die neuen Datenbanken.

### Verifikation Phase 1

```bash
# Auf einem Infra-Node:
docker exec -it $(docker ps -qf name=haproxy) \
  psql -h 127.0.0.1 -p 5433 -U superuser -d postgres \
  -c "\l" | grep -E "paperless|authentik"
# Erwartet: Beide Datenbanken gelistet
```

---

## Phase 2: Valkey-Cluster

### Architekturentscheidung: Valkey statt Redis

Valkey ist der Linux-Foundation-Fork von Redis (seit Maerz 2024). API-kompatibel,
BSD-lizensiert, aktiv gewartet. Paperless-ngx und Authentik unterstuetzen Valkey
als Drop-in-Replacement ueber die Standard-Redis-URI (`redis://`).

### Stack-Datei: `stacks/infrastructure/valkey/valkey-stack.yml`

Neuen Ordner anlegen: `stacks/infrastructure/valkey/`

**Cluster-Topologie:** 3-Node Valkey-Cluster (ein Replica pro Swarm-Node)

```yaml
version: "3.9"

services:
  valkey-1:
    image: valkey/valkey:8-alpine
    hostname: valkey-1
    command: >
      valkey-server
      --port 6379
      --bind 0.0.0.0
      --protected-mode no
      --maxmemory 128mb
      --maxmemory-policy allkeys-lru
      --appendonly yes
      --appendfsync everysec
      --dir /data
    volumes:
      - valkey-1-data:/data
    networks:
      - valkey-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.app == true
        preferences:
          - spread: node.id
      resources:
        limits:
          memory: 192M
        reservations:
          memory: 64M
      restart_policy:
        condition: any
        delay: 5s

  valkey-2:
    image: valkey/valkey:8-alpine
    hostname: valkey-2
    command: >
      valkey-server
      --port 6379
      --bind 0.0.0.0
      --protected-mode no
      --maxmemory 128mb
      --maxmemory-policy allkeys-lru
      --appendonly yes
      --appendfsync everysec
      --dir /data
      --replicaof valkey-1 6379
    volumes:
      - valkey-2-data:/data
    networks:
      - valkey-network
    depends_on:
      - valkey-1
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.app == true
        preferences:
          - spread: node.id
      resources:
        limits:
          memory: 192M
        reservations:
          memory: 64M
      restart_policy:
        condition: any
        delay: 5s

  valkey-3:
    image: valkey/valkey:8-alpine
    hostname: valkey-3
    command: >
      valkey-server
      --port 6379
      --bind 0.0.0.0
      --protected-mode no
      --maxmemory 128mb
      --maxmemory-policy allkeys-lru
      --appendonly yes
      --appendfsync everysec
      --dir /data
      --replicaof valkey-1 6379
    volumes:
      - valkey-3-data:/data
    networks:
      - valkey-network
    depends_on:
      - valkey-1
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.app == true
        preferences:
          - spread: node.id
      resources:
        limits:
          memory: 192M
        reservations:
          memory: 64M
      restart_policy:
        condition: any
        delay: 5s

  valkey-sentinel-1:
    image: valkey/valkey:8-alpine
    hostname: valkey-sentinel-1
    command: >
      valkey-sentinel /etc/valkey/sentinel.conf
    configs:
      - source: sentinel_conf
        target: /etc/valkey/sentinel.conf
    networks:
      - valkey-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.app == true
        preferences:
          - spread: node.id
      resources:
        limits:
          memory: 64M
      restart_policy:
        condition: any
        delay: 5s

  valkey-sentinel-2:
    image: valkey/valkey:8-alpine
    hostname: valkey-sentinel-2
    command: >
      valkey-sentinel /etc/valkey/sentinel.conf
    configs:
      - source: sentinel_conf
        target: /etc/valkey/sentinel.conf
    networks:
      - valkey-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.app == true
        preferences:
          - spread: node.id
      resources:
        limits:
          memory: 64M
      restart_policy:
        condition: any
        delay: 5s

  valkey-sentinel-3:
    image: valkey/valkey:8-alpine
    hostname: valkey-sentinel-3
    command: >
      valkey-sentinel /etc/valkey/sentinel.conf
    configs:
      - source: sentinel_conf
        target: /etc/valkey/sentinel.conf
    networks:
      - valkey-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.app == true
        preferences:
          - spread: node.id
      resources:
        limits:
          memory: 64M
      restart_policy:
        condition: any
        delay: 5s

volumes:
  valkey-1-data:
  valkey-2-data:
  valkey-3-data:

configs:
  sentinel_conf:
    name: valkey_sentinel_${SENTINEL_CONF_HASH:-latest}
    file: ./sentinel.conf

networks:
  valkey-network:
    driver: overlay
    attachable: true
```

### Sentinel-Konfiguration: `stacks/infrastructure/valkey/sentinel.conf`

```
port 26379
sentinel monitor mymaster valkey-1 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 10000
sentinel parallel-syncs mymaster 1
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
```

**Erklaerung:** 3 Sentinel-Instanzen ueberwachen den Master (valkey-1). Bei Ausfall
wird automatisch ein Replica zum Master befrdert. `quorum=2` (2 von 3 muessen
zustimmen). Paperless und Authentik verbinden sich via `redis://valkey-1:6379` — bei
Failover uebernimmt ein anderer Node die valkey-1 DNS-Aufloesung im Overlay.

### Warum Sentinel statt Redis-Cluster-Mode

| Aspekt | Sentinel | Redis-Cluster-Mode |
|--------|----------|--------------------|
| Komplexitaet | Gering — 1 Master + N Replicas | Hoch — Slot-Hashing, Resharding |
| Client-Support | Standard `redis://` URI | Erfordert Cluster-faehigen Client |
| Paperless/Authentik | Voll kompatibel | Nicht alle Libraries unterstuetzen Cluster |
| Failover | Automatisch via Sentinel | Automatisch, aber komplexer |
| Datenvolumen | Passt — Homelab-Scale | Ueberdimensioniert |

**Entscheidung:** Sentinel-Mode. Maximale Kompatibilitaet bei ausreichender HA.

### Netzwerk-Anbindung fuer Consumer

Andere Stacks (Paperless, Authentik) verbinden sich via externes Netzwerk:

```yaml
# In paperless-stack.yml / authentik-stack.yml:
networks:
  valkey-stack_valkey-network:
    external: true
```

Redis-URI fuer Consumer: `redis://valkey-1:6379/0` (DB 0 fuer Paperless),
`redis://valkey-1:6379/1` (DB 1 fuer Authentik).

### Verifikation Phase 2

```bash
# Cluster-Status
docker exec $(docker ps -qf name=valkey-1) valkey-cli info replication
# Erwartet: role:master, connected_slaves:2

# Sentinel-Status
docker exec $(docker ps -qf name=sentinel-1) valkey-cli -p 26379 sentinel masters
# Erwartet: mymaster, num-slaves=2, num-sentinels=3

# Failover testen
docker service scale valkey-stack_valkey-1=0
# Warten 10s, dann:
docker exec $(docker ps -qf name=sentinel-1) valkey-cli -p 26379 sentinel get-master-addr-by-name mymaster
# Erwartet: valkey-2 oder valkey-3 wurde zum Master
```

---

## Phase 3: Authentik Stack

### Stack-Datei: `stacks/apps/authentik/authentik-stack.yml`

Neuen Ordner anlegen: `stacks/apps/authentik/`

```yaml
version: "3.9"

services:
  authentik-server:
    image: ghcr.io/goauthentik/server:2025.2
    command: server
    environment:
      AUTHENTIK_POSTGRESQL__HOST: pg-haproxy
      AUTHENTIK_POSTGRESQL__PORT: "5433"
      AUTHENTIK_POSTGRESQL__USER: authentik
      AUTHENTIK_POSTGRESQL__NAME: authentik
      AUTHENTIK_POSTGRESQL__PASSWORD: file:///run/secrets/authentik_db_password
      AUTHENTIK_SECRET_KEY: file:///run/secrets/authentik_secret_key
      AUTHENTIK_REDIS__HOST: valkey-1
      AUTHENTIK_REDIS__PORT: "6379"
      AUTHENTIK_REDIS__DB: "1"
      AUTHENTIK_ERROR_REPORTING__ENABLED: "false"
      AUTHENTIK_LOG_LEVEL: info
    volumes:
      - /mnt/cephfs/swarm-state/stack-authentik/media:/media
      - /mnt/cephfs/swarm-state/stack-authentik/certs:/certs
    secrets:
      - authentik_db_password
      - authentik_secret_key
    networks:
      - traefik_public
      - postgres-ha-stack_postgres-network
      - valkey-stack_valkey-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.app == true
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 512M
      labels:
        - "traefik.enable=true"
        - "traefik.docker.network=traefik_public"
        # HTTPS Router
        - "traefik.http.routers.authentik.rule=Host(`auth.hornung-bn.de`)"
        - "traefik.http.routers.authentik.entrypoints=websecure"
        - "traefik.http.routers.authentik.tls=true"
        - "traefik.http.routers.authentik.tls.certresolver=dns"
        - "traefik.http.routers.authentik.service=authentik"
        - "traefik.http.services.authentik.loadbalancer.server.port=9000"
        # HTTP -> HTTPS Redirect
        - "traefik.http.routers.authentik-http.rule=Host(`auth.hornung-bn.de`)"
        - "traefik.http.routers.authentik-http.entrypoints=web"
        - "traefik.http.routers.authentik-http.middlewares=https-redirect@docker"
        # ForwardAuth Middleware (fuer andere Services)
        - "traefik.http.middlewares.authentik-forwardauth.forwardAuth.address=http://authentik-server:9000/outpost.goauthentik.io/auth/traefik"
        - "traefik.http.middlewares.authentik-forwardauth.forwardAuth.trustForwardHeader=true"
        - "traefik.http.middlewares.authentik-forwardauth.forwardAuth.authResponseHeaders=X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid,X-authentik-jwt,X-authentik-meta-jwks,X-authentik-meta-outpost,X-authentik-meta-provider,X-authentik-meta-app,X-authentik-meta-version"
      restart_policy:
        condition: any
        delay: 10s

  authentik-worker:
    image: ghcr.io/goauthentik/server:2025.2
    command: worker
    environment:
      AUTHENTIK_POSTGRESQL__HOST: pg-haproxy
      AUTHENTIK_POSTGRESQL__PORT: "5433"
      AUTHENTIK_POSTGRESQL__USER: authentik
      AUTHENTIK_POSTGRESQL__NAME: authentik
      AUTHENTIK_POSTGRESQL__PASSWORD: file:///run/secrets/authentik_db_password
      AUTHENTIK_SECRET_KEY: file:///run/secrets/authentik_secret_key
      AUTHENTIK_REDIS__HOST: valkey-1
      AUTHENTIK_REDIS__PORT: "6379"
      AUTHENTIK_REDIS__DB: "1"
      AUTHENTIK_ERROR_REPORTING__ENABLED: "false"
      AUTHENTIK_LOG_LEVEL: info
    volumes:
      - /mnt/cephfs/swarm-state/stack-authentik/media:/media
      - /mnt/cephfs/swarm-state/stack-authentik/certs:/certs
    secrets:
      - authentik_db_password
      - authentik_secret_key
    networks:
      - postgres-ha-stack_postgres-network
      - valkey-stack_valkey-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.app == true
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 512M
      restart_policy:
        condition: any
        delay: 10s

secrets:
  authentik_db_password:
    external: true
  authentik_secret_key:
    external: true

networks:
  traefik_public:
    external: true
  postgres-ha-stack_postgres-network:
    external: true
  valkey-stack_valkey-network:
    external: true
```

### Authentik Image-Version

**Empfehlung:** `2025.2` (aktuelles Stable Release). Authentik hat seit Ende 2024
keinen separaten Redis fuer den Worker — ein einzelner Valkey/Redis reicht fuer
Server + Worker.

**WICHTIG: `file:///run/secrets/` Syntax pruefen!** Authentik unterstuetzt seit
2024.6+ das direkte Lesen von Docker Secrets via `file:///` Prefix in Umgebungsvariablen.
Bei aelteren Versionen muss stattdessen die Umgebungsvariable den Klartext-Wert enthalten
(dann Entrypoint-Wrapper noetig analog Vaultwarden). **Bei Implementierung Version
verifizieren und ggf. anpassen.**

### ForwardAuth-Middleware

Die Middleware `authentik-forwardauth` wird als Traefik-Label auf dem authentik-server
definiert und steht dann cluster-weit zur Verfuegung. Andere Services aktivieren
ForwardAuth durch:

```yaml
# Auf einem geschuetzten Service:
deploy:
  labels:
    - "traefik.http.routers.myapp.middlewares=authentik-forwardauth@docker"
```

### Manuelle Post-Deployment-Schritte

1. **Erster Login:** `https://auth.hornung-bn.de/if/flow/initial-setup/`
   - Admin-Account anlegen (Username + Passwort)
2. **Embedded Outpost** verifizieren:
   - Admin > Outposts > "authentik Embedded Outpost" — muss "Connected" zeigen
3. **Application + Provider** fuer Paperless anlegen (Phase 5):
   - Provider: "Proxy Provider" > Forward Auth (Single Application)
   - External Host: `https://paperless.hornung-bn.de`
   - Application: Name "Paperless", Provider zuweisen

### Verifikation Phase 3

```bash
# Service-Status
docker service ls | grep authentik
# Erwartet: authentik-server 1/1, authentik-worker 1/1

# Login-Page
curl -sf https://auth.hornung-bn.de/ -o /dev/null -w "%{http_code}"
# Erwartet: 200 oder 302

# Authentik Healthcheck
curl -sf https://auth.hornung-bn.de/-/health/live/
# Erwartet: 200
```

---

## Phase 4: Paperless-ngx Stack

### Stack-Datei: `stacks/apps/paperless/paperless-stack.yml`

Neuen Ordner anlegen: `stacks/apps/paperless/`

```yaml
version: "3.9"

services:
  paperless-webserver:
    image: ghcr.io/paperless-ngx/paperless-ngx:2.15
    environment:
      PAPERLESS_DBENGINE: postgresql
      PAPERLESS_DBHOST: pg-haproxy
      PAPERLESS_DBPORT: "5433"
      PAPERLESS_DBNAME: paperless
      PAPERLESS_DBUSER: paperless
      PAPERLESS_DBPASS: /run/secrets/paperless_db_password
      PAPERLESS_REDIS: redis://valkey-1:6379/0
      PAPERLESS_TIKA_ENABLED: "1"
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT: http://gotenberg:3000
      PAPERLESS_TIKA_ENDPOINT: http://tika:9998
      PAPERLESS_URL: https://paperless.hornung-bn.de
      PAPERLESS_SECRET_KEY: /run/secrets/paperless_secret_key
      PAPERLESS_TIME_ZONE: Europe/Berlin
      PAPERLESS_OCR_LANGUAGE: deu+eng
      PAPERLESS_OCR_MODE: skip
      PAPERLESS_CONSUMER_POLLING: "30"
      PAPERLESS_CONSUMER_RECURSIVE: "true"
      PAPERLESS_FILENAME_FORMAT: "{created_year}/{correspondent}/{title}"
      PAPERLESS_TASK_WORKERS: "2"
      PAPERLESS_THREADS_PER_WORKER: "2"
      USERMAP_UID: "1000"
      USERMAP_GID: "1000"
    volumes:
      - /mnt/cephfs/swarm-state/stack-paperless/data:/usr/src/paperless/data
      - /mnt/cephfs/swarm-state/stack-paperless/media:/usr/src/paperless/media
      - /mnt/cephfs/swarm-state/stack-paperless/export:/usr/src/paperless/export
      - /mnt/cephfs/swarm-state/stack-paperless/consume:/usr/src/paperless/consume
    secrets:
      - paperless_db_password
      - paperless_secret_key
    networks:
      - traefik_public
      - postgres-ha-stack_postgres-network
      - valkey-stack_valkey-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.app == true
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 512M
      labels:
        - "traefik.enable=true"
        - "traefik.docker.network=traefik_public"
        # HTTPS Router
        - "traefik.http.routers.paperless.rule=Host(`paperless.hornung-bn.de`)"
        - "traefik.http.routers.paperless.entrypoints=websecure"
        - "traefik.http.routers.paperless.tls=true"
        - "traefik.http.routers.paperless.tls.certresolver=dns"
        - "traefik.http.routers.paperless.service=paperless"
        - "traefik.http.services.paperless.loadbalancer.server.port=8000"
        # HTTP -> HTTPS Redirect
        - "traefik.http.routers.paperless-http.rule=Host(`paperless.hornung-bn.de`)"
        - "traefik.http.routers.paperless-http.entrypoints=web"
        - "traefik.http.routers.paperless-http.middlewares=https-redirect@docker"
        ## ForwardAuth via Authentik (INITIAL AUSKOMMENTIERT — Phase 5 aktivieren)
        #- "traefik.http.routers.paperless.middlewares=authentik-forwardauth@docker"
      restart_policy:
        condition: any
        delay: 10s

  tika:
    image: apache/tika:3.1.0
    networks:
      - default
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.app == true
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 256M
      restart_policy:
        condition: any
        delay: 5s

  gotenberg:
    image: gotenberg/gotenberg:8.17
    command:
      - "gotenberg"
      - "--chromium-disable-javascript=true"
      - "--chromium-allow-list=file:///tmp/.*"
      - "--api-timeout=120s"
    networks:
      - default
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.app == true
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 256M
      restart_policy:
        condition: any
        delay: 5s

secrets:
  paperless_db_password:
    external: true
  paperless_secret_key:
    external: true

networks:
  default:
    driver: overlay
  traefik_public:
    external: true
  postgres-ha-stack_postgres-network:
    external: true
  valkey-stack_valkey-network:
    external: true
```

### Neue Docker Secrets (Portainer UI)

| Secret-Name | Zweck |
|-------------|-------|
| `paperless_secret_key` | Django Secret Key (mind. 50 Zeichen, zufaellig generiert) |

(`paperless_db_password` wurde bereits in Phase 1 erstellt.)

### Paperless-ngx Secret-Handling

**WICHTIG: `PAPERLESS_DBPASS` und `PAPERLESS_SECRET_KEY` Syntax pruefen!**

Paperless-ngx unterstuetzt seit v2.x das Lesen von Docker Secrets via Pfad-Angabe:
- `PAPERLESS_DBPASS=/run/secrets/paperless_db_password` (Pfad zur Secret-Datei)
- `PAPERLESS_SECRET_KEY=/run/secrets/paperless_secret_key`

Falls die Version dies NICHT unterstuetzt, Entrypoint-Wrapper analog Vaultwarden verwenden:
```bash
export PAPERLESS_DBPASS=$(cat /run/secrets/paperless_db_password)
export PAPERLESS_SECRET_KEY=$(cat /run/secrets/paperless_secret_key)
exec /usr/local/bin/paperless-ngx "$@"
```

### Consumer-Hinweis

Paperless-ngx fuehrt den Consumer-Prozess intern via `supervisord` aus — der Webserver-
Container uebernimmt auch das Polling des `/consume` Verzeichnisses. Kein separater
Swarm-Service noetig. Steuerung via `PAPERLESS_CONSUMER_POLLING=30` (alle 30 Sekunden).

### Superuser anlegen (nach Deployment)

```bash
docker exec -it $(docker ps -qf name=paperless-webserver) \
  python3 manage.py createsuperuser
```

### Verifikation Phase 4

```bash
# Service-Status
docker service ls | grep paperless
# Erwartet: paperless-webserver 1/1, tika 1/1, gotenberg 1/1

# Login-Page
curl -sf https://paperless.hornung-bn.de/accounts/login/ -o /dev/null -w "%{http_code}"
# Erwartet: 200

# API Check
curl -sf https://paperless.hornung-bn.de/api/ -o /dev/null -w "%{http_code}"
# Erwartet: 200 oder 403

# Consumer-Test: Datei in consume-Verzeichnis legen
cp /tmp/test.pdf /mnt/cephfs/swarm-state/stack-paperless/consume/
# Warten ~60s, dann Paperless UI pruefen
```

---

## Phase 5: ForwardAuth aktivieren

### Voraussetzungen

1. Authentik laeuft und ist erreichbar
2. Application + Provider fuer Paperless in Authentik konfiguriert
3. Embedded Outpost verbunden

### Aktivierung

In `stacks/apps/paperless/paperless-stack.yml` die auskommentierte Zeile einkommentieren:

```yaml
# VORHER (auskommentiert):
#- "traefik.http.routers.paperless.middlewares=authentik-forwardauth@docker"

# NACHHER (aktiv):
- "traefik.http.routers.paperless.middlewares=authentik-forwardauth@docker"
```

Stack neu deployen:
```bash
docker stack deploy -c paperless-stack.yml paperless-stack
```

### Verifikation Phase 5

```bash
# Ohne Authentik-Session:
curl -sf https://paperless.hornung-bn.de/ -o /dev/null -w "%{http_code}"
# Erwartet: 302 (Redirect zu auth.hornung-bn.de)

# Mit gueltigem Authentik-Cookie: normaler Paperless-Zugriff
```

---

## webhooks.conf Ergaenzungen

Neue Eintraege nach den bestehenden Zeilen:

```
# Valkey (Portainer webhook — keine Docker Configs)
stacks/infrastructure/valkey/valkey-stack.yml=<PORTAINER_WEBHOOK_UUID>

# Authentik (Portainer webhook — keine Docker Configs)
stacks/apps/authentik/authentik-stack.yml=<PORTAINER_WEBHOOK_UUID>

# Paperless (Portainer webhook — keine Docker Configs)
stacks/apps/paperless/paperless-stack.yml=<PORTAINER_WEBHOOK_UUID>
```

**Hinweis:** Die Portainer Webhook UUIDs entstehen erst nach Erstellung der Stacks in
Portainer (Repository-Mode). `<PORTAINER_WEBHOOK_UUID>` ist ein Platzhalter.

Falls Docker Configs spaeter benoetigt werden (z.B. Sentinel-Config bei Valkey),
auf `ssh-deploy` mit Content-Hash umstellen (analog Vaultwarden).

---

## CephFS-Verzeichnisse (vor Deployment anlegen)

```bash
# Auf einem beliebigen Infra-Node (z.B. docker-infra-1):

# Paperless-ngx
mkdir -p /mnt/cephfs/swarm-state/stack-paperless/{data,media,export,consume}
chown -R 1000:1000 /mnt/cephfs/swarm-state/stack-paperless

# Authentik
mkdir -p /mnt/cephfs/swarm-state/stack-authentik/{media,certs}
chown -R 1000:1000 /mnt/cephfs/swarm-state/stack-authentik
```

### PBS Backup

Automatisch abgedeckt — `pbs-backup-stack.yml` mounted `/mnt/cephfs/swarm-state/`
als Read-Only Volume. Alle neuen Unterverzeichnisse werden automatisch mit gesichert.

---

## Ressourcen-Uebersicht

| Service | Memory Limit | Memory Reserve | CPU |
|---------|-------------|----------------|-----|
| Valkey (x3) | 192 MB | 64 MB | shared |
| Valkey Sentinel (x3) | 64 MB | — | shared |
| Authentik Server | 1 GB | 512 MB | shared |
| Authentik Worker | 1 GB | 512 MB | shared |
| Paperless Webserver | 2 GB | 512 MB | shared |
| Tika | 1 GB | 256 MB | shared |
| Gotenberg | 1 GB | 256 MB | shared |
| **Gesamt** | **~7.4 GB** | **~2.4 GB** | — |

Die 3 Infra-Nodes haben je 16 GB RAM. Mit bestehenden Services (~8 GB genutzt)
bleiben ~40 GB frei ueber den Cluster. Ausreichend.

---

## Netzwerk-Topologie

```
                    ┌──────────────────┐
                    │   traefik_public  │
                    └───┬──────┬───────┘
                        │      │
              ┌─────────┘      └─────────┐
              │                          │
     ┌────────┴────────┐       ┌─────────┴────────┐
     │ authentik-server │       │ paperless-websvr  │
     │   (auth.h-bn.de)│       │ (paperless.h-bn)  │
     └───┬────────┬────┘       └───┬─────────┬─────┘
         │        │                │         │
    ┌────┘   ┌────┘           ┌────┘    ┌────┘
    │        │                │         │
┌───┴────┐ ┌─┴──────────┐ ┌──┴───┐  ┌──┴──────────┐
│ Valkey │ │ PostgreSQL  │ │Valkey│  │ PostgreSQL   │
│ (DB 1) │ │ via HAProxy │ │(DB 0)│  │ via HAProxy  │
└────────┘ │ :5433       │ └──────┘  │ :5433        │
           └─────────────┘           └──────────────┘

    ┌────────────────────────────────────────────┐
    │        valkey-stack_valkey-network          │
    │  valkey-1 (M) ←→ valkey-2 (R) ←→ valkey-3 │
    │  sentinel-1    sentinel-2    sentinel-3     │
    └────────────────────────────────────────────┘
```

---

## Offene Pruefpunkte fuer die Implementierung

1. **Authentik `file:///` Syntax:** Verifizieren ob die gewaehlte Authentik-Version
   Docker Secrets via `file:///run/secrets/` Prefix in Environment-Variablen liest.
   Falls nicht: Entrypoint-Wrapper analog Vaultwarden erstellen.

2. **Paperless Secret-Pfade:** Pruefen ob `PAPERLESS_DBPASS=/run/secrets/...` als
   Pfad interpretiert wird (v2.x Feature). Falls nicht: `$(cat ...)` Wrapper.

3. **Valkey Sentinel Failover:** Nach Deployment Failover testen (valkey-1 skalieren
   auf 0, pruefen ob Sentinel automatisch neuen Master waehlt).

4. **Paperless Consumer:** Das Standard-Image fuehrt den Consumer intern via
   `supervisord` aus. KEIN separater Swarm-Service noetig. Falls Probleme auftreten,
   `PAPERLESS_CONSUMER_POLLING` erhoehen.

5. **Portainer Webhook UUIDs:** Entstehen erst nach Stack-Erstellung in Portainer.
   In `webhooks.conf` nachtragen.

6. **Traefik `https-redirect` Middleware:** Muss bereits existieren (wird von Traefik-
   Stack bereitgestellt). Falls nicht vorhanden, im Traefik-Stack definieren.

---

## Referenz-Dateien

| Datei | Verwendung |
|-------|-----------|
| `stacks/infrastructure/postgres-ha/db-init.sh` | DB-Init erweitern (Phase 1) |
| `stacks/infrastructure/postgres-ha/postgres-ha-stack.yml` | Secrets hinzufuegen (Phase 1) |
| `stacks/apps/vaultwarden/vaultwarden-stack.yml` | Multi-Network + Secrets Pattern |
| `stacks/apps/frigate/docker-compose.yml` | Secrets-to-Volume Pattern |
| `stacks/traefik/traefik-stack.yml` | Traefik-Label Referenz |
| `webhooks.conf` | Deploy-Mode Referenz |
