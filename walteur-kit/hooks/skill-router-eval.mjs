#!/usr/bin/env node
// walteur-apex skill-router-eval — closes R12 (ULTIMATE-UPGRADE-2026.md): "skill router-eval + budget
// — per-skill should/shouldn't-trigger probes; cap <=~12 active skills (accuracy craters past ~40)."
//
// skill-router.mjs's OWN selftest only exercises a curated 26-skill synthetic fixture. This runs the
// SAME routeSkills() function against the REAL skill-index.json (223 skills, 18 disciplines) across
// realistic signal profiles, and checks two things nothing else checks:
//   1. Should/shouldn't-fire precision on real data — a profile must require the skills it obviously
//      needs, and must NEVER require a skill from a discipline outside DISCIPLINE_RELEVANCE for that
//      build_class (e.g. a software build must never require a 'sales' or 'hr' skill).
//   2. The active-skill BUDGET — required-skill count per profile must stay under a cap (default 12).
//      WALTEUR's own R12 note: routing accuracy craters past ~40 active skills. This is currently
//      unenforced anywhere.
//
// Usage:
//   node skill-router-eval.mjs <path-to-skill-router.mjs> <path-to-skill-index.json> [--budget N]
//   node skill-router-eval.mjs --help
//
// Exit 0 = all checks pass (budget + precision). Exit 2 = at least one check failed (mirrors WALTEUR's
// fail-closed gate convention). Report written next to the skill-index.json as
// skill-router-eval-report.json.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

// A verification tool that is itself unverified is the thing this whole folder argues against.
// --selftest builds synthetic router/index pairs and asserts this eval's own contract.
async function selftest() {
  let pass = 0, fail = 0
  const ck = (name, cond) => { if (cond) { console.log(`  ok   - ${name}`); pass++ } else { console.log(`  FAIL - ${name}`); fail++ } }
  const self = process.argv[1]
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'sre-selftest-'))
  // Minimal stand-in router honouring the real CLI contract: <signals> <index> <outRouting> <outRequired>.
  // Stub router honouring the real CLI contract and enough of the real signal->skill logic to satisfy
  // every PROFILE's mustRequire/mustNotRequire. `extra` injects an out-of-relevance skill with a chosen
  // reason, so rule-1 (curated, allowed) and rule-3 (broad scan, must not leak) can be told apart.
  const router = path.join(d, 'router.mjs')
  const mkRouter = (extra = null) => fs.writeFileSync(router, `
import fs from 'node:fs'
const [s,i,or,orq]=process.argv.slice(2)
if(!orq){console.error('usage');process.exit(2)}
const sig=JSON.parse(fs.readFileSync(s,'utf8'))
const idx=JSON.parse(fs.readFileSync(i,'utf8'))
const by=new Map(idx.skills.map(x=>[x.skill,x]))
const out=[]
const add=(n,reason)=>{ if(by.has(n)&&!out.some(o=>o.skill===n)) out.push({skill:n,required:true,reason,discipline:by.get(n).discipline}) }
if(sig.build_class!=='document'){ add('org-tdd-discipline','code-build floor'); add('org-premortem','code-build floor') }
if(sig.external_surface||sig.has_pii||sig.regulated) add('org-confidentiality-guard','signal:external_surface')
if(sig.regulated||sig.has_api_boundary||sig.security_sensitive||sig.has_payments) add('org-secure-coding-checklist','signal:security_sensitive')
if(sig.is_ai_agent) add('org-model-risk','signal:is_ai_agent')
if(sig.regulated) add('org-dpia-writer','signal:regulated')
${extra ? `add(${JSON.stringify(extra.skill)}, ${JSON.stringify(extra.reason)})` : ''}
fs.writeFileSync(or,JSON.stringify({routed:out,optional:[]}))
fs.writeFileSync(orq,JSON.stringify({skills:out}))
`)
  const index = path.join(d, 'index.json')
  fs.writeFileSync(index, JSON.stringify({ skills: [
    { skill: 'org-tdd-discipline', discipline: 'engineering' },
    { skill: 'org-premortem', discipline: 'process' },
    { skill: 'org-confidentiality-guard', discipline: 'quality' },
    { skill: 'org-secure-coding-checklist', discipline: 'engineering' },
    { skill: 'org-model-risk', discipline: 'ai-governance' },
    { skill: 'org-dpia-writer', discipline: 'legal' },   // out-of-relevance by design; curated rule-1
    { skill: 'org-cold-outreach', discipline: 'sales' }, // out-of-relevance; used for the leak case
  ] }))
  const run = (extra = []) => {
    try {
      execFileSync(process.execPath, [self, router, index, ...extra], { stdio: 'pipe' })
      return 0
    } catch (e) { return e.status ?? 1 }
  }
  console.log('skill-router-eval selftest:')
  // 1. missing args must be exit 2, never 0 (a mis-wired CI must not read as a pass)
  let rc; try { execFileSync(process.execPath, [self], { stdio: 'pipe' }); rc = 0 } catch (e) { rc = e.status }
  ck('no args -> exit 2 (not 0)', rc === 2)
  // 2. nonexistent router path -> exit 2, not an uncaught throw
  try { execFileSync(process.execPath, [self, path.join(d, 'nope.mjs'), index], { stdio: 'pipe' }); rc = 0 } catch (e) { rc = e.status }
  ck('missing router path -> exit 2', rc === 2)
  // 3. --help -> exit 0
  try { execFileSync(process.execPath, [self, '--help'], { stdio: 'pipe' }); rc = 0 } catch (e) { rc = e.status }
  ck('--help -> exit 0', rc === 0)
  // 4. a healthy router: satisfies every profile, within budget, no rule-3 leak -> exit 0
  mkRouter()
  ck('healthy router within budget -> exit 0', run() === 0)
  // 5. budget breach -> exit 2
  mkRouter()
  ck('budget of 1 exceeded -> exit 2', run(['--budget', '1']) === 2)
  // 6. rule-3 relevance leak (a sales skill pulled in by the broad scan) -> exit 2
  mkRouter({ skill: 'org-cold-outreach', reason: 'signal_tag match' })
  ck('rule-3 out-of-relevance leak -> exit 2', run() === 2)
  // 7. the SAME out-of-relevance skill via a CURATED rule-1 binding is allowed by design -> exit 0
  mkRouter({ skill: 'org-cold-outreach', reason: 'signal:external_surface' })
  ck('curated rule-1 cross-discipline binding -> exit 0', run() === 0)
  // 8. a report is written next to the index
  ck('writes report next to the index', fs.existsSync(path.join(path.dirname(index), 'skill-router-eval-report.json')))
  // 9. the mirrored RELEVANCE oracle has not drifted from the real router's DISCIPLINE_RELEVANCE
  ck('RELEVANCE oracle matches skill-router.mjs (or router absent)', relevanceMatchesSource())
  fs.rmSync(d, { recursive: true, force: true })
  console.log(`skill-router-eval selftest: ${pass}/${pass + fail} passed`)
  return fail === 0
}

// The RELEVANCE map below is duplicated from skill-router.mjs deliberately, so the eval judges against
// an independent oracle rather than importing the thing under test. Duplication without a drift check
// is just a stale oracle, so assert equality against the source when it can be located.
function relevanceMatchesSource() {
  const candidates = [
    'D:/Walteur/walteur-framework/walteur-kit/hooks/skill-router.mjs',
    'D:/Walteur/walteur-starter/walteur-kit/hooks/skill-router.mjs',
  ].filter((p) => fs.existsSync(p))
  if (!candidates.length) return true // nothing to compare against; not a failure
  const src = fs.readFileSync(candidates[0], 'utf8')
  const m = src.match(/const DISCIPLINE_RELEVANCE\s*=\s*\{[\s\S]*?\n\}/)
  if (!m) return true
  for (const [k, v] of Object.entries(RELEVANCE)) {
    const row = m[0].match(new RegExp(`['"]?${k.replace(/[^a-z-]/gi, '')}['"]?\\s*:\\s*\\[([^\\]]*)\\]`))
    if (!row) return false
    const got = row[1].split(',').map((s) => s.trim().replace(/['"]/g, '')).filter(Boolean).sort()
    if (JSON.stringify(got) !== JSON.stringify([...v].sort())) return false
  }
  return true
}

const args = process.argv.slice(2)
const usage = () => {
  console.log('skill-router-eval - precision + budget probes for skill-router.mjs against a real skill-index.json')
  console.log('usage: node skill-router-eval.mjs <path-to-skill-router.mjs> <path-to-skill-index.json> [--budget N]')
  console.log('       node skill-router-eval.mjs --selftest')
  console.log('report: <index-dir>/skill-router-eval-report.json')
  console.log('exit:   0 = all checks pass · 2 = a check failed or the invocation was wrong')
}
const SELFTEST = args.includes('--selftest')
if (args.includes('-h') || args.includes('--help')) { usage(); process.exit(0) }
// Missing arguments must NOT exit 0 — ADOPTION.md tells a runner that non-zero means a budget breach,
// so a mis-wired CI invocation printing help and exiting 0 would read as a clean pass. Exit 2.
if (!SELFTEST) {
  if (args.length < 2) { console.error('skill-router-eval: FAIL - missing required arguments\n'); usage(); process.exit(2) }
  for (const p of [args[0], args[1]]) {
    if (!fs.existsSync(p)) { console.error(`skill-router-eval: FAIL - no such file: ${p}`); process.exit(2) }
  }
}

const routerPath = SELFTEST ? '' : path.resolve(args[0])
const indexPath = SELFTEST ? '' : path.resolve(args[1])
const budgetIdx = args.indexOf('--budget')
const BUDGET = budgetIdx >= 0 ? parseInt(args[budgetIdx + 1], 10) : 12
const OPTIONAL_WARN = 40 // per WALTEUR's own R12 note: accuracy craters past ~40 ACTIVE (required+optional) skills

const index = SELFTEST ? { skills: [] } : JSON.parse(fs.readFileSync(indexPath, 'utf8'))

// skill-router.mjs's own module-top-level code unconditionally dispatches on process.argv and calls
// process.exit(...) in every branch (--selftest | 4-arg CLI | usage-error) — that makes it unsafe to
// `import()` in-process (it would hijack OUR process.argv and exit before routeSkills() ever runs).
// It is a documented CLI tool (see its own header comment), so we shell out to it exactly the way it's
// designed to be invoked, once per profile, via temp files. This never touches skill-router.mjs itself.
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'skill-router-eval-'))
function routeSkills(signals) {
  const signalsPath = path.join(tmpDir, `signals-${Math.random().toString(36).slice(2)}.json`)
  const outRouting = path.join(tmpDir, `routing-${Math.random().toString(36).slice(2)}.json`)
  const outRequired = path.join(tmpDir, `required-${Math.random().toString(36).slice(2)}.json`)
  fs.writeFileSync(signalsPath, JSON.stringify(signals))
  execFileSync(process.execPath, [routerPath, signalsPath, indexPath, outRouting, outRequired], { stdio: ['ignore', 'ignore', 'inherit'] })
  return JSON.parse(fs.readFileSync(outRouting, 'utf8'))
}

// DISCIPLINE_RELEVANCE mirrored from skill-router.mjs (kept here as a check, not re-exported by the
// router) — used to assert rule-3's broad discipline+signal_tag scan never leaks a skill from a
// build-class-irrelevant discipline into the required or optional set.
const RELEVANCE = {
  software: ['engineering', 'quality', 'process', 'security', 'ai-governance', 'operations-data', 'meta'],
  'data-ai': ['engineering', 'quality', 'process', 'security', 'ai-governance', 'operations-data', 'meta'],
  'cloud-iac': ['engineering', 'quality', 'process', 'security', 'operations-data', 'it', 'meta'],
  document: ['quality', 'communications', 'process'],
  workflow: ['process', 'operations-data', 'quality', 'engineering'],
  mixed: ['engineering', 'quality', 'process', 'security', 'ai-governance', 'operations-data', 'meta'],
}
// Dispatched here rather than at the top: selftest() checks the RELEVANCE oracle for drift against
// skill-router.mjs, and RELEVANCE is a `const` declared just above — calling earlier hits its TDZ.
if (SELFTEST) process.exit((await selftest()) ? 0 : 2)

const byName = new Map(index.skills.map(s => [s.skill, s]))
const disciplineOf = (skill) => byName.get(skill)?.discipline

// Realistic signal profiles — not exhaustive, but each names a concrete real-world build shape and a
// should/shouldn't-fire expectation grounded in what the profile obviously needs.
const PROFILES = [
  {
    name: 'bare software build (no signals)',
    signals: { build_class: 'software' },
    mustRequire: ['org-tdd-discipline', 'org-premortem'],
  },
  {
    name: 'external-facing SaaS with UI, DB, auth, API, payments',
    signals: {
      build_class: 'software', external_surface: true, has_ui: true, has_db: true, has_auth: true,
      has_api_boundary: true, has_payments: true, security_sensitive: true,
    },
    mustRequire: ['org-confidentiality-guard', 'org-secure-coding-checklist', 'org-tdd-discipline'],
  },
  {
    name: 'regulated AI agent product (fintech-adjacent)',
    signals: {
      build_class: 'software', external_surface: true, has_pii: true, regulated: true, is_ai_agent: true,
      has_api_boundary: true, security_sensitive: true,
    },
    mustRequire: ['org-confidentiality-guard', 'org-model-risk', 'org-dpia-writer'],
  },
  {
    name: 'internal doc deliverable (no code floor)',
    signals: { build_class: 'document', is_doc_deliverable: true },
    mustRequire: [],
    mustNotRequire: ['org-tdd-discipline', 'org-premortem'],
  },
  {
    name: 'cloud-iac infra build',
    signals: { build_class: 'cloud-iac', security_sensitive: true },
    mustRequire: [],
  },
]

let failures = 0
const results = []
const record = (ok, msg) => { results.push({ ok, msg }); if (!ok) failures++; console.log(`  ${ok ? 'ok  ' : 'FAIL'} - ${msg}`) }

console.log(`skill-router-eval: ${index.skills.length} real skills, budget=${BUDGET}\n`)

// Rule-1 (curated REQUIRED_BINDINGS) and rule-2 (code-build floor) bindings bypass
// DISCIPLINE_RELEVANCE by design in skill-router.mjs — they're hand-vetted exceptions (e.g. a
// 'regulated' software build deliberately pulls in the 'legal' org-dpia-writer). Only rule-3's
// broad discipline+signal_tag scan is SUPPOSED to be relevance-gated (its own code comment says so).
// Distinguish by `reason`: rule-1 reason is `signal:<name>`, rule-2 is `code-build floor`, rule-3 is
// `<discipline> hard_gate + signal` (required) or `signal_tag match` (optional) — verified against
// skill-router.mjs's entry() function.
const isRule3 = (r) => r.reason === 'signal_tag match' || /hard_gate \+ signal$/.test(r.reason || '')

for (const p of PROFILES) {
  console.log(`profile: ${p.name}`)
  const routing = routeSkills(p.signals, index)
  const allEntries = [...routing.routed, ...routing.optional]
  const reqNames = routing.routed.map(r => r.skill)
  const optNames = routing.optional.map(r => r.skill)
  const active = reqNames.length + optNames.length

  for (const must of p.mustRequire || []) record(reqNames.includes(must), `requires ${must}`)
  for (const mustNot of p.mustNotRequire || []) record(!reqNames.includes(mustNot), `does NOT require ${mustNot}`)

  const relevant = new Set(RELEVANCE[p.signals.build_class] || [])
  // Only flag rule-3 (broad scan) leakage — curated rule-1/rule-2 cross-discipline pulls are by design.
  const outOfRelevance = allEntries.filter(e => isRule3(e) && !relevant.has(disciplineOf(e.skill))).map(e => e.skill)
  record(outOfRelevance.length === 0, `rule-3 broad scan never pulls a skill outside build_class relevance${outOfRelevance.length ? ` (${outOfRelevance.join(', ')})` : ''}`)

  record(reqNames.length <= BUDGET, `required-skill count ${reqNames.length} <= budget ${BUDGET}`)
  if (active > OPTIONAL_WARN) console.log(`  warn - active (required+optional) skill count ${active} exceeds advisory threshold ${OPTIONAL_WARN} (R12: routing accuracy craters past ~40)`)
  console.log('')
}

const report = {
  verdict: failures === 0 ? 'PASS' : 'FAIL',
  ts: new Date().toISOString(),
  gate: 'skill-router-eval',
  budget: BUDGET,
  index_skill_count: index.skills.length,
  profiles_run: PROFILES.length,
  failures,
  checks: results,
}
fs.writeFileSync(path.join(path.dirname(indexPath), 'skill-router-eval-report.json'), JSON.stringify(report, null, 2))
fs.rmSync(tmpDir, { recursive: true, force: true })
console.log(`skill-router-eval: ${results.length - failures}/${results.length} checks passed`)
process.exit(failures === 0 ? 0 : 2)
