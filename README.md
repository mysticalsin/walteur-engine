# WALTEUR — the build-engine framework

A self-prompting, file-first **build engine** for software and cloud/IaC. Give it an idea (or a repo to improve); it runs the lifecycle — discover → plan → build → verify → review → ship → reflect — behind typed, evidence-gated checks (zero-dep `bash` + `jq`). Drop-in as `CLAUDE.md`, portable across models.

> **Nav:** current score/ledger → [`STAMP.md`](STAMP.md) · first run (10 min) → [`QUICKSTART.md`](QUICKSTART.md) ·
> gate failed? → [`walteur-kit/REMEDIATION.md`](walteur-kit/REMEDIATION.md) · health/triage →
> `bash walteur-kit/hooks/doctor.sh` · in-flight upgrade plan → [`walteur-kit/UPGRADE-S033.md`](walteur-kit/UPGRADE-S033.md)

## Quickstart

```bash
# 1. copy the engine into your project (or into ~/.claude)
cp WALTEUR-builder-CLAUDE.md  /path/to/your-project/CLAUDE.md
cp -r walteur-kit            /path/to/your-project/walteur-kit

# 2. (optional) wire the runnable hooks for HARD, exit-2 enforcement
cp -r walteur-kit/hooks      /path/to/your-project/.claude/hooks

# 3. prove the engine is intact (runs clean INSIDE a sandbox)
bash walteur-kit/selftest.sh        # -> 244 passed, 0 failed (sandbox-off; sandboxed canonical ship-gate integration cases can differ because they dispatch the external canonical kit)

# 4. scope to job size, then go:
#    typo / 1-liner  -> SKIP   (no ceremony)
#    small feature   -> /feature  (lightweight Planner->Coder->Tester->Reviewer)
#    new product     -> /goal     (full lifecycle + senior gate panel)
```

## Works without the hooks

The skill docs + discipline travel anywhere. The HARD, exit-2 enforcement (gate-guard, ship-gate, cost ceiling) needs the shell hooks under `.claude/hooks` plus the runnable kit. Without them the gates degrade to **PROTOCOL** (model-judgment): you keep the discipline, not the mechanical block.

## Status — honest

- **Proof:** `walteur-kit/selftest.sh` → **244 passed / 0 failed / 0 skipped** (sandbox-off), every temp path `$TMPDIR`-anchored so it also runs inside a command sandbox. (v10.20 adds 2 gates — integrator-audit + excellence-loop, proven by their own selftests; the aggregate re-stamp to 243 awaits a hydrated re-run, see the release-ledger policy note.) Sandbox-sensitive cases are the ship-gate integration tests that dispatch the external canonical kit; verify those in the target sandbox before claiming sandbox parity.
- **First field miles (2026-06-27):** WALTEUR drove a real product — **Tempo**, an Apple-grade focus timer (`Desktop/Tempo`) — through the lifecycle and its gates **certified it on real output**: TDD `node --test` 9/9 (the tests caught a real UTC/local timezone bug pre-ship), `apple-grade-design` PASS, `anti-slop-ui` PASS, `design-depth` PASS, `test-claim-verifier` re-ran the actual tests (exit 0). See `Desktop/Tempo/CERTIFICATION.md`. The **gates + craft standards are now proven on a real build**, not just selftests.
- **Remaining gap — honest:** that build was driven through the lifecycle by hand. The **full *autonomous* `walteur.js` orchestrator** (self-prompting persona waves → senior panel → terminal audit) has **not yet run end-to-end on a fresh idea**; doing that — and populating `run-trace.jsonl` / `eval/ab-results.jsonl` / `~/.walteur/memory` from it — is the next milestone.

## Changelog

**v9.0 · the front of the funnel: validate the bet before the build, prove intent at ship.**
**v9.1 · proof over heuristics: AST-backed gates (ast-grep), supply-chain fail-closed (OSV.dev), a recipe contract, an A/B "prove-the-pillar" harness, and self-correcting bi-temporal memory — graphify stays the one retrieval brain.**
**v9.2 · product-company spine: PRODUCT-STANDARD.md + product-standard-gate force full app surface, value loop, business model, trust/ops, launch readiness, and signed cuts for serious product builds.**
**v9.4 · industrial self-improving loop: self-improvement-gate + outcome-eval-gate force trace mining, current GitHub/source scouting, regression-proven upgrades, and independent outcome scoring.**
**v9.5 · autoprompt + delivery orchestration: prompt-refinement-gate + delivery-orchestration-gate force "Improve this prompt", specialist routing, SDLC gates, role independence, full-stack coverage, handoffs, and audit trail.**
**v9.6 · recovery + context sentinel: STATE.json now requires "I will figure it out" recovery discipline and a `Tony,` response-prefix sentinel that triggers baton compaction when it disappears.**
**v9.7 · enforceable blocked recovery: blockers, BLOCKED gates, and blocked stages must cite a valid 3-path Figure-It-Out JSONL decision.**
**v9.8 · current-stack hard gate: PLAN cannot pass without run-date stack proof from current official/source material and evidence refs.**
**v9.9 · project context + memory proof: AGENTS/CLAUDE/rules/baton context and subagent handoffs are gated, and self-improvement memory capture must cite real result evidence.**
**v9.10 · upstream source router: `self-heal.sh`, `source-manifest.json`, and `SOURCE-ROUTER.md` pin Tony's curated GitHub source graph and require source-use receipts before stack, workflow, skill, tool, or subagent choices.**
**v9.13 · trace-mining baseline: `trace-mine.sh` now emits `trace-mine-report.json`, is selected by the registry baseline, and stays covered by aggregate selftest proof.**
**v9.15 · Definition-of-Done proof refs: `definition-of-done-gate.sh` now rejects fake proof text and missing/empty/outside-root evidence files at ship/reflect.**
**v9.16 · Replayable PASS evidence: `evidence-gate.sh` and `harness-state-lint.sh` now reject summary-only PASS evidence and require path-backed, command-output, or signed human proof.**
**v9.17 · Skill-readiness manifest: fresh scaffolds now write `required-skills.json`, malformed manifests fail, and selected skill-readiness reports PASS instead of SKIP.**
**v9.18 · Verification command coverage: scaffolded contracts derive commands from every selected spec hook, and `build-contract-lint.sh` fails selected-gate command drift.**
**v9.19 · Registry selftest coverage: aggregate selftest now fails when selected spec hooks with `--selftest` are missing from the suite, and selected hooks without `--selftest` need named exceptions.**
**v9.20 · Selftest exception manifest: selected spec hooks without `--selftest` now need typed rationale, replacement proof, and next action in `selftest-exceptions.json`; stale exceptions fail aggregate selftest.**
**v9.21 · Tool-readiness selftest: `tool-readiness.sh` now owns a 9/9 hook-local selftest, aggregate runs it, and the no-selftest exception manifest drops to 14 entries.**
**v9.22 · Schema-lint selftest: `schema-lint.sh` now owns a 9/9 hook-local selftest, bypass writes a SKIP report, aggregate runs it, and the no-selftest exception manifest drops to 13 entries.**
**v9.23 · Docrun selftest: `docrun.sh` now owns a 9/9 hook-local selftest, previous-line `walteur:skip` is fixed, aggregate runs it, and the no-selftest exception manifest drops to 12 entries.**
**v9.24 · Benchmark-gate selftest: `benchmark-gate.sh` now owns an 11/11 hook-local selftest, aggregate runs it, and the no-selftest exception manifest drops to 11 entries.**
**v9.25 · Design-gate selftest: `design-gate.sh` now owns an 11/11 hook-local selftest, evaluates the requested project root, aggregate runs it, and the no-selftest exception manifest drops to 10 entries.**
**v9.26 · Cost-budget selftest: `cost-budget.sh` now owns a 13/13 hook-local selftest, honors `WALTEUR_ROOT`, writes bypass/detail reports reliably, aggregate runs it, and the no-selftest exception manifest drops to 9 entries.**
**v9.27 · Tool-contract-lint selftest: `tool-contract-lint.sh` now owns a 13/13 hook-local selftest, honors `WALTEUR_ROOT`, writes bypass/detail reports reliably, aggregate runs it, and the no-selftest exception manifest drops to 8 entries.**
**v9.28 · Contract-gate selftest: `contract-gate.sh` now owns an 11/11 hook-local selftest, honors `WALTEUR_ROOT`, writes bypass/detail reports reliably, aggregate runs it, and the no-selftest exception manifest drops to 7 entries.**
**v9.29 · IaC-scan selftest: `iac-scan.sh` now owns an 11/11 hook-local selftest, honors `WALTEUR_ROOT`, proves scanner pass/fail with PATH-isolated fake tools, aggregate runs it, and the no-selftest exception manifest drops to 6 entries.**
**v9.30 · Release-gate selftest: `release-gate.sh` now owns a 13/13 hook-local selftest, honors `WALTEUR_ROOT`, proves release readiness and fake vulnerability failure, aggregate runs it, and the no-selftest exception manifest drops to 5 entries.**
**v9.31 · Restore-proof selftest: `restore-proof.sh` now owns an 11/11 hook-local selftest, honors `WALTEUR_ROOT`, proves SQLite restore PASS/FAIL round trips, aggregate runs it, and the no-selftest exception manifest drops to 4 entries.**
**v9.32 · Security-gate selftest: `security-gate.sh` now owns a 9/9 hook-local selftest, honors `WALTEUR_ROOT`, proves scanner-absent SKIP, fake gitleaks clean PASS, fake secret-leak FAIL, bypass, and PAUSED behavior; aggregate runs it, and the no-selftest exception manifest drops to 3 entries.**
**v9.33 · Spec-trace selftest: `spec-trace.sh` now owns a 17/17 hook-local selftest, honors `WALTEUR_ROOT`, proves T1/T2/T3/T4 PASS/FAIL paths, normalizes trailing punctuation on REQ/STORY tokens, aggregate runs it, and the no-selftest exception manifest drops to 2 entries.**
**v9.34 · Compliance-gate selftest: `compliance-gate.sh` now owns a 15/15 hook-local selftest, honors `WALTEUR_ROOT`, proves PII inventory PASS/FAIL, missing lawful basis/retention FAIL, unredacted PII log FAIL, invalid inventory FAIL, bypass, and PAUSED behavior; aggregate runs it, and the no-selftest exception manifest drops to 1 entry.**
**v9.35 · AI-safety-gate selftest: `ai-safety-gate.sh` now owns a 15/15 hook-local selftest, honors `WALTEUR_ROOT`, proves non-AI NOT_APPLICABLE, R2 injection-corpus VETO/PASS, R1 loop-cap VETO/PASS, R3 model-pin VETO/PASS, bypass, and PAUSED behavior; aggregate runs it, and the no-selftest exception manifest drops to 0 entries.**
**v9.36 · Aggregate skip cleanup: legacy AI-safety and benchmark distribution-fixture checks are removed from `selftest.sh` because hook-local selftests own those twins; aggregate stayed 68 passed / 0 failed while skips dropped from 11 to 7.**
**v9.37 · Machine-readable aggregate proof: `selftest.sh` now writes `walteur-kit/selftest-report.json` with verdict, summary, pass/fail/skip counts, and skip reasons; at v9.37 aggregate proof was 68 passed / 0 failed / 7 skipped.**
**v9.38 · Schema-checked aggregate proof: `schemas/selftest-report.schema.json` now backs `selftest-report.json`, and `selftest.sh` fail-closes if the report shape, counts, or skip reasons drift; at v9.38 aggregate proof was 69 passed / 0 failed / 7 skipped.**
**v9.39 · Aggregate skip budget: `selftest-skip-budget.json` and its schema now allow only known optional skip reasons and fail closed on new skip drift; at v9.39 aggregate proof was 70 passed / 0 failed / 7 skipped.**
**v9.40 · Poisoned skip-budget proof: aggregate selftest now proves the skip-budget guard rejects a synthetic unexpected skip reason; at v9.40 aggregate proof was 71 passed / 0 failed / 7 skipped.**
**v9.41 · Worktree isolation twins: distribution-local git-worktree good/poisoned fixtures now prove clean isolated merges and conflict detection; at v9.41 aggregate proof was 73 passed / 0 failed / 6 skipped.**
**v9.42 · Generated autonomy-state proof: aggregate selftest now proves `harness-init.sh` creates `STATE.json` with `autonomy_policy="full_autopilot"` by default; at v9.42 aggregate proof was 74 passed / 0 failed / 5 skipped.**
**v9.43 · Canonical orchestrator proof: aggregate selftest now resolves the canonical runnable-kit `walteur.js` and proves autonomy guard, advisory blind-review wiring, and WAVE-LOGIC extraction; at v9.43 aggregate proof was 78 passed / 0 failed / 2 skipped.**
**v9.44 · Canonical runtime hooks proof: aggregate selftest now resolves canonical `.claude/hooks` and proves kill-switch, gate-guard, ship-gate, dispatch, and tool-readiness smoke paths; at v9.44 aggregate proof was 107 passed / 0 failed / 1 skipped.**
**v9.45 · Zero-skip aggregate proof: aggregate selftest began running P12 ast-grep rule twins through a pinned `@ast-grep/cli` fallback when no local binary exists; at v9.45 aggregate proof was 108 passed / 0 failed / 0 skipped.**
**v9.46 · Tool-acquisition contract + CI aggregate proof: pinned on-demand CLI fallback moved into `tool-acquisition.json`, aggregate selftest validates that contract before running P12 AST twins, and CI enforces the zero-skip report; at v9.46 aggregate proof was 109 passed / 0 failed / 0 skipped.**
**v9.47 · Lockfile-backed tool acquisition: `tool-acquisition/ast-grep/package-lock.json` pins the AST CLI tarball integrity; aggregate selftest validates manifest plus lockfile, runs P12 twins through temp `npm ci`, and CI installs the locked workspace before enforcing the zero-skip report; aggregate proof is 109 passed / 0 failed / 0 skipped.**
**v9.48 · Generic poisoned tool acquisition: aggregate selftest now validates every npm-backed acquisition entry against its package workspace, lockfile, binary path, install/prove commands, and proof config, then proves manifest path drift, package.json dependency drift, and package-lock integrity drift fail closed; aggregate proof is 112 passed / 0 failed / 0 skipped.**
**v9.49 · Live prove-command acquisition: `tool-acquisition.json` now records the package `prove_script`, aggregate selftest validates package scripts against it, executes `npm run prove` from a locked workspace copy, and CI runs the locked workspace proof before aggregate enforcement; aggregate proof is 113 passed / 0 failed / 0 skipped.**
**v9.50 · Manifest-driven acquisition runner: `tool-acquisition.json` now declares `proof_assets`, `tool-acquisition-proof.sh` runs install/prove modes from the manifest, aggregate selftest rejects missing proof assets and script drift, and CI no longer names ast-grep directly; aggregate proof is 115 passed / 0 failed / 0 skipped.**
**v9.51 · Acquisition runner selftest: `tool-acquisition-proof.sh` now owns `--check-only` contract validation and `--selftest` poison fixtures, and aggregate selftest proves the runner rejects missing assets, package drift, and prove-script drift before executing acquired tools; aggregate proof is 116 passed / 0 failed / 0 skipped.**
**v9.52 · Acquisition runner selftest parity: `tool-acquisition-proof.sh --selftest` now proves 7/7 local fixtures, adding manifest binary-path drift, install-command drift, and package-lock integrity drift to the runner's own contract proof; aggregate proof remains 116 passed / 0 failed / 0 skipped.**
**v9.53 · Acquisition runner schema floor: `tool-acquisition-proof.sh --check-only` now validates the full manifest shape locally and `--selftest` proves 10/10 fixtures, adding duplicate tool id, duplicate proof asset, and unknown manifest key rejection; aggregate proof remains 116 passed / 0 failed / 0 skipped.**
**v9.54 · Acquisition CI preflight: CI now runs `tool-acquisition-proof.sh --check-only` and `--selftest` before install/prove, and aggregate selftest verifies that order; aggregate proof is 117 passed / 0 failed / 0 skipped.**
**v9.55 · Acquisition nested-shape proof: `tool-acquisition-proof.sh --selftest` now proves 14/14 fixtures, adding unknown tool, on-demand, proof, and lockfile key rejection so every manifest object layer is poison-tested; aggregate proof remains 117 passed / 0 failed / 0 skipped.**
**v9.56 · Acquisition schema uniqueness parity: the published JSON Schema now declares every expressible acquisition uniqueness floor, the runner proves 16/16 local fixtures including duplicate local binary and duplicate proof arg rejection, and aggregate selftest poison-tests schema uniqueness drift; aggregate proof is 118 passed / 0 failed / 0 skipped.**
**v9.57 · Release ledger gate: `release-ledger.json`, schema, and `release-ledger-lint.sh` make WALTEUR current version, proof counts, registry count, scaffold count, mirror pair, and component manifest IDs machine-checkable; scaffold proof is 74/74, release-ledger selftest is 9/9, and aggregate proof is 120 passed / 0 failed / 0 skipped.**
**v9.58 · Source-use receipt gate: `source-use.schema.json` and `source-use-gate.sh` turn upstream GitHub/source-router adoption into typed receipts with source id, immutable pinned ref, extracted pattern, rejected parts, safety checks, artifact refs, verification, and rollback proof; scaffold proof is 76/76 and aggregate proof is 122 passed / 0 failed / 0 skipped.**
**v9.59 · Source-use schema parity: aggregate selftest now proves the published `source-use.schema.json` declares the receipt floors enforced by `source-use-gate.sh`, and rejects a poisoned schema missing the immutable pinned-ref floor; aggregate proof is 124 passed / 0 failed / 0 skipped.**
**v9.60 · Release proof-claim history: `release-ledger.json` now carries aggregate proof history and configured proof-claim paths, and `release-ledger-lint.sh` rejects stale prose where a known version is paired with the wrong aggregate count; release-ledger selftest is 10/10 and aggregate proof remains 124 passed / 0 failed / 0 skipped.**
**v9.61 · Release-ledger schema parity: aggregate selftest now proves the published `release-ledger.schema.json` declares the history and proof-claim floors enforced by `release-ledger-lint.sh`, and rejects a poisoned schema missing the history version floor; aggregate proof is 126 passed / 0 failed / 0 skipped.**
**v9.62 · Ruflo source-router addition: `source-manifest.json` pins `ruvnet/ruflo` as an agent meta-harness source, and `release-ledger-lint.sh` now verifies the source manifest count plus required source id; release-ledger selftest is 11/11 and aggregate proof is 127 passed / 0 failed / 0 skipped.**
**v9.63 · Trace redundancy mining: `run-trace.sh emit` can record optional `tool_signature`, and `trace-mine.sh` now detects repeated identical successful tool signatures while ignoring one-offs; run-trace selftest is 22/22, trace-mine selftest is 33/33, and aggregate proof remains 127 passed / 0 failed / 0 skipped.**
**v9.64 · Source-count claim truth: `release-ledger-lint.sh` now scans configured docs for source-count prose and rejects stale counts against `source-manifest.json`; release-ledger selftest is 12/12 and aggregate proof remains 127 passed / 0 failed / 0 skipped.**
**v9.65 · Frontend budget gate: `frontend-budget.sh` now has an 8/8 selftest, `schemas/frontend-budget.schema.json` publishes browser payload/Core Web Vitals floors, `gate-registry` selects `frontend-budget` for software/mixed builds, and aggregate proof is 130 passed / 0 failed / 0 skipped.**
**v9.66 · Browser proof gate: `browser-proof-gate.sh` now has a 10/10 selftest, `schemas/browser-proof.schema.json` publishes route/screenshot/accessibility/interaction evidence floors, `gate-registry` selects `browser-proof-gate` for software/mixed builds, and aggregate proof is 133 passed / 0 failed / 0 skipped.**
**v9.67 · Migration proof gate: `migration-proof-gate.sh` now has a 10/10 selftest, `schemas/migration-proof.schema.json` publishes forward/rollback/verification/lock-risk/backfill evidence floors, `gate-registry` selects `migration-proof-gate` for software/mixed builds, and aggregate proof is 136 passed / 0 failed / 0 skipped.**
**★ v10.20 (latest · 2026-07-10) · 150 registered gates (61 HARD fail-closed; live count via `gate-registry.json`) · CROSS-MODEL INTEGRATOR AUDIT (`integrator-audit-gate.sh`, rocket-fuel port: fresh Codex adversarial `VERDICT: SHIP` at ship via `rf-codex.sh`) · EXCELLENCE PLATEAU LAW (`excellence-loop-gate.sh`: green is the floor — plateau of two refined-and-re-proved rounds or cap-with-residuals) · 68-PERSONA SENIOR ORG (`personas.json`): Chief of Staff + FRONT-LOADED Senior PM (red flags from the START) + specialists by signal + terminal Audit Squad, enforced by `persona-coverage-gate.sh` + evidence-based `persona-breadcrumbs.sh` · AUTOMATIC context compaction at 150k/200k ABSOLUTE tokens (`compaction-policy.json` + `context-compaction-gate.sh` + `walteur.js maybeCompact`) · LOOP-ENGINEERING self-improvement (`loop-readiness-gate.sh` L0-L3 + `harness-self-audit-gate.sh`, self-score 100/100 after the DIM-2 ceiling bug-fix — the prior rubric maxed at 98; NOTE this is the self-audit gate's OWN internal rubric, **not** the harness-100 blind-panel score, which is **65.48/100** at panel #12 — see `STAMP.md` and `walteur-kit/harness-100/panel-12.json`) · craft floors `anti-slop-prose` / `hollow-artifact` (ships-mock) / `skill-quality` (190-skill lint, 94/100 — a lint score, again not the panel score) / `data-correctness` · best-of-breed fold (gstack + loop-engineering + War Mode V15 + 40-repo intake). See `CHANGELOG.md`.**
**v9.68 · Migration safety gates: `migration-lint.sh` now has a 9/9 selftest, `migration-roundtrip.sh` now has a 7/7 selftest, `gate-registry` selects both for software/mixed builds, and aggregate proof is 138 passed / 0 failed / 0 skipped.**
**v9.69 · Architecture fitness gate: `fitness-gate.sh` now has a 10/10 selftest, honors `WALTEUR_ROOT`, writes bypass reports, `gate-registry` selects it for software/mixed builds, and aggregate proof is 139 passed / 0 failed / 0 skipped.**
**v9.70 · Frontend quality gates: `a11y-content-lint.sh` now has an 8/8 selftest, `i18n-lint.sh` now has a 7/7 selftest, `gate-registry` selects both for software/mixed builds, and aggregate proof is 141 passed / 0 failed / 0 skipped.**
**v9.71 · Tool signature normalization: `run-trace.sh emit --command` now derives conservative normalized signatures for known-equivalent command forms, `trace-mine.sh` groups those shared signatures while ignoring unknown commands, run-trace selftest is 25/25, trace-mine selftest is 39/39, and aggregate proof stays 141 passed / 0 failed / 0 skipped.**
**v9.72 · SBOM supply-chain gate: `sbom-gate.sh` now has a 14/14 selftest, validates non-empty CycloneDX/SPDX/Syft dependency inventory or live Syft generation, `gate-registry` selects it for software/workflow/data-AI/cloud-IaC/mixed builds, and aggregate proof is 142 passed / 0 failed / 0 skipped.**
**v9.73 · Operate readiness gate: `operate-readiness-gate.sh` now has a 14/14 selftest, `operate-readiness.schema.json` publishes SLO/DORA/incident/on-call/observability/rollback/support floors, `gate-registry` selects it for software/workflow/data-AI/cloud-IaC/mixed builds, and aggregate proof is 145 passed / 0 failed / 0 skipped.**
**v9.74 · SDLC run proof gate: `sdlc-run-gate.sh` now has a 14/14 selftest, `sdlc-run.schema.json` publishes the five-stage runtime proof floor, `gate-registry` selects it for software/workflow/data-AI/cloud-IaC/mixed builds, Ruflo is refreshed to current `main`, and aggregate proof is 149 passed / 0 failed / 0 skipped.**
**v9.75 · AI-tool governance gate: `ai-tool-governance-gate.sh` now has a 14/14 selftest, `ai-tool-governance.schema.json` publishes the inventory, approval, boundary, human-review, audit, cost, and rollback floor for AI tools/models/agents/MCP/plugin surfaces, `gate-registry` selects it for software/workflow/data-AI/cloud-IaC/mixed builds, and aggregate proof is 152 passed / 0 failed / 0 skipped.**
**v9.76 · AuthZ tenant proof gate: `authz-tenant-gate.sh` now has a 14/14 selftest, `authz-tenant.schema.json` publishes deny-by-default authorization, role/permission matrix, negative/anonymous/privilege tests, audit, signoff, and tenant-isolation evidence floors, `gate-registry` selects it for software/workflow/data-AI/cloud-IaC/mixed builds, and aggregate proof is 155 passed / 0 failed / 0 skipped.**
**v9.78 · enterprise blueprint spine: `enterprise-blueprint.json` + `enterprise-blueprint-gate.sh` force the raw goal into a concrete user/job/artifact/surface/acceptance/trust/ops/cuts/final-packet build target before PLAN. Scaffold proof is 79/79, gate count is 76, aggregate proof is 161 passed / 0 failed / 0 skipped.**
**v9.77 · Privacy data proof gate: `privacy-data-gate.sh` now has a 15/15 selftest, `privacy-data.schema.json` publishes inventory, processing records, minimization, lawful basis, retention, deletion/export, logging redaction, encryption, transfers, breach response, DPIA, signed evidence, and lifecycle test floors, `gate-registry` selects it for software/workflow/data-AI/cloud-IaC/mixed builds, and aggregate proof is 158 passed / 0 failed / 0 skipped.**
**Production-layer spine · layers.json + production-layers-gate force every delivery layer to be owned, evidenced, or consciously deferred.**
**Architecture-fitness spine · fitness-gate.sh force software/mixed builds to prove acyclic layers, unreachable forbidden dependencies, and configured architecture fitness tools.**
**Frontend-quality spine · a11y-content-lint.sh + i18n-lint.sh force content accessibility and translation discipline for software/mixed frontends.**
**SBOM spine · sbom-gate.sh force dependency/container surfaces to prove a non-empty CycloneDX, SPDX, or Syft inventory, generate one with Syft, or record missing proof tooling loudly.**
**Operate-readiness spine · operate-readiness-gate.sh + operate-readiness.schema.json force runtime systems to prove SLOs, DORA targets, incident response, on-call ownership, observability, rollback rehearsal, support handoff, and post-incident learning before ship.**
**Decision spine · adr.schema.json + adr-gate force open forks to close and ADRs to carry rejected alternatives, dissent, owners, and index evidence.**
**Prompt spine · prompt-refinement.schema.json + prompt-refinement-gate force the raw user ask to become an enterprise build brief before PLAN.**
**Current-stack spine · current-stack.schema.json + current-stack-gate force today's stack assumptions to be dated, sourced, evidenced, and drift-aware.**
**Delivery-orchestration spine · delivery-orchestration.schema.json + delivery-orchestration-gate force the agent team, SDLC, frontend/backend/QA/security coverage, handoffs, and worktree boundaries to be explicit.**
**AI-tool-governance spine · ai-tool-governance.schema.json + ai-tool-governance-gate force every AI tool, model, agent, MCP/plugin, data boundary, approval, output gate, cost control, audit log, and rollback path to be inventoried before ship.**
**AuthZ-tenant spine · authz-tenant.schema.json + authz-tenant-gate force deny-by-default access decisions, role/permission matrices, negative access tests, anonymous denial, privilege escalation checks, audit refs, signed evidence, and tenant-isolation proof before ship.**
**Privacy-data spine · privacy-data.schema.json + privacy-data-gate force personal, sensitive, regulated, and AI-context data lifecycle proof: inventory, processing purpose, minimization, lawful basis, retention, deletion/export, redacted logging, encryption, transfers, breach response, DPIA, tests, and signed evidence.**
**SDLC-run spine · sdlc-run.schema.json + sdlc-run-gate force local build, shared dev, staging, beta, production, independent review, QA, adversarial checks, rollback, monitoring, signoff, and retro proof to exist before ship.**
**Project-context spine · project-context.schema.json + project-context-gate force project-specific AGENTS/CLAUDE/rules context, context budget, baton, and subagent handoff evidence.**
**Self-improvement spine · self-improvement.schema.json + self-improvement-gate force trace mining, current GitHub scouting, bounded proposals, regression proof, and evidence-backed memory capture.**
**Trace-mining spine · run-trace explicit and normalized tool signatures + trace-mine.sh + trace-mine-report.json mine recurring tool/gate/stall/redundant-call patterns and append proposal-only improvements to `_relay/ISSUES.md`.**
**Frontend-budget spine · frontend-budget.schema.json + frontend-budget.sh force frontend builds to declare browser payload and Core Web Vitals budgets, and fail built JS over budget.**
**Browser-proof spine · browser-proof.schema.json + browser-proof-gate.sh force UI builds to provide fresh replayable route, screenshot, accessibility, interaction, and command-output evidence.**
**Migration-proof spine · migration-proof.schema.json + migration-proof-gate.sh force database migration work to provide fresh forward, rollback, verification, lock-risk, and backfill evidence.**
**Migration-safety spine · migration-lint.sh + migration-roundtrip.sh force migration rollback bodies, expand-contract sequencing, lock-safe indexes, safe NOT NULL changes, and roundtrip preconditions.**
**Source-router spine · source-manifest.schema.json + self-heal.sh + SOURCE-ROUTER.md force typed upstream source selection, pinned refs, source-use receipts, and promote-only-with-proof adoption.**
**Source-use spine · source-use.schema.json + source-use-gate force every source-router receipt to prove immutable pinned ref, extracted pattern, rejected parts, license/maintenance/security/fit checks, artifact refs, verification, and rollback where needed.**
**Release-ledger spine · release-ledger.json + release-ledger-lint force current version, proof counts, aggregate proof history, stale proof prose, stale source-count prose, published schema parity, source-manifest count/id, registry count, scaffold count, mirror pair, and component manifest IDs to stay machine-checkable.**
**Outcome-eval spine · outcome-eval.schema.json + outcome-eval-gate force an independent rubric judgment of the delivered artifact against the user outcome.**
**Recovery/context spine · harness-state.schema.json + harness-state-lint force 3-path obstacle recovery, blocked-work recovery decisions, and the `Tony,` response-prefix context sentinel.**
**Runtime-evidence spine · harness-state.schema.json + evidence-gate force PASS claims to cite replayable proof, not summary-only green text.**
**QA-proof spine · qa-report.schema.json + qa-contract-gate force unit/integration, functional, logic, integration, data integrity, security, and UX/resilience proof.**
**Score spine · scoreboard.schema.json + scoreboard-gate force locked target, eight dimensions, per-dimension floors, security floor, evidence refs, and freshness.**
**Definition-of-Done spine · DEFINITION-OF-DONE.md + definition-of-done-gate force every checked DoD item to cite a typed proof reference or existing local evidence file, and fail ship when any item is unchecked, stale, placeholder-filled, weakly waived, or fake-evidenced.**
**Terminal-audit spine · audit.schema.json + audit-contract-gate force real certification: scores, 13-layer walk, intent evidence, no blockers, no shortfalls, and fresh reproduced evidence.**

WALTEUR turns an idea into the single best, enterprise-grade, evidence-backed realization — and refuses to
say *best / done / sure* without cited, fresh evidence. It runs one disciplined lifecycle:

```
TODAY (current-stack + best-in-class benchmark)
  → DISCOVER  (validate the bet: opportunity-tree → red-team kill-criteria → cheapest test → PRD)
  → PRODUCT STANDARD (value loop → full app surface → business/trust/ops/launch)
  → PRODUCTION LAYERS (13 layers owned → evidenced → deferred with risk owner)
  → THINK → IMPROVE PROMPT + ENTERPRISE BLUEPRINT + SOURCE ROUTER → PLAN + DELIVERY ORCHESTRATION + PROJECT CONTEXT + FIGURE-IT-OUT RECOVERY + CONTEXT SENTINEL + SELF-IMPROVEMENT SCOUT → DEBATE REAL FORKS → ADR → BUILD
  → REVIEW (7-senior panel + independent outcome eval) → QA corps (typed multi-dimension proof) → SDLC RUN PROOF
  → AUDIT (scores + 13-layer walk + intended-vs-implemented + reproduced evidence) → SHIP → REFLECT
```

Most rework is not bad code — it is building the *wrong* thing. v9.0 adds the symmetric front-funnel twin of
plan-before-build: **no plan without a validated problem.**

## What's here

| Path | What it is |
|---|---|
| `walteur/SKILL.md` | The full build engine (also shipped as `WALTEUR-builder-CLAUDE.md` — byte-identical drop-in CLAUDE.md) |
| `walteur-skill/SKILL.md` | The **portable** form (`walteur-portable`) — the hook-free discipline, no repo needed |
| `walteur-discover/SKILL.md` | Companion: WHAT to build (PRD · opportunity-tree · strategy-red-team · prioritization · stories) |
| `walteur-design/SKILL.md` | Companion: how it LOOKS (DESIGN.md contract · screenshot-verify loop) |
| `walteur-kit/hooks/*.sh` | Discipline-gate hooks (spec-lint, spec-trace, design-gate, benchmark-gate, product-standard-gate, production-layers-gate, fitness-gate, a11y-content-lint, i18n-lint, sbom-gate, operate-readiness-gate, authz-tenant-gate, privacy-data-gate, sdlc-run-gate, adr-gate, prompt-refinement-gate, delivery-orchestration-gate, project-context-gate, self-improvement-gate, outcome-eval-gate, qa-contract-gate, scoreboard-gate, definition-of-done-gate, audit-contract-gate, edge-protection, prd-gate, **+ v9.1: ast-grep AST backend, `intent-trace.sh`, `osv-gate.sh`**, ...) |
| `walteur-kit/HARNESS-LOOP.md` | The canonical enterprise loop contract for software, workflows, docs, data/AI, cloud/IaC, and mixed builds |
| `walteur-kit/self-heal.sh` · `walteur-kit/source-manifest.json` · `walteur-kit/SOURCE-ROUTER.md` · `walteur-kit/schemas/source-manifest.schema.json` | The upstream source router: pins Tony's curated GitHub repos, checks drift, and requires source-use receipts before source-backed planning choices |
| `walteur-kit/schemas/source-use.schema.json` · `walteur-kit/hooks/source-use-gate.sh` | **v9.59** source-use receipt gate plus schema parity proof; validates source id, immutable pinned ref against `source-manifest.json`, extracted pattern, rejected parts, license/maintenance/security/fit checks, artifact refs, verification, rollback for installs/imports/copies/spec changes, blocked-by-default boundaries, and aggregate-poisoned schema drift |
| `walteur-kit/tool-acquisition.json` · `walteur-kit/schemas/tool-acquisition.schema.json` · `walteur-kit/hooks/tool-acquisition-proof.sh` · `walteur-kit/tool-acquisition/ast-grep/package-lock.json` | **v9.56** pinned, lockfile-backed CLI acquisition contracts; aggregate proof validates every npm-backed manifest entry, checks schema-declared uniqueness floors, runs 16/16 runner-local poison fixtures with nested shape and duplicate array proof, verifies CI preflight order, copies declared proof assets, poison-tests schema and manifest drift, and executes package prove commands from the manifest |
| `walteur-kit/hooks/enterprise-blueprint-gate.sh` · `walteur-kit/schemas/enterprise-blueprint.schema.json` · `walteur-kit/examples/enterprise-blueprint.good.json` | **v9.78** enterprise blueprint spine; forces the raw goal into a concrete user/job/artifact/surface/acceptance/trust/ops/cuts/final-packet build target before PLAN. Scaffold proof is 79/79, gate count is 76, aggregate proof is 161 passed / 0 failed / 0 skipped. |
| `walteur-kit/release-ledger.json` · `walteur-kit/schemas/release-ledger.schema.json` · `walteur-kit/hooks/release-ledger-lint.sh` | **v9.78** machine-readable release truth; validates current version strings, proof counts, aggregate proof history, stale proof prose, stale source-count prose, published schema parity, source-manifest count/id, registry count, scaffold proof, skill mirror pair, component manifest IDs, browser-proof evidence, migration-proof evidence, selected migration safety gates, selected architecture fitness gate, selected frontend quality gates, selected SBOM gate, selected operate-readiness gate/schema, selected SDLC-run gate/schema, selected AI-tool-governance gate/schema, selected AuthZ-tenant gate/schema, selected privacy-data gate/schema, normalized trace proof strings, and strict report counts; selected as baseline reflect gate |
| `walteur-kit/hooks/sbom-gate.sh` | Verify gate that validates non-empty CycloneDX/SPDX/Syft dependency inventory or live Syft generation for software, workflow, data/AI, cloud/IaC, and mixed builds |
| `walteur-kit/hooks/operate-readiness-gate.sh` · `walteur-kit/schemas/operate-readiness.schema.json` | Ship gate that fails runtime/deployable systems without fresh SLO, DORA, incident response, on-call, observability, rollback rehearsal, support handoff, and post-incident review proof |
| `walteur-kit/hooks/sdlc-run-gate.sh` · `walteur-kit/schemas/sdlc-run.schema.json` | Ship gate that fails ship/reflect runs without fresh five-stage SDLC execution proof: local build, shared dev, staging, beta, production, independent review, QA, adversarial checks, rollback, monitoring, signoff, and retro evidence |
| `walteur-kit/hooks/authz-tenant-gate.sh` · `walteur-kit/schemas/authz-tenant.schema.json` | Ship gate that fails authz/tenant/ship surfaces without fresh deny-by-default authorization, role/permission matrix, negative/anonymous/privilege tests, audit, signoff, and tenant-isolation evidence |
| `walteur-kit/hooks/privacy-data-gate.sh` · `walteur-kit/schemas/privacy-data.schema.json` | Ship gate that fails personal, sensitive, regulated, or AI-context data surfaces without fresh data lifecycle proof: inventory, purpose, minimization, lawful basis, retention, deletion/export, redacted logging, encryption, transfers, breach response, DPIA, tests, and signed evidence |
| `walteur-kit/hooks/frontend-budget.sh` · `walteur-kit/schemas/frontend-budget.schema.json` | Verify gate that fails frontend builds without bundle/Core Web Vitals budgets and fails built JS over budget |
| `walteur-kit/hooks/browser-proof-gate.sh` · `walteur-kit/schemas/browser-proof.schema.json` | Verify gate that fails UI builds without fresh replayable browser route, screenshot, accessibility, interaction, and command-output evidence |
| `walteur-kit/hooks/a11y-content-lint.sh` | Verify gate that fails frontend content accessibility issues: missing image alt, unlabeled inputs, generic links, and unnamed buttons |
| `walteur-kit/hooks/i18n-lint.sh` | Verify gate that fails i18n-enabled frontends with hardcoded user-facing strings or locale catalog key drift |
| `walteur-kit/hooks/migration-proof-gate.sh` · `walteur-kit/schemas/migration-proof.schema.json` | Verify gate that fails database migration work without fresh forward, rollback, verification, lock-risk, and backfill evidence |
| `walteur-kit/hooks/migration-lint.sh` | Verify gate that fails unsafe migration files: missing/no-op rollback, expand+contract in one up, unsafe Postgres indexes, and unsafe NOT NULL changes |
| `walteur-kit/hooks/migration-roundtrip.sh` | Verify gate that fails migrations missing the down/reverse direction required for up-down-up roundtrip proof, with live DB proof recorded when available |
| `walteur-kit/hooks/loop-workspace-gate.sh` | Baseline gate that verifies `LOG.md`, `signals/README.md`, `docs/README.md`, and `domains/README.md` stay present and schema-anchored |
| `walteur-kit/hooks/run-trace.sh` · `walteur-kit/hooks/trace-mine.sh` | Baseline trace substrate and reflect miner; explicit `tool_signature` spans or conservative `--command` normalization let trace-mine flag repeated successful equivalent command forms, while one-offs and unknown command families stay ignored |
| `walteur-kit/` | PRD/PLAN templates, schemas, Definition of Done, gate reports — see `walteur-kit/README.md` |
| `walteur-kit/PRODUCT-STANDARD.md` | Product/company completeness contract: value loop, full app surface, business model, trust/ops, launch readiness, signed cuts |
| `walteur-kit/scaffold/layers.template.json` | 13-layer production reality template for `walteur-kit/layers.json` |
| `walteur-kit/scaffold/harness-init.sh` | Bootstrap command that writes registry, build contract, estimate, initial runtime state, fork control, and the loop workspace substrate, then proves they reconcile; generated verification commands cover every selected spec-shipped gate |
| `walteur-kit/scaffold/build-contract.template.json` | Typed intake scaffold for the user outcome, class, risk, interfaces, verification gates, and evidence |
| `walteur-kit/hooks/build-contract-lint.sh` | Detect-or-skip gate that validates `walteur-kit/build-contract.json` before runtime state starts, including selected-gate command/manual-check coverage |
| `walteur-kit/gate-registry.json` | Class/risk matrix that declares which gates must appear for each build type |
| `walteur-kit/hooks/gate-registry-lint.sh` | Detect-or-skip gate that validates the matrix and checks build contracts include required gates |
| `walteur-kit/hooks/estimate-gate.sh` | Hard gate that validates `walteur-kit/estimate.json` and reconciles it with runtime budgets |
| `walteur-kit/hooks/current-stack-gate.sh` | Hard PLAN gate that validates `walteur-kit/current-stack.json`: run date, current sources, stack choices, stale-training checks, evidence refs, and stack-fingerprint drift acknowledgement |
| `walteur-kit/hooks/harness-state-lint.sh` | Detect-or-skip gate that validates `walteur-kit/autopilot/STATE.json` against the harness loop contract, including recovery policy, blocked-work recovery decisions, context sentinel, and replayable PASS evidence shape |
| `walteur-kit/hooks/phase-gate.sh` | Hard gate that blocks phase jumps without prior-stage evidence or real skip reasons |
| `walteur-kit/hooks/evidence-gate.sh` | Hard gate that proves cited evidence exists, is replayable or signed, and supports PASS claims |
| `walteur-kit/hooks/risk-acceptance-gate.sh` | Hard gate that proves high-risk ship and accepted-risk claims have approved owner signoff |
| `walteur-kit/hooks/adr-gate.sh` | Review/ship gate that blocks unresolved forks and rejects thin ADR records |
| `walteur-kit/hooks/prompt-refinement-gate.sh` | Plan gate that requires "Improve this prompt": raw ask, improved prompt, enterprise build brief, routing, specialist plan, verification plan, and stop conditions |
| `walteur-kit/hooks/delivery-orchestration-gate.sh` | Plan gate that requires agent roster, SDLC stages, role independence, frontend/backend/QA/security coverage, handoffs, worktree boundaries, and audit trail |
| `walteur-kit/hooks/project-context-gate.sh` | Plan gate that requires project-specific AGENTS/CLAUDE/rules context, context budget, baton, and subagent handoff refs |
| `walteur-kit/hooks/self-improvement-gate.sh` | Plan gate that requires trace mining, current GitHub/source scouting, bounded proposals, regression proof, and evidence-backed reusable lessons |
| `walteur-kit/hooks/outcome-eval-gate.sh` | Review gate that requires an independent outcome evaluator rubric with evidence, confidence, bias checks, and no blockers |
| `walteur-kit/hooks/qa-contract-gate.sh` | Verify gate that rejects shallow QA PASS stubs and validates multi-dimension evidence |
| `walteur-kit/hooks/scoreboard-gate.sh` | Ship gate that validates locked 8-dimension scores, floors, security floor, and score evidence |
| `walteur-kit/hooks/definition-of-done-gate.sh` | Ship gate that validates the DoD checklist is closed, backed by typed proof refs or existing local evidence files, reasoned for N/A, placeholder-free, and fresh |
| `walteur-kit/hooks/audit-contract-gate.sh` | Ship gate that rejects shallow audit stubs and validates the terminal audit certificate shape |
| `walteur-kit/hooks/skill-readiness.sh` | Hard gate that proves declared required skills left machine-readable breadcrumbs; fresh scaffolds include an explicit empty manifest so selected skill-readiness PASSes rather than SKIPs |
| `walteur-kit/hooks/devenv-gate.sh` | Gate that checks reproducible developer environment discipline for code-producing work |
| `walteur-kit/hooks/config-validation.sh` | Gate that checks validated config access and committed env secret hygiene |
| `walteur-kit/hooks/quickstart-check.sh` | Gate that proves README quickstart/onboarding shape and clean-container readiness where Docker is available |
| `walteur-kit/hooks/nfr-lint.sh` | Gate that checks non-functional requirements are quantified when NFR discipline is present |
| `walteur-kit/hooks/observe-lint.sh` | Gate that checks logging, metrics, tracing, and PII-in-log anti-patterns |
| `walteur-kit/hooks/perf-gate.sh` | Gate that checks tail-latency budgets and perf regression context when performance surfaces exist |
| `.claude/agents/specialists/` | Reusable specialist defs (e.g. `intent-auditor` — intended-vs-implemented) |
| `walteur-kit/ast-grep-rules/` · `sgconfig.yml` · `ast-grep-tests/` | **v9.1/v9.56** P12 structural rules + project config + good/poison twin fixtures (`ast-grep test` 9/9 through declared proof assets and the validated, runner-nested-shape-proven, schema-uniqueness-proven, CI-preflight-proven, prove-command-executed lockfile-backed acquisition runner) |
| `walteur-kit/schemas/recipe.schema.json` · `recipes/` | **v9.1** the recipe contract — a parameterized runnable workflow artifact (goose pattern, no runtime) |
| `walteur-kit/eval/ab-bench.sh` · `prove-pillar.md` | **v9.1** the A/B "prove-the-pillar-pays" benchmark harness (`--selftest` 10/10) |
| `walteur-kit/skills/build-with-agent-team/` · `rules/` · `extensions/` | **v9.1** contract-first agent-team skill · memory-discipline + karpathy-discipline rules · graphify extensions (install under `.claude/`) |
| `walteur-kit/canonical-kit-staging/` | **v9.1+** bi-temporal memory + `pause_per_task` + spec-trace T4 + harness-contract adoption patches for the runnable kit (`~/walteur/starter`) |
| `walteur-kit/UPGRADE-v9.1.md` | **v9.1** the upgrade spec: what shipped, what's staged, the roadmap, the honesty matrix |

> **Distribution note (honesty law §1).** This is the **spec distribution** — skill docs + discipline-gate
> hooks plus the runnable upstream self-heal/source-router spine. The full **runnable kit**
> (`walteur-starter`) additionally ships the 4 machinery hooks
> (kill-switch · gate-guard · tdd-guard · ship-gate) and the orchestrator. Where a doc says "HARD-wired" or quotes
> an aggregate selftest/gate-count, those are canonical-kit figures (see the §5.7 distribution banner).
> Self-test what ships here: `bash walteur-kit/hooks/prd-gate.sh --selftest` (5/5) and
> `bash walteur-kit/hooks/product-standard-gate.sh --selftest` (7/7) and
> `bash walteur-kit/hooks/production-layers-gate.sh --selftest` (8/8) and
> `bash walteur-kit/hooks/adr-gate.sh --selftest` (10/10) and
> `bash walteur-kit/hooks/prompt-refinement-gate.sh --selftest` (11/11) and
> `bash walteur-kit/hooks/delivery-orchestration-gate.sh --selftest` (13/13) and
> `bash walteur-kit/hooks/project-context-gate.sh --selftest` (9/9) and
> `bash walteur-kit/self-heal.sh --selftest` (12/12) and
> `bash walteur-kit/hooks/self-improvement-gate.sh --selftest` (14/14) and
> `bash walteur-kit/hooks/trace-mine.sh --selftest` (39/39) and
> `bash walteur-kit/hooks/outcome-eval-gate.sh --selftest` (13/13) and
> `bash walteur-kit/hooks/qa-contract-gate.sh --selftest` (11/11) and
> `bash walteur-kit/hooks/scoreboard-gate.sh --selftest` (10/10) and
> `bash walteur-kit/hooks/definition-of-done-gate.sh --selftest` (12/12) and
> `bash walteur-kit/hooks/audit-contract-gate.sh --selftest` (10/10).

## Three companions, one grammar
**discover** decides *what is worth building* · **design** decides *how it looks* · **walteur** *builds it* —
all governed by the same fail-closed, cite-or-veto, evidence-backed discipline.

## The harness contract
`walteur-kit/HARNESS-LOOP.md` is the short control surface: classify the request, write a typed build contract,
surface an estimate, keep `debate/OPEN.json` empty before ship, select gates from the class/risk registry, run the phase loop, require evidence at every gate, persist state, then reflect. The big skill docs explain the full engine; the harness
contract is what keeps every project type on the same enterprise-grade rails.
Start a new control surface with:

```bash
bash walteur-kit/scaffold/harness-init.sh --goal "Build the requested outcome" --class software --risk medium
```

## Provenance
By Tony Walteur. Synthesizes (MIT): obra/superpowers, nizos/tdd-guard, VoltAgent/awesome-design-md,
nextlevelbuilder/ui-ux-pro-max, vabole/apple-skills, smtg-ai/claude-squad, wshobson/agents,
microsoft/playwright-mcp, yamadashy/repomix, and **phuryn/pm-skills** (the v9.0 front-of-funnel spine —
opportunity-solution-tree, strategy-red-team, prioritization, create-prd, job-stories, intended-vs-implemented),
plus the 11-pillar tool spine (context7, storybook, spec-kit, gitleaks, shadcn/ui, OpenHands, browser-use,
sentry, …). **v9.1 adds** ast-grep/ast-grep (P12 AST), OSV.dev (P13 supply-chain), getzep/graphiti
(bi-temporal-memory PATTERN), block/goose (recipe-contract + OSV + injection PATTERN),
coleam00/context-engineering-intro (contract-first agent-team + WISC), snarktank/ai-dev-tasks
(lettered-Qs + relevant-files manifest), zilliztech/claude-context (Merkle incremental-sync PATTERN) —
**patterns/connections only, never their infra; graphify stays the one retrieval brain.**
**v9.10 adds Tony's curated upstream source graph** in `walteur-kit/source-manifest.json`, including
OpenMontage, PM-Skills, Agent-Reach, Headroom, Anthropic Skills/Knowledge Work Plugins, Superpowers,
gstack, Addy Osmani agent-skills, rtk, ECC, codegraph, Understand-Anything, academic research skills,
autoresearch, UI/UX, design-system, Apple-platform, defensive-security sources, and `ruvnet/ruflo`. The current graph pins
45 verified sources, with the latest batch adding Ruflo agent meta-harness patterns, TDD enforcement, Playwright MCP browser proof, repo
packing, parallel-agent sessions, memory hygiene, specialist catalogs, marketing, image/video workflows,
knowledge compilation, .NET display text, loop-workspace substrate, and a blocked-by-default anti-bot boundary lane.
Adapted into WALTEUR's terse idiom — never raw paste.

## License
MIT — see [LICENSE](LICENSE).
