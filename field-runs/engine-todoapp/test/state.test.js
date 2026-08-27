/**
 * @file test/state.test.js — the FULL pure-logic suite for `src/state.js` (Task 5).
 *
 * Owner: node:test Suite Author. This is the complete state suite the two earlier TDD
 * driver files (test/state-deserialize-total.test.js) deliberately did NOT try to be —
 * it is organized into the TEN groups the frozen brief enumerates, each a top-level
 * `test()` with `t.test()` subtests so a failure names the exact case.
 *
 * Constraints (Definition-of-Done invariants, not preferences):
 *   - Zero third-party deps: `node:test` + `node:assert/strict` ONLY. No jsdom, no mock lib.
 *   - Determinism: ids come from an INJECTED `idFactory` stub `() => 'id-' + (n++)`, never
 *     from mocking global `crypto` (.claude/rules/testing.md §1).
 *   - Immutability is PROVEN, not asserted by eye: every mutating call captures a
 *     deep copy of the input BEFORE the call and `deepStrictEqual`s the input against that
 *     copy AFTER, so an in-place mutation fails loudly.
 *   - `deepStrictEqual` proves both the serialize/deserialize round-trip and immutability.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  add,
  toggle,
  edit,
  remove,
  filter,
  activeCount,
  serialize,
  deserialize,
  migrate,
  CURRENT_VERSION,
} from '../src/state.js';

// ---------------------------------------------------------------------------
// Test doubles & fixtures — all project-owned, zero third-party.
// ---------------------------------------------------------------------------

/**
 * A deterministic id factory matching the brief's `() => 'id-' + (n++)`. Each call returns
 * a fresh, monotonic id so assertions on `add`'s output are exact without touching global
 * `crypto`.
 *
 * @param {number} [start=0]
 * @returns {() => string}
 */
function makeIdFactory(start = 0) {
  let n = start;
  return () => `id-${n++}`;
}

/**
 * A structural deep clone via JSON round-trip — sufficient here because the `Todo` record
 * is constrained to JSON-round-trip-safe primitives only (string/boolean/number). Used to
 * snapshot an input BEFORE a mutating call so the AFTER state can be compared for
 * accidental in-place mutation.
 *
 * @template T
 * @param {T} value
 * @returns {T}
 */
function deepCopy(value) {
  return JSON.parse(JSON.stringify(value));
}

/** A canonical two-item fixture reused across groups. Fresh copy per call (no shared state). */
function fixture() {
  return [
    { id: 'a', text: 'buy milk', done: false, created: 1720000000000 },
    { id: 'b', text: 'walk dog', done: true, created: 1720000000001 },
  ];
}

// ===========================================================================
// GROUP 1 — add: trims, appends, empty -> no-op, deterministic id via idFactory.
// ===========================================================================
test('(1) add', async (t) => {
  await t.test('trims surrounding whitespace and appends one item', () => {
    const before = [];
    const after = add(before, '  buy milk  ', makeIdFactory());
    assert.equal(after.length, 1);
    assert.equal(after[0].text, 'buy milk'); // trimmed
    assert.equal(after[0].done, false);
    assert.equal(typeof after[0].created, 'number');
    assert.ok(Number.isFinite(after[0].created));
  });

  await t.test('assigns a deterministic id from the injected idFactory', () => {
    const idFactory = makeIdFactory();
    let todos = [];
    todos = add(todos, 'first', idFactory);
    todos = add(todos, 'second', idFactory);
    assert.deepStrictEqual(
      todos.map((todo) => todo.id),
      ['id-0', 'id-1'],
    );
    // Exact full-shape match (created is dynamic, so pin it from the produced item).
    assert.deepStrictEqual(todos[0], {
      id: 'id-0',
      text: 'first',
      done: false,
      created: todos[0].created,
    });
  });

  await t.test('appends to the END, preserving existing order', () => {
    const before = [{ id: 'a', text: 'x', done: false, created: 1 }];
    const after = add(before, 'y', makeIdFactory(9));
    assert.deepStrictEqual(
      after.map((todo) => todo.id),
      ['a', 'id-9'],
    );
  });

  await t.test('empty string -> no-op returning the SAME input reference', () => {
    const before = fixture();
    assert.equal(add(before, '', makeIdFactory()), before); // same reference (===)
  });

  await t.test('whitespace-only string -> no-op returning the SAME input reference', () => {
    const before = fixture();
    assert.equal(add(before, '   \t\n ', makeIdFactory()), before);
  });
});

// ===========================================================================
// GROUP 2 — toggle: flips done, unknown id -> no-op.
// ===========================================================================
test('(2) toggle', async (t) => {
  await t.test('flips done false -> true on the matched item only', () => {
    const before = fixture(); // a:false, b:true
    const after = toggle(before, 'a');
    assert.equal(after[0].done, true); // flipped
    assert.equal(after[1].done, true); // untouched
  });

  await t.test('flips done true -> false on the matched item', () => {
    const after = toggle(fixture(), 'b');
    assert.equal(after[1].done, false);
  });

  await t.test('unknown id -> no-op returning the SAME input reference', () => {
    const before = fixture();
    assert.equal(toggle(before, 'does-not-exist'), before);
  });
});

// ===========================================================================
// GROUP 3 — edit: changes text, empty -> removes item, unknown id -> no-op.
// ===========================================================================
test('(3) edit', async (t) => {
  await t.test('changes text (trimmed) on the matched item only', () => {
    const before = fixture();
    const after = edit(before, 'a', '  renamed  ');
    assert.equal(after[0].text, 'renamed'); // trimmed + changed
    assert.equal(after[1].text, 'walk dog'); // untouched
  });

  await t.test('empty trimmed text REMOVES the item (TodoMVC contract)', () => {
    const before = fixture();
    const after = edit(before, 'a', '   ');
    assert.deepStrictEqual(
      after.map((todo) => todo.id),
      ['b'],
    );
  });

  await t.test('unknown id -> no-op returning the SAME input reference', () => {
    const before = fixture();
    assert.equal(edit(before, 'nope', 'whatever'), before);
  });
});

// ===========================================================================
// GROUP 4 — remove: drops item.
// ===========================================================================
test('(4) remove', async (t) => {
  await t.test('drops the matched item', () => {
    const after = remove(fixture(), 'a');
    assert.deepStrictEqual(
      after.map((todo) => todo.id),
      ['b'],
    );
  });

  await t.test('unknown id -> no-op returning the SAME input reference', () => {
    const before = fixture();
    assert.equal(remove(before, 'nope'), before);
  });
});

// ===========================================================================
// GROUP 5 — filter: all/active/done each return the correct view; unknown mode -> all.
// ===========================================================================
test('(5) filter', async (t) => {
  const todos = fixture(); // a: active, b: done

  await t.test("'all' returns every item (identity view — same reference)", () => {
    assert.equal(filter(todos, 'all'), todos);
    assert.deepStrictEqual(filter(todos, 'all'), todos);
  });

  await t.test("'active' returns only not-done items", () => {
    assert.deepStrictEqual(
      filter(todos, 'active').map((todo) => todo.id),
      ['a'],
    );
  });

  await t.test("'done' returns only done items", () => {
    assert.deepStrictEqual(
      filter(todos, 'done').map((todo) => todo.id),
      ['b'],
    );
  });

  await t.test('unknown mode degrades to all (never throws)', () => {
    assert.doesNotThrow(() => filter(todos, 'bogus-mode'));
    assert.equal(filter(todos, 'bogus-mode'), todos);
    assert.equal(filter(todos, undefined), todos);
  });
});

// ===========================================================================
// GROUP 6 — activeCount.
// ===========================================================================
test('(6) activeCount', async (t) => {
  await t.test('counts not-done items in a mixed list', () => {
    const todos = [
      { id: 'a', text: 'x', done: false, created: 1 },
      { id: 'b', text: 'y', done: true, created: 2 },
      { id: 'c', text: 'z', done: false, created: 3 },
    ];
    assert.equal(activeCount(todos), 2);
  });

  await t.test('empty list -> 0', () => {
    assert.equal(activeCount([]), 0);
  });

  await t.test('all done -> 0', () => {
    assert.equal(activeCount([{ id: 'a', text: 'x', done: true, created: 1 }]), 0);
  });
});

// ===========================================================================
// GROUP 7 — immutability: the input array/objects are NOT mutated by any mutator.
// Each case captures a deep copy of the input BEFORE the call and deepStrictEquals the
// input against that copy AFTER — an in-place mutation would diverge and fail.
// ===========================================================================
test('(7) immutability — no mutator mutates its input', async (t) => {
  await t.test('add does not mutate the input array or items', () => {
    const before = fixture();
    const snapshot = deepCopy(before);
    add(before, 'new item', makeIdFactory());
    assert.deepStrictEqual(before, snapshot);
  });

  await t.test('toggle does not mutate the input array or items', () => {
    const before = fixture();
    const snapshot = deepCopy(before);
    toggle(before, 'a');
    assert.deepStrictEqual(before, snapshot);
  });

  await t.test('edit (rename) does not mutate the input array or items', () => {
    const before = fixture();
    const snapshot = deepCopy(before);
    edit(before, 'a', 'renamed');
    assert.deepStrictEqual(before, snapshot);
  });

  await t.test('edit (empty -> remove) does not mutate the input array or items', () => {
    const before = fixture();
    const snapshot = deepCopy(before);
    edit(before, 'a', '   ');
    assert.deepStrictEqual(before, snapshot);
  });

  await t.test('remove does not mutate the input array or items', () => {
    const before = fixture();
    const snapshot = deepCopy(before);
    remove(before, 'a');
    assert.deepStrictEqual(before, snapshot);
  });

  await t.test('filter does not mutate the input array or items', () => {
    const before = fixture();
    const snapshot = deepCopy(before);
    filter(before, 'active');
    assert.deepStrictEqual(before, snapshot);
  });

  await t.test('serialize does not mutate the input array or items', () => {
    const before = fixture();
    const snapshot = deepCopy(before);
    serialize(before);
    assert.deepStrictEqual(before, snapshot);
  });
});

// ===========================================================================
// GROUP 8 — round-trip: deepStrictEqual(deserialize(serialize(fixture)), fixture).
// ===========================================================================
test('(8) round-trip serialize/deserialize', async (t) => {
  await t.test('deepStrictEqual(deserialize(serialize(fixture)), fixture)', () => {
    const original = fixture();
    assert.deepStrictEqual(deserialize(serialize(original)), original);
  });

  await t.test('round-trip on an empty list yields []', () => {
    assert.deepStrictEqual(deserialize(serialize([])), []);
  });

  await t.test('serialize emits the {version, todos} envelope', () => {
    const original = fixture();
    const parsed = JSON.parse(serialize(original));
    assert.equal(parsed.version, CURRENT_VERSION);
    assert.deepStrictEqual(parsed.todos, original);
  });
});

// ===========================================================================
// GROUP 9 — deserialize TOTAL: every listed input -> []. One subtest per case.
// ===========================================================================
test('(9) deserialize is TOTAL (every corrupt input -> [])', async (t) => {
  /** @type {Array<[string, string | null]>} label -> raw input */
  const cases = [
    ['null (absent key, never JSON.parse(null))', null],
    ['"{not json" (malformed JSON, SyntaxError swallowed)', '{not json'],
    ["'null' (valid JSON null literal)", 'null'],
    ["'42' (valid JSON number)", '42'],
    ['\'"s"\' (valid JSON string)', '"s"'],
    ["'{}' (valid JSON object, no todos array)", '{}'],
    ["'[{}]' (bare array of a shapeless item -> SHAPE_GUARD reject)", '[{}]'],
  ];

  for (const [label, input] of cases) {
    await t.test(`${label} -> []`, () => {
      let out;
      assert.doesNotThrow(() => {
        out = deserialize(input);
      }, `deserialize threw on: ${label}`);
      assert.deepStrictEqual(out, []);
    });
  }
});

// ===========================================================================
// GROUP 10 — migrate: v0 bare-array -> v1 envelope todos; future version -> [].
// ===========================================================================
test('(10) migrate — the version spine', async (t) => {
  await t.test('v0 bare array -> {version:CURRENT_VERSION, todos} envelope', () => {
    const bare = [{ id: 'a', text: 'x', done: false, created: 1 }];
    assert.deepStrictEqual(migrate(bare), {
      version: CURRENT_VERSION,
      todos: bare,
    });
  });

  await t.test('a v0 bare array deserializes end-to-end to the todos (envelope-free legacy)', () => {
    const legacy = JSON.stringify([{ id: 'a', text: 'x', done: false, created: 1 }]);
    assert.deepStrictEqual(deserialize(legacy), [
      { id: 'a', text: 'x', done: false, created: 1 },
    ]);
  });

  await t.test('future version -> [] (forward-unreadable, never crash)', () => {
    assert.deepStrictEqual(migrate({ version: CURRENT_VERSION + 1, todos: [] }), []);
  });

  await t.test('a future-version envelope deserializes end-to-end to []', () => {
    const future = JSON.stringify({ version: CURRENT_VERSION + 1, todos: [] });
    assert.deepStrictEqual(deserialize(future), []);
  });

  await t.test('non-array, non-object primitive -> [] (never throws)', () => {
    assert.doesNotThrow(() => migrate(42));
    assert.deepStrictEqual(migrate(42), []);
    assert.deepStrictEqual(migrate(null), []);
  });
});
