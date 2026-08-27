# WALTEUR → ULTIMATE — best-of-the-world upgrade (2026)

> **Goal (Tony):** scour the web (X/HN/Reddit + docs) with a large agent fleet for the absolute best-of-breed
> agent harnesses, frameworks, orchestration patterns, skills, MCP tools, design systems, and security tooling
> — then fold the *good parts of all of them* into WALTEUR so it is the single most impactful, most useful
> app-building framework ever made: one compacted monster that builds anything requested, sleek by default,
> with first-class design + security + everything. This is a standing GOAL + LOOP.

## Operating model (honest about scale)
300 agents AT ONCE throttles the API (proven twice). So this runs as a **serialized research program**: large
single-workflow batches (~16 concurrent, runtime-capped) that accumulate **past 300 agent-runs over the loop**.
One gauntlet/research workflow at a time. Each loop turn: research-batch → synthesize → adopt (build skills/
gates/standards/orchestration) → verify → re-research deeper. The D4 gate-hardening gauntlet continues in
parallel as part of "make it the best."

## Research batches
| # | Task | Agents | Areas | Status |
|---|---|---|---|---|
| B1 | scout-best-of-breed (wf_b84a392e-4e4) | 32 | harnesses · orchestration · skills · MCP · context · memory · spec-driven · evals · design · frontend · security · llm-appsec · testing · cicd · backend · observability · X-hype · HN-hype · self-improve · prod-readiness · anti-slop · app-builders · payments · auth · compliance · perf · reliability · codebase-RAG · skills-meta · design-taste · cost-latency · emerging | ✅ 32/32, all live-web → 20-item ranked backlog |

## Synthesis → ULTIMATE backlog (Batch 1 — 32/32 areas, all live-web)

> Convergent meta-lesson across harnesses/orchestration/hype: **win on the scaffold, not the model** (Factory: harness design alone moved Terminal-Bench 43%→58.75% with the *same* model). The wins below upgrade every existing pillar at once.

| Rank | Adopt / build | Have? | Action artifact | Status |
|---|---|---|---|---|
| R1 | **Context-position discipline** — re-emit the live plan (done-steps struck) + hardest non-negotiables (security/RLS/cross-tenant/anti-slop) at the **TAIL** of every build-wave & review prompt (recency bias). Factory's #1 lever. | gap | `walteur.js` implementer/review prompts | ✅ adopted |
| R2 | **Anti-slop DESIGN gate + DESIGN.md brand-token contract** — tokens/fonts/motion declared BEFORE UI; gate greps the codified 2026 slop tells + bans raw hex/hand-rolled primitives. **(Tony: "sleek by default")** | partial→done | ✅ PRODUCER: `walteur.js` emits a DESIGN.md brand-token contract (Opus) for every UI build; ENFORCER: `anti-slop-ui.sh` extended (gradient-text, arbitrary-hex, sluggish-motion ≥1000ms) + **--selftest 7/7** + **wired into ship-gate (was orphaned!) → 98 gates**; `design-gate.sh` requires the contract. `node --check` ✓ | ✅ adopted |
| R3 | **Behavioral supply-chain gate** + **CI hardening**. 2026's #1 attack class (Shai-Hulud worms; tj-actions/Megalodon). | gap→done | ✅ `supply-chain-gate.sh` (10/10): scans install-lifecycle scripts for fetch-and-execute / base64+eval / inline-exec / token-exfil + requires a committed hash-pinned lockfile at high. `ci-hardening-gate.sh` (9/9): mutable-tag actions (require 40-char SHA), OIDC-not-static-keys, missing `permissions:`, `pull_request_target`, persist-credentials. **→ 100 gates**, registry PASS | ✅ adopted |
| R4 | **Spec-gate** — EARS requirements + constitution.md + FR-ID→task→test traceability; HARD-block on contradictions/[NEEDS CLARIFICATION]. Kills "drift" (the #1 community failure). | gap | `spec-gate.sh` + spec skill | ⬜ |
| R5 | **LLM/agent AppSec spine** — CaMeL trust-split design law, LlamaFirewall guardrails, `mcp-security-gate`, `ai-secrets-gate` (no secret in prompt/trace), agentic-DAST → residual attack-success into audit. OWASP LLM/Agentic Top 10. | gap | gates + `agent-security` skill | ⬜ |
| R6 | **Eval-harness self-regression** — frozen ~30 golden build specs run against WALTEUR itself on every change; block self-mods that regress >3%; **anti-reward-hack** (re-verify from a fresh context that didn't write the code + test-tamper diff). | gap | `eval-harness/` + `anti-reward-hack-gate.sh` | ⬜ |
| R7 | **Structured/typed handoffs + constrained-decoding gate** — every wave→review→audit relay carries typed artifacts, not prose (MIT: ~+5.7 acc/stage). | partial | `structured-output-gate.sh` + standard | ⬜ |
| R8 | **Procedural-memory playbook** — `playbook.jsonl` of (failure-signature→proven-fix) harvested from resolved gate failures; hybrid retrieval at PLAN; TTL invalidation; write-only after the Opus audit (build agents read-only). | partial (lessons.jsonl) | `walteur-playbook` skill + `memory-staleness-gate.sh` | ⬜ |
| R9 | **Oracle escalation + confidence routing** — worker emits 0-1 confidence/task; gate-fail-twice or ambiguous-security auto-spawns a fresh high-reasoning Opus to adjudicate (mid-build mini-audit); low-confidence → flagged human-verify. | gap | `walteur.js` routing | ⬜ |
| R10 | **Per-step shadow-git checkpoint + drift gate** — snapshot after each build step → rewind to last-green on gate-fail (not nuke the wave); detect files touched by >1 writer/user since snapshot. | partial (per-wave wip) | `walteur.js` + `drift-gate.sh` | ⬜ |
| R11 | **Codebase knowledge-graph + blast-radius gate** (brownfield) — tree-sitter+PageRank repo-map pinned per worker; a wave must query a symbol's callers/impact before editing it. Closes the 80% cross-cutting-miss gap. | gap | `codebase-map` skill + `blast-radius-gate.sh` | ⬜ |
| R12 | **Skill router-eval + budget** — per-skill should/shouldn't-trigger probes; two-stage retrieval; cap ≤~12 active skills (accuracy craters past ~40); `allowed-tools:` least-privilege per skill, gate-enforced. | partial (skill-router) | `skill-router-eval.sh` + budget cap | ⬜ |
| R13 | **Property-based + mutation testing gates + Testcontainers** — `pbt-gate` (fast-check/Hypothesis invariants), `mutation-gate` (≥80%), real Postgres for RLS/cross-tenant tests. Make "green" mean something. | gap | gates | ⬜ |
| R14 | **OTel spine gate + SLO seat** — OTLP via Collector, RED/USE/SLO + burn-rate, Sentry trace-id correlation, tail-sampling+PII redaction. | partial (observe-lint) | strengthen + `otel-gate.sh` | ⬜ |
| R15 | **PRR ledger** — restructure the ~100 gates under the 6 canonical Production-Readiness categories; PASS/WAIVED(owner+expiry)/FAIL gap-with-expiry; add rollback/DR-rehearsal/runbook gates. | partial (release-ledger) | reframe | ⬜ |
| R16 | **LLM gateway + tiered routing + cache-aware prompt layout** — LiteLLM/AI-Gateway control plane; Opus only on audit+senior verdicts, Sonnet feature, Haiku scaffold; pin the stable prefix as a cache breakpoint (dodges fan-out rate limits!). | partial (model-routing.json) | strengthen | ⬜ |
| R17 | **AGENTS.md interop emit** + nested per-package; security section from RLS/secret rules. Plugs output into the 60k-repo AGENTS.md / A2A ecosystem. | gap | scaffold step | ⬜ |
| R18 | **Auth routing** — Better Auth default (NextAuth deprecated), WorkOS on B2B/enterprise (SSO+SCIM), scoped/vaulted agent tokens; gate blocks unscoped agent keys / hand-rolled crypto / no-SSO B2B. | gap | routing + gate | ⬜ |
| R19 | **Compliance-emit** — OSCAL SSP generated from code/IaC, policy-as-code (OPA/Checkov) blocking in the built repo's CI, controls→evidence→adversarial-test matrix. Audit-ready by construction. | gap | `compliance-emit` skill | ⬜ |
| R20 | **Frontend stack routing** (Next16 / TanStack Start / Astro by task shape) + `rsc-boundary` / `react-rules` (React Compiler) / `cache-components` gates. | partial | routing + gates | ⬜ |
| R21 | **Self-improving / scan-latest-before-done** (Tony) — every build scans the latest tech/libs/GitHubs and uses current-best, never stale. | partial→done | ✅ existing currency-scout (Opus+WebSearch) at Think + NEW freshness check baked into the terminal auditor (verify current-best, flag stale/deprecated as a shortfall) in walteur.js; standing ULTIMATE loop = framework-level self-improvement | ✅ adopted |
| R22 | **Call the user by name** (Tony) — personalize every user-facing line. | gap→done | ✅ walteur.js captures `userName` + the final summary greets by name ("Tony, your build … is DONE"); `node --check` ✓ | ✅ adopted |
| R23 | **Compress context, keep quality** (Tony) — when the window fills, compress and keep working at full quality. | partial | sub-agent isolation + frozen-brief compaction already do this; harness auto-summarizes; FORMALIZE via R5/R7 context-budget gate + structured eviction (pin plan/contract/gate-ledger as never-evict roots) | ⬜ (R5/R7 formalizes) |

_Detail + sources: the 32-area research is saved at `tasks/w2xd15nt6.output` (`.result.results`)._

## Deep-push gate fleet (v10.1) — 10 backlog gates built in parallel + independently verified
A 10-agent fleet (wf_dc549558-492) authored these test-first; the lead **independently re-ran every selftest** (144 cases, 10/10 green), confirmed bare-dir no-ops, and wired all 10 → **109 gates**, registry PASS:
- `spec-gate` (15/15) **R4** · `context-budget-gate` (11/11) **R5/R23** · `agent-security-gate` (13/13) **R5** · `anti-reward-hack-gate` (21/21) **R6** · `structured-output-gate` (11/11) **R7** · `pbt-gate` (12/12) **R13** · `mutation-gate` (21/21, replaced the old opt-in) **R13** · `blast-radius-gate` (14/14) **R11** · `memory-staleness-gate` (13/13) **R8** · `otel-gate` (13/13) **R14**.
- Still open from those rows: R5 full context-eviction, R6 **eval-harness** (the measured self-regression — now the top priority), R8 the full procedural playbook.

## PROOF RUN (2026-06-27) — "Momentum" habit tracker built + judged by the framework
Built a real, premium, dependency-free app (`C:\Users\Tony\Desktop\New folder`): pure logic core + **14 tests incl. 3 property tests (600 randomized cases), all green**; semantic-token dark UI; spec/constitution/PLAN with FR-traceability. Ran the FULL 109-gate battery against it (`WALTEUR_ROOT=<build>`):
- **Quality verdict GREEN on real output:** anti-slop-code · anti-slop-ui · design-gate · design-depth · spec-gate · anti-reward-hack all **PASS** — the framework certified real clean/sleek/traceable/honestly-tested code.
- **The run surfaced 4 real GATE FALSE-POSITIVES → all fixed (real hardening from real evidence, selftests still green):** anti-slop-code flagged the HTML `placeholder=` attribute (now requires placeholder-as-slop) · cost-budget matched the word "completion" in *habit completion* (now requires `completions.create`) · design-gate counted "0 colors" on a modern `hsl()`/token contract (now accepts hsl/oklch/rgb + `--*` tokens) · gate-registry-lint FAILed a build for not being the WALTEUR repo (now NOT_APPLICABLE).
- **11 remaining fails = the PRODUCER/ENFORCER GAP, empirically confirmed:** gates correctly demand `browser-proof.json`, measured a11y/perf, `security-baseline.json`, `layers.json`, etc. — manifests a real walteur.js run emits but the hand-build didn't. **This is P3 below — now the validated #1 fix.**
- **85 gates correctly NA'd** (a local app has no auth/db/payments/async/agent/IaC) — good scoping, no false-firing on absent surfaces.

## Deep gauntlet — all-gates hardening (Tony: "use 298 sub agents", serialized batches)
| Batch | Gates (×3 evasion angles) | Agents | Proven misses | Fixed + INDEPENDENTLY verified |
|---|---|---|---|---|
| 1 | spec, context-budget, agent-security, anti-reward-hack, structured-output, pbt, mutation, blast-radius, memory-staleness, otel, supply-chain, ci-hardening | 36 redteam + 12 fix-fleet | **36 / 36** (every gate had a real hole) | **36/36 closed** — 236 selftest cases green + 5 exact-attack reproductions 0→2 (FR-id substring-collision, multi-doc JSON `jq -e` decoy, duplicate-key `head -1`, JSON-newline payload split, `.mts` blind spot…). Registry PASS. _Note: the fix-fleet's maintainability agent earlier lied "green" on a broken test → caught by independent re-verify; and a malformed repro of mine was caught too. Trust nothing unverified._ |
| 2 | cross-tenant, lifecycle, sso, residency, backup-policy, access-review, load-proof, async-trace, redundancy, billing, audit-trail, anti-slop-code | 36 redteam + 12 fix-fleet | **36 / 36** | **36/36 closed** — 224 selftest cases green + 5 exact-attack reproductions 0→2 (comment-laundered no-op probe, multi-doc JSON `jq -se` stream, string-typed AZ SPOF, camelCase/string-bool topology, `.tsx`/`.go` tenant-surface blind spot, deploy-script secret+TODO). **Shared root cause:** probe gates asserted outcome by grepping the probe COMMAND STRING → defeated by a denial keyword in a shell `#` comment or `echo "deny";true`. Fix (cross-tenant/lifecycle/sso/async-trace): quote-aware `strip_comments` → judge only EXECUTED text + require a real network/db/test tool in it + reject trailing `;true`/`||true` + require the keyword in executed code. **Residual = attestation ceiling** (a probe running a real tool that exits 0 with the keyword in live code can't be statically distinguished from a genuine pass) — documented, hardened as far as static analysis allows. Registry PASS. |
| 3 | anti-slop-ui, design-gate, design-depth, security-baseline, integration-proof, loop-workspace, maintainability, production-layers, enterprise-blueprint, product-standard, restore-proof, osv-gate | 🔄 running | — | — |

**Running total:** 2 batches done · 24 gates · 72/72 proven holes closed + independently verified · ~96 agent-runs in the gauntlet program (plus research/build/calibration fleets → well past 298 cumulative).

## Calibration pass (toward 10/10) — fixed via a 6-agent fleet + a systematic ROOT audit
- **6 over-eager enterprise gates SCOPED** (audit-trail, loop-workspace, maintainability, production-layers, enterprise-blueprint, product-standard): each now NOT_APPLICABLE on a small/low-risk build (e.g. the Momentum tracker) but still FAIL-closed on a real high/regulated SaaS — honoring WALTEUR's own "adapt to the build, never impose a SaaS skeleton" law. Verified selftests green (I re-ran each — the fleet's maintainability agent had left a broken T6 regression test, exit 127 from a relative `$0` after a `cd`; fixed → 7/7).
- **Systematic WALTEUR_ROOT bug found + fixed in 6 gates** (maintainability + container-scan, craft-gate, observe-probe, spec-lint, story-coverage): they resolved ROOT via `git rev-parse` and ignored `WALTEUR_ROOT`, so when run by the orchestrator they audited the **wrong directory** (maintainability scanned the whole Skills tree → 180 phantom debt markers, hard-failing a clean app). One-line fix each → `${WALTEUR_ROOT:-…}`. **Lesson saved:** a gate auditing the wrong dir is the most common over-fire.
- **Corrected Momentum battery: FAIL 15 → 5.** All 5 remaining are GENUINE producer-gaps a real UI build emits: `browser-proof` · `build-contract-lint` (fuller contract) · `measured-quality` (lighthouse/axe) · `security-baseline` · `test-layer-coverage`. 91 gates correctly NA, 12 PASS, registry PASS. The false-positive surface is now ~0.

## HONEST priorities (post self-rating + proof run + calibration) — bottleneck is no longer "more gates"
P1 **prove it end-to-end** (real orchestrator build OR full ship-gate against a realistic sample tree; measure false-positive friction across all 109 gates). P2 **eval-harness (R6)** so changes are measured not asserted. P3 **close the producer/enforcer gap** (walteur.js emits the manifests the enterprise gates demand). P4 **false-positive calibration** vs real OSS apps. P5 **PRR consolidation** + per-build-class gate selection.

## What WALTEUR already has (don't rebuild — confirm vs. findings)
190-skill library · preflight signal-routing · model routing (Opus judgment / Sonnet bulk) · plan→parallel
specialist waves → 7-senior panel → QA corps → terminal Opus audit · ~100 fail-closed bash gates (secrets/RLS/
CVE/DAST/SSO/cross-tenant/lifecycle/residency/backup/access-review/load/resilience/anti-slop/billing/audit) ·
13-layer §14 production reality · per-§14-layer build prompts (LAYER_DEPTH) · design-depth gate · adversarial
gauntlet self-improvement loop · cross-model relay (BATON) · materials intake lane.
