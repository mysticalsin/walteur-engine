#!/usr/bin/env node
// walteur-run.mjs — THIN STANDALONE RUNNER for walteur.js's OWN telemetry, ROUTING and BUDGET paths.
//
// S033 (engine-surgeon pass) created this runner to close the "no runnable proof of walteur.js" asymmetry.
// S038 (panel-12 orchestration pass) extends it from a telemetry replay into a real CONTROL-FLOW harness,
// because the panel's finding was correct about the old version: it extracted only
// MODEL_ROUTING_BY_PHASE/routingConformance/_spanQueue/emitSpan/flushSpans and then replayed 14 hand-written
// emitSpan() calls, so the engine's cost ceiling and its dispatch path had ZERO executed proof.
//
// ============================  HONESTY HEADER (read this first)  ============================
// WHAT THIS PROVES:  walteur.js (the orchestrator) cannot run standalone — it has a top-level
//   `return`, and it depends on harness-INJECTED globals (`agent`, `parallel`, `phase`, `log`,
//   `budget`, `args`). This runner stands those globals up as STUBS so the orchestrator's REAL
//   logging / model-routing / dispatch / budget PATH can execute end-to-end. Specifically it executes,
//   from the orchestrator's OWN source text:
//     · emitSpan/flushSpans      → the native per-phase run-trace.jsonl append (real bash, real file)
//     · routingConformance       → incl. the S038 'n/a means unchecked' fix (regression guard below)
//     · dispatch/dispatchConformance → the SINGLE dispatch choke point: mechanical-lane downgrade,
//                                  per-phase route conformance, retry-fallback allowance, lane counters
//     · estUsd/meterStatus/blendedRateUsdPerMtok/unmeteredEstUsd/overBudget → the $ ceiling arithmetic,
//                                  driven to the point where overBudget() ACTUALLY FIRES (scenario B)
//     · MIRROR-SYNC GATE          → MODEL_ROUTING_BY_PHASE and ALLOWED_MODELS_BY_PHASE are hand-maintained
//                                  copies of walteur-kit/model-routing.json. This runner DIFFS both
//                                  against that JSON and exits 1 on drift, so the copies cannot rot.
//
// WHAT THIS IS NOT:  a real autonomous build. Every `agent()` call here is STUBBED — it returns
//   a small canned object that is CLEARLY marked `__stub:true`. NO model runs, NO product code
//   is written, NO gate actually evaluates anything. Token counts in scenario A come from a STUB
//   counter and are labeled as such; scenario B deliberately runs with NO budget object at all,
//   which is exactly the condition every real field run ran under.
//
// FIDELITY:  none of the extracted logic is re-implemented here. It is SLICED VERBATIM from
//   walteur.js at runtime (read the file, cut the exact source text, eval it in a closure over the
//   stubs). If walteur.js's source changes, this runner picks the change up automatically — it cannot
//   silently drift from the real path. A failed slice ABORTS loudly (never a silent fallback copy).
//
// EXIT: 0 = every assertion held. 1 = a regression, a mirror drift, or a failed slice.
// ENV:  WALTEUR_JS_PATH / WALTEUR_ROUTING_JSON override the inputs (used to run negative controls
//       against a perturbed COPY in a temp dir — never against the repo).
// ===========================================================================================

import { readFileSync, mkdirSync, rmSync, existsSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join, resolve } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WALTEUR_JS = process.env.WALTEUR_JS_PATH ? resolve(process.env.WALTEUR_JS_PATH) : join(__dirname, 'walteur.js')
const ROUTING_JSON = process.env.WALTEUR_ROUTING_JSON
  ? resolve(process.env.WALTEUR_ROUTING_JSON)
  : resolve(__dirname, '..', '..', 'walteur-kit', 'model-routing.json')

// A scratch project dir so we never touch real build output. The native trace lands at
// <projectPath>/walteur-kit/run-trace.jsonl — exactly where the orchestrator writes it.
// IMPORTANT: forward slashes. projectPath is interpolated verbatim into the bash command that
// flushSpans builds, and bash treats backslashes as escapes — a Windows `C:\…` path would be mangled.
const projectPath = join(process.env.TEMP || '/tmp', 'walteur-run-trace-proof-procoding').replace(/\\/g, '/')
const tracePath = join(projectPath, 'walteur-kit', 'run-trace.jsonl')
// fresh start so the row count reflects THIS run only (honest count, no stale appends)
rmSync(projectPath, { recursive: true, force: true })
mkdirSync(join(projectPath, 'walteur-kit'), { recursive: true })

let FAILS = 0
function ok(cond, what) {
  if (cond) { log(`  ok   — ${what}`); return true }
  log(`  FAIL — ${what}`); FAILS++; return false
}

// ─────────────────────────  STUB HARNESS GLOBALS  ─────────────────────────
// phase() / log() are REAL (they just print) — same observable behavior as the harness.
let _phase = 'IDLE'
function phase(name) { _phase = name; log(`── phase: ${name} ──`) }
function log(msg) { console.log(`[walteur-run] ${msg}`) }

// budget — a simple counter (clearly a stub), but its spent()/remaining()/total shape is REAL — the
// same contract walteur.js reads. Scenario A wires this in; scenario B deliberately passes `undefined`
// so the engine runs the NO-METER path that every real field run actually ran.
function makeStubBudget() {
  let _spent = 0
  return { total: 10_000_000, spent: () => _spent, remaining: () => 10_000_000 - _spent, _bump: (n) => { _spent += n } }
}

// agent — THE STUB. Two behaviors:
//   (A) trace-flush calls: flushSpans() emits a prompt of the form
//         "WALTEUR run-trace flush … Using Bash, run EXACTLY:\n`<cmd>`\nReport done."
//       We extract <cmd> and ACTUALLY execute it (child_process) — this is the orchestrator's
//       OWN bash append command, run for real. This is the only place real I/O happens.
//   (B) every other call: return a small canned object, clearly tagged __stub.
let _agentCalls = 0
let _flushExecs = 0
let _seenModels = []
function makeAgent(bumpBudget) {
  return async function agent(prompt, opts = {}) {
    _agentCalls++
    _seenModels.push({ label: opts.label || '', model: opts.model, phase: opts.phase })
    if (bumpBudget) bumpBudget(1000) // pretend each agent "spent" some tokens — exercises the metered path
    const isTraceFlush = typeof prompt === 'string' && prompt.startsWith('WALTEUR run-trace flush')
    if (isTraceFlush) {
      const m = prompt.match(/Using Bash, run EXACTLY:\n`([\s\S]*?)`\nReport done\./)
      if (!m) throw new Error('trace-flush prompt did not match expected shape — emitSpan/flushSpans contract changed?')
      execSync(m[1], { stdio: 'pipe', shell: process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : '/bin/sh' })
      _flushExecs++
      return { __stub: true, ran: 'trace-flush', label: opts.label }
    }
    return { __stub: true, label: opts.label || 'stub', model: opts.model, phase: opts.phase }
  }
}

// safeOne — the orchestrator wraps flushes/dispatches in safeOne(thunk,label). We mirror the SAME
// contract INCLUDING the S038 retry-flag protocol (set the engine's _retryDispatch immediately before
// the synchronous thunk call, clear it right after) so the retry-fallback allowance is exercised for real.
const failures = []
function makeSafeOne(setRetry) {
  return async function safeOne(thunk, label) {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        setRetry(attempt > 0)
        const p = thunk(attempt > 0)
        setRetry(false)
        const r = await p
        if (r) return r
      } catch (e) { setRetry(false); log(`${label}: attempt ${attempt} error ${(e && e.message) || e}`) }
    }
    const s = { __failed: true, label, status: 'FAILED' }; failures.push(s); return s
  }
}

// ─────────────────  SLICE THE REAL SOURCE OUT OF walteur.js  ─────────────────
const src = readFileSync(WALTEUR_JS, 'utf8')

function declEnd(text, start) {
  // brace-matched declaration end. NOTE: the param list itself uses braces (destructured params like
  // `function emitSpan({ phase: ph, … })` / `function dispatch(prompt, opts = {})`), so we must FIRST
  // close the parameter parens `(...)`, THEN match the BODY braces — not the first `{` we see.
  const parenOpen = text.indexOf('(', start)
  let pdepth = 0, j = parenOpen
  for (; j < text.length; j++) {
    const c = text[j]
    if (c === '(') pdepth++
    else if (c === ')') { pdepth--; if (pdepth === 0) { j++; break } }
  }
  const braceOpen = text.indexOf('{', j) // first brace AFTER the param list = the body
  let depth = 0, i = braceOpen
  for (; i < text.length; i++) {
    const c = text[i]
    if (c === '{') depth++
    else if (c === '}') { depth--; if (depth === 0) { i++; break } }
  }
  return i
}
function sliceDecl(text, startMarker, kind) {
  const start = text.indexOf(startMarker)
  if (start === -1) throw new Error(`could not locate "${startMarker}" in ${WALTEUR_JS}`)
  if (kind === 'const-line') return text.slice(start, text.indexOf('\n', start))
  return text.slice(start, declEnd(text, start))
}
// sliceRegion — a CONTIGUOUS span of real source from startMarker through the end of the declaration
// that begins at endMarker. Used for the cost block and the routing/dispatch block, both of which are
// several interdependent declarations in a row; slicing the region keeps them byte-identical together.
function sliceRegion(text, startMarker, endMarker) {
  const start = text.indexOf(startMarker)
  if (start === -1) throw new Error(`could not locate region start "${startMarker}" in ${WALTEUR_JS}`)
  const endStart = text.indexOf(endMarker, start)
  if (endStart === -1) throw new Error(`could not locate region end "${endMarker}" in ${WALTEUR_JS}`)
  return text.slice(start, declEnd(text, endStart))
}

// COST region: PRICE_USD_PER_MTOK_OUT … estUsd()  (per-lane pricing, lane counters, meterStatus, estUsd)
const costRegionSrc = sliceRegion(src, 'const PRICE_USD_PER_MTOK_OUT =', 'const estUsd = () =>')
// ROUTING+DISPATCH region: MODEL_ROUTING_BY_PHASE … dispatch()  (incl. both inline assertion IIFEs,
// which therefore EXECUTE here — the engine's own contract checks run inside this harness)
const routingRegionSrc = sliceRegion(src, 'const MODEL_ROUTING_BY_PHASE = {', 'function dispatch(')
const spanQueueSrc = sliceDecl(src, 'const _spanQueue = []', 'const-line')
const emitSpanSrc = sliceDecl(src, 'function emitSpan(', 'fn')
const flushSpansSrc = sliceDecl(src, 'async function flushSpans(', 'fn')
const overBudgetSrc = sliceDecl(src, 'function overBudget(', 'fn')

log(`walteur.js         : ${WALTEUR_JS}`)
log(`model-routing.json : ${ROUTING_JSON}`)
log('sliced REAL source from walteur.js:')
log(`  cost region     : ${costRegionSrc.split('\n').length} lines (PRICE_USD_PER_MTOK_OUT … estUsd)`)
log(`  routing region  : ${routingRegionSrc.split('\n').length} lines (MODEL_ROUTING_BY_PHASE … dispatch)`)
log(`  overBudget      : ${overBudgetSrc.trim()}`)
log(`  emitSpan        : ${emitSpanSrc.split('\n').length} lines · flushSpans: ${flushSpansSrc.split('\n').length} lines`)

// wireEngine — eval the sliced source in a closure over the stubs. `budgetObj === undefined` reproduces
// the real field-run condition (no harness meter at all).
function wireEngine(budgetObj) {
  const spentAtStart = (budgetObj && budgetObj.spent) ? budgetObj.spent() : 0
  const holder = { set: () => {} }
  const agentImpl = makeAgent(budgetObj ? (n) => budgetObj._bump(n) : null)
  const safeOneImpl = makeSafeOne((v) => holder.set(v))
  const f = new Function(
    'process', 'projectPath', 'safeOne', 'agent', 'log', 'budget', '_spentAtStart',
    `${costRegionSrc}\n${routingRegionSrc}\n${spanQueueSrc};\n${emitSpanSrc}\n${flushSpansSrc}\n${overBudgetSrc}\n` +
    `return { emitSpan, flushSpans, _spanQueue, routingConformance, MODEL_ROUTING_BY_PHASE, ALLOWED_MODELS_BY_PHASE,` +
    ` MECHANICAL_LABEL_RE, dispatchConformance, dispatch, _routingViolations, _laneDispatches, _totalDispatches,` +
    ` estUsd, meterStatus, blendedRateUsdPerMtok, unmeteredEstUsd, overBudget, PRICE_USD_PER_MTOK_OUT,` +
    ` UNMETERED_OUT_TOKENS_PER_DISPATCH, setRetry: (v) => { _retryDispatch = v } };`
  )
  const eng = f(process, projectPath, safeOneImpl, agentImpl, log, budgetObj, spentAtStart)
  holder.set = eng.setRetry
  eng.safeOne = safeOneImpl
  return eng
}

// ─────────────────  GATE 0a — NO DISPATCH MAY BYPASS THE CHOKE POINT  ─────────────────
// dispatch() is only a real control point if EVERY call site goes through it. A future edit that writes
// `await agent(...)` again would silently escape the lane counters (breaking the $ ceiling) and the
// conformance check. This is the static guard: in walteur.js there must be exactly ONE raw agent() call —
// the one INSIDE dispatch() itself.
function chokePointGate() {
  log('')
  log('=== GATE 0a · every agent() dispatch goes through dispatch() ===')
  const bypasses = (src.match(/(?:=>|await)\s+agent\(/g) || []).length
  const viaDispatch = (src.match(/(?:=>|await)\s+dispatch\(/g) || []).length
  const rawInsideDispatch = (src.match(/return agent\(prompt,/g) || []).length
  ok(bypasses === 0, `no '=> agent(' / 'await agent(' bypass remains in walteur.js (found ${bypasses}, want 0)`)
  ok(viaDispatch > 50, `${viaDispatch} dispatch sites route through the choke point`)
  ok(rawInsideDispatch === 1, `exactly 1 raw agent() call, inside dispatch() itself (found ${rawInsideDispatch})`)
}

// ─────────────────  GATE 0 — MIRROR SYNC vs walteur-kit/model-routing.json  ─────────────────
// walteur.js has no `fs`, so its routing tables are hand-maintained MIRRORS of the JSON. Nothing used to
// prevent drift. This is the gate that closes it: comparison of both mirrors against the JSON's own
// .by_phase and .routes[], exiting 1 on any disagreement.
function mirrorSyncGate(eng) {
  log('')
  log('=== GATE 0 · routing mirror sync (walteur.js tables vs walteur-kit/model-routing.json) ===')
  if (!existsSync(ROUTING_JSON)) { log(`  FAIL — model-routing.json not found at ${ROUTING_JSON}`); FAILS++; return }
  const rj = JSON.parse(readFileSync(ROUTING_JSON, 'utf8'))
  const byPhase = rj.by_phase || {}
  const mirror = eng.MODEL_ROUTING_BY_PHASE
  const jKeys = Object.keys(byPhase).sort(), mKeys = Object.keys(mirror).sort()
  ok(jKeys.join(',') === mKeys.join(','), `by_phase mirror has the same phases (js=${mKeys.length}) as the JSON (json=${jKeys.length})`)
  const badPrimary = jKeys.filter(k => byPhase[k] !== mirror[k])
  ok(badPrimary.length === 0, `by_phase mirror primary models all agree with the JSON${badPrimary.length ? ` — DRIFT on: ${badPrimary.map(k => `${k}(json=${byPhase[k]},js=${mirror[k]})`).join(', ')}` : ''}`)
  // ALLOWED_MODELS_BY_PHASE must be exactly the set of models routes[] permits per phase.
  const derived = {}
  for (const r of (rj.routes || [])) {
    if (!r.phase || !r.model) continue
    derived[r.phase] = derived[r.phase] || new Set()
    derived[r.phase].add(r.model)
    if (r.converge_with) derived[r.phase].add(r.converge_with)
  }
  const allowed = eng.ALLOWED_MODELS_BY_PHASE
  const dKeys = Object.keys(derived).sort(), aKeys = Object.keys(allowed).sort()
  ok(dKeys.join(',') === aKeys.join(','), `ALLOWED_MODELS_BY_PHASE covers exactly the phases routes[] declares (js=${aKeys.length}, json=${dKeys.length})`)
  const badAllowed = dKeys.filter(k => {
    const want = [...(derived[k] || [])].sort().join('|')
    const got = [...(allowed[k] || [])].sort().join('|')
    return want !== got
  })
  ok(badAllowed.length === 0, `ALLOWED_MODELS_BY_PHASE equals the routes[]-derived model sets${badAllowed.length ? ` — DRIFT on: ${badAllowed.map(k => `${k}(json=${[...derived[k]].sort().join('|')},js=${(allowed[k] || []).slice().sort().join('|')})`).join(', ')}` : ''}`)
  // the mechanical lane, the retry fallback tier and the default model must match the JSON, not stale literals
  ok(eng.MECHANICAL_LABEL_RE instanceof RegExp && (rj.lanes || {}).mechanical === 'haiku',
    `lanes.mechanical is 'haiku' in the JSON and the engine has a mechanical-label allowlist`)
  ok((rj.fallback_policy || {}).on_retry === 'sonnet', `fallback_policy.on_retry is 'sonnet' (the tier dispatchConformance permits on a retry)`)
  ok(String(rj.default_model || '') === 'sonnet', `default_model is 'sonnet' (dispatch()'s fallback when a call site omits model)`)
}

// ─────────────────  SCENARIO A — METERED RUN + telemetry + the 'n/a' false-positive fix  ─────────────────
async function scenarioA() {
  log('')
  log('=== SCENARIO A · metered run: real emitSpan/flushSpans + routing conformance ===')
  const eng = wireEngine(makeStubBudget())
  const { emitSpan, flushSpans } = eng

  phase('Self-Heal'); emitSpan({ phase: 'Self-Heal', model: 'sonnet', tool: 'Bash', exit_code: '0', tokens: 500 })
  await flushSpans('Self-Heal')
  phase('Scope'); emitSpan({ phase: 'Scope', model: 'opus', tool: 'agent', exit_code: '0', tokens: 1200 })
  await flushSpans('Scope')
  phase('Think'); emitSpan({ phase: 'Think', model: 'opus', tool: 'agent', exit_code: '0', tokens: 3000 })
  await flushSpans('Think')
  phase('Plan'); emitSpan({ phase: 'Plan', model: 'opus', tool: 'agent', exit_code: '0', tokens: 2500 })
  await flushSpans('Plan')
  phase('Build'); emitSpan({ phase: 'Build', model: 'sonnet', tool: 'parallel', exit_code: '0', tokens: 8000 })
  await flushSpans('Build')
  phase('Review'); emitSpan({ phase: 'Review', model: 'opus', tool: 'agent', exit_code: '0', tokens: 2200 })
  await flushSpans('Review')
  phase('Refine'); emitSpan({ phase: 'Refine', model: 'opus', tool: 'refine', exit_code: '0', gate_verdict: 'iter:1', tokens: 1500 })
  await flushSpans('Refine')
  phase('Validate'); emitSpan({ phase: 'Validate', model: 'opus', tool: 'agent', exit_code: '0', tokens: 2100 })
  await flushSpans('Validate')

  phase('Audit')
  emitSpan({ phase: 'Audit', model: 'opus', tool: 'agent', exit_code: '0', tokens: 1800 })
  // S038 #2 REGRESSION GUARD — the TERMINAL RECONCILE span, verbatim in shape from walteur.js's run-end
  // reconciliation: model 'n/a' (emitSpan's own "no model" default). Before the fix this row reported
  // routing_mismatch:true on EVERY real run — a built-in false positive that made routing_mismatch
  // un-gateable. It must now be CLEAN.
  emitSpan({ phase: 'Audit', model: 'n/a', tool: 'reconcile', exit_code: '0', gate_verdict: 'tokens_actual:0_vs_estimated_mid:2115000;meter:metered_zero', tokens: 0 })
  // NEGATIVE CONTROL — Audit is opus-non-negotiable; requesting 'sonnet' MUST fold routing_mismatch:true
  // into the written gate_verdict. If routingConformance ever regresses to a no-op this row goes clean and
  // the proof is void.
  emitSpan({ phase: 'Audit', model: 'sonnet', tool: 'agent', exit_code: '0', gate_verdict: 'NEGATIVE-CONTROL-poisoned-model', tokens: 0 })
  await flushSpans('Audit')

  const lines = existsSync(tracePath) ? readFileSync(tracePath, 'utf8').split('\n').filter(Boolean) : []
  log(`trace rows written            : ${lines.length}`)
  log(`stub agent() calls            : ${_agentCalls} (of which ${_flushExecs} REALLY ran walteur.js's bash append)`)
  const mismatchRows = lines.filter(l => l.includes('routing_mismatch:true'))
  ok(lines.length >= 11, `flushSpans actually wrote the native trace (${lines.length} rows)`)
  ok(mismatchRows.length === 1, `exactly 1 routing_mismatch row — the deliberate negative control (got ${mismatchRows.length})`)
  const reconcileRow = lines.find(l => l.includes('"tool":"reconcile"'))
  ok(!!reconcileRow && !reconcileRow.includes('routing_mismatch'),
    `the reconcile span (model 'n/a') is CLEAN — the S038 #2 built-in false positive is gone`)
  ok(eng.routingConformance('Audit', 'n/a').checked === false, `routingConformance('Audit','n/a') → checked:false`)
  ok(eng.routingConformance('Audit', 'sonnet').routing_mismatch === true, `routingConformance('Audit','sonnet') → still a real mismatch`)
  log('---- run-trace.jsonl (full) ----')
  for (const l of lines) console.log(l)
  log('--------------------------------')
  return lines
}

// ─────────────────  SCENARIO B — THE CEILING ACTUALLY FIRES WITH NO TOKEN METER  ─────────────────
// This is the panel-12 headline finding. Every real field run had NO `budget` object, so estUsd() returned
// a hardcoded 0 and overBudget(0, 25) was false forever — the ceiling was reported, never enforced. Here we
// wire the engine with budget===undefined (the real condition) and drive REAL dispatches through the REAL
// dispatch() choke point until the REAL overBudget() fires.
async function scenarioB() {
  log('')
  log('=== SCENARIO B · NO token meter (the real field-run condition): does the ceiling bite? ===')
  const eng = wireEngine(undefined)
  const MAX_USD = 25
  ok(eng.meterStatus() === 'idle', `meterStatus() before any dispatch = 'idle' (got '${eng.meterStatus()}')`)
  ok(eng.estUsd() === 0, `estUsd() with nothing dispatched = $0 (got $${eng.estUsd()})`)

  let firedAt = -1
  let n = 0
  const CAP = 400
  while (n < CAP) {
    if (eng.overBudget(eng.estUsd(), MAX_USD)) { firedAt = n; break }
    // a real dispatch through the real choke point (Review is an opus phase per routes[])
    await eng.dispatch('stub prompt', { label: `review:senior${n}`, model: 'opus', phase: 'Review' })
    n++
  }
  log(`dispatches issued             : ${n} · est_usd=$${eng.estUsd()} · meter=${eng.meterStatus()}`)
  log(`lane counters                 : ${JSON.stringify(eng._laneDispatches)}`)
  ok(eng.meterStatus() === 'unmetered_dispatch_estimate', `meterStatus() = 'unmetered_dispatch_estimate' with no budget object (got '${eng.meterStatus()}')`)
  ok(eng.estUsd() > 0, `estUsd() is NON-ZERO after real dispatches (got $${eng.estUsd()}) — the ceiling now has a real input`)
  ok(firedAt > 0 && firedAt < CAP, `overBudget() ACTUALLY FIRED after ${firedAt} opus dispatches (ceiling $${MAX_USD}) — BUDGET_EXCEEDED is now reachable`)
  // the arithmetic must be auditable, not magic: opus dispatches × assumed output tokens × opus price
  const expect = +((eng.UNMETERED_OUT_TOKENS_PER_DISPATCH / 1e6) * firedAt * eng.PRICE_USD_PER_MTOK_OUT.opus).toFixed(2)
  ok(Math.abs(eng.estUsd() - expect) < 0.011, `est_usd reproduces by hand: ${firedAt} × ${eng.UNMETERED_OUT_TOKENS_PER_DISPATCH} tok × $${eng.PRICE_USD_PER_MTOK_OUT.opus}/M = $${expect} (engine says $${eng.estUsd()})`)
  // per-lane pricing (the flat-$30/M defect): an opus token must NOT cost the same as a haiku token
  const engO = wireEngine(undefined), engH = wireEngine(undefined)
  await engO.dispatch('p', { label: 'review:x', model: 'opus', phase: 'Review' })
  await engH.dispatch('p', { label: 'trace:flush:Audit', model: 'haiku', phase: 'Audit' })
  ok(engO.estUsd() > engH.estUsd(), `an opus dispatch ($${engO.estUsd()}) costs MORE than a haiku dispatch ($${engH.estUsd()}) — flat $30/M pricing is gone`)
  ok(engO.blendedRateUsdPerMtok() === eng.PRICE_USD_PER_MTOK_OUT.opus, `blended rate on an all-opus mix = the opus price ($${engO.blendedRateUsdPerMtok()}/M)`)
  return firedAt
}

// ─────────────────  SCENARIO C — CONFORMANCE AT THE DISPATCH, NOT THE ANNOTATION  ─────────────────
async function scenarioC() {
  log('')
  log('=== SCENARIO C · dispatch-level routing conformance + mechanical lane ===')
  const eng = wireEngine(undefined)
  // (i) a NON-retry dispatch asking for sonnet in the opus-only Audit phase = a real violation
  await eng.dispatch('p', { label: 'audit:final', model: 'sonnet', phase: 'Audit' })
  ok(eng._routingViolations.length === 1, `a hardcoded sonnet at an Audit dispatch is CAUGHT at the dispatch (violations=${eng._routingViolations.length})`)
  const vSpan = eng._spanQueue.find(s => String(s.gv).includes('routing_violation:true'))
  ok(!!vSpan && vSpan.ec === '2', `the violation is emitted as an exit_code 2 span for run-trace.jsonl to carry`)
  // (ii) attempt 0 of a safeOne pair is still checked; only the RETRY is allowed the fallback tier
  const before = eng._routingViolations.length
  await eng.safeOne(() => eng.dispatch('p', { label: 'audit:final', model: 'sonnet', phase: 'Audit' }), 'audit:final')
  ok(eng._routingViolations.length === before + 1, `attempt 0 of a safeOne retry pair is still checked (not a blanket exemption)`)
  const before2 = eng._routingViolations.length
  eng.setRetry(true)
  eng.dispatch('p', { label: 'audit:final', model: 'sonnet', phase: 'Audit' })
  eng.setRetry(false)
  ok(eng._routingViolations.length === before2, `a RETRY drop to the sonnet fallback tier is permitted (fallback_policy.on_retry) — no new violation`)
  // (iii) declared escalation: Build → opus for tagged (security/payments/…) tasks is legitimate
  const b4 = eng._routingViolations.length
  await eng.dispatch('p', { label: 'build:T7', model: 'opus', phase: 'Build' })
  ok(eng._routingViolations.length === b4, `Build → opus (the routes[] escalation for tagged tasks) is NOT flagged`)
  // (iv) MECHANICAL LANE: a bookkeeping label is actively downgraded to haiku
  const eng2 = wireEngine(undefined)
  _seenModels = []
  await eng2.dispatch('p', { label: 'trace:flush:Audit', model: 'sonnet', phase: 'Audit' })
  await eng2.dispatch('p', { label: 'checkpoint:plan', model: 'sonnet', phase: 'Plan' })
  await eng2.dispatch('p', { label: 'self-optimize:queue', model: 'sonnet', phase: 'Audit' })
  await eng2.dispatch('p', { label: 'audit:final', model: 'opus', phase: 'Audit' })
  const mech = _seenModels.filter(m => m.model === 'haiku').length
  ok(mech === 3, `3 bookkeeping dispatches were routed to the haiku MECHANICAL lane (got ${mech}) — the third lane is real`)
  ok(eng2._laneDispatches.haiku === 3 && eng2._laneDispatches.opus === 1, `lane counters agree: ${JSON.stringify(eng2._laneDispatches)}`)
  ok(eng2._routingViolations.length === 0, `the haiku downgrade of a mechanical label is NOT a conformance violation`)
}

async function run() {
  log(`projectPath = ${projectPath}`)
  const eng0 = wireEngine(undefined) // running the slice at all EXECUTES walteur.js's own inline assertion IIFEs
  log('walteur.js inline contract assertions (overBudget/routingConformance/dispatchConformance) executed OK')
  chokePointGate()
  mirrorSyncGate(eng0)
  await scenarioA()
  const firedAt = await scenarioB()
  await scenarioC()

  log('')
  log('================  RUN SUMMARY  ================')
  log(`stub agent() calls total      : ${_agentCalls}`)
  log(`  of which REAL trace-flush exec: ${_flushExecs}  (these actually ran walteur.js's bash append)`)
  log(`safeOne failures recorded     : ${failures.length}`)
  log(`ceiling fired after           : ${firedAt} unmetered opus dispatches (was: never — estUsd() returned a hardcoded 0)`)
  log(`assertion failures            : ${FAILS}`)
  if (FAILS > 0) { log('!! REGRESSION — see the FAIL lines above.'); process.exitCode = 1 }
  else log('all assertions held.')
}

run().catch(e => { console.error('[walteur-run] FATAL', e); process.exitCode = 1 })
