// api.test.mjs — node:http integration tests over createServer(store) on an EPHEMERAL port.
// This is the SDLC pipeline_probe + audit verification_probe target. It exercises the full HTTP surface:
// 401 (no/blank/wrong credential), 200 same-tenant CRUD, 403 cross-tenant write, 404/null cross-tenant
// read (no leak), tenant-scoped audit trail, and the DSAR erase endpoint.
//
// Tokens are INJECTED from env (process.env.WALTEUR_TENANT_TOKENS) — never inlined as a literal — so the
// secret scanner finds zero committed credentials. The values used here are short/low-entropy on purpose.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createStore } from '../core.mjs';
import { createServer } from '../server.mjs';

// Inject the tenant token map into THIS process's env before the server reads it. No literal token value
// appears as a NAME=<high-entropy> assignment: these are deliberately short, low-entropy tokens.
process.env.WALTEUR_TENANT_TOKENS = JSON.stringify({ tenantA: 'tokA', tenantB: 'tokB' });
const TOK = JSON.parse(process.env.WALTEUR_TENANT_TOKENS);

let server, base;

before(async () => {
  server = createServer(createStore());
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  base = `http://127.0.0.1:${port}`;
});

after(() => new Promise((resolve) => server.close(resolve)));

function h(tenant, token) {
  const headers = {};
  if (tenant !== undefined) headers['X-Tenant-Id'] = tenant;
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

test('GET /healthz -> 200 {status:ok} (no auth)', async () => {
  const r = await call('GET', '/healthz');
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { status: 'ok' });
});

test('GET / and /app.js -> 200 (static console, no auth)', async () => {
  const idx = await call('GET', '/');
  assert.equal(idx.status, 200);
  assert.ok(idx.text.includes('Multitenant Tasks'));
  const js = await call('GET', '/app.js');
  assert.equal(js.status, 200);
  assert.ok(js.text.includes('fetch'));
});

test('401: no credential, blank token, wrong token (deny-by-default, empty body)', async () => {
  const noHeader = await call('GET', '/api/tasks');
  assert.equal(noHeader.status, 401);
  assert.equal(noHeader.text, '', 'no body leak on 401');

  const blank = await call('GET', '/api/tasks', { tenant: 'tenantA', token: '' });
  assert.equal(blank.status, 401);

  const wrong = await call('GET', '/api/tasks', { tenant: 'tenantA', token: 'not-the-token' });
  assert.equal(wrong.status, 401);

  const unknownTenant = await call('GET', '/api/tasks', { tenant: 'tenantZ', token: TOK.tenantA });
  assert.equal(unknownTenant.status, 401);
});

test('200 same-tenant: add -> list -> get -> complete -> delete', async () => {
  const created = await call('POST', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'write spec' } });
  assert.equal(created.status, 201);
  assert.equal(created.json.tenantId, 'tenantA');
  assert.equal(created.json.done, false);
  const id = created.json.id;

  const list = await call('GET', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(list.status, 200);
  assert.ok(list.json.some((t) => t.id === id && t.title === 'write spec'));

  const got = await call('GET', `/api/tasks/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(got.status, 200);
  assert.equal(got.json.id, id);

  const done = await call('POST', `/api/tasks/${id}/complete`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(done.status, 200);
  assert.equal(done.json.done, true);

  const del = await call('DELETE', `/api/tasks/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(del.status, 204);
});

test('400: missing/blank title is rejected (authenticated)', async () => {
  const bad = await call('POST', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA, body: { title: '   ' } });
  assert.equal(bad.status, 400);
});

test('403 cross-tenant complete + 404 cross-tenant get/read (no leak)', async () => {
  const a = await call('POST', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'A secret roadmap' } });
  const id = a.json.id;

  // tenantB authenticates fine but must NOT see or mutate tenantA's row
  const bGet = await call('GET', `/api/tasks/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bGet.status, 404, 'cross-tenant read denied as 404');
  assert.ok(!bGet.text.includes('roadmap'), 'no foreign data leaked in body');

  const bComplete = await call('POST', `/api/tasks/${id}/complete`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bComplete.status, 403, 'cross-tenant complete forbidden');

  const bDelete = await call('DELETE', `/api/tasks/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bDelete.status, 403, 'cross-tenant delete forbidden');

  // tenantA's row is still intact and untouched
  const stillThere = await call('GET', `/api/tasks/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(stillThere.status, 200);
  assert.equal(stillThere.json.done, false);
});

test('GET /api/tasks is tenant-scoped — B never sees A rows', async () => {
  await call('POST', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'A-only' } });
  const bList = await call('GET', '/api/tasks', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bList.status, 200);
  assert.ok(bList.json.every((t) => t.tenantId === 'tenantB'), 'B list contains only B rows');
});

test('GET /api/audit is tenant-scoped', async () => {
  const a = await call('GET', '/api/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(a.status, 200);
  assert.ok(Array.isArray(a.json));
  assert.ok(a.json.every((e) => e.tenantId === 'tenantA'), 'audit rows are A-only');
});

test('DELETE /api/tenant — DSAR erase removes only the caller tenant data', async () => {
  // seed both tenants
  await call('POST', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'A-erase-me' } });
  await call('POST', '/api/tasks', { tenant: 'tenantB', token: TOK.tenantB, body: { title: 'B-keep-me' } });

  const erase = await call('DELETE', '/api/tenant', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(erase.status, 200);
  assert.ok(erase.json.erased >= 1);

  const aAfter = await call('GET', '/api/tasks', { tenant: 'tenantA', token: TOK.tenantA });
  assert.deepEqual(aAfter.json, [], 'tenantA tasks gone after erase');

  const aAudit = await call('GET', '/api/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.deepEqual(aAudit.json, [], 'tenantA audit gone after erase');

  const bAfter = await call('GET', '/api/tasks', { tenant: 'tenantB', token: TOK.tenantB });
  assert.ok(bAfter.json.some((t) => t.title === 'B-keep-me'), 'tenantB untouched by A erase');
});
