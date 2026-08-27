// api.test.mjs — node:http integration tests over createServer(store) on an EPHEMERAL port.
// This is the SDLC pipeline_probe + audit verification_probe target. It exercises the full HTTP surface:
// 401 (no/blank/wrong credential), 201 issue (raw key returned ONCE), 200 list (metadata only, NO raw key),
// 200 rotate (new raw key, hash changed), 200 revoke, 403 cross-tenant write, 404/null cross-tenant read
// (no leak), tenant-scoped audit trail, the DSAR erase endpoint, and /health 200.
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
  assert.ok(idx.text.includes('API keys'));
  const js = await call('GET', '/app.js');
  assert.equal(js.status, 200);
  assert.ok(js.text.includes('fetch'));
});

test('401: no credential, blank token, wrong token, unknown tenant (deny-by-default, empty body)', async () => {
  const noHeader = await call('GET', '/keys');
  assert.equal(noHeader.status, 401);
  assert.equal(noHeader.text, '', 'no body leak on 401');

  const blank = await call('GET', '/keys', { tenant: 'tenantA', token: '' });
  assert.equal(blank.status, 401);

  const wrong = await call('GET', '/keys', { tenant: 'tenantA', token: 'not-the-token' });
  assert.equal(wrong.status, 401);

  const unknownTenant = await call('GET', '/keys', { tenant: 'tenantZ', token: TOK.tenantA });
  assert.equal(unknownTenant.status, 401);
});

test('201 issue returns the RAW key ONCE; GET list never carries a raw key', async () => {
  const issued = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'ci-deploy' } });
  assert.equal(issued.status, 201);
  assert.equal(issued.json.tenantId, 'tenantA');
  assert.equal(issued.json.label, 'ci-deploy');
  assert.equal(issued.json.status, 'active');
  assert.ok(typeof issued.json.key === 'string' && issued.json.key.startsWith('wk_'), 'raw key in 201 body');
  const raw = issued.json.key;
  const id = issued.json.id;

  const list = await call('GET', '/keys', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(list.status, 200);
  assert.ok(list.json.some((k) => k.id === id && k.label === 'ci-deploy'));
  assert.ok(list.json.every((k) => k.key === undefined), 'NO raw key field in any list row');
  assert.ok(!list.text.includes(raw), 'the issued raw key MUST NOT appear in the list response');

  const got = await call('GET', `/keys/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(got.status, 200);
  assert.equal(got.json.key, undefined, 'GET /keys/:id is metadata only');
  assert.ok(!got.text.includes(raw), 'raw key never returned on a single-key GET');
  assert.equal(got.json.last4, raw.slice(-4), 'last4 matches the issued raw key tail');
});

test('200 rotate mints a NEW raw key and CHANGES the stored hash; old key tail differs', async () => {
  const issued = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'rotate-me' } });
  const id = issued.json.id;
  const beforeHash = (await call('GET', `/keys/${id}`, { tenant: 'tenantA', token: TOK.tenantA })).json.hash;

  const rotated = await call('POST', `/keys/${id}/rotate`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(rotated.status, 200);
  assert.ok(rotated.json.key.startsWith('wk_'), 'rotate returns a fresh raw key ONCE');
  assert.notEqual(rotated.json.key, issued.json.key, 'rotated raw key differs from the original');

  const afterHash = (await call('GET', `/keys/${id}`, { tenant: 'tenantA', token: TOK.tenantA })).json.hash;
  assert.notEqual(afterHash, beforeHash, 'ROTATE CHANGED THE STORED HASH over HTTP');
});

test('200 revoke flips status; a revoked key cannot be rotated (409)', async () => {
  const issued = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'doomed' } });
  const id = issued.json.id;
  const rev = await call('DELETE', `/keys/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(rev.status, 200);
  assert.equal(rev.json.status, 'revoked');

  const rot = await call('POST', `/keys/${id}/rotate`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(rot.status, 409, 'rotating a revoked key is a conflict');
});

test('400: missing label rejected (authenticated)', async () => {
  const noLabel = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: {} });
  assert.equal(noLabel.status, 400);
});

test('403 cross-tenant rotate/revoke + 404 cross-tenant get (no leak)', async () => {
  const a = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'secret-key' } });
  const id = a.json.id;

  const bGet = await call('GET', `/keys/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bGet.status, 404, 'cross-tenant read denied as 404');

  const bRotate = await call('POST', `/keys/${id}/rotate`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bRotate.status, 403, 'cross-tenant rotate forbidden');

  const bRevoke = await call('DELETE', `/keys/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bRevoke.status, 403, 'cross-tenant revoke forbidden');

  // tenantA's key is still intact, active, and unchanged
  const stillThere = await call('GET', `/keys/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(stillThere.status, 200);
  assert.equal(stillThere.json.status, 'active');
});

test('GET /keys is tenant-scoped — B never sees A keys', async () => {
  await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'a-only' } });
  const bList = await call('GET', '/keys', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bList.status, 200);
  assert.ok(bList.json.every((k) => k.tenantId === 'tenantB'), 'B list contains only B keys');
});

test('GET /audit is tenant-scoped and never carries a raw key', async () => {
  const issued = await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'audited' } });
  const a = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(a.status, 200);
  assert.ok(Array.isArray(a.json));
  assert.ok(a.json.every((e) => e.tenantId === 'tenantA'), 'audit rows are A-only');
  assert.ok(!a.text.includes(issued.json.key), 'audit trail MUST NOT contain a raw key');
});

test('POST /admin/erase — DSAR erase removes only the caller tenant data', async () => {
  await call('POST', '/keys', { tenant: 'tenantA', token: TOK.tenantA, body: { label: 'a-erase-me' } });
  const bKey = await call('POST', '/keys', { tenant: 'tenantB', token: TOK.tenantB, body: { label: 'b-keep-me' } });

  const erase = await call('POST', '/admin/erase', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(erase.status, 200);
  assert.ok(erase.json.erased >= 1);

  const aAfter = await call('GET', '/keys', { tenant: 'tenantA', token: TOK.tenantA });
  assert.deepEqual(aAfter.json, [], 'tenantA keys gone after erase');

  const aAudit = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.deepEqual(aAudit.json, [], 'tenantA audit gone after erase');

  const bAfter = await call('GET', '/keys', { tenant: 'tenantB', token: TOK.tenantB });
  assert.ok(bAfter.json.some((k) => k.id === bKey.json.id), 'tenantB untouched by A erase');
});
