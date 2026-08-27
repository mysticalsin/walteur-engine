# WALTEUR UPGRADE — 2026-06 (8.5 → 10)

Build-ready tracking surface for the upgrade. The human narrative lives in
`Improvement Walteur.md`; this file is the **machine-tracked fix table** — each row carries the
file that implements it, the acceptance test that proves it *real*, the evidence artifact, and a
verdict. Companion plan: `C:\Users\Tony\.claude\plans\snazzy-spinning-flask.md`.

- **Canonical version:** v9.78 (`Pro Coding/WALTEUR-builder-CLAUDE.md`).
- **Date:** 2026-06-27 · **Owner:** Tony.
- **Verdict legend:** `PROVEN` (evidence on disk this session) · `PAPER-ONLY` (spec claims it; no
  runtime evidence yet) · `IN-PROGRESS` · `OPEN` (not implemented).

## Top-line rollup

| Verdict | Fixes |
|---|---|
| PROVEN (this session) | **F2 skill auto-routing**, **F7 completeness gates**, F0 env pre-flight |
| IN-PROGRESS | F1 model routing (artifact done) |
| PAPER-ONLY | F3 DoD, F4 no-silent-truncation, F5 current-stack, F6 context provenance |
| OPEN | — |

Both red cells are now built and proven by selftest this session — F2 (skill auto-routing, was
4/10) and F7 (completeness, was 6/10). What remains is mechanical: register the new gates in
`gate-registry.json` (+ `release-ledger.json` counts), reconcile the v8.5 skill to v9.78, and run
the Phase-3 re-audit to flip the PAPER-ONLY rows to PROVEN with cited runtime evidence.

## Definition of full potential (the bar for a 10)

- Every integration **live-wired-and-proven or signed-deferred** — none silently mock.
- **Automated tests at every layer** (logic + component + E2E) that actually run.
- Quality **measured** (Lighthouse/axe artifacts), not claimed.
- The **right skill fired at the right step, logged**.
- **Model routing logged per phase** (Opus on judgment, Sonnet on bulk).
- The loop **stops on a real DoD**, not "it builds."

## Fix table

| Fix | On-paper | Implementing file(s) | Acceptance test (proves REAL) | Evidence artifact | Verdict |
|---|---|---|---|---|---|
| **F0 — Env pre-flight (jq/AV/CRLF)** _(new finding, this session)_ | n/a | `bootstrap.sh` (fold-in TODO); local fix: `C:\Users\Tony\bin\jq` CR-strip wrapper + winget jq | A gate `--selftest` reaches full pass on native Windows bash | `release-ledger-lint.sh --selftest` → **12/12** (was 11/12) | **IN-PROGRESS** (locally PROVEN; bootstrap fold-in pending) |
| **F1 — Model routing** | §0a Rule 0 table | `model-routing.json` (CREATED 2026-06-27), `scaffold/harness-init.sh` (now emits it), `walteur.js` per-phase model log (TODO) | A run log shows BUILD=sonnet, REVIEW+AUDIT=opus — no Opus-on-everything | `model-routing.json` exists; per-phase `model` log pending | **IN-PROGRESS** |
| **F2 — Skill auto-routing** | IMPLEMENTED 2026-06-27 | `skill-index.json` (190 skills) + `skill-index-build.mjs` + `skill-index-lint.sh` (7/7); `skill-router.mjs` (10/10); `skill-readiness.sh` routing cross-check (12/12); `walteur.js` Preflight phase | DONE: a regulated UI+API build auto-commits 9 required skills; gate returns FAIL (rc2) before they run, PASS (rc0) after | `skill-routing.json` + `required-skills.json` (router-generated); `skill-readiness-report.json` | **PROVEN (spine)** — full runtime confirm in Phase-3 re-audit |
| **F3 — Real DoD** | Closed — `definition-of-done-gate.sh` + `audit-contract-gate.sh` | `walteur-kit/hooks/definition-of-done-gate.sh`, `DEFINITION-OF-DONE.md` | Report PASS; every checked item carries a validated `Evidence:` ref; zero placeholders | `definition-of-done-report.json` | **PAPER-ONLY** → confirm in re-audit |
| **F4 — No silent truncation** | Closed — `walteur.js` blast-radius keeps all severities | `walteur-starter/.claude/workflows/walteur.js` | Inject a low + high severity finding; assert findings-in == findings-out | `qa-report.json` + injected fixture | **PAPER-ONLY** (needs fixture) |
| **F5 — Env pre-flight (current-stack)** | Closed — `current-stack-gate.sh` + `bootstrap.sh` | `walteur-kit/hooks/current-stack-gate.sh` | Run-date proof dated BEFORE first BUILD commit | `current-stack-report.json` | **PAPER-ONLY** → confirm |
| **F6 — Context provenance** | Closed — `context_sentinel`, `harness-state-lint.sh` | `walteur.js` STATE writer, `harness-state-lint.sh` | Sentinel valid, lint PASS, responses prefixed "Tony," | `harness-state-report.json` + `_relay/BATON.md` | **PAPER-ONLY** → confirm |
| **F7 — Completeness / full potential** | BUILT 2026-06-27 | `integration-proof-gate.sh` (13/13) · `measured-quality-gate.sh` (9/9) · `test-layer-coverage-gate.sh` (11/11) · `schemas/integrations.schema.json` · wired into `ship-gate.sh` + 3 DoD lines + audit shortfalls | DONE: 6-mock Hermes build exits 2 naming all 6 mocks; a11y/perf must be MEASURED (Lighthouse+axe); E2E must be a re-runnable command. All new gates are safe no-ops on bare/non-applicable projects | `integration-proof-report.json`, `measured-quality-report.json`, `test-layer-coverage-report.json` | **PROVEN (gates)** — runtime confirm in re-audit |
| **F8 — Security & production hardening** _(from M005/M006)_ | BUILT 2026-06-27 | `security-baseline-gate.sh` (12/12) + `schemas/security-baseline.schema.json` + `scaffold/security-baseline.template.json` (embeds your hardening prompts) + `PRODUCTION-SECURITY-MAP.md` (§14 × 11). Wired: ship-gate · DoD · registry (81) · auditor | A naked SaaS (auth+db+ui+api, no baseline) exits 2 listing all 11 required checks (RLS · OWASP · headers · rate limits · CAPTCHA/CORS · safe errors · no leaks · server-side validation · privacy · no frontend secrets · auth failure-path tests). Each practice mapped to a §14 production layer | `security-baseline-report.json` | **PROVEN** |

## Scorecard (retro run #1 → target → current)

| Dimension | Run #1 | Target | Now |
|---|---|---|---|
| Multi-agent orchestration | 9.5 | 10 | 9.5 |
| Verify-before-done | 9 | 10 | 9 |
| Guardrails / ethics | 9 | 10 | 9 |
| Spec quality | 8.5 | 10 | 8.5 |
| **Skill/tool utilization** | **4** | **10** | **8** (F2 spine proven; runtime confirm pending) |
| **Completeness / full potential** | **6** | **10** | **8** (no-mocks + measured a11y/perf + E2E layer all gated) |
| Model routing clarity | 6 | 10 | 7 (`model-routing.json` now real) |
| Context hygiene | 7 | 10 | 7 |

## Done this session

- **F0 (env pre-flight):** diagnosed + fixed the Windows gate toolchain — jq via winget, a CR-stripping wrapper (`C:\Users\Tony\bin\jq`), CRLF root-caused. Proven: `release-ledger-lint --selftest` 11/12 → 12/12.
- **F1 (model routing):** created `walteur-kit/model-routing.json` (faithful to §0a Rule 0); `harness-init.sh` now emits it on every scaffold (selftest 80/80). Per-phase model already logged via `walteur.js` `emitSpan`.
- **F2 (skill auto-routing — the headline 4/10):** built the full spine —
  - `skill-index.json` (190 Org skills, signal-tagged) + `skill-index-build.mjs` generator + `skill-index-lint.sh` drift guard (selftest 7/7).
  - `skill-router.mjs` — signals → committed skill set, discipline-gated (selftest 10/10).
  - `skill-readiness.sh` — added a routing cross-check + data-driven verdict so an **empty PASS on a build that needs a skill now FAILS** (selftest 9→12/12).
  - `walteur.js` — new `phase('Preflight')` that runs the router between PLAN and BUILD (syntax-validated); scaffold ships the index + tools to every project.
  - **End-to-end proof:** a regulated UI+API build auto-commits 9 required skills; the gate returns FAIL (rc2) before they run and PASS (rc0) after they stamp breadcrumbs.
- **F7 (completeness — the 6/10):** three new HARD gates, all proven by selftest, all wired:
  - `integration-proof-gate.sh` (13/13) — no integration may silently mock; must be live-wired-and-proven, signed-deferred (owner+ticket), or a time-boxed low/medium-risk prototype. **Proof:** the exact run-#1 build (Supabase, MS Graph, Cal.com, Teams, Twenty CRM, n8n) now exits 2 naming all 6 silent mocks.
  - `measured-quality-gate.sh` (9/9) — a UI build must ship real Lighthouse (categories ≥ threshold) + axe (`violations:0`) artifacts; "couldn't measure" FAILs, not skips.
  - `test-layer-coverage-gate.sh` (11/11) — logic + component + E2E each need a re-runnable command at exit 0; a claimed E2E pass with no command FAILs.
  - Wired: `ship-gate.sh` dispatch (+ `skill-readiness` + `skill-index-lint`), 3 Evidence-bearing DoD lines, and the terminal auditor now records any completeness FAIL as a critical shortfall. All 5 new gates verified as safe no-ops on bare/non-applicable projects.
- **F8 · Security & production hardening (your 11-point checklist, M005):** built `security-baseline-gate.sh` (12/12) enforcing privacy/GDPR · RLS · auth failure-path tests · security headers · OWASP review · server-side validation · no data leaks · no frontend secrets · rate limits · CAPTCHA+CORS · safe error messages — required per build signal, each **verified / signed-deferred** (not deferrable at high/regulated risk) **/ N-A**. Ships a schema + a fillable template embedding your exact hardening prompts. Wired into ship-gate + DoD + registry (81 gates) + the auditor. **Proof:** a naked SaaS (auth+db+ui+api) exits 2 listing all 11 checks. Plus `PRODUCTION-SECURITY-MAP.md` mapping the **13 §14 layers × the 11 practices × the gates** — the framework now provably accounts for the full backend/API/production reality (M003/M004); CyberStrike (M006) cited as the OWASP pentest companion.
- **Version reconciliation (one canonical harness):** regenerated the stale **v8.5** starter skill to **v9.78** (byte-identical to the canonical builder); re-pointed starter `CLAUDE.md` off "11 Pillars" → "13 Pillars". Registered all 4 new gates in `gate-registry.json` (76→80) + bumped `release-ledger.json` count; verified gate-registry-lint PASS on the real registry and harness-init 80/80.
- Authored the materials intake lane (`materials/INDEX.md`), this roadmap, and the retro postscript.
- **Capstone re-audit (gate level):** built a realistic web-app project shape and ran the full new-gate sweep both ways — a **full-potential build PASSES all 5 gates** (9 skills auto-committed) and an **under-shipped build** (silently-mocked integration + unmeasured a11y + no E2E + a skipped skill — run #1's exact failure mode) is **BLOCKED by all 4**. The upgrade's thesis, proven end-to-end on a real project shape.

## Round 2 — verification, live proof, hardening (after "is this the best?")

Honest answer was *no* — the gates mostly checked **attestation** (an artifact exists), not **correctness**. Closed the highest-leverage gaps:

- **Verification, not attestation:** `integration-proof-gate` now actually RUNS a `proof.probe_command` (network tools allowed, destructive refused) — a "live-wired" integration whose probe doesn't respond FAILS (17/17). `security-baseline-gate` now does THREE real machine checks over attestation (16/16, all proven on planted cases): scans client source for exposed secrets (leaked Stripe/Google key → FAIL), and scans SQL/migrations for **Row-Level Security** (tables but no `ENABLE ROW LEVEL SECURITY`/`CREATE POLICY` → FAIL — the multi-tenant "naked DB" that leaks every customer at $50M+ ARR).
- **Proved it LIVE:** scaffolded a real software/high-risk SaaS, a **real LLM agent ran the Preflight prompt** → produced correct 9 signals on disk → the router committed the right skills → all 3 gates BLOCKED demanding the work. The Preflight→router→gates integration is validated end-to-end with a real model (not fixtures). This is what `walteur.js` does at `/goal` time minus the rest of the loop.
- **Hardened:** the live run + a `pipefail` audit exposed real bugs — two `func | grep -q` SIGPIPE false-negatives (security scan never fired; measured-quality UI-detection silently failed) now fixed with regression tests; router precision tightened (6 vs 9 required skills, no `brainstorming`/`socratic-build`/`model-risk` noise); the **Windows jq self-heal folded into `bootstrap.sh`** (detects MINGW, winget-installs jq, writes a self-finding CR-strip shim) so any Windows box works without a manual bandage.

## Enterprise $50–100M ARR backlog (the 12h loop's target list)

Goal: WALTEUR can one-shot a SaaS that survives **$50–100M ARR** — layer by layer, no corner-cutting. A parallel `enterprise-readiness-audit` workflow (8 dimensions: multi-tenancy · enterprise auth · billing integrity · scale/perf · observability/SLO · reliability/DR · compliance/governance · security depth) ranks the gaps. Each loop iteration: read this list → take the top item → build it with twin selftests → verify green → update this list. Use subagents/Workflow for parallel work.

Backlog from the `enterprise-readiness-audit` workflow (9 Opus agents, 2026-06-27), ranked by severity × leverage / effort. Status: ⬜ todo · ✅ done.

| # | St | Dim | Gap | Build (WALTEUR idiom) | Sev | Eff |
|---|---|---|---|---|---|---|
| 1 | ✅ | Security depth | 9/11 security-baseline checks pass on a hand-written "verified" string (headers, CORS, rate-limit, validation, errors…) | active scans in security-baseline: header_scan (CSP/HSTS/X-CTO), cors_scan (ACAO:`*`), ratelimit_scan (no 429) — a miss overrides attestation | high | M |
| 2 | ✅ | Multi-tenancy | No ACTIVE cross-tenant leakage probe — the #1 SaaS bug (tenant A reads tenant B) was never executed | `cross-tenant-probe-gate.sh` (10/10): runs a real two-tenant attack (auth as A, fetch B, require deny); refuses self-cert when tenant cols exist | **crit** | M |
| 3 | ✅ | Billing | No webhook signature-verify / idempotency; no outbound Idempotency-Key → double-charge / forged events | `billing-integrity-gate.sh` (8/8): scans webhook handlers for signature+event-id dedupe; fails money-create calls w/o idempotencyKey | **crit** | M |
| 4 | ✅ | Ent. auth | SCIM deprovisioning zero coverage — terminated employee keeps access | `lifecycle-access-gate.sh` (10/10): manifest + active disable→401 revocation probe; deprovisioning not deferrable at high/regulated risk | **crit** | L |
| 5 | ✅ | Reliability/DR | No backup cadence/retention/PITR + no serving-tier redundancy | `backup-policy-gate.sh` (9/9): per-datastore cadence/retention/PITR/offsite/encryption + cadence-vs-RPO cross-check · `redundancy-topology-gate.sh` (10/10): no customer-facing single-region+single-AZ+<2-replica SPOF tier | **crit** | L |
| 6 | ✅ | Compliance | Data residency unenforced (silent SKIP) — a hard MSA breach | `residency-gate.sh` (8/8): manifest required_regions + per-store/subprocessor region + active IaC region-literal scan | **crit** | M |
| 7 | ✅ | Compliance | No periodic access-review / recertification (SOC2 CC6) | `access-review-gate.sh` (9/9): cadence ≤90d + fresh last-review + scope (human+service principals) + signoff | **crit** | M |
| 8 | ✅ | Ent. auth | SSO unmodeled (Golden-SAML / audience-confusion → account takeover) | `sso-gate.sh` (10/10): requires signature+audience+time-window+replay controls, each verified by a malicious-assertion probe (→403); not deferrable at high risk | **crit** | L |
| 9 | ⬜ | Multi-tenancy | `tenant_surface` self-certified false despite tenant_id columns in source | authz-tenant cross-check: tenant cols present + attested false → FAIL (cheapest high-leverage) | med | S |
| 10 | ✅ | Scale | Load test never *required* to run (tool-absent → SKIP) | `load-proof-gate.sh` (9/9): requires a fresh (≤14d) load run with achieved p99 ≤ budget at a declared target RPS + VUs on every critical path; mandatory at high/regulated | **crit** | L |
| 11 | ✅ | Audit trail | Audit-log integrity attestation-only across 3 gates | `audit-trail-gate.sh` (8/8): manifest (immutability + ≥365d retention + actor/tenant/ts/action) + active scan (privileged action w/ no audit emit → FAIL) | high | M |
| 12 | ✅ | Multi-tenancy | `scan_rls` blind to ORM schemas (Prisma/Drizzle/TypeORM) + `USING(true)` no-ops | extend scan_rls: detect ORM tenant tables w/o RLS session-var → FAIL; flag `USING(true)` | **crit** | M |
| 13 | ✅ | Security | Ordinary CVEs pass when scanner absent; no DAST | `cve-gate.sh` (11/11): fail-closed on unexpired CRITICAL/HIGH CVE + missing-scan-at-high-risk + signed time-boxed exceptions; `dast-gate.sh` (10/10): fresh ZAP/Burp scan of the deployed surface, fail on High/Critical | high | M |
| 14 | ✅ | Observability | Async distributed tracing never audited | `async-trace-lint.sh` (10/10): async-trace.json enumerates every producer→consumer hop; requires W3C traceparent injected on the producer + extracted on the consumer (optional live probe); broken propagation not deferrable at high/regulated | high | M |
| 15 | ✅ | Reliability/Scale | No circuit-breaker / DLQ / connection-pool-ceiling | `resilience-async-gate.sh` (11/11): resilience.json outbound-dep circuit-breaker+timeout + connection-pool ceiling (Σ instances·pool ≤ db_max_connections) + async-jobs.json per-job DLQ+idempotency_key; not deferrable at high/regulated | high | M |

## Build-depth pivot (v10.0 — the framework must BUILD the full $50–100M infra deep + clean, not just gate it)

> Tony's bar: understand the concept → set the baseline → go SUPER deep into the details, zero AI slop, "as if coding for Anthropic." Two levers: ENFORCE (the 96 gates + `anti-slop-code-gate`) and PRODUCE (the build agents themselves go deep).

| # | Depth lever | Status | What landed |
|---|---|---|---|
| D1 | Per-§14-layer specialist build prompts | ✅ | `walteur.js`: `LAYER_DEPTH` map (auth · data/RLS · api · payments · async · observability · infra · frontend) + `layerFor(task)` router; each implementer's brief now carries its layer's full "build the FULL layer" spec (real migrations+RLS+indexes; idempotency+webhook-sig+reconciliation; DLQ+trace-context; WCAG AA states; …). Token-aware (≤2 matched blocks). `node --check` ✓, router spot-checked ✓ |
| D2 | DESIGN / architecture-depth pass (plan decomposes each layer to real depth before Build) | ✅ | PRODUCE: planner prompt now demands a "### Layer depth: <layer>" section per touched layer (using `LAYER_CATALOG`, lifted above `phase('Plan')` as single source of truth) + names data model/API surface/failure modes/NFRs explicitly, and decomposes the DAG so each non-negotiable is owned by a task. ENFORCE: `design-depth-gate.sh` (8/8) — for each flagged signal (has_auth/has_db/has_payments/has_async/has_api_boundary/has_ui/is_cloud_iac) checks the design-of-record shows that layer's depth; fail-closed at high/regulated, advisory below. `node --check` ✓. 97 gates |
| D3 | Thread the craft bar through reviewer + audit prompts (not just the implementer) | ✅ | `walteur.js`: `CRAFT_REVIEW` const (single source) injected into all 7 governance-panel senior reviewers AND the terminal fresh-Opus auditor — slop/happy-path-only (TODO/placeholder/stub/`as any`/empty-catch/missing edge+error handling/unvalidated input/missing authz/no-idempotency) is now a VETO/CRITICAL shortfall, not a nit; auditor also reads anti-slop-code + design-depth reports. Craft bar now spans implementer→review→certify. `node --check` ✓ |
| D4 | Adversarial gauntlets (≤40 agents) on the new gates → regression selftests | 🔄 | In progress, gate-by-gate (tally below). |

### D4 gauntlet tally
| Gate | Agents | Proven misses | Fixes shipped | Result |
|---|---|---|---|---|
| `anti-slop-code-gate` | 14 | **14 / 14** (every agent found a hole) | widened INC to 50+ extensions (.c/.cpp/.tf/.scala/.ex/.dart/.lua/.html/…); stopped excluding shipping dirs (scripts/, migrations/); perl **multiline** empty/comment-only/bare-return **swallowed-catch** detector; added `console.log` scan (was promised, never implemented); broadened todo (`TO DO`/`FIX ME`), ai-slop synonyms (`not yet built`/`real logic goes here`/`incomplete:`/`hardcoded backdoor`), stub-cred variants (`REPLACE_WITH`/`<paste-here>`/`tbd`), type-escape (`@ts-expect-error`, `as  any` multi-space, `type X = any` alias) → **14 G-regressions** | **26/26 selftest** + 6 exact-fixture reproductions exit 0→2 + 5 false-positive guards exit 0. Holes empirically closed. |
| `cve-gate` | 12 | **11 / 12** (only the post-dated scan was caught) | added a severity **normalization engine** — trims whitespace (`HIGH `), derives from numeric **CVSS** (≥9→CRITICAL/≥7→HIGH), maps vendor synonyms (Important/Sev1/P0/blocker), reads `.Severity`/`.level`/`.rating`, and treats empty/unknown severity on a real CVE as **UNKNOWN→fail-closed** at high/regulated; **multi-shape parser** (WALTEUR/npm-audit-object/Trivy/Grype/osv-nested); reject **future-dated** scans; widened dep-surface to **lockfiles** (pnpm/poetry/Gemfile/go.sum/…); **cap exception expiry** ≤365d (no 2099 placeholders) → **14 G-regressions** | **25/25 selftest** + 3 exact-fixture reproductions exit 0→2 + 2 false-positive guards exit 0. Holes empirically closed. |
| `sso-gate` | 12 | **7 / 12** (5 manifest-shape defenses already held) | **probe runner made fail-closed** — a trivial no-op (`true`/`:`/`echo`/`test`), an off-allowlist / non-existent script, a whitespace probe, or a probe that asserts **no rejection** (401/403/deny) no longer counts as "verified" (was a silent pass); **duplicate control entries** rejected (order can't defeat `head -1`); widened SSO-surface detection to .cs/.rb/.php/.scala/… → **6 G-regressions** | **16/16 selftest** + 3 exact-fixture reproductions exit 0→2 + FP guard. Holes empirically closed. |
| _probe-bypass propagation_ | — | shared root cause | the fail-closed `run_probe` (reject trivial / off-allowlist / whitespace + assert the right OUTCOME) was propagated to **cross-tenant-probe** (deny/403), **lifecycle-access** (401/revoked), **async-trace** (traceparent/propagation), and **integration-proof** (real round-trip, not `true`). Each got real selftest probes + G-regressions | **cross-tenant 14/14 · lifecycle 14/14 · async-trace 14/14 · integration-proof 18/18**; registry PASS; all bare-dir no-ops. 5 gates' active verification now has teeth. |
| `resilience-async-gate` | 12 | **7 / 12** (fail-OPEN arithmetic) | the pool-ceiling math now coerces via jq `tonumber` and **fails CLOSED** when instances/pool/ceiling aren't valid numbers (was: `"4"`/`"100 "`/fractional → jq error → swallowed → check skipped → PASS); dlq must be a real queue **name** (not `true`/`yes`/sentinel); idempotency_key must be **boolean true**; jobs/services object-shapes fail-closed; widened async-surface detection → **8 G-regressions** | **19/19 selftest** + 3 exact fixtures exit 0→2 + FP guard (string nums within ceiling still PASS). |
| `dast-gate` | 5 (suite) | **5 / 5** | severity **normalization engine** (trim/casing, ZAP `riskdesc "High (Medium)"`→HIGH, numeric `riskcode`, reads `.Risk`/`.severity_level`, unknown→fail-closed at high); **multi-shape** parser (flat `.alerts[]` + ZAP-native `.site[].alerts[]`); reject **future-dated** scans; **cap exception expiry** ≤365d → **6 G-regressions** | **16/16 selftest** + FP guard (informational-only still PASS). |
| _suite gauntlet (35 agents)_ | 24 ran (11 rate-limited) | **20 misses** | ran resilience + suite **concurrently → 47 agents → throttled** (lesson: serialize big gauntlets). Remaining to harden: **design-depth** (5 — bare substring grep, needs section+body+polarity rewrite), backup-policy (2), load-proof (2), access-review (2), residency (3), redundancy (1) — plus a serialized re-gauntlet of the rate-limited gates | resilience + dast done above; rest queued. |

**Already strong** (audit-confirmed — don't rebuild): the attestation-override scan pattern (secrets+RLS) · osv-gate MAL-* supply-chain · schema-lint money-precision · integration-proof active probe runner · restore-proof DR drill + migration-roundtrip · deny-by-default authz-tenant · privacy-data GDPR spine · ai-tool-governance · perf-gate p99/p999 · operate-readiness manifest · resilience-lint timeouts/jitter · SBOM + observe-lint discipline.

**Self-improvement engine:** a **300-agent adversarial gauntlet** (red-team agents build a vuln + run the real gate + report caught/MISSED) found **43 PROVEN false-negatives** in the secret/RLS scans; the top 12 are fixed with `G1–G12` regression selftests (security-baseline now **30/30**). Lesson: batch ≤40 agents (300-at-once hit the API rate limit). This gauntlet + the 12h `/loop` cron are the self-improving loop.

**Done so far:** verification-not-attestation (integration round-trip probe · secret scan now covers config/data/browser-roots/JWT/service-account/exposure-vector · RLS scan covers raw SQL + ORM + account/org/customer discriminators + dead-comment decoys + client-trusted predicates · headers/CORS/rate-limit) · **enterprise gates: billing-integrity (8/8) + audit-trail (8/8)** wired into ship-gate + DoD + registry (83 gates).

## Remaining (clear next increments)

1. **Phase 3 (orchestrator re-audit)** — the only piece needing a **live `/goal` run** (the Workflow runtime; `walteur.js` can't run standalone). Run `field-runs/support-risk-command-center` (or a fresh Hermes-like build) under the upgraded engine to capture the per-phase model log, the skill-preflight report, the live-vs-deferred integration manifest, and measured Lighthouse/axe — flipping the PAPER-ONLY rows (F3/F4/F5/F6) → PROVEN with cited runtime evidence. The gates that *check* this evidence are already proven (above); this run produces the evidence.
2. **Perf follow-up** — `release-ledger-lint.sh` hangs on the big canonical tree on Windows (per-line jq over the 281KB skill/builder). Batch the proof-claim scan. Normal builds are unaffected (a fresh project's ledger is absent → instant NOT_APPLICABLE).

## Sequencing

1. **Phase 0** (now): reconcile versions (F1 cont.), this roadmap, materials lane. _(in progress)_
2. **Phase 1:** skill auto-routing engine (F2) — the biggest lever.
3. **Phase 2:** completeness engine (F7) — co-headline.
4. **Phase 3:** prove-it re-audit on `field-runs/support-risk-command-center` — flip PAPER-ONLY → PROVEN with cited evidence; fill the `Now` scorecard column.
