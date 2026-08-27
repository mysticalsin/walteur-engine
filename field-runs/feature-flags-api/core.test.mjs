// EXECUTABLE authz + erasure proof at the UNIT level: the cross-tenant denial and DSAR erasure are
// asserted by an actually-running test, not a self-written "verdict:PASS". Run: node --test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStore } from './core.mjs';

test('same-tenant: setFlag, getFlags, getFlag, deleteFlag work (boolean + variant)', () => {
  const s = createStore();
  const b = s.setFlag('tenantA', 'new-checkout', true);
  assert.equal(b.tenantId, 'tenantA');
  assert.equal(b.kind, 'boolean');
  assert.equal(b.value, true);

  const v = s.setFlag('tenantA', 'banner-color', 'blue');
  assert.equal(v.kind, 'variant');
  assert.equal(v.value, 'blue');

  assert.deepEqual(s.getFlags('tenantA').map((f) => f.key).sort(), ['banner-color', 'new-checkout']);
  assert.equal(s.getFlag('tenantA', 'new-checkout').value, true);
  assert.equal(s.deleteFlag('tenantA', 'banner-color'), true);
  assert.equal(s.getFlag('tenantA', 'banner-color'), null);
});

test('setFlag updates an existing OWNED flag in place (no duplicate key)', () => {
  const s = createStore();
  s.setFlag('tenantA', 'beta', false);
  s.setFlag('tenantA', 'beta', true); // update
  const flags = s.getFlags('tenantA').filter((f) => f.key === 'beta');
  assert.equal(flags.length, 1, 'same key updates, never duplicates');
  assert.equal(flags[0].value, true);
});

test('getFlags is tenant-scoped — no tenant ever sees another tenant flags', () => {
  const s = createStore();
  s.setFlag('tenantA', 'a-1', true);
  s.setFlag('tenantA', 'a-2', 'on');
  s.setFlag('tenantB', 'b-1', true);
  assert.equal(s.getFlags('tenantA').length, 2);
  assert.equal(s.getFlags('tenantB').length, 1);
  assert.ok(s.getFlags('tenantB').every((f) => f.tenantId === 'tenantB'));
});

test('same key in two tenants is two INDEPENDENT flags (no shared namespace)', () => {
  const s = createStore();
  s.setFlag('tenantA', 'dark-mode', true);
  s.setFlag('tenantB', 'dark-mode', false);
  assert.equal(s.getFlag('tenantA', 'dark-mode').value, true);
  assert.equal(s.getFlag('tenantB', 'dark-mode').value, false, 'B writing its own key must not affect A');
});

test('DENY-BY-DEFAULT read: cross-tenant getFlag returns null, never the other tenant flag', () => {
  const s = createStore();
  s.setFlag('tenantA', 'secret-rollout', 'treatment');
  // tenantB tries to read tenantA's flag by the same key name
  assert.equal(s.getFlag('tenantB', 'secret-rollout'), null, 'B must not read A flag, even by key name');
  // and B's own view is empty
  assert.deepEqual(s.getFlags('tenantB'), []);
});

test('DENY-BY-DEFAULT write: cross-tenant deleteFlag throws forbidden, A flag untouched', () => {
  const s = createStore();
  s.setFlag('tenantA', 'a-only', true);
  assert.throws(() => s.deleteFlag('tenantB', 'a-only'), /forbidden/);
  // tenantA's flag is still present and unchanged
  assert.equal(s.getFlag('tenantA', 'a-only').value, true);
});

test('isolation invariant: across many tenants/keys, no cross-tenant leak ever occurs', () => {
  const s = createStore();
  const tenants = ['t1', 't2', 't3', 't4'];
  for (const tn of tenants) { s.setFlag(tn, 'shared-key', tn); s.setFlag(tn, `${tn}-key`, true); }
  for (const owner of tenants) {
    for (const other of tenants) {
      if (other === owner) continue;
      // other must NOT see owner's private key at all
      assert.equal(s.getFlag(other, `${owner}-key`), null, `${other} must not read ${owner}'s private key`);
      // the shared key name resolves to EACH tenant's OWN value, never the owner's
      assert.equal(s.getFlag(other, 'shared-key').value, other, 'shared-key resolves per-tenant, no leak');
      // and a cross-tenant delete of the private key is forbidden
      assert.throws(() => s.deleteFlag(other, `${owner}-key`), /forbidden/);
    }
  }
});

test('auto-audit: every MUTATION (set/delete) writes an audit row; reads do not', () => {
  const s = createStore();
  s.setFlag('tenantA', 'a-1', true);   // mutation 1
  s.getFlag('tenantA', 'a-1');          // read — must NOT audit
  s.getFlags('tenantA');                // read — must NOT audit
  s.setFlag('tenantA', 'a-1', false);  // mutation 2 (update)
  s.deleteFlag('tenantA', 'a-1');      // mutation 3
  const trail = s.auditTrail('tenantA');
  assert.deepEqual(trail.map((e) => e.action), ['set', 'set', 'delete']);
  assert.ok(trail.every((e) => e.tenantId === 'tenantA' && e.key === 'a-1'));
});

test('auto-audit is tenant-scoped: a tenant never sees another tenant audit rows', () => {
  const s = createStore();
  s.setFlag('tenantA', 'a-1', true);
  s.setFlag('tenantB', 'b-1', true);
  assert.equal(s.auditTrail('tenantA').length, 1);
  assert.equal(s.auditTrail('tenantB').length, 1);
  assert.ok(s.auditTrail('tenantB').every((e) => e.tenantId === 'tenantB'));
  // a denied cross-tenant write must NOT leave an audit row for the attacker or the victim
  assert.throws(() => s.deleteFlag('tenantB', 'a-1'), /forbidden/);
  assert.equal(s.auditTrail('tenantB').length, 1); // unchanged — no audit for a denied action
});

test('DSAR right-to-erasure: a tenant erases ALL its own data (flags + audit), nothing leaks or survives', () => {
  const s = createStore();
  s.setFlag('tenantA', 'a-1', true);
  s.setFlag('tenantA', 'a-2', 'variant-x');
  s.setFlag('tenantB', 'b-1', true);
  const erased = s.eraseTenant('tenantA');
  assert.ok(erased >= 1);
  // tenantA fully gone — flags AND audit trail
  assert.deepEqual(s.getFlags('tenantA'), []);
  assert.deepEqual(s.auditTrail('tenantA'), []);
  // tenantB untouched (erasure is tenant-scoped, deny-by-default)
  assert.equal(s.getFlags('tenantB').length, 1);
  assert.equal(s.auditTrail('tenantB').length, 1);
});

test('input validation: missing tenantId / key / bad value is rejected', () => {
  const s = createStore();
  assert.throws(() => s.setFlag('', 'k', true), /tenantId required/);
  assert.throws(() => s.setFlag('t', '  ', true), /key required/);
  assert.throws(() => s.setFlag('t', 'k', 123), /value must be a boolean or a non-empty variant string/);
  assert.throws(() => s.setFlag('t', 'k', ''), /value must be a boolean or a non-empty variant string/);
  assert.throws(() => s.getFlags(''), /tenantId required/);
});

test('snapshot/load round-trips the store (persistence) without cross-tenant bleed', () => {
  const s = createStore();
  s.setFlag('tenantA', 'a-1', true);
  s.setFlag('tenantB', 'b-1', 'on');
  const snap = s.snapshot();
  const s2 = createStore();
  s2.load(snap);
  assert.equal(s2.getFlag('tenantA', 'a-1').value, true);
  assert.equal(s2.getFlag('tenantB', 'b-1').value, 'on');
  assert.equal(s2.getFlag('tenantB', 'a-1'), null, 'load must not bleed A keys into B');
});
