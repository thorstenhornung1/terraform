# Open Archiver — Meilisearch Reindex Tool

Rebuilds the Open Archiver `emails` full-text index from the **source of truth**
(PostgreSQL `archived_emails` + the mail blobs in Ceph RGW S3) when the
Meilisearch index has been lost or reset — e.g. after the `MDB_CORRUPTED`
CephFS incident that left the index near-empty while **all 272k+ mails are
intact** in DB + S3.

Open Archiver **v0.5.0 has no built-in reindex** (upstream issue
[LogicLabs-OU/OpenArchiver#284](https://github.com/LogicLabs-OU/OpenArchiver/issues/284),
open, no maintainer response). This standalone tool fills that gap **without
modifying Open Archiver**.

- **Status:** developed + offline-tested; **not yet run against production**.
- **Image:** built locally from the `Dockerfile` here (Node 22-alpine).
- **What it writes:** only Meilisearch (`addDocuments`). It is **read-only**
  against PostgreSQL and S3 — *unless* you pass `--mark-indexed` (opt-in, then
  it flips `archived_emails.is_indexed=true` on processed rows; see Risks).

> ⚠️ This is a recovery/operational tool, not part of the GitOps-deployed stack.
> It is meant to be run **manually and deliberately**, then removed.

---

## How it works (and why it's safe to re-run)

It reproduces Open Archiver v0.5.0's own indexing path **exactly**, so the
documents it writes are byte-identical in shape to what the app produces. The
field mapping is copied line-for-line from the upstream source:

| Step | This tool | Open Archiver v0.5.0 source |
|------|-----------|------------------------------|
| Page rows | keyset over `archived_emails` (`ORDER BY id`, batches of 500) | `IndexingService.indexEmailBatch` |
| Build doc | `createEmailDocument()` mirror | `IndexingService.createEmailDocument` (lines 376-407) |
| Body text | `simpleParser(eml).text \|\| .html \|\| tika(text/plain) \|\| ''` | identical (lines 383-390) |
| Attachment text | Tika `PUT /tika`, `{filename, content}` | `extractAttachmentContents` + `OcrService` |
| Sanitize | `sanitizeObject` (strip control chars / `�`) | identical (lines 33-61) |
| Settings | `searchable/filterable/sortable` as below | `SearchService.configureEmailIndex` (150-175) |
| Write | `addDocuments(docs, {primaryKey:'id'})` | `addDocuments('emails', docs, 'id')` (line 178) |

**Primary key is `id`** (the `archived_emails.id` UUID). Meilisearch dedups by
primary key, so re-running simply **overwrites** identical documents. The tool
does **no deletes**. Running it twice, or resuming after an interruption, is
safe and idempotent.

### The exact Meilisearch document shape

```jsonc
{
  "id":            "<uuid>",            // = archived_emails.id  (Meili primaryKey)
  "userEmail":     "owner@domain",      // = archived_emails.user_email
  "from":          "sender@domain",     // = archived_emails.sender_email  (single string!)
  "to":            ["a@x", "b@y"],      // = recipients.to[].address   (string[])
  "cc":            [],                  // = recipients.cc[].address
  "bcc":           [],                  // = recipients.bcc[].address
  "subject":       "…",                 // = archived_emails.subject
  "body":          "…",                 // parsed plain text of the .eml from S3
  "attachments":   [                    // one entry per attachment row
    { "filename": "invoice.pdf", "content": "…extracted text via Tika…" }
  ],
  "timestamp":     1780810350000,       // = new Date(sent_at).getTime()  (ms epoch)
  "ingestionSourceId": "<uuid>"         // = archived_emails.ingestion_source_id
}
```

> **Verified against the live system (read-only) on 2026-06-07:** the running
> `emails` index reports exactly these 11 fields (`fieldDistribution`), primary
> key `id`, and settings already matching `configureEmailIndex`. The DB
> `recipients` jsonb uses the `.address` key (the `Recipient` TS type's `.email`
> is *not* what's stored). `storage_path` already contains the full S3 key incl.
> the `open-archiver/…` prefix, and the S3 `.eml` blobs are **plaintext** (no
> `oa_enc_idf_v1::` prefix, because `STORAGE_ENCRYPTION_KEY` is unset).

Index settings applied (idempotently):

```jsonc
searchableAttributes: [subject, body, from, to, cc, bcc,
                       attachments.filename, attachments.content, userEmail]
filterableAttributes: [from, to, cc, bcc, timestamp, ingestionSourceId, userEmail]
sortableAttributes:   [timestamp]
```

---

## Configuration

All config is read from env vars; secrets are read from `$NAME`, `$NAME_FILE`,
or `/run/secrets/<name>` (so Docker secrets work directly).

| Env var | Default | From secret | Purpose |
|---------|---------|-------------|---------|
| `POSTGRES_HOST` | `pg-haproxy` | | DB host (HAProxy primary port) |
| `POSTGRES_PORT` | `5433` | | DB port |
| `POSTGRES_DB` | `open_archive` | | DB name |
| `POSTGRES_USER` | `openarchiver` | | DB user |
| `POSTGRES_PASSWORD` | — | `openarchiver_db_password` | DB password (**required**) |
| `MEILI_HOST` | `http://openarchiver-meili:7700` | | Meilisearch URL |
| `MEILI_MASTER_KEY` | — | `openarchiver_meili_master_key` | Meili key (**required**) |
| `MEILI_INDEX` | `emails` | | index name |
| `STORAGE_S3_ENDPOINT` | `http://s3-rgw` | | Ceph RGW endpoint |
| `STORAGE_S3_BUCKET` | `openarchiver` | | bucket |
| `STORAGE_S3_REGION` | `us-east-1` | | region |
| `STORAGE_S3_ACCESS_KEY_ID` | — | `openarchiver_s3_access_key` | S3 key (**required**) |
| `STORAGE_S3_SECRET_ACCESS_KEY` | — | `openarchiver_s3_secret_key` | S3 secret (**required**) |
| `STORAGE_S3_FORCE_PATH_STYLE` | `true` | | path-style addressing |
| `STORAGE_ENCRYPTION_KEY` | *(unset)* | | only if blobs are encrypted (homelab: leave unset) |
| `TIKA_URL` | `http://openarchiver-tika:9998` | | attachment text extraction |
| `TIKA_ENABLED` | `true` | | set `false` to skip Tika (`--no-tika`) |

### CLI flags

```
--dry-run              Build docs, print a redacted sample, write NOTHING. No
                       DB/Meili/S3 mutations. (S3 reads still happen.)
--limit=N              Only process the first N emails (smoke test).
--batch-size=N         Emails per addDocuments call (default 500).
--doc-concurrency=N    Emails turned into docs in parallel (default 10).
--start-after=<uuid>   Resume from a keyset cursor (skip id <= this).
--only-unindexed       Only rows WHERE is_indexed = false.
--mark-indexed         After Meili accepts a batch, set is_indexed=true on those
                       rows. ⚠️ WRITES TO POSTGRES. Off by default.
--no-tika              Skip attachment extraction (filenames still indexed; body
                       still extracted via mailparser).
--skip-settings        Don't (re)apply index settings.
--no-wait              Don't await Meili task completion per batch.
-h, --help             Help.
```

---

## ⚠️ Critical network constraint (read before running)

The tool must reach four services that live on three **overlay** networks:

| Target | Network | Attachable? |
|--------|---------|-------------|
| `pg-haproxy` | `postgres-ha-stack_postgres-network` | ✅ yes |
| `s3-rgw` | `s3-rgw_s3-network` | ✅ yes |
| `openarchiver-meili`, `openarchiver-tika` | `openarchiver_default` | ❌ **no** |

Because `openarchiver_default` is **not attachable**, a plain
`docker run --network openarchiver_default …` will **fail to attach**. You must
run the tool as a **one-off Swarm service** (services *can* join non-attachable
overlays), constrained to an app node where CephFS/Meili live.

(Verified 2026-06-07: `docker network inspect openarchiver_default` →
`Attachable=false`; the other two → `Attachable=true`.)

---

## Controlled execution (recommended procedure)

Run everything from a **Swarm manager** (`192.168.4.40`/`.41`/`.42`). All
required secrets already exist (`openarchiver_*`).

### 0. Pre-flight snapshot (per the project disaster-recovery rule)

The tool only *adds* documents to Meili (no deletes), and is read-only against
DB/S3. Still, snapshot the Meili state before a large run so you can roll back:

```bash
# On the node where openarchiver-meili runs (node.labels.app == true):
docker service ps openarchiver_openarchiver-meili --format '{{.Node}} {{.CurrentState}}'
# Optional cold-consistent copy of the index dir (stop writer first if you want a
# guaranteed-consistent copy; otherwise a hot copy is fine for a rollback point):
sudo cp -a /mnt/cephfs/swarm-state/stack-openarchiver/meili/data.ms \
           /mnt/cephfs/swarm-state/stack-openarchiver/meili/data.ms.bak-$(date +%Y%m%d-%H%M%S)
```

### 1. Build the image (on a manager)

```bash
cd /path/to/swarm-stacks/stacks/apps/openarchiver/reindex-tool
docker build -t openarchiver-reindex:local .
```

> The image must exist on whichever node the service lands on. Either build on
> all three app nodes, or push to GHCR
> (`ghcr.io/thorstenhornung1/swarm-stacks/openarchiver-reindex`) and reference
> that — same pattern as the other custom images in this repo. For a one-off,
> building on each app node (or pinning the service to one node you built on) is
> simplest.

### 2. Smoke test — DRY RUN, 20 emails (writes nothing)

This builds 20 real documents (reads DB + S3 + Tika) and prints a redacted
sample so you can eyeball the shape. It does **not** write to Meili.

```bash
docker service create \
  --name oa-reindex-dryrun \
  --restart-condition none \
  --constraint 'node.labels.app == true' \
  --network openarchiver_default \
  --network postgres-ha-stack_postgres-network \
  --network s3-rgw_s3-network \
  --secret openarchiver_db_password \
  --secret openarchiver_meili_master_key \
  --secret openarchiver_s3_access_key \
  --secret openarchiver_s3_secret_key \
  -e POSTGRES_HOST=pg-haproxy -e POSTGRES_PORT=5433 \
  -e POSTGRES_DB=open_archive -e POSTGRES_USER=openarchiver \
  -e MEILI_HOST=http://openarchiver-meili:7700 \
  -e STORAGE_S3_ENDPOINT=http://s3-rgw -e STORAGE_S3_BUCKET=openarchiver \
  -e STORAGE_S3_REGION=us-east-1 -e STORAGE_S3_FORCE_PATH_STYLE=true \
  -e TIKA_URL=http://openarchiver-tika:9998 \
  openarchiver-reindex:local \
  --dry-run --limit=20

# Watch the logs until it exits:
docker service logs -f oa-reindex-dryrun
# When done:
docker service rm oa-reindex-dryrun
```

Confirm in the log: the printed sample document has the 11 keys above, `from` is
a single address, `to/cc/bcc` are arrays, `attachments` is `[{filename,content}]`.

### 3. Small real run — 50 emails written to Meili

Same command, drop `--dry-run`, keep a small `--limit`:

```bash
docker service create --name oa-reindex-test --restart-condition none \
  --constraint 'node.labels.app == true' \
  --network openarchiver_default \
  --network postgres-ha-stack_postgres-network \
  --network s3-rgw_s3-network \
  --secret openarchiver_db_password --secret openarchiver_meili_master_key \
  --secret openarchiver_s3_access_key --secret openarchiver_s3_secret_key \
  -e POSTGRES_HOST=pg-haproxy -e POSTGRES_PORT=5433 \
  -e POSTGRES_DB=open_archive -e POSTGRES_USER=openarchiver \
  -e MEILI_HOST=http://openarchiver-meili:7700 \
  -e STORAGE_S3_ENDPOINT=http://s3-rgw -e STORAGE_S3_BUCKET=openarchiver \
  -e STORAGE_S3_REGION=us-east-1 -e STORAGE_S3_FORCE_PATH_STYLE=true \
  -e TIKA_URL=http://openarchiver-tika:9998 \
  openarchiver-reindex:local \
  --limit=50

docker service logs -f oa-reindex-test
docker service rm oa-reindex-test
```

Then **search in the Open Archiver UI** for a term you know is in one of those
50 mails — confirm it's found and the result opens correctly.

### 4. Full run — all 272k+ emails

Once steps 2-3 look right, run the whole archive. This is long-running; let it
run detached and tail the logs. The log prints a `Resume hint:` cursor on exit,
and every batch logs the current cursor — so if it dies you can resume with
`--start-after=<uuid>`.

```bash
docker service create --name oa-reindex --restart-condition none \
  --constraint 'node.labels.app == true' \
  --network openarchiver_default \
  --network postgres-ha-stack_postgres-network \
  --network s3-rgw_s3-network \
  --secret openarchiver_db_password --secret openarchiver_meili_master_key \
  --secret openarchiver_s3_access_key --secret openarchiver_s3_secret_key \
  --limit-cpu 1.5 --limit-memory 2G \
  -e POSTGRES_HOST=pg-haproxy -e POSTGRES_PORT=5433 \
  -e POSTGRES_DB=open_archive -e POSTGRES_USER=openarchiver \
  -e MEILI_HOST=http://openarchiver-meili:7700 \
  -e STORAGE_S3_ENDPOINT=http://s3-rgw -e STORAGE_S3_BUCKET=openarchiver \
  -e STORAGE_S3_REGION=us-east-1 -e STORAGE_S3_FORCE_PATH_STYLE=true \
  -e TIKA_URL=http://openarchiver-tika:9998 \
  openarchiver-reindex:local
  # add --only-unindexed if you also run with --mark-indexed and want resumability via the DB flag

docker service logs -f oa-reindex
# On completion the log prints the final Meili numberOfDocuments. Then:
docker service rm oa-reindex
```

**Resume after an interruption:** re-run the same command and append
`--start-after=<last-cursor-uuid-from-the-log>`. (Or use
`--only-unindexed --mark-indexed` so progress is tracked in the DB and a bare
re-run continues automatically.)

### Verify

```bash
# Document count in Meili should approach the archived_emails row count.
OACID=$(docker ps --filter name=openarchiver_open-archiver -q | head -1)
MK=$(docker exec "$OACID" cat /run/secrets/openarchiver_meili_master_key)
docker exec -e MK="$MK" "$OACID" node -e \
 'require("http").get("http://openarchiver-meili:7700/indexes/emails/stats",{headers:{Authorization:"Bearer "+process.env.MK}},r=>{let d="";r.on("data",c=>d+=c);r.on("end",()=>console.log(d))})'
```

---

## Risks & mitigations

- **Load on the live stack.** The tool shares Meili, Tika and S3 (RGW) with the
  running app. A full 272k run does a lot of S3 GETs and Tika extractions.
  Mitigations: it indexes in batches with a small inter-batch pause, bounded
  `--doc-concurrency` (default 10), and CPU/mem limits in the run command. Run
  it during a quiet window. Lower `--doc-concurrency` / `--batch-size` if Frigate
  or other Ceph consumers feel it (Ceph is shared — see project memory).
- **`--mark-indexed` writes to PostgreSQL.** Only the boolean
  `archived_emails.is_indexed` is touched (set `true`), and only for rows Meili
  accepted. It's safe and reversible (`UPDATE … SET is_indexed=false`), but it
  *is* a DB write — off by default. The app does not depend on this flag for
  search; it's purely for resumability/observability.
- **Patroni failover / HAProxy idle-kill.** The DB pool uses TCP keepalives and a
  60s `statement_timeout`. If a failover happens mid-run the process may error
  out — just resume with `--start-after`. No partial document is ever written
  (Meili dedups by id; a re-sent batch overwrites cleanly).
- **Skipped emails.** If a mail blob is missing in S3 or a row is malformed, that
  single email is logged (`WARN build failed …`) and skipped; the run continues.
  The final log reports `skipped=N`. Re-running won't fix a genuinely missing
  blob, but it will pick up anything transient.
- **Index settings.** Applied idempotently before indexing. If you'd rather not
  touch settings (they already match upstream on the live system), pass
  `--skip-settings`.
- **Encrypted storage.** This deployment stores blobs in plaintext. If you ever
  enable `STORAGE_ENCRYPTION_KEY`, set the same key here (the tool mirrors OA's
  `oa_enc_idf_v1::` decrypt) or bodies/attachments will be garbage.

---

## Local development / offline test

```bash
npm install                 # only for local dev; node_modules is gitignored
node src/shape.test.mjs     # offline: proves the document shape (no network)
node src/reindex.mjs --help
```

`shape.test.mjs` asserts the built document's key set/order and field types
against the live Meili wire format captured on 2026-06-07, including the
`recipients.*.address` mapping. It runs fully offline.

---

## Should this be an upstream contribution instead? (Fork evaluation)

See **[FORK_EVALUATION.md](./FORK_EVALUATION.md)** for the full comparison of the
two approaches (this standalone tool vs. a proper upstream PR for #284), with
architecture sketches for both and a recommendation.

**TL;DR:** Use this standalone tool **now** to recover (zero upstream risk, no
fork to maintain). **Then** contribute a small upstream PR to #284 — an admin
API route that enqueues the *existing* BullMQ `index-email-batch` jobs for all
emails — so future index losses are a one-click fix and you can drop this tool.
