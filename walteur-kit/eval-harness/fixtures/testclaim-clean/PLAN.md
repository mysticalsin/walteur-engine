# Plan — Checkout Discount Fix

## Tasks
- T1 fixes FR-88 — `applyDiscount` must take a *percentage* off the order total
- T2 keeps `calculateTotal` (line items + tax) covered by regression tests

## Status
Agent reported the fix complete and the full test suite passing (see
`walteur-kit/qa-report.json`, recorded_command `npm test`). This time the claim is
true: `npm test` was actually run before the PASS verdict was written, and
re-running it reproduces the same green result — exactly what
test-claim-verifier-gate is supposed to let through.
