// EXECUTABLE authz + erasure proof at the UNIT level: the cross-tenant denial and DSAR erasure are
// asserted by an actually-running test, not a self-written "verdict:PASS". Run: node --test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStore } from './core.mjs';

test('same-tenant: createDoc, getDocs, getDoc, updateDoc, deleteDoc work', () => {
  const s = createStore();
  const d = s.createDoc('tenantA', 'Q3 Plan', 'first draft');
  assert.equal(d.tenantId, 'tenantA');
  assert.ok(/^doc_[0-9a-f]+$/.test(d.id), 'id is opaque');
  assert.equal(d.title, 'Q3 Plan');
  assert.equal(d.body, 'first draft');
  assert.equal(d.createdAt, d.updatedAt);

  const d2 = s.createDoc('tenantA', 'Notes', '');
  assert.deepEqual(s.getDocs('tenantA').map((x) => x.title).sort(), ['Notes', 'Q3 Plan']);
  assert.equal(s.getDoc('tenantA', d.id).body, 'first draft');

  const upd = s.updateDoc('tenantA', d.id, { body: 'second draft' });
  assert.equal(upd.body, 'second draft');
  assert.ok(upd.updatedAt > upd.createdAt, 'update advances updatedAt, not createdAt');

  assert.equal(s.deleteDoc('tenantA', d2.id), true);
  assert.equal(s.getDoc('tenantA', d2.id), null);
});

test('createDoc assigns a fresh unique id per document (no id reuse within a tenant)', () => {
  const s = createStore();
  const a = s.createDoc('tenantA', 'A', 'x');
  const b = s.createDoc('tenantA', 'B', 'y');
  assert.notEqual(a.id, b.id, 'two creates get distinct ids');
  assert.equal(s.getDocs('tenantA').length, 2);
});

test('updateDoc patches only provided fields, leaves others intact', () => {
  const s = createStore();
  const d = s.createDoc('tenantA', 'Title-1', 'Body-1');
  const upd = s.updateDoc('tenantA', d.id, { title: 'Title-2' });
  assert.equal(upd.title, 'Title-2');
  assert.equal(upd.body, 'Body-1', 'body unchanged when only title patched');
});

test('getDocs is tenant-scoped — no tenant ever sees another tenant documents', () => {
  const s = createStore();
  s.createDoc('tenantA', 'a-1', 'x');
  s.createDoc('tenantA', 'a-2', 'y');
  s.createDoc('tenantB', 'b-1', 'z');
  assert.equal(s.getDocs('tenantA').length, 2);
  assert.equal(s.getDocs('tenantB').length, 1);
  assert.ok(s.getDocs('tenantB').every((d) => d.tenantId === 'tenantB'));
});

test('DENY-BY-DEFAULT read: cross-tenant getDoc returns null, never the other tenant doc', () => {
  const s = createStore();
  const a = s.createDoc('tenantA', 'confidential', 'treatment-plan');
  // tenantB tries to read tenantA's document by its real id
  assert.equal(s.getDoc('tenantB', a.id), null, 'B must not read A doc, even with the real id');
  // and B's own view is empty
  assert.deepEqual(s.getDocs('tenantB'), []);
});

test('DENY-BY-DEFAULT write: cross-tenant updateDoc/deleteDoc throws forbidden, A doc untouched', () => {
  const s = createStore();
  const a = s.createDoc('tenantA', 'a-only', 'original');
  assert.throws(() => s.deleteDoc('tenantB', a.id), /forbidden/);
  assert.throws(() => s.updateDoc('tenantB', a.id, { body: 'hacked' }), /forbidden/);
  // tenantA's doc is still present and unchanged
  const still = s.getDoc('tenantA', a.id);
  assert.equal(still.body, 'original');
});

test('isolation invariant: across many tenants/ids, no cross-tenant leak ever occurs', () => {
  const s = createStore();
  const tenants = ['t1', 't2', 't3', 't4'];
  const ids = {};
  for (const tn of tenants) {
    ids[tn] = s.createDoc(tn, `${tn}-title`, `${tn}-body`).id;
  }
  for (const owner of tenants) {
    for (const other of tenants) {
      if (other === owner) continue;
      // other must NOT see owner's doc at all
      assert.equal(s.getDoc(other, ids[owner]), null, `${other} must not read ${owner}'s doc by id`);
      // a cross-tenant update/delete of the owner's doc is forbidden
      assert.throws(() => s.deleteDoc(other, ids[owner]), /forbidden/);
      assert.throws(() => s.updateDoc(other, ids[owner], { body: 'x' }), /forbidden/);
    }
  }
});

test('auto-audit: every MUTATION (create/update/delete) writes an audit row; reads do not', () => {
  const s = createStore();
  const d = s.createDoc('tenantA', 't', 'b'); // mutation 1 (create)
  s.getDoc('tenantA', d.id);                  // read — must NOT audit
  s.getDocs('tenantA');                       // read — must NOT audit
  s.updateDoc('tenantA', d.id, { body: 'b2' }); // mutation 2 (update)
  s.deleteDoc('tenantA', d.id);                 // mutation 3 (delete)
  const trail = s.auditTrail('tenantA');
  assert.deepEqual(trail.map((e) => e.action), ['create', 'update', 'delete']);
  assert.ok(trail.every((e) => e.tenantId === 'tenantA' && e.id === d.id));
});

test('auto-audit is tenant-scoped: a tenant never sees another tenant audit rows', () => {
  const s = createStore();
  const a = s.createDoc('tenantA', 'a', '');
  s.createDoc('tenantB', 'b', '');
  assert.equal(s.auditTrail('tenantA').length, 1);
  assert.equal(s.auditTrail('tenantB').length, 1);
  assert.ok(s.auditTrail('tenantB').every((e) => e.tenantId === 'tenantB'));
  // a denied cross-tenant write must NOT leave an audit row for the attacker or the victim
  assert.throws(() => s.deleteDoc('tenantB', a.id), /forbidden/);
  assert.equal(s.auditTrail('tenantB').length, 1); // unchanged — no audit for a denied action
});

test('DSAR right-to-erasure: a tenant erases ALL its own data (docs + audit), nothing leaks or survives', () => {
  const s = createStore();
  s.createDoc('tenantA', 'a-1', 'x');
  s.createDoc('tenantA', 'a-2', 'y');
  s.createDoc('tenantB', 'b-1', 'z');
  const erased = s.eraseTenant('tenantA');
  assert.ok(erased >= 1);
  // tenantA fully gone — docs AND audit trail
  assert.deepEqual(s.getDocs('tenantA'), []);
  assert.deepEqual(s.auditTrail('tenantA'), []);
  // tenantB untouched (erasure is tenant-scoped, deny-by-default)
  assert.equal(s.getDocs('tenantB').length, 1);
  assert.equal(s.auditTrail('tenantB').length, 1);
});

test('input validation: missing tenantId / title / bad body is rejected', () => {
  const s = createStore();
  assert.throws(() => s.createDoc('', 'title', 'b'), /tenantId required/);
  assert.throws(() => s.createDoc('t', '  ', 'b'), /title required/);
  assert.throws(() => s.createDoc('t', 'title', 123), /body must be a string/);
  assert.throws(() => s.getDocs(''), /tenantId required/);
  // updating a non-owned/absent id is forbidden, not a crash
  assert.throws(() => s.updateDoc('t', 'doc_missing', { body: 'x' }), /forbidden/);
});

test('snapshot/load round-trips the store (persistence) without cross-tenant bleed', () => {
  const s = createStore();
  const a = s.createDoc('tenantA', 'a-1', 'x');
  const b = s.createDoc('tenantB', 'b-1', 'on');
  const snap = s.snapshot();
  const s2 = createStore();
  s2.load(snap);
  assert.equal(s2.getDoc('tenantA', a.id).body, 'x');
  assert.equal(s2.getDoc('tenantB', b.id).body, 'on');
  assert.equal(s2.getDoc('tenantB', a.id), null, 'load must not bleed A ids into B');
});
