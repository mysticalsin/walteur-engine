# WALTEUR Definition of Done

> Template. A build is not done until every applicable item below has fresh evidence.

## Use

- Keep this file per project or per run.
- Check an item only after reading the actual output.
- For non-applicable items, write `N/A - reason` on the same line.
- Every checked item needs same-line `Evidence:` with a typed proof (`command:`, `report:`, `screenshot:`, `review:`, `signed-decision:`, `url:`, `log:`) or an existing non-empty project file.
- A "known gap" is allowed only when it is named, risk-rated, and accepted by the right owner.

## 0. Scope And Risk

- [ ] Build class recorded: `software`, `workflow`, `document`, `data-ai`, `cloud-iac`, or `mixed`.
- [ ] User outcome and success metric recorded with baseline and target.
- [ ] In scope, out of scope, and protected paths recorded.
- [ ] Risk tier recorded: `low`, `medium`, `high`, or `regulated`.
- [ ] Autonomy policy recorded: `full_autopilot`, `pause_at_plan_and_audit`, `pause_at_review`, or `pause_per_task`.
- [ ] `STATE.json` records `recovery_policy.posture="i_will_figure_it_out"`, exactly three recovery paths, six decision dimensions, validation, log path, and escalation rule.
- [ ] Every blocked stage, `BLOCKED` gate, or `blockers[]` entry records `recovery_decision_id` that resolves to a valid 3-path decision in `walteur-kit/figure-it-out.jsonl`.
- [ ] `STATE.json` records `context_sentinel.user_name="Tony"`, `response_prefix="Tony,"`, every-response enforcement, and `compact_and_resume` into `_relay/BATON.md`.
- [ ] External action, money, contract, production, and confidential-data boundaries recorded.

## 1. Intent

- [ ] Current date checked for time-sensitive facts.
- [ ] `self-heal-report.json` exists or records a loud skip, and `source-manifest.json` + `SOURCE-ROUTER.md` were consulted before stack, workflow, tool, skill, or subagent choices.
- [ ] `current-stack.json` passes `current-stack-gate.sh`: today's run date, build class, domain, selected stack, current official/source refs, stale-training checks, existing evidence refs, and stack drift acknowledgement where applicable.
- [ ] For user-facing or new-product work, `walteur-kit/PRD.md` exists and passes the PRD gate.
- [ ] For user-facing, commercial, venture-grade, or full-product work, `walteur-kit/PRODUCT-STANDARD.md` exists and passes the product-standard gate.
- [ ] Product surface covers onboarding, core workflow, data model, auth/permissions, settings, states, analytics, admin/ops, value exchange, support, security/privacy, and release ops - or each cut is signed with a reason.
- [ ] For software, data/AI, cloud/IaC, or mixed work, `walteur-kit/layers.json` exists and passes the production-layers gate.
- [ ] For UI work, `DESIGN.md` or `design-system/MASTER.md` exists and passes the design gate.
- [ ] For existing code, repo context was gathered through graphify/wiki first, then scoped raw reads.
- [ ] At least three assumptions or unknowns are recorded.
- [ ] The cheapest validation or technical spike is recorded for the highest-risk assumption.
- [ ] Every acceptance criterion has an observable verification path.
- [ ] `prompt-refinement.json` passes `prompt-refinement-gate.sh`: the raw ask is refined into an enterprise build brief with outcome, non-goals, acceptance criteria, routing, specialist plan, verification plan, and stop conditions.

## 2. Plan

- [ ] `PLAN.md` exists, is specific to this project, and cites the PRD or existing intent source.
- [ ] Estimate recorded before build: tokens, time, cost, and max budget.
- [ ] Relevant-files manifest lists test files before source files.
- [ ] Task graph is ordered by dependency, with parallel ownership boundaries when agents are used.
- [ ] Every upstream source that shaped the plan has a `walteur-kit/source-use.json` receipt and `walteur-kit/source-use-report.json` proof with `source_id`, immutable pinned ref, extracted pattern, rejected parts, license/maintenance/security/fit checks, artifact refs, verification, and rollback where needed.
- [ ] Protected paths are declared under `<boundaries>` or equivalent.
- [ ] Rollback, undo, or recovery path is named before any high-risk change.
- [ ] Any architecture, product, API, data-model, or scope fork has an ADR with rejected alternatives, dissent, owner, and `debate/OPEN.json` cleared.
- [ ] `delivery-orchestration.json` passes `delivery-orchestration-gate.sh`: agent roster, SDLC stages, role independence, frontend/backend/API/QA/security/UX coverage, handoffs, worktree boundaries, and audit trail are recorded.
- [ ] `project-context.json` passes `project-context-gate.sh`: AGENTS/CLAUDE/rules context, context budget, baton, source refs, and subagent handoff refs are evidenced.
- [ ] `self-improvement.json` passes `self-improvement-gate.sh`: trace mining, current GitHub scout, candidate review, bounded proposals, regression proof, rollback proof for promoted changes, and evidence-backed memory capture are recorded.

## 3. Build

- [ ] Failing test, fixture, eval, dry-run, or acceptance check existed before implementation.
- [ ] Implementation changed only the files needed for the task.
- [ ] No placeholder, TODO, fake proof, or unchecked stub remains.
- [ ] No unrelated refactor, formatting churn, or metadata noise was added.
- [ ] For workflows, the runbook/SOP was dry-run with sample inputs.
- [ ] For documents, all factual claims have source references or are marked unknown.
- [ ] For data/AI systems, eval data, model/version, prompt/version, and failure modes are recorded.
- [ ] For cloud/IaC, plan output, policy scan, and rollback instructions are recorded.

## 4. Verification

- [ ] Unit or component tests passed.
- [ ] Integration or workflow tests passed where applicable.
- [ ] E2E, browser, screenshot, or dry-run verification passed where applicable.
- [ ] Lint, typecheck, schema validation, or equivalent static checks passed.
- [ ] Security, secrets, dependency, and supply-chain checks passed or recorded as loud skips.
- [ ] Performance, reliability, or cost budgets were checked where applicable.
- [ ] Accessibility and content checks passed for UI or user-facing material.
- [ ] `qa-report.json` passes `qa-contract-gate.sh` or the equivalent verification report records unit/integration, functional, logic, integration, data integrity, security, UX/resilience, blockers, gaps, and PRD acceptance coverage.
- [ ] `scoreboard.json` passes `scoreboard-gate.sh`: composite meets target, every dimension meets its floor, security is at least 8, targets are locked, and evidence refs exist.
- [ ] The verification output was read, not merely executed.

## 5. Review

- [ ] Self-critique completed against the user request and plan.
- [ ] Intended-vs-implemented review cites both intended behavior and actual artifact.
- [ ] Code review, document review, or workflow review was completed by an independent pass.
- [ ] Security review completed for auth, data, external calls, money, or regulated surfaces.
- [ ] All reviewer vetoes or blockers are resolved or explicitly accepted by owner.
- [ ] `adr-gate.sh` passes: no unresolved forks remain, and any ADR files have typed index records plus rejected alternatives and dissent.
- [ ] `outcome-eval.json` passes `outcome-eval-gate.sh`: an independent evaluator scored the artifact against the requested outcome with rubric evidence, confidence, bias checks where needed, and no blockers.
- [ ] Any open gap has severity, owner, next action, and acceptance reason.

## 6. Ship

- [ ] Ship artifact is in the expected location and named in the final handoff.
- [ ] Release notes, README, API docs, operator notes, or user docs are updated where applicable.
- [ ] Rollback or recovery path was tested or explicitly signed off.
- [ ] Monitoring, alerting, audit log, or follow-up check is defined for live systems.
- [ ] Human sign-off is logged for high-risk, regulated, external, production, or irreversible work.
- [ ] `audit.json` passes `audit-contract-gate.sh` or the terminal audit equivalent records the same scores, layer walk, intent evidence, blockers, shortfalls, and reproduced evidence.
- [ ] Known gaps are stated plainly, or `Known gaps: none, verified`.

## 7. Reflect

- [ ] `_relay/BATON.md` or handoff notes record current state, done items, blockers, and next action.
- [ ] If any agent stopped starting responses with `Tony,`, the run compacted into `_relay/BATON.md`, refreshed critical instructions, and resumed from that baton.
- [ ] Dead ends and handoff hints are recorded so the next agent does not repeat failed paths.
- [ ] Lessons or mistakes were added to the right memory file when a correction occurred.
- [ ] Gate failures or recurring patterns were routed into the improvement backlog.
- [ ] Any self-improvement proposal promoted by the run has regression proof and a rollback path; rejected or deferred proposals state why.
- [ ] Source-manifest additions or accepted upstream drift were recorded with selftest proof and a memory lesson.
- [ ] Final response lists checks run and any checks skipped with reasons.
