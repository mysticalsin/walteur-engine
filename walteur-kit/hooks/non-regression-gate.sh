#!/usr/bin/env bash
# WALTEUR non-regression-gate — HARD terminal gate (the PROVE-phase contract, §2.6 BROWNFIELD UPGRADE). The
# brownfield ship blocker: an upgrade ships only if it is >= the captured baseline on EVERY dimension (no
# silent regression), the characterization/golden-master net is still GREEN (observable behavior preserved),
# and every intentional behavior change carries a SIGNED ADR. The gate RE-DERIVES regression from before/after
# (evidence over assertion) — it never trusts the self-reported verdict.
#
# Applicability: a "brownfield signal" is preflight-signals.json .is_brownfield==true OR a walteur-kit/
#   baseline.json or walteur-kit/non-regression.json present. Greenfield => NOT_APPLICABLE.
# Contract (HARD), when applicable, walteur-kit/non-regression.json must prove ALL of:
#   - baseline_ref resolves to an existing baseline.json
#   - dimensions[] is non-empty; each {name, before, after} numeric; for EVERY dimension after>=before UNLESS
#     it carries a waiver_ref that resolves to an existing signed record
#   - characterization.status == green (or na-with-reason WITH a reason)
#   - every behavior_changes[].adr_ref names an EXISTING adr file (an unsigned behavior change is a silent break)
#   Any breach => FAIL exit 2. Missing non-regression.json on a brownfield ship => FAIL (fail-closed).
#
# jq required: applicable + jq missing => fail-closed FAIL (cannot verify the safety proof). HARD by design.
# Bypass WALTEUR_NONREGRESSION=off => SKIP exit 0. Kill switch walteur-kit/PAUSED => exit 2.
# Report: walteur-kit/non-regression-report.json {verdict, ts, gate, mode, reason, findings}.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "non-regression-gate - HARD terminal gate (the PROVE-phase contract, -2.6 BROWNFIELD UPGRADE). The"
  printf '%s\n' "usage: bash non-regression-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/non-regression-report.json - fix recipes: walteur-kit/REMEDIATION.md (## non-regression-gate)"
  printf '%s\n' "bypass: WALTEUR_NONREGRESSION=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
NR="$KIT/non-regression.json"
REPORT="$KIT/non-regression-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; }
write_report() { # $1=verdict $2=mode $3=reason
  if have jq; then
    jq -n --arg v "$1" --arg ts "$TS" --arg mode "$2" --arg r "$3" --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"non-regression", mode:$mode, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"non-regression","mode":"%s","reason":"%s"}\n' "$1" "$TS" "$2" "$3" > "$REPORT" 2>/dev/null || true
}

brownfield_signal() { [ -f "$SIGNALS" ] && have jq && jq -e '.is_brownfield==true' "$SIGNALS" >/dev/null 2>&1; }
applies() { brownfield_signal && return 0; [ -f "$KIT/baseline.json" ] && return 0; [ -f "$NR" ] && return 0; return 1; }
resolve() { # $1=ref -> echo a resolving path or empty
  local r="$1"
  [ -z "$r" ] && return 0
  for p in "$r" "$ROOT/$r" "$KIT/$(basename "$r")"; do [ -f "$p" ] && { echo "$p"; return 0; }; done
  echo ""
}

run_gate() {
  [ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }

  if [ "${WALTEUR_NONREGRESSION:-on}" = "off" ]; then
    echo "WALTEUR non-regression-gate SKIP — bypass WALTEUR_NONREGRESSION=off (recorded)." >&2
    write_report "SKIP" "bypass" "bypass WALTEUR_NONREGRESSION=off"; exit 0
  fi

  if ! applies; then
    echo "WALTEUR non-regression-gate NOT_APPLICABLE — no brownfield signal (greenfield ship)." >&2
    write_report "NOT_APPLICABLE" "not-applicable" "no brownfield signal (no preflight-signals.is_brownfield, no baseline.json, no non-regression.json)"
    exit 0
  fi

  if ! have jq; then
    add_finding "tool-missing" "jq required to verify the brownfield non-regression proof"
    write_report "FAIL" "tool-missing" "jq not installed — cannot verify non-regression (fail-closed; HARD gate)"
    echo "WALTEUR non-regression-gate: FAIL — jq missing, cannot verify (fail-closed)." >&2
    exit 2
  fi

  if [ ! -f "$NR" ]; then
    add_finding "missing-proof" "brownfield ship with no walteur-kit/non-regression.json. Run PROVE (§2.6): snapshot the after-state and compare to baseline.json."
    write_report "FAIL" "applicable" "brownfield ship but no non-regression.json — non-regression is unproven"
    echo "WALTEUR non-regression-gate: FAIL — no non-regression.json (run PROVE)." >&2
    exit 2
  fi
  if ! jq -e . "$NR" >/dev/null 2>&1; then
    add_finding "invalid-json" "non-regression.json is not valid JSON"
    write_report "FAIL" "applicable" "non-regression.json is not valid JSON"
    echo "WALTEUR non-regression-gate: FAIL — non-regression.json is not valid JSON." >&2
    exit 2
  fi

  fail=0

  # baseline_ref must resolve
  BREF="$(jq -r '.baseline_ref // ""' "$NR" 2>/dev/null)"
  if [ -z "$BREF" ]; then
    add_finding "missing-baseline-ref" "non-regression.json has no baseline_ref — cannot anchor the comparison"; fail=1
  elif [ -z "$(resolve "$BREF")" ]; then
    add_finding "baseline-missing" "baseline_ref '$BREF' does not resolve to a file"; fail=1
  fi

  # dimensions non-empty
  if ! jq -e '(.dimensions // []) | length > 0' "$NR" >/dev/null 2>&1; then
    add_finding "no-dimensions" "dimensions[] is empty — nothing is proven"; fail=1
  fi
  # non-numeric before/after anywhere => unprovable
  if jq -e '(.dimensions // []) | any(.[]; (.before|type!="number") or (.after|type!="number"))' "$NR" >/dev/null 2>&1; then
    add_finding "non-numeric" "a dimension has non-numeric before/after — after>=before is unprovable"; fail=1
  fi
  # any dimension that regressed (after<before) WITHOUT a waiver_ref => FAIL
  while IFS= read -r d; do
    [ -n "$d" ] && { add_finding "regression" "dimension '$d' regressed (after<before) with no signed waiver_ref"; fail=1; }
  done < <(jq -r '(.dimensions // [])[]
      | select((.after|type=="number") and (.before|type=="number") and (.after < .before))
      | select((.waiver_ref // "") == "") | .name' "$NR" 2>/dev/null)
  # any waiver_ref that is present must resolve to a real signed record
  while IFS= read -r w; do
    [ -z "$w" ] && continue
    [ -z "$(resolve "$w")" ] && { add_finding "waiver-missing" "waiver_ref '$w' does not resolve to a signed record"; fail=1; }
  done < <(jq -r '(.dimensions // [])[] | (.waiver_ref // "") | select(. != "")' "$NR" 2>/dev/null)

  # characterization / golden-master net
  CSTATUS="$(jq -r '.characterization.status // ""' "$NR" 2>/dev/null)"
  case "$CSTATUS" in
    green) : ;;
    na-with-reason) jq -e '(.characterization.reason // "")|length>0' "$NR" >/dev/null 2>&1 \
        || { add_finding "char-na-noreason" "characterization na-with-reason but no reason given"; fail=1; } ;;
    red) add_finding "char-red" "characterization/golden-master net is RED — observable behavior regressed"; fail=1 ;;
    *)   add_finding "char-missing" "characterization.status missing/invalid (need green | na-with-reason)"; fail=1 ;;
  esac

  # every behavior change must cite an existing, signed ADR
  while IFS= read -r a; do
    if [ -z "$a" ]; then
      add_finding "behavior-unsigned" "a behavior_change has an empty adr_ref — an unsigned breaking change"; fail=1; continue
    fi
    [ -z "$(resolve "$a")" ] && { add_finding "adr-missing" "behavior_change adr_ref '$a' does not resolve to a signed ADR file"; fail=1; }
  done < <(jq -r '(.behavior_changes // [])[] | (.adr_ref // "")' "$NR" 2>/dev/null)

  if [ "$fail" -ne 0 ]; then
    write_report "FAIL" "applicable" "non-regression NOT proven — see findings (regression, red golden-master, or unsigned behavior change)"
    echo "WALTEUR non-regression-gate: FAIL — non-regression NOT proven." >&2
    exit 2
  fi

  NDIM="$(jq -r '(.dimensions // []) | length' "$NR" 2>/dev/null)"
  write_report "PASS" "applicable" "non-regression proven: after>=before on all $NDIM dimension(s), golden-master $CSTATUS, behavior changes signed"
  echo "WALTEUR non-regression-gate: PASS — after>=before on all $NDIM dims, golden-master $CSTATUS." >&2
  exit 0
}

# ── embedded self-test (good + poisoned twins; hermetic) ─────────────────────────
selftest() {
  pass=0; fail=0
  if ! have jq; then echo "non-regression-gate selftest SKIP - no jq."; return 0; fi
  echo "non-regression-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  brown() { mkdir -p "$1/walteur-kit"; printf '{"is_brownfield":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  base() { printf '{"baseline_version":1}\n' > "$1/walteur-kit/baseline.json"; }
  edit() { jq "$1" "$2/walteur-kit/non-regression.json" > "$2/m" && mv "$2/m" "$2/walteur-kit/non-regression.json"; }
  goodnr() { jq -n '{non_regression_version:1, proven_ts:"2026-06-27T01:00:00Z",
    baseline_ref:"walteur-kit/baseline.json",
    dimensions:[{name:"correctness",before:6,after:8},{name:"security",before:5,after:7}],
    characterization:{status:"green",command:"npm run golden"},
    behavior_changes:[], verdict:"pass"}' > "$1/walteur-kit/non-regression.json"; }

  # 1. greenfield -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"is_brownfield":false}\n' > "$t/walteur-kit/preflight-signals.json"; ck "greenfield -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. good (after>=before, golden green, no behavior change) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; goodnr "$t"; ck "after>=before, golden green -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. brownfield, baseline present, NO non-regression.json -> FAIL (fail-closed)
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; ck "brownfield, no non-regression.json -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. a regressed dimension, no waiver -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; goodnr "$t"; edit '.dimensions[1].after=3' "$t"; ck "regression, no waiver -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. a regressed dimension WITH a resolving signed waiver -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; goodnr "$t"; mkdir -p "$t/walteur-kit/adr"; printf 'signed: Tony\n' > "$t/walteur-kit/adr/0007-drop-legacy.md"; edit '.dimensions[1].after=3 | .dimensions[1].waiver_ref="walteur-kit/adr/0007-drop-legacy.md"' "$t"; ck "regression + signed waiver -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 6. characterization RED -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; goodnr "$t"; edit '.characterization.status="red"' "$t"; ck "golden-master red -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. behavior_change with EMPTY adr_ref -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; goodnr "$t"; edit '.behavior_changes=[{change:"renamed endpoint",adr_ref:""}]' "$t"; ck "behavior change unsigned -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. behavior_change adr_ref -> MISSING file -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; goodnr "$t"; edit '.behavior_changes=[{change:"renamed endpoint",adr_ref:"walteur-kit/adr/ghost.md"}]' "$t"; ck "behavior change adr missing -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. behavior_change adr_ref -> EXISTING signed file -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; goodnr "$t"; mkdir -p "$t/walteur-kit/adr"; printf 'signed: Tony\n' > "$t/walteur-kit/adr/0008-rename.md"; edit '.behavior_changes=[{change:"renamed endpoint",adr_ref:"walteur-kit/adr/0008-rename.md"}]' "$t"; ck "behavior change signed -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 10. baseline_ref unresolvable -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; goodnr "$t"; edit '.baseline_ref="walteur-kit/nope.json"' "$t"; ck "baseline_ref unresolvable -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 11. non-numeric after -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; goodnr "$t"; edit '.dimensions[0].after="high"' "$t"; ck "non-numeric after -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 12. na-with-reason characterization, no behavior change -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; goodnr "$t"; edit '.characterization={status:"na-with-reason",reason:"pure static render; DOM snapshotted in baseline"}' "$t"; ck "characterization na+reason -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 13. empty dimensions -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; goodnr "$t"; edit '.dimensions=[]' "$t"; ck "empty dimensions -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 14. invalid JSON -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; printf 'not json\n' > "$t/walteur-kit/non-regression.json"; ck "invalid JSON -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 15. bypass -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; WALTEUR_ROOT="$t" WALTEUR_NONREGRESSION=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  # 16. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/nonregress.XXXXXX")"; brown "$t"; base "$t"; goodnr "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "non-regression-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi
run_gate "${1:-}"
