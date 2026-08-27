# Changelog

## Versioning schemes
Four schemes coexist by design, not by drift: **README.md**'s v9.x history is a granular per-gate/selftest
engine stamp; **CHANGELOG.md** (this file) uses v10.x for feature-level release narrative; **STAMP.md**'s
S-numbers are the immutable, sha256-chained certification ledger (one append-only row per
independently-scored change); **release-ledger.json**'s `current_version` (now `10.20`) is the
machine-checked release truth (schema/mirror/registry/proof-count validated before publish). CHANGELOG
v10.3 and STAMP S001 describe the same event — the anchor point where the two ledgers start running in
parallel. This prose goes stale by design — read the version, don't trust the sentence:
`jq -r '.current_version' walteur-kit/release-ledger.json`.

## 2026-07-25 — doc-surface currency pass (panel #12, docs dimension)

Panel #12 found the gate count stated **four different ways across eight doc/data surfaces** while the
live registry read 150 total / 61 HARD. Fixes below are limited to the doc surfaces; no gate, threshold,
registry entry or report was touched.

### Fixed
- **`FEATURES.md`** — the catalog's own stated job is "where the capabilities are actually explained", and
  it stopped at v10.3 (2026-06-28) while the shipped release was v10.20. Now carries a **Currency block**
  (the four `jq` commands that print live truth, plus a where-to-look table), new sections for **v10.20**,
  the **v10.6→v10.19 S-ledger span**, **v10.5** and **v10.4**, and four corrected claims: the stale
  `143`/`59` gate pair → the live **150 total / 61 HARD**; selftest `160/0/0` → the ledger's certified
  **243/0/0**; self-audit `98/100` → **100/100** (`walteur-kit/harness-audit-report.json`, with the
  three-different-0-100-scores confusion named explicitly); and `no field miles yet` → the honest split
  (**8 internal field runs** FR-1→FR-8, **zero verified external ships**).
- **`DESIGN.md`** — annotated in-file as the load-bearing selftest fixture it is: names the **12 hooks**
  that read it (`grep -rl 'DESIGN\.md' walteur-kit/hooks/*.sh`), records the reproduced consequence of
  deleting it (`design-gate.sh <dir>` exits **2** with a UI file present, 0 when restored), and states
  that unlike `PLAN.md` it has **no** `walteur-kit/` copy. Kept as an HTML comment so no gate's key
  parsing changes — `design-gate .` and `design-depth-gate .` still exit 0, `design-gate --selftest` 16/16.
- **`LOOP.md`** — `preflight-signals.json` is a **per-build** artifact (it lives in each
  `field-runs/<app>/walteur-kit/`, deliberately absent from this repo), not `walteur-kit/preflight-signals.json`
  as written; `cost-budget.sh` given its real path (`walteur-kit/hooks/cost-budget.sh`); the kill-switch
  claim now ships the temp-root command that reproduces `rc=2` without pausing this repo.
  `loop-readiness-gate` still PASS (L3, 94/100).
- **`PUBLISH-RUNBOOK.md`** — "TWO publish-ready artifacts" was written 2026-07-01 and missed the third:
  **Artifact C / Route 4**, the `design-proof-app` build already committed to `docs/live/` with
  `.github/workflows/pages.yml` wired. Recorded as **staged, not shipped** — no `SHIPPED.md` row until the
  URL answers 200 to a third party — and the 2026-07-01 credential facts are now dated rather than
  asserted as current.
- **`CHANGELOG.md`** (this file) — the Versioning-schemes paragraph still said `current_version` was
  `10.0`; it is **10.20**.

### Added
- **`docs/EXPECTED-REDS.md`** — `bash walteur-kit/hooks/doctor.sh` exits **1** on this tree with **29 FAIL
  reports** and no doc predicted it. The page separates the 7 "harness-is-not-a-product, manifest absent"
  reds (verbatim reasons) from the substantive-finding reds, verifies that all 29
  `REMEDIATION.md#<anchor>` fix recipes resolve, and states plainly that nothing is excluded, downgraded
  or accepted — the count is expected to fall, and a rise is a regression.

### Still red (deliberately, not mine to close)
- **`docrun` FAIL — 10 blocks.** Every failure is in a file outside this pass's scope
  (`field-runs/engine-humansize/README.md`, `field-runs/jsonlint-cli/README.md` ×5,
  `walteur-kit/PENDING-SETTINGS-PATCH.md`, `walteur-kit/harness-100/PENDING-HOOKS-PATCH.md` ×3): console
  transcripts and partial source citations fenced as ```` ```shell ````/```` ```bash ````. The 3 new
  blocks added by this pass all pass `bash -n` (`blocks_checked` 95 → 101, failures unchanged at 10).
- **Gate count on `QUICKSTART.md` (146), and the proof-claim enforcement set.**
  `release-ledger.json.proof_claim_paths` covers only README.md, walteur-kit/README.md, walteur/SKILL.md
  and WALTEUR-builder-CLAUDE.md — which is exactly why FEATURES/QUICKSTART/STAMP were the three that
  drifted. Adding the remaining count-bearing surfaces to that list needs the ledger, which this pass does
  not own.

## 2026-07-11 — karpathy-discipline rule (aphorisms promoted to protocol)

### Added
- **`rules/karpathy-discipline.md`** (live `.claude/rules/` + distribution `walteur-kit/rules/`,
  byte-identical) — the karpathy-guidelines skill (MIT) promoted from "quality-reference" to a
  delta-only PROTOCOL rule, per the source-manifest `promotion_policy` (trigger: explicit user
  request). A 4-agent coverage map of the spec/gates/rules found the four principles already covered
  at PHASE boundaries (§2 pre-flight, §5.3 forks, §10 blockers, §6.1 one-liners, terminal audit); the
  rule carries only the per-change delta: mid-build confusion-surfacing (below fork-class), three
  named simplicity prohibitions (single-use abstraction · unrequested configurability ·
  impossible-scenario handling), the pre-commit diff walk + mention-don't-delete duty, and
  sub-gate-threshold verifiable goals (`[step] → verify: [check]`).

### Changed
- **`walteur-kit/source-manifest.json`** — `andrej-karpathy-skills.adopted_surface` UPDATED in place
  (schema is closed; explicit update, not a duplicate entry) to record the promotion.
- **Spec twins §6.1** (`WALTEUR-builder-CLAUDE.md` + `walteur/SKILL.md`, identical edit, `cmp` PASS
  after) — the rule is now WIRED into the v10 code standard as the per-change delta companion, not
  just distributed. twin-invariant violation count unchanged by the edit (89 before = 89 after — all
  pre-existing cross-distribution drift, see below).

### Known reds — CLOSED same day (v10.20)
Both pre-existing reds above were driven to green in the follow-up pass, with proof:
- **Aggregate selftest re-run: 243 passed, 0 failed, 0 skipped — ALL GREEN, in-sandbox** (the 6
  residual in-sandbox fails recorded on 2026-06-23 no longer reproduce).
- **`release-ledger-lint` FAIL → PASS**: ledger reconciled to the fresh real proof —
  `current_version` 10.19 → **10.20**, `aggregate_proof.expected_passed` 241 → 243, matching
  `aggregate_history` row appended, spec twins' prose proof-claim (line 60) updated 241 → 243.
- **`twin-invariant` 89 → 0 (PASS, 183 checked)**: Tony-approved mirror sync of 89 stale/missing
  hook twins (88 `walteur-kit/hooks/` + 1 `.claude/hooks/`) from this repo into the sibling
  `walteur-starter` scaffold (fresh side → stale side; backup tar in session scratchpad). The 6
  previously-missing v10 gates (excellence-loop · lesson-gate · integrator-audit ·
  injection-resistance · design-contrast · design-scale) now exist in the scaffold.
- `gate-registry-lint` real-file PASS re-confirmed after all edits.
- Tooling trap found en route: rtk-proxied `diff` reported two DIFFERING twin files as
  "identical" — `cmp`/`shasum` disagreed and were right. Trust `cmp` for byte-identity claims.

### Recovered
- **`.git` corruption (OneDrive sync)** — `refs/heads/main` was an empty file; restored from the
  `.git/logs/HEAD` reflog to `a86d7c0` and the 385-file uncommitted harness-100 delta committed as a
  state-sync commit. Two broken-name refs (`v9-Toto's Mac.1-hardening` variants, duplicates of
  `v9.1-hardening` @`3ab2c22`) still block `git fetch` and need manual removal. Remote note:
  `origin/main` (mysticalsin/rocket-fuel) now carries a diverged rocket-fuel history force-pushed
  2026-07-10 — WALTEUR main must NOT be force-pushed over it without an explicit decision.

## 2026-07-03 — harness-100 campaign, wave 1

Day 1 of the "harness-100" improvement loop (`_agent_state/org-goal/goal-2026-07-03-harness-100.json`):
memory-spine and self-audit hardening, verified against the real repo, not fixtures.

### Added
- **kill-switch.sh wired to the `Bash` tool matcher** (`.claude/settings.json`) — previously bound only to
  `Write|Edit|MultiEdit`; a tripped kill-switch now also stops Bash-issued commands.
- **CI real-file self-audit job** (`.github/workflows/ci.yml`, job `self-audit-real-file`) — runs
  `harness-self-audit-gate.sh` against the actual repo in CI, not a fixture.
- **lesson-gate.sh live** — gate #143, registered in `gate-registry.json`, 13/13 selftest; DOGFOODED same
  day: the first real lesson captured via `--capture` into `walteur-kit/memory/lessons.jsonl` (the
  mirror-resync content-loss below).
- **`walteur-kit/autopilot/STATE.json` created** — the baton stamper previously defaulted to
  `phase:UNKNOWN`; it now stamps the real phase (`build`), confirmed by `harness-state-lint.sh` PASS.
- **graphify knowledge graph built** for this repo — `graphify-out/`: 741 nodes / 953 edges / 49
  communities (`GRAPH_REPORT.md`), a 59-article wiki (`graphify-out/wiki/`) plus `graph.html`; a live query
  was answered from the graph with citations (scoped corpus 47 files, excluding field-runs/fixtures/mirror
  twin; 815k subagent tokens; `.sh` hooks not yet graphable by graphify's code-extension list — follow-up).

### Changed
- **`walteur/SKILL.md` mirror resynced** to the fresher `WALTEUR-builder-CLAUDE.md` (which carried S033/S034
  TEAM MODE content this copy was missing). An adversarial verifier caught a real content loss the fresh
  side's own v10 rewrite had silently introduced (the per-discipline plan-review / gstack phrase) via a
  pre-copy snapshot diff; the phrase was restored to BOTH files before accepting the mirror — byte-identical
  again.
- **release-ledger.json `current_version` 9.78 → 10.0**, with a matching `10.0` history row — recorded to
  satisfy the major.minor schema pattern; frontmatter says `version: 10`, CHANGELOG top says v10.5. The
  exact minor is left open as a reconciliation backlog item (see Versioning schemes above).

### Verified
`release-ledger-lint.sh` real-file PASS (first time this campaign) · `gate-registry-lint.sh` real-file PASS
· `harness-self-audit-gate.sh` real-file PASS. Source of truth: `walteur-kit/harness-100/loop-state.json`
`done[]` (B02, B04, B06, B08, B15, B24, B27-partial).

## S-ledger rollup: S004–S037 (2026-06-28 → 2026-07-02)

CHANGELOG went untouched from v10.5/S003 (2026-06-28) while STAMP.md's append-only ledger kept running
alone through S037 (2026-07-02, score 66/100, gates 142). This entry narrates the uncovered span at
feature level; every claim traces to its own dated row in STAMP.md.

### Added — remaining executing gates close the audit's "make it EXECUTE" list (S004-S007, gates 128→131)
- **sdlc-run-gate** (S004) and **audit-contract-gate** (S005) become EXECUTORS (probe re-run + observed
  exit) — completing all 4 named shape-reading compliance gates (authz/privacy/sdlc-run/audit-contract) as
  executors.
- **dead-code-gate** (runs Knip) + **db-health-gate** (runs orm-doctor) (S006), then **security-scan-gate**
  (runs MEDUSA, S007) — three tool-executing gates, run+observe+fail-closed. 7 gates now execute+observe.

### Changed — independent panels correct the self-score down, twice, and it's earned back both times
- **S008**: first independent 8-agent adversarial re-audit — self-scored 54, corrected DOWN to **46**
  (probes opt-in+unbound, tool-gates inert when the tool is absent, SHIPPED.md empty). Fixed via **S009-S012**
  (trivial-probe rejection, twin-invariant portable Windows paths, tool-gate strict mode, execution-ratio
  meta-gate; gates 131→132); re-audited at **S013** to **48** ("autonomous program complete" declared).
- **S014**: fix-batch (constant-exit class closed via shared `_probe-proof.sh`) re-scored by an independent
  panel DOWN to **44** — "the cap is the external ship, not more gates." Gates 132→136.

### Added — five real field apps built end-to-end + 3 more gates, score climbs 49→60 (S015-S023)
- **multitenant-tasks** (S015, KEYSTONE): first real multi-tenant app driven end-to-end; 4/5 EXEC executors
  fired on real tests, exec-ratio 4%→44%.
- **broadened execution + self-enforcing mirror** (S016): secret-rotation now counted (exec-ratio 60% on the
  field app), test-layer EXEC path + false-green leak fixed, real-run twin-invariant wired HARD into
  gate-suite (live hook drift BLOCKS exit 2, doc-twin excepted). Gates 136.
- **support-risk-command-center** (S017), **feature-flags-api** (S018), **documents-api** (S019, reaches
  SHIPPED.md's "3-5 ships across domains" band), **apikeys-vault** (S020, top of that band; 7/7 exec-ratio =
  100%, incl. secret-rotation zero-committed-key-literal scan).
- **chaos-resilience-gate** (S021) genuinely EXECUTES a kill/restart drill and observes recovery. **loopkit
  fold**: 33 audited PROTOCOL skills vendored into the Org library, 191→223 indexed (S022). **flaky-test-gate**
  armed, gates 136→**137** (S023).

### Changed — second major correction, earned back via a fix cycle (S024-S029)
- **S024**: SECOND independent 8-dim re-audit — self-scored 60 corrected DOWN to **46** again (killer:
  all-green-nothing-ran passes by default; phantom orchestration dispatch tools; field-proven capped 32 —
  zero external ships). Fixed via **S025** (execution-ratio build-class auto-floor) and **S026**
  (orchestration honesty relabel — no more `create_subagent`/`assign_task` phantom tools).
- Earned back independently: **51** (S027, robustness+enforcement fixes confirmed), **54** (S028,
  orchestration re-scored 28→52), **55** (S029, usability re-scored 38→48 via a new `REMEDIATION.md` fix-recipe
  guide).

### Added — WALTEUR runs itself end-to-end for the first time — the ~60 autonomous ceiling (S030-S032)
- **S030**: WALTEUR's FIRST real end-to-end run — built `jsonlint-cli` via its own 12-phase pipeline (97
  agents, 118 min), 244 tests reproduced, honest audit caught a real BOM bug and refused to ship it.
  Orchestration 52→76, composite 55→**58**.
- **S031**: sixth executor hardened (`test-claim-verifier` constant-exit hole closed); `jsonlint-cli` made
  publish-ready (BOM fixed, 247/247, LICENSE, 16-file pack). Score held 58 pending re-panel.
- **S032**: S031 hardening independently confirmed — enforcement 68→72, robustness 65→82, composite
  58→**60**, recorded verbatim as "THE ~60 AUTONOMOUS CEILING, REACHED HONESTLY" — every point from S008
  onward earned via an independent re-panel, never self-asserted.

### Added — TEAM MODE and the engine's own end-to-end runs push past the ceiling (S033-S037)
- **S033**: major upgrade (14 Sonnet builders + engine surgery) adds **TEAM MODE** — named CC terminals as
  peers, `peerbus-mcp`, `team-coordination-gate`. Gates 137→**142**. Composite 60→**64**.
- **S034**: TEAM MODE runs end-to-end for the first time (3 scripted peers post→claim→build→review over the
  real bus; negative-control tamper→FAIL→restore→PASS); `stamp.sh` gains an anti-forgery verification sample
  (re-runs a random sample of registry selftests before stamping, refuses on any RED). Score held **64**.
- **S035**: THREE REAL CLAUDE AGENTS (not scripts) — ATLAS/FORGE/SENTINEL — coordinate a live micro-build
  over the peerbus with real judgment (a caught slug/slugify contract mismatch + self-correction; an
  unprompted ReDoS review by the reviewer agent). Orchestration 78→81, composite 64→**65**.
- **S036**: `walteur.js` runs a COMPLETE 12-phase build for the first time since S030 (3 engine bugs fixed:
  a parser-rejected escape, forbidden `Date.now`/`new Date`, an unguarded Think-phase crash) — builds
  `humansize` (234/234 tests), autonomously refuses to overclaim `shippable` on 2 doc gaps. Score held **65**.
- **S037**: second complete e2e run on a NEW build class (URL-shortener HTTP API, 86/86 tests) — **skill
  injection proven end-to-end for the first time** (routing fires on real signals, 5 content-bound
  skill-receipts cross-checked against actual source lines); terminal audit live-verifies 3 real HTTP
  security findings and returns `shippable:false`. Composite 65→**66** — first integer past 65.

### Verified
Composite 47 → 66/100; gates 128 → 137 → **142**. Two independent-panel corrections DOWN, both kept
un-smoothed (S008: 54→46; S024: 60→46) — every later point re-earned via re-panel, never self-credited.
field-proven (the external-ship dimension) climbed 16→46 across the five-app ladder (S008→S020), was
independently corrected back to 32 at S024, and has been held there through S037 — the hard cap is still a
real `npm publish`, which has not happened. Every score/gate figure above is quoted from its own dated row
in STAMP.md (S004-S037); nothing here is asserted beyond what those rows already state.

## v10.5 — privacy-data EXECUTES + executing-audit-tool catalog (2026-06-28)

Phase 1 continues: a second named shape-reading compliance gate becomes an executor; five audit tools
web-verified and triaged by ONE question — can it be an EXECUTING gate?

### Changed — privacy-data-gate: verdict-reader → EXECUTOR (right-to-erasure)
- Optional `retention_deletion.erasure_probe = {command, expect_exit}` is RE-RUN and its exit OBSERVED
  (DSAR deletion actually works); `WALTEUR_PRIVACY_EXEC=1` makes it REQUIRED (shape-only rejected). Same
  injection guard as authz. `--selftest` 15→**21/21** (6 new exec twins). The reference app gained a real
  **GDPR right-to-erasure** (`eraseTenant`: wipes a tenant's tasks + audit rows, nothing cross-tenant),
  proven by `node --test` (8→**9/9**).

### Added — audit-tools.json (executing-gate triage of 5 tools)
- **Knip** (ISC) + **orm-doctor** (MIT) + **MEDUSA** (AGPL — copyleft noted) = **adopt-executing-gate** (all
  RUN headless + emit JSON/score/fail-exit — real run+observe+fail-closed, not shape-read). Teed up as
  `dead-code-gate` / `db-health-gate` / `security-scan-gate`. **Ponytail** (LLM reviewer) + **ReconForge**
  (post-deploy recon) = **reference-only** — they can't execute deterministically, so they can't close the
  PROOF gap; honestly catalogued as such, not gated on.

### Verified
privacy-data 21/21 + app 9/9; mirrored to walteur-starter; full 128-gate suite re-run; stamped S003.

## v10.4 — authz-tenant EXECUTES + agent-native fold (2026-06-28)

The audit's #1 fix, landed: the most-cited shape-reading gate now executes and observes.

### Changed — authz-tenant-gate: verdict-reader → EXECUTOR
- A tenant surface may carry `tenant_isolation.cross_tenant_probe = {command, expect_exit}`; the gate
  **RE-RUNS it and OBSERVES the exit** (ship-gate injection guard reused: allowlisted runner + dangerous-token
  refusal). With `WALTEUR_AUTHZ_TENANT_EXEC=1`, a tenant surface **MUST** carry a probe — a ref-only ("shape")
  proof is rejected. `--selftest` 13→**20/20** (5 new exec twins incl. probe-fails→FAIL, exec-mode-no-probe→FAIL,
  dangerous-token→FAIL). **Proven on the real app with a NEGATIVE CONTROL**: breaking tenant isolation in
  `multitenant-tasks/core.mjs` made the gate exit 2; restoring it passed. Real teeth, not a self-written verdict.

### Added — agent-native (BuilderIO) fold
- Researched + assessed (`agent-native-adoption.md`): steal disciplines, host nothing (~70% is runtime/product
  machinery a build harness shouldn't host). **Folded the one ADOPT-CORE idea — auto-audit-per-mutation** — into
  the reference app: every mutation writes a tenant-scoped audit row, reads don't, a denied cross-tenant write
  leaves no row; proven by `node --test` (6→**8/8**). Two ADOPT-OPTIONAL ideas (schema-per-action contracts +
  exposure flags; `assertAccess`/`accessFilter`) recorded as roadmap.

### Verified
authz-tenant-gate selftest 20/20 + real-app exec PASS + negative-control FAIL→PASS; app 8/8; mirrored to
walteur-starter; full 128-gate suite re-run; stamped into STAMP.md (S002).

## v10.3 — Phase 1: real teeth + immutable stamp + first executable field proof (2026-06-28)

Acting on the independent adversarial audit (~44/100, capped by PROOF not capability). First proof-closing pass.

### Added — the permanent certification stamp (gate 127 → 128)
- **STAMP.md** + **stamp.sh** (writer) + **stamp-chain.json** (sha256 chain) + **stamp-integrity-gate.sh**
  (HARD, `--selftest` 10/10): an APPEND/UPDATE-ONLY certification ledger. The `Current` score block is
  re-stampable, but every dated history row is **immutable** — its sha256 is chained and re-hashed at ship;
  a deleted file, removed row, or altered row => FAIL exit 2. The score-of-record survives any other file
  being optimized/deleted. Exactly: "a stamp that can update by score but never gets deleted."

### Changed — skip-budget (the robustness killer, "couldn't-measure != passed")
- **gate-suite.sh**: a tool-missing selftest skip is now classified **cannot_measure** (not a silent pass);
  if `cannot_measure > WALTEUR_GATESUITE_MAXCANNOT` (default 8) the suite **FAILs**, and the aggregator
  **fails closed when its own jq is absent** instead of self-disabling to SKIP. `--selftest` 10/10 (2 new
  budget twins). Stale "119 gates" header removed.

### Added — first executable field proof (multitenant-tasks)
- `field-runs/multitenant-tasks/` — a real, dependency-free multi-tenant app with **deny-by-default tenant
  isolation**, proven by an **actually-running test** (`node --test` → 6/6: cross-tenant read→null,
  write→forbidden, isolation invariant across many tenants). `test-claim-verifier-gate` **RE-RAN** the suite
  and verified it (PASS); a falsified claim makes it exit 2 — real teeth executing, not a self-written verdict.
  This is the audit's "make authz EXECUTE" demonstrated end to end, plus the field-mile pattern in miniature.

### Verified
Every gate `--selftest` N/N + independent reproduction; registry + both ledgers 127 → **128** (parity);
mirrored to walteur-starter; full 128-gate `gate-suite` re-run; result stamped into the immutable STAMP.md.

## v10.2 — governed data acquisition (2026-06-28)

Gave WALTEUR real data-access muscle for DISCOVER/RESEARCH, folded in *governed* (the WALTEUR-grade way):
licenses are mostly clean, but the USAGE (robots/ToS/anti-circumvention/PII) is the real exposure for a
$50-100M product — so the fold is a vetted catalog + a governance gate, not raw scraper dependencies.

### Added (gate 126 → 127)
- **data-tools.json** — web-verified catalog (2026-06-28) of 8 data-acquisition tools: **Firecrawl** (MCP, AGPL
  core/MIT MCP), **Crawl4AI** (Apache-2.0, MCP), **MarkItDown** (MIT, MCP) = adopt-core; **browser-use**,
  **Crawlee**, **Scrapy**, **curl_cffi** = adopt-optional; **AutoScraper** = reference. Per-tool license-class,
  access methods, MCP server, anti-blocking level, when-to-use, governance notes. `agency-agents` (232 persona
  templates) catalogued as `not_data_tools` — persona idea-mining only.
- **data-acquisition-gate.sh** (HARD, registry-wired, ship-gate-dispatched, `--selftest` 12/12): governed
  external sourcing — vetted tool required (no ad-hoc scrapers), provenance per source (url/tool/output_ref),
  robots + PII handling, and **high-risk tools (curl_cffi/browser-use/Crawlee) require a recorded `legal_signoff`**.
  Detect-or-SKIP (arms on `data-acquisition.json`).
- **field-runs/SHIPPED.md** — field-proof ledger so real shipped products become citable evidence the audit can credit.

### Verified
`--selftest` 12/12 + independent out-of-harness 0→2 reproduction against the REAL catalog (high-risk
`curl_cffi` FAILs without signoff, PASSes with it; medium `firecrawl` PASSes). registry + both release-ledgers
bumped 126 → **127** (parity restored — also fixed a pre-existing 122-vs-126 ledger drift). Mirrored to walteur-starter.

## v10.1 — loop-engineering image folds (2026-06-28)

Four concepts from the LOOPER / Hermes-Skills / Loop-Engineering design boards, **adversarially coverage-audited
first** (a 6-agent audit against the existing 125 gates, evidence-required) so nothing duplicates prior coverage.
Two of six candidates were proven already-covered and skipped; four were real gaps and folded in, each
independently re-verified (bash -n + full `--selftest` + exact-fixture reproduction 0→2 + mirror to walteur-starter).

### Added — gate (125 → 126)
- **review-egress-redaction-gate** (NEW, HARD, registry-wired, ship-gate-dispatched, `--selftest` 12/12):
  before any handoff of project content to an external / "council" / reviewer MODEL, the gate **actively
  re-scans the payload file** (does NOT trust a "redacted" claim) for raw secrets — private-key blocks,
  `AKIA`/`sk-`/`ghp_`/`xox`/`AIza`/JWT tokens, `user:pass@` connection strings, `KEY=<secret-value>` — AND
  requires a recorded **consent**; redaction placeholders excused. Detect-or-SKIP (arms on a declared
  council-egress surface). The one egress surface no existing gate covered. From LOOPER "egress redacts
  .env + secrets, consent first".

### Changed — three existing gates extended (loop-engineering teeth)
- **tool-guardrail-gate** G5: `on_fatal` now admits **`replan`** (route a failed dangerous-tool call back to
  the planner) — the missing **Reject + Replan** limb of the Loop-Engineering per-action safety chain.
  Schema + `--selftest` (29/29, new GOOD twin: dangerous tool + replan → PASS).
- **definition-of-done-gate**: **verification-typing** — each closed DoD item is classified
  `programmatic | judge | human` from its evidence kind, tallied in `counts.by_verification`, and an item
  claiming `Verify: programmatic` over only a judge/human note now **FAILS** (kills "a11y/perf
  claimed-not-measured"). `--selftest` 17/17 (3 new twins incl. the masquerade catch). From LOOPER's
  programmatic/judge/human taxonomy.
- **self-improvement-gate** + **self-improvement.schema.json**: new **`skill-mint`** proposal source — a
  recurring reusable-workflow gap turned into a NEW skill must carry recurrence **provenance** (support≥2) +
  the authored **SKILL.md** + a **PASSING** skill-quality/skill-frontmatter verdict, else FAIL. Closes the
  Hermes "it also creates its own skills" loop without letting an unproven skill be claimed. `--selftest`
  17/17 (3 new twins).

### Audited-and-skipped (already covered — no bloat)
- **Council independence**: `delivery-orchestration-gate` already enforces reviewer/evaluator
  id-independence (reviewer_ids ∩ builder_ids = ∅; evaluator self-review → FAIL) + `audit-contract` terminal
  `model:opus`.
- **Loop-control ceilings**: walteur.js already has `HARD_REFINE_CAP` (revise cap) + `MAX_USD`/`budgetStop`
  + `loop-readiness-gate` HARD-requires budget/killswitch/runlog for an L3 claim.

### Verified (honesty)
Every change re-verified by the lead (agents lie about "green"): each gate's own `--selftest` N/N PLUS an
independent out-of-harness 0→2 reproduction (egress: clean→leak-`ghp_`; replan: replan→`continue`; DoD: honest
vs masquerade; skill-mint: quality PASS→FAIL). registry-lint PASS at 126. All four mirrored into walteur-starter.

## v10 — best-of-breed intake · senior persona org · auto-compaction · loop-engineering (2026-06-27)

A standing ULTIMATE-upgrade loop: adversarial gauntlet hardening + a 40-repo best-of-breed intake
(HARNESS_V2_REPORT + loop-engineering + War Mode V15 + gstack), folded in proven, one verified gate at a time.

### Added — brownfield upgrade track (§2.6 · `/upgrade` · `/comprehend`) — the symmetric twin of DISCOVER
Point WALTEUR at an app you (or anyone, with any tool) already built and it **comprehends before it changes**:
reverse-engineers the app's intent into `INTENT.md` (what-it-is · original goal · used-for · every claim labeled
confirmed/inferred/unknown with file:line evidence; short-circuits to `PRD.md` for a WALTEUR-built app), captures
a before-`baseline.json` + a **characterization/golden-master** net, lifts every dimension (tiered
refine-in-place → modernize → re-architect), and **PROVES non-regression** (after ≥ before on every dimension,
golden-master green, behavior changes signed) before ship — never breaking what works.
- **3 new gates** (registry-wired, `--selftest` 9/9 · 13/13 · 16/16): **intent-reconstruction-gate** (discover) ·
  **baseline-capture-gate** (plan) · **non-regression-gate** (ship, HARD terminal blocker). All detect-or-SKIP on
  greenfield — zero blast radius on a new build. Total gates 122 → **125**.
- **Schemas**: `intent.schema.json` · `baseline.schema.json` · `non-regression.schema.json`. **Templates**:
  `INTENT.template.md` · `UPGRADE-PLAN.template.additions.md`.
- **`walteur.js`**: Comprehend → Baseline phases in the brownfield branch (gap-audit vs intent/baseline →
  `upgrade-backlog.json`) + a Prove phase before the terminal audit; `non-regression-gate` dispatched in `ship-gate.sh`.
- Commands: **`/upgrade`** (autopilot, twin of `/goal`) · **`/comprehend`** (audit-only, twin of `/discover`).
- Spec: new **§2.6** in `WALTEUR-builder-CLAUDE.md` + pipeline MODE, command map, Iron Law 13, scaling row,
  §19 gate table, DoD §8. Discipline credit: Feathers, *Working Effectively with Legacy Code* (characterization tests).

### Added — gates (110 → 117, all with `--selftest`, registry-wired, fail-closed)
- **persona-coverage-gate** + **personas.json (68-role senior org)** — Chief of Staff, FRONT-LOADED Senior PM
  (red-flag register at PLAN), specialists spawned BY SIGNAL (Pro Designer/CMO/Cybersecurity/Data/DevOps/
  Full-Stack/Accessibility/Performance/Compliance/… 60+), terminal Audit Squad. required/advisory enforcement;
  evidence-based `persona-breadcrumbs.sh` emitter wired into `walteur.js` after the audit; a Senior-PM
  front-loaded red-flag pass at Plan→Build.
- **context-compaction-gate** + **compaction-policy.json** + **checkpoint-schema.md** — AUTOMATIC context
  compaction at 150k/200k ABSOLUTE tokens (not % of the 1M window), hands-free; `walteur.js maybeCompact()`
  checkpoints at each wave boundary so every agent stays in its sharpest zone.
- **loop-readiness-gate** (L0-L3, ported from loop-engineering `loop-audit`) + **harness-self-audit-gate**
  (scores the harness 0-100 across 6 dims, fail-closes on regression — WALTEUR self-scores 98/100).
- **anti-slop-prose-gate** (user-facing copy, from stop-slop) · **hollow-artifact-gate** (catches ships-mock:
  traces a handler to a REAL data source, from GSD verifier L4) · **skill-quality-gate** (lints the 190-skill
  Org library — scored 94/100) · **data-correctness-gate** (SQL join-explosion/avg-of-avgs/denominator).
- **loop-engineering corpus** (`walteur-kit/loop-engineering/`): failure-modes · loop-safety · primitives ·
  context-economics · checkpoint-schema · repo-adoption-report — MIT, credited to Cobus Greyling / Addy Osmani.
  WALTEUR's own `LOOP.md` documents the autonomous loops (scores loop-readiness L3).

### Changed
- Skill version **v9.78 → v10**; `ship-gate` dispatches the 7 new gates; registry + release-ledger at 117.
- gstack (garrytan/gstack) virtual-team model folded in: validates the persona org + the per-discipline
  plan-review pattern.

### Verified (honesty)
Every gate independently re-verified by the lead (agents lie about "green" — proven): bash -n + full
`--selftest` N/N + exact-fixture reproduction 0→2 + registry-lint PASS + `node --check` on every walteur.js
edit. Deep gauntlet batches 1-3: 108 proven false-negatives found, 72 fixed+verified (rest queued). Several
real bugs caught in our OWN new gates (perl `m{} i` space-abort · `${VAR:-{}}` brace · while-read drops last
line w/o trailing newline · tab-split) — all logged to memory so no future gate repeats them.

## v9.1 — AST proof · supply-chain · recipe · self-correcting memory (2026-06-15)

From a 32-agent evaluation of 6 external repos (ast-grep, graphiti, goose, claude-context,
context-engineering-intro, ai-dev-tasks): adopt patterns/opt-in connections only — graphify stays
the one retrieval brain; no second KG, no infra-in-repo.

### Added
- **P12 CODE-STRUCTURE (ast-grep)** — opt-in AST backend for `resilience-lint` + `anti-slop-ui`
  (4 HARD twin-proven rules; 2 documented advisories) + `intent-trace.sh` (§5.5 deterministic
  existence proof, never correctness) + `prd.schema` `ast_proof`.
- **P13 SUPPLY-CHAIN (OSV.dev)** — `osv-gate.sh`, fail-closed on MAL-* malicious-package advisories
  (proven on a real 4-ecosystem project: npm/PyPI/crates/Go).
- Recipe contract (`recipe.schema.json` + `recipes/`); prove-pillar A/B harness (`eval/ab-bench.sh`);
  `build-with-agent-team` skill; `rules/memory-discipline.md`; prompt micro-lifts.
- Self-correcting memory: bi-temporal lessons (`invalidated_at`/`superseded_by`) + lesson-gate
  supersede-on-contradiction + `recall.sh` current-only filter; `pause_per_task` autonomy option.

### Changed
- `ship-gate` now dispatches prd-gate + intent-trace + osv-gate. Pillars 11 → 13.
- Anti-bloat pass on our own output: merkle 190→84, build-with-agent-team 183→144, others trimmed.
- Flaky worktree-isolation selftest hardened with a bounded retry-guard (now stable).

### Verified
`ast-grep test` 6/6 · canonical `selftest.sh` 66/66 (with write access) · recipes conform 2/2 ·
OSV/ab-bench/end-to-end all proven with real runs.

### Honesty
AST proves EXISTENCE, never correctness. Three live-runtime proofs (a `/goal` run, a live
`api.osv.dev` round-trip, ab-bench vs a real `claude -p`) are covered by proxy + CI — not faked.

## v9.0 — front of the funnel (DISCOVER · PRD · intended-vs-implemented)
- `walteur-discover` companion + §2.5 DISCOVER + `prd-gate` + the intended-vs-implemented audit axis.
