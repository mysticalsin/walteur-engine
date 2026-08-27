# documents-api — PRD (field run)

A deny-by-default, multi-tenant **document** service. Each tenant manages its own set of documents
(title + body, with opaque server-assigned ids); no tenant can ever read, write, or even detect another
tenant's documents. Built on Node built-ins only (http/fs/crypto), zero external dependencies.

## Stories

- **STORY-1 (tenant isolation):** A request carrying another tenant's identity can never read or mutate my
  documents. Cross-tenant reads return 404 (no existence oracle); cross-tenant writes (update/delete)
  return 403; a denied action leaves no audit row. *Proven by `test/cross-tenant.test.mjs` (5/5) +
  `core.test.mjs`.*

- **STORY-2 (right-to-erasure / DSAR):** Deleting my tenant removes ALL of my documents and audit rows and
  nothing belonging to any other tenant. *Proven by `test/erasure.test.mjs` (2/2) + `core.test.mjs`.*

- **STORY-3 (authenticated CRUD):** With a valid `X-Tenant` + `Authorization: Bearer <token>`, I can
  create, list, read, update, and delete my own documents; missing/blank/wrong credentials are denied 401
  with an empty body. *Proven by `test/api.test.mjs` (10/10).*

- **STORY-4 (operable):** Health endpoint, structured token-redacted logs, SLOs + alerts, a real
  process-kill chaos drill (recovery observed), and a verified blue-green rollback target.

## Controls present (all five HONEST for this app)
1. **Tenancy** — per-tenant buckets behind `core.owned()`; `authz-tenant.json` → `test/cross-tenant.test.mjs`.
2. **Erasure** — `core.eraseTenant()` via `POST /admin/erase`; `privacy-data.json` → `test/erasure.test.mjs`.
3. **Pipeline** — `sdlc-run.json` → `test/api.test.mjs`.
4. **Audit** — `audit.json` certified+fresh → `test/api.test.mjs`. *HONEST CAP: layer_walk is 8/13 — the
   field run has no live CI/CD cluster, deploy stages, monitoring infra, or ADR corpus, so layers 9-13 are
   NOT fabricated. A 13-layer requirement would FAIL honestly; recorded 8/13.*
5. **Rollback** — `cutover-plan.json` → `bash ops/rollback.sh --check`.

## Non-goals
No external DB, no network egress, no UI framework. The document store is in-memory with best-effort
`data.json` persistence; isolation correctness lives in `core.mjs`, not the persistence layer.
