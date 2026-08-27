// EXECUTABLE authz proof: the cross-tenant denial is asserted by an actually-running test,
// not a self-written "verdict:PASS". Run: node --test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStore } from './core.mjs';

test('same-tenant: add, list, get, complete work', () => {
  const s = createStore();
  const a = s.add('tenantA', 'write spec');
  assert.equal(a.tenantId, 'tenantA');
  assert.deepEqual(s.list('tenantA').map((t) => t.title), ['write spec']);
  assert.equal(s.get('tenantA', a.id).id, a.id);
  assert.equal(s.complete('tenantA', a.id).done, true);
});

test('list is tenant-scoped — no tenant ever sees another tenant rows', () => {
  const s = createStore();
  s.add('tenantA', 'A-1');
  s.add('tenantA', 'A-2');
  s.add('tenantB', 'B-1');
  assert.equal(s.list('tenantA').length, 2);
  assert.equal(s.list('tenantB').length, 1);
  assert.ok(s.list('tenantB').every((t) => t.title.startsWith('B')));
});

test('DENY-BY-DEFAULT read: cross-tenant get returns null, never the other tenant data', () => {
  const s = createStore();
  const a = s.add('tenantA', 'secret roadmap');
  // tenantB tries to read tenantA's row by id
  assert.equal(s.get('tenantB', a.id), null);
});

test('DENY-BY-DEFAULT write: cross-tenant complete/remove throws forbidden', () => {
  const s = createStore();
  const a = s.add('tenantA', 'A-1');
  assert.throws(() => s.complete('tenantB', a.id), /forbidden/);
  assert.throws(() => s.remove('tenantB', a.id), /forbidden/);
  // and tenantA's row is untouched
  assert.equal(s.get('tenantA', a.id).done, false);
});

test('isolation invariant: across many tenants/ids, no cross-tenant leak ever occurs', () => {
  const s = createStore();
  const ids = {};
  for (const tn of ['t1', 't2', 't3', 't4']) {
    ids[tn] = [s.add(tn, `${tn}-x`).id, s.add(tn, `${tn}-y`).id];
  }
  for (const owner of Object.keys(ids)) {
    for (const other of Object.keys(ids)) {
      if (other === owner) continue;
      for (const id of ids[owner]) {
        assert.equal(s.get(other, id), null, `${other} must not read ${owner}'s task ${id}`);
        assert.throws(() => s.complete(other, id), /forbidden/);
      }
    }
  }
});

test('auto-audit: every MUTATION (add/complete/remove) writes an audit row; reads do not', () => {
  const s = createStore();
  const a = s.add('tenantA', 'A-1'); // mutation 1
  s.get('tenantA', a.id); // read — must NOT audit
  s.list('tenantA'); // read — must NOT audit
  s.complete('tenantA', a.id); // mutation 2
  s.remove('tenantA', a.id); // mutation 3
  const trail = s.auditTrail('tenantA');
  assert.deepEqual(trail.map((e) => e.action), ['add', 'complete', 'remove']);
  assert.ok(trail.every((e) => e.tenantId === 'tenantA' && e.taskId === a.id));
});

test('auto-audit is tenant-scoped: a tenant never sees another tenant audit rows', () => {
  const s = createStore();
  const a = s.add('tenantA', 'A-1');
  s.add('tenantB', 'B-1');
  assert.equal(s.auditTrail('tenantA').length, 1);
  assert.equal(s.auditTrail('tenantB').length, 1);
  assert.ok(s.auditTrail('tenantB').every((e) => e.tenantId === 'tenantB'));
  // a denied cross-tenant write must NOT leave an audit row for the attacker or the victim
  assert.throws(() => s.complete('tenantB', a.id), /forbidden/);
  assert.equal(s.auditTrail('tenantB').length, 1); // unchanged — no audit for a denied action
});

test('DSAR right-to-erasure: a tenant erases ALL its own data (tasks + audit), nothing leaks or survives', () => {
  const s = createStore();
  const a = s.add('tenantA', 'A-1');
  s.complete('tenantA', a.id);
  s.add('tenantB', 'B-1');
  const erased = s.eraseTenant('tenantA');
  assert.ok(erased >= 1);
  // tenantA fully gone — data AND audit trail
  assert.deepEqual(s.list('tenantA'), []);
  assert.deepEqual(s.auditTrail('tenantA'), []);
  // tenantB untouched (erasure is tenant-scoped, deny-by-default)
  assert.equal(s.list('tenantB').length, 1);
  assert.equal(s.auditTrail('tenantB').length, 1);
});

test('input validation: missing tenantId or title is rejected', () => {
  const s = createStore();
  assert.throws(() => s.add('', 'x'), /tenantId required/);
  assert.throws(() => s.add('t', '  '), /title required/);
  assert.throws(() => s.list(''), /tenantId required/);
});
