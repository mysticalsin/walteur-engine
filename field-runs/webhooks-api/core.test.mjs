// EXECUTABLE authz + erasure + secret-handling proof at the UNIT level: the cross-tenant denial, DSAR
// erasure, and "secret stored only as a fingerprint" invariant are asserted by an actually-running test,
// not a self-written "verdict:PASS". Run: node --test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { createStore, ALLOWED_EVENTS } from './core.mjs';

const URL_A = 'https://hooks.example.com/a';
const URL_B = 'https://hooks.example.com/b';

test('same-tenant: create, list, get, update, delete work', () => {
  const s = createStore();
  const c = s.createSubscription('tenantA', { url: URL_A, eventType: 'order.created' });
  assert.equal(c.tenantId, 'tenantA');
  assert.equal(c.eventType, 'order.created');
  assert.equal(c.active, true, 'active defaults to true');
  assert.match(c.id, /^sub_[0-9a-f]{18}$/);

  const got = s.getSubscription('tenantA', c.id);
  assert.equal(got.url, URL_A);

  const upd = s.updateSubscription('tenantA', c.id, { active: false, eventType: 'order.updated' });
  assert.equal(upd.active, false);
  assert.equal(upd.eventType, 'order.updated');

  assert.equal(s.getSubscriptions('tenantA').length, 1);
  assert.equal(s.deleteSubscription('tenantA', c.id), true);
  assert.equal(s.getSubscription('tenantA', c.id), null);
});

test('SECRET HANDLING: raw secret returned ONCE on create; only a fingerprint + last4 are stored', () => {
  const s = createStore();
  const c = s.createSubscription('tenantA', { url: URL_A, eventType: 'order.created' });
  // create response carries the raw secret exactly once
  assert.match(c.secret, /^whsec_[A-Za-z0-9_-]{32}$/);
  // the fingerprint stored is the sha256 of THAT secret (one-way, recomputable, not the secret itself)
  const expected = 'sha256:' + crypto.createHash('sha256').update(c.secret).digest('hex');
  assert.equal(c.secretFingerprint, expected);
  assert.equal(c.secretLast4, c.secret.slice(-4));

  // a subsequent READ never returns the raw secret again
  const got = s.getSubscription('tenantA', c.id);
  assert.equal(got.secret, undefined, 'get() must never return the raw secret');
  assert.ok(got.secretFingerprint && got.secretLast4, 'fingerprint + last4 remain available');

  // and a list never leaks a raw secret either
  for (const row of s.getSubscriptions('tenantA')) {
    assert.equal(row.secret, undefined, 'list rows must never carry a raw secret');
  }
});

test('SECRET HANDLING: snapshot (persistence shape) contains NO raw secret value', () => {
  const s = createStore();
  const c = s.createSubscription('tenantA', { url: URL_A, eventType: 'order.created' });
  const snap = s.snapshot();
  const blob = JSON.stringify(snap);
  assert.ok(!blob.includes(c.secret), 'the raw secret must never appear in the persisted snapshot');
  assert.ok(blob.includes(c.secretFingerprint), 'the fingerprint DOES persist (identifies the secret)');
});

test('rotate-secret: mints a NEW secret, replaces the fingerprint, returns the raw secret once', () => {
  const s = createStore();
  const c = s.createSubscription('tenantA', { url: URL_A, eventType: 'order.created' });
  const r = s.rotateSecret('tenantA', c.id);
  assert.match(r.secret, /^whsec_[A-Za-z0-9_-]{32}$/);
  assert.notEqual(r.secret, c.secret, 'rotation produces a different secret');
  assert.notEqual(r.secretFingerprint, c.secretFingerprint, 'the stored fingerprint changes on rotate');
  const got = s.getSubscription('tenantA', c.id);
  assert.equal(got.secretFingerprint, r.secretFingerprint, 'the new fingerprint is what persists');
  assert.equal(got.secret, undefined, 'rotate does not leave a raw secret in the store');
});

test('validation: url must be a valid https URL, host must not be internal (SSRF guard)', () => {
  const s = createStore();
  assert.throws(() => s.createSubscription('t', { url: 'http://hooks.example.com/x', eventType: 'order.created' }), /valid https URL/);
  assert.throws(() => s.createSubscription('t', { url: 'not-a-url', eventType: 'order.created' }), /valid https URL/);
  assert.throws(() => s.createSubscription('t', { url: '', eventType: 'order.created' }), /valid https URL/);
  // SSRF: loopback + private ranges are denied
  assert.throws(() => s.createSubscription('t', { url: 'https://localhost/x', eventType: 'order.created' }), /host not allowed/);
  assert.throws(() => s.createSubscription('t', { url: 'https://127.0.0.1/x', eventType: 'order.created' }), /host not allowed/);
  assert.throws(() => s.createSubscription('t', { url: 'https://10.0.0.5/x', eventType: 'order.created' }), /host not allowed/);
  assert.throws(() => s.createSubscription('t', { url: 'https://192.168.1.10/x', eventType: 'order.created' }), /host not allowed/);
  assert.throws(() => s.createSubscription('t', { url: 'https://169.254.169.254/latest/meta-data', eventType: 'order.created' }), /host not allowed/);
});

test('validation: eventType must be on the allow-list; active must be boolean', () => {
  const s = createStore();
  assert.throws(() => s.createSubscription('t', { url: URL_A, eventType: 'totally.made.up' }), /eventType not allowed/);
  assert.throws(() => s.createSubscription('t', { url: URL_A, eventType: 'order.created', active: 'yes' }), /active must be a boolean/);
  // every declared allow-listed event is actually accepted
  for (const ev of ALLOWED_EVENTS) {
    const c = s.createSubscription('t', { url: URL_A, eventType: ev });
    assert.equal(c.eventType, ev);
  }
});

test('getSubscriptions is tenant-scoped — no tenant ever sees another tenant subscriptions', () => {
  const s = createStore();
  s.createSubscription('tenantA', { url: URL_A, eventType: 'order.created' });
  s.createSubscription('tenantA', { url: URL_B, eventType: 'order.updated' });
  s.createSubscription('tenantB', { url: URL_A, eventType: 'user.created' });
  assert.equal(s.getSubscriptions('tenantA').length, 2);
  assert.equal(s.getSubscriptions('tenantB').length, 1);
  assert.ok(s.getSubscriptions('tenantB').every((x) => x.tenantId === 'tenantB'));
});

test('DENY-BY-DEFAULT read: cross-tenant getSubscription returns null, never the other tenant sub', () => {
  const s = createStore();
  const a = s.createSubscription('tenantA', { url: URL_A, eventType: 'payment.succeeded' });
  // tenantB tries to read tenantA's subscription by its real id
  assert.equal(s.getSubscription('tenantB', a.id), null, 'B must not read A sub, even with the real id');
  assert.deepEqual(s.getSubscriptions('tenantB'), []);
});

test('DENY-BY-DEFAULT write: cross-tenant update/rotate/delete throw forbidden, A sub untouched', () => {
  const s = createStore();
  const a = s.createSubscription('tenantA', { url: URL_A, eventType: 'order.created' });
  assert.throws(() => s.updateSubscription('tenantB', a.id, { active: false }), /forbidden/);
  assert.throws(() => s.rotateSecret('tenantB', a.id), /forbidden/);
  assert.throws(() => s.deleteSubscription('tenantB', a.id), /forbidden/);
  // tenantA's subscription is still present and unchanged
  const still = s.getSubscription('tenantA', a.id);
  assert.equal(still.active, true);
  assert.equal(still.secretFingerprint, a.secretFingerprint, "B's denied rotate did not change A's secret");
});

test('isolation invariant: across many tenants/ids, no cross-tenant leak ever occurs', () => {
  const s = createStore();
  const tenants = ['t1', 't2', 't3', 't4'];
  const owned = {};
  for (const tn of tenants) {
    owned[tn] = s.createSubscription(tn, { url: URL_A, eventType: 'order.created' }).id;
  }
  for (const ownerT of tenants) {
    for (const other of tenants) {
      if (other === ownerT) continue;
      assert.equal(s.getSubscription(other, owned[ownerT]), null, `${other} must not read ${ownerT}'s sub`);
      assert.throws(() => s.deleteSubscription(other, owned[ownerT]), /forbidden/);
      assert.throws(() => s.updateSubscription(other, owned[ownerT], { active: false }), /forbidden/);
    }
  }
});

test('auto-audit: every MUTATION (create/update/rotate/delete) writes a row; reads do not', () => {
  const s = createStore();
  const c = s.createSubscription('tenantA', { url: URL_A, eventType: 'order.created' }); // create
  s.getSubscription('tenantA', c.id);   // read — must NOT audit
  s.getSubscriptions('tenantA');         // read — must NOT audit
  s.updateSubscription('tenantA', c.id, { active: false }); // update
  s.rotateSecret('tenantA', c.id);       // rotate
  s.deleteSubscription('tenantA', c.id); // delete
  const trail = s.auditTrail('tenantA');
  assert.deepEqual(trail.map((e) => e.action), ['create', 'update', 'rotate', 'delete']);
  assert.ok(trail.every((e) => e.tenantId === 'tenantA' && e.id === c.id));
});

test('auto-audit is tenant-scoped: a tenant never sees another tenant audit rows', () => {
  const s = createStore();
  s.createSubscription('tenantA', { url: URL_A, eventType: 'order.created' });
  s.createSubscription('tenantB', { url: URL_A, eventType: 'order.created' });
  assert.equal(s.auditTrail('tenantA').length, 1);
  assert.equal(s.auditTrail('tenantB').length, 1);
  // a denied cross-tenant write must NOT leave an audit row for attacker or victim
  const a = s.getSubscriptions('tenantA')[0];
  assert.throws(() => s.deleteSubscription('tenantB', a.id), /forbidden/);
  assert.equal(s.auditTrail('tenantB').length, 1); // unchanged — no audit for a denied action
});

test('DSAR right-to-erasure: a tenant erases ALL its own data (subs + audit), nothing leaks or survives', () => {
  const s = createStore();
  s.createSubscription('tenantA', { url: URL_A, eventType: 'order.created' });
  s.createSubscription('tenantA', { url: URL_B, eventType: 'order.updated' });
  s.createSubscription('tenantB', { url: URL_A, eventType: 'user.created' });
  const erased = s.eraseTenant('tenantA');
  assert.ok(erased >= 1);
  // tenantA fully gone — subscriptions AND audit trail
  assert.deepEqual(s.getSubscriptions('tenantA'), []);
  assert.deepEqual(s.auditTrail('tenantA'), []);
  // tenantB untouched (erasure is tenant-scoped, deny-by-default)
  assert.equal(s.getSubscriptions('tenantB').length, 1);
  assert.equal(s.auditTrail('tenantB').length, 1);
});

test('input validation: missing tenantId is rejected', () => {
  const s = createStore();
  assert.throws(() => s.createSubscription('', { url: URL_A, eventType: 'order.created' }), /tenantId required/);
  assert.throws(() => s.getSubscriptions(''), /tenantId required/);
  assert.throws(() => s.auditTrail('  '), /tenantId required/);
});

test('snapshot/load round-trips the store (persistence) without cross-tenant bleed or secret leak', () => {
  const s = createStore();
  const a = s.createSubscription('tenantA', { url: URL_A, eventType: 'order.created' });
  const b = s.createSubscription('tenantB', { url: URL_B, eventType: 'user.updated' });
  const snap = s.snapshot();
  const s2 = createStore();
  s2.load(snap);
  assert.equal(s2.getSubscription('tenantA', a.id).url, URL_A);
  assert.equal(s2.getSubscription('tenantB', b.id).eventType, 'user.updated');
  assert.equal(s2.getSubscription('tenantB', a.id), null, 'load must not bleed A ids into B');
  // the reloaded store still carries no raw secret
  assert.equal(s2.getSubscription('tenantA', a.id).secret, undefined);
});
