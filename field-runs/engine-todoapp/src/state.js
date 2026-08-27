/**
 * @file src/state.js — the PURE state module.
 *
 * DOM-free, side-effect-free ES module. Zero reference to `window`, `document`, or
 * `localStorage` anywhere — even at module top-level — so it imports cleanly under
 * `node:test` with no jsdom/shim. All persistence I/O lives one layer out in
 * `storage.js`, which injects the storage adapter as a function parameter.
 *
 * Design contract (PLAN.md §3/§4, ADR 1 = all-or-nothing shape guard):
 *   - Every mutator returns a NEW array and NEVER mutates its input. Callers rely on
 *     referential identity (`old !== new`) to decide when to re-render/persist, and a
 *     no-op mutation returns the SAME reference so `old === new` short-circuits work.
 *   - `deserialize` is a TOTAL function: every input — null/undefined, malformed JSON,
 *     valid-JSON-wrong-shape, future version, any mistyped item — maps to a valid
 *     array and NEVER throws. There is no 500-equivalent; a UI must never be bricked
 *     by corrupt local storage.
 *   - The `Todo` record is constrained to JSON-round-trip-safe primitives only
 *     (string/boolean/number — NO Date objects) so serialize never drifts.
 */

/**
 * A single todo item. Fields are JSON-round-trip-safe primitives only.
 * @typedef {Object} Todo
 * @property {string}  id       Non-empty, unique within the array (the primary key).
 * @property {string}  text     Trimmed, non-empty (empty commit === delete, per TodoMVC).
 * @property {boolean} done     Strictly `true`/`false` (never a truthy coercion).
 * @property {number}  created  Epoch milliseconds; used only for stable ordering.
 */

/**
 * The persisted envelope shape written to the single `localStorage` key.
 * @typedef {Object} Envelope
 * @property {1}           version  Schema version — the migration spine.
 * @property {Todo[]}      todos    The item array.
 */

/** Current on-disk schema version. Bump + add a `migrate` branch when the shape changes. */
export const CURRENT_VERSION = 1;

/** Valid filter modes. Anything outside this set is treated as `all`. */
const FILTER_MODES = /** @type {const} */ (['all', 'active', 'done']);

/**
 * Runtime type guard for a single persisted item — the equivalent of NOT NULL + type
 * CHECK constraints. `JSON.parse` can succeed and still yield garbage, so structural
 * validation is mandatory at the trust boundary.
 *
 * @param {unknown} item
 * @returns {item is Todo}
 */
function isValidTodo(item) {
  if (item === null || typeof item !== 'object' || Array.isArray(item)) return false;
  const t = /** @type {Record<string, unknown>} */ (item);
  if (typeof t.id !== 'string' || t.id.length === 0) return false;
  if (typeof t.text !== 'string') return false;
  if (typeof t.done !== 'boolean') return false;
  // `created` is optional on ingest (migrated v0 data may lack it) but, when present,
  // must be a finite number — never a Date object or NaN, which would break round-trip.
  if ('created' in t) {
    if (typeof t.created !== 'number' || !Number.isFinite(t.created)) return false;
  }
  return true;
}

/**
 * Normalize a validated item to the canonical `Todo` field set, in stable field order,
 * dropping any extra keys so the persisted envelope never carries data beyond the
 * documented shape. Assumes `isValidTodo(item)` already returned true.
 *
 * @param {Todo} item
 * @returns {Todo}
 */
function canonicalizeTodo(item) {
  /** @type {Todo} */
  const normalized = { id: item.id, text: item.text, done: item.done, created: 0 };
  normalized.created =
    typeof item.created === 'number' && Number.isFinite(item.created) ? item.created : 0;
  return normalized;
}

/**
 * SHAPE_GUARD — the all-or-nothing structural gate (ADR 1, Option B).
 *
 * Returns the input as a canonical `Todo[]` IFF it is an array in which EVERY item
 * passes `isValidTodo`. If the value is not an array, or ANY item fails, the entire
 * payload is rejected and `[]` is returned (a single corrupt record never yields a
 * partial list — the failure is loud, not silently patched).
 *
 * @param {unknown} todos
 * @returns {Todo[]}
 */
export function SHAPE_GUARD(todos) {
  if (!Array.isArray(todos)) return [];
  for (const item of todos) {
    if (!isValidTodo(item)) return [];
  }
  return todos.map(canonicalizeTodo);
}

/**
 * migrate — the version spine. Routes raw parsed data to the current envelope shape.
 *
 *   - A bare array (legacy v0, pre-envelope) is wrapped into `{version:1, todos}`.
 *   - A `{version:1, todos}` envelope passes through unchanged.
 *   - An unknown/future version (or any unrecognized shape) is treated as unreadable
 *     and collapses to `[]` — never crash, never half-write.
 *
 * Note: `migrate` performs SHAPE routing only; structural validation of items is done
 * by `SHAPE_GUARD` after migration. It never throws.
 *
 * @param {unknown} raw
 * @returns {Envelope | Todo[]}  An envelope to be shape-guarded, or `[]` if unreadable.
 */
export function migrate(raw) {
  // v0: a bare array of items (no envelope). Wrap it into the current envelope.
  if (Array.isArray(raw)) {
    return { version: CURRENT_VERSION, todos: raw };
  }
  // A versioned envelope.
  if (raw !== null && typeof raw === 'object') {
    const env = /** @type {Record<string, unknown>} */ (raw);
    if (env.version === CURRENT_VERSION && Array.isArray(env.todos)) {
      return { version: CURRENT_VERSION, todos: /** @type {Todo[]} */ (env.todos) };
    }
    // version < current with a todos array would branch here in future migrations.
    // Forward-unknown (version > current) or any shape without a valid todos array
    // is unreadable.
    return [];
  }
  // null / number / string / boolean / undefined — nothing to migrate.
  return [];
}

/**
 * add — append a new todo. Trims `text`; an empty/whitespace-only commit is a no-op
 * that returns the SAME input reference (never a phantom item).
 *
 * @param {Todo[]} todos
 * @param {string} text
 * @param {() => string} [idFactory=crypto.randomUUID]  Injected for deterministic tests.
 * @returns {Todo[]}
 */
export function add(todos, text, idFactory = crypto.randomUUID) {
  const trimmed = typeof text === 'string' ? text.trim() : '';
  if (!trimmed) return todos; // empty commit => no-op, same reference (no phantom)
  /** @type {Todo} */
  const item = { id: idFactory(), text: trimmed, done: false, created: Date.now() };
  return [...todos, item];
}

/**
 * toggle — flip a todo's `done` flag immutably. An unknown `id` is a no-op that
 * returns the SAME input reference.
 *
 * @param {Todo[]} todos
 * @param {string} id
 * @returns {Todo[]}
 */
export function toggle(todos, id) {
  if (!todos.some((t) => t.id === id)) return todos; // unknown id => same reference
  return todos.map((t) => (t.id === id ? { ...t, done: !t.done } : t));
}

/**
 * edit — replace a todo's text (trimmed). Per the TodoMVC contract, committing an
 * empty/whitespace-only text REMOVES the item. An unknown `id` is a no-op that
 * returns the SAME input reference.
 *
 * @param {Todo[]} todos
 * @param {string} id
 * @param {string} text
 * @returns {Todo[]}
 */
export function edit(todos, id, text) {
  if (!todos.some((t) => t.id === id)) return todos; // unknown id => same reference
  const trimmed = typeof text === 'string' ? text.trim() : '';
  if (!trimmed) return todos.filter((t) => t.id !== id); // empty edit => delete (TodoMVC)
  return todos.map((t) => (t.id === id ? { ...t, text: trimmed } : t));
}

/**
 * remove — drop a todo by id immutably. An unknown `id` is a no-op that returns the
 * SAME input reference.
 *
 * @param {Todo[]} todos
 * @param {string} id
 * @returns {Todo[]}
 */
export function remove(todos, id) {
  if (!todos.some((t) => t.id === id)) return todos; // unknown id => same reference
  return todos.filter((t) => t.id !== id);
}

/**
 * filter — return a VIEW of the todos for a filter mode. `all` returns the same
 * reference (no copy needed for the identity view). `active`/`done` return a new
 * filtered array. Any unknown mode is treated as `all`. Never throws.
 *
 * @param {Todo[]} todos
 * @param {('all'|'active'|'done'|string|undefined)} mode
 * @returns {Todo[]}
 */
export function filter(todos, mode) {
  switch (mode) {
    case 'active':
      return todos.filter((t) => !t.done);
    case 'done':
      return todos.filter((t) => t.done);
    case 'all':
    default:
      return todos; // unknown/undefined mode degrades to `all` (never throw)
  }
}

/**
 * activeCount — the number of not-done todos, for the live-region "N remaining" phrasing.
 *
 * @param {Todo[]} todos
 * @returns {number}
 */
export function activeCount(todos) {
  let n = 0;
  for (const t of todos) {
    if (!t.done) n += 1;
  }
  return n;
}

/**
 * serialize — wrap the todos in the `{version, todos}` envelope and stringify. Items
 * are emitted in canonical field order so the serialized form is stable.
 *
 * @param {Todo[]} todos
 * @returns {string} JSON string of `{version:1, todos}`.
 */
export function serialize(todos) {
  /** @type {Envelope} */
  const envelope = {
    version: CURRENT_VERSION,
    todos: todos.map((t) => ({ id: t.id, text: t.text, done: t.done, created: t.created })),
  };
  return JSON.stringify(envelope);
}

/**
 * deserialize — TOTAL FUNCTION. Parse a persisted string back to a valid `Todo[]`.
 *
 * Every input maps to a valid array and NEVER throws:
 *   - `null`/`undefined` (absent key)      -> `[]`  (never `JSON.parse(null)`)
 *   - malformed JSON (`{not json`)          -> `[]`  (SyntaxError swallowed)
 *   - valid JSON, wrong shape               -> `[]`  (via migrate + SHAPE_GUARD)
 *     (`null`, `42`, `"s"`, `{}`, `[{}]`)
 *   - future/unknown version                -> `[]`  (forward-unreadable)
 *   - ANY item mistyped (all-or-nothing)    -> `[]`  (ADR 1, Option B)
 *   - a well-formed v1 envelope             -> the canonical `Todo[]`
 *
 * @param {string | null | undefined} str
 * @returns {Todo[]}
 */
export function deserialize(str) {
  if (str === null || str === undefined) return []; // absent key — never JSON.parse(null)
  if (typeof str !== 'string') return []; // defensive: non-string input

  /** @type {unknown} */
  let parsed;
  try {
    parsed = JSON.parse(str);
  } catch {
    return []; // malformed JSON (SyntaxError) — total function contract
  }

  const migrated = migrate(parsed);
  // migrate returns `[]` for unreadable input, or an envelope for readable input.
  if (Array.isArray(migrated)) return SHAPE_GUARD(migrated); // `[]` stays `[]`
  return SHAPE_GUARD(migrated.todos);
}
