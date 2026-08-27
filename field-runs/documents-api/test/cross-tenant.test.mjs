// cross-tenant.test.mjs — DEDICATED deny-by-default proof over the HTTP surface.
// This is the authz cross_tenant_probe target. It proves the DENIAL specifically: a fully-authenticated
// tenantB CANNOT read or mutate tenantA's documents, AND a denied action leaves NO audit row behind. A
// test that merely shows "the server responds" would prove nothing — every assertion here is about denial.
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

test('SETUP: tenantA owns a doc; tenantB is a real, authenticated tenant', async () => {
  const created = await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'a-confidential', body: 'treatment' } });
  assert.equal(created.status, 201);
  // tenantB can authenticate (proving the denial below is authorization, not authentication)
  const bOwn = await call('GET', '/docs', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bOwn.status, 200);
});

test('DENY READ: tenantB GET of tenantA doc -> 404, body carries no A data', async () => {
  const a = await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'a-rollout', body: 'treatment-xyz' } });
  const bRead = await call('GET', `/docs/${a.json.id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bRead.status, 404, 'cross-tenant read MUST be denied (404, no existence oracle)');
  assert.ok(!bRead.text.includes('treatment-xyz'), 'denied read MUST NOT leak the foreign value');
});

test('DENY WRITE: tenantB update/delete of tenantA doc -> 403, and NO audit row is written', async () => {
  const a = await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'a-write-target', body: 'orig' } });
  const id = a.json.id;

  // B's audit trail before the denied attempt
  const beforeB = await call('GET', '/audit', { tenant: 'tenantB', token: TOK.tenantB });
  const beforeBlen = beforeB.json.length;

  const bPut = await call('PUT', `/docs/${id}`, { tenant: 'tenantB', token: TOK.tenantB, body: { body: 'hacked' } });
  assert.equal(bPut.status, 403, 'cross-tenant update MUST be 403');

  const bDelete = await call('DELETE', `/docs/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bDelete.status, 403, 'cross-tenant delete MUST be 403');

  // A denied action must NOT leave an audit row for the attacker...
  const afterB = await call('GET', '/audit', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(afterB.json.length, beforeBlen, 'denied cross-tenant action must NOT write an audit row');

  // ...and tenantA's doc is untouched by the attack.
  const aRow = await call('GET', `/docs/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aRow.status, 200);
  assert.equal(aRow.json.body, 'orig', "tenantA's doc was NOT modified or deleted by the attacker");
});

test('DENY ENUMERATION: tenantB cannot list or see ANY of tenantA docs', async () => {
  await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'a-private', body: 'secret' } });
  const bList = await call('GET', '/docs', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bList.status, 200);
  assert.ok(bList.json.every((d) => d.tenantId === 'tenantB'), 'B list MUST contain zero A docs');
  assert.ok(!bList.text.includes('secret'), 'no A body ever appears in B list');
});

test('DENY ERASE SCOPE: tenantB erase cannot touch tenantA data', async () => {
  await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'a-survives', body: 'x' } });
  const aBefore = await call('GET', '/docs', { tenant: 'tenantA', token: TOK.tenantA });
  const aCountBefore = aBefore.json.length;

  // B erases its OWN tenant — this must not remove any A docs
  await call('POST', '/admin/erase', { tenant: 'tenantB', token: TOK.tenantB });

  const aAfter = await call('GET', '/docs', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aAfter.json.length, aCountBefore, "tenantB's DSAR erase MUST NOT delete tenantA docs");
});
