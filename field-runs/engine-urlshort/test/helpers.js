// test/helpers.js
//
// Zero-dependency HTTP test harness for the URL-shortener integration suite
// (AGENTS.md §4, .claude/rules/testing.md, PLAN.md §2). This module is the ONLY
// place the suite talks to the network, so the two spike-confirmed footguns on this
// project are contained here once instead of copy-pasted into every test:
//
//   1. `listen(0)` is ASYNC. `server.address()` returns null until the 'listening'
//      event fires — reading the port synchronously after `.listen(0)` is a real
//      race on Node v24.13.1, not paranoia. startServer() awaits 'listening' BEFORE
//      reading `.address().port` so callers always get a bound port.
//
//   2. An undrained keep-alive response body is the #1 confirmed cause of a hung
//      `node --test` run here. req() drains the response to 'end' on EVERY path,
//      including the empty 302 redirect body, so no socket lingers half-open and the
//      runner can exit cleanly.
//
// We drive the REAL server over REAL HTTP using ONLY node:http — no supertest, no
// fetch (node:http does NOT auto-follow redirects; that is a feature here — we assert
// the 302 + Location directly). Zero third-party dependencies, matching the project's
// hard constraint.

import http from 'node:http';
import { once } from 'node:events';
import { createServer } from '../src/server.js';

/**
 * Start a fresh server instance on an OS-assigned ephemeral port and return both the
 * server (so the caller can close it in t.after) and the resolved port.
 *
 * The `await once(server, 'listening')` is load-bearing: `.listen(0)` schedules the
 * bind asynchronously, and `server.address()` is `null` until the 'listening' event
 * fires. Reading the port before that await is the intermittent race documented in
 * .claude/rules/testing.md — so we await first, THEN read the port.
 *
 * An injectable `store` is forwarded to createServer() so a test can force the
 * collision/exhaustion branches deterministically without relying on a real 6-byte
 * code collision.
 *
 * @param {{ store?: { has: (c: string) => boolean, get: (c: string) => string | undefined, save: (u: string) => string } }} [options]
 * @returns {Promise<{ server: import('node:http').Server, port: number }>}
 */
export async function startServer(options = {}) {
  const server = createServer(options);
  server.listen(0);
  await once(server, 'listening'); // REQUIRED before address() is valid — real race, not theoretical.
  const address = server.address();
  if (address === null || typeof address !== 'object') {
    // Defensive: a non-object address means we are not bound to a TCP port (e.g. a
    // pipe/socket path). That is never expected here — fail loud rather than return a
    // bogus port and produce a confusing downstream connection error.
    throw new Error(`startServer: expected a TCP AddressInfo, got ${JSON.stringify(address)}`);
  }
  return { server, port: address.port };
}

/**
 * Issue a single HTTP request against 127.0.0.1:<port> and resolve once the response
 * body is FULLY drained. Resolves with the status, the raw headers, the raw text body,
 * and a lazily-parsed `json` (present only when the body parses as JSON — a 302 with an
 * empty body has no `json`, and that is fine).
 *
 * Draining to 'end' on every path — including the empty 302 body — is what lets the
 * socket close and `node --test` exit cleanly. `res.on('error', reject)` and
 * `request.on('error', reject)` are BOTH attached so a transport failure surfaces as a
 * rejected promise, never a silently-swallowed error or a hang.
 *
 * @param {number} port
 * @param {{ method?: string, path?: string, headers?: Record<string, string>, body?: string }} spec
 * @returns {Promise<{ status: number, headers: import('node:http').IncomingHttpHeaders, text: string, json?: unknown }>}
 */
export function req(port, { method = 'GET', path = '/', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const request = http.request(
      { host: '127.0.0.1', port, method, path, headers },
      (res) => {
        /** @type {Buffer[]} */
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          /** @type {{ status: number, headers: import('node:http').IncomingHttpHeaders, text: string, json?: unknown }} */
          const result = {
            status: /** @type {number} */ (res.statusCode),
            headers: res.headers,
            text,
          };
          // Parse the body as JSON when it is non-empty and well-formed. The 302 body
          // is empty (no `json` key); every error/success JSON body parses. We never
          // throw on a non-JSON body here — the test asserts on `.status`/`.text` in
          // that case — so an unparseable body is simply left without `.json`.
          if (text.length > 0) {
            try {
              result.json = JSON.parse(text);
            } catch {
              // Non-JSON body: leave `json` undefined; callers that need it assert its
              // presence explicitly. This never masks a real failure — the status and
              // text are still resolved for the caller to inspect.
            }
          }
          resolve(result);
        });
        // A mid-response transport error must reject, never hang the drain above.
        res.on('error', reject);
      }
    );

    // A connection-level error (refused, reset) must reject rather than leave the
    // promise pending — a pending promise here would hang the whole `node --test` run.
    request.on('error', reject);

    if (body !== undefined) {
      request.write(body);
    }
    request.end();
  });
}
