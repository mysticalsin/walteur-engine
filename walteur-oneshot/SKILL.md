---
name: walteur-oneshot
description: One-shot builder — give a goal, answer a few FRAME questions, then it plans, builds, and verifies autonomously with WALTEUR gate rigor. Portable to Codex. Use whenever you build, ship, deploy, scope, refactor, or upgrade a product/feature/system/agent. Triggers on /oneshot, /walteur-oneshot, /one-shot, or "one-shot build X", "make me a…", "build X end to end".
---

# WALTEUR One-Shot (Claude Code)

## What this is
The one-shot build engine: give a goal, answer the FRAME questions, then it runs to a shipped, evidence-backed result. **The method is in [`CORE.md`](./CORE.md); this file only binds it to Claude Code** — it does not restate the phases or gates.

## Run it
Follow `CORE.md` end to end. Enforce every gate in [`references/core-gates.md`](./references/core-gates.md) — pass with evidence or skip with a stated reason. Phase run-order (definitions live in `CORE.md`):

1. FRAME & DISCOVER  →  2. PLAN + DEBATE  →  3. ESTIMATE  →  4. BUILD  →  5. REVIEW + QA  →  6. TERMINAL AUDIT  →  7. SHIP + REFLECT

After FRAME, run 2–7 unattended; re-enter only on a genuine blocker (per the CORE contract).

## Claude Code bindings
- **REVIEW + QA fan-out.** Spawn a subagent panel — one agent per independent lens (Product · Architecture · Security · UX · Data · API), plus a blind-diff reader and an outcome-evaluator, and the QA-corps dimensions (esp. the Logic pass) as separate agents. Reconcile at the TERMINAL AUDIT. One model → run them as separate focused passes instead.
- **BUILD fan-out.** For disjoint work, dispatch one subagent per file-cluster in its own git worktree (no overlapping files).
- **Model routing.** Route heavy reasoning (PLAN, TERMINAL AUDIT) to a stronger model; mechanical steps to a cheaper one. The terminal audit should run fresh-eyes on the strongest available model.
- **Multi-model via Nexus (optional).** When the `mcp__nexus__*` tools are wired and the Nexus API is live, delegate build work across 12+ model families — candidates + cross-model verify + **best-of-N** — instead of Claude-only. Two per-run modes (overlay ↔ full-delegate), preflight, and the exact tool sequences live in [`references/nexus-multimodel.md`](./references/nexus-multimodel.md). Fall back to the subagent panel (and say so) when Nexus is unreachable.
- **Invocation.** The Skill tool, or `/oneshot <goal>` / `/walteur-oneshot <goal>`.

## `--full` mode
Invoke with `--full` to defer to the real WALTEUR harness instead of the lean inline gates. Requires Claude Code **and** a repo carrying `walteur-kit/`: it wires `.claude/settings.json` PreToolUse hooks, the 148-gate `gate-registry.json`, the 68-persona `personas.json`, and `ship-gate.sh` on `git commit`/`git tag`. If `--full` is requested outside Claude Code or without `walteur-kit/`, say so plainly and fall back to the lean gates — never claim the full harness ran when it didn't (honesty law).
