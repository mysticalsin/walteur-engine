# Materials intake — WALTEUR → 10 upgrade

The incoming-materials lane for the upgrade. Every document, image, screenshot, brand
reference, or instruction Tony drops gets a row here so it is **traceable** and **nothing
silently vanishes**. Folds materials in "as we go."

## Intake law

A material is not "done" until its row reads **`status: folded-in`** AND **`applied_in`**
cites a real artifact (a file path, a gate, a doc section, or a commit). An `inbox` row is a
visible promise that triage is owed. Images get an `alt` line because a future agent cannot
see the PNG.

## Folders

| folder | holds |
|---|---|
| `docs/` | text documents (specs, notes, PRDs, transcripts) |
| `images/` | screenshots, infographics, brand refs, diagrams (each needs an `alt` description) |
| `instructions/` | standing instructions / directives from Tony |

## Naming

`YYYY-MM-DD__<kind>__<slug>.<ext>` — kind ∈ `doc | image | infographic | brand | instruction | screenshot`.

## Routing rules

- **Brand reference** → route to `DESIGN.md` / the `walteur-design` skill (`informs: DESIGN.md`).
- **Architecture infographic** → `docs/ARCHITECTURE.md` (or the relevant `walteur-loop.png`).
- **Bug / run screenshot** → attach as evidence to the relevant fix row (same convention as
  the existing `browser-proof` screenshots).
- **Instruction** → capture as a preference/procedure and cite where it changed behavior.

## Register

| id | file | kind | dropped | summary (≤25w) | informs | status | applied_in | provenance | alt (images) |
|---|---|---|---|---|---|---|---|---|---|
| M000 | `../../../Improvement Walteur.md` | doc | 2026-06-26 | The retro grading WALTEUR 8.5/10; the 6 fixes + "full potential" bar + scorecard. The source of this upgrade. | all fixes | folded-in | `UPGRADE-2026-06.md`, plan `snazzy-spinning-flask.md` | Tony (Opus 4.8 retro) | — |
| M001 | (chat image) | infographic | 2026-06-26 | "Claude Code Project Structure" — generic CLAUDE.md / `.claude/` layout reference. Low relevance to WALTEUR internals. | reference only | triaged | — | GenAI.works infographic | Folder tree: CLAUDE.md, .mcp.json, .claude/{settings,rules,commands,skills,agents,hooks} with one-line descriptions of each |
| M002 | (chat image) | infographic | 2026-06-27 | "Agent Swarms" — orchestrator spawns specialized subagents, fans out tasks, collects results. Mirrors WALTEUR §5.6 SWARM / walteur.js. | §5.6 SWARM (already implemented) | triaged | confirms existing walteur.js | community infographic | Orchestrator box (tools: create_subagent, assign_task, search, browser) → creates subagents (AI/Physics/Life-Sciences/Anthropology Researcher, Fact Checker, Web Developer) → assigns 100 research tasks + 25 dev tasks in parallel → each returns task results → Final Results |
| M003 | (chat image) | infographic | 2026-06-27 | "Full-Stack Production Reality" — a 13-layer stack. This IS WALTEUR §14; the user's point is run #1 didn't ENFORCE the backend/API/security layers. | §14 + security-baseline-gate | folded-in | security-baseline-gate.sh, §14 layer map | community infographic | A vertical stack of 13 colored layers, top→bottom: Frontend · APIs & Backend Logic · Database & Storage · Auth & Permissions · Hosting & Deployment · Cloud & Compute · CI/CD & Version Control · Security & RLS · Rate Limiting · Caching & CDN · Load Balancing & Scaling · Error Tracking & Logs · Availability & Recovery |
| M004 | (chat image) | infographic | 2026-06-27 | "Claude Code workspace" cheatsheet — full project tree WITH backend (src/services/{api,auth,database}.ts, tests/{unit,integration,e2e}). Confirms backend/API scaffold coverage. | scaffold / §14 backend coverage | triaged | verified against scaffold archetypes | community cheatsheet | Detailed my_project/ tree: CLAUDE.md, .claude/{settings.json, commands/, skills/{code-review,text-writer,security-audit,refactor}/SKILL.md, agents/, plugins/}, .mcp.json, src/{components/{auth,dashboard}, services/{api.ts,auth.ts,database.ts}, utils/{logger,validators}, types}, tests/{unit,integration,e2e}, docs/{architecture,api-reference,onboarding}, scripts/{setup,deploy,seed.db}. Side panels: settings.json + .mcp.json structures, CLAUDE.md template, hook events, MCP servers, context-management thresholds |
| M005 | (chat text) | instruction | 2026-06-27 | The 11-point security/production hardening checklist (privacy/GDPR, RLS, auth failure-path tests, security headers, OWASP, server-side validation, data-leak check, no frontend secrets, rate limits, CAPTCHA+CORS, safe error messages). "Build fast, don't ship naked." | security-baseline-gate (the centerpiece) | folded-in | security-baseline.json + security-baseline-gate.sh | Tony (curated checklist) | — |
| M006 | https://github.com/CyberStrikeus/CyberStrike.git | reference | 2026-06-27 | CyberStrike — AI-powered pentest agent: 13+ security agents, 120+ OWASP test cases, OWASP WSTG/MASTG/CIS/MITRE ATT&CK, 8 proxy testers (IDOR, authz-bypass, injection, SSRF, mass-assignment). AGPL-3.0. | security-baseline OWASP item + recommended pentest tool | folded-in | security-baseline-gate (OWASP categories) + source-manifest note | CyberStrikeus/CyberStrike (AGPL-3.0) | — |
| M007 | https://github.com/Archive228/loopkit | reference | 2026-06-30 | loopkit — 33 PROTOCOL coding-agent skills (debug · git · security · test · refactor · docs · agent-discipline). Audited line-by-line, NO code executed. Harmful bits EXCLUDED: install.sh, `.mcp.json` (auto-npx + token), prettier PostToolUse hook (would break twin-invariant). ~20 overlap existing HARD gates (maps_to noted); 10 fill genuine debug/git gaps. | skill-index router + `skill` dimension (PROTOCOL, not HARD) | folded-in | `Tony Skills 2026/Org Skills Library/**/loopkit-*` (33 vendored, MIT provenance headers) · `walteur-kit/skill-index.json` 191→223 both kits (lint PASS, twins identical) · `_vendor-loopkit/PROVENANCE.json` | Archive228/loopkit (MIT) | — |

_Add new rows as materials arrive. Keep `inbox` rows visible until triaged._
