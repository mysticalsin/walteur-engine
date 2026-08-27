#!/usr/bin/env bash
# WALTEUR ast-grep opt-in preamble — sourced by resilience-lint.sh AND anti-slop-ui.sh.
# CONTRACT it must preserve in BOTH hosts:
#   - host FAIL  == exit 2
#   - host PASS  == exit 0
#   - host SKIP  == exit 0 + a LOUD stderr line (never silent-green)
#
# This preamble runs ast-grep as the AUTHORITATIVE pass IFF ast-grep is on PATH. The rule set is
# MIXED-SEVERITY (5 error + 4 warning, e.g. v9.2 R6/R8 return-in-catch-{js,py} + floating-catch-js +
# banned-api/todo), so ast-grep's exit code only reflects the ERROR rules:
#   - ast-grep finds >=1 ERROR-severity match    -> ast-grep exits 1  -> we exit 2 (host FAIL contract)
#   - only WARNING-severity matches (or none)    -> ast-grep exits 0  -> we exit 0 (host PASS contract).
#       A warning match is a REAL finding but does NOT set exit 1 — it is surfaced (printed above) and is
#       then re-caught by the host's grep/awk floor (or an explicit host warning pass). The AST pass does
#       not block on warnings by design (WARNING-FIRST).
#   - ast-grep ABSENT                            -> print LOUD SKIP, RETURN 100 (sentinel) so the caller
#                                                   falls through to its existing grep/awk floor.
# NOTE: ast-grep scan exits 1 (NOT 2) on an error finding — verified at
#   https://ast-grep.github.io/reference/cli/scan.html  ("Status code 1 if at least one rule matches
#   if severity setted to error"). We deliberately remap 1 -> 2 to honor the WALTEUR exit contract.
#
# Usage inside a host hook (place AFTER the PAUSED/bypass checks, BEFORE the grep work):
#   . "$(dirname "$0")/_ast-grep-preamble.sh"
#   walteur_astgrep_pass "$ROOT/walteur-kit/sgconfig.yml" "$SCAN_PATH" "<gate-name>"
#   rc=$?
#   if [ "$rc" -ne 100 ]; then exit "$rc"; fi      # 0 or 2 => authoritative; 100 => fall through to grep floor
#   # ... existing zero-dep grep/awk path runs only when ast-grep was absent ...

walteur_astgrep_pass() {  # $1=sgconfig path  $2=scan target dir/file  $3=gate label
  local cfg="$1" target="$2" gate="$3"

  if ! command -v ast-grep >/dev/null 2>&1; then
    echo "WALTEUR $gate: ast-grep NOT installed — LOUD SKIP of the AST backend; falling back to the zero-dep grep/awk floor (NOT silent-green). install: brew install ast-grep" >&2
    return 100   # sentinel: caller must run its grep floor
  fi
  if [ ! -f "$cfg" ]; then
    echo "WALTEUR $gate: ast-grep present but $cfg missing — LOUD SKIP of the AST backend; falling back to grep/awk floor." >&2
    return 100
  fi

  echo "WALTEUR $gate: ast-grep AUTHORITATIVE pass (-c $cfg) over $target" >&2
  # MIXED severity: ONLY an error-severity match sets exit 1. A warning-severity match prints above but
  # leaves exit 0 — it is recovered by the host grep/awk floor (WARNING-FIRST, never silent-green).
  ast-grep scan -c "$cfg" "$target" >&2
  local ag=$?
  case "$ag" in
    0) echo "WALTEUR $gate: ast-grep — no error-severity AST findings (warnings, if any, handled by the host floor)." >&2; return 0 ;;
    1) echo "WALTEUR $gate: ast-grep FAIL — AST finding(s) above. (ast-grep exit 1 -> host exit 2)" >&2; return 2 ;;
    *) # any OTHER ast-grep exit (e.g. config parse error) is NOT a clean pass — do not silent-green.
       echo "WALTEUR $gate: ast-grep errored (exit $ag) — treating as LOUD SKIP, falling back to grep/awk floor." >&2
       return 100 ;;
  esac
}
