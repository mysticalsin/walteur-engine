# The Five Primitives + Memory — WALTEUR's realization of each

> Adapted from loop-engineering `docs/primitives.md` (MIT). The building blocks of any reliable loop. This is
> the conceptual basis `loop-readiness-gate.sh` scores. WALTEUR has all five + memory — cited below.

| # | Primitive | What it gives | WALTEUR's realization |
|---|---|---|---|
| 1 | **Scheduling / automation** | the heartbeat | `/loop` + ScheduleWakeup (self-paced) + the 12h cron; fire-immediately, durable. |
| 2 | **Worktrees** | parallelism without merge hell | `isolation: worktree` for parallel mutators; auto-cleanup. |
| 3 | **Skills** | persistent memory of *intent* (pay down intent debt) | 190-skill Org library + skill-index + skill-routing (MUST-use-if-applies, fail-closed via skill-readiness). |
| 4 | **Plugins / connectors (MCP)** | reach beyond the filesystem | mcp-routing (advisory); ≤3–5 MCPs, CLI+Skill preferred ([[context-economics]]). |
| 5 | **Sub-agents (maker / checker)** | the single most important reliability pattern | the 7-senior review panel + terminal Opus audit + adversarial gauntlet; the implementer never judges its own work. |
| + | **Memory / state** | survive across turns/sessions | `loop-state.json`, `_relay/BATON.md`, the persistent memory dir + `MEMORY.md`, `release-ledger.json`. |

**The discipline:** add each primitive only when the previous one has proven its value *and its failure mode*
(see [[failure-modes]]). WALTEUR earned all five over the gauntlet/improvement loops — it didn't start at L3.

---
*Provenance: loop-engineering Five Primitives + Memory (MIT, Cobus Greyling / Addy Osmani).*
