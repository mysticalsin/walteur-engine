# Plan
<!-- SELFTEST BASELINE FIXTURE — not the framework roadmap.
     10+ gates read this file by name (design-depth-gate.sh, ship-gate.sh, scoreboard-gate.sh,
     nfr-lint.sh, spec-lint.sh, …) and a byte-identical copy lives at walteur-kit/PLAN.md.
     The real roadmap is the goal state under _agent_state/org-goal/.
     Kept as an HTML comment so no gate's line/section parsing is disturbed. -->
## Out of scope
- no auth in v1 (named non-goal)
## Success metric
- baseline 120ms; target p95 <= 50ms
## Tasks
- T1 parse input — Acceptance: Given empty input When run Then exit 0; p95 <= 50ms
