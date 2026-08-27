// server.mjs — HTTP surface over core.mjs with DENY-BY-DEFAULT tenant isolation for WEBHOOK SUBSCRIPTIONS.
//
// Auth chokepoint: every request except GET / , GET /app.js , GET /health(z) requires TWO headers:
//   X-Tenant: <tenantId>   AND   Authorization: Bearer <token>
// The (tenantId -> token) map is read from env WALTEUR_TENANT_TOKENS ONLY (a JSON string), never from a
// file — there are zero credential VALUES committed anywhere. Tokens are compared in constant time via
// crypto.timingSafeEqual. Missing/blank/unknown-tenant/wrong-token => 401 with an EMPTY body (no leak of
// which tenant exists). Authenticated requests carry tenantId straight into core.mjs's owned() chokepoint
// — isolation is NOT reimplemented here; cross-tenant access is denied there (403 on write, 404/null on
// read). Logs are structured JSON to stdout with the Authorization header and any token REDACTED to "***".
//
// Webhook signing secrets: minted in core on create + rotate-secret and returned to the caller EXACTLY
// ONCE in the JSON response. Only a sha256 fingerprint + last4 persist, so data.json holds subscriptions +
// audit rows and ZERO secret values by construction.
//
// Persistence: the store is mirrored to data.json after every mutation (best-effort, atomic-ish via a
// tmp+rename) and reloaded on boot.
//
// Node built-ins only (node:http, node:crypto, node:fs, node:path, node:url) — zero external deps.

import http from 'node:http';
import crypto from 'node:crypto';
import { readFileSync, existsSync, writeFileSync, renameSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createStore } from './core.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, 'public');
const DATA_FILE = process.env.WEBHOOKS_DATA_FILE || path.join(__dirname, 'data.json');
const BODY_LIMIT = 1024 * 1024; // 1MB cap

// Validation errors from core that map to a 400 (bad request) rather than a 403 (ownership). Kept as one
// list so the create + update paths classify identically.
const VALIDATION_RE = /required|must be|not allowed|valid https URL|host not allowed/;

// Structured JSON log to stdout. REDACTS any credential-bearing field to "***" so a token (or a webhook
// signing secret) can never be written to a log line, even by accident.
const REDACT_KEYS = new Set(['authorization', 'token', 'bearer', 'x-token', 'tenant_tokens', 'secret']);
export function logLine(obj) {
  const safe = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined) continue;
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
// configured token for tenantId. Uses timingSafeEqual on equal-length buffers; unequal lengths burn a
// fixed comparison so the failure path stays timing-flat and never short-circuits on length alone.
function tokenMatches(expected, presented) {
  if (typeof expected !== 'string' || typeof presented !== 'string') return false;
  const a = Buffer.from(expected, 'utf8');
  const b = Buffer.from(presented, 'utf8');
  if (a.length !== b.length) {
    crypto.timingSafeEqual(a, a); // burn a comparison to avoid a length-based timing oracle
    return false;
  }
  return crypto.timingSafeEqual(a, b);
}

// authenticate(req, tokens) -> tenantId | null. Deny-by-default: any missing/blank/mismatched credential
// yields null (the caller turns that into a 401 with no body). Accepts the canonical
// `Authorization: Bearer <token>` and, as an alias, `X-Token: <token>`.
export function authenticate(req, tokens) {
  const tenantId = (req.headers['x-tenant'] || req.headers['x-tenant-id'] || '').toString().trim();
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
      if (size > BODY_LIMIT) { aborted = true; resolve({ ok: false, code: 413 }); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      if (aborted) return;
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw.trim()) return resolve({ ok: true, value: {} });
      try { resolve({ ok: true, value: JSON.parse(raw) }); }
      catch { resolve({ ok: false, code: 400 }); }
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

// Best-effort durable persistence: write to a tmp file then rename over data.json (rename is atomic on the
// same volume). Errors are logged, never thrown — a persistence hiccup must not break a live request, and
// the in-memory store remains the source of truth for the response just sent.
function persist(store) {
  try {
    const tmp = DATA_FILE + '.tmp';
    writeFileSync(tmp, JSON.stringify(store.snapshot()));
    renameSync(tmp, DATA_FILE);
  } catch (e) {
    logLine({ level: 'error', event: 'persist_failed', error: String(e && e.message || e) });
  }
}

function hydrate(store) {
  try {
    if (existsSync(DATA_FILE)) store.load(JSON.parse(readFileSync(DATA_FILE, 'utf8')));
  } catch (e) {
    logLine({ level: 'warn', event: 'hydrate_failed', error: String(e && e.message || e) });
  }
}

// createServer(store, { persistOnMutate }) -> an UNLISTENED http.Server, so tests can server.listen(0) on
// an ephemeral port. The tenant token map is resolved per-request from env, so a test can set
// WALTEUR_TENANT_TOKENS before each call without restarting the process. persistOnMutate defaults to false
// so unit/integration tests stay filesystem-free; the CLI entrypoint turns it on.
export function createServer(store = createStore(), { persistOnMutate = false } = {}) {
  const save = () => { if (persistOnMutate) persist(store); };

  return http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const method = req.method || 'GET';
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
      // health_check target. Liveness only; leaks no tenant data.
      if (method === 'GET' && (url.pathname === '/healthz' || url.pathname === '/health')) {
        send(res, 200, { status: 'ok' });
        return finish(200);
      }

      // ── Auth chokepoint (deny-by-default) ────────────────────────────────────────────────────
      const tokens = loadTenantTokens();
      const tenantId = authenticate(req, tokens);
      if (!tenantId) { deny401(res); return finish(401); }

      // ── Authenticated routes — all isolation enforced by core.mjs owned() ────────────────────

      // GET /subscriptions  (tenant-scoped list of the caller's OWN subscriptions)
      if (method === 'GET' && url.pathname === '/subscriptions') {
        send(res, 200, store.getSubscriptions(tenantId));
        return finish(200, tenantId);
      }

      // POST /subscriptions  { url, eventType, active? }  -> create a subscription the caller OWNS.
      // The 201 response carries the signing `secret` ONCE; it is never returned again.
      if (method === 'POST' && url.pathname === '/subscriptions') {
        const body = await readJsonBody(req);
        if (!body.ok) { send(res, body.code, body.code === 413 ? { error: 'body too large' } : { error: 'invalid json' }); return finish(body.code, tenantId); }
        const input = body.value && typeof body.value === 'object' ? body.value : {};
        try {
          const sub = store.createSubscription(tenantId, {
            url: input.url, eventType: input.eventType, active: input.active,
          });
          save();
          send(res, 201, sub);
          return finish(201, tenantId);
        } catch (e) {
          send(res, 400, { error: String(e && e.message || 'bad request') });
          return finish(400, tenantId);
        }
      }

      // GET /audit  (tenant-scoped audit trail)
      if (method === 'GET' && url.pathname === '/audit') {
        send(res, 200, store.auditTrail(tenantId));
        return finish(200, tenantId);
      }

      // POST /admin/erase  (DSAR right-to-erasure for the CALLER's own tenant)
      if (method === 'POST' && url.pathname === '/admin/erase') {
        const erased = store.eraseTenant(tenantId);
        save();
        send(res, 200, { erased });
        return finish(200, tenantId);
      }

      // POST /subscriptions/:id/rotate-secret  -> rotate the signing secret of an OWNED subscription.
      // Matched BEFORE the bare /subscriptions/:id route. Returns the new `secret` ONCE.
      const rotateMatch = /^\/subscriptions\/([^/]+)\/rotate-secret$/.exec(url.pathname);
      if (rotateMatch) {
        const id = decodeURIComponent(rotateMatch[1]);
        if (method !== 'POST') {
          send(res, 405, { error: 'method not allowed' }, { Allow: 'POST' });
          return finish(405, tenantId);
        }
        try {
          const sub = store.rotateSecret(tenantId, id); // throws 'forbidden' on cross-tenant/absent
          save();
          send(res, 200, sub);
          return finish(200, tenantId);
        } catch (e) {
          return handleOwnershipError(e, res, finish, tenantId);
        }
      }

      // /subscriptions/:id  — GET one OWNED sub, PUT update one OWNED sub, DELETE one OWNED sub
      const subMatch = /^\/subscriptions\/([^/]+)$/.exec(url.pathname);
      if (subMatch) {
        const id = decodeURIComponent(subMatch[1]);
        if (method === 'GET') {
          const sub = store.getSubscription(tenantId, id); // null on cross-tenant/absent — no leak
          if (!sub) { send(res, 404, { error: 'not found' }); return finish(404, tenantId); }
          send(res, 200, sub);
          return finish(200, tenantId);
        }
        if (method === 'PUT') {
          const body = await readJsonBody(req);
          if (!body.ok) { send(res, body.code, body.code === 413 ? { error: 'body too large' } : { error: 'invalid json' }); return finish(body.code, tenantId); }
          const patch = {};
          const v = body.value && typeof body.value === 'object' ? body.value : {};
          if (v.url !== undefined) patch.url = v.url;
          if (v.eventType !== undefined) patch.eventType = v.eventType;
          if (v.active !== undefined) patch.active = v.active;
          try {
            const sub = store.updateSubscription(tenantId, id, patch); // throws 'forbidden' on cross-tenant/absent
            save();
            send(res, 200, sub);
            return finish(200, tenantId);
          } catch (e) {
            if (e && VALIDATION_RE.test(e.message) && !/forbidden/.test(e.message)) {
              send(res, 400, { error: e.message });
              return finish(400, tenantId);
            }
            return handleOwnershipError(e, res, finish, tenantId);
          }
        }
        if (method === 'DELETE') {
          try {
            store.deleteSubscription(tenantId, id); // throws 'forbidden' on cross-tenant/absent
            save();
            res.writeHead(204); res.end();
            return finish(204, tenantId);
          } catch (e) {
            return handleOwnershipError(e, res, finish, tenantId);
          }
        }
        send(res, 405, { error: 'method not allowed' }, { Allow: 'GET, PUT, DELETE' });
        return finish(405, tenantId);
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
// To return an honest status without leaking another tenant's existence, a write to a sub the caller does
// not OWN is 'forbidden' => 403. We cannot tell absent vs cross-tenant without leaking, so the
// deny-by-default surface returns 403 for any non-owned write (no existence oracle).
function handleOwnershipError(e, res, finish, tenantId) {
  if (e && /forbidden/.test(e.message)) {
    send(res, 403, { error: 'forbidden' });
    return finish(403, tenantId);
  }
  send(res, 500, { error: 'internal error' });
  return finish(500, tenantId);
}

// ── CLI entrypoint: listen on PORT (default 8209) when run directly ───────────────────────────────
const invokedDirectly = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const port = Number(process.env.PORT) || 8209;
  const store = createStore();
  hydrate(store);
  const server = createServer(store, { persistOnMutate: true });
  server.listen(port, () => {
    logLine({ level: 'info', event: 'listening', port, pid: process.pid, data_file: path.basename(DATA_FILE) });
  });
  const shutdown = (sig) => { logLine({ level: 'info', event: 'shutdown', signal: sig }); server.close(() => process.exit(0)); };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

export default createServer;
