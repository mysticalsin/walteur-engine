// test/validate.test.js
// TDD: written BEFORE src/validate.js exists. Must fail (ERR_MODULE_NOT_FOUND),
// then pass once src/validate.js is implemented. Exercises the pure, HTTP-free
// validation module — body-shape validation (validateShortenBody) and the
// POST-parse scheme-allowlist URL validation (validateUrl) — pinning EVERY branch
// on both the AppError class and its typed `.code` (never just "some 400").
//
// Design contract under test (AGENTS.md §3/§5, PLAN.md §2 "do NOT re-litigate"):
//   - Scheme allowlisting is POST-parse ONLY. `new URL()` HAPPILY parses
//     javascript:/file:/data: (with an empty host) and ftp:// (with a host) — none
//     of these throw. The allowlist check runs AFTER parse and rejects them with
//     DISALLOWED_PROTOCOL. There must be NO pre-parse regex/prefilter.
//   - `http://` (scheme, "//", but no host) is the case that DOES make `new URL()`
//     throw a TypeError -> mapped to INVALID_URL.
//   - Valid http/https URLs are returned in CANONICAL (u.href) form: uppercase
//     scheme/host lowercased, surrounding whitespace stripped by the WHATWG parser.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppError } from '../src/errors.js';
import { validateShortenBody, validateUrl } from '../src/validate.js';

// ---------------------------------------------------------------------------
// Helper: assert a thunk throws an AppError carrying an EXACT typed code.
// Pins the taxonomy, not just "it threw" — INVALID_URL vs DISALLOWED_PROTOCOL
// are both 400 and would otherwise be indistinguishable.
// ---------------------------------------------------------------------------
function assertThrowsCode(fn, expectedCode) {
  assert.throws(
    fn,
    (err) => {
      assert.ok(err instanceof AppError, `expected an AppError, got ${err && err.name}`);
      assert.strictEqual(
        err.code,
        expectedCode,
        `expected AppError.code === ${expectedCode}, got ${err.code}`
      );
      return true;
    },
    `expected a throw with code ${expectedCode}`
  );
}

// ===========================================================================
// validateShortenBody — request body shape at the trust boundary
// ===========================================================================

test('validateShortenBody: null body -> MISSING_URL (non-object rejected before property access)', () => {
  assertThrowsCode(() => validateShortenBody(null), 'MISSING_URL');
});

test('validateShortenBody: undefined body -> MISSING_URL', () => {
  assertThrowsCode(() => validateShortenBody(undefined), 'MISSING_URL');
});

test('validateShortenBody: array body -> MISSING_URL (arrays are not valid shorten bodies)', () => {
  assertThrowsCode(() => validateShortenBody(['http://example.com']), 'MISSING_URL');
});

test('validateShortenBody: primitive (string) body -> MISSING_URL', () => {
  assertThrowsCode(() => validateShortenBody('http://example.com'), 'MISSING_URL');
});

test('validateShortenBody: primitive (number) body -> MISSING_URL', () => {
  assertThrowsCode(() => validateShortenBody(42), 'MISSING_URL');
});

test('validateShortenBody: object with no url key -> MISSING_URL', () => {
  assertThrowsCode(() => validateShortenBody({ notUrl: 'x' }), 'MISSING_URL');
});

test('validateShortenBody: url present but undefined -> MISSING_URL', () => {
  assertThrowsCode(() => validateShortenBody({ url: undefined }), 'MISSING_URL');
});

test('validateShortenBody: url present but null -> INVALID_TYPE (present-but-wrong-type, not missing)', () => {
  // null is a present value that is not a string -> the type branch, not the missing branch.
  assertThrowsCode(() => validateShortenBody({ url: null }), 'INVALID_TYPE');
});

test('validateShortenBody: url is a number -> INVALID_TYPE', () => {
  assertThrowsCode(() => validateShortenBody({ url: 123 }), 'INVALID_TYPE');
});

test('validateShortenBody: url is a boolean -> INVALID_TYPE', () => {
  assertThrowsCode(() => validateShortenBody({ url: true }), 'INVALID_TYPE');
});

test('validateShortenBody: url is an object -> INVALID_TYPE', () => {
  assertThrowsCode(() => validateShortenBody({ url: { href: 'http://x.com' } }), 'INVALID_TYPE');
});

test('validateShortenBody: url is an array -> INVALID_TYPE', () => {
  assertThrowsCode(() => validateShortenBody({ url: ['http://x.com'] }), 'INVALID_TYPE');
});

test('validateShortenBody: valid string url -> returns the exact string (no mutation, no parse here)', () => {
  const out = validateShortenBody({ url: 'http://example.com/path' });
  assert.strictEqual(out, 'http://example.com/path');
});

test('validateShortenBody: empty-string url passes the shape gate (emptiness is validateUrl\'s job, not this layer\'s)', () => {
  // A string is a string; whether '' is a *valid URL* is validateUrl's responsibility.
  // This layer only guarantees "present and of type string".
  const out = validateShortenBody({ url: '' });
  assert.strictEqual(out, '');
});

// ===========================================================================
// validateUrl — POST-parse scheme allowlist
// ===========================================================================

// ---- DISALLOWED_PROTOCOL: schemes that PARSE fine but are not http(s) --------
// These are the crux of the design: `new URL()` does NOT throw on any of them.

test('validateUrl: javascript: parses (empty host) then hits DISALLOWED_PROTOCOL', () => {
  // Sanity: prove the premise — new URL() really does accept this without throwing.
  assert.doesNotThrow(() => new URL('javascript:alert(1)'));
  assertThrowsCode(() => validateUrl('javascript:alert(1)'), 'DISALLOWED_PROTOCOL');
});

test('validateUrl: file: parses (empty host) then hits DISALLOWED_PROTOCOL', () => {
  assert.doesNotThrow(() => new URL('file:///etc/passwd'));
  assertThrowsCode(() => validateUrl('file:///etc/passwd'), 'DISALLOWED_PROTOCOL');
});

test('validateUrl: data: parses (empty host) then hits DISALLOWED_PROTOCOL', () => {
  assert.doesNotThrow(() => new URL('data:text/html,<script>alert(1)</script>'));
  assertThrowsCode(
    () => validateUrl('data:text/html,<script>alert(1)</script>'),
    'DISALLOWED_PROTOCOL'
  );
});

test('validateUrl: ftp:// parses WITH a host then still hits DISALLOWED_PROTOCOL', () => {
  // ftp is the "has a hostname but wrong scheme" case — proves the check is on the
  // scheme, not merely on hostname emptiness.
  const u = new URL('ftp://ftp.example.com/file.txt');
  assert.strictEqual(u.hostname, 'ftp.example.com'); // host is NON-empty here
  assertThrowsCode(() => validateUrl('ftp://ftp.example.com/file.txt'), 'DISALLOWED_PROTOCOL');
});

test('validateUrl: mailto: (scheme, no host) -> DISALLOWED_PROTOCOL (not INVALID_URL — it parses)', () => {
  assert.doesNotThrow(() => new URL('mailto:someone@example.com'));
  assertThrowsCode(() => validateUrl('mailto:someone@example.com'), 'DISALLOWED_PROTOCOL');
});

// ---- INVALID_URL: strings that make `new URL()` actually THROW ----------------

test('validateUrl: "http://" (scheme + // but no host) throws TypeError -> INVALID_URL', () => {
  // This is the ONE http-family input that new URL() rejects — assert the premise
  // then assert the mapping. It must NOT be reported as DISALLOWED_PROTOCOL.
  assert.throws(() => new URL('http://'), TypeError);
  assertThrowsCode(() => validateUrl('http://'), 'INVALID_URL');
});

test('validateUrl: "https://" alone throws TypeError -> INVALID_URL', () => {
  assert.throws(() => new URL('https://'), TypeError);
  assertThrowsCode(() => validateUrl('https://'), 'INVALID_URL');
});

test('validateUrl: empty string -> INVALID_URL (new URL("") throws)', () => {
  assert.throws(() => new URL(''), TypeError);
  assertThrowsCode(() => validateUrl(''), 'INVALID_URL');
});

test('validateUrl: garbage with no scheme -> INVALID_URL', () => {
  assert.throws(() => new URL('not a url at all'), TypeError);
  assertThrowsCode(() => validateUrl('not a url at all'), 'INVALID_URL');
});

test('validateUrl: bare host without scheme ("example.com") -> INVALID_URL', () => {
  // No scheme => new URL() throws (there is no base). Must map to INVALID_URL,
  // never silently succeed by inferring http.
  assert.throws(() => new URL('example.com'), TypeError);
  assertThrowsCode(() => validateUrl('example.com'), 'INVALID_URL');
});

// ---- Valid http/https + canonicalization (must PASS, returns u.href) ----------

test('validateUrl: plain http URL passes and returns canonical href', () => {
  assert.strictEqual(validateUrl('http://example.com'), 'http://example.com/');
});

test('validateUrl: plain https URL passes and returns canonical href', () => {
  assert.strictEqual(validateUrl('https://example.com'), 'https://example.com/');
});

test('validateUrl: http URL with path/query/fragment returns exact canonical href', () => {
  assert.strictEqual(
    validateUrl('https://example.com/a/b?q=1&r=2#frag'),
    'https://example.com/a/b?q=1&r=2#frag'
  );
});

test('validateUrl: UPPERCASE scheme + host is normalized to lowercase canonical href', () => {
  // HTTP://A.COM must PASS (scheme is http after WHATWG normalization) and the
  // returned href must be the lowercased canonical form.
  assert.strictEqual(validateUrl('HTTP://A.COM'), 'http://a.com/');
});

test('validateUrl: mixed-case https host normalizes host to lowercase, preserves path case', () => {
  // Scheme + host lowercase; the path is case-sensitive and must be preserved.
  assert.strictEqual(
    validateUrl('HTTPS://Example.COM/PathCase'),
    'https://example.com/PathCase'
  );
});

test('validateUrl: leading/trailing ASCII whitespace is trimmed by the parser -> canonical href', () => {
  // The WHATWG URL parser strips leading/trailing C0 control + space. Padded input
  // must PASS and normalize; assert the EXACT trimmed canonical href.
  assert.strictEqual(validateUrl('   http://example.com/x   '), 'http://example.com/x');
});

test('validateUrl: surrounding tab/newline whitespace is stripped -> canonical href', () => {
  assert.strictEqual(validateUrl('\t\nhttps://example.com\n\t'), 'https://example.com/');
});

test('validateUrl: combined UPPERCASE + whitespace padding normalizes to canonical href', () => {
  assert.strictEqual(validateUrl('  HTTP://Example.Com/Foo  '), 'http://example.com/Foo');
});

test('validateUrl: default port is dropped from the canonical href', () => {
  // http default port 80 / https default port 443 are elided by canonicalization.
  assert.strictEqual(validateUrl('http://example.com:80/'), 'http://example.com/');
  assert.strictEqual(validateUrl('https://example.com:443/'), 'https://example.com/');
});

test('validateUrl: non-default explicit port is preserved in the canonical href', () => {
  assert.strictEqual(validateUrl('http://example.com:8080/'), 'http://example.com:8080/');
});

// ---- Return-value discipline: validateUrl returns the canonical STRING --------

test('validateUrl: returns a string (u.href), never a URL object', () => {
  const out = validateUrl('http://example.com');
  assert.strictEqual(typeof out, 'string', 'validateUrl must return the canonical href string');
});
