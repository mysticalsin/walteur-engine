#!/usr/bin/env bash
# WALTEUR .claude/hooks delegation preamble — SOURCED by the thin shims in this directory.
#
# WHY THIS EXISTS
# ---------------
# Every gate has exactly ONE real implementation, at <repo>/walteur-kit/hooks/<name>.sh.
# The .claude/hooks/ directory used to carry FORKED COPIES of 13 of them. Nothing invoked
# those copies — .claude/settings.json wires only gate-guard.sh, kill-switch.sh, ship-gate.sh
# and tdd-guard.sh, and .claude/hooks/ship-gate.sh resolves every gate it runs as
# "$KIT/hooks/$name" (always the walteur-kit copy) — so the forks were unreachable AND
# unguarded: walteur-kit/eval/twin-invariant.sh only cmps .claude/hooks/X across two
# DISTRIBUTIONS (A vs B), never .claude/hooks/X against walteur-kit/hooks/X in the SAME tree.
# The result was silent drift. tool-liveness-probe.sh drifted worst: the .claude copy was the
# pre-fix version that parsed .tools[] as if every entry were a string, exploding each object's
# keys/values into junk tool names and failing closed — the exact bug walteur-kit's copy
# documents having fixed.
#
# The fix is structural, not vigilance: a shim cannot drift from what it delegates to. Each
# .claude/hooks/<name>.sh is now three lines that source this file, which resolves and execs
# the canonical with ALL arguments forwarded verbatim (--help, --selftest, everything). The
# help text, the report path and the selftest all come from the single real implementation.
#
# CONTRACT
#   - Delegates to  $REPO/walteur-kit/hooks/<basename of the sourcing shim>
#   - $REPO is WALTEUR_ROOT when set and a directory, else the shim's own repo root
#     (.claude/hooks -> ../..). WALTEUR_ROOT lets the selftest drive hermetic fixtures.
#   - FAIL-CLOSED: canonical absent => exit 2 with a loud stderr line. NEVER a silent pass.
#   - Windows-Git-Bash-safe $0 drive arm, same as .claude/hooks/gate-suite.sh.
#
# SELFTEST: this file is sourced, not run, so `bash _delegate.sh --selftest` runs the
# delegation selftest instead of delegating: a POSITIVE control (canonical present, exit 0,
# args forwarded), NEGATIVE CONTROL A (canonical absent => exit 2 + fail-closed stderr),
# NEGATIVE CONTROL B (canonical exits 2 => shim propagates 2, does not swallow it), and a
# POISON CHECK that neuters the fail-closed branch and asserts NEGATIVE A stops firing —
# proving the assertion observes the real branch rather than a fixture that always exits 2.

set -uo pipefail

_walteur_delegate_resolve() {
  # $1 = the sourcing shim's $0
  case "$1" in
    /*|?:[\\/]*) _WD_SELF="$1" ;;
    *) if command -v realpath >/dev/null 2>&1; then _WD_SELF="$(realpath "$1" 2>/dev/null || printf '%s' "$1")"
       else _WD_SELF="$(cd "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1")"; fi ;;
  esac
  _WD_NAME="$(basename "$_WD_SELF")"
  _WD_HERE="$(cd "$(dirname "$_WD_SELF")" 2>/dev/null && pwd)"   # <repo>/.claude/hooks
  if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "${WALTEUR_ROOT:-}" ]; then
    _WD_REPO="$(cd "$WALTEUR_ROOT" 2>/dev/null && pwd)"
  else
    _WD_REPO="$(cd "$_WD_HERE/../.." 2>/dev/null && pwd)"
  fi
  _WD_CANON="$_WD_REPO/walteur-kit/hooks/$_WD_NAME"
}

_walteur_delegate_exec() {
  _walteur_delegate_resolve "$_WD_ARG0"
  if [ ! -f "$_WD_CANON" ]; then
    echo "$_WD_NAME shim: FAIL — canonical implementation not found at $_WD_CANON (fail-closed, never a silent pass) -> exit 2" >&2
    exit 2
  fi
  exec bash "$_WD_CANON" "$@"
}

# ── selftest: only when this preamble is EXECUTED directly, never when sourced ────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    -h|--help)
      printf '%s\n' "_delegate.sh - shared delegation preamble sourced by the .claude/hooks thin shims."
      printf '%s\n' "usage: bash _delegate.sh [--selftest|--help]   (sourced by shims; not a gate itself)"
      printf '%s\n' "report: none - it execs walteur-kit/hooks/<shim basename> with all args forwarded"
      exit 0 ;;
  esac

  _wd_selftest() {
    pass=0; fail=0
    ck() {
      if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1))
      else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi
    }
    for t in mktemp mkdir rm sed grep basename dirname; do
      command -v "$t" >/dev/null 2>&1 || { echo "_delegate selftest SKIP - required tool '$t' not installed."; return 0; }
    done

    echo "_delegate selftest:"
    _me="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/wddel.XXXXXX")" || return 1

    # Build a fake repo: <root>/.claude/hooks/{_delegate.sh,demo-gate.sh} + <root>/walteur-kit/hooks/demo-gate.sh
    mkfixture() { # $1=root  $2=canonical body ("" => do not create the canonical)  $3=delegate file to install
      mkdir -p "$1/.claude/hooks" "$1/walteur-kit/hooks"
      cp "$3" "$1/.claude/hooks/_delegate.sh"
      printf '#!/usr/bin/env bash\n_WD_ARG0="$0"\n. "$(dirname "$0")/_delegate.sh"\n_walteur_delegate_exec "$@"\n' > "$1/.claude/hooks/demo-gate.sh"
      chmod +x "$1/.claude/hooks/demo-gate.sh"
      if [ -n "$2" ]; then printf '%s' "$2" > "$1/walteur-kit/hooks/demo-gate.sh"; chmod +x "$1/walteur-kit/hooks/demo-gate.sh"; fi
    }

    # (1) POSITIVE — canonical present, exits 0, echoes a marker => delegated, args forwarded.
    d1="$tmp/positive"
    mkfixture "$d1" '#!/usr/bin/env bash
echo "MARKER-$1"
exit 0
' "$_me"
    out1="$(WALTEUR_ROOT="$d1" bash "$d1/.claude/hooks/demo-gate.sh" hello 2>&1)"; rc1=$?
    ck "POSITIVE: canonical present -> exit 0" 0 "$rc1"
    case "$out1" in
      *MARKER-hello*) echo "  ok   - POSITIVE: args forwarded verbatim (marker seen)"; pass=$((pass+1)) ;;
      *) echo "  FAIL - POSITIVE: args NOT forwarded (got: $out1)"; fail=$((fail+1)) ;;
    esac

    # (2) NEGATIVE CONTROL A — canonical absent => exit 2 + fail-closed stderr line.
    d2="$tmp/negativeA"
    mkfixture "$d2" "" "$_me"
    out2="$(WALTEUR_ROOT="$d2" bash "$d2/.claude/hooks/demo-gate.sh" 2>&1)"; rc2=$?
    ck "NEGATIVE A: canonical absent -> exit 2 (fail-closed)" 2 "$rc2"
    case "$out2" in
      *fail-closed*) echo "  ok   - NEGATIVE A: fail-closed stderr line present"; pass=$((pass+1)) ;;
      *) echo "  FAIL - NEGATIVE A: fail-closed stderr line MISSING (got: $out2)"; fail=$((fail+1)) ;;
    esac

    # (3) NEGATIVE CONTROL B — canonical exits 2 => shim must PROPAGATE 2, not swallow it.
    d3="$tmp/negativeB"
    mkfixture "$d3" '#!/usr/bin/env bash
echo "canonical failing on purpose" >&2
exit 2
' "$_me"
    WALTEUR_ROOT="$d3" bash "$d3/.claude/hooks/demo-gate.sh" >/dev/null 2>&1; rc3=$?
    ck "NEGATIVE B: canonical exits 2 -> shim propagates 2 (not swallowed)" 2 "$rc3"

    # (4) POISON CHECK — neuter the fail-closed branch; NEGATIVE A must stop firing. Proves the
    #     assertion observes the real branch, not a fixture that would exit 2 regardless.
    poisoned="$tmp/poisoned-delegate.sh"
    sed 's/^    exit 2$/    exit 0/' "$_me" > "$poisoned" 2>/dev/null || cp "$_me" "$poisoned"
    d4="$tmp/negativeA-poison"
    mkfixture "$d4" "" "$poisoned"
    WALTEUR_ROOT="$d4" bash "$d4/.claude/hooks/demo-gate.sh" >/dev/null 2>&1; rc4=$?
    ck "POISON CHECK: fail-closed neutered -> NEGATIVE A no longer exits 2 (assertion is a real observer)" 0 "$rc4"

    rm -rf "$tmp"
    echo "_delegate selftest: $pass/$((pass+fail)) passed"
    [ "$fail" -eq 0 ]
  }

  case "${1:-}" in
    --selftest) _wd_selftest; exit $? ;;
    *) echo "_delegate.sh is a sourced preamble, not a gate. Run: bash _delegate.sh --selftest | --help" >&2; exit 2 ;;
  esac
fi
