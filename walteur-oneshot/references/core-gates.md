# WALTEUR One-Shot — Lean Gates

The irreducible set distilled from WALTEUR's 148-gate registry — enforced **inline** (self-checked, no hooks needed), so the same teeth work in Claude Code and Codex. `--full` mode (Claude only) swaps this for the real `walteur-kit` harness.

| Gate | Type | Checks | WALTEUR origin |
|---|---|---|---|
| **plan-before-build** | HARD | A written plan physically exists before any code is written. No file, no build. | `gate-guard` |
| **current-stack** | HARD | Stack, versions, and APIs verified against current sources on the run-date — no stale-training assumptions, no hallucinated/nonexistent APIs. | `current-stack-gate` |
| **anti-slop** | PROTOCOL | Code: formatter-clean, types strict, no `TODO: implement`, no empty catch, small focused modules. Prose: no filler. UI: design tokens (no magic numbers), WCAG AA, every screen has loading/empty/error states, zero AI-slop signatures (purple→indigo gradients, lorem ipsum, fake "Acme/John Doe" data, "Something went wrong"). | `anti-slop-code` / `anti-slop-prose` / `anti-slop-ui` |
| **security-floor** | HARD | No secrets in code, input validation, authz enforced, injection/SSRF defended, deps pinned (no typosquats); tenant isolation proven when multi-tenant. Security is a hard floor — if breached, stop everything and fix first. | `security-gate`, `cross-tenant-probe-gate` |
| **evidence/re-run** | HARD | Every "done" claim cites fresh output; the recorded verification command re-runs clean and you trust the exit code, not the self-report. | `evidence-gate` |
| **no-hollow-artifact** | PROTOCOL | Ships a real working thing — not a mock/stub facade, not fake data passed off as a working flow. | `hollow-artifact-gate` |
| **terminal-audit certification** | PROTOCOL | A fresh-eyes pass re-derives the evidence and certifies built == intended: each load-bearing rule cites the documented intent (quoted) AND the enforcing code (`file:line`) before ship. Cannot rubber-stamp. | `audit-gate` |

**Reporting rule:** label each gate **HARD** (mechanical/fact-checkable) or **PROTOCOL** (model judgment) when you report it. A skipped gate is announced with its reason (e.g. "no UI → anti-slop/UI n/a"), never silently passed. A HARD gate that can't be run is a blocker, not a pass. This is the honesty law applied to gates: absence of a check is NOT-FOUND, never PROVEN-CLEAN.
