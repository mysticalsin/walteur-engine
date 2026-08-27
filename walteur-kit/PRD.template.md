---
# WALTEUR PRD contract — the DISCOVER-phase artifact (walteur-discover §3).
# Machine-checkable frontmatter validated against walteur-kit/schemas/prd.schema.json.
# Enforced by prd-gate.sh (HARD existence/anti-stub for user-facing/new products, detect-or-SKIP).
# Write terse (caveman LITE). Markets/segments = problems/jobs, never demographics. Relative timeframes, never dates.
prd_version: 1
product: <name>
date: <run-date — bash: date -u +%Y-%m-%d>
outcome: <the ONE measurable result this moves — a metric, not a feature>
success_metrics:            # ≥1 required; each carries a number + unit. north-star + 1–5 leading inputs.
  - { name: "<north-star metric>", baseline: "<or —>", target: "<number+unit>", kind: north-star }
  - { name: "<leading input>",     target: "<number+unit>", kind: leading }
scope_ranked:               # ≥1 required; the prioritization output, top-N = the wedge (in_v1: true)
  - { item: "<feature/solution>", score_model: "RICE|ICE|OpportunityScore", score: 0.0, in_v1: true }
deprioritized:              # what was CUT and why (explicit — silent cuts are scope drift)
  - { item: "<feature>", reason: "<below the wedge line / unvalidated / out of scope>" }
assumptions:                # ≥1 load-bearing claim (the strategy-red-team output)
  - { claim: "<load-bearing assertion — false ⇒ the bet dies>",
      fails_if: "<concrete, falsifiable condition>",
      cheapest_test: "<smallest experiment that moves the belief>",
      kill_criterion: "<threshold at which to STOP or pivot>",
      confidence: "verified|assumed|unknown" }
stories:                    # ≥1; each story's acceptance criteria are the §5.4 QA test targets.
  # ACs SHOULD use EARS grammar (Mavis, Rolls-Royce): "WHEN <trigger> [WHILE <state>], THE <system>
  # SHALL <observable response>". EARS makes the trigger + response testable verbatim. Free-form ACs are
  # still ALLOWED (spec-lint only NUDGES, never blocks) — but an EARS AC is a ready-made §5.4 QA test.
  - { id: "STORY-1",
      jtbd: "When <situation>, I want to <motivation>, so I can <outcome>",
      acceptance: ["WHEN <trigger>, THE <system> SHALL <observable response> (incl. edge case)", "AC2 …"] }
benchmark_ref: walteur-kit/benchmark.md   # §2.0b best-in-class coverage (user-facing products)
---

# PRD — <product>

## 1. Summary
<2–3 sentences: what this is, for whom, the bet in one line.>

## 2. Background — why now?
<Context. What changed / what just became possible. Why this is worth doing now and not later.>

## 3. Objective + success metric tree
<The objective and why it matters to the user AND the business. The north-star metric + 1–5 leading
inputs that drive it (mirror `success_metrics` above; each a number+unit). How it ladders to strategy.>

## 4. Target user (JTBD + anti-persona)
<Who, framed as a job: "When [situation], they want to [motivation], so they can [outcome]." Drop the
demographic; anchor on the situation. **Anti-persona:** who this is explicitly NOT for (scope-bounding).>

## 5. Value proposition
<What-before (the user's current state/pain) → How (the mechanism) → What-after (the outcome) →
Alternatives (what they use today, and why this beats it). User outcome BEFORE the solution.>

## 6. Prioritized scope (the wedge)
<The `scope_ranked` table rendered: each item with its RICE/ICE/Opportunity-Score and v1 in/out.
Then the NOT-doing list (`deprioritized`) — what was cut and why. The wedge = the narrowest slice
that teaches the most, defensible by the score, not a vibe.>

## 7. Load-bearing assumptions (red-team — walteur-discover §4.3)
<The 3–5 ranked kill-assumptions. For each: Claim · Fails-if · Evidence-this-week · Kill-criterion ·
Cheapest-test · confidence(verified/assumed/unknown). Plus the §6 kill-or-proceed DECISION
(kill/pivot/proceed) and the cited result of any test already run. What's well-reasoned, stated plainly.>

## 8. Stories & acceptance criteria
<Each story (mirror `stories` above): JTBD line + 4–6 testable acceptance criteria (INVEST + 3 C's;
observable behaviours incl. edge/perf/a11y/integration). These are the §5.4 QA corps test targets and
the §4.1a PLAN task inputs — author them, do not assume they pre-exist.>

**Write ACs in EARS grammar** (Easy Approach to Requirements Syntax — Mavis/Rolls-Royce). EARS gives each
AC an explicit trigger and a single observable, testable response, so the QA corps can lift it verbatim:

- **Ubiquitous** — `THE <system> SHALL <response>.` (an always-true invariant)
- **Event-driven** — `WHEN <trigger>, THE <system> SHALL <response>.`
- **State-driven** — `WHILE <state>, THE <system> SHALL <response>.`
- **Unwanted/edge** — `IF <error/edge condition>, THEN THE <system> SHALL <response>.`
- **Optional** — `WHERE <feature is present>, THE <system> SHALL <response>.`

> Example. Free-form: "logins should be fast and handle bad passwords gracefully." → EARS:
> `WHEN a user submits valid credentials, THE auth service SHALL return a session token within 200ms.`
> `IF the password is incorrect, THEN THE auth service SHALL return 401 and SHALL NOT reveal which field failed.`
>
> Free-form ACs are still accepted — spec-lint R7 only *nudges* toward EARS (WARNING, never a block). But
> an EARS AC carries its own trigger+response, which is exactly what §5.4 needs to write the test.

---
*Fill this in DISCOVER (walteur-discover skill), reference it from PLAN.md's "Why" (never restate — spec
drift = rewrite), and anchor the §5.5 intended-vs-implemented audit to its documented intent. Mark every
claim verified / assumed / unknown; add [HUMAN/EXPERT REVIEW REQUIRED] where model competence ends.*
