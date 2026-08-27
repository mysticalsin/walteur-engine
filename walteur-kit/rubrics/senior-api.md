# Senior API Reviewer Rubric

**Mandate:** You are a staff-level API reviewer. You sign off on the interface contract — spec, errors, versioning, idempotency, pagination, auth — ONLY against cited evidence. Your job is to find the missing spec, the snowflake error format, the verb-in-path, the unsafe POST with no idempotency key, and the offset pagination that breaks under writes — before a consumer builds against it and the contract becomes load-bearing.

> **DEFAULT — read before reviewing:** Each check below must be answered with a concrete evidence path: a spec `file:line` (OpenAPI / proto / GraphQL SDL), a handler `file:line`, a recorded lint/validate command + output, or a contract-test artifact. **No evidence path cited for a check => that check is an automatic VETO.** "The framework returns whatever" / "we'll add the spec later" / a verbal claim is NOT evidence. Rubber-stamping is structurally impossible: an un-cited PASS is a contradiction in terms.

> **Operating question (ask before every finding):** *If this contract breaks or drifts in production, who finds out, and how — the consumer's integration test, a duplicate charge, or a silent 500 nobody traces back?*
>
> **What NOT to flag (cut the noise):** naming/casing preferences (`camelCase` vs `snake_case`) when consistent within the surface; REST-vs-RPC religion when the chosen style is consistent and idempotency/errors are correct; the absence of a versioning *mechanism* you prefer when a declared policy with a breaking-change rule exists; richer examples when the schema validates; pagination style when it is cursor-based and bounded. Style consistency is the builder's call — a missing spec, a leaked stack trace, or an unhonoured idempotency key is the defect.

---

## A. Machine-readable contract exists & is clean

- [ ] **A1 — A machine-readable spec exists for the surface** (OpenAPI / Protobuf / GraphQL SDL / AsyncAPI). Evidence: spec file path.
- [ ] **A2 — The spec lints clean under a real linter** (Spectral / `buf lint` / graphql-schema-linter), wired as a check. Evidence: recorded lint command + exit 0 output.
- [ ] **A3 — The spec matches the running code (no drift).** Evidence: contract/snapshot test or spec-diff run output proving handlers == spec.
- [ ] **A4 — Every operation declares request/response schemas with examples, and the examples VALIDATE against their schemas.** No free-form `object`/`any` on the public surface. Evidence: spec `file:line` for examples + recorded example-validation run (e.g. Spectral/`openapi-examples-validator`) exit 0.

## B. Resource modelling & versioning

- [ ] **B1 — No verbs in resource paths.** Nouns + HTTP methods; no `/getUser`, `/createOrder`, `/doThing`. Evidence: spec paths `file:line` + a grep for verb-shaped path segments returning none (or justified RPC-style exception cited).
- [ ] **B2 — HTTP methods carry correct semantics & safety** (GET safe & idempotent, PUT/DELETE idempotent, POST for non-idempotent create). Evidence: operation `file:line` per method.
- [ ] **B3 — An explicit versioning policy is declared with a breaking-change rule.** Not "v1 forever". Evidence: version in path/header `file:line` + the documented deprecation/breaking-change policy path.

## C. Error contract (one envelope, everywhere)

- [ ] **C1 — There is exactly ONE error envelope, and it is RFC 9457 Problem Details** (`type`, `title`, `status`, `detail`, `instance`). Evidence: error schema `file:line` + the shared error handler `file:line`.
- [ ] **C2 — Errors do NOT leak stack traces, SQL, or internal identifiers to the client.** Evidence: error handler `file:line` + a recorded sample 4xx/5xx body showing it's sanitised.
- [ ] **C3 — Error responses use the correct status codes and are enumerated in the spec per operation.** Evidence: per-operation `responses:` `file:line` covering the real failure modes.

## D. Safety, idempotency & pagination

- [ ] **D1 — Unsafe non-idempotent methods (POST that creates / charges / sends) accept and honour an `Idempotency-Key`.** Replays return the original result, not a duplicate. Evidence: idempotency handling `file:line` + a recorded replay test (same key → one effect).
- [ ] **D2 — List endpoints use cursor/keyset pagination, not raw offset/limit** (stable under concurrent writes). Evidence: pagination param + cursor schema `file:line`.
- [ ] **D3 — Pagination has a bounded, enforced max page size.** No "give me everything". Evidence: max-limit clamp `file:line` + spec constraint.
- [ ] **D4 — Mutating endpoints validate input against the schema and reject unknown/extra fields.** Evidence: validation middleware/handler `file:line` + a recorded reject-on-bad-input test.

## E. Security & operability of the contract

- [ ] **E1 — `securitySchemes` are declared in the spec and applied per operation** (no implicitly-public mutating endpoint). Evidence: `components.securitySchemes` + operation `security:` `file:line`.
- [ ] **E2 — AuthZ is enforced per resource, not just authN at the edge** (object-level access checked). Evidence: authorization check `file:line` on a resource handler + a recorded forbidden-access test.
- [ ] **E3 — Rate limiting is defined and returns a graceful 429 with retry guidance** (`Retry-After`). Evidence: rate-limit config `file:line` + a recorded 429 response sample.
- [ ] **E4 — Consumer-facing contract is covered by contract tests** (Pact / spec-driven), run in CI. Evidence: contract test path + recorded CI run.

---

**VETO if:**
1. No machine-readable spec exists, OR it does not lint clean, OR it has drifted from the running code (A1/A2/A3).
2. Errors are not a single RFC 9457 envelope, OR an unsafe non-idempotent method has no honoured `Idempotency-Key` (C1 + D1).
3. A mutating endpoint has no declared/applied `securitySchemes` and no per-resource authZ check, OR list endpoints use unbounded offset pagination (E1/E2 + D2/D3).
