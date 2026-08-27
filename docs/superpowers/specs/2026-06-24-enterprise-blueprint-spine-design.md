# Enterprise Blueprint Spine Design

## Goal
Add a WALTEUR plan-stage spine that turns a raw user goal into a concrete enterprise build blueprint before implementation starts.

## Problem
WALTEUR already has a strong evidence gate system, but the first generated contract can still be too generic. A valid scaffold can say "Deliver verified outcome" without forcing the exact user, workflow, surfaces, acceptance criteria, trust model, operating model, explicit cuts, and final delivery packet. That means later gates may prove artifact shape without forcing a vivid build target.

## Design
Add `walteur-kit/enterprise-blueprint.json`, validated by `walteur-kit/hooks/enterprise-blueprint-gate.sh` and `walteur-kit/schemas/enterprise-blueprint.schema.json`.

The blueprint is a plan-stage artifact that records:

- Raw user goal and upgraded enterprise goal.
- Primary user and owner or buyer.
- Jobs-to-be-done and current workaround.
- Artifact map across UI, API, workflow, document, data, AI, IaC, tests, and ops.
- Surface map for UI, API, data, jobs, docs, and ops.
- Acceptance suite with `AC-001` style IDs.
- Trust model, including auth, data, privacy, security, and auditability.
- Operating model, including observability, support, rollback, incident response, and ownership.
- Quality bar with concrete feel, anti-feel, reference quality, and concreteness floor.
- Explicit cuts with risk and review trigger.
- Final delivery packet requirements.

## Gate behavior
The new gate must:

- Return `NOT_APPLICABLE` when no meaningful build signal exists.
- Return `FAIL` when a selected or signaled build lacks a blueprint.
- Return `FAIL` for placeholder text, malformed JSON, restated goals, thin acceptance coverage, missing artifacts, missing trust or operating model, missing explicit cuts, missing final delivery packet, or fake evidence refs.
- Return `PASS` only when the blueprint is concrete enough to guide a build.

## Integration
- Register `enterprise-blueprint-gate` in `gate-registry.json` as a selected spec gate.
- Add it to `harness-init.sh` bootstrap files and selected verification commands.
- Generate a first-pass blueprint during scaffold.
- Add examples for a good blueprint and a vague blueprint.
- Add aggregate selftest coverage.
- Update README, kit README, and HARNESS-LOOP to document the new spine.

## Non-goals
- Do not replace the PRD, product standard, design contract, QA report, or terminal audit.
- Do not claim field-mile proof.
- Do not add a new daemon, package dependency, or runtime service.

## Verification
- Watch the new gate selftest fail before implementation.
- Implement the gate and schema.
- Run the new gate selftest.
- Run relevant schema and registry checks.
- Run aggregate `bash walteur-kit/selftest.sh`.
