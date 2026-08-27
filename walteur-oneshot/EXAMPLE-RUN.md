# EXAMPLE-RUN — walteur-oneshot dry-run trace

A worked trace of the full loop on a toy goal, showing how each phase and gate is exercised. Illustrative (not executed here) — it demonstrates the shape of a real run, including gates that legitimately **skip with a reason**.

**Goal given:** "one-shot build a CLI that counts words in a file."

---

### 1. FRAME & DISCOVER
- **Current-reality:** run-date checked; target stack = Python 3.12 stdlib (no deps needed — verified `argparse`/`open` are current, no stale API). Not a user-facing product → best-in-class benchmark **skipped (reason: internal CLI, no market category)**; PRD **skipped (reason: not user-facing)**.
- **SCOPE (≤5 Qs, one batch):** *(1)* success = correct word count matching `wc -w` on UTF-8 text; *(2)* in scope: one file arg, stdin fallback; out: encodings beyond UTF-8, globbing; *(3)* stack: Python stdlib; *(4)* hard lines: none (no PII/money/prod); *(5)* autonomy: full autopilot.
- **Exit — locked scope:** "A Python 3.12 CLI `wc-words <file>` (stdin fallback) that prints the UTF-8 word count, matching `wc -w`, with a non-zero exit + stderr on a missing file."

### 2. PLAN + DEBATE  *(HARD gate)*
- **Improved brief:** outcome = drop-in `wc -w` for words; non-goals = char/line counts, non-UTF-8; acceptance = matches `wc -w` on 3 fixtures + empty + missing-file error.
- **Plan written to `PLAN.md`** (architecture: single `main()` + `count_words(text)->int`; edge cases: empty file → 0, missing file → exit 2 + stderr, huge file → stream by line; test matrix: 5 cases).
- **DEBATE fork:** read-whole-file vs stream-by-line → **ADR:** stream by line (decision · why: bounded memory on huge files · rejected: read-all is simpler but O(filesize) memory · dissent: none for this scope).
- ✅ **plan-before-build** HARD gate satisfied — `PLAN.md` exists before any code.

### 3. ESTIMATE
tokens ≈ 3k–6k · time ≈ 2–4 min · cost ≈ trivial. (Autopilot → recorded, proceeds.)

### 4. BUILD
ACT → TEST → ANALYZE → REFINE → RETEST → COMMIT: wrote failing test `test_count_words` (5 cases) → minimal `count_words` + `main` → tests green → committed. No scope creep (no char/line flags added).
- ✅ **current-stack** HARD: stdlib APIs verified current, none hallucinated.

### 5. REVIEW + QA
- **REVIEW** (sequential lenses, single context): Architecture — clean `count_words` boundary, cited `wc_words.py:12`; Security — reads a path, no shell, no injection surface (floor met). Product — matches scope.
- **QA CORPS** — Functional: file/stdin/empty/missing/huge ✓. **Logic & Correctness** (dedicated pass): built an input that breaks a naive `split()` — multiple spaces + trailing newline + a tab; confirmed `str.split()` collapses runs correctly, count matches `wc -w`. Data-Integrity / Integration: **skipped (reason: no DB, no external service)**.
- ✅ **evidence/re-run** HARD: re-ran `python -m pytest -q` myself → `5 passed`, exit 0 (not self-reported).
- ✅ **anti-slop**: linter zero warnings, no TODO/placeholder, small module. UI arm **skipped (reason: CLI, no UI)**.
- ✅ **no-hollow-artifact**: real working CLI, run against a real file, not a stub.

### 6. TERMINAL AUDIT  *(fresh eyes)*
Re-derived evidence: re-ran the suite (`5 passed`) and ran the binary against a fixture — output matched `wc -w`. Intended-vs-implemented: intent "exit non-zero on missing file" (quoted from scope) ↔ code `wc_words.py:23 sys.exit(2)` + stderr — both cited. No launch blockers. **Certified: shippable.**

### 7. SHIP + REFLECT
Shipped as a reviewable diff (human reviews). Proof attached: `pytest 5 passed exit 0` + a sample run. **Gaps stated:** UTF-8 only; non-UTF-8 encodings deferred (signed out-of-scope). **Lesson captured (1):** "For text-counting CLIs, diff against the platform `wc` on an adversarial whitespace fixture — a passing unit test with clean inputs hides run-collapse bugs."

---

**Gate ledger (honesty law — every gate accounted for):**
| Gate | Result |
|---|---|
| plan-before-build (HARD) | ✅ PLAN.md before code |
| current-stack (HARD) | ✅ stdlib verified current |
| anti-slop (PROTOCOL) | ✅ code/prose · UI arm skipped (no UI) |
| security-floor (HARD) | ✅ no injection surface |
| evidence/re-run (HARD) | ✅ pytest re-run, exit 0 |
| no-hollow-artifact (PROTOCOL) | ✅ real CLI |
| terminal-audit certification (PROTOCOL) | ✅ certified, intent↔code cited |

Every gate passed **or** skipped with a stated reason — none silently green.
