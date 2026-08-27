#!/usr/bin/env node
// WALTEUR skill-index-build — parse a Org-style skills library into a machine-readable
// skill-index.json that the skill router (walteur.js Preflight) and the fail-closed
// skill-readiness gate query. Run ONCE per skills-library change, not per build.
//
// Usage:
//   node skill-index-build.mjs <skills-root> [out.json] [YYYY-MM-DD]
//
// Each SKILL.md contributes one entry: discipline (from the numbered parent folder),
// phase_affinity (from frontmatter phase/suggested_stage), signal_tags (keyword lexicon
// over description + body), trigger_keywords, breadcrumb (declared or conventional),
// hard_gate, and an optional verdict-key/pass-value for stamp-with-verdict skills.
import fs from 'node:fs'
import path from 'node:path'

const root = process.argv[2]
const outPath = process.argv[3] || 'skill-index.json'
const stampDate = process.argv[4] || new Date().toISOString().slice(0, 10)
if (!root) { console.error('skill-index-build: missing <skills-root>'); process.exit(2) }

const DISCIPLINE_BY_NUM = {
  '00': 'quality', '01': 'sales', '02': 'communications', '03': 'delivery', '04': 'engineering',
  '05': 'strategy', '06': 'marketing', '07': 'management', '08': 'process', '09': 'talent',
  '10': 'hr', '11': 'finance', '12': 'it', '13': 'legal', '14': 'security', '15': 'operations-data',
  '16': 'meta', '17': 'ai-governance',
}
function disciplineOf(folder) {
  const m = folder.match(/(\d{2})/)
  return (m && DISCIPLINE_BY_NUM[m[1]]) || 'other'
}

// Map frontmatter phase + suggested_stage to WALTEUR runtime phases.
function phaseAffinity(phase, stage) {
  const p = (phase || '').toLowerCase(), s = (stage || '').toLowerCase()
  const out = new Set()
  if (s.includes('discovery') || p.includes('discover')) out.add('Scope')
  if (s.includes('pre-development') || s.includes('before-any-major-commitment') || p.includes('pre-commitment')) out.add('Plan')
  if (p.includes('engineering')) out.add('Build')
  if (s.includes('pre-merge') || s.includes('pre-release') || s.includes('quality-gate')) out.add('Review')
  if (p.includes('brand') || p.includes('design')) out.add('Review')
  if (s.includes('external-release') || p.includes('security')) { out.add('Audit'); out.add('Review') }
  if (out.size === 0) out.add('Review')
  return [...out]
}

// Keyword lexicon: a hit means the skill is relevant when that build-signal is asserted.
const SIGNAL_LEXICON = [
  ['regulated', /regulat|banking|pharma|defen[cs]e|healthcare|public sector|hipaa|soc ?2|gdpr|compliance/i],
  ['has_pii', /\bpii\b|personal data|personal information|privacy|confidential|sensitive data|\bnda\b/i],
  ['external_surface', /external|press release|public|client|case study|linkedin|conference|marketing|\bdeck\b|board pack|outreach/i],
  ['has_payments', /payment|billing|invoice|stripe|checkout|pricing|revenue/i],
  ['has_api_boundary', /\bapi\b|endpoint|\brest api\b|graphql|webhook|integration boundary/i],
  ['has_ui', /\bui\b|\bux\b|\bdesign\b|frontend|interface|\bbrand\b|visual|landing page/i],
  ['has_db', /database|schema|migration|\bsql\b|postgres|data model/i],
  ['is_ai_agent', /\bllm\b|ai agent|agentic|prompt engineer|model risk|anthropic|openai|\brag\b|fine-tun|chatbot|copilot/i],
  ['security_sensitive', /security|secure coding|vulnerab|injection|owasp|authz|penetration|pentest/i],
]
function signalTags(text) {
  return SIGNAL_LEXICON.filter(([, re]) => re.test(text)).map(([tag]) => tag)
}

const HARD_GATE_RE = /HARD GATE|MANDATORY GATE|Mandatory gate|no exceptions|no commitment ships|MUST (run|pass|complete)|ships without/i

const STOP = new Set(('the a an of to and or for in on with use using when before after any that this it is are as by into not no your you our their a org output skill skills which who what before-any whether').split(' '))
function triggerKeywords(desc) {
  const words = (desc || '').toLowerCase().match(/[a-z][a-z-]{3,}/g) || []
  const seen = new Set(), out = []
  for (const w of words) { if (STOP.has(w) || seen.has(w)) continue; seen.add(w); out.push(w); if (out.length >= 12) break }
  return out
}

function parseFrontmatter(src) {
  const m = src.match(/^---\s*\n([\s\S]*?)\n---/)
  const fm = {}
  if (m) for (const line of m[1].split('\n')) {
    const mm = line.match(/^([A-Za-z0-9_]+):\s*(.*)$/)
    if (mm) fm[mm[1]] = mm[2].trim()
  }
  return fm
}

// Walk the library for */SKILL.md
function findSkillFiles(dir, acc = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) findSkillFiles(p, acc)
    else if (e.isFile() && e.name === 'SKILL.md') acc.push(p)
  }
  return acc
}

const files = findSkillFiles(root).sort()
const skills = []
for (const file of files) {
  const src = fs.readFileSync(file, 'utf8')
  const fm = parseFrontmatter(src)
  const name = fm.name || path.basename(path.dirname(file))
  const rel = path.relative(root, file).split(path.sep).join('/')
  const topFolder = rel.split('/')[0] || ''
  const discipline = disciplineOf(topFolder)
  // declared breadcrumb (a walteur-kit/*.json pass-stamp the skill writes), else convention
  const declared = (src.match(/walteur-kit\/[A-Za-z0-9_./-]+\.json/) || [])[0]
  const breadcrumb = declared || `walteur-kit/skills/${name}.json`
  // signal_tags come from the CURATED one-line description (the trigger), not the whole
  // body — scanning the body over-matches and the router would fire ~every skill.
  const desc = fm.description || ''
  // hard_gate = the skill itself declares a mandatory gate (an explicit ## HARD GATE
  // heading, or "HARD GATE / Mandatory / no exceptions" in the trigger line).
  const hard_gate = HARD_GATE_RE.test(desc) || /^#{1,3}\s*HARD GATE/im.test(src)
  const entry = {
    skill: name,
    discipline,
    phase_affinity: phaseAffinity(fm.phase, fm.suggested_stage),
    signal_tags: signalTags(desc),
    trigger_keywords: triggerKeywords(desc),
    breadcrumb,
    hard_gate,
    source_path: rel,
  }
  if (declared && /"?verdict"?/i.test(src)) { entry.breadcrumb_verdict_key = 'verdict'; entry.breadcrumb_pass_value = 'PASS' }
  skills.push(entry)
}

const index = {
  schema_version: 1,
  generated_at: stampDate,
  source_root: path.basename(root),
  skill_count: skills.length,
  skills,
}
fs.writeFileSync(outPath, JSON.stringify(index, null, 2) + '\n')
console.error(`skill-index-build: wrote ${skills.length} skills to ${outPath}`)
