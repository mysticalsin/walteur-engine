# WALTEUR — Full-Stack Production & Security Map (§14 × the 11-point baseline)

The point of this map: a build is **not** just a frontend. WALTEUR takes the whole production
reality into account — **frontend, APIs, backend logic, database, auth, hosting, cloud, CI/CD,
security/RLS, rate limiting, caching, load-balancing, error tracking, availability/recovery** —
and every layer is **owned or signed-deferred** (`production-layers-gate.sh` on `layers.json`),
with a gate that enforces it and a security practice that hardens it. "Build fast — don't ship naked."

Sources folded in: the 13-layer "Full-Stack Production Reality" (M003), the backend-inclusive
workspace cheatsheet (M004, `src/services/{api,auth,database}.ts` + `tests/{unit,integration,e2e}`),
the 11-point hardening checklist (M005), and OWASP/pentest methodology from CyberStrike (M006).

## The 13 layers → what enforces them → what hardens them

| # | §14 Layer | Scaffold / artifact | Gate(s) that enforce it | Security baseline check(s) |
|---|---|---|---|---|
| 1 | **Frontend** | `src/components/*`, `DESIGN.md` | design-gate · frontend-budget · browser-proof · **measured-quality** (Lighthouse+axe) · a11y-content-lint · anti-slop-ui | `security_headers` · `captcha_cors` · `no_frontend_secrets` |
| 2 | **APIs & Backend Logic** | `src/services/api.ts` | contract-gate · api-contract · tool-contract-lint · schema-lint · **test-layer-coverage** (e2e) | `server_side_validation` · `owasp_review` · `no_frontend_secrets` |
| 3 | **Database & Storage** | `src/services/database.ts` | migration-lint · migration-proof · migration-roundtrip · schema-lint · restore-proof | `rls` (Row-Level Security) |
| 4 | **Auth & Permissions** | `src/services/auth.ts`, `src/components/auth/*` | **authz-tenant-gate** (deny-by-default, least-privilege, negative tests) | `auth_failure_tests` · `rls` |
| 5 | **Hosting & Deployment** | `scripts/deploy.sh`, infra | sdlc-run-gate · operate-readiness | `security_headers` |
| 6 | **Cloud & Compute** | IaC (`*.tf`/cdk) | iac-scan · production-layers-gate | — |
| 7 | **CI/CD & Version Control** | `ci.github-actions.yml` | sdlc-run-gate · release-gate · release-ledger-lint | (secrets scan in CI: security-gate) |
| 8 | **Security & RLS** | — | **security-gate** (gitleaks) · osv-gate · sbom-gate · ai-safety-gate · **security-baseline-gate** · **integration-proof** | `rls` · `owasp_review` · `no_data_leaks` · `privacy_legal` |
| 9 | **Rate Limiting** | API middleware | edge-protection (§14 L9) | `rate_limits` (cap every paid-API endpoint) |
| 10 | **Caching & CDN** | CDN config | edge-protection (§14 L10) | — |
| 11 | **Load Balancing & Scaling** | infra | production-layers · operate-readiness · perf-gate · frontend-budget | — |
| 12 | **Error Tracking & Logs** | Sentry (P11) | observe-lint | `safe_error_messages` (generic to users; full server-side) |
| 13 | **Availability & Recovery** | backups, DR runbook | restore-proof · migration-roundtrip · operate-readiness (RTO/RPO/DR) | — |

## The 11-point security baseline (M005) — enforced by `security-baseline-gate.sh`

Required per build signal; each **verified** (evidence) / **signed-deferred** (owner+ticket; not at
risk high/regulated) / **not-applicable** (reason). HARD on *addressed*; correctness is PROTOCOL
(security QA + `org-secure-coding-checklist` + an OWASP pentest such as **CyberStrike** — 120+
OWASP cases, 8 proxy testers: IDOR, authz-bypass, injection, SSRF, mass-assignment).

| # | Practice | Required when | Layer |
|---|---|---|---|
| 1 | **Privacy/GDPR-CCPA** — policy + know where user data lives | db/auth/pii/external | L8 |
| 2 | **RLS** — policies on every table (DB not readable from DevTools) | has_db | L8/L3 |
| 3 | **Auth failure-path tests** — wrong-pw×5, reset unknown email, double verify, signup existing | has_auth | L4 |
| 4 | **Security headers + baseline** | ui/external | L1/L5 |
| 5 | **OWASP review** — SQLi, XSS, auth | external/api | L8 |
| 6 | **Server-side validation** (client validation is UX, not security) | api boundary | L2 |
| 7 | **No data leaks** — .env in frontend, over-returning APIs, secrets in logs | ui/api/external | L8 |
| 8 | **No frontend secrets** — API keys server-side/proxied | has_ui | L2/L4 |
| 9 | **Rate limits** on every paid-API endpoint | api/payments | L9 |
| 10 | **CAPTCHA on public forms + CORS locked** | ui + external | L1/L8 |
| 11 | **Safe error messages** — generic to users, full server-side | external/api | L12 |

## How a build proves it took all of this into account

1. **Preflight** detects signals (has_ui, has_api_boundary, has_db, has_auth, has_payments, external_surface) → commits the right skills (incl. `org-secure-coding-checklist`).
2. **Plan** writes `layers.json` — every one of the 13 layers in-scope (owned) or out-of-scope (signed reason); `production-layers-gate` enforces it.
3. **Build** scaffolds the backend (`services/api.ts` · `auth.ts` · `database.ts`) + tests at every layer.
4. **Verify/Ship** — `ship-gate.sh` runs the per-layer gates above **plus** `security-baseline-gate.sh`; a naked build (no RLS, keys in frontend, no rate limits, leaky errors…) **cannot ship**.
5. **Audit** — the terminal Opus auditor records any completeness/security FAIL as a critical shortfall; `certified` requires none.
