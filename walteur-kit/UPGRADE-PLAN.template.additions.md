# UPGRADE-PLAN additions (§2.6 BROWNFIELD UPGRADE)

These fields are ADDED to every `PLAN.md` task on a brownfield `/upgrade` run — on top of the normal §4.2
task matrix (`What` · `Acceptance` · `Model` · `Blocker` · `Sign-off`). They make an upgrade task provably
*safe* (it cannot silently regress) and *measured* (it names the dimension it lifts and by how much). The
greenfield PLAN template is unchanged; this is the brownfield delta.

## Per-task additions

```
Task N: [VERB] [object] — [success metric]
  What: exact command / file / expected output     Acceptance: testable binary outcome
  Model: sonnet | opus (tag security/arch/hard)
  Sign-off: self | code-review | QA | security | PM
  ── brownfield delta ───────────────────────────────────────────────────────────────
  Lifts: <dimension> from <baseline score> → <target score>   (cites walteur-kit/baseline.json)
  Tier: refine-in-place | modernize | re-architect            (the safest tier that achieves the lift)
  Non-regression AC: <the characterization/golden-master assertion that must STAY green after this task>
  Behavior change: none | <what observable behavior changes> → signed ADR walteur-kit/adr/<id>
  Preserves intent: <which INTENT.md claim/job this task keeps intact (or extends)>
```

## The three tiers (auto-picked: the safest tier that achieves the lift)

| Tier | What it allows | Default for | Proof obligation |
|---|---|---|---|
| **refine-in-place** | harden, secure, complete, polish — NO structural change | most tasks | golden-master green; behavior identical |
| **modernize** | upgrade stack/deps/idioms; swap an impl behind a stable interface | stale stack, dead deps, deprecated APIs | golden-master green; interface contract unchanged |
| **re-architect** | restructure modules / change a contract | only where the lift is impossible in-place | golden-master green OR a signed behavior-change ADR + migration |

**Behavior is preserved by default.** A task that changes observable behavior is NOT forbidden — it is *gated*:
it must name the change and carry a **signed ADR** (`walteur-kit/adr/*`). The non-regression gate FAILS on any
behavior change without one. This is what lets `/upgrade` go as far as `re-architect` while staying safe.

## The non-regression contract (every task obeys it)

1. The task's `Lifts:` dimension MUST end `after >= before` (the baseline score is the floor) — proven by
   `non-regression-gate.sh` at ship.
2. NO OTHER dimension may drop (a security fix that tanks perf is not a clean lift) — the gate checks ALL
   baseline dimensions, not just the one this task targets.
3. The characterization/golden-master net stays green every wave — a red net halts the wave (Iron Law 4:
   no fix without root cause).
4. Cross-cutting symbol edits record callers in `walteur-kit/blast-radius.json` — the existing
   `blast-radius-gate.sh` (HARD on brownfield high/regulated) enforces it.

*Authored alongside PLAN.md on a `/upgrade` run. The RICE-ranked source backlog lives in
`walteur-kit/upgrade-backlog.json`; each in-scope item becomes a task carrying these fields.*
