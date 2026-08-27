# HARNESS-100 — Pinned Scoring Rubric (do not edit mid-campaign)

> The definition of "every aspect" for goal-2026-07-03-harness-100. Panels are BLIND: fresh agents,
> no access to prior scores or to who fixed what. Maker never judges own work. Editing this file
> mid-campaign invalidates score comparability — bump `rubric_version` and restart the streak if changed.

rubric_version: 1
scale: 0–10 per dimension, one decimal. Anchors: 5 = solid OSS · 7 = strong professional ·
9 = industry-leading · 10 = strictly better than every named competitor (Anthropic harness
engineering, OpenAI Codex workflows, spec-workflow, OneRedOak, Palantir AIP-grade governance).
weighted_total: sum(score × weight) ÷ 10 → /100.

| # | Dimension | Weight | What 10/10 means |
|---|-----------|--------|------------------|
| 1 | oneshot | 15 | Vague prompt → enterprise-grade app end-to-end, zero hand-holding, evidence in field-runs |
| 2 | code | 12 | Harness's own hooks/scripts flawless: quoting, fail-modes, no duplication, no dead code |
| 3 | security | 12 | Fail-closed everywhere, supply chain + secrets + injection surfaces provably covered |
| 4 | design | 10 | Enforced bar is genuinely Apple-grade; gate detects mediocre design, not checklist theater |
| 5 | uxdx | 10 | Operator starts/stops/resumes friction-free; failures explain themselves; 15-min onboarding |
| 6 | memory | 12 | Provably learns from mistakes: capture-on-correction, recall-before-act, fresh baton, live graph |
| 7 | qa | 10 | Maker/checker separation, selftest AND real-file coverage, regressions locked, honest verdicts |
| 8 | orchestration | 7 | Right model per task, budget enforced, no wasted tokens, disciplined parallelism |
| 9 | reliability | 7 | Crash/stall recovery, drift detection, engine self-observability, honest PAUSED semantics |
| 10 | docs | 5 | Stranger (or another model) productive in 15 minutes; claims match shipped reality |

**Certification:** two CONSECUTIVE blind panels ≥98/100 weighted, no dimension <9.0,
plus one-shot drill green, plus fresh terminal audit PASS. A single ≥98 is not certification.

**Anti-inflation rules:** panels run as fresh agents with this file as their only scoring contract ·
evidence must be file:line-cited · a score without a cited basis is discarded and the dimension re-run ·
verifiers are prompted to refute, not confirm.
