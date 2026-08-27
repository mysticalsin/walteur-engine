// injection-driver.mjs — executed adversarial probe driver for the apikeys-vault core.
//
// The injection-resistance-gate runs this as `node injection-driver.mjs <hostile-input-file>` under a
// hard timeout. It reads a hostile input string from argv[2] and drives EVERY untrusted-input path of the
// REAL core.mjs, asserting the domain's own security invariants:
//   1. RAW KEY NEVER LEAKS   — the once-shown raw secret never appears in any read/serialize surface.
//   2. CROSS-TENANT ISOLATION — a hostile tenantId/id can never read/rotate/revoke another tenant's key.
//   3. NO PROTOTYPE POLLUTION — a malicious snapshot into load() must not pollute Object.prototype.
//   4. NO ENV-SECRET LEAK     — a secret in the process env is never emitted.
// Exits 0 (PROBE_OK) iff every invariant holds; 1 (PROBE_FAIL) on a breach; a crash / hang is itself a
// failure the gate catches (signal / timeout). This is a run-proof against the actual code, not a claim.
import { readFileSync } from 'node:fs';
import { createStore } from './core.mjs';

const hostile = process.argv[2] ? readFileSync(process.argv[2], 'utf8') : 'x';
const CANARY = process.env.INJECTION_CANARY || '';
const fails = [];
const check = (cond, why) => { if (!cond) fails.push(why); };

const store = createStore();

// 1) RAW-KEY-NEVER-LEAKS: issue a key (hostile label), capture the once-shown raw, then assert its secret
//    body never appears in ANY read/serialize surface the store exposes.
const issued = store.createKey('tenantA', hostile.slice(0, 200) || 'label');
const raw = issued.key;
const rawBody = raw.replace(/^wk_/, '');
const surfaces = JSON.stringify({
  list: store.listKeys('tenantA'),
  get: store.getKey('tenantA', issued.id),
  audit: store.auditTrail('tenantA'),
  snap: store.snapshot(),
});
check(!surfaces.includes(rawBody), 'RAW KEY LEAKED into a read/serialize surface');
check(CANARY === '' || !surfaces.includes(CANARY), 'env canary leaked into output');

// 2) CROSS-TENANT ISOLATION under hostile ids: a hostile tenantId must not reach tenantA's key.
for (const evil of ['__proto__', 'constructor', 'prototype', hostile.slice(0, 60), 'tenantB']) {
  check(store.getKey(evil, issued.id) === null, 'cross-tenant read leaked via a hostile tenantId');
  check(store.listKeys(evil).every((k) => k.tenantId === evil), 'listKeys returned a foreign-tenant record');
  try { store.rotateKey(evil, issued.id); check(false, 'cross-tenant rotate succeeded'); } catch { /* forbidden expected */ }
  try { store.revokeKey(evil, issued.id); check(false, 'cross-tenant revoke succeeded'); } catch { /* forbidden expected */ }
}

// 3) NO PROTOTYPE POLLUTION via load(): a malicious snapshot must not pollute Object.prototype nor crash.
try {
  store.load(JSON.parse('{"tenants":{"__proto__":{"polluted":true}},"auditLog":[],"clock":0}'));
} catch { /* deny-by-default: rejecting is fine, polluting is not */ }
check(({}).polluted === undefined, 'Object.prototype polluted via load()');

// 4) DoS surface: verify accepts arbitrary presented material; must reject, not hang/crash.
try { store.verifyKey('tenantA', hostile.slice(0, 5000)); } catch { /* ok to reject */ }

if (fails.length) { console.error('PROBE_FAIL: ' + fails.join(' | ')); process.exit(1); }
console.log('PROBE_OK');
process.exit(0);
