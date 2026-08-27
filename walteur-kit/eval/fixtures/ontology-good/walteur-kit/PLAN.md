# Plan — billing run

A monthly job that turns each Tenant's usage into an Invoice.

## Goals

- For each Tenant, gather every OrderLine for the period and total it.
- Render one Invoice per Tenant and post the movement to the Ledger.
- The TenantOrg alias and a stray "order line" mention both resolve to known entities.

## Out of scope

- No tax computation in v1 (named non-goal — deferred to v2).

## Success metric

- Billing-run latency: baseline 9 min today; target p95 <= 3 min over a 30 day window.

## Acceptance criteria

- Given a Tenant with OrderLine rows When the run executes Then exactly one Invoice is produced.
- Given the Invoice When it is finalised Then the Ledger records the movement.

## Tasks

- T1 — collect every OrderLine for the Tenant.
- T2 — render the Invoice and post to the Ledger.
