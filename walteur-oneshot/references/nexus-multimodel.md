# Nexus multi-model delegation (optional binding)

Route build work across **multiple model families** — not just Claude — via the
**Nexus** orchestration engine (`Pro Coding/field-runs/nexus/`, local `D:\Omega`).
Nexus owns the hard parts: a pure inspectable router picks the best model per
task across 12+ API providers + CLI harnesses, runs a DAG with retry/reroute,
cross-model verification, and a **best-of-N** pass (N models attempt one task, a
cross-model judge picks or synthesises the strongest). This binding tells the
one-shot engine *when* and *how* to delegate. It is **optional** — when Nexus
isn't reachable, say so and fall back to the Claude subagent panel.

## Preflight (always, before delegating)
1. **Tools present?** The `mcp__nexus__nexus_build / nexus_status / nexus_wait /
   nexus_best_of / nexus_files` tools must be available (wired via the Nexus
   repo's `.mcp.json`). Absent → not integrated here; fall back, state it.
2. **API live?** Those tools call the Nexus API on `http://localhost:4801`.
   If a call errors with a connection/timeout, the server is down — bootstrap it:
   `cd <nexus> && npm run dev` (API :4801 + web :4800), or `docker compose up`.
   Never claim a multi-model run happened if the server was down (honesty law).
3. **Keys?** No provider keys → Nexus uses **simulated twins** (labelled `(sim)`)
   — proves the wiring end-to-end at **zero spend**, but the output is mock. With
   keys set (in the Nexus vault or env), tasks route to real providers. Always
   report which: `nexus_status` shows each task's actual `modelId` (a `(sim)`
   suffix = simulated). State sim-vs-live and cost in the final handoff.

## Two modes — selectable per run
Default **OVERLAY**. Use **FULL-DELEGATE** when the user asks for it
("build it with the whole roster", "full multi-model", "use every model").

### Mode A — OVERLAY (default)
Claude builds the coherent whole; Nexus adds multi-model muscle where it raises
quality without surrendering coherence:
- **Candidates on load-bearing pieces.** For a hard, self-contained sub-problem
  (a tricky algorithm, a schema, a security-sensitive function), `nexus_build`
  a tight spec for just that piece, `nexus_wait`, then `nexus_best_of` on its
  leaf task → fold the winner into your build. Different model families surface
  approaches one model misses.
- **Cross-model verification** of the key deliverable: after your build, run the
  critical piece through Nexus so *other* model families independently judge it
  (the best-of judge is always a model that produced none of the candidates).

### Mode B — FULL-DELEGATE
Hand the build to Nexus; Claude orchestrates + audits:
1. `nexus_build(prompt, budgetUsd?)` → returns `projectId`.
2. `nexus_wait(projectId, timeoutSec)` → blocks to a terminal state.
3. `nexus_status(projectId)` → read the plan, per-task models, DoD gate, delivery.
4. `nexus_best_of(projectId, <key leaf taskId>, n)` on the primary deliverable
   leaf (e.g. `frontend`/`backend`/`copy` from the status — **not** internal
   `__…__` tasks) → the winner is promoted into the workspace.
5. `nexus_files(projectId)` then `nexus_files(projectId, <path>)` → pull the
   delivered files back for the TERMINAL AUDIT.
6. **You still audit.** Nexus's DoD gate is not the WALTEUR terminal audit —
   re-derive evidence (run it, cite `file:line`) before you certify.

## best-of-N — what it does
`nexus_best_of(projectId, taskId, n)` (n∈[2,6], default 3) runs the task on the
top-n routed **API** models in parallel (CLI harnesses excluded — they write
files natively and would clobber the shared workspace), then a cross-model judge
scores them and either picks the strongest by merit or returns a synthesis that
merges their best parts. The winner is promoted to the task's output **and files**
(prior snapshotted), and the pick feeds Nexus's learning loop. Returns the winner
model + rationale. Blocking (n+1 model calls) — budget accordingly.

## When NOT to delegate
- Trivial change (typo, one-liner) — overhead not worth it.
- Tightly-coupled refactor where one coherent author beats a committee.
- Nexus unreachable and you can't bootstrap it — fall back to the Claude panel
  and **say so**; never fabricate a multi-model result.
