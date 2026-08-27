# WALTEUR — features (readable catalog)

The human-readable map of what the engine does. The skill `description:` field stays keyword-dense on purpose — it is the skill-activation/trigger surface, not docs — so this file is where the capabilities are actually explained. Authoritative contracts live in `walteur-kit/HARNESS-LOOP.md`; proof status is in the root `README.md`.

## Currency — what is live right now (regenerate, don't trust the prose)

Every number below in a dated section is history. These five commands are the only current truth; if a
sentence anywhere in this file disagrees with them, the commands win and the sentence is a bug.

```sh
jq -r '.current_version' walteur-kit/release-ledger.json          # release of record        -> 10.20
jq '[.gates[]]|length' walteur-kit/gate-registry.json             # registered gates         -> 150
jq '[.gates[]|select(.hardness|test("hard";"i"))]|length' walteur-kit/gate-registry.json   # HARD -> 61
jq -c '.aggregate_proof' walteur-kit/release-ledger.json          # CERTIFIED aggregate      -> 244/0/0
jq -c '{verdict,counts}' walteur-kit/selftest-report.json         # last local run (mutable)
```

Live at v10.20 (2026-07-10): **150 registered gates**, **61 HARD fail-closed**, certified aggregate
**244 passed / 0 failed / 0 skipped**.

The last two commands are different things and the difference matters. `release-ledger.json`
`aggregate_proof` is the **certified claim** (schema-checked, re-stamped only with a fresh full run);
`selftest-report.json` is whatever the **last run on this box** wrote, and any agent re-running
`selftest.sh` overwrites it. When they disagree, `release-ledger-lint.sh` exits 2 and *that disagreement
is the finding* — do not quote either number as green without checking the other. Where to look for what:

| Question | Surface |
|---|---|
| per-release narrative (v10.x, dated) | `CHANGELOG.md` |
| score of record + append-only certification ledger | `STAMP.md` (its `## Current` block) |
| machine-checked release truth (version, aggregate, proof-claim paths) | `walteur-kit/release-ledger.json` |
| gate ids, hardness, availability, report path | `walteur-kit/gate-registry.json` |
| field proof (what was actually built/shipped) | `field-runs/SHIPPED.md` |
| why `doctor.sh` exits 1 on this tree (predicted reds, not a broken install) | `docs/EXPECTED-REDS.md` |

Three different 0-100 scores exist in this repo and they are **not** the same metric: the harness-100
**panel score** (independent blind panel, recorded in `STAMP.md → Current`), the
**harness-self-audit** internal score (`walteur-kit/harness-audit-report.json`, 100/100 at
2026-07-10 — it scores scaffold coverage, not delivered outcomes), and the **skill-quality lint**
score (`walteur-kit/skill-quality-report.json`: composite 94, 190 skills, 0 broken, floor 70). Any
single 0-100 number quoted without one of those three owners is unattributed — don't repeat it.

## v10.20 — cross-model integrator audit + excellence plateau law (2026-07-10)

- **`integrator-audit-gate`** (detect-or-skip, spec) — the rocket-fuel port: at ship, a *different model*
  (Codex, via `rf-codex.sh`) must return a fresh adversarial `VERDICT: SHIP`. One model grading its own
  homework no longer closes the loop.
- **`excellence-loop-gate`** (detect-or-skip, spec) — the **excellence plateau law**: green is the floor,
  not the finish. Either two refined-and-re-proved rounds plateau, or the run caps out with named residuals.
- Registered gates reach **150 / 61 HARD**; `harness-self-audit-gate` scores the scaffold **100/100**
  (`walteur-kit/harness-audit-report.json`, 2026-07-10) after the DIM-2 ceiling bug-fix — the prior rubric
  could not exceed 98, which is why older copies of this file said 98.

## v10.6 → v10.19 — the S-ledger span (2026-06-28 → 2026-07-11)

This file went untouched across that span while `STAMP.md`'s append-only ledger kept running (S004→S038).
The dated narrative lives in `CHANGELOG.md` ("S-ledger rollup: S004–S037", "2026-07-03 — harness-100
campaign, wave 1", "2026-07-11 — karpathy-discipline rule") and every figure there traces to its own
sha256-chained STAMP row. The capabilities this catalog was missing:

- **Gates that run a real tool and observe its exit** — `dead-code-gate` (Knip), `db-health-gate`
  (orm-doctor), `security-scan-gate` (MEDUSA), `chaos-resilience-gate` (a real kill/restart drill),
  `flaky-test-gate`. Plus `execution-ratio-gate`, the meta-gate that measures how much of a run actually
  *executed* versus read a shape.
- **TEAM MODE** — `team-coordination-gate` (HARD) + `peerbus-mcp`: named Claude Code terminals as peers
  posting/claiming/building/reviewing over one bus, proven with a negative control (tamper → FAIL →
  restore → PASS).
- **`lesson-gate`** (protocol) — captured lessons in `walteur-kit/memory/lessons.jsonl`, dogfooded on a
  real content-loss incident the same day it landed.
- **`rules/karpathy-discipline.md`** — the karpathy-guidelines skill promoted from reference to a
  delta-only PROTOCOL rule (mid-build confusion-surfacing, three named simplicity prohibitions, the
  pre-commit diff walk).
- **Eight internal field runs** (FR-1 → FR-8 in `field-runs/SHIPPED.md`), including the first
  orchestrator-built app end-to-end (`jsonlint-cli`), the first engine-built npm-shaped package
  (`engine-humansize`), and the first real React/Vite UI to make the design gates fire on actual `.tsx`
  (`design-proof-app`, with a real Playwright browser-proof).

## v10.5 — privacy-data EXECUTES + executing-audit-tool catalog (2026-06-28)

- **`privacy-data-gate`: verdict-reader → EXECUTOR.** An optional
  `retention_deletion.erasure_probe = {command, expect_exit}` is **re-run and its exit observed** — DSAR
  deletion has to actually work; `WALTEUR_PRIVACY_EXEC=1` makes the probe mandatory and rejects shape-only
  proof. Selftest 15 → 21/21.
- **`audit-tools.json`** — five audit tools triaged by one question: *can it be an executing gate?* Knip
  (ISC) + orm-doctor (MIT) + MEDUSA (AGPL, copyleft noted) → adopt-executing-gate. Ponytail and ReconForge
  can't execute deterministically, so they are catalogued as reference-only rather than gated on.

## v10.4 — authz-tenant EXECUTES + agent-native fold (2026-06-28)

- **`authz-tenant-gate`: verdict-reader → EXECUTOR.** A tenant surface may carry
  `tenant_isolation.cross_tenant_probe = {command, expect_exit}`; the gate **re-runs it and observes the
  exit** behind the ship-gate injection guard (allowlisted runner, dangerous-token refusal).
  `WALTEUR_AUTHZ_TENANT_EXEC=1` makes a probe mandatory. Proven on the real app with a **negative
  control**: breaking tenant isolation made the gate exit 2, restoring it passed. Selftest 13 → 20/20.
- **agent-native (BuilderIO) fold** — one adopt-core idea taken (auto-audit-per-mutation: every mutation
  writes a tenant-scoped audit row, reads don't, a denied cross-tenant write leaves no row), ~70% of the
  source deliberately not hosted because it is runtime/product machinery a build harness shouldn't own.

## v10.3 — Phase 1: real teeth + immutable stamp (2026-06-28)

First pass on the audit's proof gaps (the harness scored ~44/100 because it's proven to *fire*, not *deliver*):
- **Immutable certification STAMP.md** (gate 128) — append/update-only score-of-record; the current score
  re-stamps freely but every dated row is sha256-chained and **can never be deleted or altered** (a row
  removal/edit FAILs the ship). Survives any other file being optimized away. Written by `stamp.sh`.
- **Skip-budget in gate-suite** — a tool-missing skip is now `cannot_measure`, not a silent pass; over budget
  the suite FAILs, and the aggregator fails closed when its own jq is absent. "Couldn't measure" no longer
  reads as "passed."
- **First executable field proof** (`field-runs/multitenant-tasks/`) — a real deny-by-default multi-tenant app
  whose cross-tenant denial is proven by `node --test` (6/6) and **re-run by `test-claim-verifier-gate`** at
  gate time (a falsified claim exits 2). The audit's "make authz EXECUTE" — demonstrated.

## v10.2 — governed data acquisition (2026-06-28)

WALTEUR can now **reach the open web and real files** during DISCOVER/RESEARCH — but *governed*, because a
$50-100M product that scrapes carries real legal exposure (robots/ToS/anti-circumvention/PII), not just a
technical one. Eight best-in-class tools were web-verified (current license, MCP availability, governance)
and folded in as a vetted catalog, not raw dependencies:

- **`data-tools.json` (NEW catalog)** — Firecrawl, Crawl4AI, MarkItDown (adopt-core, all MCP-native),
  browser-use, Crawlee, Scrapy, curl_cffi (adopt-optional), AutoScraper (reference). Each carries license +
  **license-class**, access methods, **MCP server**, anti-blocking level, when-to-use, and **governance notes**
  (the through-line: licenses are mostly clean; the *usage* is the legal risk). agency-agents is catalogued as
  persona idea-mining, explicitly *not* a data tool.
- **`data-acquisition-gate` (NEW, HARD, gate 127)** — when a build pulls external data it must route through a
  **vetted** tool (no ad-hoc scrapers), record **provenance** per source (url/tool/output_ref), prove **robots +
  PII** handling, and — the teeth — **high-risk anti-bot/auth-bypass tools (curl_cffi/browser-use/Crawlee)
  require a recorded `legal_signoff`**, else FAIL. Detect-or-SKIP; arms only when `data-acquisition.json` exists.
- **`field-runs/SHIPPED.md` (NEW ledger)** — the field-proof of record: where real shipped products become
  *citable* evidence so the audit can legitimately credit them. A real ship with no row here scores as no ship.

## v10.1 — loop-engineering image folds (2026-06-28)

Four concepts mined from the LOOPER / Hermes-Skills / Loop-Engineering design boards, each adversarially
coverage-audited against the existing harness first (6-agent audit) so nothing duplicates what already exists:

- **`review-egress-redaction-gate` (NEW, HARD) — reviewer-model egress.** Before any project content is handed
  to an external / "council" / reviewer MODEL, the gate **actively re-scans the payload** (it does not trust a
  "redacted:true" claim) for raw secrets — private-key blocks, `AKIA`/`sk-`/`ghp_`/`xox`/`AIza`/JWT tokens,
  `user:pass@` connection strings, `KEY=<secret-value>` — and requires a recorded **consent**. Redaction
  placeholders (`<REDACTED>`, `your-key`, `***`) are excused. Detect-or-SKIP (arms only when a council-egress
  surface is declared). This is the one surface no existing gate covered: `confidentiality-gate` guards
  *published* artifacts, `agent-security-gate` guards the build's *own source*. Gate **126**.
- **Reject + Replan (`tool-guardrail-gate` G5).** `on_fatal` now admits **`replan`** as a first-class recovery
  action (route the failed dangerous-tool call back to the planner) alongside halt/escalate/rollback/compensate/
  abort — the missing limb of Loop-Engineering's "Reject + Replan" safety chain.
- **Verification-typing (`definition-of-done-gate`).** Every closed DoD item is classified `programmatic | judge
  | human` from its evidence kind, tallied in the report (`counts.by_verification`), and — the teeth — an item
  that *claims* `Verify: programmatic` while citing only a judge/human note now **FAILS**. Kills the retro's
  "a11y/perf claimed-not-measured" masquerade. From LOOPER's programmatic/judge/human verification taxonomy.
- **Skill-minting (`self-improvement-gate`).** A new `skill-mint` proposal source closes the loop from
  consume-only to **create-its-own-skills** (Hermes): a recurring reusable-workflow gap turned into a NEW skill
  must carry recurrence **provenance** (support≥2) + the authored **SKILL.md** + a **PASSING** skill-quality /
  skill-frontmatter verdict, else FAIL. You cannot claim a minted skill that hasn't passed the quality bar.

Skipped after audit (already covered, evidence-backed): **council independence** (`delivery-orchestration-gate`
enforces reviewer/evaluator id-independence — self-review→FAIL — plus `audit-contract` terminal `model:opus`) and
**loop-control ceilings** (walteur.js `HARD_REFINE_CAP` revise-cap + `MAX_USD`/`budgetStop` + `loop-readiness`
HARD-requires budget/killswitch/runlog). Gates total **125 → 126**.

## v10 — what's new (2026-06)

- **125 gates at v10 launch** (up from ~83 pre-v10), each with an embedded `--selftest`, registry-wired, independently re-verified. That launch figure is history — the live count today is **150 registered / 61 HARD** (see the Currency block above for the two commands that print it).
- **Brownfield upgrade track (§2.6 · `/upgrade` · `/comprehend`)** — point WALTEUR at an app you already built and it **comprehends before it changes**: reverse-engineers its intent into `INTENT.md` (every claim confirmed/inferred/unknown with file:line evidence; short-circuits to `PRD.md` for a WALTEUR-built app), captures a before-`baseline.json` + a characterization/golden-master net, lifts every dimension (tiered refine-in-place → modernize → re-architect), and **PROVES non-regression** (after ≥ before on every dimension, golden-master green, behavior changes signed) before ship. 3 new gates (`intent-reconstruction` · `baseline-capture` · `non-regression`), all detect-or-skip on greenfield. The symmetric twin of DISCOVER.
- **68-persona senior org** (`personas.json`) — spawned ON DEMAND by build signal and run together: a **Chief of Staff** coordinating, a **front-loaded Senior PM** that writes a red-flag register at PLAN (catches the integration mismatch on day one, not at the post-mortem), specialists by signal (Pro Designer, CMO, Senior Cybersecurity Analyst, Data Engineer, DevOps-SRE, Full-Stack, Accessibility, Performance, Compliance, + 50 more), and a **terminal Audit Squad**. `required`/`advisory` enforcement scales it from a tiny build to a full enterprise bench. Enforced by `persona-coverage-gate` + evidence-based `persona-breadcrumbs.sh` (a role only counts as engaged when its phase's artifact exists — coverage can't be faked).
- **Automatic context compaction at 150k/200k ABSOLUTE tokens** (`compaction-policy.json`) — quality degrades with absolute context size, not % of the window, so on a 1M window WALTEUR compacts hands-free at 150k and hard-handoffs at 200k via a Pi-format BATON checkpoint (`checkpoint-schema.md`). `walteur.js maybeCompact()` runs it at each wave boundary; `context-compaction-gate` enforces it.
- **loop-engineering self-improvement** — `loop-readiness-gate` (L0-L3) + `harness-self-audit-gate` (scores the harness scaffold 0-100 across 6 dimensions and **fail-closes if a future change drops a gate or erodes coverage**; self-score 98/100 at v10, **100/100 since v10.20** — `walteur-kit/harness-audit-report.json`. This is the scaffold-coverage score, not the panel score in `STAMP.md`). Corpus in `walteur-kit/loop-engineering/` (MIT, Cobus Greyling / Addy Osmani).
- **New craft floors:** `anti-slop-prose` (user-facing copy), `hollow-artifact` (catches ships-mock — traces a handler to a real data source), `skill-quality` (lints the 190-skill Org library), `data-correctness` (SQL join-explosion / avg-of-avgs / unguarded denominator).

## The loop

A typed 8-phase state machine with evidence-gated promotion and a single corrective back-edge:

`intake → discover → plan → build → verify → review → ship → reflect`

Each phase has one question, a required artifact, and a gate predicate. A red gate routes back to the smallest phase that can fix the cause. Gate verdicts: `PASS · FAIL · SKIP · BLOCKED · ACCEPTED_RISK` — no gate may silently green itself.

## Job-sized entry points

| Trigger | Use when | Weight |
|---|---|---|
| (skip) | typo / 1-line / pure-CLI / brownfield where intent already exists | none |
| `/feature` | a small, single feature | lightweight Planner→Coder→Tester→Reviewer |
| `/goal` | a new user-facing product | full lifecycle + senior gate panel |
| `/comprehend` | understand + audit an existing app (no edits) | §2.6 reverse-engineer `INTENT.md` + `baseline.json` + ranked `upgrade-backlog.json`, then STOP |
| `/upgrade` | improve an app you already built | §2.6 full brownfield track: comprehend → baseline → upgrade → PROVE non-regression → ship |

## Gate families (what gets proven)

- **Intake/plan contracts** — build-contract, estimate, current-stack (run-date stack proof), prompt-refinement ("improve this prompt"), delivery-orchestration (roster/SDLC/independence), project-context, source-use (curated upstream router), self-improvement.
- **Verify** — qa-contract, evidence-gate, phase-gate, schema-lint, contract-gate, tool-contract-lint, **tool-guardrail** (pre/post/error-path coverage for agent tools), fitness, resilience, a11y/i18n, perf, observe.
- **Security/supply-chain** — security-gate, **osv-gate** (OSV.dev MAL-* fail-closed, including on corrupt responses), sbom-gate, ai-safety, ai-tool-governance, authz-tenant, privacy-data, compliance, iac-scan.
- **Review/ship** — outcome-eval (independent scorer), adr-gate, risk-acceptance, scoreboard, definition-of-done, audit-contract (terminal Opus cert: exists/green/fresh, not "correct"), release-gate, operate-readiness, migration-proof/lint/roundtrip, restore-proof, browser-proof, sdlc-run.
- **Production reality** — production-layers (the 13-layer model: accounted-for / owned / signed-off, schema-enforced).

## Engine properties

- **File-first, stack-neutral, zero-dep** (`bash` + `jq`). No runtime daemon. Drop-in as `CLAUDE.md`, portable across models.
- **Honest enforcement labels** — HARD (exit-2 hook) vs PROTOCOL (verdict exists/green/fresh, *not* correctness). `availability: spec | canonical | optional`. Absent canonical hooks are never faked present.
- **Self-test spine** — `walteur-kit/selftest.sh` proves the gates FIRE: the certified aggregate is **244 passed / 0 failed / 0 skipped** sandbox-off (`release-ledger.json.aggregate_proof`). The ship-gate integration cases dispatch the external canonical kit, so verify those inside your own sandbox before claiming sandbox parity — a re-run under different conditions can land 241/2 instead, which is why the ledger and the on-disk report are cross-checked by `release-ledger-lint.sh` rather than trusted individually. `selftest.sh --fast` runs a core subset in ~1 min into a **separate** `selftest-fast-report.json` and is explicitly *not* the certification proof. `walteur-kit/audit-surface.sh` summarizes the surface in one command.
- **Self-improvement loop** — trace-mining, current-source scouting, bounded proposals, regression-proven upgrades, compounding memory (infrastructure built; see README for what is/isn't yet exercised on real builds).

## Honest status

The machinery is proven to **fire** (certified aggregate 244/0/0) and proven to **run end-to-end on real apps**:
`field-runs/SHIPPED.md` carries **8 internal field runs** (FR-1 → FR-8), each re-runnable on disk — two of
them built by the engine itself through the full 12-phase pipeline, one a real React/Vite UI with a
Playwright browser-proof.

What is still **unproven** is outcome efficacy, and the reason is precise: **zero verified external ships.**
Every `Live URL` cell in that ledger reads local-only — no public URL, no external users, no revenue. The
`design-proof-app` static build is *staged* for GitHub Pages (`docs/live/`, `.github/workflows/pages.yml`)
but deliberately **not** claimed: no ledger row is written until the URL returns HTTP 200 to a third party.
`PUBLISH-RUNBOOK.md` holds the consent-boundary routes; the engine never publishes on its own.

See `README.md` → "Status — honest" and `field-runs/SHIPPED.md` → "Audit impact".
