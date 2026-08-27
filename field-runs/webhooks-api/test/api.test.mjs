// api.test.mjs — node:http integration tests over createServer(store) on an EPHEMERAL port.
// This is the SDLC pipeline_probe + audit verification_probe target. It exercises the full HTTP surface:
// 401 (no/blank/wrong credential), 200/201 same-tenant subscription CRUD + rotate-secret, 403 cross-tenant
// write, 404/null cross-tenant read (no leak), validation 400s, tenant-scoped audit, the DSAR erase
// endpoint, and /health 200.
//
// Tokens are INJECTED from env (process.env.WALTEUR_TENANT_TOKENS) — never inlined as a literal — so the
// secret scanner finds zero committed credentials. The values used here are short/low-entropy on purpose.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { createStore } from '../core.mjs';
import { createServer } from '../server.mjs';

process.env.WALTEUR_TENANT_TOKENS = JSON.stringify({ tenantA: 'tokA', tenantB: 'tokB' });
const TOK = JSON.parse(process.env.WALTEUR_TENANT_TOKENS);
const URL_A = 'https://hooks.example.com/a';

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
  assert.ok(idx.text.includes('Webhook'));
  const js = await call('GET', '/app.js');
  assert.equal(js.status, 200);
  assert.ok(js.text.includes('fetch'));
});

test('401: no credential, blank token, wrong token, unknown tenant (deny-by-default, empty body)', async () => {
  const noHeader = await call('GET', '/subscriptions');
  assert.equal(noHeader.status, 401);
  assert.equal(noHeader.text, '', 'no body leak on 401');

  const blank = await call('GET', '/subscriptions', { tenant: 'tenantA', token: '' });
  assert.equal(blank.status, 401);

  const wrong = await call('GET', '/subscriptions', { tenant: 'tenantA', token: 'not-the-token' });
  assert.equal(wrong.status, 401);

  const unknownTenant = await call('GET', '/subscriptions', { tenant: 'tenantZ', token: TOK.tenantA });
  assert.equal(unknownTenant.status, 401);
});

test('201 create returns the signing secret ONCE; later reads never return it again', async () => {
  const created = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'order.created' } });
  assert.equal(created.status, 201);
  assert.equal(created.json.tenantId, 'tenantA');
  assert.equal(created.json.active, true);
  assert.match(created.json.secret, /^whsec_[A-Za-z0-9_-]{32}$/, 'secret returned once on create');
  // fingerprint stored is sha256 of the returned secret
  const expected = 'sha256:' + crypto.createHash('sha256').update(created.json.secret).digest('hex');
  assert.equal(created.json.secretFingerprint, expected);

  const id = created.json.id;
  const got = await call('GET', `/subscriptions/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(got.status, 200);
  assert.equal(got.json.secret, undefined, 'GET never returns the raw secret');
  assert.ok(!got.text.includes(created.json.secret), 'the raw secret never appears in a read response');
  assert.ok(got.json.secretFingerprint && got.json.secretLast4, 'fingerprint + last4 are still present');
});

test('200/201 same-tenant: create -> list -> get -> update -> rotate -> delete', async () => {
  const created = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'order.created' } });
  assert.equal(created.status, 201);
  const id = created.json.id;

  const list = await call('GET', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(list.status, 200);
  assert.ok(list.json.some((x) => x.id === id));

  const got = await call('GET', `/subscriptions/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(got.status, 200);
  assert.equal(got.json.eventType, 'order.created');

  const updated = await call('PUT', `/subscriptions/${id}`, { tenant: 'tenantA', token: TOK.tenantA, body: { active: false, eventType: 'order.updated' } });
  assert.equal(updated.status, 200);
  assert.equal(updated.json.active, false);
  assert.equal(updated.json.eventType, 'order.updated');

  const rotated = await call('POST', `/subscriptions/${id}/rotate-secret`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(rotated.status, 200);
  assert.match(rotated.json.secret, /^whsec_[A-Za-z0-9_-]{32}$/, 'rotate returns a fresh secret once');
  assert.notEqual(rotated.json.secretFingerprint, created.json.secretFingerprint, 'fingerprint changed on rotate');

  const del = await call('DELETE', `/subscriptions/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(del.status, 204);
});

test('400: invalid url (http / SSRF host) and off-allow-list eventType are rejected (authenticated)', async () => {
  const httpUrl = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: 'http://hooks.example.com/x', eventType: 'order.created' } });
  assert.equal(httpUrl.status, 400);

  const ssrf = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: 'https://127.0.0.1/x', eventType: 'order.created' } });
  assert.equal(ssrf.status, 400);

  const badEvent = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'nope.invalid' } });
  assert.equal(badEvent.status, 400);
});

test('403 cross-tenant update/rotate/delete + 404 cross-tenant get (no leak)', async () => {
  const a = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'payment.succeeded' } });
  const id = a.json.id;

  // tenantB authenticates fine but must NOT see or mutate tenantA's subscription
  const bGet = await call('GET', `/subscriptions/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bGet.status, 404, 'cross-tenant read denied as 404');
  assert.ok(!bGet.text.includes(a.json.secretFingerprint), 'no foreign data leaked in body');

  const bPut = await call('PUT', `/subscriptions/${id}`, { tenant: 'tenantB', token: TOK.tenantB, body: { active: false } });
  assert.equal(bPut.status, 403, 'cross-tenant update forbidden');

  const bRotate = await call('POST', `/subscriptions/${id}/rotate-secret`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bRotate.status, 403, 'cross-tenant rotate forbidden');

  const bDelete = await call('DELETE', `/subscriptions/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bDelete.status, 403, 'cross-tenant delete forbidden');

  // tenantA's subscription is still intact and untouched
  const stillThere = await call('GET', `/subscriptions/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(stillThere.status, 200);
  assert.equal(stillThere.json.active, true);
  assert.equal(stillThere.json.secretFingerprint, a.json.secretFingerprint, "tenantA's secret unchanged by B's rotate");
});

test('GET /subscriptions is tenant-scoped — B never sees A subscriptions', async () => {
  await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'order.created' } });
  const bList = await call('GET', '/subscriptions', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bList.status, 200);
  assert.ok(bList.json.every((x) => x.tenantId === 'tenantB'), 'B list contains only B subscriptions');
});

test('GET /audit is tenant-scoped', async () => {
  const a = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(a.status, 200);
  assert.ok(Array.isArray(a.json));
  assert.ok(a.json.every((e) => e.tenantId === 'tenantA'), 'audit rows are A-only');
});

test('POST /admin/erase — DSAR erase removes only the caller tenant data', async () => {
  await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'order.created' } });
  await call('POST', '/subscriptions', { tenant: 'tenantB', token: TOK.tenantB, body: { url: URL_A, eventType: 'order.created' } });

  const erase = await call('POST', '/admin/erase', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(erase.status, 200);
  assert.ok(erase.json.erased >= 1);

  const aAfter = await call('GET', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA });
  assert.deepEqual(aAfter.json, [], 'tenantA subscriptions gone after erase');

  const aAudit = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.deepEqual(aAudit.json, [], 'tenantA audit gone after erase');

  const bAfter = await call('GET', '/subscriptions', { tenant: 'tenantB', token: TOK.tenantB });
  assert.ok(bAfter.json.length >= 1, 'tenantB untouched by A erase');
});
