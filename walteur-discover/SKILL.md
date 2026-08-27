---
name: walteur-discover
license: MIT
description: >-
  WALTEUR-DISCOVER v1.0 — the product-discovery companion to the WALTEUR build engine. Use for ANY work that
  decides WHAT is worth building and WHY, before a line of code: scoping a new product/feature, validating a
  bet, writing a PRD, framing the problem, prioritizing scope, red-teaming a plan's assumptions, deriving the
  success metric. Triggers: /discover, /prd, /red-team, "should we build this", "what should we build",
  "validate this idea", or WALTEUR reaching SCOPE on a new user-facing product. It runs SCOUT mode (discovery
  decisions + rationale, no build) or SPEC-AUTHOR mode (writes the project's PRD.md contract BEFORE any plan;
  prd-gate.sh enforces it), and closes discovery with a kill-or-proceed loop that falsifies the bet cheaply
  before spend. Companion skill — WALTEUR builds the thing right; WALTEUR-DISCOVER proves it is the right thing.
metadata:
  type: discovery-companion
  version: 1.0
  status: standing-companion
  pairs_with: walteur (build engine ≥ v9.0)
  sibling: walteur-design (design = how it LOOKS · discover = WHAT is worth building · walteur = HOW it is built)
  enforcement: "prd-gate.sh (HARD existence/anti-stub, detect-or-SKIP) + spec-lint R6 (PLAN Why→PRD ref) + spec-trace story-trace + Senior PM cite-or-VETO + §5.5 intent reconciliation"
  synthesizes:
    - mysticalsin/pm-skills (a fork of phuryn/pm-skills v2.0, MIT, Paweł Huryn / Product Compass) — the complete 9-plugin / 68-skill marketplace, installed at .agents/skills/; phuryn is the upstream author (honest provenance). The product-thinking spine below is adapted into WALTEUR's terse cite-or-veto idiom:
    - "  pm-product-discovery/opportunity-solution-tree (Teresa Torres OST — outcome→opportunities→≥3 solutions→experiments)"
    - "  pm-product-discovery/prioritize-features + pm-execution/prioritization-frameworks (Opportunity Score = Importance×(1−Satisfaction); RICE; ICE)"
    - "  pm-execution/strategy-red-team (load-bearing-assumption falsification — Fails-if / Cheapest-test / Kill-criterion)"
    - "  pm-product-discovery/brainstorm-experiments-new+existing (XYZ hypothesis · fake-door · technical spike · concierge — KILL a build cheaply before spend)"
    - "  pm-execution/create-prd (8-section PRD spine) + pm-execution/job-stories + user-stories (JTBD + INVEST + testable AC)"
    - "  pm-ai-shipping/intended-vs-implemented + ship-check (intent-on-record so §5.5 AUDIT can prove documented == implemented)"
    - "  pm-go-to-market/ideal-customer-profile + beachhead-segment (anti-persona / smallest-winnable scope-bounding)"
    - "  pm-product-strategy/value-proposition (Value Proposition Canvas — What-before/How/What-after/Alternatives, user-outcome-first)"
    - "  formula credit: Opportunity Score = Importance×(1−Satisfaction) is Dan Olsen, The Lean Product Playbook (OST tree structure = Teresa Torres)"
---

# WALTEUR-DISCOVER v1.0 — the discovery companion (Scout + Spec-Author)

> **WALTEUR builds the thing right. WALTEUR-DISCOVER proves it is the RIGHT thing — in writing, before the plan.**
> The front-funnel twin of plan-before-build: **NO PLAN WITHOUT A VALIDATED PROBLEM.**
> Most rework is not bad code — it is building the wrong thing, or an underspecified thing. This kills that class.

---

## 0. THE DISCOVERY LAW (HARD-enforced for user-facing / new products)

**Every new user-facing product (and any non-trivial new feature) ships a `walteur-kit/PRD.md` BEFORE the PLAN is signed.**
Enforced mechanically: `walteur-kit/hooks/prd-gate.sh` (dispatched by ship-gate, detect-or-SKIP) exit-2 blocks a ship while a product signal exists without a non-stub PRD. Non-stub floor = a problem statement + ≥1 target-user/JTBD + ≥1 success metric carrying a number+unit + a prioritized-scope section + a NOT-doing/out-of-scope section. A `touch PRD.md` does not satisfy the law. Detect-or-SKIP: typo / 1-line / pure-backend-CLI / brownfield-where-intent-already-exists → SKIP (recorded, never silent-green).

Why a file, not vibes: `PLAN.md` says HOW to build; `DESIGN.md` says how it LOOKS; **`PRD.md` says WHAT is worth building and WHY, and records the bet's load-bearing assumptions so §5.5 AUDIT can later prove documented == implemented.** Without the contract, the engine optimizes a build nobody validated — the most expensive slop there is.

**Honesty (§1):** the gate is HARD on the PRD's *existence and non-stub shape*. Whether the bet is actually *right* is PROTOCOL — the red-team kill-criteria (§4.3) and the Senior PM cite-or-VETO are the real safeguard. Never present a green prd-gate as proof the bet is sound.

## 1. THE TWO MODES (never blur them — mirrors walteur-design's Consultant/Craftsman split)

| Mode | Output | When |
|---|---|---|
| **SCOUT** | discovery decisions + rationale + the falsified/surviving assumptions. **ZERO build, ZERO plan.** | "should we build this?", "what should we build first?", validating a bet, a real fork in problem framing, pre-PLAN advice to the senior panel |
| **SPEC-AUTHOR** | the `PRD.md` contract, written to schema (§3) | after the bet survives the §6 kill-or-proceed loop — author the PRD the PLAN will reference |

Scout recommends; Tony (or the WALTEUR Chief on autopilot) decides; Spec-Author writes it down. A Spec-Author who discovers the bet is unvalidated mid-write must STOP and re-enter Scout mode — never paper over an unfalsified assumption with PRD prose.

## 2. DISCOVERY PRE-FLIGHT (before writing the PRD — commit to a SHARP bet)

Answer as ONE batch (omit any already given), write the answers into the PRD's Background + Objective:
1. **Outcome** — the ONE measurable result this is supposed to move (a metric, not a feature). The top of the opportunity tree (§4.1).
2. **Target user + job** — JTBD form: *When [situation], they want to [motivation], so they can [outcome]*. Drop the demographic; anchor on the situation. Name the **anti-persona** (who it is explicitly NOT for) — scope-bounding beats scope-creep.
3. **Riskiest assumption** — the single load-bearing claim that, if false, kills the whole bet (§4.3). If you can't name one, you haven't thought hard enough yet.
4. **The wedge** — the narrowest genuinely-shippable slice that teaches the most (the top of the §4.2 prioritization, not a vibe pick).
5. **Kill-criterion** — the threshold at which you'd STOP or pivot. A bet with no kill-criterion is a belief, not a plan.

Skipping pre-flight = building a confident answer to an unvalidated question. `/adhd` the problem framing if it genuinely forks; real forks → WALTEUR §5.3 debate → ADR.

## 3. THE PRD.md CONTRACT (create-prd 8-section spine, compressed to WALTEUR's terse standard)

Structure — YAML machine-checkable frontmatter (validated against `walteur-kit/schemas/prd.schema.json`) + 8 prose sections. Write in caveman LITE (grammar intact, no filler). Markets/segments are defined by people's PROBLEMS/JOBS, never demographics. Timeframes are relative, never exact dates.

```markdown
---
prd_version: 1
product: <name>
date: <run-date>
outcome: <the one measurable result>
success_metrics:            # each carries a number + unit (north-star + 1–5 leading inputs)
  - { name: "activation rate", baseline: "—", target: "40%", kind: north-star }
  - { name: "time-to-first-value", target: "< 5 min", kind: leading }
scope_ranked:               # the prioritization table, top-N is the wedge
  - { item: "<feature>", score_model: "RICE", score: 8.4, in_v1: true }
deprioritized:              # what was CUT + why (explicit; gold-plating guard)
  - { item: "<feature>", reason: "below the wedge line" }
assumptions:                # the red-team output — each load-bearing claim
  - { claim: "activation is the constraint", fails_if: "users churn at onboarding not activation",
      cheapest_test: "5 user-session replays", kill_criterion: "<2/5 reach first value" }
stories:                    # job/user stories, each with testable acceptance criteria
  - { id: "STORY-1", jtbd: "When <situation>, I want <motivation>, so I can <outcome>",
      acceptance: ["AC1 …", "AC2 …"] }
benchmark_ref: walteur-kit/benchmark.md   # §2.0b best-in-class coverage
---
1. Summary (2–3 sentences)          5. Value Proposition (What-before / How / What-after / Alternatives)
2. Background — why now?            6. Prioritized Scope (the table + the NOT-doing list)
3. Objective + success metric tree  7. Load-bearing Assumptions (the red-team table — §4.3)
4. Target user (JTBD + anti-persona) 8. Stories & Acceptance Criteria (→ §5.4 QA test targets)
```

Rules: every section ladders back to the outcome (a section that doesn't is cut). Assumptions are flagged explicitly so they can be validated (§4.3–4.4), never buried as fact. Stories' acceptance criteria ARE the QA corps's test targets (§5.4) and the §4.1a PLAN inputs — author them, never assume they pre-exist.

*Source note (§1 faithfulness): the 8-section spine is **create-prd**; the value-prop micro-structure (What-before → How → What-after → Alternatives) is the **pm value-proposition** skill / Value Proposition Canvas, NOT create-prd's §6 (which uses the Value Curve / jobs-pains-gains framing). Opportunity Score is Olsen (§4.1).*

## 4. THE METHOD (the discovery pipeline — what SCOUT runs, in order)

The ordering is the point: frame the opportunity, rank it, falsify the bet, test the cheapest kill-assumption, THEN author the PRD. Skipping to the PRD is how you write a confident spec for the wrong thing.

### 4.1 OPPORTUNITY FRAMING (Teresa Torres opportunity-solution-tree)
One measurable **outcome** on top → **opportunities** = customer pains/problems, NEVER features → **≥3 candidate solutions per opportunity** (compare-and-contrast beats the first-idea trap) → cheap **experiments** at the leaves. Rank opportunities by **Opportunity Score = Importance × (1 − Satisfaction)** (the upper-left quadrant; the formula is **Dan Olsen, *The Lean Product Playbook*** — the OST tree structure is Torres, the scoring formula is Olsen). Prioritize PROBLEMS, not features; never let the requester's named feature skip the problem it serves.

### 4.2 PRIORITIZE THE SCOPE (prioritize-features + prioritization-frameworks)
Replace "pick the wedge" vibe-ranking with math. Score candidate solutions/features by **RICE = (Reach × Impact × Confidence) / Effort** (teams) or **ICE = Impact × Confidence × Ease** (quick). The wedge = the top-N. **Always record what was CUT and why** (the `deprioritized` list) — an unstated cut is silent scope drift. Kano only for understanding expectations, never for ranking.

### 4.3 RED-TEAM THE BET (strategy-red-team — this is WALTEUR's fork-debate made rigorous, upstream of build)
A red-team is not a pre-mortem: it attacks the load-bearing assumptions **now**, while the cheapest test still has time to run.
1. **Extract every claim** the bet asserts (user/market/constraint/mechanism/timeline). Keep only **load-bearing** ones — *if false, the bet dies*. Drop cosmetic claims.
2. **Steelman, then attack the steelman** — never a strawman. An attack on a weak version is worthless.
3. Write each failure mode as **"Fails if ___"** — concrete and falsifiable ("Fails if activation isn't the constraint" ≫ "execution risk").
4. **Rank by (impact if wrong) × (likelihood wrong) × (cheapness to test).** Surface the ranking; don't bury the lede.
5. **Self-refute, don't fabricate** — default "this risk is real" unless the bet already cites evidence against it; but if a claim is genuinely sound, say so plainly. A red-team that manufactures doubt is as useless as one that rubber-stamps.
6. For each surviving kill-assumption, hand the operator: **Fails-if** · **Evidence to get this week** · **Kill-criterion** (the threshold to stop/pivot) · **Cheapest test**. 3–5 max — five real kill-assumptions with tests beat twenty generic risks.

### 4.4 CHEAPEST-VALIDATION → KILL or PROCEED (brainstorm-experiments — the gate WALTEUR never had)
For the top kill-assumptions, run the **cheapest test that moves the belief BEFORE committing build budget**: fake-door, landing page / waitlist, technical spike, concierge/Wizard-of-Oz, first-click prototype. State each as an **XYZ hypothesis — "at least X% of Y will do Z"** with a success threshold. **Measure behavior, not opinions** (Savoia's *The Right It*: Skin-in-the-Game > stated interest; Your Own Data > others'). If the test fails the kill-criterion → **KILL or pivot the bet** and say why; the cheapest honest "no" is the highest-leverage output discovery produces. Only a surviving bet PROCEEDS to PRD authoring + PLAN.

### 4.5 STRUCTURED SPRINT (optional accelerated cadence — when the founding bet must lock in days, not continuously)
§4.1–4.4 is the *continuous* discovery pipeline (run it in order, any time). When a NEW product needs its founding bet locked fast — the $100M-north-star "give it an objective → lock what's worth building" kickoff — pack the same activities into one of two time-boxed sprints. A sprint is a *cadence for §4.1–4.4*, never a replacement and never a gate: it still terminates in the §6 kill-or-proceed loop and a `PRD.md`.
- **Foundation Sprint** (Knapp & Zeratsky, *Click*; 2-day, founder-level): **basics** (customer · problem · advantage) → **differentiation** (the 2×2 vs the best alternative — feeds the §4.2 wedge) → **approach options** → **magic-lenses** vote → one **founding hypothesis**: *"If we help [customer] solve [problem] with [approach], they choose us over [alt] because [differentiation]."* That hypothesis IS the bet §4.3 red-teams and the claim the PRD §3 objective ladders to.
- **Design Sprint** (Knapp, *Sprint*; 5-day Mon→Fri): map → sketch → decide → prototype → test-with-5-users. Reach for it when the *solution* (not the bet) is the risk and a clickable prototype is the cheapest §4.4 test; output = first-click/concierge evidence into the PRD §7 assumptions table.
Reach for a sprint when discovery is the bottleneck and stakeholders are co-available; otherwise run §4.1–4.4 continuously. *(Source: Knapp/Zeratsky + AJ&Smart sprint methods; move-sequence absorbed from product-on-purpose/pm-skills, Apache-2.0. Prose only — no second index, one-brain intact.)*

## 5. ANTI-SLOP TABLE (instant Scout VETO — the front-funnel twin of walteur-design's anti-slop)

| PM-slop signature | Instead |
|---|---|
| persona by demographics ("35-yo urban professional") | JTBD: *When [situation], wants [motivation], so [outcome]* + an anti-persona |
| feature list presented as a strategy | outcome → opportunities → ranked solutions (§4.1–4.2); state the trade-off / what we will NOT do |
| vanity / output metric ("ship 10 features") | a customer-centric outcome metric + leading inputs, each with a number+unit |
| unfalsifiable assumption ("users will love it") | "Fails if ___" + a cheapest test + a kill-criterion (§4.3) |
| "research shows users want it" with no citation | cited evidence, or label it ASSUMED and route to §4.4; absence of evidence ≠ evidence (§1) |
| solution-first value prop | What-before → How → What-after → Alternatives (user outcome before the solution) |
| roadmap with exact dates | relative timeframes (v1 vs future); dates rot |
| "build everything" scope | the wedge = top-N of the §4.2 ranking + an explicit deprioritized list |
| skipping the cheapest test to "just build it" | KILL-or-PROCEED gate (§4.4) — falsify before spend |

Match rigor to domain: regulated/money/health bets get a harder red-team and a [HUMAN/EXPERT REVIEW REQUIRED] marker where model competence ends (WALTEUR §1).

## 6. THE KILL-OR-PROCEED LOOP (closes EVERY discovery — no exceptions)

```
FRAME → RED-TEAM → CHEAPEST-TEST → DECIDE(kill | pivot | proceed) → EVIDENCE
```
1. **FRAME** — outcome → opportunities → ranked scope (§4.1–4.2).
2. **RED-TEAM** — surface the load-bearing assumptions, ranked (§4.3).
3. **CHEAPEST-TEST** — run the smallest experiment that moves the top kill-assumption (§4.4); measure behavior.
4. **DECIDE** — against each kill-criterion: KILL (and say why), PIVOT (re-frame), or PROCEED. Default to honesty over momentum.
5. **EVIDENCE** — the decision + the test result + the surviving assumptions go in `PRD.md` §7. "We validated it" with no cited test = an overclaim (WALTEUR §1).

## 7. PRE-PLAN DISCOVERY QA (the checklist — priority-ordered; Scout's self-critique before the Senior PM gate)

| Priority | Check |
|---|---|
| CRITICAL | a measurable outcome (not a feature) · ≥1 load-bearing assumption named with a kill-criterion · the bet survived (or was killed by) a cheapest test · a NOT-doing/out-of-scope list exists |
| HIGH | success metric carries a number+unit · scope is the top-N of a recorded RICE/Opportunity-Score ranking · every story has testable acceptance criteria · target user in JTBD form + anti-persona |
| MEDIUM | value prop is user-outcome-first (What-before/after) · benchmark.md referenced (§2.0b) · assumptions split verified / assumed / unknown |
| LOW | relative timeframes only · opportunities ranked, not just listed |

Run before the WALTEUR Senior PM review — this checklist is Scout's self-critique; the Senior PM's cite-or-VETO is the independent gate.

## 8. INTEGRATION MAP (how this composes with WALTEUR v9.0)

| WALTEUR piece | WALTEUR-DISCOVER role |
|---|---|
| §2 SCOPE / §2.5 DISCOVER | this skill IS the §2.5 DISCOVER phase — runs after the §2.0b benchmark, before §2a scoping / §4 PLAN |
| §2.0b best-in-class benchmark | feeds the value prop + the differentiation thesis; the PRD references `benchmark.md` |
| gate-guard (plan-before-build) | **prd-gate.sh is its front-funnel twin** (HARD existence/anti-stub, detect-or-SKIP) — the design twin is design-gate.sh |
| §4.1 PLAN design doc | the doc's "Why" CITES `PRD.md` (never restates — spec drift = rewrite); §4.1a stories + §4.2a prioritization come from the PRD |
| spec-lint R6 / spec-trace story-trace | mechanical checks that PLAN's Why references the PRD and every PRD story traces to a task |
| Senior PM (§5) cite-or-VETO | independent review of PRD quality, prioritization defensibility, story→AC coverage |
| §5.3 debate → ADR | a real problem-framing fork (two surviving bets) gets debated, not averaged |
| §5.4 QA corps | the PRD's stories + acceptance criteria ARE the QA test targets (test the LOGIC, not just the code) |
| §5.5 terminal AUDIT | the intended-vs-implemented pass anchors to the PRD's documented intent (intent on record) |
| /adhd | problem-framing ideation when the pre-flight forks |

## 8a. CHAINED PM SKILLS (net-new beyond the front-funnel slice)

The full mysticalsin/pm-skills marketplace (9 plugins / 68 skills, installed at `.agents/skills/`) is available. Beyond the front-funnel slice already wired into §4–6 above, DISCOVER can chain these in SCOUT or SPEC-AUTHOR mode when the Design Read calls for it:

| Group | Chainable skills |
|---|---|
| **Market-research** | `competitor-analysis` · `user-personas` · `market-sizing` · `customer-journey-map` · `market-segments` |
| **Product-strategy** | `value-proposition` · `product-strategy` · `product-vision` · `lean-canvas` · `pricing-strategy` |
| **Product-discovery** | `interview-script` · `identify-assumptions-new` · `identify-assumptions-existing` · `brainstorm-ideas-new` · `brainstorm-ideas-existing` · `brainstorm-experiments-new` · `brainstorm-experiments-existing` · `summarize-interview` · `analyze-feature-requests` |
| **AI-shipping** | `shipping-artifacts` |
| **Execution** | `outcome-roadmap` · `stakeholder-map` · `test-scenarios` · `brainstorm-okrs` |

**Scope boundary (anti-bloat / one-skill-per-lane):** the marketing-growth plugin (`growth-loops`, `gtm-motions`, `gtm-strategy`, `north-star-metric`, `launch-strategy`, `referral-program`, `multi-brand-campaign`, `seo-commander`, `cold-outreach`) and the go-to-market plugin (`beachhead-segment`, `ideal-customer-profile`, `positioning-ideas`, `marketing-ideas`, `lead-magnet-manager`) are installed and available but OUT of WALTEUR-DISCOVER's default chain. WALTEUR builds; the §3.L optional GTM brief in walteur's pipeline is the one boundary touch (opt-in, never a gate). DISCOVER does not chain marketing/growth/GTM skills by default — invoke them directly when explicitly needed.

## 9. SCALING (don't run full discovery for a typo)

| Job | Discovery overhead |
|---|---|
| typo / 1-line / pure-backend-CLI | none — prd-gate SKIPs (no product signal) |
| brownfield where intent already exists | confirm against existing intent; PRD optional (recorded SKIP), red-team only the changed bet |
| small feature on a user-facing product | light: §2 pre-flight + §4.3 red-team of the riskiest assumption + a thin PRD section |
| new feature, real user impact | §4.1–4.4 full + PRD + Senior PM sign-off |
| new user-facing product | full pre-flight → §4 method → §6 kill-or-proceed → PRD.md → Senior PM sign-off → PLAN |

On `full_autopilot` the Chief self-signs the PRD exactly as it self-signs the PLAN (§2a) — DISCOVER adds rigor, not a human stop, except the existing §10 Tony-only forks (taste / irreversible spend / security floor / external-money).

---

*Provenance: synthesizes mysticalsin/pm-skills (a fork of phuryn/pm-skills v2.0, MIT, Paweł Huryn / Product Compass) — the complete 9-plugin / 68-skill marketplace, installed at `.agents/skills/`; phuryn is the upstream author — opportunity-solution-tree, strategy-red-team, prioritize-features, prioritization-frameworks, brainstorm-experiments, create-prd, job-stories, user-stories, intended-vs-implemented, ship-check, ideal-customer-profile, beachhead-segment — adapted into WALTEUR's terse, evidence-backed, cite-or-veto idiom (never raw PM prose). Sibling of walteur-design v1.0 (design = how it looks; discover = what's worth building; walteur = how it is built). By Tony Walteur.*
