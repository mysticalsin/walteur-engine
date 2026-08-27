# WALTEUR One-Shot (Codex)

The one-shot build engine, for OpenAI Codex. **The method is [`CORE.md`](./CORE.md); enforce [`references/core-gates.md`](./references/core-gates.md). This file only binds them to Codex** — it does not restate the phases or gates.

## Run it
Follow `CORE.md` end to end; account for every gate in `references/core-gates.md` (pass with evidence or skip with a stated reason). Phase run-order (definitions live in `CORE.md`):

1. FRAME & DISCOVER  →  2. PLAN + DEBATE  →  3. ESTIMATE  →  4. BUILD  →  5. REVIEW + QA  →  6. TERMINAL AUDIT  →  7. SHIP + REFLECT

After FRAME, run 2–7 unattended; re-enter only on a genuine blocker (per the CORE contract).

## Codex bindings
- **Single context, sequential passes.** No subagent fan-out. Run REVIEW + QA as *separate, deliberate reads* in-context — one focused pass per lens (Product · Architecture · Security · UX · Data · API), then the QA-corps dimensions, giving the **Logic & Correctness** pass its own dedicated read. Do not blur them into one review.
- **Gates enforced inline.** The lean gates are self-checked as you work — there are no auto-firing hooks. Treat each HARD gate as a stop-and-fix; announce every skip with its reason.
- **Model.** Use Codex's model throughout; where a phase (PLAN, TERMINAL AUDIT) wants stronger reasoning, note that explicitly rather than pretending the pass was as strong as a top-tier model.
- **The terminal audit is still mandatory** — a genuine fresh-eyes re-read that re-runs the evidence, even in one context.

## What is not available in Codex
These Claude-Code capabilities degrade to inline discipline — **named, not silently dropped** (honesty law):
- **No `--full` walteur-kit harness** — no PreToolUse hooks, no 148-gate `gate-registry.json`, no `personas.json`, no `ship-gate.sh`. You get the 7 lean gates as reasoning, not mechanical blocks.
- **No subagent / git-worktree fan-out** — REVIEW/QA and parallel BUILD collapse to sequential passes.
- **No Anthropic model routing** — one model, no per-phase opus/sonnet split.
Say when a gate was reasoned rather than mechanically enforced; never present an inline judgment as a hard block.

## Standalone use
If you use this outside the walteur repo, bundle `CORE.md` and `references/core-gates.md` alongside this `AGENTS.md` (or paste their contents in) — the method and gates must travel with the wrapper, since Codex reads the files present, not the repo.
