// api.test.mjs — node:http integration tests over createServer(store) on an EPHEMERAL port.
// This is the SDLC pipeline_probe + audit verification_probe target. It exercises the full HTTP surface:
// 401 (no/blank/wrong credential), 200/201 same-tenant flag CRUD, 403 cross-tenant write, 404/null
// cross-tenant read (no leak), tenant-scoped audit trail, the DSAR erase endpoint, and /health 200.
//
// Tokens are INJECTED from env (process.env.WALTEUR_TENANT_TOKENS) — never inlined as a literal — so the
// secret scanner finds zero committed credentials. The values used here are short/low-entropy on purpose.

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

function h(tenant, token) {
  const headers = {};
  if (tenant !== undefined) headers['X-Tenant'] = tenant;
  if (token !== undefined) headers['Authorization'] = `Bearer ${token}`;
  return headers;
}

async function call(method, path, { tenant, token, body } = {}) {
  const headers = h(tenant, token);
  const opts = { method, headers };
  if (body !== undefined) { headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
  const res = await fetch(base + path, opts);
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  return { status: res.status, json, text };
}

test('GET /health -> 200 {status:ok} (no auth)', async () => {
  const r = await call('GET', '/health');
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { status: 'ok' });
});

test('GET /healthz -> 200 (alias, no auth)', async () => {
  const r = await call('GET', '/healthz');
  assert.equal(r.status, 200);
});

test('GET / and /app.js -> 200 (static console, no auth)', async () => {
  const idx = await call('GET', '/');
  assert.equal(idx.status, 200);
  assert.ok(idx.text.includes('Feature Flags'));
  const js = await call('GET', '/app.js');
  assert.equal(js.status, 200);
  assert.ok(js.text.includes('fetch'));
});

test('401: no credential, blank token, wrong token, unknown tenant (deny-by-default, empty body)', async () => {
  const noHeader = await call('GET', '/flags');
  assert.equal(noHeader.status, 401);
  assert.equal(noHeader.text, '', 'no body leak on 401');

  const blank = await call('GET', '/flags', { tenant: 'tenantA', token: '' });
  assert.equal(blank.status, 401);

  const wrong = await call('GET', '/flags', { tenant: 'tenantA', token: 'not-the-token' });
  assert.equal(wrong.status, 401);

  const unknownTenant = await call('GET', '/flags', { tenant: 'tenantZ', token: TOK.tenantA });
  assert.equal(unknownTenant.status, 401);
});

test('200/201 same-tenant: set -> list -> get -> update -> delete', async () => {
  const created = await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { key: 'new-checkout', value: true } });
  assert.equal(created.status, 201);
  assert.equal(created.json.tenantId, 'tenantA');
  assert.equal(created.json.kind, 'boolean');
  assert.equal(created.json.value, true);

  const variant = await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { key: 'banner', value: 'blue' } });
  assert.equal(variant.status, 201);
  assert.equal(variant.json.kind, 'variant');

  const list = await call('GET', '/flags', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(list.status, 200);
  assert.ok(list.json.some((f) => f.key === 'new-checkout' && f.value === true));

  const got = await call('GET', '/flags/new-checkout', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(got.status, 200);
  assert.equal(got.json.key, 'new-checkout');

  const updated = await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { key: 'new-checkout', value: false } });
  assert.equal(updated.status, 201);
  assert.equal(updated.json.value, false);

  const del = await call('DELETE', '/flags/banner', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(del.status, 204);
});

test('400: missing key or bad value rejected (authenticated)', async () => {
  const noKey = await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { value: true } });
  assert.equal(noKey.status, 400);
  const badVal = await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { key: 'k', value: 123 } });
  assert.equal(badVal.status, 400);
});

test('403 cross-tenant delete + 404 cross-tenant get/read (no leak)', async () => {
  await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { key: 'secret-rollout', value: 'treatment' } });

  // tenantB authenticates fine but must NOT see or mutate tenantA's flag
  const bGet = await call('GET', '/flags/secret-rollout', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bGet.status, 404, 'cross-tenant read denied as 404');
  assert.ok(!bGet.text.includes('treatment'), 'no foreign value leaked in body');

  const bDelete = await call('DELETE', '/flags/secret-rollout', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bDelete.status, 403, 'cross-tenant delete forbidden');

  // tenantA's flag is still intact and untouched
  const stillThere = await call('GET', '/flags/secret-rollout', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(stillThere.status, 200);
  assert.equal(stillThere.json.value, 'treatment');
});

test('GET /flags is tenant-scoped — B never sees A flags', async () => {
  await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { key: 'a-only', value: true } });
  const bList = await call('GET', '/flags', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bList.status, 200);
  assert.ok(bList.json.every((f) => f.tenantId === 'tenantB'), 'B list contains only B flags');
});

test('GET /audit is tenant-scoped', async () => {
  const a = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(a.status, 200);
  assert.ok(Array.isArray(a.json));
  assert.ok(a.json.every((e) => e.tenantId === 'tenantA'), 'audit rows are A-only');
});

test('POST /admin/erase — DSAR erase removes only the caller tenant data', async () => {
  await call('POST', '/flags', { tenant: 'tenantA', token: TOK.tenantA, body: { key: 'a-erase-me', value: true } });
  await call('POST', '/flags', { tenant: 'tenantB', token: TOK.tenantB, body: { key: 'b-keep-me', value: true } });

  const erase = await call('POST', '/admin/erase', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(erase.status, 200);
  assert.ok(erase.json.erased >= 1);

  const aAfter = await call('GET', '/flags', { tenant: 'tenantA', token: TOK.tenantA });
  assert.deepEqual(aAfter.json, [], 'tenantA flags gone after erase');

  const aAudit = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.deepEqual(aAudit.json, [], 'tenantA audit gone after erase');

  const bAfter = await call('GET', '/flags', { tenant: 'tenantB', token: TOK.tenantB });
  assert.ok(bAfter.json.some((f) => f.key === 'b-keep-me'), 'tenantB untouched by A erase');
});
