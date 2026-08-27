#!/usr/bin/env node
// WALTEUR skill-router — the Preflight engine that turns detected build signals into a
// COMMITTED skill set. Queries skill-index.json, emits skill-routing.json (the rich
// ledger) and required-skills.json (the projection the fail-closed skill-readiness gate
// consumes). This is what makes the 184 skills FIRE at the right step instead of sitting
// idle — it converts skill use from PROTOCOL ("the agent might remember") into
// routed → committed → fail-closed.
//
// Usage (Preflight phase of walteur.js, or standalone):
//   node skill-router.mjs <signals.json> <skill-index.json> <out-skill-routing.json> <out-required-skills.json>
//   node skill-router.mjs --selftest
//
// signals.json shape: { build_class, has_ui, is_user_facing, external_surface, has_pii,
//   has_payments, has_api_boundary, has_db, has_auth, regulated, is_ai_agent,
//   security_sensitive, is_cloud_iac, is_doc_deliverable, risk_tier }
import fs from 'node:fs'

// Which disciplines are even relevant to a build class — keeps a software build from
// pulling in Sales/HR/Finance skills just because they share a keyword.
const DISCIPLINE_RELEVANCE = {
  software: ['engineering', 'quality', 'process', 'security', 'ai-governance', 'operations-data', 'meta'],
  'data-ai': ['engineering', 'quality', 'process', 'security', 'ai-governance', 'operations-data', 'meta'],
  'cloud-iac': ['engineering', 'quality', 'process', 'security', 'operations-data', 'it', 'meta'],
  document: ['quality', 'communications', 'process'],
  workflow: ['process', 'operations-data', 'quality', 'engineering'],
  mixed: ['engineering', 'quality', 'process', 'security', 'ai-governance', 'operations-data', 'meta'],
}

// Curated high-confidence bindings: when SIGNAL is asserted, these named skills are REQUIRED.
// Every skill name here is verified present in skill-index.json (the router drops absent
// names anyway via `mark()`, but a binding that never fires is dead weight — don't add one
// without checking `skill-index.json` first).
const REQUIRED_BINDINGS = [
  // confidentiality + secure-coding (external surface / PII / regulated / payments / API / sec-sensitive)
  { signal: 'external_surface', skills: ['org-confidentiality-guard'] },
  { signal: 'has_pii', skills: ['org-confidentiality-guard'] },
  { signal: 'regulated', skills: ['org-confidentiality-guard', 'org-secure-coding-checklist'] },
  { signal: 'has_payments', skills: ['org-secure-coding-checklist'] },
  { signal: 'has_api_boundary', skills: ['org-secure-coding-checklist'] },
  { signal: 'security_sensitive', skills: ['org-secure-coding-checklist'] },
  { signal: 'is_user_facing', skills: ['org-prd-builder'] },
  // has_ui => design disciplines: brand + UI/UX discipline + design-system craft
  { signal: 'has_ui', skills: ['org-brand-dna', 'org-uiux-discipline', 'loopkit-design-system'] },
  // has_db => migration/data safety skills
  { signal: 'has_db', skills: ['loopkit-migration-writer', 'loopkit-schema-diff', 'org-database-discipline'] },
  // is_ai_agent => AI-governance set
  { signal: 'is_ai_agent', skills: ['org-model-risk', 'org-ai-output-audit', 'org-ai-vendor-governance'] },
  // has_auth => authz/security review
  { signal: 'has_auth', skills: ['loopkit-authz-check', 'org-pentest-discipline'] },
  // is_doc_deliverable => doc-quality set (not TDD — a document-class build has no code floor)
  { signal: 'is_doc_deliverable', skills: ['loopkit-readme-audit', 'org-adr-writer', 'org-writing-plans'] },
  // regulated => compliance set (beyond confidentiality/secure-coding above)
  { signal: 'regulated', skills: ['org-dpia-writer', 'org-vendor-security-review', 'org-ai-act-compliance'] },
]
// Code-shaped builds always carry these floors regardless of signal.
const ALWAYS_FOR_CODE = ['org-tdd-discipline', 'org-premortem']
const CODE_CLASSES = new Set(['software', 'data-ai', 'cloud-iac', 'mixed', 'workflow'])

export function routeSkills(signals = {}, index = { skills: [] }, opts = {}) {
  const buildClass = signals.build_class || opts.build_class || 'software'
  const relevant = new Set(DISCIPLINE_RELEVANCE[buildClass] || DISCIPLINE_RELEVANCE.software)
  const byName = new Map((index.skills || []).map(s => [s.skill, s]))
  const asserted = new Set(Object.entries(signals).filter(([, v]) => v === true).map(([k]) => k))
  if (asserted.has('has_ui')) asserted.add('is_user_facing')

  const required = new Map() // name -> reason
  const optional = new Map()
  const mark = (name, isRequired, reason) => {
    if (!byName.has(name)) return // only ever emit skills that actually exist in the index
    if (isRequired) { required.set(name, reason); optional.delete(name) }
    else if (!required.has(name)) optional.set(name, reason)
  }

  // 1. curated required bindings
  for (const b of REQUIRED_BINDINGS) if (asserted.has(b.signal)) for (const sk of b.skills) mark(sk, true, `signal:${b.signal}`)
  // 2. code-build floors
  if (CODE_CLASSES.has(buildClass)) for (const sk of ALWAYS_FOR_CODE) mark(sk, true, 'code-build floor')
  // 3. broad applicability by signal_tag ∩ asserted, discipline-gated. Any hard-gate skill
  //    (mandatory per its own SKILL.md, regardless of discipline — security, quality,
  //    process, ai-governance, ...) that matches an asserted signal becomes required here;
  //    every other match is optional (advisory). Scoping to hard_gate keeps this
  //    high-precision — the skill itself already declared it non-optional, this just wires
  //    that declaration to the signals that make it relevant.
  for (const s of index.skills || []) {
    if (!relevant.has(s.discipline)) continue
    if ((s.signal_tags || []).some(t => asserted.has(t))) {
      if (s.hard_gate) mark(s.skill, true, `${s.discipline} hard_gate + signal`)
      else mark(s.skill, false, 'signal_tag match')
    }
  }

  const entry = (name, reason, isRequired) => {
    const s = byName.get(name)
    const e = { skill: name, required: isRequired, phase: (s.phase_affinity || ['Review'])[0], breadcrumb: s.breadcrumb, discipline: s.discipline, reason }
    if (s.breadcrumb_verdict_key) { e.breadcrumb_verdict_key = s.breadcrumb_verdict_key; e.breadcrumb_pass_value = s.breadcrumb_pass_value }
    return e
  }
  const routed = [...required].map(([n, r]) => entry(n, r, true)).sort((a, b) => a.skill.localeCompare(b.skill))
  const opt = [...optional].map(([n, r]) => entry(n, r, false)).sort((a, b) => a.skill.localeCompare(b.skill))
  return { signals: [...asserted].sort(), routed, optional: opt }
}

// Projection consumed by skill-readiness.sh (required-skills.json).
export function toRequiredSkills(routing) {
  const proj = (r) => {
    const o = { skill: r.skill, required: r.required, breadcrumb: r.breadcrumb, discipline: r.discipline }
    if (r.breadcrumb_verdict_key) { o.breadcrumb_verdict_key = r.breadcrumb_verdict_key; o.breadcrumb_pass_value = r.breadcrumb_pass_value }
    return o
  }
  return { schema_version: 1, generated_by: 'skill-router', skills: [...routing.routed.map(proj), ...routing.optional.map(proj)] }
}

function selftest() {
  let pass = 0, fail = 0
  const ck = (name, cond) => { if (cond) { console.log(`  ok   - ${name}`); pass++ } else { console.log(`  FAIL - ${name}`); fail++ } }
  // minimal index covering the bound skills
  const index = { skills: [
    { skill: 'org-confidentiality-guard', discipline: 'quality', phase_affinity: ['Audit', 'Review'], signal_tags: ['external_surface', 'has_pii', 'regulated'], breadcrumb: 'walteur-kit/confidentiality-pass.json', hard_gate: true, breadcrumb_verdict_key: 'verdict', breadcrumb_pass_value: 'PASS' },
    { skill: 'org-prd-builder', discipline: 'engineering', phase_affinity: ['Plan'], signal_tags: [], breadcrumb: 'walteur-kit/skills/org-prd-builder.json', hard_gate: false },
    { skill: 'org-brand-dna', discipline: 'quality', phase_affinity: ['Review'], signal_tags: ['has_ui', 'external_surface'], breadcrumb: 'walteur-kit/skills/org-brand-dna.json', hard_gate: false },
    { skill: 'org-uiux-discipline', discipline: 'engineering', phase_affinity: ['Review'], signal_tags: ['external_surface', 'has_ui'], breadcrumb: 'walteur-kit/skills/org-uiux-discipline.json', hard_gate: false },
    { skill: 'loopkit-design-system', discipline: 'engineering', phase_affinity: ['Review'], signal_tags: ['has_ui'], breadcrumb: 'walteur-kit/skills/loopkit-design-system.json', hard_gate: false },
    { skill: 'org-secure-coding-checklist', discipline: 'engineering', phase_affinity: ['Build', 'Review'], signal_tags: ['regulated', 'security_sensitive'], breadcrumb: 'walteur-kit/skills/org-secure-coding-checklist.json', hard_gate: false },
    { skill: 'org-tdd-discipline', discipline: 'engineering', phase_affinity: ['Build'], signal_tags: [], breadcrumb: 'walteur-kit/skills/org-tdd-discipline.json', hard_gate: false },
    { skill: 'org-premortem', discipline: 'process', phase_affinity: ['Plan'], signal_tags: [], breadcrumb: 'walteur-kit/skills/org-premortem.json', hard_gate: true },
    { skill: 'org-cold-outreach', discipline: 'sales', phase_affinity: ['Review'], signal_tags: ['external_surface'], breadcrumb: 'walteur-kit/skills/org-cold-outreach.json', hard_gate: false },
    // has_db bindings
    { skill: 'loopkit-migration-writer', discipline: 'operations-data', phase_affinity: ['Build'], signal_tags: ['has_db'], breadcrumb: 'walteur-kit/skills/loopkit-migration-writer.json', hard_gate: false },
    { skill: 'loopkit-schema-diff', discipline: 'operations-data', phase_affinity: ['Build'], signal_tags: ['has_db'], breadcrumb: 'walteur-kit/skills/loopkit-schema-diff.json', hard_gate: false },
    { skill: 'org-database-discipline', discipline: 'engineering', phase_affinity: ['Build'], signal_tags: ['has_db'], breadcrumb: 'walteur-kit/skills/org-database-discipline.json', hard_gate: false },
    // is_ai_agent bindings
    { skill: 'org-model-risk', discipline: 'ai-governance', phase_affinity: ['Review'], signal_tags: ['is_ai_agent', 'regulated'], breadcrumb: 'walteur-kit/skills/org-model-risk.json', hard_gate: true },
    { skill: 'org-ai-output-audit', discipline: 'ai-governance', phase_affinity: ['Review'], signal_tags: ['is_ai_agent'], breadcrumb: 'walteur-kit/skills/org-ai-output-audit.json', hard_gate: false },
    { skill: 'org-ai-vendor-governance', discipline: 'ai-governance', phase_affinity: ['Review'], signal_tags: ['is_ai_agent'], breadcrumb: 'walteur-kit/skills/org-ai-vendor-governance.json', hard_gate: false },
    // widened-rule-3 fixture: a hard_gate skill with NO curated binding at all — only reachable
    // through rule 3's broad discipline+signal_tag scan. Proves rule 3 alone is live, isolated
    // from rule 1 (curated bindings) and rule 2 (code floor).
    { skill: 'org-tabletop-crisis', discipline: 'process', phase_affinity: ['Plan'], signal_tags: ['is_ai_agent'], breadcrumb: 'walteur-kit/skills/org-tabletop-crisis.json', hard_gate: true },
    // has_auth bindings
    { skill: 'loopkit-authz-check', discipline: 'security', phase_affinity: ['Build', 'Review'], signal_tags: ['has_api_boundary', 'security_sensitive'], breadcrumb: 'walteur-kit/skills/loopkit-authz-check.json', hard_gate: false },
    { skill: 'org-pentest-discipline', discipline: 'security', phase_affinity: ['Audit'], signal_tags: ['external_surface', 'security_sensitive'], breadcrumb: 'walteur-kit/skills/org-pentest-discipline.json', hard_gate: false },
    // is_doc_deliverable bindings (document build class: quality/communications/process only)
    { skill: 'loopkit-readme-audit', discipline: 'communications', phase_affinity: ['Review'], signal_tags: [], breadcrumb: 'walteur-kit/skills/loopkit-readme-audit.json', hard_gate: false },
    { skill: 'org-adr-writer', discipline: 'engineering', phase_affinity: ['Build'], signal_tags: ['external_surface'], breadcrumb: 'walteur-kit/skills/org-adr-writer.json', hard_gate: false },
    { skill: 'org-writing-plans', discipline: 'process', phase_affinity: ['Review'], signal_tags: ['has_ui'], breadcrumb: 'walteur-kit/skills/org-writing-plans.json', hard_gate: false },
    // regulated compliance set (beyond confidentiality/secure-coding)
    { skill: 'org-dpia-writer', discipline: 'legal', phase_affinity: ['Review'], signal_tags: ['regulated', 'has_pii'], breadcrumb: 'walteur-kit/skills/org-dpia-writer.json', hard_gate: false },
    { skill: 'org-vendor-security-review', discipline: 'security', phase_affinity: ['Audit'], signal_tags: ['regulated', 'security_sensitive'], breadcrumb: 'walteur-kit/skills/org-vendor-security-review.json', hard_gate: false },
    { skill: 'org-ai-act-compliance', discipline: 'ai-governance', phase_affinity: ['Audit'], signal_tags: ['external_surface', 'regulated', 'is_ai_agent'], breadcrumb: 'walteur-kit/skills/org-ai-act-compliance.json', hard_gate: false },
    // widened-rule-3 negative control: a hard_gate skill in a discipline NOT relevant to
    // 'software' (DISCIPLINE_RELEVANCE has no 'sales') must stay unreachable even though its
    // signal_tags match an asserted signal.
    { skill: 'org-bid-qualifier', discipline: 'sales', phase_affinity: ['Plan'], signal_tags: ['has_payments'], breadcrumb: 'walteur-kit/skills/org-bid-qualifier.json', hard_gate: true },
  ] }
  const reqNames = (r) => r.routed.map(x => x.skill)

  console.log('skill-router selftest:')

  let r = routeSkills({ build_class: 'software', external_surface: true }, index)
  ck('external_surface -> confidentiality-guard REQUIRED', reqNames(r).includes('org-confidentiality-guard'))
  ck('software floor: tdd + premortem REQUIRED', reqNames(r).includes('org-tdd-discipline') && reqNames(r).includes('org-premortem'))
  ck('external_surface does NOT pull in Sales cold-outreach (discipline-gated)', !reqNames(r).includes('org-cold-outreach') && !r.optional.map(x => x.skill).includes('org-cold-outreach'))

  r = routeSkills({ build_class: 'software', has_ui: true }, index)
  ck('has_ui -> is_user_facing -> prd-builder REQUIRED', reqNames(r).includes('org-prd-builder'))
  ck('has_ui -> brand-dna REQUIRED', reqNames(r).includes('org-brand-dna'))

  r = routeSkills({ build_class: 'software', regulated: true, has_api_boundary: true }, index)
  ck('regulated/api -> secure-coding-checklist REQUIRED', reqNames(r).includes('org-secure-coding-checklist'))

  r = routeSkills({ build_class: 'document' }, index)
  ck('document class: no code floor (no tdd)', !reqNames(r).includes('org-tdd-discipline'))

  r = routeSkills({ build_class: 'software' }, index)
  ck('bare software build: only code floor required', reqNames(r).sort().join(',') === 'org-premortem,org-tdd-discipline')

  // has_ui -> design disciplines (rule 1 curated bindings)
  r = routeSkills({ build_class: 'software', has_ui: true }, index)
  ck('has_ui -> uiux-discipline REQUIRED', reqNames(r).includes('org-uiux-discipline'))
  ck('has_ui -> design-system REQUIRED', reqNames(r).includes('loopkit-design-system'))

  // has_db -> migration/data skills
  r = routeSkills({ build_class: 'software', has_db: true }, index)
  ck('has_db -> migration-writer REQUIRED', reqNames(r).includes('loopkit-migration-writer'))
  ck('has_db -> schema-diff REQUIRED', reqNames(r).includes('loopkit-schema-diff'))
  ck('has_db -> database-discipline REQUIRED', reqNames(r).includes('org-database-discipline'))

  // is_ai_agent -> ai-governance set
  r = routeSkills({ build_class: 'software', is_ai_agent: true }, index)
  ck('is_ai_agent -> model-risk REQUIRED', reqNames(r).includes('org-model-risk'))
  ck('is_ai_agent -> ai-output-audit REQUIRED', reqNames(r).includes('org-ai-output-audit'))
  ck('is_ai_agent -> ai-vendor-governance REQUIRED', reqNames(r).includes('org-ai-vendor-governance'))

  // has_auth -> authz/security
  r = routeSkills({ build_class: 'software', has_auth: true }, index)
  ck('has_auth -> authz-check REQUIRED', reqNames(r).includes('loopkit-authz-check'))
  ck('has_auth -> pentest-discipline REQUIRED', reqNames(r).includes('org-pentest-discipline'))

  // is_doc_deliverable -> doc-quality set; document class pulls doc skills NOT TDD
  r = routeSkills({ build_class: 'document', is_doc_deliverable: true }, index)
  ck('is_doc_deliverable -> readme-audit REQUIRED', reqNames(r).includes('loopkit-readme-audit'))
  ck('is_doc_deliverable -> adr-writer REQUIRED', reqNames(r).includes('org-adr-writer'))
  ck('is_doc_deliverable -> writing-plans REQUIRED', reqNames(r).includes('org-writing-plans'))
  ck('document class pulls doc skills, not TDD (no code floor)', !reqNames(r).includes('org-tdd-discipline') && !reqNames(r).includes('org-premortem'))

  // regulated -> compliance set (beyond confidentiality/secure-coding)
  r = routeSkills({ build_class: 'software', regulated: true }, index)
  ck('regulated -> dpia-writer REQUIRED', reqNames(r).includes('org-dpia-writer'))
  ck('regulated -> vendor-security-review REQUIRED', reqNames(r).includes('org-vendor-security-review'))
  ck('regulated -> ai-act-compliance REQUIRED', reqNames(r).includes('org-ai-act-compliance'))

  // rule 3 widened: ANY relevant-discipline hard_gate skill matching a signal becomes
  // required, not just security. org-tabletop-crisis (process, hard_gate) has NO curated
  // binding anywhere — it can only be pulled in by rule 3's broad discipline+signal_tag scan.
  // Before the fix this required discipline === 'security'; process would have stayed
  // optional-only (dead code for every non-security hard_gate skill).
  r = routeSkills({ build_class: 'software', is_ai_agent: true }, index)
  ck('rule 3 widened: non-security hard_gate (process) REQUIRED via broad signal match, not just optional', reqNames(r).includes('org-tabletop-crisis'))
  const tcEntry = r.routed.find(x => x.skill === 'org-tabletop-crisis')
  ck('rule 3 reason string reflects the discipline that fired it', tcEntry && tcEntry.reason === 'process hard_gate + signal')

  // rule 3 negative control: a hard_gate skill in a discipline NOT relevant to the build
  // class must stay unreachable even though its signal_tags match an asserted signal.
  r = routeSkills({ build_class: 'software', has_payments: true }, index)
  ck('NEGATIVE CONTROL: hard_gate skill in irrelevant discipline (sales) stays unreachable', !reqNames(r).includes('org-bid-qualifier') && !r.optional.map(x => x.skill).includes('org-bid-qualifier'))

  // projection carries verdict-key through
  r = routeSkills({ build_class: 'software', external_surface: true }, index)
  const proj = toRequiredSkills(r)
  const cg = proj.skills.find(s => s.skill === 'org-confidentiality-guard')
  ck('projection carries breadcrumb_verdict_key', cg && cg.breadcrumb_verdict_key === 'verdict' && cg.breadcrumb_pass_value === 'PASS')

  // never emit a skill absent from the index
  r = routeSkills({ build_class: 'software', has_payments: true }, { skills: [] })
  ck('empty index -> emits nothing', r.routed.length === 0 && r.optional.length === 0)

  console.log(`skill-router selftest: ${pass}/${pass + fail} passed`)
  return fail === 0
}

// ── CLI ──
const argv = process.argv.slice(2)
if (argv[0] === '--selftest') {
  process.exit(selftest() ? 0 : 1)
} else if (argv.length >= 4) {
  const [signalsPath, indexPath, outRouting, outRequired] = argv
  const signals = JSON.parse(fs.readFileSync(signalsPath, 'utf8'))
  const index = JSON.parse(fs.readFileSync(indexPath, 'utf8'))
  const routing = routeSkills(signals, index)
  const ledger = { schema_version: 1, committed_at: signals.committed_at || new Date().toISOString().slice(0, 10), build_class: signals.build_class || 'software', signals: routing.signals, routed: routing.routed, optional: routing.optional, note: 'committed pre-build; fail-closed via skill-readiness.sh' }
  fs.writeFileSync(outRouting, JSON.stringify(ledger, null, 2) + '\n')
  fs.writeFileSync(outRequired, JSON.stringify(toRequiredSkills(routing), null, 2) + '\n')
  console.error(`skill-router: ${routing.routed.length} required, ${routing.optional.length} optional -> ${outRouting}, ${outRequired}`)
} else {
  console.error('usage: skill-router.mjs <signals.json> <skill-index.json> <out-routing.json> <out-required.json> | --selftest')
  process.exit(2)
}
