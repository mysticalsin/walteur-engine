// cross-tenant.test.mjs — DEDICATED deny-by-default proof over the HTTP surface.
// This is the authz cross_tenant_probe target. It proves the DENIAL specifically: a fully-authenticated
// tenantB CANNOT read or mutate tenantA's subscriptions, CANNOT rotate A's signing secret, AND a denied
// action leaves NO audit row behind. A test that merely shows "the server responds" would prove nothing —
// every assertion here is about the denial.
//
// Tokens are injected from env, never inlined; the values are short/low-entropy on purpose.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
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

test('SETUP: tenantA owns a subscription; tenantB is a real, authenticated tenant', async () => {
  const created = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'order.created' } });
  assert.equal(created.status, 201);
  // tenantB can authenticate (proving the denial below is authorization, not authentication)
  const bOwn = await call('GET', '/subscriptions', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bOwn.status, 200);
});

test('DENY READ: tenantB GET of tenantA subscription -> 404, body carries no A data', async () => {
  const a = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'payment.failed' } });
  const id = a.json.id;
  const bRead = await call('GET', `/subscriptions/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bRead.status, 404, 'cross-tenant read MUST be denied (404, no existence oracle)');
  assert.ok(!bRead.text.includes(a.json.secretFingerprint), 'denied read MUST NOT leak the foreign subscription');
});

test('DENY WRITE: tenantB delete of tenantA subscription -> 403, and NO audit row is written', async () => {
  const a = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'order.created' } });
  const id = a.json.id;

  // B's audit trail before the denied attempt
  const beforeB = await call('GET', '/audit', { tenant: 'tenantB', token: TOK.tenantB });
  const beforeBlen = beforeB.json.length;

  const bDelete = await call('DELETE', `/subscriptions/${id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bDelete.status, 403, 'cross-tenant delete MUST be 403');

  // A denied action must NOT leave an audit row for the attacker...
  const afterB = await call('GET', '/audit', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(afterB.json.length, beforeBlen, 'denied cross-tenant action must NOT write an audit row');

  // ...and tenantA's subscription is untouched by the attack.
  const aRow = await call('GET', `/subscriptions/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aRow.status, 200);
  assert.equal(aRow.json.id, id, "tenantA's subscription was NOT deleted by the attacker");
});

test('DENY SECRET ROTATION: tenantB cannot rotate tenantA signing secret', async () => {
  const a = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'order.created' } });
  const id = a.json.id;
  const fpBefore = a.json.secretFingerprint;

  const bRotate = await call('POST', `/subscriptions/${id}/rotate-secret`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bRotate.status, 403, "tenantB rotating tenantA's secret MUST be 403");
  assert.equal(bRotate.json && bRotate.json.secret, undefined, 'a denied rotate returns no secret');

  // tenantA's fingerprint is unchanged — B's denied rotate did not mint a new secret for A
  const aRow = await call('GET', `/subscriptions/${id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aRow.json.secretFingerprint, fpBefore, "tenantA's signing secret was NOT rotated by the attacker");
});

test('DENY OVERWRITE SCOPE: tenantB creating its own sub never collides with tenantA ids', async () => {
  const a = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'order.created' } });
  const b = await call('POST', '/subscriptions', { tenant: 'tenantB', token: TOK.tenantB, body: { url: URL_A, eventType: 'order.created' } });
  assert.equal(b.status, 201);
  // even if B somehow learned A's id, B's GET of it is denied (separate id namespaces)
  const bGetA = await call('GET', `/subscriptions/${a.json.id}`, { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bGetA.status, 404, "B cannot address A's id namespace");
  // A likewise cannot see B's
  const aGetB = await call('GET', `/subscriptions/${b.json.id}`, { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aGetB.status, 404);
});

test('DENY ERASE SCOPE: tenantB erase cannot touch tenantA data', async () => {
  await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'order.created' } });
  const aBefore = await call('GET', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA });
  const aCountBefore = aBefore.json.length;

  // B erases its OWN tenant — this must not remove any A subscriptions
  await call('POST', '/admin/erase', { tenant: 'tenantB', token: TOK.tenantB });

  const aAfter = await call('GET', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(aAfter.json.length, aCountBefore, "tenantB's DSAR erase MUST NOT delete tenantA subscriptions");
});
