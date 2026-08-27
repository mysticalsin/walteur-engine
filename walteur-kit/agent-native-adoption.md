# agent-native (BuilderIO) — adoption record

Source: https://github.com/BuilderIO/agent-native (MIT, ~2.8k stars, BuilderIO, pre-1.0, very active —
`@agent-native/core@0.79.x` as of 2026-06-28). A TypeScript framework for "rung-3" agentic SaaS where
agent + UI share one typed action surface (`defineAction` → 7 consumers: model tool, React hooks, client
call, HTTP, MCP tool, A2A tool, CLI) over one SQL DB.

## Honest verdict
**Steal disciplines, host nothing.** ~70% of agent-native (live UI↔agent sync, Yjs/TipTap multiplayer, the
runtime, the scaffolding CLI, A2A, MCP hosting, the "rungs" framing) is runtime/product machinery a
stack-neutral, fail-closed **build harness** cannot and should not host. WALTEUR is not the kind of thing
agent-native is. But three of its disciplines are genuinely good and aligned with WALTEUR's evidence-gated
philosophy — and one closes part of the PROOF gap.

## Folded in (this pass)
- **Auto-audit-per-mutation (ADOPT-CORE — the one idea that yields runtime evidence).** agent-native
  auto-audits every mutating action (who/what/when/surface) and skips reads. Folded into the
  `field-runs/multitenant-tasks` reference app as a real, **executable** proof: every `add/complete/remove`
  writes a tenant-scoped audit row; reads don't; a *denied* cross-tenant write leaves no audit row. Proven by
  `node --test` (8/8) and re-run by the harness — runtime evidence, not a shape-read claim. This is the
  agent-native concept that directly attacks WALTEUR's honest weakness.

## Roadmap (ADOPT-OPTIONAL — not yet built)
- **Schema-per-action contracts + exposure flags** (`needsApproval` / `publicAgent` / `readOnly` /
  `parallelSafe`): mandate every generated capability ship a Standard-Schema contract + a declared exposure
  block; an `action-contract-parity` gate shape-checks existence/parity. Capability + AuthZ-adjacent.
- **`assertAccess` / `accessFilter` per-row tenant primitives**: require generated multi-tenant write paths to
  declare a write-assert + read-filter; fold into the (now-executing) authz-tenant gate's negative probe.

## Skipped (REFERENCE-ONLY / SKIP)
`defineAction` 7-surface runtime, MCP/A2A hosting, the rungs ladder, live-sync/multiplayer, the scaffolding
CLI, their thinner skills system — all runtime/product features irrelevant to a build-time gate harness, or
already covered better by WALTEUR's existing skill/catalog system.
