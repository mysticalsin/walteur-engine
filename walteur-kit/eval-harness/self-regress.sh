#!/usr/bin/env bash
# WALTEUR eval-harness self-regress — MEASURED self-regression over the poisoned/clean fixture twins.
#
# The de-circularized fixtures (walteur-kit/eval-harness/fixtures/*, item #24) exist but nothing drove
# them through the REAL gates — gate-suite.sh only runs each gate's hermetic --selftest, so a gate can go
# blind on real input while its selftest stays green. This runner closes that gap (roadmap R6 / P2 — the
# measured self-regression): for every fixture it runs its TARGET gate against the fixture tree and asserts
# the frozen expectation — a POISONED twin MUST be caught (gate exits 2) and its CLEAN twin MUST pass
# (gate exits 0). A gate that stops catching its poison (went blind) OR starts false-firing on its clean
# twin is a self-regression => exit 2. Measured, not asserted: PASS means the gates ACTUALLY ran + observed.
#
# Manifest: walteur-kit/eval-harness/manifest.json  — [ {fixture, gate, expect:"FAIL"|"PASS", note} ]
# Report:   walteur-kit/eval-harness/self-regress-report.json
# Bypass:   WALTEUR_SELFREGRESS=off (recorded, not free)
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
    printf '%s\n' "self-regress - measured self-regression: drives the poisoned/clean fixtures through their real gates."
    printf '%s\n' "usage: bash self-regress.sh [--selftest|--help|<default run>]"
    printf '%s\n' "report: walteur-kit/eval-harness/self-regress-report.json - fix recipes: walteur-kit/REMEDIATION.md (## self-regress)"
    printf '%s\n' "bypass: WALTEUR_SELFREGRESS=off (recorded, not free)"
    exit 0 ;;
esac

set -uo pipefail

# run one fixture through one gate; echo the observed verdict from the real exit code.
# expect 2=>FAIL(caught), 0=>PASS(clean); anything else is an ERROR (never silently a pass).
run_fixture() {
  local fx="$1" gate="$2" hooks="$3" rc tmp
  [ -d "$fx" ] || { echo "ERROR:no-fixture"; return; }
  [ -f "$hooks/$gate" ] || { echo "ERROR:no-gate"; return; }
  # STAGE the fixture OUTSIDE any walteur-kit/ path. Gates prune '*/walteur-kit/*' on the ABSOLUTE path,
  # so a fixture that lives under walteur-kit/eval-harness/fixtures/ would have ALL its files pruned
  # (its abs path contains /walteur-kit/) — the gate would scan 0 files and the poison would slip through.
  # Copying to a temp root makes the gate see the fixture's real src/ (its own walteur-kit/ is still pruned).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/selfregress-fx.XXXXXX")" || { echo "ERROR:no-tmp"; return; }
  cp -R "$fx"/. "$tmp"/ 2>/dev/null
  WALTEUR_ROOT="$tmp" bash "$hooks/$gate" "$tmp" >/dev/null 2>&1
  rc=$?
  rm -rf "$tmp"
  case "$rc" in
    2) echo "FAIL" ;;
    0) echo "PASS" ;;
    *) echo "ERROR:rc$rc" ;;
  esac
}

main() {
  local ROOT KIT HOOKS EH MAN REPORT
  ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  KIT="$ROOT/walteur-kit"; HOOKS="$KIT/hooks"; EH="$KIT/eval-harness"
  MAN="$EH/manifest.json"; REPORT="$EH/self-regress-report.json"
  [ -f "$KIT/PAUSED" ] && { echo "self-regress: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_SELFREGRESS:-on}" = "off" ] && { echo "self-regress: bypassed"; exit 0; }
  # No eval-harness on this tree => NOT_APPLICABLE (a built product, not the framework repo).
  [ -f "$MAN" ] || { echo "self-regress: NOT_APPLICABLE (no eval-harness manifest)"; exit 0; }
  command -v jq >/dev/null 2>&1 || { echo "self-regress: FAIL — jq absent; cannot measure (fail-closed)" >&2; exit 2; }

  local total=0 ok=0 regress='[]' errors='[]'
  local n; n="$(jq 'length' "$MAN" 2>/dev/null || echo 0)"
  local i=0
  while [ "$i" -lt "$n" ]; do
    local fixture gate expect fxdir observed
    fixture="$(jq -r ".[$i].fixture" "$MAN")"; gate="$(jq -r ".[$i].gate" "$MAN")"; expect="$(jq -r ".[$i].expect" "$MAN")"
    i=$((i+1)); total=$((total+1))
    fxdir="$EH/fixtures/$fixture"
    observed="$(run_fixture "$fxdir" "$gate" "$HOOKS")"
    case "$observed" in
      ERROR:*) errors="$(printf '%s' "$errors" | jq --arg f "$fixture" --arg g "$gate" --arg o "$observed" '. + [{fixture:$f, gate:$g, observed:$o}]')" ;;
      "$expect") ok=$((ok+1)) ;;
      *) regress="$(printf '%s' "$regress" | jq --arg f "$fixture" --arg g "$gate" --arg e "$expect" --arg o "$observed" \
            '. + [{fixture:$f, gate:$g, expected:$e, observed:$o, kind:(if $e=="FAIL" then "gate-went-blind (poison not caught)" else "gate-false-fires (clean twin failed)" end)}]')" ;;
    esac
  done

  local nreg nerr; nreg="$(printf '%s' "$regress" | jq 'length')"; nerr="$(printf '%s' "$errors" | jq 'length')"
  jq -n --argjson t "$total" --argjson o "$ok" --argjson r "$regress" --argjson e "$errors" \
    '{verdict:(if ($r|length)>0 or ($e|length)>0 then "FAIL" else "PASS" end), gate:"self-regress", total:$t, matched:$o, regressions:$r, errors:$e}' \
    > "$REPORT" 2>/dev/null || true

  if [ "$nreg" -gt 0 ] || [ "$nerr" -gt 0 ]; then
    echo "self-regress: FAIL — $nreg regression(s), $nerr error(s) of $total fixtures (matched=$ok) -> exit 2" >&2
    printf '%s' "$regress" | jq -r '.[] | "  ✗ " + .fixture + " via " + .gate + ": expected " + .expected + " got " + .observed + "  [" + .kind + "]"' 2>/dev/null >&2
    printf '%s' "$errors"  | jq -r '.[] | "  ! " + .fixture + " via " + .gate + ": " + .observed' 2>/dev/null >&2
    exit 2
  fi
  echo "self-regress: PASS — $ok/$total fixtures behaved per baseline (poison caught, clean clean)."
  exit 0
}

selftest() {
  local pass=0 fail=0
  command -v jq >/dev/null 2>&1 || { echo "self-regress selftest SKIP - no jq."; return 0; }
  echo "self-regress selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  local SELF; SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  mkworld() {
    local d="$1" gatebody="$2"; mkdir -p "$d/walteur-kit/hooks" "$d/walteur-kit/eval-harness/fixtures/poison" "$d/walteur-kit/eval-harness/fixtures/clean"
    printf '%s\n' "$gatebody" > "$d/walteur-kit/hooks/catch.sh"
    : > "$d/walteur-kit/eval-harness/fixtures/poison/POISON"
    : > "$d/walteur-kit/eval-harness/fixtures/clean/OK"
    printf '%s\n' '[{"fixture":"poison","gate":"catch.sh","expect":"FAIL"},{"fixture":"clean","gate":"catch.sh","expect":"PASS"}]' \
      > "$d/walteur-kit/eval-harness/manifest.json"
  }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }

  # 1. a CORRECT gate (exit 2 iff POISON present) -> poison caught + clean clean -> PASS
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/selfregress.XXXXXX")"
  mkworld "$t" '#!/usr/bin/env bash
r="${WALTEUR_ROOT:-$1}"; [ -f "$r/POISON" ] && exit 2 || exit 0'
  ck "correct gate -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 2. a BLIND gate (always exit 0) -> poison NOT caught (expected FAIL, got PASS) -> regression -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/selfregress.XXXXXX")"
  mkworld "$t" '#!/usr/bin/env bash
exit 0'
  ck "gate went blind -> FAIL" 2 "$(run "$t")"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  jq -e '.verdict=="FAIL" and (.regressions|length)==1 and (.regressions[0].kind|test("blind"))' \
    "$t/walteur-kit/eval-harness/self-regress-report.json" >/dev/null 2>&1
  ck "report records the blind-gate regression" 0 "$?"; rm -rf "$t"

  # 3. a TRIGGER-HAPPY gate (always exit 2) -> clean twin false-fails (expected PASS, got FAIL) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/selfregress.XXXXXX")"
  mkworld "$t" '#!/usr/bin/env bash
exit 2'
  ck "gate false-fires on clean twin -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 4. an ERRORING gate (exit 1) -> ERROR, never silently a pass -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/selfregress.XXXXXX")"
  mkworld "$t" '#!/usr/bin/env bash
exit 1'
  ck "gate error (rc=1) -> FAIL (never silent pass)" 2 "$(run "$t")"; rm -rf "$t"

  # 5. no manifest -> NOT_APPLICABLE (exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/selfregress.XXXXXX")"; mkdir -p "$t/walteur-kit"
  ck "no manifest -> NOT_APPLICABLE" 0 "$(run "$t")"; rm -rf "$t"

  # 6. bypass
  t="$(mktemp -d "${TMPDIR:-/tmp}/selfregress.XXXXXX")"; mkworld "$t" '#!/usr/bin/env bash
exit 0'
  WALTEUR_ROOT="$t" WALTEUR_SELFREGRESS=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"

  echo "self-regress selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
