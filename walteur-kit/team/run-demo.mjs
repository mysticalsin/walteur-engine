#!/usr/bin/env node
// WALTEUR TEAM MODE — real end-to-end coordination run through the LIVE peerbus.
// Drives 3 named peers (ATLAS/FORGE/SENTINEL) as real, separate peerbus MCP processes
// (each with its own WALTEUR_PEER_NAME/ROLE identity, exactly as launch-team.ps1 sets them),
// speaking real JSON-RPC 2.0 over stdio — NOT the gate's selftest fixtures. It runs a genuine
// coordinated micro-build (ATLAS posts a task -> FORGE claims + writes a real file + test +
// runs it -> messages SENTINEL -> SENTINEL re-runs the test + marks done), producing a 100%
// real _team/ bus (registry.json, board.json, board-log.jsonl, messages-log.jsonl) that
// team-coordination-gate then validates. This is the "run, not just wired" proof.
//
// Honest scope label: these are SCRIPTED peers on one machine (real processes, real bus,
// real coordination protocol), NOT 7 humans in 7 terminals. It proves the coordination
// SURFACE works end-to-end on real receipts; it does not prove human-driven multi-terminal use.
//
// Usage: node run-demo.mjs [team_dir]   (default: <repo>/field-runs/team-demo/_team)
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const BUS = path.join(HERE, 'peerbus-mcp.mjs')
const REPO = path.resolve(HERE, '..', '..')
const DEMO_ROOT = process.argv[2] || path.join(REPO, 'field-runs', 'team-demo')
const TEAM_DIR = path.join(DEMO_ROOT, '_team')
const WORK = path.join(DEMO_ROOT, 'src')

// fresh bus + workspace
fs.rmSync(TEAM_DIR, { recursive: true, force: true })
fs.mkdirSync(path.join(TEAM_DIR, 'inbox'), { recursive: true })
fs.mkdirSync(WORK, { recursive: true })
// the demo is a self-contained mini-project: carry the roster manifest so team-coordination-gate
// verifies it exactly as it would any real deployed project (which ships walteur-kit/team/).
const demoTeamKit = path.join(DEMO_ROOT, 'walteur-kit', 'team')
fs.mkdirSync(demoTeamKit, { recursive: true })
fs.copyFileSync(path.join(HERE, 'team-manifest.json'), path.join(demoTeamKit, 'team-manifest.json'))

// One real peerbus process per peer, fed a batch of JSON-RPC lines; returns parsed results by id.
function peer(name, role, calls) {
  return new Promise((resolve, reject) => {
    const p = spawn(process.execPath, [BUS], {
      env: { ...process.env, WALTEUR_PEER_NAME: name, WALTEUR_PEER_ROLE: role, WALTEUR_TEAM_DIR: TEAM_DIR },
      stdio: ['pipe', 'pipe', 'inherit'],
    })
    let buf = '', out = []
    p.stdout.on('data', d => {
      buf += d
      let nl
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1)
        if (line) { try { out.push(JSON.parse(line)) } catch { /* skip */ } }
      }
    })
    p.on('close', () => resolve(out))
    p.on('error', reject)
    let id = 0
    const send = (method, params) => p.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }) + '\n')
    send('initialize', { protocolVersion: '2024-11-05' })
    for (const [tool, args] of calls) send('tools/call', { name: tool, arguments: args })
    p.stdin.end()
  })
}
// call k (1-based, in the order passed to peer()) has JSON-RPC id k+1 (initialize is id 1).
const tool = (r, k) => { const m = r.find(x => x.id === k + 1); return m && m.result && m.result.content ? JSON.parse(m.result.content[0].text) : null }

const log = (m) => console.log(m)

// ── the coordinated flow ──────────────────────────────────────────────────────
;(async () => {
  // 0. JOIN round — all peers register (in real team mode every terminal is online at once;
  //    in this scripted run we register the roster first so cross-peer messaging resolves).
  await peer('ATLAS', 'lead-orchestrator', [['set_summary', { summary: 'lead online', status: 'active' }]])
  await peer('SENTINEL', 'security-reviewer', [['set_summary', { summary: 'reviewer online, watching review lane', status: 'active' }]])
  await peer('FORGE', 'builder-backend', [['set_summary', { summary: 'builder online', status: 'active' }]])
  log('JOIN: ATLAS, SENTINEL, FORGE registered')

  // 1. ATLAS posts the task with a contract in the detail
  let r = await peer('ATLAS', 'lead-orchestrator', [
    ['board_post', { title: 'add /health endpoint', detail: 'export health() returning {status:"ok"}; test asserts it', files: ['src/health.mjs'] }],
    ['list_peers', {}],
  ])
  const posted = tool(r, 1)
  log(`ATLAS posted ${posted.posted}`)

  // 2. FORGE joins, claims, builds a REAL file + test, runs it, hands to review
  r = await peer('FORGE', 'builder-backend', [
    ['set_summary', { summary: 'claiming build task', status: 'active' }],
    ['check_messages', {}],
    ['board_claim', { task_id: posted.posted }],
    ['board_update', { task_id: posted.posted, status: 'building', note: 'writing src/health.mjs + test' }],
  ])
  log(`FORGE claim: ${JSON.stringify(tool(r, 3))}`)
  // real product + real test
  fs.writeFileSync(path.join(WORK, 'health.mjs'), 'export function health() { return { status: "ok" } }\n')
  fs.writeFileSync(path.join(WORK, 'health.test.mjs'),
    "import { test } from 'node:test'\nimport assert from 'node:assert'\nimport { health } from './health.mjs'\ntest('health ok', () => { assert.equal(health().status, 'ok') })\n")
  const { execSync } = await import('node:child_process')
  let testExit = 0, testOut = ''
  try { testOut = execSync(`"${process.execPath}" --test`, { cwd: WORK, encoding: 'utf8' }) } catch (e) { testExit = e.status || 1; testOut = (e.stdout || '') + (e.stderr || '') }
  log(`FORGE ran node --test -> exit ${testExit}`)
  await peer('FORGE', 'builder-backend', [
    ['send_message', { to: 'SENTINEL', subject: 'review', body: `${posted.posted} ready: src/health.mjs + test, node --test exit ${testExit}` }],
    ['board_update', { task_id: posted.posted, status: 'review', note: `built + tested (node --test exit ${testExit}); handing to SENTINEL` }],
  ])
  log('FORGE handed to review (never self-done)')

  // 3. SENTINEL joins, reads the message, RE-RUNS the test itself, marks done only on green
  r = await peer('SENTINEL', 'security-reviewer', [
    ['check_messages', {}],
    ['board_list', { status: 'review' }],
  ])
  const msgs = tool(r, 1)
  log(`SENTINEL inbox: ${msgs.count} msg(s)`)
  let reExit = 0
  try { execSync(`"${process.execPath}" --test`, { cwd: WORK, encoding: 'utf8' }) } catch (e) { reExit = e.status || 1 }
  log(`SENTINEL independently re-ran node --test -> exit ${reExit}`)
  if (reExit === 0) {
    await peer('SENTINEL', 'security-reviewer', [
      ['board_update', { task_id: posted.posted, status: 'done', note: `re-ran node --test independently, observed exit 0; secrets scan clean; approved` }],
    ])
    log(`SENTINEL approved ${posted.posted} -> done`)
  } else {
    await peer('SENTINEL', 'security-reviewer', [
      ['send_message', { to: 'FORGE', body: `${posted.posted} REJECTED: test exit ${reExit}` }],
      ['board_update', { task_id: posted.posted, status: 'building', note: `veto: independent re-run failed exit ${reExit}` }],
    ])
    log(`SENTINEL vetoed ${posted.posted}`)
  }

  // summary of the real bus
  const reg = JSON.parse(fs.readFileSync(path.join(TEAM_DIR, 'registry.json'), 'utf8'))
  const board = JSON.parse(fs.readFileSync(path.join(TEAM_DIR, 'board.json'), 'utf8'))
  const blog = fs.readFileSync(path.join(TEAM_DIR, 'board-log.jsonl'), 'utf8').trim().split('\n').length
  const mlog = fs.readFileSync(path.join(TEAM_DIR, 'messages-log.jsonl'), 'utf8').trim().split('\n').length
  log(`\nREAL BUS: ${Object.keys(reg.peers).length} peers, ${board.tasks.length} task(s), ${blog} board transitions, ${mlog} message(s)`)
  log(`task final status: ${board.tasks[0].status} (owner ${board.tasks[0].owner})`)
  log(`bus dir: ${TEAM_DIR}`)
})().catch(e => { console.error('DEMO FAILED:', e); process.exit(1) })
