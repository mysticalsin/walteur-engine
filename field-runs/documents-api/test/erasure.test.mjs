// erasure.test.mjs — DSAR right-to-erasure over HTTP. This is the privacy erasure_probe target.
// After POST /admin/erase (core.eraseTenant), the caller tenant's documents AND audit rows are gone, while
// a sibling tenant is fully untouched. Proves GDPR right-to-erasure is real and tenant-scoped.
//
// Tokens injected from env, never inlined; values are short/low-entropy on purpose.

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

test('DSAR erase: caller tenant docs + audit are fully removed', async () => {
  // tenantA accrues docs and audit (create + create + update + delete => audit rows)
  const d1 = await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'a-1', body: 'x' } });
  const d2 = await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'a-2', body: 'y' } });
  await call('PUT', `/docs/${d1.json.id}`, { tenant: 'tenantA', token: TOK.tenantA, body: { body: 'x2' } });
  await call('DELETE', `/docs/${d2.json.id}`, { tenant: 'tenantA', token: TOK.tenantA });

  const beforeDocs = await call('GET', '/docs', { tenant: 'tenantA', token: TOK.tenantA });
  const beforeAudit = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.ok(beforeDocs.json.length >= 1);
  assert.ok(beforeAudit.json.length >= 4, 'create+create+update+delete = 4 audit rows');

  const erase = await call('POST', '/admin/erase', { tenant: 'tenantA', token: TOK.tenantA });
  assert.equal(erase.status, 200);
  assert.ok(erase.json.erased >= 1, 'erase reports a count');

  const afterDocs = await call('GET', '/docs', { tenant: 'tenantA', token: TOK.tenantA });
  const afterAudit = await call('GET', '/audit', { tenant: 'tenantA', token: TOK.tenantA });
  assert.deepEqual(afterDocs.json, [], 'all tenantA docs erased');
  assert.deepEqual(afterAudit.json, [], 'all tenantA audit rows erased');
});

test('DSAR erase is tenant-scoped: a sibling tenant is untouched', async () => {
  await call('POST', '/docs', { tenant: 'tenantA', token: TOK.tenantA, body: { title: 'a-x', body: 'x' } });
  const bDoc = await call('POST', '/docs', { tenant: 'tenantB', token: TOK.tenantB, body: { title: 'b-keep', body: 'y' } });

  const bBefore = await call('GET', '/docs', { tenant: 'tenantB', token: TOK.tenantB });
  const bCountBefore = bBefore.json.length;

  await call('POST', '/admin/erase', { tenant: 'tenantA', token: TOK.tenantA });

  const bAfter = await call('GET', '/docs', { tenant: 'tenantB', token: TOK.tenantB });
  assert.equal(bAfter.json.length, bCountBefore, 'tenantB doc count unchanged by tenantA erase');
  assert.ok(bAfter.json.some((d) => d.id === bDoc.json.id), 'tenantB data still present');
});
