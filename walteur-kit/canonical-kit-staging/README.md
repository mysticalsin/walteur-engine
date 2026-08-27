# canonical-kit-staging — mixed applied reference copies and staged patches

> **STATUS (2026-06-22): PARTIALLY APPLIED.** Rows 15-19 below were applied into the canonical runnable kit
> and merged to `~/walteur` **main** (`~/walteur` IS a git repo; `starter/` is tracked under it — correcting
> an earlier note that called it "not git-tracked"). Trail: `v9.1-canonical-wire` → main, commits
> `d9b223c` (wire) · `521b875` (the 3 follow-ups) · `db239a8` (merge). Each was verified: the canonical
> `walteur-kit/selftest.sh` v9.1 block is 4/4; the lesson-gate supersede twin is 6/6; orchestrator-smoke PASS.
> Row 20 remains staged. Rows 36-37 are newer harness-contract staging patches, not applied. These files remain
> here as reference copies plus staged adoption notes.
>
> *Original intent (kept for context):* the ast-grep gate backend was applied into this git SPEC tree (its
> homes exist here); the memory/HITL/spec-trace pieces below targeted the runnable kit and are now applied there.

| File | Target in `~/walteur/starter` | What it does | Honesty |
|---|---|---|---|
| `SCHEMA.lessons.md` | `walteur-kit/memory/SCHEMA.lessons.md` | Typed lesson record (Preference/Procedure/Requirement) + optional bi-temporal fields `invalidated_at` / `superseded_by` / `source_build`. Schema-on-read; old keyless lessons stay valid (back-compat). | PROTOCOL (advisory store) |
| `lesson-gate.sh.patch` | merge into `walteur-kit/memory/lesson-gate.sh` | On a detected contradiction, CLOSE the superseded lesson's window in the LIVE store (was: park-in-conflicts-then-exit, kept serving stale). **Conservative:** only auto-closes on an explicit `superseded_by` link or an exact-key contradiction; ambiguous = HELD, as today. | PROTOCOL |
| `recall.sh` | `walteur-kit/memory/recall.sh` | RECALL filter — `(.invalidated_at // null)==null` so closed lessons never reach PLAN. ~12 lines jq. | deterministic filter |
| `STATE.json.delta` | merge into `walteur-kit/autopilot/STATE.json` | Adds `pause_per_task` as a third `_autonomy_options` value (off by default). | PROTOCOL |
| `walteur.seam.pause_per_task.md` | `.claude/workflows/walteur.js` seam | Where the orchestrator halts after EACH build sub-task (reuses the shipped APPROVED-file + STATE.json halt-resume machinery). `walteur.js` was not readable this session — this is the seam SPEC, not a verified patch. | PROTOCOL / ASSUMED seam |
| `spec-trace.T4.patch.md` | patch `walteur-kit/hooks/spec-trace.sh` (:251-267) | T4 gains Arm B: when a PRD AC carries an `ast_proof`, delegate to `intent-trace.sh` for a code-PROOF (not just a text reference). **STAGED, not applied** — it edits a working 15KB hook; apply after reviewing the real :251-267 against the patch. | HARD (additive) |
| `PRD.worked-example.md` | reference | 3 worked ACs that pin a construct (authz-check etc.) → the `ast_proof` shape `intent-trace.sh` consumes via `prd.proofs.json`. | doc |

## Apply order
1. `SCHEMA.lessons.md` (doc) → 2. `lesson-gate.sh` merge → 3. `recall.sh` → 4. selftest the invalidation twin →
5. `STATE.json` delta → 6. `walteur.seam.pause_per_task.md` into `walteur.js` → 7. (optional) `spec-trace.T4.patch`.
Nothing here ships until its selftest is green (the kill-criterion).

## Harness-contract staging (2026-06-22)

These files are STAGED for the canonical runnable kit. They were written after reading the live local files in
`~/walteur/starter`; that worktree currently has unrelated dirty changes, so this spec tree records
the adoption patch instead of editing those files.

| File | Target in `~/walteur/starter` | What it does | Honesty |
|---|---|---|---|
| `ship-gate.gate-registry.patch.md` | `.claude/hooks/ship-gate.sh` | Adds dispatch for every baseline gate in `gate-registry.json` before the discipline gate list, including prompt refinement, delivery orchestration, self-improvement, outcome evaluation, QA, score, audit, and docrun. | STAGED patch |
| `walteur.gate-contract-state.md` | `.claude/workflows/walteur.js` | Makes `/goal` emit `build-contract.json`, `estimate.json`, `gate-registry.json`, rich `autopilot/STATE.json` with `recovery_policy` and `context_sentinel`, prompt/delivery/self-improvement/outcome runtime JSON, gate reports, and `debate/OPEN.json`, then runs the baseline harness gates at plan and audit time. | STAGED patch |

Verification for the staging notes:

```bash
bash walteur-kit/eval/canonical-staging-lint.sh --selftest
bash walteur-kit/eval/canonical-staging-lint.sh
```
