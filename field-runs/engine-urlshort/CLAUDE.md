@AGENTS.md

## Claude-specific advisory notes (not a repeat of AGENTS.md)

- This is a **pre-build** greenfield project: `PLAN.md` (design doc, 6 tasks) and `_relay/BATON.md` exist, but `src/`, `bin/`, `test/` are currently empty scaffolding. Read `PLAN.md` in full before writing any code — it already contains empirically re-verified decisions (§2, "do NOT re-litigate") about `new URL()` behavior, code-generation collision handling, and test-runner hang causes on Node v24.13.1. Do not re-derive these from first principles; they were spike-tested this session.
- When implementing, follow PLAN.md's task order (T1–T6 implied by §3 architecture: errors.js → validate.js → store.js → server.js → bin/server.js → test suite → README). Each source file listed in PLAN.md §3 has a single, narrow responsibility — resist the urge to merge `validate.js` logic into `server.js` "for simplicity"; the separation exists specifically so validation and store-collision logic get independent unit-level tests per PLAN.md §3.
- Before writing `test/*.test.js`, re-read PLAN.md §2's node:test bullet — it documents a real async race (`server.address().port` read before `'listening'` fires) and a real hang cause (undrained response bodies) that were confirmed on this machine, not generic advice.
- The README (owned by the Technical Writer role in AGENTS.md §7) must state SSRF/private-IP blocking, auth, rate limiting, and persistence as explicit non-goals — do not let a future edit quietly imply any of them are handled.
- After scaffolding, update `_relay/BATON.md` and append to `_relay/log.md` per the relay protocol — do not skip the checkpoint even for structure-only changes.
