// TDD driver test for Task 3 — the storage adapter (src/storage.js).
//
// Written BEFORE src/storage.js exists. It MUST fail (ERR_MODULE_NOT_FOUND) on a
// clean checkout, then pass once src/storage.js implements the module. This is the
// worker-owned "enough failing assertions to drive the module" slice; the FULL
// storage suite (test/storage.test.js) lands in T5 and is owned by the test author —
// this file is deliberately named `storage-import-safety.test.js` so it does not
// collide with that one (mirrors the T2 driver naming convention).
//
// Focus of this driver — the two contracts the design doc calls the single most
// likely build mistake, plus the failure paths this task owns:
//   (1) `import('../src/storage.js')` RESOLVES under plain Node with no DOM globals —
//       proving the module references NO top-level `window`/`localStorage`/`document`
//       (a top-level reference throws ReferenceError the instant the module loads).
//   (2) load() is total over adapter failure: a throwing getItem yields [], not a throw.
//   (3) load() maps null / malformed / wrong-shape stored blobs to [] (via deserialize).
//   (4) save() reports {ok:false, reason:e.name} on a throwing setItem (QuotaExceededError
//       specifically), {ok:true} on success, and NEVER mutates its input.

import test from 'node:test';
import assert from 'node:assert/strict';

// ---------------------------------------------------------------------------
// Project-owned in-memory adapter stub (~5 lines, no third-party mock). Mirrors the
// {getItem,setItem} contract of the browser Web Storage API surface this app uses.
// ---------------------------------------------------------------------------
function makeMemoryAdapter(initial = {}) {
  const map = new Map(Object.entries(initial));
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, v),
    // expose for assertions on what was actually written
    _map: map,
  };
}

const KEY = 'todos.v1';

// ---------------------------------------------------------------------------
// (1) THE load-bearing guard: the module imports cleanly under plain Node. If
// src/storage.js references `window`/`localStorage`/`document` at top level, this
// dynamic import rejects with a ReferenceError and the test fails loudly.
// ---------------------------------------------------------------------------
test('import(storage.js) RESOLVES under plain Node — no top-level DOM global', async () => {
  await assert.doesNotReject(
    () => import('../src/storage.js'),
    'importing storage.js must not throw (no top-level window/localStorage/document)',
  );
  const mod = await import('../src/storage.js');
  assert.equal(typeof mod.load, 'function', 'must export load()');
  assert.equal(typeof mod.save, 'function', 'must export save()');
});

// ---------------------------------------------------------------------------
// (2) load() is total over a THROWING adapter — the single behavioral guard the brief
// names alongside import-safety. Even a getItem that throws yields [], never a throw.
// ---------------------------------------------------------------------------
test('load(): a throwing getItem yields [] (never throws)', async () => {
  const { load } = await import('../src/storage.js');
  const throwingAdapter = {
    getItem() {
      throw new Error('storage disabled (e.g. Safari private mode)');
    },
    setItem() {},
  };
  let out;
  assert.doesNotThrow(() => {
    out = load(KEY, throwingAdapter);
  });
  assert.deepStrictEqual(out, []);
});

// ---------------------------------------------------------------------------
// (3) load() maps absent/malformed/wrong-shape blobs to [] — one test per distinct
// case (no combined catch-all), per the project testing rule.
// ---------------------------------------------------------------------------
test('load(): absent key (getItem -> null) returns [] without JSON.parse(null)', async () => {
  const { load } = await import('../src/storage.js');
  assert.deepStrictEqual(load(KEY, makeMemoryAdapter()), []);
});

test('load(): malformed JSON blob returns []', async () => {
  const { load } = await import('../src/storage.js');
  const adapter = makeMemoryAdapter({ [KEY]: '{not json' });
  assert.deepStrictEqual(load(KEY, adapter), []);
});

test('load(): wrong-shape blob (item missing done) returns [] (all-or-nothing)', async () => {
  const { load } = await import('../src/storage.js');
  const adapter = makeMemoryAdapter({
    [KEY]: JSON.stringify({ version: 1, todos: [{ id: 'a', text: 'x' }] }),
  });
  assert.deepStrictEqual(load(KEY, adapter), []);
});

test('load(): well-formed v1 envelope round-trips to the canonical Todo[]', async () => {
  const { load } = await import('../src/storage.js');
  const todos = [{ id: 'a', text: 'buy milk', done: false, created: 1720000000000 }];
  const adapter = makeMemoryAdapter({ [KEY]: JSON.stringify({ version: 1, todos }) });
  assert.deepStrictEqual(load(KEY, adapter), todos);
});

// ---------------------------------------------------------------------------
// (4) save() — success, quota failure, generic failure, and no input mutation.
// ---------------------------------------------------------------------------
test('save(): success returns {ok:true} and persists the serialized envelope', async () => {
  const { load, save } = await import('../src/storage.js');
  const adapter = makeMemoryAdapter();
  const todos = [{ id: 'a', text: 'x', done: false, created: 1 }];
  const result = save(KEY, todos, adapter);
  assert.deepStrictEqual(result, { ok: true });
  // round-trips back through load()
  assert.deepStrictEqual(load(KEY, adapter), todos);
});

test('save(): setItem throwing QuotaExceededError -> {ok:false, reason:"QuotaExceededError"}', async () => {
  const { save } = await import('../src/storage.js');
  const quotaAdapter = {
    getItem: () => null,
    setItem() {
      // Reproduce the browser DOMException without depending on a browser: a plain
      // Error whose `.name` is 'QuotaExceededError' (the contract is on e.name).
      const err = new Error('The quota has been exceeded.');
      err.name = 'QuotaExceededError';
      throw err;
    },
  };
  const result = save(KEY, [{ id: 'a', text: 'x', done: false, created: 1 }], quotaAdapter);
  assert.deepStrictEqual(result, { ok: false, reason: 'QuotaExceededError' });
});

test('save(): any other setItem throw -> {ok:false, reason:e.name} (never throws)', async () => {
  const { save } = await import('../src/storage.js');
  const brokenAdapter = {
    getItem: () => null,
    setItem() {
      const err = new TypeError('setItem is not available');
      throw err;
    },
  };
  let result;
  assert.doesNotThrow(() => {
    result = save(KEY, [{ id: 'a', text: 'x', done: false, created: 1 }], brokenAdapter);
  });
  assert.deepStrictEqual(result, { ok: false, reason: 'TypeError' });
});

test('save(): does not mutate its input todos array or items', async () => {
  const { save } = await import('../src/storage.js');
  const todos = [{ id: 'a', text: 'x', done: false, created: 1 }];
  const snapshot = JSON.parse(JSON.stringify(todos));
  save(KEY, todos, makeMemoryAdapter());
  assert.deepStrictEqual(todos, snapshot, 'save must not mutate the caller array/items');
});
