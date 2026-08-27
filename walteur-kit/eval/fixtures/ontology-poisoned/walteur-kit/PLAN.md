# Plan — billing run

A monthly job that turns each Tenant's usage into an Invoice.

## Goals

- For each Tenant, gather every OrderLine for the period and total it.
- A Subscription drives the Invoice cadence and a PaymentGateway captures funds.
- Render one Invoice per Tenant and post the movement to the Ledger.

## Out of scope

- No tax computation in v1 (named non-goal — deferred to v2).

## Success metric

- Billing-run latency: baseline 9 min today; target p95 <= 3 min over a 30 day window.

## Acceptance criteria

- Given a Tenant with OrderLine rows When the run executes Then exactly one Invoice is produced.
- Given a Subscription When the cadence fires Then the PaymentGateway is charged.

## Tasks

- T1 — collect every OrderLine for the Tenant.
- T2 — render the Invoice and post to the Ledger.
