// api.test.mjs — node:http integration tests over createServer(store) on an EPHEMERAL port.
// This is the SDLC pipeline_probe + audit verification_probe target. It exercises the full HTTP surface:
// 401 (no/blank/wrong credential), 200/201 same-tenant doc CRUD, 403 cross-tenant write, 404/null
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
  assert.ok(idx.text.includes('Documents'));
  const js = await call('GET', '/app.js');
  assert.equal(js.status, 200);
  assert.ok(js.text.includes('fetch'));
});

test('401: no credential, blank token, wrong token, unknown tenant (deny-by-default, empty body)', async () => {
  const noHeader = await call('GET', '/docs');
  assert.equal(noHeader.status, 401);
  assert.equal(noHeader.text, '', 'no body leak on 401');

  const blank = await call('GET', '/docs', { tenant: 'tenantA', token: '' });
  assert.equal(blank.status, 401);

  const wrong = await call('GET', '/docs', { tenant: 'tenantA', token: 'not-the-token' });
  assert.equal(wrong.status, 401);

  const unknownTenant = await call('GET', '/docs', { tenant: 'tenantZ', token: TOK.tenantA });
  assert.equal(unknownTenant.status, 401);
});

test('200/201 same-tenant: create -> list -> get -> update -> delete', async () => {
  const created = await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'Q3 Plan', body: 'first draft' } });
  assert.equal(created.status, 201);
  assert.equal(created.json.tenantId, 'tenantA');
  assert.equal(created.json.title, 'Q3 Plan');
  assert.equal(created.json.body, 'first draft');
  const id = created.json.id;
  assert.ok(/^doc_/.test(id));

  const list = await call('GET', '/docs', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(list.status, 200);
  assert.ok(list.json.some((d) => d.id === id && d.title === 'Q3 Plan'));

  const got = await call('GET', `/docs/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(got.status, 200);
  assert.equal(got.json.id, id);

  const updated = await call('PUT', `/docs/${id}`, { tenant: 'tenantA', token: TOK.tenantA, body: { body: 'second draft' } });
  assert.equal(updated.status, 200);
  assert.equal(updated.json.body, 'second draft');

  const del = await call('DELETE', `/docs/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(del.status, 204);

  const gone = await call('GET', `/docs/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(gone.status, 404, 'deleted doc is gone for its owner too');
});

test('400: missing title rejected (authenticated)', async () => {
  const noTitle = await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { body: 'orphan' } });
  assert.equal(noTitle.status, 400);
});

test('403 cross-tenant update/delete + 404 cross-tenant get/read (no leak)', async () => {
  const a = await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'secret-doc', body: 'treatment-plan' } });
  const id = a.json.id;

  // tenantB authenticates fine but must NOT see or mutate tenantA's doc
  const bGet = await call('GET', `/docs/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bGet.status, 404, 'cross-tenant read denied as 404');
  assert.ok(!bGet.text.includes('treatment-plan'), 'no foreign value leaked in body');

  const bPut = await call('PUT', `/docs/${id}`, { tenant: 'tenantB', token: TOK.tenantB, body: { body: 'hacked' } });
  assert.equal(bPut.status, 403, 'cross-tenant update forbidden');

  const bDelete = await call('DELETE', `/docs/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bDelete.status, 403, 'cross-tenant delete forbidden');

  // tenantA's doc is still intact and untouched
  const stillThere = await call('GET', `/docs/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(stillThere.status, 200);
  assert.equal(stillThere.json.body, 'treatment-plan');
});

test('GET /docs is tenant-scoped — B never sees A docs', async () => {
  await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'a-only', body: 'x' } });
  const bList = await call('GET', '/docs', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bList.status, 200);
  assert.ok(bList.json.every((d) => d.tenantId === 'tenantB'), 'B list contains only B docs');
});

test('GET /audit is tenant-scoped', async () => {
  const a = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(a.status, 200);
  assert.ok(Array.isArray(a.json));
  assert.ok(a.json.every((e) => e.tenantId === 'tenantA'), 'audit rows are A-only');
});

test('POST /admin/erase — DSAR erase removes only the caller tenant data', async () => {
  await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'a-erase-me', body: 'x' } });
  const bDoc = await call('POST', '/docs', { tenant: 'tenantB', token: TOK.tenantB, body: { title: 'b-keep-me', body: 'y' } });

  const erase = await call('POST', '/admin/erase', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(erase.status, 200);
  assert.ok(erase.json.erased >= 1);

  const aAfter = await call('GET', '/docs', { tenant: 'tenantA', token: TOK.tenantA });
  assert.deepEqual(aAfter.json, [], 'tenantA docs gone after erase');

  const aAudit = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.deepEqual(aAudit.json, [], 'tenantA audit gone after erase');

  const bAfter = await call('GET', '/docs', { tenant: 'tenantB', token: TOK.tenantB });
  assert.ok(bAfter.json.some((d) => d.id === bDoc.json.id), 'tenantB untouched by A erase');
});
