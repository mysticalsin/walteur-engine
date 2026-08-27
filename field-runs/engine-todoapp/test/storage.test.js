/**
 * @file test/storage.test.js — the FULL storage-adapter suite for `src/storage.js` (Task 5).
 *
 * Owner: node:test Suite Author. Organized into the FIVE groups the frozen brief
 * enumerates ((a)–(e)), each a top-level `test()` with `t.test()` subtests. The persistence
 * doubles are the project-owned stubs in `./helpers/memory-storage.js` (~5 lines each, no
 * third-party mock — the zero-dep Definition-of-Done forbids `sinon`/`jest.mock`).
 *
 * Group (a) is the load-bearing guard the design doc calls "the single most likely build
 * mistake": `import('../src/storage.js')` must RESOLVE under plain Node with no DOM globals,
 * proving the module references no top-level `window`/`localStorage`/`document` (any such
 * top-level reference throws `ReferenceError` the instant the module loads).
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { MemoryStorage, QuotaExceededStorage, ThrowingStorage } from './helpers/memory-storage.js';

/** The single storage key the app persists under (PLAN.md §Layout). */
const KEY = 'todos.v1';

/** A canonical fixture the round-trip cases persist and read back. */
function fixture() {
  return [
    { id: 'a', text: 'buy milk', done: false, created: 1720000000000 },
    { id: 'b', text: 'walk dog', done: true, created: 1720000000001 },
  ];
}

/** Wrap a valid todos array in the on-disk `{version:1, todos}` envelope as a JSON string. */
function envelope(todos) {
  return JSON.stringify({ version: 1, todos });
}

// ===========================================================================
// GROUP (a) — the import-resolves guard. A REAL assertion, not a side effect: the module
// must import cleanly under plain Node (no top-level DOM global) AND expose load/save.
// ===========================================================================
test('(a) import(storage.js) RESOLVES under plain Node — the top-level-DOM-global guard', async (t) => {
  await t.test('dynamic import does not reject (no ReferenceError from a top-level DOM ref)', async () => {
    await assert.doesNotReject(
      () => import('../src/storage.js'),
      'importing storage.js must not throw — a top-level window/localStorage/document ref would',
    );
  });

  await t.test('the module exports load() and save() as functions', async () => {
    const mod = await import('../src/storage.js');
    assert.equal(typeof mod.load, 'function', 'must export load()');
    assert.equal(typeof mod.save, 'function', 'must export save()');
  });
});

// ===========================================================================
// GROUP (b) — load returns [] for absent key / malformed / wrong-shape / throwing adapter.
// One subtest per distinct failure mode (no combined catch-all, per testing rule §3).
// ===========================================================================
test('(b) load returns [] on every corrupt/absent/failing read', async (t) => {
  await t.test('absent key (getItem -> null) -> [] (never JSON.parse(null))', async () => {
    const { load } = await import('../src/storage.js');
    assert.deepStrictEqual(load(KEY, new MemoryStorage()), []);
  });

  await t.test('malformed JSON blob -> []', async () => {
    const { load } = await import('../src/storage.js');
    const adapter = new MemoryStorage({ [KEY]: '{not json' });
    assert.deepStrictEqual(load(KEY, adapter), []);
  });

  await t.test('wrong-shape blob (item missing done) -> [] (all-or-nothing, ADR 1)', async () => {
    const { load } = await import('../src/storage.js');
    const adapter = new MemoryStorage({ [KEY]: envelope([{ id: 'a', text: 'x' }]) });
    assert.deepStrictEqual(load(KEY, adapter), []);
  });

  await t.test('valid-JSON wrong-type payload (a bare number) -> []', async () => {
    const { load } = await import('../src/storage.js');
    const adapter = new MemoryStorage({ [KEY]: '42' });
    assert.deepStrictEqual(load(KEY, adapter), []);
  });

  await t.test('throwing adapter (getItem throws) -> [] (never propagates the throw)', async () => {
    const { load } = await import('../src/storage.js');
    let out;
    assert.doesNotThrow(() => {
      out = load(KEY, new ThrowingStorage());
    });
    assert.deepStrictEqual(out, []);
  });
});

// ===========================================================================
// GROUP (c) — load returns the array for a valid stored envelope.
// ===========================================================================
test('(c) load returns the canonical Todo[] for a valid stored envelope', async (t) => {
  await t.test('a well-formed v1 envelope round-trips to its todos', async () => {
    const { load } = await import('../src/storage.js');
    const todos = fixture();
    const adapter = new MemoryStorage({ [KEY]: envelope(todos) });
    assert.deepStrictEqual(load(KEY, adapter), todos);
  });

  await t.test('a v0 bare-array (legacy) payload migrates and loads its todos', async () => {
    const { load } = await import('../src/storage.js');
    const legacy = [{ id: 'a', text: 'x', done: false, created: 1 }];
    const adapter = new MemoryStorage({ [KEY]: JSON.stringify(legacy) });
    assert.deepStrictEqual(load(KEY, adapter), legacy);
  });
});

// ===========================================================================
// GROUP (d) — save returns {ok:true} normally and {ok:false,reason:'QuotaExceededError'}
// when the throwing (quota) stub is used.
// ===========================================================================
test('(d) save reports its outcome as a value (never throws)', async (t) => {
  await t.test('a clean write returns {ok:true}', async () => {
    const { save } = await import('../src/storage.js');
    const result = save(KEY, fixture(), new MemoryStorage());
    assert.deepStrictEqual(result, { ok: true });
  });

  await t.test('a QuotaExceededError on setItem -> {ok:false, reason:"QuotaExceededError"}', async () => {
    const { save } = await import('../src/storage.js');
    let result;
    assert.doesNotThrow(() => {
      result = save(KEY, fixture(), new QuotaExceededStorage());
    });
    assert.deepStrictEqual(result, { ok: false, reason: 'QuotaExceededError' });
  });

  await t.test('save does not mutate its input todos array or items', async () => {
    const { save } = await import('../src/storage.js');
    const todos = fixture();
    const snapshot = JSON.parse(JSON.stringify(todos));
    save(KEY, todos, new MemoryStorage());
    assert.deepStrictEqual(todos, snapshot);
  });
});

// ===========================================================================
// GROUP (e) — save -> load round-trip through the in-memory stub yields the original todos.
// ===========================================================================
test('(e) save -> load round-trip through the in-memory stub', async (t) => {
  await t.test('deepStrictEqual(load(save(todos)), todos) through one shared adapter', async () => {
    const { load, save } = await import('../src/storage.js');
    const adapter = new MemoryStorage();
    const todos = fixture();

    const result = save(KEY, todos, adapter);
    assert.deepStrictEqual(result, { ok: true });

    const loaded = load(KEY, adapter);
    assert.deepStrictEqual(loaded, todos);
  });

  await t.test('round-trip on an empty list yields []', async () => {
    const { load, save } = await import('../src/storage.js');
    const adapter = new MemoryStorage();
    assert.deepStrictEqual(save(KEY, [], adapter), { ok: true });
    assert.deepStrictEqual(load(KEY, adapter), []);
  });
});
