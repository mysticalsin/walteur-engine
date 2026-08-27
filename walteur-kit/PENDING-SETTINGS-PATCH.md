# PENDING-SETTINGS-PATCH — hook false-blocker remediation (2026-07-17)

> Closes the open `_relay/ISSUES.md` escalation (2026-07-03) about `tdd-guard.sh` / `ship-gate.sh`
> false-blocking automation. **Status:** evidence-backed + verified-by-inspection + deterministic
> mechanism repro. NOT auto-applied — the hooks are automation-write-protected (classifier blocks agent
> edits to hooks that gate the agent), and the framework selftest can't be run right now (OneDrive throttled).
> **Apply → then run `bash .claude/hooks/tdd-guard.sh --selftest` (or gate-suite) before relying on it.**

---

## Fix 1 — `tdd-guard.sh:26` — SIGPIPE/pipefail false-block  (REAL BUG — apply)

**Root cause.** Line 26 tests test-existence with `find … -print | grep -q .` under `set -uo pipefail`
(line 15). `grep -q` exits on the FIRST match; in a repo with many matching test files, `find` keeps
writing to the now-closed pipe → receives **SIGPIPE → exit 141**. Under `pipefail` the pipeline's status
becomes 141 (non-zero), so `if ! <pipeline>` takes the **"no tests"** branch and **exit 2 blocks a
legitimate source edit even though tests exist.** It is a race (buffer/timing dependent), which is why it
deadlocks edits intermittently and unpredictably.

**Evidence (deterministic, this machine).**
```
set -o pipefail; seq 1 100000000 | grep -q . ; echo $?     # => 141  (should be 0)
# => `if ! seq … | grep -q .` reports "empty/not-found" on an obviously non-empty stream
```
Live this session: a `src/lib/scoring.ts` edit in a repo with hundreds of test files was blocked with
`TDD: no tests exist yet.` See memory `pipefail-sigpipe-grep-q-trap` (a prior incident where it
"deadlocked ALL .sh edits").

**BEFORE (lines 26–29):**
```bash
if ! find "$ROOT" -path "*/node_modules" -prune -o \( -name "*test*" -o -name "*spec*" \) -type f -print 2>/dev/null | grep -q .; then
  echo "TDD: no tests exist yet. Write a FAILING test first, then implement. (bypass: WALTEUR_TDD=off)" >&2
  exit 2
fi
```

**AFTER (SIGPIPE-immune — `-print -quit` makes `find` EXIT after the first match: no pipe, no SIGPIPE, faster):**
```bash
_first_test="$(find "$ROOT" -path "*/node_modules" -prune -o \( -name "*test*" -o -name "*spec*" \) -type f -print -quit 2>/dev/null)"
if [ -z "$_first_test" ]; then
  echo "TDD: no tests exist yet. Write a FAILING test first, then implement. (bypass: WALTEUR_TDD=off)" >&2
  exit 2
fi
```

**Why safe.** Identical semantics — block iff no `*test*`/`*spec*` file exists — but the emptiness check
reads a CAPTURED STRING, not the SIGPIPE-corrupted pipeline exit code. Fixes only a false-BLOCK; does not
weaken TDD enforcement (still blocks when genuinely no tests). `-print -quit` verified on macOS `find`
(Darwin) and is standard on GNU find. Verified: with 3000 test files, both the buggy and fixed forms were
exercised; the fixed form is deterministically correct.

**Portable fallback** (only if some target `find` lacks `-print -quit`):
```bash
_first_test="$(find "$ROOT" -path "*/node_modules" -prune -o \( -name "*test*" -o -name "*spec*" \) -type f -print 2>/dev/null | head -n1)"
```
(`head -n1` still SIGPIPEs `find`, but the verdict is read from the captured string — immune. Verified.)

---

## Fix 2 — `ship-gate.sh` command-guard — NOT a bug; deliberate fail-safe (owner decision, do NOT auto-change)

The 2026-07-03 escalation said ship-gate fired on any command containing `git` + substring
`staging`/`storage`. **That is already fixed** — the current guard (line 32) matches **word-bounded `git`
AND `commit|tag`**:
```bash
if printf '%s' "$CMD" | grep -Eq '(^|[^a-zA-Z0-9_])git([^a-zA-Z0-9_]|$)' && printf '%s' "$CMD" | grep -Eq 'commit|tag'; then
```
`staging`/`storage` no longer match.

**Residual (by design).** It still over-triggers when a benign git command contains `commit`/`tag` as a
substring ANYWHERE — a comment, an `echo` string, a branch name, `commits`, `hotfix-tags`. This bit this
session: a `git clone …; echo "…contains baton commits…"` matched `commits` → ship-gate ran → failed on an
unmet DoD → blocked a benign clone.

This over-trigger is **deliberate fail-safe** (lines 27–29): it only ADDS a gate to an unrelated command
and can never let a real ship transition (incl. indirection like `g=git; $g commit`) slip through.
Loosening it is a **security tradeoff on a HARD gate → an owner decision, not an autonomous change.**

Options (only if the automation friction outweighs the fail-safe):
- **(a) Keep as-is** (recommended). Automation uses the documented `bash <script.txt>` workaround so no
  `git`+`commit/tag` appears in the Bash-tool command string.
- (b) Require `git` adjacent to a `commit`/`tag` subcommand token on the executed segment
  (e.g. `\bgit\b[^|;&]*\b(commit|tag)\b`) — fewer false-fires but reopens some indirection.
- (c) Parse the first token per `;`/`&&`-segment and fire only when a git invocation's subcommand is
  literally `commit`/`tag`.
**Recommend (a).** Do NOT auto-apply (b)/(c) — they weaken the fail-safe.

---

## Apply + verify
1. Apply **Fix 1** to `.claude/hooks/tdd-guard.sh` (and any canonical `walteur-starter` copy; keep the
   copies md5-identical per the framework's spec-parity rule).
2. Run `bash .claude/hooks/tdd-guard.sh --selftest` and the gate-suite; confirm green.
3. **Fix 2**: no code change unless you choose (b)/(c); if so, re-run the ship-gate selftest afterward.

---

## Fix 3 — wire the R6 eval-harness self-regression runner (BUILT + VERIFIED this session)

Delivered to `walteur-kit/eval-harness/`: `self-regress.sh` (hermetic `--selftest` 7/7) + `manifest.json`
(11 fixtures) + `baseline.json` (frozen **11/11 PASS** against the real v10 gates). It drives every
poisoned/clean fixture through its real gate and exits 2 if any gate went blind on its poison or
false-fires on its clean twin — the measured self-regression (roadmap R6/P2). Run standalone now:
`WALTEUR_ROOT=<repo> bash walteur-kit/eval-harness/self-regress.sh` → PASS 11/11.

Fixes it made (no gate weakened): (a) the runner STAGES each fixture in a temp dir outside `walteur-kit/`
because gates prune `*/walteur-kit/*` on the absolute path and would otherwise nuke fixtures that live
under `walteur-kit/eval-harness/`; (b) `clean-pkg` was an under-specified clean twin (vacuous `{}`
lockfile → supply-chain correctly failed it) — curated to a real clean package (left-pad dep +
`lockfileVersion 3` + integrity hash); supply-chain now PASSes it (verified).

To wire it into automatic reflect/ship dispatch (owner step — touches hooks + registry):
1. Add the thin gate wrapper (gates live in `hooks/`):
   `walteur-kit/hooks/self-regress-gate.sh`:
   ```
   #!/usr/bin/env bash
   exec bash "$(cd "$(dirname "$0")/../eval-harness" && pwd)/self-regress.sh" "$@"
   ```
2. Register in `walteur-kit/gate-registry.json` (gates array):
   ```
   {"id":"self-regress","stage":"reflect","hardness":"hard","availability":"spec",
    "hook":"self-regress-gate.sh","report":"walteur-kit/eval-harness/self-regress-report.json",
    "evidence":"Every poisoned fixture is caught by its gate and every clean twin passes."}
   ```
3. Add to `ship-gate.sh` reflect/ship dispatch (near the other META gates, ~line 274):
   `run_gate self-regress-gate.sh`
4. Verify: `bash walteur-kit/hooks/gate-suite.sh` must stay green (self-regress's `--selftest` joins the suite).
