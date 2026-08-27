# Loop failure-mode catalog — and how WALTEUR already mitigates each

> Adapted from loop-engineering `docs/failure-modes.md` (MIT, Cobus Greyling / Addy Osmani). Severity:
> **S1** wasted tokens · **S2** wrong code/bad tickets merged · **S3** security/data-loss/incident.

| Failure mode | Sev | WALTEUR mitigation (mechanical) |
|---|---|---|
| **Infinite fix loop** (never converges) | S2 | Hard attempt cap → escalate (LOOP.md human gates: 3rd failure escalates). Separate verifier (panel/audit), not same session. |
| **State rot** (acts on merged/closed ghosts) | S1→S2 | `loop-state.json` read at start, written every run; `release-ledger` timestamps; prune resolved items. |
| **Verifier theater** (approves, then CI fails) | S2 | Verifier must REPRODUCE: gauntlet re-runs every `--selftest` + reproduces the exact poisoned fixture 0→2. Lead independently re-verifies every "green" (agents lie — proven). |
| **Notification fatigue** | S1→S2 | PushNotify only the one-line wrap / actionable escalation, not every run. |
| **Token burn** | S1 | Cheap triage (preflight-signals) before the fleet; `cost-budget.sh`; empty watchlist → exit cheap; serialize workflows. |
| **Over-reach (wrong scope)** | S2→S3 | Path denylist (LOOP.md + security gates); `blast-radius-gate`; "smallest diff"; anti-rationalization gate flags "while I'm here". |
| **Comprehension debt spiral** | S2 | Run log + ULTIMATE-UPGRADE tally; lead reads every result; no rubber-stamp auto-merge. |
| **Cognitive surrender** ("the loop handles it") | S2 | Honest self-rating, explicit human gates on medium-risk; success = quality bar held, not volume. |
| **Parallel collision** (two agents, same files) | S2 | `isolation: worktree` for parallel mutators; **serialize workflows** (one at a time); collision note in state. |
| **Escalation failure** (stuck, human never told) | S2 | `waiting_on_human` in loop-state; PushNotification on escalation; kill switch (`PAUSED`). |

**Use:** when a WALTEUR loop misbehaves, classify it here first, then point at the named mitigation — don't
invent a new control if one exists. New failure mode → add a row + a regression (G#) if it's gate-checkable.

---
*Provenance: loop-engineering failure-mode catalog (MIT). Mapped to WALTEUR's fail-closed gates + loop discipline.*
