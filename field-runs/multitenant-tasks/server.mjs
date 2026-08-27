// server.mjs — HTTP surface over core.mjs with DENY-BY-DEFAULT tenant isolation.
//
// Auth chokepoint: every request except GET / , GET /app.js , GET /healthz requires TWO headers:
//   X-Tenant-Id: <tenantId>   AND   Authorization: Bearer <token>
// The (tenantId -> token) map is read from env WALTEUR_TENANT_TOKENS ONLY (a JSON string), never from a
// file — there are zero credential VALUES committed anywhere. Tokens are compared in constant time via
// crypto.timingSafeEqual. Missing/blank/unknown-tenant/wrong-token => 401 with an EMPTY body (no leak of
// which tenant exists or whether a role matched). Authenticated requests carry tenantId straight into
// core.mjs's owned() chokepoint — isolation is NOT reimplemented here; cross-tenant access is denied there
// (403 on write, 404/null on read). Logs are structured JSON to stdout with the Authorization header and
// any token field REDACTED to "***".
//
// Node built-ins only (node:http, node:crypto, node:fs, node:path, node:url) — zero external deps.

import http from 'node:http';
import crypto from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createStore } from './core.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, 'public');
const BODY_LIMIT = 1024 * 1024; // 1MB cap

// Structured JSON log to stdout. REDACTS any credential-bearing field to "***" so a token can never be
// written to a log line, even by accident.
const REDACT_KEYS = new Set(['authorization', 'token', 'bearer', 'x-token', 'tenant_tokens']);
export function logLine(obj) {
  const safe = {};
  for (const [k, v] of Object.entries(obj)) {
    safe[k] = REDACT_KEYS.has(k.toLowerCase()) ? '***' : v;
  }
  process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), ...safe }) + '\n');
}

// Load the tenant->token map from env ONLY. Absent/blank/malformed => empty map => deny-by-default
// (every request 401s). This is the single place credentials enter the process.
function loadTenantTokens() {
  const raw = process.env.WALTEUR_TENANT_TOKENS;
  if (!raw || !raw.trim()) return {};
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed;
  } catch {
    // fall through to empty map — never crash, never log the raw value
  }
  return {};
}

// Constant-time credential compare. Returns true only when the presented token exactly matches the
// configured token for tenantId. Uses timingSafeEqual on equal-length buffers; unequal lengths are
// compared against a fixed-length dummy so the failure path stays timing-flat and never short-circuits
// on length alone.
function tokenMatches(expected, presented) {
  if (typeof expected !== 'string' || typeof presented !== 'string') return false;
  const a = Buffer.from(expected, 'utf8');
  const b = Buffer.from(presented, 'utf8');
  if (a.length !== b.length) {
    // still burn a comparison to avoid a length-based timing oracle
    crypto.timingSafeEqual(a, a);
    return false;
  }
  return crypto.timingSafeEqual(a, b);
}

// authenticate(req, tokens) -> tenantId | null. Deny-by-default: any missing/blank/mismatched credential
// yields null (the caller turns that into a 401 with no body). Accepts the canonical
// `Authorization: Bearer <token>` and, as an alias, `X-Token: <token>`.
export function authenticate(req, tokens) {
  const tenantId = (req.headers['x-tenant-id'] || '').toString().trim();
  if (!tenantId) return null;

  const authz = (req.headers['authorization'] || '').toString();
  let presented = '';
  const m = /^Bearer\s+(.+)$/i.exec(authz);
  if (m) presented = m[1].trim();
  if (!presented) presented = (req.headers['x-token'] || '').toString().trim();
  if (!presented) return null;

  const expected = Object.prototype.hasOwnProperty.call(tokens, tenantId) ? tokens[tenantId] : null;
  if (typeof expected !== 'string' || expected.length === 0) {
    // unknown tenant: still run a constant-time compare against a dummy, then deny
    tokenMatches(presented, presented);
    return null;
  }
  return tokenMatches(expected, presented) ? tenantId : null;
}

// Read and JSON-parse a request body with a hard 1MB cap. Resolves { ok, value } or { ok:false, code }.
function readJsonBody(req) {
  return new Promise((resolve) => {
    let size = 0;
    const chunks = [];
    let aborted = false;
    req.on('data', (c) => {
      if (aborted) return;
      size += c.length;
      if (size > BODY_LIMIT) {
        aborted = true;
        resolve({ ok: false, code: 413 });
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      if (aborted) return;
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw.trim()) return resolve({ ok: true, value: {} });
      try {
        resolve({ ok: true, value: JSON.parse(raw) });
      } catch {
        resolve({ ok: false, code: 400 });
      }
    });
    req.on('error', () => resolve({ ok: false, code: 400 }));
  });
}

function send(res, status, body, headers = {}) {
  const payload = body === undefined ? '' : (typeof body === 'string' ? body : JSON.stringify(body));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', ...headers });
  res.end(payload);
}

// 401 helper: empty body, no existence/role leak.
function deny401(res) {
  res.writeHead(401, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end('');
}

const STATIC = {
  '/': { file: 'index.html', type: 'text/html; charset=utf-8' },
  '/app.js': { file: 'app.js', type: 'text/javascript; charset=utf-8' },
};

// createServer(store) -> an UNLISTENED http.Server, so tests can server.listen(0) on an ephemeral port.
// The tenant token map is resolved per-request from env, so a test can set WALTEUR_TENANT_TOKENS before
// each call without restarting the process.
export function createServer(store = createStore()) {
  return http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const method = req.method || 'GET';
    const route = `${method} ${url.pathname}`;
    const start = process.hrtime.bigint();

    const finish = (status, tenantId) => {
      const ms = Number(process.hrtime.bigint() - start) / 1e6;
      logLine({
        level: status >= 500 ? 'error' : status >= 400 ? 'warn' : 'info',
        method, path: url.pathname, status, tenant: tenantId || '-',
        ms: Math.round(ms * 1000) / 1000,
        authorization: req.headers['authorization'] ? '***' : undefined,
      });
    };

    try {
      // ── Static + health (no auth) ────────────────────────────────────────────────────────────
      if (method === 'GET' && STATIC[url.pathname]) {
        const { file, type } = STATIC[url.pathname];
        const fp = path.join(PUBLIC_DIR, file);
        if (!existsSync(fp)) { send(res, 404, { error: 'not found' }); return finish(404); }
        res.writeHead(200, { 'Content-Type': type });
        res.end(readFileSync(fp));
        return finish(200);
      }
      // Health probe (no auth). Both /healthz and /health answer — /health is the cutover plan's
      // health_check target (curl -sf localhost:8137/health). Liveness only; leaks no tenant data.
      if (method === 'GET' && (url.pathname === '/healthz' || url.pathname === '/health')) {
        send(res, 200, { status: 'ok' });
        return finish(200);
      }

      // ── Auth chokepoint (deny-by-default) ────────────────────────────────────────────────────
      const tokens = loadTenantTokens();
      const tenantId = authenticate(req, tokens);
      if (!tenantId) { deny401(res); return finish(401); }

      // ── Authenticated routes — all isolation enforced by core.mjs owned() ────────────────────
      // POST /api/tasks
      if (method === 'POST' && url.pathname === '/api/tasks') {
        const body = await readJsonBody(req);
        if (!body.ok) { send(res, body.code, body.code === 413 ? { error: 'body too large' } : { error: 'invalid json' }); return finish(body.code, tenantId); }
        const title = body.value && body.value.title;
        if (!title || !String(title).trim()) { send(res, 400, { error: 'title required' }); return finish(400, tenantId); }
        const task = store.add(tenantId, title);
        send(res, 201, task);
        return finish(201, tenantId);
      }

      // GET /api/tasks  (tenant-scoped list)
      if (method === 'GET' && url.pathname === '/api/tasks') {
        send(res, 200, store.list(tenantId));
        return finish(200, tenantId);
      }

      // GET /api/audit  (tenant-scoped audit trail)
      if (method === 'GET' && url.pathname === '/api/audit') {
        send(res, 200, store.auditTrail(tenantId));
        return finish(200, tenantId);
      }

      // DELETE /api/tenant  (DSAR right-to-erasure for the CALLER's own tenant)
      if (method === 'DELETE' && url.pathname === '/api/tenant') {
        const erased = store.eraseTenant(tenantId);
        send(res, 200, { erased });
        return finish(200, tenantId);
      }

      // /api/tasks/:id  and  /api/tasks/:id/complete
      const taskMatch = /^\/api\/tasks\/(\d+)$/.exec(url.pathname);
      const completeMatch = /^\/api\/tasks\/(\d+)\/complete$/.exec(url.pathname);

      if (taskMatch) {
        const id = Number(taskMatch[1]);
        if (method === 'GET') {
          const task = store.get(tenantId, id); // null on cross-tenant/absent — no leak
          if (!task) { send(res, 404, { error: 'not found' }); return finish(404, tenantId); }
          send(res, 200, task);
          return finish(200, tenantId);
        }
        if (method === 'DELETE') {
          try {
            store.remove(tenantId, id); // throws 'forbidden' on cross-tenant
            res.writeHead(204); res.end();
            return finish(204, tenantId);
          } catch (e) {
            return handleOwnershipError(e, res, finish, tenantId, store, id);
          }
        }
        send(res, 405, { error: 'method not allowed' }, { Allow: 'GET, DELETE' });
        return finish(405, tenantId);
      }

      if (completeMatch && method === 'POST') {
        const id = Number(completeMatch[1]);
        try {
          const task = store.complete(tenantId, id); // throws 'forbidden' on cross-tenant
          send(res, 200, task);
          return finish(200, tenantId);
        } catch (e) {
          return handleOwnershipError(e, res, finish, tenantId, store, id);
        }
      }

      send(res, 404, { error: 'not found' });
      return finish(404, tenantId);
    } catch (err) {
      send(res, 500, { error: 'internal error' });
      return finish(500);
    }
  });
}

// core.mjs throws 'forbidden' for BOTH a cross-tenant access AND an absent id (both deny-by-default).
// To return an honest status without leaking another tenant's existence, we distinguish only by whether
// the id exists at all FOR THIS TENANT is impossible to know — so: a write to a row that belongs to
// nobody we can see is 'forbidden' => 403. We cannot tell absent vs cross-tenant without leaking, so the
// deny-by-default surface returns 403 for any non-owned write. This is intentional (no existence oracle).
function handleOwnershipError(e, res, finish, tenantId, store, id) {
  if (e && /forbidden/.test(e.message)) {
    send(res, 403, { error: 'forbidden' });
    return finish(403, tenantId);
  }
  send(res, 500, { error: 'internal error' });
  return finish(500, tenantId);
}

// ── CLI entrypoint: listen on PORT (default 8137) when run directly ──────────────────────────────
const invokedDirectly = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const port = Number(process.env.PORT) || 8137;
  const store = createStore();
  const server = createServer(store);
  server.listen(port, () => {
    logLine({ level: 'info', event: 'listening', port, pid: process.pid });
  });
  const shutdown = (sig) => { logLine({ level: 'info', event: 'shutdown', signal: sig }); server.close(() => process.exit(0)); };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

export default createServer;
