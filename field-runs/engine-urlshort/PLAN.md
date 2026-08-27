# Design Doc — Zero-Dependency Node URL Shortener (`engine-urlshort`)

## 1. Goal & Contract
A zero-dependency (runtime AND dev) Node.js HTTP JSON API for URL shortening:
- `POST /shorten` with JSON body `{ "url": "<http(s) url>" }` → `201 { code, shortUrl }`.
- `GET /:code` → `302` redirect with `Location: <original url>`, empty body.
- In-memory `Map<code,url>` store; resets on process restart (per requirement).
- Strict, typed-error input validation (reject non-http(s) schemes + malformed/missing/non-string input).
- Collision-safe short codes via bounded regenerate-on-collision.
- A `node:test` suite that drives the running server over REAL HTTP using only `node:http`.
- A README documenting endpoints, the typed-error table, run/test commands, and explicit non-goals.

**Stack (verified on Node v24.13.1, Active LTS):** `node:http` server, `node:crypto` for codes, `node:test` + `node:assert/strict` for the suite. Pure ESM (`"type":"module"`), explicit `.js` extensions on relative imports. `engines: {"node": ">=20"}` — floor at 20 (node:test stable since 20; we test on 24 LTS where subtest auto-await closed the silent-pass footgun). Cross-platform npm scripts only (Windows dev host — no bash-only invocations).

## 2. Empirically Verified Decisions (spike-confirmed, do NOT re-litigate)
Re-verified this session on Node v24.13.1:
- **Scheme allowlisting is POST-parse only.** `new URL()` does NOT throw on scheme: `javascript:`, `file:`, `data:` parse with `hostname===""`; `ftp://x/y` parses with a host. A pre-parse regex is wrong and bypass-prone. Correct check: after `new URL()`, require `u.protocol === 'http:' || u.protocol === 'https:'` AND `u.hostname.length > 0`.
- **`new URL()` throws `TypeError`** specifically (`http://` empty-host → TypeError). Catch it → `INVALID_URL`.
- **WHATWG normalizes silently & safely:** `HTTP://A.COM` → `http://a.com/`, whitespace trimmed, etc. Do NOT hand-filter whitespace/backslashes — the parser already handles them; a hand-check disagrees with it and creates false rejects or bypasses. Store & redirect on `u.href` (canonical serialized form), never the raw input.
- **Two distinct typed errors from validation:** parse-TypeError → `INVALID_URL`; parse-ok-but-protocol/host-fails → `DISALLOWED_PROTOCOL`. Both 400, kept distinct so parse-failure vs policy-failure are legible.
- **Codes:** `crypto.randomBytes(6).toString('base64url')` → exactly **8 chars**, alphabet `A-Za-z0-9-_`, no padding, URL-safe (verified `len: 8`). Zero-dep one-liner; beats hand-rolled base62.
- **Collision-safe = BOUNDED retry:** `do { code = gen() } while (store.has(code))` capped at ~8 attempts; on cap-out throw typed `CODE_GEN_EXHAUSTED` (500). Never loop unbounded (a store bug would hang the request).
- **`shortUrl` is request-derived, never hardcoded:** `${proto}://${req.headers.host}/${code}`, `proto` from `x-forwarded-proto` else `http`, optional `BASE_URL` env override taking priority. The test suite binds an ephemeral `listen(0)` port; only a request-derived `shortUrl` carries the actual bound port so the round-trip resolves.
- **node:test over real HTTP (verified exits 0, no hang):** per test `createServer(); server.listen(0); await once(server,'listening')` BEFORE reading `server.address().port` (listen is async — `address()` is null pre-bind, a real race). Register `t.after(() => new Promise(r => server.close(r)))` and RETURN the close Promise so the runner blocks until the port is released. Drive with `http.request({host:'127.0.0.1',port,...})`; ALWAYS attach `res.on('error',reject)` and fully drain the body in EVERY path (including the empty 302 body) — an undrained keep-alive response is the #1 cause of a hung `--test` runner. `node:http` never auto-follows 302 — assert `statusCode===302` + `headers.location` directly.

## 3. Architecture — 3 source files + scaffolding, ~150 LOC, zero deps
Single request handler with **explicit route-then-method matching** (route match first so we know a path exists before checking method → correct 404-vs-405 + `Allow` header).

- **`src/server.js`** — exports factory `createServer()` returning an UNSTARTED `http.Server` (do NOT `listen` at import time; the test suite owns `listen(0)`). This seam is what makes the whole thing testable over real HTTP. Owns the handler, route dispatch, body-cap accumulation, JSON parse, response helpers (`sendJson`, `sendError`), and the request-derived `shortUrl` builder.
- **`src/validate.js`** — pure functions: `validateShortenBody(parsed)` (object/string/missing checks → `MISSING_URL`/`INVALID_TYPE`) and `validateUrl(str)` returning `{ href }` or throwing a typed `AppError` (`INVALID_URL` / `DISALLOWED_PROTOCOL`). Isolated so validation has its own unit-level failing tests independent of HTTP.
- **`src/store.js`** — `createStore()` → `{ has, get, save(url) }` where `save` does bounded collision retry against the `Map` and returns the minted code, throwing `CODE_GEN_EXHAUSTED` on cap-out. Isolated so the collision path can be forced in a unit test (inject a stub generator / pre-seed the map).
- **`src/errors.js`** — `AppError` class (`code`, `status`, `message`) + the canonical typed-error registry (single source of truth for code→status). Imported by server, validate, store, tests, and referenced by README (docs must match this table byte-for-byte).
- **`bin/server.js`** — one-line production entrypoint: `createServer().listen(process.env.PORT ?? 3000)`. Keeps `src/server.js` side-effect-free.
- **`test/*.test.js`** — `node:test` files (see Layer depth: OBSERVABILITY/testing).
- **`README.md`**, **`package.json`**.

### Request flow (`POST /shorten`)
1. Enforce body cap while accumulating chunks (track byte length; if > 1 MB → `req.destroy()` + `413 PAYLOAD_TOO_LARGE` BEFORE parse — hand-rolled body parsing is otherwise an unbounded-memory DoS).
2. Empty body → `400 EMPTY_BODY`. `JSON.parse` in try/catch → `400 INVALID_JSON`.
3. `validateShortenBody` → `MISSING_URL` / `INVALID_TYPE`.
4. `validateUrl` → `INVALID_URL` (TypeError) or `DISALLOWED_PROTOCOL` (protocol/host policy).
5. `store.save(u.href)` → bounded collision retry → `code`.
6. `201 { code, shortUrl }`, `shortUrl` request-derived.

### Request flow (`GET /:code`)
`store.has(code)` ? `302` + `Location: store.get(code)` + drained empty body : `404 CODE_NOT_FOUND`.
Known path + wrong method → `405 METHOD_NOT_ALLOWED` + `Allow` header. Unknown path → `404 NOT_FOUND`.

## 4. Data Model (in-memory)
Single structure — no DB, no persistence (deliberate; see non-goals).
- **Store:** JS `Map<string,string>`, key = `code` (8-char base64url, unique by construction + collision retry), value = `url` (canonical `u.href`, always `http(s)`, host non-empty).
- **Invariants encoded in code (the DB substitutes here):** key uniqueness enforced by `Map` + `has()`-guarded bounded retry (the "unique index"); value always a validated canonical http(s) URL (the "CHECK constraint" — enforced at the `validateUrl` boundary before `save`); no NULL codes/urls (validation rejects before insert). No FKs/N+1/transactions apply (single-map single-write per request).

## 5. API Surface & Typed-Error Taxonomy (single envelope `{ error: { code, message } }`, stable UPPER_SNAKE codes)
| Route | Method | Success | Error codes (status) |
|---|---|---|---|
| `/shorten` | POST | `201 {code,shortUrl}` | `413 PAYLOAD_TOO_LARGE`, `400 EMPTY_BODY`, `400 INVALID_JSON`, `400 MISSING_URL`, `400 INVALID_TYPE`, `400 INVALID_URL`, `400 DISALLOWED_PROTOCOL`, `500 CODE_GEN_EXHAUSTED` |
| `/shorten` | other | — | `405 METHOD_NOT_ALLOWED` + `Allow: POST` |
| `/:code` | GET | `302` + `Location` | `404 CODE_NOT_FOUND` |
| `/:code` | other | — | `405 METHOD_NOT_ALLOWED` + `Allow: GET` |
| any other path | any | — | `404 NOT_FOUND` |

**Security baseline (2026):** every response sets `Content-Type: application/json` (error + success bodies; the 302 sends no body). Never leak stack traces — the `{error:{code,message}}` envelope is the ONLY client-facing shape; unexpected internals map to a generic `500 INTERNAL_ERROR` with full detail logged server-side only. `405` always sets `Allow`.

## 6. Failure Modes (named, each OWNED by a task with a failing test)
- **Runner hang** (undrained keep-alive body / port not released): mitigated by drain-in-every-path `req()` helper + returned `server.close` Promise in `t.after`. (Test task T4.)
- **Validation bypass** (regex/pre-parse scheme check letting `javascript:`/`file:`/`data:` through): mitigated by post-parse `u.protocol` allowlist + `hostname.length>0`. (Validation task T2 owns `DISALLOWED_PROTOCOL`/`INVALID_URL` tests.)
- **Unbounded-memory DoS** (no body cap before parse): mitigated by byte-tracked accumulation + `413` before parse. (Server task T3 owns the 413 test.)
- **Request hang on code exhaustion** (unbounded collision loop): mitigated by bounded retry → `CODE_GEN_EXHAUSTED`. (Store task T2b owns the forced-collision test.)
- **Wrong-port `shortUrl`** (hardcoded base): mitigated by request-derived builder; round-trip test asserts GET on the returned `shortUrl` resolves. (Test task T4.)
- **SSRF is OUT OF SCOPE and stated:** protocol allowlisting does NOT block `http://127.0.0.1`, `http://169.254.169.254` (cloud metadata), `http://[::1]`. README must name SSRF/private-IP blocking as a deliberate non-goal so "validated" is not misread as "safe to fetch". (README task T5.)

## 7. NFRs / SLOs
- **Latency:** pure in-memory Map + one `randomBytes(6)` per shorten; target p99 < 5 ms server-processing on localhost (no I/O, no DB). No blocking calls on the request path.
- **Availability/durability:** single-process, in-memory. **RPO = ∞ / RTO = process restart** — all data lost on restart, ACCEPTED per the in-memory requirement and stated in README. No HA/multi-AZ (out of scope).
- **Throughput/safety:** body cap 1 MB per request (DoS bound); bounded 8-attempt code retry (no unbounded CPU). No rate-limiting (out of scope — flagged in README as the next security layer if promoted beyond local/embedded use).
- **Correctness SLO:** `node --test` green — round-trip 302, every typed-reject path pinned on BOTH status AND `error.code`, 404/405 + `Allow`, 413, forced-collision → `CODE_GEN_EXHAUSTED`.

## Layer depth: API CONTRACT (the layer this build centrally touches)
Non-negotiables committed:
- **Validate & reject at the boundary with a typed taxonomy, never 500 on bad input.** Every malformed-input path returns a 4xx with a stable `error.code` (table §5). The only 500s are genuine internals (`CODE_GEN_EXHAUSTED`, `INTERNAL_ERROR`) — never triggered by client input.
- **One consistent error envelope:** `{ error: { code, message } }` everywhere, single-sourced in `src/errors.js`, asserted in tests, documented in README (byte-for-byte match — grep the shipped registry before writing the README table).
- **Typed request/response contract** without a schema lib (zero-dep): explicit hand-validation in `src/validate.js` acts as the boundary schema; response shapes are fixed in the two success helpers.
- **Authz per endpoint:** N/A — no auth in scope (public shortener); stated as a non-goal, not silently skipped.
- **Idempotency / pagination / versioning:** minting a new code per POST is the spec (no dedup required); no list endpoint → no pagination; versioning noted as a non-goal (single unversioned surface for the local/embedded use case). These are explicitly named rather than hand-waved.

## Layer depth: OBSERVABILITY (the testing/inspectability slice this build touches)
Non-negotiables committed (scaled to a zero-dep local service):
- **Consistent error envelope, zero stack-trace/PII leak to clients** — internals logged server-side only (§5).
- **Health/readiness:** `bin/server.js` logs the bound address on `listening` (readiness signal for embedders); a trivial liveness is implicit (process up). (Full `/healthz` route is out of scope for this pass — noted as a candidate follow-up, not silently dropped.)
