# Rule — Testing (engine-todoapp)

## 1. Deterministic IDs via injected `idFactory`, never mock global `crypto`

Would removing this rule cause a mistake on THIS project specifically? Yes — `add()`'s default
`idFactory = crypto.randomUUID` makes output non-deterministic unless the test supplies its own factory.
Mocking global `crypto` (e.g. `globalThis.crypto = {...}`) leaks across test files run in the same process
and is exactly the kind of "cleverness" PLAN.md §2 explicitly rules out ("No global mocking of `crypto`").

```js
// test/state.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { add } from '../state.js';

test('add assigns deterministic ids via injected idFactory', () => {
  let n = 0;
  const idFactory = () => `id-${n++}`;
  const todos = add([], 'buy milk', idFactory);
  assert.deepStrictEqual(todos, [
    { id: 'id-0', text: 'buy milk', done: false, created: todos[0].created },
  ]);
});
```

## 2. `storage.js` tests use a project-owned in-memory stub, not a third-party mock

Would removing this rule cause a mistake on THIS project specifically? Yes — the zero-dependency
Definition of Done forbids any mocking library (`sinon`, `jest.mock`, etc.); PLAN.md §Definition-of-Done
explicitly calls for "an in-memory storage stub the project owns (~5 lines, no third-party mock)." Reaching
for a dependency here — even a dev-only one — breaks `deps-baseline.json`.

```js
// test/storage.test.js — the ~5-line stub this project owns
function makeMemoryAdapter() {
  const map = new Map();
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, v),
  };
}
```

## 3. Every shape-guard edge case gets its own explicit test — no combined "handles bad input" catch-all

Would removing this rule cause a mistake on THIS project specifically? Yes — PLAN.md §3 "Failure modes"
lists five distinct cases (absent key, malformed JSON, wrong-shape `null`/`42`/`"str"`/`{}`/`[{}]`, quota
exceeded, round-trip) as separately owned. A single catch-all `test('handles bad input', ...)` can pass
while silently regressing one specific case (e.g. `deserialize(null)` colliding with the malformed-JSON
path) without the test suite ever catching it — write one `test(...)` block per case in
`test/storage.test.js`.
