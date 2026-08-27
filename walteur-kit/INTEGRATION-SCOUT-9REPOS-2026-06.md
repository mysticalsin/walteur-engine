# WALTEUR — Integration Scout, 9 user-requested repos (2026-06-21)

**Method:** 10-agent workflow (9 parallel repo assessors → synthesis). Read-only, web/clone-verified. Anti-bloat + one-brain law enforced.

> **Net:** only **3 of 9** genuinely raise WALTEUR's build power (each opens a lane it provably lacks). 3 are TOOLS for the products WALTEUR builds (recommend, don't adopt). ~8 are PATTERNS to absorb as prose. 6 are rejected (one-brain / portability / anti-bloat). Two most-starred repos (pi 64k, codegraph 52k) add the least to the engine — popularity ≠ net-new value.

## Integrate (3 — genuinely-empty lanes)

| # | What | Effort | Lane / how |
|---|---|---|---|
| 1 | **`anthropics/skills` → document-skills** (docx · pdf · pptx · xlsx, with real read/write toolchains: docx-js, pptxgenjs, pypdf+OCR, openpyxl+recalc) | **S** | NEW **deliverable/artifact lane** of the 13-layer build (output = Word report / board deck / financial model / filled PDF, not running code). **Install-as-plugin, never vendor** (license). Hands off to the `org-excel/docx/pdf` convention skills for formatting + the confidentiality-gate for egress. grep confirmed WALTEUR has zero docx/pptx/xlsx/pdf/pandoc/ooxml engine; the org look-alikes are prompt-only (no scripts). |
| 2 | **`anthropics/knowledge-work-plugins` → bio-research ONLY** (nf-core RNA-seq/WGS/ATAC-seq, scvi-tools single-cell, scanpy QC, Allotrope LIMS) | M | NEW isolated vertical companion **`walteur-bio`** alongside discover/design — reached for genomics/wet-lab/preclinical projects. Bio MCPs (PubMed/bioRxiv/ChEMBL/ClinicalTrials) = read-only sources next to context7, NOT a retrieval brain. Apache-2.0. 100% net-new vertical (zero in WALTEUR + 68 pm + 191 Org skills). Reject the other 12 plugins (duplicate pm-skills/Org corps). |
| 3 | **`mukul975/Anthropic-Cybersecurity-Skills` → CURATED ~15-25 defensive subset** (threat-modeling, DFIR, ATT&CK/D3FEND-tagged) | M | Into the existing `/security` + secure-coding + QA-Security dimension as a **graphify-indexed reference library** (`walteur-kit/security-playbooks/`) + an optional DFIR/incident companion. **NOT all 762** (35MB/198K lines = the biggest anti-bloat/file-scale violation on the table). Gives the security re-prosecutor citable attack paths. |

## Tools for projects WALTEUR builds (recommend; not harness-adopted)

- **camoufox / camoufox-js** (the UPSTREAM daijro engine, NOT the jo-inc wrapper) — when a project's scraping/automation target hard-blocks Chromium+Playwright (Cloudflare Turnstile, enterprise bot-detect). Browser lane (P08). The jo-inc wrapper itself is REJECTED (long-running Express daemon — breaks portable/file-scale).
- **`heygen-com/hyperframes`** (Apache-2.0 HTML→MP4) — the **license-clean** video escape hatch when a project can't accept Remotion's source-available company license. Video lane. (Watch: still 0.x, pre-1.0 churn.)
- **`earendil-works/pi` → pi-ai** (MIT standalone multi-provider LLM API, 20+ providers, unified tool-calling/streaming) — a provider-agnostic LLM backend for a WALTEUR-built product. (The pi CLI/TUI/harness itself is REJECTED — peer to Claude Code, zero net-new.)

## Patterns to absorb (idea, not infra)

- **codegraph** — maintained call-graph blast-radius (callers/callees/impact) + personalized-PageRank structural relevance → adapt INTO the v10 "graphify code-extension" bet (route through graphify; NOT a second SQLite index).
- **academic-research-skills** — (a) Lu-2026 7-mode AI-research-failure taxonomy → fold into the failure-triage router (#1); (b) source-anchored claim audit (fetch cited source, judge at quote+page granularity) → QA/honesty law; (c) concession-threshold anti-sycophancy (concede only if rebuttal ≥4/5, no consecutive concessions) → §5 governance/debate.
- **pi-ai** — runtime cross-provider context handoff (serialize convo → resume on another provider, convert thinking blocks) → enrich the `_relay/BATON.md` cross-model baton.
- **knowledge-work-plugins** — data-context-extractor meta-skill (mine analyst tribal knowledge → per-company data skill) → walteur-discover's per-project AGENTS.md/glossary generation.
- **Anthropic-Cybersecurity-Skills** — the ATT&CK / D3FEND / NIST-AI-RMF framework-ID frontmatter convention → label-enrich OSV/guarddog/opengrep findings.
- **Understand-Anything** — PATTERN-ONLY (store rejected): dependency-ORDERED guided onboarding tours.

## Rejected (6 — law / scope)

- **colbymchenry/codegraph** (as install) — own SQLite code-KG + own 8-tool MCP retrieval surface = **second brain** (one-brain law). Technique adopted as pattern; store refused.
- **Lum1104/Understand-Anything** (as install) — two parallel retrieval substrates incl. the exact embedding store v9.2 already declined. Second brain.
- **jo-inc/camofox-browser** (the wrapper) — long-running Express daemon + multi-platform deploy = breaks portable/file-scale. (The upstream camoufox engine is fine as a project-tool.)
- **earendil-works/pi** (as harness) — CLI/TUI/agent-core/sandbox duplicate the Claude Code runtime WALTEUR rides.
- **academic-research-skills** (the suite) — academic-manuscript domain (PRISMA/APA7/LaTeX peer-review) is out-of-scope; WALTEUR builds software. Patterns kept.
- **knowledge-work-plugins** (all but bio-research) + **anthropics/skills** (the other 12) — duplicate occupied lanes (pm-skills, Org corps, taste, mcp-author, skill-creator, claude-api already installed).

## Sequenced adoption (queued)
1. **[S, done this scout-tick]** install `document-skills` as a plugin.
2. **[M]** curated cybersec subset → `walteur-kit/security-playbooks/` + `/security` wiring (graphify-indexed; ~15-25 skills).
3. **[M]** `walteur-bio` vertical companion (bio-research) + its read-only MCPs.
4. **[doc]** record the 3 project-tools (camoufox/hyperframes/pi-ai) in the build's tool-selection guidance; absorb the ~8 patterns into their named surfaces (failure-triage, QA honesty, BATON, discover).
