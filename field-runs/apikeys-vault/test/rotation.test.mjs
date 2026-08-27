// rotation.test.mjs — KEY-LIFECYCLE proof over the HTTP surface (the domain's whole point).
// Proves: rotate mints a NEW raw key, CHANGES the stored hash, INVALIDATES the prior credential, and writes
// a 'rotate' audit row; and that a revoked key is dead (rotate -> 409). This is the test-coverage component
// layer and the substantive evidence behind the secret-rotation policy for issued keys.
//
// Tokens injected from env, never inlined; values are short/low-entropy on purpose.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createStore } from '../core.mjs';
import { createServer } from '../server.mjs';

process.env.WALTEUR_TENANT_TOKENS = JSON.stringify({ tenantA: 'tokA', tenantB: 'tokB' });
const TOK = JSON.parse(process.env.WALTEUR_TENANT_TOKENS);

let server, base;

before(async () => {
  server = createServer(createStore());
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => new Promise((resolve) => server.close(resolve)));

async function call(method, path, { tenant, token, body } = {}) {
  const headers = {};
  if (tenant !== undefined) headers['X-Tenant'] = tenant;
  if (token !== undefined) headers['Authorization'] = `Bearer ${token}`;
  const opts = { method, headers };
  if (body !== undefined) { headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
  const res = await fetch(base + path, opts);
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  return { status: res.status, json, text };
}

test('ROTATE invalidates the old key: hash changes, new raw key differs, rotatedAt advances', async () => {
  const issued = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'lifecycle' } });
  assert.equal(issued.status, 201);
  const id = issued.json.id;
  const oldRaw = issued.json.key;
  const before = await call('GET', `/keys/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  const oldHash = before.json.hash;
  const oldRotatedAt = before.json.rotatedAt;

  const rotated = await call('POST', `/keys/${id}/rotate`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(rotated.status, 200);
  assert.ok(rotated.json.key.startsWith('wk_'), 'a fresh raw key is returned ONCE');
  assert.notEqual(rotated.json.key, oldRaw, 'the new raw key differs from the original');

  const after = await call('GET', `/keys/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.notEqual(after.json.hash, oldHash, 'the stored hash CHANGED — the old credential no longer matches');
  assert.ok(after.json.rotatedAt > oldRotatedAt, 'rotatedAt advanced');
  assert.equal(after.json.createdAt, issued.json.createdAt, 'createdAt is preserved across rotation');
  assert.notEqual(after.json.last4, '', 'last4 reflects the new key');
});

test('ROTATE writes a tenant-scoped audit row (action: rotate, same key id)', async () => {
  const issued = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'audited-rotate' } });
  const id = issued.json.id;

  const before = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  const beforeRotateRows = before.json.filter((e) => e.action === 'rotate' && e.id === id).length;

  await call('POST', `/keys/${id}/rotate`, { tenant: 'tenantA', token: TOK.tenantA });

  const after = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  const afterRotateRows = after.json.filter((e) => e.action === 'rotate' && e.id === id).length;
  assert.equal(afterRotateRows, beforeRotateRows + 1, 'exactly one rotate audit row was written for this key');
  assert.ok(after.json.every((e) => e.tenantId === 'tenantA'), 'audit rows stay tenant-scoped');
});

test('repeated rotation keeps changing the hash each time (no hash reuse across rotations)', async () => {
  const issued = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'multi-rotate' } });
  const id = issued.json.id;
  const seen = new Set([issued.json.hash]);
  for (let i = 0; i < 3; i++) {
    await call('POST', `/keys/${id}/rotate`, { tenant: 'tenantA', token: TOK.tenantA });
    const cur = (await call('GET', `/keys/${id}`, { tenant: 'tenantA', token: TOK.tenantA })).json.hash;
    assert.ok(!seen.has(cur), `rotation ${i + 1} produced a previously-unseen hash`);
    seen.add(cur);
  }
});

test('a REVOKED key is dead: rotate returns 409 and the key stays revoked', async () => {
  const issued = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'revoke-then-rotate' } });
  const id = issued.json.id;
  const rev = await call('DELETE', `/keys/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(rev.json.status, 'revoked');

  const rot = await call('POST', `/keys/${id}/rotate`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(rot.status, 409, 'a revoked key cannot be rotated');

  const after = await call('GET', `/keys/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(after.json.status, 'revoked', 'the key remains revoked');
});
