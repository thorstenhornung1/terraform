# Reisekostenabrechnung — Travel Expense Management

Self-hosted Flask app for managing travel-expense reports, with PDF
rendering (WeasyPrint) and PostgreSQL backend.

- **Production URL:** https://reisekosten.hornung-bn.de
- **Image:** `ghcr.io/thorstenhornung1/reisekosten:v2`
- **App repo:** https://github.com/thorstenhornung1/Reisekostenabrechnung (branch `v2-postgres`)
- **Stack:** Flask 3 + Gunicorn + psycopg3 + WeasyPrint
- **Backend:** Patroni HA Postgres cluster (`pg-haproxy:5433`, db `reisekosten`)
- **State:** CephFS at `/mnt/cephfs/swarm-state/stack-reisekosten/{uploads,generated}`

## ⚠️ Phase 1: Public, no authentication

The app is currently exposed publicly without authentication. Travel-expense
data is sensitive (addresses, amounts, IBAN). Phase 2 will add Authentik
OIDC + multi-user support — see the migration plan for details.

## First-time deployment

### 1. Docker secrets (cluster manager, e.g. 192.168.4.40)

```bash
openssl rand -hex 32 | sudo docker secret create reisekosten_secret_key -
openssl rand -hex 24 | sudo docker secret create reisekosten_db_password -
```

### 2. DB user creation

`stacks/infrastructure/postgres-ha/db-init.sh` is extended with
`init_app "reisekosten" "$REISEKOSTEN_PASS" "reisekosten"`. Trigger by
redeploying the postgres-ha stack — `db-init` runs at the next deploy
and creates DB + user idempotently.

### 3. CephFS volumes

```bash
sudo mkdir -p /mnt/cephfs/swarm-state/stack-reisekosten/{uploads,generated}
sudo chown -R 1000:1000 /mnt/cephfs/swarm-state/stack-reisekosten
```

### 4. DNS entry (Technitium)

```
reisekosten.hornung-bn.de  A  192.168.4.100   # Traefik VIP
```

Optional: Cloudflare record for external access (consider Tailscale-only
during Phase 1 to reduce attack surface — see planning doc).

### 5. Deploy

GHA `Deploy stacks` workflow handles this automatically on push to main.
Manual: `docker stack deploy -c reisekosten-stack.yml --resolve-image always reisekosten`.

### 6. Initial data migration (one-time)

From a host with access to both the local SQLite file and the cluster
Postgres (Tailscale or SSH tunnel):

```bash
cd Reisekostenabrechnung
DATABASE_URL=postgres://reisekosten:PASSWORD@<cluster-postgres>:5433/reisekosten \
  python migrate_sqlite_to_postgres.py
```

`geo_locations` is intentionally NOT migrated — re-seeded at app startup
from `data/DE.txt` (faster than 23k INSERTs).

## Operations

### Logs

```bash
docker service logs -f --tail 100 reisekosten_reisekosten
```

### Force-rolling-restart (e.g. to pick up new image at same tag)

```bash
docker pull ghcr.io/thorstenhornung1/reisekosten:v2
NEW_DIGEST=$(docker image inspect ghcr.io/thorstenhornung1/reisekosten:v2 \
  --format '{{(index .RepoDigests 0)}}')
docker service update --image "$NEW_DIGEST" reisekosten_reisekosten
```

### Connect to the DB

```bash
ssh ansible@192.168.4.40 \
  "docker exec -it \$(docker ps -q -f name=postgres-ha-stack_postgres-2) \
     psql -U reisekosten -d reisekosten"
```

### Secret rotation

`SECRET_KEY` rotation invalidates all active sessions but no data is lost:
```bash
openssl rand -hex 32 | docker secret create reisekosten_secret_key_v2 -
docker service update --secret-rm reisekosten_secret_key \
  --secret-add source=reisekosten_secret_key_v2,target=reisekosten_secret_key \
  reisekosten_reisekosten
docker secret rm reisekosten_secret_key
```

DB-password rotation requires a coordinated update of the `reisekosten`
Postgres user role and the Docker secret — see SECRETS_WORKFLOW.md.

## Architecture

```
                ┌──────────────────────┐
  HTTPS  ──────►│  Traefik (websecure) │
                └──────┬───────────────┘
                       │ traefik_public network
                       ▼
                ┌──────────────────────┐
                │  reisekosten         │  Single replica (Phase 1)
                │  Flask + gunicorn    │  port 8000
                └──────┬─────────┬─────┘
                       │         │
        postgres-network│         │ CephFS bind-mount
                       │         │
                       ▼         ▼
              ┌──────────────┐ ┌──────────────────────────────┐
              │  pg-haproxy  │ │ /mnt/cephfs/swarm-state/     │
              │  :5433 (RW)  │ │   stack-reisekosten/         │
              └──────┬───────┘ │     uploads/    generated/   │
                     │         └──────────────────────────────┘
                     ▼
              Patroni cluster
              (postgres-1/2/3)
```
