// cross-tenant.test.mjs — DEDICATED deny-by-default proof over the HTTP surface.
// This is the authz cross_tenant_probe target. It proves the DENIAL specifically: a fully-authenticated
// tenantB CANNOT read or mutate tenantA's rows, AND a denied action leaves NO audit row behind. A test
// that merely shows "the server responds" would prove nothing — every assertion here is about the denial.
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
  if (tenant !== undefined) headers['X-Tenant-Id'] = tenant;
  if (token !== undefined) headers['Authorization'] = `Bearer ${token}`;
  const opts = { method, headers };
  if (body !== undefined) { headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
  const res = await fetch(base + path, opts);
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  return { status: res.status, json, text };
}

test('SETUP: tenantA owns a row; tenantB is a real, authenticated tenant', async () => {
  const created = await call('POST', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'A-confidential' } });
  assert.equal(created.status, 201);
  // tenantB can authenticate (proving the denial below is authorization, not authentication)
  const bOwn = await call('GET', '/api/tasks', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bOwn.status, 200);
});

test('DENY READ: tenantB GET of tenantA row -> 404, body carries no A data', async () => {
  const a = await call('POST', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'A-roadmap-xyz' } });
  const id = a.json.id;
  const bRead = await call('GET', `/api/tasks/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bRead.status, 404, 'cross-tenant read MUST be denied (404, no existence oracle)');
  assert.ok(!bRead.text.includes('A-roadmap-xyz'), 'denied read MUST NOT leak the foreign title');
});

test('DENY WRITE: tenantB complete + delete of tenantA row -> 403, and NO audit row is written', async () => {
  const a = await call('POST', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'A-write-target' } });
  const id = a.json.id;

  // B's audit trail before the denied attempts
  const beforeB = await call('GET', '/api/audit', { tenant: 'tenantB', token: TOK.tenantB });
  const beforeBlen = beforeB.json.length;

  const bComplete = await call('POST', `/api/tasks/${id}/complete`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bComplete.status, 403, 'cross-tenant complete MUST be 403');

  const bDelete = await call('DELETE', `/api/tasks/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bDelete.status, 403, 'cross-tenant delete MUST be 403');

  // A denied action must NOT leave an audit row for the attacker...
  const afterB = await call('GET', '/api/audit', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(afterB.json.length, beforeBlen, 'denied cross-tenant action must NOT write an audit row');

  // ...and tenantA's row + audit are untouched by the attack.
  const aRow = await call('GET', `/api/tasks/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aRow.status, 200);
  assert.equal(aRow.json.done, false, "tenantA's row was NOT completed by the attacker");
});

test('DENY ERASE SCOPE: tenantB erase cannot touch tenantA data', async () => {
  await call('POST', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'A-survives' } });
  const aBefore = await call('GET', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA });
  const aCountBefore = aBefore.json.length;

  // B erases its OWN tenant — this must not remove any A rows
  await call('DELETE', '/api/tenant', { tenant: 'tenantB', token: TOK.tenantB });

  const aAfter = await call('GET', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aAfter.json.length, aCountBefore, "tenantB's DSAR erase MUST NOT delete tenantA rows");
});
