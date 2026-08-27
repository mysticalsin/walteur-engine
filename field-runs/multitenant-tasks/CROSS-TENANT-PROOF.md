# multitenant-tasks — executable authz proof (field run)

A deliberately small but **real** multi-tenant app built to exercise the harness and produce an
*execution-backed* authz proof — the exact thing the adversarial audit said WALTEUR's gates assert but
never run.

## The invariant (deny-by-default tenant isolation)
- `get(tenantB, taskOfA)` → `null` (cross-tenant **read** denied; no existence/content leak)
- `complete/remove(tenantB, taskOfA)` → throws `forbidden` (cross-tenant **write** denied)
- `list(tenant)` only ever returns that tenant's rows

## How it's proven (not asserted)
- `core.test.mjs` runs the invariant across many tenants/ids: **`node --test` → 6/6 pass.**
- `walteur-kit/test-claim.json` records the command, and **`test-claim-verifier-gate` RE-RUNS it** at gate
  time — a falsified claim (broken command) makes the gate exit 2. So the green is reproduced, not trusted.

## Harness reaction observed (2026-06-28)
| Gate | Behavior | Result |
|---|---|---|
| `test-claim-verifier-gate` | re-ran `node --test` against the live source | PASS (claim reproduced, exit 0) |
| `test-claim-verifier-gate` (negative control) | re-ran a falsified command | FAIL exit 2 (real teeth) |
| `gate-suite` | 128-gate regression incl. the new skip-budget | recorded in STAMP.md |

This is the field-mile pattern in miniature: a real artifact, a real test, a gate that **executes** the
claim. Scaling it to a full $50-100M product is Phase 2 of the ultra roadmap; this proves the mechanism works.
