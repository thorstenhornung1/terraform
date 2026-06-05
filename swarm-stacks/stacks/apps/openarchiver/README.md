# Open Archiver — Self-Hosted E-Mail Archive

Zentrales Mailarchiv im Docker Swarm: Microsoft-365-/IMAP-Ingestion,
Volltextsuche über Mails **und** Anhänge (Tika), mbox-Altbestand-Import.

- **URL:** https://archive.hornung-bn.de
- **Image:** `logiclabshq/open-archiver:v0.5.0` (Docker Hub, public)
- **App-Projekt:** https://github.com/LogicLabs-OU/OpenArchiver
- **Stack:** SvelteKit (Frontend 3000 / Backend 4000 / BullMQ-Worker, ein Container)
- **Backend-DB:** Patroni-HA-Postgres (`pg-haproxy:5433`, DB `open_archive`)
- **Index:** Meilisearch auf **CephFS** (`…/stack-openarchiver/meili`, single-writer)
- **Queue:** stack-interne Valkey (`noeviction`!)
- **Mail-Blobs:** **Ceph RGW S3** (`STORAGE_TYPE=s3`, Endpoint `http://s3-rgw`, Bucket `openarchiver`)
- **Auth:** Open Archivers **eigene Benutzerverwaltung** (kein SSO/forwardAuth, s.u.)

## Warum S3 für die Mail-Blobs?

Erwartet werden ~350 GB Mailbestand. Auf CephFS würde jede Mail 3x repliziert auf
jedem App-Node Platz fragmentieren; der Ceph-RGW-S3-Pool ist der dafür gebaute
Objektspeicher (ebenfalls 3x repliziert, aber als Objektpool). Die 3 radosgw-
Daemons (pve01/02/03) hängen hinter dem `s3-rgw`-HAProxy-Stack (HA, Muster wie
`pg-haproxy`); Open Archiver verbindet path-style über das Overlay `s3-rgw_s3-network`.

## Verschlüsselung & Sicherung

`openarchiver_encryption_key` verschlüsselt DB-Felder (u.a. die hinterlegten
Mailbox-/Graph-Credentials). `create-secrets.sh` zeigt ihn einmalig an → in den
Passwortmanager. Bei Verlust bleibt das Archiv lesbar; nur die Ingestion-Quellen
müssen in der UI neu verbunden werden.

Die **Mail-Blobs liegen bewusst unverschlüsselt** im Ceph-RGW-S3-Pool (Homelab-
Entscheidung: Pool 3x repliziert; kein `STORAGE_ENCRYPTION_KEY`). Das vermeidet das
DR-Risiko eines verlorenen Storage-Keys; der Schutz gegen Offline-Diebstahl der
Rohdaten (gestohlene Disk, geleaktes Off-Site-Backup) entfällt dafür.

## Auth: eigene Benutzerverwaltung (kein SSO)

Open Archiver OSS akzeptiert serverseitig **nur** `Authorization: Bearer <JWT>`
und `x-api-key` (verifiziert in `requireAuth.ts`) — es gibt **keinen** Header-/
Proxy-Auto-Login. Ein vorgeschaltetes Traefik-`forwardAuth` (Authentik) würde
daher nur zu einem **Doppel-Login** führen (erst Authentik, dann nochmal Open
Archiver). Deshalb läuft die App mit ihrer eingebauten Benutzerverwaltung; der
erste in der UI angelegte Account ist Admin. Zugriff ist auf VLAN 4/VPN beschränkt.

## Warum diese Architektur-Abweichungen (vs. offizielle compose)?

| Komponente | Offizielle compose | Hier | Grund |
|-----------|--------------------|------|-------|
| PostgreSQL | eigener Container | `pg-haproxy:5433` | Repo-Standard, HA + zentrale PBS-Backups |
| Valkey | eigener Container | stack-intern, `noeviction` | BullMQ-Queue: `allkeys-lru` der zentralen Valkey würde Jobs evicten |
| Mail-Blobs | named volume | Ceph RGW S3 | skaliert auf ~350 GB ohne CephFS-Fragmentierung |
| Meili-Storage | named volume | CephFS, single-writer | LMDB → 1 Replica + `stop-first`; bei Korruption re-index (kein Datenverlust) |
| Secrets | `.env`-Datei | Docker-Secrets via `entrypoint-wrapper.sh` | keine Klartext-Credentials im Git |

## Erstinbetriebnahme

### 1. S3-Bucket anlegen (Ceph RGW)

Die S3-Keys sind bereits als externe Docker-Secrets vorhanden
(`openarchiver_s3_access_key`, `openarchiver_s3_secret_key` — RGW-User). Bucket
einmalig anlegen, z.B. von einem Manager aus über den `s3-rgw`-Endpoint:

```bash
AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \
  aws --endpoint-url http://s3-rgw s3 mb s3://openarchiver
# alternativ direkt auf einem PVE-Node gegen radosgw:
#   radosgw-admin bucket ... / s3cmd mb s3://openarchiver
```

### 2. CephFS-Verzeichnisse (auf einem Manager)

```bash
sudo mkdir -p /mnt/cephfs/swarm-state/stack-openarchiver/{valkey,meili}
sudo chown -R 1000:1000 /mnt/cephfs/swarm-state/stack-openarchiver
```

`/import` ist KEIN CephFS-Dir, sondern ein Docker-NFS-Volume auf den Synology-
Share `email_import` (192.168.2.3:/volume1/email_import, s. VOLUMES im Stack) —
für große mbox-Importe ohne HTTP-Upload-Limit.

### 3. Docker-Secrets (auf einem Manager, z.B. 192.168.4.40)

```bash
./create-secrets.sh
# → ENCRYPTION_KEY extern sichern (Passwortmanager)
# (S3-Keys werden NICHT erzeugt — sie existieren bereits als externe Secrets.)
```

### 4. DB-User + DB anlegen

`stacks/infrastructure/postgres-ha/db-init.sh` ist um
`init_app "openarchiver" "$OPENARCHIVER_PASS" "open_archive"` erweitert, und
`postgres-ha-stack.yml` referenziert `openarchiver_db_password` im `db-init`-Service.
Auslösen durch Redeploy des postgres-ha-Stacks (db-init legt DB + User idempotent an):

```bash
docker stack deploy -c stacks/infrastructure/postgres-ha/postgres-ha-stack.yml postgres-ha-stack
```

### 5. DNS-Eintrag (Technitium)

```
archive.hornung-bn.de  A  <Traefik-VIP>
```

⚠️ Vor dem Setzen verifizieren, auf welche VIP die bestehenden App-Domains zeigen
(`dig +short paperless.hornung-bn.de`) und exakt dieselbe IP verwenden.
⚠️ **In dns1, dns2 UND dns3 EINZELN pflegen** — der Technitium-Cluster
repliziert manuell angelegte Records nicht automatisch (vgl. Reisekosten-NXDOMAIN-Fall).

### 6. Deploy

GitOps via `webhooks.conf` (`...openarchiver-stack.yml=none,ssh-deploy`) — Push
auf `main` triggert die GHA `Deploy stacks`. Manuell:

```bash
ENTRYPOINT_WRAPPER_HASH=$(sha256sum entrypoint-wrapper.sh | cut -c1-12) \
  docker stack deploy -c openarchiver-stack.yml --resolve-image always openarchiver
```

## Post-Deploy: Mailquellen anbinden (Web-UI)

- **Microsoft 365:** Entra-ID-App-Registrierung (App-only Graph-Zugriff, minimale
  Rechte, nur `hornung-bn.de`) → in Open Archiver als Ingestion-Source „Microsoft 365".
- **mbox-Altbestand (große Files):** NICHT per Browser-Upload (internes Payload-
  Limit ~100 MB)! Datei auf den Synology-Share `email_import` legen (NFS
  192.168.2.3:/volume1/email_import, im Container als `/import` gemountet) → UI →
  Ingestion → Mbox → **Local Path** → `/import/<datei>.mbox`.
- **Maildir:** kein nativer Importtyp → vorab nach mbox/eml konvertieren.

## Betrieb

### DB-Passwort rotieren

```bash
# Auf einem Swarm Manager:
NEW_PASS=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)
docker run --rm --network postgres-ha-stack_postgres-network \
  --secret pg_superuser_password postgres:16-alpine sh -c "
    export PGPASSWORD=\$(cat /run/secrets/pg_superuser_password)
    psql -h pg-haproxy -p 5433 -U postgres \
      -c \"ALTER USER openarchiver WITH PASSWORD '$NEW_PASS'\"
  "
docker secret rm openarchiver_db_password
printf '%s' "$NEW_PASS" | docker secret create openarchiver_db_password -
docker service update --force openarchiver_open-archiver
docker service update --force postgres-ha-stack_db-init
```

> Secret-Name **nie** mit Versions-Suffix (`_v2`) — db-init und Stack müssen
> exakt denselben Namen referenzieren (swarm-stacks#37).

### Meili-Index neu aufbauen (bei Korruption)

Der Meili-Index liegt single-writer auf CephFS und ist **vollständig
reindexierbar** (Quelle: Postgres + die Mail-Blobs in S3). Bei „failed to infer
DB version" o.ä.:

```bash
# Service stoppen, data.ms leeren, Service neu starten:
docker service scale openarchiver_openarchiver-meili=0
sudo rm -rf /mnt/cephfs/swarm-state/stack-openarchiver/meili/data.ms
docker service scale openarchiver_openarchiver-meili=1
# danach in der Open-Archiver-UI den Reindex anstoßen
```

### S3-Bucket prüfen

```bash
AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \
  aws --endpoint-url http://s3-rgw s3 ls s3://openarchiver/ --recursive | head
```

## Komponenten-Ports (intern)

| Service | Port | Netz |
|---------|------|------|
| open-archiver | 3000 (FE), 4000 (BE) | traefik_public, postgres-ha, s3-rgw, default |
| openarchiver-meili | 7700 | default |
| openarchiver-valkey | 6379 | default |
| openarchiver-tika | 9998 | default |
