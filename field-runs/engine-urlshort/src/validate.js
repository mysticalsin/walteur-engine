// src/validate.js
// Pure, HTTP-free input validation at the trust boundary. No node:http, no I/O, no
// store access — just "is this a well-formed shorten request, and is this URL one we
// are willing to shorten?" Every rejection is a typed AppError from src/errors.js so
// the route layer can hand `.status`/`.code` straight to `sendError` without
// re-deriving anything (AGENTS.md §3/§5).
//
// TWO responsibilities, split into two functions so each is unit-testable in
// isolation:
//   1. validateShortenBody(parsed) — shape gate: the parsed JSON body must be a
//      plain object carrying a string `url`. Distinguishes "missing" (MISSING_URL)
//      from "present but wrong type" (INVALID_TYPE) so the client gets an actionable
//      error, never a generic 400 or a 500 on bad input.
//   2. validateUrl(str) — the security-critical scheme allowlist. See the extended
//      note on validateUrl for WHY this is POST-parse only.

import { AppError } from './errors.js';

/**
 * Shape-validate the parsed JSON body of `POST /shorten`.
 *
 * This layer does NOT parse or canonicalize the URL — it only guarantees the body is
 * a plain object with a `url` property that is present and of type `string`. Whether
 * that string is a *valid, allowed* URL is validateUrl's job. Keeping the two
 * concerns separate is deliberate: a missing/mistyped field and a well-typed but
 * disallowed URL are different client errors that deserve different codes.
 *
 * @param {unknown} parsed - The already-JSON-parsed request body.
 * @returns {string} The raw `url` string, unmodified (caller passes it to validateUrl).
 * @throws {AppError} MISSING_URL   - body is not a plain object, or `url` is absent/undefined.
 * @throws {AppError} INVALID_TYPE  - `url` is present but not a string (null, number, object, array, boolean).
 */
export function validateShortenBody(parsed) {
  // Reject anything that is not a plain object BEFORE touching properties. `typeof
  // null === 'object'`, and arrays are objects, so both must be excluded explicitly —
  // otherwise `null.url` throws a raw TypeError (a 500 on bad input) and an array
  // would be silently treated as an object. Both are client errors -> MISSING_URL.
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new AppError('MISSING_URL', 'Request body must be a JSON object with a "url" string.');
  }

  const { url } = parsed;

  // Absent or explicitly-undefined `url` is "missing", distinct from a present but
  // wrong-typed value below.
  if (url === undefined) {
    throw new AppError('MISSING_URL', 'Request body is missing the required "url" field.');
  }

  // Present but not a string (null, number, boolean, object, array) is a type error,
  // not a missing-field error — the client sent the field, just wrong.
  if (typeof url !== 'string') {
    throw new AppError('INVALID_TYPE', 'The "url" field must be a string.');
  }

  return url;
}

/**
 * Validate a candidate URL string and return its canonical form.
 *
 * SECURITY-CRITICAL — scheme allowlisting is POST-parse ONLY (AGENTS.md §5, PLAN.md
 * §2 "do NOT re-litigate"). We deliberately do NOT pre-filter with a regex, because a
 * regex allowlist is bypass-prone and the WHATWG `new URL()` parser is the only
 * authority on what a string actually resolves to. Concretely, verified on Node
 * v24.13.1:
 *   - `new URL('javascript:alert(1)')`, `new URL('file:///x')`, and
 *     `new URL('data:text/html,...')` all PARSE SUCCESSFULLY with an EMPTY hostname —
 *     they do NOT throw. Only the explicit `u.protocol` allowlist below rejects them.
 *   - `new URL('ftp://host/f')` parses successfully WITH a non-empty hostname — so a
 *     hostname-emptiness check alone is insufficient; the scheme itself must be
 *     checked. This is why the guard is `(not http and not https) OR empty-host`.
 *   - `new URL('http://')` (scheme + '//' but no host) is the one http-family input
 *     that THROWS a TypeError -> mapped to INVALID_URL, NOT DISALLOWED_PROTOCOL.
 *
 * Canonicalization: we return `u.href`, the WHATWG-normalized form. The parser
 * lowercases the scheme and host, strips leading/trailing C0-control + space
 * whitespace, and elides default ports. So `'  HTTP://Example.Com/Foo  '` returns
 * `'http://example.com/Foo'`. Downstream storage/redirect MUST use this canonical
 * string, never the raw client input.
 *
 * NOTE: this is a *syntax* check, not a network-safety guarantee. SSRF / private-IP /
 * cloud-metadata blocking is explicitly out of scope (AGENTS.md §5) — "allowed
 * scheme" never means "safe to fetch".
 *
 * @param {string} str - Candidate URL (already confirmed to be a string by validateShortenBody).
 * @returns {string} The canonical `u.href`.
 * @throws {AppError} INVALID_URL          - `new URL(str)` threw (malformed / no host / empty).
 * @throws {AppError} DISALLOWED_PROTOCOL  - parsed OK but scheme is not http/https, or host is empty.
 */
export function validateUrl(str) {
  let u;
  try {
    u = new URL(str);
  } catch {
    // `new URL()` throws a TypeError for malformed input (no scheme, `http://` with no
    // host, empty string, etc.). Map to a typed client error — never let the raw
    // TypeError surface as a 500. We intentionally do not inspect the caught error:
    // any parse failure is, uniformly, an INVALID_URL from the client's perspective.
    throw new AppError('INVALID_URL', 'The provided value is not a well-formed URL.');
  }

  // POST-parse allowlist. Reject on EITHER a non-http(s) scheme OR an empty host.
  // `u.protocol` includes the trailing colon ('http:' / 'https:'). The empty-host
  // clause catches host-less schemes like javascript:/file:/data:/mailto: that parse
  // successfully; the scheme clause catches host-bearing wrong schemes like ftp://.
  if ((u.protocol !== 'http:' && u.protocol !== 'https:') || u.hostname.length === 0) {
    throw new AppError(
      'DISALLOWED_PROTOCOL',
      'Only http and https URLs with a host are allowed.'
    );
  }

  // Canonical form — store/redirect this, never the raw input.
  return u.href;
}
