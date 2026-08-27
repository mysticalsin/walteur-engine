# PRD — Multitenant Tasks

## Problem
Teams sharing one task service must never see each other's tasks. A single isolation bug leaks one
customer's roadmap to another. The build must make cross-tenant access impossible by construction and
prove it by execution, not assertion.

## Story
STORY-1: As an authenticated tenant, I can create, list, complete, and delete only my OWN tasks, and a
request carrying another tenant's identity can never read or mutate my rows. Deny-by-default: any missing
or mismatched credential is rejected with 401 and no body; any cross-tenant write is 403 and any
cross-tenant read is 404 with no data leak.

STORY-2: As a data subject, I can exercise GDPR right-to-erasure: deleting my tenant removes all of my
tasks and audit rows and nothing belonging to any other tenant.

## Acceptance
- Auth chokepoint requires `X-Tenant-Id` + `Authorization: Bearer <token>`; tokens are env-injected only.
- Cross-tenant isolation is enforced by core.mjs `owned()` and proven by `test/cross-tenant.test.mjs`.
- Right-to-erasure is proven by `test/erasure.test.mjs`.
- The full HTTP pipeline is proven by `test/api.test.mjs`.
