# WALTEUR — Gate Remediation Guide ("a gate failed, now what?")

The panel's usability gap: gates print *what* failed but not *how to fix it*. This is the one-page
answer. Every gate also self-documents: `bash walteur-kit/hooks/<gate>.sh --help` and
`--selftest` (proves the gate itself works). Reports land in `walteur-kit/<gate>-report.json` — read
the `reason` field first.

## Fast triage
1. Run the meta-suite: `bash walteur-kit/hooks/gate-suite.sh` — it names every broken gate.
2. For a named gate, open `walteur-kit/<gate>-report.json` and read `reason`.
3. Find the gate below (`Ctrl+F "## <gate-id>"`) → apply the fix → re-run that one gate
   (`bash walteur-kit/hooks/<gate>.sh`).
4. A gate that SKIPs for a missing tool is **cannot_measure**, not a pass — install the tool (jq, perl, node)
   and re-run.

## Full gate index (every id in `walteur-kit/gate-registry.json`, one row per gate)

Each row below follows the same shape: **Enforces** (what the gate checks, from its own header contract) ·
**Common failure** (the most frequent real-world FAIL cause) · **Fix** (the exact command/file to touch) ·
**Bypass** (the `WALTEUR_<NAME>=off` env var, when one exists). A logged bypass is still logged — it is a
recorded, auditable skip, never a silent pass. Gates with no documented bypass (`phase-gate`, `evidence-gate`,
core invariants) have none by design.

## build-contract-lint
Enforces: `walteur-kit/build-contract.json` is well-formed typed intake for the build.
Common failure: the contract file is malformed JSON, or missing while `gate-registry-lint` expects it.
Fix: validate with `jq . walteur-kit/build-contract.json`; fix the JSON syntax or classification fields; if the build genuinely has no contract yet, this gate is NOT_APPLICABLE (no action needed).
Bypass: `WALTEUR_BUILD_CONTRACT_GATE=off` — bypass is recorded, not free.

## gate-registry-lint
Enforces: `gate-registry.json` is valid and required gates (per the build contract's class/risk) are declared.
Common failure: registry malformed, or a build-contract risk tier requires a gate id that is absent from the registry.
Fix: `jq . walteur-kit/gate-registry.json` to find the syntax break; add the missing required gate entry (copy an existing entry's shape).
Bypass: `WALTEUR_GATE_REGISTRY=off` — bypass is recorded, not free.

## estimate-gate
Enforces: an upfront time/token/cost estimate exists and its budgets match runtime STATE.
Common failure: `STATE.json` exists (build started) but `walteur-kit/estimate.json` was never written, or the estimate is a zero/placeholder past intake.
Fix: author `walteur-kit/estimate.json` with real (non-zero) budget figures before advancing past intake; make sure `STATE.json` budgets match the estimate's expected values.
Bypass: `WALTEUR_ESTIMATE_GATE=off` — bypass is recorded, not free.

## current-stack-gate
Enforces: planning used current, dated, sourced stack facts (not stale training-data assumptions).
Common failure: `walteur-kit/current-stack.json` missing at plan/build stage, or its run-date/sources are stale/weak, or a stack drift was detected but never acknowledged.
Fix: web-scout the current official docs for the chosen stack, write `current-stack.json` with a fresh run date + real source URLs, and acknowledge any drift explicitly in the file.
Bypass: `WALTEUR_CURRENT_STACK=off` — bypass is recorded, not free.

## harness-state-lint
Enforces: `walteur-kit/autopilot/STATE.json`, when present, is well-formed and carries the enterprise loop fields.
Common failure: STATE.json hand-edited into an invalid shape, or missing a required loop field.
Fix: `jq . walteur-kit/autopilot/STATE.json`; restore the required fields per the harness-state schema.
Bypass: `WALTEUR_HARNESS_STATE=off` — bypass is recorded, not free.

## phase-gate
Enforces: the harness loop's phases advance in order (no skipping intake→plan→build→verify→review→ship→reflect).
Common failure: STATE.json's phase field was hand-set out of order, or advanced without the prior stage's evidence.
Fix: correct `STATE.json`'s phase to the next legitimate step, and ensure the prior phase's gates actually PASSed first — do not jump ahead.
Bypass: none — this gate has no `WALTEUR_*=off` switch by design (it is a core ordering invariant). Kill switch: `walteur-kit/PAUSED` still forces exit 2, never a way around the check.

## evidence-gate
Enforces: evidence entries in STATE.json actually support the claims/verdicts they're attached to (not summary-only).
Common failure: an evidence entry is a bare "done"/"passed" string with no reference to a real file or command output.
Fix: replace vague evidence entries with real file/command references (`file:line`, report path, or command output) that a reader could independently verify.
Bypass: none — this gate has no `WALTEUR_*=off` switch by design (it is a core evidence-truth invariant).

## risk-acceptance-gate
Enforces: high-risk/regulated ship decisions and accepted risk gaps carry real owner signoff, not silent acceptance.
Common failure: a ship at risk_tier high/regulated with no signoff record, or an ACCEPTED_RISK/known-gap entry with no named owner.
Fix: add a signoff block (owner name + date + rationale) to the STATE risk-acceptance entry before shipping; do not silently mark a high-risk gap accepted.
Bypass: `WALTEUR_RISK_ACCEPTANCE=off` — bypass is recorded, not free.

## adr-gate
Enforces: no unresolved architecture forks at ship, and any recorded ADRs are complete (not thin one-liners).
Common failure: `debate/OPEN.json` has an unresolved fork at ship/reflect, or an ADR file lacks rejected alternatives/dissent.
Fix: close every fork in `debate/OPEN.json` (pick a decision, record why), and flesh out thin ADRs with rejected alternatives + dissent + owner in `walteur-kit/adr/INDEX.json`.
Bypass: `WALTEUR_ADR=off` — bypass is recorded, not free.

## prompt-refinement-gate
Enforces: the "improve this prompt" pass ran before planning/building (a refined brief, not the raw ask).
Common failure: `walteur-kit/prompt-refinement.json` missing at plan stage, or the refined prompt is vague / has thin acceptance criteria.
Fix: run the prompt-refinement pass and write a concrete refined brief with clear routing and acceptance criteria to `prompt-refinement.json`.
Bypass: `WALTEUR_PROMPT_REFINEMENT=off` — bypass is recorded, not free.

## enterprise-blueprint-gate
Enforces: a concrete plan-stage build target (the enterprise blueprint) exists, not a vague placeholder.
Common failure: a build signal exists (real work started) but `enterprise-blueprint.json`/`.md` is absent, placeholder, or too thin to act on.
Fix: write a concrete blueprint with real, evidence-referenced targets — not "TBD" or one-line stubs.
Bypass: `WALTEUR_ENTERPRISE_BLUEPRINT=off` — bypass is recorded, not free.

## delivery-orchestration-gate
Enforces: a typed agent-team/SDLC orchestration plan exists — roster, stage gates, coverage, worktree boundaries, audit trail.
Common failure: `delivery-orchestration.json` missing at plan stage, or present but with a weak roster / no stage gates / no worktree isolation declared.
Fix: fill in `delivery-orchestration.json` with the real agent roster, per-stage gates, coverage plan, independence/worktree boundaries, handoffs, and an audit trail.
Bypass: `WALTEUR_DELIVERY_ORCHESTRATION=off` — bypass is recorded, not free.

## ai-tool-governance-gate
Enforces: every AI/tool used in the build is inventoried, approved, and boundary-checked before ship.
Common failure: ship/reflect phase with no `ai-tool-governance.json`, or an entry missing an approval/boundary field.
Fix: enumerate every AI tool/model/MCP server the build used in `ai-tool-governance.json` with approval status and data-boundary declaration.
Bypass: `WALTEUR_AI_TOOL_GOVERNANCE=off` — bypass is recorded, not free.

## authz-tenant-gate
Enforces: real access-control/tenant-isolation proof — a probe that actually asserts a 403/404 on cross-tenant access, not a no-op.
Common failure: `cross_tenant_probe` is a trivial constant (`true`, `bash -c 'exit 0'`) that always "passes" without testing anything.
Fix: write a real probe that authenticates as tenant A, requests tenant B's resource, and asserts a deny (403/404); point `cross_tenant_probe.command` at it and arm `WALTEUR_AUTHZ_TENANT_EXEC=1`. Never weaken the check to pass.
Bypass: `WALTEUR_AUTHZ_TENANT=off` — bypass is recorded, not free.

## privacy-data-gate
Enforces: personal/sensitive/regulated data has a real lifecycle proof (erasure/DSAR actually works).
Common failure: the erasure probe is missing or is a no-op that never observed a real deletion.
Fix: implement right-to-erasure end-to-end and have the probe re-run it, observing exit 0 on the real deletion path.
Bypass: `WALTEUR_PRIVACY_DATA=off` — bypass is recorded, not free.

## sdlc-run-gate
Enforces: the full 5-stage SDLC (local_build → shared_dev → staging → beta → production) actually ran in order.
Common failure: `sdlc-run.json` missing at ship/reflect, or a stage is skipped/out of order.
Fix: record each stage's real run evidence in `sdlc-run.json` in the required order — do not skip straight to production.
Bypass: `WALTEUR_SDLC_RUN=off` — bypass is recorded, not free.

## project-context-gate
Enforces: project-specific AI context (rule files, subagent handoffs) is real and current, not generic boilerplate.
Common failure: `project-context.json` present but the context is generic, cites stale sources, or handoffs are broken.
Fix: replace generic context with project-specific rule files and verify handoff artifacts resolve; refresh stale source citations.
Bypass: `WALTEUR_PROJECT_CONTEXT=off` — bypass is recorded, not free.

## source-use-gate
Enforces: every adopted upstream source (library/code/pattern) has a valid, pinned-ref receipt with compatibility/verification/rollback.
Common failure: `source-use.json` references an unknown `source_id`, a mutable ref (branch instead of pinned SHA/tag), or an install with no verification/rollback plan.
Fix: pin the source to an exact commit/tag/version, register it in `source-manifest.json`, and record compatibility checks + a rollback plan in `source-use.json`.
Bypass: `WALTEUR_SOURCE_USE_GATE=off` — bypass is recorded, not free.

## loop-workspace-gate
Enforces: the shared loop workspace (LOG.md + signals/ + docs/ + domains/) exists when the build actually warrants an operated improvement loop.
Common failure: risk_tier high/regulated (or an ongoing-operation signal) but the loop workspace files/anchors are missing.
Fix: scaffold the loop workspace (`LOG.md`, `signals/`, `docs/`, `domains/`) with the required anchors once the build is warranted.
Bypass: `WALTEUR_LOOP_WORKSPACE=off` — bypass is recorded, not free.

## self-improvement-gate
Enforces: a compounding improvement loop ran — trace mining, current GitHub scouting, bounded proposals, regression proof, a captured learning.
Common failure: `self-improvement.json` missing at plan+ stage, or present without trace mining / current scouting / regression proof.
Fix: run `trace-mine.sh`, scout current best-practice sources, propose a bounded improvement, prove no regression, and record the learning in `self-improvement.json`.
Bypass: `WALTEUR_SELF_IMPROVEMENT=off` — bypass is recorded, not free.

## outcome-eval-gate
Enforces: an INDEPENDENT evaluator scored the outcome — rubric, evidence refs, confidence, bias checks, freshness — not a self-graded pass.
Common failure: `outcome-eval.json` PASS with no independent evaluator identity, no rubric reference, or stale evidence.
Fix: run a genuinely independent evaluation pass (a different model/persona than the builder) against a named rubric, cite real evidence, and record a confidence + bias-check note.
Bypass: `WALTEUR_OUTCOME_EVAL=off` — bypass is recorded, not free.

## qa-contract-gate
Enforces: a typed, multi-dimension QA report exists and is coherent — no VETO/FAIL lines under a claimed PASS, a safe re-runnable unit-test command, PRD coverage.
Common failure: on a code build_class, `WALTEUR_QA_EXEC` defaults ARMED and re-runs `unit_integration.recorded_command` — a no-op command (`true`, `exit 0`) is refused, or the observed exit is nonzero.
Fix: record a REAL, re-runnable unit/integration test command in the QA report and make sure it exits 0 when re-run; fill every required QA dimension; resolve any VETO/FAIL line before claiming PASS.
Bypass: `WALTEUR_QA_CONTRACT=off` — bypass is recorded, not free.

## docrun
Enforces: every fenced ```bash/sh/shell/console block across the repo's markdown actually parses (`bash -n`).
Common failure: a copy-paste doc block has a real shell syntax error (unbalanced quote, stray heredoc), or a pseudo-shell illustrative block wasn't marked skip.
Fix: fix the syntax error in the fenced block, or mark deliberately-illustrative pseudo-shell with `` ```bash walteur:skip `` or a preceding `<!-- walteur:skip -->`.
Bypass: `WALTEUR_DOCRUN=off` — bypass is recorded, not free.

## spec-lint
Enforces: `PLAN.md` has an Out-of-scope section, zero banned vagueness (TBD/TODO/etc/"handle edge cases"), a quantified success metric, and a real comparator or Given/When/Then in acceptance criteria.
Common failure: a vagueness hit like "should be scalable" or "TBD", or a success metric with no number+unit.
Fix: name a real non-goal under "## Out of scope"; replace vague adjectives with a quantified target (e.g. "p99 < 200ms"); add a Given/When/Then or comparator to at least one acceptance criterion.
Bypass: none found in this gate's own header/body — treat R1–R4 as always-on; R7 (EARS check) is warn-only by default, promote with `WALTEUR_EARS=hard`.

## spec-trace
Enforces: every `REQ-<id>` in `PLAN.md` maps to >=1 task (forward trace), every task traces to a requirement (no gold-plating), and every premortem High×High scenario has a mitigation task.
Common failure: a task was added with no `REQ-<id>` reference and no `[no-req]`/`traces: none` tag (gold-plating), or a High×High premortem row has an empty Mitigation cell.
Fix: tag scaffolding tasks `[no-req]`, add the matching `REQ-<id>` to real feature tasks, and fill in a `mitigation_task_id` for every High×High premortem scenario.
Bypass: `WALTEUR_SPECTRACE=off` — bypass is recorded, not free.

## prd-gate
Enforces: a non-stub `PRD.md` exists on any user-facing/new product before planning (problem, JTBD, success metric with number+unit, prioritized scope, out-of-scope).
Common failure: a `touch PRD.md` stub, or a PRD missing the success-metric-with-number-and-unit section.
Fix: write a real PRD covering all six required sections (problem/background, target user, quantified success metric, prioritized scope, NOT-doing list, >=12 non-empty lines).
Bypass: `WALTEUR_PRD=off` — bypass is recorded, not free.

## benchmark-gate
Enforces: a user-facing product names >=3 real competitors and declares every table-stakes feature's disposition (planned-with-ref or out-of-scope-with-signer).
Common failure: `benchmark.md` stub with fewer than 3 leaders, or a `table_stakes` entry with no `ref`.
Fix: research and name >=3 real competitors, and for every table-stakes feature either link a task ref (planned) or record an out-of-scope reason + signer.
Bypass: `WALTEUR_BENCHMARK=off` — bypass is recorded, not free.

## product-standard-gate
Enforces: a completeness standard (PRODUCT-STANDARD.md) exists for any product-signal build, with existing evidence refs.
Common failure: a UI/product signal exists but `PRODUCT-STANDARD.md` is absent, a stub, or its evidence refs point to nonexistent files.
Fix: author the product standard doc and make every evidence reference resolve to a real file in the repo.
Bypass: `WALTEUR_PRODUCT_STANDARD=off` — bypass is recorded, not free.

## production-layers-gate
Enforces: `walteur-kit/layers.json` declares and owns all 13 production layers for any code/product build (no missing/duplicate/placeholder/unsigned layer).
Common failure: a layer entry is missing, duplicated, a placeholder, or has no signed owner.
Fix: fill in every one of the 13 layers in `layers.json` with a real owner signature; remove duplicates; replace placeholders with real content.
Bypass: `WALTEUR_PRODUCTION_LAYERS=off` — bypass is recorded, not free.

## fitness-gate
Enforces: no cyclic dependencies or cross-bounded-context imports; declared layer edges in `layers.json` are self-consistent; heavy tools (dependency-cruiser/import-linter/deptrac) confirm when present.
Common failure: a declared dependency cycle among layers in `layers.json`, or a real dependency-cruiser/import-linter violation.
Fix: break the cycle (invert or extract the shared dependency); fix the reported cross-boundary import; if a heavy tool is absent, install it (dependency-cruiser/import-linter/deptrac) to get real coverage — a missing tool only SKIPs that sub-check, it never blocks alone.
Bypass: `WALTEUR_FITNESS=off` — bypass is recorded, not free.

## design-gate
Enforces: a non-stub `DESIGN.md` (or `design-system/MASTER.md`) exists for any UI build, and the walteur-design companion skill's MUST-chain craft engine actually resolves in `skill-index.json`.
Common failure: UI files exist with no `DESIGN.md`, or the design-mandate skill name is dangling (not in the skill index).
Fix: author `DESIGN.md` (>=10 non-empty lines + a color/palette mention); repoint the walteur-design SKILL.md mandate at an indexed skill (`jq '.skills[].skill' walteur-kit/skill-index.json`) or vendor the missing skill and regenerate the index.
Bypass: `WALTEUR_DESIGN=off` — bypass is recorded, not free.

## frontend-budget
Enforces: any frontend build that ships JS has a bundle-size + Core Web Vitals budget, and (if built) the shipped bytes stay under it.
Common failure: `frontend-budget.json` absent on a build with a "build" script + frontend source, or the built `dist/`/`build/` output exceeds the declared `bundles[].max_kb`.
Fix: author `frontend-budget.json` per `schemas/frontend-budget.schema.json` (bundles + core_web_vitals); if over budget, code-split/tree-shake/lazy-load until under the cap.
Bypass: `WALTEUR_FRONTEND=off` — bypass is recorded, not free.

## browser-proof-gate
Enforces: real, replayable browser evidence (screenshot + a11y + interaction) exists for any UI build.
Common failure: `browser-proof.json` missing, stale (>14 days), or missing one of screenshot/accessibility/interaction evidence.
Fix: run the app in a real browser (Playwright/the `run`/`verify` skill), capture a screenshot + a11y pass + an interaction trace, and record them fresh in `browser-proof.json`.
Bypass: `WALTEUR_BROWSER_PROOF=off` — bypass is recorded, not free.

## a11y-content-lint
Enforces: content-level a11y — every `<img>` has alt, every form input has a label, no generic link text ("click here"), every button has an accessible name.
Common failure: a decorative-looking `<img>` with no `alt`, or a `<button>` with only an icon and no `aria-label`.
Fix: add `alt=""` (decorative) or a real description to every image; add `aria-label`/`<label for>` to every input; replace "click here" with descriptive link text; add `aria-label` to icon-only buttons.
Bypass: `WALTEUR_A11Y=off` — bypass is recorded, not free.

## i18n-lint
Enforces: on any project actually using an i18n framework, no hardcoded user-facing strings bypass the catalog, and non-default locale files aren't missing keys the default locale has.
Common failure: a JSX text node or `alert("literal")` with a raw string not wrapped in `t(...)`/`<FormattedMessage>`; or a non-default locale JSON missing a key the default locale has.
Fix: wrap the literal in the project's translation function/component and add the key to the catalog; backfill the missing key into every non-default locale file.
Bypass: `WALTEUR_I18N=off` — bypass is recorded, not free.

## migration-proof-gate
Enforces: database migration work has an evidence contract — owner, rollout strategy, forward/rollback commands, verification refs, lock-risk evidence, backfill plan.
Common failure: `migration-proof.json` missing on a migration surface, or a referenced local proof file doesn't exist / is empty.
Fix: author `migration-proof.json` with all required fields and make every referenced evidence file real and non-empty.
Bypass: `WALTEUR_MIGRATION_PROOF=off` — bypass is recorded, not free.

## migration-lint
Enforces: every migration is reversible (real rollback body), no ADD+DROP in the same file, Postgres `CREATE INDEX` uses `CONCURRENTLY`, no unsafe `NOT NULL` without a default.
Common failure: a migration's down/rollback body is just `pass`/`raise`/empty, or a `CREATE INDEX` on Postgres omits `CONCURRENTLY` (table lock).
Fix: write a real, non-empty rollback for every migration; split combined add+drop migrations into separate expand/contract steps; add `CONCURRENTLY` to Postgres index creation; add a `DEFAULT` before a `NOT NULL` addition on large tables.
Bypass: `WALTEUR_MIGRATION=off` — bypass is recorded, not free.

## migration-roundtrip
Enforces: `migrate up → down → up` produces an identical schema hash (the rollback truly inverts the forward migration).
Common failure: a migration has an up but no down direction at all (fails the zero-dep precheck), or (when the live-DB path runs) the schema hash after round-trip differs.
Fix: add the missing down direction; if hashes diverge, fix the down migration so it fully reverses every change the up migration made.
Bypass: `WALTEUR_MIGRATION_RT=off`. Enable the live-DB round-trip with `WALTEUR_MIGRATION_DB=on` + `DATABASE_URL_TEST` — bypass is recorded, not free.

## resilience-lint
Enforces: no empty catch/except-pass, network calls have timeouts, retry loops use jitter, library errors are typed (not bare string throws), E2E selectors aren't brittle (no pixel clicks/deep nth-child/absolute XPath).
Common failure: a `catch (e) {}` empty block, or a `fetch()`/`requests.get()` call with no timeout configured nearby.
Fix: handle or log the caught error (never swallow silently); add a timeout/AbortSignal to every network call; add jitter to fixed-delay retry loops; replace pixel/XPath E2E selectors with `getByRole`/`getByTestId`.
Bypass: `WALTEUR_RESILIENCE=off`. Silent-failure rules are WARN-only by default; promote with `WALTEUR_RESILIENCE_SILENT=hard` — bypass is recorded, not free.

## devenv-gate
Enforces: a reproducible dev environment — `.editorconfig`, a task runner (Makefile/Justfile/npm scripts), and a toolchain version pin (`.nvmrc`/`.tool-versions`/etc).
Common failure: a code-stack project missing all three disciplines ("works on my machine").
Fix: add `.editorconfig`, a task runner file (or npm `scripts`), and a toolchain pin file matching your runtime.
Bypass: `WALTEUR_DEVENV=off` — bypass is recorded, not free.

## config-validation
Enforces: no raw `process.env`/`os.environ` access without a validated config module (zod/pydantic-settings/viper/etc), and no committed `.env` with real-looking secrets.
Common failure: `process.env.X` read directly outside a validated config module with no schema layer anywhere in the repo, or a tracked `.env` with a high-entropy value.
Fix: introduce a typed config module (envalid/zod/t3-env for JS, pydantic-settings for Python, viper/envconfig for Go) and route all env reads through it; remove the committed `.env` and rotate any leaked secret, replacing it with `.env.example` placeholders.
Bypass: `WALTEUR_CONFIG=off` — bypass is recorded, not free.

## nfr-lint
Enforces: every non-functional requirement is quantified — unit, numeric target, load condition (Planguage), never a weasel word like "should be fast".
Common failure: an `nfr.json` entry (or PLAN.md NFR section) with no number+unit — "highly available" instead of "99.9% over 30d".
Fix: rewrite every NFR as `<metric> <comparator> <number><unit> under <load_condition>` (e.g. "p99 latency < 200ms at 500 rps").
Bypass: `WALTEUR_NFR=off` — bypass is recorded, not free.

## observe-lint
Enforces: no `print()`/`console.log` as logging in app code (outside CLI paths), latency metrics are histograms (not gauges), no PII interpolated into log calls, and (if Sentry is a dep) it's actually initialized with tracing.
Common failure: a `logger.info(f"login {email}")`-style line interpolating PII directly into a log call.
Fix: redact/mask the PII field before logging (`redact(email)`); replace `console.log`/`print` with a structured logger in app code; rename latency gauges as histograms; wire `Sentry.init` with `traces_sample_rate >= 0.1` if the Sentry SDK is a dependency.
Bypass: `WALTEUR_OBSERVE=off` — bypass is recorded, not free.

## perf-gate
Enforces: any service/load-script context declares a perf budget with p99 AND p999 tail latency for every critical path; k6/wrk2 runs stay within 10% of baseline.
Common failure: a service entrypoint exists with no `perf-budget.json` at all ("unbudgeted perf" — forbidden), or a `critical_paths[]` entry missing `p999`.
Fix: author `perf-budget.json` with p99 AND p999 for every critical path; if a load-tool run regressed >10% vs baseline, investigate and fix the regression (or update the baseline deliberately).
Bypass: implicit via the detect-or-skip layer for heavy tools; the zero-dep budget-presence check has no off-switch documented in the header — treat as always-on when a service/load surface exists.

## security-gate
Enforces: gitleaks (secrets), osv-scanner/npm audit/pip-audit (HIGH+ vulns), semgrep OWASP-top-ten (ERROR findings) — each run if installed.
Common failure: gitleaks finds a committed secret, or a HIGH+ dependency vulnerability is unpatched.
Fix: remove/rotate the leaked secret (gitleaks finding); upgrade the vulnerable dependency to a patched version; fix the semgrep-flagged OWASP pattern. Install any missing tool (gitleaks/osv-scanner/semgrep) to get real coverage instead of a SKIP.
Bypass: `WALTEUR_SECURITY=off` — bypass is recorded, not free.

## osv-gate
Enforces: no MAL-* (malicious-package) advisory in OSV.dev for any candidate dependency before it's adopted.
Common failure: a newly added dependency (or MCP server package) has a live `MAL-*` advisory.
Fix: remove the malicious package immediately and find a legitimate alternative; if this was a typosquat, double-check the intended package name. Do not proceed with a MAL-flagged dependency under any circumstance.
Bypass: `WALTEUR_OSV=off`. Missing curl/network => loud SKIP, not a pass, unless `WALTEUR_OSV=strict` — bypass is recorded, not free.

## sbom-gate
Enforces: a valid, non-empty SBOM (CycloneDX/SPDX/Syft) exists for any dependency/container surface.
Common failure: no persisted SBOM and no `syft` binary to generate one on a project with real dependencies.
Fix: install `syft` and generate an SBOM (`syft . -o cyclonedx-json > walteur-kit/sbom.json`), or hand-author one that satisfies the CycloneDX/SPDX shape with a non-empty component list.
Bypass: `WALTEUR_SBOM=off` or `WALTEUR_SBOM_GATE=off` — bypass is recorded, not free.

## contract-gate
Enforces: if PLAN.md declares `surface: api`, a machine-readable API spec (OpenAPI/proto/GraphQL schema) must exist; `spectral` lint errors (if installed) fail the build.
Common failure: PLAN.md says "surface: api" but no `openapi.yaml`/`.proto`/`schema.graphql` exists anywhere in the repo.
Fix: author the missing API spec file; fix any spectral ERROR-severity lint finding against it.
Bypass: `WALTEUR_CONTRACT=off` — bypass is recorded, not free.

## schema-lint
Enforces: money columns use NUMERIC/DECIMAL (never float), timestamps are timezone-aware, every table has a primary key, status/enum columns are constrained (not free-text VARCHAR).
Common failure: a `price`/`amount`/`total` column declared as `FLOAT`/`REAL`, or a `status` column as unconstrained `VARCHAR` with no CHECK/enum/FK.
Fix: change the money column type to `NUMERIC`/`DECIMAL` (or integer cents); add a CHECK constraint, enum type, or lookup FK to the status column; add `timestamptz`/timezone-aware type to naive timestamps; add a primary key to any table missing one.
Bypass: `WALTEUR_SCHEMA=off` — bypass is recorded, not free.

## confidentiality-gate
Enforces: named-client/NDA/M&A identifiers don't leak into external-facing artifacts (release notes, case studies, press, public docs).
Common failure: the build produces an external artifact but `confidentiality-pass.json` is absent or FAIL.
Fix: run the confidentiality scan over every external-facing doc, redact any named-client/NDA/deal-codename hit, and record a fresh PASS in `confidentiality-pass.json` (or a signed `layers.json` deferral).
Bypass: `WALTEUR_CONFIDENTIALITY=off`. Default is WARNING-FIRST (exit 0 + WARN); arm HARD with `WALTEUR_CONFIDENTIALITY_HARD=1` — bypass is recorded, not free.

## ontology-lint
Enforces (advisory only, never blocks): PRD/PLAN/ADR domain nouns resolve against a typed glossary (`ontology.json`) so terms mean the same thing everywhere.
Common failure: a capitalized domain noun used in the PRD/PLAN has no matching entry (or alias) in `ontology.json`.
Fix: add the missing term to `ontology.json` (`{name, type, aka, definition}`), or fix the inconsistent naming to match an existing entry.
Bypass: `WALTEUR_ONTOLOGY=off` — this gate is always exit 0 (advisory); bypass is recorded, not free.

## tool-readiness
Enforces: every tool declared `required:true` in `required-tools.json` is actually on PATH before the build proceeds — the one fail-closed gate.
Common failure: a required tool (jq/node/docker/etc) declared required but not installed on this box.
Fix: install the missing tool per the printed install hint; if the tool is genuinely optional for this build, mark it `required:false` in `required-tools.json` instead of installing a tool you don't need.
Bypass: `WALTEUR_TOOLREADY=off` — bypass is recorded, not free.

## skill-readiness
Enforces: every skill declared `required:true` in `required-skills.json` left a content-bound receipt (real artifacts, real timestamp, a 40+ char summary) — not just an existing-file check.
Common failure: a skill receipt file exists but is empty/garbage, or its `.artifacts[]` paths don't resolve to real files, or `.fired_at` is stale (>168h default).
Fix: re-run the skill and let it write a real receipt with existing artifact paths, a fresh `fired_at`, and a substantive `summary` (>=40 chars).
Bypass: `WALTEUR_SKILLREADY=off` — bypass is recorded, not free.

## operate-readiness-gate
Enforces: any runtime/deployable surface has an operate-readiness proof — SLOs, DORA targets, runbooks, on-call, observability, rollback rehearsal with RTO/RPO, support handoff, postmortem procedure.
Common failure: a Docker/k8s/serverless surface exists but `operate-readiness.json` is missing or stale, or a referenced runbook/evidence file doesn't exist.
Fix: author `operate-readiness.json` with every required field, and make every referenced runbook/evidence file real and in-repo.
Bypass: `WALTEUR_OPERATE_READINESS=off` — bypass is recorded, not free.

## release-gate
Enforces: a deployable surface has `release-readiness.json` with a non-empty rollback command and a non-"recreate" deploy strategy; syft/cosign/grype confirm when present.
Common failure: `.deploy_strategy` set to `"recreate"` (downtime, no safe rollout), or `.rollback_command` empty.
Fix: switch to a real zero-downtime strategy (blue-green/canary/rolling) and record a real, tested rollback command; install syft/cosign/grype for the supply-chain sub-checks if you want that coverage.
Bypass: `WALTEUR_RELEASE=off` — bypass is recorded, not free.

## quickstart-check
Enforces: the README's quickstart actually works — either a container reaches a `walteur:ready` marker, or (no docker) the README has a real quickstart heading + a fenced shell block.
Common failure: the README has no quickstart/getting-started heading, or has one but no fenced ```bash/sh block under it.
Fix: add a "## Quickstart" (or Getting Started) heading with a real, runnable fenced shell block that a fresh clone can copy-paste; have it (or a `walteur-kit/quickstart-ready.sh` probe) print `walteur:ready` on success.
Bypass: `WALTEUR_QS_DOCKER=off` skips only the container assertion (zero-dep README check still runs). Full bypass: `WALTEUR_QUICKSTART=off`. Budget: `WALTEUR_QS_BUDGET` seconds (default 90) — bypass is recorded, not free.

## run-trace
Enforces: a flat, append-only telemetry ledger of phase/tool/gate spans exists once trace enforcement is due.
Common failure: intake+ runs with zero usable trace spans in `run-trace.jsonl`.
Fix: make sure the harness is emitting spans (`run-trace.sh emit ...`) at each phase transition; check the ledger isn't being truncated by a stray write.
Bypass: `WALTEUR_TRACE=off` — bypass is recorded, not free.

## trace-mine
Enforces (offline, on-demand): systemic (recurring >=3x) patterns in the trace/refine/SUMMARY ledgers get surfaced as candidate lessons — never a hard-failing gate on its own.
Common failure: not a FAIL-producing gate in normal operation; if invoked and it errors, the underlying ledger file (`run-trace.jsonl`/`refine-log.json`/`SUMMARY.jsonl`) is likely malformed.
Fix: validate the malformed ledger file with `jq .`/`jq -s .` and repair or truncate the bad line; re-run `trace-mine.sh`.
Bypass: `WALTEUR_TRACEMINE=off` — bypass is recorded, not free.

## release-ledger-lint
Enforces: `release-ledger.json` is valid, and docs/mirrors/manifests/registry/source-count claims are not stale vs the current gate/skill counts.
Common failure: the ledger's declared gate/skill count no longer matches the live registry (a gate was added/removed and the ledger wasn't refreshed).
Fix: regenerate the release-ledger counts from the live `gate-registry.json`/`skill-index.json` and update every stale doc/manifest reference.
Bypass: `WALTEUR_RELEASE_LEDGER=off` — bypass is recorded, not free.

## ai-safety-gate
Enforces (VETO-only): an AI build has a prompt-injection test corpus, every agent loop has a hard model-independent termination cap, and no hardcoded Claude/Anthropic model literal outside env/config.
Common failure: an agent-loop source file with no iteration cap / max-turns guard, or a hardcoded `claude-*` model string as a literal in source.
Fix: add a hard termination cap (max iterations, independent of model behavior) to the agent loop; move the model id to an env var or config file; add a `tests/injection/` corpus if the build has no prompt-injection tests yet.
Bypass: `WALTEUR_AISAFE=off` — bypass is recorded, not free.

## cost-budget
Enforces: any app spending money per request (LLM calls, cloud SDKs) has `cost-budget.json` with real per-unit/per-task USD or token caps.
Common failure: an LLM/cloud-spend signal in source with no `cost-budget.json` at all.
Fix: author `cost-budget.json` per `schemas/cost-budget.schema.json` with real `max_usd_per_request`/`max_usd_per_run` or `max_usd_per_task`/`max_tokens` figures.
Bypass: `WALTEUR_COST=off`. Cap env: `MAX_BUILD_COST_USD` (default 25) — bypass is recorded, not free.

## tool-contract-lint
Enforces: every agent tool contract declares `side_effect_class`, and any `write_irreversible`/`external_money` tool REQUIRES `oversight_gate:true`; tool `input` must be a typed JSON-schema object.
Common failure: a dangerous tool (money-moving or irreversible-write) contract with `oversight_gate:false` or missing, or a tool with a free-form/no-schema `input`.
Fix: set `oversight_gate:true` on every irreversible/money tool (add a real human-in-the-loop check before it fires); replace the free-form input with a proper JSON-Schema object.
Bypass: `WALTEUR_TOOL_CONTRACT=off` — bypass is recorded, not free.

## tool-guardrail-gate
Enforces: `tool-guardrails.json` exists for any agent build and every declared tool has non-empty `pre_call.checks`, `post_call.checks`, and a real (non-swallowing) `error_path.on_fatal`.
Common failure: a tool entry with empty `pre_call.checks`/`post_call.checks` arrays (nothing validated in or out).
Fix: add real pre-call validation (authz/rate-limit/injection-scrub) and post-call validation (size-bound/scrub the tool result) for every declared tool; make `on_fatal` a real halt/recover action, never a silent retry-forever.
Bypass: `WALTEUR_TOOL_GUARDRAIL=off` — bypass is recorded, not free.

## iac-scan
Enforces: tfsec/checkov/conftest (whichever installed) find no HIGH+ finding in Terraform/Bicep/k8s manifests.
Common failure: a real tfsec HIGH+ finding (e.g. a public S3 bucket, an open security group) or a failed checkov policy check.
Fix: fix the flagged IaC misconfiguration directly (close the security-group rule, add encryption, etc); install tfsec/checkov if none is present to get real coverage instead of a SKIP.
Bypass: `WALTEUR_IAC=off` — bypass is recorded, not free.

## restore-proof
Enforces: a backup actually restores (dump → restore → smoke query → RTO check against a throwaway target) — never proven from a mere backup file existing.
Common failure: by default this gate LOUD-SKIPs (it never provisions a destructive round-trip as a side effect); when actually armed, a restore that fails the smoke query or blows the RTO budget.
Fix: opt in explicitly with `WALTEUR_RESTORE_PROOF_RUN=on` + `RESTORE_TEST_DB_URL` and run the real dump→restore→smoke cycle; if it fails, fix the backup/restore tooling until the smoke query succeeds within the declared RTO.
Bypass: `WALTEUR_RESTORE_PROOF=off` — bypass is recorded, not free.

## scoreboard-gate
Enforces: the eight-dimension score contract is complete at ship — composite meets target, every dimension meets its floor, security >=8, nothing unlocked without a target.
Common failure: a dimension below its floor (commonly security <8), or the composite below the declared target.
Fix: address the weak dimension's underlying findings (re-run the relevant gates) until it clears its floor; do not lower the floor to pass.
Bypass: `WALTEUR_SCOREBOARD=off` — bypass is recorded, not free.

## definition-of-done-gate
Enforces: every DoD checklist item is checked with real evidence (not a placeholder) before ship.
Common failure: an unchecked item, or a checked item with a weak/missing Evidence cell, or a stale evidence file reference.
Fix: complete the missing DoD item for real, then link fresh, real evidence (a file, report, or command output) in the Evidence cell — never mark done without a link.
Bypass: `WALTEUR_DOD=off` — bypass is recorded, not free.

## compliance-gate
Enforces: PII handling has a `data-inventory.json`, every `pii.*` entry has a lawful basis + retention TTL, and no PII is interpolated into an unredacted log call.
Common failure: PII-looking code (email/ssn/phone fields) with no `data-inventory.json` at all, or a `pii.*` entry missing `lawful_basis`/`retention_ttl_days`.
Fix: author `data-inventory.json` cataloging every PII field with its lawful basis and retention period; wrap any PII interpolated into a log call with a redactor (`redact()`/`mask()`).
Bypass: `WALTEUR_COMPLIANCE=off` — bypass is recorded, not free.

## audit-contract-gate
Enforces: the terminal audit certificate has zero `launch_blockers`, all 13 production layers attested, fresh evidence, intent/layer proof.
Common failure: an audit certified with a non-empty `launch_blockers[]`, or an incomplete layer cert (e.g. 8/13 attested) — by design this FAILs until complete.
Fix: resolve every launch blocker for real before certifying; complete the missing §14 production layers or record an honest signed deferral (never fabricate a layer as done).
Bypass: `WALTEUR_AUDIT_CONTRACT=off` — bypass is recorded, not free.

## audit-gate
Enforces (terminal, on `git commit`/`git tag`): PLAN.md exists, DoD complete + composite score meets target, QA report is a fresh PASS with a re-run unit/integration command, `debate/OPEN.json` is empty, and `audit.json` is Opus-authored + certified + fresh.
Common failure: `audit.json` missing/stale, or `.model` isn't `opus`, or `.certified` isn't `true`, or the QA report's recorded command wasn't actually re-run.
Fix: re-run the full audit pass with the Opus-tier reviewer, get a fresh `certified:true` `audit.json`; re-run the QA unit/integration command and confirm a real green before recording it; close every open debate fork.
Bypass: `WALTEUR_SHIP=off` — bypass is recorded, not free.

## doc-quality-gate
Enforces (document build_class): deliverables exist and are non-empty, the doc is sectioned (not a wall of text), every claim is cited, headings + paragraph-length cap, external docs pass a humanizer check.
Common failure: `doc-quality.json` deliverables path pointing at a missing/empty file, or `sourcing.claims_cited < sourcing.claims_total` (an uncited claim).
Fix: cite every factual claim (add the missing citation and bump `claims_cited`), break up any paragraph over the cap (default 220 words) with real headings, and run the humanizer pass for any externally-shared doc.
Bypass: `WALTEUR_DOC_QUALITY=off` — bypass is recorded, not free.

## workflow-quality-gate
Enforces (workflow build_class): a single accountable owner (RACI), a real dry-run, a defined exception path, a defined recovery path.
Common failure: `workflow-quality.json` with an empty `ownership.raci.accountable`, or `dry_run.performed` false/missing.
Fix: name one accountable owner in the RACI block; actually perform a dry run and record its evidence ref; document the exception path and the recovery path with real refs.
Bypass: `WALTEUR_WORKFLOW_QUALITY=off` — bypass is recorded, not free.

## container-scan
Enforces: hadolint/trivy/kubeconform (whichever installed) find no lint error / HIGH+ misconfig / schema-invalid manifest in container/k8s files.
Common failure: a real hadolint lint error (e.g. `USER root` left in, no pinned base image tag) or a trivy HIGH/CRITICAL config finding.
Fix: fix the flagged Dockerfile/manifest issue directly (pin the base image, add a non-root USER, fix the k8s schema violation); install hadolint/trivy/kubeconform if none present.
Bypass: `WALTEUR_CONTAINER=off` — bypass is recorded, not free.

## maintainability-gate
Enforces: every manifest has a committed lockfile (up the ancestor chain), a dependency-automation config (renovate/dependabot) exists when a manifest exists, and every debt marker (TODO/FIXME/skip/eslint-disable) is recorded in `debt-ledger.json`.
Common failure: a `package.json`/`pyproject.toml` with no matching lockfile committed anywhere up the tree, or a `TODO`/`test.skip` with no matching `debt-ledger.json` entry.
Fix: commit the missing lockfile (`npm install`/`poetry lock`/etc); add a `renovate.json` or `.github/dependabot.yml`; register every debt marker in `debt-ledger.json` with `{id,kind,location,reason,owner,expires}`.
Bypass: `WALTEUR_MAINTAIN=off` — bypass is recorded, not free.

## craft-gate
Enforces: the stack's formatter + linter + type-checker trio all pass (ruff/prettier+eslint+tsc/gofmt+vet/cargo fmt+clippy — whichever stack is present and the tool is installed).
Common failure: a real formatting diff (`prettier --check` fails) or a lint/type error the tool actually caught.
Fix: run the formatter to auto-fix (`prettier --write` / `ruff format`), then fix the real lint/type errors it reports — do not suppress with a blanket disable comment.
Bypass: `WALTEUR_CRAFT=off` — bypass is recorded, not free.

## skill-index-lint
Enforces: `skill-index.json` is well-formed, with no duplicate skill entries and valid breadcrumb declarations.
Common failure: a duplicate skill id, or a breadcrumb field pointing at a malformed/missing shape.
Fix: remove the duplicate entry; fix the breadcrumb field to match the required shape.
Bypass: `WALTEUR_SKILL_INDEX=off` — bypass is recorded, not free.

## integration-proof-gate
Enforces: every external dependency in `integrations.json` is `live-wired` (real round-trip proof), `signed-deferred` (owner+ticket+reason), or `mock` (only if `allow_mock_prototype:true` and low/medium risk) — never silently faked.
Common failure: an integration left as `mock` without `allow_mock_prototype:true` set at the root, or `live-wired` with no fresh `proof.command_output_ref`.
Fix: wire the integration for real and record a fresh command-output proof, or formally defer it with an owner + ticket + reason; never leave a production integration mocked without the explicit root flag.
Bypass: `WALTEUR_INTEGRATION_PROBE=off` — bypass is recorded, not free.

## measured-quality-gate
Enforces: Lighthouse + axe-core results are real (tool-emitted provenance fields present), fresh (<72h), and meet thresholds (perf/a11y/best-practices >=0.9, zero axe violations).
Common failure: a hand-written `{categories:{performance:{score:0.95}}}` stub with no `.lighthouseVersion`/`.fetchTime`/`.audits` (fails the provenance check), or a stale artifact past `WALTEUR_MEASURED_MAXAGE` (72h default).
Fix: run `npx lighthouse <url> --output=json --output-path=walteur-kit/quality/lighthouse.json` and `npx @axe-core/cli <url> --save walteur-kit/quality/axe.json` for real — these tools emit the required provenance fields automatically; re-run if the artifact is stale. To force a live re-measure, set `WALTEUR_MEASURED_EXEC=1` and record the target at `walteur-kit/quality/target.json`.
Bypass: `WALTEUR_MEASURED_QUALITY=off` — bypass is recorded, not free.

## test-layer-coverage-gate
Enforces: every required test layer (logic/component/e2e per build type) has a `recorded_command` that actually exits 0 — a claimed-PASS layer with no re-runnable command is treated as not-executed.
Common failure: a UI build's `test-coverage.json` missing the `e2e` layer, or a layer's `recorded_command` field is empty/absent.
Fix: record a real, re-runnable test command for every required layer in `test-coverage.json` and arm `WALTEUR_TEST_LAYERS_EXEC=1` so it's re-run and the observed exit is checked.
Bypass: `WALTEUR_TEST_LAYERS=off` — bypass is recorded, not free.

## security-baseline-gate
Enforces: the 11-point production-security baseline (RLS, auth failure-path tests, security headers, OWASP review, server-side validation, no frontend secrets, rate limits, CAPTCHA+CORS, safe error messages, etc) is addressed when the relevant signal is present.
Common failure: a `security-baseline.json` check left with no `status` (not verified/signed-deferred/not-applicable), or missing entirely for a required check.
Fix: implement the missing control (or formally sign-defer it with reason+owner+ticket+review_trigger) and record it in `security-baseline.json` with real evidence.
Bypass: `WALTEUR_SECURITY_BASELINE=off` — bypass is recorded, not free.

## billing-integrity-gate
Enforces: every payment webhook verifies signatures and dedupes by event id; every money-moving API call carries an idempotency key.
Common failure: a `stripe.charges.create`/`paymentIntents.create` call with no idempotency key parameter, or a webhook handler with no signature verification.
Fix: add the payment provider's idempotency-key parameter to every money-moving create call; add signature verification (e.g. `stripe.webhooks.constructEvent`) plus an event-id dedupe check to every webhook handler.
Bypass: `WALTEUR_BILLING=off` — bypass is recorded, not free.

## audit-trail-gate
Enforces: `audit-trail.json` declares immutability + retention + captured fields + required events, AND every privileged action in source actually emits an audit event.
Common failure: an admin/auth-privileged code path (role change, data export, permission grant) with no matching audit-emit call anywhere.
Fix: add a real audit-log emit call at every privileged action site; ensure `audit-trail.json` declares retention >= `WALTEUR_AUDIT_MIN_RETENTION_DAYS` (default 365) and immutability.
Bypass: `WALTEUR_AUDIT_TRAIL=off` — bypass is recorded, not free.

## cross-tenant-probe-gate
Enforces: a REAL two-tenant attack probe (authenticate as tenant A, request tenant B's resource) observes a deny — self-certification without a probe is refused.
Common failure: tenant columns exist in source but `tenant-isolation.json` is absent (self-certifying away the requirement), or a probe command exits non-zero (a real leak) instead of asserting the deny.
Fix: write and run the real cross-tenant probe, confirm it returns a deny/empty for the foreign tenant's resource, and record it in `tenant-isolation.json`. A leak found by the probe is a real vulnerability — fix the authorization check immediately.
Bypass: `WALTEUR_TENANT=off`. Skip only the live probe (keep the manifest requirement): `WALTEUR_TENANT_PROBE=off` — bypass is recorded, not free.

## residency-gate
Enforces: `residency.json` declares required regions per datastore, and no IaC region literal falls outside the allowed set, for regulated/restricted/confidential data.
Common failure: an IaC file provisions a resource in a region outside `residency.json`'s `required_regions`.
Fix: move the out-of-region resource to an allowed region, or update `residency.json` if the requirement itself was wrong (with a real justification, not to dodge the check).
Bypass: `WALTEUR_RESIDENCY=off` — bypass is recorded, not free.

## backup-policy-gate
Enforces: `backup-policy.json` declares a cadence, off-region/immutable copy, and PITR per datastore, with cadence meeting the declared RPO.
Common failure: a datastore's backup cadence is wider than its declared RPO (e.g. daily backups but a 4h RPO promise).
Fix: tighten the backup cadence to meet the RPO (or relax the RPO honestly if that's the real target), and add an off-region/immutable copy if missing.
Bypass: `WALTEUR_BACKUP=off` — bypass is recorded, not free.

## access-review-gate
Enforces: `access-review.json` records a cadence (<=90 days default) and a FRESH last review with a real signoff.
Common failure: the last recorded review is older than `WALTEUR_ACCESS_REVIEW_MAX_CADENCE_DAYS` (default 90), or there's no signoff.
Fix: conduct the quarterly (or declared-cadence) access review now, and record the date + signoff in `access-review.json`.
Bypass: `WALTEUR_ACCESS_REVIEW=off` — bypass is recorded, not free.

## lifecycle-access-gate
Enforces: `access-lifecycle.json` + a real deprovisioning probe (disable a user via SCIM, assert their existing session/token then returns 401).
Common failure: the deprovisioning probe was never actually run, or (when run) the disabled user's token still returns 200 (session not truly revoked).
Fix: wire real session/token revocation into the deprovisioning flow (invalidate server-side session store or token blocklist on disable), then re-run the probe and confirm 401. This cannot be signed-deferred at high/regulated risk.
Bypass: `WALTEUR_LIFECYCLE=off`. Skip only the live probe: `WALTEUR_LIFECYCLE_PROBE=off` — bypass is recorded, not free.

## sso-gate
Enforces: `sso.json` with each SSO control (signature verification, audience/Recipient restriction, NotBefore/NotOnOrAfter, replay/nonce, OIDC state+PKCE) verified by a probe that sends a malicious assertion and asserts rejection.
Common failure: a probe that was never run, or one that (when run) fails to reject a forged/replayed assertion.
Fix: implement and test the missing SAML/OIDC control (signature check, audience restriction, replay protection, PKCE), then run the probe against a real malicious assertion and confirm it's rejected (403).
Bypass: `WALTEUR_SSO=off`. Skip only the live probes: `WALTEUR_SSO_PROBE=off` — bypass is recorded, not free.

## load-proof-gate
Enforces: a FRESH load-run artifact proves achieved p99 <= budget at a declared target RPS+VUs (not merely a perf-gate loud-SKIP).
Common failure: `load-proof.json` is stale, or missing while `has_api_boundary` is true at high/regulated risk.
Fix: run a real k6/wrk2 load test at the declared RPS/VUs, record the achieved p99 in `load-proof.json` fresh; if `WALTEUR_LOAD_EXEC=1` is armed, make sure `recorded_command` is a real (non-no-op) command that gets re-run.
Bypass: `WALTEUR_LOAD=off` — bypass is recorded, not free.

## anti-slop-code-gate
Enforces: zero AI-slop tells in production source — no TODO/FIXME/HACK, no "placeholder"/"coming soon", no stub credentials, no empty catch, no `as any`/`@ts-ignore` without justification, no bare `console.log` in server code.
Common failure: a leftover `// TODO: implement this` or a `changeme`/`your-api-key` stub credential in a deploy script or entrypoint.
Fix: finish the stubbed implementation for real (no placeholder); replace stub credentials with real config/secret references; remove or properly handle the empty catch; add a reason to any `eslint-disable`.
Bypass: `WALTEUR_ANTISLOP=off`. Tunable: `WALTEUR_ANTISLOP_MAX` (default 0 hits allowed) — bypass is recorded, not free.

## cve-gate
Enforces: no unexpired CRITICAL/HIGH CVE in the dependency tree (via `cve-report.json`); high/regulated risk with NO scan at all also FAILs.
Common failure: `cve-report.json` missing/stale on a high/regulated build, or an open CRITICAL/HIGH CVE with no matching entry in `cve-exceptions.json`.
Fix: run a real CVE scanner and write its normalized output to `cve-report.json`; upgrade the vulnerable dependency, or (only with real justification) add a signed, time-boxed exception to `cve-exceptions.json`.
Bypass: `WALTEUR_CVE=off` — bypass is recorded, not free.

## dast-gate
Enforces: no unexpired High/Critical DAST (dynamic scan) alert; an external surface at high/regulated risk with NO DAST run at all also FAILs.
Common failure: `dast-report.json` missing on an `external_surface` build at high/regulated risk, or an open High/Critical ZAP/Burp-shaped alert.
Fix: run a real dynamic scan (OWASP ZAP/Burp) against a deployed environment and record the normalized report; fix the flagged runtime vulnerability (reflected XSS, missing header, injection, SSRF).
Bypass: `WALTEUR_DAST=off` — bypass is recorded, not free.

## async-trace-lint
Enforces: every producer→consumer async hop in `async-trace.json` proves trace-context is injected on the producer and extracted on the consumer.
Common failure: a queue/event hop declared without both `injected`/`extracted` proof, so trace correlation silently breaks across the async boundary.
Fix: inject `traceparent` (or equivalent) on the producer before enqueue, extract and continue the trace on the consumer, and record the hop's proof in `async-trace.json`.
Bypass: `WALTEUR_ASYNCTRACE=off`. Skip only live probes: `WALTEUR_ASYNCTRACE_PROBE=off` — bypass is recorded, not free.

## resilience-async-gate
Enforces: outbound dependencies have circuit-breakers/bulkheads, async jobs have a dead-letter queue + idempotency key, and connection-pool sizing doesn't exceed `db_max_connections` across instances.
Common failure: `resilience.json`/`async-jobs.json` missing a circuit-breaker declaration for an outbound dependency, or a pool-size sum (instances × pool_size) exceeding the declared DB max connections.
Fix: add a circuit-breaker/bulkhead around the outbound call; add a DLQ + idempotency key to the async job; reduce per-instance pool size (or DB max connections up) so the sum stays under the DB's limit.
Bypass: `WALTEUR_RESILIENCE=off` — bypass is recorded, not free.

## redundancy-topology-gate
Enforces: no customer-facing serving tier is a single point of failure — single region AND single AZ AND <2 replicas is forbidden.
Common failure: `topology.json` declares a customer-facing tier with 1 replica in 1 AZ.
Fix: scale the tier to >=2 replicas across >=2 AZs (or regions, per your SLA), and record the corrected topology.
Bypass: `WALTEUR_TOPOLOGY=off` — bypass is recorded, not free.

## design-depth-gate
Enforces: every §14 layer flagged by preflight signals (auth/db/payments/async/api/ui) has a real "### Layer depth: <layer>" prose section (>=200 non-whitespace chars, not a keyword dump) in PLAN.md, on any high/regulated OR user-facing build.
Common failure: a bare keyword list ("authz deny-by-default session refresh revoke rbac argon2 mfa") with no actual sentences — this no longer counts as of S033.
Fix: write a real "### Layer depth: <layer>" section with 2-4 concrete sentences decomposing that layer's actual design (see the gate's own `deepplan()` selftest fixture for the bar to hit).
Bypass: `WALTEUR_DESIGNDEPTH=off` — bypass is recorded, not free.

## anti-slop-ui
Enforces: no AI-slop UI tells — purple/indigo gradients, "lorem ipsum", fake data (Acme/John Doe/pravatar), emoji in buttons, arbitrary pixel Tailwind sizing, `outline:none` without focus-visible, raw `alert(`, "Something went wrong", hand-rolled primitives when shadcn/ui is set up, inline layout styles.
Common failure: a `from-purple-500 to-indigo-500` gradient class, or placeholder text like "John Doe"/"jane@example.com" left in a UI component.
Fix: replace the gradient with a brand-token color, replace placeholder/fake data with real or clearly-marked sample data, add a `focus-visible` style anywhere `outline:none` is used, replace raw `<button>`/`<input>` with the shadcn/ui component when a shadcn setup exists, move inline layout styles to Tailwind utility classes.
Bypass: none documented in this gate's header — it is a straight HARD gate on frontend source with no `WALTEUR_*=off` line found; treat as always-on when frontend files exist.

## supply-chain-gate
Enforces: no malicious package-lifecycle script (fetch-and-execute, base64+eval, token exfil) and a committed, non-vacuous lockfile for reproducible installs.
Common failure: a `postinstall`/`preinstall` script that does something suspicious (network fetch piped to exec, base64-decoded eval), or a missing/empty lockfile at high/regulated risk.
Fix: remove or replace the suspicious dependency immediately (this is a real supply-chain attack pattern, treat it as an incident); commit a real, non-empty lockfile.
Bypass: `WALTEUR_SUPPLYCHAIN=off` — bypass is recorded, not free.

## ci-hardening-gate
Enforces: `.github/workflows/*.yml` pin third-party actions to a 40-char commit SHA (not a mutable tag), use OIDC (not long-lived cloud keys), declare top-level `permissions`, avoid bare `pull_request_target`, and checkout with `persist-credentials:false`.
Common failure: a third-party action pinned to `@v3` (a mutable, re-writable tag) instead of a commit SHA, or no top-level `permissions:` block.
Fix: pin every third-party action to its full 40-char commit SHA; add a minimal top-level `permissions:` block; switch long-lived cloud secrets to OIDC; add `persist-credentials: false` to `actions/checkout`.
Bypass: `WALTEUR_CIHARDEN=off` — bypass is recorded, not free.

## spec-gate
Enforces: `spec.md` enumerates >=3 requirements with `FR-###` ids + EARS-shaped acceptance lines, `constitution.md` has >=1 standing security/RLS/tenant principle, no "[NEEDS CLARIFICATION]"/"TBD" markers, and every `FR-###` traces into PLAN.md.
Common failure: a `spec.md` requirement with no EARS-shaped (WHEN/THEN/SHALL) acceptance line, or an `FR-###` never referenced anywhere in PLAN.md.
Fix: rewrite the requirement's acceptance criteria in EARS grammar; add the missing `FR-###` reference to the corresponding PLAN.md task; remove any `[NEEDS CLARIFICATION]`/`TBD` marker by actually resolving the open question.
Bypass: `WALTEUR_SPEC=off`. Fail-closed only at risk_tier high/regulated; advisory below that — bypass is recorded, not free.

## context-budget-gate
Enforces: every handoff artifact (briefs/SUMMARY ledger) stays under `WALTEUR_CTX_MAX` tokens (default 8000, ~bytes/4), and PLAN.md exists whenever briefs are present.
Common failure: a brief file grew past the token budget (bloated handoff context), or briefs exist with no PLAN.md as the root anchor.
Fix: compress the oversized brief (summarize, drop stale sections) until under budget; author PLAN.md if briefs exist without one.
Bypass: `WALTEUR_CTXBUDGET=off` — bypass is recorded, not free.

## agent-security-gate
Enforces: an agent surface declares a trust-split (untrusted-data path has zero tool/credential authority), `no_secret_in_prompt`, a named prompt-injection control; actively scans for a secret/env var interpolated into a prompt literal.
Common failure: a secret or env var (`process.env.API_KEY`) interpolated directly into a prompt/messages/system string literal in code.
Fix: never interpolate a secret into a prompt — route credentials through the tool-call layer, not the model context; declare the trust-split and a named injection control in `agent-security.json`.
Bypass: `WALTEUR_AGENTSEC=off` — bypass is recorded, not free.

## injection-resistance-gate
Enforces: an untrusted-input project (one that declares `walteur-kit/injection-probes.json`) survives an EXECUTED adversarial corpus — each case is actually RUN against the real target under a hard per-case timeout, and the build FAILs if any case hangs (DoS), crashes by signal (e.g. SIGSEGV/stack-overflow), exits above its declared `max_exit`, or leaks the env canary / a `must_not_contain` marker (e.g. `/etc/passwd` content). This is a run-proof, not a posture claim.
Common failure: the target hangs on a deeply-nested or huge input, crashes on hostile input, or echoes a secret/traversal marker in its output; or the manifest declares zero cases (a probe that runs nothing is not proof); or `perl`/`jq` is missing at ship (under `WALTEUR_TOOLGATE_STRICT=1` an unrunnable probe fail-closes instead of loud-SKIP).
Fix: make the target bound its work (depth/size limits, iterative parse), refuse path-escapes, and never emit secrets; declare a real corpus in `injection-probes.json` (`target.cmd`, `canary`, `timeout_ms`, non-empty `cases[]` with `input`/`gen`/`argv` + `max_exit` + `must_not_contain`); provision `perl` and `jq` in the ship environment.
Bypass: `WALTEUR_INJECTION=off` — bypass is recorded, not free.

## anti-reward-hack-gate
Enforces: no tautological test assertions (`expect(true).toBe(true)`), no empty test bodies, no skipped-but-counted tests without a `reason=`.
Common failure: `expect(X).toBe(X)` (comparing a value to itself) or `it("x", () => {})` with no assertion inside.
Fix: replace the tautology with a real assertion against expected behavior; fill in the empty test body or delete the test; add a `reason=` justification to any `it.skip`/`@pytest.mark.skip`.
Bypass: `WALTEUR_NOREWARDHACK=off` — bypass is recorded, not free.

## structured-output-gate
Enforces: any file that calls an LLM AND consumes its output must validate that output against a schema before use (zod/pydantic/JSON-schema, or a `response_format` param on the call).
Common failure: `response.choices[0].message.content` (or similar) consumed raw with no `.parse()`/`.safeParse()`/schema validation anywhere in that file.
Fix: add schema validation immediately after the model call (zod `.safeParse()`, pydantic `model_validate()`, or pass `response_format`/`schema` on the call itself) before using the output.
Bypass: `WALTEUR_STRUCTOUT=off` — bypass is recorded, not free.

## pbt-gate
Enforces: at high/regulated risk, pure-logic modules (parsers, money/tax math, auth/authz checks, validators, tokenizers) have at least one property-based test (fast-check/Hypothesis/proptest), not just example-based unit tests.
Common failure: a `price`/`tax`/`auth` module exists with only hand-picked example unit tests, no `fc.property`/`@given`/`proptest!` anywhere.
Fix: add a property-based test that hammers the module with generated inputs (fast-check for JS/TS, Hypothesis for Python, proptest for Rust) covering the edge cases example tests miss.
Bypass: `WALTEUR_PBT=off` — bypass is recorded, not free.

## mutation-gate
Enforces: `mutation-report.json`'s `.score` meets `WALTEUR_MUT_MIN` (default 80); a high/regulated build WITH tests but NO mutation report also FAILs.
Common failure: the test suite's mutation score is below 80 (tests execute the code but don't actually catch injected bugs), or no mutation testing was ever run on a high-risk build with tests.
Fix: run a mutation-testing tool (Stryker/mutmut/cargo-mutants) and strengthen tests that don't kill the reported surviving mutants until the score clears the floor.
Bypass: `WALTEUR_MUTATION=off` — bypass is recorded, not free.

## blast-radius-gate
Enforces: on a brownfield edit, every cross-cutting symbol touched (shared util/base class/shared type) records `callers_checked:true` + a non-empty impact assessment in `blast-radius.json`.
Common failure: an edit to a shared util with `callers_checked` false/missing, or an empty impact assessment.
Fix: actually search for and check every caller of the touched shared symbol, then record `callers_checked:true` with a real, non-empty summary of what you checked and what changed for them.
Bypass: `WALTEUR_BLASTRADIUS=off` — bypass is recorded, not free.

## intent-reconstruction-gate
Enforces: on a brownfield build with no existing PRD, `INTENT.md` reconstructs the app's original purpose with confidence labels (confirmed/inferred/unknown) and evidence refs (file:line) — not a guess sold as fact.
Common failure: `INTENT.md` missing a confidence label or an evidence reference (the two load-bearing fields) — a guess presented as certainty.
Fix: for every claim in `INTENT.md`, add a confidence label and at least one `file:line` evidence reference backing it; if a fact can't be confirmed, label it `inferred` or `unknown` honestly rather than omitting the label.
Bypass: `WALTEUR_INTENT=off` — bypass is recorded, not free.

## baseline-capture-gate
Enforces: a brownfield build captures a real 'before' snapshot (`baseline.json`) — build/test status, numeric dimension scores, characterization-test status — before touching anything.
Common failure: `baseline.json` missing a `dimensions[]` numeric score, or `characterization.status` set without the required `command|path` (present) or `reason` (absent-with-reason).
Fix: run the existing test/build suite and record its real status; score each dimension numerically; either point to a real characterization/golden-master command, or give an honest reason it's absent.
Bypass: `WALTEUR_BASELINE=off` — bypass is recorded, not free.

## non-regression-gate
Enforces (terminal, brownfield): every baseline dimension is `after >= before` (or carries a signed waiver), characterization status is green, and every intentional behavior change has a signed ADR.
Common failure: a dimension regressed (`after < before`) with no `waiver_ref`, or a behavior change with no matching `adr_ref`.
Fix: fix the regression until the dimension clears its baseline value, or get a real signed waiver on record; write an ADR for any intentional behavior change and reference it from `non-regression.json`.
Bypass: `WALTEUR_NONREGRESSION=off` — bypass is recorded, not free.

## memory-staleness-gate
Enforces: every `playbook.json`/`.jsonl` entry has a `valid_until` date that is not in the past (fail-closed on missing/unparseable dates too).
Common failure: a playbook entry's `valid_until` date has passed, or the field is missing/malformed entirely.
Fix: re-verify the stale fact against current reality and set a fresh `valid_until`; if the fact is genuinely still true, re-date it — never leave a past date on record.
Bypass: `WALTEUR_MEMSTALE=off` — bypass is recorded, not free.

## otel-gate
Enforces: any `has_api_boundary` build has traces+metrics+logs+traceparent propagation, either via `observability.json` or real OpenTelemetry code.
Common failure: an API boundary at high/regulated risk with neither an `observability.json` manifest nor any `@opentelemetry`/OTLP code in source.
Fix: wire OpenTelemetry (or another tracing SDK) into the service and declare all four pillars (`traces`, `metrics`, `logs`, `traceparent`) as `true` in `observability.json` once wired for real.
Bypass: `WALTEUR_OTEL=off` — bypass is recorded, not free.

## loop-readiness-gate
Enforces: any declared autonomous loop (L2/L3) has the hard L3 controls — a maker/checker verifier, state, a safety path-denylist, a token budget, a run log, a kill switch — and scores >=78 on the loop-readiness rubric.
Common failure: a build claims L3 (unattended) but is missing one of the six hard controls (commonly: no kill switch, or no path-denylist).
Fix: add the missing control for real (e.g. a `PAUSED`-style kill switch, a documented safety denylist of paths the loop must never touch), then re-score; do not claim a level the loop hasn't earned.
Bypass: `WALTEUR_LOOPREADY=off` — bypass is recorded, not free.

## anti-slop-prose-gate
Enforces: user-facing copy (under `copy/`, `content/`, `marketing/`, etc, or `copy-manifest.json`) avoids AI-slop phrasing — "Here's the thing:", "it's not X, it's Y", "the data tells us", "let me walk you through".
Common failure: a landing-page or onboarding copy file with a telegraphed binary contrast or ChatGPT-throat-clearing phrase.
Fix: rewrite the flagged line in a real human voice specific to your product — delete the meta-commentary, state the point directly. Per-line override for a deliberate exception: `<!-- slop-ok -->` or `// slop-ok`.
Bypass: `WALTEUR_PROSESLOP=off`. Tunable: `WALTEUR_PROSESLOP_MAX` (default 0) — bypass is recorded, not free.

## harness-self-audit-gate
Enforces: the WALTEUR harness scaffold itself (gate count, six-dimension score) never silently regresses below its committed baseline floor (default 70).
Common failure: a gate was accidentally deleted or disabled, dropping the live gate count below the baseline snapshot.
Fix: restore the missing/disabled gate, or if the change is intentional (a deliberate consolidation), re-baseline explicitly with `WALTEUR_SELFAUDIT=rebaseline` — never silently let coverage erode.
Bypass: `WALTEUR_SELFAUDIT=off` — bypass is recorded, not free.

## integrator-audit-gate
Enforces: a FRESH adversarial cross-model (Codex) verdict receipt ending exactly `VERDICT: SHIP` exists in `walteur-kit/integrator/` for the current build, produced read-only via the rocket-fuel driver (`~/.claude/skills/rocket-fuel/scripts/rf-codex.sh`, override `WALTEUR_RF_CODEX`) and parsed deterministically by `rf-codex.sh verdict` — a second model must fail to break the build before it ships.
Common failure: no receipt at ship (attack never run), a `VERDICT: REVISE` receipt (findings still open), or a receipt older than the newest source file (scope moved after the verdict).
Fix: write an honest adversarial brief (adversarial framing, default-verdict-is-REVISE, exact SHIP/REVISE ending instruction), run `rf-codex.sh start read-only <root> walteur-kit/integrator <brief> ship-audit-r1`, fix every finding, `resume` the SAME thread as ship-audit-rN until the last line is `VERDICT: SHIP`. Codex down (usage-limit/model/auth)? Write `walteur-kit/integrator/DEGRADED.json` {rc,reason,ts} AND an approved `accepted_risk` signoff covering `integrator-audit-gate` in `autopilot/STATE.json` — loud, recorded, never silent.
Bypass: `WALTEUR_INTEGRATOR=off` — bypass is recorded, not free.

## excellence-loop-gate
Enforces: the §3.x refine loop exits only legitimately — `scoreboard.json refine_history` shows a PLATEAU (two consecutive refined-and-re-proved all-green rounds with no composite improvement; a first-round all-green — even 100/100 — is never terminal; an unrefined repeat is idling, not a plateau) or the `refine_max` cap with residual deductions PRESENTED (`scoreboard.residuals` or owned `STATE.known_gaps`). Green is the floor, not the finish.
Common failure: shipping on the first all-green round (no falsification cycle), or a capped loop with no residuals presented.
Fix: run one more REFINED-and-re-proved cycle (a genuine refinement attempt, all proofs re-run) and append it to `refine_history`; if the cap is hit, list every residual deduction with evidence in `scoreboard.residuals` instead of claiming convergence.
Bypass: `WALTEUR_EXCELLENCE=off` — bypass is recorded, not free.

## hollow-artifact-gate
Enforces: a server/route handler that a build with `has_db`/`has_api_boundary` declares must actually call a DB/query/fetch — no hard-coded static-empty (`[]`/`{}`) or mock response with nothing real behind it.
Common failure: a route handler returns `res.json([])` (or a hardcoded mock array) with no database/query/fetch call anywhere in the file.
Fix: wire the handler to a real data-access call (query/fetch/ORM call); if a genuinely-empty response is correct for this route, mark it explicitly with `// hollow-ok` (or `<!-- hollow-ok -->`) and explain why.
Bypass: `WALTEUR_HOLLOW=off`. Tunable: `WALTEUR_HOLLOW_MAX` (default 0) — bypass is recorded, not free.

## skill-quality-gate
Enforces: every `SKILL.md` has a routable name+description, and the library's composite quality score doesn't drop below the floor (default 70); any skill scoring <40 is BROKEN and fails closed.
Common failure: a `SKILL.md` with no `description` field (unroutable — the model can never tell when to fire it), or an oversized 900-line body with no progressive disclosure.
Fix: write a specific, trigger-clear `description` naming exactly when the skill should fire; break an oversized SKILL.md into a short main file + referenced detail docs (progressive disclosure).
Bypass: `WALTEUR_SKILLQUAL=off`. Tunable: `WALTEUR_SKILLQUAL_FLOOR` (default 70) — bypass is recorded, not free.

## data-correctness-gate
Enforces: SQL/analytics code avoids join-explosion (COUNT/SUM over a JOIN without DISTINCT), average-of-averages, nested aggregates, and unguarded division (no NULLIF).
Common failure: `SELECT COUNT(*) FROM orders JOIN items ...` with no `DISTINCT` (row inflation from the join fan-out), or `a / b` with no `NULLIF(b, 0)` guard.
Fix: add `DISTINCT` (or restructure via a subquery) to prevent join-fan-out double counting; wrap the divisor in `NULLIF(b, 0)`; replace an average-of-averages with a properly weighted aggregate. Per-line override: `-- data-ok`.
Bypass: `WALTEUR_DATAQA=off`. Tunable: `WALTEUR_DATAQA_MAX` (default 0) — bypass is recorded, not free.

## context-compaction-gate
Enforces: inherited working context (briefs+SUMMARY+BATON+STATE) stays under the 200k-token handoff ceiling, and a build carrying real context declares an automatic (not human-required) compaction policy once past 150k tokens.
Common failure: aggregate context exceeded 150k tokens with no `compaction-policy.json` declared, or the declared policy has `mode` other than `automatic`.
Fix: compress/prune the oversized handoff artifacts now (summarize stale briefs, evict what a fresh agent doesn't need); author `compaction-policy.json` with `mode:"automatic"`, `compact_at<=150000`, `handoff_at<=200000`.
Bypass: `WALTEUR_COMPACT=off` — bypass is recorded, not free.

## persona-coverage-gate
Enforces: every persona `personas.json` + preflight signals say is REQUIRED for this build left an engagement breadcrumb at `walteur-kit/personas/<id>.json` (not FAIL/SKIP).
Common failure: a required specialist persona (e.g. Senior Cybersecurity Analyst on a security-relevant build) never actually engaged — no breadcrumb file, or one recording FAIL/SKIP.
Fix: actually engage the required persona/role for this build and have it write a real breadcrumb with its findings; do not fabricate an engagement that didn't happen.
Bypass: `WALTEUR_PERSONA=off` — bypass is recorded, not free.

## apple-grade-design-gate
Enforces (now unconditional on any user-facing build, not just high/regulated): a tight type scale (<=8 steps), a 4/8pt spacing grid, <=6 raw hex colors (semantic tokens instead), motion present, and a declared design system (DESIGN.md).
Common failure: more than 8 distinct font-size steps in the stylesheet, or off-grid spacing values (e.g. `padding: 13px`) not on the 4pt grid.
Fix: consolidate the type scale down to <=8 steps; snap every spacing value to the 4/8pt grid; replace raw hex colors with semantic design tokens (down to <=6 raw hex uses); add real transitions/motion. Per-line override for an intentional exception: `/* apple-ok */`.
Bypass: `WALTEUR_APPLE=off`. Tunables: `WALTEUR_APPLE_TYPESTEPS` (default 8), `WALTEUR_APPLE_OFFGRID` (default 8) — bypass is recorded, not free.

## design-contrast-gate
Enforces: a UI project that declares `walteur-kit/contrast-pairs.json` has every declared text/background pair COMPUTED against the WCAG 2.1 AA contrast floor — 4.5:1 for normal text, 3.0:1 for large text (`"large":true`) — using real relative-luminance math (sRGB linearization → luminance → ratio), not regex hex-counting. This is the perceptual-accessibility check the CSS-hygiene gates cannot do.
Common failure: a text/bg pair below its floor (e.g. a "subtle" gray `#838395` on white = 3.72:1 < 4.5). Absent manifest but UI/CSS source present → FAIL (contrast is unverifiable and must not silently pass). Malformed manifest or a bad hex → FAIL. `jq` missing honors `WALTEUR_TOOLGATE_STRICT` (fail-closed at ship, loud-SKIP off-ship).
Fix: darken/lighten the offending token until its computed ratio clears the floor (the report lists each pair's `ratio`), then re-run; declare all critical text/bg pairs (both light and dark themes) in `contrast-pairs.json` as `{name, fg, bg, large}` hex. Use `bash design-contrast-gate.sh --ratio <fg> <bg>` to compute a single pair.
Bypass: `WALTEUR_DESIGN_CONTRAST=off` — bypass is recorded, not free.

## design-scale-gate
Enforces: a UI project that declares `walteur-kit/design-scale.json` has three token invariants COMPUTED (sibling to `design-contrast-gate`, opt-in): (1) the type ramp `type_scale_px` (in ascending intended order) is strictly increasing + distinct — catches an inverted/duplicate token; (2) every `spacing_px` token is an integer multiple of the author-declared `spacing_base_px` (≥2) — catches an off-grid stray (a lone 13px on a 4px grid); (3) every `tap_targets[].min_px` is ≥44px (WCAG 2.5.5 / Apple HIG minimum touch size). It deliberately does NOT demand a constant modular ratio — a legit hybrid scale (tight UI steps + a big display jump, e.g. 12/13/15/17/20/28/64) must pass; a naive constant-ratio check would false-positive on it.
Common failure: a non-monotonic type token, a spacing value off the declared base grid, or a tap target below 44px. Absent manifest → NOT_APPLICABLE (opt-in; unlike contrast it is not forced). `jq` missing honors `WALTEUR_TOOLGATE_STRICT` (fail-closed at ship, NOT_APPLICABLE off-ship).
Fix: reorder/dedupe the type ramp; move the stray spacing token onto the base grid (or declare the real base); raise the too-small tap target to ≥44px; keep `design-scale.json` in sync with the stylesheet tokens (copy values verbatim).
Bypass: none needed — the gate is opt-in (no manifest = NOT_APPLICABLE).

## test-claim-verifier-gate
Enforces: a "tests pass" claim (QA report PASS + recorded command, or `test-claim.json`) is RE-RUN for real and blocked on a non-zero exit — never trusted from assertion alone.
Common failure: the recorded test command is a constant-exit/no-op (`true`, `bash -c 'exit 0'`) — refused outright — or the real re-run genuinely fails.
Fix: record the ACTUAL test-runner command (`npm test`, `pytest`, etc — never a stub) and make sure it truly passes when re-run; fix the real failing test(s) the re-run surfaces, don't paper over them.
Bypass: `WALTEUR_TESTCLAIM=off`. Skip the live run (record intent only): `WALTEUR_TESTCLAIM_DRYRUN=on` — bypass is recorded, not free.

## gate-suite
Enforces (meta-harness): every registry gate's `--selftest` reports N/N green; a skip-budget caps how many gates may `cannot_measure` (missing tool) before the whole suite FAILs.
Common failure: one gate's `--selftest` itself started failing (a regex/quoting edit broke it), or too many gates are `cannot_measure` (missing jq/perl/etc) — over `WALTEUR_GATESUITE_MAXCANNOT` (default 8).
Fix: run the named gate's own `--selftest` directly to see which assertion broke, and fix that gate's logic (see its own REMEDIATION row); install the missing tool(s) driving the `cannot_measure` count down.
Bypass: `WALTEUR_GATESUITE=off`. Per-gate timeout: `WALTEUR_GATESUITE_TIMEOUT` (default 150s) — bypass is recorded, not free.

## tool-liveness-probe
Enforces: every required tool actually EXECS successfully (not just `command -v` present) — catches a dead/broken shim (exit 126/127) that `command -v` would miss.
Common failure: a stale pipx/npm/uv/winget shim on PATH that `command -v` finds but that fails to actually execute (exit 126/127) after a runtime upgrade.
Fix: reinstall the broken tool's shim (`pipx reinstall <tool>` / `npm i -g <tool>` / `winget upgrade <tool>`); if the tool is genuinely optional here, mark it `required:false` in `required-tools.json`.
Bypass: `WALTEUR_TOOLPROBE=off` — bypass is recorded, not free.

## skill-frontmatter-gate
Enforces: every `SKILL.md`'s frontmatter has a valid kebab-case `name` (<=64 chars, no leading/trailing/double hyphen) and a `description` (<=1024 chars, no raw `<`/`>`), with no unknown keys.
Common failure: a `description` containing a raw `<`/`>` character (breaks the loader), or a `name` with a double hyphen or uppercase letters.
Fix: fix the `name` to valid kebab-case; escape or remove raw angle brackets from `description`; remove or rename any frontmatter key outside the allowed set (or set `WALTEUR_SKILLFM_STRICT=on` only once you've cleaned it up).
Bypass: `WALTEUR_SKILLFM=off` — bypass is recorded, not free.

## review-egress-redaction-gate
Enforces: any payload handed to an external reviewer model is proven secret-free (active re-scan, not trust the manifest) AND carries recorded consent.
Common failure: a `council-egress.json` handoff with `consent.granted != true`, or a payload file that still contains a live secret (private key, `sk-`/`ghp_`/`AKIA` token, JWT, connection string) despite a claimed "redaction:PASS".
Fix: actually redact the live secret from the payload file (replace with `<REDACTED>`) before sending it to any external reviewer; get and record real consent (`consent.granted:true`) before the handoff.
Bypass: `WALTEUR_EGRESS=off` — bypass is recorded, not free.

## data-acquisition-gate
Enforces: any declared external data pull routes through a vetted tool (`data-tools.json`), records provenance, proves robots/PII handling, and — for high-risk tools (curl_cffi/browser-use/crawlee) — carries a legal signoff.
Common failure: a source's `tool_id` isn't in the vetted catalog (an ad-hoc scraper), or `robots_checked`/`pii_scanned` is false/missing, or a high-risk tool has no `legal_signoff`.
Fix: route the acquisition through a catalog-vetted tool (or add the tool to `data-tools.json` with a real risk rating first); actually check `robots.txt` and PII-scan the captured content, recording both as true; get and record a legal signoff before using a high-risk tool.
Bypass: `WALTEUR_DATAACQ=off` — bypass is recorded, not free.

## stamp-integrity-gate
Enforces: `STAMP.md`'s dated history rows are immutable — every row's live sha256 must match `stamp-chain.json`'s recorded hash; a row can never be deleted or altered (only new rows appended).
Common failure: a `STAMP.md` history row was hand-edited or deleted, so its live content no longer hashes to the value recorded in `stamp-chain.json`.
Fix: never hand-edit `STAMP.md` — restore the original row content exactly as recorded, or if a genuine correction is needed, append a NEW row via `stamp.sh` rather than altering history.
Bypass: `WALTEUR_STAMP=off` — bypass is recorded, not free.

## dead-code-gate
Enforces: `knip` (JS/TS unused-export/file/dependency scanner) reports zero issues (or under `WALTEUR_KNIP_MAX`, default 0) — a REAL run, not a shape-read.
Common failure: knip finds a real unused export/file/dependency, or knip itself errors (exit >=2, a config problem).
Fix: remove the genuinely unused export/file/dependency knip flagged, or add a legitimate `knip.json` ignore entry if it's a false positive (e.g. a dynamically-loaded module); if knip itself errors, fix its config.
Bypass: `WALTEUR_DEADCODE=off`. Install knip if absent (currently a loud SKIP, not a pass) — bypass is recorded, not free.

## db-health-gate
Enforces: `orm-doctor` (Prisma/Drizzle AST scanner: N+1 queries, missing FK indexes, unsafe raw SQL, mass mutations without WHERE) reports no critical finding and a score >= `WALTEUR_ORMSCORE_MIN` (default 90).
Common failure: a real N+1 query pattern, a mass `updateMany`/`deleteMany` with no WHERE clause, or a missing index on a foreign key.
Fix: fix the flagged N+1 (eager-load or batch the query), add the missing FK index, add a WHERE clause to the mass mutation, or wrap the raw-SQL call in a parameterized query.
Bypass: `WALTEUR_DBHEALTH=off`. Install orm-doctor if absent (currently a loud SKIP) — bypass is recorded, not free.

## security-scan-gate
Enforces: `medusa` (AI-first security scanner: Log4Shell/Spring4Shell/LangChain-RCE/MCP-poisoning/prompt-injection + secrets) reports zero findings (or under `WALTEUR_MEDUSA_MAX`, default 0) — a real observed run.
Common failure: a real medusa finding (a known-vulnerable pattern or an exposed secret it caught that other scanners missed).
Fix: fix the flagged vulnerability pattern directly; rotate any secret medusa's scan surfaced. If medusa is genuinely absent, install it (AGPL-3.0, used as an external CLI only — never vendor its source) to get real coverage instead of a SKIP.
Bypass: `WALTEUR_SECSCAN=off`. Command override: `WALTEUR_MEDUSA_CMD` — bypass is recorded, not free.

## execution-ratio-gate
Enforces: on a code `build_class`, a meaningful fraction of applicable gates actually EXECUTED+observed something (not just shape-read their own self-written JSON), and `cannot_measure` (tool-absent) reports stay under a skip budget.
Common failure: `0%` executed — gates declared PASS without running anything real (arm the executor gates), or too many `cannot_measure` SKIPs (install the missing tools).
Fix: arm the executor gates (`WALTEUR_*_EXEC=1`) so they re-run real tests/probes instead of trusting a stale JSON; install the missing tools (jq/perl/knip/orm-doctor/medusa) driving `cannot_measure` down; if the build genuinely has no executors that apply, set `build_class` honestly (doc/content) rather than faking execution.
Bypass: `WALTEUR_EXECRATIO=off` — bypass is recorded, not free.

## chaos-resilience-gate
Enforces: at high/regulated risk (or a declared SLO target), a REAL chaos/game-day drill happened — a fault was injected, a steady-state metric observed, recovery confirmed with evidence — never merely a resilient-looking config.
Common failure: `chaos-report.json` missing/stale (>30 days default) on a high-risk build, or a drill with `recovered:false` and no signed risk-acceptance ref.
Fix: run a real drill (kill a pod, cut a dependency, inject latency), record the hypothesis/fault/steady-state metric/recovery evidence fresh in `chaos-report.json`; if a drill genuinely failed to recover, get a signed risk-acceptance before it can stay on record.
Bypass: `WALTEUR_CHAOS=off` — bypass is recorded, not free.

## secret-rotation-gate
Enforces: when `secrets-policy.json` declares secrets, NONE are committed as literals (active scan), every declared secret is sourced from a managed store (kms/vault/secret-manager/env-injected, never hardcoded), and rotation stays within `rotation_max_age_days`.
Common failure: a declared secret's `last_rotated` is older than its `rotation_max_age_days`, or a committed literal the active perl scan catches.
Fix: rotate the overdue secret now and update `last_rotated`; move any hardcoded secret to your managed store (KMS/Vault/secret manager) and remove the literal from tracked source.
Bypass: `WALTEUR_SECRETROT=off` — bypass is recorded, not free.

## zero-downtime-cutover-gate
Enforces: a deploy/cutover has a proven rollback — `cutover-plan.json` with an allowed strategy (blue-green/canary/expand-contract/rolling), a real `rollback_command`, a FRESH `rollback_proof` (exit 0), every migration reversible or justified, and a health check.
Common failure: `cutover-plan.json`'s `rollback_proof.ran_ts` is stale, or `strategy` isn't one of the allowed values, or a listed migration has `reversible:false` with no signed justification.
Fix: re-run the rollback drill and record a fresh `rollback_proof`; switch `strategy` to blue-green/canary/expand-contract/rolling; get a signed expand-contract justification for any genuinely-irreversible migration in the cutover.
Bypass: `WALTEUR_CUTOVER=off`. EXEC (re-run the rollback command for real and observe): `WALTEUR_CUTOVER_EXEC=1` — bypass is recorded, not free.

## slo-error-budget-gate
Enforces: any in-scope service has `slo.json` with an errors SLO AND a latency SLO, every SLO bound to a real alert, a non-dangling alert set, a valid error-budget percentage, real dashboard refs, and `logging.structured:true`.
Common failure: an SLO with no matching entry in `alerts[]` (unwatched SLO), or `logging.structured` false/missing.
Fix: add an alert bound to every declared SLO (`alerts[].slo` must match an `slos[].name`); set `logging.structured:true` once structured logging is actually wired; fix any dangling alert that references a nonexistent SLO name.
Bypass: none documented in this header excerpt — treat as always-on when the build is in scope (has_api_boundary / external_surface / is_cloud_iac / code build_class).

## flaky-test-gate
Enforces: no test uses `retryTimes`/`this.retries`/`.retry(`/`retries: N` to mask a real race instead of fixing it.
Common failure: a `jest.retryTimes(3)` or `retries: 2` config re-running a flaky test until it goes green.
Fix: remove the retry wrapper and fix the underlying race (await the real condition, mock time/RNG/network) instead of hiding it. See skill `loopkit-flaky-hunter`.
Bypass: `WALTEUR_FLAKY=off` skips entirely; default is WARNING-FIRST (exit 0 + WARN); arm blocking with `WALTEUR_FLAKY=hard` — bypass is recorded, not free.

## report-integrity-gate
Enforces: freshness (`.ts` within `WALTEUR_REPORT_MAXAGE`h, default 72) and coherence (no PASS report with a nonzero `observed_exit`; no `*_executed:true` marker without an `.observed_exit` field) across every `walteur-kit/*-report.json`.
Common failure: FAIL only occurs under `WALTEUR_REPORT_INTEGRITY=hard`. A freshness finding means a report is stale — re-run the named gate. A coherence finding (PASS + nonzero `observed_exit`) means that gate wrote a self-contradictory report — fix that gate's report-writing logic. A coherence finding (`*_executed` marker with no `observed_exit`) means the marker was set without recording what was actually observed.
Fix: re-run the named gate to refresh its `.ts` (or raise `WALTEUR_REPORT_MAXAGE`); for a coherence finding, fix the offending gate's report-writing code to either drop the contradictory field or record the real `observed_exit` alongside any `*_executed` marker.
Bypass: `WALTEUR_REPORT_INTEGRITY_GATE=off` (distinct from `WALTEUR_REPORT_INTEGRITY=hard/stale`, which controls severity/mode, not bypass) — bypass is recorded, not free.

## data-pull-required-gate
Enforces: a build that declares it needs live external data (`build-contract.json .data_needs:true` or `preflight-signals.json .needs_external_data:true`) produced a real, fresh acquisition breadcrumb — closes the "passes by being empty" hole.
Common failure: `walteur-kit/acquisition-log.jsonl` is absent, or every line's artifact is missing/under 64 bytes, or every line is outside the freshness window (default 24h).
Fix: append a real line to `acquisition-log.jsonl` for each actual pull — `{"ts":"<RFC3339 UTC now>","source":"<data-tools.json id or WebSearch/WebFetch>","query_or_url":"<the query or URL>","artifact":"walteur-kit/data/<file>","bytes":<n>}` — and save the real captured content (>=64 bytes) at that artifact path. Stale entries (older than `WALTEUR_DATAPULL_WINDOW_H`, default 24h) don't count — re-pull within the current build window.
Bypass: `WALTEUR_DATAPULL=off` — bypass is recorded, not free.

## field-ship-verify-gate
Enforces: any `field-runs/SHIPPED.md` row claiming `verified` for an npm/GitHub target actually resolves (real registry/API check), and every `verified` claim has a checkable target or an explicit internal-only disclaimer.
Common failure: a row claims `verified` for an npm package/GitHub repo that doesn't resolve (404 / unpublished), or claims `verified` with no checkable target and no internal-only disclaimer.
Fix: mark the row `attested` until the ship is real, add an explicit internal-only disclaimer (e.g. "NOT public, no external URL") if it's genuinely local-only, or make the claim true (`npm publish` / `gh repo create --push` per PUBLISH-RUNBOOK.md) so the check actually resolves. See `walteur-kit/field-ship-report.json` for which row and why.
Bypass: `WALTEUR_FIELDSHIP=off` — bypass is recorded, not free.

## remediation-coverage-gate
Enforces: this page keeps up with the registry — every registered gate id has a `## <gate-id>` fix-recipe anchor here, and every hook under `walteur-kit/hooks/` honors the documented `--help` contract (prints help, exits 0, no side effects).
Common failure: a new gate was registered without adding its recipe row here, or a new hook shipped without a `--help` arm.
Fix: add the missing `## <gate-id>` section (Enforces / Common failure / Fix / Bypass, matching the rows above), or add the standard early `--help` arm to the hook (print gate id + purpose + usage + report path + bypass env, `exit 0` before any side effect). `walteur-kit/remediation-coverage-report.json` lists exactly which ids/hooks are missing.
Bypass: `WALTEUR_REMEDIATION_COVERAGE=off` — bypass is recorded, not free.

## team-coordination-gate
Enforces: a TEAM MODE run (5-7 named Claude Code terminals on the peerbus, `walteur-kit/team/`) left coherent, non-forged receipts: registry peers/board actors/message correspondents all in `team-manifest.json`, heartbeats independent (not byte-identical), every done task claimed first (claim ts ≤ done ts), no builder marking own work done, well-formed message envelopes.
Common failure: a task was moved to done by its own builder (review is mandatory — TEAM-PROTOCOL §3), or the board/registry was hand-edited instead of driven through the peerbus tools.
Fix: route ALL board transitions through the peerbus (`board_claim`/`board_update`) — have SENTINEL or PROBE re-review and close the task; never hand-edit `_team/*.json`. If a peer crashed mid-claim, release the task to backlog with a note and let the log show it. `walteur-kit/team-coordination-report.json` names each violation.
Bypass: `WALTEUR_TEAM_GATE=off` — bypass is recorded, not free.

## canonical-staging
Enforces: the canonical-kit-staging area does not silently diverge from the shipped kit.
Common failure: a hook was edited under `walteur-kit/hooks/` but its `canonical-kit-staging/` copy (or vice-versa) was not reconciled.
Fix: diff the staged copy against the canonical file and reconcile them; delete the staged copy if it is no longer the source of truth.
Bypass: `WALTEUR_CANONICAL_STAGING=off` — recorded, not free.

## container
Enforces: container images ship with a vulnerability scan (trivy/grype) or a persisted SBOM.
Common failure: a Dockerfile/compose file is present but no image scanner is installed and no SBOM was generated.
Fix: install trivy or grype (or generate an SBOM with syft), re-run, and resolve any HIGH/CRITICAL image CVEs.
Bypass: `WALTEUR_CONTAINER=off` — recorded, not free.

## edge-protection
Enforces: an HTTP server declares rate-limiting/caching (or a signed `layers.json` deferral) before ship (§14 law).
Common failure: a server listens with no rate-limit, cache, or CDN signal and no signed deferral.
Fix: add a rate limiter and cache/CDN headers, OR sign a `walteur-kit/layers.json` deferral entry that owns the risk.
Bypass: `WALTEUR_EDGE=off` — recorded, not free.

## gate-utilization
Enforces: gates actually EXECUTE against the real project, not just pass hermetic selftests (execution ratio floor).
Common failure: the aggregate is green but few gates ran a real tool/probe against the working tree.
Fix: run the gates against the real project and provision the backing scanners so gates execute instead of loud-skip.
Bypass: `WALTEUR_EXECRATIO=off` — recorded, not free.

## guarddog
Enforces: dependencies are scanned for novel-malware heuristics (guarddog).
Common failure: guarddog is not installed, so the novel-malware surface is unscanned.
Fix: `pip install 'guarddog>=3.0'` and re-run; set `WALTEUR_GUARDDOG=hard` on the ship path to block heuristic hits (or `GUARDDOG_FIXTURE` to verify offline).
Bypass: `WALTEUR_GUARDDOG=off` — recorded, not free.

## lesson-gate
Enforces: the self-improvement capture loop is alive — `lessons.jsonl` exists and is fresh.
Common failure: the store is missing/stale, or `WALTEUR_MEM` points at a different path than the campaign captures to.
Fix: capture a lesson (`echo JSON | bash walteur-kit/hooks/lesson-gate.sh --capture`), point `WALTEUR_MEM` at the live store, and mark recalled lessons with `--apply <id>`.
Bypass: `WALTEUR_LESSON=off` — recorded, not free.

## observe-probe
Enforces: the build emits observability signals (tracing/metrics/structured logs).
Common failure: a service has no telemetry, so production failures would be invisible.
Fix: add structured logging plus a metrics/trace signal (OpenTelemetry or equivalent) on the critical paths.
Bypass: `WALTEUR_OBSERVE=off` — recorded, not free.

## opengrep
Enforces: source is scanned for taint/injection flaws by a SAST engine (opengrep).
Common failure: the opengrep binary is absent, so the SAST surface is unscanned.
Fix: install the opengrep binary, re-run, and resolve reported taint findings.
Bypass: `WALTEUR_OPENGREP=off` — recorded, not free.

## self-heal
Enforces: a prior-run defect flagged by the self-heal phase is resolved before proceeding.
Common failure: the self-heal span recorded a defect (failed gate, broken invariant) that was never fixed.
Fix: read the self-heal entry in `run-trace.jsonl`, resolve the named defect, and re-run the phase.
Bypass: none — self-heal is an internal recovery phase, not a toggle.

## selftest
Enforces: the aggregate self-test (`walteur-kit/selftest.sh`) is green — every gate's hook-local proof passes.
Common failure: a gate's `--selftest` regressed, or an edit broke a fixture.
Fix: run `bash walteur-kit/selftest.sh`, read the first FAIL line, fix that gate, and re-run until 0 failed.
Bypass: none — the aggregate proof is the harness's own truth.

## story-coverage
Enforces: each UI component ships stories for its Default, Loading, and Error states.
Common failure: a `*.stories.tsx` exists but is missing the Error (or Loading) export.
Fix: add the missing story export(s) so every state the component can render is documented and testable.
Bypass: `WALTEUR_STORY=off` — recorded, not free.

## tool-liveness
Enforces: a declared-required tool is actually installed and runnable, not just named.
Common failure: `tool-acquisition.json` declares a tool that is absent or broken on this host.
Fix: install/repair the tool via the lockfile-backed tool-acquisition flow and re-run the liveness probe.
Bypass: `WALTEUR_TOOL_LIVENESS=off` — recorded, not free.

## twin-invariant
Enforces: the mirror twins (`walteur/SKILL.md` and `WALTEUR-builder-CLAUDE.md`) stay byte-identical in their mirrored regions.
Common failure: one twin was edited without applying the same edit to the other.
Fix: re-sync the two files so the mirrored content is byte-identical; verify with the twin-invariant selftest.
Bypass: none — twin drift is a correctness invariant.

## worktree
Enforces: parallel git-worktree isolation is clean (create -> merge -> cleanup) with same-file conflicts detected.
Common failure: a worktree merge left conflicts, or cleanup did not remove the temporary worktree.
Fix: resolve the same-file conflict, complete the merge, and ensure the temporary worktree was removed; re-run the isolation proof.
Bypass: none — isolation correctness is not optional.

## non-generic-design-gate
Enforces: the UI is not generic-looking, *measured* — `pbakaus/impeccable`'s 65 offline anti-pattern detector rules run over the UI files and the finding count must be `<= WALTEUR_SLOP_MAX` (default 0). No LLM, no API key, deterministic.
Common failure: real anti-patterns fired (the report's `findings[]` names each rule id + file), or the gate SKIPped — no impeccable checkout at `~/AI-Brain-build/impeccable`, no `node`, or no UI files to scan. A SKIP is **cannot_measure**, not a pass.
Fix: read `walteur-kit/non-generic-design-report.json` → `findings[]` and fix the named rule in the named file (each rule id maps to an impeccable detector). For a SKIP: clone impeccable (or point `WALTEUR_IMPECCABLE` at your checkout), install `node`, and re-run. Do **not** raise `WALTEUR_SLOP_MAX` to clear real findings — that threshold exists for a deliberate, recorded tolerance, not to hide slop. Output the gate cannot parse is treated as failure-to-VERIFY, so a parse error means fix the invocation, not the threshold.
Config: `WALTEUR_IMPECCABLE` (checkout path) · `WALTEUR_SLOP_MAX` (default 0) · `WALTEUR_UI_GLOB_DIR` (scan dir, default auto-detect from repo root).
Bypass: `WALTEUR_NON_GENERIC_DESIGN=off` — recorded, not free.
Anchor note: the hook writes `"gate":"non-generic-design"` (short id) while the registry id — and this anchor — is `non-generic-design-gate`. `doctor.sh` resolves the short id onto this heading via its `<id>-gate` suffix rule, so the triage pointer is live.

## registry-report-contract-gate
Enforces: for every gate whose hook declares a static top-level `REPORT="$KIT/..."`, `gate-registry.json`'s `report` field names **that exact path**. A registry that names a file the hook never writes makes the gate UNOBSERVABLE — the report is permanently absent, and a reader that treats absence as "nothing said FAIL" reads it as green.
Common failure: a hook's `REPORT=` path was renamed without updating its registry row. Found live 2026-07-25 in 3 of 148 gates (`mutation-gate`, `restore-proof`, `maintainability-gate`) — one of them HARD, so a *blocking* gate could never be observed through its own contract.
Fix: read `walteur-kit/registry-report-contract-report.json`; each mismatch names the gate, the registry-declared path, and the hook's own `REPORT=` path. Change whichever side is wrong — normally the registry row, because the hook's `REPORT=` is what actually gets written. Then prove it: run the hook and confirm the registry-declared file exists afterwards —
`g=<gate-id>; bash walteur-kit/hooks/$g.sh; ls -l "$(jq -r --arg g "$g" '.gates[]|select(.id==$g)|.report' walteur-kit/gate-registry.json)"`.
Do **not** "fix" this by deleting the `report` field or by making the hook's path dynamic: hooks with no static `REPORT=` line are counted **UNCHECKABLE**, never as passing, so hiding a gate from this check does not clear it.
Bypass: `WALTEUR_REGISTRY_REPORT_CONTRACT=off` — recorded, not free. No jq / no registry => LOUD SKIP with the reason stated, never a silent pass.

---

## Non-gate hooks (`--help` fix-pointer targets)

Every hook under `walteur-kit/hooks/` prints `fix recipes: walteur-kit/REMEDIATION.md (## <id>)` in its
`--help`. Most of those ids are registered gates, documented in the index above. The hooks below are
**emitters, runners, and maintenance tools** — real, load-bearing, and *not* registry ids, so
`remediation-coverage-gate` (which checks registry-id anchors) does not cover them. They are documented here
because their `--help` points here, and a fix-pointer that resolves to nothing is a broken promise. Resolve
every pointer in the tree with `bash walteur-kit/hooks/doctor-anchors.sh`.

## doctor
What it is: `walteur-kit/hooks/doctor.sh` — the first-run health check **and** the failure-triage entrypoint. Exit 0 = healthy with zero FAIL reports · exit 1 = a missing tool/registry, a failed core selftest, **or** any `walteur-kit/*-report.json` with `verdict:"FAIL"` · exit 2 = `walteur-kit/PAUSED` present.
Common failure — `exit 1` with a long "Failing gates (N) — triage" list: **doctor itself is fine.** It is reporting other gates' recorded verdicts, including ones written days ago. Work the list: each row gives the gate id, its own `reason`, and a `REMEDIATION.md#<anchor>` pointer. The epilogue names the 3 most-recent failures with their exact re-run command — start there.
Common failure — `FAIL - gate-registry.json missing`: you are not at the repo root. doctor now says so explicitly ("run from the repo root — walteur-kit/ not found here"). `cd` to the git toplevel, or set `WALTEUR_ROOT=/path/to/repo`.
Common failure — `bash: jq: command not found` chains into a degraded report: install jq (`brew install jq` / `winget install jqlang.jq`). A toolless box is **cannot_measure**, not healthy.
Read-only / CI use: `bash walteur-kit/hooks/doctor.sh --dry-run` prints the report to stdout and writes **nothing** — use it as a CI probe or when you must not mutate the tree. `--stdout` is an alias.
Fix (doctor's own logic suspect): `bash walteur-kit/hooks/doctor.sh --selftest` — GOOD/POISONED twins with synthetic fixtures, including a seeded-FAIL triage twin, a self-report-exclusion negative control, and an unknown-flag control. If that is green, doctor is not the bug; the gate it names is.
Bypass: `WALTEUR_DOCTOR=off` — recorded, not free.

## doctor-anchors
What it is: `walteur-kit/hooks/doctor-anchors.sh` — the fix-pointer link checker. Every `--help` pointer (`REMEDIATION.md (## X)`) in every hook, plus every triage anchor `doctor.sh` would emit from a live FAIL report, must resolve to a real `## ` heading in this file. Fails closed (exit 2) on any 404, so "failures explain themselves" can never silently rot again.
Common failure: `DEAD --help pointer` — a hook's `--help` names an anchor that does not exist here. Fix by **writing the section** (real Enforces / Common failure / Fix / Bypass content), not by deleting the pointer.
Common failure: `DEAD triage anchor` — a gate's report writes a `.gate` short id that no heading matches under doctor's `<id>` / `<id>-gate` / `<id>-lint` / `<id>-check` resolution, and no alias covers it. Either add the heading, or (when the report id and the registry slug differ by more than a suffix) add the pair to `REMEDIATION_ALIASES` in `doctor.sh` — the alias is honored **only** if its target heading actually exists.
Fix: `bash walteur-kit/hooks/doctor-anchors.sh` names every dead pointer with its source file. Do not add an exclude to silence one — an excluded pointer is still dead for the operator standing in front of it.
Self-test: `bash walteur-kit/hooks/doctor-anchors.sh --selftest` (hermetic; includes a negative control that seeds a dead pointer and asserts the checker FAILs on it — a checker that cannot fail is theater).
Bypass: `WALTEUR_DOCTOR_ANCHORS=off` — recorded, not free. Kill switch: `walteur-kit/PAUSED` => exit 2.

## ship-gate
What it is: `walteur-kit/hooks/ship-gate.sh` — the HARD terminal gate, wired `PreToolUse` on the `Bash` tool. An internal command-guard makes it a **no-op** unless the command is a real ship transition (`git commit` / `git tag`). Exit 2 on any red.
Common failure — blocked at commit with a named red: it checked, in order, (1) command-guard (2) `walteur-kit/PAUSED` (3) `PLAN.md` present (4) refine-gate: DoD complete **and** composite score >= target (5) `qa-report.json`: top + 5 lines PASS, a **re-run** unit/integration command recorded, and the report fresh (6) `debate` OPEN items empty (7) `audit.json`: `model=="opus"`, `certified==true`, fresh. Whichever one it named is the one to close — produce the missing evidence, do not fabricate it.
Common failure — blocked on a commit that is not a ship (docs, a WIP): the command-guard fires on any command mentioning `git` plus `commit|tag`, deliberately over-triggering so indirection (`g=git; $g commit`) cannot slip through. Over-triggering only *adds* a gate; it can never let a real ship through. If the run is genuinely not a ship, use `WALTEUR_SHIP=off` for that one command — it is recorded.
Common failure — a false block from a broken pipe / `pipefail` interaction: see `walteur-kit/PENDING-SETTINGS-PATCH.md`. A hook that false-blocks the operator is the worst failure mode this harness has; if you hit it, apply that patch and prove it with `bash walteur-kit/hooks/ship-gate.sh --selftest`, do not disable the gate permanently.
Honesty boundary: HARD = existence / freshness / green / Opus-authored / re-run-recorded, all checkable facts. The *correctness* of the verdicts inside those files stays PROTOCOL (LLM judgment) — labeled, never claimed as enforced.
Bypass: `WALTEUR_SHIP=off` — recorded, not free.

## stamp
What it is: `walteur-kit/hooks/stamp.sh` — appends an **immutable** certification row to `STAMP.md` + `walteur-kit/stamp-chain.json`. The "Current" score line may change; every dated history row is permanent (sha256-chained, enforced by `stamp-integrity-gate`).
Usage: `bash walteur-kit/hooks/stamp.sh "<event>" <score> <gates> "<proof>"`.
Common failure: **STAMP REFUSED** — `walteur-kit/gate-suite-report.json` is missing, stale (older than `WALTEUR_STAMP_MAXAGE` hours, default 24), or not `verdict:"PASS"`. Since v10.4 a score cannot be recorded from assertion alone; it must be corroborated by a fresh passing suite.
Fix: run `bash walteur-kit/hooks/gate-suite.sh` to produce a fresh PASS report, then re-run `stamp.sh`. If the suite genuinely does not pass, the score is not stampable yet — that is the gate working.
Common failure: `stamp-integrity-gate` FAILs right after a stamp — a history row or the chain file was altered/removed. Restore the row from git history; never rewrite a dated row to make the chain verify.
Bypass: emergency-only `WALTEUR_STAMP_FORCE=1` — the row **and** the chain entry permanently record `forced:true`, so a forced stamp is never indistinguishable from a proven one.

## selftest-fast
What it is: the CORE subset lane, `bash walteur-kit/selftest.sh --fast`. It runs the load-bearing gate `--selftest`s plus three real-file lints (harness-self-audit, gate-registry, release-ledger) and the hermetic twin-invariant guard, and writes `walteur-kit/selftest-fast-report.json`. It never touches `selftest-report.json`.
Common failure: `verdict:"FAIL"` with `counts.failed > 0`. The report carries the failing check **names**; re-run just that gate's own selftest (`bash walteur-kit/hooks/<gate>.sh --selftest`) to see the assertion that broke.
Fix: fix the named gate's logic, then re-run `bash walteur-kit/selftest.sh --fast` and confirm `counts.failed == 0`. Do not delete a check from the fast lane to clear it — the lane exists so a reviewer can re-verify the load-bearing surface inside a review window, and a shrunken lane verifies less.
Honesty boundary: this lane is `partial:true` by construction. A green `--fast` is **not** the certification proof — that is the full `bash walteur-kit/selftest.sh`, whose verdict and counts land in `walteur-kit/selftest-report.json`. Never quote a `--fast` pass count as the aggregate.
Anchor note: the fast report writes no `.gate` field, so `doctor.sh` derives the id from the filename (`selftest-fast`) — that is why this heading is named for the report, not for a registry gate.

## compact-context
What it is: `walteur-kit/hooks/compact-context.sh` — a **Stop**-hook resume-pointer writer. It writes a cheap, machine-readable RESUME SNAPSHOT block into `_relay/BATON.md` (phase, completed task ids, open-issue tail, next-action pointer) so the next session resumes without re-reading the transcript. It is *not* a context summarizer — that is the harness's own `/compact`.
Contract: a Stop hook must be fail-safe. This one **always exits 0**, never blocks, never errors. It self-skips silently outside a WALTEUR project (no `walteur-kit/` in cwd or `$CLAUDE_PROJECT_DIR`).
Common failure: `_relay/BATON.md` was never written or is stale, so the next session starts cold. Causes, in order of likelihood: (1) `walteur-kit/PAUSED` is present — the hook deliberately writes nothing while paused; (2) `WALTEUR_COMPACT=off`; (3) the Stop hook is not registered in `.claude/settings.json`; (4) you are not in the project root.
Fix: `rm walteur-kit/PAUSED` (if the run is meant to continue), unset the bypass, confirm the Stop-hook registration, then run `bash walteur-kit/hooks/compact-context.sh` manually and check the RESUME SNAPSHOT block in `_relay/BATON.md`. Prove the logic with `bash walteur-kit/hooks/compact-context.sh --selftest` (hermetic; builds WALTEUR and non-WALTEUR temp dirs).
Bypass: `WALTEUR_COMPACT=off` — a loud, recorded skip, still exit 0.

## persona-breadcrumbs
What it is: `walteur-kit/hooks/persona-breadcrumbs.sh` — an **emitter, not a gate**. It maps the real governance phases onto the `personas.json` roster and writes `walteur-kit/personas/<id>.json` for every persona whose `spawn_when` matches the build signals **and** whose phase's evidence artifact actually exists. Run it near the end of a build (the orchestrator calls it after the terminal audit).
Why it matters: it is what makes `persona-coverage-gate` honest. A persona counts as "engaged" only when its phase genuinely ran — `PLAN.md` for plan/coordination, `SUMMARY.jsonl` for build, `qa-report.json` for review, `audit.json` for audit, `red-flag-register.json` for the Senior PM. A skipped phase writes no breadcrumb, and coverage FAILs.
Common failure: `persona-coverage-gate` reports missing personas even though the run happened. Check, in order: (1) was this hook run at all after the audit? (2) does `walteur-kit/personas.json` exist and parse? (3) does `walteur-kit/preflight-signals.json` exist (no signals => no `spawn_when` match)? (4) does the phase's evidence artifact exist on disk?
Fix: produce the missing phase evidence (that is the real gap — the persona did not run), then re-run `bash walteur-kit/hooks/persona-breadcrumbs.sh`. Do **not** hand-author a breadcrumb file to satisfy coverage: the breadcrumb's whole value is that it is derived from evidence, and a fabricated one converts a real coverage gap into a silent green.
Bypass: `WALTEUR_PERSONA=off` — recorded, not free.

## intent-trace
What it is: `walteur-kit/hooks/intent-trace.sh` — the deterministic structural arm of intended-vs-implemented (§5.5). For each PRD acceptance criterion carrying an `ast_proof` block, it runs the ast-grep pattern and proves the construct **exists** at a concrete `file:line`, landing a proof object in `walteur-kit/audit.json` → `intent_vs_impl[].ast_proof`.
Common failure — exit 2, "claimed but ABSENT": an acceptance criterion pins a construct that ast-grep cannot find. Either the construct was never built (build it) or the pattern is wrong (fix the `ast_proof` pattern in the PRD proofs sidecar). Do not delete the criterion to clear the gate — that removes the claim instead of proving it.
Common failure — LOUD SKIP: `ast-grep` is not on PATH while ≥1 `ast_proof` exists. That is recorded, exit 0, and it is **cannot_measure**, not a pass. Install ast-grep. Under `WALTEUR_INTENT_TRACE=strict` a missing tool is itself exit 2 (ship posture) — use strict for a real ship.
NOT_APPLICABLE: no PRD proofs sidecar, or zero `ast_proof` blocks => loud exit 0. Nothing to trace yet.
Honesty boundary: every proof object carries `proves:"existence"`. This hook de-circularizes *existence* only — it never proves the construct is semantically correct or that it fires on the live path. That stays PROTOCOL (the §5.4 logic-correctness QA arm + the policy-shadow guard). Absence of a match is NOT-FOUND, never proven-absent behavior.
Bypass: `WALTEUR_INTENT_TRACE=off`. Kill switch: `walteur-kit/PAUSED`.

## opengrep-gate
What it is: `walteur-kit/hooks/opengrep-gate.sh` — inter-procedural source→sink **taint** analysis via the OSS `opengrep` engine (~12 languages). It sees what ast-grep and grep structurally cannot: a tainted source (`req.query`, argv, env, a network body) reaching a dangerous sink (exec/eval/SQL string/path open) *through function calls*. ast-grep proves structure; opengrep proves flow.
Common failure — a real taint finding: the report's `details[]` names each error-level SARIF result. Break the flow at the narrowest point — validate/parameterize at the sink, or sanitize at the boundary. Default posture is **warning-first**: a finding is a LOUD WARN at exit 0 and does not block until you set `WALTEUR_OPENGREP=hard`. This hook is deliberately not wired into the live `ship-gate.sh`.
Common failure — LOUD SKIP: `opengrep` is not installed. Recorded, exit 0, and honest: "we could not run the taint engine". Install it, or set `WALTEUR_OPENGREP=hard` so a can't-run on a security surface becomes exit 2. Never read a skip as green.
Fix / re-grade offline: `OPENGREP_SARIF=/path/to.json bash walteur-kit/hooks/opengrep-gate.sh` re-grades a CI SARIF artifact with no engine run — also how the selftest proves the parse logic hermetically. `OPENGREP_BIN` overrides the binary, `OPENGREP_CONFIG` the ruleset (default `walteur-kit/opengrep-rules/` if present, else the engine's bundled config).
Honesty boundary: a PASS means "this ruleset found no error-level source→sink path", not "the code is safe". `warning`/`note` results are recorded as informational and never block.
Bypass: `WALTEUR_OPENGREP=off` — recorded, exit 0. Kill switch: `walteur-kit/PAUSED` => exit 2.

## guarddog-gate
What it is: `walteur-kit/hooks/guarddog-gate.sh` — the EGRESS companion to `osv-gate`. Before a new dependency (or a packaged MCP server) is enabled, DataDog `guarddog` runs Semgrep source rules + package-metadata heuristics over the declared manifests and warns on a fresh typosquat / install-time code-exec / data-exfil package that **OSV has not indexed yet**. osv-gate fires only on an advisory that already exists; this is left-of-advisory detection.
Common failure — `issues > 0`: the report's `hits[]` names the package and the rule that fired. Verify the package by hand before enabling it: read the version's install scripts and network calls. A heuristic hit is a **signal**, not a verdict — guarddog can false-positive on a legitimate install script. Default posture is warning-first (exit 0); `WALTEUR_GUARDDOG=hard` gives it teeth.
Common failure — LOUD SKIP: `guarddog` is absent. Recorded, exit 0, **even in hard mode** — a missing tool is not a malicious-package finding, and only a real hit is hard-blockable. Install guarddog (>= 3.0, the v3 `verify --output-format=json` contract) to actually measure.
NOT_APPLICABLE: no `package.json` and no `requirements.txt` under ROOT => exit 0. Nothing declared, nothing to verify.
Fix / hermetic re-grade: `GUARDDOG_FIXTURE=/path/to/output.json` uses that file as guarddog's JSON output with no subprocess (the selftest path, and how to re-grade a CI artifact offline). `GUARDDOG_BIN` overrides the binary path.
Honesty boundary: a PASS means "guarddog ran and flagged nothing for the candidates we scanned" — absence of a hit is NOT-FOUND, never proven-safe. guarddog's output is treated as data, never executed.
Bypass: `WALTEUR_GUARDDOG=off` — recorded, exit 0. Kill switch: `walteur-kit/PAUSED` => exit 2.

## stack-fingerprint
What it is: `walteur-kit/hooks/stack-fingerprint.sh` — a cheap manifest-hash drift detector. It cksums the stable-sorted manifest surface (`package.json` scripts+deps, `pyproject.toml`, `Cargo.toml`, `go.mod`, `requirements.txt`) into `walteur-kit/.stack-fingerprint`, and on a later run emits ONE line to `_relay/ISSUES.md` when the stack moved. The point is a durable signal that the best-practice-stack assumption needs re-checking.
Verdicts: no manifest => `SKIP` exit 0 · no stored fingerprint => `BASELINE` written, exit 0 (first run) · unchanged => `UNCHANGED`, one stderr line, exit 0 (the common path, no ISSUES write) · changed => `DRIFT`, exit 0, one line appended to `_relay/ISSUES.md` naming which manifests moved, **and the baseline is refreshed** so drift is reported once per move, not every run.
This is advisory, not a HARD gate: it never exits 2 on drift. Exit 2 is reserved for the `PAUSED` kill switch and a `--selftest` failure.
Common failure — you expected a DRIFT line and got nothing: the previous run already consumed it (the baseline auto-refreshes), or the edit was outside the fingerprinted surface (only the root-nearest instance of each manifest is hashed; `node_modules`/`.git`/`dist`/`build`/`vendor` are pruned). Check `_relay/ISSUES.md` history before assuming the detector is broken.
Common failure — DRIFT fires on every run: the stored baseline is not being written (read-only tree, or the file was gitignored away). Confirm `walteur-kit/.stack-fingerprint` exists and is writable.
Fix / re-baseline deliberately: `bash walteur-kit/hooks/stack-fingerprint.sh --refresh` force-rewrites the baseline from current state with no ISSUES line. Use it after you have *acted* on a drift, not to make one go away unread.
Bypass: `WALTEUR_STACKFP=off` — loud skip, exit 0, no file touched.

## skill-index-build
What it is: `walteur-kit/hooks/skill-index-build.sh` — a **maintenance tool**, not a runtime gate. It generates `walteur-kit/skill-index.json` from a skills library, delegating the parse to `skill-index-build.mjs`. Run it once per skills-library change. The runtime drift guard is the registered gate `skill-index-lint` (see the index above).
Usage: `bash walteur-kit/hooks/skill-index-build.sh <skills-root> [out.json] [YYYY-MM-DD]`.
Common failure — `skill-index-build: node is required to parse the skills library` (exit 2): install `node`. This tool has a hard node dependency by design; it does not degrade to a partial index.
Common failure — `skill-index-lint` FAILs after a library change: the index was never rebuilt. Re-run this tool against the library root and commit the regenerated `skill-index.json`. Do not hand-edit `skill-index.json` to satisfy the lint — it is generated output, and a hand-edit guarantees the next rebuild reverts it.
Common failure — the generated index is empty or missing skills: you pointed `<skills-root>` at the wrong directory. It expects the library root that *contains* the skill directories, not one skill.
Bypass: none — it is a generator, not a gate. Nothing to bypass; just don't run it.

---

## Utility scripts (not standalone gate-registry ids — referenced by name in builder recipes)

These are real, load-bearing tools invoked BY gates above, but they are not themselves registered `id`s
in `gate-registry.json` — `remediation-coverage-gate.sh` (below) checks registry-id anchor coverage, not these.
Kept here because their failure modes are common and were supplied by name. (`stamp` graduated to its own
`## stamp` anchor above, because `stamp.sh --help` points there.)

### twin-invariant (walteur-kit/eval/twin-invariant.sh)
What it does: asserts the doc-twin, distribution-twin (hooks/rubrics/required-skills.json/`.claude/hooks`), and rubric house-contract stay byte-identical/present across the two canonical trees. Invoked from inside `gate-suite.sh`'s run_twin_real check, not registered as its own top-level gate id.
Common failure: `--selftest` shows a `.claude/hooks` twin DRIFT assertion failing (POISON 5 or the SCOPE=hooks cross-tree assertion) — the 4th check_distribution_twins() loop (`.claude/hooks/*.sh` comparison) regressed.
Fix: verify the CA/CB path variables still point at `$TREE_A/.claude/hooks` and `$TREE_B/.claude/hooks` (not `walteur-kit/.claude/hooks`), and that `note_drift`/`note_missing` are still called inside the loop, not just `note_ok`. For an ordinary (non-selftest) drift: re-sync canonical→starter (`cp` the file + `cmp -s` to confirm identical).
Bypass: `WALTEUR_TWIN=off` (loud skip). Normal mode is WARN-only (exit 0); arm HARD blocking with `WALTEUR_TWIN=hard` — bypass is recorded, not free.

### gate-suite-shim (.claude/hooks/gate-suite.sh)
What it does: a thin delegating shim — resolves and execs the ONE canonical `walteur-kit/hooks/gate-suite.sh` implementation, forwarding all args (including `--selftest`). Not a separate registry id; the registered gate is `gate-suite` (the canonical), above.
Common failure: `.claude/hooks/gate-suite.sh --selftest` shows `shim selftest: X/Y passed` with X<Y — a NEGATIVE CONTROL caught real fail-open risk in the shim's canonical-resolution or fail-closed branch.
Fix: do NOT weaken the assertions to make it pass — fix the `resolve_and_exec` logic so the fail-closed contract actually holds (exit 2 when the canonical is absent, propagate the canonical's non-zero exit rather than swallowing it, exec verbatim with all args forwarded when the canonical is present).
Bypass: none documented for the shim itself — it always execs the canonical; the canonical's own bypass is `WALTEUR_GATESUITE=off`.

## Bypass / kill switches (use honestly, they're recorded — never silent-green)
- `walteur-kit/PAUSED` present → every gate exits 2 (paused ≠ green).
- `WALTEUR_<GATE>=off` → a recorded LOUD skip for that gate (e.g. `WALTEUR_TWIN=off`). See each gate's row
  above for its exact env var name — several gates use a shortened or historical name that does not match
  the registry id 1:1 (e.g. `spec-trace` → `WALTEUR_SPECTRACE`, `a11y-content-lint` → `WALTEUR_A11Y`,
  `i18n-lint` → `WALTEUR_I18N`).
- HARD arming: most detect-or-report gates block only when armed (`WALTEUR_*_HARD=1` / `_EXEC=1` / `_MIN=N`).
  Warning-first is by design; arm for a real ship.
- A logged bypass is not a free pass: every `WALTEUR_<GATE>=off` is a recorded, auditable skip in that
  gate's own report JSON — it proves you chose to skip, not that the underlying risk went away.

## Still stuck?
Read the gate's source header (`sed -n '1,30p' walteur-kit/hooks/<gate>.sh`) — every gate documents its
CONTRACT, kill switch, and bypass at the top. Run `bash walteur-kit/hooks/<gate>.sh --selftest` to confirm
the gate's own logic is sound before assuming the finding is wrong.

## Coverage
`remediation-coverage-gate.sh` fails closed when a registry gate id has no matching `## <gate-id>` anchor
here, or when a hook under `walteur-kit/hooks/` has no `--help` arm. See that gate's own header for details.
