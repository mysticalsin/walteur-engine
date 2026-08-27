# WALTEUR — Integration Scout (better GitHubs to increase results)

**Date:** 2026-06-20 · **Method:** 17-agent workflow (10 web-search lanes → fit-assessment vs the live repo → ranked synthesis, ~1.07M tokens). 47 candidates assessed, ground-truth-grep-verified against WALTEUR's actual hooks.

> **Honest headline:** WALTEUR is near-complete for its scope; most of the 47 were noise (duplicate a shipped surface or violate a law). But a handful fill **grep-confirmed empty gaps** — capability additions, not polish. Nothing here needs a hosted runner, a second index, or stored keys.

---

## Adopt — 5 net-new tool integrations (each maps to a verified-empty hole)

| # | Tool | Eff | The confirmed gap it fills | Where it plugs in |
|---|---|---|---|---|
| 1 | **terryyin/lizard** | S | `maintainability-gate.sh` has M1/M2/M3 but **zero complexity metric** (grep: no lizard/CCN refs). ast-grep gates structure, lizard gates metrics — no overlap. | new M4 sub-check (cyclomatic complexity / fn length), detect-or-LOUD-SKIP, `-C`/`-L` configurable, good/poisoned twin |
| 2 | **DataDog/guarddog** | M | `osv-gate.sh` fires **only** on `MAL-*` / `database_specific.malicious` (verified verbatim) — a fresh typosquat/install-exec/exfil package OSV hasn't indexed slips through. Left-of-CVE detection. | new `guarddog-gate.sh` beside osv-gate on the P13 surface; pin ≥3.0; output = data |
| 3 | **opengrep/opengrep** | M | resilience-lint's own header says R6/R8 are **structural-only, no data-flow**. OpenGrep adds free inter-procedural source→sink **taint** across ~12 langs. | HARD gate beside ast-grep (P12) backing silent-failure-lint + the security re-prosecutor (#11); SARIF → twin discipline |
| 4 | **schemathesis** | M | `contract-gate.sh` stops at **static** spec lint — nothing drives a *running* API; QA Integration is LLM-judged. Turns OpenAPI/GraphQL into reproducible crash artifacts (prove-it, not assert-it). | new `api-fuzz-gate.sh` on the existing `surface: api` detection, after contract-gate; feeds §5.4 Integration |
| 5 | **agent-sh/agnix** | M | Nothing proves WALTEUR's **own** delivery surface (SKILL.md + hooks + MCP + CLAUDE/AGENTS.md) is spec-valid before distribution; selftest only checks agent-md frontmatter. RFC-2119 MUST/SHOULD → warning-first→HARD. | new `packaging-lint.sh` (opt-in, `required:false`); pin a version (churns fast); twin-prove subset before HARD |
| 6 | **confident-ai/deepeval** | S | The whole eval lane (deepeval/inspect/promptfoo/ragas) is **absent**. A failing metric assertion *is* a fail-closed gate — rides the **existing pytest runner**, no new dispatch. | prove-pillar + the pytest verification gate; local path only (no login); `DEEPEVAL_RESULTS_FOLDER` = the evidence prove-pillar cites |

---

## Adopt — high-value PATTERNS (idea, not the infra)

- **claude_code_agent_farm → claim-before-edit lock** (S). v9.2's spawn-justification (#10) + merge-base (#8) only *detect* a write collision; a lockfile over the frozen-briefs **owned-files** set *prevents* it. Prevention vs detection — the one open gap in the parallel strategy. Take the lock primitive, drop the tmux fleet.
- **Fission-AI/OpenSpec → delta-spec format** (M). spec-lint R6 only requires PLAN→PRD *reference*; there is **no change-as-diff primitive**. Vendor the ADDED/MODIFIED/REMOVED delta format into spec-lint R6 + spec-trace (markdown-in-git, no DB). Complements spec-kit (greenfield) for iterative change.
- **gepa-ai/GEPA → trace-reflection** (M). run-trace.jsonl (#2) + reflect.sh both exist, but the loop prunes by counters and never **proposes a targeted prompt/gate edit from a failure trace**. Lift reflect-on-trace → propose-edit → Pareto-keep onto `/optimize` reading existing spans. **Proposals only, human sign-off.** Reject the pip pkg (LLM-heavy); TextGrad is the documented runner-up.
- **ccswarm → replay/rollback** (M). run-trace.sh has `--read` but **zero replay/rollback** — time-travel debugging of a run for ~free on the existing NDJSON. (+ optional N-of-M quorum gate for high-stakes forks only.)
- **tbhb/vale-ears** (S). Vendor the 4 Vale rule files to promote spec-lint R7 EARS from advisory-nudge ("NEVER BLOCKS", confirmed) to a twinned warning-first→HARD gate.
- **metaswarm → orchestrator re-runs the suite itself** (M). Honor a panel PASS only if the gate-runner *itself* re-ran tests+coverage (host-verified, not self-reported). Closes the last trust gap in the review corps.
- **getgrit/gritql → autofix-recipe shape** (S). A FAIL also offers a reviewable in-repo rewrite — delivered on the ast-grep `--rewrite` engine already in the spine, no new binary.

---

## Watch (promote when a trigger fires)

inspect_ai (agent-behavior transcript + local viewer; if pytest path isn't enough) · EvoMaster (2nd API engine; after schemathesis proven) · mcpb (MCP-bundle gate; when an MCP build is in flight) · bearer (at-rest PII dataflow; Elastic License → optional) · joern (deep CPG taint; deep-audit tier only) · ossf/scorecard (dep health; needs a token-free path) · bencher (statistical perf thresholds vs the fixed >10% line) · capslock (Go capability-delta on P13).

## Rejected (law/anti-bloat — gaps by design)

**ruflo/claude-flow** (platform: 2nd brain + hosted hive-mind) · **ReMe / ace / textgrad** (duplicate shipped lesson-loop / 2nd optimizer) · **cargo-mutants / stryker-js** (already in mutation-gate.sh) · **mutahunter** (mandatory OPENAI key + AGPL + nondeterministic mutants) · **mcp registry** (always-on Postgres service) · **kics** (iac-scan already runs tfsec+checkov+conftest) · **skill-check** (strict subset of agnix). The two mutation engines surfaced a *real* adjacent gap though: `mutation-gate.sh` has **no --selftest twin** — that belongs to the twin-invariant track, not a tool import.

---

## Sequencing note

These are **deferred until the v9.2 refine-to-10 loop completes and the 10/10 is independently verified** — they edit the same canonical files (maintainability-gate, osv-gate area, resilience-lint, spec-lint, reflect.sh, walteur.js) the refine loop is touching, so adopting now would clobber it. Suggested order once clear: lizard (#1, S) + deepeval (#6, S) + the agent_farm lock + vale-ears (quick wins) → then guarddog/opengrep/schemathesis/agnix (the M-effort SAST/fuzz/packaging gates, warning-first) → then GEPA/OpenSpec/ccswarm patterns. Each lands warning-first, twin-proven before HARD, twin-synced across the 3 trees.
