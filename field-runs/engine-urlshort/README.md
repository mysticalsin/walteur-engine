# engine-urlshort

A zero-dependency Node.js HTTP JSON API for URL shortening. `POST /shorten` mints
an opaque short code for a validated `http(s)` URL; `GET /:code` 302-redirects to
it. Storage is an in-memory `Map` — nothing is persisted to disk.

No runtime dependencies. No dev dependencies. Built entirely on `node:http`,
`node:crypto`, and `node:test`.

## 1. Quick start

Requires **Node >= 20** (tested on Node 24 LTS).

```
npm start
```

Runs `node bin/server.js`. Reads `PORT` from the environment (defaults to `3000`)
and logs a single structured JSON line to stdout once bound:

```json
{"level":"info","at":"2026-07-02T22:52:43.409Z","msg":"listening","url":"http://127.0.0.1:3000"}
```

Run the test suite:

```
npm test
```

Runs `node --test` (built-in test runner, no third-party framework). Both scripts
are plain `npm` scripts — they work identically in PowerShell, cmd, and any POSIX
shell.

Optional coverage report:

```
node --test --experimental-test-coverage
```

`--experimental-test-coverage` is **optional and still experimental** in current
Node releases — it is not part of `npm test` and is not required to validate the
suite. Use the plain `npm test` output (pass/fail counts) as the source of truth.

## 2. Endpoints

### `POST /shorten`

Request body — JSON, `{ "url": "<http(s) url>" }`:

```
curl -s -i -X POST http://127.0.0.1:3000/shorten \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com/page"}'
```

Response — `201 Created`, `Content-Type: application/json`:

```json
{"code":"q3FV1waY","shortUrl":"http://127.0.0.1:3000/q3FV1waY"}
```

- `code` — the newly generated short code (collision-safe against the in-memory
  store; regenerated on collision, bounded, throws `CODE_GEN_EXHAUSTED` on
  exhaustion — see the error table below).
- `shortUrl` — the full redirect URL, built from the incoming request (`Host`
  header and `X-Forwarded-Proto`, or the `BASE_URL` environment variable if set).
  Never hardcoded.
- The stored/returned URL is the **canonical** form (`new URL(input).href`), not
  necessarily byte-identical to what you submitted (e.g. scheme/host are
  lowercased, a default port is dropped).

Any request that isn't well-formed JSON with a valid `http(s)` `url` field
returns one of the typed 4xx errors in the table below instead of `201`.

Wrong HTTP method on `/shorten` (i.e. not `POST`) returns `405 Method Not Allowed`
with an `Allow: POST` header.

### `GET /:code`

```
curl -s -i http://127.0.0.1:3000/q3FV1waY
```

Response — `302 Found`, empty body, redirect target in the `Location` header:

```
HTTP/1.1 302 Found
Location: https://example.com/page
```

`node:http` (and most HTTP libraries) will not auto-follow this for you inside a
test or script — assert/inspect the `Location` header directly, or use `curl -L`
to follow it interactively.

An unknown code returns `404` with `error.code = "CODE_NOT_FOUND"` (see below).
Wrong HTTP method on a known `/:code` path (i.e. not `GET`) returns
`405 Method Not Allowed` with an `Allow: GET` header. Any path that doesn't match
`/shorten` or a single-segment `/:code` returns `404` with `error.code =
"NOT_FOUND"`.

## 3. Typed errors

Every error response uses exactly one envelope shape:

```json
{ "error": { "code": "SOME_CODE", "message": "human-readable detail" } }
```

`Content-Type: application/json` is always set. No stack trace, internal path, or
raw exception message is ever put on the wire — unexpected failures are logged
server-side (structured JSON to stderr) and returned to the client as the generic
`INTERNAL_ERROR` below.

The full registry, reproduced byte-for-byte from `src/errors.js` (`ERRORS`):

| Code | HTTP status | Meaning |
|---|---|---|
| `EMPTY_BODY` | 400 | `POST /shorten` request body was empty. |
| `INVALID_JSON` | 400 | Request body could not be parsed as JSON. |
| `MISSING_URL` | 400 | Parsed body is not a JSON object, or has no `url` key (or `url` is `undefined`). |
| `INVALID_TYPE` | 400 | `url` is present but not a string. |
| `INVALID_URL` | 400 | `url` string could not be parsed as a URL at all (`new URL()` threw). |
| `DISALLOWED_PROTOCOL` | 400 | `url` parsed, but its scheme is not `http:`/`https:`, or it has no host. |
| `PAYLOAD_TOO_LARGE` | 413 | Request body exceeded the 1 MiB cap (enforced while streaming, before `JSON.parse`). |
| `CODE_NOT_FOUND` | 404 | `GET /:code` — no URL is registered for this code. |
| `NOT_FOUND` | 404 | Request path does not match `/shorten` or a single-segment `/:code`. |
| `METHOD_NOT_ALLOWED` | 405 | Known path, wrong HTTP method (response carries an `Allow` header). |
| `CODE_GEN_EXHAUSTED` | 500 | Short-code generation exhausted its bounded collision-retry budget. |
| `INTERNAL_ERROR` | 500 | An unexpected, unclassified server-side failure. |

If this table and `src/errors.js` ever disagree, `src/errors.js` is the source of
truth — file a doc-drift bug rather than trusting this README.

## 4. Non-goals (explicit — read before relying on this service for anything beyond local/embedded use)

This service does **one thing**: validate an `http(s)` URL's syntax, mint a code,
and redirect. It deliberately does **not** do the following, and none of these
are TODOs — they are out of scope for this build:

- **The returned `shortUrl` origin is NOT a trusted/canonical value when `BASE_URL`
  is unset.** With no `BASE_URL`, `shortUrl` is reconstructed from the client-controlled
  `Host` and `X-Forwarded-Proto` headers, so a request with `Host: attacker.example`
  yields `shortUrl: "http(s)://attacker.example/<code>"`. This is **not** an open
  redirect — the *stored* and *redirected* target (`GET /:code` → 302 `Location`) is
  always the canonicalized URL and is unaffected. But a consumer that renders, emails,
  or treats the returned `shortUrl` as authoritative must set a fixed `BASE_URL` (or
  front the service with a Host allowlist). An absent `Host` header falls back to
  `localhost` rather than emitting a malformed `http://undefined/...`.
- **SSRF / private-IP / cloud-metadata blocking is NOT implemented.** The only
  check applied is a post-parse `http:`/`https:` scheme allowlist (see
  `DISALLOWED_PROTOCOL` above). That allowlist does **not** stop
  `http://127.0.0.1`, `http://169.254.169.254` (the cloud instance-metadata
  endpoint on AWS/GCP/Azure), `http://[::1]`, `http://0.0.0.0`, DNS-rebinding
  targets, or any other loopback/link-local/internal address — all of those are
  syntactically valid `http(s)` URLs and will validate and store successfully.
  **A "validated" URL is not a "safe to fetch" URL.** This service never itself
  fetches the target (it only redirects the client's browser to it), but any
  caller that treats "passed validation" as "safe to request server-side" is
  making an SSRF mistake this codebase does not protect against.
- **No persistence.** The store is a plain in-memory `Map`. All codes and URLs
  are lost on process restart or crash — RPO is infinite, RTO is "however long
  it takes to restart the process." There is no database, no disk write, no
  replication.
- **No authentication or authorization.** Every endpoint is fully public and
  unauthenticated. There are no API keys, sessions, users, or tenants.
- **No rate limiting.** Nothing throttles or blocks a client making unlimited
  requests to either endpoint.
- **No deduplication.** Shortening the same URL twice produces two different
  codes pointing at the same (canonicalized) URL.
- **No vanity codes or expiry/TTL.** Codes are opaque and random; there is no way
  to request a specific code, and no code ever expires on its own.
- **No HTTPS/TLS termination, no CORS, no API versioning.** This is a bare HTTP
  service intended to run behind whatever TLS-terminating proxy or embedding
  process the operator chooses to put in front of it, if any.

None of the above are silently missing — they are stated scope boundaries. Adding
any of them is a scope change, not a bug fix.
