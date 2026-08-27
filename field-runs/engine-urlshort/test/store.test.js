// test/store.test.js
//
// TDD spec for src/store.js — the in-memory Map-backed store with bounded,
// collision-safe short-code generation (PLAN.md ADR 1 / AGENTS.md §3, §7).
//
// Written FIRST against a nonexistent src/store.js (expected RED: the import
// throws ERR_MODULE_NOT_FOUND). Implementation follows to turn this GREEN.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStore } from '../src/store.js';
import { AppError } from '../src/errors.js';

test('save() returns an 8-char code and get() round-trips the exact url', () => {
  const store = createStore();
  const url = 'https://example.com/some/deep/path?query=1&other=two#frag';

  const code = store.save(url);

  assert.strictEqual(typeof code, 'string');
  assert.strictEqual(code.length, 8, `expected an 8-char code, got "${code}" (len ${code.length})`);
  // base64url alphabet only: A-Z a-z 0-9 - _
  assert.match(code, /^[A-Za-z0-9_-]{8}$/, 'code must be URL-safe base64url characters only');

  assert.strictEqual(store.has(code), true);
  assert.strictEqual(store.get(code), url, 'get() must round-trip the exact url byte-for-byte');
});

test('save() generates independent codes across multiple calls (default generator)', () => {
  const store = createStore();
  const codeA = store.save('https://example.com/a');
  const codeB = store.save('https://example.com/b');

  assert.notStrictEqual(codeA, codeB);
  assert.strictEqual(store.get(codeA), 'https://example.com/a');
  assert.strictEqual(store.get(codeB), 'https://example.com/b');
});

test('has()/get() reflect empty state before any save()', () => {
  const store = createStore();
  assert.strictEqual(store.has('nonexist'), false);
  assert.strictEqual(store.get('nonexist'), undefined);
});

test('injected generate: duplicates then a fresh value still succeeds and does not collide', () => {
  const seen = ['DUPDUP01', 'DUPDUP01', 'DUPDUP01', 'FRESH999'];
  let i = 0;
  const store = createStore({
    generate: () => seen[i++],
  });

  // Pre-seed the collision code directly into the store's namespace by saving
  // a first url that legitimately claims 'DUPDUP01' via the same generator
  // sequence would consume it, so instead force the collision deterministically:
  // first call to save() below will draw 'DUPDUP01' (fresh — succeeds), then a
  // second save() will draw 'DUPDUP01' again (collision against the first),
  // 'DUPDUP01' again (collision again), then 'FRESH999' (succeeds).
  const firstCode = store.save('https://example.com/first');
  assert.strictEqual(firstCode, 'DUPDUP01');

  const secondCode = store.save('https://example.com/second');
  assert.strictEqual(
    secondCode,
    'FRESH999',
    'save() must retry past collisions and land on the first non-colliding code'
  );

  // Prove no collision occurred: both codes map to their own distinct urls.
  assert.strictEqual(store.get('DUPDUP01'), 'https://example.com/first');
  assert.strictEqual(store.get('FRESH999'), 'https://example.com/second');
  assert.strictEqual(i, 4, 'generator should have been called exactly 4 times (1 + 3)');
});

test('injected generate: always-colliding stub throws CODE_GEN_EXHAUSTED after the bounded cap (no hang)', () => {
  const store = createStore({
    generate: () => 'SEEDSEED',
  });

  // First save() claims 'SEEDSEED' legitimately (store is empty).
  const firstCode = store.save('https://example.com/seed');
  assert.strictEqual(firstCode, 'SEEDSEED');

  // Second save(): generator ALWAYS returns 'SEEDSEED', which is now taken.
  // Must throw a bounded, typed CODE_GEN_EXHAUSTED — never hang / loop forever.
  assert.throws(
    () => store.save('https://example.com/never-lands'),
    (err) => {
      assert.ok(err instanceof AppError, 'must throw an AppError instance');
      assert.strictEqual(err.code, 'CODE_GEN_EXHAUSTED');
      assert.strictEqual(err.status, 500);
      return true;
    }
  );

  // The failed save must not have mutated the store under some other code.
  assert.strictEqual(store.get('SEEDSEED'), 'https://example.com/seed');
});

test('always-colliding stub throws deterministically (bounded retry count), does not silently accept a duplicate', () => {
  let calls = 0;
  const store = createStore({
    generate: () => {
      calls += 1;
      return 'SEEDSEED';
    },
  });

  store.save('https://example.com/seed'); // claims 'SEEDSEED', calls = 1
  calls = 0; // reset counter to isolate the exhausting call

  assert.throws(() => store.save('https://example.com/other'), {
    name: 'AppError',
    code: 'CODE_GEN_EXHAUSTED',
  });

  // Bounded means a small, fixed number of attempts — not unbounded/huge.
  assert.ok(calls > 0 && calls <= 8, `expected 1-8 generator calls before exhaustion, got ${calls}`);
});
