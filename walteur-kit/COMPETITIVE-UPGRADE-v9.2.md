# WALTEUR — Competitive Upgrade Analysis (v9.2 candidate roadmap)

**Date:** 2026-06-20 · **Method:** 14-agent workflow (6 understand → 5 gap-analyze → 3 synthesize, ~1.3M tokens).
**Sources compared:** `ChristopherKahler/paul` (Plan-Apply-Unify Loop) · `Pimzino/claude-code-spec-workflow` · `OneRedOak/claude-code-workflows` · `poshan0126/dotclaude` · Palantir AIP "End-to-End Agentic Architecture".

> Honesty law: every "WALTEUR already has X" below was checked against the inventory the workflow built from the actual repo, not asserted. Items marked *verified* were grep/cmp-confirmed in the run.

---

## Verdict

WALTEUR is clearly **AHEAD** on: 7-senior cite-or-veto review panel + a QA corps that tests logic (not just code); de-circularized real-signal eval with good/poisoned twins; cross-MODEL `_relay/` resume; files-as-state-machine over a STATE.json; a self-improving lessons loop with bi-temporal supersede; and a deliberate file-scale/portable posture that *correctly* cedes hosted-runner / vector-index / runtime-RBAC to platform scope.

WALTEUR is genuinely **BEHIND** in four converged areas (every source pointed at some subset):

1. **Observability of the engine itself** — no queryable per-phase execution-SPAN trace. `estimate.json`/`pending-feedback.jsonl` capture coarse cost + outcomes, not per-phase/per-tool/per-gate spans.
2. **Failure handling is structurally code-fix-biased** — a RED gate routes straight into REFINE with no Intent/Spec/Code branch at any iteration; the "3+ fails = redesign" rule is a *code-architecture* redesign, never a spec/PRD re-derivation. "Was the bet/spec wrong?" is never asked in the loop.
3. **Per-spawn context cost** — each isolated agent re-derives the same domain semantics from scratch; no frozen brief.
4. **Enforcement gaps** — load-bearing mandates (org-confidentiality-guard, graphify-first recall) are still PROTOCOL; nothing HARD enforces them.

**Single most important behavioral upgrade:** the failure-triage router (#1). **Critical sequencing:** build the run-trace spans (#2) *first* — it is #1's measurement precondition; shipping the router with no way to prove it cut wasted cycles would violate WALTEUR's own "prove it, don't assert it" law.

---

## The five sources at a glance

| Source | Thesis | What WALTEUR takes |
|---|---|---|
| **paul** (Plan-Apply-Unify) | Quality over speed; *in-session context over subagent sprawl*; fights context-rot | Failure-triage instinct; frozen briefs; spawn-justification (measure, don't slash); merge-base diff; `BATON.md` handoff hints |
| **spec-workflow** (Pimzino) | Requirements→Design→Tasks→Impl on rails; real-time dashboard; bug-fix loop | Optional read-only file viewer over existing state; EARS-format ACs. (Reject: per-task hard-stops, doc-graders) |
| **OneRedOak** | Battle-tested startup configs; dual-loop (slash + GitHub Actions); Playwright design-review | Playwright console+network as standard QA evidence; CI jobs (twin-invariant, token-budget). (Reject: hosted PR-bot, "Net Positive>Perfection", confidence-8 magic number) |
| **dotclaude** (poshan) | Lean `.claude/`; plugin marketplace; evidence-based installer; silent-failure-hunter | Plugin/marketplace distribution; silent-failure lint rules; house-contract "what NOT to flag" per rubric; context-budget CI |
| **Palantir AIP** | 12-component enterprise agentic platform | run-trace observability; model-catalog; ontology-lite glossary; per-agent tool allowlists. (Reject as platform-scale: gateway, vector services, runtime RBAC) |

---

## Top 14 ranked upgrades

> Effort S/M/L · Impact high/medium. Sequencing: **#2 before #1**; **#3 before #10**; **#4 & #5 share one prerequisite** (teach org-confidentiality-guard to emit a pass-stamp file).

| # | Upgrade | Eff/Imp | Where it plugs in |
|---|---|---|---|
| 1 | **Failure-triage router** — on a RED gate, classify Intent / Spec / Code before REFINE. Intent→re-DISCOVER (through a human pause-seam), Spec→edit PLAN/PRD + re-derive, Code→existing REFINE. Default Code on ambiguity; force Intent/Spec only on 2nd consecutive same-gate fail. | M/high | §3.x refine loop + walteur.js RED-gate handler |
| 2 | **`run-trace.jsonl`** — one append-only span per phase/tool/gate `{ts,phase,model,tool,exit_code,gate_verdict,tokens(labeled estimate)}`. `/trace` cmd + eval reads it. Derive `usage.jsonl` from spans (don't double-log). **Build first.** | M/high | walteur.js dispatch points; feeds eval/ab-bench.sh |
| 3 | **Frozen per-task briefs** — `briefs/<task-id>.md` = PRD slice + design slice + ACs + owned-files, mtime-invalidated. Each spawn reads its brief, stops re-deriving the full PRD/PLAN. | M/high | §5.6 swarm wave design |
| 4 | **`confidentiality-gate.sh`** — HARD egress gate; fail-closed blocks external artifacts lacking a org-confidentiality-guard pass-stamp. Egress twin of the existing at-rest `compliance-gate.sh`. | M/high | ship-gate dispatch |
| 5 | **Skill-invocation enforcement** (`skill-readiness.sh`) — block ship if a declared-required skill (confidentiality-guard, graphify-recall) left no invocation breadcrumb. | M/high | ship-gate + final-auditor |
| 6 | **Per-task reconciliation ledger** — one line per task/wave: PASS / GAP / DRIFT / DONE_WITH_CONCERNS / BLOCKED. No line = ship blocked. DRIFT/concerns read first by QA. | M/high | §5.6 wave completion + ship-gate |
| 7 | **`twin-invariant.sh`** — CI guard asserting SKILL.md ≡ WALTEUR-builder-CLAUDE.md (verified byte-identical today, 118.1K) + rubric house-contracts present + relay mirrors in sync. Regression-catcher. | S/high | eval/ + CI |
| 8 | **merge-base diff scoping** — reviewers receive `git diff --merge-base origin/HEAD` (working-tree fallback). Quick win. | S/medium | §5.2a blind-diff + §5 panel |
| 9 | **ontology-lite** — file-scale typed entity glossary (`ontology.json`) gates lint against; NOT a second index (graphify stays the brain). Brief's shared vocabulary. | L/medium | walteur-discover output; panel/QA/intent-auditor |
| 10 | **Spawn-justification discipline** — 6-criteria check before fan-out; measure spawn ROI via run-trace. *Never* applies to governance panel/auditor/security-floor. NB: the "use subagents liberally" line is in Tony's **personal global CLAUDE.md**, not WALTEUR — do not silently edit it. | L/medium | §5.6 / walteur.js only |
| 11 | **Isolated security re-prosecutor** — second isolated pass re-prosecutes each finding; demotes any that can't cite both sides + a named >0.8-exploitability path. Rejects the literal "confidence 8" scalar. | M/medium | §5.4 QA Security dimension |
| 12 | **Scope-adaptive graded ceremony** — classify quick-fix / standard / complex; quick-fix runs the SAME loop at compressed PROTOCOL fidelity but still passes ALL hard gates. | M/medium | walteur.js entry routing |
| 13 | **silent-failure-lint** — extend resilience-lint past empty-catch: R6 indistinguishable-fallback, R7 `||true`/missing `set -e`, R8 floating promises. Warning-first → HARD after twin-proof. | M/medium | resilience-lint.sh + ast-grep-rules |
| 14 | **Provably read-only reviewers** — POPULATE the per-agent `allowed-tools` field (schema already exists §5.2) so reviewers are host-enforced non-mutating. | M/medium | .claude/agents/specialists/ |

---

## Tools beyond skills (7)

1. **Playwright MCP** — make `browser_console_messages` + `browser_network_requests` a *standard* evidence source for Security/Logic QA, not just walteur-design. (Already wired in `.mcp.json`.)
2. **GitHub Actions** — new jobs on existing SHA-pinned CI: `twin-invariant.sh`, a `token-budget.sh` over always-loaded surface (dotclaude pattern), and a **macOS leg** to catch GNU-vs-BSD awk/sed divergence in the bash hooks. *Not* a hosted PR-bot.
3. **claude-api skill** — the model-ID authority; `model-catalog.json` is unbuildable without it (ai-safety-gate R3 vetoes hardcoded `claude-*` literals).
4. **`model-catalog.json`** — upgrade static `model-routing.json` into a budget-aware catalog with enablement/cost/latency tags; a PreToolUse shim refuses disabled/deprecated models and auto-downgrades against the `MAX_BUILD_COST_USD` ceiling.
5. **`.claude-plugin/marketplace.json`** over a **symlink monorepo** — one source-of-truth tree kills the two-copy spec/canonical maintenance burden and makes #7 trivial; companions become independently semver'd plugins. *Validate OneDrive symlink portability first.*
6. **ast-grep** (already a pillar) — back the new silent-failure rules (#13) structurally, not via fragile grep.
7. **Optional read-only viewer** over `walteur-kit/` + `_relay/` + `run-trace.jsonl` — spec-workflow's decoupled-dashboard insight, at file-scale. Strictly read-only, on-demand, never a dependency.

---

## Explicitly rejected (9) — gaps by design, not by omission

- **Hosted model gateway + always-on trigger plane + live PR-comment bot** — platform-scale + needs stored keys; WALTEUR deliberately declined the @-mention bot for portability. Scheduling already exists via the CC harness.
- **Vector / embedding / OSDK retrieval substrate** — violates the one-brain law. qdrant MCP was literally on the bench in this environment and consciously declined; v10 routes semantic recall *through* a graphify extension.
- **Runtime RBAC / marking / purpose-based access control** — unenforceable by a prompt framework = paper control, worse than the gap. (Contrast #14, which IS host-enforceable.)
- **"Net Positive > Perfection" velocity ethic** — direct conflict with No-Laziness + anti-slop gate.
- **Literal "confidence ≥ 8" magic-number threshold** — vibe scalar; #11 takes the shape (cite-both-sides + named exploitability path), not the number.
- **Per-phase hard-stop approval pipeline / single-task stop executor** — autonomy conflict; WALTEUR already has the opt-in version (Seam 1/2, `pause_per_task`) done better.
- **Auto-apply audit findings into PLAN.md** — bypasses gate-guard sign-off + debate-the-real-forks.
- **Read-only doc-grader agents** — validate doc *shape*, can pass a beautiful-but-wrong doc; already covered deterministically by prd-gate + spec-lint + spec-trace.
- **Steering docs / NPM installer / HANDOFF.md / fixture harness / claude-md memory hygiene** — WALTEUR has equal-or-better (constitution + lessons-loop + graphify; `_relay/` BATON cross-model resume; per-gate `--selftest` + twins; bi-temporal CONSOLIDATE).

---

## Quick wins (same-day, low-risk)

- merge-base diff scoping (#8).
- **Document the existing autonomy seams** as a named registry (Seam 1 after PLAN, Seam 2 after AUDIT already exist) + add a post-REVIEW seam — gives #1's Intent branch a place to hang.
- **`<boundaries>` DO-NOT-CHANGE block** in PLAN.template (protect migrations/, auth/, prod config) read by gate-guard — high-fit to "minimal blast radius."
- **Subtractive REFLECT pass** — periodic report of which current registry gates ever returned non-SKIP (mine run-trace) → retire-or-justify. Never auto-deletes a HARD security gate. *The one idea that asks what to REMOVE.*
- **EARS-format ACs** (WHEN/THEN/SHALL) as an advisory spec-lint nudge.
- **"Problems over prescriptions"** clause for REVIEW/AUDIT roles only.
- **Blast-radius sort key** for non-veto findings (data-corruption > lost-writes > security > UX > cosmetic).
- **"What NOT to flag" + one operating question** per rubric (dotclaude house-contract) — cuts review noise.
- **Decimal-phase interrupt** convention (PLAN.1) for hotfixes; pairs with #12.
- **`BATON.md` handoff hint** ("Tried X, broke Y, use Z").
- **Manifest-hash drift fingerprint** — cksum of stable-sorted manifests → one line to `_relay/ISSUES.md` when the stack moves.

---

## Suggested build order (v9.2)

```
1. run-trace.jsonl (#2)            ← measurement substrate, unblocks everything
2. teach confidentiality-guard pass-stamp  → confidentiality-gate (#4) + skill-readiness (#5)
3. failure-triage router (#1)      ← now measurable; Intent branch via the new seam
4. frozen briefs (#3) + per-task reconciliation (#6)
5. quick wins batch (seams registry, boundaries block, merge-base, EARS, twin-invariant #7)
6. silent-failure-lint (#13, warning-first) + read-only reviewer allowlists (#14)
7. strategic: model-catalog, marketplace monorepo, ontology-lite, scope-graded ceremony, spawn-justification
```
