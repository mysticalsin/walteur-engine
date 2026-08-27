# PLAN — Accessible Zero-Dependency Todo SPA (engine-todoapp)

## Definition of Done

- `node --test` runs green with zero third-party deps installed (empty node_modules; only Node built-ins node:test + node:assert/strict used); `npm ls --all` shows an empty dependency tree.
- App is fully operable by opening index.html directly via file:// AND via any static server — no build step, no npm install required to run.
- Every action (add / toggle / edit / delete / filter all|active|done) is operable by keyboard alone: Tab order is logical, Enter adds/commits edit, Escape cancels edit and restores focus to the edit trigger, Space/Enter activates toggle/delete/filter.
- Screen-reader state is correct and announced: form control is labelled, toggle uses native checkbox semantics, active filter exposes aria-pressed (or aria-current), and exactly one persistent role=status live region announces terse state+count on every mutation (never recreated, single text-node child).
- Tasks persist across reload via localStorage using a {version:1, todos:[...]} envelope; the loader NEVER throws on any input (absent key, malformed JSON, wrong shape null/42/"str"/{}/[{}]) and always resolves to a valid todo array.
- state.js is a DOM-free, side-effect-free ES module importable by node:test with no jsdom/shim; storage.js takes the storage adapter and idFactory as FUNCTION PARAMETERS (never a module-top-level global reference to window/localStorage).
- node:test suite covers: add, toggle, edit, delete, filter (all/active/done), serialize/deserialize round-trip (deepStrictEqual on a canonical fixture), deterministic IDs via injected idFactory stub, and every persistence failure/shape-guard edge case above via an in-memory storage stub the project owns (~5 lines, no third-party mock).
- README documents setup/run (no-install), the Node LTS target (24.x actively tested, engines >=22 floor), and an explicit Accessibility Notes section (keyboard map table + ARIA rationale) matching the shipped markup byte-accurately.
- Machine-readable proof reports are emitted even on a green build: test-layer-coverage.json and a11y-contract.json (and a deps-baseline.json asserting zero deps), so the auditor's FAIL path is real and auditability parity with sibling builds holds.
- No secret/key/PII in any client file or log; all doc code examples (function signatures) grep-match the shipped source byte-for-byte; WCAG 2.2 AA-oriented (contrast, focus visible, labels) verified by code review — no framework, bundler, transpiler, or third-party runtime/dev dependency anywhere.

## Design Doc

# Design Doc — Accessible Zero-Dependency Todo SPA

## 1. Problem & success

A keyboard-and-screen-reader user manages a personal task list in a single browser tab. Success is precise and testable: **every** action (add / toggle / edit / delete / filter all|active|done) is operable by keyboard alone with correct **announced** ARIA state; tasks survive reload via `localStorage`; and a `node:test` suite over the **pure** state logic passes green **with zero third-party dependencies** (runtime AND dev). The app runs by opening `index.html` — no install, no build.

Non-negotiable constraints that shape every decision below:
- **Zero deps, runtime and dev.** `node:test`/`node:assert/strict` are Node built-ins → the dependency tree stays empty. No jsdom, no framework, no bundler, no transpiler, no third-party test mock.
- **Pure logic must be DOM-free.** The state module imports under `node:test` with no shim. This forces a ports-and-adapters split.
- **Runs from `file://`.** ES modules + `localStorage` only; no build artifact.

## 2. Architecture — ports & adapters (the load-bearing decision)

Three source layers, strictly ordered by purity. This is not ceremony — it is the only shape that satisfies "pure logic testable under node:test with zero deps."

```
state.js      PURE. Plain arrays/objects. Zero I/O, zero localStorage/window reference.
   ^            add . toggle . edit . remove . filter . serialize . deserialize . SHAPE_GUARD
   |            idFactory injected as a param (defaults to crypto.randomUUID).
storage.js    IMPURE-CAPABLE but PARAMETERIZED. load(key, adapter) / save(key, todos, adapter).
   ^            The adapter ({getItem,setItem}) is a FUNCTION PARAMETER - never a module-top-level global.
   |            load() try/catches everything and ALWAYS returns a valid array. save() never assumes success.
app.js        IMPURE. The only layer that touches the DOM and passes real window.localStorage - in ONE place.
index.html    Semantic markup + one persistent live region + <script type=module src=app.js>.
```

**Why the injection is at the function signature, not module load:** if `storage.js` read `localStorage` at module top-level, `import`-ing it under `node:test` throws `ReferenceError` the instant the test file loads — `window`/`localStorage` do not exist in Node. Passing the adapter as a parameter means `state.js` and `storage.js` import cleanly in Node; the test passes a ~5-line in-memory Map-backed stub it owns (satisfies "no third-party mock"); the browser passes `window.localStorage` exactly once in `app.js`. **This is the single most likely build mistake — the storage worker's failing test must assert import-under-node succeeds.**

**Determinism:** `add(todos, text, idFactory = crypto.randomUUID)` — tests inject an incrementing stub (`() => 'id-' + (n++)`) so add/toggle/edit/delete assertions are exact. No global mocking of `crypto`.

## 3. Data model (the DATA/PERSISTENCE layer)

There is no SQL tier, so the "data model" is the persisted JSON schema + its integrity guards. These are treated with the same rigor as table constraints.

**Persisted envelope** (the one localStorage key `todos.v1`):
```
{ "version": 1, "todos": [ Todo, ... ] }
```
**Todo record** (fields constrained to JSON-round-trip-safe primitives only — string/boolean/number, NO Date objects, to avoid serialize drift):

| field     | type    | invariant (the "constraint")                                        |
|-----------|---------|---------------------------------------------------------------------|
| `id`      | string  | non-empty, unique within the array (the "primary key")              |
| `text`    | string  | trimmed, non-empty (empty commit === delete, per TodoMVC)           |
| `done`    | boolean | strictly `true`/`false` (never truthy coercion)                     |
| `created` | number  | epoch ms; used only for stable ordering                             |

**Integrity is enforced by a runtime SHAPE_GUARD, not just try/catch** — because `JSON.parse` can *succeed* and still yield garbage. The guard is the equivalent of `NOT NULL` + type `CHECK` + `Array.isArray`:
- reject non-array top-level (`null`, `42`, `"str"`, `{}`) via `Array.isArray(parsed.todos)`;
- reject any item missing/mistyped `id`(string,non-empty) / `text`(string) / `done`(boolean) → item dropped or whole load rejected → `[]`.

**"Migrations" (reversible, no destructive drift):** the `version` field is the migration spine. `deserialize` branches on `version`; an unknown/older version routes through a pure `migrate(raw)` step (v0 bare-array → v1 envelope is the shipped example). Renaming a field later (`done`→`completed`) becomes a one-line version branch, **not** silent data loss misread as "malformed." Forward-unknown (version > current) → treat as unreadable → `[]` (never crash, never half-write).

**Failure modes (every one has an owning test):**
1. Absent key → `getItem` returns `null` → loader returns `[]` **without** `JSON.parse(null)` (which yields `null` and silently collides with case 3).
2. Malformed JSON (`{not json`) → `SyntaxError` caught → `[]`.
3. Valid JSON, **wrong shape** (`null`, `42`, `\"s\"`, `{}`, `[{}]`) → SHAPE_GUARD → `[]`. *(The commonly under-scoped case; mandatory.)*
4. `QuotaExceededError` on `setItem` → `save()` catches, returns `{ok:false, reason}`, does not throw; app surfaces a non-blocking status.
5. Round-trip: `deepStrictEqual(deserialize(serialize(x)), x)` on a canonical fixture.

## 4. Internal API contract (the API-CONTRACT layer)

The pure module's signatures **are** the contract — typed by JSDoc, validated at the boundary, immutable-by-convention (every mutator returns a **new** array; inputs are never mutated, so the caller controls persistence timing).

| function | signature | typed error / edge behavior |
|---|---|---|
| `add` | `(todos, text, idFactory?) -> todos'` | `text` trimmed; empty → returns `todos` unchanged (no phantom item) |
| `toggle` | `(todos, id) -> todos'` | unknown `id` → returns `todos` unchanged (no throw) |
| `edit` | `(todos, id, text) -> todos'` | trimmed empty → **removes** the item (TodoMVC contract); unknown id → unchanged |
| `remove` | `(todos, id) -> todos'` | unknown id → unchanged |
| `filter` | `(todos, mode) -> todos_view` | `mode in {all,active,done}`; unknown mode → treated as `all` (never throw) |
| `serialize` | `(todos) -> string` | wraps in `{version:1,todos}`; stable field order |
| `deserialize` | `(string|null) -> todos` | **total function** — every input maps to a valid array, never throws |
| `activeCount` | `(todos) -> number` | for the live-region "N remaining" phrasing |

Error taxonomy is deliberately **"never throw on bad input"**: pure functions degrade to a no-op on unknown ids/modes; the persistence boundary degrades to `[]`/`{ok:false}`. There is no 500-equivalent — a UI must never be bricked by corrupt storage.

## 5. Accessibility contract (the FRONTEND/UX layer) — WCAG 2.2 AA-oriented

Reference base: prefer **native semantic HTML5 over ARIA** wherever native suffices (the 2026 "ARIA anti-patterns" correction — APG has no todo pattern; do not bolt `role=listbox/grid` onto a list). ARIA is added only where native semantics are dropped or insufficient.

**Markup:**
- `<h1>` app title; `<form>` with a **labelled** `<input>` (visible `<label>` or `aria-label`) + submit `<button>`.
- Task list: plain `<ul>`/`<li>`. Add `role="list"` **defensively** on the `<ul>` — Safari strips list semantics when `list-style:none` is set via CSS, and VoiceOver then won't announce it as a list.
- Per item: native `<input type="checkbox">` (toggle, native checked-state announcement), the label text, native `<button>` for Edit and for Delete. Per-item `aria-label="Edit {title}"` / `"Delete {title}"` — **unique per item**, not generic.
- Filters: three `<button>`s with `aria-pressed` reflecting the active filter (`aria-current="true"` is the acceptable alternative; pick one and document it). Native buttons → free keyboard activation.

**Live region (get this exactly right — most common a11y bug here):**
- **Exactly one** visually-hidden element with `role="status"` (implies `aria-live="polite"` + `aria-atomic="true"`), **present from initial page load**, **never removed/recreated** — only `textContent` overwritten. Its only child is a single text node (no nested markup, or NVDA over-announces structure).
- Terse **state + count** phrasing: `Task added, 4 remaining.` — never restate full item text, never append/accumulate.
- Debounce ~150-200 ms for bulk mutations. Never pair `aria-live="assertive"` with `role="alert"` (double-announce on VoiceOver/iOS). Conditionally mounting the region loses the FIRST announcement on several AT pairs — hence always-present-but-empty.

**Focus management (each is a testable behavior in the a11y-contract):**
- **Add:** after submit, clear input, keep focus in the input (rapid entry).
- **Toggle:** no focus move (native checkbox).
- **Delete:** redirect focus to a `tabindex="-1"` heading/anchor **above** the list — never to the next/prev sibling (ambiguous as items renumber). If the list is now empty, focus the add input. This heading-anchor pattern needs no empty/first/last edge-case branching.
- **Edit:** swap label → `<input type="text">` in the **same** DOM slot, prefilled with current text, autofocus + select-all on entry; Enter commits, Escape cancels and restores focus to the item's Edit button (never leaves focus stranded on a removed node).

**Visual / contrast:**
- Focus-visible outline on every interactive element (never `outline: none` without a replacement); text contrast >= 4.5:1 normal / 3:1 large; hit targets sized for pointer + touch; strike-through/done styling is not the sole signal (checkbox state + `aria-checked` carries it).

## Layout (source layers)

```
field-runs/engine-todoapp/
  index.html
  app.js
  state.js
  storage.js
  styles.css
  README.md
  test/
    state.test.js
    storage.test.js
    a11y-contract.test.js (static/markup assertions, no jsdom)
  test-layer-coverage.json
  a11y-contract.json
  deps-baseline.json
  package.json (name, engines>=22, no dependencies/devDependencies, "type":"module", test script -> node --test)
```
