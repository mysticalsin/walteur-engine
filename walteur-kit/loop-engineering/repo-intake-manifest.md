# Best-of-breed repo intake — manifest (HARNESS_V2_REPORT + Tony's 2026-06-27 list)

> 50-agent pull, **gated on the session-usage reset (2:30pm America/New_York)**. One scout agent per repo:
> shallow-clone → analyze (skills / tools / structure / patterns / MCP) → propose the SPECIFIC foldable
> artifact for WALTEUR and flag WALTEUR-status (HAS-STRONGER · HAS-WEAKER/ENRICH · NEW-ADOPT · SKIP).
> Then synthesize+dedupe+rank → build the top adoptions (next workflow). Serialized in ~2 batches of ~20.

## Tier 1 — Agent harness / OS / orchestration
| Repo | Category | Likely fold into WALTEUR |
|---|---|---|
| ruvnet/ruflo | meta-harness, swarm | orchestration patterns for walteur.js; `.agents/` + `manifest.json` structure |
| affaan-m/ECC | agent OS, 156 skills | skill-library patterns; token-economics; eval-harness |
| earendil-works/pi | unified LLM API, multi-IDE | model-routing abstraction; `.pi/` config; cross-model relay |
| smtg-ai/claude-squad | multi-agent coordination | parallel-wave / fleet coordination |
| wshobson/agents | agent collection | reusable subagent definitions |
| 0xNyk/lacp | agent coordination protocol | multi-loop collision protocol |
| affaan-m/everything-claude-code | claude resources | misc patterns, hooks |
| mysticalsin/dotclaude | claude dotfiles | `.claude/` structure conventions |
| gsd-build/get-shit-done | GSD workflow | anti-context-rot; spec→plan→execute discipline |

## Tier 2 — Skills (SKILL.md system)
| Repo | Category | Fold |
|---|---|---|
| obra/superpowers | SKILL.md standard, mandatory invocation, TDD | skill-routing "MUST USE IF APPLIES"; already partly in WALTEUR |
| anthropics/skills | official Agent Skills spec | canonical SKILL.md format conformance |
| anthropics/knowledge-work-plugins | research skills | research-phase skills |
| addyosmani/agent-skills | 21 production skills (anti-rationalization) | anti-rationalization gate (already extracting); red-flag checks |
| forrestchang/andrej-karpathy-skills · multica-ai/andrej-karpathy-skills | karpathy skills | reasoning/research skills |
| Imbad0202/academic-research-skills | research→write→review→revise | research pipeline skill |
| karpathy/autoresearch | auto research | research loop pattern |
| product-on-purpose/pm-skills | product mgmt | PM/spec skills |
| coreyhaines31/marketingskills | marketing | GTM skills |
| nextlevelbuilder/ui-ux-pro-max-skill | UI/UX | design skills → design-gate enrichment |
| VoltAgent/awesome-design-md | design refs | design system corpus |
| vabole/apple-skills | apple HIG | design taste |
| mukul975/Anthropic-Cybersecurity-Skills | 754 security skills | security-baseline + gate enrichment |
| claude-world/notebooklm-skill | notebooklm | research/synthesis skill |
| humanizr/humanizer | humanize text | copy/voice skill |
| hardikpandya/stop-slop | anti-slop | anti-slop-code/ui enrichment |
| AgriciDaniel/banana-claude | misc skills | triage |

## Tier 3 — Token & context optimization (HIGH VALUE — serves "compress context" standing req)
| Repo | Category | Fold |
|---|---|---|
| rtk-ai/rtk | CLI proxy, 80-90% token cut | wrap dev commands; cost-budget integration |
| chopratejas/headroom | tool-output compression 60-95% | compress gate/CI output before LLM |
| yamadashy/repomix | repo→single-file packing | RESEARCH-phase context packing |
| colbymchenry/codegraph | pre-indexed code knowledge graph | codebase-RAG; MCP |
| Lum1104/Understand-Anything | interactive code knowledge graph | codebase comprehension |

## Tier 4 — MCP & browser / quality / memory
| Repo | Category | Fold |
|---|---|---|
| microsoft/playwright-mcp | official browser MCP | browser-proof / measured-quality (a11y snapshots) |
| jo-inc/camofox-browser | stealth browser | drop-in Playwright replacement |
| vercel-labs/agent-browser | agent browser | VERIFY-phase browser |
| Panniantong/Agent-Reach | internet MCP | research connectivity |
| nizos/tdd-guard | TDD enforcement | test-layer-coverage / TDD red-flag gate |
| letta-ai/claude-subconscious | subconscious memory agent | memory-staleness / persistent memory |
| thedotmack/claude-mem | claude memory | memory system |
| hesreallyhim/awesome-claude-code | curated list | scout source for more |
| garrytan/gstack | stack | scaffold patterns |
| harry0703/MoneyPrinterTurbo | AI video | (low harness relevance — SKIP unless a media skill is wanted) |

**Dedupe note:** the two andrej-karpathy-skills repos are variants (scout one, diff the other). superpowers / ui-ux-pro-max / get-shit-done / autoresearch / gstack appeared twice in the list — counted once.
