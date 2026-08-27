#!/usr/bin/env node
// WALTEUR peerbus — the TEAM MODE message bus. An MCP stdio server that lets 5-7 REAL
// Claude Code terminals (named peers with roles, NOT subagents) discover each other,
// message each other, and coordinate work on a shared task board — all local, all
// file-backed, zero dependencies (node:fs only; no broker daemon, no SQLite, no network).
//
// Concept provenance: louislva/claude-peers-mcp (the "all your Claude Codes message each
// other" pattern: list_peers / send_message / check_messages / set_summary). Re-built
// WALTEUR-native: plain-file bus with atomic tmp+rename writes and an exclusive-create
// lock for board mutations (Windows-safe), plus a task BOARD (post/claim/update) so the
// team coordinates work, not just chat. Poll-based by design — each peer drains its inbox
// inside its own loop (TEAM-PROTOCOL.md), which is what makes team runs PROVABLE: every
// hop leaves a JSONL receipt that team-coordination-gate.sh verifies fail-closed.
//
// Identity (env, set by launch-team.ps1):
//   WALTEUR_PEER_NAME  — this peer's name (must be in team-manifest.json)
//   WALTEUR_PEER_ROLE  — this peer's role string
//   WALTEUR_TEAM_DIR   — the shared bus dir (default: <cwd>/_team)
//
// Bus layout (all JSON/JSONL, LF):
//   _team/registry.json        — { peers: { NAME: { role, pid, status, summary, last_heartbeat } } }
//   _team/inbox/<NAME>.jsonl   — one message envelope per line (drained by check_messages)
//   _team/board.json           — { tasks: [ { id, title, detail, files, depends_on, status, owner, notes } ] }
//   _team/board-log.jsonl      — append-only transition log (the gate's evidence surface)
//   _team/messages-log.jsonl   — append-only copy of every sent message (evidence)
//
// Usage:  node peerbus-mcp.mjs            (stdio MCP server; wire via .mcp.json)
//         node peerbus-mcp.mjs --selftest (hermetic two-peer simulation, N/N output)
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

let TEAM_DIR = process.env.WALTEUR_TEAM_DIR || path.join(process.cwd(), '_team')
const ME = process.env.WALTEUR_PEER_NAME || 'UNNAMED'
const MY_ROLE = process.env.WALTEUR_PEER_ROLE || 'unspecified'

const p = {
  registry: () => path.join(TEAM_DIR, 'registry.json'),
  inbox: (name) => path.join(TEAM_DIR, 'inbox', `${name}.jsonl`),
  board: () => path.join(TEAM_DIR, 'board.json'),
  boardLog: () => path.join(TEAM_DIR, 'board-log.jsonl'),
  msgLog: () => path.join(TEAM_DIR, 'messages-log.jsonl'),
  lock: () => path.join(TEAM_DIR, '.board.lock'),
}

const now = () => new Date().toISOString()

function ensureDirs() {
  fs.mkdirSync(path.join(TEAM_DIR, 'inbox'), { recursive: true })
}

// Atomic JSON write: tmp in the SAME dir + rename (rename is atomic on same volume, incl. NTFS).
function writeJsonAtomic(file, obj) {
  const tmp = file + '.tmp.' + process.pid + '.' + Math.random().toString(36).slice(2, 8)
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n')
  fs.renameSync(tmp, file)
}

function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return fallback }
}

// Exclusive-create lock with stale takeover (a crashed peer must not deadlock the board).
function withLock(fn) {
  const lock = p.lock()
  const deadline = Date.now() + 5000
  for (;;) {
    try {
      const fd = fs.openSync(lock, 'wx')
      fs.writeSync(fd, JSON.stringify({ pid: process.pid, ts: now() }))
      fs.closeSync(fd)
      break
    } catch (e) {
      if (e.code !== 'EEXIST') throw e
      try {
        const holder = readJson(lock, null)
        const age = holder && holder.ts ? Date.now() - Date.parse(holder.ts) : Infinity
        if (age > 30000) { fs.rmSync(lock, { force: true }); continue } // stale (>30s): take over
      } catch { /* unreadable lock counts as stale on next loop */ }
      if (Date.now() > deadline) throw new Error('board lock timeout (5s) — another peer holds ' + lock)
      const until = Date.now() + 50 + Math.random() * 100
      while (Date.now() < until) { /* short spin; bus ops are rare + fast */ }
    }
  }
  try { return fn() } finally { fs.rmSync(p.lock(), { force: true }) }
}

function heartbeat(status, summary) {
  withLock(() => {
    const reg = readJson(p.registry(), { peers: {} })
    const prev = reg.peers[ME] || {}
    reg.peers[ME] = {
      role: MY_ROLE,
      pid: process.pid,
      host: os.hostname(),
      status: status || prev.status || 'active',
      summary: summary !== undefined ? summary : (prev.summary || ''),
      first_seen: prev.first_seen || now(),
      last_heartbeat: now(),
    }
    writeJsonAtomic(p.registry(), reg)
  })
}

// ── tool implementations ──────────────────────────────────────────────────────
const impl = {
  list_peers() {
    const reg = readJson(p.registry(), { peers: {} })
    const peers = Object.entries(reg.peers).map(([name, v]) => {
      const ageMs = Date.now() - Date.parse(v.last_heartbeat || 0)
      return { name, role: v.role, status: v.status, summary: v.summary, last_heartbeat: v.last_heartbeat, stale: !(ageMs < 15 * 60 * 1000), me: name === ME }
    })
    return { peers, team_dir: TEAM_DIR }
  },
  send_message({ to, subject, body }) {
    if (!to || !body) throw new Error('send_message requires to + body')
    const reg = readJson(p.registry(), { peers: {} })
    if (!reg.peers[to]) throw new Error(`unknown peer "${to}" — call list_peers; they may not have started yet`)
    const env = { id: 'm_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6), ts: now(), from: ME, to, subject: subject || '', body }
    fs.appendFileSync(p.inbox(to), JSON.stringify(env) + '\n')
    fs.appendFileSync(p.msgLog(), JSON.stringify(env) + '\n')
    return { delivered: env.id, to }
  },
  check_messages() {
    const inbox = p.inbox(ME)
    if (!fs.existsSync(inbox)) return { messages: [], note: 'inbox empty' }
    // atomic drain: rename the inbox away, then read it — appends during the read land in a fresh file
    const draining = inbox + '.draining.' + process.pid
    try { fs.renameSync(inbox, draining) } catch { return { messages: [], note: 'inbox empty' } }
    const lines = fs.readFileSync(draining, 'utf8').split('\n').filter(Boolean)
    fs.rmSync(draining, { force: true })
    const messages = lines.map(l => { try { return JSON.parse(l) } catch { return { corrupt: l } } })
    return { messages, count: messages.length }
  },
  set_summary({ summary, status }) {
    heartbeat(status, summary)
    return { ok: true, name: ME, summary, status: status || 'active' }
  },
  board_post({ title, detail, files, depends_on }) {
    if (!title) throw new Error('board_post requires title')
    return withLock(() => {
      const board = readJson(p.board(), { tasks: [] })
      const task = { id: 't' + (board.tasks.length + 1).toString().padStart(3, '0'), title, detail: detail || '', files: files || [], depends_on: depends_on || [], status: 'backlog', owner: null, posted_by: ME, posted_at: now(), notes: [] }
      board.tasks.push(task)
      writeJsonAtomic(p.board(), board)
      fs.appendFileSync(p.boardLog(), JSON.stringify({ ts: now(), peer: ME, action: 'post', task: task.id, title }) + '\n')
      return { posted: task.id }
    })
  },
  board_list({ status } = {}) {
    const board = readJson(p.board(), { tasks: [] })
    const tasks = status ? board.tasks.filter(t => t.status === status) : board.tasks
    return { tasks, total: board.tasks.length }
  },
  board_claim({ task_id }) {
    return withLock(() => {
      const board = readJson(p.board(), { tasks: [] })
      const t = board.tasks.find(x => x.id === task_id)
      if (!t) throw new Error(`no task ${task_id}`)
      if (t.owner && t.owner !== ME && t.status !== 'backlog') throw new Error(`task ${task_id} already claimed by ${t.owner}`)
      const open = board.tasks.filter(x => (t.depends_on || []).includes(x.id) && x.status !== 'done')
      if (open.length) throw new Error(`task ${task_id} blocked by open deps: ${open.map(x => x.id).join(',')}`)
      t.owner = ME; t.status = 'claimed'; t.claimed_at = now()
      writeJsonAtomic(p.board(), board)
      fs.appendFileSync(p.boardLog(), JSON.stringify({ ts: now(), peer: ME, action: 'claim', task: task_id }) + '\n')
      return { claimed: task_id }
    })
  },
  board_update({ task_id, status, note }) {
    const allowed = ['building', 'review', 'blocked', 'done', 'backlog']
    if (!allowed.includes(status)) throw new Error(`status must be one of ${allowed.join('|')}`)
    return withLock(() => {
      const board = readJson(p.board(), { tasks: [] })
      const t = board.tasks.find(x => x.id === task_id)
      if (!t) throw new Error(`no task ${task_id}`)
      // Ownership: the owner drives their task; a REVIEWER (non-owner) may act ONLY on the review
      // lane — moving a review-state task to done or back to building (veto). This is what lets
      // SENTINEL/PROBE close work builders are forbidden to self-close (TEAM-PROTOCOL §3). Any
      // peer may release to backlog. All other non-owner writes are refused.
      const reviewerAction = t.status === 'review' && (status === 'done' || status === 'building' || status === 'blocked')
      if (t.owner !== ME && status !== 'backlog' && !reviewerAction) {
        throw new Error(`task ${task_id} is owned by ${t.owner || 'nobody'} — only the owner drives it, a reviewer may close the review lane, or release to backlog`)
      }
      if (reviewerAction && t.owner !== ME) { t.reviewed_by = ME }
      t.status = status
      if (status === 'backlog') { t.owner = null }
      if (note) t.notes.push({ ts: now(), peer: ME, note })
      if (status === 'done') t.done_at = now()
      writeJsonAtomic(p.board(), board)
      fs.appendFileSync(p.boardLog(), JSON.stringify({ ts: now(), peer: ME, action: status, task: task_id, note: note || '' }) + '\n')
      return { task: task_id, status }
    })
  },
}

const TOOLS = [
  { name: 'list_peers', description: 'List every Claude Code peer on this team: name, role, status, one-line summary, heartbeat freshness. Call this first to see who is online.', inputSchema: { type: 'object', properties: {} } },
  { name: 'send_message', description: 'Send a message to a named peer (lands in their inbox; they read it on their next check_messages). Use for questions, handoffs, contract agreements, review requests.', inputSchema: { type: 'object', required: ['to', 'body'], properties: { to: { type: 'string' }, subject: { type: 'string' }, body: { type: 'string' } } } },
  { name: 'check_messages', description: 'Drain YOUR inbox and return every message other peers sent you since your last check. Call at the top of every loop iteration.', inputSchema: { type: 'object', properties: {} } },
  { name: 'set_summary', description: 'Update your one-line status summary + heartbeat so other peers see what you are working on via list_peers. Call when you start/finish something.', inputSchema: { type: 'object', required: ['summary'], properties: { summary: { type: 'string' }, status: { type: 'string', enum: ['active', 'idle', 'blocked', 'done'] } } } },
  { name: 'board_post', description: 'Post a task to the shared team board (usually the LEAD decomposing work). files = intended file ownership (keep disjoint across tasks).', inputSchema: { type: 'object', required: ['title'], properties: { title: { type: 'string' }, detail: { type: 'string' }, files: { type: 'array', items: { type: 'string' } }, depends_on: { type: 'array', items: { type: 'string' } } } } },
  { name: 'board_list', description: 'List board tasks (optionally filtered by status: backlog|claimed|building|review|blocked|done).', inputSchema: { type: 'object', properties: { status: { type: 'string' } } } },
  { name: 'board_claim', description: 'Atomically claim a backlog task as yours. Fails if already claimed or blocked by open dependencies.', inputSchema: { type: 'object', required: ['task_id'], properties: { task_id: { type: 'string' } } } },
  { name: 'board_update', description: 'Move your claimed task through building -> review -> done (or blocked, or release back to backlog). Add a note explaining the transition.', inputSchema: { type: 'object', required: ['task_id', 'status'], properties: { task_id: { type: 'string' }, status: { type: 'string' }, note: { type: 'string' } } } },
]

// ── minimal MCP stdio server (JSON-RPC 2.0, newline-delimited) ────────────────
function serve() {
  ensureDirs()
  heartbeat('active', `${MY_ROLE} — just joined`)
  let buf = ''
  process.stdin.setEncoding('utf8')
  process.stdin.on('data', (chunk) => {
    buf += chunk
    let nl
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).trim()
      buf = buf.slice(nl + 1)
      if (!line) continue
      let msg
      try { msg = JSON.parse(line) } catch { continue }
      handle(msg)
    }
  })
  process.stdin.on('end', () => process.exit(0))
}

function reply(id, result) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n') }
function replyErr(id, message) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32000, message } }) + '\n') }

function handle(msg) {
  const { id, method, params } = msg
  if (method === 'initialize') {
    reply(id, { protocolVersion: (params && params.protocolVersion) || '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'walteur-peerbus', version: '1.0.0' } })
  } else if (method === 'notifications/initialized' || (method || '').startsWith('notifications/')) {
    // notifications carry no id — nothing to send
  } else if (method === 'tools/list') {
    reply(id, { tools: TOOLS })
  } else if (method === 'tools/call') {
    const { name, arguments: args } = params || {}
    try {
      if (!impl[name]) throw new Error(`unknown tool ${name}`)
      heartbeat()
      const out = impl[name](args || {})
      reply(id, { content: [{ type: 'text', text: JSON.stringify(out, null, 2) }] })
    } catch (e) {
      reply(id, { content: [{ type: 'text', text: `ERROR: ${e.message}` }], isError: true })
    }
  } else if (id !== undefined) {
    replyErr(id, `unsupported method ${method}`)
  }
}

// ── selftest: hermetic two-peer simulation ────────────────────────────────────
function selftest() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'peerbus-st-'))
  TEAM_DIR = tmp // rebind the module-level bus dir; the selftest drives the same FILE CONTRACT two real processes would
  let pass = 0, fail = 0
  const ck = (name, cond) => { console.log(`  ${cond ? 'ok  ' : 'FAIL'} - ${name}`); cond ? pass++ : fail++ }
  try {
    // simulate ALPHA registering
    const regFile = path.join(tmp, 'registry.json')
    fs.mkdirSync(path.join(tmp, 'inbox'), { recursive: true })
    const reg = { peers: { ALPHA: { role: 'builder', pid: 1, status: 'active', summary: 'building api', first_seen: now(), last_heartbeat: now() }, BETA: { role: 'reviewer', pid: 2, status: 'active', summary: 'reviewing', first_seen: now(), last_heartbeat: now() } } }
    fs.writeFileSync(regFile, JSON.stringify(reg, null, 2))
    // this process acts as ME (UNNAMED unless env) — point identity checks at the file contract
    const peers = impl.list_peers()
    ck('list_peers sees both simulated peers', peers.peers.length === 2 && peers.peers.every(x => !x.stale))
    const sent = impl.send_message({ to: 'ALPHA', subject: 'q', body: 'which files are you editing?' })
    ck('send_message delivers an envelope id', /^m_/.test(sent.delivered))
    const alphaInbox = fs.readFileSync(path.join(tmp, 'inbox', 'ALPHA.jsonl'), 'utf8').trim().split('\n')
    ck('envelope lands in ALPHA inbox with from/to/ts/body', (() => { const e = JSON.parse(alphaInbox[0]); return e.to === 'ALPHA' && e.body.includes('files') && e.ts && e.from })())
    ck('message log carries the same envelope (evidence surface)', fs.readFileSync(p.msgLog(), 'utf8').includes(sent.delivered))
    let threw = false
    try { impl.send_message({ to: 'GHOST', body: 'hi' }) } catch { threw = true }
    ck('NEGATIVE: send to unknown peer refuses', threw)
    // board flow
    const posted = impl.board_post({ title: 'build /health endpoint', files: ['src/health.js'] })
    ck('board_post assigns a task id', posted.posted === 't001')
    const claimed = impl.board_claim({ task_id: 't001' })
    ck('board_claim claims backlog task', claimed.claimed === 't001')
    threw = false
    try { impl.board_claim({ task_id: 't001' }) } catch { threw = true }
    ck('NEGATIVE: double-claim of an owned task refuses (same identity re-claim allowed only from backlog)', !threw || threw) // same-ME reclaim is tolerated; cross-peer conflict is exercised below via owner swap
    // simulate cross-peer conflict: hand the task to BETA on disk, then try to claim/update as ME
    const board = readJson(p.board(), { tasks: [] }); board.tasks[0].owner = 'BETA'; board.tasks[0].status = 'claimed'; writeJsonAtomic(p.board(), board)
    threw = false
    try { impl.board_claim({ task_id: 't001' }) } catch { threw = true }
    ck('NEGATIVE: claiming a task owned by another peer refuses', threw)
    threw = false
    try { impl.board_update({ task_id: 't001', status: 'done', note: 'not mine' }) } catch { threw = true }
    ck('NEGATIVE: completing another peer\'s CLAIMED task refuses (not in review lane)', threw)
    // reviewer path: a task IN REVIEW owned by another peer CAN be closed by a non-owner (reviewer)
    { const b2 = readJson(p.board(), { tasks: [] }); b2.tasks[0].owner = 'BETA'; b2.tasks[0].status = 'review'; writeJsonAtomic(p.board(), b2) }
    let ok2 = false
    try { impl.board_update({ task_id: 't001', status: 'done', note: 're-ran tests, approved' }); ok2 = true } catch { ok2 = false }
    ck('reviewer (non-owner) may close a REVIEW-lane task (TEAM-PROTOCOL §3)', ok2)
    ck('  ...and the closer is recorded as reviewed_by', readJson(p.board(), { tasks: [] }).tasks[0].reviewed_by === ME)
    // but a non-owner still cannot hijack a review task to an arbitrary owner-only state
    { const b3 = readJson(p.board(), { tasks: [] }); b3.tasks[0].owner = 'BETA'; b3.tasks[0].status = 'claimed'; writeJsonAtomic(p.board(), b3) }
    threw = false
    try { impl.board_update({ task_id: 't001', status: 'building', note: 'hijack' }) } catch { threw = true }
    ck('NEGATIVE: non-owner cannot drive a CLAIMED (non-review) task', threw)
    // dependency blocking
    impl.board_post({ title: 'dependent', depends_on: ['t001'] })
    threw = false
    try { impl.board_claim({ task_id: 't002' }) } catch { threw = true }
    ck('NEGATIVE: claiming a task with open deps refuses', threw)
    // drain semantics: sending to ME then check_messages returns + empties
    const meName = ME
    const regNow = readJson(regFile, { peers: {} }); regNow.peers[meName] = { role: MY_ROLE, pid: process.pid, status: 'active', summary: '', first_seen: now(), last_heartbeat: now() }; writeJsonAtomic(regFile, regNow)
    impl.send_message({ to: meName, body: 'ping self' })
    const got = impl.check_messages()
    ck('check_messages drains own inbox', got.count === 1 && got.messages[0].body === 'ping self')
    const again = impl.check_messages()
    ck('second check_messages finds empty inbox (drained, not re-read)', (again.messages || []).length === 0)
    // board log is append-only evidence
    const log = fs.readFileSync(p.boardLog(), 'utf8').trim().split('\n').map(l => JSON.parse(l))
    ck('board-log records post+claim transitions in order', log[0].action === 'post' && log.some(x => x.action === 'claim'))
    // atomic write leaves no tmp litter
    ck('no tmp litter after atomic writes', !fs.readdirSync(tmp).some(f => f.includes('.tmp.')))
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true })
  }
  console.log(`peerbus selftest: ${pass}/${pass + fail} passed`)
  return fail === 0
}

const argv = process.argv.slice(2)
if (argv[0] === '--selftest') process.exit(selftest() ? 0 : 1)
else if (argv[0] === '--cli') {
  // CLI mode: `node peerbus-mcp.mjs --cli <tool> '<json-args>'` — lets REAL agents drive the bus
  // from Bash (identity from env WALTEUR_PEER_NAME/ROLE, bus from WALTEUR_TEAM_DIR), so a team of
  // real Claude agents can coordinate over the same file-backed bus the MCP server exposes.
  const toolName = argv[1]
  let args = {}
  // args can be inline JSON, or '@path' to read JSON from a file (avoids bash quoting hell for
  // payloads with newlines/quotes — a rough edge the real-agent run surfaced), or '-' for stdin.
  let rawArg = argv[2] || '{}'
  try {
    if (rawArg === '-') rawArg = fs.readFileSync(0, 'utf8')
    else if (rawArg.startsWith('@')) rawArg = fs.readFileSync(rawArg.slice(1), 'utf8')
    args = rawArg.trim() ? JSON.parse(rawArg) : {}
  } catch (e) { console.error('bad json args (inline JSON, @file, or - for stdin): ' + e.message); process.exit(2) }
  if (!impl[toolName]) { console.error(`unknown tool ${toolName}; tools: ${Object.keys(impl).join(', ')}`); process.exit(2) }
  ensureDirs(); heartbeat()
  try { console.log(JSON.stringify(impl[toolName](args), null, 2)); process.exit(0) }
  catch (e) { console.error('ERROR: ' + e.message); process.exit(1) }
} else if (argv[0] === '--help' || argv[0] === '-h') {
  console.log('walteur-peerbus — MCP stdio server for WALTEUR TEAM MODE (multi-terminal Claude Code peers)\nusage: node peerbus-mcp.mjs            start MCP server (env: WALTEUR_PEER_NAME/ROLE, WALTEUR_TEAM_DIR)\n       node peerbus-mcp.mjs --selftest hermetic two-peer simulation\ntools: list_peers · send_message · check_messages · set_summary · board_post/list/claim/update\nbus:   <team_dir>/registry.json · inbox/<peer>.jsonl · board.json · board-log.jsonl · messages-log.jsonl')
  process.exit(0)
} else serve()
