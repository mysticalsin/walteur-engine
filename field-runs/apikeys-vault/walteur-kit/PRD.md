# apikeys-vault — PRD (field run)

A deny-by-default, multi-tenant **API-key vault**. Each tenant issues, lists, rotates, and revokes its own
API keys; no tenant can ever read, rotate, revoke, or even detect another tenant's keys. The CARDINAL rule:
a freshly minted **raw key is shown exactly once** at issue (and once again on rotate) and is then
unrecoverable — the vault stores only a **sha256 hash + last4 + timestamps**, never the raw secret. Built on
Node built-ins only (http/fs/crypto), zero external dependencies.

## Stories

- **STORY-1 (tenant isolation):** A request carrying another tenant's identity can never read, rotate, or
  revoke my keys. Cross-tenant reads return 404 (no existence oracle); cross-tenant rotate/revoke return
  403; a denied action leaves no audit row. *Proven by `test/cross-tenant.test.mjs` (6/6) + `core.test.mjs`.*

- **STORY-2 (write-once secret):** The raw key is returned exactly once (issue/rotate response) and is never
  stored, never returned by `GET /keys`, and never written to a log line or `data.json`. The store holds
  `sha256(raw)` + last4 only. *Proven by `core.test.mjs` (raw-never-stored, snapshot-has-no-raw) +
  `test/api.test.mjs` (list/get carry no raw) + a live-run scan of `data.json` and logs.*

- **STORY-3 (real rotation):** Rotating a key mints new material, replaces the stored hash (invalidating the
  prior credential), bumps `rotatedAt`, and writes a `rotate` audit row. A revoked key cannot be rotated
  (409). *Proven by `test/rotation.test.mjs` (4/4) + `core.test.mjs` (rotate-changes-hash).*

- **STORY-4 (right-to-erasure / DSAR):** Deleting my tenant removes ALL of my key records and audit rows and
  nothing belonging to any other tenant. *Proven by `test/erasure.test.mjs` (2/2) + `core.test.mjs`.*

- **STORY-5 (authenticated lifecycle):** With a valid `X-Tenant` + `Authorization: Bearer <token>`, I can
  issue, list, read, rotate, and revoke my own keys; missing/blank/wrong credentials are denied 401 with an
  empty body. *Proven by `test/api.test.mjs` (12/12).*

- **STORY-6 (operable):** Health endpoint, structured token/key-redacted logs, SLOs + alerts, a real
  process-kill chaos drill (recovery observed), and a verified blue-green rollback target.

## Controls present (all five HONEST for this app) + a 6th executor

1. **Tenancy** — per-tenant buckets behind `core.owned()`; `authz-tenant.json` -> `test/cross-tenant.test.mjs`.
2. **Erasure** — `core.eraseTenant()` via `POST /admin/erase`; `privacy-data.json` -> `test/erasure.test.mjs`.
3. **Pipeline** — `sdlc-run.json` -> `test/api.test.mjs`.
4. **Audit** — `audit.json` certified+fresh -> `test/api.test.mjs`. *HONEST CAP: layer_walk is 8/13 — the
   field run has no live CI/CD cluster, deploy stages, monitoring infra, or ADR corpus, so layers 9-13 are
   NOT fabricated. A 13-layer requirement would FAIL honestly; recorded 8/13.*
5. **Rollback** — `cutover-plan.json` -> `bash ops/rollback.sh --check`.
6. **Test-layer coverage** — `test-coverage.json`: logic=`core.test.mjs`, integration=`test/api.test.mjs`,
   component=`test/rotation.test.mjs`, e2e=`test/cross-tenant.test.mjs` — fires as a 6th EXECUTOR under
   `WALTEUR_TEST_LAYERS_EXEC=1` (each recorded_command re-run, observed exit 0).

## Secret-rotation, exercised meaningfully

Key lifecycle IS the domain, so `ops/secrets-policy.json` carries both the app's env-injected control-plane
secrets AND a substantive `issued_key_rotation_policy` (90-day max age, rotate/revoke endpoints, hash-only
at rest, a `rotation_proof` command). The secret-rotation gate's perl scan finds ZERO committed key literals
because every key is `crypto.randomBytes`-minted at runtime and stored as a hash; bearer tokens are
env-injected.

## Non-goals
No external DB, no network egress, no UI framework. The vault is in-memory with best-effort `data.json`
persistence (hashes only); isolation + the write-once-secret invariant live in `core.mjs`, not the
persistence layer.
