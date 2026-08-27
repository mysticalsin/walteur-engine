# walteur-kit — runtime gates & artifacts (distribution note · honest by §1)

> **Nav:** score/ledger → [`../STAMP.md`](../STAMP.md) · first run → [`../QUICKSTART.md`](../QUICKSTART.md) ·
> gate failed? → [`REMEDIATION.md`](REMEDIATION.md) · health/triage → `bash walteur-kit/hooks/doctor.sh` ·
> upgrade plan → [`UPGRADE-S033.md`](UPGRADE-S033.md)

> **This `walteur-kit/` is part of the WALTEUR SPEC DISTRIBUTION** (skill docs + discipline-gate hooks),
> **NOT the full canonical runnable kit.** The canonical kit (`~/walteur/starter`) additionally ships
> the 4 machinery hooks (kill-switch · gate-guard · tdd-guard · ship-gate) and the
> `.claude/workflows/walteur.js` orchestrator. `walteur/SKILL.md`
> describes the FULL engine; where it says a gate is "HARD-wired" or quotes canonical aggregate figures,
> those are **canonical-kit figures** (see the §5.7 distribution banner). The Honesty
> Law (§1) forbids reading any artifact here as more-wired than it is.

## What is actually in THIS folder
- **`hooks/`** - discipline-gate hooks (design-gate, benchmark-gate, product-standard-gate, production-layers-gate, adr-gate, prompt-refinement-gate, delivery-orchestration-gate, project-context-gate, self-improvement-gate, outcome-eval-gate, qa-contract-gate, scoreboard-gate, definition-of-done-gate, audit-contract-gate, spec-lint,
  spec-trace, edge-protection, schema-lint, resilience-lint, prd-gate, ai-safety-gate, and more).
  Self-test the product spine here: `bash walteur-kit/hooks/prd-gate.sh --selftest` (**5/5**) and
  `bash walteur-kit/hooks/product-standard-gate.sh --selftest` (**7/7**) and
  `bash walteur-kit/hooks/enterprise-blueprint-gate.sh --selftest` (**8/8**) and
  `bash walteur-kit/hooks/production-layers-gate.sh --selftest` (**8/8**) and
  `bash walteur-kit/hooks/fitness-gate.sh --selftest` (**10/10**) and
  `bash walteur-kit/hooks/a11y-content-lint.sh --selftest` (**8/8**) and
	  `bash walteur-kit/hooks/i18n-lint.sh --selftest` (**7/7**) and
	  `bash walteur-kit/hooks/sbom-gate.sh --selftest` (**14/14**) and
	  `bash walteur-kit/hooks/operate-readiness-gate.sh --selftest` (**14/14**) and
	  `bash walteur-kit/hooks/sdlc-run-gate.sh --selftest` (**14/14**) and
	  `bash walteur-kit/hooks/ai-tool-governance-gate.sh --selftest` (**14/14**) and
	  `bash walteur-kit/hooks/authz-tenant-gate.sh --selftest` (**14/14**) and
	  `bash walteur-kit/hooks/privacy-data-gate.sh --selftest` (**15/15**) and
	  `bash walteur-kit/hooks/adr-gate.sh --selftest` (**10/10**) and
  `bash walteur-kit/hooks/prompt-refinement-gate.sh --selftest` (**11/11**) and
  `bash walteur-kit/hooks/delivery-orchestration-gate.sh --selftest` (**13/13**) and
  `bash walteur-kit/hooks/project-context-gate.sh --selftest` (**9/9**) and
  `bash walteur-kit/hooks/self-improvement-gate.sh --selftest` (**14/14**) and
  `bash walteur-kit/hooks/trace-mine.sh --selftest` (**39/39**) and
  `bash walteur-kit/hooks/outcome-eval-gate.sh --selftest` (**13/13**) and
  `bash walteur-kit/hooks/qa-contract-gate.sh --selftest` (**11/11**) and
  `bash walteur-kit/hooks/scoreboard-gate.sh --selftest` (**10/10**) and
  `bash walteur-kit/hooks/definition-of-done-gate.sh --selftest` (**12/12**) and
  `bash walteur-kit/hooks/audit-contract-gate.sh --selftest` (**10/10**). The 4 machinery hooks +
  `ship-gate.sh` are **NOT present here** (they live in the canonical runnable kit). The discipline hooks
  are complete, self-tested, hard-capable hooks; dispatch by `ship-gate.sh` remains a canonical-kit
  integration concern.
- **`PRD.template.md` · `schemas/prd.schema.json`** — the DISCOVER-phase PRD contract (§2.5, walteur-discover).
- **`PRODUCT-STANDARD.md` · `schemas/product-standard.schema.json`** - the product/company completeness contract for user-facing, commercial, venture-grade, or full-product builds. It forces value loop, full app surface, business model, trust/ops, launch readiness, and signed cuts.
- **`scaffold/layers.template.json` · `schemas/production-layers.schema.json`** - the 13-layer production reality contract for `walteur-kit/layers.json`.
- **`hooks/fitness-gate.sh`** - the architecture fitness contract for software and mixed builds. It fails invalid layer JSON, declared dependency cycles, forbidden direct or transitive dependencies, and failing configured architecture tools. Self-test: `bash walteur-kit/hooks/fitness-gate.sh --selftest` (**10/10**).
- **`hooks/a11y-content-lint.sh`** - the frontend content accessibility contract for software and mixed builds. It fails missing image alt text, unlabeled inputs, generic link text, and unnamed buttons. Self-test: `bash walteur-kit/hooks/a11y-content-lint.sh --selftest` (**8/8**).
- **`hooks/i18n-lint.sh`** - the i18n contract for software and mixed builds when an i18n framework or catalog exists. It fails hardcoded user-facing strings and locale catalog key drift. Self-test: `bash walteur-kit/hooks/i18n-lint.sh --selftest` (**7/7**).
- **`hooks/sbom-gate.sh`** - the dependency inventory/SBOM contract for software, workflow, data/AI, cloud/IaC, and mixed builds. It validates non-empty CycloneDX, SPDX, or Syft JSON inventories, can prove live Syft generation, fails malformed or empty SBOMs, and records a loud SKIP when dependency signals exist but no SBOM proof tool is available. Self-test: `bash walteur-kit/hooks/sbom-gate.sh --selftest` (**14/14**).
- **`schemas/operate-readiness.schema.json` · `hooks/operate-readiness-gate.sh`** - the operate-stage runtime contract for software, workflow, data/AI, cloud/IaC, and mixed builds. Runtime/deployable surfaces must prove fresh SLOs, DORA targets, incident response, on-call ownership, observability, rollback rehearsal, support handoff, and post-incident review evidence. Self-test: `bash walteur-kit/hooks/operate-readiness-gate.sh --selftest` (**14/14**).
- **`schemas/sdlc-run.schema.json` · `hooks/sdlc-run-gate.sh`** - the ship-stage execution contract for software, workflow, data/AI, cloud/IaC, and mixed builds. Ship/reflect runs must prove the five-stage SDLC actually executed in order with local build, shared dev, staging, beta, production, independent review, QA, adversarial checks, rollback, monitoring, signoff, and retro evidence. Self-test: `bash walteur-kit/hooks/sdlc-run-gate.sh --selftest` (**14/14**).
- **`schemas/authz-tenant.schema.json` · `hooks/authz-tenant-gate.sh`** - the ship-stage authorization and tenant-isolation contract for software, workflow, data/AI, cloud/IaC, and mixed builds. Authz/tenant/ship surfaces must prove deny-by-default decisions, role/permission matrices, fail-closed and least-privilege controls, session/token policy, audit logging, positive and negative authorization tests, anonymous denial, privilege escalation prevention, tenant policy/RLS, cross-tenant denial, signed evidence, and fresh local proof files. Self-test: `bash walteur-kit/hooks/authz-tenant-gate.sh --selftest` (**14/14**).
- **`schemas/privacy-data.schema.json` · `hooks/privacy-data-gate.sh`** - the ship-stage privacy data lifecycle contract for software, workflow, data/AI, cloud/IaC, and mixed builds. Personal, sensitive, regulated, or AI-context data surfaces must prove inventory, processing records, purpose, minimization, lawful basis, retention, deletion/export, backup deletion policy, redacted logging, encryption, access control, transfers, breach response, DPIA handling, lifecycle tests, signed evidence, and fresh local proof files. Self-test: `bash walteur-kit/hooks/privacy-data-gate.sh --selftest` (**15/15**).
- **`schemas/adr.schema.json` · `hooks/adr-gate.sh`** - the decision record contract. It blocks non-empty `debate/OPEN.json` at ship and rejects thin ADR records without rejected alternatives, dissent, ownership, status, and typed index evidence.
- **`schemas/prompt-refinement.schema.json` · `hooks/prompt-refinement-gate.sh`** - the Improve-this-prompt contract. It forces the raw user request to become an enterprise build brief with outcome, acceptance criteria, routing, specialist plan, verification plan, and stop conditions before PLAN.
- **`enterprise-blueprint.json` · `schemas/enterprise-blueprint.schema.json` · `hooks/enterprise-blueprint-gate.sh`** - the plan-stage concreteness contract. It turns the raw goal into users, jobs, artifacts, surfaces, acceptance criteria, trust model, operating model, explicit cuts, and the final delivery packet before PLAN. Self-test: `bash walteur-kit/hooks/enterprise-blueprint-gate.sh --selftest` (**8/8**).
- **`schemas/current-stack.schema.json` · `hooks/current-stack-gate.sh`** - the current-stack contract. It forces PLAN and later phases to prove run-date stack choices against current official/source material, stale-training checks, evidence refs, and stack-fingerprint drift acknowledgements.
- **`schemas/harness-state.schema.json` · `hooks/evidence-gate.sh`** - the replayable PASS evidence contract. It rejects summary-only green evidence; PASS proof must be path-backed, command output with timestamp, or signed human proof with owner and timestamp.
- **`schemas/delivery-orchestration.schema.json` · `hooks/delivery-orchestration-gate.sh`** - the delivery team contract. It forces the selected agent roster, SDLC stages, role independence, frontend/backend/QA/security coverage, handoffs, worktree boundaries, and audit trail to be explicit.
- **`schemas/project-context.schema.json` · `hooks/project-context-gate.sh`** - the project-context contract. It forces project-specific AGENTS/CLAUDE/rules context, context budget, baton, and subagent handoff evidence.
- **`hooks/loop-workspace-gate.sh`** - the loop workspace contract. It verifies `LOG.md`, `signals/README.md`, `docs/README.md`, and `domains/README.md` exist and contain the required work-log, signal, doc, and domain schema anchors. Self-test: `bash walteur-kit/hooks/loop-workspace-gate.sh --selftest` (**6/6**).
- **`schemas/self-improvement.schema.json` · `hooks/self-improvement-gate.sh`** - the compounding quality contract. It forces trace mining, current GitHub/source scouting, bounded proposals, regression proof, rollback proof for promoted changes, and evidence-backed lesson capture.
- **`hooks/run-trace.sh` · `hooks/trace-mine.sh`** - the trace substrate and reflect-stage miner. `run-trace.sh emit` can record explicit `tool_signature` values or derive conservative signatures from known-equivalent `--command` forms; `trace-mine.sh` reads `run-trace.jsonl`, `refine-log.json`, `SUMMARY.jsonl`, and `receipt.json`, ignores one-offs, writes `trace-mine-report.json`, and appends proposal-only systemic findings, including repeated successful normalized tool signatures, to `_relay/ISSUES.md`. Self-tests: `bash walteur-kit/hooks/run-trace.sh --selftest` (**25/25**) and `bash walteur-kit/hooks/trace-mine.sh --selftest` (**39/39**).
- **`schemas/frontend-budget.schema.json` · `hooks/frontend-budget.sh`** - the frontend budget contract. It fails frontend builds without browser payload/Core Web Vitals budgets and fails built JS over budget. Self-test: `bash walteur-kit/hooks/frontend-budget.sh --selftest` (**8/8**).
- **`schemas/browser-proof.schema.json` · `hooks/browser-proof-gate.sh`** - the real-browser evidence contract. It fails UI builds without fresh route, viewport/browser, command-output, screenshot, accessibility, and interaction proof. Self-test: `bash walteur-kit/hooks/browser-proof-gate.sh --selftest` (**10/10**).
- **`schemas/migration-proof.schema.json` · `hooks/migration-proof-gate.sh`** - the database migration proof contract. It fails migration work without fresh forward, rollback, verification, lock-risk, and backfill evidence. Self-test: `bash walteur-kit/hooks/migration-proof-gate.sh --selftest` (**10/10**).
- **`hooks/migration-lint.sh` · `hooks/migration-roundtrip.sh`** - the executable migration safety contracts. They fail missing/no-op rollbacks, expand+contract migrations, unsafe index locks, unsafe NOT NULL changes, and missing down/reverse directions. Self-tests: `bash walteur-kit/hooks/migration-lint.sh --selftest` (**9/9**) and `bash walteur-kit/hooks/migration-roundtrip.sh --selftest` (**7/7**).
- **`schemas/outcome-eval.schema.json` · `hooks/outcome-eval-gate.sh`** - the independent outcome evaluator contract. It rejects builder self-review, weak rubrics, missing evidence, low confidence, missing bias checks, blockers, and stale evaluations.
- **`schemas/source-use.schema.json` · `hooks/source-use-gate.sh`** - the upstream source-use receipt contract. It treats `source-use.json` as NOT_APPLICABLE when absent, but fails malformed receipts, unknown source ids, mutable refs, refs not matching `source-manifest.json`, blocked-by-default adoption, unsafe adoption checks, missing verification, unsafe refs, and missing rollback for install/import/copy/spec-change use. Self-test: `bash walteur-kit/hooks/source-use-gate.sh --selftest` (**9/9**).
- **`schemas/qa-report.schema.json` · `hooks/qa-contract-gate.sh`** - the QA proof contract. It rejects shallow PASS stubs, missing QA dimensions, logic/security/data VETOs hidden under top-level PASS, failed unit commands, stale QA reports, and missing PRD acceptance-criteria coverage.
- **`schemas/scoreboard.schema.json` · `hooks/scoreboard-gate.sh`** - the eight-dimension score contract. It rejects two-field score stubs, unlocked targets, composite below target, scores below floor, security below 8, missing evidence refs, stale scoreboards, and missing dimensions.
- **`DEFINITION-OF-DONE.md` · `hooks/definition-of-done-gate.sh`** - the Definition-of-Done contract. At ship/reflect it rejects missing or unchecked DoD items, checked items without validated proof refs, loose fake evidence text, missing/empty/outside-root evidence files, weak `N/A` lines, placeholders, and stale checklists. Self-test: `bash walteur-kit/hooks/definition-of-done-gate.sh --selftest` (**12/12**).
- **`schemas/audit.schema.json` · `hooks/audit-contract-gate.sh`** - the terminal audit certificate contract. It rejects shallow `certified:true` stubs, missing 13-layer walks, missing intended-vs-implemented evidence, blockers, shortfalls, stale evidence, and unreproduced evidence.
- **`HARNESS-LOOP.md`** - the canonical enterprise loop contract across software, workflows, documents, data/AI, cloud/IaC, and mixed builds.
- **`self-heal.sh` · `source-manifest.json` · `SOURCE-ROUTER.md` · `schemas/source-manifest.schema.json`** - the upstream source router. It pins 45 of Tony's curated GitHub repos, including `ruvnet/ruflo`, checks drift without auto-applying changes, and requires source-use receipts before stack, workflow, skill, tool, or subagent choices. Self-test: `bash walteur-kit/self-heal.sh --selftest` (**12/12**).
- **`tool-acquisition.json` · `schemas/tool-acquisition.schema.json` · `hooks/tool-acquisition-proof.sh` · `tool-acquisition/ast-grep/package-lock.json`** - the pinned, lockfile-backed tool-acquisition contract. The schema declares expressible uniqueness floors, the runner locally validates manifest shape, proves 16/16 poison fixtures across every manifest object layer and duplicate acquisition arrays, aggregate selftest validates every npm-backed acquisition entry, verifies CI preflight order, copies declared proof assets, poison-tests schema and manifest drift, then runs acquisition-backed proofs; CI enforces a zero-skip report.
- **`release-ledger.json` · `schemas/release-ledger.schema.json` · `hooks/release-ledger-lint.sh`** - the machine-readable release truth contract. It validates current version strings, aggregate proof counts, aggregate proof history, stale proof prose, stale source-count prose, published schema parity, source-manifest count/id, scaffold proof counts, registry gate count, selected release gate, mirrored skill pair, component manifest IDs, selected migration safety gates, selected architecture fitness gate, selected frontend quality gates, selected SBOM gate, selected operate-readiness gate/schema, selected SDLC-run gate/schema, selected AI-tool-governance gate/schema, selected AuthZ-tenant gate/schema, selected privacy-data gate/schema, and strict report counts after aggregate proof. Self-test: `bash walteur-kit/hooks/release-ledger-lint.sh --selftest` (**12/12**).
- **`scaffold/harness-init.sh`** - bootstrap command that copies the source router and DoD template, writes `gate-registry.json`, `build-contract.json`, `estimate.json`, `autopilot/STATE.json`, `debate/OPEN.json`, `required-skills.json`, and the loop workspace substrate (`LOG.md`, `signals/README.md`, `docs/README.md`, `domains/README.md`), then runs the bootstrap-safe reconciliation gates. The generated `build-contract.json` includes a registry-derived verification command that covers every selected spec-shipped gate hook, with manual checks for canonical gates; `STATE.json` includes the figure-it-out recovery policy and the `Tony,` context sentinel. Self-test: `bash walteur-kit/scaffold/harness-init.sh --selftest` (**79/79**).
- **`scaffold/build-contract.template.json`** - the typed intake scaffold for outcome, build class, risk, interfaces, gates, and evidence.
- **`gate-registry.json`** - the class/risk gate matrix that decides which gates a build contract must declare.
- **`DEFINITION-OF-DONE.md`** - the per-build DoD checklist template (§4.3); every checked item needs same-line `Evidence:` with a typed proof ref or existing non-empty project file.

### v9.78 additions (this branch - SPEC tree, self-tested here)
- **Enterprise blueprint spine** - `schemas/enterprise-blueprint.schema.json` and `hooks/enterprise-blueprint-gate.sh` force the plan-stage target to be concrete before implementation: raw goal, upgraded enterprise goal, primary user, owner or buyer, job map, artifact map, surface map, acceptance suite, trust model, operating model, quality bar, explicit cuts, and final delivery packet. `scaffold/harness-init.sh` now writes `enterprise-blueprint.json`, runs `enterprise-blueprint-gate.sh`, and proves the generated blueprint in its **79/79** selftest. Gate count is **76**. Aggregate proof is **161 passed, 0 failed, 0 skipped**.

### v9.77 additions (this branch - SPEC tree, self-tested here)
- **Privacy data proof gate** - `schemas/privacy-data.schema.json` publishes the lifecycle evidence floor for personal, sensitive, regulated, and AI-context data: inventory, processing records, purpose, minimization, lawful basis, retention, deletion/export, backup deletion policy, redacted logging, encryption, access control, transfers, breach response, DPIA handling, tests, signoff, and local proof files. `hooks/privacy-data-gate.sh` now owns a **15/15** selftest, honors `WALTEUR_ROOT`, requires fresh `walteur-kit/privacy-data.json` proof at ship/reflect or when privacy/data signals are detected, validates local evidence refs, and `gate-registry.json` selects it for software, workflow, data/AI, cloud/IaC, and mixed builds. Aggregate proof now proves **158 passed, 0 failed, 0 skipped**.

### v9.76 additions (this branch - SPEC tree, self-tested here)
- **AuthZ tenant proof gate** - `schemas/authz-tenant.schema.json` publishes the deny-by-default authorization, role/permission matrix, fail-closed, least-privilege, session/token policy, audit, negative/anonymous/privilege test, signoff, and tenant-isolation evidence floor for authz/tenant/ship surfaces. `hooks/authz-tenant-gate.sh` now owns a **14/14** selftest, honors `WALTEUR_ROOT`, requires fresh `walteur-kit/authz-tenant.json` proof at ship/reflect or when authz/tenant code is detected, validates local evidence refs, and `gate-registry.json` selects it for software, workflow, data/AI, cloud/IaC, and mixed builds. Aggregate proof now proves **155 passed, 0 failed, 0 skipped**.

### v9.75 additions (this branch - SPEC tree, self-tested here)
- **AI-tool governance gate** - `schemas/ai-tool-governance.schema.json` publishes the inventory, approval, runtime-boundary, human-review, output-gate, cost-control, audit-log, revoke-plan, and rollback evidence floor for AI tools, models, agents, MCP servers, plugins, connectors, browser tools, local tools, and CI surfaces. `hooks/ai-tool-governance-gate.sh` now owns a **14/14** selftest, honors `WALTEUR_ROOT`, requires fresh `walteur-kit/ai-tool-governance.json` proof at ship/reflect, rejects confidential/restricted data on general-purpose runtimes, blocks Opus execution-stage use, validates local evidence refs, and `gate-registry.json` selects it for software, workflow, data/AI, cloud/IaC, and mixed builds. Aggregate proof now proves **152 passed, 0 failed, 0 skipped**.

### v9.74 additions (this branch - SPEC tree, self-tested here)
- **SDLC run proof gate** - `schemas/sdlc-run.schema.json` publishes the five-stage execution floor for local build, shared dev, staging, beta, production, independent review, QA, adversarial checks, rollback, monitoring, signoff, and retro evidence. `hooks/sdlc-run-gate.sh` now owns a **14/14** selftest, honors `WALTEUR_ROOT`, requires fresh `walteur-kit/sdlc-run.json` proof at ship/reflect, validates local evidence refs, and `gate-registry.json` selects it for software, workflow, data/AI, cloud/IaC, and mixed builds. Ruflo is refreshed to current `main` head `79b8634bd1375de4afd60e5f40067b41febc1beb`. Aggregate proof now proves **149 passed, 0 failed, 0 skipped**.

### v9.73 additions (this branch - SPEC tree, self-tested here)
- **operate readiness gate** - `schemas/operate-readiness.schema.json` publishes the operate-stage evidence floor for SLOs, DORA metrics, incident response, on-call ownership, observability, rollback rehearsal, support handoff, and post-incident learning. `hooks/operate-readiness-gate.sh` now owns a **14/14** selftest, honors `WALTEUR_ROOT`, detects runtime/deployable surfaces, requires fresh `walteur-kit/operate-readiness.json` proof for those surfaces, validates evidence refs, and `gate-registry.json` selects it for software, workflow, data/AI, cloud/IaC, and mixed builds. Aggregate proof now proves **145 passed, 0 failed, 0 skipped**.

### v9.72 additions (this branch - SPEC tree, self-tested here)
- **SBOM supply-chain gate** - `hooks/sbom-gate.sh` now owns a **14/14** selftest, honors `WALTEUR_ROOT`, validates non-empty CycloneDX/SPDX/Syft inventory or live Syft generation, fails malformed or empty SBOMs, writes bypass/skip reports, and `gate-registry.json` selects it for software, workflow, data/AI, cloud/IaC, and mixed builds. Aggregate proof now proves **142 passed, 0 failed, 0 skipped**.

### v9.71 additions (this branch - SPEC tree, self-tested here)
- **tool signature normalization** - `hooks/run-trace.sh emit --command` now derives conservative signatures for known-equivalent command forms such as shell-wrapped `npm test` and `npm run test` with the same arguments. `hooks/trace-mine.sh` groups those shared normalized signatures as redundant successful tool calls, while unknown command families stay ungrouped unless an explicit signature is supplied. Self-tests: **run-trace 25/25**, **trace-mine 39/39**. Aggregate proof remains **141 passed, 0 failed, 0 skipped**.

### v9.70 additions (this branch - SPEC tree, self-tested here)
- **frontend quality gates** - `hooks/a11y-content-lint.sh` now owns an **8/8** selftest, `hooks/i18n-lint.sh` now owns a **7/7** selftest, both honor `WALTEUR_ROOT`, both write bypass reports, and `gate-registry.json` selects both for software and mixed builds. Aggregate proof now proves **141 passed, 0 failed, 0 skipped**.

### v9.69 additions (this branch - SPEC tree, self-tested here)
- **architecture fitness gate** - `hooks/fitness-gate.sh` now owns a **10/10** selftest, honors `WALTEUR_ROOT`, writes bypass reports, and `gate-registry.json` selects it for software and mixed builds. Aggregate proof now proves **139 passed, 0 failed, 0 skipped**.

### v9.68 additions (this branch - SPEC tree, self-tested here)
- **migration safety gates** - `hooks/migration-lint.sh` now owns a **9/9** selftest, `hooks/migration-roundtrip.sh` now owns a **7/7** selftest, both honor `WALTEUR_ROOT`, and `gate-registry.json` selects both for software and mixed builds. Aggregate proof now proves **138 passed, 0 failed, 0 skipped**.

### v9.67 additions (this branch - SPEC tree, self-tested here)
- **migration proof gate** - `schemas/migration-proof.schema.json` now publishes database rollout evidence floors, `hooks/migration-proof-gate.sh` owns a **10/10** selftest, and `gate-registry.json` selects `migration-proof-gate` for software and mixed builds. Aggregate proof validates the schema floors, rejects a poisoned schema missing the `verification_refs.minItems` floor, and now proves **136 passed, 0 failed, 0 skipped**.

### v9.66 additions (this branch - SPEC tree, self-tested here)
- **browser proof gate** - `schemas/browser-proof.schema.json` now publishes real-browser evidence floors, `hooks/browser-proof-gate.sh` owns a **10/10** selftest, and `gate-registry.json` selects `browser-proof-gate` for software and mixed builds. Aggregate proof validates the schema floors, rejects a poisoned schema missing the `routes.minItems` floor, and now proves **133 passed, 0 failed, 0 skipped**.

### v9.65 additions (this branch - SPEC tree, self-tested here)
- **frontend budget gate** - `schemas/frontend-budget.schema.json` now publishes bundle and Core Web Vitals floors, `hooks/frontend-budget.sh` owns an **8/8** selftest, and `gate-registry.json` selects `frontend-budget` for software and mixed builds. Aggregate proof validates the schema floors, rejects a poisoned schema missing the `max_kb` floor, and now proves **130 passed, 0 failed, 0 skipped**.

### v9.64 additions (this branch - SPEC tree, self-tested here)
- **source-count claim truth** - `release-ledger.json` now declares `source_claim_paths`, `schemas/release-ledger.schema.json` publishes that floor, and `hooks/release-ledger-lint.sh` rejects stale source-count prose against `source-manifest.json`. This caught and fixed the harness loop's stale old-count claim after the manifest reached 45 sources. Hook selftest: **12/12**. Aggregate proof remains **127 passed, 0 failed, 0 skipped**.

### v9.63 additions (this branch - SPEC tree, self-tested here)
- **trace redundancy mining** - `hooks/run-trace.sh emit` now accepts `--signature` / `--tool_signature` and records an optional `tool_signature` without changing the required seven-key trace contract. `hooks/trace-mine.sh` now mines repeated identical successful signatures as redundant tool-call patterns, emits proposal-only findings, and proves a one-off signature is ignored. Self-tests: **run-trace 22/22**, **trace-mine 33/33**. Aggregate proof remains **127 passed, 0 failed, 0 skipped**.

### v9.62 additions (this branch - SPEC tree, self-tested here)
- **Ruflo source-router addition** - `source-manifest.json` now pins `ruvnet/ruflo` as an agent meta-harness source for swarm coordination, plugin architecture, adaptive memory, federation patterns, security guardrails, cost controls, witness verification, dual Claude/Codex collaboration, and MetaHarness audit concepts. Current manifest head: `79b8634bd1375de4afd60e5f40067b41febc1beb`. `release-ledger.json`, `schemas/release-ledger.schema.json`, and `hooks/release-ledger-lint.sh` verify the source manifest path, expected source count, and required source id so the routed source set cannot silently drop Ruflo. Hook selftest: **11/11**. Aggregate proof: **127 passed, 0 failed, 0 skipped**.

### v9.61 additions (this branch - SPEC tree, self-tested here)
- **release-ledger schema parity** - aggregate selftest now validates the published `schemas/release-ledger.schema.json` for the history and proof-claim floors enforced by `hooks/release-ledger-lint.sh`: required aggregate history, unique history records, version pattern, zero failed/skipped constants, and configured proof-claim paths. It also rejects a poisoned schema missing the history version floor. Aggregate proof: **126 passed, 0 failed, 0 skipped**.

### v9.60 additions (this branch - SPEC tree, self-tested here)
- **release proof-claim history** - `release-ledger.json` now carries aggregate proof history plus proof-claim scan paths, and `hooks/release-ledger-lint.sh` rejects prose where a known version appears beside the wrong aggregate proof count. Hook selftest now proves stale aggregate proof prose fails closed: **10/10**. Aggregate proof remains **124 passed, 0 failed, 0 skipped**.

### v9.59 additions (this branch - SPEC tree, self-tested here)
- **source-use schema parity** - aggregate selftest now validates the published `schemas/source-use.schema.json` for the receipt floors enforced by `hooks/source-use-gate.sh`: required receipt fields, immutable pinned-ref pattern, adoption use types, rejected-parts/artifact refs, fit-check shape, and safety check evidence. It also rejects a poisoned schema missing the pinned-ref immutability floor. Aggregate proof: **124 passed, 0 failed, 0 skipped**.

### v9.58 additions (this branch - SPEC tree, self-tested here)
- **source-use receipt gate** - `schemas/source-use.schema.json` and `hooks/source-use-gate.sh` turn SOURCE-USE from protocol into a machine-checkable receipt contract. Receipts must prove source id, immutable pinned ref against `source-manifest.json`, extracted pattern, rejected parts, license/maintenance/security/fit checks, artifact refs, verification, and rollback for install/import/copy/spec-change use; blocked-by-default sources cannot be adopted silently. Hook selftest: **9/9**. Scaffold proof: **76/76**. Gate count: **54**. Aggregate proof: **122 passed, 0 failed, 0 skipped**.

### v9.57 additions (this branch - SPEC tree, self-tested here)
- **release ledger gate** - `release-ledger.json`, `schemas/release-ledger.schema.json`, and `hooks/release-ledger-lint.sh` make current version, proof counts, registry count, scaffold count, mirrored docs, and component manifest IDs machine-checkable. The hook selftests 9/9, baseline selects `release-ledger-lint`, scaffold proof is **74/74**, and aggregate proof is **120 passed, 0 failed, 0 skipped**.

### v9.56 additions (this branch - SPEC tree, self-tested here)
- **acquisition schema uniqueness parity** - `schemas/tool-acquisition.schema.json` now declares `uniqueItems` for the tools array, local binaries, proof args, and proof assets; `hooks/tool-acquisition-proof.sh --selftest` proves 16/16 local fixtures by adding duplicate local binary and duplicate proof arg rejection; aggregate selftest poison-tests missing schema uniqueness floors. Aggregate proof is **118 passed, 0 failed, 0 skipped**.

### v9.55 additions (this branch - SPEC tree, self-tested here)
- **acquisition nested-shape proof** - `hooks/tool-acquisition-proof.sh --selftest` now proves 14/14 local fixtures by adding unknown tool, on-demand, proof, and lockfile key rejection to the existing root unknown-key fixture. Aggregate proof remains **117 passed, 0 failed, 0 skipped**.

### v9.54 additions (this branch - SPEC tree, self-tested here)
- **acquisition CI preflight** - `.github/workflows/twin-invariant.yml` now runs `hooks/tool-acquisition-proof.sh --check-only` and `--selftest` before install/prove. Aggregate selftest verifies that preflight order before publishing green. Current aggregate proof: **117 passed, 0 failed, 0 skipped**.

### v9.53 additions (this branch - SPEC tree, self-tested here)
- **acquisition runner schema floor** - `hooks/tool-acquisition-proof.sh --check-only` now validates the full root, tool, on-demand, proof, and lockfile manifest shape before field drift checks. `--selftest` proves 10/10 local fixtures by adding duplicate tool id, duplicate proof asset, and unknown manifest key rejection. At v9.53 aggregate proof was **116 passed, 0 failed, 0 skipped**.

### v9.52 additions (this branch - SPEC tree, self-tested here)
- **acquisition runner selftest parity** - `hooks/tool-acquisition-proof.sh --selftest` now proves 7/7 local fixtures: valid fixture acceptance, missing proof asset rejection, package dependency drift rejection, prove-script drift rejection, manifest binary-path drift rejection, install-command drift rejection, and package-lock integrity drift rejection. At v9.52 aggregate proof was **116 passed, 0 failed, 0 skipped**.

### v9.51 additions (this branch - SPEC tree, self-tested here)
- **acquisition runner selftest** - `hooks/tool-acquisition-proof.sh` now owns `--check-only` contract validation and `--selftest` poison fixtures for missing proof assets, package dependency drift, and prove-script drift. Aggregate selftest runs the runner selftest before executing manifest-declared proofs, so future acquired tools inherit the same fail-closed contract. At v9.51 aggregate proof was **116 passed, 0 failed, 0 skipped**.

### v9.50 additions (this branch - SPEC tree, self-tested here)
- **manifest-driven acquisition runner** - `tool-acquisition.json` now declares `proof_assets`; `hooks/tool-acquisition-proof.sh` reads every npm-backed manifest tool, installs checked-in workspaces when asked, proves in place when asked, and otherwise builds an isolated temp proof root with exactly the declared assets before running `npm run prove`. Aggregate selftest rejects missing proof assets and package prove-script drift, then executes the manifest runner. CI now calls the same runner and no longer names ast-grep directly. At v9.50 aggregate proof was **115 passed, 0 failed, 0 skipped**.

### v9.49 additions (this branch - SPEC tree, self-tested here)
- **live prove-command acquisition** - `tool-acquisition.json` records the package `prove_script` beside `prove_command`; `selftest.sh` validates package `scripts.prove` against the manifest, installs a locked workspace copy, and executes `npm run prove` so the acquisition package script, `sgconfig.yml`, AST rules, test fixtures, lockfile install, and binary all prove together. `.github/workflows/twin-invariant.yml` also runs the locked workspace proof before aggregate selftest. At v9.49 aggregate proof was **113 passed, 0 failed, 0 skipped**.

### v9.48 additions (this branch - SPEC tree, self-tested here)
- **generic poisoned tool acquisition** - `tool-acquisition.json`, `schemas/tool-acquisition.schema.json`, and `selftest.sh` now validate every npm-backed acquisition entry against its package workspace, package.json dependency, package-lock tarball URL and integrity, binary path, install command, prove command, and proof config. Aggregate selftest also creates poisoned fixtures proving manifest binary-path drift, package.json dependency drift, and package-lock integrity drift fail closed before any acquired tool can publish green. At v9.48 aggregate proof was **112 passed, 0 failed, 0 skipped**.

### v9.47 additions (this branch - SPEC tree, self-tested here)
- **lockfile-backed tool acquisition** - `tool-acquisition/ast-grep/package.json` and `package-lock.json` pin `@ast-grep/cli@0.44.0` with npm lockfile v3 and the tarball integrity recorded in `tool-acquisition.json`. Aggregate selftest validates manifest plus lockfile, prefers an installed locked binary when present, otherwise runs a temp `npm ci --prefer-offline --no-audit --fund=false` from the checked-in lockfile, and `.github/workflows/twin-invariant.yml` installs the locked workspace before enforcing `selftest-report.json` as `PASS` / `ALL_GREEN` / zero skipped. At v9.47 the aggregate proof was **109 passed, 0 failed, 0 skipped**.

### v9.46 additions (this branch - SPEC tree, self-tested here)
- **tool-acquisition contract + CI aggregate proof** - `tool-acquisition.json` and `schemas/tool-acquisition.schema.json` pinned the on-demand `@ast-grep/cli@0.44.0` fallback. Aggregate selftest validated that contract before running P12 AST twins, preferred the manifest-pinned `npx` path for reproducible proof, accepted local `ast-grep` only when it matched the manifest version and `npx` was unavailable, and `.github/workflows/twin-invariant.yml` enforced `selftest-report.json` as `PASS` / `ALL_GREEN` / zero skipped. At v9.46 the aggregate proof was **109 passed, 0 failed, 0 skipped**.

### v9.45 additions (this branch - SPEC tree, self-tested here)
- **pinned ast-grep fallback + zero-skip budget** - aggregate selftest started running the P12 AST rule twins through local `ast-grep` when installed or pinned `@ast-grep/cli@0.44.0` through `npx` when no local binary existed. `selftest-skip-budget.json` moved to `max_skipped=0` and an empty allowlist, with schema support for zero allowed skip reasons. At v9.45 the aggregate proof was **108 passed, 0 failed, 0 skipped**.

### v9.44 additions (this branch - SPEC tree, self-tested here)
- **canonical `.claude/hooks` resolver + `selftest.sh`** - aggregate selftest resolves the canonical runnable-kit runtime hooks when the spec tree has no local `.claude/hooks`, then proves kill-switch, gate-guard, ship-gate pass/veto paths, gate dispatch, edge/design/craft/resilience/story/tool-readiness smoke cases, and clean-state recovery in the throwaway project. The retired runtime-hook skip was removed from `selftest-skip-budget.json`, lowering the skip ceiling to **1**. At v9.44 the aggregate proof was **107 passed, 0 failed, 1 skipped**.

### v9.43 additions (this branch - SPEC tree, self-tested here)
- **canonical `walteur.js` resolver + `selftest.sh`** - aggregate selftest resolves the canonical runnable-kit orchestrator when the spec tree has no local `.claude/workflows/walteur.js`, then proves the autonomy default/approval guard, advisory blind-review wiring, and WAVE-LOGIC extraction against that real file. The retired canonical-orchestrator skips were removed from `selftest-skip-budget.json`, lowering the skip ceiling to **2**. At v9.43 the aggregate proof was **78 passed, 0 failed, 2 skipped**.

### v9.42 additions (this branch - SPEC tree, self-tested here)
- **`scaffold/harness-init.sh` + `selftest.sh`** - aggregate selftest proves generated project state defaults to `autonomy_policy="full_autopilot"` when this spec distribution does not include a live `walteur-kit/autopilot/STATE.json`. The retired state skip was removed from `selftest-skip-budget.json`, lowering the skip ceiling to **5**. At v9.42 the aggregate proof was **74 passed, 0 failed, 5 skipped**.

### v9.41 additions (this branch - SPEC tree, self-tested here)
- **`eval/fixtures/worktree-isolation-good/run.sh` + `eval/fixtures/worktree-isolation-poisoned/run.sh` + `selftest.sh`** - aggregate selftest proves git-worktree isolation with a clean two-agent merge and a poisoned same-file conflict. The retired worktree skip was removed from `selftest-skip-budget.json`, lowering the skip ceiling to **6**. At v9.41 the aggregate proof was **73 passed, 0 failed, 6 skipped**.

### v9.40 additions (this branch - SPEC tree, self-tested here)
- **`selftest.sh` poisoned skip-budget proof** - aggregate selftest feeds the skip-budget validator a synthetic unexpected skip reason and requires rejection. This proves the allowlist blocks drift, not only that the current seven skips pass. At v9.40 the aggregate proof was **71 passed, 0 failed, 7 skipped**.

### v9.39 additions (this branch - SPEC tree, self-tested here)
- **`selftest-skip-budget.json` + `schemas/selftest-skip-budget.schema.json` + `selftest.sh`** - aggregate selftest validates the live skip reasons against an explicit allowlist and maximum skip budget. New, renamed, or excess skip reasons fail closed before the final report is published. At v9.39 the aggregate proof was **70 passed, 0 failed, 7 skipped**.

### v9.38 additions (this branch - SPEC tree, self-tested here)
- **`schemas/selftest-report.schema.json` + `selftest.sh`** - aggregate selftest validates `walteur-kit/selftest-report.json` before publishing it. The schema covers the static report contract, and the shell/JQ self-check proves verdict, timestamp, summary, counts, and skip reasons match the actual aggregate counters. At v9.38 the aggregate proof was **69 passed, 0 failed, 7 skipped**.

### v9.37 additions (this branch - SPEC tree, self-tested here)
- **`selftest.sh` + `selftest-report.json`** - aggregate selftest writes a machine-readable report at `walteur-kit/selftest-report.json` with `schema_version`, `verdict`, `summary`, `counts`, and `skip_reasons`. At v9.37 the aggregate proof was **68 passed, 0 failed, 7 skipped**, with the remaining skips listed as explicit reasons in the report.

### v9.36 additions (this branch - SPEC tree, self-tested here)
- **`selftest.sh` aggregate skip cleanup** - legacy AI-safety and benchmark distribution-fixture assertions were removed because `ai-safety-gate.sh --selftest` and `benchmark-gate.sh --selftest` now own those twins locally. Aggregate proof remains **68 passed, 0 failed** while skips drop from **11** to **7**, making remaining skips represent actual absent optional surfaces rather than stale fixture packs.

### v9.35 additions (this branch - SPEC tree, self-tested here)
- **`hooks/ai-safety-gate.sh` + `selftest.sh` + `selftest-exceptions.json`** - `ai-safety-gate.sh` now honors `WALTEUR_ROOT` and exposes a hook-local `--selftest` (**15/15**) for invalid directory SKIP, non-AI NOT_APPLICABLE, missing injection corpus R2 VETO, valid corpus + capped loop + env-sourced model PASS, uncapped loop R1 VETO, hardcoded model R3 VETO, bypass SKIP report, and PAUSED behavior. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **0** entries. Aggregate selftest: **68 passed, 0 failed, 11 skipped**.

### v9.34 additions (this branch - SPEC tree, self-tested here)
- **`hooks/compliance-gate.sh` + `selftest.sh` + `selftest-exceptions.json`** - `compliance-gate.sh` now honors `WALTEUR_ROOT` and exposes a hook-local `--selftest` (**15/15**) for no-PII PASS, PII-without-inventory FAIL, valid pii inventory + redacted log PASS, missing lawful basis/retention FAIL, unredacted PII log FAIL, invalid inventory JSON FAIL, bypass SKIP report, and PAUSED behavior. The selftest isolates PATH so compliance proof never depends on installed policy tools. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **1** entry. Aggregate selftest: **67 passed, 0 failed, 11 skipped**.

### v9.33 additions (this branch - SPEC tree, self-tested here)
- **`hooks/spec-trace.sh` + `selftest.sh` + `selftest-exceptions.json`** - `spec-trace.sh` now honors `WALTEUR_ROOT` and exposes a hook-local `--selftest` (**17/17**) for missing PLAN SKIP, no trace signal NOT_APPLICABLE, valid PLAN/PRD trace PASS, untraced requirement T1 FAIL, untraced task T2 FAIL, unmitigated premortem T3 FAIL, untraced PRD story T4 FAIL, bypass SKIP report, and PAUSED behavior. REQ/STORY extraction now normalizes trailing punctuation so sentence-ending IDs do not false-fail. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **2** entries. Aggregate selftest: **66 passed, 0 failed, 11 skipped**.

### v9.32 additions (this branch - SPEC tree, self-tested here)
- **`hooks/security-gate.sh` + `selftest.sh` + `selftest-exceptions.json`** - `security-gate.sh` now honors `WALTEUR_ROOT` and exposes a hook-local `--selftest` (**9/9**) for no scanners SKIP, fake gitleaks clean PASS, fake gitleaks secret-leak FAIL, bypass SKIP report, and PAUSED behavior. The selftest isolates PATH so security proof never depends on installed local scanners. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **3** entries. Aggregate selftest: **65 passed, 0 failed, 11 skipped**.

### v9.31 additions (this branch - SPEC tree, self-tested here)
- **`hooks/restore-proof.sh` + `selftest.sh` + `selftest-exceptions.json`** - `restore-proof.sh` now honors `WALTEUR_ROOT` and exposes a hook-local `--selftest` (**11/11**) for no backup/DB context NOT_APPLICABLE, restore round-trip disabled SKIP, SQLite restore round-trip PASS, missing SQLite source FAIL, bypass SKIP report, and PAUSED behavior. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **4** entries. Aggregate selftest: **64 passed, 0 failed, 11 skipped**.

### v9.30 additions (this branch - SPEC tree, self-tested here)
- **`hooks/release-gate.sh` + `selftest.sh` + `selftest-exceptions.json`** - `release-gate.sh` now honors `WALTEUR_ROOT` and exposes a hook-local `--selftest` (**13/13**) for no deployable surface NOT_APPLICABLE, deployable surface without release-readiness FAIL, valid release readiness PASS, unsafe recreate strategy FAIL, fake grype high-vulnerability FAIL, bypass SKIP report, and PAUSED behavior. The selftest isolates PATH so heavy-tool proof never depends on installed local scanners. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **5** entries. Aggregate selftest: **63 passed, 0 failed, 11 skipped**.

### v9.29 additions (this branch - SPEC tree, self-tested here)
- **`hooks/iac-scan.sh` + `selftest.sh` + `selftest-exceptions.json`** - `iac-scan.sh` now honors `WALTEUR_ROOT` and exposes a hook-local `--selftest` (**11/11**) for no-IaC NOT_APPLICABLE, IaC with no scanners SKIP, fake tfsec clean PASS, fake tfsec finding FAIL, bypass SKIP report, and PAUSED behavior. The selftest isolates PATH so scanner proof never depends on installed local tools. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **6** entries. Aggregate selftest: **62 passed, 0 failed, 11 skipped**.

### v9.28 additions (this branch - SPEC tree, self-tested here)
- **`hooks/contract-gate.sh` + `selftest.sh` + `selftest-exceptions.json`** - `contract-gate.sh` now honors `WALTEUR_ROOT` and exposes a hook-local `--selftest` (**11/11**) for no-API NOT_APPLICABLE, declared API without spec FAIL, machine-readable GraphQL spec PASS, fake spectral error FAIL, bypass SKIP report, and PAUSED behavior. Structured report details now use the same safe writer pattern as the other retired hooks. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **7** entries. Aggregate selftest: **61 passed, 0 failed, 11 skipped**.

### v9.27 additions (this branch - SPEC tree, self-tested here)
- **`hooks/tool-contract-lint.sh` + `selftest.sh` + `selftest-exceptions.json`** - `tool-contract-lint.sh` now honors `WALTEUR_ROOT` and exposes a hook-local `--selftest` (**13/13**) for non-AI NOT_APPLICABLE, AI signal with missing contracts FAIL, valid contract PASS, dangerous external-money tool without oversight FAIL, free-form input FAIL, bypass SKIP report, and PAUSED behavior. The report writer now uses the same structured-detail-safe path as `cost-budget.sh`, and neutral temp roots keep applicability fixtures honest. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **8** entries. Aggregate selftest: **60 passed, 0 failed, 11 skipped**.

### v9.26 additions (this branch - SPEC tree, self-tested here)
- **`hooks/cost-budget.sh` + `selftest.sh` + `selftest-exceptions.json`** - `cost-budget.sh` now honors `WALTEUR_ROOT` and exposes a hook-local `--selftest` (**13/13**) for no-cost-context NOT_APPLICABLE, missing budget FAIL, valid budget PASS, invalid budget shape FAIL, codeburn over-cap FAIL, bypass SKIP report, and PAUSED behavior. The report writer now avoids Bash default-value brace corruption and preserves structured details. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **9** entries. Aggregate selftest: **59 passed, 0 failed, 11 skipped**.

### v9.25 additions (this branch - SPEC tree, self-tested here)
- **`hooks/design-gate.sh` + `selftest.sh` + `selftest-exceptions.json`** - `design-gate.sh` now evaluates the requested project root and exposes a hook-local `--selftest` (**11/11**) for non-UI skip, valid design contract, missing design contract, stub design contract, bypass, and PAUSED behavior. Aggregate selftest runs it directly, while retaining ship-gate dispatch smoke coverage, and the no-selftest exception manifest drops to **10** entries. Aggregate selftest: **58 passed, 0 failed, 11 skipped**.

### v9.24 additions (this branch - SPEC tree, self-tested here)
- **`hooks/benchmark-gate.sh` + `selftest.sh` + `selftest-exceptions.json`** - `benchmark-gate.sh` now exposes a hook-local `--selftest` (**11/11**) for CLI-only skip, valid product benchmark, touch-stub benchmark, zero table-stakes benchmark, bypass, and PAUSED behavior. Aggregate selftest runs it directly, while retaining the broader smoke cases, and the no-selftest exception manifest drops to **11** entries. Aggregate selftest: **57 passed, 0 failed, 11 skipped**.

### v9.23 additions (this branch - SPEC tree, self-tested here)
- **`hooks/docrun.sh` + `selftest.sh` + `selftest-exceptions.json`** - `docrun.sh` now exposes a hook-local `--selftest` (**9/9**) for no-markdown projects, passing shell blocks, skipped bad blocks, failing shell blocks, bypass, and PAUSED behavior. The previous-line `<!-- walteur:skip -->` marker now persists to the following fence. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **12** entries. Aggregate selftest: **56 passed, 0 failed, 11 skipped**.

### v9.22 additions (this branch - SPEC tree, self-tested here)
- **`hooks/schema-lint.sh` + `selftest.sh` + `selftest-exceptions.json`** - `schema-lint.sh` now exposes a hook-local `--selftest` (**9/9**) for not-applicable projects, valid SQL schema, bad SQL schema, bypass, and PAUSED behavior. Bypass now writes a SKIP report. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **13** entries. Aggregate selftest: **55 passed, 0 failed, 11 skipped**.

### v9.21 additions (this branch - SPEC tree, self-tested here)
- **`hooks/tool-readiness.sh` + `selftest.sh` + `selftest-exceptions.json`** - `tool-readiness.sh` now exposes a hook-local `--selftest` (**9/9**) for absent manifest, required-present tools, optional tools, missing required tools, bypass, and PAUSED behavior. Aggregate selftest runs it directly, and the no-selftest exception manifest drops to **14** entries. Aggregate selftest: **54 passed, 0 failed, 11 skipped**.

### v9.20 additions (this branch - SPEC tree, self-tested here)
- **`selftest-exceptions.json` + `schemas/selftest-exceptions.schema.json` + `selftest.sh`** - selected spec hooks without `--selftest` now need typed exception records with rationale, replacement proof, and next action. Aggregate selftest fails missing, malformed, duplicate, stale, non-selected, missing-file, or now-selftesting exceptions. Aggregate selftest: **53 passed, 0 failed, 11 skipped**.

### v9.19 additions (this branch - SPEC tree, self-tested here)
- **`selftest.sh` + `gate-registry.json`** - aggregate selftest now audits selected spec hooks from the registry. Any selected hook with `--selftest` support must be run by the aggregate suite; selected hooks without selftests must be listed as explicit exceptions. Registry parse errors and empty selector output fail. Aggregate selftest: **53 passed, 0 failed, 11 skipped**.

### v9.18 additions (this branch - SPEC tree, self-tested here)
- **`hooks/build-contract-lint.sh` + `scaffold/harness-init.sh`** - generated verification commands now derive from `gate-registry.json` and cover every selected spec-shipped hook. `build-contract-lint.sh` fails selected runnable gates missing from `verification.commands`, and selected canonical gates must be named in `manual_checks` with their hook and evidence instruction. Self-tests: `build-contract-lint.sh` **7/7**, `harness-init.sh` **76/76**.

### v9.17 additions (this branch - SPEC tree, self-tested here)
- **`scaffold/required-skills.template.json` + `hooks/skill-readiness.sh` + `scaffold/harness-init.sh`** - fresh scaffolds now write an explicit empty `required-skills.json`, and `skill-readiness-report.json` must PASS instead of SKIP. Malformed required-skills manifests fail closed. Self-tests: `skill-readiness.sh` **9/9**, current `harness-init.sh` **76/76**.

### v9.16 additions (this branch - SPEC tree, self-tested here)
- **`hooks/evidence-gate.sh` + `schemas/harness-state.schema.json` + `hooks/harness-state-lint.sh`** - runtime PASS evidence hardening. Summary-only PASS evidence now fails; report/audit/screenshot/source proof needs a path, command proof needs command + output path + timestamp, and review/decision/manual-check proof needs either a path or owner + timestamp + summary. Self-tests: `evidence-gate.sh` **12/12**, `harness-state-lint.sh` **19/19**.

### v9.15 additions (this branch - SPEC tree, self-tested here)
- **`hooks/definition-of-done-gate.sh`** - ship-stage DoD proof-ref enforcement. It reports `definition-of-done-report.json`, self-tests **12/12**, and fails ship/reflect if a checked item cites loose fake evidence text, a missing/empty/outside-root local file, or an unsafe path. Accepted proof refs are typed (`command:`, `report:`, `screenshot:`, `review:`, `signed-decision:`, `url:`, `log:`) or existing non-empty project files.

### v9.14 additions (this branch - SPEC tree, self-tested here)
- **`hooks/definition-of-done-gate.sh`** - ship-stage DoD enforcement. It reports `definition-of-done-report.json`, and fails ship/reflect if the DoD file is missing, has unchecked items, checked items without `Evidence:`, weak `N/A` reasons, placeholders, or stale timestamps. v9.15 tightens checked `Evidence:` into validated proof refs.
- **`gate-registry.json` + `scaffold/harness-init.sh`** - baseline now selects `definition-of-done-gate`; harness-init copies `DEFINITION-OF-DONE.md`, writes `definition-of-done-report.json`, and current self-test is **79/79**. Gate count is **76** in this spec tree after v9.78.

### v9.13 additions (this branch - SPEC tree, self-tested here)
- **`hooks/trace-mine.sh`** - now writes a structured `walteur-kit/trace-mine-report.json` for PASS/SKIP/BLOCKED paths and self-tests the report evidence, proposal-only behavior, no-parallel-memory-store rule, paused/off/no-artifact paths, recurring stall mining, v9.63 redundant signature mining, and v9.71 normalized command-signature mining. Self-test: `bash walteur-kit/hooks/trace-mine.sh --selftest` (**39/39**).
- **`gate-registry.json` + `scaffold/harness-init.sh`** - baseline now selects `trace-mine`; after v9.77, harness-init self-test is **76/76**. Gate count is **69** in this spec tree.

### v9.12 additions (this branch - SPEC tree, self-tested here)
- **`hooks/loop-workspace-gate.sh`** - baseline gate for the loop workspace substrate. It fails initialized WALTEUR projects missing `LOG.md`, `signals/README.md`, `docs/README.md`, `domains/README.md`, or their required schema anchors. Self-test: `bash walteur-kit/hooks/loop-workspace-gate.sh --selftest` (**6/6**).
- **`gate-registry.json` + `scaffold/harness-init.sh`** - baseline selects `loop-workspace-gate`; after v9.78, current harness-init self-test is **79/79** and gate count is **76** in this spec tree.

### v9.10 additions (this branch - SPEC tree, self-tested here)
- **`self-heal.sh` + `schemas/source-manifest.schema.json` + `source-manifest.json`** - strict upstream source manifest with 45 of Tony's curated GitHub repos, canonical redirected URLs, pinned branch heads, routing categories, use triggers, adoption modes, promotion policy, and risk policy. Latest batch: Ruflo agent meta-harness patterns, TDD, browser proof, repo packing, parallel agents, memory, specialist panels, marketing, image/video, knowledge compilation, .NET display text, loop-workspace substrate, and anti-bot boundary routing. Self-test: `bash walteur-kit/self-heal.sh --selftest` (**12/12**).
- **`SOURCE-ROUTER.md` + `HARNESS-LOOP.md` + `DEFINITION-OF-DONE.md`** - prompt refinement and PLAN must now select relevant manifest sources and write `SOURCE-USE` receipts before those sources shape architecture, stack, skills, tools, or subagents.
- **`scaffold/harness-init.sh`** - fresh projects now receive `self-heal.sh`, `source-manifest.json`, `SOURCE-ROUTER.md`, `DEFINITION-OF-DONE.md`, `required-skills.json`, `LOG.md`, `signals/README.md`, `docs/README.md`, and `domains/README.md`; after v9.77, harness-init self-test is **76/76**.

### v9.9 additions (this branch - SPEC tree, self-tested here)
- **`schemas/project-context.schema.json` + `hooks/project-context-gate.sh`** - PLAN and later phases now require `walteur-kit/project-context.json`: project-specific AGENTS/CLAUDE/rules context, size budgets, source refs, baton, and subagent handoff artifact/validation refs. Self-test: `bash walteur-kit/hooks/project-context-gate.sh --selftest` (**9/9**).
- **`schemas/self-improvement.schema.json` + `hooks/self-improvement-gate.sh`** - memory capture now requires `result_ref` evidence and `captured:true`; lessons are capped at 25 words. Self-test: `bash walteur-kit/hooks/self-improvement-gate.sh --selftest` (**14/14**).
- **`gate-registry.json` + `scaffold/harness-init.sh`** - baseline selects `project-context-gate`; after v9.78, current harness-init self-test is **79/79**. Gate count is **76** in this spec tree.

### v9.8 additions (this branch - SPEC tree, self-tested here)
- **`schemas/current-stack.schema.json` + `hooks/current-stack-gate.sh`** - PLAN and later phases now require `walteur-kit/current-stack.json`: today's run date, build class, domain, selected stack items, current official/source refs, stale-training checks, evidence refs that exist, and acknowledgement when `stack-fingerprint-report.json` reports DRIFT. Self-test: `bash walteur-kit/hooks/current-stack-gate.sh --selftest` (**8/8**).
- **`gate-registry.json` + `scaffold/harness-init.sh`** - baseline selects `current-stack-gate`; after v9.78, current harness-init self-test is **79/79**. Gate count is **76** in this spec tree.

### v9.7 additions (SPEC tree, self-tested here)
- **`schemas/harness-state.schema.json` + `hooks/harness-state-lint.sh`** - runtime state now requires `recovery_policy` with `posture="i_will_figure_it_out"`, exactly three recovery paths, six decision dimensions, validation, log path, and escalation rule. It also requires `context_sentinel` with `user_name="Tony"`, `response_prefix="Tony,"`, every-response enforcement, and `compact_and_resume` into `_relay/BATON.md` when the prefix disappears. When `stages[]` are `blocked`, `gates[]` are `BLOCKED`, or `blockers[]` is non-empty, each entry must carry `recovery_decision_id`; the referenced `walteur-kit/figure-it-out.jsonl` record must include one obstacle, exactly three complete paths, chosen path, reasoning, validation test, escalation trigger, and timestamp. After v9.16, self-test: `bash walteur-kit/hooks/harness-state-lint.sh --selftest` (**19/19**).
- **`scaffold/harness-init.sh`** - generated states include the recovery/context contract by default; after v9.78, current harness-init self-test is **79/79**.

### v9.5 additions (SPEC tree, self-tested here)
- **`schemas/prompt-refinement.schema.json` + `hooks/prompt-refinement-gate.sh`** - "Improve this prompt" contract: raw ask, improved prompt, outcome, scope, acceptance criteria, routing, specialist plan, verification plan, quality stop conditions. Self-test: `bash walteur-kit/hooks/prompt-refinement-gate.sh --selftest` (**11/11**).
- **`schemas/delivery-orchestration.schema.json` + `hooks/delivery-orchestration-gate.sh`** - industrial delivery contract: agent roster, SDLC stage gates, role independence, frontend/backend coverage, handoffs, worktree boundaries, audit trail. Self-test: `bash walteur-kit/hooks/delivery-orchestration-gate.sh --selftest` (**13/13**).
- **`LOOP-SCOUT-2026-06-22.md`** - source-backed scout note for current loop/harness patterns and the adoption decision.
- **`gate-registry.json` + `scaffold/harness-init.sh`** - baseline selects the prompt, delivery, AI-tool-governance, AuthZ-tenant, privacy-data, and SDLC-run gates; after v9.78, current harness-init self-test is **79/79**.

### v9.4 additions (SPEC tree, self-tested here)
- **`schemas/self-improvement.schema.json` + `hooks/self-improvement-gate.sh`** - compounding quality contract: trace mining, current GitHub/source scout, candidate review, bounded proposals, regression proof, rollback proof, evidence-backed memory capture. Self-test: `bash walteur-kit/hooks/self-improvement-gate.sh --selftest` (**14/14**).
- **`schemas/outcome-eval.schema.json` + `hooks/outcome-eval-gate.sh`** - independent outcome evaluation contract: evaluator independence, weighted rubric, evidence refs, confidence, bias checks, no blockers, freshness. Self-test: `bash walteur-kit/hooks/outcome-eval-gate.sh --selftest` (**13/13**).
- **`gate-registry.json` + `scaffold/harness-init.sh`** - baseline selects the self-improvement and outcome gates; after v9.78, current harness-init self-test is **79/79**.

### v9.2 additions (SPEC tree, self-tested here)
- **`PRODUCT-STANDARD.md` + `schemas/product-standard.schema.json`** - product/company completeness contract for serious product builds.
- **`hooks/product-standard-gate.sh`** - detect-or-skip gate for product/company completeness; self-test: `bash walteur-kit/hooks/product-standard-gate.sh --selftest` (**7/7**).
- **`scaffold/layers.template.json` + `schemas/production-layers.schema.json`** - typed 13-layer production reality contract.
- **`hooks/production-layers-gate.sh`** - detect-or-skip gate for layer ownership, evidence refs, and signed deferrals; self-test: `bash walteur-kit/hooks/production-layers-gate.sh --selftest` (**8/8**).
- **`hooks/adr-gate.sh` + `schemas/adr.schema.json`** - typed ADR/fork control; self-test: `bash walteur-kit/hooks/adr-gate.sh --selftest` (**10/10**).
- **`hooks/qa-contract-gate.sh` + `schemas/qa-report.schema.json`** - typed QA proof contract; self-test: `bash walteur-kit/hooks/qa-contract-gate.sh --selftest` (**11/11**).
- **`hooks/scoreboard-gate.sh` + `schemas/scoreboard.schema.json`** - typed eight-dimension score contract; self-test: `bash walteur-kit/hooks/scoreboard-gate.sh --selftest` (**10/10**).
- **`hooks/definition-of-done-gate.sh` + `DEFINITION-OF-DONE.md`** - typed DoD closure contract; self-test: `bash walteur-kit/hooks/definition-of-done-gate.sh --selftest` (**12/12**).
- **`hooks/audit-contract-gate.sh` + `schemas/audit.schema.json`** - terminal audit contract; self-test: `bash walteur-kit/hooks/audit-contract-gate.sh --selftest` (**10/10**).
- **`gate-registry.json`** - now selects `benchmark-gate`, `product-standard-gate`, `production-layers-gate`, `adr-gate`, `prompt-refinement-gate`, `delivery-orchestration-gate`, `project-context-gate`, `self-improvement-gate`, `outcome-eval-gate`, `qa-contract-gate`, `scoreboard-gate`, `definition-of-done-gate`, and `audit-contract-gate` so fresh contracts cannot silently skip product, production, prompt, delivery team, project context, decision, self-improvement, outcome evaluation, QA, score, DoD closure, or terminal-audit proof.

### v9.1 additions (SPEC tree, self-tested here)
- **`hooks/_ast-grep-preamble.sh` + `sgconfig.yml` + `ast-grep-rules/` + `ast-grep-tests/` + `tool-acquisition.json`** — the **P12** opt-in AST backend for `resilience-lint.sh` + `anti-slop-ui.sh` (ADDITIVE — AST-fail ⇒ exit 2; absent ⇒ grep floor). Rule twins are aggregate-proven through the validated lockfile-backed acquisition contract. Self-test: `ast-grep test -c walteur-kit/sgconfig.yml` (**9/9**). `required-tools.json` registers ast-grep `required:false`.
- **`hooks/intent-trace.sh`** — the §5.5 deterministic intended-vs-implemented arm: proves a PRD `ast_proof` construct EXISTS at file:line (HARD), never correctness. Self-test: `bash walteur-kit/hooks/intent-trace.sh --selftest` (**3/3**). `schemas/prd.schema.json` gains the back-compat `ast_proof` shape.
- **`hooks/osv-gate.sh`** — the **P13** supply-chain gate: fail-closed on a MAL-* OSV.dev advisory; offline ⇒ recorded SKIP. Self-test (offline, hermetic): `bash walteur-kit/hooks/osv-gate.sh --selftest` (**7/7**).
- **`schemas/recipe.schema.json` + `recipes/`** — the recipe contract (parameterized runnable workflow artifact; goose pattern, NO runtime).
- **`schemas/build-contract.schema.json`** - the typed `build-contract.json` contract for intake, scope, risk, verification, and evidence.
- **`scaffold/harness-init.sh`** - deterministic harness bootstrap for fresh projects; self-test: `bash walteur-kit/scaffold/harness-init.sh --selftest`.
- **`hooks/build-contract-lint.sh`** - detect-or-skip HARD gate for `walteur-kit/build-contract.json`; selected runnable gates must appear in `verification.commands`, and selected canonical gates must appear in `manual_checks`; self-test: `bash walteur-kit/hooks/build-contract-lint.sh --selftest` (**7/7**).
- **`schemas/gate-registry.schema.json`** - the typed class/risk gate matrix contract.
- **`hooks/gate-registry-lint.sh`** - detect-or-skip HARD gate for `walteur-kit/gate-registry.json` and required gates in `build-contract.json`; self-test: `bash walteur-kit/hooks/gate-registry-lint.sh --selftest`.
- **`schemas/estimate.schema.json`** - the typed `estimate.json` contract for upfront time, token, and cost estimates.
- **`hooks/estimate-gate.sh`** - HARD gate for `walteur-kit/estimate.json` and `STATE.budgets` reconciliation; self-test: `bash walteur-kit/hooks/estimate-gate.sh --selftest`.
- **`schemas/harness-state.schema.json`** - the typed `STATE.json` contract for phase, gate, evidence, budget, recovery posture, context sentinel, handoff, and known-gap tracking.
- **`hooks/harness-state-lint.sh`** - detect-or-skip HARD gate for `walteur-kit/autopilot/STATE.json`; self-test: `bash walteur-kit/hooks/harness-state-lint.sh --selftest` (**19/19**).
- **`hooks/phase-gate.sh`** - HARD gate that blocks phase jumps until prior stages have evidence or real skip reasons; self-test: `bash walteur-kit/hooks/phase-gate.sh --selftest`.
- **`hooks/evidence-gate.sh`** - HARD gate that proves cited evidence exists, is replayable or signed, and supports PASS claims; self-test: `bash walteur-kit/hooks/evidence-gate.sh --selftest` (**12/12**).
- **`hooks/risk-acceptance-gate.sh`** - HARD gate that proves high-risk ship and accepted-risk claims have approved owner signoff; self-test: `bash walteur-kit/hooks/risk-acceptance-gate.sh --selftest`.
- **`hooks/skill-readiness.sh`** - HARD gate that proves declared required skills left machine-readable breadcrumbs; fresh scaffolds start from explicit empty `required-skills.json`; self-test: `bash walteur-kit/hooks/skill-readiness.sh --selftest` (**9/9**).
- **`hooks/devenv-gate.sh`** - detect-or-skip gate for reproducible developer environment discipline; self-test: `bash walteur-kit/hooks/devenv-gate.sh --selftest`.
- **`hooks/config-validation.sh`** - detect-or-skip gate for validated config access and committed env secret hygiene; self-test: `bash walteur-kit/hooks/config-validation.sh --selftest`.
- **`hooks/quickstart-check.sh`** - detect-or-skip gate for README quickstart/onboarding shape and clean-container readiness where Docker is available; self-test: `bash walteur-kit/hooks/quickstart-check.sh --selftest`.
- **`hooks/nfr-lint.sh`** - detect-or-skip gate for quantified non-functional requirements; self-test: `bash walteur-kit/hooks/nfr-lint.sh --selftest`.
- **`hooks/observe-lint.sh`** - detect-or-skip gate for logging, metrics, tracing, and PII-in-log anti-patterns; self-test: `bash walteur-kit/hooks/observe-lint.sh --selftest`.
- **`hooks/perf-gate.sh`** - detect-or-skip gate for tail-latency budgets and perf regression context; self-test: `bash walteur-kit/hooks/perf-gate.sh --selftest`.
- **`eval/ab-bench.sh` + `eval/prove-pillar.md`** — the A/B "prove-the-pillar-pays" benchmark harness (`--selftest` **10/10**).
- **`skills/build-with-agent-team/` · `rules/memory-discipline.md` · `rules/karpathy-discipline.md` · `extensions/`** — contract-first agent-team skill, memory-discipline + karpathy-discipline rules (LLM-coding-pitfall delta, promoted from andrej-karpathy-skills per its promotion_policy), graphify-extension patterns. (Install `skills/` and `rules/` under `.claude/` on adoption.)
- **`canonical-kit-staging/`** - reference copies for v9.1 items already applied to the canonical runnable kit plus still-staged spec-trace and harness-contract adoption patches; see its README. **`UPGRADE-v9.1.md`** is the full upgrade spec.
- **HONESTY (§1):** every v9.1 hook self-tests green HERE; wiring them into `ship-gate.sh` dispatch + re-counting the aggregate selftest happen in the canonical runnable kit. AST proves EXISTENCE, never correctness.

## Report JSONs — read honestly
| File | Status |
|---|---|
| `self-heal-report.json` | Generated by `self-heal.sh`; records PASS/WARN/SKIP/FAIL for pinned upstream source refs and is the evidence input for the source router. |
| `benchmark-gate-report.json`, `ai-safety-report.json`, `product-standard-report.json` | Generated by hooks in this tree when you run them; absent or stale reports are not proof of a current pass. |
| `debate/OPEN.json`, `adr/INDEX.json`, `adr-report.json` | `OPEN.json` is the fork backstop: `[]` means no unresolved forks. If ADR Markdown exists, `adr/INDEX.json` must match `schemas/adr.schema.json` and `adr-gate.sh` must pass. |
| `prompt-refinement.json`, `delivery-orchestration.json`, `project-context.json`, `self-improvement.json`, `outcome-eval.json`, `audit.json`, `qa-report.json`, `scoreboard.json`, `DEFINITION-OF-DONE.md` | **Runtime stubs/templates** — populated by the orchestrator/gates at build time. At plan and later, `prompt-refinement-gate.sh` requires `prompt-refinement.json` to match `schemas/prompt-refinement.schema.json`; `delivery-orchestration-gate.sh` requires `delivery-orchestration.json` to match `schemas/delivery-orchestration.schema.json`; `project-context-gate.sh` requires `project-context.json` to match `schemas/project-context.schema.json`; `self-improvement-gate.sh` requires `self-improvement.json` to match `schemas/self-improvement.schema.json`; at review and later, `outcome-eval-gate.sh` requires `outcome-eval.json` to match `schemas/outcome-eval.schema.json`; at verify, `qa-contract-gate.sh` requires `qa-report.json` to match `schemas/qa-report.schema.json`; at ship, `scoreboard-gate.sh` requires `scoreboard.json` to match `schemas/scoreboard.schema.json`, `definition-of-done-gate.sh` requires every DoD item closed with validated proof refs or reasoned N/A, and `audit-contract-gate.sh` requires `audit.json` to match `schemas/audit.schema.json`. |
| `trace-mine-report.json` | Generated by `trace-mine.sh`; records PASS/SKIP/BLOCKED, artifact availability, recurrence threshold, systemic count, lesson proposal count, and whether a proposal block was appended. |
| `definition-of-done-report.json` | Generated by `definition-of-done-gate.sh`; records PASS/SKIP/NOT_APPLICABLE/FAIL, DoD item counts, reason, and findings for unchecked, stale, placeholder, missing/weak evidence, invalid proof refs, missing local evidence files, or weak-N/A items. |
| `prd-gate-report.json`, `spec-lint-report.json`, `spec-trace-report.json` | Generated by hooks that are present here when you run them; read timestamps before using them as evidence. |
