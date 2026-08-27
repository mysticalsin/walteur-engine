---
name: build-with-agent-team
license: MIT
description: >-
  BUILD-WITH-AGENT-TEAM v1.0 — the parallel-build orchestration companion to WALTEUR, for when a build fans
  out to >1 worker across an integration boundary (frontend+backend, microservices, an SSE emitter+reader —
  any two agents that meet at a wire). Triggers: /build-team, /parallel-build, "build the frontend and backend
  in parallel", "split this across agents", "the API and the UI don't match", or WALTEUR §5.6 SWARM spawning
  >1 worker that share a contract. claude-squad + disjoint-file-ownership stop write COLLISIONS but not
  integration MISMATCH; the fix is CONTRACT-FIRST — the lead AUTHORS the integration contract before spawning
  workers, names cross-cutting-concern owners, runs a CONTRACT-DIFF before integration, and closes with a
  lead-level E2E. PROTOCOL discipline (made HARD by an integration test).
metadata:
  type: orchestration-companion
  version: 1.0
  status: standing-companion
  pairs_with: walteur (build engine ≥ v9.0)
  sibling: walteur-discover (WHAT is worth building) · walteur-design (how it LOOKS) — this = how the PARTS MEET
  enforcement: "PROTOCOL (lead judgment) — the contract artifact + named owners + contract-diff + lead E2E. Made HARD only when you add a real integration test (backend-fixture ↔ frontend-decoder) the §5.6 wave or ship-gate runs."
  extends: "WALTEUR §5.6 SWARM (parallel dependency waves) + §5.1 claude-squad worktree isolation + §5.2 file-ownership"
  synthesizes:
    - context-engineering-intro (Cole Medin, MIT) — the parallel-agent / context-engineering build pattern: a lead engineers the shared context (the contract) BEFORE fan-out, rather than letting each worker infer the boundary; adapted into WALTEUR's terse cite-or-veto idiom (never raw prose).
---

# BUILD-WITH-AGENT-TEAM v1.0 — contract-first parallel orchestration

> **WALTEUR builds the parts right. BUILD-WITH-AGENT-TEAM makes the parts MEET.**
> The integration counterpart of plan-before-build: **NO PARALLEL FAN-OUT WITHOUT A WRITTEN CONTRACT.**
> claude-squad gives worktrees. Disjoint-file-ownership stops write collisions. Neither stops the
> classic parallel-build failure: two agents finish green, owning different files, and **don't meet at the wire.**

---

## 0. THE INTEGRATION LAW (PROTOCOL — judgment, made HARD by a test)

**Before WALTEUR fans a build out to >1 worker that share a boundary, the lead AUTHORS the integration contract — then the workers build TO it, not toward a guessed shape.**

Why a contract, not vibes: §5.2 file-ownership + §5.1 worktrees make parallel work *collision-free* — two agents never write the same file. But collision-free is not *integration-correct*. Each worker, isolated, infers the boundary from its own side and the two inferences drift apart. The build is 100% green on both sides and 0% working end-to-end. **The contract is the one piece of context both workers must SHARE — engineer it first (this is the context-engineering pattern: the lead owns the shared context, not each worker's guess).**

**Honesty (WALTEUR §1):** this skill is **PROTOCOL** — a discipline the lead runs with judgment. It does NOT mechanically block a ship. The contract-diff (§4) and the lead E2E (§5) become **HARD** the moment you encode them as a real integration test (a backend response fixture the frontend decoder must parse, run by the §5.6 wave or ship-gate) — see §6. Until then: a written contract + a passing contract-diff is *evidence the parts will meet*, never *proof they do*. Never sell "both sides are green" as "it integrates." Absence of a contract-diff finding = NOT-RUN, never PROVEN-INTEGRATED.

## 1. WHERE THIS SITS IN THE SWARM (it doesn't replace §5.6 — it precedes the fan-out)

§5.6 SWARM topo-sorts the task DAG into waves and runs each wave's disjoint-file tasks in parallel. This skill is the **discipline the lead runs at the boundary between the scaffold wave and the parallel-worker wave** — after the roster is designed (§5.6 `create_subagent`), before `assign_task` dispatches the workers.

```
THINK → PLAN (task DAG, disjoint files §5.2)
  → SWARM scaffold wave (§5.6 — a scaffold task always runs first)
  → ⟦ THIS SKILL ⟧  author CONTRACT (§2) · assign concern OWNERS (§3)
  → SWARM parallel worker wave (§5.6 — each in its worktree §5.1, building TO the contract)
  → ⟦ THIS SKILL ⟧  CONTRACT-DIFF (§4) before integration
  → integrate → lead-level E2E (§5) → WALTEUR §5 panel · §5.4 QA corps · §5.5 audit
```

The SWARM gives speed and isolation. This skill gives the **shared boundary** the isolation would otherwise hide.

## 2. THE CONTRACT — what the lead AUTHORS before spawning workers

The lead writes one artifact (suggest `walteur-kit/integration-contract.md` + a machine-checkable sidecar `walteur-kit/contract.json` when a diff test will read it). It pins EVERY boundary detail a worker would otherwise GUESS. Vagueness here = drift later. Pin all of:

| # | Pin | The drift it kills (caveman: two agent guess different, no meet) |
|---|---|---|
| 1 | **Exact endpoint URLs — incl. trailing slash** | `/api/users` vs `/api/users/` → 404 / 307-redirect that drops the POST body. The slash IS the contract. |
| 2 | **HTTP method + status codes** per route (200 vs 201 vs 204; which 4xx) | frontend treats 201-created as an error; backend returns 204-no-body where the UI awaits JSON. |
| 3 | **Request JSON shape** — exact field names, types, required vs optional, casing | `userId` vs `user_id` vs `id`; `camelCase` vs `snake_case`; a field one side sends and the other never reads. |
| 4 | **Response JSON shape — and the ENVELOPE: flat vs nested** | `{ "data": { "user": {…} } }` vs `{ "user": {…} }` vs `{…}`. The single most common parallel-build break. Pin the exact nesting depth. |
| 5 | **Error-body shape** (the unhappy path is a contract too) | success is `{data}` but error is `{error:{code,message}}` vs `{message}` vs a bare string vs an HTML 500 page. The UI's catch-block decodes a shape that was never agreed. |
| 6 | **SSE / WebSocket event types + per-event payload** | `event: token` vs `event: message` vs unnamed `data:` lines; `[DONE]` sentinel format; whether each frame is JSON or raw text; reconnect/last-event-id semantics. |
| 7 | **Auth header / token shape + where it rides** | `Authorization: Bearer …` vs `X-Api-Key` vs a cookie; the exact header name and scheme. |
| 8 | **Pagination / list shape** | `{items, nextCursor}` vs `{results, page, total}` vs a bare array + a `Link` header. |
| 9 | **Content-Type + serialization** | JSON vs `multipart/form-data` vs `x-www-form-urlencoded`; dates as ISO-8601 string vs epoch ms vs epoch s. |
| 10 | **Null/empty/absent convention** | missing key vs `null` vs `""` vs `[]` — and which the consumer must tolerate. |

Rule: **if a worker would have to ASSUME it, it goes in the contract.** A contract that omits the envelope or the trailing slash is a stub — it will pass review and fail integration. Author it to schema where a §6 test will consume it (then it is machine-checkable, not prose).

**Cite-or-it's-a-question:** every contract field is either pinned-by-the-lead or marked `ASSUMED` (and queued for the §4 diff to confirm). An unpinned field presented as settled is an overclaim (WALTEUR §1).

## 3. CROSS-CUTTING CONCERNS — name an OWNER, don't let them fall between workers

Disjoint-file-ownership has a blind spot: a concern that lives in NO single worker's files (it spans the boundary) gets **owned by nobody** and silently dropped — exactly the §5.2 collision problem inverted. The lead assigns a **named owner** (one worker, or the lead) for each spanning concern, BEFORE fan-out:

| Concern | Default owner | Why it falls through the cracks |
|---|---|---|
| **CORS / preflight** | backend worker (frontend confirms in diff) | both assume the other handles it; neither sets the allowed origin/headers. |
| **Auth token lifecycle** (issue · refresh · attach · 401-retry) | one named owner end-to-end | backend issues, frontend forgets to attach, or vice-versa — split ownership = no ownership. |
| **Error taxonomy** (the shapes in §2.5) | the contract author (lead) | the unhappy path has no file of its own; it spans every route. |
| **Idempotency / retry keys** | backend worker | double-submit on a flaky network with no agreed key. |
| **Time zone / clock / date encoding** | the contract author (lead) | one side ISO-8601-UTC, the other local-epoch — silent off-by-hours. |
| **Pagination contract** | backend worker | shape pinned in §2.8 but cursor semantics owned by no one. |
| **Versioning / breaking-change policy** | lead | nobody owns "what happens when the shape changes." |

Write the owner table into the contract artifact. **A spanning concern with no named owner is the parallel-build equivalent of a swallowed error** — assign it or it disappears.

## 4. THE CONTRACT-DIFF — prove the parts meet BEFORE integration (the load-bearing step)

After the parallel wave finishes and before integration, the lead runs a **contract-diff**: exercise EACH side against the contract independently, then diff the two observed shapes. This catches drift while it is still cheap (each worker is still in its worktree §5.1).

Minimum diff (PROTOCOL — the lead runs and reads it; do NOT trust either worker's self-report — re-observe, WALTEUR §1):

1. **Backend side — observe the REAL emitted shape.** Hit the actual endpoint and capture what it *actually* returns (not what the code "should" return):
   ```bash
   # exact URL incl. trailing slash; capture status + body + content-type
   curl -sS -w '\n%{http_code} %{content_type}\n' -X POST http://localhost:PORT/api/users/ \
     -H 'Content-Type: application/json' -d '{"email":"a@b.co"}'
   # SSE: observe the actual event names + payload framing
   curl -sN http://localhost:PORT/api/stream | head -20
   ```
2. **Frontend side — observe the EXPECTED shape.** Read the decoder/fetch the worker wrote and extract the shape it assumes — the URL it calls, the envelope it unwraps, the error key it reads, the SSE event name it listens for.
3. **DIFF the two against the contract (§2).** For each of the 10 pins: backend-observed vs frontend-expected vs contract. Any mismatch is a finding:
   - URL/slash mismatch · method/status mismatch · envelope flat-vs-nested mismatch · field-name/casing mismatch · error-shape mismatch · SSE-event-name mismatch · auth-header mismatch · date-encoding mismatch · null-convention mismatch.
4. **A finding blocks integration** (PROTOCOL stop). Fix the side that drifted from the contract — never "adjust the contract to match the code" silently; if the contract was wrong, the lead RE-AUTHORS it (§2) and BOTH sides realign. The contract is the source of truth, not whichever side finished first.

> **Make it HARD (§6):** encode the contract-diff as a real integration test — a recorded backend response fixture that the frontend decoder must parse, run by the §5.6 wave / ship-gate, exit-2 on mismatch. Then "the parts meet" stops being lead judgment and becomes a re-run exit code (WALTEUR's DONE-certificate = evidence, A1).

> **The meta-anti-pattern this whole skill kills — optimistic green:** both workers report green from their own unit tests, neither ran the *other* side. Green ≠ integrated (WALTEUR §1). The per-pin drift classes the diff hunts (envelope, trailing-slash, SSE event-name, error-shape, casing, status-code, date encoding, null-vs-absent, auth-header, pagination) are the "drift it kills" column of the §2 table; CORS-owned-by-nobody is §3.

## 5. THE LEAD-LEVEL E2E (the close — one real round-trip, not two green units)

After integration, the **lead** (not either worker) runs ONE end-to-end round-trip across the full boundary and OBSERVES it — the smallest path that exercises every pinned contract point at once:

- start both sides, drive the real happy path (login → fetch → render, or prompt → stream → display) and watch the actual output;
- drive ONE unhappy path (a 4xx/5xx) and confirm the frontend decodes the §2.5 error shape and shows a real message, not `undefined`;
- for streams: confirm the first token renders, the stream completes, and the `[DONE]` sentinel closes cleanly.

This is the WALTEUR verification law applied to the seam: **"both sides are green" is not proof; the observed round-trip is.** The lead E2E feeds the §5.4 QA corps (Integration dimension) and the §5.5 terminal audit — it is the evidence those gates anchor to. A green E2E with no observed output recorded is an overclaim.

## 6. MAKE IT HARD — from PROTOCOL discipline to a re-run exit code

This skill is PROTOCOL by default. Two steps promote the load-bearing parts to HARD (mechanically blocking), in WALTEUR's honest idiom — a real exit 2 on a real violation, detect-or-LOUD-SKIP when the prerequisite is absent:

1. **Contract-diff as an integration test.** Write the contract's response shape as a fixture (`walteur-kit/contract.json` or a recorded fixture file); write a test asserting the frontend decoder parses the fixture and the backend emits its shape. Wire it into the §5.6 wave (or ship-gate). Mismatch → exit 2 — now §4 is HARD. Fixture/endpoint absent → LOUD SKIP (recorded, exit 0), never silent-green.
2. **Contract presence/non-stub gate (optional).** A discipline-gate hook (sibling of `prd-gate.sh` / `design-gate.sh`) can exit-2 when a multi-worker boundary exists but `walteur-kit/integration-contract.md` is missing or a stub; single-worker build → NOT_APPLICABLE (exit 0, loud). **Honesty:** such a gate is HARD only on the contract's EXISTENCE/non-stub shape — whether the contract is CORRECT stays PROTOCOL (the §4 diff + the §5 E2E). Never sell existence as correctness.

> Until you wire step 1, the contract-diff is evidence, not proof. That distinction is the skill's honesty boundary — state it; don't erase it.

## 7. INTEGRATION MAP + SCALING

Composes with WALTEUR v9.0: this skill runs AFTER the §5.6 SWARM roster is designed and authors the contract (§2) BETWEEN the scaffold wave and the parallel-worker wave; §5.2 file-ownership / §5.1 worktrees are the prerequisite (they stop write collisions, this stops the mismatch they can't see); the lead E2E (§5) + contract-diff (§4) are the §5.4 QA-corps Integration evidence; the contract IS the documented intent the §5.5 AUDIT proves built==contracted against; the §6 HARD integration test plugs into the ship-gate. On a genuine contract fork (envelope flat vs nested, REST vs SSE) → /adhd → §5.3 debate → ADR.

**Scale the overhead to the boundary:** solo / one file → none (NOT_APPLICABLE); two workers, trivial shared type → a thin contract, eyeball the diff; frontend+backend pair → full §2 contract + §3 owners + §4 diff + §5 E2E; ≥3 services / a stream / external partner API → add the §6 HARD test + a contract per boundary + a versioning owner (§3). On `full_autopilot` the WALTEUR Chief authors and self-signs the contract as it self-signs the PLAN/PRD — contract-first adds rigor, not a human stop, except the existing Tony-only forks.

---

*Provenance: synthesizes the parallel-agent / context-engineering build pattern from **context-engineering-intro** (Cole Medin, MIT) — a lead engineers the shared CONTEXT (here, the integration contract) before fanning work out to parallel agents, rather than letting each isolated worker infer the boundary — adapted into WALTEUR's terse, evidence-backed, cite-or-veto idiom (never raw prose). Extends WALTEUR §5.6 SWARM + §5.1 claude-squad worktree isolation + §5.2 disjoint-file-ownership. Sibling of walteur-discover (WHAT is worth building) and walteur-design (how it LOOKS); this companion is how the PARTS MEET. PROTOCOL discipline by default; the contract-diff and lead E2E become HARD when encoded as a real integration test (§6). By Tony Walteur.*
