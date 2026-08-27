# PENDING — B03 hook patches (blocked by tdd-guard.sh false-fail bug)

## Why this file exists

`.claude/hooks/tdd-guard.sh` (wired on the Write|Edit|MultiEdit matcher) blocks every Edit/Write to a
non-test `.sh`/source file with `TDD: no tests exist yet.` — even though the repo demonstrably has test
files (e.g. `field-runs/apikeys-vault/core.test.mjs`, `walteur-kit/selftest.sh`).

**Root cause found and verified:** `tdd-guard.sh` line 26 runs under `set -uo pipefail`:

```bash
if ! find "$ROOT" -path "*/node_modules" -prune -o \( -name "*test*" -o -name "*spec*" \) -type f -print 2>/dev/null | grep -q .; then
```

`grep -q` exits as soon as it sees the first match, closing its end of the pipe. `find` then gets SIGPIPE.
Under `pipefail`, that turns the pipeline non-zero even though `grep -q` itself matched (found a test file),
so the `if !` branch fires and the gate reports "no tests" unconditionally. Verified directly:

```
$ bash -c 'set -uo pipefail; find "<ROOT>" -path "*/node_modules" -prune -o \( -name "*test*" -o -name "*spec*" \) -type f -print 2>/dev/null | grep -q .; echo $?'
141   # (or similar non-zero) — false NOTFOUND despite real matches existing
```

This blocks Edit/Write to **every** `.claude/hooks/*.sh` file (including editing `tdd-guard.sh` itself —
self-referential deadlock), so per binding constraint #6 ("If Edit/Write is DENIED on a protected path
(`.claude/hooks/*`, `.claude/settings.json`), do NOT work around it via bash redirection or any trick —
record it in blocked_paths and move on") the B03 patches below were NOT applied directly. They are recorded
here instead, ready to paste once `tdd-guard.sh` is fixed or `WALTEUR_TDD=off` is set for the apply session.

**Suggested fix for tdd-guard.sh** (out of scope for this task — flagging only): wrap the pipeline so grep's
early exit doesn't propagate `find`'s SIGPIPE under `pipefail`, e.g.:

```bash
if ! ( set +o pipefail; find "$ROOT" -path "*/node_modules" -prune -o \( -name "*test*" -o -name "*spec*" \) -type f -print 2>/dev/null | grep -q . ); then
```

---

## Patch 1 — `.claude/hooks/kill-switch.sh` — add `--selftest`

Apply instructions:
1. `WALTEUR_TDD=off` (or fix the bug above), then open `.claude/hooks/kill-switch.sh`.
2. Replace the final two lines (`[ -f "$(git rev-parse ...)/walteur-kit/PAUSED" ] ...` / `exit 0`) with the
   block below.
3. Run `bash .claude/hooks/kill-switch.sh --selftest` — expect `2/2 passed`.

```bash
case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

main() {
  [ -f "$ROOT/walteur-kit/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }
  exit 0
}

selftest() {
  pass=0; fail=0
  echo "kill-switch selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }

  t="$(mktemp -d "${TMPDIR:-/tmp}/kill-switch.XXXXXX")" || { echo "kill-switch selftest: mktemp failed"; return 1; }
  mkdir -p "$t/walteur-kit"
  touch "$t/walteur-kit/PAUSED"
  ck "fixture PAUSED present -> exit 2" 2 "$(run "$t")"
  rm -f "$t/walteur-kit/PAUSED"
  ck "fixture PAUSED absent -> exit 0" 0 "$(run "$t")"
  rm -rf "$t"

  echo "kill-switch selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
```

Full resulting file (paste over the whole file if easier — identical behavior on the default run path,
`WALTEUR_ROOT` override is additive/opt-in only):

```bash
#!/usr/bin/env bash
# Global pause: if walteur-kit/PAUSED exists, block all gated tool use. exit 2 = block.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "kill-switch - Global pause: if walteur-kit/PAUSED exists, block all gated tool use. exit 2 = block."
  printf '%s\n' "usage: bash kill-switch.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: see hook header - fix recipes: walteur-kit/REMEDIATION.md (## kill-switch)"
  exit 0 ;;
esac

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

main() {
  [ -f "$ROOT/walteur-kit/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }
  exit 0
}

selftest() {
  pass=0; fail=0
  echo "kill-switch selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }

  t="$(mktemp -d "${TMPDIR:-/tmp}/kill-switch.XXXXXX")" || { echo "kill-switch selftest: mktemp failed"; return 1; }
  mkdir -p "$t/walteur-kit"
  touch "$t/walteur-kit/PAUSED"
  ck "fixture PAUSED present -> exit 2" 2 "$(run "$t")"
  rm -f "$t/walteur-kit/PAUSED"
  ck "fixture PAUSED absent -> exit 0" 0 "$(run "$t")"
  rm -rf "$t"

  echo "kill-switch selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
```

---

## Patch 2 — `.claude/hooks/gate-guard.sh` — hard-coded LOOP.md path denylist + `--selftest`

Source of the denylist: `LOOP.md` lines 39-42 ("Path denylist (never auto-edit without a human gate)"):
`.env` / `.env.*` · `**/secrets/**` · `**/credentials/**` · `**/*_key*` / `**/*_secret*` · `.terraform/**` ·
`k8s/production/**` · `**/migrations/**` · `auth/**` · `payments/**` · `billing/**`.

Design: matches the TARGET path only (`tool_input.file_path`/`.path` from the PreToolUse payload), extracted
with `grep`/`sed` (no `jq` dependency, so it can't silently fail-open if `jq` is absent — satisfies "missing
deps must FAIL, not skip, for HARD gates"). Runs BEFORE the PLAN-before-build check so a denylist hit is
never masked by the generic "no PLAN.md" message. Fail-closed: unknown target path → no match → falls
through to the existing PLAN/boundaries logic (does not itself introduce a fail-open branch).

Apply instructions:
1. `WALTEUR_TDD=off` (or fix the bug above), then open `.claude/hooks/gate-guard.sh`.
2. Insert the block below immediately after this existing line (do not remove it):
   `[ "${WALTEUR_GATE:-on}" = "off" ] && exit 0`
   ...and BEFORE the existing `# ── PLAN-before-build (unchanged) ──` comment / `if [ ! -s "$ROOT/PLAN.md" ]`
   block.
3. In the existing "boundaries" section further down, change the line
   `payload="$(cat 2>/dev/null || true)"` to `# payload already read above by the denylist check` (delete
   the re-read — stdin can only be consumed once) and reuse the `$payload` variable already set.
4. Also insert the `denylist_selftest` cases into the existing `--selftest` dispatch (gate-guard.sh
   currently has no `--selftest` case at all — add the whole dispatch block at the end of the file, mirroring
   the house pattern used by `data-correctness-gate.sh` / `context-compaction-gate.sh`).
5. Run `bash .claude/hooks/gate-guard.sh --selftest` — expect all cases `ok`.

### 3a. Denylist check block (insert after the WALTEUR_GATE off check)

```bash
# ── path denylist (HARD, fail-closed; LOOP.md "Path denylist" section) ───────
# Never auto-edit these without a human gate. Match the WRITE/EDIT TARGET path only (not the whole
# command string), so reads/greps of a denylisted path are not false-flagged. No jq dependency — a missing
# jq must not fail this HARD check open.
payload="$(cat 2>/dev/null || true)"
target_path="$(printf '%s' "$payload" | grep -o '"\(file_path\|path\)"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/^"[a-z_]+"[[:space:]]*:[[:space:]]*"//; s/"$//')"
if [ -n "$target_path" ]; then
  rel="${target_path#"$ROOT"/}"
  denylist_match=""
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    pat="$(printf '%s' "$g" | sed -E 's#\*\*/#*#g; s#\*\*#*#g')"
    case "$rel" in
      $pat) denylist_match="$g"; break ;;
    esac
  done <<'DENYLIST_EOF'
.env
.env.*
**/secrets/**
**/credentials/**
**/*_key*
**/*_secret*
.terraform/**
k8s/production/**
**/migrations/**
auth/**
payments/**
billing/**
DENYLIST_EOF
  if [ -n "$denylist_match" ]; then
    echo "GATE: DENYLIST BLOCK — path denylist hit, human gate required." >&2
    echo "  target: '$rel' matched glob '$denylist_match' (LOOP.md Path denylist)" >&2
    echo "  escalation: needs Tony — LOOP.md human gate. (this is a HARD block, no bypass flag)" >&2
    exit 2
  fi
fi
```

### 3b. Reuse the payload in the existing boundaries section

Find (further down, in the `# ── boundaries (WARNING-FIRST; additive) ──` block):

```bash
if [ "${WALTEUR_BOUNDARIES:-warn}" != "off" ] && command -v jq >/dev/null 2>&1; then
  payload="$(cat 2>/dev/null || true)"
  path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)"
```

Replace the `payload="$(cat 2>/dev/null || true)"` line with nothing (delete it) — `$payload` is already
populated by the denylist block above and stdin must only be read once.

### 3c. `--selftest` dispatch (gate-guard.sh has none today — add at the very end of the file, replacing
the current final `exit 0`)

```bash
selftest() {
  pass=0; fail=0
  echo "gate-guard selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }

  # denylist: denied path -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/gate-guard.XXXXXX")" || { echo "gate-guard selftest: mktemp failed"; return 1; }
  mkdir -p "$t/walteur-kit"; printf 'PLAN\n' > "$t/PLAN.md"
  rc="$(cd "$t" && echo '{"tool_input":{"file_path":"secrets/prod.env"}}' | WALTEUR_ROOT="$t" bash "$OLDPWD_SELF" >/dev/null 2>&1; echo $?)"
  ck "denylist secrets/prod.env -> exit 2" 2 "$rc"
  rc="$(cd "$t" && echo '{"tool_input":{"file_path":"payments/charge.ts"}}' | WALTEUR_ROOT="$t" bash "$OLDPWD_SELF" >/dev/null 2>&1; echo $?)"
  ck "denylist payments/charge.ts -> exit 2" 2 "$rc"
  # benign path -> falls through to PLAN check (PLAN.md exists) -> exit 0
  rc="$(cd "$t" && echo '{"tool_input":{"file_path":"src/app.ts"}}' | WALTEUR_ROOT="$t" bash "$OLDPWD_SELF" >/dev/null 2>&1; echo $?)"
  ck "benign src/app.ts -> exit 0" 0 "$rc"
  rm -rf "$t"

  echo "gate-guard selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) : ;;  # (default run already executed top-to-bottom above; this case exists only for the dispatch)
esac
```

NOTE: gate-guard.sh's existing body is NOT wrapped in a `main()` function (unlike kill-switch.sh /
data-correctness-gate.sh) — it runs top-to-bottom unconditionally today, ending in `exit 0`. To add
`--selftest` cleanly without changing default-run behavior, wrap the existing top-to-bottom body (from
`set -uo pipefail` down to the final `exit 0`) in a `main() { ... }` function first, then dispatch
`case "${1:-}" in --selftest) selftest; exit $? ;; *) main "$@" ;; esac` at the end — mirroring the
`data-correctness-gate.sh` pattern exactly (see that file for the `$SELF` self-path-resolution boilerplate
this snippet assumes, referenced above as `$OLDPWD_SELF`/`$SELF`).

---

## Status

- Not applied to `.claude/hooks/kill-switch.sh` or `.claude/hooks/gate-guard.sh` — both are `.claude/hooks/*`
  paths and Edit was DENIED by `tdd-guard.sh`'s false-fail (see root cause above). Recorded per binding
  constraint #6; no bash-redirection workaround was used.
- `walteur-kit/hooks/kill-switch.sh` and `walteur-kit/hooks/gate-guard.sh` ("canonical" locations per the
  task brief) do **not exist in this repo** — only the `.claude/hooks/` copies exist (verified via
  `find . -iname "gate-guard.sh" -o -iname "kill-switch.sh"`, 2 hits, both under `.claude/hooks/`). The
  patches above target the `.claude/hooks/` copies since those are the only real files and the ones actually
  wired in `.claude/settings.json`.
