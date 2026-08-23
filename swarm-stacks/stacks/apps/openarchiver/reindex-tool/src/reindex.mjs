#!/usr/bin/env node
// =============================================================================
// Open Archiver — Standalone Meilisearch Reindexer
// =============================================================================
// Rebuilds the Open Archiver `emails` Meilisearch index from the source of
// truth (PostgreSQL `archived_emails` + the mail blobs in Ceph RGW S3) WITHOUT
// touching Open Archiver itself. Use after an index loss/corruption when the
// 272k+ archived mails are intact in DB+S3 but the Meili index is (near) empty.
//
// It produces documents that are BYTE-IDENTICAL in shape to what Open Archiver
// v0.5.0 writes, so search behaves exactly the same and the app stays consistent.
// Document shape + field mapping mirror, line-for-line:
//   OpenArchiver@v0.5.0 packages/backend/src/services/IndexingService.ts
//     - createEmailDocument()        (lines 376-407)  -> the doc fields
//     - sanitizeText()/sanitizeObject() (lines 33-61) -> identical sanitization
//     - addDocuments('emails', docs, 'id')  (line 178) -> primary key 'id'
//   OpenArchiver@v0.5.0 packages/backend/src/services/SearchService.ts
//     - configureEmailIndex()        (lines 150-175)  -> index settings
//   OpenArchiver@v0.5.0 packages/backend/src/services/OcrService.ts
//     - extractTextWithTika()        (lines 117-201)  -> Tika PUT /tika contract
//   OpenArchiver@v0.5.0 packages/backend/src/services/storage/S3StorageProvider.ts
//     - get(path) uses Key=storage_path verbatim (no prefix; blobs are plaintext
//       in this deployment because STORAGE_ENCRYPTION_KEY is unset).
//
// VERIFIED against the live homelab system (read-only) on 2026-06-07:
//   - archived_emails: 272,437 rows, all is_indexed=false
//   - recipients jsonb uses the `.address` key (NOT `.email`)
//   - storage_path already contains the full S3 key incl. "open-archiver/..." prefix
//   - S3 objects are plaintext .eml (no "oa_enc_idf_v1::" prefix)
//   - Meili index "emails" exists, primaryKey "id", settings already match OA
//
// SAFETY: This tool is idempotent. Meili dedups by primary key `id`, so a
//   document for an email that is already indexed is simply overwritten with an
//   identical document. Re-running is safe and resumes coverage. It performs NO
//   deletes and NO writes to PostgreSQL unless --mark-indexed is passed
//   (which only flips archived_emails.is_indexed=true for processed rows).
//
// See README.md for how to run this as a controlled one-off Swarm job.
// =============================================================================

import { readFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import pg from 'pg';
import { MeiliSearch } from 'meilisearch';
import { simpleParser } from 'mailparser';
import { S3Client, GetObjectCommand } from '@aws-sdk/client-s3';

// Handle --help/-h before touching any config or secrets (so it always works).
if (process.argv.slice(2).some((a) => a === '--help' || a === '-h')) {
	printHelp();
	process.exit(0);
}

// ----------------------------------------------------------------------------
// Config (env + Docker secrets). Mirrors the names the Open Archiver stack uses.
// ----------------------------------------------------------------------------

// Missing required config is collected here (not thrown at module load) so that
// `--help` works without secrets and the user sees ALL missing values at once.
const MISSING_REQUIRED = [];

/** Read a value from $NAME, else from $NAME_FILE, else from /run/secrets/<secretName>. */
function readConfig(name, { secret, required = false, fallback = undefined } = {}) {
	if (process.env[name] != null && process.env[name] !== '') return process.env[name];
	const fileVar = process.env[`${name}_FILE`];
	if (fileVar) {
		try {
			return readFileSync(fileVar, 'utf8').replace(/\n+$/, '');
		} catch (e) {
			throw new Error(`Cannot read ${name}_FILE=${fileVar}: ${e.message}`);
		}
	}
	if (secret) {
		try {
			return readFileSync(`/run/secrets/${secret}`, 'utf8').replace(/\n+$/, '');
		} catch {
			/* fall through */
		}
	}
	if (required) {
		MISSING_REQUIRED.push(`${name} (or ${name}_FILE / secret ${secret ?? '-'})`);
		return undefined;
	}
	return fallback;
}

function boolEnv(name, def) {
	const v = process.env[name];
	if (v == null || v === '') return def;
	return v === 'true' || v === '1' || v === 'yes';
}

const CONFIG = {
	// --- PostgreSQL (Patroni HA via HAProxy primary port) ---
	pg: {
		host: readConfig('POSTGRES_HOST', { fallback: 'pg-haproxy' }),
		port: parseInt(readConfig('POSTGRES_PORT', { fallback: '5433' }), 10),
		database: readConfig('POSTGRES_DB', { fallback: 'open_archive' }),
		user: readConfig('POSTGRES_USER', { fallback: 'openarchiver' }),
		password: readConfig('POSTGRES_PASSWORD', {
			secret: 'openarchiver_db_password',
			required: true,
		}),
		// HAProxy can idle-kill long-lived conns / failover (Patroni). Keep TCP
		// keepalives on and a finite statement timeout so a stuck query surfaces.
		keepAlive: true,
		statement_timeout: 60_000,
	},
	// --- Meilisearch ---
	meili: {
		host: readConfig('MEILI_HOST', { fallback: 'http://openarchiver-meili:7700' }),
		apiKey: readConfig('MEILI_MASTER_KEY', {
			secret: 'openarchiver_meili_master_key',
			required: true,
		}),
		index: process.env.MEILI_INDEX || 'emails',
	},
	// --- Ceph RGW S3 (mail blob storage) ---
	s3: {
		endpoint: readConfig('STORAGE_S3_ENDPOINT', { fallback: 'http://s3-rgw' }),
		bucket: readConfig('STORAGE_S3_BUCKET', { fallback: 'openarchiver' }),
		region: readConfig('STORAGE_S3_REGION', { fallback: 'us-east-1' }),
		accessKeyId: readConfig('STORAGE_S3_ACCESS_KEY_ID', {
			secret: 'openarchiver_s3_access_key',
			required: true,
		}),
		secretAccessKey: readConfig('STORAGE_S3_SECRET_ACCESS_KEY', {
			secret: 'openarchiver_s3_secret_key',
			required: true,
		}),
		forcePathStyle: boolEnv('STORAGE_S3_FORCE_PATH_STYLE', true),
		// Optional: AES-256 hex key. Only set if this deployment used storage
		// encryption (it does NOT in the homelab). Mirrors StorageService decrypt.
		encryptionKey: readConfig('STORAGE_ENCRYPTION_KEY', { fallback: undefined }),
	},
	// --- Tika (attachment + fallback body text extraction) ---
	tika: {
		url: process.env.TIKA_URL || 'http://openarchiver-tika:9998',
		// If false, attachment text is skipped (filenames still indexed). Body text
		// still comes from mailparser. Set TIKA_ENABLED=false to run without Tika.
		enabled: boolEnv('TIKA_ENABLED', true),
		timeoutMs: parseInt(process.env.TIKA_TIMEOUT_MS || '180000', 10),
	},
	// --- Run controls ---
	batchSize: parseInt(process.env.REINDEX_BATCH_SIZE || process.env.MEILI_INDEXING_BATCH || '500', 10),
	// How many emails are turned into documents in parallel within a batch.
	// OA uses 10 (IndexingService CONCURRENCY_LIMIT). Keep modest to be gentle
	// on S3/Tika/the running OA instance.
	docConcurrency: parseInt(process.env.REINDEX_DOC_CONCURRENCY || '10', 10),
	dryRun: boolEnv('DRY_RUN', false),
	limit: process.env.REINDEX_LIMIT ? parseInt(process.env.REINDEX_LIMIT, 10) : undefined,
	startAfterId: process.env.REINDEX_START_AFTER_ID || undefined, // resume cursor (UUID)
	onlyUnindexed: boolEnv('REINDEX_ONLY_UNINDEXED', false), // WHERE is_indexed = false
	markIndexed: boolEnv('REINDEX_MARK_INDEXED', false), // UPDATE is_indexed=true after success (WRITE!)
	skipSettings: boolEnv('REINDEX_SKIP_SETTINGS', false),
	waitTasks: boolEnv('REINDEX_WAIT_TASKS', true), // await Meili task completion per batch
};

// CLI flag aliases (so `--dry-run` etc. work in addition to env vars).
for (const arg of process.argv.slice(2)) {
	switch (arg) {
		case '--dry-run': CONFIG.dryRun = true; break;
		case '--only-unindexed': CONFIG.onlyUnindexed = true; break;
		case '--mark-indexed': CONFIG.markIndexed = true; break;
		case '--no-tika': CONFIG.tika.enabled = false; break;
		case '--skip-settings': CONFIG.skipSettings = true; break;
		case '--no-wait': CONFIG.waitTasks = false; break;
		case '--help':
		case '-h':
			printHelp();
			process.exit(0);
		default:
			if (arg.startsWith('--limit=')) CONFIG.limit = parseInt(arg.split('=')[1], 10);
			else if (arg.startsWith('--batch-size=')) CONFIG.batchSize = parseInt(arg.split('=')[1], 10);
			else if (arg.startsWith('--start-after=')) CONFIG.startAfterId = arg.split('=')[1];
			else if (arg.startsWith('--doc-concurrency=')) CONFIG.docConcurrency = parseInt(arg.split('=')[1], 10);
			else { console.error(`Unknown argument: ${arg}\n`); printHelp(); process.exit(2); }
	}
}

function printHelp() {
	console.log(`Open Archiver Meilisearch reindexer

Usage: node src/reindex.mjs [options]

Options:
  --dry-run                Build documents but do NOT write to Meili. Prints a
                           redacted sample document. No DB/Meili/S3 mutations.
  --limit=N                Only process the first N emails (smoke test).
  --batch-size=N           Emails per Meili addDocuments call (default 500).
  --doc-concurrency=N      Emails turned into docs in parallel (default 10).
  --start-after=<uuid>     Resume: skip rows with id <= this (keyset cursor).
  --only-unindexed         Only rows WHERE is_indexed = false.
  --mark-indexed           After a batch is accepted by Meili, set is_indexed=true
                           on those rows. THIS WRITES TO POSTGRES. Off by default.
  --no-tika                Skip Tika attachment extraction (filenames still indexed,
                           body still extracted via mailparser).
  --skip-settings          Do not (re)apply index settings before indexing.
  --no-wait                Do not await Meili task completion per batch (faster,
                           but errors surface later in Meili task queue).
  -h, --help               Show this help.

Most options also have env equivalents (see README.md). Secrets are read from
$NAME, $NAME_FILE, or /run/secrets/<name>.`);
}

// ----------------------------------------------------------------------------
// Sanitization — copied verbatim from Open Archiver v0.5.0 IndexingService.ts
// (lines 33-61). Keeping these byte-identical guarantees identical documents.
// ----------------------------------------------------------------------------

function sanitizeText(text) {
	if (!text) return '';
	return text
		.replace(/�/g, '')
		.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '')
		.trim();
}

function sanitizeObject(obj) {
	if (typeof obj === 'string') {
		return sanitizeText(obj);
	} else if (Array.isArray(obj)) {
		return obj.map(sanitizeObject);
	} else if (obj !== null && typeof obj === 'object') {
		const sanitized = {};
		for (const key in obj) {
			if (Object.prototype.hasOwnProperty.call(obj, key)) {
				sanitized[key] = sanitizeObject(obj[key]);
			}
		}
		return sanitized;
	}
	return obj;
}

// Mirrors IndexingService.ensureEmailDocumentFields (lines 483-497): guarantees
// every required field is present with the correct type before indexing.
function ensureEmailDocumentFields(doc) {
	return {
		id: doc.id || 'missing-id',
		userEmail: doc.userEmail || 'unknown',
		from: doc.from || '',
		to: Array.isArray(doc.to) ? doc.to : [],
		cc: Array.isArray(doc.cc) ? doc.cc : [],
		bcc: Array.isArray(doc.bcc) ? doc.bcc : [],
		subject: doc.subject || '',
		body: doc.body || '',
		attachments: Array.isArray(doc.attachments) ? doc.attachments : [],
		timestamp: typeof doc.timestamp === 'number' ? doc.timestamp : Date.now(),
		ingestionSourceId: doc.ingestionSourceId || 'unknown',
	};
}

function isValidEmailDocument(doc) {
	try {
		JSON.stringify(doc);
		return true;
	} catch {
		return false;
	}
}

// ----------------------------------------------------------------------------
// Storage decrypt (only used if STORAGE_ENCRYPTION_KEY is set). Mirrors
// StorageService.decrypt (lines 46-66). The homelab deployment is plaintext, so
// this is a no-op there, but keeping it correct makes the tool portable.
// ----------------------------------------------------------------------------

const ENCRYPTION_PREFIX = Buffer.from('oa_enc_idf_v1::');

async function maybeDecrypt(buffer) {
	if (!CONFIG.s3.encryptionKey) return buffer;
	const prefix = buffer.subarray(0, ENCRYPTION_PREFIX.length);
	if (!prefix.equals(ENCRYPTION_PREFIX)) return buffer; // not encrypted
	const crypto = await import('node:crypto');
	const key = Buffer.from(CONFIG.s3.encryptionKey, 'hex');
	const iv = buffer.subarray(ENCRYPTION_PREFIX.length, ENCRYPTION_PREFIX.length + 16);
	const encrypted = buffer.subarray(ENCRYPTION_PREFIX.length + 16);
	const decipher = crypto.createDecipheriv('aes-256-cbc', key, iv);
	return Buffer.concat([decipher.update(encrypted), decipher.final()]);
}

// ----------------------------------------------------------------------------
// Tika — mirrors OcrService.extractTextWithTika (PUT /tika, text/plain).
// extractText() mirrors helpers/textExtractor.ts: with TIKA_URL set, ALL
// mimetypes go through Tika (Tika decides what it can parse).
// ----------------------------------------------------------------------------

async function extractTextWithTika(buffer, mimeType) {
	if (!CONFIG.tika.enabled) return '';
	if (!buffer || buffer.length === 0) return '';
	// OA size guard: 100MB with Tika (textExtractor.ts line 122).
	if (buffer.length > 100 * 1024 * 1024) {
		warn(`skip extraction: file too large (${buffer.length} bytes)`);
		return '';
	}
	const url = `${CONFIG.tika.url.replace(/\/$/, '')}/tika`;
	try {
		const res = await fetch(url, {
			method: 'PUT',
			headers: {
				'Content-Type': mimeType || 'application/octet-stream',
				Accept: 'text/plain',
				Connection: 'close',
			},
			body: buffer,
			signal: AbortSignal.timeout(CONFIG.tika.timeoutMs),
		});
		if (!res.ok) {
			warn(`Tika ${res.status} ${res.statusText} for ${mimeType}`);
			return '';
		}
		return (await res.text()).trim();
	} catch (e) {
		warn(`Tika error for ${mimeType}: ${e.message}`);
		return '';
	}
}

// ----------------------------------------------------------------------------
// Clients
// ----------------------------------------------------------------------------

const pgPool = new pg.Pool({
	host: CONFIG.pg.host,
	port: CONFIG.pg.port,
	database: CONFIG.pg.database,
	user: CONFIG.pg.user,
	password: CONFIG.pg.password,
	keepAlive: CONFIG.pg.keepAlive,
	statement_timeout: CONFIG.pg.statement_timeout,
	max: 4,
});

const meili = new MeiliSearch({ host: CONFIG.meili.host, apiKey: CONFIG.meili.apiKey });

// WaitOptions for meilisearch-js v0.51 .waitTask(): ms. Generous timeout because
// a 500-doc batch with large bodies/attachments can take a while to index.
const WAIT_OPTS = {
	timeout: parseInt(process.env.MEILI_TASK_TIMEOUT_MS || '600000', 10),
	interval: parseInt(process.env.MEILI_TASK_POLL_MS || '1000', 10),
};

const s3 = new S3Client({
	endpoint: CONFIG.s3.endpoint,
	region: CONFIG.s3.region,
	credentials: {
		accessKeyId: CONFIG.s3.accessKeyId,
		secretAccessKey: CONFIG.s3.secretAccessKey,
	},
	forcePathStyle: CONFIG.s3.forcePathStyle,
});

async function s3GetBuffer(key) {
	const out = await s3.send(new GetObjectCommand({ Bucket: CONFIG.s3.bucket, Key: key }));
	const buf = Buffer.from(await out.Body.transformToByteArray());
	return maybeDecrypt(buf);
}

// ----------------------------------------------------------------------------
// Document builder — mirrors IndexingService.createEmailDocument (lines 376-407)
//   from: email.senderEmail (a single string)
//   to/cc/bcc: recipients.{to,cc,bcc}[].address  (the DB jsonb uses .address)
//   body: parsedEmail.text || parsedEmail.html || tika(text/plain) || ''
//   attachments: [{ filename, content }]  (content = extracted text)
//   timestamp: new Date(email.sentAt).getTime()
//   ingestionSourceId: email.ingestionSourceId
//   id: email.id  (== Meili primary key)
// ----------------------------------------------------------------------------

async function createEmailDocument(email, attachments) {
	// 1) Attachment text — mirrors extractAttachmentContents (lines 409-430).
	const attachmentContents = [];
	for (const att of attachments) {
		try {
			const buf = await s3GetBuffer(att.storage_path);
			const content = await extractTextWithTika(buf, att.mime_type || '');
			attachmentContents.push({ filename: att.filename, content });
		} catch (e) {
			warn(`attachment extract failed (${att.filename} @ ${att.storage_path}): ${e.message}`);
		}
	}

	// 2) Body text — mirrors createEmailDocument (lines 383-390).
	let emailBodyText = '';
	const buf = await s3GetBuffer(email.storage_path); // throws if blob missing -> email skipped by caller
	const parsed = await simpleParser(buf);
	emailBodyText =
		parsed.text ||
		parsed.html ||
		(await extractTextWithTika(buf, 'text/plain')) ||
		'';

	// 3) Recipients — DB jsonb shape: { to:[{name,address}], cc:[...], bcc:[...] }.
	const recipients = email.recipients || {};
	const addr = (list) => (Array.isArray(list) ? list.map((r) => r?.address).filter(Boolean) : []);

	// 4) Assemble — EXACT field set/order of EmailDocument (email.types.ts 71-87).
	return {
		id: email.id,
		userEmail: email.user_email,
		from: email.sender_email,
		to: addr(recipients.to),
		cc: addr(recipients.cc),
		bcc: addr(recipients.bcc),
		subject: email.subject || '',
		body: emailBodyText,
		attachments: attachmentContents,
		timestamp: new Date(email.sent_at).getTime(),
		ingestionSourceId: email.ingestion_source_id,
	};
}

// ----------------------------------------------------------------------------
// DB access — keyset pagination over archived_emails (stable, no OFFSET drift).
// ----------------------------------------------------------------------------

async function fetchEmailPage(afterId, size) {
	const where = [];
	const params = [];
	if (afterId) {
		params.push(afterId);
		where.push(`id > $${params.length}`);
	}
	if (CONFIG.onlyUnindexed) where.push('is_indexed = false');
	const whereSql = where.length ? `WHERE ${where.join(' AND ')}` : '';
	params.push(size);
	const sql = `
		SELECT id, user_email, sender_email, recipients, subject,
		       storage_path, sent_at, ingestion_source_id, has_attachments
		FROM archived_emails
		${whereSql}
		ORDER BY id ASC
		LIMIT $${params.length}`;
	const { rows } = await pgPool.query(sql, params);
	return rows;
}

async function fetchAttachments(emailId) {
	const { rows } = await pgPool.query(
		`SELECT a.id, a.filename, a.mime_type, a.storage_path
		   FROM email_attachments ea
		   JOIN attachments a ON a.id = ea.attachment_id
		  WHERE ea.email_id = $1`,
		[emailId],
	);
	return rows;
}

async function markIndexed(ids) {
	if (!ids.length) return;
	await pgPool.query(`UPDATE archived_emails SET is_indexed = true WHERE id = ANY($1::uuid[])`, [ids]);
}

async function countTotal() {
	const where = CONFIG.onlyUnindexed ? 'WHERE is_indexed = false' : '';
	const { rows } = await pgPool.query(`SELECT count(*)::bigint AS n FROM archived_emails ${where}`);
	return Number(rows[0].n);
}

// ----------------------------------------------------------------------------
// Meili index settings — mirrors SearchService.configureEmailIndex (150-175).
// Applied idempotently. Safe even when settings already match (no-op task).
// ----------------------------------------------------------------------------

async function ensureIndexConfigured() {
	const index = meili.index(CONFIG.meili.index);
	// Make sure the index exists with the right primary key (OA uses 'id').
	// meilisearch-js v0.51: create/update/addDocuments return an EnqueuedTaskPromise
	// with a .waitTask({timeout,interval}) helper that resolves to the final Task.
	try {
		await meili.getIndex(CONFIG.meili.index);
	} catch {
		log(`index "${CONFIG.meili.index}" not found — creating with primaryKey "id"`);
		if (!CONFIG.dryRun) {
			await meili.createIndex(CONFIG.meili.index, { primaryKey: 'id' }).waitTask(WAIT_OPTS);
		}
	}
	if (CONFIG.skipSettings) {
		log('skipping index settings (--skip-settings)');
		return index;
	}
	log('applying index settings (configureEmailIndex-equivalent)…');
	if (!CONFIG.dryRun) {
		const task = await index.updateSettings({
			searchableAttributes: [
				'subject', 'body', 'from', 'to', 'cc', 'bcc',
				'attachments.filename', 'attachments.content', 'userEmail',
			],
			filterableAttributes: [
				'from', 'to', 'cc', 'bcc', 'timestamp', 'ingestionSourceId', 'userEmail',
			],
			sortableAttributes: ['timestamp'],
		}).waitTask(WAIT_OPTS);
		if (task.status !== 'succeeded') {
			throw new Error(`updateSettings task ${task.uid} status=${task.status} error=${JSON.stringify(task.error)}`);
		}
	}
	return index;
}

// ----------------------------------------------------------------------------
// Logging
// ----------------------------------------------------------------------------

const t0 = Date.now();
function ts() { return `[+${((Date.now() - t0) / 1000).toFixed(1)}s]`; }
function log(...a) { console.log(ts(), ...a); }
function warn(...a) { console.warn(ts(), 'WARN', ...a); }

function redactDoc(doc) {
	const c = structuredClone(doc);
	if (typeof c.body === 'string') c.body = `<string len=${c.body.length}>`;
	if (typeof c.from === 'string') c.from = `<addr len=${c.from.length}>`;
	for (const k of ['to', 'cc', 'bcc']) if (Array.isArray(c[k])) c[k] = c[k].map((x) => `<addr len=${(x || '').length}>`);
	if (Array.isArray(c.attachments)) {
		c.attachments = c.attachments.map((a) => ({
			filename: typeof a.filename === 'string' ? `<fn len=${a.filename.length}>` : a.filename,
			content: typeof a.content === 'string' ? `<content len=${a.content.length}>` : a.content,
		}));
	}
	return c;
}

// Simple promise-pool for bounded concurrency within a batch.
async function mapConcurrent(items, concurrency, fn) {
	const results = new Array(items.length);
	let next = 0;
	const workers = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
		while (true) {
			const i = next++;
			if (i >= items.length) break;
			results[i] = await fn(items[i], i);
		}
	});
	await Promise.all(workers);
	return results;
}

// ----------------------------------------------------------------------------
// Main
// ----------------------------------------------------------------------------

async function main() {
	if (MISSING_REQUIRED.length) {
		throw new Error(
			`Missing required configuration:\n  - ${MISSING_REQUIRED.join('\n  - ')}\n` +
			`Provide each via $NAME, $NAME_FILE, or a Docker secret (see README.md).`,
		);
	}
	log('Open Archiver reindexer starting');
	log('config:', JSON.stringify({
		pg: { host: CONFIG.pg.host, port: CONFIG.pg.port, db: CONFIG.pg.database, user: CONFIG.pg.user },
		meili: { host: CONFIG.meili.host, index: CONFIG.meili.index },
		s3: { endpoint: CONFIG.s3.endpoint, bucket: CONFIG.s3.bucket, region: CONFIG.s3.region, pathStyle: CONFIG.s3.forcePathStyle, encrypted: !!CONFIG.s3.encryptionKey },
		tika: { url: CONFIG.tika.url, enabled: CONFIG.tika.enabled },
		batchSize: CONFIG.batchSize, docConcurrency: CONFIG.docConcurrency,
		dryRun: CONFIG.dryRun, limit: CONFIG.limit, onlyUnindexed: CONFIG.onlyUnindexed,
		markIndexed: CONFIG.markIndexed, startAfterId: CONFIG.startAfterId,
	}, null, 2));

	// Preflight: connectivity to all three backends (fail fast with a clear msg).
	log('preflight: PostgreSQL…');
	const total = await countTotal();
	log(`preflight ok: ${total.toLocaleString()} archived_emails to consider${CONFIG.onlyUnindexed ? ' (unindexed only)' : ''}`);

	log('preflight: Meilisearch…');
	const health = await meili.health();
	log(`preflight ok: Meili status=${health.status}`);

	log('preflight: S3 (HEAD a sample object via first DB row)…');
	{
		const probe = await pgPool.query(
			`SELECT storage_path FROM archived_emails ${CONFIG.onlyUnindexed ? 'WHERE is_indexed = false' : ''} ORDER BY id ASC LIMIT 1`,
		);
		if (probe.rows[0]) {
			try {
				await s3.send(new GetObjectCommand({ Bucket: CONFIG.s3.bucket, Key: probe.rows[0].storage_path, Range: 'bytes=0-0' }));
				log('preflight ok: S3 reachable, sample object readable');
			} catch (e) {
				throw new Error(`S3 preflight failed for key "${probe.rows[0].storage_path}": ${e.message}`);
			}
		}
	}

	const index = await ensureIndexConfigured();

	let cursor = CONFIG.startAfterId || null;
	let processed = 0;
	let indexed = 0;
	let skipped = 0;
	let printedSample = false;

	const target = CONFIG.limit != null ? Math.min(CONFIG.limit, total) : total;

	while (true) {
		const remaining = CONFIG.limit != null ? CONFIG.limit - processed : Infinity;
		if (remaining <= 0) break;
		const pageSize = Math.min(CONFIG.batchSize, remaining);

		const rows = await fetchEmailPage(cursor, pageSize);
		if (rows.length === 0) break;

		// Build documents with bounded concurrency (mirrors OA's per-batch parallelism).
		const built = await mapConcurrent(rows, CONFIG.docConcurrency, async (email) => {
			try {
				const atts = email.has_attachments ? await fetchAttachments(email.id) : [];
				return await createEmailDocument(email, atts);
			} catch (e) {
				warn(`build failed for email ${email.id} (storage_path=${email.storage_path}): ${e.message}`);
				return null; // skip this email; do not abort the whole run
			}
		});

		// Sanitize + ensure fields + validate (mirrors indexEmailBatch 138-156).
		const docs = [];
		const builtIds = [];
		for (const raw of built) {
			if (!raw) { skipped++; continue; }
			const doc = ensureEmailDocumentFields(sanitizeObject(raw));
			if (!isValidEmailDocument(doc)) { warn(`invalid doc id=${raw.id} (JSON.stringify failed) — skipped`); skipped++; continue; }
			docs.push(doc);
			builtIds.push(doc.id);
		}

		if (!printedSample && docs.length) {
			log('SAMPLE document (redacted; verify shape against Meili existing docs):');
			console.log(JSON.stringify(redactDoc(docs[0]), null, 2));
			printedSample = true;
		}

		processed += rows.length;
		cursor = rows[rows.length - 1].id; // advance keyset cursor by last row id

		if (docs.length === 0) {
			log(`batch: 0 indexable docs (advanced cursor to ${cursor}); processed=${processed}/${target}`);
			continue;
		}

		if (CONFIG.dryRun) {
			indexed += docs.length;
			log(`DRY-RUN batch: would addDocuments ${docs.length} (cursor=${cursor}); processed=${processed}/${target}`);
		} else {
			// Same call as OA: addDocuments('emails', docs, primaryKey 'id'). Meili
			// dedups by id, so re-runs simply overwrite identical docs (idempotent).
			const enqueued = index.addDocuments(docs, { primaryKey: 'id' });
			let taskUid;
			if (CONFIG.waitTasks) {
				const done = await enqueued.waitTask(WAIT_OPTS);
				taskUid = done.uid;
				if (done.status !== 'succeeded') {
					throw new Error(`Meili task ${done.uid} status=${done.status} error=${JSON.stringify(done.error)}`);
				}
			} else {
				taskUid = (await enqueued).taskUid;
			}
			indexed += docs.length;
			if (CONFIG.markIndexed) await markIndexed(builtIds); // WRITE to PG (opt-in)
			log(`batch: indexed ${docs.length} (task ${taskUid}); cursor=${cursor}; processed=${processed}/${target} indexed=${indexed} skipped=${skipped}`);
		}

		// Tiny pause keeps load gentle on the live OA stack (S3/Tika/Meili shared).
		await sleep(50);
	}

	log(`DONE. processed=${processed} indexed=${indexed} skipped=${skipped} dryRun=${CONFIG.dryRun}`);
	if (!CONFIG.dryRun) {
		const stats = await index.getStats();
		log(`Meili index "${CONFIG.meili.index}" now reports numberOfDocuments=${stats.numberOfDocuments}`);
	}
	log(`Resume hint: re-run with --start-after=${cursor ?? '<none>'} to continue from here.`);
}

main()
	.then(async () => { await pgPool.end().catch(() => {}); process.exit(0); })
	.catch(async (e) => {
		console.error(ts(), 'FATAL', e?.stack || e?.message || String(e));
		await pgPool.end().catch(() => {});
		process.exit(1);
	});
