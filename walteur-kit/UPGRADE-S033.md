# UPGRADE S033 — the push past the ~60 autonomous ceiling (2026-07-01)

Goal (Tony): make WALTEUR able to one-shot any request at 100/100 — with design, skills,
MCP data-pull, and full figure-it-out autonomy. Honest framing: 100 requires the field-proven
high band (external users + outcomes), which is gated on Tony's own ship actions. This upgrade
maximizes every autonomously-movable dimension and stages the field routes so each is
one command for Tony.

Baseline: S032 = 60/100 · enf72 rob82 orch76 usab48 field32 sdlc72 skill48 maint72
(weights 18/10/14/6/22/12/12/6). Gate-suite PASS 106/115 green, 0 broken.

Evidence source: 11-reader adversarial analysis (session b4ef5ca5, `scratchpad/analysis.json`),
every dock file:line-cited. Score movement is only EARNED via independent re-panel (honesty law).

## The confirmed killers (from the analysis, all file:line-verified)

1. **EXEC is built but never armed** — 5 gates carry complete, selftested EXECUTE modes
   (test-layer-coverage, cutover, chaos, audit-contract, authz-tenant) behind env flags that
   NO runner ever sets: dead code in every real run.
2. **The skill router routes but nothing dispatches** — routed skills never reach any agent
   prompt (walteur.js has zero skill references in the build/review sections); skill-readiness
   passes on an empty breadcrumb file; enforceable coverage 6/223.
3. **Tool absence reads as green** — 38 hooks SKIP-exit-0 on missing jq; every tool-runner
   SKIPs-exit-0 when its tool is absent; execution-ratio excludes SKIPs from its denominator
   (a toolless box looks MORE executed); code-build auto-floor is 1.
4. **Reports are hand-writable** — `echo '{"verdict":"PASS","observed_exit":0}' > x-report.json`
   is indistinguishable from a real executed gate; freshness verified nowhere; stamp.sh will
   immortalize an unverified free-text proof claim.
5. **Usability surface is thin and partly false** — 9/137 gates tabled in REMEDIATION.md;
   the documented `--help` recovery path silently EXECUTES the gate in ~149/152 hooks.
6. **The engine can't close its own loop** — after corrective refine it never re-audits
   (shippable=false is predetermined); assumptions evaporate; missing tools end the run;
   no deferral protocol; one telemetry hiccup kills the ship verdict.
7. **No MCP/data layer** — a data-needing build that never pulls real data passes everything;
   data-tools.json is prose, not a connectable manifest; tool-liveness-probe mis-parses the
   canonical required-tools.json on its live path (confirmed defect).
8. **Design is advisory on the common path** — measured-quality accepts fabricated Lighthouse
   JSON; craft gates relax to non-blocking below risk_tier=high; the mandated craft engine
   skill doesn't exist on disk.
9. **CI is inert** — no .github/workflows anywhere; the shipped CI template would fail the
   kit's own ci-hardening-gate (mutable action refs, all-zeros SHA pins accepted as valid).
10. **Field-proven evidence is fragile** — the publish-ready jsonlint-cli lives only in a
    session Temp scratchpad; no repository field; stale shippable:false receipt.

## Execution plan (Sonnet builders, disjoint file ownership, twins synced at the end)

**Wave 1 — 14 parallel builders** (each: LF-only bash, selftest N/N + negative control, no
registry/STAMP/walteur.js/ship-gate edits outside ownership):

| # | Owner | Files | Delivers |
|---|-------|-------|----------|
| 1 | exec-defaults | 5 EXEC-mode hooks | build-class-aware EXEC default ON for code builds (opt-out env) |
| 2 | exec-ratio | execution-ratio-gate.sh | SKIPs in denominator + cannot_measure budget + report-ts freshness + floor 1→3 (code) |
| 3 | probe-unify | sso, lifecycle-access, cross-tenant, integration-proof, async-trace | all point at _probe-proof.sh (one audited kernel) |
| 4 | exec-breadth | qa-contract, load-proof | re-run recorded commands (test-claim pattern), emit execution markers |
| 5 | authenticity | mutation, browser-proof, migration-roundtrip | fabrication floors + replay + sqlite default-execute |
| 6 | skill-receipts | skill-readiness.sh + new schema | content-bound receipts (artifact refs + verdict + ts), empty-file = FAIL |
| 7 | skill-router | skill-router.mjs, skill-index.json | revive rule 3, ~25 curated bindings, signal_tags backfill, has_ui→design skills |
| 8 | ship-rob | ship-gate.sh (both copies), stamp.sh, new report-integrity-gate.sh | un-drift twins, kill true|: hole, stamp refuses unproven claims, report freshness+coherence gate |
| 9 | maint-twin | eval/twin-invariant.sh, .claude/hooks shim | extend invariant to .claude/hooks, shim negative-control selftest, re-sync live drift |
| 10 | sdlc | ci-hardening-gate.sh, .github/workflows/ci.yml, definition-of-done-gate.sh, sdlc-run-gate.sh | reject placeholder SHAs, activate own CI (gate-green), per-build-class DoD floor, staging E2E probe |
| 11 | mcp-data | mcp-manifest.json, tool-liveness-probe.sh, new data-pull-required-gate.sh | machine-readable MCP layer, fix confirmed parser defect, kill passes-by-being-empty |
| 12 | design | measured-quality, apple-grade, design-depth, design-gate + walteur-design/SKILL.md | execute-or-fail measurement + provenance, fail-closed craft floors for user-facing, fix dangling craft-engine chain |
| 13 | usab-doctor | doctor.sh, README.md, QUICKSTART.md | doctor = failure triage, first-run path, README nav |
| 14 | field | field-runs/jsonlint-cli, PUBLISH-RUNBOOK.md, new field-ship-verify-gate.sh, _relay/receipt.json | rescue artifact from Temp, one-command publish, machine-verified ledger rows |

**Wave 2 — serialized:**
- **Engine surgeon** (walteur.js + walteur-run.mjs, one owner): mechanical skill-router run in
  Preflight + routed-skill injection into phase-agent prompts (the DISPATCHER), EXEC-flag arming
  for code builds, data_needs classifier + arming wire, re-audit after corrective refine,
  assumption ledger (assumptions.json), deferral protocol (deferrals.json), infra-vs-product
  failure classification, flushSpans projectPath normalization, planned-vs-actual path-normalize,
  per-phase token reconciliation into spans, acquisition breadcrumbs. Proof: node --check +
  walteur-js-logic selftest + walteur-run.mjs exit 0.
- **Registrar**: add new gates to gate-registry.json, gate-registry-lint green.
- **Remediation table**: fix-recipe rows for EVERY registry gate + remediation-coverage-gate
  (mechanically lints table vs registry, and --help presence).
- **Help sweep**: standard --help arm in all hooks (after all other hook edits).

**Wave 3 — verify + earn:**
- Twin sync to walteur-starter (byte-identical), twin-invariant ×3-5 (drift can be a transient
  sibling race — verify repeatedly).
- Full gate-suite: broken:0 required; fixer agents on fallout.
- Independent adversarial re-panel (8 dims, verify-then-score, default-low, file:line-bound).
  Independent number wins. Stamp S033.

## RESULT (earned 2026-07-02)

Independent 8-dim verify-then-score re-panel (default-low, file:line + live-rerun, every dim
`fix_is_real:true`): **60 → 64/100.** Per-dim: enf 72→75 · rob 82→85 · orch 76 (held) ·
usab 48→58 · field 32 (held) · sdlc 72→78 · skill 48→55 · maint 72→77. Weighted 63.74 → 64.
Gates 137→142. gate-suite PASS 113/119, broken:0, twin drift=0. Stamped **S033** through
stamp.sh's own truth-binding (fresh PASS suite report required). NEW capability: TEAM MODE.

Held honestly: **orchestration** (engine surgery + team mode are real + source-verified but
were not run end-to-end with real agents/terminals this session — no credit until a real run)
and **field-proven** (all machinery real, but the weight-22 score is gated on real external
users/URL — `npm whoami`=ENEEDAUTH).

Residuals the panel flagged (next work): stamp.sh still accepts a hand-forged *fresh bare
PASS* gate-suite-report (spoofing narrowed one hop, not closed); report-integrity runs
advisory in ship-gate by default; skill-dispatch + team-mode are wired-not-run.

## What still needs Tony (the road from 64 to 100)

1. `npm publish` of jsonlint-cli (publish-ready; runbook staged) — breaks the field-proven 32 cap.
2. Consent to push a public GitHub repo (+ CI receipt) and a GitHub Pages ship — second/third
   verified public URLs.
3. Real external users + one outcome metric — the rubric's mid/high band (field 50-90+).
   The outcome-metric capture loop ships in this upgrade so the evidence is verifiable the
   moment users exist.
