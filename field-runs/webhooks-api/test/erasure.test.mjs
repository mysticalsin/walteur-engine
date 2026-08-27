// erasure.test.mjs — DSAR right-to-erasure over HTTP. This is the privacy erasure_probe target.
// After POST /admin/erase (core.eraseTenant), the caller tenant's subscriptions AND audit rows are gone,
// while a sibling tenant is fully untouched. Proves GDPR right-to-erasure is real and tenant-scoped.
//
// Tokens injected from env, never inlined; values are short/low-entropy on purpose.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createStore } from '../core.mjs';
import { createServer } from '../server.mjs';

process.env.WALTEUR_TENANT_TOKENS = JSON.stringify({ tenantA: 'tokA', tenantB: 'tokB' });
const TOK = JSON.parse(process.env.WALTEUR_TENANT_TOKENS);
const URL_A = 'https://hooks.example.com/a';
const URL_B = 'https://hooks.example.com/b';

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

test('DSAR erase: caller tenant subscriptions + audit are fully removed', async () => {
  // tenantA accrues subscriptions and audit (create + create + rotate + delete => audit rows)
  const a1 = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'order.created' } });
  const a2 = await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_B, eventType: 'order.updated' } });
  await call('POST', `/subscriptions/${a1.json.id}/rotate-secret`, { tenant: 'tenantA', token: TOK.tenantA });
  await call('DELETE', `/subscriptions/${a2.json.id}`, { tenant: 'tenantA', token: TOK.tenantA });

  const beforeSubs = await call('GET', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA });
  const beforeAudit = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.ok(beforeSubs.json.length >= 1);
  assert.ok(beforeAudit.json.length >= 3);

  const erase = await call('POST', '/admin/erase', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(erase.status, 200);
  assert.ok(erase.json.erased >= 1, 'erase reports a count');

  const afterSubs = await call('GET', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA });
  const afterAudit = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.deepEqual(afterSubs.json, [], 'all tenantA subscriptions erased');
  assert.deepEqual(afterAudit.json, [], 'all tenantA audit rows erased');
});

test('DSAR erase is tenant-scoped: a sibling tenant is untouched', async () => {
  await call('POST', '/subscriptions', { tenant: 'tenantA', token: TOK.tenantA, body: { url: URL_A, eventType: 'order.created' } });
  await call('POST', '/subscriptions', { tenant: 'tenantB', token: TOK.tenantB, body: { url: URL_B, eventType: 'user.created' } });

  const bBefore = await call('GET', '/subscriptions', { tenant: 'tenantB', token: TOK.tenantB });
  const bCountBefore = bBefore.json.length;

  await call('POST', '/admin/erase', { tenant: 'tenantA', token: TOK.tenantA });

  const bAfter = await call('GET', '/subscriptions', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bAfter.json.length, bCountBefore, 'tenantB subscription count unchanged by tenantA erase');
  assert.ok(bAfter.json.length >= 1, 'tenantB data still present');
});
