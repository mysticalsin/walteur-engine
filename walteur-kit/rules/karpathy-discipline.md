# Rule — Karpathy Discipline (the LLM-coding-pitfall delta, per-change)

> PROTOCOL rule (judgment, not a hook). Pure-prompt: zero infra, zero deps. The agent obeys it; nothing
> mechanically enforces it. Lifted from the karpathy-guidelines skill (MIT; Andrej Karpathy's LLM
> coding-pitfall observations, multica-ai/andrej-karpathy-skills lineage) — adapted to WALTEUR as
> DELTA-ONLY: each section adds what no existing surface states; existing surfaces are cited, never
> restated.

## 1. SURFACE confusion per-decision, not just per-phase. Hiding confusion is a defect.

§2 surfaces assumptions at intake; §5.3/§10 catch forks and blockers. This rule covers the gap between
them: an ambiguity, interpretation choice, or felt confusion discovered MID-BUILD — too small to be a
fork, not yet a blocker — is named in the turn it arises. Options + a recommendation; the chosen
assumption appended to PLAN.md §Design doc (§2a's existing destination — the mid-build TIMING is the
delta). Never silently guessed past.

- The named anti-pattern: proceeding while confused, where the confusion never becomes a blocker —
  that is how wrong builds ship green. Quiet confusion = surface it NOW.
- Source override, named: the source says "if unclear, stop and ASK"; on autopilot, §2a's
  pick-simplest-defensible-and-record supersedes the ask — the RECORD is then mandatory, not optional.
- Simpler-than-the-ask duty: when the REQUESTED approach is more complex than the job needs, say so
  BEFORE implementing. (Complements §2.5 DISCOVER / blueprint — those raise the bar of the right
  build; this challenges accidental complexity in the ask itself. Never a lever to lower THE BAR.)
- Escalates past one turn → the existing routes: §5.3 /debate→ADR · §10 stop-conditions.

## 2. PROHIBIT the three speculative classes, per-change — not only at terminal audit.

§6.1 owns "simplicity first (50 ≫ 200 lines)". The delta — three defect classes no surface names:

- NO abstraction for single-use code. Inline until a second real caller exists.
- NO unrequested flexibility/configurability — speculative config options, plugin points, generic
  parameters, extension hooks nobody asked for.
- NO error handling for impossible scenarios. This is §6.1 "boil the lake" read correctly:
  completeness = handling REAL edge cases; simplicity = refusing imaginary ones. Both laws hold.

Run the check at the TDD REFACTOR step inside every §3 BUILD pass (pre-commit), not only at the
terminal audit. Boundary: simplicity constrains the CODE, never the signed scope — scope moves only
via the §5.3/benchmark machinery. Mechanical backstops: dead-code-gate · maintainability-gate.

## 3. WALK the diff before commit. Mention, don't delete.

§6.1 owns "surgical", "match style", and "orphan-cleanup only your own dead code". The operational
delta:

- PRE-COMMIT DIFF WALK: §6.1's "every line traces" run as a procedure — hunk-by-hunk over the final
  diff; every hunk traces to the request or is an orphan YOUR change created; anything else → revert
  before commit.
- MENTION, DON'T DELETE: pre-existing dead code or unrelated flaws noticed en route get one line in
  the reply or `_relay/ISSUES.md` — never silent-delete, silent-fix, or silent-ignore.
- Brownfield + dead-code-gate (Knip default max=0 sees ALL dead code, not just yours): baseline the
  pre-existing findings; hold yourself to net-new orphans only.
- §6.1's "match style" means: surrounding-file conventions (naming, error style, import order,
  comment voice) beat your preferred idiom; a style migration is a scope change → §5.3, not a
  drive-by.

## 4. REWRITE every task into a verifiable goal — below the HOOK threshold too.

§16: protocols always apply; only the HOOKS (gate-guard · tdd-guard · prompt-refinement ·
test-claim-verifier · excellence-loop) stop firing below the build tier. The delta — where only
PROTOCOL binds (quick fix, refactor, conversational ask):

- INTAKE MOVE, every task, any tier: rewrite it into a verifiable goal with a binary check. Bug →
  repro-first per the TDD iron law (§6.1 / Iron Law 2). Refactor → same tests green before AND
  after — run the BEFORE pass yourself; no baseline, no refactor.
- Multi-step sub-hook work states the inline micro-plan: `[step] → verify: [check]`.
- BEFORE looping autonomously, test your own success criterion: machine-checkable? "Make it work" is
  not — strengthen it, or ask one clarifying question (house norm: at most one) BEFORE starting the
  loop, not during. Weak criteria force clarification round-trips; strong criteria are what EARN
  independent looping.

---
*Provenance: karpathy-guidelines SKILL.md (MIT) — think-before-coding / simplicity-first /
surgical-changes / goal-driven-execution, from Andrej Karpathy's LLM coding-pitfall observations
(x.com/karpathy/status/2015883857489522876); multica-ai/andrej-karpathy-skills is the pinned
source-manifest entry. Promoted 2026-07-11 on explicit user request — a user-request override of the
manifest promotion_policy's default trigger (concrete local failure), recorded in adopted_surface.
Tradeoff inherited from the source: biases caution over speed — for trivial tasks, judgment. Adapted
delta-only against WALTEUR §2/§2a/§3/§5.3/§6.1/§10/§11/§16 + the dead-code / maintainability gates
(4-agent coverage map + 2-agent adversarial verify, 2026-07-11). PROTOCOL, not HARD — no hook
enforces this; it is an operating discipline.*
