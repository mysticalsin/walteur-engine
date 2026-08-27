#!/usr/bin/env bash
# WALTEUR report-integrity-gate — freshness + coherence floor across walteur-kit/*-report.json.
#
# The gate suite proves each gate's HERMETIC --selftest and execution-ratio-gate proves how many gates
# EXECUTED vs shape-read — but nothing checks whether the REPORTS THEMSELVES are internally honest: a
# report can claim verdict:PASS while its own observed_exit is nonzero, or claim an *_executed marker
# without ever recording what exit it observed. This gate closes that seam with two checks, run over
# every walteur-kit/*-report.json that carries a .verdict field:
#
#   1. FRESHNESS (fresh mode only, see MODES below) — .ts must exist and be within
#      WALTEUR_REPORT_MAXAGE hours (default 72). Missing/stale .ts => finding.
#   2. COHERENCE (always checked) —
#        a. verdict==PASS AND observed_exit is a number != 0 => finding (a PASS report cannot also
#           record a nonzero observed exit; that is a self-contradiction, not a pass).
#        b. any key matching *_executed == true present WITHOUT an .observed_exit field on the SAME
#           report => finding (an execution claim with nothing recording what was actually observed).
#
# MODES:
#   --selftest         hermetic GOOD/POISONED fixture pass — see selftest() below.
#   (default)           ADVISORY scan of $KIT/*-report.json in FRESH mode (freshness + coherence both
#                       checked); reports findings to stderr + JSON, exit 0 UNLESS WALTEUR_REPORT_INTEGRITY
#                       is "hard" (then any finding => exit 2).
#   WALTEUR_REPORT_INTEGRITY_MODE=stale  skips the freshness check (coherence-only; useful for a cold
#                       audit pass over historical reports where staleness is expected and not the point).
#
# CONTRACT: PAUSED => exit 2 (unless bypassed). Bypass: WALTEUR_REPORT_INTEGRITY_GATE=off (note: distinct
#   from WALTEUR_REPORT_INTEGRITY, which controls hard/advisory severity, not bypass).
# Report: walteur-kit/report-integrity-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "report-integrity-gate - freshness + coherence floor across walteur-kit/*-report.json."
  printf '%s\n' "usage: bash report-integrity-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/report-integrity-report.json - fix recipes: walteur-kit/REMEDIATION.md (## report-integrity-gate)"
  printf '%s\n' "bypass: WALTEUR_REPORT_INTEGRITY_GATE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

# scan_dir(): the actual check logic, factored so both main() and selftest() call the same code path
# against different roots. Writes findings to stdout as a jq-built JSON array; prints nothing else.
# Args: $1=kit_dir  $2=maxage_hours  $3=mode(fresh|stale)
scan_dir() {
  local kit="$1" maxage="$2" mode="$3" now findings='[]' f base v ts_val has_ts age_secs marker_line
  now="$(date -u +%s)"
  for f in "$kit"/*-report.json; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in report-integrity-report.json) continue ;; esac
    jq -e . "$f" >/dev/null 2>&1 || continue
    v="$(jq -r '.verdict // empty' "$f" 2>/dev/null)"
    [ -n "$v" ] || continue   # only reports that carry a verdict are in scope

    # ── check 1: freshness (fresh mode only) ──
    if [ "$mode" = "fresh" ]; then
      ts_val="$(jq -r '.ts // empty' "$f" 2>/dev/null)"
      if [ -z "$ts_val" ] || [ "$ts_val" = "null" ]; then
        findings="$(printf '%s' "$findings" | jq --arg g "$base" '. + [{report:$g, check:"freshness", reason:"no .ts field present"}]')"
      else
        ts_epoch="$(date -u -d "$ts_val" +%s 2>/dev/null || true)"
        if [ -z "$ts_epoch" ]; then
          findings="$(printf '%s' "$findings" | jq --arg g "$base" --arg t "$ts_val" '. + [{report:$g, check:"freshness", reason:("ts \($t) is not a parseable timestamp")}]')"
        else
          age_secs=$(( now - ts_epoch ))
          if [ "$age_secs" -gt "$(( maxage * 3600 ))" ]; then
            findings="$(printf '%s' "$findings" | jq --arg g "$base" --argjson age "$age_secs" --argjson max "$(( maxage * 3600 ))" '. + [{report:$g, check:"freshness", reason:("stale: age \($age)s exceeds max \($max)s")}]')"
          fi
        fi
      fi
    fi

    # ── check 2a: PASS verdict + nonzero observed_exit is a self-contradiction ──
    if [ "$v" = "PASS" ]; then
      if jq -e '(.observed_exit != null) and (.observed_exit | type == "number") and (.observed_exit != 0)' "$f" >/dev/null 2>&1; then
        oe="$(jq -r '.observed_exit' "$f" 2>/dev/null)"
        findings="$(printf '%s' "$findings" | jq --arg g "$base" --arg oe "$oe" '. + [{report:$g, check:"coherence", reason:("verdict PASS but observed_exit=\($oe) (nonzero) — self-contradictory")}]')"
      fi
    fi

    # ── check 2b: any *_executed==true marker with no .observed_exit on the same report ──
    marker_line="$(jq -r '[to_entries[] | select(.key | test("_executed$")) | select(.value == true) | .key] | join(",")' "$f" 2>/dev/null)"
    if [ -n "$marker_line" ]; then
      if ! jq -e '.observed_exit != null' "$f" >/dev/null 2>&1; then
        findings="$(printf '%s' "$findings" | jq --arg g "$base" --arg m "$marker_line" '. + [{report:$g, check:"coherence", reason:("execution marker(s) [\($m)] set true with no .observed_exit recorded on the same report")}]')"
      fi
    fi
  done
  printf '%s' "$findings"
}

main() {
  ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  KIT="$ROOT/walteur-kit"
  REPORT="$KIT/report-integrity-report.json"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$KIT"

  [ -f "$KIT/PAUSED" ] && { printf '{"verdict":"FAIL","ts":"%s","gate":"report-integrity","reason":"paused"}\n' "$TS" > "$REPORT" 2>/dev/null; echo "report-integrity-gate: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_REPORT_INTEGRITY_GATE:-}" = "off" ] && { printf '{"verdict":"SKIP","ts":"%s","gate":"report-integrity","reason":"bypassed via WALTEUR_REPORT_INTEGRITY_GATE=off"}\n' "$TS" > "$REPORT" 2>/dev/null; echo "report-integrity-gate: SKIP (bypass)" >&2; exit 0; }
  if ! have jq; then printf '{"verdict":"SKIP","ts":"%s","gate":"report-integrity","reason":"jq not installed"}\n' "$TS" > "$REPORT" 2>/dev/null; echo "report-integrity-gate: SKIP (no jq)" >&2; exit 0; fi

  local maxage mode hard findings n
  maxage="${WALTEUR_REPORT_MAXAGE:-72}"
  mode="${WALTEUR_REPORT_INTEGRITY_MODE:-fresh}"
  hard=0; [ "${WALTEUR_REPORT_INTEGRITY:-}" = "hard" ] && hard=1

  findings="$(scan_dir "$KIT" "$maxage" "$mode")"
  n="$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo 0)"

  if [ "$n" -eq 0 ]; then
    jq -n --arg ts "$TS" --argjson maxage "$maxage" --arg mode "$mode" \
      '{verdict:"PASS", ts:$ts, gate:"report-integrity", reason:"no freshness/coherence findings across walteur-kit/*-report.json", findings:[], maxage_hours:$maxage, mode:$mode, hard:false}' \
      > "$REPORT" 2>/dev/null
    echo "report-integrity-gate: PASS — 0 findings (mode=$mode, maxage=${maxage}h)" >&2
    exit 0
  fi

  jq -n --arg ts "$TS" --argjson maxage "$maxage" --arg mode "$mode" --argjson f "$findings" --argjson hard "$([ "$hard" = 1 ] && echo true || echo false)" \
    --arg v "$([ "$hard" = 1 ] && echo FAIL || echo PASS)" \
    '{verdict:$v, ts:$ts, gate:"report-integrity", reason:(($f|length|tostring) + " finding(s) across walteur-kit/*-report.json"), findings:$f, finding_count:($f|length), maxage_hours:$maxage, mode:$mode, hard:$hard}' \
    > "$REPORT" 2>/dev/null

  echo "report-integrity-gate: $n finding(s) (mode=$mode, maxage=${maxage}h, hard=$hard)" >&2
  printf '%s' "$findings" | jq -r '.[] | "  - " + .report + " [" + .check + "]: " + .reason' 2>/dev/null | head -20 >&2

  if [ "$hard" -eq 1 ]; then
    echo "report-integrity-gate: FAIL — WALTEUR_REPORT_INTEGRITY=hard, findings block -> exit 2" >&2
    exit 2
  fi
  echo "report-integrity-gate: PASS (advisory) — findings reported but not blocking; set WALTEUR_REPORT_INTEGRITY=hard to enforce" >&2
  exit 0
}

selftest() {
  echo "report-integrity-gate selftest:"
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (exit $3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  run_hard() { WALTEUR_ROOT="$1" WALTEUR_REPORT_INTEGRITY=hard bash "$SELF" >/dev/null 2>&1; echo $?; }

  if ! have jq; then echo "  skip - jq absent, report-integrity-gate SKIPs by design (fail-open by declared contract, not silently)"; echo "report-integrity-gate selftest: 0/0 passed (jq absent)"; return 0; fi

  # G1 GOOD — a single fresh, coherent PASS report (with a matched executed+observed_exit pair) -> PASS, 0 findings.
  t="$(mktemp -d "${TMPDIR:-/tmp}/reportinte.XXXXXX")"; mkdir -p "$t/walteur-kit"
  now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg ts "$now_ts" '{verdict:"PASS", ts:$ts, gate:"good-gate", observed_exit:0, good_thing_executed:true}' > "$t/walteur-kit/good-report.json"
  ck "G1 GOOD fresh coherent report -> exit 0 (advisory PASS)" 0 "$(run "$t")"
  jq -e '.verdict=="PASS" and .finding_count==null' "$t/walteur-kit/report-integrity-report.json" >/dev/null 2>&1 || jq -e '.verdict=="PASS"' "$t/walteur-kit/report-integrity-report.json" >/dev/null 2>&1
  ck "  own report records verdict PASS" 0 "$?"
  rm -rf "$t"

  # G2 POISON — stale ts (100h old, default max 72h) -> advisory finding, still exit 0 (not hard).
  t="$(mktemp -d "${TMPDIR:-/tmp}/reportinte.XXXXXX")"; mkdir -p "$t/walteur-kit"
  old_epoch=$(( $(date -u +%s) - 100*3600 ))
  old_ts="$(date -u -d "@$old_epoch" +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg ts "$old_ts" '{verdict:"PASS", ts:$ts, gate:"stale-gate"}' > "$t/walteur-kit/stale-report.json"
  ck "G2 stale report (100h>72h) -> advisory PASS (exit 0)" 0 "$(run "$t")"
  jq -e '.finding_count >= 1' "$t/walteur-kit/report-integrity-report.json" >/dev/null 2>&1; ck "  finding recorded for staleness" 0 "$?"
  ck "G2b same fixture under WALTEUR_REPORT_INTEGRITY=hard -> FAIL (exit 2)" 2 "$(run_hard "$t")"
  rm -rf "$t"

  # G3 POISON — hand-forged: verdict PASS but observed_exit nonzero (self-contradiction) -> finding.
  t="$(mktemp -d "${TMPDIR:-/tmp}/reportinte.XXXXXX")"; mkdir -p "$t/walteur-kit"
  jq -n --arg ts "$now_ts" '{verdict:"PASS", ts:$ts, gate:"lying-gate", observed_exit:1}' > "$t/walteur-kit/lying-report.json"
  ck "G3 PASS+observed_exit!=0 -> advisory PASS (exit 0)" 0 "$(run "$t")"
  jq -e '.findings[] | select(.check=="coherence" and (.reason|test("self-contradictory")))' "$t/walteur-kit/report-integrity-report.json" >/dev/null 2>&1
  ck "  coherence finding names the self-contradiction" 0 "$?"
  ck "G3b same fixture under hard mode -> FAIL (exit 2)" 2 "$(run_hard "$t")"
  rm -rf "$t"

  # G4 POISON — *_executed:true marker with no observed_exit field anywhere on the report -> finding.
  t="$(mktemp -d "${TMPDIR:-/tmp}/reportinte.XXXXXX")"; mkdir -p "$t/walteur-kit"
  jq -n --arg ts "$now_ts" '{verdict:"PASS", ts:$ts, gate:"claim-gate", something_executed:true}' > "$t/walteur-kit/claim-report.json"
  ck "G4 *_executed marker with no observed_exit -> advisory PASS (exit 0)" 0 "$(run "$t")"
  jq -e '.findings[] | select(.check=="coherence" and (.reason|test("execution marker")))' "$t/walteur-kit/report-integrity-report.json" >/dev/null 2>&1
  ck "  coherence finding names the missing observed_exit" 0 "$?"
  ck "G4b same fixture under hard mode -> FAIL (exit 2)" 2 "$(run_hard "$t")"
  rm -rf "$t"

  # G5 POISON — hand-forged garbage-not-json report must not crash the gate; it is simply skipped
  # (jq -e . fails), and a clean sibling report still gets scanned correctly.
  t="$(mktemp -d "${TMPDIR:-/tmp}/reportinte.XXXXXX")"; mkdir -p "$t/walteur-kit"
  printf 'GARBAGE NOT EVEN JSON\n' > "$t/walteur-kit/garbage-report.json"
  jq -n --arg ts "$now_ts" '{verdict:"PASS", ts:$ts, gate:"clean-gate"}' > "$t/walteur-kit/clean-report.json"
  ck "G5 forged non-JSON report does not crash the gate -> exit 0" 0 "$(run "$t")"
  rm -rf "$t"

  # G6 POISON — no .ts at all -> a freshness finding (missing ts), not a crash, in fresh mode.
  t="$(mktemp -d "${TMPDIR:-/tmp}/reportinte.XXXXXX")"; mkdir -p "$t/walteur-kit"
  jq -n '{verdict:"PASS", gate:"nots-gate"}' > "$t/walteur-kit/nots-report.json"
  ck "G6 no .ts field -> advisory PASS (exit 0)" 0 "$(run "$t")"
  jq -e '.findings[] | select(.check=="freshness" and (.reason|test("no \\.ts")))' "$t/walteur-kit/report-integrity-report.json" >/dev/null 2>&1
  ck "  freshness finding for missing ts" 0 "$?"
  rm -rf "$t"

  # G7 — WALTEUR_REPORT_INTEGRITY_MODE=stale skips the freshness check (coherence-only): a stale-ts
  # report that is otherwise coherent produces ZERO findings under stale mode.
  t="$(mktemp -d "${TMPDIR:-/tmp}/reportinte.XXXXXX")"; mkdir -p "$t/walteur-kit"
  jq -n --arg ts "$old_ts" '{verdict:"PASS", ts:$ts, gate:"stale-gate"}' > "$t/walteur-kit/stale-report.json"
  WALTEUR_ROOT="$t" WALTEUR_REPORT_INTEGRITY_MODE=stale bash "$SELF" >/dev/null 2>&1; rc=$?
  ck "G7 stale-mode skips freshness check (same stale ts, otherwise coherent) -> exit 0" 0 "$rc"
  jq -e '.finding_count == null or .finding_count == 0' "$t/walteur-kit/report-integrity-report.json" >/dev/null 2>&1; ck "  zero findings in stale mode for a coherent-but-old report" 0 "$?"
  rm -rf "$t"

  # G8 — no reports at all -> PASS, 0 findings (never false-fail an empty kit).
  t="$(mktemp -d "${TMPDIR:-/tmp}/reportinte.XXXXXX")"; mkdir -p "$t/walteur-kit"
  ck "G8 no reports present -> PASS (exit 0)" 0 "$(run "$t")"
  rm -rf "$t"

  # G9 — bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/reportinte.XXXXXX")"; mkdir -p "$t/walteur-kit"
  WALTEUR_ROOT="$t" WALTEUR_REPORT_INTEGRITY_GATE=off bash "$SELF" >/dev/null 2>&1; ck "bypass WALTEUR_REPORT_INTEGRITY_GATE=off -> exit 0" 0 "$?"
  touch "$t/walteur-kit/PAUSED"
  ck "PAUSED -> exit 2" 2 "$(run "$t")"
  rm -rf "$t"

  echo "report-integrity-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
