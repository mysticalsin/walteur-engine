# Best-of-breed repo adoption report (live — built from scout batches)

> Scout batch 1: 6/20 repos returned (14 hit transient server rate-limiting → re-scout in smaller batches).
> Status legend: NEW-ADOPT · ENRICH · HAS-STRONGER · SKIP. Artifacts ranked by priority (1=highest).

## Repos scouted so far
- **github.com/ruvnet/ruflo** — `ENRICH` — SKIP the swarm/federation/vector-memory bulk (WALTEUR has stronger or doesn't need it), but ruflo-metaharness has a real gap-filler WALTEUR lacks: it audits the HARNESS ITSELF (readiness score + structural drift + MCP-surface threat-model), worth folding as 3-4 inward-pointing gates plus the hook-injection-hardening idiom.
- **affaan-m/ECC (everything-claude-code) — Claude Code plugin: 271 skills, 67 agents, 92 commands, hook fleet, multi-IDE** — `ENRICH` — ENRICH: skip the 271-skill domain library (WALTEUR's Org covers it), but steal four real mechanisms — skill-comply's empirical routing-compliance gauntlet, gateguard's DENY-FORCE-ALLOW fact-forcing PreToolUse gate (+2.25 quality), the live metrics-bridge/context-monitor (turns pre-flight budgets into real-time loop/cost/scope enforcement), and the 12-category harness self-audit scorer; ECC has no token-compression (RTK/repomix) tooling so it doesn't help the noisy-output problem.
- **chopratejas/headroom** — `ENRICH` — ENRICH - Headroom is the shipped, benchmarked version of the RTK/token-opt layer WALTEUR already noted; its measured-waste loop detector and merge-safe learned-pattern writer are the two highest-value, directly-portable upgrades to WALTEUR's crude memory loop, with output-shaping and wrap/CCR as bonus levers.
- **yamadashy/repomix** — `ENRICH` — ENRICH — WALTEUR already NOTED Repomix but never wired it; fold the pack-once/grep-incrementally MCP loop + token-count-tree gate + skill-generate (NOT the overhyped --compress, which repomix itself says is usually unnecessary).
- **https://github.com/nizos/tdd-guard** — `ENRICH` — ENRICH — WALTEUR's gates/gauntlet are broader, but tdd-guard's AST test-counting + Zod-parsed real-test-result contract make TDD enforcement DETERMINISTIC where WALTEUR's is still prose; fold those two primitives plus the clean-Red rubric and the shell-bypass deny pattern.
- **hardikpandya/stop-slop** — `NEW-ADOPT` — NEW-ADOPT, narrow but real: WALTEUR gates code/UI slop but has no PROSE-slop gate — fold this grep-able tell corpus + the <35/50 fail-closed rubric to cover the copy/microcopy/docs every shipped SaaS emits; adopt its dogmatic rules (em-dash/adverb/3-item bans) as overridable defaults, not absolutes.

## Candidate artifacts (ranked)

| P | Artifact | Type | Spec |
|---|---|---|---|

## Build status
- ✅ **anti-slop-prose-gate** (from stop-slop) — built, 11/11 selftest, wired (gate 111), registry lint PASS.
- ⏳ remaining artifacts: queued for the build-fleet after batch-2 scout + synthesis.

## Re-scout (batch 1b) — 9/10 repos
- **rtk-ai/rtk** — `ENRICH` — ENRICH — strong, concrete, and aligned with a goal WALTEUR already wrote down but hasn't built. RTK is the shipping implementation of the token-economics layer 
- **letta-ai/claude-subconscious** — `ENRICH` — ENRICH (not NEW-ADOPT). WALTEUR's memory/persistence/routing/review machinery is strictly stronger than this Letta demo, so the core idea is HAS-STRONGER. But t
- **https://github.com/addyosmani/agent-skills** — `ENRICH` — ENRICH — not NEW-ADOPT. WALTEUR already out-scopes ~85% of this pack (skill library, review panel, model-routing, orchestration, security/observability gates). 
- **smtg-ai/claude-squad** — `ENRICH` — ENRICH (narrow). claude-squad is a human-in-the-loop tmux+worktree multiplexer for parallel local agents — WALTEUR already strictly exceeds it on isolation, mem
- **https://github.com/wshobson/agents** — `ENRICH` — ENRICH (not NEW-ADOPT): WALTEUR already has stronger versions of this repo's headline assets — its specialist-team factory beats the 194 static agents, its mode
- **https://github.com/microsoft/playwright-mcp** — `ENRICH` — ENRICH. WALTEUR already has gstack (headless QA) and walteur-design's screenshot loop, but it verifies UI via vision screenshots — non-deterministic, token-heav
- **https://github.com/anthropics/knowledge-work-plugins** — `NEW-ADOPT` — NEW-ADOPT (narrow but real). This is Anthropic's knowledge-work (not code-build) marketplace, so 90% is HAS-STRONGER vs WALTEUR's panel/gates/gauntlet/routing. 
- **gsd-build/get-shit-done (GSD / "Get Shit Done" — spec-driven AI workflow, archived; source intact, continues as open-gsd/gsd-core)** — `ENRICH` — ENRICH. GSD is WALTEUR's closest structural peer, and on the headline axes WALTEUR is stronger: GSD's gates are 4 soft advisory types and every GSD hook is non-
- **earendil-works/pi (Pi Agent Harness — unified multi-provider LLM API + self-extensible coding-agent runtime, TypeScript monorepo)** — `ENRICH` — ENRICH — not NEW-ADOPT (Pi is a competing TS runtime; WALTEUR rides the Claude Code harness, so wholesale adoption would be a rewrite and WALTEUR already has st

### Re-scout artifacts (ranked)
| P | Artifact | Type | Spec |
|---|---|---|---|

## Build status (running)
- ✅ **anti-slop-prose-gate** (stop-slop) — 11/11, gate 111.
- ✅ **harness-self-audit-gate** (ECC/ruflo) — 9/9, gate 112; real WALTEUR self-score **98/100**, fail-closes on regression.
- ⏳ next inline builds: hollow-artifact-gate (L4 ships-mock catch), skill-quality-gate (lint 190 skills), rtk-rewrite hook (token-opt), data-correctness-gate, win silent-launcher.
- ✅ **hollow-artifact-gate** (GSD verifier L4) — 10/10, gate 113; catches ships-mock (handler→real data source).
- ✅ **skill-quality-gate** (agent-skills/ECC) — 8/8, gate 114; real Org library **94/100**, 0 broken of 190.
- ✅ **data-correctness-gate** (ECC validate-data) — 10/10, gate 115; flags join-explosion / avg-of-avgs / nested-aggregate / unguarded-denominator in SQL.

## Auto-compaction at absolute thresholds (Tony's standing rule, 2026-06-27)
- ✅ **compaction-policy.json** — source of truth: compact 150k / handoff 200k ABSOLUTE tokens, mode automatic, no human.
- ✅ **context-compaction-gate** — 9/9, gate 116; fail-closes if context exceeds 200k or the policy is missing/misconfigured.
- ✅ **checkpoint-schema.md** (Pi format) — the quality-preserving BATON vehicle for every compaction.
- ✅ **walteur.js maybeCompact()** — runtime auto-compaction at each wave boundary (node --check verified); writes a BATON checkpoint when context crosses 150k.
- ✅ **context-economics.md** — rewritten to absolute thresholds (percent ladders are wrong on a 1M window).

## Senior persona org (Tony's standing model, 2026-06-27)
- ✅ **personas.json** — expanded to **68 named senior roles** across every discipline (leadership, product, design, eng frontend/backend/full-stack/mobile/embedded/game/web3/ML, data, infra/ops, quality, security, GTM, docs, legal, FinOps, domain SME, + full Audit Squad). enforcement: 22 required / 46 advisory.
- ✅ **persona-coverage-gate** — 10/10, gate 117; fail-closes if a signal-required senior role left no engagement breadcrumb.
- ✅ **walteur.js Senior PM red-flag pass** — front-loaded at Plan→Build (node --check OK): writes red-flag-register.json + Chief-of-Staff/PM breadcrumbs BEFORE any code is built. Audit Squad = the existing 7-senior panel + QA corps + terminal Opus audit.
- ✅ **persona-breadcrumbs.sh** (emitter, 4/4) — evidence-based: writes a breadcrumb only when a persona's phase artifact exists (PLAN/SUMMARY/qa-report/audit/red-flag-register). Wired into walteur.js after the audit (node --check OK); end-to-end coverage PASS 17/17 on a full UI+API+DB build. personas.json + compaction-policy.json seeded into the scaffold.

## gstack (garrytan/gstack) — /goal fold (2026-06-27)
- **VALIDATES the persona org**: gstack turns Claude Code into a 23-specialist virtual team (CEO, eng manager, designer-catches-slop, reviewer, QA-with-real-browser, CSO OWASP+STRIDE, release engineer) — a subset of WALTEUR's 68-role roster. Confirms the named-senior-org model is best-in-class (Garry Tan / YC).
- **ADOPT — per-discipline PLAN review**: gstack's plan-ceo-review / plan-eng-review / plan-design-review / plan-devex-review run each senior over the PLAN before build. WALTEUR has the front-loaded Senior PM red-flag pass; extend it so each required persona reviews the plan (not just builds). [queued]
- **Power tools noted**: real-browser QA via CDP, make-pdf, diagram, scrape, landing-report — candidate tools for the VERIFY/design phases.

## Pro Coding full-implementation verification (2026-06-27)
- find-skills (vercel-labs) installed + indexed (skill-index-lint PASS, 191 skills); orchestrator (walteur.js, v10 wiring, node --check) + .claude/hooks (ship-gate, 8 new-gate dispatches) MIRRORED into Pro Coding → self-contained.
- 6-agent verification: wiring all-pass · docs v10 all-pass · 102/117 selftest-green initially.
- Fixed 13/15 flagged gates — all WINDOWS-PORTABILITY (not logic): $0 C:/ path arm (7 gates) · stat -c-first mtime (9 gates) · PATH=:$PATH selftest sandbox (3 gates). Now **115/117 green**; all 8 v10-built gates 100%; registry-lint PASS; harness 98/100.
- Residual: qa-contract-gate (10/11) + i18n-lint (4/7) — PRE-EXISTING logic bugs (v9.70-era, not v10 work), queued.

## Scout batch 2a (2026-06-27) — 10 repos, 38 artifacts
- **obra/superpowers** `ENRICH` — ENRICH, narrowly. WALTEUR already out-classes superpowers on gates, org/panel, skill ecosystem, gauntlet, memory and budgets — so 
- **anthropics/skills** `ENRICH` — ENRICH. anthropics/skills is the OFFICIAL Agent-Skills source, and WALTEUR's 190-skill library is exactly the thing the spec gover
- **thedotmack/claude-mem (v13.4.0) — persistent cross-session memory system for Claude Code** `ENRICH` — ENRICH, not adopt-wholesale. The HEADLINE (persistent cross-session memory + auto-compaction + context-budget) is HAS-STRONGER on 
- **smtg-ai/claude-squad** `ENRICH` — ENRICH. claude-squad is HAS-STRONGER on all structure (worktree isolation, agent/model routing, parallel waves, handoff, memory) -
- **nextlevelbuilder/ui-ux-pro-max-skill** `ENRICH` — ENRICH — not NEW-ADOPT (WALTEUR already owns the design-quality PHILOSOPHY via walteur-design/tonys-design/anti-slop gates, and th
- **product-on-purpose/pm-skills** `ENRICH` — ENRICH. WALTEUR dominates pm-skills on every runtime BUILD dimension (its 117 gates, gauntlet, 68-persona org, compaction, worktre
- **https://github.com/Panniantong/Agent-Reach** `ENRICH` — ENRICH. Agent-Reach's social/web CHANNELS are SKIP (out of WALTEUR's scope — it builds SaaS, it is not an internet scraper). But t
- **https://github.com/jo-inc/camofox-browser** `ENRICH` — ENRICH. The PRODUCT (stealth web browsing) is a hard SKIP for WALTEUR — WALTEUR builds SaaS, it does not browse the live web at ru
- **github.com/Imbad0202/academic-research-skills (v3.13.0; DOI-archived, CC BY-NC 4.0)** `ENRICH` — ENRICH, not NEW-ADOPT and not SKIP. This is a different DOMAIN (academic prose, human-in-the-loop, explicitly NOT autonomous SaaS)
- **Lum1104/Understand-Anything (Egonex-AI/Understand-Anything) — interactive code knowledge-graph plugin (Claude Code / Cursor / Copilot / Codex / Gemini, multi-platform)** `ENRICH` — ENRICH (not NEW-ADOPT, not SKIP). As a product, Understand-Anything is orthogonal to WALTEUR and HAS-STRONGER doesn't apply — it's
### Top P1 artifacts (batch 2a)
- **task-brief.sh + review-package.sh (context** [tool] — Port superpowers scripts/task-brief and scripts/review-package as Git-Bash WALTEUR tools that extract one plan-task's text and a BASE..HEAD review pac
- **skill-frontmatter-gate.sh** [gate] — Fail-closed gate porting skills/skill-creator/scripts/quick_validate.py to bash+jq: for every SKILL.md in the 190-skill library, parse YAML frontmatte
- **progressive-disclosure-retrieval** [pattern] — Wire WALTEUR's unwired RTK/Headroom token-opt as a HARD 3-layer memory-retrieval discipline (claude-mem mem-search): every memory/repo query returns a
- **worker-heartbeat.sh** [gate] — Fail-closed liveness gate: hash each parallel worker's captured output/log-tail (sha256sum) every poll; if a worker's hash is unchanged for N consecut
- **design-rules-db + find-design-rule retriev** [tool] — Fold ui-reasoning.csv (161 product-type rows: pattern/style/color-mood/typo-mood/anti-patterns/severity/Decision_Rules-JSON) + colors.csv (160 token-s
- **skill-trigger-eval** [tool] — Port run-trigger-evals.mjs as a WALTEUR gate-able harness: per-skill evals/trigger-fixtures.json (~16 labeled queries, train/validation split, expect:
- **tool-liveness-probe.sh** [gate] — Fail-closed gate that, for each required external tool/MCP-CLI (jq, repomix, gh, rg, etc.), goes beyond `command -v` and actually execs a side-effect-
- **failure-telemetry-loop** [tool] — A post-build hook that computes a stable failure-signature (error/gate-name + first non-vendored stack/log frame, line-not-column, a la reporter.js st
- **gate-calibration-harness** [tool] — Add scripts/gate_calibration.sh + a gold-set dir (gates/gold/<gate>/manifest.json with fnr/fpr/balanced_accuracy thresholds + N labeled tuples): for e
- **change-tier-gate.sh** [gate] — Fail-open-to-cheap deterministic pre-gate (port of fingerprint.ts compareFingerprints + change-classifier.ts classifyUpdate): on an incremental/brownf

## Scout batch 2b (2026-06-27) — 10 repos, 27 artifacts (intake ~complete: 45 repo-scouts)
- **mukul975/Anthropic-Cybersecurity-Skills** `ENRICH` — ENRICH (narrow). The 817-skill library is overwhelmingly SOC-analyst/DFIR/red-team content that is OUT OF SCOPE for a Sa
- **VoltAgent/awesome-design-md** `ENRICH` — ENRICH — the concept is already folded, the breadth is not. WALTEUR's walteur-design SKILL.md (C:\Users\Tony\Downloads\S
- **vabole/apple-skills** `HAS-STRONGER` — SKIP-as-repo / HAS-STRONGER. apple-skills is a native-iOS/Swift library; ~85% (Swift API refs, DocC auto-fetch tooling, 
- **forrestchang/andrej-karpathy-skills** `HAS-STRONGER` — SKIP — zero foldable artifacts. Two independent reasons. (1) ALREADY OWNED: this exact skill is already bundled in WALTE
- **karpathy/autoresearch** `ENRICH` — ENRICH — not a new adoption (autoresearch is already a pinned WALTEUR source and §9 L724 already names the loop in one s
- **https://github.com/0xNyk/lacp** `NEW-ADOPT` — NEW-ADOPT (scoped). Most of lacp overlaps WALTEUR and WALTEUR is stronger on routing/budget/memory/orchestration/learnin
- **https://github.com/mysticalsin/dotclaude (cloned as poshan0126/dotclaude — mysticalsin redirects to the same content)** `ENRICH` — ENRICH, not NEW-ADOPT. dotclaude is a lean starter kit whose AGENTS/SKILLS/RULES are all WEAKER-or-equal to what WALTEUR
- **coreyhaines31/marketingskills** `ENRICH` — ENRICH (3 artifacts), not NEW-ADOPT. WALTEUR is a SaaS BUILD orchestrator; the 45 marketing/GTM skills (CRO copy, cold e
- **vercel-labs/agent-browser** `ENRICH` — ENRICH — fold 3 (optionally 4) artifacts. agent-browser is the best-in-class agent browser-driver and, notably, already 
- **humanizr/humanizer** `ENRICH` — SKIP the .NET library itself — it is string/date/number formatting, not AI-text humanization; the task framing is a name
### Top P1 (batch 2b)
- **ship-security-gates.sh** [gate] — Fail-closed bash gate bundle wiring the 4 concrete CI-recipes from this repo into WALTEUR's ship-time layer: (1) secrets scan via gitleaks+t
- **design-seed-catalog (structure/doc)** [structure] — Add walteur-starter/.claude/skills/walteur-design/seeds/INDEX.md listing all 74 awesome-design-md brands grouped by archetype (dark-precisio
- **experiment-ledger.schema.json + experime** [gate] — Append-only walteur-kit/experiment-ledger.jsonl of {commit, metric_name, metric_value, baseline_value, status: keep|discard|crash, hypothesi
- **stop-rationalization-gate** [gate] — Port lacp hooks/stop_quality_gate.py into WALTEUR as a Claude-Code Stop-event hook gate: 8 heuristic rationalization regexes (pre-existing/o
- **test-claim-verifier** [gate] — Fold lacp stop_quality_gate.check_test_verification() (lines 352-396) into a WALTEUR fail-closed gate: when an agent's completion message cl
- **gate-fixture-harness** [tool] — Port hooks/tests/run-all.sh into WALTEUR as scripts/test-gates.sh: a fixture runner that pipes each tests/fixtures/<gate>/*.json {stdin,env,
- **ai-slop-prose-lexicon.txt** [doc] — Distill skills/seo-audit/references/ai-writing-detection.md + copywriting/natural-transitions.md 'AI Tells' into a flat greppable banned-tok
- **agent-browser-trust-boundary** [doc] — New rule Pro Coding/.claude/rules/browser-trust-boundary.md (PROTOCOL, mirrors existing memory-discipline.md format) adapted from skill-data
- **shared-dependency-hold-protocol** [doc] — Add a 'Shared-Change Hold' section to build-with-agent-team.md: when the contract-diff or planning reveals ≥2 parallel workers need the SAME
- ✅ **test-claim-verifier-gate** (lacp) — 11/11, gate 119; runs the actual test command when a build claims 'tests pass', blocks false-green. Allowlisted runners + dangerous-token guard + dry-run.
- ✅ **gate-suite** (dotclaude/gauntlet) — 7/7, gate 120; runs ALL gate selftests as one regression suite (meta-protection: a careless edit can't silently flip a gate open).
- ✅ **gate-suite FULL RUN: 92/103 gates GREEN, 4 broken** — the entire 120-gate arsenal verified green in one pass (2026-06-27).
- ✅ **gate-suite FULL RUN re-verified: 96/103 gate selftests GREEN, 0 broken** — found+fixed 4 more silently-broken gates (ai-safety/security/release/sbom restricted-PATH); the entire arsenal proven green together.
- ✅ **tool-liveness-probe** (Agent-Reach) — 6/6, gate 121; EXECs each required tool (missing|BROKEN-shim 126/127|timeout|ok), catches dead shims command -v misses.
- ✅ **skill-frontmatter-gate** (anthropics skill-creator) — 9/9, gate 122; enforces SKILL.md upload contract. FOUND+FIXED 8 real violations in the 190-skill Org library (raw <> breaking the loader + 1 oversized desc) → library now 190/190 conform.
