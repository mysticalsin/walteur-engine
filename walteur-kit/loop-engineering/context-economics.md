# Context economics — compress hard, keep quality (Tony's standing requirement, mechanized)

> Folds the **token-optimization pillar** of HARNESS_V2_REPORT (RTK · Headroom · Repomix) + War Mode V15's
> context-preservation ladder (§0.2 #12–13, §0.16). Serves Tony's standing requirement: *"when the context
> window is too big, compress and keep working at full quality."* Related: [[walteur-always-best-quality]].

## 1. The compaction ladder — ABSOLUTE tokens, not percent (automatic, no human)
Model quality degrades with **absolute** context size, not with percent of the window. On a 1M window a
percent ladder (compact at 70% = 700k) keeps agents reasoning in a degraded zone far too long. So WALTEUR pins
compaction to absolute tokens — source of truth `walteur-kit/compaction-policy.json` (mode: automatic):

| Working context | Action |
|---|---|
| **≤ 150k** | Work normally — full context, sharpest reasoning. |
| **150k (compact_at)** | **Compact automatically** — summarize every COMPLETED wave/phase to durable files (STATE.json, briefs, reports); drop the resolved transcript; keep PLAN.md + open work + BATON. |
| **200k (handoff_at)** | **Hard handoff** — write the Pi-format checkpoint to `_relay/BATON.md` ([[checkpoint-schema]]) and continue fresh from it. Never carry a transcript past 200k, even with 800k window to spare. |

WALTEUR realization: `compaction-policy.json` holds the thresholds; `walteur.js maybeCompact()` checks estimated
context at each wave boundary and compacts hands-free; `context-compaction-gate.sh` enforces the policy + the
200k aggregate ceiling fail-closed; `_relay/BATON.md` ([[checkpoint-schema]]) is the quality-preserving vehicle.
**Compact at a logical breakpoint (between waves), never mid-fix — and never wait for the window to fill.**

## 2. CLI + Skill > MCP (the highest-ROI token optimization)
An MCP server loads its full tool schema into context **permanently** — a 5-server / 58-tool setup can burn
14k–55k tokens *before the first prompt* (25–30% of a 200k window, gone). A CLI is **free** in context (the
model already knows `tool --help`); a Skill wraps it in ~40 tokens, loaded on demand.

**Hierarchy (prefer top):** (1) CLI + Skill wrapper · (2) Skill-only · (3) MCP — only when a live
bidirectional/stateful connection is essential (streaming DB cursor, stateful browser session, no CLI exists).
**MCP budget: keep 3–5 enabled at once.** For every MCP ask "does a CLI exist?" — if yes, replace it with a
Skill that wraps the CLI. (e.g. `gh` + a gh-pr skill ≈ 40 tokens vs the GitHub MCP ≈ 14k.)

## 3. Tooling to adopt (from the v2 repo synthesis — pull + evaluate post-reset)
| Tool | Saving | WALTEUR fit |
|---|---|---|
| **RTK** (`rtk-ai/rtk`) | 80–90% on dev-command output (`git status` 2000→200 tok) | wrap noisy build/test/git in gates + the orchestrator; `rtk init -g` hooks transparently. |
| **Headroom** (`chopratejas/headroom`) | 60–95% on tool outputs / logs / RAG chunks | compress gate reports + CI logs before they reach a reviewer agent. |
| **Repomix** (`yamadashy/repomix`) | repo → one LLM-friendly file | RESEARCH/onboarding phase context packing; feed a subsystem to a scout in one shot. |
| **CodeGraph** (`colbymchenry/codegraph`) | pre-indexed knowledge graph, 100% local | codebase-RAG for DISCOVER; fewer exploratory tool calls. |

## 4. Advisory checklist (apply every loop)
- [ ] Prefer the cheapest model that meets the quality bar per task (THINK Opus · EXECUTE Sonnet · cheap ops Haiku).
- [ ] Modular files (100s of lines, not 1000s) — less to load, less to re-emit.
- [ ] Compact at logical breakpoints; never carry a full transcript past 70%.
- [ ] ≤3–5 MCPs; everything else CLI+Skill.
- [ ] Triage cheap before spawning a fleet; empty watchlist → exit cheap.

---
*Provenance: token-optimization tooling + savings figures from HARNESS_V2_REPORT (Kimi.ai synthesis of
rtk-ai/rtk, chopratejas/headroom, yamadashy/repomix, colbymchenry/codegraph). Compaction ladder + CLI>MCP
hierarchy from Ultron War Mode V15 §0.2 #12–13 and §0.16 (Tony's protocol). Loop framing: loop-engineering (MIT).*
