// cross-tenant.test.mjs — DEDICATED deny-by-default proof over the HTTP surface.
// This is the authz cross_tenant_probe target. It proves the DENIAL specifically: a fully-authenticated
// tenantB CANNOT read or mutate tenantA's flags, AND a denied action leaves NO audit row behind. A test
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

test('SETUP: tenantA owns a flag; tenantB is a real, authenticated tenant', async () => {
  const created = await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { key: 'a-confidential', value: 'treatment' } });
  assert.equal(created.status, 201);
  // tenantB can authenticate (proving the denial below is authorization, not authentication)
  const bOwn = await call('GET', '/flags', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bOwn.status, 200);
});

test('DENY READ: tenantB GET of tenantA flag -> 404, body carries no A data', async () => {
  await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { key: 'a-rollout-xyz', value: 'treatment-xyz' } });
  const bRead = await call('GET', '/flags/a-rollout-xyz', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bRead.status, 404, 'cross-tenant read MUST be denied (404, no existence oracle)');
  assert.ok(!bRead.text.includes('treatment-xyz'), 'denied read MUST NOT leak the foreign value');
});

test('DENY WRITE: tenantB delete of tenantA flag -> 403, and NO audit row is written', async () => {
  await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { key: 'a-write-target', value: true } });

  // B's audit trail before the denied attempt
  const beforeB = await call('GET', '/audit', { tenant: 'tenantB', token: TOK.tenantB });
  const beforeBlen = beforeB.json.length;

  const bDelete = await call('DELETE', '/flags/a-write-target', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bDelete.status, 403, 'cross-tenant delete MUST be 403');

  // A denied action must NOT leave an audit row for the attacker...
  const afterB = await call('GET', '/audit', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(afterB.json.length, beforeBlen, 'denied cross-tenant action must NOT write an audit row');

  // ...and tenantA's flag is untouched by the attack.
  const aRow = await call('GET', '/flags/a-write-target', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aRow.status, 200);
  assert.equal(aRow.json.value, true, "tenantA's flag was NOT deleted by the attacker");
});

test('DENY OVERWRITE SCOPE: tenantB setting the SAME key cannot affect tenantA flag', async () => {
  await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { key: 'dark-mode', value: true } });
  // B writes its OWN flag with the same key name — must be independent, never overwrite A
  const bSet = await call('POST', '/flags', { tenant: 'tenantB', token: TOK.tenantB, body: { key: 'dark-mode', value: false } });
  assert.equal(bSet.status, 201);

  const aRow = await call('GET', '/flags/dark-mode', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aRow.json.value, true, "tenantB writing the same key MUST NOT change tenantA's flag");
  const bRow = await call('GET', '/flags/dark-mode', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bRow.json.value, false, 'tenantB sees only its own value for the shared key name');
});

test('DENY ERASE SCOPE: tenantB erase cannot touch tenantA data', async () => {
  await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { key: 'a-survives', value: true } });
  const aBefore = await call('GET', '/flags', { tenant: 'tenantA', token: TOK.tenantA });
  const aCountBefore = aBefore.json.length;

  // B erases its OWN tenant — this must not remove any A flags
  await call('POST', '/admin/erase', { tenant: 'tenantB', token: TOK.tenantB });

  const aAfter = await call('GET', '/flags', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aAfter.json.length, aCountBefore, "tenantB's DSAR erase MUST NOT delete tenantA flags");
});
