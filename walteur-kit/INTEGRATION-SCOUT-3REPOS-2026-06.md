# WALTEUR — Integration Scout, 3 user-requested repos (2026-06-21)

**Method:** 3 parallel general-purpose assessors (one repo each) → synthesis. Each cloned/web-read the repo, read README + every SKILL.md/manifest + LICENSE, verified architecture before verdict. Anti-bloat + one-brain + portable + honesty laws enforced.

> **Net:** **0 of 3** earn a harness install. **1** contributes a narrow PATTERN delta (now absorbed). **2** are TOOLS for the products WALTEUR builds (recommend, don't adopt). The two most-starred (Headroom 11.3K, Agent-Reach 5.2K) add the least to the engine — popularity ≠ net-new value, exactly as the 9-repo scout found.

## Verdicts

| # | Repo | Stars | License | Verdict |
|---|---|---|---|---|
| 1 | **product-on-purpose/pm-skills** | ~3.9K | Apache-2.0 | **ABSORB-AS-PATTERN** (sprint delta only) · REJECT the rest |
| 2 | **Panniantong/Agent-Reach** | ~5.2K | MIT | **RECOMMEND-AS-PROJECT-TOOL** (+ 1 absorbed pattern) |
| 3 | **chopratejas/headroom** | ~11.3K | Apache-2.0 | **REJECT as install** · project-tool only |

## 1 — product-on-purpose/pm-skills → ABSORB the sprint delta, REJECT the rest

**What it is (verified):** mature file-scale skill library (v2.28/3.0) — 67 SKILL.md + 5 sub-agents + 12 workflows + 95 sample outputs. Pure prompt-docs: no MCP server, no embedding/vector store, no daemon, no DB. Two dependency-free Node hooks (SessionStart phase-router, PreToolUse guardrails lint). Families: define / discover / develop / deliver-PRD / measure-experiment / iterate / foundation / tool-sprints / utility.

**Lane:** PM / PRD / product-front-of-funnel — the lane **walteur-discover already occupies** and has already absorbed TWO prior pm-skills sources (phuryn, mysticalsin). This is the THIRD.

**Why mostly REJECT:** anti-bloat / one-skill-per-lane. ~50+ skills duplicate methods walteur-discover already chains. No one-brain or portability violation (it's prose), so the bar is purely net-new value — and almost all of it is duplicate. Do **not** install the plugin (would be a 4th parallel PM library).

**Genuine net-new delta (ABSORBED):** the two **time-boxed sprint engines** WALTEUR had no skill for — **Foundation Sprint** (Knapp/Zeratsky, 2-day, lock the founding hypothesis) + **Design Sprint** (Knapp, 5-day, prototype→test). Landed as **walteur-discover §4.5 STRUCTURED SPRINT** — an optional cadence for §4.1–4.4, never a replacement, never a gate; terminates in the §6 kill-or-proceed loop + PRD. Prose only (one-brain intact), Apache-2.0 attribution inline. Did NOT import the 67 SKILL.md, hooks, Astro site, or sub-agents.

## 2 — Panniantong/Agent-Reach → RECOMMEND-AS-PROJECT-TOOL

**What it is (verified, against the name):** NOT outreach/cold-email. "Reach" = giving an agent *read-reach into the internet*. Python CLI (`agent-reach` console script) that installs + `doctor`-health-checks + routes READ/ingest access to 13 platforms (X, Reddit, YouTube, Bilibili, Xiaohongshu, GitHub, RSS, web, LinkedIn, V2EX, Xueqiu, Xiaoyuzhou, Exa). Each channel = ordered backend-candidate list; the agent calls upstream CLIs/APIs directly. Ships a Claude-Code SKILL.md. SKILL.md explicitly EXCLUDES write ops (posting/commenting) and report-writing. MIT.

**No law violation (verified):** grep for `embedding|vector|faiss|chromadb|qdrant|pinecone|uvicorn|fastapi|flask|run_server|while True` over the package = **zero** hits. Only "server" is a stdio MCP exposing one `get_status` tool — not a network daemon, not a retrieval index. Needs per-platform keys/cookies for some channels; 6 are zero-config.

**Why project-tool, not harness:** it's an *application capability* (gated-source scraping infra), not skills-discipline. It is **inbound read**, not the outbound GROWTH/distribution lane — so it does NOT fill the $100M go-to-market gap. As a harness skill it would duplicate WALTEUR's research step and risks pulling content *around* graphify (one-brain tension). Breaks no law → not a REJECT, but earns no lane.

**Disposition:** when a built product needs paywalled/login-gated/geo-blocked ingestion → install `agent-reach` as a per-project dependency; pipe its output **into** graphify (one-brain holds). **ABSORBED pattern:** the `doctor` backend-probe discipline (ordered-candidate-backends + execute-before-claiming-healthy) → reinforces WALTEUR's tool-readiness/tool-wiring step.

## 3 — chopratejas/headroom → REJECT as install (project-tool only)

**What it is (verified):** context-compression layer for LLM apps (Apache-2.0). Per-content-type compressors (JSON/code/logs/diffs; code via tree-sitter AST) + a Compress-Cache-Retrieve store. Four modes: Python pkg, TS pkg, an **OpenAI/Anthropic-compatible HTTP proxy** (`headroom proxy --port 8787`), and an **MCP server** (`headroom_compress/retrieve/stats`). Also `headroom learn` (mines failed sessions → writes to CLAUDE.md/AGENTS.md) and a **cross-agent memory: per-project SQLite + HNSW**. `docker-compose` stands up **Qdrant + Neo4j**.

**Three laws fire (any one fatal):**
- **ONE-BRAIN — violated:** memory/retrieve tier is a *second index* (SQLite + HNSW + `headroom_retrieve` MCP; compose runs Qdrant **and** Neo4j). Exactly the forbidden second retrieval brain.
- **PORTABLE/FILE-SCALE — violated:** proxy/MCP/memory modes are a long-running HTTP daemon (`:8787`) backed by always-on containers. Not file-scale.
- **ANTI-BLOAT — violated:** lane already covered (run-trace + HARD cost ceiling + compaction Stop hook + flywheel + BATON). `headroom learn` duplicates the flywheel; cross-agent memory duplicates graphify+BATON.

**Disposition:** do NOT land in either distribution; do NOT absorb as pattern (WALTEUR already has every pattern worth taking — ast-grep gates, cost ceiling, compaction, flywheel). Recommend only as an optional project-level dev tool a *built product* may put in front of its own LLM calls to cut its runtime token bill — never harness infra, never wired to graphify.

## Project-tools recorded (recommend; not harness-adopted)
- **agent-reach** (MIT) — gated/geo-blocked source ingestion for a built product; pipe output through graphify.
- **headroom** (Apache-2.0) — optional runtime token-cost proxy in front of a built product's own LLM calls.

## Applied this tick
1. **[done]** walteur-discover **§4.5 STRUCTURED SPRINT** (Foundation + Design Sprint cadence; spec distribution only — discover has no canonical twin).
2. **[done]** tool-readiness/tool-wiring reinforced by the agent-reach `doctor` backend-probe pattern (prose).
3. **[done]** this report.
