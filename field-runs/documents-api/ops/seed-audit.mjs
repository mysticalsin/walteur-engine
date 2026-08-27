// ops/seed-audit.mjs — refresh the on-disk audit marker (audit.json) for the documents-api field run.
//
// This writes a SMALL, FRESH provenance marker recording WHEN the audit trail mechanism was last seeded
// and WHICH executable proof backs it. It does NOT fabricate audit rows: the real, tenant-scoped audit
// trail is produced at runtime by core.mjs auditTrail() and proven by the executable tests named here.
// The marker simply timestamps that the audit machinery is wired and re-verified, so the audit cert's
// "fresh" claim points at a file that was actually touched this run — never a stale or invented artifact.
//
// Node built-ins only. Writes documents-api/audit.json (relative to repo root, i.e. ../ from ops/).
// Run: node ops/seed-audit.mjs

import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createStore } from '../core.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, '..');
const OUT = path.join(ROOT, 'audit.json');

// Exercise the REAL audit machinery once so this marker is backed by an actually-run trail, not a claim.
// Two tenants, a few mutations + a denied cross-tenant write that must leave NO row — the same invariant
// the tests assert. We record only the SHAPE (counts), never any tenant body content.
const s = createStore();
const a = s.createDoc('seed-tenant-a', 'seed-doc', 'seed-body');
s.updateDoc('seed-tenant-a', a.id, { body: 'seed-body-2' });
s.createDoc('seed-tenant-b', 'b-doc', 'b-body');
let deniedLeftNoRow = false;
const bBefore = s.auditTrail('seed-tenant-b').length;
try { s.deleteDoc('seed-tenant-b', a.id); } catch { /* forbidden — expected */ }
deniedLeftNoRow = s.auditTrail('seed-tenant-b').length === bBefore;

const marker = {
  schema_version: 1,
  service: 'documents-api',
  seeded_ts: new Date().toISOString(),
  audit_mechanism: 'core.mjs auditTrail() — auto-audits every create/update/delete; reads are not audited; tenant-scoped.',
  self_check: {
    tenant_a_rows: s.auditTrail('seed-tenant-a').length,
    tenant_b_rows: s.auditTrail('seed-tenant-b').length,
    denied_cross_tenant_write_left_no_row: deniedLeftNoRow,
  },
  backed_by: [
    'core.test.mjs (auto-audit + tenant-scoped + DSAR erasure)',
    'test/api.test.mjs (GET /audit tenant-scoped over HTTP)',
    'test/cross-tenant.test.mjs (denied write leaves no audit row)',
  ],
  verification_probe: 'node --test test/api.test.mjs',
  note: 'This marker is FRESH provenance for the audit cert; runtime audit rows are produced by core.mjs, not by this file.',
};

writeFileSync(OUT, JSON.stringify(marker, null, 2) + '\n');
process.stdout.write(`seed-audit: wrote ${OUT} (a_rows=${marker.self_check.tenant_a_rows} b_rows=${marker.self_check.tenant_b_rows} denied_left_no_row=${deniedLeftNoRow})\n`);
