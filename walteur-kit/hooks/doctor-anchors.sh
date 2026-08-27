#!/usr/bin/env bash
# WALTEUR doctor-anchors.sh — the fix-pointer LINK CHECKER. Closes the last hop of the
# "failures explain themselves" chain.
#
# WHY THIS EXISTS
#   Every hook's --help ends with `fix recipes: walteur-kit/REMEDIATION.md (## <id>)`, and doctor.sh
#   prints `fix -> walteur-kit/REMEDIATION.md#<id>` for every failing gate. Nothing proved those
#   anchors RESOLVE. Measured on 2026-07-25 before this gate existed: 10 of 155 --help pointers named a
#   section that does not exist (including the two most operator-facing hooks, doctor.sh -> '## doctor'
#   and ship-gate.sh -> '## ship-gate'), and 2 of 28 live triage pointers were dead. An operator
#   following the pointer lands on nothing, at exactly the moment they are already blocked. A fix
#   pointer that 404s is worse than no pointer: it spends the operator's trust and then their time.
#
# WHAT IT CHECKS (both are mechanical facts; no judgment anywhere)
#   C1  --help POINTER RESOLUTION — for every hook under walteur-kit/hooks/*.sh that has a -h|--help
#       arm, run `--help`, extract the `REMEDIATION.md (## X)` pointer, and require a literal
#       `## X` heading in walteur-kit/REMEDIATION.md.
#   C2  TRIAGE POINTER RESOLUTION — ask doctor.sh itself (`--dry-run`, which writes nothing) for the
#       anchors it would print for the CURRENT set of FAIL reports, and require each to resolve.
#       Delegating to doctor means this check can never drift from doctor's real resolution rules
#       (<id>, <id>-gate, <id>-lint, <id>-check, then the explicit REMEDIATION_ALIASES list).
#
# HONESTY BOUNDARIES (load-bearing — do not erode)
#   * C1 EXECUTES `--help`, it does not read the source, so what is checked is what the operator
#     actually sees. Hooks with NO --help arm are counted as `no_help_arm` and reported — they are
#     NOT counted as passing, and they are NOT 404s either; that gap belongs to
#     remediation-coverage-gate (check C2 there). Invoking `--help` on a hook with no help arm could
#     run the gate for real, so those hooks are deliberately never executed here.
#   * A PASS means "every pointer we could extract resolves to a live heading". It says nothing about
#     whether the section's CONTENT is any good — that is a human read, never a gate verdict.
#   * Underscore-prefixed files (_probe-proof.sh, _ast-grep-preamble.sh) are sourced libraries, never
#     invoked standalone, and are skipped.
#   * Do NOT add an exclude to silence a dead pointer. An excluded pointer is still dead for the
#     operator standing in front of it. Write the section instead.
#
# CONTRACT
#   walteur-kit/PAUSED present                => exit 2 (paused is not green).
#   WALTEUR_DOCTOR_ANCHORS=off                => recorded LOUD SKIP, exit 0.
#   REMEDIATION.md absent OR hooks/ absent    => NOT_APPLICABLE, exit 0 (kit not scaffolded yet).
#   any dead pointer (C1 or C2)               => FAIL, exit 2. HARD, fail-closed.
#   all pointers resolve                      => PASS, exit 0.
# Report: walteur-kit/doctor-anchors-report.json {verdict, ts, gate, reason, pointers_checked,
#         dead_help[], dead_triage[], no_help_arm[], hooks_scanned}
# Selftest: bash walteur-kit/hooks/doctor-anchors.sh --selftest — hermetic temp trees, INCLUDING a
#           negative control that seeds a dead pointer and asserts this checker FAILs on it. A checker
#           that cannot fail is theater.
# Zero-dep floor: bash + grep + sed. jq used for the report WHEN PRESENT (printf fallback).
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "doctor-anchors - fix-pointer link checker: every REMEDIATION.md anchor must resolve."
  printf '%s\n' "usage: bash doctor-anchors.sh [--selftest|--help|<default run>]"
  printf '%s\n' "  (no arg)    resolve every hook --help pointer + every live doctor triage pointer"
  printf '%s\n' "exit: 0 all resolve (or NOT_APPLICABLE) - 2 a dead pointer, or PAUSED"
  printf '%s\n' "report: walteur-kit/doctor-anchors-report.json - fix recipes: walteur-kit/REMEDIATION.md (## doctor-anchors)"
  printf '%s\n' "bypass: WALTEUR_DOCTOR_ANCHORS=off (recorded, not free)"
  exit 0 ;;
  --selftest|'') : ;;
  *)
  printf '%s\n' "doctor-anchors: unknown option: ${1}" >&2
  printf '%s\n' "doctor-anchors: valid options are --selftest | --help | no argument." >&2
  exit 64 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) SELF="$(pwd)/$0" ;;
esac
SELF_PATH="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")"

have() { command -v "$1" >/dev/null 2>&1; }

# ── core check (a function so --selftest can drive it against fixture trees) ──
run_check() {
  ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  ROOT="$(cd "$ROOT" 2>/dev/null && pwd || printf '%s' "$ROOT")"
  KIT="$ROOT/walteur-kit"
  HOOKS_DIR="$KIT/hooks"
  REMEDIATION="$KIT/REMEDIATION.md"
  REPORT="$KIT/doctor-anchors-report.json"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  write_report() {
    _v="$1"; _r="$2"
    [ -d "$KIT" ] || return 0
    if have jq; then
      jq -n --arg v "$_v" --arg ts "$TS" --arg r "$_r" \
            --argjson checked "${pointers_checked:-0}" \
            --argjson scanned "${hooks_scanned:-0}" \
            --arg dh "${dead_help:-}" --arg dt "${dead_triage:-}" --arg nh "${no_help_arm:-}" \
        '{verdict:$v, ts:$ts, gate:"doctor-anchors", reason:$r,
          pointers_checked:$checked, hooks_scanned:$scanned,
          dead_help:      ($dh|split("\n")|map(select(length>0))),
          dead_triage:    ($dt|split("\n")|map(select(length>0))),
          no_help_arm:    ($nh|split("\n")|map(select(length>0)))}' > "$REPORT" 2>/dev/null && return 0
    fi
    printf '{"verdict":"%s","ts":"%s","gate":"doctor-anchors","reason":"%s","pointers_checked":%s}\n' \
      "$_v" "$TS" "$_r" "${pointers_checked:-0}" > "$REPORT"
  }

  [ -f "$KIT/PAUSED" ] && {
    echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; return 2; }
  [ "${WALTEUR_DOCTOR_ANCHORS:-on}" = "off" ] && {
    pointers_checked=0; hooks_scanned=0; dead_help=""; dead_triage=""; no_help_arm=""
    write_report "SKIP" "WALTEUR_DOCTOR_ANCHORS=off"
    echo "doctor-anchors: bypassed (WALTEUR_DOCTOR_ANCHORS=off) — recorded, not free." >&2; return 0; }

  if [ ! -f "$REMEDIATION" ] || [ ! -d "$HOOKS_DIR" ]; then
    pointers_checked=0; hooks_scanned=0; dead_help=""; dead_triage=""; no_help_arm=""
    echo "doctor-anchors: NOT_APPLICABLE — REMEDIATION.md or hooks/ absent under $KIT (kit not scaffolded)." >&2
    write_report "NOT_APPLICABLE" "REMEDIATION.md or hooks/ absent"
    return 0
  fi

  # Live '## ' headings, exactly as doctor.sh reads them.
  HEADINGS="$(grep -E '^## ' "$REMEDIATION" 2>/dev/null | sed 's/^## //')"
  heading_live() { printf '%s\n' "$HEADINGS" | grep -Fxq "$1"; }

  pointers_checked=0; hooks_scanned=0
  dead_help=""; dead_triage=""; no_help_arm=""

  # ── C1: every hook --help pointer ──────────────────────────────────────────
  for f in "$HOOKS_DIR"/*.sh; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in _*) continue ;; esac       # sourced libraries, never invoked standalone
    hooks_scanned=$((hooks_scanned+1))
    # Only EXECUTE --help on hooks that actually declare a help arm: invoking --help on a hook that
    # has none would fall through and run the gate for real.
    # Both dispatch shapes count as a real help arm: a `case` pattern (`-h|--help)` / `--help|-h)`)
    # and an `if/elif [ "${1:-}" = "--help" ]` test. A hook matching neither is never executed.
    if ! grep -qE '(-h\|--help|--help\|-h)\)|=[[:space:]]*"?--help"?' "$f"; then
      no_help_arm="${no_help_arm}${base}
"
      continue
    fi
    helpout="$(bash "$f" --help 2>/dev/null)"
    ptr="$(printf '%s\n' "$helpout" | sed -n 's/.*REMEDIATION\.md (## \([A-Za-z0-9._-]*\)).*/\1/p' | head -1)"
    [ -n "$ptr" ] || continue                  # no pointer advertised: nothing to resolve
    pointers_checked=$((pointers_checked+1))
    heading_live "$ptr" || dead_help="${dead_help}${base} -> ## ${ptr}
"
  done

  # ── C2: every live triage pointer doctor would print ───────────────────────
  # Delegate to doctor.sh --dry-run (writes nothing) so the resolution rules stay single-sourced.
  if [ -f "$HOOKS_DIR/doctor.sh" ] && have jq; then
    dr="$(WALTEUR_ROOT="$ROOT" bash "$HOOKS_DIR/doctor.sh" --dry-run 2>/dev/null)"
    if printf '%s' "$dr" | jq -e . >/dev/null 2>&1; then
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        pointers_checked=$((pointers_checked+1))
        heading_live "$a" || dead_triage="${dead_triage}doctor triage -> ## ${a}
"
      done <<EOF
$(printf '%s' "$dr" | jq -r '(.triage // [])[].remediation' 2>/dev/null | sed 's/.*#//')
EOF
    else
      echo "doctor-anchors: warn — doctor.sh --dry-run produced no parseable report; C2 not measured (cannot_measure, not a pass)." >&2
    fi
  fi

  dead_n=0
  [ -n "$dead_help" ]   && dead_n=$((dead_n + $(printf '%s' "$dead_help"   | grep -c .)))
  [ -n "$dead_triage" ] && dead_n=$((dead_n + $(printf '%s' "$dead_triage" | grep -c .)))

  echo "doctor-anchors: $pointers_checked pointer(s) checked across $hooks_scanned hook(s)."
  if [ -n "$no_help_arm" ]; then
    printf '  note - %s hook(s) have no --help arm (no pointer to resolve; see remediation-coverage-gate C2):\n' \
      "$(printf '%s' "$no_help_arm" | grep -c .)"
    printf '%s' "$no_help_arm" | sed 's/^/         /'
  fi
  if [ "$dead_n" -gt 0 ]; then
    echo "  FAIL - $dead_n DEAD fix-pointer(s) — the named REMEDIATION.md section does not exist:"
    [ -n "$dead_help" ]   && printf '%s' "$dead_help"   | sed 's/^/         DEAD --help pointer:  /'
    [ -n "$dead_triage" ] && printf '%s' "$dead_triage" | sed 's/^/         DEAD triage anchor:   /'
    echo "  Fix: WRITE the missing section in walteur-kit/REMEDIATION.md (Enforces / Common failure / Fix / Bypass)."
    echo "       Do not delete the pointer and do not add an exclude — see REMEDIATION.md (## doctor-anchors)."
    write_report "FAIL" "$dead_n dead fix-pointer(s)"
    return 2
  fi
  echo "  ok   - every fix-pointer resolves to a live '## ' heading in REMEDIATION.md."
  write_report "PASS" "all $pointers_checked pointer(s) resolve"
  return 0
}

# ── selftest ─────────────────────────────────────────────────────────────────
selftest() {
  pass=0; fail=0
  ck() {
    if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1))
    else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi
  }

  # Fixture hooks are ASSEMBLED at runtime, never written as literals — and this comment deliberately
  # does not spell one out either. If a complete pointer string appeared anywhere in this file, anyone
  # auditing pointer health with a plain `grep` over walteur-kit/hooks/*.sh would harvest this checker's
  # own test fixtures and report phantom dead pointers. The checker must not pollute what it measures.
  PTR_PREFIX='REMEDIATION.md ('       # split so no complete pointer literal exists in this source
  make_fixture_hook() {               # $1=path  $2=anchor-name
    { printf '#!/usr/bin/env bash\n'
      printf 'case "${1:-}" in\n'
      printf '  -h|--help) printf %s "report: x - fix recipes: walteur-kit/%s## %s)"; exit 0 ;;\n' \
             "'%s\\n'" "$PTR_PREFIX" "$2"
      printf 'esac\nexit 0\n'
    } > "$1"
  }

  # A fixture tree: REMEDIATION.md with two headings + hooks whose --help points at them.
  make_tree() {
    d="$1"
    mkdir -p "$d/walteur-kit/hooks"
    printf '## alpha-gate\nEnforces: demo.\n\n## beta\nEnforces: demo.\n' > "$d/walteur-kit/REMEDIATION.md"
    make_fixture_hook "$d/walteur-kit/hooks/alpha-gate.sh" "alpha-gate"
    make_fixture_hook "$d/walteur-kit/hooks/beta.sh" "beta"
    # a sourced library: must be skipped, never executed
    printf '#!/usr/bin/env bash\nexit 7\n' > "$d/walteur-kit/hooks/_lib.sh"
  }

  echo "doctor-anchors selftest:"

  # GOOD twin -> every pointer resolves -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/dactest.XXXXXX")" || return 1
  make_tree "$t"
  out="$(WALTEUR_ROOT="$t" bash "$SELF_PATH" 2>&1)"; rc=$?
  ck "all pointers resolve -> exit 0" 0 "$rc"
  printf '%s' "$out" | grep -q '2 pointer(s) checked'
  ck "counted both hook pointers (and skipped the _lib.sh library)" 0 "$?"
  [ -f "$t/walteur-kit/doctor-anchors-report.json" ]
  ck "wrote its report" 0 "$?"
  rm -rf "$t"

  # NEGATIVE CONTROL 1 -> seed a DEAD --help pointer -> MUST fail closed
  t="$(mktemp -d "${TMPDIR:-/tmp}/dactest.XXXXXX")" || return 1
  make_tree "$t"
  make_fixture_hook "$t/walteur-kit/hooks/gamma.sh" "gamma-does-not-exist"
  out="$(WALTEUR_ROOT="$t" bash "$SELF_PATH" 2>&1)"; rc=$?
  ck "NEGATIVE CONTROL: a dead --help pointer -> exit 2 (fail-closed)" 2 "$rc"
  printf '%s' "$out" | grep -q 'gamma.sh -> ## gamma-does-not-exist'
  ck "names the offending hook AND the missing section" 0 "$?"
  if have jq; then
    jq -e '.verdict=="FAIL" and (.dead_help|length)==1' "$t/walteur-kit/doctor-anchors-report.json" >/dev/null 2>&1
    ck "report records verdict FAIL with the dead pointer listed" 0 "$?"
  fi
  rm -rf "$t"

  # NEGATIVE CONTROL 2 -> a heading that only PREFIX-matches must not count as resolved
  t="$(mktemp -d "${TMPDIR:-/tmp}/dactest.XXXXXX")" || return 1
  make_tree "$t"
  make_fixture_hook "$t/walteur-kit/hooks/delta.sh" "bet"
  WALTEUR_ROOT="$t" bash "$SELF_PATH" >/dev/null 2>&1
  ck "NEGATIVE CONTROL: '## bet' must NOT resolve against '## beta' -> exit 2" 2 "$?"
  rm -rf "$t"

  # A hook with NO --help arm is reported, never executed, and is not a 404
  t="$(mktemp -d "${TMPDIR:-/tmp}/dactest.XXXXXX")" || return 1
  make_tree "$t"
  printf '#!/usr/bin/env bash\ntouch "%s/SIDE-EFFECT"\nexit 0\n' "$t" > "$t/walteur-kit/hooks/nohelp.sh"
  out="$(WALTEUR_ROOT="$t" bash "$SELF_PATH" 2>&1)"; rc=$?
  ck "hook with no --help arm does not fail the check" 0 "$rc"
  [ -f "$t/SIDE-EFFECT" ]
  ck "hook with no --help arm was NEVER executed (no side effect)" 1 "$?"
  printf '%s' "$out" | grep -q 'nohelp.sh'
  ck "hook with no --help arm is reported by name" 0 "$?"
  rm -rf "$t"

  # NOT_APPLICABLE: no REMEDIATION.md
  t="$(mktemp -d "${TMPDIR:-/tmp}/dactest.XXXXXX")" || return 1
  mkdir -p "$t/walteur-kit/hooks"
  WALTEUR_ROOT="$t" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no REMEDIATION.md -> NOT_APPLICABLE exit 0" 0 "$?"
  rm -rf "$t"

  # PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/dactest.XXXXXX")" || return 1
  make_tree "$t"; : > "$t/walteur-kit/PAUSED"
  WALTEUR_ROOT="$t" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> exit 2" 2 "$?"
  rm -rf "$t"

  # Bypass -> recorded SKIP exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/dactest.XXXXXX")" || return 1
  make_tree "$t"
  WALTEUR_DOCTOR_ANCHORS=off WALTEUR_ROOT="$t" bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass WALTEUR_DOCTOR_ANCHORS=off -> exit 0" 0 "$?"
  if have jq; then
    jq -e '.verdict=="SKIP"' "$t/walteur-kit/doctor-anchors-report.json" >/dev/null 2>&1
    ck "bypass is RECORDED in the report (never a silent green)" 0 "$?"
  fi
  rm -rf "$t"

  # Unknown flag -> exit 64, never a silent default run
  t="$(mktemp -d "${TMPDIR:-/tmp}/dactest.XXXXXX")" || return 1
  make_tree "$t"
  WALTEUR_ROOT="$t" bash "$SELF_PATH" --check-everything >/dev/null 2>&1
  ck "unknown flag -> exit 64 (EX_USAGE)" 64 "$?"
  rm -rf "$t"

  echo "doctor-anchors selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

run_check
exit $?
