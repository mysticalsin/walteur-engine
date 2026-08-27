#!/usr/bin/env bash
# Global pause: if walteur-kit/PAUSED exists, block all gated tool use. exit 2 = block.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "kill-switch - Global pause: if walteur-kit/PAUSED exists, block all gated tool use. exit 2 = block."
  printf '%s\n' "usage: bash kill-switch.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: none (exit code IS the verdict: 0 = allow, 2 = blocked) - fix recipes: walteur-kit/REMEDIATION.md (## kill-switch)"
  exit 0 ;;
esac

set -uo pipefail

# --selftest was advertised above but no case arm handled it, so the flag fell through to the
# PAUSED check and this hook — the harness's GLOBAL EMERGENCY STOP, wired as a PreToolUse hook in
# .claude/settings.json — exited 0. An operator verifying the kill switch got a green that proved
# nothing, and nothing anywhere exercised either branch of it.
#
# This selftest drives the REAL resolution path (git rev-parse --show-toplevel, run from the
# fixture's cwd) rather than a re-implementation, so it fails if that resolution breaks. It asserts
# BOTH directions plus the non-git fallback, and a POISON CHECK neuters the blocking branch to prove
# the block assertion observes real behaviour rather than a fixture that would exit 2 regardless.
if [ "${1:-}" = "--selftest" ]; then
  pass=0; fail=0
  ck() {
    if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1))
    else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi
  }
  for t in git mktemp mkdir rm sed touch; do
    command -v "$t" >/dev/null 2>&1 || { echo "kill-switch selftest SKIP - required tool '$t' not installed."; exit 0; }
  done

  echo "kill-switch selftest:"
  case "$0" in
    /*) SELF="$0" ;;
    *)  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" ;;
  esac
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/killswitch.XXXXXX")" || exit 1

  # (1) git repo, NO PAUSED => allow (exit 0).
  g="$tmp/repo"; mkdir -p "$g/walteur-kit"
  ( cd "$g" && git init -q . >/dev/null 2>&1 )
  ( cd "$g" && bash "$SELF" >/dev/null 2>&1 ); ck "git repo without PAUSED -> allow" 0 "$?"

  # (2) git repo, PAUSED present => block (exit 2) and say so on stderr.
  touch "$g/walteur-kit/PAUSED"
  out="$( cd "$g" && bash "$SELF" 2>&1 >/dev/null )"; rc=$?
  ck "git repo with walteur-kit/PAUSED -> BLOCK" 2 "$rc"
  case "$out" in
    *PAUSED*) echo "  ok   - block names walteur-kit/PAUSED and how to resume"; pass=$((pass+1)) ;;
    *) echo "  FAIL - block message missing/unclear (got: $out)"; fail=$((fail+1)) ;;
  esac

  # (3) PAUSED is resolved from the REPO ROOT, not the cwd: from a subdirectory of the same repo the
  #     block must still fire (this is what git rev-parse --show-toplevel buys us).
  mkdir -p "$g/deep/nested"
  ( cd "$g/deep/nested" && bash "$SELF" >/dev/null 2>&1 ); ck "PAUSED honoured from a nested subdir (repo-root resolution)" 2 "$?"

  # (4) non-git directory: falls back to '.', so ./walteur-kit/PAUSED still blocks.
  n="$tmp/nogit"; mkdir -p "$n/walteur-kit"; touch "$n/walteur-kit/PAUSED"
  ( cd "$n" && bash "$SELF" >/dev/null 2>&1 ); ck "non-git dir with ./walteur-kit/PAUSED -> BLOCK (fallback path)" 2 "$?"

  # (5) POISON CHECK: neuter the blocking exit; case (2) must stop blocking. Proves the assertions
  #     above observe the real branch instead of a fixture that exits 2 on its own.
  poisoned="$tmp/poisoned-kill-switch.sh"
  sed 's/exit 2; }/exit 0; }/' "$SELF" > "$poisoned" 2>/dev/null || cp "$SELF" "$poisoned"
  ( cd "$g" && bash "$poisoned" >/dev/null 2>&1 ); ck "POISON CHECK: blocking branch neutered -> no longer blocks (assertions are real observers)" 0 "$?"

  rm -rf "$tmp"
  echo "kill-switch selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]; exit $?
fi

[ -f "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/walteur-kit/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }
exit 0
