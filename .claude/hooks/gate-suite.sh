#!/usr/bin/env bash
# WALTEUR gate-suite — THIN SHIM (single source of truth).
#
# The ONE real gate-suite implementation lives at  <repo>/walteur-kit/hooks/gate-suite.sh  and carries the
# run_twin_real live-HOOK-drift guard plus the cannot_measure skip-budget. This .claude copy used to be a
# stale ~114-line FORK that LACKED run_twin_real — two divergent gate-suite implementations coexisted, so a
# careless edit to one would not be caught by the other (a single-source-of-truth violation). It is now a
# thin delegating shim: there is exactly ONE implementation, and this copy can never silently diverge.
#
# It resolves the canonical relative to WALTEUR_ROOT if set, else this shim's own repo root (.claude/hooks
# -> ../.. -> walteur-kit/...), and execs it, forwarding ALL args (incl. --selftest). The two real-world
# callers — walteur-init.sh and doctor.sh — invoke this only as `gate-suite.sh --selftest` and match on the
# `gate-suite selftest: N/N passed` line + exit code; the canonical emits exactly that, so their behavior is
# preserved (and strengthened: the selftest now exercises the twin guard and skip-budget too).
#
# SHIM SELFTEST (S024 dock closed): `--selftest` first proves the fail-closed promise on ITSELF — a POSITIVE
# control (stub canonical present, exits 0 => shim must exec it, marker seen, exit 0, args forwarded), a
# NEGATIVE CONTROL A (no canonical at all => shim must exit 2, the fail-closed line on stderr) and a NEGATIVE
# CONTROL B (stub canonical exits 2 => shim must propagate 2, not swallow it). These run in hermetic mktemp
# fake repos via WALTEUR_ROOT so the real canonical is never touched. Prints "shim selftest: N/N passed".
# Only THEN does it forward to the real canonical's own --selftest (the 152-gate meta-harness), so the
# documented `gate-suite selftest: N/N passed` line callers key off is still emitted and still load-bearing —
# the shim selftest is additive coverage, not a replacement for exercising the canonical.
#
# Windows-Git-Bash-safe: $0 drive arm, set -uo pipefail. FAIL-CLOSED (exit 2) if the canonical is absent —
# never a silent pass.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "gate-suite - THIN SHIM (single source of truth)."
  printf '%s\n' "usage: bash gate-suite.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: see hook header - fix recipes: walteur-kit/REMEDIATION.md (## gate-suite)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac
HERE="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)"   # <repo>/.claude/hooks
# REPO resolution: WALTEUR_ROOT overrides (the shim-selftest hermetic-fixture hook and any caller that wants
# to point the shim at a different tree), else the shim's own on-disk repo root (.claude/hooks -> ../..).
if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "${WALTEUR_ROOT:-}" ]; then
  REPO="$(cd "$WALTEUR_ROOT" 2>/dev/null && pwd)"
else
  REPO="$(cd "$HERE/../.." 2>/dev/null && pwd)"        # <repo>
fi
CANON="$REPO/walteur-kit/hooks/gate-suite.sh"

resolve_and_exec() {
  if [ ! -f "$CANON" ]; then
    echo "gate-suite shim: FAIL — canonical implementation not found at $CANON (fail-closed, never a silent pass) -> exit 2" >&2
    return 2
  fi
  bash "$CANON" "$@"
}

# ── shim self-test: proves the fail-closed promise (lines above) on the shim binary itself, hermetically ──
shim_selftest() {
  local pass=0 fail=0 tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-suite-shim-selftest.XXXXXX")" || { echo "  FAIL - mktemp"; echo "shim selftest: 0/1 passed"; return 1; }
  trap 'rm -rf "$tmp"' RETURN

  ck() { # $1=label $2=want $3=got
    if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1))
    else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi
  }

  echo "gate-suite shim selftest:"

  # --- fixture layout matching the shim's own resolution contract: <root>/.claude/hooks (unused, the shim
  #     itself is driven via WALTEUR_ROOT + $SELF) + <root>/walteur-kit/hooks/gate-suite.sh (the canonical) ---

  # (1) POSITIVE — stub canonical present, exits 0 and echoes a marker => shim execs it, marker seen, args forwarded.
  local d1="$tmp/positive"
  mkdir -p "$d1/walteur-kit/hooks"
  printf '#!/usr/bin/env bash\necho "MARKER-$1"\nexit 0\n' > "$d1/walteur-kit/hooks/gate-suite.sh"
  chmod +x "$d1/walteur-kit/hooks/gate-suite.sh"
  local out1 rc1
  out1="$(WALTEUR_ROOT="$d1" bash "$SELF" hello 2>&1)"; rc1=$?
  ck "POSITIVE: stub canonical present -> exit 0" 0 "$rc1"
  if printf '%s' "$out1" | grep -q "MARKER-hello"; then echo "  ok   - POSITIVE: args forwarded verbatim (marker seen)"; pass=$((pass+1))
  else echo "  FAIL - POSITIVE: args forwarded verbatim (marker NOT seen: $out1)"; fail=$((fail+1)); fi

  # (2) NEGATIVE CONTROL A — no canonical at all => shim must fail-closed exit 2 with the documented stderr line.
  local d2="$tmp/negativeA"
  mkdir -p "$d2/walteur-kit/hooks" "$d2/.claude/hooks"
  local out2 rc2
  out2="$(WALTEUR_ROOT="$d2" bash "$SELF" --selftest-marker-noop 2>&1)"; rc2=$?
  ck "NEGATIVE A: canonical absent -> exit 2 (fail-closed)" 2 "$rc2"
  if printf '%s' "$out2" | grep -qi "fail-closed"; then echo "  ok   - NEGATIVE A: fail-closed stderr line present"; pass=$((pass+1))
  else echo "  FAIL - NEGATIVE A: fail-closed stderr line MISSING ($out2)"; fail=$((fail+1)); fi

  # (3) NEGATIVE CONTROL B — stub canonical exits 2 => shim must PROPAGATE 2 (exec/return not swallowed to 0).
  local d3="$tmp/negativeB"
  mkdir -p "$d3/walteur-kit/hooks"
  printf '#!/usr/bin/env bash\necho "stub failing on purpose"\nexit 2\n' > "$d3/walteur-kit/hooks/gate-suite.sh"
  chmod +x "$d3/walteur-kit/hooks/gate-suite.sh"
  local rc3
  WALTEUR_ROOT="$d3" bash "$SELF" >/dev/null 2>&1; rc3=$?
  ck "NEGATIVE B: stub canonical exits 2 -> shim propagates 2 (not swallowed)" 2 "$rc3"

  # (4) poison check on the poison itself: a shim copy with 'exit 0' spliced onto the missing-canonical branch
  #     must FAIL this same NEGATIVE A assertion when re-run against it — proves the test observes the real
  #     shim binary's fail-closed branch, not a fixture that always exits 2 on its own.
  local poisoned="$tmp/poisoned-shim.sh"
  sed 's/return 2$/return 0/' "$SELF" > "$poisoned" 2>/dev/null || cp "$SELF" "$poisoned"
  chmod +x "$poisoned"
  local d4="$tmp/negativeA-poison"
  mkdir -p "$d4/walteur-kit/hooks" "$d4/.claude/hooks"
  local rc4
  WALTEUR_ROOT="$d4" bash "$poisoned" >/dev/null 2>&1; rc4=$?
  ck "POISON CHECK: a shim with fail-closed neutered no longer exits 2 (proves NEGATIVE A is a real observer)" 0 "$rc4"

  echo "shim selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest)
    shim_rc=0
    shim_selftest || shim_rc=1
    echo ""
    # Forward to the REAL canonical's own --selftest too (documented contract: callers key off the
    # `gate-suite selftest: N/N passed` line the canonical emits). Combine: shim failure OR canonical
    # selftest failure => non-zero exit, never a silent green.
    resolve_and_exec --selftest
    canon_rc=$?
    if [ "$shim_rc" -ne 0 ] && [ "$canon_rc" -eq 0 ]; then exit 1; fi
    exit "$canon_rc"
    ;;
  *) resolve_and_exec "$@"; exit $? ;;
esac
