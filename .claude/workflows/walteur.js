// WALTEUR — the runnable build engine (orchestrator), v7 "swarm".
// Idea -> Scope -> Think(parallel research|audit) -> Team(create specialists) -> Plan ->
//         Build(parallel dependency waves) -> Review(panel) -> Refine(loop) ->
//         Validate(QA + parallel fact-check) -> Audit. Real agents, real gates, real files.
//
// The SWARM layer (this version): an Opus agent() DESIGNS the specialist roster the idea needs (a
// structured, capped list — there is NO bespoke "create_subagent" dispatch tool; the design is one
// agent() call), then the Build phase IMPLEMENTS that roster via real Workflow agent()/parallel()
// fan-out across dependency waves (each implementer its own context window). The six-senior panel +
// QA + terminal audit remain the GOVERNANCE gates over the swarm's output.
//
// Invoke:  Workflow({ name: 'walteur', args: { idea, projectPath, mode, scopeAnswers, maxRefine } })
export const meta = {
  name: 'walteur',
  description: 'WALTEUR runnable build engine (swarm) — idea to audited build: dynamic specialist creation + parallel task fan-out (waves), governed by a six-senior panel, QA, and a terminal fresh-Opus audit. Greenfield + brownfield.',
  whenToUse: 'Run from /goal <idea> or /walteur <idea> to autonomously build or improve a project to the bar.',
  phases: [
    { title: 'Self-Heal', detail: '§0.0 upstream drift sentinel (Sonnet, fail-open)' },
    { title: 'Scope', detail: 'lock the wedge + detect greenfield/brownfield' },
    { title: 'Comprehend', detail: 'BROWNFIELD (§2.6): reverse-engineer the existing app\'s intent → INTENT.md (confirmed/inferred/unknown + file:line evidence); short-circuit to PRD.md when present' },
    { title: 'Baseline', detail: 'BROWNFIELD (§2.6): capture the before-snapshot + golden-master net → baseline.json (so improvement & non-regression are provable)' },
    { title: 'Think', detail: 'parallel research fan-out (greenfield) | parallel gap-audit vs intent+baseline (brownfield)' },
    { title: 'Team', detail: 'one Opus agent() DESIGNS the specialist roster — a structured, capped list (not a dispatch tool)' },
    { title: 'Plan', detail: 'design doc + task DAG (files + deps + assigned specialist) + DoD (Opus)' },
    { title: 'Debate', detail: 'auto-fired Socratic forks → ADR (only when a genuine architecture fork exists)' },
    { title: 'Build', detail: 'real parallel() agent() waves implement the roster in dependency order' },
    { title: 'Review', detail: 'six-senior governance panel, parallel (Opus)' },
    { title: 'Refine', detail: 'loop: fix the failing gate, rebuild, re-verify — until green or budget' },
    { title: 'Validate', detail: 'QA gatekeeper + parallel fact-checkers run the real tests/checks (Opus)' },
    { title: 'Prove', detail: 'BROWNFIELD (§2.6): snapshot the after-state, prove after>=before on every dimension + golden-master green → non-regression.json' },
    { title: 'Audit', detail: 'terminal fresh-Opus certification: best-achievable, or exact shortfalls' },
  ],
}

let A = (typeof args !== 'undefined' && args) || {}
// args can arrive as an object OR a JSON string (harness serialization) — normalize to an object.
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (_) { A = {} } }
// Workflow-runtime SAFETY: the Workflow parser forbids Date.now()/new Date() (they break resume
// determinism), so "now" MUST arrive via args from the caller (who has a real clock). Callers pass
// nowTs (ISO string) + nowMs (epoch ms); absent => empty/0 sentinels that degrade SAFELY (an empty
// ISO just omits a stamp; nowMs=0 makes the deferral-expiry check never expire = honest non-blocking).
const _NOW_ISO = typeof A.nowTs === 'string' ? A.nowTs : ''
const _NOW_MS = Number(A.nowMs) || 0
log('args received: ' + JSON.stringify({ idea: A.idea, projectPath: A.projectPath, mode: A.mode, maxRefine: A.maxRefine }))
// Fail-fast: WALTEUR refuses to invent a project. No idea => stop, don't hallucinate a build.
if (!A.idea || A.idea === 'UNSPECIFIED IDEA') {
  return { error: 'WALTEUR aborted: no idea provided in args.idea. The engine does not invent projects — pass the idea.', args_seen: A }
}
const idea = A.idea
// v10.1 ULTIMATE (Tony's standing ask) — ADDRESS THE USER BY NAME. Capture it from args (or a sensible
// fallback) and personalize every user-facing line: the BATON handoff, progress logs, and the final summary.
const userName = (A.userName || A.user || A.name || '').toString().trim() || 'there'
// S033 #8a — NORMALIZE projectPath at intake (backslashes → forward slashes; resolve to absolute where
// possible). flushSpans() and every other Bash-interpolation site downstream build `${projectPath}/...`
// verbatim into bash commands, and bash treats backslashes as escapes — a raw Windows `C:\Users\...` path
// mangles the interpolated command (the real jsonlint-cli run lost its Self-Heal span to exactly this: the
// literal directory `C:UsersTony...` was created instead of the intended path). Git-Bash accepts
// `C:/Users/...` happily, so normalize ONCE here — every downstream consumer inherits the fix for free.
// Ported from the same fix already proven in walteur-starter/.claude/workflows/walteur-run.mjs:36-40.
function normalizeProjectPath(p) {
  if (!p || typeof p !== 'string') return p
  let n = p.replace(/\\/g, '/')
  try {
    if (typeof process !== 'undefined' && process.cwd && !/^([a-zA-Z]:)?\//.test(n)) {
      // relative path — resolve against cwd so downstream absolute-path comparisons (reconciliation) are stable.
      n = (process.cwd().replace(/\\/g, '/') + '/' + n).replace(/\/+/g, '/')
    }
  } catch (_) { /* process.cwd unavailable in some harness sandboxes — keep the slash-normalized form */ }
  return n
}
const projectPath = normalizeProjectPath(A.projectPath || '/tmp/walteur-build')
// CANONICAL KIT (S037 fix): a freshly-scaffolded build project does NOT ship walteur-kit/skill-index.json
// or hooks/skill-router.mjs, so the mechanical skill-router dispatch hit NO_INDEX and routed 0 skills even
// when the build's real signals (has_api_boundary/is_user_facing/…) SHOULD route several. Passing the
// WALTEUR repo's own kit path here lets the router source the index+script from canonical while still
// reading the project's preflight-signals.json and writing routing INTO the project. Absent => legacy
// project-local behavior (NO_INDEX loud-skip), never a crash.
const CANON_KIT = (typeof A.walteurKit === 'string' && A.walteurKit) ? A.walteurKit.replace(/\\/g, '/').replace(/\/+$/,'') : ''
const wantMode = A.mode || 'auto'
const maxRefine = A.maxRefine || 6  // v10.20: reconciled to spec §3.x default (was 3); emitted as scoreboard.refine_max
const given = A.scopeAnswers || null
const MAX_USD = Number(A.maxCostUsd) || 25 // HARD per-build dollar ceiling (default $25). A token-based $ ESTIMATE — NOT a precise invoice; bounds runaway cost off the best meter available (see estUsd()/meterStatus()).
const _spentAtStart = (typeof budget !== 'undefined' && budget && budget.spent) ? budget.spent() : 0 // BUG-G: snapshot of the session-cumulative spend at THIS build's start.

// ── S038 #1 — THE CEILING MUST BITE (panel-12 orchestration finding).
// BEFORE: estUsd() read ONLY budget.spent(). Every real field run of this engine ran in a harness with NO
// `budget` object, so estUsd() returned a hardcoded 0, overBudget(0, 25) was false forever, and no build in
// field-runs/ has ever produced a BUDGET_EXCEEDED artifact. The ceiling was REPORTED, never ENFORCED.
// Two independent defects are fixed here:
//   (a) FLAT PRICING. The old form priced EVERY output token at ~$30/M, so an opus token and a haiku token
//       cost the same in the model that guards the ceiling — an opus-heavy run was systematically
//       under-estimated. Now each lane carries its own published output price and the metered path prices
//       the metered delta at the LANE-MIX-WEIGHTED rate actually dispatched (blendedRateUsdPerMtok()).
//   (b) NO METER => NO CEILING. When the harness exposes no budget object there is still ONE real, engine-
//       observed counter: how many agent() dispatches this build has issued, per lane (_laneDispatches,
//       incremented in dispatch() — the single choke point every dispatch goes through). The unmetered
//       fallback prices that REAL count at a documented, deliberately CONSERVATIVE per-dispatch output
//       assumption. It is an estimate and is labeled as one everywhere it surfaces (meterStatus() returns
//       'unmetered_dispatch_estimate', the receipt and the terminal reconcile span both carry it) — but it
//       is derived from an observed counter, it is non-zero the moment work happens, and it therefore makes
//       overBudget() reachable. A runaway loop now HALTS instead of billing silently.
// Prices are per 1M OUTPUT tokens (output dominates agent cost; input is not modeled — another reason the
// estimate is conservative-by-construction on the input side and must never be called an invoice).
const PRICE_USD_PER_MTOK_OUT = { opus: 75, sonnet: 15, haiku: 4 }
const UNMETERED_OUT_TOKENS_PER_DISPATCH = 3000 // documented ASSUMPTION for the no-meter fallback only (~3k output tokens for a typical WALTEUR agent turn). Never presented as measured.
const _laneDispatches = { opus: 0, sonnet: 0, haiku: 0, unknown: 0 }
const _totalDispatches = () => _laneDispatches.opus + _laneDispatches.sonnet + _laneDispatches.haiku + _laneDispatches.unknown
// lane-mix-weighted $/Mtok: what a token ACTUALLY costs given the mix this build dispatched. Falls back to
// the sonnet rate before any dispatch exists (default_model in model-routing.json), never to a flat blend.
function blendedRateUsdPerMtok() {
  const n = _totalDispatches()
  if (!n) return PRICE_USD_PER_MTOK_OUT.sonnet
  const weighted = _laneDispatches.opus * PRICE_USD_PER_MTOK_OUT.opus
    + _laneDispatches.sonnet * PRICE_USD_PER_MTOK_OUT.sonnet
    + _laneDispatches.haiku * PRICE_USD_PER_MTOK_OUT.haiku
    + _laneDispatches.unknown * PRICE_USD_PER_MTOK_OUT.sonnet
  return weighted / n
}
// unmetered fallback: REAL per-lane dispatch counts × assumed output tokens × that lane's real price.
function unmeteredEstUsd() {
  const t = UNMETERED_OUT_TOKENS_PER_DISPATCH / 1e6
  return +(t * (_laneDispatches.opus * PRICE_USD_PER_MTOK_OUT.opus
    + _laneDispatches.sonnet * PRICE_USD_PER_MTOK_OUT.sonnet
    + _laneDispatches.haiku * PRICE_USD_PER_MTOK_OUT.haiku
    + _laneDispatches.unknown * PRICE_USD_PER_MTOK_OUT.sonnet)).toFixed(2)
}
// meterStatus() — names the cost source HONESTLY, and names a BROKEN meter as broken:
//   'metered'                    — a budget object exists and has reported a non-zero per-build delta.
//   'metered_zero'               — a budget object exists but reported ZERO after dispatches happened.
//                                  That is a BROKEN meter, not a free build: it is a LOUD failure
//                                  (exit_code 2 span + blocker), never a silent green.
//   'unmetered_dispatch_estimate'— no budget object; the ceiling is enforced off the real dispatch counter.
//   'idle'                       — nothing dispatched yet; nothing to say.
function meterStatus() {
  const metered = (typeof budget !== 'undefined' && budget && budget.spent)
  const delta = metered ? Math.max(0, budget.spent() - _spentAtStart) : 0
  if (!metered) return _totalDispatches() ? 'unmetered_dispatch_estimate' : 'idle'
  if (delta > 0) return 'metered'
  return _totalDispatches() ? 'metered_zero' : 'idle'
}
const estUsd = () => {
  const metered = (typeof budget !== 'undefined' && budget && budget.spent)
  const delta = metered ? Math.max(0, budget.spent() - _spentAtStart) : 0
  // BUG-G fix (retained): per-BUILD delta, NOT session-cumulative. budget.spent() is a turn-wide SHARED pool
  // across the main loop + all workflows; without subtracting the start snapshot, a busy session trips the
  // per-build $ceiling on EVERY new build before any work happens.
  if (delta > 0) return +(delta / 1e6 * blendedRateUsdPerMtok()).toFixed(2)
  // no meter, or a meter reporting zero while work is happening: fall back to the observed dispatch counter
  // so the ceiling has a real, non-zero input. NEVER returns a hardcoded 0 once dispatches exist.
  return +unmeteredEstUsd()
}
// A5 — fail-CLOSED budget guard. The old form returned true (no-op) whenever no budget object existed,
// allowing unbounded-cost refine oscillation. Now: with a real budget, gate on remaining()+$ceiling;
// WITHOUT one, bound hard by a refine cap so cost can never run away on a stuck loop.
let refineIter = 0
const HARD_REFINE_CAP = 6  // v10.20: matches spec §3.x cap 6 (was 5)
const haveBudget = !(typeof budget === 'undefined' || !budget || !budget.total)
const budgetGuard = () => haveBudget ? (budget.remaining() > 40_000 && estUsd() < MAX_USD) : (estUsd() < MAX_USD && refineIter < HARD_REFINE_CAP)

// S033 #9 — PER-PHASE TOKEN RECONCILIATION. Every emitSpan() call site defaults tokens=0 and (before this
// change) NO caller ever passed a real value, so run-trace.sh --rollup summed zeros — vacuous. `budget` (when
// the harness provides one) exposes a REAL, harness-metered spent() counter shared across this whole turn;
// tokensSincePhase() returns the DELTA consumed since the last call, i.e. this phase's real token spend.
// Honest labeling per the harness contract: this is the harness's own metered count (not a chars/4 guess),
// so it is passed as a genuine `tokens` value, not an "estimate_chars4" one — BUT when no `budget` object
// exists (haveBudget=false, e.g. a stub runner), we fall back to 0 (never fabricate a number with no source).
let _tokensCursor = _spentAtStart
function tokensSincePhase() {
  if (!haveBudget || !budget.spent) return 0
  const now = budget.spent()
  const delta = Math.max(0, now - _tokensCursor)
  _tokensCursor = now
  return delta
}

// ── BUG-A FIX — BOUNDED CONTEXT. cap(str, maxKb) truncates large inlined strings so no agent
//    prompt overflows the model input window. Applies to all research/think/plan/audit/fork prompts
//    that inline large parallel-results arrays or full JSON objects.
//    Choice: 24 KB (≈6k tokens at ~4 chars/token) per inlined block keeps each block well inside a
//    200k-token model window even with 5–8 large injections in the same prompt; anything bigger goes
//    via file-path read (the brief pattern) not inline injection. The truncation marker is explicit so
//    an agent knows data was cut and does not hallucinate the missing tail.
function cap(str, maxKb = 24) {
  const maxChars = maxKb * 1024
  if (typeof str !== 'string') str = JSON.stringify(str)
  if (str.length <= maxChars) return str
  return str.slice(0, maxChars) + `\n…[truncated to ${maxKb}KB — full data in project files]`
}

// ── BUG-B FIX — MID-RUN BUDGET ENFORCEMENT. overBudget() is the hard per-wave/per-fanout gate.
//    Returns true when the running cost estimate meets or exceeds the ceiling so the caller can STOP.
//    Labeled as an estimate (never a precise invoice). Inline node-assertion (self-documenting):
//      overBudget(25, 25) → true  (at ceiling)
//      overBudget(25.01, 25) → true  (over ceiling)
//      overBudget(24.99, 25) → false  (under ceiling)
function overBudget(spentUsd, ceiling) { return spentUsd >= ceiling }
// inline assertion — proves the helper contract without requiring a test harness
;(() => {
  if (overBudget(25, 25) !== true) throw new Error('overBudget: at-ceiling should be true')
  if (overBudget(25.01, 25) !== true) throw new Error('overBudget: over-ceiling should be true')
  if (overBudget(24.99, 25) !== false) throw new Error('overBudget: under-ceiling should be false')
})()
// budgetStop() writes the BUDGET_EXCEEDED sentinel files and returns the partial result object.
// Called at each wave boundary and before each major fan-out when overBudget() fires.
async function budgetStop(waveDone, phaseName) {
  const spent = estUsd()
  const meterAtStop = meterStatus()
  log(`BUDGET STOP: $${spent} >= ceiling $${MAX_USD} at ${phaseName} (wave ${waveDone}) · meter=${meterAtStop} · ${_totalDispatches()} dispatch(es) [${_laneDispatches.opus}o/${_laneDispatches.sonnet}s/${_laneDispatches.haiku}h] — halting swarm. Partial result with SHIPPABLE=false.`)
  emitSpan({ phase: phaseName, model: 'n/a', tool: 'budget-stop', exit_code: '2', gate_verdict: `BUDGET_EXCEEDED:true(est_usd=${spent},ceiling_usd=${MAX_USD},meter=${meterAtStop},dispatches=${_totalDispatches()})` })
  await safeOne(() => dispatch(
    `WALTEUR budget-stop (BUG-B mid-run ceiling). Using Bash \`mkdir -p ${projectPath}/_relay ${projectPath}/walteur-kit\`, then use the Write tool to create TWO files verbatim:\n` +
    `FILE ${projectPath}/walteur-kit/autopilot/STATE.json:\n{"phase":"BUDGET_EXCEEDED","completed_task_ids":${JSON.stringify([...completedIds])}}\n\n` +
    `FILE ${projectPath}/_relay/receipt.json:\n${JSON.stringify({ est_usd: spent, ceiling_usd: MAX_USD, shippable: false, phase_stopped: phaseName, wave_done: waveDone, meter: meterAtStop, dispatches_total: _totalDispatches(), lane_dispatches: { ..._laneDispatches }, note: meterAtStop === 'metered' ? 'build halted at cost ceiling — metered output tokens priced at the lane-mix-weighted rate; conservative, not an invoice' : 'build halted at cost ceiling — NO harness token meter, so the estimate came from the REAL per-lane dispatch counter x an assumed per-dispatch output size; an estimate from an observed counter, never an invoice' })}\n\n` +
    `FILE ${projectPath}/_relay/ISSUES.md:\n# Build halted — budget ceiling reached\nHalted at estimated $${spent} of $${MAX_USD} ceiling at phase ${phaseName}, wave ${waveDone}.\n\n**Partial build:** ${[...completedIds].length} task(s) completed.\n\n**To resume:** raise the ceiling via \`maxCostUsd\` arg (e.g. \`/goal <idea> maxCostUsd=50\`) then re-run /goal — STATE.json checkpoints skip already-built tasks.\n\nReport done.`,
    { label: `budget-stop:${phaseName}`, model: 'sonnet', phase: phaseName }), `budget-stop:${phaseName}`)
  return {
    idea, projectPath, SHIPPABLE: false,
    budget_stop: true, est_usd: spent, ceiling_usd: MAX_USD,
    meter: meterAtStop, dispatches_total: _totalDispatches(), lane_dispatches: { ..._laneDispatches },
    phase_stopped: phaseName, wave_done: waveDone,
    completed_tasks: [...completedIds].length, plan_tasks: (plan && plan.tasks && plan.tasks.length) || 0,
    note: `Build halted at estimated $${spent} (ceiling $${MAX_USD}). Raise maxCostUsd and re-run /goal to continue — completed tasks are checkpointed in STATE.json.`,
  }
}
// BUG-F fix — declare completedIds BEFORE any budget gate. budgetStop() reads [...completedIds], but the
// Think-phase gate (BUG-D, line ~343) fires long before the Build phase where completedIds was originally
// declared (line ~671), so an early budget stop crashed with a temporal-dead-zone ReferenceError. Declared
// empty here; the A2-resume below REASSIGNS it (no longer redeclares) so checkpoint-resume still works.
let completedIds = new Set()
let plan = null // BUG-F-2: declared early so budgetStop()'s `plan_tasks` read can't TDZ-crash when a budget gate fires before the Plan phase; REASSIGNED (not redeclared) at the Plan phase below.
log(`WALTEUR build: "${idea}" -> ${projectPath} · cost ceiling $${MAX_USD}`)

// ── §2a — HITL autonomy policy. Read from scopeAnswers first, then top-level args; default full_autopilot.
// The default path (full_autopilot) reaches DONE with ZERO behavior change.
const autonomyPolicy = (given && given.autonomy_policy) || A.autonomy_policy || 'full_autopilot'

// >>> FAILCLASS-LOGIC START (pure; S033 #7 infra-vs-product failure classification — keep self-contained, no outer refs)
// classifyFailure(label) — a CLOSED allowlist (not a keyword grep an agent could game): only labels that
// literally match one of the known non-product bookkeeping call sites classify 'infra' (telemetry flush,
// scope-track ledger write, persona-engagement breadcrumbs, self-optimize outcome queue, STATE.json
// checkpoint writes). EVERYTHING else — build:T<id>, refine:*, review:*, qa:*, audit:*, triage:*, debate:*,
// etc. — classifies 'product' by default (the safe default: an unrecognized label never gets a free pass).
// This honors the flushSpans comment (line ~179, "never blocks the build") which the OLD shippable check
// (failures.length===0) contradicted: one flaky telemetry flush or ledger write could sink an otherwise
// shippable one-shot. classifyFailure is pure + closed-allowlist so it cannot be gamed by an agent labeling
// a real build failure "infra" — only the ENGINE assigns labels, at fixed safeOne() call sites.
const INFRA_LABEL_RE = /^(trace:flush|scope-track|persona:breadcrumbs|self-optimize:queue|state:|checkpoint:|freeze-briefs|reconcile:wave|spawn-justify|wip:wave|compact:wave|approve:|emit-estimate|write-PLAN\.md|design-contract|scaffold:context|debate:adr)\b/
function classifyFailure(label) {
  return INFRA_LABEL_RE.test(String(label || '')) ? 'infra' : 'product'
}
// inline assertions (same pattern as overBudget above) — proves the allowlist contract without a test harness
;(() => {
  if (classifyFailure('trace:flush:Audit') !== 'infra') throw new Error('classifyFailure: trace:flush should be infra')
  if (classifyFailure('build:T3') !== 'product') throw new Error('classifyFailure: build:T3 should be product')
  if (classifyFailure('refine:2') !== 'product') throw new Error('classifyFailure: refine:2 should be product')
  if (classifyFailure('scope-track') !== 'infra') throw new Error('classifyFailure: scope-track should be infra')
  if (classifyFailure(undefined) !== 'product') throw new Error('classifyFailure: unlabeled/unknown should default product (safe default)')
})()
// <<< FAILCLASS-LOGIC END

// ── A3 — no silent drops. safeOne() retries, falls back a model tier, then returns a FAILED sentinel
//    that is COUNTED (forces shippable=false + a codified blocker) — never silently filter(Boolean)'d away.
//    thunk(useFallback) builds the agent() call; on the 2nd attempt it should drop to the cheaper tier.
const failures = []
async function safeOne(thunk, label) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      // S038 #3 — tell dispatch() that THIS invocation is a retry, so a drop to the sonnet fallback tier is
      // recognized as model-routing.json's declared .fallback_policy.on_retry rather than reported as a
      // routing violation. Set immediately before the SYNCHRONOUS thunk call and cleared immediately after
      // it returns its promise — dispatch() reads the flag synchronously inside the thunk, before any await,
      // so a concurrent parallel() fan-out can never observe another call's flag.
      _retryDispatch = attempt > 0
      const p = thunk(attempt > 0)
      _retryDispatch = false
      const r = await p
      // S1 — tag fallback-tier successes so the reconcile join can mark them DONE_WITH_CONCERNS (a build
      // that only succeeded on the cheaper tier is a real concern, not a clean PASS). Object results only.
      if (r) { if (attempt > 0 && typeof r === 'object') r.__usedFallback = true; return r }
    } catch (e) { _retryDispatch = false; log(`${label}: attempt ${attempt} error ${(e && e.message) || e}`) }
  }
  log(`${label}: FAILED after retry+fallback — recorded as a blocker (no silent drop)`)
  // S1 — carry the task id so the wave-reconcile join (`build.find(b => b.id === t.id)`) MATCHES a failed
  // build-task sentinel and classifies it BLOCKED, not GAP. label is `build:T<id>`; parse the id back out.
  const m = /^build:T(\d+)$/.exec(label || '')
  const s = { __failed: true, label, status: 'FAILED' }
  if (m) s.id = Number(m[1])
  failures.push(s); return s
}
const ok = (arr) => arr.filter(x => x && !x.__failed) // the SUCCESS set; failures are tracked separately, never erased

const APPROVE_SCHEMA = { type: 'object', additionalProperties: false, required: ['approved'], properties: { approved: { type: 'boolean' } } }
// ── v9.2 #9 — NAMED AUTONOMY SEAMS REGISTRY (all OPT-IN; full_autopilot fires NONE) ─────────────────
// WALTEUR's human-in-the-loop pauses are placed at exactly these named seams (the requireApproval call
// sites). Documenting them as a registry gives #1's Intent re-DISCOVER branch a named home (Seam 4) and
// makes the seam set auditable. Every seam is gated by autonomy_policy — the DEFAULT (full_autopilot)
// fires NONE, so today's autopilot path is byte-for-byte unchanged.
//   Seam 1 · POST-PLAN   (after PLAN, before BUILD)   — fires when policy ∈ {pause_at_plan_and_audit, pause_per_task}. Gate "PLAN".
//   Seam 2 · POST-REVIEW (after REVIEW, before REFINE) — EXPOSED (v9.2 #9 + #7). Wired in code and now
//     reachable: 'pause_at_review' is in STATE.json _autonomy_options and documented in SKILL.md §2a.
//     Pauses after the governance panel + advisory findings complete, before REFINE spends budget — lets a
//     human inspect verdicts and decide whether to proceed. Gate "REVIEW".
//   Seam 3 · POST-AUDIT  (after AUDIT, before SHIP)    — fires when policy ∈ {pause_at_plan_and_audit, pause_per_task}. Gate "SHIP".
//   Seam 4 · INTENT-REDISCOVER (in REFINE, before a re-DISCOVER) — ALWAYS pauses regardless of policy (see §Refine); the only non-opt-in seam, because re-DISCOVER must never run unattended.
//   (Per-wave: pause_per_task also pauses after each build WAVE — gate "BUILD-WAVE-<n>".)
// HITL gate (§2a) — OFF unless autonomy_policy==='pause_at_plan_and_audit' (Seams 1+3) or 'pause_per_task'.
// Halt-and-resume: write a request, proceed only if a FRESH human APPROVED file exists (newer than the
// request, consumed on read). Otherwise STOP with an honest resume instruction (re-running /goal resumes).
// Never hangs. The optional `policies` arg restricts a seam to specific policies (Seam 2 uses it).
async function requireApproval(gateName, summary, policies) {
  // Default seams (1/3 and per-wave): the ORIGINAL guard, byte-for-byte — HITL cannot silently flip on.
  if (!policies && autonomyPolicy !== 'pause_at_plan_and_audit' && autonomyPolicy !== 'pause_per_task') return true
  // Seam-scoped override (v9.2 #9 Seam 2): a caller-supplied policy list restricts WHICH policy fires this seam.
  if (policies && !policies.includes(autonomyPolicy)) return true
  const res = await safeOne(() => dispatch(
    `WALTEUR HITL approval gate "${gateName}". In ${projectPath} using Bash:\n` +
    `1) Write walteur-kit/APPROVAL-REQUEST.json = {"gate":"${gateName}","summary":${JSON.stringify(summary)},"ts": <output of \`date +%s\`>}.\n` +
    `2) If file walteur-kit/APPROVED exists AND is newer than APPROVAL-REQUEST.json (test: \`[ walteur-kit/APPROVED -nt walteur-kit/APPROVAL-REQUEST.json ]\`): run \`rm -f walteur-kit/APPROVED\` (consume it) and return approved=true.\n` +
    `3) Otherwise return approved=false.\n` +
    `Return ONLY {"approved": <bool>}.`,
    { model: 'sonnet', label: `approve:${gateName}`, phase: 'Approve', schema: APPROVE_SCHEMA }), `approve:${gateName}`)
  return !!(res && res.approved)
}

// ── v9.2 #2 — run-trace telemetry: flat append-only span ledger. NOT a retrieval index; graphify stays
//    the one brain. Spans are ACCUMULATED per phase, flushed ONCE per phase boundary via a single safeOne
//    Bash agent call (≤11 flushes per full build, never ~50). A failed flush = tracked non-fatal blocker
//    (safeOne pushes to failures[]) — never blocks the build. Tokens are labeled "estimate" (never metered).
//    Respects WALTEUR_TRACE=off (loud skip). No outcome fields (those belong to pending-feedback.jsonl).
// S033 #10 — ROUTING CONFORMANCE. walteur.js has no `fs`/`require` (confirmed: no imports anywhere in this
// file — every I/O goes through agent()+Bash), so it cannot read walteur-kit/model-routing.json at runtime.
// MODEL_ROUTING_BY_PHASE is therefore an embedded MIRROR of model-routing.json's `.by_phase` table — if that
// JSON's phase table changes, this const must be updated to match (documented here so it's not silently
// missed). This IS the honest, in-process check available: DECLARED (this table) vs REQUESTED (the model
// literal at the call site) conformance. Payload verification — whether the harness actually ROUTED to that
// model — is NOT available in-process (agent() results carry no model-echo metadata); a mismatch here only
// proves the ENGINE requested a model that disagrees with its own declared table, which is still a real,
// catchable defect class (e.g. a future edit that hardcodes 'sonnet' at an Audit call site).
const MODEL_ROUTING_BY_PHASE = { 'Self-Heal': 'sonnet', 'Scope': 'opus', 'Think': 'opus', 'Team': 'opus', 'Plan': 'opus', 'Debate': 'opus', 'Build': 'sonnet', 'Review': 'opus', 'Refine': 'opus', 'Validate': 'opus', 'Audit': 'opus' }
// S038 #2 — 'n/a' IS NOT A REQUESTED MODEL. The terminal token-reconciliation span (and every future
// Bash-only span) emits model:'n/a', which is emitSpan's own default for "this span had no model". The old
// guard only rejected a FALSY requestedModel, so 'n/a' was compared against the phase's declared model and
// reported routing_mismatch:true on EVERY real run (see the reconcile row in every field-runs trace). That
// built-in false positive is exactly what made routing_mismatch un-gateable: a hook exiting 2 on it would
// have been permanently red for a reason that is not a defect. 'n/a' (and '') now mean unchecked.
const NO_MODEL_SENTINELS = ['n/a', 'na', 'none', '-', '']
function routingConformance(phaseName, requestedModel) {
  const declared = MODEL_ROUTING_BY_PHASE[phaseName]
  const req = String(requestedModel || '').trim().toLowerCase()
  if (!declared || NO_MODEL_SENTINELS.indexOf(req) !== -1) return { checked: false } // phase not in the table, or no model requested (e.g. a Bash-only / reconcile span) — nothing to check
  return { checked: true, declared, requested: requestedModel, routing_mismatch: declared !== requestedModel }
}
;(() => { // inline assertions (same pattern as overBudget/classifyFailure above)
  if (routingConformance('Audit', 'sonnet').routing_mismatch !== true) throw new Error('routingConformance: Audit+sonnet should mismatch (table says opus)')
  if (routingConformance('Audit', 'opus').routing_mismatch !== false) throw new Error('routingConformance: Audit+opus should conform')
  if (routingConformance('NotAPhase', 'opus').checked !== false) throw new Error('routingConformance: unknown phase should be unchecked, not a false mismatch')
  if (routingConformance('Audit', 'n/a').checked !== false) throw new Error("routingConformance: 'n/a' means NO model requested — must be unchecked, not a mismatch")
})()

// ── S038 #3 — CONFORMANCE AT THE DISPATCH, NOT AT THE ANNOTATION.
// BEFORE: routingConformance() had exactly ONE production call site — inside emitSpan() — so it audited the
// ~23 telemetry spans while all ~66 REAL agent() dispatch sites went unchecked. A future edit hardcoding
// 'sonnet' at an Audit dispatch was invisible unless someone also emitted a span for it.
// NOW: every dispatch goes through dispatch(), the single choke point, which checks the requested model
// against the models model-routing.json's `routes[]` actually PERMITS for that phase — not just `by_phase`'s
// single primary, because the routing file legitimately declares per-phase alternates (Build escalates to
// opus for security/concurrency/migration/payments/auth/schema/money tasks; Validate runners and routine
// Refine edits de-escalate to sonnet; Think's currency-scout and DIVERGE frames are sonnet). Hand-mirrored
// like MODEL_ROUTING_BY_PHASE above (walteur.js has no fs) — walteur-run.mjs asserts BOTH mirrors against
// walteur-kit/model-routing.json on every run and exits non-zero on drift, so the copies cannot rot silently.
const ALLOWED_MODELS_BY_PHASE = {
  'Self-Heal': ['sonnet'], 'Scope': ['opus'], 'Think': ['opus', 'sonnet'], 'Team': ['opus'], 'Plan': ['opus'],
  'Debate': ['opus'], 'Build': ['sonnet', 'opus'], 'Review': ['opus'], 'Refine': ['opus', 'sonnet'],
  'Validate': ['opus', 'sonnet'], 'Audit': ['opus'],
}
// The MECHANICAL lane (model-routing.json lanes.mechanical = haiku). A CLOSED allowlist of pure-bookkeeping
// labels — telemetry flush, ledger/breadcrumb appends, STATE.json checkpoints, WIP notes, wave compaction.
// These are Bash/Write calls with no product judgment in them, so they are (a) always permitted to run on
// haiku in any phase and (b) ACTIVELY downgraded to haiku by dispatch(). Before this, only 2 of ~66
// dispatches ever requested haiku, so the declared three-lane policy was really two lanes and every
// bookkeeping append burned mid-tier tokens. Deliberately NARROWER than INFRA_LABEL_RE (which also covers
// judgment-ish infra like debate:adr / design-contract / emit-estimate — those stay on their declared lane).
const MECHANICAL_LABEL_RE = /^(trace:flush|scope-track|persona:breadcrumbs|self-optimize:queue|state:|checkpoint:|wip:wave|compact:wave)\b/
const FALLBACK_TIER = 'sonnet' // model-routing.json .fallback_policy.on_retry
let _retryDispatch = false // set by safeOne() immediately before invoking a RETRY thunk; read synchronously by dispatch()
const _routingViolations = []
function dispatchConformance(phaseName, model, label, isRetry) {
  const allowed = ALLOWED_MODELS_BY_PHASE[phaseName]
  const m = String(model || '').trim().toLowerCase()
  if (!allowed || !m) return { checked: false }
  if (allowed.indexOf(m) !== -1) return { checked: true, violation: false, reason: 'declared' }
  if (m === 'haiku' && MECHANICAL_LABEL_RE.test(String(label || ''))) return { checked: true, violation: false, reason: 'mechanical_lane' }
  if (m === FALLBACK_TIER && isRetry) return { checked: true, violation: false, reason: 'retry_fallback_tier' }
  return { checked: true, violation: true, reason: 'not_permitted_for_phase', allowed: allowed.join('|'), requested: m }
}
;(() => { // inline assertions — the contract, provable without a harness
  if (dispatchConformance('Audit', 'sonnet', 'audit:final', false).violation !== true) throw new Error('dispatchConformance: Audit+sonnet must be a violation (routes[] permits opus only)')
  if (dispatchConformance('Audit', 'sonnet', 'audit:final', true).violation !== false) throw new Error('dispatchConformance: a RETRY on the sonnet fallback tier is permitted (fallback_policy.on_retry)')
  if (dispatchConformance('Build', 'opus', 'build:T4', false).violation !== false) throw new Error('dispatchConformance: Build+opus is a DECLARED escalation for tagged tasks')
  if (dispatchConformance('Audit', 'haiku', 'trace:flush:Audit', false).violation !== false) throw new Error('dispatchConformance: the mechanical lane may run bookkeeping on haiku in any phase')
  if (dispatchConformance('Audit', 'haiku', 'audit:final', false).violation !== true) throw new Error('dispatchConformance: haiku for a NON-mechanical label must still be a violation')
  if (dispatchConformance('Preflight', 'sonnet', 'x', false).checked !== false) throw new Error('dispatchConformance: a phase absent from routes[] is unchecked, not a false violation')
})()
// dispatch(prompt, opts) — THE single agent() choke point. Transparent (same signature, same return), and it
// is what makes the cost ceiling and the routing policy real rather than annotated:
//   1. MECHANICAL LANE — a bookkeeping label is downgraded to haiku (the declared mechanical lane).
//   2. CONFORMANCE — the effective model is checked against routes[] for the phase; a violation is recorded
//      AND emitted as an exit_code:2 span so run-trace.jsonl carries it for any consuming gate.
//   3. COST — the per-lane dispatch counter that feeds estUsd()/overBudget() is incremented HERE, which is
//      why the ceiling has a real input even in a harness with no token meter.
function dispatch(prompt, opts = {}) {
  const o = opts || {}
  const label = String(o.label || '')
  const isRetry = _retryDispatch
  let model = o.model || 'sonnet' // model-routing.json .default_model
  if (MECHANICAL_LABEL_RE.test(label) && model !== 'haiku') model = 'haiku'
  const conf = dispatchConformance(o.phase, model, label, isRetry)
  if (conf.checked && conf.violation) {
    _routingViolations.push({ phase: o.phase, label, requested: model, allowed: conf.allowed })
    emitSpan({ phase: o.phase, model, tool: 'dispatch', exit_code: '2', gate_verdict: `routing_violation:true(label=${label},allowed=${conf.allowed},requested=${model})` })
    log(`ROUTING VIOLATION · ${o.phase || '?'} · ${label || 'unlabeled'} requested '${model}' but routes[] permits ${conf.allowed} — recorded to run-trace.jsonl (exit_code 2).`)
  }
  if (model === 'opus' || model === 'sonnet' || model === 'haiku') _laneDispatches[model]++
  else _laneDispatches.unknown++
  return agent(prompt, model === o.model ? o : { ...o, model })
}
const _spanQueue = []
function emitSpan({ phase: ph, model: mdl = 'n/a', tool: tl = '', exit_code: ec = '0', gate_verdict: gv = '', tokens: tok = 0 }) {
  if ((typeof process !== 'undefined' && process.env && process.env.WALTEUR_TRACE === 'off')) return
  // S033 #10 — fold routing-conformance into gv (gate_verdict) as a suffix so it survives the existing
  // {phase,model,tool,exit_code,gate_verdict,tokens} trace schema with ZERO shape changes (no new field to
  // migrate every consumer for). Only appends when a mismatch is actually found — a conforming span's gv is
  // untouched, so today's honest traces (e.g. jsonlint-cli's) stay byte-identical.
  const rc = routingConformance(ph, mdl)
  const gv2 = (rc.checked && rc.routing_mismatch) ? `${gv}${gv ? ';' : ''}routing_mismatch:true(declared=${rc.declared},requested=${rc.requested})` : gv
  _spanQueue.push({ ph, mdl, tl, ec: String(ec), gv: String(gv2), tok: Number(tok) || 0 })
}
async function flushSpans(forPhase) {
  if (_spanQueue.length === 0) return
  if ((typeof process !== 'undefined' && process.env && process.env.WALTEUR_TRACE === 'off')) { _spanQueue.length = 0; return }
  const spans = _spanQueue.splice(0) // drain atomically
  const lines = spans.map(s => {
    // ts is generated bash-side (workflow scripts cannot call the JS Date API). Inject it as a printf
    // ARG so the double-quoted $(date) actually substitutes, while the json body stays single-quoted
    // (literal — bash does no expansion). The old form put $(date) INSIDE the single quotes, so every
    // row got a literal "$(date...)" string instead of a timestamp.
    const body = JSON.stringify({ phase: s.ph, model: s.mdl, tool: s.tl, exit_code: s.ec, gate_verdict: s.gv, tokens: { estimate: s.tok } }).slice(1, -1)
    const esc = body.replace(/'/g, "'\\''")
    return `printf '{"ts":"%s",%s}\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '${esc}'`
  }).join(' && ')
  const appendCmd = `mkdir -p ${projectPath}/walteur-kit && ( ${lines} ) >> ${projectPath}/walteur-kit/run-trace.jsonl`
  await safeOne(() => dispatch(`WALTEUR run-trace flush (v9.2 telemetry). Using Bash, run EXACTLY:\n\`${appendCmd}\`\nReport done.`,
    { model: 'sonnet', label: `trace:flush:${forPhase}`, phase: forPhase }), `trace:flush:${forPhase}`)
}

// ── §0.0 STEP 0 — UPSTREAM SELF-HEAL (token-cheap; fail-OPEN; never blocks) ──
phase('Self-Heal')
emitSpan({ phase: 'Self-Heal', model: 'sonnet', tool: 'Bash', exit_code: '0', tokens: tokensSincePhase() })
await safeOne(() => dispatch(
  `WALTEUR Step 0 upstream self-heal (token-cheap, fail-open). In ${projectPath} run EXACTLY: \`bash walteur-kit/self-heal.sh 2>&1 || true\` (it is TTL-cached, so ~free on repeat runs; pure git ls-remote, ~0 tokens). Report its one-line summary verbatim. If it reports "MATERIAL drift", the script has ALREADY appended the drift proposal to _relay/ISSUES.md — just note that and STOP. Do NOT fetch changelogs inline (no WebFetch, no curl): the per-source changelog deep-dive is the standalone /self-heal command's job, NOT a build-time step. Build-time self-heal stays token-cheap and NEVER blocks on a network fetch (BUG-C fix: inline GitHub release WebFetches 404 and stalled the build before any product work).`,
  { model: 'sonnet', label: 'self-heal', phase: 'Self-Heal' }), 'self-heal')

// ───────────────────────── SCOPE ─────────────────────────
await flushSpans('Self-Heal')
phase('Scope')
emitSpan({ phase: 'Scope', model: 'opus', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
const SCOPE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['one_line', 'users_and_metric', 'in_scope', 'out_scope', 'stack', 'constraints', 'is_brownfield', 'domain', 'assumptions', 'data_needs', 'data_domains'],
  properties: {
    one_line: { type: 'string' }, users_and_metric: { type: 'string' },
    in_scope: { type: 'array', items: { type: 'string' } }, out_scope: { type: 'array', items: { type: 'string' } },
    stack: { type: 'string' }, constraints: { type: 'string' },
    is_brownfield: { type: 'boolean' },
    domain: { type: 'string', description: 'the problem domain (web app, CLI, data pipeline, research report, ML, etc.) — drives which specialists to create' },
    assumptions: { type: 'array', items: { type: 'string' } },
    // S033 #3 — DATA NEEDS. true when the build genuinely needs REAL external data pulled during the build
    // (a research report, market analysis, data pipeline, anything whose deliverable IS pulled data) — as
    // opposed to a normal software build that just reads its own dependency docs. Drives data-pull-required-gate.
    data_needs: { type: 'boolean', description: 'true ONLY if this build must pull REAL external/live data during the build to be genuinely done (research report, market analysis, data pipeline) — false for an ordinary software/CLI/UI build' },
    data_domains: { type: 'array', items: { type: 'string' }, description: 'if data_needs is true, the domains/topics/sources the build must pull data about (e.g. "competitor pricing", "arxiv ML papers"); [] if data_needs is false' },
  },
}
const scope = await dispatch(
  `You are the WALTEUR scoping lead. Idea: "${idea}". Project path: ${projectPath}.\n` +
  (given ? `Tony answered: ${JSON.stringify(given)}.\n` : `No answers given — pick the SIMPLEST defensible reading; record every assumption.\n`) +
  `Run \`ls -la ${projectPath} 2>/dev/null\` to detect brownfield (existing codebase) vs greenfield. Lock the NARROWEST genuinely-shippable wedge. Name the domain (it drives which specialists get created).\n` +
  `DATA NEEDS (S033 #3): set data_needs=true ONLY if the deliverable itself requires REAL external/live data pulled during this build (a research report, market/competitor analysis, a data pipeline ingesting live sources) — an ordinary software/CLI/UI build that merely reads its own dependency docs is data_needs=false. If true, name the concrete domains/topics/sources in data_domains.`,
  { schema: SCOPE_SCHEMA, model: 'opus', phase: 'Scope' }
)
const brownfield = wantMode === 'brownfield' || (wantMode === 'auto' && scope.is_brownfield)
log(`scope · ${brownfield ? 'BROWNFIELD' : 'GREENFIELD'} · domain: ${scope.domain} · stack: ${scope.stack}`)

// S033 #5 — ASSUMPTION LEDGER. SCOPE_SCHEMA has required scope.assumptions[] (the Scope agent already
// decides/records them when scopeAnswers is absent), but until now that array lived only in-memory and
// evaporated — Tony could never audit WHAT the engine silently assumed on an ambiguous one-shot. Persist it
// to walteur-kit/assumptions.json now (Scope phase) so it survives; the BATON/summary reference the path so
// it is discoverable post-build (see finalBaton). Best-effort (safeOne — a failed write never blocks Scope).
const assumptionLedger = { assumed_at: _NOW_ISO, phase: 'Scope', assumptions: (scope.assumptions || []).map(a => ({ assumption: a, risk: 'unrated', revisit_when: 'scope revisited or Intent re-DISCOVER' })) }
await safeOne(() => dispatch(`WALTEUR assumption ledger (v10.2 #5). Using Bash \`mkdir -p ${projectPath}/walteur-kit\`, then use the Write tool to create ${projectPath}/walteur-kit/assumptions.json with EXACTLY this content (verbatim): ${JSON.stringify(assumptionLedger)}`,
  { label: 'assumptions:write', model: 'sonnet', phase: 'Scope' }), 'assumptions:write')
if (assumptionLedger.assumptions.length) log(`v10.2 #5 · ${assumptionLedger.assumptions.length} assumption(s) recorded → walteur-kit/assumptions.json`)

// ── v9.2 #12 — SCOPE-ADAPTIVE GRADED CEREMONY. A classify_scope step picks a track:
//   quick-fix (1-2 files) | standard | complex. The track flexes ONLY PROTOCOL ceremony — quick-fix gets a
//   1-task PLAN, no PRD/benchmark demanded, single-line reconciliation. The HARD machinery gates (panel,
//   QA corps incl. Logic-Correctness + Security floor, terminal audit, evidence re-run, composite≥target)
//   run UNCHANGED on EVERY track — non-negotiable. Default = 'standard' on any ambiguity (today's behavior).
//   See CEREMONY-LOGIC pure block (below, near the wave logic) for the deterministic classifier the selftest
//   proves. Caller may force a track via A.track ('quick-fix'|'standard'|'complex').
// >>> CEREMONY-LOGIC START (pure; v9.2 #12 — keep self-contained, no outer refs)
// S6 — file_count is often undefined (A.fileCount not in STATE.json args); fall back to in_scope_count
// as the file-breadth proxy so quick-fix is reachable. in_scope_count is the best available signal
// (it reflects the number of scope items, a close proxy for touched-file breadth on small tasks).
// 'standard' remains the safe default on any ambiguity — behavior-preserving for the existing path.
function classifyScopeTrack({ forced, file_count, in_scope_count = 0, is_brownfield = false }) {
  const T = { 'quick-fix': 1, 'standard': 1, 'complex': 1 }
  if (forced && T[forced]) return forced // explicit caller override wins
  const fc = Number.isFinite(Number(file_count)) ? Number(file_count) : in_scope_count // S6 — fallback proxy
  if (fc >= 1 && fc <= 2 && in_scope_count <= 3) return 'quick-fix'
  if (fc >= 8 || in_scope_count >= 8) return 'complex'
  return 'standard' // default on ambiguity — preserves today's behavior
}
// ceremony fidelity per track — PROTOCOL only; the HARD gate set is identical across all three.
const CEREMONY = {
  'quick-fix': { plan_tasks: '1 task', demand_prd: false, demand_benchmark: false, reconciliation: 'single-line' },
  'standard':  { plan_tasks: 'a tight DAG', demand_prd: true, demand_benchmark: false, reconciliation: 'per-task' },
  'complex':   { plan_tasks: 'a full DAG', demand_prd: true, demand_benchmark: true, reconciliation: 'per-task' },
}
// <<< CEREMONY-LOGIC END
const scopeTrack = (() => {
  const fc = (scope.in_scope || []).length // proxy for touched-file breadth when no explicit count
  return classifyScopeTrack({ forced: A.track, file_count: A.fileCount, in_scope_count: fc, is_brownfield: brownfield })
})()
const ceremony = CEREMONY[scopeTrack]
// BUG-E fix — RESEARCH/SCOUT/TEAM depth is now track-graded PROTOCOL (was: full fan-out on EVERY track,
// so a 1-file trivial game ran 29 agents / 1.15M tok / ~$86 and budget-stopped at 0/10 BEFORE any file).
// This grades ONLY the discretionary research/scaffolding spend; the HARD gates (panel/QA/audit/security
// floor/composite) still run UNCHANGED on every track (proven by the budget-checks at each fan-out + smoke).
//   research_max  — ceiling on parallel research questions (the research-lead maxItems). 0 ⇒ SKIP research.
//   research_model— synthesis model tier; Opus reserved for complex (deep convergence), Sonnet otherwise.
//   scout         — run the currency scout (Opus+WebSearch)? quick-fix reuses a recalled stack instead.
//   team_cap      — max EXECUTION specialists; quick-fix needs ~2, complex may need the full domain roster.
// ANTI-LOBOTOMY FLOOR — quick-fix is research_max:1, NOT 0. A "quick-fix" classification can be WRONG
// (a deceptively-hard build hiding behind a 1-2-file diff); zero research there ships slop. So even
// quick-fix keeps ONE capped research pass — the cheapest dose that still catches a misread. The
// OUTPUT CAP (appended to every researcher prompt below) bounds that pass so it can't dump a spec.
const TRACK = {
  'quick-fix': { research_max: 1, research_model: 'sonnet', scout: false, team_cap: 2 },
  'standard':  { research_max: 2, research_model: 'sonnet', scout: true,  team_cap: 4 },
  'complex':   { research_max: 5, research_model: 'opus',   scout: true,  team_cap: 8 },
}[scopeTrack]
log(`v9.2 #12 · scope track: ${scopeTrack.toUpperCase()} (PROTOCOL ceremony flexes; ALL HARD gates still run) · plan=${ceremony.plan_tasks} · PRD=${ceremony.demand_prd} · benchmark=${ceremony.demand_benchmark} · research≤${TRACK.research_max} (${TRACK.research_model}) · scout=${TRACK.scout} · team≤${TRACK.team_cap}`)
await safeOne(() => dispatch(`WALTEUR scope-track ledger (v9.2 #12). Using Bash \`mkdir -p ${projectPath}/walteur-kit\`, then use the Write tool to create ${projectPath}/walteur-kit/scope-track.json with EXACTLY this content (verbatim): ${JSON.stringify({ track: scopeTrack, ceremony, note: 'graded PROTOCOL ceremony only; HARD machinery gates (panel/QA/audit/security-floor/composite) run UNCHANGED on every track.' })}`,
  { label: 'scope-track', model: 'sonnet', phase: 'Scope' }), 'scope-track')

// ───────────────────────── THINK (parallel fan-out) ─────────────────────────
await flushSpans('Scope')
phase('Think')
emitSpan({ phase: 'Think', model: 'opus', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
// REALITY CHECK — establish TODAY + scan the CURRENT best-practice stack on the actual run-date.
// The engine evolves WITH the ecosystem; it never builds from a frozen training snapshot.
const STACK_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['as_of', 'current_best', 'stale_warnings'],
  properties: { as_of: { type: 'string', description: "today's date, established by running `date`" },
    current_best: { type: 'string', description: 'the CURRENT best-practice stack/versions/idioms/tools for this domain AS OF TODAY' },
    stale_warnings: { type: 'array', items: { type: 'string' }, description: 'things training "knows" that are now deprecated/superseded' } },
}
// BUG-E fix — the currency scout (WebSearch + a full reality scan) is discretionary research, not a HARD
// gate, so quick-fix SKIPS it: a 1-2 file fix to a known stack does not warrant a live web scan. The
// recalled-stack fallback keeps `reality` shaped identically (as_of/current_best/stale_warnings) so every
// downstream consumer (plan prompt, build standard) is untouched. standard/complex keep the live scout.
// S033 #3 — acquisition breadcrumb instruction for the currency scout's real web pulls. Every WebSearch
// query becomes one line in walteur-kit/acquisition-log.jsonl ({ts,source,query_or_url,artifact,bytes}) —
// the exact contract data-pull-required-gate.sh reads (walteur-kit/hooks/data-pull-required-gate.sh:25-31).
// Reference-grade breadcrumbs (this scout) are distinct from a data_needs:true build's live-data pulls, but
// use the SAME log so 'the engine researched the web' stops being unprovable after the fact.
const ACQUISITION_BREADCRUMB_INSTR = `\n\nACQUISITION BREADCRUMB (S033 #3): for EVERY WebSearch query or page you actually fetch, append ONE line to ${projectPath}/walteur-kit/acquisition-log.jsonl (Bash \`mkdir -p ${projectPath}/walteur-kit\`, then append, never overwrite) = {"ts":"<UTC ISO-8601 now>","source":"WebSearch","query_or_url":"<the exact query or URL>","artifact":"<path to a file you saved the result to, or the query text itself if nothing was saved>","bytes":<int, 0 if not saved>}. Skip this if you found nothing to search (recalled-only path).`
const reality = TRACK.scout
  ? await dispatch(
      `You are the WALTEUR currency scout. Run \`date\` (Bash) to establish TODAY. For domain "${scope.domain}" / stack "${scope.stack}", research the CURRENT best-practice AS OF TODAY — latest stable versions, the now-idiomatic libraries/tools/patterns, and anything deprecated or superseded since your training cutoff. Load WebSearch (ToolSearch "select:WebSearch") and search the latest; read current official docs if useful. Prefer current-verified facts over recalled ones; FLAG anything your training "knows" that is now stale.${ACQUISITION_BREADCRUMB_INSTR}`,
      { schema: STACK_SCHEMA, model: 'sonnet', label: 'reality:stack-scan', phase: 'Think' }
    )
  : await dispatch(
      `You are the WALTEUR currency scout (QUICK-FIX fast path — NO web search). Run \`date\` (Bash) for TODAY. For domain "${scope.domain}" / stack "${scope.stack}", state the standard, well-known best-practice stack/versions/idioms from your own knowledge — do NOT search the web. List anything you are unsure is current in stale_warnings. Keep it short.`,
      { schema: STACK_SCHEMA, model: 'sonnet', label: 'reality:stack-recall', phase: 'Think' }
    )
log(`reality · as of ${reality.as_of} · ${reality.stale_warnings.length} stale warning(s)`)
if (TRACK.scout) emitSpan({ phase: 'Think', model: 'sonnet', tool: 'acquisition', exit_code: '0', gate_verdict: 'scout:webSearch' }) // S033 #3 — acquisition span for the scout's real web pull
// RECALL — read the engine's cross-build memory (the "dreaming" loop, §8) and surface lessons
// relevant to THIS domain/stack so the build doesn't repeat past failure modes.
// CANONICAL-FIRST (panel #12 memory finding): recall used to `cat ~/.walteur/memory/lessons.jsonl`, which is
// only a DERIVED read-replica of walteur-kit/memory/lessons.jsonl (see memory-sync.sh). On this repo that
// replica was 19 days stale and missing the 6 newest lessons, so recall served a corpus the harness had
// already outgrown. Read the canonical co-located store FIRST; the replica is a fallback only, never a
// preference; and refresh the replica in the same breath so the two cannot silently diverge again.
const RECALL_SCHEMA = { type: 'object', additionalProperties: false, required: ['lessons', 'applied_ids'], properties: { lessons: { type: 'array', items: { type: 'string' } }, applied_ids: { type: 'array', items: { type: 'string' } } } }
const recall = await dispatch(
  `You are the WALTEUR recall agent. Read the engine's cross-build memory with Bash, CANONICAL FIRST:\n` +
  `STEP 1 — \`bash walteur-kit/memory/memory-sync.sh >/dev/null 2>&1 || true\` (best-effort: re-projects the canonical corpus onto the global read-replica so a drifted replica cannot be served to a later reader).\n` +
  `STEP 2 — \`cat walteur-kit/memory/lessons.jsonl 2>/dev/null || cat ~/.walteur/memory/lessons.jsonl 2>/dev/null\`. The FIRST path is the canonical store; \`~/.walteur/memory/lessons.jsonl\` is only a derived read-replica and may be stale — use it ONLY if the canonical path does not exist, and say so. May be empty or absent.\n` +
  `STEP 3 — IGNORE any row whose \`.invalidated_at\` is non-null (superseded) and any row whose \`.harmful\` exceeds its \`.helpful\` (it made past builds worse). For a "${scope.domain}" / "${scope.stack}" build, return ONLY the lessons RELEVANT to this build as short "do/avoid X because Y" lines (in lessons), AND the \`.id\` of each relevant lesson (in applied_ids) — these ids let the self-improvement loop later score whether applying them actually helped. Skip irrelevant/low-confidence ones. Empty/missing file => return [] for both.`,
  { schema: RECALL_SCHEMA, model: 'sonnet', label: 'recall:memory', phase: 'Think' }
)
log(`recall · ${recall.lessons.length} relevant lesson(s) from cross-build memory`)
const THINK_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['findings', 'approach', 'risks'],
  properties: { findings: { type: 'string' }, approach: { type: 'string' }, risks: { type: 'array', items: { type: 'string' } } },
}
let think
if (brownfield) {
  // ───────── §2.6 BROWNFIELD UPGRADE: COMPREHEND → BASELINE → gap-AUDIT ─────────
  // You cannot safely UPGRADE an app whose intent you have not recovered, nor PROVE you improved it without
  // a captured before-state. COMPREHEND emits INTENT.md (the reverse-engineered purpose, every claim labeled
  // confirmed/inferred/unknown with file:line evidence) — the brownfield twin of DISCOVER's PRD. BASELINE
  // emits baseline.json (the before-snapshot + a golden-master net) — the floor the upgrade must beat and
  // never drop below. Enforced by intent-reconstruction-gate + baseline-capture-gate (+ non-regression at ship).
  phase('Comprehend')
  emitSpan({ phase: 'Comprehend', model: 'opus', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
  await safeOne(() => dispatch(
    `WALTEUR COMPREHEND (§2.6 brownfield upgrade). Project ${projectPath}, goal "${idea}". Reverse-engineer the EXISTING app's intent — never sell a guess as a fact (§1).\n` +
    `STEP 0 — Using Bash \`mkdir -p ${projectPath}/walteur-kit\`, then use the Write tool to create/merge ${projectPath}/walteur-kit/preflight-signals.json so it carries {"is_brownfield":true} (PRESERVE any existing keys) — this is the signal the brownfield gates fire on.\n` +
    `STEP 1 — SHORT-CIRCUIT: if ${projectPath}/walteur-kit/PRD.md exists and is non-stub, the intent is already documented — set reconstructed:false in INTENT.md and CONFIRM it against the code; skip a full reconstruction.\n` +
    `STEP 2 — otherwise READ the real evidence (README/docs, package manifest, entrypoints, key source, \`git log\` if a repo) and recover: what it IS, the ORIGINAL goal it was built for, what it is USED for, and who uses it. Label EVERY claim confirmed (cite a file:line) / inferred / unknown.\n` +
    `STEP 3 — Write ${projectPath}/walteur-kit/INTENT.md following walteur-kit/INTENT.template.md (frontmatter validates against schemas/intent.schema.json): what_it_is · original_goal · used_for · users[] · claims[] (label+evidence) · open_questions[] · evidence_refs[]. It MUST pass walteur-kit/hooks/intent-reconstruction-gate.sh.`,
    { label: 'comprehend:intent', model: 'opus', phase: 'Comprehend' }), 'comprehend:intent')

  phase('Baseline')
  emitSpan({ phase: 'Baseline', model: 'sonnet', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
  await safeOne(() => dispatch(
    `WALTEUR BASELINE (§2.6 brownfield upgrade). Project ${projectPath}. Capture the BEFORE-state, BEFORE any edit — it is the floor the upgrade must beat and never drop below.\n` +
    `STEP 1 — MEASURE as-is with real numbers (read/grep/run): does it build? (command + pass/fail) · existing tests (status + passed/failed/total) · score the 8 WALTEUR dimensions (correctness, security, design, performance, accessibility, maintainability, completeness, UX) 0-10 with evidence · §14 13-layer coverage · a security scan · perf/a11y/bundle where measurable.\n` +
    `STEP 2 — AUTHOR or CONFIRM a CHARACTERIZATION / golden-master net: a runnable command that captures current observable outputs/snapshots so an upgrade cannot silently change behavior. If genuinely N/A (e.g. pure static render), record characterization.status="absent-with-reason" + the reason.\n` +
    `STEP 3 — Using Bash \`mkdir -p ${projectPath}/walteur-kit\`, Write ${projectPath}/walteur-kit/baseline.json (validates against schemas/baseline.schema.json): baseline_version · captured_ts (now, ISO-8601) · target · build{status} · tests{status,...} · dimensions[]{name,score} (NUMERIC scores) · characterization{status,...}. It MUST pass walteur-kit/hooks/baseline-capture-gate.sh.`,
    { label: 'baseline:capture', model: 'sonnet', phase: 'Baseline' }), 'baseline:capture')

  // gap-AUDIT — measure the existing system against the recovered INTENT + the WALTEUR bar, in parallel.
  phase('Think')
  const DIMS = ['architecture & code structure', 'performance & resource cost', 'correctness & tests', 'UX/interface & docs']
  const audits = ok(await parallel(DIMS.map(d => () =>
    safeOne(() => dispatch(`WALTEUR brownfield auditor. Project ${projectPath}, goal "${idea}". Read walteur-kit/INTENT.md (recovered intent) + walteur-kit/baseline.json (before-scores). MEASURE the "${d}" dimension with evidence (file:line, real numbers — read/grep/run) and GAP-score it against BOTH the recovered intent AND the WALTEUR bar. Output findings + the highest-leverage improvements that LIFT this dimension WITHOUT breaking what works.`,
      { schema: THINK_SCHEMA, model: 'sonnet', label: `audit:${d.split(' ')[0]}`, phase: 'Think' }), `audit:${d.split(' ')[0]}`)
  )))
  think = await safeOne((fb) => dispatch(`WALTEUR synthesis (Opus). Merge these parallel audit findings into ONE upgrade approach for "${idea}" — highest-leverage, lowest-risk, PRESERVE intent, don't break what works:\n${cap(audits)}\n\nThen use the Write tool to create ${projectPath}/walteur-kit/upgrade-backlog.json = a RICE-ranked array of upgrade items, each {item, dimension, from_score, to_target, tier:("refine-in-place"|"modernize"|"re-architect"), rice:{reach,impact,confidence,effort,score}, non_regression_ac, behavior_change:(false|"<what changes>")}. The in-scope top-N become PLAN tasks carrying the UPGRADE-PLAN.template.additions.md fields (Lifts/Tier/Non-regression AC/signed-ADR-if-behavior-change).`,
    { schema: THINK_SCHEMA, model: fb ? 'sonnet' : 'opus', label: 'think:synthesize', phase: 'Think' }), 'think:synthesize')
  if (!think || think.__failed) think = { findings: `brownfield synthesis degraded (structured-output failure) — proceeding from the parallel audits for "${idea}"`, approach: 'apply the highest-leverage, lowest-risk improvements that preserve intent and do not break what works', risks: ['synthesis step degraded — extra QA scrutiny warranted'] }
} else {
  // research lead decomposes -> parallel researchers -> synthesis (the swarm research pattern).
  // BUG-E fix — maxItems is track-graded (TRACK.research_max): quick-fix=1, standard=2, complex=5.
  // minItems:1 + the quick-fix floor (research_max:1) guarantee >=1 capped research pass on EVERY track,
  // so a MISCLASSIFIED quick-fix still gets one real de-risking pass instead of building blind.
  // The OUTPUT CAP appended to each researcher prompt is the SRS-dump killer — without it a Sonnet
  // researcher returned a full verbatim SRS kick-table spec, blowing the token budget before Build.
  const RQ_SCHEMA = { type: 'object', additionalProperties: false, required: ['questions'], properties: { questions: { type: 'array', minItems: 1, maxItems: TRACK.research_max, items: { type: 'string' } } } }
  // RESILIENCE (figure-it-out): a StructuredOutput failure on this single call must NOT crash the whole
  // build — safeOne catches the retry-cap throw, and we fall back to one generic de-risking question so
  // research still runs. The safeOne __failed sentinel is still counted, so the build is honestly flagged.
  const rqRaw = await safeOne((fb) => dispatch(`WALTEUR research lead for a NEW build: "${idea}" (stack ${scope.stack}). List 1-${TRACK.research_max} concrete research questions whose answers de-risk the design (proven patterns/libraries to reuse, real edge cases, the right API). Ask only what genuinely de-risks THIS build — fewer is better. Just the questions.`,
    { schema: RQ_SCHEMA, model: fb ? 'sonnet' : 'opus', label: 'think:questions', phase: 'Think' }), 'think:questions')
  const rq = (rqRaw && !rqRaw.__failed && Array.isArray(rqRaw.questions) && rqRaw.questions.length) ? rqRaw : { questions: [`What is the simplest correct way to build "${idea}" in ${scope.stack}, and what are the real edge cases to cover?`] }
  // S033 #3 — data-needing builds route external pulls through data-tools.json + a real acquisition
  // breadcrumb (distinct from the scout's reference-grade one — this is the data-pull-required-gate's
  // live-data contract: walteur-kit/hooks/data-pull-required-gate.sh reads acquisition-log.jsonl and
  // demands a real, fresh, >=64-byte artifact when scope.data_needs asserted needs_external_data).
  const DATA_PULL_INSTR = scope.data_needs
    ? `\n\nDATA PULL REQUIRED (S033 #3 — this build declared data_needs=true for domains: ${(scope.data_domains || []).join(', ') || '(unspecified)'}): if answering this question requires a REAL external pull (WebSearch/WebFetch/an MCP tool), route it through a walteur-kit/data-tools.json catalog tool when one applies, SAVE the captured content under ${projectPath}/walteur-kit/data/, and append ONE line per pull to ${projectPath}/walteur-kit/acquisition-log.jsonl (create/append, never overwrite) = {"ts":"<UTC ISO-8601 now>","source":"<tool id or WebSearch/WebFetch>","query_or_url":"<query or URL>","artifact":"walteur-kit/data/<file>","bytes":<int>}. The artifact file MUST be real and >=64 bytes — an empty/stub file fails the gate.`
    : ''
  const research = ok(await parallel(rq.questions.map((q, i) => () =>
    safeOne(() => dispatch(`WALTEUR researcher. For the build "${idea}" (${scope.stack}), answer with evidence — read real dependency source if useful: ${q}\n\nOUTPUT CAP: answer in <=250 words. Give ONLY the decision-relevant conclusion — the concrete pattern/library/API + any real edge case — NOT a tutorial, spec dump, or verbatim docs. Do NOT reproduce full specifications, kick-tables, or source files; cite them by name/path instead. findings <=200 words; approach 1-3 sentences; risks <=3 bullets.${DATA_PULL_INSTR}`,
      { schema: THINK_SCHEMA, model: 'sonnet', label: `research:${i + 1}`, phase: 'Think' }), `research:${i + 1}`)
  )))
  think = await safeOne((fb) => dispatch(`WALTEUR synthesis (${TRACK.research_model === 'opus' ? 'Opus' : 'Sonnet'}). From this parallel research, converge on the SIMPLEST correct approach for "${idea}", name the real edge cases, and the patterns/libraries to reuse:\n${cap(research)}`,
    { schema: THINK_SCHEMA, model: fb ? 'sonnet' : TRACK.research_model, label: 'think:synthesize', phase: 'Think' }), 'think:synthesize')
  // RESILIENCE: synthesis is a single critical call; if it degrades, proceed from scope+research with a
  // minimal valid THINK object rather than crashing (the __failed sentinel already flagged the build).
  if (!think || think.__failed) think = { findings: `research synthesis degraded (structured-output failure) — proceeding from scope + research for "${idea}"`, approach: 'implement the simplest correct design from the research; prefer proven patterns and cover the named edge cases', risks: ['synthesis step degraded — extra QA scrutiny warranted'] }
}

// ───────────────────────── TEAM (agent() roster design — not a dispatch tool) ─────────────────────────
await flushSpans('Think')
// BUG-D fix — budget gate BEFORE the post-Think fan-outs (Team/Plan/scaffold/Build/Review). The expensive
// Think research fan-out previously ran UNGATED: the first overBudget() check was only at the Build wave
// (line ~700), so a simple build blew ~3.5× the ceiling ($86.87 vs $25) on research before any code was
// written. This honors the line-81 contract ("checked at each wave boundary AND before each major fan-out").
if (overBudget(estUsd(), MAX_USD)) return await budgetStop(0, 'Think')
phase('Team')
emitSpan({ phase: 'Team', model: 'opus', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
const TEAM_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['roster'],
  // BUG-E fix — HARD roster cap (maxItems), not just a prompt hint. The oversized-team failure
  // proves a prompt-only "size it to the work" is ignorable; maxItems makes the cap structurally binding.
  // EXECUTION roster only — the fixed seven-senior panel + QA corps + audit are separate and uncapped.
  properties: { roster: { type: 'array', minItems: 1, maxItems: TRACK.team_cap, items: {
    type: 'object', additionalProperties: false, required: ['role', 'mandate', 'kind', 'model'],
    properties: {
      role: { type: 'string', description: 'a domain-specific specialist, e.g. "Frontend Builder", "Physics Modeler", "Fact Checker"' },
      mandate: { type: 'string' }, kind: { type: 'string', enum: ['builder', 'researcher', 'verifier'] },
      model: { type: 'string', enum: ['sonnet', 'opus'] },
    } } } },
}
const team = await dispatch(
  `You are the WALTEUR orchestrator's roster designer. Idea: "${idea}", domain: ${scope.domain}, stack: ${scope.stack}, approach: ${think.approach}. ` +
  `Design the SPECIALIST roster this build needs — domain-specific and sized to the work (a CLI needs a couple builders + a test/verifier; a web app needs frontend + backend + a fact-checker; a research report needs domain researchers + fact-checkers; a CLOUD/INFRA build needs a Cloud/Platform Architect + an IaC Author (Terraform/Pulumi/CDK) + a Pipeline/CI-CD Engineer + a security/compliance reviewer). ` +
  // BUG-E fix — track-aware roster cap. A single-file trivial game does NOT need a large team; oversizing
  // the roster multiplied the agent count + token spend (29 agents) before any code was written. The cap
  // is on the EXECUTION roster only; the HARD governance gates (seven-senior panel + QA corps + audit) are
  // FIXED panels that run UNCHANGED regardless of roster size — this never touches them.
  `SCOPE TRACK = ${scopeTrack.toUpperCase()}: build a MINIMAL roster of AT MOST ${TRACK.team_cap} specialist(s) — ${scopeTrack === 'quick-fix' ? 'a single builder + one verifier is usually right; do NOT pad the team' : scopeTrack === 'complex' ? 'use as many of the cap as the domain genuinely needs' : 'lean — only the roles the build truly needs'}. Fewer, well-chosen specialists beat a crowd. ` +
  `Opus only for hard/critical/security/concurrency/infra specialists; Sonnet for routine. These are the EXECUTION specialists; the seven-senior panel + QA + audit are separate governance gates.`,
  { schema: TEAM_SCHEMA, model: 'opus', phase: 'Team' }
)
log(`team created: ${team.roster.map(r => r.role).join(', ')}`)

// ───────────────────────── PLAN (task DAG) ─────────────────────────
await flushSpans('Team')
// v10.0 DEPTH — the per-§14-layer "build the FULL layer" catalog. Single source of truth: the planner uses it
// to force a per-layer depth section in the design doc; the Build phase injects the matched block into each
// implementer's brief (via layerFor() below). Goal: the framework BUILDS the full $50-100M infra deep + clean.
const LAYER_DEPTH = {
  auth: 'AUTH/IDENTITY: real session lifecycle (issue, refresh, revoke, logout-all); argon2/bcrypt or a delegated IdP; an MFA hook; deny-by-default authz checked server-side on EVERY route (never trust client claims); HttpOnly+SameSite+Secure cookies; rate-limit + lockout on auth endpoints; verify token signature+exp+aud and reject alg=none.',
  data: 'DATA/PERSISTENCE: real reversible migrations (no destructive drift); every tenant-scoped table carries an RLS/row-scope policy keyed to the session principal (no USING(true)); FKs + NOT NULL + CHECK + unique indexes encode the invariants; an index for every query path; no N+1 (batch/join); money as integer minor units or decimal (never float); transactions around multi-write invariants.',
  api: 'API CONTRACT: typed request/response (zod/OpenAPI); validate and reject malformed input at the boundary with a typed error taxonomy (never 500 on bad input); explicit versioning; idempotent creates (idempotency key); pagination with bounded limits; one consistent error envelope; authz enforced per endpoint.',
  payments: 'PAYMENTS/BILLING: every money-mutating call carries an idempotency key; webhooks verify the provider signature AND dedupe by event id; reconcile provider state against the local ledger; handle pending/failed/refunded/disputed/partial; price server-side (never trust client amounts); audit every transaction.',
  async: 'ASYNC/JOBS: every job idempotent and keyed (safe to redeliver); a dead-letter queue for poison messages; retry with backoff + max attempts; propagate W3C trace context producer to consumer; bounded concurrency (no unbounded fan-out); visibility timeout greater than max processing time.',
  observability: 'OBSERVABILITY: structured JSON logs with a correlation/trace id and zero PII/secrets; RED/USE metrics on critical paths; spans across service and async boundaries; actionable error reporting with context; health + readiness endpoints; every privileged action emits an audit record.',
  infra: 'INFRA/IaC: declarative IaC (no console-only state); least-privilege IAM; secrets from a manager (never committed); pinned regions for residency; resource limits + autoscaling; health checks + graceful shutdown; a reproducible build; no single-AZ customer-facing tier.',
  frontend: 'FRONTEND/UX: render EVERY state (loading, empty, error, success, partial); pending/optimistic UI on mutations; accessible to WCAG AA (labels, focus order, keyboard, contrast, aria); no layout shift; client validation mirrors the server (never the only check); no secret/key in the client bundle; resilient to slow or failed fetches.',
}
const LAYER_CATALOG = Object.values(LAYER_DEPTH).map(v => '- ' + v).join('\n')

// v10.1 ULTIMATE (research R1 — "win on the scaffold": Factory's harness lesson, +15pts Terminal-Bench, same
// model). Frontier models exhibit RECENCY BIAS — they obey what is nearest the END of the context. So the
// hardest non-negotiables are RE-EMITTED at the TAIL of every implementer brief (and the reviewer), not just
// stated once at the top. This is the single highest-leverage harness change: it upgrades every wave at once.
const TAIL_RULES = `\n\n=== NON-NEGOTIABLES — read these LAST; they OVERRIDE anything above if in tension ===\n` +
  `1. NEVER weaken, stub, or skip a security control to make a test or gate pass.\n` +
  `2. Every data access is tenant/authz-scoped, deny-by-default; no cross-tenant read is possible.\n` +
  `3. No secret in code/config/client-bundle/logs; validate every input at the trust boundary.\n` +
  `4. Finished production code ONLY — no TODO/placeholder/stub/"in a real app"/empty-catch/\`as any\`/\`@ts-expect-error\`.\n` +
  `5. Money and writes are idempotent; external deps are live-wired-and-proven OR a DEFERRAL — write a row to ${projectPath}/walteur-kit/deferrals.json (JSON array; create it with [] first if absent) = {"id":"D<n>","what":"<the dependency/credential you could not wire>","why_deferred":"<the concrete reason, e.g. missing credential name>","needs":"<what would unblock it>","expires":"<a date you choose, or empty>","ticket_text":"<one-line follow-up ticket>"} — NEVER a prose promise, and never faked.\n` +
  `6. If you cannot do it correctly, STOP and report status BLOCKED with the reason — do not fake it or lower the bar.`

phase('Plan')
emitSpan({ phase: 'Plan', model: 'opus', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
const PLAN_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['design_doc', 'tasks', 'definition_of_done'],
  properties: {
    design_doc: { type: 'string' },
    tasks: { type: 'array', minItems: 1, items: {
      type: 'object', additionalProperties: false, required: ['id', 'title', 'files', 'deps', 'role', 'detail', 'acceptance', 'model'],
      properties: {
        id: { type: 'number' }, title: { type: 'string' },
        files: { type: 'array', items: { type: 'string' }, description: 'exact files this task OWNS (must be DISJOINT from other same-wave tasks so they build in parallel safely)' },
        deps: { type: 'array', items: { type: 'number' }, description: 'task ids that must finish first (a shared-scaffold task should be id 1 with no deps; others depend on it)' },
        role: { type: 'string', description: 'which specialist role from the team builds this' },
        detail: { type: 'string', description: 'what to implement + the failing test to write first (TDD)' },
        acceptance: { type: 'string' }, model: { type: 'string', enum: ['sonnet', 'opus'] },
      } } },
    definition_of_done: { type: 'array', items: { type: 'string' } },
  },
}
plan = await dispatch(
  `You are the WALTEUR planner (Opus).\nGOAL: ${idea}\nSCOPE: ${cap(scope, 8)}\nTHINK: ${cap(think, 8)}\nTEAM: ${team.roster.map(r => r.role).join(', ')}\nPROJECT: ${projectPath}\n` +
  `Build to the CURRENT standards (as of ${reality.as_of}): ${reality.current_best}${reality.stale_warnings.length ? ' — AVOID (now stale): ' + reality.stale_warnings.join('; ') : ''}.\n${recall && recall.lessons.length ? 'APPLY these lessons from past WALTEUR builds (do not repeat these failure modes):\n- ' + recall.lessons.join('\n- ') + '\n' : ''}` +
  `SCOPE TRACK = ${scopeTrack.toUpperCase()} (v9.2 #12 graded ceremony — PROTOCOL fidelity only; the HARD gates panel/QA/audit/security-floor still run regardless). ${scopeTrack === 'quick-fix' ? 'This is a QUICK-FIX: produce a 1-TASK PLAN (no DAG ceremony), do NOT demand a PRD or a benchmark, keep the DoD minimal. Still ship working, tested code.' : scopeTrack === 'complex' ? 'This is COMPLEX: produce a full DAG, justify the design doc thoroughly.' : 'This is STANDARD: a tight DAG.'}\n` +
  `Produce a design doc and a TASK DAG. CRITICAL for parallel building: make task FILE OWNERSHIP DISJOINT — two tasks in the same dependency wave must never write the same file. Put shared scaffolding (package.json, dir layout, shared config) in a single id=1 task with deps=[]; other tasks depend on it and own their own files. Assign each task a specialist role + model tier. Every task ships working, tested, traceable code. Keep it tight.` +
  (scopeTrack === 'quick-fix' ? '' :
  `\n\nDEPTH (this is a $50-100M-ARR-grade build, not a demo — design for the real thing): decide which production layers the goal actually touches, and for EACH one the design_doc MUST contain a "### Layer depth: <layer>" section that commits to its non-negotiables below, then DECOMPOSE the DAG so every non-negotiable is OWNED by a concrete task with its own failing test. Do NOT hand-wave a layer the build clearly needs (auth, data/RLS, payments, async, observability, infra, frontend). A thin design here becomes a thin build. Layer non-negotiables:\n${LAYER_CATALOG}\nName the data model (tables/columns/indexes/constraints), the API surface (routes + typed errors), the failure modes, and the NFRs/SLOs (p99, RPO/RTO) explicitly in the design_doc — not "TBD".`),
  { schema: PLAN_SCHEMA, model: 'opus', phase: 'Plan' }
)
await dispatch(`Using Bash, ensure ${projectPath} exists (mkdir -p) and write the plan to ${projectPath}/PLAN.md; \`git init -q\` if not a repo. Plan:\n${JSON.stringify(plan).slice(0, 12000)}`,
  { label: 'write-PLAN.md', model: 'sonnet', phase: 'Plan' })
// CHECKPOINT — write the initial cross-model handoff so ANY model can resume from the plan.
await dispatch(
  `Use Bash to \`mkdir -p ${projectPath}/_relay\`, then use the Write tool to create ${projectPath}/_relay/BATON.md with EXACTLY this content (verbatim, no reformatting):\n\n# BATON — ${idea.slice(0, 70).replace(/\n/g, ' ')}\n**Status:** in progress · plan written, building next   **Project:** ${projectPath}\n## Done (verified)\n- Scope locked (${brownfield ? 'brownfield' : 'greenfield'} · stack: ${scope.stack})\n- PLAN.md written: ${plan.tasks.length} tasks\n## Next steps (in order)\n1. BUILD the tasks (TDD), then panel review -> refine -> QA -> terminal audit.\n## Context (absolute paths)\n- product: ${projectPath} · plan: ${projectPath}/PLAN.md · engine: .claude/workflows/walteur.js (re-run /goal to resume)\n---\n_Any model: read this + PLAN.md + _relay/ISSUES.md, then continue._\n\nThen append "checkpoint: plan (${plan.tasks.length} tasks)" as a new line to ${projectPath}/_relay/log.md.`,
  { label: 'checkpoint:plan', model: 'sonnet', phase: 'Plan' }
)
// v10.1 ULTIMATE (research R2 — "sleek by default") — DESIGN CONTRACT. A UI build with no written design
// system ships generic AI-slop (the Lovable/v0 lesson: the magic is a token contract emitted BEFORE any UI
// code). Emit DESIGN.md so every frontend wave builds against it and design-gate + anti-slop-ui enforce it.
// UI builds only; additive (never overwrites an existing DESIGN.md); skipped on quick-fix.
const hasUI = /\b(react|next|vue|svelte|astro|remix|tailwind|shadcn|frontend|\.tsx|\.jsx|component|web[- ]?app|dashboard|landing page|ui\b)\b/i.test(`${scope.stack} ${JSON.stringify(plan.tasks).slice(0, 4000)}`)
if (hasUI && scopeTrack !== 'quick-fix') {
  await safeOne(() => dispatch(
    `You are the WALTEUR design-contract agent (Opus, taste matters). Build: "${idea}". Stack: ${scope.stack}. Project: ${projectPath}.\n` +
    `First Bash-check: \`ls ${projectPath}/DESIGN.md 2>/dev/null && echo EXISTS || echo ABSENT\`. If EXISTS, report "design contract present" and STOP (never overwrite).\n` +
    `Otherwise emit ${projectPath}/DESIGN.md — the BRAND-TOKEN CONTRACT every UI wave MUST build against (this is how Linear/Vercel/Anthropic-grade products avoid the generic AI look). It MUST contain:\n` +
    `1. VISUAL DIRECTION: 2-3 sentences + 2-3 named best-in-class references for THIS product's category (real products) + the intended feeling.\n` +
    `2. COLOR: a SEMANTIC token table (background, foreground, primary, secondary, muted, accent, destructive, border, ring) as OKLCH/HSL for light AND dark — never raw per-component hex — mapped to a Tailwind v4 @theme block.\n` +
    `3. TYPOGRAPHY: a DISPLAY font + a body font (a real pairing, NOT Inter-for-everything) + a modular type scale.\n` +
    `4. SPACE/RADIUS/ELEVATION: a spacing scale, radius tokens (not one flat radius everywhere), shadow tokens.\n` +
    `5. MOTION: durations (interactions <300ms, ease-out), what animates (transform/opacity only), prefers-reduced-motion.\n` +
    `6. DO / DON'T: explicitly ban the AI-slop tells — no purple→blue gradient backgrounds, no gradient text, no Inter-only, no dead :hover states, no raw hex in components, no >300ms interaction motion, no hero→3-cards→pricing skeleton; components come from shadcn/Radix primitives.\n` +
    `Write it with the Write tool, then report the chosen fonts + primary color.`,
    { label: 'design-contract', model: 'opus', phase: 'Plan' }), 'design-contract')
  log('v10.1 R2 · emitted DESIGN.md brand-token contract (UI build) — every frontend wave builds against it; design-gate + anti-slop-ui enforce it')
}
// ───────────────────────── SCAFFOLD — per-project structure + AI-context (§17 PROJECT-CONTEXT LAW) ─────────────────────────
// Emit the best-practice production structure for this stack + the per-project AI-context files
// (AGENTS.md · CLAUDE.md · .claude/rules) CURATED from the real PLAN/scope — NOT generic.
// Research finding: generic auto-gen context hurts agent success (lower success, higher cost).
// Every rule emitted must pass: "would removing this cause a mistake on THIS project specifically?"
// Hard invariants go to hooks/settings, not CLAUDE.md prose. Behavior-preserving: the scaffold is
// additive-only (does NOT overwrite existing files); it runs ONCE after PLAN, before BUILD.
// Skipped for brownfield where AGENTS.md already exists and is newer than PLAN.md (no-op safe).
await safeOne(() => dispatch(
  `You are the WALTEUR scaffold agent (§17 PROJECT-CONTEXT LAW). Stack: ${scope.stack}. Project: ${projectPath}. Plan has ${plan.tasks.length} tasks.\n` +
  `GOAL: emit (1) the best-practice production structure for this stack, (2) per-project AI-context files UNIQUE to this project, (3) ensure _relay/ is wired.\n\n` +
  `STEP 1 — STRUCTURE. Using Bash, run \`ls ${projectPath}/AGENTS.md 2>/dev/null && echo EXISTS || echo ABSENT\` to detect whether AGENTS.md already exists.\n` +
  `If EXISTS and the project is brownfield, SKIP steps 2–3 (context already present) and report "scaffold: AGENTS.md present, skipping context generation (brownfield)".\n` +
  `Otherwise: detect archetype from stack ("${scope.stack}") using this table: [python+openai|anthropic|langchain|llama → ai-app] [next|react+app/ → web-app] [bin|console_scripts|main.go|main.rs → cli] [*.tf|Pulumi.yaml|cdk.json → cloud-iac] [unknown → web-app]. ` +
  `Run \`mkdir -p ${projectPath}/.claude/rules\` and create the archetype-appropriate directory structure (mkdir -p only — never overwrite existing files). ADAPTIVE §14 LAYER FOLDERS: create folders ONLY for the §14 production layers THIS request needs (web-app/SaaS → frontend/ api/ db/ auth/ infra/ observability/; CLI or local single-player game → only what it uses). NEVER scaffold empty infra folders for out-of-scope layers — the structure adapts to the idea, never imposes a SaaS skeleton on a script.\n\n` +
  `STEP 2 — AGENTS.md (cross-tool standard, 32 KiB cap). Generate AGENTS.md at ${projectPath}/AGENTS.md. CURATED-NOT-GENERIC:\n` +
  `- §1 project overview: 2–3 sentences from the idea + scope. Real success metric.\n` +
  `- §2 commands: run \`cat ${projectPath}/package.json 2>/dev/null || cat ${projectPath}/pyproject.toml 2>/dev/null || cat ${projectPath}/Makefile 2>/dev/null || echo NONE\` to extract REAL commands. Write "# TODO: fill in" if not detectable — NEVER invent.\n` +
  `- §3 code style: stack-specific idiom, ≥1 real code snippet for THIS stack.\n` +
  `- §4 testing: framework + file naming from plan.tasks (not generic).\n` +
  `- §5 security: constraints from scope "${JSON.stringify(scope).slice(0, 400)}".\n` +
  `- §6 commit/PR: conventional commits.\n` +
  `- §7 §14 PRODUCTION-LAYER OWNERSHIP (scoped to THIS request — ADAPTIVE; the table every sub-agent reads to know its layer + folder + focus). Walk all 13 §14 layers [1 Frontend · 2 APIs & Backend Logic · 3 Database & Storage · 4 Auth & Permissions · 5 Hosting & Deployment · 6 Cloud & Compute · 7 CI/CD & Version Control · 8 Security & RLS · 9 Rate Limiting · 10 Caching & CDN · 11 Load Balancing & Scaling · 12 Observability & Logs · 13 Availability & Recovery]. For EACH emit one row: Layer | IN-SCOPE or OUT-OF-SCOPE(one-line reason) | Owner (a specialist from the roster: ${team.roster.map(r => r.role).join(', ')}) | Folder (the in-scope folder, or —) | Focus (one line). SCOPE HONESTLY to this idea — a local/CLI/single-player/static build marks most infra layers OUT-OF-SCOPE WITH A REASON (never silently drop one; never force a DB/auth/rate-limit/LB tier onto something that does not need it). The terminal audit (layer_walk) validates this table against the built code.\n` +
  `Anti-slop: every command real, every snippet specific to this stack, no rule that applies equally to any project.\n\n` +
  `STEP 3 — CLAUDE.md (≤200 lines) and .claude/rules/*.md. Write ${projectPath}/CLAUDE.md: line 1 must be "@AGENTS.md", then Claude-specific advisory notes only (not a repeat of AGENTS.md). Hard invariants go to hooks/settings, not here.\n` +
  `Write .claude/rules/code-style.md and .claude/rules/testing.md: each with ≥1 real code snippet, each passing "would removing this cause a mistake on THIS project specifically?". Skip any generic rule.\n\n` +
  `STEP 4 — RELAY. Update ${projectPath}/_relay/BATON.md to note "AGENTS.md + CLAUDE.md + .claude/rules generated" in the Done section. Append one line to ${projectPath}/_relay/log.md: "checkpoint: scaffold (AGENTS.md + context generated)".\n\n` +
  `Report: archetype chosen · files created (list) · commands detected vs TODO · rules generated with per-project reason · relay status.`,
  { label: 'scaffold:context', model: 'sonnet', phase: 'Plan' }), 'scaffold:context')
log('§17 scaffold: per-project structure + AI-context emitted (AGENTS.md · CLAUDE.md · .claude/rules · _relay updated)')
// ───────────────────────── ESTIMATE (a WALTEUR FUNDAMENTAL) ─────────────────────────
// Before the expensive phases, ALWAYS tell the user the token + time + cost this build will take,
// as a RANGE (best case: 0 refine/0 forks .. worst case: full refine + forks). Calibrated on prior runs
// (~45k output tokens/agent; ~1.2 min/agent wall with parallelism). Emitted as a first-class artifact
// (walteur-kit/estimate.json) AND surfaced upfront. An estimate, never a precise invoice.
const TOK = 45000, MINPA = 1.2, PANEL = 7
const k = (t) => `${Math.round(t / 1000)}k`
const aMin = 12 + plan.tasks.length + PANEL + 5 + 6                          // best case: no refine, no forks
const aMax = 12 + plan.tasks.length + PANEL * (1 + maxRefine) + 5 + 6 + 7    // worst case: full refine + forks
const estAgents = Math.round((aMin + aMax) / 2)
const estTokens = estAgents * TOK
const estMin = Math.round(estAgents * MINPA)
const estBuildUsd = +(estTokens / 1e6 * 30).toFixed(0)
const estimate = {
  tokens: { min: aMin * TOK, expected: estTokens, max: aMax * TOK },
  minutes: { min: Math.round(aMin * MINPA), expected: estMin, max: Math.round(aMax * MINPA) },
  usd: { expected: estBuildUsd, hard_ceiling: MAX_USD },
  agents: { min: aMin, expected: estAgents, max: aMax },
  basis: '~45k output tokens/agent, ~1.2 min/agent wall (parallelized); range = best (0 refine/0 forks) .. worst (full refine + forks). Estimate, not an invoice.',
}
log(`📊 ESTIMATE (pre-build) · tokens ~${k(estTokens)} (${k(aMin * TOK)}–${k(aMax * TOK)}) · time ~${estMin}m (${estimate.minutes.min}–${estimate.minutes.max}m) · cost ~$${estBuildUsd} · ${estAgents} agents · HARD ceiling $${MAX_USD}`)
// First-class artifact: any model / the user reads the projected cost BEFORE committing to the build.
await safeOne(() => dispatch(`Using Bash \`mkdir -p ${projectPath}/walteur-kit\`, then use the Write tool to create ${projectPath}/walteur-kit/estimate.json with EXACTLY this content (verbatim): ${JSON.stringify(estimate)}`,
  { label: 'emit-estimate', model: 'sonnet', phase: 'Plan' }), 'emit-estimate')

// §2a HITL gate — SEAM 1 · POST-PLAN checkpoint (v9.2 #9 registry). OFF by default (full_autopilot). When
// pause_at_plan_and_audit: writes APPROVAL-REQUEST.json and halts until a human places walteur-kit/APPROVED.
if (!(await requireApproval('PLAN', `Plan ready (${(plan.tasks || []).length} tasks). Review PLAN.md/estimate.json, then approve to build.`))) {
  log('⏸ PAUSED for human approval after PLAN. Review the plan, write walteur-kit/APPROVED, then re-run /goal to resume.')
  return { paused: true, gate: 'PLAN' }
}

// ───────────────────────── PREFLIGHT (skill auto-routing: signals → committed skills) ─────────────────────────
// Fix #2 (skill/tool utilization). Between PLAN and BUILD, turn skill use from PROTOCOL into
// routed→committed→fail-closed: derive build signals, then run skill-router.mjs to COMMIT the applicable
// Org skills (skill-routing.json) and regenerate required-skills.json. The fail-closed skill-readiness
// gate then blocks ship if a routed-required skill never stamps its breadcrumb. No skill-index.json in the
// project => the router LOUD-SKIPs and the build is unaffected.
//
// S033 #1 — MECHANICAL SKILL DISPATCH. This harness (walteur.js) has NO Node `child_process`/`execSync`
// global — every shell command in this file, without exception, runs through the `agent()`+Bash-tool
// seam (confirmed: no `require`/`import` anywhere in this file; only `process.env`/`process.cwd` are used
// directly). "The engine runs the router itself" is therefore implemented as the STRONGEST mechanical
// guarantee actually available in this harness: (1) signal derivation stays an agent call (it needs LLM
// judgment over scope/plan — an engine-side heuristic here would be a worse signal, not a better one), but
// (2) running skill-router.mjs is now a SEPARATE, narrowly-scoped, mandatory agent call whose ONLY job is
// to run the router and read back its own output — and (3) the ENGINE (real JS below, not agent self-report)
// reads skill-routing.json back and independently verifies it parses + is non-empty when skill-index.json
// exists. A router failure (missing file, bad JSON, non-zero exit) is therefore a REAL recorded failures[]
// entry (via safeOne, counted, never silently swallowed) — not a prompt the agent could skip unnoticed.
await flushSpans('Plan')
phase('Preflight')
emitSpan({ phase: 'Preflight', model: 'sonnet', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
// S033 #2 — EXEC ARMING (the gate-run seam). Gates run OUTSIDE this process (git-commit-time, via
// ship-gate.sh), so walteur.js cannot set env for that later shell directly — but 5 gates
// (test-layer-coverage, zero-downtime-cutover, chaos-resilience, audit-contract, authz-tenant) already
// self-arm their EXEC mode by READING walteur-kit/build-contract.json's build_class/risk_tier (wave-1
// landed default_*_exec_armed() in each hook). The gap: walteur.js READS build-contract.json (line below)
// but never WROTE one — an unscaffolded contract means every default_*_exec_armed() check returns false
// and all 5 gates silently stay shape-read-only. Write it here, BEFORE Preflight reads it back, so the
// gates' own already-proven auto-arm logic actually fires for code build classes. Chaos stays
// risk-tier-gated (only high|regulated arms it) per its own contract — data_needs alone never raises risk.
const CODE_DOMAIN_RE = /\b(cli|cloud|iac|terraform|pulumi|infra|data[- ]?pipeline|ml|ai[- ]?agent|api|backend|web[- ]?app|service|microservice)\b/i
const inferredBuildClass = /\b(terraform|pulumi|cloudformation|cdk|iac)\b/i.test(`${scope.domain} ${scope.stack}`) ? 'cloud-iac'
  : /\b(ml|ai[- ]?agent|llm|langchain|data[- ]?pipeline|etl)\b/i.test(`${scope.domain} ${scope.stack}`) ? 'data-ai'
  : /\b(research report|market analysis|document|write-?up|whitepaper)\b/i.test(scope.domain || '') ? 'document'
  : CODE_DOMAIN_RE.test(`${scope.domain} ${scope.stack}`) || scopeTrack !== 'quick-fix' ? 'software'
  : 'software' // default — matches every EXEC-gate's own fallback ("software" when build-contract.json is absent)
const inferredRiskTier = (scope.data_needs || /\b(payment|pii|regulated|hipaa|pci|gdpr|financ|health)\b/i.test(`${JSON.stringify(scope)}`)) ? 'high' : 'standard'
await safeOne(() => dispatch(
  `WALTEUR build-contract emission (S033 #2 — EXEC arming seam). Using Bash \`mkdir -p ${projectPath}/walteur-kit\`, then use the Write tool: if ${projectPath}/walteur-kit/build-contract.json does NOT already exist, create it with EXACTLY this content (verbatim): ${JSON.stringify({ id: (idea || 'build').slice(0, 60), build_class: inferredBuildClass, risk_tier: inferredRiskTier, note: 'auto-classified by walteur.js Preflight from scope.domain/stack; arms EXEC-default gates (test-layer-coverage, zero-downtime-cutover, chaos-resilience, audit-contract, authz-tenant) for code build classes — see each gate default_*_exec_armed()' })}. If it ALREADY exists, do NOT overwrite it (a scaffold or a prior run may have written a more specific one) — report "build-contract.json already present, left untouched".`,
  { label: 'build-contract:emit', model: 'sonnet', phase: 'Preflight' }), 'build-contract:emit')
log(`v10.2 #2 · EXEC-arming build-contract: build_class=${inferredBuildClass} risk_tier=${inferredRiskTier} (arms test-layer-coverage/cutover/chaos/audit-contract/authz-tenant per their own build-class-aware defaults; chaos additionally needs risk_tier high|regulated)`)
// S033 #3 — data_needs (from SCOPE_SCHEMA) flows into preflight-signals.json as needs_external_data, and
// (when true) into build-contract's data classification the data-pull-required-gate arms on.
const needsExternalData = !!scope.data_needs
await safeOne(() => dispatch(
  `WALTEUR skill PREFLIGHT for build "${idea}". Derive the build signals that drive mechanical skill routing + data-need gating.\n` +
  `STEP 1 — derive build signals from scope ${cap(scope, 6)} and plan ${cap(plan, 6)}. Read .build_class and .risk_tier from ${projectPath}/walteur-kit/build-contract.json. Then use the Write tool to create ${projectPath}/walteur-kit/preflight-signals.json as EXACTLY one JSON object: {"build_class":<from contract>,"risk_tier":<from contract>,"committed_at":<today YYYY-MM-DD>,"needs_external_data":${needsExternalData}, then booleans} for keys has_ui, is_user_facing, external_surface, has_pii, has_payments, has_api_boundary, has_db, has_auth, regulated, is_ai_agent, security_sensitive — each true ONLY if the scope/plan genuinely implies it. needs_external_data is FIXED at ${needsExternalData} (from Scope's data_needs) — do not change it.`,
  { label: 'preflight:signals', model: 'sonnet', phase: 'Preflight' }), 'preflight:signals')
// S033 #1 — MECHANICAL router dispatch: a dedicated, narrow agent call whose ONLY job is running the
// router — no judgment, no "if you think it's useful". try/catch (via safeOne) means a router failure is
// COUNTED in failures[], never silently dropped. Engine then independently verifies the output artifact.
const routerRun = await safeOne(() => dispatch(
  `WALTEUR mechanical skill-router dispatch (S033 #1 / S037 canonical-kit fallback — NOT optional, NOT judgment; run this exactly). In ${projectPath}:\n` +
  `1) Bash: \`[ -f walteur-kit/skill-index.json ] && echo HAVE_LOCAL || echo NO_LOCAL\`.\n` +
  `2) Pick INDEX + ROUTER: if HAVE_LOCAL use \`walteur-kit/skill-index.json\` + \`walteur-kit/hooks/skill-router.mjs\`. ` +
  `Else if a canonical kit was provided (${CANON_KIT || 'NONE'}) use \`${CANON_KIT}/skill-index.json\` + \`${CANON_KIT}/hooks/skill-router.mjs\` (source the index+script from canonical; still read the project's OWN signals + write output INTO the project). ` +
  `Else report {"ran":false,"reason":"no skill-index (local or canonical)"} and stop.\n` +
  `3) Confirm \`walteur-kit/preflight-signals.json\` exists (the Scope phase wrote it; if absent, report {"ran":false,"reason":"no preflight-signals"} and stop). Then run EXACTLY \`node <ROUTER> walteur-kit/preflight-signals.json <INDEX> walteur-kit/skill-routing.json walteur-kit/required-skills.json\` and capture its real exit code.\n` +
  `4) Report {"ran":true,"exit_code":<int>}.`,
  { label: 'skill-router:exec', model: 'sonnet', phase: 'Preflight' }), 'skill-router:exec')
// Engine-side verification (real JS, not agent self-report): read skill-routing.json back, count routed
// skills, AND capture the routed-REQUIRED entries themselves (name/phase/breadcrumb/discipline) so the
// engine can inject them into the matching Build/Review/Validate agent prompts below (S033 #1 second half —
// "nothing DISPATCHES the routed skills into the agents that must fire them"). A HAVE_INDEX build whose
// router run failed or whose output is missing/unparseable is a recorded failure, closing the "orchestrator
// never mechanically verifies skill-routing.json was created" dock.
const ROUTING_CHECK_SCHEMA = { type: 'object', additionalProperties: false, required: ['exists', 'required_count', 'optional_count', 'required_entries'],
  properties: { exists: { type: 'boolean' }, required_count: { type: 'number' }, optional_count: { type: 'number' },
    required_entries: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['skill', 'phase', 'breadcrumb', 'discipline'],
      properties: { skill: { type: 'string' }, phase: { type: 'string' }, breadcrumb: { type: 'string' }, discipline: { type: 'string' } } } } } }
const routingCheck = await safeOne(() => dispatch(
  `WALTEUR router-output verification (mechanical read-back, S033 #1). In ${projectPath}, Bash \`cat walteur-kit/skill-routing.json 2>/dev/null\`. If it exists and parses, return {"exists":true,"required_count":<len of .routed where .required==true>,"optional_count":<len of .routed where .required==false>,"required_entries":<the .routed entries where .required==true, each projected to {skill,phase,breadcrumb,discipline}>}. If absent (e.g. no skill-index.json was present), return {"exists":false,"required_count":0,"optional_count":0,"required_entries":[]}.`,
  { schema: ROUTING_CHECK_SCHEMA, model: 'sonnet', label: 'skill-router:verify', phase: 'Preflight' }), 'skill-router:verify')
const routedRequiredCount = (routingCheck && !routingCheck.__failed && routingCheck.required_count) || 0
const routedOptionalCount = (routingCheck && !routingCheck.__failed && routingCheck.optional_count) || 0
const routedRequired = (routingCheck && !routingCheck.__failed && Array.isArray(routingCheck.required_entries)) ? routingCheck.required_entries : []
emitSpan({ phase: 'Preflight', model: 'sonnet', tool: 'skill-router', exit_code: (routerRun && routerRun.__failed) ? '1' : '0', gate_verdict: `required:${routedRequiredCount},optional:${routedOptionalCount}` })
log(`v10.2 #1 · mechanical skill-router dispatch: ${routedRequiredCount} required · ${routedOptionalCount} optional skill(s) routed`)
// S033 #1 — per-phase lookup so Build/Review/Validate agent prompts can inject ONLY the skills affine to
// their own phase (never dump the whole routed set into every prompt — bounded, phase-scoped injection).
function skillInjectFor(phaseName) {
  const hits = routedRequired.filter(r => r.phase === phaseName)
  if (!hits.length) return ''
  const lines = hits.map(r => `  - ${r.skill} (${r.discipline}) — write its receipt to ${r.breadcrumb || `walteur-kit/skills/${r.skill}.json`} per walteur-kit/schemas/skill-receipt.schema.json (skill, fired_at, phase:"${phaseName}", artifacts:[>=1 real path you touched], summary:>=40 chars of what you concluded).`).join('\n')
  return `\n\nREQUIRED SKILL(S) for this phase (S033 #1, routed by skill-router.mjs — apply the discipline, then write the receipt; a receipt with a fake/empty artifact fails skill-readiness):\n${lines}\nInclude each receipt path in your reported outputs.`
}

// ───────────────────────── DEBATE (auto-fired Socratic forks → ADR) ─────────────────────────
// B12 — closes the §5.3 "debate is manual; the autopilot doesn't fire it" honesty gap. Between PLAN and
// BUILD, detect genuine architecture-significant forks; for each, two Socratic advocates argue, a neutral
// decider rules, and the decision is recorded as an ADR. No forks (simple build) => nothing fires.
await flushSpans('Plan')
phase('Debate')
emitSpan({ phase: 'Debate', model: 'opus', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
const FORKS_SCHEMA = { type: 'object', additionalProperties: false, required: ['forks'], properties: { forks: { type: 'array', maxItems: 3, items: {
  type: 'object', additionalProperties: false, required: ['question', 'option_a', 'option_b', 'why_it_matters'],
  properties: { question: { type: 'string' }, option_a: { type: 'string' }, option_b: { type: 'string' }, why_it_matters: { type: 'string' } } } } } }
const DECIDE_SCHEMA = { type: 'object', additionalProperties: false, required: ['chosen', 'reason', 'rejected_tradeoff'],
  properties: { chosen: { type: 'string' }, reason: { type: 'string' }, rejected_tradeoff: { type: 'string' } } }
const forkScan = await safeOne(() => dispatch(`You are the WALTEUR fork detector. Build: "${idea}". Plan: ${cap(plan, 7)}. Scope: ${cap(scope, 6)}. Identify ONLY GENUINE architecture-significant forks — decisions with >=2 viable options and a REAL trade-off (datastore, sync vs async, monolith vs split, auth model, state management, etc.). Return [] for a simple build; do NOT invent forks for a trivial CLI.`,
  { schema: FORKS_SCHEMA, model: 'opus', label: 'debate:scan', phase: 'Debate' }), 'debate:scan')
const forks = (forkScan && !forkScan.__failed && forkScan.forks) || []
const adrs = []
for (let fi = 0; fi < forks.length; fi++) {
  const f = forks[fi]
  const [advA, advB] = await parallel([
    () => safeOne(() => dispatch(`You are debate-advocate A. Argue FOR "${f.option_a}" over "${f.option_b}" for: ${f.question} (build: ${idea}). Socratic probing — surface the assumptions the other side must defend. Evidence-based, concrete to this build.`, { model: 'opus', label: `debate:${fi}:A`, phase: 'Debate' }), `debate:${fi}:A`),
    () => safeOne(() => dispatch(`You are debate-advocate B. Argue FOR "${f.option_b}" over "${f.option_a}" for: ${f.question} (build: ${idea}). Socratic probing of A's assumptions. Evidence-based.`, { model: 'opus', label: `debate:${fi}:B`, phase: 'Debate' }), `debate:${fi}:B`),
  ])
  const decision = await safeOne(() => dispatch(`You are the WALTEUR decider (no stake). Fork: ${f.question}. Why it matters: ${f.why_it_matters}.\nAdvocate A (for ${f.option_a}):\n${typeof advA === 'string' ? advA : JSON.stringify(advA)}\nAdvocate B (for ${f.option_b}):\n${typeof advB === 'string' ? advB : JSON.stringify(advB)}\nRule: pick the lower-risk option for THIS build, cite the specific arguments that decided it, and name the rejected option's real trade-off.`,
    { schema: DECIDE_SCHEMA, model: 'opus', label: `debate:${fi}:decide`, phase: 'Debate' }), `debate:${fi}:decide`)
  if (decision && !decision.__failed) adrs.push({ n: fi + 1, question: f.question, chosen: decision.chosen, reason: decision.reason, rejected: f.option_a === decision.chosen ? f.option_b : f.option_a, tradeoff: decision.rejected_tradeoff })
}
if (adrs.length) {
  log(`debate · ${adrs.length} fork(s) resolved → ADR`)
  const adrMd = adrs.map(a => `# ADR ${String(a.n).padStart(4, '0')} — ${a.question}\nStatus: ACCEPTED\n## Decision\n${a.chosen}\n## Why\n${a.reason}\n## Rejected\n${a.rejected} — trade-off: ${a.tradeoff}`).join('\n\n---\n\n')
  await safeOne(() => dispatch(`Using Bash \`mkdir -p ${projectPath}/walteur-kit/adr ${projectPath}/walteur-kit/debate\`, then use the Write tool to create ${projectPath}/walteur-kit/adr/RESOLVED.md with EXACTLY:\n${adrMd}\nThen Bash: \`echo '[]' > ${projectPath}/walteur-kit/debate/OPEN.json\` (forks are resolved, none left open).`,
    { label: 'debate:adr', model: 'sonnet', phase: 'Debate' }), 'debate:adr')
} else { log('debate · no genuine architecture forks (simple build) — none to resolve') }

// ── SENIOR PM — FRONT-LOADED red-flag detection (Tony's org model). Before any build, a very senior PM
//    makes everything FIT TOGETHER and flags the red flags from the START; the Chief of Staff records the
//    plan→build coordination handoff. Both drop persona breadcrumbs that persona-coverage-gate.sh enforces. ──
phase('Plan-Risk')
{
  const planDigest = (plan.tasks || []).map(t => `T${t.id}[${t.role || 'dev'}] ${String(t.detail || '').slice(0, 80)} files=${(t.files || []).join(',') || '?'} deps=${(t.deps || []).join(',') || '-'}`).join('\n').slice(0, 12000)
  await safeOne(() => dispatch(
    `You are the SENIOR PROJECT MANAGER (Opus). FRONT-LOAD the red flags BEFORE the build starts. The plan:\n${planDigest}\n\n` +
    `Make everything FIT TOGETHER and flag every red flag NOW: scope gaps, mismatched/unowned interfaces between tasks, missing dependencies, two tasks writing the same file in one wave, vague acceptance, over-scoped tasks (>5 files), security/data hot-spots needing a specialist, anything that bites at integration. ` +
    `Using Bash \`mkdir -p ${projectPath}/walteur-kit/personas\`, then the Write tool, create ${projectPath}/walteur-kit/red-flag-register.json = {"reviewer":"senior-pm","fits_together":true,"red_flags":[{"id":"RF1","severity":"high|med|low","area":"","risk":"","owner_role":"","mitigation":""}]} (list the REAL flags you find; [] only if genuinely none), ` +
    `${projectPath}/walteur-kit/personas/senior-pm.json = {"verdict":"PASS","persona":"senior-pm","evidence":"red-flag register written"}, and ` +
    `${projectPath}/walteur-kit/personas/chief-of-staff.json = {"verdict":"PASS","persona":"chief-of-staff","evidence":"coordinated plan->build handoff"}. Be senior and specific — a real PM catches the integration mismatch on day one. Report the high-severity count.`,
    { label: 'senior-pm:red-flags', model: 'opus', phase: 'Plan-Risk' }), 'senior-pm:red-flags')
}

// ───────────────────────── BUILD (real parallel() agent() dependency waves) ─────────────────────────
await flushSpans('Debate')
phase('Build')
// S033 #10 — corrected marker model from 'opus' to 'sonnet': model-routing.json:by_phase.Build declares
// "sonnet" (the bulk-execution default lane; individual tasks route opus only for hard/critical work per
// task.model — see the real per-task agent() calls below, which already alternate correctly). The OLD
// 'opus' label here was a genuine table-vs-code mismatch that routing-conformance would now catch on
// every single build; fixing it here is the correct move (the phase-marker should reflect the declared
// default, not a stale label) rather than suppressing the check.
emitSpan({ phase: 'Build', model: 'sonnet', tool: 'parallel', exit_code: '0', tokens: tokensSincePhase() })
const TASK_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['id', 'status', 'files_written', 'tests_pass', 'evidence'],
  properties: {
    id: { type: 'number' }, status: { type: 'string', enum: ['DONE', 'BLOCKED'] },
    files_written: { type: 'array', items: { type: 'string' } }, tests_pass: { type: 'boolean' },
    evidence: { type: 'string', description: 'exact test command + result/exit code' },
  },
}
// >>> WAVE-LOGIC START (pure; extracted verbatim by selftest — keep self-contained, no outer refs)
// topological waves: each wave = tasks whose deps are all satisfied; run the wave in parallel (disjoint files = safe).
function toWaves(tasks) {
  const done = new Set(); const waves = []; let rem = tasks.slice()
  let guard = 0
  while (rem.length && guard++ < 50) {
    const ready = rem.filter(t => (t.deps || []).every(d => done.has(d)))
    const wave = ready.length ? ready : rem // cycle/safety: if nothing ready, run the rest serially-as-one
    waves.push(wave); wave.forEach(t => done.add(t.id)); rem = rem.filter(t => !wave.includes(t))
  }
  return waves
}
// A4 — enforce same-wave file-disjointness in CODE (not just a planner prompt). Greedily split a wave
// into sub-batches where no two tasks share an owned file, so parallel writers can NEVER race on a file
// (the package.json last-write-wins class of bug). Colliding tasks fall to a later, serialized batch.
function disjointBatches(wave) {
  const batches = []
  for (const t of wave) {
    const files = (t.files || [])
    let placed = false
    for (const b of batches) {
      if (!files.some(f => b.claimed.has(f))) { b.tasks.push(t); files.forEach(f => b.claimed.add(f)); placed = true; break }
    }
    if (!placed) batches.push({ tasks: [t], claimed: new Set(files) })
  }
  return batches.map(b => b.tasks)
}
// <<< WAVE-LOGIC END
// >>> RECON-LOGIC START (pure; v9.2 #6 reconciliation classifier — keep self-contained, no outer refs)
// Per-task reconciliation: planned (the frozen brief's owned-files) vs actual (the files the implementer
// wrote). Verdict vocabulary: PASS | GAP | DRIFT | DONE_WITH_CONCERNS | BLOCKED. DRIFT/DONE_WITH_CONCERNS
// are the QA-read-first flags. Pure + deterministic so the selftest can prove the classifier table.
//   - BLOCKED            : implementer reported status BLOCKED (or failed sentinel).
//   - GAP                : tests did not pass (built, but the AC is not met).
//   - DRIFT              : tests pass BUT the actual files diverge from the planned owned-file set
//                          (wrote a file it did not own, or skipped an owned file) — scope drift.
//   - DONE_WITH_CONCERNS : tests pass, files match, but a concern was recorded (e.g. fallback model used).
//   - PASS               : tests pass, files match the plan, no concern.
// S033 #8b — PATH-NORMALIZE before set-comparison. The only real end-to-end run (jsonlint-cli) produced
// DRIFT on effectively every task because implementers reported ABSOLUTE Windows paths (C:\Users\...\src\
// parser.mjs) against RELATIVE planned paths (src/parser.mjs) — the raw Set comparison below treated them
// as different files, making the PASS verdict unreachable in practice (SUMMARY.jsonl showed 10/10 DRIFT).
// normFile() strips backslash→slash, lower-cases the drive letter, and drops any leading absolute-path
// segment down to the LAST occurrence of a path segment that also appears in the (relative) planned set's
// basename space — simplest robust rule: normalize slashes, then if the string contains '/', try matching
// on the path SUFFIX once a planned-relative form is known. Kept deliberately simple + pure (no outer refs,
// no projectPath access — this block is extracted verbatim by the selftest): strip drive prefix
// (`C:/...`), strip any `.../<repo-root-looking>/` prefix is NOT attempted here (no filesystem knowledge in
// a pure fn) — instead we normalize to slash-form and compare by SUFFIX match against each planned file, so
// an absolute path that simply ENDS WITH a planned relative path counts as the same file.
function normSlashes(f) { return String(f || '').replace(/\\/g, '/').replace(/^[a-zA-Z]:\//, '') }
function sameFile(actual, planned) {
  const a = normSlashes(actual), p = normSlashes(planned)
  if (a === p) return true
  // absolute actual path ending in the planned relative path (e.g. ".../project/src/a.mjs" vs "src/a.mjs")
  return a.length > p.length && a.endsWith('/' + p)
}
function reconcileVerdict({ status, tests_pass, planned_files = [], actual_files = [], concern = false }) {
  if (status === 'BLOCKED' || status === 'FAILED') return 'BLOCKED'
  if (!tests_pass) return 'GAP'
  const wroteUnowned = actual_files.some(f => !planned_files.some(pf => sameFile(f, pf)))
  const skippedOwned = planned_files.some(pf => !actual_files.some(f => sameFile(f, pf)))
  if (wroteUnowned || skippedOwned) return 'DRIFT'
  if (concern) return 'DONE_WITH_CONCERNS'
  return 'PASS'
}
const RECON_QA_FIRST = new Set(['DRIFT', 'DONE_WITH_CONCERNS']) // verdicts QA reads first
// S1 — WIRING resolver: find a task's build result for reconciliation. A failed implementer is a sentinel
// {__failed:true,status:'FAILED',id} (id carried by safeOne); a normal result has a matching id. If neither
// matches by id, fall back to the failures[] list by the `build:T<id>` label so a failed task can NEVER read
// as r={} (which mis-classifies BLOCKED → GAP). Returns the result object (possibly the sentinel) or {}.
function resolveBuildResult(build, failures, taskId) {
  const r = build.find(b => b && b.id === taskId)
  if (r) return r
  const f = (failures || []).find(x => x && x.label === `build:T${taskId}`)
  return f ? { status: 'FAILED', __failed: true, id: taskId } : {}
}
// <<< RECON-LOGIC END
// >>> SPAWN-LOGIC START (pure; v9.2 #10 spawn-justification — keep self-contained, no outer refs)
// Before EXECUTION fan-out, justify each spawn against 6 criteria (paul's "measure, don't slash" instinct):
//   independence · clear scope · parallel value · real complexity · token efficiency · state compatibility.
// "Prefer in-session when uncertain" for SMALL tasks: a task that is small AND fails >=2 criteria is
// recommended in-session. This is a RECORDED recommendation only — it does NOT change today's execution
// path (the build still fans out via the existing waves); it surfaces spawn ROI honestly per WALTEUR's law.
// HARD EXCLUSION: it NEVER applies to the governance panel / final-auditor / security-floor /
// Logic-Correctness / intent-auditor — those MUST stay isolated regardless (passed isExcluded=true).
function spawnJustify({ files = [], deps = [], detail = '', acceptance = '', model = 'sonnet', sameWaveCount = 1, isExcluded = false }) {
  if (isExcluded) return { recommend: 'spawn', isolation_required: true, criteria: {}, small: false, met: 6 }
  const fileCount = files.length
  const detailLen = (detail || '').length + (acceptance || '').length
  const criteria = {
    independence:        deps.length === 0,                 // no upstream task dependency
    clear_scope:         fileCount >= 1 && detailLen >= 40, // owns concrete files + a real spec
    parallel_value:      sameWaveCount > 1,                 // siblings to run alongside (parallelism pays)
    real_complexity:     model === 'opus' || fileCount >= 2 || detailLen >= 200, // non-trivial work
    token_efficiency:    detailLen >= 60,                   // enough context to amortize a spawn's overhead
    state_compatibility: fileCount <= 8,                    // bounded owned-file set = safe disjoint state
  }
  const met = Object.values(criteria).filter(Boolean).length
  const small = fileCount <= 1 && detailLen < 120
  // prefer in-session when SMALL and the criteria are weak (<=4 met); else spawn (today's default).
  const recommend = (small && met <= 4) ? 'in-session' : 'spawn'
  return { recommend, isolation_required: false, criteria, small, met }
}
// <<< SPAWN-LOGIC END
// >>> RADIUS-LOGIC START (pure; v9.2 blast-radius sort key — keep self-contained, no outer refs)
// Order NON-VETO findings in the codified output by BLAST RADIUS so the worst-consequence items read first:
//   data-corruption > lost-writes > security-exposure > degraded-UX > cosmetic.
// PURE PRESENTATION ONLY — this changes ORDERING, never blocking: the security FLOOR (composite securityFloor
// / panel Security senior) still hard-blocks ship regardless of where a finding sorts. Classification is by
// keyword over the finding text; unknown → middle rank so it is neither buried nor falsely top-ranked.
const BLAST_RANK = { 'data-corruption': 0, 'lost-writes': 1, 'security-exposure': 2, 'degraded-ux': 3, 'cosmetic': 4 }
function blastRadius(text = '') {
  // stems use a LEADING \b but NO trailing \b, so suffixed forms match (inject→injection, corrupt→corruption,
  // authoriz→authorization, concurren→concurrency, accessib→accessibility, exploit→exploitable, vuln→vulnerability).
  const t = String(text).toLowerCase()
  if (/\b(corrupt|data loss|inconsisten|integrity|bad state|wrong data)/.test(t)) return 'data-corruption'
  if (/\b(lost write|overwrit|\brace\b|concurren|dropped (write|update)|clobber|last-write-wins)/.test(t)) return 'lost-writes'
  if (/\b(inject|xss|csrf|ssrf|authz|authoriz|auth bypass|secret|credential|rce|exploit|vuln|owasp|privilege)/.test(t)) return 'security-exposure'
  if (/\b(ux|usability|a11y|accessib|loading state|empty state|error state|confusing|onboarding)/.test(t)) return 'degraded-ux'
  if (/\b(cosmetic|typo|whitespace|lint|style|nit|formatting)/.test(t)) return 'cosmetic'
  return 'degraded-ux' // unknown → middle rank (neither buried nor falsely critical)
}
// stable sort findings ascending by blast rank (worst first). Stable = ties keep insertion order.
function sortByBlastRadius(findings) {
  return findings
    .map((f, i) => ({ f, i, r: BLAST_RANK[blastRadius(f.text)] }))
    .sort((a, b) => (a.r - b.r) || (a.i - b.i))
    .map(x => ({ ...x.f, blast_radius: blastRadius(x.f.text) }))
}
// <<< RADIUS-LOGIC END
// >>> CLAIM-LOGIC START (pure; claim-before-edit convention — keep self-contained, no outer refs)
// Per-wave file-claim registry. PREVENTION layer over disjointBatches (A4): records which task-id
// "owns" each file for the duration of a wave so cross-batch conflicts inside the same wave are
// blocked BEFORE dispatch (not post-hoc). In practice disjointBatches already guarantees disjointness,
// so this always returns ok:true for valid plans — the check is an explicit documented safety net for
// future extensions. Claims are in-memory (Map), never written to disk (zero agent calls).
function claimFiles(claims, taskId, files) {
  // Returns {ok: true} if all files are unclaimed, and claims them.
  // Returns {ok: false, blocked_by: taskId, conflicting_files: [...]} if any file is already claimed.
  const conflicts = files.filter(f => claims.has(f))
  if (conflicts.length > 0) {
    const blockedBy = claims.get(conflicts[0])
    return { ok: false, blocked_by: blockedBy, conflicting_files: conflicts }
  }
  files.forEach(f => claims.set(f, taskId))
  return { ok: true }
}

function clearClaims(claims) {
  claims.clear()
}
// <<< CLAIM-LOGIC END
// A2 — persisted phase state for crash/interruption recovery. STATE.json records {phase, completed_task_ids}
// so a re-run of /goal SKIPS already-built work instead of rebuilding the whole pipeline from Scope.
//
// ── v9.2 — DECIMAL-PHASE INTERRUPT convention (STATE.json) ──────────────────────────────────────────
// `phase` is a free string, so an URGENT hotfix that arrives mid-build is recorded as a DECIMAL phase off
// the phase it interrupts: e.g. mid-PLAN → "PLAN.1", mid-Build → "Build.1" (next "Build.2"). The decimal
// phase runs its OWN compressed loop (a quick-fix-track mini-lifecycle: scope → 1-task plan → build →
// panel/QA/audit) and then SLOTS BACK into the parent phase WITHOUT renumbering the integer phases — the
// parent build resumes exactly where it paused. CONTRACT:
//   • a decimal phase MUST still pass the SAME HARD gates (panel/QA/Security-floor/terminal audit/composite
//     ≥ target/evidence re-run) — the compression is PROTOCOL only (typically the #12 'quick-fix' track).
//   • completed_task_ids is shared, so a hotfix never re-builds parent tasks.
//   • on completion the writer restores `phase` to the parent integer phase and the loop continues.
// This is a documented convention (the /hotfix command doc drives it); no integer-phase code changes — the
// string schema already supports it, keeping today's default integer-phase behavior byte-for-byte identical.
const STATE_SCHEMA = { type: 'object', additionalProperties: false, required: ['phase', 'completed_task_ids'],
  properties: { phase: { type: 'string', description: 'integer phase (Scope|Think|…|Audit|DONE|STALLED) OR a decimal interrupt phase like "PLAN.1"/"Build.2" for an urgent hotfix that slots back without renumbering' }, completed_task_ids: { type: 'array', items: { type: 'number' } } } }
const writeState = (obj) => safeOne(() => dispatch(`Using Bash \`mkdir -p ${projectPath}/walteur-kit/autopilot\`, then use the Write tool to OVERWRITE ${projectPath}/walteur-kit/autopilot/STATE.json with EXACTLY this content (verbatim): ${JSON.stringify(obj)}`,
  { label: `state:${obj.phase}`, model: 'sonnet', phase: 'Build' }), `state:${obj.phase}`)
const prior = await safeOne(() => dispatch(`Read ${projectPath}/walteur-kit/autopilot/STATE.json if present (Bash \`cat ... 2>/dev/null\`). Return its phase + completed_task_ids. If absent/empty/unparseable, return phase="IDLE", completed_task_ids=[].`,
  { schema: STATE_SCHEMA, model: 'sonnet', label: 'state:read', phase: 'Build' }), 'state:read')
completedIds = new Set((prior && !prior.__failed && prior.completed_task_ids) || [])
if (completedIds.size) log(`A2 resume · STATE.json shows ${completedIds.size} task(s) already built — skipping those, rebuilding only the rest`)

// ── v9.2 #3 — FROZEN PER-TASK BRIEFS. Before the swarm fan-out, freeze ONE brief per task to
//    walteur-kit/briefs/<task-id>.md = {PRD slice + design slice + the task's ACs + owned-file list}.
//    Each spawned implementer/reviewer reads its frozen brief instead of re-deriving the full PRD/PLAN/
//    DESIGN from scratch — cuts per-spawn context cost. mtime-INVALIDATED on PLAN.md ONLY: a brief is reused
//    on a re-run only if it is newer than PLAN.md; otherwise it is re-frozen. S9 — the brief's content
//    (owned files, ACs, detail, design slice) ALL derive from plan.* / scope.* / ADRs, i.e. from PLAN.md's
//    source — NOT from PRD.md (the "PRD slice" is built from the in-memory scope.* object). The old PRD.md
//    mtime check was therefore mismatched against the brief's actual content source: a PRD.md edit with an
//    unchanged scope caused needless re-churn while keying off a file the brief does not mirror. Keying
//    invalidation to exactly PLAN.md makes the freshness contract coherent. The design slice is
//    plan.design_doc + any resolved ADRs (the build's design-of-record). Emitted via the
//    existing agent()-mediated Write pattern (no Node fs) in ONE batched call. Failure = tracked non-fatal
//    blocker (safeOne) — the implementer prompt falls back to the inline brief if the file is absent.
const adrSliceForBrief = adrs.length
  ? adrs.map(a => `- ADR ${a.n}: ${a.question} → CHOSE ${a.chosen} (rejected ${a.rejected})`).join('\n')
  : '(no architecture forks resolved)'
const briefDocs = plan.tasks.map(t => {
  const md = `# Brief — Task ${t.id}: ${t.title}\n` +
    `> Frozen per-task brief (v9.2 #3). Read THIS instead of re-reading the full PRD/PLAN/DESIGN.\n\n` +
    `## Owned files (touch ONLY these)\n${(t.files || []).map(f => `- ${f}`).join('\n') || '- (none declared)'}\n\n` +
    `## Acceptance (this task only)\n${t.acceptance || '(none)'}\n\n` +
    `## What to implement\n${t.detail || '(see title)'}\n\n` +
    `## PRD slice (the wedge this serves)\n- One-line: ${scope.one_line}\n- Users + success metric: ${scope.users_and_metric}\n- In scope: ${(scope.in_scope || []).join('; ')}\n- Out of scope: ${(scope.out_scope || []).join('; ')}\n- Constraints: ${scope.constraints}\n\n` +
    `## Design slice (design-of-record)\n${(plan.design_doc || '(none)').slice(0, 1400)}\n\n### Architecture decisions in force\n${adrSliceForBrief}\n\n` +
    `## Build standard\nStack: ${scope.stack}. Build to current best (${reality.as_of}): ${reality.current_best}.\n`
  return { id: t.id, md }
}).filter(b => b.id != null)
// mtime-invalidation: freeze a brief ONLY if it is missing OR older than PLAN.md. One batched Bash+Write
// call; reuses fresh briefs on a re-run (cheap), re-freezes stale ones. S9 — key on PLAN.md ONLY (the file
// the brief's content actually derives from); the PRD.md check was dropped as mismatched (see comment above).
if (briefDocs.length) {
  const heredocs = briefDocs.map(b => {
    const path = `${projectPath}/walteur-kit/briefs/${b.id}.md`
    // freeze if: brief missing, OR PLAN.md newer than brief.
    return `BRF="${path}"; STALE=0; [ -f "$BRF" ] || STALE=1; [ -f ${projectPath}/PLAN.md ] && [ ${projectPath}/PLAN.md -nt "$BRF" ] && STALE=1; if [ "$STALE" = 1 ]; then cat > "$BRF" <<'WALTEUR_BRIEF_EOF'\n${b.md}\nWALTEUR_BRIEF_EOF\nfi`
  }).join('\n')
  await safeOne(() => dispatch(
    `WALTEUR frozen-brief freezer (v9.2 #3). Using Bash, first \`mkdir -p ${projectPath}/walteur-kit/briefs\`, then run EXACTLY this block (it re-freezes ONLY briefs that are missing or older than PLAN.md — mtime-invalidated):\n\n${heredocs}\n\nThen report how many brief files now exist: \`ls ${projectPath}/walteur-kit/briefs/ | wc -l\`.`,
    { label: 'freeze-briefs', model: 'sonnet', phase: 'Build' }), 'freeze-briefs')
  log(`v9.2 #3 · froze/reused ${briefDocs.length} per-task brief(s) → walteur-kit/briefs/ (mtime-invalidated vs PLAN.md)`)
}

// v10.0 DEPTH — LAYER_DEPTH (the per-§14-layer "build the FULL layer" catalog) is defined ABOVE phase('Plan')
// as the single source of truth — used by the planner's design-depth mandate AND the implementer-brief
// injection below. layerFor() (here) matches a task's files/role/title to its layer(s), token-aware (cap 2).
const layerFor = (t) => {
  const hay = ((t.files || []).join(' ') + ' ' + (t.role || '') + ' ' + (t.title || '') + ' ' + (t.detail || '')).toLowerCase()
  const rules = [
    ['auth', /auth|login|logout|session|oauth|sso|saml|oidc|jwt|rbac|permission|password|mfa|identity/],
    ['payments', /pay|billing|invoice|charge|stripe|checkout|subscription|ledger|refund|webhook/],
    ['data', /migrat|schema|\.sql|prisma|drizzle|typeorm|sequelize|repositor|\bmodel\b|entity|\bdao\b|\bdb\b|database|query/],
    ['async', /queue|\bjob\b|worker|consumer|producer|kafka|\bsqs\b|rabbit|\bcron\b|celery|\bbull\b|sidekiq|event-?bus/],
    ['observability', /logging|logger|\blogs?\b|metric|telemetry|observ|sentry|monitor|opentelemetry|tracing|\bspan\b/],
    ['infra', /terraform|\.tf\b|pulumi|cloudformation|\bk8s\b|kubernetes|helm|dockerfile|\bdeploy|\binfra|ci\/cd|pipeline/],
    ['api', /route|controller|\bapi\b|endpoint|handler|graphql|resolver|\.proto|\brest\b|\brpc\b/],
    ['frontend', /component|\.tsx|\.jsx|\.vue|\.svelte|\bpage\b|\bview\b|\bui\b|\bcss\b|frontend|client|button|\bform\b|modal/],
  ]
  const hits = []
  for (const [k, re] of rules) { if (re.test(hay)) hits.push(k) }
  return hits.slice(0, 2)
}

const build = []
// v9.2 #6 — per-task reconciliation ledger. Accumulates one record per built task; flushed as ONE
// SUMMARY.jsonl line per task per wave (planned=frozen brief, actual=diff/result). DRIFT/concern items
// are collected so QA reads them FIRST. WARNING-FIRST: a wave that built work but produced no
// reconciliation line gets a loud WARN (never blocks). graphify stays the one brain — flat append-only file.
const reconQaFirst = [] // {id, verdict} for DRIFT / DONE_WITH_CONCERNS — surfaced to QA before everything else
// v9.2 #10 — SPAWN-JUSTIFICATION discipline (RECORDED, behavior-preserving). Before the EXECUTION fan-out,
// justify each BUILD task spawn against the 6 criteria via the pure spawnJustify(). This is the ONLY place
// it applies — the governance panel / final-auditor / security-floor / Logic-Correctness / intent-auditor
// are NEVER subject to it (they must stay isolated). The recommendation is logged + written to a
// justification artifact; it does NOT change today's fan-out (small/uncertain tasks are merely flagged
// "prefer in-session"), honoring the "measure spawn ROI, don't slash" instinct + BEHAVIOR-PRESERVING law.
{
  const _waves = toWaves(plan.tasks)
  const _just = []
  _waves.forEach((wv, wi) => wv.forEach(t => {
    const j = spawnJustify({ files: t.files || [], deps: t.deps || [], detail: t.detail || '', acceptance: t.acceptance || '', model: t.model, sameWaveCount: wv.length, isExcluded: false })
    _just.push({ 'task-id': t.id, wave: wi + 1, recommend: j.recommend, criteria_met: j.met, small: j.small, criteria: j.criteria })
  }))
  const inSession = _just.filter(j => j.recommend === 'in-session')
  log(`v9.2 #10 · spawn-justification: ${_just.length} task(s) checked · ${inSession.length} flagged "prefer in-session" (recorded only — fan-out unchanged)`)
  await safeOne(() => dispatch(`WALTEUR spawn-justification ledger (v9.2 #10, advisory). Using Bash \`mkdir -p ${projectPath}/walteur-kit\`, then use the Write tool to create ${projectPath}/walteur-kit/spawn-justification.json with EXACTLY this content (verbatim): ${JSON.stringify({ note: '6-criteria spawn ROI check; advisory only — execution fan-out unchanged (behavior-preserving). Governance/auditor/security-floor/Logic-Correctness/intent-auditor are EXCLUDED and always isolated.', tasks: _just })}`,
    { label: 'spawn-justify', model: 'sonnet', phase: 'Build' }), 'spawn-justify')
}
// ── AUTO-COMPACTION (Tony's absolute-token rule; walteur-kit/compaction-policy.json: compact 150k / handoff
//    200k). Quality degrades with ABSOLUTE context size, not % of the window — so we compact on absolute tokens
//    hands-free, regardless of the 1M window. The durable handoff context (SUMMARY.jsonl + briefs) is what a
//    resumed run / fresh agent inherits; at each wave boundary maybeCompact MEASURES it via
//    context-compaction-gate.sh and, when it crosses the threshold (rc=2), writes the BATON checkpoint so the
//    build continues fresh without quality loss. No human in the loop. Active only on larger plans (>=8 tasks);
//    small builds never approach 150k, so they pay nothing.
const COMPACT_AFTER_TASKS = 8
async function maybeCompact(pp, waveNo) {
  if ((plan.tasks || []).length < COMPACT_AFTER_TASKS) return
  await safeOne(() => dispatch(
    `WALTEUR auto-compaction check (wave ${waveNo}; Tony's absolute-token rule). Using Bash, run EXACTLY:\n` +
    `g="${pp}/walteur-kit/hooks/context-compaction-gate.sh"; if [ -f "$g" ]; then WALTEUR_ROOT="${pp}" bash "$g"; rc=$?; else rc=0; fi; ` +
    `if [ "$rc" = "2" ]; then mkdir -p "${pp}/_relay"; printf '## compaction checkpoint — wave %s (%s)\\nCompleted waves: walteur-kit/SUMMARY.jsonl. Open work: PLAN.md. Context crossed the 150k compact threshold — continue fresh from here, do not re-load resolved waves.\\n' '${waveNo}' "$(date -u +%FT%TZ)" >> "${pp}/_relay/BATON.md"; fi; ` +
    `echo "auto-compaction wave ${waveNo} rc=$rc"`,
    { label: `compact:wave${waveNo}`, model: 'haiku', phase: 'Build' }), `compact:wave${waveNo}`)
}
let w = 0
for (const wave of toWaves(plan.tasks)) {
  w++
  // ── BUG-B FIX — hard budget check at EVERY wave boundary before spawning new work.
  if (overBudget(estUsd(), MAX_USD)) return await budgetStop(w - 1, 'Build')
  let waveBuilt = false
  const batches = disjointBatches(wave)
  log(batches.length > 1
    ? `build wave ${w}: ${wave.length} task(s) → ${batches.length} disjoint batches (shared-file collision serialized — A4)`
    : `build wave ${w}: ${wave.map(t => `T${t.id}`).join(', ')} (${wave.length} parallel)`)
  // CLAIM-LOGIC — per-wave in-memory file-claim registry. Prevents cross-batch file conflicts at the
  // wave level before dispatch. disjointBatches already guarantees this, so the check is a documented
  // safety net (always ok:true for valid plans). Cleared after the wave completes.
  const waveClaims = new Map()
  // A4 — WIP-commit before the wave so any in-wave mv/rm is reversible (the /rewind bash blind spot).
  await safeOne(() => dispatch(`Using Bash in ${projectPath}: run \`git add -A && git commit -q -m "wip: before build wave ${w}" || true\` (a no-op if nothing staged). Report done.`,
    { label: `wip:wave${w}`, model: 'sonnet', phase: 'Build' }), `wip:wave${w}`)
  for (const batch of batches) {
    // A2 — skip tasks already completed in a prior run (the terminal audit re-runs all tests, so a
    // trusted checkpoint is re-verified at the gate; resumed tasks count as built so metrics stay honest).
    const todo = batch.filter(t => !completedIds.has(t.id))
    batch.filter(t => completedIds.has(t.id)).forEach(t => build.push({ id: t.id, status: 'DONE', tests_pass: true, files_written: t.files || [], evidence: 'resumed from STATE.json checkpoint (re-verified by terminal audit)' }))
    if (todo.length < batch.length) log(`  (A2: skipped ${batch.length - todo.length} already-built task(s) from STATE.json)`)
    // CLAIM-LOGIC — register file claims for each task before dispatch. disjointBatches already
    // guarantees no same-batch file overlap, so this is always ok:true for valid plans. Logged as a
    // warning (never a block) if a collision is somehow detected — the task is treated as deferred.
    const todoAfterClaim = todo.filter(t => {
      const claim = claimFiles(waveClaims, t.id, t.files || [])
      if (!claim.ok) {
        log(`  ⚠️  CLAIM-LOGIC: T${t.id} deferred (files ${claim.conflicting_files.join(',')} already claimed by T${claim.blocked_by} this wave — collision serialized)`)
        return false
      }
      return true
    })
    const results = await parallel(todoAfterClaim.map(t => () => {
      // v10.0 DEPTH — inject this task's §14-layer spec(s) so the agent builds the FULL layer, not a sketch.
      const depthBlocks = layerFor(t).map(l => LAYER_DEPTH[l]).filter(Boolean)
      const layerInject = depthBlocks.length ? `\nLAYER DEPTH — implement the FULL layer; these are non-negotiable for THIS task: ${depthBlocks.join(' ')}\n` : ''
      return safeOne(fb => dispatch(
        `You are a WALTEUR ${t.role} (implementer). Working dir: ${projectPath} (Bash + Write). ` +
        `FIRST read your frozen brief: \`cat ${projectPath}/walteur-kit/briefs/${t.id}.md\` (v9.2 #3 — it holds the PRD slice + design slice + this task's ACs + your owned-file list; read IT instead of re-reading the full PRD/PLAN/DESIGN). If that file is absent, fall back to the inline brief below.\n` +
        `Implement TASK ${t.id}: ${t.title}. You OWN these files (do not touch others'): ${t.files.join(', ')}. Detail: ${t.detail}. Acceptance: ${t.acceptance}. ` +
        `TDD: failing test first, then the code, then RUN the test and read the real exit code. Stack: ${scope.stack}. ` +
        `CRAFT — write this as a staff engineer shipping a $50-100M-ARR product would (the bar is "would this pass review at Anthropic"): implement the FULL behavior end-to-end — every branch, error path, and edge case (empty / loading / failure / unauthorized / rate-limited / concurrent), not a happy-path sketch. NEVER a stub, TODO, "for now", "in a real app you'd…", or placeholder credential — finished production code only. Real typed errors (no empty catch, no swallowed errors, no \`console.log\` left in server code); precise types (no \`any\`, no \`@ts-ignore\`); validate every input at the trust boundary; emit structured logs + metrics on critical paths; enforce tenant/authz scoping on every data access. Idiomatic to ${scope.stack}, named for the domain, small composable units, matching the surrounding code — depth without gold-plating. Any external dependency is live-wired and proven, OR write a row to ${projectPath}/walteur-kit/deferrals.json (create as [] if absent; append, never overwrite) = {"id":"D<n>","what":"<dependency>","why_deferred":"<reason>","needs":"<what unblocks it>","expires":"<date or empty>","ticket_text":"<follow-up>"} — a deferral is honest, a fake dependency is not. ` +
        layerInject +
        skillInjectFor('Build') +
        `The task's test MUST pass on a fresh run — report the exact command + result.` +
        TAIL_RULES,
        { schema: TASK_SCHEMA, model: fb ? 'sonnet' : (t.model === 'opus' ? 'opus' : 'sonnet'), label: `build:T${t.id}`, phase: 'Build' }
      ), `build:T${t.id}`)
    }))
    if (todo.length) waveBuilt = true
    build.push(...results)
    results.forEach(r => { if (r && r.id != null && r.tests_pass) completedIds.add(r.id); log(`  T${r.id != null ? r.id : r.label}: ${r.status}${r.tests_pass ? ' ✓' : ' ✗'}`) })
  }
  clearClaims(waveClaims) // CLAIM-LOGIC — release all per-wave file claims after the wave completes
  await writeState({ phase: 'Build', completed_task_ids: [...completedIds] }) // checkpoint after each wave
  // v9.2 #6 — RECONCILE this wave: one SUMMARY.jsonl line per task = {task-id, planned-vs-actual,
  // per-AC verdict, deviation+why}. planned = the frozen brief's owned-file set; actual = files_written.
  // Verdict via the pure reconcileVerdict() table. WARNING-FIRST: if the wave built work but no line was
  // produced, WARN (never block). DRIFT / DONE_WITH_CONCERNS collected for QA-read-first ordering.
  const waveRecon = wave.map(t => {
    const r = resolveBuildResult(build, failures, t.id) // S1 — matches failed sentinels (id-carried + label fallback), never r={}
    const concern = !!(r && r.__failed) || (r.status === 'DONE' && r.tests_pass === false) || !!(r && r.__usedFallback) // S1 — fallback-tier success is a concern
    const verdict = reconcileVerdict({ status: r.status, tests_pass: r.tests_pass, planned_files: t.files || [], actual_files: r.files_written || [], concern })
    const planned = (t.files || []).slice().sort().join(',')
    const actual = (r.files_written || []).slice().sort().join(',')
    let deviation = ''
    if (verdict === 'DRIFT') deviation = `owned-file drift: planned [${planned}] vs actual [${actual}]`
    else if (verdict === 'GAP') deviation = 'tests did not pass on this task'
    else if (verdict === 'BLOCKED') deviation = r.__failed ? 'implementer failed after retry+fallback' : 'implementer reported BLOCKED'
    else if (verdict === 'DONE_WITH_CONCERNS') deviation = 'built but a concern was recorded (e.g. fallback model / partial)'
    if (RECON_QA_FIRST.has(verdict)) reconQaFirst.push({ id: t.id, verdict })
    return { 'task-id': t.id, wave: w, planned, actual, ac_verdict: verdict, deviation }
  })
  if (waveBuilt && waveRecon.length === 0) {
    log(`⚠️  v9.2 #6 WARN: build wave ${w} produced NO reconciliation line — ledger gap (not blocking).`)
  } else if (waveRecon.length) {
    const reconCmds = waveRecon.map(rec => `printf '%s\\n' '${JSON.stringify(rec).replace(/'/g, "'\\''")}'`).join(' && ')
    await safeOne(() => dispatch(`WALTEUR reconciliation ledger (v9.2 #6). Using Bash, run EXACTLY:\n\`mkdir -p ${projectPath}/walteur-kit && ( ${reconCmds} ) >> ${projectPath}/walteur-kit/SUMMARY.jsonl\`\nReport done.`,
      { label: `reconcile:wave${w}`, model: 'sonnet', phase: 'Build' }), `reconcile:wave${w}`)
    const flags = waveRecon.filter(r => RECON_QA_FIRST.has(r.ac_verdict))
    log(`v9.2 #6 · wave ${w} reconciled: ${waveRecon.map(r => `T${r['task-id']}=${r.ac_verdict}`).join(' · ')}${flags.length ? ` · ${flags.length} flagged for QA-read-first` : ''}`)
  }
  await maybeCompact(projectPath, w) // auto-compact context at 150k/200k absolute (Tony's rule), hands-free
  // §2a HITL — pause_per_task: halt after each build WAVE that actually built work (resumed/skipped
  // waves never re-pause, avoiding an infinite-pause loop). OFF by default; reuses the APPROVED-file seam.
  if (autonomyPolicy === 'pause_per_task' && waveBuilt && !(await requireApproval(`BUILD-WAVE-${w}`, `Build wave ${w} done (${wave.length} task(s)). Review the diff, then approve to continue.`))) {
    log(`⏸ PAUSED for human approval after build wave ${w} (autonomy_policy=pause_per_task). Write walteur-kit/APPROVED, then re-run /goal to resume.`)
    return { paused: true, gate: `BUILD-WAVE-${w}` }
  }
}

// ───────────────────────── REVIEW (governance panel, parallel) ─────────────────────────
await flushSpans('Build')
// ── BUG-B FIX — budget check before spawning the 7-senior governance panel fan-out.
if (overBudget(estUsd(), MAX_USD)) return await budgetStop(w, 'Review')
phase('Review')
emitSpan({ phase: 'Review', model: 'opus', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
// v9.2 #8 — STANDARDIZED merge-base diff scoping. Every reviewer (the §5.2a blind-diff reviewer + the §5
// seven-senior panel) scopes "the diff" to `git diff --merge-base origin/HEAD` so review focuses on THIS
// build's net change, not the whole tree. detect-or-SKIP: if no merge-base resolves (no origin/HEAD, e.g. a
// fresh greenfield repo with no remote), FALL BACK to the working-tree diff (`git diff` + the pre-build wip
// commit if present) and RECORD a one-line note that merge-base was unavailable — never error, never block.
const MERGEBASE_DIFF = `Scope the diff with merge-base (v9.2 #8): try \`git diff --merge-base origin/HEAD\` first; if that errors or origin/HEAD does not resolve (e.g. a fresh repo with no remote), FALL BACK to the working-tree diff (\`git diff\`, plus the pre-build "wip: before build wave" commit if present) and note that merge-base was unavailable. Never let a missing merge-base block you.`
const SENIORS = [
  ['Senior PM', 'scope, wedge, measurable win, Definition of Done'],
  ['Senior UI/UX', 'design/UX quality, states, accessibility (N/A if no UI)'],
  ['Senior Full-Stack', 'simplest-correct architecture, tests, the production-reality layers for this stack'],
  ['Senior Security', 'injection, secrets, authz, input validation, dependency risk — the floor'],
  ['Senior Growth', 'usable + adoptable; README/onboarding clear'],
  ['Senior DevOps/SRE', 'hosting, cloud/compute, CI/CD, observability, availability/DR — §14 layers 5,6,7,12,13 (the cloud-heavy layers)'],
  ['Chief of Staff', 'every task done, tests green, DoD met, honestly shippable'],
]
// v10.0 DEPTH (D3) — the craft bar, applied by EVERY senior reviewer + the terminal auditor. Slop and
// happy-path-only code is a VETO, not a nit. Mirrors anti-slop-code-gate + the implementer CRAFT mandate.
const CRAFT_REVIEW = 'CRAFT BAR (this build targets $50-100M-ARR production; the bar is "would this pass review at Anthropic"): a happy-path-only, stubbed, or AI-slop implementation is a VETO, not a nit. Within YOUR discipline, veto (citing file:line) any TODO/FIXME/placeholder/"in a real app you would"/stub return, missing error or edge handling (empty, loading, failure, unauthorized, rate-limited, concurrent), an any-typed or @ts-ignore escape, an empty catch or swallowed error, unvalidated input at a trust boundary, missing tenant/authz scoping, or a money/write path with no idempotency.'
const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['senior', 'verdict', 'blocking_issues', 'notes'],
  properties: { senior: { type: 'string' }, verdict: { type: 'string', enum: ['PASS', 'VETO'] },
    blocking_issues: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } },
}
const reviewOnce = () => parallel(SENIORS.map(([name, owns]) => () =>
  safeOne(fb => dispatch(`You are ${name} on a WALTEUR build, reviewing ${projectPath} (read it; run the tests). ${MERGEBASE_DIFF} You own: ${owns}. Goal: ${idea}. Ruthless, evidence-based. Apply the CITE-OR-VETO rubric for your discipline (the full rubrics ship in walteur-kit/rubrics/): every blocking issue MUST cite a concrete file:line; if you cannot cite evidence for a concern, do not raise it; if a required check for your discipline has NO evidence in the project, that is itself a VETO. ${CRAFT_REVIEW} VETO only for a real blocking gap with a concrete fix; auto-PASS if your discipline does not apply to this build.${skillInjectFor('Review')}\n\nRead LAST (your final instruction, it overrides the tone above): absence of evidence for a required security / RLS / cross-tenant / secret / authz / anti-slop check IS itself a VETO — never auto-PASS to reduce friction, and every blocking issue cites a concrete file:line.`,
    { schema: VERDICT_SCHEMA, model: fb ? 'sonnet' : 'opus', label: `review:${(name.split(' ')[1] || name)}`, phase: 'Review' }), `review:${(name.split(' ')[1] || name)}`)
)).then(rs => rs.filter(Boolean)) // sentinels (failed reviewers) are retained → counted as blockers via failures[], never silently dropped
let panel = await reviewOnce()
const vetoes = (p) => p.filter(v => v && v.verdict === 'VETO')
// v10.20 PLATEAU LAW (rocket-fuel port) — every §3.x cycle is recorded in scoreboard.json refine_history;
// excellence-loop-gate.sh enforces plateau-or-cap-with-residuals over it at ship.
// Codex-audit fixes: round 1 is the BASELINE generate (refined:false — a generate is not a refinement, so
// it can never be one of the two consecutive REFINED rounds a plateau requires); every round carries a
// NUMERIC composite computed from the live panel (no null-composite escape in the gate's no-improvement law).
const _refineHistory = []
const roundComposite = () => (SENIORS.length ? +(10 * (panel.length - vetoes(panel).length) / SENIORS.length).toFixed(1) : (vetoes(panel).length === 0 ? 10 : 5))
const pushRefineRound = (refined) => _refineHistory.push({ round: _refineHistory.length + 1, composite: roundComposite(), all_green: vetoes(panel).length === 0, refined: !!refined, reproved: true })
pushRefineRound(false)  // baseline generate — not a refinement

const BLIND_SCHEMA = { type: 'object', additionalProperties: false, required: ['findings'], properties: { findings: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['severity','file','note'], properties: { severity: { type: 'string', enum: ['block','important','nit'] }, file: { type: 'string' }, line: { type: 'integer' }, note: { type: 'string' } } } } } }
// Blind-diff reviewer (§5.2) — ADVISORY ONLY. Diff-only, zero intent context. Deliberately NOT in `panel`.
// Its findings are advisory; the final auditor reconciles each one (promote to shortfall or dismiss with reason).
// It NEVER enters panel/vetoes() and therefore CANNOT block ship or burn refine cycles.
await safeOne(() => dispatch(
  `WALTEUR blind-diff reviewer (advisory). In ${projectPath} via Bash, get the build diff. ${MERGEBASE_DIFF} You are given ONLY the diff — NO plan, NO spec, NO benchmark, NO ADRs, NO goal. Judge whether the code stands on its OWN terms: correctness, footguns, smells, dead code, missing error handling — given zero knowledge of intent. Classify each finding block|important|nit. Use the Write tool to write walteur-kit/blind-review.json = {"findings":[{"severity","file","line","note"}]}. You do NOT block the ship — this is advisory; the final auditor reconciles your findings.`,
  { model: 'opus', label: 'blind-review', phase: 'Review', schema: BLIND_SCHEMA }), 'blind-review')

// §2a HITL gate — SEAM 2 · POST-REVIEW checkpoint (v9.2 #9 + #7). EXPOSED: 'pause_at_review' is now in
// STATE.json _autonomy_options and SKILL.md §2a. Fires ONLY when autonomy_policy='pause_at_review' (or
// 'pause_per_task' if that policy ever adds ['pause_at_review'] to its requireApproval calls — it does not
// today). Default full_autopilot and pause_at_plan_and_audit do NOT fire this seam. Lets a human inspect
// the governance panel verdicts + advisory findings before the REFINE loop spends budget.
if (!(await requireApproval('REVIEW', `Governance review done — ${vetoes(panel).length} veto(es) of ${panel.length}. Inspect the senior verdicts + advisory findings, then approve to enter REFINE.`, ['pause_at_review']))) {
  log('⏸ PAUSED for human approval after REVIEW (autonomy_policy=pause_at_review). Write walteur-kit/APPROVED, then re-run /goal to resume.')
  return { paused: true, gate: 'REVIEW' }
}

// ───────────────────────── REFINE (loop to the bar) ─────────────────────────
await flushSpans('Review')
phase('Refine')
emitSpan({ phase: 'Refine', model: 'opus', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
// A5 — stuck/loop detection: the blocking-issue set must STRICTLY SHRINK each pass. If it fails to
// shrink for 2 consecutive iterations (oscillation: fix A breaks B, fix B breaks A), stop blind
// refining and route ONCE to a root-cause re-plan instead of burning the budget on thrash.
let prevOpenCount = Infinity, stagnant = 0

// v9.2 #1 — TRIAGE-LOGIC START (pure; keep self-contained between these markers for selftest extraction)
// Per-gate consecutive-RED counter: Map<gateKey, consecutiveCount>. Reset when the gate turns GREEN.
// Triage fires only on 2nd+ consecutive same-gate RED. Default (1st RED, low-conf, parse-fail) → Code.
const _consecutiveRedByGate = new Map()
function triageRoute({ gate, consecutive_n, classification, confidence, threshold = 0.7 }) {
  // Default / safety rules — Code path preserves today's behavior
  if (consecutive_n < 2) return 'Code'
  if (!classification || classification === 'Code') return 'Code'
  if (confidence < threshold) return 'Code'
  if (classification === 'Intent') return 'Intent'
  if (classification === 'Spec') return 'Spec'
  return 'Code' // unparseable or unknown → safe default
}
// v9.2 #1 — TRIAGE-LOGIC END

const TRIAGE_SCHEMA = { type: 'object', additionalProperties: false, required: ['root_cause', 'rationale', 'confidence'],
  properties: { root_cause: { type: 'string', enum: ['Intent', 'Spec', 'Code'] }, rationale: { type: 'string' }, confidence: { type: 'number' } } }
const REFINE_LOG_PATH = `${projectPath}/walteur-kit/refine-log.json`
let _refineLog = []

while (vetoes(panel).length > 0 && refineIter < maxRefine && budgetGuard()) {
  refineIter++
  const open = vetoes(panel).flatMap(v => (v.blocking_issues || []).map(i => `[${v.senior}] ${i}`))
  stagnant = open.length >= prevOpenCount ? stagnant + 1 : 0
  prevOpenCount = open.length

  // v9.2 #1 — per-gate consecutive RED tracking + optional triage on 2nd consecutive same-gate RED
  const vetoedGates = vetoes(panel).map(v => v.senior || 'unknown').sort().join(',')
  const prevCount = _consecutiveRedByGate.get(vetoedGates) || 0
  const newCount = prevCount + 1
  _consecutiveRedByGate.set(vetoedGates, newCount)
  // Reset gates that turned green. S4 — exact-equality membership (NOT substring): only the currently-vetoing
  // gate string retains its counter; every other key resets. The old `!vetoedGates.includes(g)` was a substring
  // test over the comma-joined senior names, so e.g. prev 'Security' leaked when current is 'PM,Security'.
  for (const [g] of _consecutiveRedByGate) { if (g !== vetoedGates) _consecutiveRedByGate.delete(g) }
  let triageVerdict = null
  if (newCount >= 2) {
    log(`refine ${refineIter}: gate "${vetoedGates}" RED for ${newCount} consecutive iters — invoking triage agent.`)
    const triage = await safeOne(() => dispatch(
      `WALTEUR failure-triage (v9.2). Gate "${vetoedGates}" has been RED for ${newCount} consecutive refine iterations. Open issues:\n- ${open.join('\n- ')}\nProject ${projectPath}. Classify the ROOT CAUSE:\n- Intent: the original goal/bet is wrong — refining code won't fix this; requires re-DISCOVER.\n- Spec: the PLAN/PRD is wrong or contradictory — spec needs editing first.\n- Code: the implementation is wrong — the existing refine path is correct.\nReturn {root_cause:"Intent"|"Spec"|"Code", rationale:"<1-2 sentences>", confidence:<0.0-1.0>}. Default to Code on any uncertainty.`,
      { schema: TRIAGE_SCHEMA, model: 'opus', label: `triage:${refineIter}`, phase: 'Refine' }), `triage:${refineIter}`)
    const root_cause = (triage && !triage.__failed && triage.root_cause) || 'Code'
    const confidence = (triage && !triage.__failed && triage.confidence) || 0
    const route = triageRoute({ gate: vetoedGates, consecutive_n: newCount, classification: root_cause, confidence })
    triageVerdict = { iter: refineIter, gate: vetoedGates, consecutive_n: newCount, root_cause, confidence, route, rationale: (triage && triage.rationale) || '' }
    _refineLog.push(triageVerdict)
    emitSpan({ phase: 'Refine', model: 'opus', tool: 'triage', exit_code: '0', gate_verdict: `triage:${route}:iter${refineIter}` })
    await safeOne(() => dispatch(
      `Write the file ${REFINE_LOG_PATH} with this JSON content: ${JSON.stringify(_refineLog)}`,
      { model: 'sonnet', label: `triage:log:${refineIter}`, phase: 'Refine' }), `triage:log:${refineIter}`)
    if (route === 'Spec') {
      log(`refine ${refineIter}: triage SPEC — editing PLAN/PRD then re-deriving.`)
      await safeOne(() => dispatch(
        `WALTEUR spec-editor. The triage agent determined the SPEC is wrong. Working dir ${projectPath}. Read walteur-kit/PLAN.md and walteur-kit/PRD.md (if it exists). The failing gate "${vetoedGates}" issues:\n- ${open.join('\n- ')}\nFix the PLAN (and PRD if applicable) to correctly specify the solution, then re-derive any affected task implementations. Re-run the test suite. Do NOT scope-creep.`,
        { label: `spec-edit:${refineIter}`, model: 'opus', phase: 'Refine' }), `spec-edit:${refineIter}`)
      panel = await reviewOnce()
      pushRefineRound(true)
      continue
    }
    if (route === 'Intent') {
      log(`refine ${refineIter}: triage INTENT — pausing for human approval before re-DISCOVER.`)
      // SEAM 4 · INTENT-REDISCOVER (v9.2 #9 registry) — the ONLY non-opt-in seam: NEVER autopilot, always
      // pauses regardless of autonomy_policy, because a re-DISCOVER must never run unattended.
      const approved = await safeOne(() => dispatch(
        `WALTEUR HITL approval gate "INTENT-REDISCOVER". In ${projectPath} using Bash:\n` +
        `1) Write walteur-kit/APPROVAL-REQUEST.json = {"gate":"INTENT-REDISCOVER","summary":"Triage determined the original intent/bet is wrong after ${newCount} consecutive ${vetoedGates} failures. A re-DISCOVER pass is required.","ts":<date +%s>}.\n` +
        `2) If file walteur-kit/APPROVED exists AND is newer than APPROVAL-REQUEST.json: rm -f walteur-kit/APPROVED and return approved=true. Otherwise return approved=false.\nReturn ONLY {"approved": <bool>}.`,
        { model: 'sonnet', label: `approve:INTENT-REDISCOVER`, phase: 'Refine', schema: APPROVE_SCHEMA }), `approve:INTENT-REDISCOVER`)
      const wasApproved = !!(approved && !approved.__failed && approved.approved)
      if (!wasApproved) {
        log(`refine ${refineIter}: INTENT-REDISCOVER paused — no APPROVED file found. Build STOPS. Re-run /goal after placing walteur-kit/APPROVED to resume with re-DISCOVER.`)
        await flushSpans('Refine')
        return { paused: true, gate: 'INTENT-REDISCOVER', message: 'Triage determined original intent is wrong. Place walteur-kit/APPROVED and re-run /goal to proceed with re-DISCOVER.' }
      }
      // Human approved: archive the spec-of-record (PRD + PLAN) and STOP so the NEXT /goal genuinely
      // re-enters DISCOVER/Scope/Think/Plan from the front. S2 — the old `panel = await reviewOnce(); break`
      // re-reviewed the SAME unchanged code (a near no-op rebuild that then shipped the build Intent just
      // declared wrong). A real re-DISCOVER cannot run mid-loop: it needs a fresh Scope (and a re-derived
      // task DAG), which is exactly what re-running /goal does — STATE.json is reset to IDLE so the resume
      // does NOT skip phases, and the stale PLAN.md is archived so the DAG is re-derived, not re-seeded.
      // stamp is generated bash-side (workflow scripts cannot call the JS Date API)
      log(`refine ${refineIter}: INTENT-REDISCOVER approved — archiving PRD+PLAN and STOPPING for a fresh /goal re-DISCOVER.`)
      await safeOne(() => dispatch(
        `In ${projectPath} using Bash: archive the wrong spec-of-record so the next /goal re-derives from scratch — \`stamp=$(date -u +%Y%m%dT%H%M%SZ); [ -f walteur-kit/PRD.md ] && mv walteur-kit/PRD.md walteur-kit/PRD.archived-$stamp.md; [ -f PLAN.md ] && mv PLAN.md PLAN.archived-$stamp.md; true\`. Then run \`bash walteur-kit/self-heal.sh 2>&1 || true\` to refresh upstream state. Report the stamp value used and confirm done.`,
        { model: 'sonnet', label: `archive-spec:${refineIter}`, phase: 'Refine' }), `archive-spec:${refineIter}`)
      // Reset autopilot STATE so re-running /goal re-enters from the FRONT (DISCOVER/Scope), not mid-build.
      await writeState({ phase: 'IDLE', completed_task_ids: [] })
      await flushSpans('Refine')
      return { paused: true, gate: 'INTENT-REDISCOVER-APPROVED', message: `Intent re-DISCOVER approved: PRD+PLAN archived (timestamp generated by shell) and autopilot reset to IDLE. Re-run /goal to re-enter DISCOVER and re-derive the build from a fresh scope.` }
    }
  }
  // Code route (default) — existing refiner (today's behavior, unmodified)
  if (stagnant >= 2) {
    log(`refine ${refineIter}: blocking set not shrinking (${open.length}) for ${stagnant} iters — STALL → root-cause re-plan (Confusion Protocol).`)
    await safeOne(() => dispatch(`WALTEUR re-planner (Confusion Protocol). The refine loop is STUCK — these issues will not resolve by direct fixes:\n- ${open.join('\n- ')}\nWorking dir ${projectPath}. Step back: diagnose the ROOT cause (a wrong assumption or wrong approach), make the smallest STRUCTURAL change that unblocks ALL of them at once, then re-run the full test suite and confirm green.\n\nASSUMPTION LEDGER (S033 #5) — after diagnosing, APPEND one entry describing the wrong assumption you found to the "assumptions" array in ${projectPath}/walteur-kit/assumptions.json (read it first via Bash \`cat\`, merge — do NOT overwrite existing entries): {"assumption":"<the wrong assumption that caused the stall>","risk":"high","revisit_when":"next replan or scope revisit"}.`,
      { label: `replan:${refineIter}`, model: 'opus', phase: 'Refine' }), `replan:${refineIter}`)
    panel = await reviewOnce(); pushRefineRound(true); break
  }
  log(`refine ${refineIter}/${maxRefine}: ${open.length} blocking issue(s)`)
  await safeOne(() => dispatch(`WALTEUR refiner. Working dir: ${projectPath} (Bash + Write). Fix EXACTLY these blocking issues, root-cause, then RE-RUN the full test suite and confirm it passes (never declare done without a green run):\n- ${open.join('\n- ')}\nNo scope creep.`,
    { label: `refine:${refineIter}`, model: 'opus', phase: 'Refine' }), `refine:${refineIter}`)
  emitSpan({ phase: 'Refine', model: 'opus', tool: 'refine', exit_code: '0', gate_verdict: `iter:${refineIter}` })
  panel = await reviewOnce()
  pushRefineRound(true)
}

// v10.20 PLATEAU LAW — a green exit is the FLOOR, not the finish. A plateau needs TWO consecutive
// REFINED-and-re-proved all-green rounds with no composite improvement (rocket-fuel: an unrefined repeat is
// idling, not a plateau). Since the baseline generate is refined:false, a green build runs up to two
// falsification rounds (each a genuine refinement attempt that may return "nothing to refine" WITH evidence)
// to establish the two consecutive refined rounds the gate demands. Bails early if a falsification round
// reopens a veto (back to a red exit → residuals, not a fake plateau) or budget runs out.
const refinedSoFar = () => _refineHistory.filter(r => r.refined).length
for (let fx = 1; fx <= 2 && vetoes(panel).length === 0 && budgetGuard() && refinedSoFar() < maxRefine; fx++) {
  log(`excellence loop: green — falsification round ${fx}/2 (plateau law, rocket-fuel port)`)
  await safeOne(() => dispatch(`WALTEUR falsification refiner (plateau law, v10.20, pass ${fx}/2). Working dir ${projectPath} (Bash + Write). The senior panel is currently veto-free. Attempt to FALSIFY that verdict: hunt for any genuine refinement (simplicity, naming, error texts, docs truthfulness, performance) that keeps ALL existing proofs green — apply the single best one and RE-RUN the full test suite to confirm green; if nothing withstands scrutiny, change nothing and report "nothing to refine" WITH the evidence you inspected. Never weaken a proof, never expand scope.`,
    { label: `refine:falsify:${fx}`, model: 'opus', phase: 'Refine' }), `refine:falsify:${fx}`)
  panel = await reviewOnce()
  pushRefineRound(true)
}

// ───────────────────────── VALIDATE (QA + parallel fact-check) ─────────────────────────
await flushSpans('Refine')
// ── BUG-B FIX — budget check before spawning the QA corps fan-out.
if (overBudget(estUsd(), MAX_USD)) return await budgetStop(w, 'Validate')
phase('Validate')
emitSpan({ phase: 'Validate', model: 'opus', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
const QA_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['verdict', 'tests', 'test_command', 'evidence', 'gaps'],
  properties: { verdict: { type: 'string', enum: ['PASS', 'VETO'] }, tests: { type: 'string' },
    test_command: { type: 'string', description: 'the EXACT shell command you ran for unit/integration tests (e.g. "node --test") so the ship-gate can re-run it; "" if none' },
    evidence: { type: 'string' }, gaps: { type: 'array', items: { type: 'string' } } },
}
// QA CORPS — a real MULTI-AGENT proving arm that tests EVERYTHING about the build, not just the code.
// Each dimension is an independent adversarial agent. The Logic & Correctness agent specifically attacks
// the REASONING behind the build — a green test suite does NOT mean the logic is correct.
const QA_CORPS = [
  ['Functional', 'every feature & user-story works END-TO-END — exercise each real flow + boundary/empty/huge/invalid inputs. Does it actually DO what was promised?'],
  ['Logic-Correctness', 'THE LOGIC BEHIND THE BUILD: is the business logic / algorithm actually CORRECT, not merely runnable? Trace the reasoning; prove the invariants hold; hunt off-by-ones, wrong assumptions, mishandled edge cases, bad state transitions, ordering/concurrency races. Construct inputs that BREAK the logic. A passing test suite does not mean correct logic — find where the reasoning is wrong.'],
  ['Integration', 'components/services/APIs talk correctly; contracts honored across every seam; no version mismatch, no silent cross-boundary failure'],
  ['Data-Integrity', 'data stays correct & consistent; migrations safe+reversible; no corruption/loss; constraints & invariants actually enforced; concurrent writes safe'],
  ['Security', 'attack it adversarially: authz bypass, injection, secrets, input validation, SSRF — the OWASP floor'],
  ['UX-Resilience', 'real states (loading/empty/error), a11y, graceful failure, retries/timeouts, degradation under fault'],
]
const verifiers = team.roster.filter(r => r.kind === 'verifier').slice(0, 2)
// v9.2 #6 — DRIFT / DONE_WITH_CONCERNS tasks from the reconciliation ledger are read FIRST by QA.
const qaReadFirst = reconQaFirst.length
  ? ` READ-FIRST (v9.2 #6 reconciliation flagged these as DRIFT/concerns — prioritize prosecuting them, and read walteur-kit/SUMMARY.jsonl): ${reconQaFirst.map(r => `T${r.id}=${r.verdict}`).join(', ')}.`
  : ''
const qaResults = await parallel([
  () => safeOne(fb => dispatch(`You are the WALTEUR QA Gatekeeper (lead). Project ${projectPath}, goal ${idea}. Independently RUN the tests (find + execute via Bash), exercise the primary flow + edge cases. Report real command output + exit codes, and the EXACT unit/integration command in test_command. VETO on any failing/missing test or broken flow.${qaReadFirst}${skillInjectFor('Validate')}`,
    { schema: QA_SCHEMA, model: fb ? 'sonnet' : 'opus', label: 'qa:gatekeeper', phase: 'Validate' }), 'qa:gatekeeper'),
  ...QA_CORPS.map(([dim, mandate]) => () => safeOne(() => dispatch(`You are WALTEUR QA — ${dim}. Project ${projectPath}, goal "${idea}". Your dimension: ${mandate}. Test it INDEPENDENTLY with EVIDENCE — read the code, RUN things, and construct adversarial inputs. PASS only if your dimension genuinely holds; VETO with concrete, cited gaps otherwise. Set test_command to the exact command if you ran one, else "".${qaReadFirst}`,
    { schema: QA_SCHEMA, model: (dim === 'Logic-Correctness' || dim === 'Security') ? 'opus' : 'sonnet', label: `qa:${dim}`, phase: 'Validate' }), `qa:${dim}`)),
  ...verifiers.map(v => () => safeOne(() => dispatch(`You are a WALTEUR ${v.role} (verifier). Project ${projectPath}, goal ${idea}. ${v.mandate}. Independently verify with evidence (run things). Report PASS/VETO + gaps.`,
    { schema: QA_SCHEMA, model: 'sonnet', label: `verify:${v.role.split(' ')[0]}`, phase: 'Validate' }), `verify:${v.role.split(' ')[0]}`)),
])
const qa = qaResults[0]
const corps = {}
QA_CORPS.forEach(([dim], i) => { corps[dim] = qaResults[1 + i] })

// ── v9.2 #11 — ISOLATED SECURITY RE-PROSECUTOR. After the §5.4 Security-adversarial QA pass, a SEPARATE
// isolated agent re-prosecutes EACH security finding. It DEMOTES (never invents new blocks, never
// auto-vetoes): a finding is demoted to an ADVISORY note unless it can cite BOTH SIDES — the attack path
// AND the absent/present mitigation at the sink — PLUS a concrete NAMED exploitability path. Surviving
// findings stay launch-blocking (Security stays VETO). If EVERY finding is demoted, the Security dimension's
// effective verdict relaxes to PASS and the demoted findings become advisory notes in qa-report.json.
// No magic-number scalar — the bar is cite-both-sides + named-exploitability-path. Demoted-only, so it can
// NEVER tighten a PASS into a VETO. A failed re-prosecutor leaves the original Security verdict untouched.
const secRaw = corps['Security']
const secVetoed = !!(secRaw && !secRaw.__failed && secRaw.verdict === 'VETO' && (secRaw.gaps || []).length)
let securityDemotions = [] // advisory notes for qa-report.json
let securityVerdictOverride = null // set to 'PASS' only if EVERY finding is demoted
if (secVetoed) {
  const REPROS_SCHEMA = { type: 'object', additionalProperties: false, required: ['rulings'], properties: { rulings: { type: 'array', items: {
    type: 'object', additionalProperties: false, required: ['finding', 'ruling', 'reason'],
    properties: { finding: { type: 'string' }, ruling: { type: 'string', enum: ['survives', 'demote'] },
      attack_path: { type: 'string' }, mitigation_at_sink: { type: 'string' }, named_exploitability_path: { type: 'string' }, reason: { type: 'string' } } } } } }
  const repros = await safeOne(() => dispatch(
    `You are the WALTEUR ISOLATED security re-prosecutor (v9.2 #11) — a SEPARATE pass from the Security QA agent. Project ${projectPath}, goal "${idea}". The Security QA pass raised these findings:\n- ${(secRaw.gaps || []).join('\n- ')}\n\nRe-prosecute EACH finding against a strict cite-BOTH-SIDES + named-exploitability bar. A finding SURVIVES (stays launch-blocking) ONLY if you can cite ALL THREE, grounded in the actual code (file:line):\n  1) the concrete ATTACK PATH (how an attacker reaches the sink),\n  2) the MITIGATION AT THE SINK and whether it is ABSENT or PRESENT (cite the line — if a mitigation is present and adequate, the finding does NOT survive),\n  3) a concrete NAMED exploitability path (a specific, realizable exploitation, not "could be risky").\nIf ANY of the three cannot be cited from real code, DEMOTE the finding to an advisory note. You may ONLY rule survives|demote — you may NOT invent new findings and you may NOT raise a verdict. Be conservative: when a real, reachable, unmitigated vuln is shown, it SURVIVES. Return {rulings:[{finding, ruling, attack_path, mitigation_at_sink, named_exploitability_path, reason}]}.`,
    { schema: REPROS_SCHEMA, model: 'opus', label: 'security:reprosecute', phase: 'Validate' }), 'security:reprosecute')
  if (repros && !repros.__failed && Array.isArray(repros.rulings)) {
    const survivors = repros.rulings.filter(r => r.ruling === 'survives')
    securityDemotions = repros.rulings.filter(r => r.ruling === 'demote').map(r => ({ finding: r.finding, reason: r.reason }))
    if (survivors.length === 0) {
      securityVerdictOverride = 'PASS' // EVERY finding demoted → Security relaxes to PASS (demote-only)
      log(`v9.2 #11 · security re-prosecutor DEMOTED all ${securityDemotions.length} finding(s) — Security VETO → PASS (advisory notes kept). Demote-only; never auto-vetoes.`)
    } else {
      log(`v9.2 #11 · security re-prosecutor: ${survivors.length} finding(s) SURVIVE (stay launch-blocking) · ${securityDemotions.length} demoted to advisory.`)
    }
  } else {
    log('v9.2 #11 · security re-prosecutor failed to run — original Security verdict left UNTOUCHED (fail-safe).')
  }
}
const cv = (dim) => {
  if (dim === 'Security' && securityVerdictOverride) return securityVerdictOverride // #11 demote-only relax
  return (corps[dim] && !corps[dim].__failed && corps[dim].verdict) || 'VETO'
}
const checks = qaResults.slice(1) // every QA member except the lead gatekeeper
// A3 — every QA member must be a real PASS: a failed/dropped member (or a VETO from any dimension,
// including LOGIC) can never read as a pass. This is the multi-agent "test everything" gate.
// v9.2 #11 — the Security member's EFFECTIVE verdict honors the re-prosecutor's demote-only relax: if it
// flipped Security VETO→PASS (every finding demoted), that member counts as PASS here too. No other
// dimension is affected, and the re-prosecutor can never tighten a PASS into a VETO.
const effVerdict = (c) => (c && c === corps['Security'] && securityVerdictOverride) ? securityVerdictOverride : (c && c.verdict)
const qaPass = qa && !qa.__failed && qa.verdict === 'PASS' && checks.every(c => c && !c.__failed && effVerdict(c) === 'PASS')
log(`QA corps · gatekeeper ${qa && qa.verdict} · ${QA_CORPS.map(([d]) => `${d}=${cv(d)}`).join(' · ')} · qaPass=${qaPass}`)

// ─────────── §2.6 BROWNFIELD UPGRADE: PROVE (non-regression) — before the terminal audit ───────────
// A brownfield upgrade ships only if it PROVES it did not regress the baseline: snapshot the after-state,
// compare every dimension to baseline.json, re-run the golden-master net, and record every intentional
// behavior change against a signed ADR. non-regression-gate.sh (HARD, ship-stage) verifies it independently.
if (brownfield) {
  await flushSpans('Validate')
  phase('Prove')
  emitSpan({ phase: 'Prove', model: 'opus', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
  await safeOne(() => dispatch(
    `WALTEUR PROVE (§2.6 brownfield non-regression). Project ${projectPath}. Read walteur-kit/baseline.json (the before-snapshot) and PROVE the upgrade did not regress it.\n` +
    `STEP 1 — re-measure EVERY baseline dimension AFTER the upgrade (same method, real numbers). Re-run the characterization/golden-master net — it MUST be green (observable behavior preserved).\n` +
    `STEP 2 — for EVERY intentional change to observable behavior, ensure a signed ADR exists under walteur-kit/adr/ and reference it (an unsigned behavior change is a silent break and FAILS the gate).\n` +
    `STEP 3 — Write ${projectPath}/walteur-kit/non-regression.json (validates against schemas/non-regression.schema.json): non_regression_version · proven_ts · baseline_ref:"walteur-kit/baseline.json" · dimensions[]{name,before,after} (after MUST be >= before, or carry a signed waiver_ref) · characterization{status:"green",...} · behavior_changes[]{change,adr_ref} · verdict. It MUST pass walteur-kit/hooks/non-regression-gate.sh — the HARD brownfield ship blocker.`,
    { label: 'prove:non-regression', model: 'opus', phase: 'Prove' }), 'prove:non-regression')
}

// ───────────────────────── AUDIT (terminal, fresh Opus) ─────────────────────────
await flushSpans('Validate')
phase('Audit')
emitSpan({ phase: 'Audit', model: 'opus', tool: 'agent', exit_code: '0', tokens: tokensSincePhase() })
const AUDIT_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['certified', 'is_best_achievable', 'shortfalls', 'veto_overrides', 'layer_walk', 'known_gaps', 'one_line'],
  properties: {
    certified: { type: 'boolean' }, is_best_achievable: { type: 'string' },
    shortfalls: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['what', 'severity', 'fix'],
      properties: { what: { type: 'string' }, severity: { type: 'string', enum: ['critical', 'major', 'minor'] }, fix: { type: 'string' } } } },
    veto_overrides: { type: 'array', description: 'ruling on each senior veto still open at the refine cap',
      items: { type: 'object', additionalProperties: false, required: ['veto', 'ruling', 'reason'],
        properties: { veto: { type: 'string' }, ruling: { type: 'string', enum: ['stale', 'addressed', 'still_blocking'] }, reason: { type: 'string' } } } },
    layer_walk: { type: 'string', description: 'one short line per APPLICABLE §14 production-reality layer (auth, data, rate-limit, errors, recovery, etc.): status + evidence; mark N/A for layers that do not apply to this stack' },
    known_gaps: { type: 'string' }, one_line: { type: 'string' },
  },
}
// S033 #6 — DEFERRAL PROTOCOL read-back. Mechanically read walteur-kit/deferrals.json (if the build wrote
// one per the TAIL_RULES / CRAFT prompts above) and count OPEN (unexpired) entries. Deferrals are HONEST,
// not failures — they never veto shippable; they are surfaced in the final summary/BATON so Tony can see
// exactly what was deferred and why, instead of a prose promise nothing verifies.
const DEFERRALS_SCHEMA = { type: 'object', additionalProperties: false, required: ['deferrals'], properties: { deferrals: { type: 'array', items: { type: 'object', additionalProperties: true, properties: { id: { type: 'string' }, what: { type: 'string' }, why_deferred: { type: 'string' }, needs: { type: 'string' }, expires: { type: 'string' }, ticket_text: { type: 'string' } } } } } }
const deferralsRead = await safeOne(() => dispatch(`WALTEUR deferral ledger read-back (S033 #6, mechanical — do not interpret). Using Bash \`cat ${projectPath}/walteur-kit/deferrals.json 2>/dev/null\`. If the file exists and parses as a JSON array, return {"deferrals": <that array>}. If absent/empty/unparseable, return {"deferrals": []}.`,
  { schema: DEFERRALS_SCHEMA, model: 'sonnet', label: 'deferrals:read', phase: 'Audit' }), 'deferrals:read')
const allDeferrals = (deferralsRead && !deferralsRead.__failed && Array.isArray(deferralsRead.deferrals)) ? deferralsRead.deferrals : []
const _nowTs = _NOW_MS // Workflow-safe: from args (Date.now() is forbidden). 0 => never expire (honest non-blocking default).
const isExpired = (d) => { if (!d || !d.expires || _nowTs <= 0) return false; const t = Date.parse(d.expires); return Number.isFinite(t) && t < _nowTs }
const deferredTools = allDeferrals.filter(d => !isExpired(d)) // OPEN deferrals (honest, non-blocking)
if (allDeferrals.length) log(`v10.2 #6 · deferral ledger: ${deferredTools.length} open / ${allDeferrals.length} total (honest, non-blocking) — walteur-kit/deferrals.json`)

const openVetoes = vetoes(panel).flatMap(v => (v.blocking_issues || []).map(i => `[${v.senior}] ${i}`))
// S033 #4 — RE-AUDIT AFTER CORRECTIVE REFINE (figure-it-out C1 fix). runTerminalAudit() is the auditor
// invocation extracted into a reusable closure so it can be called a SECOND time after the corrective
// refine pass fixes shortfalls. `audit` was previously `const`, so the corrective branch could fix the
// underlying issues but never re-derive a certified verdict — shippable (requires audit.certified) was
// predetermined false the instant the FIRST audit failed, even when the fix genuinely resolved everything.
// `label` distinguishes the two calls' safeOne failure bookkeeping without changing behavior for the
// (overwhelmingly common) case where only one audit ever runs.
const runTerminalAudit = (label) => safeOne(fb => dispatch(
  `You are the WALTEUR final auditor (Opus, fresh eyes) — the TERMINAL authority. Project ${projectPath}, goal "${idea}", scope ${JSON.stringify(scope)}. Re-derive evidence: re-run the tests yourself, read the code + README, walk the production-reality layers for this stack, judge whether this is the BEST ACHIEVABLE realization — complete, tested, honestly shippable — OR list line-by-line exactly what is short.\n` +
  (openVetoes.length
    ? `The refine loop hit its cap with these senior vetoes STILL OPEN — having checked the actual code/tests yourself, rule on EACH (stale | addressed | still_blocking) with a reason in veto_overrides. If ANY is genuinely still_blocking, you MUST NOT certify:\n- ${openVetoes.join('\n- ')}\n`
    : `No open senior vetoes (veto_overrides = []).\n`) +
  `COMPLETENESS + SECURITY (fix #7): read walteur-kit/integration-proof-report.json, measured-quality-report.json, test-layer-coverage-report.json, skill-readiness-report.json, and security-baseline-report.json if present; record any FAIL verdict as a CRITICAL shortfall — a silent mock, unmeasured a11y/perf, an unexecuted test layer, a routed-but-unstamped skill, or an unaddressed security-baseline check (RLS, OWASP, headers, rate limits, leaks...) is launch-blocking.\n` +
  `${CRAFT_REVIEW} Any such slop or happy-path-only path in a shipping file is a CRITICAL shortfall, not minor — also read walteur-kit/anti-slop-code-report.json + design-depth-report.json if present and record a FAIL as a CRITICAL shortfall.\n` +
  `FRESHNESS (scan-the-latest-before-done): the build MUST use the current best as of ${reality.as_of} — "${reality.current_best}". ${reality.stale_warnings.length ? 'It must contain NONE of these now-stale/deprecated choices: ' + reality.stale_warnings.join('; ') + '. ' : ''}If the build shipped a stale, deprecated, or superseded library/pattern/version, record it as a shortfall with the current-best replacement. Briefly note whether a materially better current approach was missed.\n` +
  `certified=true ONLY if: no critical/major shortfalls, you reproduced passing tests, AND no open veto is still_blocking. Don't rubber-stamp.` + skillInjectFor('Audit'),
  { schema: AUDIT_SCHEMA, model: fb ? 'sonnet' : 'opus', phase: 'Audit' }
), label)
let audit = await runTerminalAudit('audit:terminal')
// A3 — if the terminal auditor itself failed, it is NOT certified (sentinel has no .certified).
if (audit.__failed) { audit.certified = false; audit.shortfalls = [{ what: 'terminal auditor failed to run', severity: 'critical', fix: 're-run /audit' }]; audit.layer_walk = audit.layer_walk || 'N/A (auditor failed)'; audit.veto_overrides = audit.veto_overrides || [] }
if (!audit.certified && (audit.shortfalls || []).some(s => s.severity !== 'minor') && budgetGuard()) {
  await flushSpans('Audit')
  phase('Refine')
  emitSpan({ phase: 'Refine', model: 'opus', tool: 'refine', exit_code: '0', gate_verdict: 'corrective' })
  log('audit not certified — one corrective refine pass')
  await safeOne(() => dispatch(`WALTEUR corrective refine. Working dir ${projectPath}. Fix these audit shortfalls (root cause), re-run tests:\n- ${(audit.shortfalls || []).map(s => `(${s.severity}) ${s.what} -> ${s.fix}`).join('\n- ')}`,
    { label: 'refine:audit', model: 'opus', phase: 'Refine' }), 'refine:audit')
  await flushSpans('Refine')
  phase('Audit')
  emitSpan({ phase: 'Audit', model: 'opus', tool: 'agent', exit_code: '0', gate_verdict: 'post-corrective' })
  // S033 #4 — the SECOND verdict decides shippable. Bounded to EXACTLY one re-audit (this `if` is not a
  // loop — there is no path back to this branch after reassigning `audit`), so a still-uncertified build
  // after the re-audit falls through honestly to shippable=false, never ping-pongs.
  log('post-corrective re-audit: re-invoking terminal auditor once (bounded, decides shippable)')
  const reaudit = await runTerminalAudit('audit:terminal:post-corrective')
  if (reaudit.__failed) { reaudit.certified = false; reaudit.shortfalls = [{ what: 'post-corrective terminal auditor failed to run', severity: 'critical', fix: 're-run /audit' }]; reaudit.layer_walk = reaudit.layer_walk || audit.layer_walk || 'N/A (auditor failed)'; reaudit.veto_overrides = reaudit.veto_overrides || [] }
  audit = reaudit // the SECOND verdict is now authoritative for dims/shippable below
  log(`post-corrective re-audit: certified=${audit.certified}`)
}

// ── PERSONA ENGAGEMENT BREADCRUMBS (Tony's org model). Map the governance phases that actually ran onto the
//    named 68-role roster so persona-coverage-gate goes LIVE + HONEST: persona-breadcrumbs.sh writes a
//    breadcrumb only when a persona's phase evidence exists (PLAN.md / SUMMARY.jsonl / qa-report / audit.json /
//    red-flag-register), conditioned on the build signals. A skipped phase or unengaged required role then
//    fails coverage. Cheap (haiku); no-ops cleanly if the emitter is absent from the scaffold. ──
await safeOne(() => dispatch(`WALTEUR persona engagement breadcrumbs. Using Bash, run EXACTLY:\n\`g="${projectPath}/walteur-kit/hooks/persona-breadcrumbs.sh"; if [ -f "$g" ]; then WALTEUR_ROOT="${projectPath}" bash "$g"; else echo "persona-breadcrumbs emitter not in scaffold (skip)"; fi\`\nReport the line it prints.`,
  { label: 'persona:breadcrumbs', model: 'haiku', phase: 'Audit' }), 'persona:breadcrumbs')

// A1 — EVIDENCE: re-derive the certificate from CAPTURED signals, not an LLM boolean. A low-interpretation
// agent re-runs the recorded test command and reports the REAL exit code + commit SHA + a stdout tail.
const testCmd = (qa && !qa.__failed && qa.test_command) || ''
const EVID_SCHEMA = { type: 'object', additionalProperties: false, required: ['ran', 'exit_code', 'commit_sha', 'tail'],
  properties: { ran: { type: 'boolean' }, exit_code: { type: 'number' }, commit_sha: { type: 'string' }, tail: { type: 'string' } } }
const evidence = testCmd
  ? await safeOne(() => dispatch(`Mechanical evidence collector — do NOT fix or interpret anything. In ${projectPath}: (1) \`git rev-parse --short HEAD 2>/dev/null\` for commit_sha; (2) run EXACTLY this command and capture its real integer exit code: ${testCmd} ; (3) report ran=true, the integer exit_code, commit_sha, and the last ~15 output lines as tail. If it can't run at all: ran=false, exit_code=-1.`,
      { schema: EVID_SCHEMA, model: 'sonnet', label: 'evidence:rerun', phase: 'Audit' }), 'evidence:rerun')
  : { ran: false, exit_code: -1, commit_sha: '', tail: 'no recorded test command' }
const testsReproduced = !!(evidence && !evidence.__failed && evidence.ran && evidence.exit_code === 0)

// A1 — COMPOSITE computed IN CODE from real signals (never a single audit boolean dressed as a score). Each dimension is
// a captured fact; the composite is their blend; the security floor is real. A re-run exit 0 is the
// strongest evidence; any dropped/failed worker (A3) tanks the failures dimension and blocks ship.
const panelPass = ok(panel).filter(v => v.verdict === 'PASS').length
const secVeto = ok(panel).some(v => /Security/i.test(v.senior || '') && v.verdict === 'VETO')
const buildPass = ok(build).filter(b => b.tests_pass).length
const buildTotal = plan.tasks.length
// S033 #7 — split failures[] by classifyFailure() BEFORE it decides anything. A worker/build/test failure
// (product) still vetoes the failures dimension + shippable, exactly as before; a telemetry-flush/ledger-
// write/checkpoint hiccup (infra) no longer sinks a real one-shot — it is logged loudly instead (never
// silently dropped: still visible in worker_failures / the BATON, just not launch-blocking).
const productFailures = failures.filter(f => classifyFailure(f && f.label) === 'product')
const infraFailures = failures.filter(f => classifyFailure(f && f.label) === 'infra')
if (infraFailures.length) log(`⚠️  S033 #7 · ${infraFailures.length} INFRA failure(s) recorded (non-blocking, never silently dropped): ${infraFailures.map(f => f.label).join(', ')}`)
const dims = {
  tests:    testsReproduced ? 10 : (qaPass ? 6 : 2),
  qa:       qaPass ? 10 : 3,
  panel:    SENIORS.length ? +(10 * panelPass / SENIORS.length).toFixed(1) : 5,
  build:    buildTotal ? +(10 * buildPass / buildTotal).toFixed(1) : 5,
  audit:    audit.certified ? 10 : 5,
  failures: productFailures.length === 0 ? 10 : 2,
  security: secVeto ? 2 : (testsReproduced ? 9 : 7),
}
const TARGET = 8.5
const composite = +(Object.values(dims).reduce((a, b) => a + b, 0) / Object.keys(dims).length).toFixed(1)
const securityFloor = dims.security
const evidenceBundle = { tests_reproduced: testsReproduced, test_command: testCmd, exit_code: (evidence && evidence.exit_code), commit_sha: (evidence && evidence.commit_sha) || '', tail: ((evidence && evidence.tail) || '').slice(0, 800) }

// A1 — SHIPPABLE now requires INDEPENDENT, re-derived evidence: a real green test re-run, zero dropped
// PRODUCT workers (S033 #7 — infra hiccups no longer veto), the computed composite at/above target, and
// the security floor — not just two LLM booleans.
const shippable = audit.certified && qaPass && testsReproduced && productFailures.length === 0 && composite >= TARGET && securityFloor >= 8
log(`certificate · composite ${composite}/${TARGET} · tests_reproduced=${testsReproduced} (exit ${evidenceBundle.exit_code}) · product_failures ${productFailures.length} (infra ${infraFailures.length}, non-blocking) · security ${securityFloor} · SHIPPABLE=${shippable}`)

// §2a HITL gate — SEAM 3 · POST-AUDIT checkpoint (v9.2 #9 registry). OFF by default (full_autopilot). When
// pause_at_plan_and_audit: halts before writing gate files + DoD until a human places walteur-kit/APPROVED.
if (!(await requireApproval('SHIP', `Audit ${audit.certified ? 'CERTIFIED' : 'NOT certified'}; composite ${composite}/${TARGET}; shippable=${shippable}. Approve to finalize.`))) {
  log('⏸ PAUSED for human approval before SHIP. Review the audit, write walteur-kit/APPROVED, then re-run /goal to resume.')
  return { paused: true, gate: 'SHIP' }
}

// EMIT GATE FILES — write the engine's verdicts into the project's walteur-kit/ so a walteur-equipped
// project's HARD ship-gate validates THIS autopilot build, not stale committed stubs. The composite the
// ship-gate reads is now the JS-computed, evidence-anchored value above.
const qaReportJson = JSON.stringify({ verdict: qaPass ? 'PASS' : 'VETO',
  unit_integration: { verdict: (qa && !qa.__failed && qa.verdict) || 'VETO', recorded_command: testCmd },
  e2e: { verdict: cv('Functional') }, performance: { verdict: 'WAIVED' },
  accessibility: { verdict: cv('UX-Resilience') }, resilience: { verdict: cv('UX-Resilience') },
  logic: { verdict: cv('Logic-Correctness') }, security: { verdict: cv('Security'), advisory_demotions: securityDemotions, reprosecuted: secVetoed },
  data_integrity: { verdict: cv('Data-Integrity') }, integration: { verdict: cv('Integration') } })
const auditJsonStr = JSON.stringify({ certified: audit.certified, model: 'opus', shortfalls: audit.shortfalls || [], layer_walk: audit.layer_walk || '', evidence: evidenceBundle })
// test-claim.json — the kit-consumable re-runnable claim (S030 wiring fix). The engine's own re-run already
// proved the suite (testsReproduced + testCmd + observed exit); without THIS file the kit's HARD
// test-claim-verifier-gate can't consume it when the top-level qa verdict is VETO'd by N/A dimensions
// (a CLI has no accessibility surface), so execution-ratio honestly FAILed the engine's own build.
// Emitted ONLY when the suite genuinely reproduced — never a false claim.
const testClaimJson = (testsReproduced && testCmd) ? JSON.stringify({ tests_pass: true, command: testCmd, source: 'engine re-run (evidenceBundle)', observed_exit: (evidence && evidence.exit_code) || 0 }) : ''
if (_refineHistory.length) _refineHistory[_refineHistory.length - 1].composite = composite // final round carries the computed score
const scoreboardJson = JSON.stringify({ target: TARGET, composite, dims, floors: { security: 8, security_actual: securityFloor }, refine_max: maxRefine, refine_history: _refineHistory, evidence: evidenceBundle, note: 'composite computed in code from captured signals (re-run exit code, qa, panel, build, audit, failures) — NOT an LLM boolean; refine_history feeds excellence-loop-gate (v10.20 plateau law)' })
const dodMd = '# Definition of Done\n' + ((plan.definition_of_done || []).map(d => '- [' + (shippable ? 'x' : ' ') + '] ' + d).join('\n') || '- [' + (shippable ? 'x' : ' ') + '] build complete + tests pass')
await safeOne(() => dispatch(
  `Using Bash \`mkdir -p ${projectPath}/walteur-kit/debate\`, then use the Write tool to create these ${testClaimJson ? 'SIX' : 'FIVE'} files with EXACTLY this content (verbatim):\n${projectPath}/walteur-kit/qa-report.json:\n${qaReportJson}\n\n${projectPath}/walteur-kit/audit.json:\n${auditJsonStr}\n\n${projectPath}/walteur-kit/scoreboard.json:\n${scoreboardJson}\n\n${projectPath}/walteur-kit/DEFINITION-OF-DONE.md:\n${dodMd}\n\n${projectPath}/walteur-kit/debate/OPEN.json:\n[]\n\n${testClaimJson ? `${projectPath}/walteur-kit/test-claim.json:\n${testClaimJson}\n\n` : ''}THEN read-back-assert: run \`jq . ${projectPath}/walteur-kit/qa-report.json ${projectPath}/walteur-kit/audit.json ${projectPath}/walteur-kit/scoreboard.json ${projectPath}/walteur-kit/debate/OPEN.json${testClaimJson ? ` ${projectPath}/walteur-kit/test-claim.json` : ''}\` — if ANY file fails to parse, rewrite it correctly and re-check. Report which parsed.`,
  { label: 'emit-gates', model: 'sonnet', phase: 'Audit' }), 'emit-gates')

// CODIFY — durable cross-model handoff: a checkpoint (BATON) + the attack queue (ISSUES) written
// into the project's _relay/ so ANY model (or a later run) resumes exactly where this left off.
const issues = []
build.filter(b => b.status === 'BLOCKED' || !b.tests_pass).forEach(b => issues.push({ src: 'build', sev: 'major', text: `task T${b.id} ${b.status}${b.tests_pass ? '' : ' (tests not passing)'}` }))
vetoes(panel).forEach(v => (v.blocking_issues || []).forEach(i => issues.push({ src: 'panel', sev: 'major', text: `${v.senior}: ${i}` })))
;((qa && qa.verdict === 'VETO' && qa.gaps) || []).forEach(g => issues.push({ src: 'qa', sev: 'major', text: g }))
;(audit.shortfalls || []).forEach(s => issues.push({ src: 'audit', sev: s.severity, text: `${s.what} -> fix: ${s.fix}` }))
// v9.2 quick win — order the codified findings by BLAST RADIUS (data-corruption > lost-writes >
// security-exposure > degraded-UX > cosmetic) so the worst-consequence items read first. Presentation
// only: blocking (shippable/composite/security floor) was decided earlier and is untouched by this sort.
const sortedIssues = sortByBlastRadius(issues)
const rows = sortedIssues.length
  ? sortedIssues.map((x, n) => `| ${n + 1} | ${x.src} | ${x.sev} | ${x.blast_radius} | ${x.text.replace(/\n/g, ' ').replace(/\|/g, '/').slice(0, 200)} | fix, then re-run /goal |`).join('\n')
  : '| — | — | — | — | (none — clean) | — |'
const finalBaton = `# BATON — ${idea.slice(0, 70).replace(/\n/g, ' ')}\n**Status:** ${shippable ? 'DONE · shippable (audit certified, tests green)' : 'STALLED · see _relay/ISSUES.md'}   **Project:** ${projectPath}\n## Done (verified)\n- ${build.filter(b => b.tests_pass).length}/${build.length} build tasks with passing tests (of ${plan.tasks.length} planned)\n- Panel ${panel.filter(v => v.verdict === 'PASS').length}/${panel.length} PASS · QA ${qa && qa.verdict} · Audit certified: ${audit.certified}\n${infraFailures.length ? `## Infra failures (non-blocking, S033 #7 — logged honestly, did NOT veto shippable)\n${infraFailures.map(f => `- ${f.label}`).join('\n')}\n` : ''}${deferredTools.length ? `## Deferred (S033 #6 — honest, non-blocking; not failures)\n${deferredTools.map(d => `- [${d.id || '?'}] ${d.what || '?'} — ${d.why_deferred || 'no reason given'} (needs: ${d.needs || '?'})`).join('\n')}\n` : ''}## Blockers / open (also in ISSUES.md — ordered worst-blast-radius first)\n${sortedIssues.length ? sortedIssues.map(x => `- [${x.src}/${x.sev}/${x.blast_radius}] ${x.text}`).join('\n') : '- none'}\n## Next steps (in order)\n${shippable ? `1. Ship ${projectPath} (publish/deploy per its README).` : '1. Work _relay/ISSUES.md (worst blast radius first).\n2. Re-run /goal (or /walteur) — it resumes the lifecycle and re-verifies.'}\n## Context (absolute paths)\n- product: ${projectPath} · plan: ${projectPath}/PLAN.md · engine: .claude/workflows/walteur.js · assumptions ledger: ${projectPath}/walteur-kit/assumptions.json (${assumptionLedger.assumptions.length} decided-not-asked assumption(s), S033 #5)\n---\n_Any model: read this + _relay/ISSUES.md + PLAN.md, then continue. No prior chat needed._`
const finalIssues = `# Attack queue — ${idea.slice(0, 70).replace(/\n/g, ' ')}\n> Read at every build-session start. Found-but-unfixed lives here; fixed graduates to Lessons.md. Ordered by blast radius (worst-consequence first).\n\n| id | source | severity | blast radius | symptom | next action |\n|----|--------|----------|--------------|---------|-------------|\n${rows}`
await dispatch(
  `Use Bash to \`mkdir -p ${projectPath}/_relay\`. Then use the Write tool to create THREE files with EXACTLY the content given (verbatim — do not reformat, summarize, or omit):\n\n=== FILE ${projectPath}/_relay/BATON.md ===\n${finalBaton}\n\n=== FILE ${projectPath}/_relay/ISSUES.md ===\n${finalIssues}\n\n=== FILE ${projectPath}/_relay/receipt.json ===\n${JSON.stringify({ est_usd: estUsd(), ceiling_usd: MAX_USD, shippable, issues: issues.length, note: 'estimate from turn-wide output tokens; conservative, not an invoice', token_reconciliation: { actual_tokens: (haveBudget && budget.spent) ? Math.max(0, budget.spent() - _spentAtStart) : 0, estimated_tokens_range: estimate.tokens, source: haveBudget ? 'budget.spent() delta (harness-metered)' : 'no budget object in this harness — 0 (never fabricated)' } })}\n\nFinally append "$(date '+%Y-%m-%dT%H:%M') · ${shippable ? 'DONE' : 'STALLED'} · codified ${issues.length} issue(s)" as a new line to ${projectPath}/_relay/log.md.`,
  { label: 'codify:handoff', model: 'sonnet', phase: 'Audit' }
)

// CONSOLIDATE ("dreaming") — append GENERALIZABLE lessons from this build to the cross-build memory
// (~/.walteur/memory/lessons.jsonl) so future builds get smarter. Conservative (Opus); the eval
// (walteur-kit/eval) is the regression detector that catches a bad lesson.
await dispatch(
  `You are the WALTEUR consolidation ("dreaming") agent. Build of "${idea}" (${scope.domain}/${scope.stack}) finished: shippable=${shippable}, refine_cycles=${refineIter}, audit_certified=${audit.certified}.\nIssues this run:\n${issues.length ? issues.map(x => `- [${x.src}] ${x.text}`).join('\n') : '- none'}\nAudit shortfalls: ${JSON.stringify((audit.shortfalls || []).map(s => s.what)).slice(0, 1400)}\n\nExtract ONLY GENERALIZABLE, evidence-backed lessons (a real failure mode + how to avoid it) useful to FUTURE builds — NOT project-specific noise, NOT platitudes. Be conservative: 0-3 lessons; if nothing genuinely generalizable, add NOTHING.\nFor EACH candidate lesson, write the JSON {"ts":"<today>","domain":"${scope.domain}","stack":"${scope.stack}","lesson":"<avoid/do X>","why":"<evidence>","source":"${idea.slice(0, 45).replace(/"/g, "'")}","confidence":"high|med"} and QUALITY-GATE it through the memory gate so a bad/duplicate lesson can't compound: if \`walteur-kit/memory/lesson-gate.sh\` exists, run \`echo '<json>' | bash walteur-kit/memory/lesson-gate.sh\` (it dedupes, holds contradictions in conflicts.jsonl, adds helpful/harmful counters, caps the store). If that script is not found, do the same by hand against ~/.walteur/memory/lessons.jsonl: \`mkdir -p ~/.walteur/memory\`; SKIP if an existing line means the same thing (case-insensitive); SKIP + append to ~/.walteur/memory/conflicts.jsonl if it directly contradicts a stored lesson; otherwise APPEND the line (with "helpful":0,"harmful":0). Never blindly append.`,
  { label: 'consolidate:dreaming', model: 'opus', phase: 'Audit' }
)

// SELF-OPTIMIZE — queue this build's OUTCOME so the lessons it APPLIED get scored (helpful/harmful) and
// harmful ones auto-retire. Path-robust: just append to the pending queue; /optimize (or CI/SessionEnd)
// drains it via `walteur-kit/memory/lesson-feedback.sh --drain`. Closes the loop:
// recall → apply → MEASURE (this outcome) → ATTRIBUTE (scores the applied lessons) → PRUNE (retire harmful).
const appliedIds = (recall && !recall.__failed && recall.applied_ids) || []
if (appliedIds.length) {
  const outcomeRec = JSON.stringify({ applied_ids: appliedIds, shippable, composite, target: TARGET, refine_cycles: refineIter }).replace(/'/g, '')
  await safeOne(() => dispatch(`Using Bash: \`mkdir -p ~/.walteur/memory && printf '%s\\n' '${outcomeRec}' >> ~/.walteur/memory/pending-feedback.jsonl\` — this QUEUES the build outcome for the self-improvement loop (the applied lessons' helpful/harmful scores are updated when /optimize drains the queue). Report done.`,
    { label: 'self-optimize:queue', model: 'sonnet', phase: 'Audit' }), 'self-optimize:queue')
}

// S033 #9 — RUN-END TOKEN RECONCILIATION. Compare the sum of all per-phase span deltas (real, harness-
// metered budget.spent() deltas — see tokensSincePhase()) against (a) the pre-build estimate.json range and
// (b) the total budget.spent() delta for this build (estUsd()'s numerator). Emits ONE terminal span so
// run-trace.sh --rollup (which already sums the `tokens` field) becomes non-vacuous with zero hook changes,
// and writes the comparison into _relay/receipt.json below. Honest labeling: haveBudget=false means every
// per-phase delta was 0 (never fabricated) — the reconciliation says so explicitly, it does not pretend.
// NOTE the guard is `budget.spent` (what a meter reading actually needs), NOT haveBudget (which also
// requires .total for remaining()-based gating). Using haveBudget here could report delta 0 while
// meterStatus() said 'metered' off the same object — the two must agree or the reconcile lies.
const totalSpentDelta = (typeof budget !== 'undefined' && budget && budget.spent) ? Math.max(0, budget.spent() - _spentAtStart) : 0
// S038 #1 — A ZERO TOKEN COUNT IS A FINDING, NOT A FACT. Every field run of this engine reconciled
// tokens_actual:0 and emitted exit_code '0' anyway, so "the budget was enforced" was never observable. The
// terminal span now reports the METER, and a meter that reports nothing while ~N dispatches happened exits 2.
const meter = meterStatus()
const meterBroken = (meter === 'metered_zero') || (meter === 'idle' && _totalDispatches() > 0)
const reconcileNote = meter === 'metered'
  ? `budget.spent() delta (harness-metered, real) — expected range from estimate.json: ${estimate.tokens.min}-${estimate.tokens.max} (mid ${estimate.tokens.expected})`
  : meter === 'metered_zero'
    ? `BROKEN METER — a budget object exists but reported ZERO tokens across ${_totalDispatches()} dispatch(es). Per-phase deltas are 0 (never fabricated); the $ ceiling fell back to the dispatch-count estimate. This is a defect in the harness meter, not a free build.`
    : `NO harness token meter — per-phase deltas are 0 (never fabricated; see tokensSincePhase()). The $ ceiling was enforced instead off the REAL per-lane dispatch counter: ${_laneDispatches.opus} opus / ${_laneDispatches.sonnet} sonnet / ${_laneDispatches.haiku} haiku × ${UNMETERED_OUT_TOKENS_PER_DISPATCH} assumed output tokens = est $${estUsd()} of $${MAX_USD} (ESTIMATE from an observed counter, never an invoice).`
emitSpan({ phase: 'Audit', model: 'n/a', tool: 'reconcile', exit_code: meterBroken ? '2' : '0',
  gate_verdict: `tokens_actual:${totalSpentDelta}_vs_estimated_mid:${estimate.tokens.expected};meter:${meter};dispatches:${_totalDispatches()};est_usd:${estUsd()};ceiling_usd:${MAX_USD}${meterBroken ? ';BUDGET_METER_BROKEN:true' : ''}`, tokens: 0 })
log(`v10.2 #9 · token reconciliation: actual ${totalSpentDelta} vs estimated ${estimate.tokens.min}-${estimate.tokens.max} (mid ${estimate.tokens.expected}) · meter=${meter} · ${reconcileNote}`)
if (meterBroken) log(`BUDGET METER BROKEN — recorded as exit_code 2 in run-trace.jsonl. The $ ceiling ran on the fallback dispatch estimate; do NOT read this build's cost as measured.`)
if (_routingViolations.length) log(`ROUTING VIOLATIONS · ${_routingViolations.length} dispatch(es) requested a model routes[] does not permit for their phase: ${_routingViolations.map(v => `${v.phase}/${v.label}=${v.requested}`).join(', ')}`)

// A2 — final checkpoint so a re-run knows the build reached terminal state (DONE | STALLED).
await writeState({ phase: shippable ? 'DONE' : 'STALLED', completed_task_ids: [...completedIds] })
// v9.2 — final trace flush (catches any audit-phase spans not flushed by a corrective refine branch)
await flushSpans('Audit')

return {
  // v10.1 ULTIMATE — address the user by name in the headline summary (Tony's standing ask).
  message: `${userName !== 'there' ? userName + ', y' : 'Y'}our build of "${idea.slice(0, 60).replace(/\n/g, ' ')}" is ${shippable ? 'DONE and shippable' : 'NOT yet shippable'} — ${audit.certified ? 'audit certified' : 'audit found shortfalls'}, ${build.filter(b => b.tests_pass).length}/${build.length} tasks green, composite ${composite}/${TARGET}. ${shippable ? 'Ship it.' : 'See _relay/ISSUES.md.'}`,
  idea, projectPath, user: userName, mode: brownfield ? 'brownfield' : 'greenfield', domain: scope.domain,
  team: team.roster.map(r => `${r.role} (${r.kind})`),
  plan_tasks: plan.tasks.length, build_waves: w,
  build_summary: build.map(b => ({ id: b.id, status: b.status, tests_pass: b.tests_pass })),
  panel: panel.map(v => ({ senior: v.senior, verdict: v.verdict })),
  refine_cycles: refineIter,
  qa: { gatekeeper: qa && !qa.__failed && qa.verdict, fact_checks: ok(checks).map(c => c.verdict) },
  audit: { certified: audit.certified, shortfalls: audit.shortfalls, veto_overrides: audit.veto_overrides, layer_walk: audit.layer_walk, one_line: audit.one_line },
  SHIPPABLE: shippable, issues_codified: issues.length, relay: `${projectPath}/_relay/`,
  certificate: { composite, target: TARGET, dims, tests_reproduced: testsReproduced, security_floor: securityFloor, evidence: evidenceBundle },
  worker_failures: failures.length, worker_failures_product: productFailures.length, worker_failures_infra: infraFailures.length, // S033 #7
  estimate,  // pre-build token/time/cost RANGE (also emitted to walteur-kit/estimate.json) — a WALTEUR fundamental
  // S038 #1 — the cost block now names its SOURCE. `meter` is the honest provenance of est_usd
  // ('metered' | 'metered_zero' = broken harness meter | 'unmetered_dispatch_estimate' | 'idle'), `enforced`
  // says whether the ceiling had a real input to bite on, and lane_dispatches/price_usd_per_mtok_out expose
  // the per-lane arithmetic so the number can be audited instead of trusted.
  cost: { est_usd: estUsd(), ceiling_usd: MAX_USD, meter, enforced: _totalDispatches() > 0,
    meter_verdict: meterBroken ? 'FAIL_BROKEN_METER' : (meter === 'metered' ? 'PASS_METERED' : 'PASS_DISPATCH_ESTIMATE'),
    lane_dispatches: { ..._laneDispatches }, dispatches_total: _totalDispatches(),
    price_usd_per_mtok_out: PRICE_USD_PER_MTOK_OUT,
    unmetered_out_tokens_per_dispatch_assumed: UNMETERED_OUT_TOKENS_PER_DISPATCH,
    routing_violations: _routingViolations.length,
    note: meter === 'metered'
      ? 'metered output tokens priced at the lane-mix-weighted rate actually dispatched; conservative (input tokens not modeled), not an invoice'
      : 'NO harness token meter (or a meter reporting zero) — est_usd derived from the REAL per-lane dispatch counter × an assumed per-dispatch output size; an estimate from an observed counter, never an invoice' },
  recalled_lessons: recall ? recall.lessons.length : 0,
  known_gaps: audit.known_gaps,
  assumptions: { count: assumptionLedger.assumptions.length, path: `${projectPath}/walteur-kit/assumptions.json` }, // S033 #5
  deferrals_open: deferredTools ? deferredTools.length : 0, // S033 #6
}
