# Reindex: standalone tool vs. upstream contribution (#284)

Open Archiver v0.5.0 has no reindex feature
([#284](https://github.com/LogicLabs-OU/OpenArchiver/issues/284), open, no
maintainer response). There are two ways to make the archive searchable again,
and they are not mutually exclusive. This document sketches both and recommends
a path, given that **you may want to upstream-merge back to OA later**.

---

## Background: how OA already indexes (the reuse opportunity)

The whole indexing path already exists in OA and is small and clean:

```
ingestion → enqueue BullMQ "indexing" job  { emails: PendingEmail[] }
            (PendingEmail = { archivedEmailId })
                         │
   indexing.worker.ts ───┤  consumes queue
                         ▼
   index-email-batch.processor.ts
                         ▼
   IndexingService.indexEmailBatch(emails)
        • indexEmailById(id) → reads archived_emails + attachments
        • createEmailDocument() → builds the Meili doc from DB + S3 (+Tika)
        • SearchService.addDocuments('emails', docs, 'id')
```

So a reindex is conceptually just: *"enqueue an `index-email-batch` job for
every `archived_emails.id`."* Everything downstream is already battle-tested by
the normal ingestion flow. Any good solution should **reuse** this path rather
than re-implement document building (re-implementing risks shape drift — which
is exactly the failure mode this tool guards against by copying the mapping
verbatim).

---

## Approach A — Standalone tool (this directory)

A separate Node script + one-off Docker job that talks directly to PostgreSQL,
S3, Tika and Meilisearch, reproducing `createEmailDocument` exactly.

```
[oa-reindex one-off Swarm service]
   ├─ PG   (pg-haproxy)         → page archived_emails (keyset, 500/batch)
   ├─ S3   (s3-rgw)             → GET .eml + attachment blobs by storage_path
   ├─ Tika (openarchiver-tika)  → extract attachment / body text
   └─ Meili(openarchiver-meili) → addDocuments('emails', docs, primaryKey 'id')
```

**Pros**
- **Zero risk to the running app / no code change to OA.** Nothing to deploy
  into the live container; the app keeps running untouched.
- **Available immediately** — already written and offline-tested here.
- **Operationally isolated**: its own CPU/mem limits, its own log, killable any
  time. Idempotent (Meili dedups by `id`), resumable via keyset cursor.
- **Version-pinned reproduction**: deps pinned to the same versions OA uses
  (`mailparser`, `meilisearch@0.51`, `pg`, `@aws-sdk/client-s3`).
- No need to rebuild/redeploy the (slow, `pnpm install` + `db:migrate`) OA image.

**Cons**
- **Shape-drift maintenance burden**: it duplicates `createEmailDocument` +
  `sanitizeObject` + the Tika/decrypt contracts. If a future OA version changes
  the document shape or storage layout, this tool must be updated in lockstep
  (mitigated: every mapping is annotated with the exact upstream source line,
  and `shape.test.mjs` will catch a mismatch against a live index).
- **Not a product feature**: it's a recovery script, invisible to other OA users;
  doesn't help #284 for anyone else; doesn't survive an OA upgrade as a feature.
- Re-implements queueing/concurrency that OA already has.

---

## Approach B — Upstream fork / PR to OA for #284

Add a first-class reindex capability inside OA that **reuses the existing
indexing path**. Two sub-variants; B1 is the right scope.

### B1 (recommended fork shape) — Admin API route + bulk-enqueue

Add a thin service method + an authenticated admin route that pages
`archived_emails` and enqueues the **existing** `index-email-batch` jobs onto the
**existing** `indexing` BullMQ queue. No new document-building code at all.

```
POST /v1/search/reindex   (requireAuth + requirePermission('settings','update'))
        │
        ▼
IndexingService.enqueueFullReindex({ onlyUnindexed?, batchSize=500 })
        • SELECT id FROM archived_emails [WHERE is_indexed=false] ORDER BY id   (keyset page)
        • for each page: indexingQueue.add('index-email-batch',
                                           { emails: ids.map(id => ({archivedEmailId:id})) })
        • (optionally) configureEmailIndex() first
        ▼
   existing indexing.worker → index-email-batch.processor → indexEmailBatch (UNCHANGED)
```

Files a PR would touch (all already exist in `packages/backend/src`):
- `services/IndexingService.ts` — add `enqueueFullReindex()` (the only new logic;
  ~30 lines, pure enqueue + paging).
- `services/SearchService.ts` — reuse `configureEmailIndex()` (already there).
- `api/routes/search.routes.ts` + `api/controllers/search.controller.ts` — add the
  guarded route (mirrors the existing `GET /v1/search`).
- `jobs/queues.ts` — reuse `indexingQueue` (already there).
- Frontend (SvelteKit): a "Rebuild search index" button on the settings/search
  admin page (optional but completes the feature).
- Docs + an OpenAPI annotation (repo has `scripts/generate-openapi-spec.mjs`).

**Pros**
- **Single source of truth** for document shape — reuses `createEmailDocument`,
  so **zero drift risk** by construction.
- **Solves #284 for everyone**; mergeable upstream; survives OA upgrades as a
  real feature; gives you a UI button for the next incident.
- Gets BullMQ's retries/backoff/observability for free; progress visible via the
  existing jobs UI.
- Backpressure/concurrency already handled by the indexing worker config.

**Cons**
- **Requires running your forked OA image** until the PR is merged upstream — i.e.
  you'd switch `logiclabshq/open-archiver:v0.5.0` to a self-built image
  (`ghcr.io/thorstenhornung1/...`). That's a maintenance + rebuild cost and a
  bigger blast radius than a side-car script.
- **Slower to get going**: needs a fork, build pipeline, and the OA image's slow
  startup (`pnpm install` + `db:migrate`) on every iteration.
- **Doesn't recover you *today*** — you still need something to run *now*, before
  a PR is written, reviewed and merged.
- PR may sit unreviewed (the maintainer hasn't responded on #284), leaving you
  carrying a fork indefinitely.

### B2 (not recommended) — `reindex` CLI command in the backend

A `pnpm reindex` script (`packages/backend/src/cli/reindex.ts`, wired into
`package.json` scripts like `db:migrate`) that calls `IndexingService` directly
in-process. Same reuse benefit as B1, runnable as `docker exec` against the live
container — but it's a less natural contribution (OA's surface is API + workers,
not a CLI), and `docker exec` one-offs are exactly the kind of manual step the
project's CI/CD rules discourage. If you go upstream, B1 (API route + button) is
the cleaner, more mergeable shape; a CLI can wrap the same service method for
local use.

---

## Recommendation

**Do both, in order — but they serve different moments:**

1. **Now: use the standalone tool (Approach A).** It recovers the index with zero
   risk to the running app and no fork to babysit. This is the correct tool for
   an incident: isolated, idempotent, resumable, removable. (It's done.)

2. **Then, deliberately: contribute Approach B1 upstream to #284.** A small,
   well-scoped PR — an admin "rebuild index" route that bulk-enqueues the
   *existing* `index-email-batch` jobs — is genuinely useful to the project,
   carries no shape-drift risk (it reuses `createEmailDocument`), and turns the
   next index loss into a one-click fix. Because you want to track upstream, this
   keeps your customizations minimal and mergeable rather than diverging.

**Why not jump straight to the fork?** The fork's main cost is that it forces you
onto a self-built OA image *before* a maintainer has even engaged on #284, and it
doesn't help you in the middle of the current incident. The standalone tool gets
you searchable *today*; the upstream PR is the durable fix you land on your own
schedule. If/when B1 merges upstream and ships in an OA release, you can delete
this tool.

**Guard against drift either way:** keep `shape.test.mjs` and re-verify the live
`emails` index `fieldDistribution` + settings after any OA upgrade — that's the
canary that tells you whether the standalone tool (A) still matches, and confirms
B1 didn't regress the shape.
