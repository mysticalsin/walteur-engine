/**
 * @file src/storage.js — the STORAGE ADAPTER layer (ports & adapters, PLAN.md §2).
 *
 * The thin, DOM-free seam between the pure `state.js` and the browser's Web Storage
 * API. Persistence I/O is injected as a FUNCTION PARAMETER (`adapter`), so this module
 * references `window`/`localStorage`/`document` NOWHERE — not even at top level. That is
 * the load-bearing invariant of the whole testability strategy: `import`ing this module
 * under `node:test` (where no DOM globals exist) must NOT throw `ReferenceError`. Only
 * `app.js` — the single DOM-owning file — ever passes the real `window.localStorage` in.
 *
 * Design contract (PLAN.md §2/§3, ADR 1 = all-or-nothing shape guard, AGENTS.md §13
 * availability = corrupt/absent storage always resolves to a valid array):
 *   - `load` is TOTAL: absent key, malformed JSON, wrong-shape payload, AND a storage
 *     adapter that itself throws (e.g. Safari private mode, disabled storage) ALL resolve
 *     to a valid array. A corrupt or unavailable store must never brick the UI.
 *   - `save` is TOTAL and reports outcome as a value, never as a thrown exception: it
 *     returns `{ok:true}` on success and `{ok:false, reason:<error name>}` on any throw
 *     (a `QuotaExceededError` DOMException being the canonical case). Callers surface the
 *     failure to the user without a try/catch of their own.
 *   - Neither function mutates its input. `save` serializes a snapshot; the caller's
 *     `todos` array and its items are left byte-for-byte untouched.
 *
 * @typedef {import('./state.js').Todo} Todo
 */

import { serialize, deserialize } from './state.js';

/**
 * The injected storage adapter — the Web Storage API surface this app depends on,
 * narrowed to exactly the two synchronous methods used. `app.js` passes the real
 * `window.localStorage` (which structurally satisfies this shape); tests pass a
 * project-owned in-memory stub. The adapter is ALWAYS a parameter, never a global.
 *
 * @typedef {Object} StorageAdapter
 * @property {(key: string) => (string | null)} getItem  Return the stored string, or
 *   `null` when the key is absent. May throw if storage is unavailable — `load` tolerates it.
 * @property {(key: string, value: string) => void} setItem  Persist `value` under `key`.
 *   May throw `QuotaExceededError` (or any error) — `save` maps the throw to a result.
 */

/**
 * The outcome of a {@link save} call. A value, never an exception, so a failed persist is
 * a first-class, surfaceable state rather than a thrown error the caller must guard.
 *
 * @typedef {{ ok: true } | { ok: false, reason: string }} SaveResult
 */

/**
 * load — read the persisted todos for `key` through the injected adapter and return a
 * guaranteed-valid `Todo[]`.
 *
 * Totality is enforced on two independent axes:
 *   1. STORED-VALUE corruption (absent / malformed / wrong-shape) is absorbed by
 *      `deserialize`, itself a total function. `getItem` returning `null` (absent key)
 *      is passed straight to `deserialize`, which maps it to `[]` WITHOUT ever calling
 *      `JSON.parse(null)`.
 *   2. ADAPTER failure — a `getItem` that itself throws (storage disabled, blocked by a
 *      privacy setting, quota-probing side effect, etc.) — is caught by the outer
 *      try/catch so the call still yields `[]` instead of propagating a `ReferenceError`
 *      or `SecurityError` into the UI.
 *
 * @param {string} key                Storage key to read (e.g. `'todos.v1'`).
 * @param {StorageAdapter} adapter    Injected `{getItem,setItem}` — never a global.
 * @returns {Todo[]}                  A valid array; `[]` on any absence/corruption/throw.
 */
export function load(key, adapter) {
  try {
    const raw = adapter.getItem(key); // `null` when absent — deserialize handles it, no JSON.parse(null)
    return deserialize(raw);
  } catch {
    // A throwing adapter (storage disabled / blocked) must not brick the UI. The failure
    // is non-recoverable for reads, so the safe, total answer is the empty list.
    return [];
  }
}

/**
 * save — serialize `todos` into the `{version:1, todos}` envelope and persist it under
 * `key` through the injected adapter, reporting the outcome as a value.
 *
 * The write path can fail for reasons entirely outside the caller's control — most
 * commonly a `QuotaExceededError` DOMException when `localStorage` is full, but also a
 * `SecurityError` (storage blocked) or any adapter-specific throw. Rather than let that
 * escape as an exception, we map ANY throw to `{ok:false, reason:e.name}` so `app.js` can
 * surface a one-line, non-blocking status ("Couldn't save — storage full") without its
 * own try/catch. A clean write returns `{ok:true}`.
 *
 * `serialize` reads a fresh snapshot of each item, so the caller's `todos` array and its
 * items are never mutated by this call.
 *
 * @param {string} key                Storage key to write (e.g. `'todos.v1'`).
 * @param {Todo[]} todos              The current list to persist (left unmutated).
 * @param {StorageAdapter} adapter    Injected `{getItem,setItem}` — never a global.
 * @returns {SaveResult}              `{ok:true}` on success; `{ok:false, reason}` on any throw.
 */
export function save(key, todos, adapter) {
  try {
    adapter.setItem(key, serialize(todos));
    return { ok: true };
  } catch (e) {
    // Surface the failure as data, keyed on the error's `name` so the UI can distinguish
    // 'QuotaExceededError' (offer to prune) from other failures. `name` is normalized to a
    // string because a non-Error throw (unusual, but possible from a hostile adapter) may
    // lack one — the contract is a string `reason`, always.
    const reason =
      e && typeof e === 'object' && typeof (/** @type {{name?: unknown}} */ (e).name) === 'string'
        ? /** @type {{name: string}} */ (e).name
        : 'Error';
    return { ok: false, reason };
  }
}
