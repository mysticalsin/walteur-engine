// src/server.js
//
// HTTP server factory + single request handler for the URL shortener (AGENTS.md
// §3/§5/§7, PLAN.md §3). This module owns ROUTING and the request lifecycle ONLY —
// it imports the store (src/store.js) and the validators (src/validate.js) rather
// than re-implementing either, and it sends every response through the shared
// sendJson/sendError helpers (src/errors.js) so the wire envelope stays uniform.
//
// The load-bearing seam: createServer() returns an UNSTARTED http.Server. It never
// calls .listen() — that is bin/server.js's job — which is exactly what lets the
// test suite bind an ephemeral listen(0) port per instance without a fixed-port
// clash (.claude/rules/code-style.md).
//
// Contract implemented here (route-THEN-method matching):
//   POST /shorten  -> 201 { code, shortUrl }        (body-capped, typed-error validated)
//   GET  /:code    -> 302 Location: <url>, empty body | 404 CODE_NOT_FOUND
//   known path, wrong method -> 405 METHOD_NOT_ALLOWED + Allow header
//   unknown path            -> 404 NOT_FOUND
//   any unexpected throw     -> 500 INTERNAL_ERROR (no stack ever on the wire)

import http from 'node:http';
import { AppError, sendJson, sendError, ERRORS } from './errors.js';
import { createStore } from './store.js';
import { validateShortenBody, validateUrl } from './validate.js';

/**
 * Hard cap on the accumulated request-body byte length for POST /shorten. Enforced
 * WHILE reading the stream (not after) so an adversarial client cannot pin unbounded
 * memory before we ever reach JSON.parse — the classic unbounded-buffer DoS
 * (AGENTS.md §5). 1 MiB is far above any legitimate `{ "url": "..." }` payload; a
 * URL past this length is not a real shortening request.
 * @type {number}
 */
const MAX_BODY_BYTES = 1024 * 1024; // 1 MiB

/**
 * The single shorten route. Anchored so `/shorten/anything` does NOT match it and
 * falls through to the unknown-path 404 rather than being treated as a shorten.
 * @type {string}
 */
const SHORTEN_PATH = '/shorten';

/**
 * A path is a code lookup iff it is a single non-empty segment under root with no
 * further slashes: `/abc12345`. This deliberately does NOT match `/`, `/a/b`, or a
 * trailing-slash form — those are unknown paths, not malformed code lookups, so they
 * get NOT_FOUND (path) rather than CODE_NOT_FOUND (code). We do NOT constrain the
 * segment to the base64url alphabet here: an 8-char base64url code is a subset of
 * this, and a well-formed-but-nonexistent code must still resolve to the
 * store-driven CODE_NOT_FOUND, which is the same answer any unknown single segment
 * gets — so a tighter charset check would only add a branch with no behavioral gain.
 * @type {RegExp}
 */
const CODE_PATH = /^\/([^/]+)$/;

/**
 * Read the full request body as a Buffer while enforcing MAX_BODY_BYTES. Resolves
 * with the collected Buffer on a clean end; rejects with an AppError('PAYLOAD_TOO_LARGE')
 * the instant the running byte total exceeds the cap, after destroying the socket so
 * no further bytes are buffered.
 *
 * We resolve/reject exactly once (guarded by `settled`) because 'error' can fire
 * after we have already destroyed the request on an over-cap condition, and a double
 * settle would otherwise surface as an unhandled rejection.
 *
 * @param {import('node:http').IncomingMessage} req
 * @returns {Promise<Buffer>}
 */
function readBody(req) {
  return new Promise((resolve, reject) => {
    /** @type {Buffer[]} */
    const chunks = [];
    let total = 0;
    let settled = false;

    const settle = (fn, value) => {
      if (settled) return;
      settled = true;
      fn(value);
    };

    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        // Over cap: stop accumulating BEFORE any parse is attempted, so an
        // adversarial client cannot pin unbounded memory. We PAUSE (not destroy) the
        // request here — destroying the socket now would also kill the 413 response
        // we still owe the client. The caller sends 413 and then signals connection
        // close; the unconsumed remainder is discarded by the resume+drain below.
        chunks.length = 0; // release what we buffered — we will never parse it.
        req.pause();
        settle(reject, new AppError('PAYLOAD_TOO_LARGE', 'Request body exceeds the 1 MiB limit.'));
        return;
      }
      chunks.push(chunk);
    });

    req.on('end', () => settle(resolve, Buffer.concat(chunks)));

    // A transport-level error (or the destroy() above) surfaces here. If we already
    // rejected with PAYLOAD_TOO_LARGE, the `settled` guard swallows this so we never
    // double-settle; otherwise it is a genuine read failure -> INTERNAL_ERROR upstream.
    req.on('error', (err) => settle(reject, err));
  });
}

/**
 * Derive the absolute short URL for a freshly minted code from the REQUEST, never a
 * hardcoded host/port (the test suite binds listen(0), so the port is only known at
 * request time). Precedence:
 *   1. BASE_URL env override, if set — for a service fronted by a fixed public origin.
 *      Joined without duplicating a slash regardless of a trailing slash in BASE_URL.
 *   2. Otherwise reconstruct from the request: `x-forwarded-proto` (a proxy/LB may
 *      terminate TLS) falling back to http, plus the Host header the client sent.
 *
 * @param {import('node:http').IncomingMessage} req
 * @param {string} code
 * @returns {string}
 */
function buildShortUrl(req, code) {
  const base = process.env.BASE_URL;
  if (base) {
    return `${base.replace(/\/+$/, '')}/${code}`;
  }
  const proto = req.headers['x-forwarded-proto'] || 'http';
  // Guard: a genuinely absent Host header (e.g. a raw HTTP/1.0 request) must NOT produce
  // "http://undefined/<code>" (a non-navigable, malformed URL shipped as a 201 success).
  // Fall back to 'localhost' so the returned shortUrl is always a valid, parseable URL.
  // NOTE: when BASE_URL is unset, shortUrl is derived from client-controlled Host/X-Forwarded-Proto
  // and MUST NOT be trusted as a canonical origin (see README §4 non-goals) — the STORED/redirected
  // href is always the canonicalized target and is unaffected by this reflection.
  const host = req.headers.host || 'localhost';
  return `${proto}://${host}/${code}`;
}

/**
 * Handle POST /shorten end-to-end: body cap -> empty-body gate -> JSON.parse ->
 * shape validation -> URL scheme allowlist -> store.save -> 201. Every failure mode
 * is a typed AppError translated to sendError by the caller's catch, EXCEPT the two
 * pre-validation gates (empty/invalid JSON) which map directly here so the client
 * gets EMPTY_BODY / INVALID_JSON rather than a generic parse crash.
 *
 * @param {import('node:http').IncomingMessage} req
 * @param {import('node:http').ServerResponse} res
 * @param {{ has: (c: string) => boolean, get: (c: string) => string | undefined, save: (u: string) => string }} store
 */
async function handleShorten(req, res, store) {
  const raw = await readBody(req); // may throw AppError('PAYLOAD_TOO_LARGE') — propagates.

  // Empty body is a distinct, actionable client error — not "invalid JSON".
  if (raw.length === 0) {
    throw new AppError('EMPTY_BODY', 'Request body is empty; expected JSON { "url": "..." }.');
  }

  let parsed;
  try {
    parsed = JSON.parse(raw.toString('utf8'));
  } catch {
    // Map the raw SyntaxError to a typed client error — a malformed body is the
    // client's fault, never a 500. We intentionally do not echo the parser message
    // (it can contain a fragment of the offending input).
    throw new AppError('INVALID_JSON', 'Request body is not valid JSON.');
  }

  // Shape gate then scheme allowlist. Both throw typed AppErrors (MISSING_URL /
  // INVALID_TYPE / INVALID_URL / DISALLOWED_PROTOCOL) that the caller's catch turns
  // into the correct 4xx via sendError. validateUrl returns the CANONICAL href — we
  // store and redirect that, never the raw client string.
  const rawUrl = validateShortenBody(parsed);
  const href = validateUrl(rawUrl);

  const code = store.save(href); // may throw AppError('CODE_GEN_EXHAUSTED') — propagates.

  sendJson(res, 201, { code, shortUrl: buildShortUrl(req, code) });
}

/**
 * Handle GET /:code: resolve the code against the store and 302-redirect to the
 * stored canonical URL, or 404 CODE_NOT_FOUND for an unknown code. The redirect body
 * is intentionally empty — but we still call res.end() so the response is fully
 * flushed and the socket does not linger half-open (a common node:test hang cause,
 * .claude/rules/testing.md).
 *
 * @param {import('node:http').ServerResponse} res
 * @param {string} code
 * @param {{ has: (c: string) => boolean, get: (c: string) => string | undefined }} store
 */
function handleRedirect(res, code, store) {
  if (!store.has(code)) {
    sendError(res, ERRORS.CODE_NOT_FOUND, 'CODE_NOT_FOUND', 'No URL is registered for this code.');
    return;
  }
  const url = store.get(code);
  res.setHeader('Location', url);
  res.writeHead(302);
  res.end(); // empty, drained body — Location carries the redirect target.
}

/**
 * Build the single request handler bound to `store`. Route-THEN-method: we first
 * decide WHICH known path the request targets, and only then check the METHOD, so a
 * known path hit with the wrong verb yields 405 + Allow (not a misleading 404).
 *
 * @param {{ has: (c: string) => boolean, get: (c: string) => string | undefined, save: (u: string) => string }} store
 * @returns {(req: import('node:http').IncomingMessage, res: import('node:http').ServerResponse) => Promise<void>}
 */
function makeHandler(store) {
  return async function handler(req, res) {
    // Strip the query string / fragment before routing: only the pathname decides the
    // route. A dummy origin is required by the WHATWG URL parser for a path-only input;
    // it never appears anywhere in a response.
    let pathname;
    try {
      pathname = new URL(req.url, 'http://internal.invalid').pathname;
    } catch {
      // req.url malformed enough that even path extraction fails — treat as unknown path.
      pathname = req.url;
    }

    try {
      // --- Route 1: the shorten endpoint (exact path match). ---
      if (pathname === SHORTEN_PATH) {
        if (req.method !== 'POST') {
          res.setHeader('Allow', 'POST');
          sendError(res, ERRORS.METHOD_NOT_ALLOWED, 'METHOD_NOT_ALLOWED', 'Use POST for /shorten.');
          return;
        }
        await handleShorten(req, res, store);
        return;
      }

      // --- Route 2: a single-segment code lookup (/:code). ---
      const codeMatch = CODE_PATH.exec(pathname);
      if (codeMatch) {
        if (req.method !== 'GET') {
          res.setHeader('Allow', 'GET');
          sendError(res, ERRORS.METHOD_NOT_ALLOWED, 'METHOD_NOT_ALLOWED', 'Use GET for /:code.');
          return;
        }
        handleRedirect(res, codeMatch[1], store);
        return;
      }

      // --- No known route matched: unknown path. ---
      sendError(res, ERRORS.NOT_FOUND, 'NOT_FOUND', 'No such route.');
    } catch (err) {
      // A typed AppError carries its own client-safe code/status — forward it verbatim
      // (this is how EMPTY_BODY / INVALID_JSON / PAYLOAD_TOO_LARGE / the validation
      // codes / CODE_GEN_EXHAUSTED reach the client). Anything else is an UNEXPECTED
      // internal fault: log the full detail server-side, return a generic 500, and
      // NEVER put a stack trace or raw message on the wire (AGENTS.md §5).
      if (res.headersSent) {
        // The response already started streaming; we cannot rewrite the status. Abort
        // the socket rather than emit a corrupt half-response, and log for triage.
        logServerError('response-already-sent', err, req);
        res.destroy();
        return;
      }
      if (err instanceof AppError) {
        if (err.code === 'PAYLOAD_TOO_LARGE') {
          // We refused the body mid-stream, so the request is only partially read.
          // Tell the client we are closing this connection (a keep-alive reuse would
          // desync on the unread remainder), send the 413, then resume+discard any
          // remaining inbound bytes so the socket drains and closes cleanly instead
          // of the client seeing a raw connection reset.
          res.setHeader('Connection', 'close');
          sendError(res, err.status, err.code, err.message);
          req.resume(); // drain and discard the rest; nothing is buffered or parsed.
          return;
        }
        sendError(res, err.status, err.code, err.message);
        return;
      }
      logServerError('unhandled', err, req);
      sendError(res, ERRORS.INTERNAL_ERROR, 'INTERNAL_ERROR', 'An unexpected error occurred.');
    }
  };
}

/**
 * Structured, single-line server-side error log. Emitted to stderr ONLY — never to
 * the client. Carries no request body and no secrets: just method + pathname + the
 * error name/message/stack for operator triage. This is the "log full detail
 * server-side only" half of the no-leak contract (AGENTS.md §5, §14 layer 12).
 *
 * @param {string} kind
 * @param {unknown} err
 * @param {import('node:http').IncomingMessage} req
 */
function logServerError(kind, err, req) {
  const record = {
    level: 'error',
    at: new Date().toISOString(),
    kind,
    method: req.method,
    path: (req.url || '').split('?')[0],
    err:
      err instanceof Error
        ? { name: err.name, message: err.message, stack: err.stack }
        : { value: String(err) },
  };
  // stderr, structured JSON — does not pollute stdout and never reaches the response.
  process.stderr.write(`${JSON.stringify(record)}\n`);
}

/**
 * Factory: return an UNSTARTED http.Server wired to a store. Callers may inject a
 * store (tests inject a stub to force the CODE_GEN_EXHAUSTED / 500 branches); by
 * default a fresh in-memory store is created per server instance so two servers in
 * one process never share mutable state.
 *
 * IMPORTANT: this NEVER calls .listen(). The returned server is inert until the
 * caller (bin/server.js in production, the test suite otherwise) binds a port.
 *
 * @param {{ store?: { has: (c: string) => boolean, get: (c: string) => string | undefined, save: (u: string) => string } }} [options]
 * @returns {import('node:http').Server}
 */
export function createServer({ store = createStore() } = {}) {
  return http.createServer(makeHandler(store));
}
