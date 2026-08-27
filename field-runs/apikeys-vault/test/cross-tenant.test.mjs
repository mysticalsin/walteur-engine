// cross-tenant.test.mjs — DEDICATED deny-by-default proof over the HTTP surface.
// This is the authz cross_tenant_probe target. It proves the DENIAL specifically: a fully-authenticated
// tenantB CANNOT list, read, rotate, or revoke tenantA's keys, AND a denied action leaves NO audit row
// behind. A test that merely shows "the server responds" would prove nothing — every assertion here is
// about denial.
//
// Tokens are injected from env, never inlined; the values are short/low-entropy on purpose.

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

test('SETUP: tenantA owns a key; tenantB is a real, authenticated tenant', async () => {
  const created = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'a-confidential' } });
  assert.equal(created.status, 201);
  // tenantB can authenticate (proving the denial below is authorization, not authentication)
  const bOwn = await call('GET', '/keys', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bOwn.status, 200);
});

test('DENY READ: tenantB GET of tenantA key -> 404, body carries no A data', async () => {
  const a = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'a-rollout' } });
  const bRead = await call('GET', `/keys/${a.json.id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bRead.status, 404, 'cross-tenant read MUST be denied (404, no existence oracle)');
  assert.ok(!bRead.text.includes(a.json.hash), 'denied read MUST NOT leak the foreign key hash');
  assert.ok(!bRead.text.includes(a.json.last4), 'denied read MUST NOT leak the foreign last4');
});

test('DENY ROTATE: tenantB rotate of tenantA key -> 403, A key hash untouched, NO audit row', async () => {
  const a = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'a-rotate-target' } });
  const id = a.json.id;
  const aHashBefore = a.json.hash;

  const beforeB = await call('GET', '/audit', { tenant: 'tenantB', token: TOK.tenantB });
  const beforeBlen = beforeB.json.length;

  const bRotate = await call('POST', `/keys/${id}/rotate`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bRotate.status, 403, 'cross-tenant rotate MUST be 403');

  const afterB = await call('GET', '/audit', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(afterB.json.length, beforeBlen, 'denied cross-tenant rotate must NOT write an audit row');

  // tenantA's key hash is unchanged by the attack (rotation did NOT happen)
  const aRow = await call('GET', `/keys/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aRow.status, 200);
  assert.equal(aRow.json.hash, aHashBefore, "tenantA's key hash was NOT changed by the attacker");
  assert.equal(aRow.json.status, 'active', "tenantA's key was NOT revoked by the attacker");
});

test('DENY REVOKE: tenantB revoke of tenantA key -> 403, A key still active, NO audit row', async () => {
  const a = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'a-revoke-target' } });
  const id = a.json.id;

  const beforeB = await call('GET', '/audit', { tenant: 'tenantB', token: TOK.tenantB });
  const beforeBlen = beforeB.json.length;

  const bRevoke = await call('DELETE', `/keys/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bRevoke.status, 403, 'cross-tenant revoke MUST be 403');

  const afterB = await call('GET', '/audit', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(afterB.json.length, beforeBlen, 'denied cross-tenant revoke must NOT write an audit row');

  const aRow = await call('GET', `/keys/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aRow.json.status, 'active', "tenantA's key was NOT revoked by the attacker");
});

test('DENY ENUMERATION: tenantB cannot list or see ANY of tenantA keys', async () => {
  const a = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'a-private' } });
  const bList = await call('GET', '/keys', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bList.status, 200);
  assert.ok(bList.json.every((k) => k.tenantId === 'tenantB'), 'B list MUST contain zero A keys');
  assert.ok(!bList.text.includes(a.json.hash), 'no A key hash ever appears in B list');
});

test('DENY ERASE SCOPE: tenantB erase cannot touch tenantA data', async () => {
  await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'a-survives' } });
  const aBefore = await call('GET', '/keys', { tenant: 'tenantA', token: TOK.tenantA });
  const aCountBefore = aBefore.json.length;

  // B erases its OWN tenant — this must not remove any A keys
  await call('POST', '/admin/erase', { tenant: 'tenantB', token: TOK.tenantB });

  const aAfter = await call('GET', '/keys', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aAfter.json.length, aCountBefore, "tenantB's DSAR erase MUST NOT delete tenantA keys");
});
