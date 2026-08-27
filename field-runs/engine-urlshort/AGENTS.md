# AGENTS.md — engine-urlshort

## 1. Project overview
A zero-dependency Node.js HTTP JSON API for URL shortening: `POST /shorten` mints an 8-char base64url code for a validated `http(s)` URL, `GET /:code` 302-redirects to it. In-memory `Map` store (no persistence — data is lost on restart, by design). Success = `node --test` is green (round-trip 302, every typed-error path pinned on status + `error.code`, 413/404/405 covered), the server starts and both endpoints behave exactly per the contract in §7 below, and the README's error table matches `src/errors.js` byte-for-byte.

## 2. Commands
No `package.json` exists yet (pre-build). Once created per PLAN.md §1, it MUST define:
```
# TODO: fill in — package.json not yet created.
# Expected once scaffolded (per PLAN.md/BATON.md):
#   npm test   -> node --test
#   npm start  -> node bin/server.js
# Confirm exact scripts against the real package.json before relying on this list.
```
Run a single server instance directly (once built): `node bin/server.js` (reads `PORT` env, defaults to 3000).
Run the suite directly (once built): `node --test` (Node 18+; project targets Node 20+ per PLAN.md engines field).

## 3. Code style
- ESM only: `"type": "module"` in package.json, explicit `.js` extensions on all relative imports (`import { createStore } from './store.js'` — omitting the extension throws under Node ESM resolution).
- Zero dependencies, runtime AND dev. Do not add anything to `dependencies`/`devDependencies` without renegotiating the scope in PLAN.md — the zero-dep constraint is a stated design goal, not an oversight.
- Validation is POST-parse only, never a pre-parse regex. `new URL()` does not reject `javascript:`/`file:`/`data:` schemes by itself — always follow with an explicit allowlist check:
```js
// src/validate.js — the ONLY correct pattern for this project
export function validateUrl(str) {
  let u;
  try {
    u = new URL(str);
  } catch {
    throw new AppError('INVALID_URL', 400, 'Malformed URL');
  }
  if ((u.protocol !== 'http:' && u.protocol !== 'https:') || u.hostname.length === 0) {
    throw new AppError('DISALLOWED_PROTOCOL', 400, 'Only http/https URLs with a host are allowed');
  }
  return { href: u.href }; // canonical form — store/redirect u.href, never the raw input
}
```
- Typed errors only: every thrown/handled error is an `AppError { code, status, message }` from `src/errors.js`, the single source of truth for the code→status table. Never let a raw `Error`/stack trace reach a client response — map unexpected internals to generic `500 INTERNAL_ERROR` and log detail server-side only.
- `src/server.js` exports a factory `createServer()` returning an **unstarted** `http.Server`. Never call `.listen()` inside `src/server.js` — that is `bin/server.js`'s job. This seam is what lets tests bind an ephemeral `listen(0)` port.

## 4. Testing
- Framework: `node:test` + `node:assert/strict`. No test runner dependency (Jest/Mocha/Vitest are out of scope — zero-dep constraint).
- File naming: `test/*.test.js`, run via `node --test` (auto-discovers `*.test.js` under `test/`).
- Every test that starts a server MUST: `server.listen(0)`, `await once(server, 'listening')` before reading `server.address().port` (listen is async — reading the port earlier is a real race, not a hypothetical one), register `t.after(() => new Promise(r => server.close(r)))` and **return** that promise so the runner blocks on port release.
- Drain every HTTP response body in every test path, including the empty 302 body — an undrained keep-alive response is the #1 cause of a hung `node --test` run in this project.
- `node:http` does not auto-follow redirects: assert `res.statusCode === 302` and `res.headers.location` directly; never `await fetch()` expecting auto-follow semantics here.
- Minimum required coverage per PLAN.md §7 (Correctness SLO): full round-trip (`POST /shorten` → `GET /:code` → 302 to the same URL), each typed-error code in the §5/§7 table asserted on BOTH `res.statusCode` AND the parsed `body.error.code`, 404 on unknown path, 405 + `Allow` header on wrong method for a known path, 413 on oversized body, and a forced-collision test that drives `store.save` to `CODE_GEN_EXHAUSTED`.

## 5. Security
- Scheme allowlist is mandatory and must be checked **after** `new URL()` parses, never before (see §3 snippet) — a pre-parse regex is bypass-prone and already rejected as a design option in PLAN.md.
- Body size cap: track accumulated byte length while reading the request stream; if it exceeds 1 MB, `req.destroy()` and respond `413 PAYLOAD_TOO_LARGE` **before** attempting `JSON.parse`. Unbounded accumulation before parsing is an unbounded-memory DoS vector.
- Bounded collision retry only: short-code generation must cap retries (~8 attempts) and throw typed `CODE_GEN_EXHAUSTED` (500) on exhaustion — never an unbounded `while` loop against the store.
- Client-facing error bodies are exactly `{ error: { code, message } }`, nothing else — no stack traces, no internal paths, no raw exception messages leaking to the response. Log full detail server-side only.
- SSRF / private-IP / cloud-metadata blocking (`127.0.0.1`, `169.254.169.254`, `::1`) is explicitly OUT OF SCOPE. Protocol allowlisting is a syntax check, not a network-safety guarantee — the README must state this so "validated" is never conflated with "safe to fetch." Do not add SSRF mitigations without first updating PLAN.md scope.
- No auth, no rate limiting, no TLS termination in this service — all stated non-goals for the local/embedded use case, not oversights. Do not silently add any of them.

## 6. Commit / PR
Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`, `chore:`). Reference the PLAN.md task ID being closed when applicable (e.g. `feat: implement bounded collision retry in store.js (T2b)`).

## 7. §14 Production-layer ownership (scoped to this request)

| Layer | Scope | Owner | Folder | Focus |
|---|---|---|---|---|
| 1. Frontend | OUT-OF-SCOPE (no UI — pure JSON API, no browser client) | — | — | — |
| 2. APIs & Backend Logic | IN-SCOPE | Node/HTTP API & Validation-Security Engineer | `src/`, `bin/` | Route dispatch (`server.js`), typed input validation (`validate.js`), error taxonomy (`errors.js`) per PLAN.md §5/§7 |
| 3. Database & Storage | IN-SCOPE (in-memory only) | Node/HTTP API & Validation-Security Engineer | `src/store.js` | `Map`-backed store with bounded collision-safe code generation; explicitly NOT persistent (RPO=∞ by design, stated in README) |
| 4. Auth & Permissions | OUT-OF-SCOPE (public unauthenticated shortener, stated non-goal in PLAN.md §"Layer depth: API CONTRACT") | — | — | — |
| 5. Hosting & Deployment | OUT-OF-SCOPE (local/embedded process only; no container/PaaS target defined in scope) | — | — | — |
| 6. Cloud & Compute | OUT-OF-SCOPE (single local Node process, no cloud provider named) | — | — | — |
| 7. CI/CD & Version Control | OUT-OF-SCOPE (no CI pipeline requested in scope; commit hygiene only, see §6) | — | — | — |
| 8. Security & RLS | IN-SCOPE (input-validation security only — no RLS, no DB) | Node/HTTP API & Validation-Security Engineer | `src/validate.js`, `src/errors.js` | Scheme allowlist, body-size cap, typed-error envelope, no-stack-trace-leak guarantee |
| 9. Rate Limiting | OUT-OF-SCOPE (stated non-goal in PLAN.md §"NFRs/SLOs" — flagged as a candidate follow-up if promoted beyond local use) | — | — | — |
| 10. Caching & CDN | OUT-OF-SCOPE (in-memory Map IS the entire data path; no CDN/edge layer in scope) | — | — | — |
| 11. Load Balancing & Scaling | OUT-OF-SCOPE (single-process by design; PLAN.md states RTO = process restart, no HA/multi-AZ) | — | — | — |
| 12. Observability & Logs | IN-SCOPE (minimal — listening-address log only) | Node/HTTP API & Validation-Security Engineer | `bin/server.js` | Log bound address on `listening` event as the readiness signal; server-side-only error logging (no `/healthz` route — stated follow-up, not silently dropped) |
| 13. Availability & Recovery | OUT-OF-SCOPE (accepted RPO=∞/RTO=restart per PLAN.md §"NFRs/SLOs" — in-memory store is explicitly non-durable) | — | — | — |

Also in scope (cross-cutting, not a single §14 layer): **node:test HTTP Integration-Test Engineer** owns `test/*.test.js` (§4 above); **Technical Writer (API README)** owns `README.md` — endpoint table, typed-error table (byte-for-byte match to `src/errors.js`), run/test commands, and the explicit non-goals list (SSRF, auth, rate limiting, persistence, HA).

The terminal audit (layer_walk) validates this table against the built code — do not mark a layer IN-SCOPE unless a folder/file above actually implements it, and do not silently implement a layer marked OUT-OF-SCOPE without updating this table and PLAN.md first.
