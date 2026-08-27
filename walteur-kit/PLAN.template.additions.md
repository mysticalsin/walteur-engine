# PLAN / BATON template — additive blocks

> Two paste-in blocks for an existing `PLAN.md` (and the BATON handoff at end-of-run). ADDITIVE — they do
> not replace the PLAN spine (tasks · Why→PRD · traceability). Pure-prompt, zero infra. Caveman LITE prose;
> the markdown is exact — paste verbatim, fill the `<…>`.
>
> Provenance: block (a) reinforces WALTEUR `tdd-guard` (test-first is the law; this just NAMES the test before
> the source so the manifest itself reads test-first). Block (b) lifted from the context-engineering `/handoff`
> convention — "Dead Ends" + "Key Decisions (why + rejected alternatives)" (MIT, credit-clean).

---

## Block (a) — paste into PLAN.md (a "Relevant Files" manifest, test-file FIRST)

Name the TEST file BEFORE its source on every row. Reading the manifest top-to-bottom should read test-first,
because the build is test-first (`tdd-guard`: the failing test exists before the implementation). A source row
with no paired test is a RED row — either pair it or sign an explicit "no test because <reason>" on the line.

```markdown
## Relevant Files (test-file FIRST, then its source)

> Each source has a paired test named ABOVE it. Test exists/fails before the source is written (tdd-guard).
> A source with no test = RED: pair it, or write `no test — <reason>` inline. No silent untested source.

| # | Test file (write/fail FIRST) | Source file (under test) | Behaviour the test pins |
|---|------------------------------|--------------------------|-------------------------|
| 1 | `<path>.test.<ext>`          | `<path>.<ext>`           | `<one observable behaviour / AC id>` |
| 2 | `<path>.test.<ext>`          | `<path>.<ext>`           | `<…>` |
| 3 | `no test — <reason>`         | `<path>.<ext>`           | `<why this source is legitimately untestable>` |
```

---

## Block (b) — paste into the BATON / handoff at end-of-run

Two sections the next agent (or the future you) cannot recover from the diff alone: the paths you tried and
ABANDONED (so they are not re-tried), and the forks you RESOLVED with the alternatives you REJECTED (so they
are not silently re-opened). Lifted from context-eng `/handoff`.

```markdown
## Dead Ends (tried → abandoned — do NOT re-try)

> What was attempted and did not work, so the next agent does not burn the same hour. Each row: the approach,
> why it failed (cite the error/finding), and the signal that would make it worth REVISITING (or "none").

- **<approach tried>** — abandoned because `<concrete failure: error / benchmark / finding>`. Revisit if `<condition, or "none">`.
- **<approach tried>** — abandoned because `<…>`. Revisit if `<…>`.

## Handoff Hints (Tried X → broke Y → use Z instead)

> The redirect a Dead End cannot give. A Dead End says "do NOT re-try this"; a Handoff Hint says "and here is
> the path that WORKS instead." Each is one structured line — Tried X, the breakage Y (cite the error/finding),
> the working alternative Z — so the next shift skips the dead end AND lands on the live path without your chat.
> Leave Z empty only if no working path was found yet (then it is a Dead End, not a hint).

- **Tried:** `<X — the approach/tool/command/config you reached for>`
  - **Broke:** `<Y — the concrete breakage: error message / failing gate / benchmark regression>`
  - **Use instead:** `<Z — the alternative that worked, with the file/command/flag to use>`
- **Tried:** `<X>` — **Broke:** `<Y>` — **Use instead:** `<Z>`

## Key Decisions (why + rejected alternatives)

> The forks that shaped this build. Each: the decision, WHY (the load-bearing reason), and the alternative(s)
> REJECTED with the reason. A decision with no rejected alternative was not a fork — drop it or state the trade.

- **Decision:** `<what was chosen>`
  - **Why:** `<the load-bearing reason — cite evidence / constraint / PRD link>`
  - **Rejected:** `<alternative>` — because `<why not>`. `<alternative 2 if any>` — because `<…>`.
```

---

## Block (c) — paste into PLAN.md (a `<boundaries>` DO-NOT-CHANGE protected-paths declaration)

A declarative no-touch list: the paths this change is FORBIDDEN to modify (highest-blast-radius surfaces —
DB migrations, auth, prod config, anything where a wrong edit is catastrophic). This is the "minimal blast
radius" law made checkable. `gate-guard.sh` READS this block on every Write/Edit: an edit to a path matched
here gets a **LOUD WARN by default** (WARNING-FIRST — it does NOT block your edit). To make it a HARD block
(exit 2) for a high-stakes change, set `WALTEUR_BOUNDARIES=hard` for that session.

This is DISTINCT from disjoint-file-ownership (which partitions work across parallel agents): boundaries is a
single declarative "never touch these, regardless of who is editing" list. Paths are matched as shell globs
against the edited file's path (repo-relative or absolute). One path (or glob) per bullet.

```markdown
## <boundaries> — DO NOT CHANGE (protected paths)

> Edits to these paths are forbidden by this plan. gate-guard WARNs on a match (WARNING-FIRST); set
> WALTEUR_BOUNDARIES=hard to make it block (exit 2). To intentionally change one, amend THIS list first
> (state why in Key Decisions) — do not bypass silently. Globs allowed (e.g. `migrations/**`).

- `migrations/**`            — schema migrations are append-only history; a retro-edit corrupts every replica.
- `**/auth/**`               — authn/authz surface; a change here is a security review, not a drive-by edit.
- `**/*.prod.{env,config,yaml,yml,json}` — production config; ships through the release process only.
- `<add the protected paths specific to this change>`
```

---
*HONESTY: blocks (a) and (b) are PROTOCOL (judgment) — no hook enforces them. Block (a) supports `tdd-guard`'s
test-first law by shape; it does not replace it. A RED row (untested source) is a real finding, not a pass.
Block (c) IS read by `gate-guard.sh` — but WARNING-FIRST: it warns by default and only blocks under
`WALTEUR_BOUNDARIES=hard`, so it never silently changes today's edit behavior. State gaps; absence of a test
= NOT-FOUND of coverage, never proven-correct.*
