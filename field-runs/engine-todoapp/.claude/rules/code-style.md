# Rule — Code style (engine-todoapp)

## 1. `state.js` must stay import-safe under Node with zero DOM globals

This project's entire testability strategy depends on `state.js` and `storage.js` never referencing
`window`, `document`, or `localStorage` at module top-level. Would removing this rule cause a mistake on
THIS project specifically? Yes — it is the exact failure mode called out in PLAN.md §2 as "the single most
likely build mistake." A top-level reference throws `ReferenceError` the instant `test/state.test.js`
imports the module in Node, and it can slip past a casual review because the file "looks pure" at a glance.

```js
// WRONG — breaks `node --test` import, even though it "looks" like it belongs in state.js
const stored = localStorage.getItem('todos.v1'); // top-level: throws in Node

// RIGHT — adapter passed as a function parameter, called only inside a function body
export function load(key, adapter) {
  try {
    const raw = adapter.getItem(key); // adapter is {getItem,setItem}, injected by the caller
    return deserialize(raw);
  } catch {
    return [];
  }
}
```

## 2. Every `state.js` mutator returns a new array — never mutates its input

Would removing this rule cause a mistake on THIS project specifically? Yes — the app relies on referential
identity to decide when to re-render/persist; an in-place mutation (`todos.push(...)`) silently breaks
callers that compare `oldTodos !== newTodos`, and it breaks the `deepStrictEqual` round-trip tests in
`test/state.test.js` that snapshot a "before" fixture for comparison.

```js
// WRONG — mutates the caller's array in place
export function toggle(todos, id) {
  const t = todos.find(t => t.id === id);
  if (t) t.done = !t.done;
  return todos;
}

// RIGHT — returns a new array; original is untouched
export function toggle(todos, id) {
  return todos.map(t => (t.id === id ? { ...t, done: !t.done } : t));
}
```
