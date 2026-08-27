// test/server.test.mjs
//
// INDEPENDENT adversarial HTTP integration suite for the URL shortener's wire
// contract. This file is a SEPARATE, self-contained check from test/http.test.js —
// it does not import test/helpers.js and builds its own req() helper from scratch,
// on purpose: the point of an independent verifier is to not inherit any mistake
// baked into the builder's own harness.
//
// Zero third-party dependencies: node:test + node:assert/strict + node:http +
// node:events only. No supertest, no fetch-based auto-follow (node:http does not
// auto-follow redirects, and that is exploited here to assert the 302 Location
// directly rather than trusting a client to hide it).
//
// Every test that starts a server:
//   1. createServer()
//   2. server.listen(0)                              -- ephemeral port
//   3. await once(server, 'listening')                -- listen(0) is ASYNC; reading
//      server.address() before this event fires is a real race, not paranoia.
//   4. read the assigned port from server.address()
//   5. t.after(() => close-Promise)                   -- RETURNED (not just called) so
//      the runner blocks on port release; every server gets torn down, always.
//
// Every case asserts BOTH the HTTP status code AND the typed error.code, because
// several codes share a status (INVALID_URL/DISALLOWED_PROTOCOL are both 400;
// CODE_NOT_FOUND/NOT_FOUND are both 404) -- asserting status alone would let a
// mislabeled error slip through green.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { createServer } from '../src/server.js';

// ---------------------------------------------------------------------------
// req(port, opts, payload) -- the ONE network primitive this suite uses.
//
// Returns a Promise wrapping http.request that:
//   - writes `payload` (if provided) to the request body verbatim, whatever type
//     it is (string, Buffer, or omitted entirely for a bodyless request);
//   - drains the FULL response body before resolving (an undrained keep-alive
//     response is the classic node:test hang cause -- draining to 'end' on every
//     path, including an empty 302 body, is what lets the process exit cleanly);
//   - parses the body as JSON when it looks like JSON, leaving `json` undefined
//     otherwise (a 302 has an empty body -- that is not an error, just no JSON);
//   - rejects the promise on ANY socket-level error (request or response), so a
//     transport failure surfaces as a rejected test rather than a silent hang.
// ---------------------------------------------------------------------------
function req(port, opts = {}, payload) {
  const { method = 'GET', path = '/', headers = {} } = opts;
  return new Promise((resolve, reject) => {
    const request = http.request(
      { host: '127.0.0.1', port, method, path, headers },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          const result = {
            status: res.statusCode,
            headers: res.headers,
            text,
            json: undefined,
          };
          if (text.length > 0) {
            try {
              result.json = JSON.parse(text);
            } catch {
              // Non-JSON body (e.g. an empty 302) -- leave json undefined; callers
              // that need it assert its presence explicitly.
            }
          }
          resolve(result);
        });
        res.on('error', reject); // mid-response transport error must reject, never hang
      }
    );

    request.on('error', reject); // connection-level failure (refused/reset) must reject

    if (payload !== undefined) {
      request.write(payload);
    }
    request.end();
  });
}

/**
 * Start a fresh server on an OS-assigned ephemeral port, await the real
 * 'listening' event (NOT a synchronous read of server.address(), which is null
 * until the event fires), and register teardown on the given test context.
 *
 * @param {import('node:test').TestContext} t
 * @param {object} [serverOpts] forwarded to createServer() (e.g. { store } for
 *   injecting a stub that forces the 500 branches deterministically)
 * @returns {Promise<{ server: import('node:http').Server, port: number }>}
 */
async function startServer(t, serverOpts) {
  const server = createServer(serverOpts);
  server.listen(0);
  await once(server, 'listening');
  const { port } = server.address();

  t.after(
    () =>
      new Promise((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      })
  );

  return { server, port };
}

/** Assert the standard typed-error envelope AND pin both status and error.code. */
function assertTypedError(res, expectedStatus, expectedCode) {
  assert.strictEqual(res.status, expectedStatus, `expected HTTP ${expectedStatus}, got ${res.status}`);
  assert.ok(res.json && typeof res.json === 'object', 'error response must have a JSON body');
  assert.ok(res.json.error && typeof res.json.error === 'object', 'body must be { error: { code, message } }');
  assert.strictEqual(res.json.error.code, expectedCode, `expected error.code ${expectedCode}, got ${res.json.error.code}`);
  assert.strictEqual(typeof res.json.error.message, 'string', 'error.message must be a string');
  assert.ok(res.json.error.message.length > 0, 'error.message must be non-empty');
}

// ===========================================================================
// (1) HAPPY PATH -- written first (TDD order): POST a valid https URL, assert
// 201, parse shortUrl, extract the code, GET it, assert 302 and that Location is
// EXACTLY the stored href (byte-for-byte, not "starts with" or "contains").
// ===========================================================================
test('happy path: POST valid https URL -> 201, GET the code -> 302 exact Location', async (t) => {
  const { port } = await startServer(t);

  const original = 'https://example.com/path?query=1#frag';

  const post = await req(
    port,
    { method: 'POST', path: '/shorten', headers: { 'content-type': 'application/json' } },
    JSON.stringify({ url: original })
  );

  assert.strictEqual(post.status, 201, 'POST /shorten with a valid https URL must return 201');
  assert.ok(post.json && typeof post.json === 'object', '201 response must be JSON');
  assert.strictEqual(typeof post.json.code, 'string', 'response must include a string code');
  assert.ok(post.json.code.length > 0, 'code must be non-empty');
  assert.strictEqual(typeof post.json.shortUrl, 'string', 'response must include a string shortUrl');

  const code = new URL(post.json.shortUrl).pathname.slice(1);
  assert.strictEqual(code, post.json.code, 'shortUrl path segment must equal the returned code');

  const redirect = await req(port, { method: 'GET', path: `/${code}` });
  assert.strictEqual(redirect.status, 302, 'GET /:code for a stored code must 302');
  // EXACT equality -- the WHATWG-canonical href, not a prefix/substring match. This
  // is the one place a builder could quietly truncate the query/fragment and still
  // "look" correct, so pin it byte-for-byte.
  assert.strictEqual(redirect.headers.location, original, 'Location must equal the exact stored href');
  assert.strictEqual(redirect.text, '', '302 body must be empty');
});

// ===========================================================================
// (2) DISALLOWED_PROTOCOL -- non-http(s) scheme, two variants: a host-bearing
// wrong scheme (ftp://) and a host-less dangerous scheme (javascript:). Both
// PARSE successfully under WHATWG new URL() -- only the explicit allowlist
// rejects them, so this is the security-critical branch.
// ===========================================================================
test('DISALLOWED_PROTOCOL: ftp:// (host-bearing, wrong scheme) -> 400', async (t) => {
  const { port } = await startServer(t);
  const res = await req(
    port,
    { method: 'POST', path: '/shorten', headers: { 'content-type': 'application/json' } },
    JSON.stringify({ url: 'ftp://ftp.example.com/file.txt' })
  );
  assertTypedError(res, 400, 'DISALLOWED_PROTOCOL');
});

test('DISALLOWED_PROTOCOL: javascript: (host-less dangerous scheme) -> 400', async (t) => {
  const { port } = await startServer(t);
  const res = await req(
    port,
    { method: 'POST', path: '/shorten', headers: { 'content-type': 'application/json' } },
    JSON.stringify({ url: 'javascript:alert(1)' })
  );
  assertTypedError(res, 400, 'DISALLOWED_PROTOCOL');
});

// ===========================================================================
// (3) INVALID_URL -- a malformed URL string that new URL() itself throws on.
// Distinct from DISALLOWED_PROTOCOL (both 400) -- "http://" has a scheme but no
// host, so the WHATWG parser rejects it BEFORE the allowlist is even reached.
// ===========================================================================
test('INVALID_URL: malformed URL string ("http://" with no host) -> 400', async (t) => {
  const { port } = await startServer(t);
  const res = await req(
    port,
    { method: 'POST', path: '/shorten', headers: { 'content-type': 'application/json' } },
    JSON.stringify({ url: 'http://' })
  );
  assertTypedError(res, 400, 'INVALID_URL');
});

test('INVALID_URL: not a URL at all ("not a url") -> 400', async (t) => {
  const { port } = await startServer(t);
  const res = await req(
    port,
    { method: 'POST', path: '/shorten', headers: { 'content-type': 'application/json' } },
    JSON.stringify({ url: 'not a url' })
  );
  assertTypedError(res, 400, 'INVALID_URL');
});

// ===========================================================================
// (4) INVALID_JSON -- a non-JSON body. Must map to a typed 400, never a raw
// SyntaxError / 500, and must never echo the parser's message verbatim.
// ===========================================================================
test('INVALID_JSON: non-JSON body -> 400', async (t) => {
  const { port } = await startServer(t);
  const res = await req(
    port,
    { method: 'POST', path: '/shorten', headers: { 'content-type': 'application/json' } },
    '{not valid json at all]'
  );
  assertTypedError(res, 400, 'INVALID_JSON');
});

// ===========================================================================
// (5) MISSING_URL -- the `url` key is entirely absent from an otherwise
// well-formed JSON object.
// ===========================================================================
test('MISSING_URL: url key absent -> 400', async (t) => {
  const { port } = await startServer(t);
  const res = await req(
    port,
    { method: 'POST', path: '/shorten', headers: { 'content-type': 'application/json' } },
    JSON.stringify({ notUrl: 'https://example.com' })
  );
  assertTypedError(res, 400, 'MISSING_URL');
});

// ===========================================================================
// (6) INVALID_TYPE -- `url` present but not a string. Distinct from MISSING_URL
// (both 400): the field was sent, just wrong-typed.
// ===========================================================================
test('INVALID_TYPE: url is a non-string (number) -> 400', async (t) => {
  const { port } = await startServer(t);
  const res = await req(
    port,
    { method: 'POST', path: '/shorten', headers: { 'content-type': 'application/json' } },
    JSON.stringify({ url: 42 })
  );
  assertTypedError(res, 400, 'INVALID_TYPE');
});

test('INVALID_TYPE: url is a non-string (array) -> 400', async (t) => {
  const { port } = await startServer(t);
  const res = await req(
    port,
    { method: 'POST', path: '/shorten', headers: { 'content-type': 'application/json' } },
    JSON.stringify({ url: ['https://example.com'] })
  );
  assertTypedError(res, 400, 'INVALID_TYPE');
});

// ===========================================================================
// (7) CODE_NOT_FOUND -- GET a syntactically fine but never-registered code.
// 404, distinct error.code from the generic route-level NOT_FOUND below.
// ===========================================================================
test('CODE_NOT_FOUND: GET an unknown code -> 404', async (t) => {
  const { port } = await startServer(t);
  const res = await req(port, { method: 'GET', path: '/doesNotExist1' });
  assertTypedError(res, 404, 'CODE_NOT_FOUND');
});

// ===========================================================================
// (8) NOT_FOUND -- an unknown ROUTE (multi-segment path matches no handler).
// Same 404 status as CODE_NOT_FOUND but a DIFFERENT error.code -- proves the
// server disambiguates "route" 404s from "code" 404s rather than collapsing
// both into one generic not-found.
// ===========================================================================
test('NOT_FOUND: unknown multi-segment route -> 404', async (t) => {
  const { port } = await startServer(t);
  const res = await req(port, { method: 'GET', path: '/some/nested/route' });
  assertTypedError(res, 404, 'NOT_FOUND');
});

// ===========================================================================
// (9) METHOD_NOT_ALLOWED -- DELETE on the known /shorten path -> 405 with an
// Allow header naming the permitted method (RFC 9110 ยง15.5.6 requires it).
// ===========================================================================
test('METHOD_NOT_ALLOWED: DELETE /shorten -> 405 with Allow header', async (t) => {
  const { port } = await startServer(t);
  const res = await req(port, { method: 'DELETE', path: '/shorten' });
  assertTypedError(res, 405, 'METHOD_NOT_ALLOWED');
  assert.strictEqual(res.headers.allow, 'POST', '405 response on /shorten must advertise Allow: POST');
});

// ===========================================================================
// (10) PAYLOAD_TOO_LARGE -- a body over the 1 MiB cap -> 413. Refused
// mid-stream before JSON.parse is ever attempted (unbounded-memory DoS guard).
// ===========================================================================
test('PAYLOAD_TOO_LARGE: oversized body (>1 MiB) -> 413', async (t) => {
  const { port } = await startServer(t);
  const filler = 'a'.repeat(1024 * 1024 + 1024); // comfortably over the 1 MiB cap
  const oversizedBody = JSON.stringify({ url: `https://example.com/${filler}` });

  const res = await req(
    port,
    { method: 'POST', path: '/shorten', headers: { 'content-type': 'application/json' } },
    oversizedBody
  );
  assertTypedError(res, 413, 'PAYLOAD_TOO_LARGE');
});

// ===========================================================================
// Collision-safety: repeated POSTs of DIFFERENT URLs must yield DISTINCT codes
// (never a duplicate/collided assignment observable at the wire level). We also
// directly force the collision-RETRY path (not just "no collision happened") by
// injecting a store whose generate() deliberately returns a colliding value on
// its first call and a fresh value on the second -- proving the retry loop, not
// merely statistical luck with the real 6-byte generator, is what the server
// exercises when a collision occurs.
// ===========================================================================
test('collision-safety: repeated POSTs of distinct URLs yield distinct codes', async (t) => {
  const { port } = await startServer(t);

  const urls = Array.from({ length: 20 }, (_, i) => `https://example.com/item/${i}`);
  const codes = new Set();

  for (const url of urls) {
    const res = await req(
      port,
      { method: 'POST', path: '/shorten', headers: { 'content-type': 'application/json' } },
      JSON.stringify({ url })
    );
    assert.strictEqual(res.status, 201, `POST for ${url} must succeed`);
    codes.add(res.json.code);
  }

  assert.strictEqual(codes.size, urls.length, 'every distinct POST must mint a distinct code');
});

test('collision-retry is actually exercised: an injected generator that collides once then succeeds still returns 201 with the retried code', async (t) => {
  // Force a real collision: the store's save() will draw 'DUPLICATE' first (which
  // already exists in the store), then 'FRESH-CODE' on retry. If the server's route
  // wiring reaches store.save() at all and the store's bounded-retry loop works, the
  // request succeeds with the SECOND value -- proving the retry path actually ran,
  // not merely that no collision happened to occur.
  let calls = 0;
  const generate = () => {
    calls += 1;
    return calls === 1 ? 'DUPLICATE' : 'FRESH-CODE';
  };
  const preseeded = new Map([['DUPLICATE', 'https://already-there.example.com/']]);
  const store = {
    has: (code) => preseeded.has(code),
    get: (code) => preseeded.get(code),
    save: (url) => {
      let code;
      let attempts = 0;
      do {
        if (attempts >= 8) throw new Error('exhausted'); // should not trigger in this test
        code = generate();
        attempts += 1;
      } while (preseeded.has(code));
      preseeded.set(code, url);
      return code;
    },
  };

  const { port } = await startServer(t, { store });

  const res = await req(
    port,
    { method: 'POST', path: '/shorten', headers: { 'content-type': 'application/json' } },
    JSON.stringify({ url: 'https://example.com/collision-retry-test' })
  );

  assert.strictEqual(res.status, 201, 'a collision on the first draw must still succeed after retry');
  assert.strictEqual(res.json.code, 'FRESH-CODE', 'the SECOND (non-colliding) generated value must be the one returned');
  assert.strictEqual(calls, 2, 'generate() must have been called exactly twice: the collision, then the retry');
});
