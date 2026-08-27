# Plan — Checkout Discount Fix

## Tasks
- T1 fixes FR-88 — `applyDiscount` must take a *percentage* off the order total
- T2 keeps `calculateTotal` (line items + tax) covered by regression tests

## Status
Agent reported the fix complete and the full test suite passing (see
`walteur-kit/qa-report.json`, recorded_command `npm test`). Merging on that claim
without re-running it is exactly the failure mode test-claim-verifier-gate exists
to catch: the recorded command was never actually executed before the PASS verdict
was written.
