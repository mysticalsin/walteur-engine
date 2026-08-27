# AGENTS.md — engine-todoapp

## 1. Project overview

A zero-dependency, accessible single-page todo app: semantic HTML5 + vanilla ES modules + `localStorage`,
with add/toggle/edit/delete/filter(all|active|done), full keyboard operability, and correct ARIA
live-region announcements. A `node:test` suite covers the pure state logic; the app runs by opening
`index.html` directly — no build step, no install.

**Success metric (real, from PLAN.md Definition of Done):** every action (add/toggle/edit/delete/filter)
is operable by keyboard alone with correctly announced ARIA state, tasks survive reload via `localStorage`,
and `node --test` runs green with an empty dependency tree (`npm ls --all` shows zero deps).

## 2. Commands

No `package.json` exists yet (this is a fresh scaffold — the build tasks create it). Per PLAN.md §Layout,
the shipped `package.json` MUST declare:

```jsonc
{
  "name": "engine-todoapp",
  "type": "module",
  "engines": { "node": ">=22" },
  "scripts": { "test": "node --test" }
  // no "dependencies", no "devDependencies" — zero-dep is a Definition-of-Done invariant
}
```

- Run tests: `node --test`
- Run the app: open `index.html` directly in a browser (`file://`) — no server required. A static server
  (e.g. `npx serve .`) also works but is optional, never mandatory.
- Verify zero-dep invariant: `npm ls --all` must show no entries.

# TODO: confirm exact test script name once package.json is committed by the build tasks — do not invent
additional scripts (no `build`, no `lint`, no `dev` server script unless PLAN.md tasks add one).

## 3. Code style

Stack-specific idiom for this project (ports-and-adapters, PLAN.md §2):

- `state.js` is **pure** — no DOM, no `window`, no `localStorage` reference anywhere, even at module
  top-level. Every mutator returns a **new** array; never mutate the input in place.
- `storage.js` takes the storage adapter and `idFactory` as **function parameters**, never as a
  module-top-level global reference. This is what lets `state.js`/`storage.js` `import` cleanly under
  `node:test` (no `window`/`localStorage` exists in Node — a top-level reference throws `ReferenceError`
  the instant the test file loads).
- `app.js` is the **only** file that touches the DOM and passes the real `window.localStorage` — in one
  place only.

Real signature shape from PLAN.md §4 (mirror this pattern for all mutators):

```js
// state.js
export function add(todos, text, idFactory = crypto.randomUUID) {
  const trimmed = text.trim();
  if (!trimmed) return todos; // empty commit => no-op, never a phantom item
  return [...todos, { id: idFactory(), text: trimmed, done: false, created: Date.now() }];
}
```

- Prefer native semantic HTML over ARIA roles wherever native semantics suffice (no `role="listbox"` or
  `role="grid"` bolted onto the task list — there is no ARIA APG "todo" pattern).
- No framework, bundler, or transpiler import anywhere in shipped source — a stray `import` from `node_modules`
  is a Definition-of-Done violation, not a style nit.

## 4. Testing

Framework: Node built-in `node:test` + `node:assert/strict` only (no jsdom, no third-party mock/stub lib).
File naming and coverage from PLAN.md §Layout / Definition of Done:

- `test/state.test.js` — add, toggle, edit, delete, filter(all/active/done), serialize/deserialize
  round-trip (`deepStrictEqual` against a canonical fixture), deterministic IDs via an injected incrementing
  `idFactory` stub (never mock global `crypto`).
- `test/storage.test.js` — every persistence failure/shape-guard edge case (absent key, malformed JSON,
  wrong shape: `null`/`42`/`"str"`/`{}`/`[{}]`) via an in-memory storage stub the project owns (~5 lines,
  no third-party mock). Must assert **import-under-node succeeds** — this is the single most likely build
  mistake per the design doc (a top-level `localStorage` reference breaks this).
- `test/a11y-contract.test.js` — static markup assertions (no jsdom): labelled input, native checkbox
  toggle, `aria-pressed`/`aria-current` on filter buttons, single persistent `role="status"` live region.

Run: `node --test`. All three suites must pass green with the dependency tree empty.

## 5. Security

Constraints from scope (this is a fully client-side, single-tab, single-user app — no server, no network
calls, no auth):

- No secret/key/PII in any client file or log — there is no backend to leak credentials for, but the
  `localStorage` payload itself must stay limited to the `Todo` shape (id/text/done/created) — never store
  anything beyond that envelope.
- `deserialize` is a **total function**: every input (including adversarial/corrupted `localStorage`
  content) maps to a valid array, **never throws**. Treat any parsing/shape code as a trust boundary even
  though the "attacker" is just corrupted local state, not a remote actor.
- No `eval`, no `innerHTML` with unescaped user `text` (todo text must be inserted via `textContent` or
  equivalent-safe DOM API to avoid self-XSS via a pasted todo string).

## 6. Commit / PR

Conventional commits (`feat:`, `fix:`, `test:`, `docs:`, `chore:`). Example: `feat(state): add pure add/toggle/edit/remove mutators`.

## 7. §14 Production-layer ownership (scoped to THIS request)

This is a static, single-user, client-only SPA with no server, no network I/O, and no multi-tenant surface.
Most infra layers are out of scope by design — do not scaffold folders for them.

| Layer | Scope | Owner | Folder | Focus |
|---|---|---|---|---|
| 1. Frontend | IN-SCOPE | Accessible Frontend Builder | `/` (index.html, app.js, styles.css) | Semantic HTML5 + keyboard/ARIA-correct todo UI |
| 2. APIs & Backend Logic | OUT-OF-SCOPE (no server; `state.js`/`storage.js` are in-process pure/adapter modules, not an API tier) | — | — | — |
| 3. Database & Storage | IN-SCOPE (browser `localStorage` only, no SQL/server DB) | Pure State-Logic Builder | `/` (storage.js) | `{version:1, todos:[...]}` envelope, load/save with total-function shape-guard |
| 4. Auth & Permissions | OUT-OF-SCOPE (single local user, no accounts, no session) | — | — | — |
| 5. Hosting & Deployment | OUT-OF-SCOPE (opens via `file://` or any static host; no deploy pipeline owned by this project) | — | — | — |
| 6. Cloud & Compute | OUT-OF-SCOPE (no cloud resources — everything runs in the browser) | — | — | — |
| 7. CI/CD & Version Control | OUT-OF-SCOPE for this task (no CI workflow requested in PLAN.md tasks; `node --test` is run locally/manually) | — | — | — |
| 8. Security & RLS | OUT-OF-SCOPE (no rows, no server, no RLS surface; XSS-safe rendering handled under Frontend) | — | — | — |
| 9. Rate Limiting | OUT-OF-SCOPE (no network endpoint to rate-limit) | — | — | — |
| 10. Caching & CDN | OUT-OF-SCOPE (no server assets to cache/CDN-front) | — | — | — |
| 11. Load Balancing & Scaling | OUT-OF-SCOPE (single-tab client app, no concurrent-request surface) | — | — | — |
| 12. Observability & Logs | OUT-OF-SCOPE (no server/log aggregation; machine-readable proof reports — test-layer-coverage.json, a11y-contract.json, deps-baseline.json — cover build-time verification instead) | — | — | — |
| 13. Availability & Recovery | IN-SCOPE (narrow: reload-survival + corrupt-storage recovery is the only "availability" surface) | Pure State-Logic Builder | `/` (storage.js) | `deserialize` never throws; corrupt/absent/malformed storage always resolves to a valid `[]` |

**Roster referenced above:** Pure State-Logic Builder (state.js/storage.js), Accessible Frontend Builder
(index.html/app.js/styles.css), node:test Suite Author (test/*.test.js), Accessibility & Docs Verifier
(README a11y notes + markup-vs-doc byte match, proof JSON reports).
