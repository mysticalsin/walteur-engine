// test/http.test.js
//
// End-to-end HTTP integration suite. This suite IS the wire contract for the service
// (AGENTS.md §4/§7, PLAN.md §7 Correctness SLO): it drives the REAL server over REAL
// HTTP via node:http only (supertest-free, zero third-party deps) and pins every path
// on BOTH the HTTP status AND the typed `error.code` — because several codes share a
// status (INVALID_URL vs DISALLOWED_PROTOCOL are both 400; CODE_NOT_FOUND vs NOT_FOUND
// are both 404), so asserting the status alone would let a mislabeled error slip
// through silently.
//
// TDD provenance: this file was written as the failing contract FIRST (it imports
// ../src/server.js via test/helpers.js) and driven to green — see
// walteur-kit/skills/org-tdd-discipline.json.
//
// Per-test lifecycle discipline (the two spike-confirmed hang causes on this project):
//   - a FRESH server per test (isolated in-memory store — no cross-test code bleed);
//   - `t.after(() => new Promise((r) => server.close(r)))` that RETURNS the close
//     promise, so the runner blocks on port release before the next test and the
//     process exits cleanly instead of hanging on a lingering listener;
//   - every response body drained to 'end' inside req() (test/helpers.js), including
//     the empty 302 body.
//
// node:http does NOT auto-follow redirects — we assert `status === 302` and the
// `Location` header directly, never via fetch's auto-follow.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { startServer, req } from './helpers.js';
import { AppError } from '../src/errors.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * Absolute path to the proof artifact this suite emits after it runs. Kept as a repo
 * path under walteur-kit/ so the WALTEUR gate can find the per-code coverage receipt.
 */
const REPORT_PATH = join(__dirname, '..', 'walteur-kit', 'test-report.json');

/**
 * The full set of typed `error.code`s this integration suite is contracted to
 * exercise. Every entry here MUST be observed on the wire during the run; the
 * post-run coverage report asserts none is left `false`, so a silently-dropped error
 * path fails the build instead of passing unnoticed.
 * @type {readonly string[]}
 */
const REQUIRED_ERROR_CODES = Object.freeze([
  'DISALLOWED_PROTOCOL',
  'INVALID_URL',
  'INVALID_JSON',
  'EMPTY_BODY',
  'MISSING_URL',
  'INVALID_TYPE',
  'CODE_NOT_FOUND',
  'NOT_FOUND',
  'METHOD_NOT_ALLOWED',
  'PAYLOAD_TOO_LARGE',
  // The two 500-status codes. Both share HTTP 500 (like the 400/404 pairs above),
  // so status alone cannot tell them apart — the wire suite must pin error.code for
  // each. Neither is reachable with the DEFAULT store: CODE_GEN_EXHAUSTED needs a
  // store whose save() always collides, and INTERNAL_ERROR needs an unexpected
  // (non-AppError) throw at the trust boundary. Both are driven below via an INJECTED
  // store through startServer({ store }) — the seam wired at src/server.js:312. Listing
  // them here makes the self-policing coverage ledger (see the final `report` test)
  // FAIL if either 500 path ever stops being exercised on the wire.
  'CODE_GEN_EXHAUSTED',
  'INTERNAL_ERROR',
]);

/**
 * Mutable coverage ledger: flips a code's flag to `true` the moment that code is seen
 * on a real response body. Recorded by recordError() and serialized into the proof
 * artifact by the final `report` test.
 * @type {Record<string, boolean>}
 */
const errorCoverage = Object.fromEntries(REQUIRED_ERROR_CODES.map((c) => [c, false]));

/**
 * Per-test running tally of pass/fail, serialized into the report so the artifact
 * carries the suite result, not just the coverage map. Each case pushes exactly one
 * entry after its assertions succeed.
 * @type {Array<{ name: string, ok: true }>}
 */
const suiteResults = [];

/**
 * Assert a JSON error response pins BOTH the status and the typed code, and mark that
 * code as covered. This is the single choke point that guarantees "status AND
 * error.code" is checked uniformly for every typed path (never status alone).
 *
 * @param {{ status: number, json?: unknown }} res
 * @param {number} expectedStatus
 * @param {string} expectedCode
 */
function assertTypedError(res, expectedStatus, expectedCode) {
  assert.strictEqual(res.status, expectedStatus, `expected HTTP ${expectedStatus}, got ${res.status}`);
  assert.ok(res.json && typeof res.json === 'object', 'error response must have a JSON body');
  const body = /** @type {{ error?: { code?: string, message?: string } }} */ (res.json);
  assert.ok(body.error && typeof body.error === 'object', 'error body must be { error: { code, message } }');
  assert.strictEqual(body.error.code, expectedCode, `expected error.code ${expectedCode}, got ${body.error.code}`);
  assert.strictEqual(typeof body.error.message, 'string', 'error.message must be a string');
  assert.ok(body.error.message.length > 0, 'error.message must be non-empty');
  errorCoverage[expectedCode] = true;
}

/**
 * Register the fresh server's close as a RETURNED promise in t.after so the runner
 * blocks until the port is released. Returning (not just calling) the promise is what
 * prevents the inter-test port-not-released hang documented in .claude/rules/testing.md.
 *
 * @param {import('node:test').TestContext} t
 * @param {import('node:http').Server} server
 */
function closeAfter(t, server) {
  t.after(() => new Promise((resolve, reject) => {
    server.close((err) => (err ? reject(err) : resolve()));
  }));
}

// ===========================================================================
// (1) Happy round-trip: POST valid url -> 201, then GET the request-derived
//     code -> 302 to the SAME canonical URL. This is the core contract.
// ===========================================================================
test('happy round-trip: POST /shorten 201 -> GET /:code 302 to the canonical URL', async (t) => {
  const { server, port } = await startServer();
  closeAfter(t, server);

  // A URL that is already in canonical WHATWG form so the stored/redirected href is
  // byte-identical to what we sent — makes the Location assertion exact.
  const original = 'http://example.com/foo/bar';

  const post = await req(port, {
    method: 'POST',
    path: '/shorten',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ url: original }),
  });

  assert.strictEqual(post.status, 201, 'POST /shorten must return 201 Created');
  assert.ok(post.json && typeof post.json === 'object', '201 body must be JSON');
  const created = /** @type {{ code?: string, shortUrl?: string }} */ (post.json);
  assert.strictEqual(typeof created.code, 'string', 'response must carry a string code');
  assert.ok(created.code.length > 0, 'code must be non-empty');
  assert.strictEqual(typeof created.shortUrl, 'string', 'response must carry a string shortUrl');

  // Derive the code from the RETURNED shortUrl (not from a hardcoded assumption): the
  // shortUrl is request-derived (http://127.0.0.1:<port>/<code>), and its last path
  // segment must equal the returned code — proving shortUrl and code are consistent.
  const shortUrlPath = new URL(created.shortUrl).pathname; // "/<code>"
  const codeFromUrl = shortUrlPath.slice(1);
  assert.strictEqual(codeFromUrl, created.code, 'shortUrl last segment must equal the returned code');
  // And the shortUrl host must be the ephemeral test host, proving it was derived from
  // the request Host header, never hardcoded.
  assert.strictEqual(new URL(created.shortUrl).host, `127.0.0.1:${port}`, 'shortUrl host must be request-derived');

  // GET /:code -> 302 with Location === the original canonical href. node:http does
  // NOT auto-follow, so we assert the redirect directly. Empty body is drained by req().
  const redirect = await req(port, { method: 'GET', path: `/${codeFromUrl}` });
  assert.strictEqual(redirect.status, 302, 'GET /:code must 302 redirect');
  assert.strictEqual(redirect.headers.location, original, 'Location must be the original canonical URL');
  assert.strictEqual(redirect.text, '', '302 redirect body must be empty');

  suiteResults.push({ name: 'happy round-trip 201 -> 302', ok: true });
});

// ===========================================================================
// (2) DISALLOWED_PROTOCOL: ftp:// parses (has a host) but is not http(s) -> 400.
// ===========================================================================
test('POST /shorten ftp:// -> 400 DISALLOWED_PROTOCOL', async (t) => {
  const { server, port } = await startServer();
  closeAfter(t, server);

  const res = await req(port, {
    method: 'POST',
    path: '/shorten',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ url: 'ftp://ftp.example.com/file.txt' }),
  });
  assertTypedError(res, 400, 'DISALLOWED_PROTOCOL');
  suiteResults.push({ name: 'ftp:// -> DISALLOWED_PROTOCOL', ok: true });
});

// ===========================================================================
// (3) INVALID_URL: "http://" (scheme + // but no host) is the one http-family
//     input that makes new URL() throw -> mapped to INVALID_URL, NOT
//     DISALLOWED_PROTOCOL (both are 400 — the code must disambiguate).
// ===========================================================================
test('POST /shorten "http://" (no host) -> 400 INVALID_URL', async (t) => {
  const { server, port } = await startServer();
  closeAfter(t, server);

  const res = await req(port, {
    method: 'POST',
    path: '/shorten',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ url: 'http://' }),
  });
  assertTypedError(res, 400, 'INVALID_URL');
  suiteResults.push({ name: 'http:// -> INVALID_URL', ok: true });
});

// ===========================================================================
// (4) INVALID_JSON: a body that is not valid JSON -> 400, mapped from the
//     SyntaxError (never a 500), and never echoing the parser message.
// ===========================================================================
test('POST /shorten garbage body -> 400 INVALID_JSON', async (t) => {
  const { server, port } = await startServer();
  closeAfter(t, server);

  const res = await req(port, {
    method: 'POST',
    path: '/shorten',
    headers: { 'content-type': 'application/json' },
    body: '{ this is : not, valid json ]',
  });
  assertTypedError(res, 400, 'INVALID_JSON');
  suiteResults.push({ name: 'garbage -> INVALID_JSON', ok: true });
});

// ===========================================================================
// (5) EMPTY_BODY: a zero-length body is a distinct, actionable client error,
//     not "invalid JSON" -> 400 EMPTY_BODY.
// ===========================================================================
test('POST /shorten empty body -> 400 EMPTY_BODY', async (t) => {
  const { server, port } = await startServer();
  closeAfter(t, server);

  // No body written at all: readBody sees 0 bytes -> EMPTY_BODY.
  const res = await req(port, {
    method: 'POST',
    path: '/shorten',
    headers: { 'content-type': 'application/json' },
  });
  assertTypedError(res, 400, 'EMPTY_BODY');
  suiteResults.push({ name: 'empty -> EMPTY_BODY', ok: true });
});

// ===========================================================================
// (6) MISSING_URL: a well-formed JSON object with no `url` field -> 400.
// ===========================================================================
test('POST /shorten {} -> 400 MISSING_URL', async (t) => {
  const { server, port } = await startServer();
  closeAfter(t, server);

  const res = await req(port, {
    method: 'POST',
    path: '/shorten',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({}),
  });
  assertTypedError(res, 400, 'MISSING_URL');
  suiteResults.push({ name: '{} -> MISSING_URL', ok: true });
});

// ===========================================================================
// (7) INVALID_TYPE: `url` present but not a string (number) -> 400. Distinct
//     from MISSING_URL: the field was sent, just wrong-typed.
// ===========================================================================
test('POST /shorten { url: 123 } -> 400 INVALID_TYPE', async (t) => {
  const { server, port } = await startServer();
  closeAfter(t, server);

  const res = await req(port, {
    method: 'POST',
    path: '/shorten',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ url: 123 }),
  });
  assertTypedError(res, 400, 'INVALID_TYPE');
  suiteResults.push({ name: '{url:123} -> INVALID_TYPE', ok: true });
});

// ===========================================================================
// (8) CODE_NOT_FOUND: GET a well-formed single-segment code that was never
//     registered -> 404 CODE_NOT_FOUND (distinct from NOT_FOUND path).
// ===========================================================================
test('GET /nope (unknown code) -> 404 CODE_NOT_FOUND', async (t) => {
  const { server, port } = await startServer();
  closeAfter(t, server);

  const res = await req(port, { method: 'GET', path: '/nope' });
  assertTypedError(res, 404, 'CODE_NOT_FOUND');
  suiteResults.push({ name: 'GET /nope -> CODE_NOT_FOUND', ok: true });
});

// ===========================================================================
// (9) NOT_FOUND: a multi-segment path matches no route -> 404 NOT_FOUND
//     (distinct code from CODE_NOT_FOUND — same 404 status).
// ===========================================================================
test('GET /a/b/c (unknown path) -> 404 NOT_FOUND', async (t) => {
  const { server, port } = await startServer();
  closeAfter(t, server);

  const res = await req(port, { method: 'GET', path: '/a/b/c' });
  assertTypedError(res, 404, 'NOT_FOUND');
  suiteResults.push({ name: 'GET /a/b/c -> NOT_FOUND', ok: true });
});

// ===========================================================================
// (10) METHOD_NOT_ALLOWED: DELETE on the known /shorten path -> 405 with an
//      Allow header advertising the permitted method.
// ===========================================================================
test('DELETE /shorten -> 405 METHOD_NOT_ALLOWED with Allow header', async (t) => {
  const { server, port } = await startServer();
  closeAfter(t, server);

  const res = await req(port, { method: 'DELETE', path: '/shorten' });
  assertTypedError(res, 405, 'METHOD_NOT_ALLOWED');
  // A 405 MUST advertise the allowed method(s) per HTTP semantics (RFC 9110 §15.5.6).
  assert.strictEqual(res.headers.allow, 'POST', '405 on /shorten must carry Allow: POST');
  suiteResults.push({ name: 'DELETE /shorten -> 405 + Allow', ok: true });
});

// ===========================================================================
// (11) PAYLOAD_TOO_LARGE: a body over the 1 MiB cap -> 413, refused mid-stream
//      BEFORE any JSON.parse (the unbounded-memory DoS guard).
// ===========================================================================
test('POST /shorten oversized body (>1 MiB) -> 413 PAYLOAD_TOO_LARGE', async (t) => {
  const { server, port } = await startServer();
  closeAfter(t, server);

  // 1 MiB + 1 byte of a valid-looking JSON payload. The server caps at 1 MiB while
  // reading the stream, so it never reaches JSON.parse — the point of the guard.
  const filler = 'x'.repeat(1024 * 1024 + 1);
  const oversized = JSON.stringify({ url: `http://example.com/${filler}` });

  const res = await req(port, {
    method: 'POST',
    path: '/shorten',
    headers: { 'content-type': 'application/json' },
    body: oversized,
  });
  assertTypedError(res, 413, 'PAYLOAD_TOO_LARGE');
  suiteResults.push({ name: 'oversized body -> 413', ok: true });
});

// ===========================================================================
// (12) CODE_GEN_EXHAUSTED: an INJECTED store whose save() throws the typed
//      AppError('CODE_GEN_EXHAUSTED') drives the 500 collision-exhaustion path
//      OVER THE WIRE — not just in the store unit test (store.test.js). The
//      injection seam is createServer({ store }) (src/server.js:312), forwarded by
//      startServer. This closes the gap where the 413/400/404 codes were
//      wire-covered but the 500 collision path was only unit-covered.
//
//      Contract nuance: for a TYPED AppError the .message IS the client-facing
//      message (server.js forwards err.message verbatim — that is intended; the
//      AppError message is authored to be client-safe). So we do NOT treat the
//      message as a secret here. What must NEVER reach the wire is the STACK: an
//      AppError carries a real .stack (errors.js Error.captureStackTrace), and a
//      regression that serialized the error object instead of just {code,message}
//      would leak internal call sites. That is what this case pins.
// ===========================================================================
test('POST /shorten with an always-exhausting store -> 500 CODE_GEN_EXHAUSTED, no stack on the wire', async (t) => {
  // A minimal store stub: has/get are inert (never reached on this path); save()
  // throws the typed exhaustion error exactly as the real store does once its
  // bounded retry cap is hit (store.js:88-93). The message is the same client-safe
  // wording the real store uses.
  const store = {
    has: () => false,
    get: () => undefined,
    save: () => {
      throw new AppError('CODE_GEN_EXHAUSTED', 'Failed to generate a unique short code after 8 attempts');
    },
  };

  const { server, port } = await startServer({ store });
  closeAfter(t, server);

  const res = await req(port, {
    method: 'POST',
    path: '/shorten',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ url: 'http://example.com/collision' }),
  });

  assertTypedError(res, 500, 'CODE_GEN_EXHAUSTED');
  // No stack frame ('    at ' is V8's frame prefix) may reach the client — the typed
  // 500 must be the client-safe { error: { code, message } } envelope, never the
  // serialized Error object with its .stack.
  assert.ok(!res.text.includes('    at '), '500 body must not contain a stack-trace frame');
  // And the body must be EXACTLY the 2-key envelope — a leaked .stack/.name would
  // surface as an extra field.
  const body = /** @type {{ error: { code: string, message: string } }} */ (res.json);
  assert.deepStrictEqual(Object.keys(body), ['error'], '500 body must be exactly { error: ... }');
  assert.deepStrictEqual(Object.keys(body.error).sort(), ['code', 'message'], 'error must carry only code + message');
  suiteResults.push({ name: 'injected exhausting store -> 500 CODE_GEN_EXHAUSTED (no stack leak)', ok: true });
});

// ===========================================================================
// (13) INTERNAL_ERROR: an INJECTED store whose save() throws a RAW Error (NOT an
//      AppError) drives the server's catch-all at src/server.js:268-269 over the
//      WIRE — the security-critical trust boundary where a leak would actually
//      happen. This is the missing security-regression guard: the no-stack-leak
//      guarantee was previously asserted only on sendError in isolation
//      (errors.test.js), never at the real boundary. A regression that changed the
//      catch-all to echo err.message (leaking a stack / internal path / secret)
//      would have shipped GREEN before this case existed.
// ===========================================================================
test('POST /shorten with a store that throws a raw Error -> 500 INTERNAL_ERROR, marker confined to stderr', async (t) => {
  // The marker stands in for any internal detail a raw thrown Error might carry — a
  // stack frame, an internal file path, a secret. The contract: it is logged
  // server-side (stderr) but NEVER reaches the client. We assert both halves.
  const LEAK_MARKER = 'RAW-ERROR-SECRET-7c21-STDERR-ONLY';
  const store = {
    has: () => false,
    get: () => undefined,
    save: () => {
      // A bare Error (not an AppError) — this is an UNEXPECTED internal fault, the
      // exact class the catch-all must convert to a generic 500 without leaking.
      throw new Error(LEAK_MARKER);
    },
  };

  const { server, port } = await startServer({ store });
  closeAfter(t, server);

  const res = await req(port, {
    method: 'POST',
    path: '/shorten',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ url: 'http://example.com/boom' }),
  });

  assertTypedError(res, 500, 'INTERNAL_ERROR');
  // The wire body must be EXACTLY the generic { error: { code, message } } envelope:
  // no stack frame, and no trace of the raw thrown Error's marker message.
  assert.ok(!res.text.includes('    at '), '500 body must not contain a stack-trace frame');
  assert.ok(!res.text.includes(LEAK_MARKER), '500 body must not echo the raw thrown Error message');
  // And prove the envelope is nothing MORE than { error: { code, message } } — a leak
  // would most likely surface as an extra field, so pin the exact shape.
  const body = /** @type {{ error: { code: string, message: string } }} */ (res.json);
  assert.deepStrictEqual(Object.keys(body), ['error'], '500 body must be exactly { error: ... }');
  assert.deepStrictEqual(Object.keys(body.error).sort(), ['code', 'message'], 'error must carry only code + message');
  suiteResults.push({ name: 'injected raw-Error store -> 500 INTERNAL_ERROR (no leak)', ok: true });
});

// ===========================================================================
// Proof artifact: after every case above has run (node:test runs top-level tests
// serially in source order, and each awaits its own subtest lifecycle on Node 20+),
// serialize the suite result + per-code coverage to walteur-kit/test-report.json.
// This test also DOUBLE-CHECKS that every required error code was actually exercised —
// so a silently-skipped path fails the build here instead of producing a green suite
// with a hole in the taxonomy.
// ===========================================================================
test('write proof artifact: walteur-kit/test-report.json with per-code coverage', async () => {
  // Fail loudly if any required code was never observed on the wire — the report must
  // reflect real coverage, never a hardcoded all-true map.
  const uncovered = REQUIRED_ERROR_CODES.filter((c) => errorCoverage[c] !== true);
  assert.deepStrictEqual(uncovered, [], `these error codes were never exercised on the wire: ${uncovered.join(', ')}`);

  // The happy round-trip (201 + 302) must also have run — assert its result is present
  // so the artifact cannot be written from a partial run.
  assert.ok(
    suiteResults.some((r) => r.name === 'happy round-trip 201 -> 302'),
    'happy-path round-trip result missing — refusing to write a partial report'
  );

  /** @type {Record<string, { exercised: boolean }>} */
  const validationCoverage = {};
  for (const code of REQUIRED_ERROR_CODES) {
    validationCoverage[code] = { exercised: errorCoverage[code] === true };
  }

  const report = {
    suite: 'http.test.js',
    generatedAt: new Date().toISOString(),
    node: process.version,
    crypto: 'randomBytes(6).base64url',
    transport: 'node:http (no supertest, zero third-party deps)',
    totalCases: suiteResults.length,
    results: suiteResults,
    validationCoverage,
  };

  // Ensure the target directory exists (idempotent) before writing the artifact.
  mkdirSync(dirname(REPORT_PATH), { recursive: true });
  writeFileSync(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, 'utf8');

  // Sanity: prove the artifact is on disk and well-formed before the suite ends.
  // 13 functional cases now: the original 11 plus the two injected-store 500 paths
  // (CODE_GEN_EXHAUSTED and INTERNAL_ERROR).
  assert.ok(report.totalCases >= 13, `expected >= 13 recorded cases, got ${report.totalCases}`);
});
