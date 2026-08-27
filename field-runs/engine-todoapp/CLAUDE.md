@AGENTS.md

## Claude-specific advisory notes

- When editing `state.js` or `storage.js`, run a mental (or actual) `node --test` check before declaring
  a task done — these two files are the ones most likely to accidentally acquire a top-level
  `window`/`localStorage`/`document` reference, which breaks import under `node:test` silently until the
  test file is actually run. Don't assume; run it.
- Do not add a `package.json` `"dependencies"` or `"devDependencies"` block for convenience (e.g. a test
  runner, a linter, a formatter). The zero-dep tree is a Definition-of-Done invariant enforced by
  `deps-baseline.json`, not a soft preference.
- When writing the `role="status"` live region logic in `app.js`, prefer overwriting `textContent` on the
  existing node over any pattern that removes/re-creates the element — re-creation loses the first
  announcement on several screen-reader/browser pairs (see PLAN.md §5).
- If asked to "add a feature" beyond PLAN.md's six tasks (e.g. drag-to-reorder, due dates, tags), flag the
  scope change explicitly rather than silently expanding `state.js`'s surface — the Todo record's fields
  are deliberately constrained to JSON-round-trip-safe primitives only (PLAN.md §3).
- The three proof JSON reports (`test-layer-coverage.json`, `a11y-contract.json`, `deps-baseline.json`) are
  Definition-of-Done deliverables, not optional extras — do not skip emitting them just because the tests
  are green.
