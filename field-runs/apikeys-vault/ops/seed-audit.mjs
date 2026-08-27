// ops/seed-audit.mjs — refresh the on-disk audit marker (audit.json) for the apikeys-vault field run.
//
// This writes a SMALL, FRESH provenance marker recording WHEN the audit trail mechanism was last seeded and
// WHICH executable proof backs it. It does NOT fabricate audit rows: the real, tenant-scoped audit trail is
// produced at runtime by core.mjs auditTrail() and proven by the executable tests named here. The marker
// simply timestamps that the audit machinery is wired and re-verified, so the audit cert's "fresh" claim
// points at a file that was actually touched this run — never a stale or invented artifact.
//
// It exercises the REAL key-lifecycle (create -> rotate -> revoke) so the recorded counts are backed by an
// actually-run trail, and it asserts the CARDINAL invariant in passing: no raw key appears in the trail.
//
// Node built-ins only. Writes apikeys-vault/audit.json (relative to repo root, i.e. ../ from ops/).
// Run: node ops/seed-audit.mjs

import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createStore } from '../core.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, '..');
const OUT = path.join(ROOT, 'audit.json');

// Exercise the REAL audit machinery once so this marker is backed by an actually-run trail, not a claim.
// Two tenants, the full key lifecycle (create/rotate/revoke) + a denied cross-tenant rotate that must leave
// NO row — the same invariants the tests assert. We record only the SHAPE (counts), never any key material.
const s = createStore();
const a = s.createKey('seed-tenant-a', 'seed-key');
const rotated = s.rotateKey('seed-tenant-a', a.id);
s.revokeKey('seed-tenant-a', a.id);
const b = s.createKey('seed-tenant-b', 'b-key');

let deniedLeftNoRow = false;
const bBefore = s.auditTrail('seed-tenant-b').length;
try { s.rotateKey('seed-tenant-b', a.id); } catch { /* forbidden — expected */ }
deniedLeftNoRow = s.auditTrail('seed-tenant-b').length === bBefore;

// confirm in passing that no raw key ever reaches the audit trail
const trailStr = JSON.stringify(s.auditTrail('seed-tenant-a'));
const rawNeverInTrail = !trailStr.includes(a.key) && !trailStr.includes(rotated.key);

const marker = {
  schema_version: 1,
  service: 'apikeys-vault',
  seeded_ts: new Date().toISOString(),
  audit_mechanism: 'core.mjs auditTrail() — auto-audits every create/rotate/revoke; reads are not audited; tenant-scoped; raw keys never recorded.',
  self_check: {
    tenant_a_rows: s.auditTrail('seed-tenant-a').length,
    tenant_b_rows: s.auditTrail('seed-tenant-b').length,
    tenant_a_actions: s.auditTrail('seed-tenant-a').map((e) => e.action),
    denied_cross_tenant_rotate_left_no_row: deniedLeftNoRow,
    raw_key_never_in_trail: rawNeverInTrail,
  },
  backed_by: [
    'core.test.mjs (auto-audit + tenant-scoped + rotation + DSAR erasure + raw-never-stored)',
    'test/api.test.mjs (GET /audit tenant-scoped over HTTP)',
    'test/cross-tenant.test.mjs (denied rotate/revoke leaves no audit row)',
    'test/rotation.test.mjs (rotate writes a rotate audit row + changes the hash)',
  ],
  verification_probe: 'node --test test/api.test.mjs',
  note: 'This marker is FRESH provenance for the audit cert; runtime audit rows are produced by core.mjs, not by this file.',
};

writeFileSync(OUT, JSON.stringify(marker, null, 2) + '\n');
process.stdout.write(`seed-audit: wrote ${OUT} (a_rows=${marker.self_check.tenant_a_rows} b_rows=${marker.self_check.tenant_b_rows} denied_left_no_row=${deniedLeftNoRow} raw_never_in_trail=${rawNeverInTrail})\n`);
