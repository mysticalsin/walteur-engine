#!/usr/bin/env bash
# WALTEUR _probe-proof.sh — shared guard sourced by execute-probe gates (authz/privacy/sdlc/audit/cutover).
#
# Closes the "constant-exit / no-op probe" CLASS the independent panel proved was bypassable by per-gate
# regex enumeration (bash -lc 'exit 0', bash -c 'exit 0;', bash -c 'exit 0 #c', node -e 'process.exit(0)',
# python -c 'pass', true/false/:, compound 'true; true'/':;:'). Enumerating evasions is undecidable
# whack-a-mole. Instead this requires a probe to TOUCH SOMETHING REAL: it either invokes a recognized test
# runner, or at least one of its tokens resolves to a file/dir that exists on disk. A no-op constant touches
# nothing real => rejected, regardless of how the shell flags are arranged. Arbitrary real-but-vacuous
# commands remain the negative-control discipline's backstop (documented; the halting case is undecidable).
#
# Usage:  source "$(dirname "$SELF")/_probe-proof.sh"
#         if ! probe_proves_something "$cmd"; then <FAIL>; fi
# Honors optional $ROOT for repo-relative path resolution.

probe_proves_something() {
  local cmd="$1" tok stripped _restore_glob
  # empty / whitespace-only proves nothing
  [ -z "${cmd//[[:space:]]/}" ] && return 1

  # 1) recognized real test-runner invocations (these legitimately name no file)
  if printf '%s' "$cmd" | grep -Eiq '(^|[[:space:];&|(])(npm|pnpm|yarn)[[:space:]]+(run[[:space:]]+)?[a-z:_-]*test|(^|[[:space:];&|(])(pytest|jest|vitest|mocha|phpunit|rspec|ctest|tox|nox|behave|cucumber|playwright|cypress|ava)([[:space:]]|$)|(^|[[:space:];&|(])(go|cargo|mvn|dotnet|swift|deno|bun)[[:space:]]+test|(^|[[:space:];&|(])node[[:space:]]+(--)?(experimental-)?test|(^|[[:space:];&|(])gradl(e|ew)[[:space:]]|(^|[[:space:];&|(])(make|just)[[:space:]]+[a-z:_-]*test'; then
    return 0
  fi

  # 2) at least one token must resolve to an existing file/dir (a real test/script/artifact)
  case $- in *f*) _restore_glob=0 ;; *) _restore_glob=1 ;; esac
  set -f
  for tok in $cmd; do
    stripped="$tok"
    stripped="${stripped#[\"\']}"; stripped="${stripped%[\"\']}"
    case "$stripped" in
      ''|-*|true|false|:|exit|[0-9]*|'&&'|'||'|';'|'|'|'{'|'}') continue ;;
    esac
    # a bare interpreter/shell/wrapper binary is not a "real test" even though it exists on disk
    case "${stripped##*/}" in
      bash|sh|zsh|dash|ksh|node|nodejs|python|python2|python3|perl|ruby|php|env|sudo|command|exec|time|nice|deno|bun) continue ;;
    esac
    if [ -e "$stripped" ] || { [ -n "${ROOT:-}" ] && [ -e "$ROOT/$stripped" ]; }; then
      [ "$_restore_glob" = 1 ] && set +f
      return 0
    fi
  done
  [ "$_restore_glob" = 1 ] && set +f
  return 1
}
