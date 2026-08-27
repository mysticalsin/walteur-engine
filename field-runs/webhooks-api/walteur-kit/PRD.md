# webhooks-api — PRD (field run)

A deny-by-default, multi-tenant **webhook-subscription** service. Each tenant registers HTTPS delivery
endpoints for platform events; no tenant can ever read, write, rotate, or even detect another tenant's
subscriptions. Built on Node built-ins only (http/fs/crypto), zero external dependencies.

## Stories

- **STORY-1 (tenant isolation):** A request carrying another tenant's identity can never read or mutate my
  subscriptions, nor rotate my signing secret. Cross-tenant reads return 404 (no existence oracle);
  cross-tenant writes (update/rotate/delete) return 403; a denied action leaves no audit row.
  *Proven by `test/cross-tenant.test.mjs` (6/6) + `core.test.mjs`.*

- **STORY-2 (right-to-erasure / DSAR):** Deleting my tenant removes ALL of my subscriptions and audit rows
  and nothing belonging to any other tenant. *Proven by `test/erasure.test.mjs` (2/2) + `core.test.mjs`.*

- **STORY-3 (secret shown once, never stored raw):** On create and on rotate-secret the HMAC signing
  secret (`whsec_…`) is returned to the caller exactly once; the store keeps only a `sha256` fingerprint +
  last4, so `data.json` (and any backup) holds zero recoverable signing secrets. *Proven by the
  secret-handling tests in `core.test.mjs` + `test/api.test.mjs`, and by a live `data.json` scan finding no
  `whsec_` value.*

- **STORY-4 (safe delivery targets):** A delivery URL must be a valid `https` URL whose host is not
  loopback/private/link-local (SSRF guard), and the event type must be on the platform allow-list;
  anything else is rejected 400. *Proven by the validation tests in `core.test.mjs` + `test/api.test.mjs`.*

- **STORY-5 (authenticated CRUD):** With a valid `X-Tenant` + `Authorization: Bearer <token>`, I can
  create, list, read, update, rotate-secret, and delete my own subscriptions; missing/blank/wrong
  credentials are denied 401 with an empty body. *Proven by `test/api.test.mjs` (11/11).*

- **STORY-6 (operable):** Health endpoint, structured token+secret-redacted logs, SLOs + alerts, a real
  process-kill chaos drill, and a verified blue-green rollback target.

## Controls present (all five HONEST for this app)
1. **Tenancy** — per-tenant buckets behind `core.owned()`; `authz-tenant.json` → `test/cross-tenant.test.mjs`.
2. **Erasure** — `core.eraseTenant()` via `POST /admin/erase`; `privacy-data.json` → `test/erasure.test.mjs`.
3. **Pipeline** — `sdlc-run.json` → `test/api.test.mjs`.
4. **Audit** — `audit.json` certified (8/13 layers, honest `known_gaps`) → `test/api.test.mjs`.
5. **Rollback** — `cutover-plan.json` → `bash ops/rollback.sh --check`.

## Non-goals
No external DB, no network egress (the service does NOT actually deliver webhooks — it manages
subscriptions), no UI framework. The subscription store is in-memory with best-effort `data.json`
persistence; isolation correctness lives in `core.mjs`, not the persistence layer. Because there is no
delivery, the raw signing secret is never retained after the one-time reveal — strengthening the secret
story rather than weakening it.
