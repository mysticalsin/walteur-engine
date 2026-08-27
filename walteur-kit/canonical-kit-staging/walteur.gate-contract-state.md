# Canonical Patch: Orchestrator Build Contract and Runtime State

Target: `~/walteur/starter/.claude/workflows/walteur.js`

Status: staged for the canonical runnable kit. This patch was written after reading the live local file at `~/walteur/starter/.claude/workflows/walteur.js` on 2026-06-22. The local repo had unrelated dirty changes, so this spec tree records the patch instead of editing that worktree.

## Why

Ship-gate dispatch is not enough. The orchestrator must emit the files the new gates reason over:

- `walteur-kit/build-contract.json`: what the run promises to deliver
- `walteur-kit/estimate.json`: the upfront time, token, and cost estimate
- `walteur-kit/current-stack.json`: the run-date stack proof
- `walteur-kit/gate-registry.json`: which gates are required for class and risk
- `walteur-kit/autopilot/STATE.json`: where the run is and which gates have evidence
- `walteur-kit/prompt-refinement.json`: the Improve-this-prompt pass from raw request to enterprise brief
- `walteur-kit/delivery-orchestration.json`: the agent roster, SDLC gates, independence, coverage, and handoff plan
- `walteur-kit/project-context.json`: the AGENTS/CLAUDE/rules context, context budget, baton, and subagent handoff proof
- `walteur-kit/self-improvement.json`: the trace mining, current source scout, candidate review, regression proof, and memory-capture plan
- `walteur-kit/outcome-eval.json`: the independent outcome evaluator rubric and verdict
- `walteur-kit/estimate-report.json`: whether the estimate is valid and reconciled to runtime budgets
- `walteur-kit/current-stack-report.json`: whether current-stack proof is dated, sourced, and evidenced
- `walteur-kit/prompt-refinement-report.json`: whether the prompt-refinement contract is valid and fresh
- `walteur-kit/delivery-orchestration-report.json`: whether the delivery-orchestration contract is valid and fresh
- `walteur-kit/project-context-report.json`: whether project context, context budget, baton, and subagent handoff refs are valid and fresh
- `walteur-kit/self-improvement-report.json`: whether the compounding improvement contract is valid and fresh
- `walteur-kit/outcome-eval-report.json`: whether the independent outcome evaluation is valid and fresh
- `walteur-kit/qa-report.json`: the structured QA result
- `walteur-kit/qa-contract-report.json`: whether the QA contract passes
- `walteur-kit/scoreboard.json`: the scored delivery result
- `walteur-kit/scoreboard-report.json`: whether the scoreboard contract passes
- `walteur-kit/audit.json`: the terminal audit result
- `walteur-kit/audit-contract-report.json`: whether the terminal audit contract passes
- `walteur-kit/build-contract-report.json`: whether the build contract passes
- `walteur-kit/gate-registry-report.json`: whether the registry passes
- `walteur-kit/phase-gate-report.json`: whether the current phase is justified by prior-stage evidence
- `walteur-kit/evidence-gate-report.json`: whether cited evidence exists and supports PASS claims
- `walteur-kit/risk-acceptance-report.json`: whether accepted risks and high-risk ship decisions have owner signoff

Without this, the gates are valid but mostly `NOT_APPLICABLE`. With this patch, `/goal` produces the typed control surface before build work starts and reconciles it at audit time.

## Plan-Phase Insertion

Insert this after the existing `emit-estimate` block and before the post-plan approval gate.

```diff
@@
 await safeOne(() => agent(`Using Bash `mkdir -p ${projectPath}/walteur-kit`, then use the Write tool to create ${projectPath}/walteur-kit/estimate.json with EXACTLY this content (verbatim): ${JSON.stringify(estimate)}`,
   { label: 'emit-estimate', model: 'sonnet', phase: 'Plan' }), 'emit-estimate')
+
+// Harness contracts: typed intake and class/risk gate selection.
+await safeOne(() => agent(
+  `WALTEUR harness contract writer. Project ${projectPath}. Goal ${JSON.stringify(idea)}. Scope ${JSON.stringify(scope).slice(0, 2000)}. Plan has ${plan.tasks.length} tasks.\n` +
+  `Use Bash to mkdir -p ${projectPath}/walteur-kit ${projectPath}/walteur-kit/autopilot.\n` +
+  `Copy the shipped gate registry if present: if [ -f walteur-kit/gate-registry.json ]; then cp walteur-kit/gate-registry.json ${projectPath}/walteur-kit/gate-registry.json; fi\n` +
+  `Read ${projectPath}/walteur-kit/estimate.json and use it as the source for runtime budgets.\n` +
+  `Write ${projectPath}/walteur-kit/build-contract.json. It MUST include schema_version=1, contract_id, request.summary, request.user_outcome, request.primary_user, request.non_goals, build_class, risk_tier, data_classification, success_metrics, constraints, interfaces, verification.gates, evidence_required, unknowns, created_at.\n` +
+  `Choose build_class from software|workflow|document|data-ai|cloud-iac|mixed. Choose risk_tier from low|medium|high|regulated. Then read ${projectPath}/walteur-kit/gate-registry.json and ensure verification.gates includes every id from requirements.all + requirements.by_build_class[build_class] + requirements.by_risk_tier[risk_tier]. Add project-specific gates after those.\n` +
+  `Write ${projectPath}/walteur-kit/current-stack.json with schema_version=1, verdict="PASS", run_date=today UTC, build_class, domain, stack_items, current official/source refs, stale_training_checks, evidence_refs, ts, and stack-fingerprint drift acknowledgement if ${projectPath}/walteur-kit/stack-fingerprint-report.json says DRIFT.\n` +
+  `Write ${projectPath}/walteur-kit/autopilot/STATE.json with schema_version=1, run_id, goal, build_class, risk_tier, phase="plan", autonomy_policy=${JSON.stringify(autonomyPolicy)}, budgets from estimate, stages for intake/discover/plan/build/verify/review/ship/reflect, gates matching the build contract ids with status SKIP or PASS plus reasons/evidence_ids, evidence, signoffs, and updated_at.\n` +
+  `Run: bash ${projectPath}/walteur-kit/hooks/build-contract-lint.sh || true; bash ${projectPath}/walteur-kit/hooks/gate-registry-lint.sh || true; bash ${projectPath}/walteur-kit/hooks/estimate-gate.sh || true; bash ${projectPath}/walteur-kit/hooks/current-stack-gate.sh || true; bash ${projectPath}/walteur-kit/hooks/harness-state-lint.sh || true; bash ${projectPath}/walteur-kit/hooks/phase-gate.sh || true; bash ${projectPath}/walteur-kit/hooks/evidence-gate.sh || true; bash ${projectPath}/walteur-kit/hooks/risk-acceptance-gate.sh || true. Report each exit code and fix JSON shape, current-stack proof, phase-order, budget, signoff, or evidence errors before returning.`,
+  { label: 'harness:contracts', model: 'sonnet', phase: 'Plan' }), 'harness:contracts')

// post-plan approval gate follows
```

Implementation note: the prompt intentionally runs the baseline plan gates and reports exit codes. It must not treat a non-zero code as a reason to continue silently. The agent must fix JSON shape, phase-order, budget, signoff, evidence, prompt, delivery, project-context, or self-improvement errors before returning.

## Required Baseline Gate Coverage

The runnable orchestrator and ship gate must run every gate in `requirements.all` from `walteur-kit/gate-registry.json`, not a hand-picked subset. Current baseline:

```bash walteur:skip
run_gate build-contract-lint.sh
run_gate gate-registry-lint.sh
run_gate estimate-gate.sh
run_gate current-stack-gate.sh
run_gate harness-state-lint.sh
run_gate phase-gate.sh
run_gate evidence-gate.sh
run_gate risk-acceptance-gate.sh
run_gate adr-gate.sh
run_gate prompt-refinement-gate.sh
run_gate delivery-orchestration-gate.sh
run_gate project-context-gate.sh
run_gate self-improvement-gate.sh
run_gate outcome-eval-gate.sh
run_gate qa-contract-gate.sh
run_gate skill-readiness.sh
run_gate docrun.sh
run_gate scoreboard-gate.sh
run_gate audit-contract-gate.sh
```

The plan-time `STATE.json` must include:

- `recovery_policy.posture="i_will_figure_it_out"`
- `recovery_policy.paths_required=3`
- `recovery_policy.dimensions_required=["what","artefact","assumption","cost","failure_mode","validation"]`
- `recovery_policy.decision_log_path="walteur-kit/figure-it-out.jsonl"`
- `recovery_policy.validation_required=true`
- `context_sentinel.user_name="Tony"`
- `context_sentinel.response_prefix="Tony,"`
- `context_sentinel.every_response=true`
- `context_sentinel.missing_prefix_action="compact_and_resume"`
- `context_sentinel.compaction_target="_relay/BATON.md"`
- `context_sentinel.baton_path="_relay/BATON.md"`

If the agent stops starting responses with `Tony,`, treat it as a context-degradation signal: compact the active state into `_relay/BATON.md`, refresh critical instructions, and continue from the baton.

## Audit-Phase Insertion

Insert this inside the existing `emit-gates` writer, next to `qa-report.json`, `audit.json`, `scoreboard.json`, `DEFINITION-OF-DONE.md`, and `debate/OPEN.json`.

```diff
@@
- `Using Bash `mkdir -p ${projectPath}/walteur-kit/debate`, then use the Write tool to create these FIVE files with EXACTLY this content (verbatim):
+ `Using Bash `mkdir -p ${projectPath}/walteur-kit/debate ${projectPath}/walteur-kit/autopilot`, then use the Write tool to create these files with EXACTLY this content (verbatim):
@@
 ${projectPath}/walteur-kit/debate/OPEN.json:
 []
+
+${projectPath}/walteur-kit/autopilot/STATE.json:
+{"schema_version":1,"run_id":"<existing run id or timestamp>","goal":${JSON.stringify(idea)},"build_class":"<same as build-contract.json>","risk_tier":"<same as build-contract.json>","phase":"ship","autonomy_policy":${JSON.stringify(autonomyPolicy)},"budgets":{"time_minutes":${estimate.minutes.expected},"input_tokens":${estimate.tokens.expected},"output_tokens":0,"cost_usd":${estimate.usd.expected}},"stages":[{"name":"intake","status":"passed","evidence_ids":["build-contract-report","gate-registry-report"]},{"name":"discover","status":"skipped","notes":"Discovery was not a separate phase for this direct run."},{"name":"plan","status":"passed","evidence_ids":["estimate-report"]},{"name":"build","status":"passed","evidence_ids":["qa"]},{"name":"verify","status":"passed","evidence_ids":["harness-state-report","phase-gate-report","evidence-gate-report","qa"]},{"name":"review","status":"skipped","notes":"No external review was required beyond the recorded audit for this run."},{"name":"ship","status":"passed","evidence_ids":["audit","scoreboard"]},{"name":"reflect","status":"not_started"}],"gates":[{"id":"build-contract-lint","stage":"intake","status":"PASS","evidence_ids":["build-contract-report"]},{"id":"gate-registry-lint","stage":"intake","status":"PASS","evidence_ids":["gate-registry-report"]},{"id":"estimate-gate","stage":"plan","status":"PASS","evidence_ids":["estimate-report"]},{"id":"harness-state-lint","stage":"verify","status":"PASS","evidence_ids":["harness-state-report"]},{"id":"phase-gate","stage":"verify","status":"PASS","evidence_ids":["phase-gate-report"]},{"id":"evidence-gate","stage":"verify","status":"PASS","evidence_ids":["evidence-gate-report"]},{"id":"risk-acceptance-gate","stage":"review","status":"PASS","evidence_ids":["risk-acceptance-report"]},{"id":"docrun","stage":"verify","status":"SKIP","reason":"No documented shell blocks in final handoff."}],"evidence":[{"id":"audit","kind":"audit","verdict":"PASS","path":"walteur-kit/audit.json"},{"id":"qa","kind":"report","verdict":"PASS","path":"walteur-kit/qa-report.json"},{"id":"scoreboard","kind":"report","verdict":"PASS","path":"walteur-kit/scoreboard.json"},{"id":"build-contract-report","kind":"report","verdict":"PASS","path":"walteur-kit/build-contract-report.json"},{"id":"gate-registry-report","kind":"report","verdict":"PASS","path":"walteur-kit/gate-registry-report.json"},{"id":"estimate-report","kind":"report","verdict":"PASS","path":"walteur-kit/estimate-report.json"},{"id":"harness-state-report","kind":"report","verdict":"PASS","path":"walteur-kit/harness-state-report.json"},{"id":"phase-gate-report","kind":"report","verdict":"PASS","path":"walteur-kit/phase-gate-report.json"},{"id":"evidence-gate-report","kind":"report","verdict":"PASS","path":"walteur-kit/evidence-gate-report.json"},{"id":"risk-acceptance-report","kind":"report","verdict":"PASS","path":"walteur-kit/risk-acceptance-report.json"}],"signoffs":[{"id":"ship-risk-owner","kind":"high_risk","owner":"<named owner>","status":"approved","reason":"Owner approved ship risk after audit and rollback review.","covers":["ship"],"evidence_ids":["audit"],"timestamp":"<date -u +%Y-%m-%dT%H:%M:%SZ>"}],"updated_at":"<date -u +%Y-%m-%dT%H:%M:%SZ>"}

- THEN read-back-assert: run `jq . ${projectPath}/walteur-kit/qa-report.json ...
+ THEN read-back-assert: run `jq . ${projectPath}/walteur-kit/qa-report.json ... ${projectPath}/walteur-kit/autopilot/STATE.json` and run the baseline harness gates.
```

The concrete implementation should generate the final `STATE.gates[]` from `build-contract.json` and `gate-registry.json`, not hard-code only the baseline gates shown above. The baseline JSON here is the minimum shape and should be expanded by code or by a shell `jq` merge.

## Verification

After applying in `~/walteur/starter`, run:

```bash walteur:skip
bash walteur-kit/hooks/build-contract-lint.sh --selftest
bash walteur-kit/hooks/gate-registry-lint.sh --selftest
bash walteur-kit/hooks/estimate-gate.sh --selftest
bash walteur-kit/hooks/current-stack-gate.sh --selftest
bash walteur-kit/hooks/harness-state-lint.sh --selftest
bash walteur-kit/hooks/phase-gate.sh --selftest
bash walteur-kit/hooks/evidence-gate.sh --selftest
bash walteur-kit/hooks/risk-acceptance-gate.sh --selftest
bash walteur-kit/selftest.sh
```

Then run one small `/goal` against a temporary project and confirm these files exist:

- `walteur-kit/build-contract.json`
- `walteur-kit/gate-registry.json`
- `walteur-kit/estimate.json`
- `walteur-kit/current-stack.json`
- `walteur-kit/autopilot/STATE.json`
- `walteur-kit/build-contract-report.json`
- `walteur-kit/gate-registry-report.json`
- `walteur-kit/estimate-report.json`
- `walteur-kit/current-stack-report.json`
- `walteur-kit/harness-state-report.json`
- `walteur-kit/phase-gate-report.json`
- `walteur-kit/evidence-gate-report.json`
- `walteur-kit/risk-acceptance-report.json`
