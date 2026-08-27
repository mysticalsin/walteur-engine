# WALTEUR — LOOP.md (the harness operating its own autonomous self-improvement loops)

> Loop engineering (Cobus Greyling / Addy Osmani, MIT): *"Harness = single session setup; Loop = harness +
> schedule + state + verification chain."* WALTEUR is the harness; Tony runs it as autonomous loops. This file
> documents those loops so `loop-readiness-gate.sh` can hold them to L0–L3 discipline. Folded in from
> [github.com/cobusgreyling/loop-engineering]. See `walteur-kit/loop-engineering/` for the full corpus.

## The loops we run

| Loop | Cadence | Level | Purpose |
|---|---|---|---|
| **Adversarial gauntlet self-improvement** | on-demand, serialized batches | L3 (unattended) | Red-team every gate (3 evasion angles), fix every proven false-negative, lock a G# regression. |
| **ULTIMATE 12h improvement /loop** | every 12h (ScheduleWakeup) | L3 (unattended) | Scout best-of-breed tools/skills/frameworks, fold into WALTEUR, re-verify, deepen. |

## Maker / checker verifier (the loop never marks its own work done)
The implementer is never the judge. Verification chain: the **7-senior review panel** → the **terminal Opus
audit** → the **adversarial gauntlet** that independently re-runs every gate's `--selftest` and reproduces the
exact poisoned fixture 0→2. The lead **independently re-verifies** every agent's "green" (agents lie about
green — proven; see `walteur-gauntlet-self-improve` memory). A reported pass is not a pass until reproduced.

## State / memory (read at start, written every run)
- `walteur-kit/loop-state.json` — current batch, gates done, holes closed (the loop's working state).
- `_relay/BATON.md` — cross-model handoff (Claude/Codex/Gemini are shifts of one worker).
- The persistent memory dir + `MEMORY.md` index — durable facts, lessons, feedback.
- **Last run** is stamped in `walteur-kit/release-ledger.json` and the `ULTIMATE-UPGRADE-2026.md` tally.

## Triage (cheap signal pass before heavy work)
`preflight-signals.json` derives build signals; `gate-registry.json` selects gates per build_class/risk_tier.
Empty watchlist → exit cheap. Never spawn the full fleet on a no-op. **Where that file lives:** it is a
*per-build* artifact, written into the BUILD's own `walteur-kit/` (see any
`field-runs/<app>/walteur-kit/preflight-signals.json`). It is deliberately **absent** from this framework
repo's `walteur-kit/` — which is why signal-gated gates fired here report NOT_APPLICABLE/SKIP rather than red.

## Token budget + kill switch
- **Token budget:** the orchestrator runs under a budget ceiling; `walteur-kit/hooks/cost-budget.sh` enforces
  per-run spend. Workflows honor a shared output-token target. On exceed → pause, notify Tony.
- **Kill switch:** drop `walteur-kit/PAUSED` → **every** gate exits 2 (fail-closed halt). Per-gate bypass
  `WALTEUR_<GATE>=off`. "Pause all" = stop the loop = remove the next ScheduleWakeup. This is the
  documented stop-the-loop mechanism. Reproduce it without stopping this repo:
  `t=$(mktemp -d "${TMPDIR:-/tmp}/paused.XXXXXX"); mkdir -p "$t/walteur-kit"; : > "$t/walteur-kit/PAUSED"; WALTEUR_ROOT="$t" bash walteur-kit/hooks/schema-lint.sh "$t" >/dev/null 2>&1; echo "rc=$?"`
  → prints `rc=2` (verified 2026-07-25 on design-gate, loop-readiness-gate and schema-lint).

## Path denylist (never auto-edit without a human gate)
The loop must **never** autonomously edit: `.env` / `.env.*` · `**/secrets/**` · `**/credentials/**` ·
`**/*_key*` / `**/*_secret*` · `.terraform/**` · `k8s/production/**` · `**/migrations/**` (unless an explicit
migration loop) · `auth/**` · `payments/**` · `billing/**`. WALTEUR's security gates (security-baseline,
authz-tenant, supply-chain, ci-hardening) enforce the same surfaces fail-closed.

## Human gates (interrupt by exception — escalate, don't guess)
Always escalate to Tony for: any security tradeoff · a new dependency outside the approved stack · scope
changes · choosing between fundamentally different architectures · the 3rd failed attempt on the same item
(hard cap → escalate, never infinite-fix). Everything else: autonomous by default.

## Multi-loop coordination
**One workflow at a time — serialize.** The runtime caps ~16 concurrent agents/workflow; two stacked
workflows throttle (proven). ≥40 agents at once, or a hard session-usage limit, fails the batch. Each batch:
launch one workflow → process → verify → next. Collision avoidance: never run two gauntlet/fix fleets at once.

---
*Provenance: structure + L0–L3 readiness model + the failure-mode/safety vocabulary adapted from
cobusgreyling/loop-engineering (MIT). Scored by `walteur-kit/hooks/loop-readiness-gate.sh`.*
