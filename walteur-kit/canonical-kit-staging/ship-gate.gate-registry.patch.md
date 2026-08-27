# Canonical Patch: Ship-Gate Harness Contract Dispatch

Target: `~/walteur/starter/.claude/hooks/ship-gate.sh`

Status: staged for the canonical runnable kit. This patch was written after reading the live local file at `~/walteur/starter/.claude/hooks/ship-gate.sh` on 2026-06-22. The live repo had unrelated dirty files, so this spec tree records the patch instead of editing that worktree.

## Why

The spec tree now has nineteen baseline harness gates selected by `walteur-kit/gate-registry.json`:

- `build-contract-lint.sh`: validates `walteur-kit/build-contract.json` when present
- `gate-registry-lint.sh`: validates `walteur-kit/gate-registry.json` and checks required build-contract gates
- `estimate-gate.sh`: validates `walteur-kit/estimate.json` and reconciles it with `STATE.budgets`
- `current-stack-gate.sh`: validates run-date stack proof from current official/source material
- `harness-state-lint.sh`: validates `walteur-kit/autopilot/STATE.json` and reconciles it with the build contract and registry when present
- `phase-gate.sh`: blocks phase jumps until prior stages have evidence or real skip reasons
- `evidence-gate.sh`: proves cited evidence exists and supports PASS claims
- `risk-acceptance-gate.sh`: proves high-risk ship and accepted-risk claims have approved owner signoff
- `adr-gate.sh`: requires material architecture decisions to be recorded
- `prompt-refinement-gate.sh`: requires "Improve this prompt" before PLAN
- `delivery-orchestration-gate.sh`: requires specialist roster, SDLC stage gates, independence, coverage, and handoffs
- `project-context-gate.sh`: requires AGENTS/CLAUDE/rules context, context budget, baton, and subagent handoff evidence
- `self-improvement-gate.sh`: requires trace mining, current source scouting, regression proof, and evidence-backed memory capture
- `outcome-eval-gate.sh`: requires an independent evaluator to grade the delivered result against the user outcome
- `qa-contract-gate.sh`: requires structured QA proof
- `skill-readiness.sh`: proves declared required skills left machine-readable breadcrumbs
- `docrun.sh`: parses documented shell blocks and fails unsafe or broken docs
- `scoreboard-gate.sh`: requires scored delivery evidence
- `audit-contract-gate.sh`: requires terminal audit evidence

The canonical ship gate should dispatch these before the long discipline gate list. Legacy projects without contract/state files keep the same behavior because detect-or-skip gates return `NOT_APPLICABLE` with exit 0 before their required phase or when their contract file is absent. `skill-readiness.sh` exits 0 when no `required-skills.json` is present. `gate-registry-lint.sh` becomes a hard guard only when the registry file is present and invalid.

## Patch

Insert this immediately after the `run_gate()` helper in `ship-gate.sh`, before the existing `run_gate tool-readiness.sh` line.

```diff
@@
   [ "$rc" = 2 ] && fail "craft-gate '$name' reported a violation (exit 2). See walteur-kit/*-report.json."
   return 0
 }
+# Harness contract dispatch. These gates make the enterprise loop typed:
+# intake contract, registry selection, estimate, current stack, runtime state, prompt refinement, delivery orchestration, project context, self-improvement, outcome eval, QA, score, and audit.
+run_gate build-contract-lint.sh
+run_gate gate-registry-lint.sh
+run_gate estimate-gate.sh
+run_gate current-stack-gate.sh
+run_gate harness-state-lint.sh
+run_gate phase-gate.sh
+run_gate evidence-gate.sh
+run_gate risk-acceptance-gate.sh
+run_gate adr-gate.sh
+run_gate prompt-refinement-gate.sh
+run_gate delivery-orchestration-gate.sh
+run_gate project-context-gate.sh
+run_gate self-improvement-gate.sh
+run_gate outcome-eval-gate.sh
+run_gate qa-contract-gate.sh
+run_gate skill-readiness.sh
+run_gate docrun.sh
+run_gate scoreboard-gate.sh
+run_gate audit-contract-gate.sh
run_gate tool-readiness.sh
```

## Required Selftest Additions

In canonical `walteur-kit/selftest.sh`, add these to the standing hook selftest block.

```diff
@@
bash "$SRC_KIT/hooks/build-contract-lint.sh" --selftest >/dev/null 2>&1; ck "build-contract-lint --selftest (5/5)" 0 $?
bash "$SRC_KIT/hooks/gate-registry-lint.sh" --selftest >/dev/null 2>&1; ck "gate-registry-lint --selftest (8/8)" 0 $?
bash "$SRC_KIT/hooks/estimate-gate.sh" --selftest >/dev/null 2>&1; ck "estimate-gate --selftest (9/9)" 0 $?
bash "$SRC_KIT/hooks/current-stack-gate.sh" --selftest >/dev/null 2>&1; ck "current-stack-gate --selftest (8/8)" 0 $?
bash "$SRC_KIT/hooks/harness-state-lint.sh" --selftest >/dev/null 2>&1; ck "harness-state-lint --selftest (18/18)" 0 $?
bash "$SRC_KIT/hooks/phase-gate.sh" --selftest >/dev/null 2>&1; ck "phase-gate --selftest (9/9)" 0 $?
bash "$SRC_KIT/hooks/evidence-gate.sh" --selftest >/dev/null 2>&1; ck "evidence-gate --selftest (8/8)" 0 $?
bash "$SRC_KIT/hooks/risk-acceptance-gate.sh" --selftest >/dev/null 2>&1; ck "risk-acceptance-gate --selftest (11/11)" 0 $?
bash "$SRC_KIT/hooks/adr-gate.sh" --selftest >/dev/null 2>&1; ck "adr-gate --selftest (10/10)" 0 $?
bash "$SRC_KIT/hooks/prompt-refinement-gate.sh" --selftest >/dev/null 2>&1; ck "prompt-refinement-gate --selftest (11/11)" 0 $?
bash "$SRC_KIT/hooks/delivery-orchestration-gate.sh" --selftest >/dev/null 2>&1; ck "delivery-orchestration-gate --selftest (13/13)" 0 $?
bash "$SRC_KIT/hooks/project-context-gate.sh" --selftest >/dev/null 2>&1; ck "project-context-gate --selftest (9/9)" 0 $?
bash "$SRC_KIT/hooks/self-improvement-gate.sh" --selftest >/dev/null 2>&1; ck "self-improvement-gate --selftest (14/14)" 0 $?
bash "$SRC_KIT/hooks/outcome-eval-gate.sh" --selftest >/dev/null 2>&1; ck "outcome-eval-gate --selftest (13/13)" 0 $?
bash "$SRC_KIT/hooks/qa-contract-gate.sh" --selftest >/dev/null 2>&1; ck "qa-contract-gate --selftest (11/11)" 0 $?
bash "$SRC_KIT/hooks/skill-readiness.sh" --selftest >/dev/null 2>&1; ck "skill-readiness --selftest" 0 $?
bash "$SRC_KIT/hooks/docrun.sh" >/dev/null 2>&1; ck "docrun" 0 $?
bash "$SRC_KIT/hooks/scoreboard-gate.sh" --selftest >/dev/null 2>&1; ck "scoreboard-gate --selftest (10/10)" 0 $?
bash "$SRC_KIT/hooks/audit-contract-gate.sh" --selftest >/dev/null 2>&1; ck "audit-contract-gate --selftest (10/10)" 0 $?
bash "$SRC_KIT/hooks/devenv-gate.sh" --selftest >/dev/null 2>&1; ck "devenv-gate --selftest (5/5)" 0 $?
bash "$SRC_KIT/hooks/config-validation.sh" --selftest >/dev/null 2>&1; ck "config-validation --selftest (5/5)" 0 $?
bash "$SRC_KIT/hooks/quickstart-check.sh" --selftest >/dev/null 2>&1; ck "quickstart-check --selftest (6/6)" 0 $?
bash "$SRC_KIT/hooks/nfr-lint.sh" --selftest >/dev/null 2>&1; ck "nfr-lint --selftest (8/8)" 0 $?
bash "$SRC_KIT/hooks/observe-lint.sh" --selftest >/dev/null 2>&1; ck "observe-lint --selftest (6/6)" 0 $?
bash "$SRC_KIT/hooks/perf-gate.sh" --selftest >/dev/null 2>&1; ck "perf-gate --selftest (6/6)" 0 $?
```

## Copy Set

Copy these spec-tree files into the canonical kit before applying the dispatch:

- `walteur-kit/gate-registry.json`
- `walteur-kit/hooks/build-contract-lint.sh`
- `walteur-kit/hooks/gate-registry-lint.sh`
- `walteur-kit/hooks/estimate-gate.sh`
- `walteur-kit/hooks/current-stack-gate.sh`
- `walteur-kit/hooks/harness-state-lint.sh`
- `walteur-kit/hooks/phase-gate.sh`
- `walteur-kit/hooks/evidence-gate.sh`
- `walteur-kit/hooks/risk-acceptance-gate.sh`
- `walteur-kit/hooks/adr-gate.sh`
- `walteur-kit/hooks/prompt-refinement-gate.sh`
- `walteur-kit/hooks/delivery-orchestration-gate.sh`
- `walteur-kit/hooks/project-context-gate.sh`
- `walteur-kit/hooks/self-improvement-gate.sh`
- `walteur-kit/hooks/outcome-eval-gate.sh`
- `walteur-kit/hooks/qa-contract-gate.sh`
- `walteur-kit/hooks/skill-readiness.sh`
- `walteur-kit/hooks/docrun.sh`
- `walteur-kit/hooks/scoreboard-gate.sh`
- `walteur-kit/hooks/audit-contract-gate.sh`
- `walteur-kit/hooks/devenv-gate.sh`
- `walteur-kit/hooks/config-validation.sh`
- `walteur-kit/hooks/quickstart-check.sh`
- `walteur-kit/hooks/nfr-lint.sh`
- `walteur-kit/hooks/observe-lint.sh`
- `walteur-kit/hooks/perf-gate.sh`
- `walteur-kit/schemas/build-contract.schema.json`
- `walteur-kit/schemas/current-stack.schema.json`
- `walteur-kit/schemas/estimate.schema.json`
- `walteur-kit/schemas/gate-registry.schema.json`
- `walteur-kit/schemas/harness-state.schema.json`
- `walteur-kit/schemas/adr.schema.json`
- `walteur-kit/schemas/prompt-refinement.schema.json`
- `walteur-kit/schemas/delivery-orchestration.schema.json`
- `walteur-kit/schemas/project-context.schema.json`
- `walteur-kit/schemas/self-improvement.schema.json`
- `walteur-kit/schemas/outcome-eval.schema.json`
- `walteur-kit/schemas/qa-report.schema.json`
- `walteur-kit/schemas/scoreboard.schema.json`
- `walteur-kit/schemas/audit.schema.json`
- `walteur-kit/scaffold/build-contract.template.json`

## Verification

Run in `~/walteur/starter` after applying:

```bash walteur:skip
bash walteur-kit/hooks/build-contract-lint.sh --selftest
bash walteur-kit/hooks/gate-registry-lint.sh --selftest
bash walteur-kit/hooks/estimate-gate.sh --selftest
bash walteur-kit/hooks/current-stack-gate.sh --selftest
bash walteur-kit/hooks/harness-state-lint.sh --selftest
bash walteur-kit/hooks/phase-gate.sh --selftest
bash walteur-kit/hooks/evidence-gate.sh --selftest
bash walteur-kit/hooks/risk-acceptance-gate.sh --selftest
bash walteur-kit/hooks/adr-gate.sh --selftest
bash walteur-kit/hooks/prompt-refinement-gate.sh --selftest
bash walteur-kit/hooks/delivery-orchestration-gate.sh --selftest
bash walteur-kit/hooks/self-improvement-gate.sh --selftest
bash walteur-kit/hooks/outcome-eval-gate.sh --selftest
bash walteur-kit/hooks/qa-contract-gate.sh --selftest
bash walteur-kit/hooks/skill-readiness.sh --selftest
bash walteur-kit/hooks/docrun.sh
bash walteur-kit/hooks/scoreboard-gate.sh --selftest
bash walteur-kit/hooks/audit-contract-gate.sh --selftest
bash walteur-kit/hooks/devenv-gate.sh --selftest
bash walteur-kit/hooks/config-validation.sh --selftest
bash walteur-kit/hooks/quickstart-check.sh --selftest
bash walteur-kit/hooks/nfr-lint.sh --selftest
bash walteur-kit/hooks/observe-lint.sh --selftest
bash walteur-kit/hooks/perf-gate.sh --selftest
bash walteur-kit/selftest.sh
```

Ship only when the selftests pass and the explicit skip count matches the known distribution shape.
