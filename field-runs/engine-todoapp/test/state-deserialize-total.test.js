// TDD driver test for Task 2 — the PURE state module (src/state.js).
//
// This file is written BEFORE src/state.js exists. It MUST fail (ERR_MODULE_NOT_FOUND)
// on a clean checkout, then pass once src/state.js implements the module. It is the
// worker-owned "enough failing assertions to drive the module" slice; the FULL
// state suite (test/state.test.js) lands in T5 and is owned by the test author — this
// file is deliberately named so it does not collide with that one.
//
// Focus of this driver: the two hardest contracts to get right —
//   (1) deserialize is a TOTAL function (never throws) over adversarial input, and
//   (2) every mutator returns a NEW array and never mutates its input,
//       plus the serialize/deserialize round-trip on a canonical fixture.

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
  SHAPE_GUARD,
} from '../src/state.js';

// A deterministic id factory so assertions are exact (never mock global crypto).
function makeIdFactory() {
  let n = 0;
  return () => `id-${n++}`;
}

// ---------------------------------------------------------------------------
// deserialize — TOTAL FUNCTION: every listed input resolves to a valid array, [] on
// anything corrupt/unreadable. This is the trust boundary the whole app leans on.
// ---------------------------------------------------------------------------

test('deserialize(null) === [] (absent key, never JSON.parse(null))', () => {
  assert.deepStrictEqual(deserialize(null), []);
});

test('deserialize(undefined) === [] (defensive: absent value)', () => {
  assert.deepStrictEqual(deserialize(undefined), []);
});

test("deserialize('{not json') === [] (malformed JSON -> SyntaxError swallowed)", () => {
  assert.deepStrictEqual(deserialize('{not json'), []);
});

test("deserialize('null') === [] (valid JSON, null literal)", () => {
  assert.deepStrictEqual(deserialize('null'), []);
});

test("deserialize('42') === [] (valid JSON, number)", () => {
  assert.deepStrictEqual(deserialize('42'), []);
});

test('deserialize(\'"s"\') === [] (valid JSON, string)', () => {
  assert.deepStrictEqual(deserialize('"s"'), []);
});

test("deserialize('{}') === [] (valid JSON, object without todos array)", () => {
  assert.deepStrictEqual(deserialize('{}'), []);
});

test("deserialize('[{}]') === [] (bare array of shapeless item -> SHAPE_GUARD reject)", () => {
  assert.deepStrictEqual(deserialize('[{}]'), []);
});

test('deserialize never throws over a fuzz sweep of adversarial inputs', () => {
  const adversarial = [
    null,
    undefined,
    '',
    '   ',
    '{not json',
    'null',
    'true',
    'false',
    '42',
    '-0',
    '"s"',
    '[]',
    '{}',
    '[{}]',
    '{"version":1}',
    '{"version":1,"todos":null}',
    '{"version":1,"todos":42}',
    '{"version":1,"todos":[{"id":"","text":"x","done":false}]}', // empty id
    '{"version":1,"todos":[{"id":"a","text":"x","done":"yes"}]}', // done not boolean
    '{"version":1,"todos":[{"id":"a","text":5,"done":false}]}', // text not string
    '{"version":2,"todos":[]}', // future version
    '{"version":0}', // bare-array migration miss
    '[1,2,3]',
    '[{"id":"a","text":"x","done":true},{"id":"b"}]', // one bad item -> all-or-nothing reject
  ];
  for (const input of adversarial) {
    let out;
    assert.doesNotThrow(() => {
      out = deserialize(input);
    }, `deserialize threw on input: ${String(input)}`);
    assert.ok(Array.isArray(out), `deserialize did not return an array for: ${String(input)}`);
  }
});

test('all-or-nothing: one malformed item rejects the whole payload (ADR 1, Option B)', () => {
  const envelope = JSON.stringify({
    version: 1,
    todos: [
      { id: 'a', text: 'good', done: false, created: 1 },
      { id: 'b', text: 'bad', done: 'nope', created: 2 }, // done mistyped
    ],
  });
  assert.deepStrictEqual(deserialize(envelope), []);
});

test('deserialize accepts a well-formed v1 envelope', () => {
  const envelope = JSON.stringify({
    version: 1,
    todos: [{ id: 'a', text: 'buy milk', done: false, created: 1720000000000 }],
  });
  assert.deepStrictEqual(deserialize(envelope), [
    { id: 'a', text: 'buy milk', done: false, created: 1720000000000 },
  ]);
});

// ---------------------------------------------------------------------------
// migrate — the version spine.
// ---------------------------------------------------------------------------

test('migrate: v0 bare array -> {version:1, todos}', () => {
  const raw = [{ id: 'a', text: 'x', done: false, created: 1 }];
  assert.deepStrictEqual(migrate(raw), {
    version: 1,
    todos: [{ id: 'a', text: 'x', done: false, created: 1 }],
  });
});

test('migrate: future/unknown version -> [] (forward-unreadable, never crash)', () => {
  assert.deepStrictEqual(migrate({ version: 2, todos: [] }), []);
});

test('migrate: garbage -> [] (never throws)', () => {
  assert.doesNotThrow(() => migrate(42));
  assert.deepStrictEqual(migrate(42), []);
  assert.deepStrictEqual(migrate(null), []);
});

// ---------------------------------------------------------------------------
// SHAPE_GUARD — Array.isArray(todos) AND every item id:non-empty-string / text:string
// / done:boolean. All-or-nothing.
// ---------------------------------------------------------------------------

test('SHAPE_GUARD: valid array passes; any bad item -> []', () => {
  const good = [{ id: 'a', text: 'x', done: true, created: 1 }];
  assert.deepStrictEqual(SHAPE_GUARD(good), good);
  assert.deepStrictEqual(SHAPE_GUARD([{ id: '', text: 'x', done: true }]), []);
  assert.deepStrictEqual(SHAPE_GUARD([{ id: 'a', text: 'x' }]), []); // missing done
  assert.deepStrictEqual(SHAPE_GUARD('not array'), []);
  assert.deepStrictEqual(SHAPE_GUARD(null), []);
});

// ---------------------------------------------------------------------------
// Mutators — return NEW array, never mutate input.
// ---------------------------------------------------------------------------

test('add: appends trimmed item, returns new array, input untouched', () => {
  const before = [];
  const after = add(before, '  buy milk  ', makeIdFactory());
  assert.notEqual(after, before);
  assert.deepStrictEqual(before, []);
  assert.equal(after.length, 1);
  assert.equal(after[0].id, 'id-0');
  assert.equal(after[0].text, 'buy milk');
  assert.equal(after[0].done, false);
  assert.equal(typeof after[0].created, 'number');
});

test('add: empty/whitespace text -> returns SAME input reference (no phantom)', () => {
  const before = [{ id: 'a', text: 'x', done: false, created: 1 }];
  assert.equal(add(before, '   ', makeIdFactory()), before);
  assert.equal(add(before, '', makeIdFactory()), before);
});

test('toggle: flips done immutably; unknown id -> unchanged', () => {
  const before = [{ id: 'a', text: 'x', done: false, created: 1 }];
  const after = toggle(before, 'a');
  assert.notEqual(after, before);
  assert.equal(before[0].done, false); // input untouched
  assert.equal(after[0].done, true);
  assert.equal(toggle(before, 'zzz'), before); // unknown id, same ref
});

test('edit: trims text; empty trimmed -> REMOVE (TodoMVC); unknown id -> unchanged', () => {
  const before = [
    { id: 'a', text: 'x', done: false, created: 1 },
    { id: 'b', text: 'y', done: false, created: 2 },
  ];
  const renamed = edit(before, 'a', '  new text  ');
  assert.equal(renamed[0].text, 'new text');
  assert.equal(before[0].text, 'x'); // input untouched
  const removed = edit(before, 'a', '   ');
  assert.deepStrictEqual(
    removed.map((t) => t.id),
    ['b'],
  );
  assert.equal(edit(before, 'zzz', 'whatever'), before); // unknown id, same ref
});

test('remove: drops item immutably; unknown id -> unchanged', () => {
  const before = [
    { id: 'a', text: 'x', done: false, created: 1 },
    { id: 'b', text: 'y', done: false, created: 2 },
  ];
  const after = remove(before, 'a');
  assert.deepStrictEqual(
    after.map((t) => t.id),
    ['b'],
  );
  assert.equal(before.length, 2); // input untouched
  assert.equal(remove(before, 'zzz'), before);
});

test('filter: all|active|done views; unknown mode -> all; never throws', () => {
  const todos = [
    { id: 'a', text: 'x', done: false, created: 1 },
    { id: 'b', text: 'y', done: true, created: 2 },
  ];
  assert.deepStrictEqual(filter(todos, 'all'), todos);
  assert.deepStrictEqual(
    filter(todos, 'active').map((t) => t.id),
    ['a'],
  );
  assert.deepStrictEqual(
    filter(todos, 'done').map((t) => t.id),
    ['b'],
  );
  assert.doesNotThrow(() => filter(todos, 'bogus'));
  assert.deepStrictEqual(filter(todos, 'bogus'), todos); // unknown -> all
  assert.deepStrictEqual(filter(todos, undefined), todos);
});

test('activeCount: counts not-done items', () => {
  const todos = [
    { id: 'a', text: 'x', done: false, created: 1 },
    { id: 'b', text: 'y', done: true, created: 2 },
    { id: 'c', text: 'z', done: false, created: 3 },
  ];
  assert.equal(activeCount(todos), 2);
  assert.equal(activeCount([]), 0);
});

// ---------------------------------------------------------------------------
// Round-trip — the persistence invariant.
// ---------------------------------------------------------------------------

test('round-trip: deepStrictEqual(deserialize(serialize(x)), x) on a fixture', () => {
  const fixture = [
    { id: 'a', text: 'buy milk', done: false, created: 1720000000000 },
    { id: 'b', text: 'walk dog', done: true, created: 1720000000001 },
  ];
  assert.deepStrictEqual(deserialize(serialize(fixture)), fixture);
});

test('serialize: produces the {version:1,todos} envelope as a JSON string', () => {
  const fixture = [{ id: 'a', text: 'x', done: false, created: 1 }];
  const str = serialize(fixture);
  assert.equal(typeof str, 'string');
  assert.deepStrictEqual(JSON.parse(str), { version: 1, todos: fixture });
});
