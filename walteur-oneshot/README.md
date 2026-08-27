# walteur-oneshot

A portable **one-shot builder** distilled from WALTEUR v10. Give it a goal, answer a few FRAME questions, and it runs plan → build → verify to a shipped, evidence-backed result — with WALTEUR's quality-gate rigor. Runs natively in **Claude Code** and **OpenAI Codex** from one shared source of truth.

## Files
| File | Role |
|---|---|
| `CORE.md` | The method — tool-agnostic single source of truth (the 7-phase loop, the honesty law, the gate pointer). |
| `references/core-gates.md` | The 7 lean gates enforced every run. |
| `SKILL.md` | Claude Code wrapper — binds `CORE.md` to Claude (subagent review panel, model routing, `--full` harness). |
| `AGENTS.md` | Codex wrapper — binds `CORE.md` to Codex (single-context sequential passes, inline gates). |
| `EXAMPLE-RUN.md` | A worked dry-run trace showing the full loop on a toy goal. |

`SKILL.md` and `AGENTS.md` never restate the method — edit `CORE.md` / `references/core-gates.md` to change behavior in both tools at once.

## The loop
`FRAME & DISCOVER → PLAN + DEBATE → ESTIMATE → BUILD → REVIEW + QA → TERMINAL AUDIT → SHIP + REFLECT`. FRAME is the only interactive phase; after it, the run is autonomous to SHIP.

## Use in Claude Code
1. Place this folder where your skills live (e.g. `.claude/skills/walteur-oneshot/`).
2. Invoke `/oneshot <goal>` (or `/walteur-oneshot <goal>`), or just describe a build — the description auto-triggers it.
3. Add **`--full`** to defer to the real `walteur-kit` harness (148 gates / 68 personas via PreToolUse hooks) when you're inside a repo that carries `walteur-kit/`. Without it, the lean inline gates run.

## Use in Codex
1. Point Codex at `AGENTS.md` (drop it in as the agent instructions, or reference it).
2. It runs the same `CORE.md` method with Codex bindings — single context, sequential review/QA, inline gates.
3. **Standalone (outside this repo):** bundle `CORE.md` and `references/core-gates.md` alongside `AGENTS.md`, since Codex reads the files present.

## Two tiers
- **Lean (default):** the 7 core gates as inline discipline — identical in Claude Code and Codex, no hooks required.
- **`--full` (Claude Code only):** the real WALTEUR harness. Requested where unavailable (Codex, or no `walteur-kit/`) → it says so and stays lean, never faking the full run.
