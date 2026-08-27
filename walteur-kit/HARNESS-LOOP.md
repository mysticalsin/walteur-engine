# WALTEUR Harness Loop

> Canonical structure for enterprise-grade builds, workflows, documents, data/AI systems, cloud/IaC, and mixed work.

This is the portable loop. It keeps WALTEUR from becoming a software-only ritual or a loose prompt style. Every run is a typed state machine with evidence gates.

## Prime Rule

```
Intake -> classify -> plan -> build -> verify -> review -> ship -> reflect
          ^                                  |
          |----------------------------------|
```

The loop only advances when the current gate has evidence. A red gate routes back to the smallest earlier phase that can fix the cause. Budget exhaustion or missing authority stops the run honestly, with options. The bar never drops just to exit the loop.

## Build Classes

Every request gets one primary class. Mixed work can name multiple classes, but one class owns the ship gate.

| Class | Typical output | Extra proof required |
|---|---|---|
| `software` | code, app, API, CLI, package | tests, lint/typecheck, security checks, rollback path |
| `workflow` | SOP, automation, operating cadence, handoff | dry-run, owner/RACI, exception path, recovery path |
| `document` | memo, deck, PRD, proposal, policy | source audit, humanizer/best pass, confidentiality check if external |
| `data-ai` | model workflow, eval, RAG, agent, dataset | eval set, failure taxonomy, cost budget, drift/safety checks |
| `cloud-iac` | infra, deployment, migration, CI/CD | plan output, policy scan, rollback/restore proof, environment parity |
| `mixed` | any combination above | all proof from the highest-risk included class |

## Phase Contract

| Phase | Question | Required artifact | Gate |
|---|---|---|---|
| Intake | What is the outcome and who owns it? | `goal`, scope, risk tier, autonomy policy | Outcome, owner, and stop conditions are explicit |
| Discover | Is this worth building? | `PRD.md` or existing intent source | Problem, metric, assumptions, and cheapest validation are recorded |
| Plan | How will this be built safely and improve over time? | `PLAN.md`, estimate, `current-stack.json`, protected paths, `prompt-refinement.json`, `enterprise-blueprint.json`, source-use receipts, `delivery-orchestration.json`, `project-context.json`, `self-improvement.json` | Raw ask is improved into a build brief and concrete enterprise blueprint; current stack assumptions and relevant upstream sources are selected; tasks trace to acceptance criteria and evidence commands; agent team, project context, SDLC, and improvement loop are recorded |
| Build | What changed? | diff, implementation notes, receipts | Minimal scope, no placeholders, test-first evidence |
| Verify | Does it work? | reports, logs, screenshots, evals | Checks ran fresh, output read, failures fixed |
| Review | Should it ship? | review notes, ADRs, outcome eval, audit findings | Independent pass, outcome rubric passes, vetoes closed, risks accepted |
| Ship | How does the user receive it? | release/handoff, docs, rollback | Artifact delivered, recovery path known, sign-off logged if needed |
| Reflect | What did the loop learn? | BATON, lessons, known gaps | Next agent can resume without rediscovery |

## Gate Semantics

- `PASS`: evidence exists, was read, and satisfies the gate.
- `FAIL`: evidence proves the gate is red. Route back to the smallest phase that can fix it.
- `SKIP`: gate does not apply. Must include why.
- `BLOCKED`: missing authority or input. Run Figure-It-Out first, then stop only with options.
- `ACCEPTED_RISK`: risk remains, owner signed it, and rollback/monitoring is clear.

No gate may silently green itself. Missing proof is `NOT_FOUND`, not proof of absence.

A gate marked `hard` in the build contract or registry cannot remain `SKIP` once its phase is due. Use `ACCEPTED_RISK` with owner signoff for a real residual risk, or route back and make the gate pass. `SKIP` is for `detect_or_skip`, manual, or protocol checks that truly do not apply.

## Build Contract

Before runtime state exists, capture the requested build in `walteur-kit/build-contract.json`, shaped by `walteur-kit/schemas/build-contract.schema.json`.

Minimum contract:

- request: summary, user outcome, primary user, and non-goals
- classification: `build_class`, `risk_tier`, `data_classification`
- proof: success metrics, interfaces, verification gates, and required evidence
- safety: constraints, unknowns, owners, and accepted risks

The build contract answers "what are we promising to deliver?" The state file answers "where is the run now?" Keep both small, typed, and evidence-oriented.

## Estimate Contract

Every non-trivial run also carries `walteur-kit/estimate.json`, shaped by `walteur-kit/schemas/estimate.schema.json`.

Minimum estimate:

- identity: `estimate_id`, `goal`, `phase`, `created_at`
- time: best, expected, and worst minutes
- tokens: best, expected, and worst tokens, with optional input/output split
- cost: best, expected, and worst USD
- assumptions: explicit reasons behind the estimate

`estimate-gate.sh` validates the estimate and reconciles it with `STATE.budgets`. Intake scaffolds may start with zero values, but once the run moves beyond intake, expected minutes and tokens must be positive. This prevents plan/build work from starting on a hidden or placeholder budget.

## Current Stack Contract

At plan and later phases, `walteur-kit/current-stack.json` records the run-date stack proof, shaped by `walteur-kit/schemas/current-stack.schema.json`.

Minimum current-stack proof:

- date: `run_date` equals the current UTC date
- classification: `build_class` and domain
- stack: selected runtimes, frameworks, libraries, tools, standards, or explicit non-applicable items
- sources: current official docs, source repos, release notes, standards, or equivalent source material
- stale-training checks: claims that could have rotted since model training, checked against cited sources
- evidence: every source capture and check points to a file that exists
- drift: if `stack-fingerprint-report.json` says `DRIFT`, the proof acknowledges that exact drift timestamp

`current-stack-gate.sh` rejects missing plan-time proof, stale dates, missing official/source evidence, unknown source IDs, placeholder text, missing evidence files, build-class mismatch, and unacknowledged stack-fingerprint drift. This makes the first promise in the loop mechanical: no PLAN from frozen stack memory.

Bootstrap a fresh project with:

```bash
bash walteur-kit/scaffold/harness-init.sh --goal "Build the requested outcome" --class software --risk medium
```

The scaffold writes the registry, build contract, estimate, initial `autopilot/STATE.json`, `debate/OPEN.json`, `DEFINITION-OF-DONE.md`, `required-skills.json`, and the loop workspace substrate (`LOG.md`, `signals/README.md`, `docs/README.md`, `domains/README.md`). It runs only the bootstrap-safe reconciliation subset at intake, while `build-contract.json.verification.commands` is generated from `gate-registry.json` and covers every selected spec-shipped gate hook for the later full verification path. Canonical-only gates are named in `manual_checks` with their hook and evidence instruction. `skill-readiness.sh` starts from an explicit empty manifest so selected fresh scaffolds PASS instead of silently SKIP. This makes a new run checkable before any build work starts without pretending PLAN/VERIFY/SHIP artifacts already exist.

## Enterprise Blueprint Contract

At plan and later phases, `walteur-kit/enterprise-blueprint.json` records the concrete target that the build must satisfy. It is shaped by `walteur-kit/schemas/enterprise-blueprint.schema.json`.

Minimum enterprise blueprint:

- goal: raw user goal plus upgraded enterprise goal that is not a restatement
- user: primary user, pain, success moment, owner or buyer, and decision metric
- work: job map, artifact map, and surface map across UI, API, data, jobs, docs, and ops
- acceptance: at least three `AC-001` style criteria with verification and evidence refs
- trust: auth, authorization, data policy, privacy, security, and auditability
- operations: observability, support, rollback, incident response, and ownership
- quality: what it must feel like, what it must not feel like, reference quality, and concreteness floor
- cuts: explicit out-of-scope items with reason, risk, and review trigger
- handoff: final delivery packet sections, including proof read, known gaps, recovery, and next action

`enterprise-blueprint-gate.sh` rejects missing blueprints, malformed JSON, placeholders, restated goals, thin quality language, missing artifacts, missing acceptance criteria, missing trust or ops models, missing cuts, missing final packet sections, and missing local evidence refs. This makes "build the best version of X" a checkable build target before implementation starts.

## Upstream Source Router Contract

At prompt refinement and plan, `walteur-kit/source-manifest.json` and
`walteur-kit/SOURCE-ROUTER.md` turn live upstream repos into a typed selection
system.

Minimum source-router proof:

- self-heal: `self-heal-report.json` exists or a skip reason is recorded
- classification: request signals are mapped to manifest `use_when[]` entries
- selection: chosen source IDs, pinned refs, and why each source applies
- extraction: the concrete pattern borrowed from each source
- rejection: the parts not adopted and why
- promotion: install, import, copy, or fork only after license, maintenance,
  security, fit, regression, and rollback proof
- receipt: a `SOURCE-USE` record is written before the source influences design

The curated source graph includes 45 user-requested repos for product
management, agent methodology, role plugins, source research, code graphs, repo
packing, TDD enforcement, browser verification, context compression, memory
hygiene, specialist panels, UI/UX, design systems, Apple apps, defensive
security, media production, marketing/growth, image generation, motion/video,
knowledge compilation, loop-workspace substrate, .NET display text, token
economy, and cross-harness operations. The manifest pins the verified branch head for each repo, and
`self-heal.sh` reports drift without auto-applying changes. Boundary sources
such as anti-bot bypass tools may inform refusal or authorization checks only.

This makes "use the best available material" a checkable planning act instead of
a vibe. Popularity can suggest what to inspect, but only evidence can promote a
tool or pattern into the build.

## Prompt Refinement Contract

At plan and later phases, `walteur-kit/prompt-refinement.json` records the mandatory "Improve this prompt" pass. It is shaped by `walteur-kit/schemas/prompt-refinement.schema.json`.

Minimum prompt refinement:

- source: the raw user request is preserved verbatim enough to audit drift
- improved prompt: the build prompt names outcome, scope, acceptance, verification, security, frontend/backend when applicable, QA, and stop conditions
- build brief: outcome, primary user, success metrics, non-goals, constraints, and at least three acceptance criteria
- routing: build class, risk tier, data classification, UI/backend/external-action booleans
- source router: selected upstream source IDs or explicit non-applicable reasons
- specialists: the roles needed and the output each role must produce
- verification: gate-by-gate evidence plan, including delivery orchestration, QA, and outcome evaluation
- quality bar: must-haves and stop conditions

`prompt-refinement-gate.sh` rejects missing plan-time reports, thin improved prompts, too few acceptance criteria, routing that contradicts the build contract, weak specialist or verification plans, missing source refs, stale reports, and placeholder text. The gate makes the harness self-prompt before it plans: it turns "build X" into the sharper brief the rest of the loop obeys.

## Delivery Orchestration Contract

At plan and later phases, `walteur-kit/delivery-orchestration.json` records how the build will be staffed and moved through the SDLC. It is shaped by `walteur-kit/schemas/delivery-orchestration.schema.json`.

Minimum delivery orchestration:

- roster: orchestrator, builders, independent reviewers, independent evaluator, and required specialists
- decomposition: tasks with owners, workstreams, touch refs, dependencies, and verification refs
- stage gates: local build, shared dev, staging, beta, production, and reflect for code-producing work
- coverage: frontend, backend, API, data, security, QA, DevOps, UX, observability, docs, release, and rollback
- handoffs: every specialist handoff names the artifact and validation ref
- independence: reviewer and evaluator IDs do not overlap builder IDs
- worktree strategy: parallel code work has isolated worktrees or is collapsed into sequential handoffs
- audit: trace ref, run state ref, escalation policy, and human signoff requirement for high or regulated risk

`delivery-orchestration-gate.sh` rejects missing plan-time reports, builder self-review, evaluator self-review, missing SDLC stages, UI work without frontend/UX coverage, API work without backend/API coverage, parallel work without isolation, missing handoff refs, high-risk delivery without human signoff requirement, stale reports, and placeholder text. This makes "spawn subagents" an auditable delivery plan instead of a vague swarm.

## Project Context Contract

At plan and later phases, `walteur-kit/project-context.json` records the AI context files and subagent handoff trail that make the run resumable without bloating the context window. It is shaped by `walteur-kit/schemas/project-context.schema.json`.

Minimum project-context proof:

- generated context: `AGENTS.md`, `CLAUDE.md`, `.claude/rules/*.md`, `_relay/BATON.md`, and source refs
- context budget: `AGENTS.md` <= 32 KiB and `CLAUDE.md` <= 200 lines, with actual byte/line counts
- specificity: real commands verified, snippets from this project, generic rules removed, no placeholders
- subagent handoffs: every specialist handoff names `from`, `to`, artifact ref, validation ref, baton ref, and status
- freshness: context is newer than the PLAN/PRD/current-stack/delivery/state inputs it summarizes

`project-context-gate.sh` rejects missing plan-time proof, missing AGENTS/CLAUDE/rule/baton files, oversized context, generic placeholder text, rules outside `.claude/rules`, broken handoff artifact or validation refs, zero handoffs, stale reports, and budget mismatches. This turns "keep context small and use subagents" into a checkable artifact instead of an instruction buried in prose.

## Self-Improvement Contract

At plan and later phases, `walteur-kit/self-improvement.json` records how the loop gets sharper over time. It is shaped by `walteur-kit/schemas/self-improvement.schema.json`.

Minimum self-improvement report:

- trace mining: `trace_refs[]` and any verifier-grounded `failure_clusters[]`
- scouting: current-year sources, including at least one GitHub repository source when repo or stack choices can add value
- source routing: selected source-manifest entries, source-use receipts, and any rejected upstreams
- candidates: license, maintenance, security review, fit, decision, and evidence for each candidate
- proposals: bounded changes only, each tied to weakness mining, scout findings, retro, or manual review
- validation: baseline, current run, zero regressions, command evidence, and rollback path for promoted changes
- compounding: memory updates with `lesson`, `target_ref`, `result_ref`, `captured:true`, and the next watch signal

`self-improvement-gate.sh` rejects missing reports once the run reaches plan, stale reports, reports without a current GitHub scout, unchecked security or maintenance claims, unbounded proposals, promoted changes without rollback proof, regression failures, missing evidence refs, memory updates without capture evidence, overlong lesson lines, and placeholder text. The gate lets the harness learn, but only through measured deltas.

## Production Layers Contract

For software, data/AI, cloud/IaC, and mixed builds, capture the 13-layer production reality in `walteur-kit/layers.json`, shaped by `walteur-kit/schemas/production-layers.schema.json`.

Minimum layer contract:

- identity: `schema_version`, `contract_id`, `date`
- coverage: exactly 13 `production_layers[]` entries, IDs 1 through 13
- ownership: every layer has `owner`, `rationale`, `evidence_ref`, and `verification`
- active layers: `in_scope`, `planned`, `built`, or `verified` layers name a `folder_or_artifact`
- cut layers: `out_of_scope` or `deferred` layers name `risk_owner` and `review_trigger`
- architecture fitness: optional `layers`, `edges`, and `forbidden` maps remain available to `fitness-gate.sh`

`production-layers-gate.sh` fails a product or code-producing build when `layers.json` is missing, malformed, incomplete, duplicated, placeholder-filled, or carrying an unsigned deferral. This makes the §14 layer walk a real intake/plan artifact instead of a terminal-audit memory exercise.

## Decision / ADR Contract

At review and ship, `walteur-kit/debate/OPEN.json` must be valid JSON and contain zero unresolved forks. A fresh scaffold writes:

```json
[]
```

When a real fork exists, write it to `OPEN.json` before deciding. After debate, clear the fork from `OPEN.json`, write `walteur-kit/adr/NNNN-slug.md`, and append `walteur-kit/adr/INDEX.json` shaped by `walteur-kit/schemas/adr.schema.json`.

Minimum ADR record:

- control: `debate/OPEN.json` is `[]` before ship
- file: `adr/NNNN-slug.md` with Context, Decision, Rationale, Rejected Alternatives, and Dissent
- index: `schema_version`, `records[]`, `id`, `path`, `status`, `decision`, `owner`, `date`
- proof: rejected alternatives are named, dissent is recorded, paths point to real ADR files

`adr-gate.sh` rejects unresolved forks, invalid or empty `OPEN.json` at ship, ADR Markdown without a typed `INDEX.json`, missing ADR sections, missing rejected alternatives, missing dissent, missing index ownership/status/date, missing indexed files, and placeholder text. The gate proves decision record shape; the quality of the decision remains protocol-reviewed by the debate and final audit.

## Outcome Evaluation Contract

At review and later phases, `walteur-kit/outcome-eval.json` records an independent judgment of whether the delivered artifact satisfies the requested outcome. It is shaped by `walteur-kit/schemas/outcome-eval.schema.json`.

Minimum outcome evaluation:

- subject: artifact and task-context refs
- evaluator: human, LLM, or hybrid reviewer who is independent from the builder
- bias checks: required for LLM or hybrid evaluation, including leniency, verbosity, and self-preference checks
- rubric: 3 to 7 weighted criteria, scores, confidence, evidence refs, and feedback
- overall: score, confidence, summary, and no blockers
- freshness: eval must be newer than the artifact, spec, QA, score, audit, and DoD evidence it judges

`outcome-eval-gate.sh` rejects builder self-review, shallow PASS reports, weights that do not sum to 1.0, scores below threshold, low confidence, missing evidence, missing bias checks for model judges, critical criteria below threshold, blockers, stale reports, and placeholder text. This makes "best" a separate evaluation event instead of the builder grading its own work.

## QA Report Contract

At verify, `walteur-kit/qa-report.json` must be a real proof report shaped by `walteur-kit/schemas/qa-report.schema.json`.

Minimum QA report:

- identity: `schema_version`, `verdict`, `ts`
- dimensions: `unit_integration`, `functional`, `logic`, `integration`, `data_integrity`, `security`, and `ux_resilience`
- command evidence: `unit_integration.recorded_command` plus `exit_code`
- trace evidence: `acceptance_criteria_coverage[]` when a PRD or PRD proof file exists
- blockers: `blockers[]`
- gaps: `known_gaps[]` with owner and severity when any remain

`qa-contract-gate.sh` rejects a shallow top-level `PASS`, missing dimensions, a VETO or FAIL hidden under top-level PASS, failed unit/integration exit code, shell-indirection in the recorded command, stale QA reports, placeholder text, missing evidence refs, and missing acceptance-criteria coverage when a PRD exists. Before verify, a zero-byte `qa-report.json` is treated as a runtime stub. At verify, review, ship, or reflect, it fails.

## Tool Guardrail Coverage Contract

For AI/agent builds, `walteur-kit/tool-guardrails.json` records the runtime guardrails wired around every agent-callable tool. It is shaped by `walteur-kit/schemas/tool-guardrails.schema.json` and composes on top of the tool-contract gate: the contract gate proves each tool's static shape, this gate proves the runtime bands and full coverage.

Minimum guardrail coverage:

- envelope: `schema_version`, `manifest_id`, `updated_at`, `policy` are strings and `tools` is an array; any present `external` field is a real JSON boolean (a quoted `"true"` is rejected, not trusted)
- pre-call: `pre_call.checks` is non-empty for every tool — arguments are validated, authorized, rate-limited, and injection-scrubbed before the call
- post-call: `post_call.checks` is non-empty for every tool — the tool result is validated, scrubbed of injected instructions, and size-bounded before the model consumes it
- error-path: `error_path.retryable` and `error_path.fatal` are arrays, and `on_fatal` is a real action, never a silent no-op
- dangerous invariant: a `write_irreversible`, `external_money`, or `external` tool requires non-empty `pre_call.checks`, an `on_fatal` that halts/escalates/rolls back/compensates/aborts (never a bare retry), AND an `evidence_ref` on every band — so the declaration is wired, not merely asserted
- no silent empty table: an applicable build with zero tools and no tool-contracts must set `"no_external_tools": true` to assert it invokes none — an empty table no longer passes by default
- coverage: every tool declared in a tool-contract appears in the guardrail table

`tool-guardrail-gate.sh` is `NOT_APPLICABLE` for non-agent builds, `SKIP`s loudly when jq is absent, and otherwise fails an agent build with a missing or empty-unacked table, a bad envelope, an uncovered contract tool, an unguarded input/output, a silently swallowed fatal error, or a dangerous tool without a halting fatal action and wired evidence. Scope honestly: the gate proves **every *declared* agent-callable tool is guarded and every declared tool-contract is covered** — externality is author-asserted via `side_effect_class`/`external` (the gate cannot infer it from code), and `checks`/`evidence_ref` prove a guardrail is *declared and pointed at code*, with actual runtime behaviour verified by the QA and outcome-eval layers. It turns the guardrail table from an unwritten assumption into a checkable artifact; it is not a substitute for executing the guardrails.

## Scoreboard Contract

At ship, `walteur-kit/scoreboard.json` must be an eight-dimension score contract shaped by `walteur-kit/schemas/scoreboard.schema.json`.

Minimum scoreboard:

- identity: `schema_version`, `ts`
- target: `target`, `targets_locked`, `locked_at`, `locked_by`
- result: `composite`
- dimensions: `design`, `infrastructure`, `security`, `ux_ui`, `performance`, `features`, `data_architecture`, and `devex`
- each dimension: `score`, `floor`, `rationale`, `evidence_ref`
- optional loop cap: `refine_max`

`scoreboard-gate.sh` rejects two-field score stubs, unlocked targets, composite below target, missing dimensions, scores below their floor, security below 8, missing evidence refs, stale scoreboards, placeholder text, and invalid target/floor numbers. Before ship, a zero-byte `scoreboard.json` is treated as a runtime stub. At ship or reflect, it fails.

## Definition of Done Contract

At ship, `walteur-kit/DEFINITION-OF-DONE.md` must be a closed checklist, not a template.

Minimum DoD proof:

- closure: no `- [ ]` unchecked items remain
- checked evidence: every `- [x]` item has same-line `Evidence: ...` with a typed proof reference or existing non-empty project file
- waivers: every non-applicable item is written as `N/A - reason`
- freshness: the DoD is newer than the source and evidence files it certifies
- hygiene: no TODO, TBD, placeholder text, or angle-bracket placeholders remain

`definition-of-done-gate.sh` rejects missing DoD files at ship/reflect, open checklist items, checked items without evidence, checked evidence that is only loose prose, missing/empty/outside-root local evidence files, weak N/A lines, placeholders, and stale checklists. Before ship, the scaffolded DoD template is allowed and reported as not applicable. At ship or reflect, it fails until the checklist is closed with validated proof references.

## Terminal Audit Contract

At ship, `walteur-kit/audit.json` must be a real certificate shaped by `walteur-kit/schemas/audit.schema.json`.

Minimum audit certificate:

- identity: `schema_version`, `model`, `ts`
- verdict: `certified` and `evidence_reproduced`
- score: eight `scored_dims` entries for design, infrastructure, security, UX/UI, performance, features, data architecture, and DevEx
- production reality: `layer_walk` covers all 13 layers with status or verdict plus evidence
- decision review: `adr_recheck` exists, even when no ADRs apply
- intent proof: `intent_vs_impl[]` cites intended behavior and implemented evidence
- blockers: `launch_blockers[]` and `shortfalls[]`
- gaps: `known_gaps[]` with owner and severity when any remain

`audit-contract-gate.sh` rejects a shallow `certified:true` stub, missing scores, missing layers, missing intended-vs-implemented proof when a PRD exists, launch blockers, shortfalls, stale audit files, placeholder text, and certified audits where the evidence was not reproduced. Before ship, a zero-byte `audit.json` is treated as a runtime stub. At ship or reflect, it fails.

## Gate Registry

`walteur-kit/gate-registry.json` maps `build_class` and `risk_tier` to the gates that must appear in the build contract.

The registry answers "which checks are mandatory for this kind of work?"

- `requirements.all`: baseline gates every run declares
- `requirements.by_build_class`: gates selected by work type
- `requirements.by_risk_tier`: gates selected by consequence
- `gates[]`: gate metadata, hook availability, report path, and expected evidence

The registry does not make absent canonical-kit hooks pretend to exist. It labels availability as `spec`, `canonical`, or `optional`, then linting checks only what this distribution can honestly verify.

## State File

The runnable kit should persist the active run in `walteur-kit/autopilot/STATE.json`, shaped by `walteur-kit/schemas/harness-state.schema.json`.

Minimum state:

- identity: `run_id`, `goal`, `build_class`, `risk_tier`
- control: `phase`, `autonomy_policy`, `budgets`, `recovery_policy`, `context_sentinel`
- progress: `stages[]`, `gates[]`, `evidence[]`
- safety: `protected_paths[]`, `decisions[]`, `signoffs[]`, `authority_boundaries[]`, `blockers[]`, `known_gaps[]`
- handoff: `next_action`, `baton_path`, `updated_at`

The state file is a control surface, not a memory brain. Graphify remains the retrieval brain. The state file answers "where is this run now?" only.

Every runnable state must also carry the recovery and context-sentinel contract:

- `recovery_policy.posture` must be `i_will_figure_it_out`
- every obstacle triggers exactly three genuinely different paths
- each path is judged on `what`, `artefact`, `assumption`, `cost`, `failure_mode`, and `validation`
- blocked stages, `BLOCKED` gates, and entries in `blockers[]` must carry `recovery_decision_id`
- every `recovery_decision_id` must resolve in `recovery_policy.decision_log_path`, usually `walteur-kit/figure-it-out.jsonl`
- each recovery decision record must include one obstacle, exactly three complete paths, a chosen path, reasoning, validation test, escalation trigger, and timestamp
- escalation is allowed only after the three paths are scored, one is chosen, validation fails, and the question for Tony is specific
- `context_sentinel.user_name` must be `Tony`
- `context_sentinel.response_prefix` must be `Tony,`
- every agent response must start with that prefix
- if the prefix disappears, treat it as context drift: compact the live state into `_relay/BATON.md`, refresh critical instructions, and continue from the baton

When `build-contract.json` and `gate-registry.json` exist, state lint also reconciles them:

- state `build_class` and `risk_tier` must match the build contract
- every required gate selected by the class/risk registry must appear in `STATE.gates[]`
- every `PASS` gate must cite evidence

When `estimate.json` exists, estimate lint also reconciles it:

- `STATE.budgets.time_minutes` must match `estimate.minutes.expected`
- `STATE.budgets.input_tokens` must match `estimate.tokens.input` when present, otherwise `estimate.tokens.expected`
- `STATE.budgets.output_tokens` must match `estimate.tokens.output` when present, otherwise zero
- `STATE.budgets.cost_usd` must match `estimate.usd.expected`

`phase-gate.sh` then checks whether the state is allowed to be at its current phase:

- prior stages must be `passed` or `skipped`
- passed prior stages need evidence references
- skipped prior stages and prior gates need real non-pending reasons
- future stages cannot already be `in_progress` or `passed`
- red gates in or before the current phase block advancement
- hard gates selected by the contract or registry cannot be skipped once their stage is prior to the current phase, or once the current stage is marked `passed`

`evidence-gate.sh` then checks whether cited evidence can support the claims:

- evidence IDs must be unique
- every referenced evidence ID must exist
- PASS gates and passed stages need at least one PASS evidence item
- PASS evidence cannot be summary-only
- report, audit, screenshot, and source evidence need a path
- command evidence needs `command`, output `path`, and `timestamp`
- review, decision, and manual-check evidence need either a path or `owner`, `timestamp`, and `summary`
- evidence paths must stay inside the project root and must not use parent traversal
- PASS evidence paths must exist and be non-empty
- JSON evidence reports with a `verdict` must match the evidence verdict in state

`risk-acceptance-gate.sh` then checks whether a run is allowed to carry risk forward:

- high or regulated ship phases need approved owner signoff with evidence
- restricted or regulated data ship phases need approved owner signoff with evidence
- active authority boundaries for external, money, contract, production, irreversible, confidential-data, or data actions need approved owner signoff with evidence
- `ACCEPTED_RISK` gates need owner, reason, and an approved `accepted_risk` signoff covering the gate ID
- accepted high or critical known gaps need owner, accepted reason, and an approved signoff covering the gap text
- approved signoffs must cite PASS or ACCEPTED_RISK evidence

`run-trace.sh` is both the append-only span writer and a default gate:

- before state exists, or while the run is still at `intake`, trace enforcement is `NOT_APPLICABLE`
- after intake, missing or malformed `walteur-kit/run-trace.jsonl` is a failed traceability gate
- usable spans must carry `ts`, `phase`, `model`, `tool`, `exit_code`, `gate_verdict`, and `tokens.estimate`
- at least one span must belong to the current phase or a prior phase

## Minimum Viable Loop (MVL) profile

The full registry can select 40-58 gates for a serious product build. That ceremony is for products, not for a typo or a small feature — so the loop is **layered, not monolithic**. The sound core is usable on its own.

The MVL is the irreducible evidence spine: the **8 phases** plus **8 core gates** that make any run honest, regardless of size:

| Phase | MVL core gate | Proves |
|---|---|---|
| intake | `build-contract-lint` | the request and its classification are captured |
| plan | `phase-gate` | phase order and prior-stage closure are valid |
| verify | `evidence-gate` | cited evidence exists and supports its verdict |
| verify | `qa-contract-gate` | functional/logic/integration checks ran with evidence |
| review | `risk-acceptance-gate` | residual risk is owned and signed, not ignored |
| ship | `definition-of-done-gate` | the DoD checklist is closed with real proof refs |
| ship | `scoreboard-gate` | the result meets the locked quality target |
| ship | `audit-contract-gate` | a terminal certificate exists, green, and fresh |

Everything else in the 69-gate registry is **opt-in depth layered on top of this core** — selected by build class (e.g. frontend/perf/i18n for software) and risk tier (e.g. compliance/authz for regulated). `availability: optional` gates (container-scan, maintainability, mutation, craft) are never forced; a build adds them when it wants them.

How to run the layers in practice (these already exist — the MVL is their floor, not a new mechanism):

- **SKIP** — typo / one-liner / pure-CLI / brownfield where intent already exists: no ceremony.
- **LIGHT** (`/feature`) — a small feature: the MVL spine, Planner→Coder→Tester→Reviewer, no full senior panel or full registry dispatch.
- **FULL** (`/goal`) — a new user-facing product: the MVL spine **plus** all class/risk-selected gates and the senior governance panel.

The rule: a run may add gates above the MVL, but never drop below it. The MVL is the line under which "done" stops meaning anything.

## Enterprise Defaults

- Default to the smallest useful slice, but never omit the proof that makes the slice safe.
- Treat high-risk surfaces as one-way doors unless rollback is proven.
- Keep deterministic checks outside model judgment wherever possible.
- Use independent review for ship decisions. Author self-review is not enough.
- Prefer flat files and schemas over standing daemons.
- Every output has an owner, an audience, and a verification path.
- Every stop produces options, not a vague blocker.

## Promotion Rule

Before a run moves from one phase to the next, it must answer:

1. What evidence did we just read?
2. What user outcome does that evidence support?
3. What remains unknown?
4. What is the next smallest action?
5. What would make us stop or roll back?

If any answer is missing, the run stays in the current phase.
