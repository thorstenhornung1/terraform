#!/usr/bin/env node
// =============================================================================
// Offline shape test — proves the document this tool builds is byte-identical
// in STRUCTURE to what Open Archiver v0.5.0 writes and to the live Meili docs
// captured on 2026-06-07. Runs fully offline (no DB/S3/Meili/Tika).
//
//   node src/shape.test.mjs
//
// It re-implements ONLY the pure transform parts of reindex.mjs (kept in sync
// by hand; they are tiny) and asserts:
//   - exact top-level key set + order
//   - field types (from=string, to/cc/bcc=string[], attachments=[{filename,content}],
//     timestamp=number, etc.)
//   - recipients jsonb uses `.address` (NOT `.email`)
// =============================================================================

import assert from 'node:assert/strict';

// --- copies of the pure helpers from reindex.mjs (must stay identical) -------
function sanitizeText(text) {
	if (!text) return '';
	return text.replace(/�/g, '').replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '').trim();
}
function sanitizeObject(obj) {
	if (typeof obj === 'string') return sanitizeText(obj);
	if (Array.isArray(obj)) return obj.map(sanitizeObject);
	if (obj !== null && typeof obj === 'object') {
		const o = {};
		for (const k in obj) if (Object.prototype.hasOwnProperty.call(obj, k)) o[k] = sanitizeObject(obj[k]);
		return o;
	}
	return obj;
}
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
// builder body identical to createEmailDocument() minus the I/O (S3/Tika/parse).
function assembleDoc(email, emailBodyText, attachmentContents) {
	const recipients = email.recipients || {};
	const addr = (list) => (Array.isArray(list) ? list.map((r) => r?.address).filter(Boolean) : []);
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

// --- synthetic DB row (column names exactly as in archived_emails) ----------
const row = {
	id: 'a46c1d71-9a23-44d5-b2d0-1b1cc63e905c',
	user_email: 'thorsten@hornung-bn.de',
	sender_email: 'newsletter@example.com',
	recipients: {
		to: [{ name: 'T H', address: 'thorsten@hornung-bn.de' }],
		cc: [],
		bcc: [],
	},
	subject: '⚽WM-Aktion control-char test', // includes BEL (0x07) to test sanitize
	storage_path: 'open-archiver/O365-Online-09918f39/emails/foo<id>.eml',
	sent_at: '2026-06-07T15:32:30.000Z',
	ingestion_source_id: '09918f39-7961-43cf-99b0-d2d8b73c6dcc',
	has_attachments: true,
};

const raw = assembleDoc(row, 'Hello body text', [{ filename: 'invoice.pdf', content: 'extracted text' }]);
const doc = ensureEmailDocumentFields(sanitizeObject(raw));

// --- assertions: live wire shape captured from Meili on 2026-06-07 ----------
const EXPECTED_KEYS = ['id', 'userEmail', 'from', 'to', 'cc', 'bcc', 'subject', 'body', 'attachments', 'timestamp', 'ingestionSourceId'];
assert.deepEqual(Object.keys(doc), EXPECTED_KEYS, 'top-level keys must match live Meili docs exactly (order included)');

assert.equal(typeof doc.id, 'string');
assert.equal(typeof doc.from, 'string', 'from must be a single string (== sender_email), NOT an array');
assert.ok(Array.isArray(doc.to) && typeof doc.to[0] === 'string', 'to must be string[]');
assert.deepEqual(doc.to, ['thorsten@hornung-bn.de'], 'recipients mapped via .address');
assert.deepEqual(doc.cc, []);
assert.deepEqual(doc.bcc, []);
assert.equal(typeof doc.timestamp, 'number');
assert.equal(doc.timestamp, Date.parse('2026-06-07T15:32:30.000Z'), 'timestamp = ms epoch of sent_at');
assert.ok(Array.isArray(doc.attachments) && doc.attachments[0].filename === 'invoice.pdf');
assert.deepEqual(Object.keys(doc.attachments[0]), ['filename', 'content'], 'attachment item shape = {filename, content}');
assert.ok(!doc.subject.includes(''), 'control characters must be stripped by sanitize');
assert.equal(typeof doc.ingestionSourceId, 'string');

// negative: ensure we did NOT accidentally use the `.email` key (Recipient type)
const wrongShape = assembleDoc({ ...row, recipients: { to: [{ name: 'x', email: 'wrong@x' }] } }, '', []);
assert.deepEqual(wrongShape.to, [], 'rows using .email (not .address) must yield empty — confirms we read .address like OA');

console.log('OK — document shape matches Open Archiver v0.5.0 + live Meili wire format.');
console.log(JSON.stringify(doc, null, 2));
