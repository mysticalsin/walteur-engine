// EXECUTABLE proof at the UNIT level for the API-key vault: tenant isolation, rotation-changes-the-hash,
// DSAR erasure, and the CARDINAL invariant — raw keys are NEVER stored — are asserted by an actually-running
// test, not a self-written "verdict:PASS". Run: node --test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStore, hashKey } from './core.mjs';

test('createKey returns a raw key ONCE; store keeps only hash + last4 (raw never persisted)', () => {
  const s = createStore();
  const issued = s.createKey('tenantA', 'ci-deploy');
  assert.equal(issued.tenantId, 'tenantA');
  assert.ok(/^key_[0-9a-f]+$/.test(issued.id), 'id is opaque');
  assert.equal(issued.label, 'ci-deploy');
  assert.equal(issued.status, 'active');
  assert.ok(typeof issued.key === 'string' && issued.key.startsWith('wk_'), 'raw key returned at issue');

  // the stored metadata exposes the hash + last4, NEVER the raw key
  const got = s.getKey('tenantA', issued.id);
  assert.equal(got.key, undefined, 'getKey never returns a raw key field');
  assert.equal(got.hash, hashKey(issued.key), 'stored hash == sha256(rawKey)');
  assert.equal(got.last4, issued.key.slice(-4), 'last4 matches raw key tail');
  assert.equal(got.createdAt, got.rotatedAt, 'rotatedAt == createdAt until first rotate');

  // the raw key must NOT appear anywhere in the serialized store (snapshot is hashes only)
  const snapStr = JSON.stringify(s.snapshot());
  assert.ok(!snapStr.includes(issued.key), 'RAW KEY MUST NOT appear in any snapshot/persistence blob');
  // listKeys also never carries the raw value
  const listStr = JSON.stringify(s.listKeys('tenantA'));
  assert.ok(!listStr.includes(issued.key), 'RAW KEY MUST NOT appear in listKeys output');
});

test('listKeys returns metadata only, never a raw key, scoped to the tenant', () => {
  const s = createStore();
  s.createKey('tenantA', 'a-1');
  s.createKey('tenantA', 'a-2');
  s.createKey('tenantB', 'b-1');
  const aList = s.listKeys('tenantA');
  assert.equal(aList.length, 2);
  assert.ok(aList.every((k) => k.key === undefined), 'no raw key field in any list row');
  assert.ok(aList.every((k) => typeof k.hash === 'string' && k.last4.length === 4));
  assert.equal(s.listKeys('tenantB').length, 1);
  assert.ok(s.listKeys('tenantB').every((k) => k.tenantId === 'tenantB'));
});

test('ROTATE changes the stored hash and last4, mints a NEW raw key, bumps rotatedAt', () => {
  const s = createStore();
  const issued = s.createKey('tenantA', 'rotate-me');
  const beforeHash = s.getKey('tenantA', issued.id).hash;
  const beforeRotatedAt = s.getKey('tenantA', issued.id).rotatedAt;

  const rotated = s.rotateKey('tenantA', issued.id);
  assert.ok(rotated.key.startsWith('wk_'), 'rotate returns a fresh raw key ONCE');
  assert.notEqual(rotated.key, issued.key, 'rotation mints a DIFFERENT raw key');

  const after = s.getKey('tenantA', issued.id);
  assert.notEqual(after.hash, beforeHash, 'ROTATE CHANGES THE STORED HASH');
  assert.equal(after.hash, hashKey(rotated.key), 'new stored hash == sha256(new rawKey)');
  assert.ok(after.rotatedAt > beforeRotatedAt, 'rotatedAt advances on rotate');
  assert.equal(after.createdAt, issued.createdAt, 'createdAt is unchanged by rotate');

  // the OLD raw key no longer validates; the NEW one does
  assert.equal(s.verifyKey('tenantA', issued.key), null, 'old raw key is invalidated by rotation');
  assert.equal(s.verifyKey('tenantA', rotated.key), issued.id, 'new raw key validates after rotation');
});

test('verifyKey checks a presented key by hash (store holds no raw), tenant-scoped, revoke kills it', () => {
  const s = createStore();
  const a = s.createKey('tenantA', 'svc');
  assert.equal(s.verifyKey('tenantA', a.key), a.id, 'a valid active key verifies inside its tenant');
  assert.equal(s.verifyKey('tenantB', a.key), null, 'the same raw key does NOT verify under another tenant');
  s.revokeKey('tenantA', a.id);
  assert.equal(s.verifyKey('tenantA', a.key), null, 'a revoked key no longer verifies');
});

test('REVOKE flips status to revoked, stamps revokedAt, and a revoked key cannot be rotated', () => {
  const s = createStore();
  const a = s.createKey('tenantA', 'doomed');
  const rev = s.revokeKey('tenantA', a.id);
  assert.equal(rev.status, 'revoked');
  assert.ok(rev.revokedAt > a.createdAt, 'revokedAt stamped');
  assert.throws(() => s.rotateKey('tenantA', a.id), /revoked/, 'a revoked key cannot be rotated back to life');
});

test('DENY-BY-DEFAULT read: cross-tenant getKey returns null, never the other tenant key', () => {
  const s = createStore();
  const a = s.createKey('tenantA', 'a-secret');
  assert.equal(s.getKey('tenantB', a.id), null, 'B must not read A key, even with the real id');
  assert.deepEqual(s.listKeys('tenantB'), []);
});

test('DENY-BY-DEFAULT write: cross-tenant rotate/revoke throws forbidden, A key untouched', () => {
  const s = createStore();
  const a = s.createKey('tenantA', 'a-only');
  const aHashBefore = s.getKey('tenantA', a.id).hash;
  assert.throws(() => s.rotateKey('tenantB', a.id), /forbidden/);
  assert.throws(() => s.revokeKey('tenantB', a.id), /forbidden/);
  const still = s.getKey('tenantA', a.id);
  assert.equal(still.hash, aHashBefore, "A's key hash unchanged by B's denied attempts");
  assert.equal(still.status, 'active', "A's key not revoked by B");
});

test('isolation invariant: across many tenants/ids, no cross-tenant leak or mutation ever occurs', () => {
  const s = createStore();
  const tenants = ['t1', 't2', 't3', 't4'];
  const ids = {};
  for (const tn of tenants) ids[tn] = s.createKey(tn, `${tn}-key`).id;
  for (const owner of tenants) {
    for (const other of tenants) {
      if (other === owner) continue;
      assert.equal(s.getKey(other, ids[owner]), null, `${other} must not read ${owner}'s key by id`);
      assert.throws(() => s.rotateKey(other, ids[owner]), /forbidden/);
      assert.throws(() => s.revokeKey(other, ids[owner]), /forbidden/);
    }
  }
});

test('auto-audit: every MUTATION (create/rotate/revoke) writes a row; reads do not; raw key never logged', () => {
  const s = createStore();
  const a = s.createKey('tenantA', 'k'); // mutation 1 (create)
  s.getKey('tenantA', a.id);             // read — must NOT audit
  s.listKeys('tenantA');                 // read — must NOT audit
  s.verifyKey('tenantA', a.key);         // read — must NOT audit
  s.rotateKey('tenantA', a.id);          // mutation 2 (rotate)
  s.revokeKey('tenantA', a.id);          // mutation 3 (revoke)
  const trail = s.auditTrail('tenantA');
  assert.deepEqual(trail.map((e) => e.action), ['create', 'rotate', 'revoke']);
  assert.ok(trail.every((e) => e.tenantId === 'tenantA' && e.id === a.id));
  // the raw key must never appear in an audit row
  const trailStr = JSON.stringify(trail);
  assert.ok(!trailStr.includes(a.key), 'audit trail MUST NOT contain the raw key');
});

test('auto-audit is tenant-scoped: a denied cross-tenant write leaves NO row for attacker or victim', () => {
  const s = createStore();
  const a = s.createKey('tenantA', 'a');
  s.createKey('tenantB', 'b');
  assert.equal(s.auditTrail('tenantA').length, 1);
  assert.equal(s.auditTrail('tenantB').length, 1);
  assert.throws(() => s.revokeKey('tenantB', a.id), /forbidden/);
  assert.equal(s.auditTrail('tenantB').length, 1, 'denied cross-tenant action writes no audit row');
});

test('DSAR right-to-erasure: a tenant erases ALL its own data (keys + audit), nothing leaks or survives', () => {
  const s = createStore();
  s.createKey('tenantA', 'a-1');
  const a2 = s.createKey('tenantA', 'a-2');
  s.rotateKey('tenantA', a2.id);
  s.createKey('tenantB', 'b-1');
  const erased = s.eraseTenant('tenantA');
  assert.ok(erased >= 1);
  assert.deepEqual(s.listKeys('tenantA'), []);
  assert.deepEqual(s.auditTrail('tenantA'), []);
  // tenantB untouched (erasure is tenant-scoped, deny-by-default)
  assert.equal(s.listKeys('tenantB').length, 1);
  assert.equal(s.auditTrail('tenantB').length, 1);
});

test('input validation: missing tenantId / label is rejected; absent/foreign id is forbidden not a crash', () => {
  const s = createStore();
  assert.throws(() => s.createKey('', 'label'), /tenantId required/);
  assert.throws(() => s.createKey('t', '  '), /label required/);
  assert.throws(() => s.listKeys(''), /tenantId required/);
  assert.throws(() => s.rotateKey('t', 'key_missing'), /forbidden/);
  assert.throws(() => s.revokeKey('t', 'key_missing'), /forbidden/);
});

test('snapshot/load round-trips the store (hashes only) without cross-tenant bleed or raw-key leak', () => {
  const s = createStore();
  const a = s.createKey('tenantA', 'a-1');
  const b = s.createKey('tenantB', 'b-1');
  const snap = s.snapshot();
  // the snapshot is hashes only — neither raw key appears
  const snapStr = JSON.stringify(snap);
  assert.ok(!snapStr.includes(a.key) && !snapStr.includes(b.key), 'no raw key in snapshot');

  const s2 = createStore();
  s2.load(snap);
  assert.equal(s2.getKey('tenantA', a.id).hash, hashKey(a.key), 'A hash survives reload');
  assert.equal(s2.getKey('tenantB', b.id).hash, hashKey(b.key), 'B hash survives reload');
  assert.equal(s2.getKey('tenantB', a.id), null, 'load must not bleed A ids into B');
  // after reload the keys still validate by their original raw value (hash round-tripped intact)
  assert.equal(s2.verifyKey('tenantA', a.key), a.id, 'reloaded hash still validates the original raw key');
});

test('two issues never collide and the mint has real entropy', () => {
  const s = createStore();
  const a = s.createKey('tenantA', 'A');
  const b = s.createKey('tenantA', 'B');
  assert.notEqual(a.id, b.id, 'distinct ids');
  assert.notEqual(a.key, b.key, 'distinct raw keys');
  // sanity: the random body is 32 bytes base64url (~43 chars) — high entropy
  assert.ok(a.key.length > 40, 'minted key carries substantial random material');
  assert.ok(a.key.startsWith('wk_'), 'minted key carries the wk_ prefix');
});
