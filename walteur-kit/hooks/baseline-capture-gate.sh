#!/usr/bin/env bash
# WALTEUR baseline-capture-gate — gate on the brownfield 'before' snapshot (the BASELINE-phase contract, §2.6
# BROWNFIELD UPGRADE). You cannot prove an upgrade IMPROVED or DID NOT BREAK an app without a captured before
# state. On a brownfield run, a missing/stub walteur-kit/baseline.json = FAIL (exit 2). Greenfield => NA.
#
# Applicability (detect-or-LOUD-SKIP): a "brownfield signal" is preflight-signals.json .is_brownfield==true OR
#   a walteur-kit/baseline.json or walteur-kit/INTENT.md present. NEITHER => NOT_APPLICABLE (a new build has
#   no prior state to baseline).
# Contract (anti-stub), when applicable, baseline.json must be valid JSON carrying ALL of:
#   captured_ts · build.status · tests.status · a NON-EMPTY dimensions[] each with a NUMERIC score ·
#   characterization.status in {present, absent-with-reason} (present => command|path; absent-with-reason =>
#   reason). The numeric dimension scores are the floor non-regression-gate later proves after>=before against.
#
# jq required: applicable + jq missing => SKIP recorded (the whole kit needs jq; detect-or-skip convention).
# Bypass WALTEUR_BASELINE=off. Kill switch walteur-kit/PAUSED => exit 2.
# Report: walteur-kit/baseline-report.json {verdict, ts, gate, mode, reason, findings}.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "baseline-capture-gate - gate on the brownfield before snapshot (the BASELINE-phase contract, -2.6"
  printf '%s\n' "usage: bash baseline-capture-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/baseline-report.json - fix recipes: walteur-kit/REMEDIATION.md (## baseline-capture-gate)"
  printf '%s\n' "bypass: WALTEUR_BASELINE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
BASE="$KIT/baseline.json"
REPORT="$KIT/baseline-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; }
write_report() { # $1=verdict $2=mode $3=reason
  if have jq; then
    jq -n --arg v "$1" --arg ts "$TS" --arg mode "$2" --arg r "$3" --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"baseline-capture", mode:$mode, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"baseline-capture","mode":"%s","reason":"%s"}\n' "$1" "$TS" "$2" "$3" > "$REPORT" 2>/dev/null || true
}

brownfield_signal() { [ -f "$SIGNALS" ] && have jq && jq -e '.is_brownfield==true' "$SIGNALS" >/dev/null 2>&1; }
applies() { brownfield_signal && return 0; [ -f "$BASE" ] && return 0; [ -f "$KIT/INTENT.md" ] && return 0; return 1; }

run_gate() {
  [ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }

  if [ "${WALTEUR_BASELINE:-on}" = "off" ]; then
    echo "WALTEUR baseline-capture-gate SKIP — bypass WALTEUR_BASELINE=off (recorded)." >&2
    write_report "SKIP" "bypass" "bypass WALTEUR_BASELINE=off"; exit 0
  fi

  if ! applies; then
    echo "WALTEUR baseline-capture-gate NOT_APPLICABLE — no brownfield signal (greenfield: nothing to baseline)." >&2
    write_report "NOT_APPLICABLE" "not-applicable" "no brownfield signal (no preflight-signals.is_brownfield, no baseline.json, no INTENT.md)"
    exit 0
  fi

  if ! have jq; then
    echo "WALTEUR baseline-capture-gate SKIP — jq not installed (recorded, not silent-green)." >&2
    write_report "SKIP" "tool-missing" "jq not installed"; exit 0
  fi

  if [ ! -f "$BASE" ]; then
    add_finding "missing-baseline" "brownfield signal present but no walteur-kit/baseline.json. Run BASELINE (§2.6): capture the before-state BEFORE the first upgrade edit (build/tests/8-dim/security/perf + a golden-master net)."
    write_report "FAIL" "applicable" "brownfield signal but no baseline.json — cannot prove improvement or non-regression without a captured before-state"
    echo "WALTEUR baseline-capture-gate: FAIL — brownfield but no baseline.json (capture it before any edit)." >&2
    exit 2
  fi

  if ! jq -e . "$BASE" >/dev/null 2>&1; then
    add_finding "invalid-json" "baseline.json is not valid JSON"
    write_report "FAIL" "applicable" "baseline.json is not valid JSON"
    echo "WALTEUR baseline-capture-gate: FAIL — baseline.json is not valid JSON." >&2
    exit 2
  fi

  MISSING=()
  jq -e '(.captured_ts // "") | length > 0'       "$BASE" >/dev/null 2>&1 || MISSING+=("captured_ts")
  jq -e '(.build.status // "") | length > 0'      "$BASE" >/dev/null 2>&1 || MISSING+=("build.status")
  jq -e '(.tests.status // "") | length > 0'      "$BASE" >/dev/null 2>&1 || MISSING+=("tests.status")
  jq -e '(.dimensions // []) | length > 0'        "$BASE" >/dev/null 2>&1 || MISSING+=("dimensions(non-empty)")
  jq -e '(.dimensions // []) | length>0 and all(.[]; (.name|type=="string") and (.score|type=="number"))' "$BASE" >/dev/null 2>&1 \
    || MISSING+=("dimensions[].score(numeric)")
  jq -e '(.characterization.status // "") | (. == "present" or . == "absent-with-reason")' "$BASE" >/dev/null 2>&1 \
    || MISSING+=("characterization.status(present|absent-with-reason)")

  CSTATUS="$(jq -r '.characterization.status // ""' "$BASE" 2>/dev/null)"
  if [ "$CSTATUS" = "present" ]; then
    jq -e '((.characterization.command // "")|length>0) or ((.characterization.path // "")|length>0)' "$BASE" >/dev/null 2>&1 \
      || MISSING+=("characterization.command|path(required when present)")
  elif [ "$CSTATUS" = "absent-with-reason" ]; then
    jq -e '(.characterization.reason // "")|length>0' "$BASE" >/dev/null 2>&1 \
      || MISSING+=("characterization.reason(required when absent-with-reason)")
  fi

  if [ "${#MISSING[@]}" -gt 0 ]; then
    for m in "${MISSING[@]}"; do add_finding "stub-baseline" "baseline.json missing/invalid: $m"; done
    write_report "FAIL" "applicable" "baseline.json is a stub — missing: $(printf '%s; ' "${MISSING[@]}")"
    echo "WALTEUR baseline-capture-gate: FAIL — baseline.json is a stub. Missing: ${MISSING[*]}" >&2
    exit 2
  fi

  NDIM="$(jq -r '(.dimensions // []) | length' "$BASE" 2>/dev/null)"
  write_report "PASS" "applicable" "baseline captured: $NDIM dimension(s) scored, characterization=$CSTATUS"
  echo "WALTEUR baseline-capture-gate: PASS — before-snapshot valid ($NDIM dims, characterization=$CSTATUS)." >&2
  exit 0
}

# ── embedded self-test (good + poisoned twins; hermetic) ─────────────────────────
selftest() {
  pass=0; fail=0
  if ! have jq; then echo "baseline-capture-gate selftest SKIP - no jq."; return 0; fi
  echo "baseline-capture-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  brown() { mkdir -p "$1/walteur-kit"; printf '{"is_brownfield":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  edit() { jq "$1" "$2/walteur-kit/baseline.json" > "$2/m" && mv "$2/m" "$2/walteur-kit/baseline.json"; }
  goodbase() { jq -n '{baseline_version:1, captured_ts:"2026-06-27T00:00:00Z", target:"app",
    build:{status:"pass",command:"npm run build"},
    tests:{status:"pass",passed:10,failed:0,total:10,command:"npm test"},
    dimensions:[{name:"correctness",score:6},{name:"security",score:5}],
    characterization:{status:"present",command:"npm run golden",count:8}}' > "$1/walteur-kit/baseline.json"; }

  # 1. greenfield (is_brownfield:false, no baseline) -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"is_brownfield":false}\n' > "$t/walteur-kit/preflight-signals.json"; ck "greenfield -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. complete baseline -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; brown "$t"; goodbase "$t"; ck "complete baseline -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. brownfield, no baseline -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; brown "$t"; ck "brownfield, no baseline -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. missing characterization -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; brown "$t"; goodbase "$t"; edit 'del(.characterization)' "$t"; ck "missing characterization -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. empty dimensions -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; brown "$t"; goodbase "$t"; edit '.dimensions=[]' "$t"; ck "empty dimensions -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. non-numeric score -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; brown "$t"; goodbase "$t"; edit '.dimensions[0].score="high"' "$t"; ck "non-numeric score -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. characterization present but no command/path -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; brown "$t"; goodbase "$t"; edit '.characterization={status:"present"}' "$t"; ck "present, no command/path -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. absent-with-reason but no reason -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; brown "$t"; goodbase "$t"; edit '.characterization={status:"absent-with-reason"}' "$t"; ck "absent-with-reason, no reason -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. absent-with-reason WITH reason -> PASS (legit: static site etc.)
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; brown "$t"; goodbase "$t"; edit '.characterization={status:"absent-with-reason",reason:"static site; DOM snapshotted"}' "$t"; ck "absent-with-reason + reason -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 10. missing captured_ts -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; brown "$t"; goodbase "$t"; edit 'del(.captured_ts)' "$t"; ck "missing captured_ts -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 11. invalid JSON -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; brown "$t"; printf 'not json\n' > "$t/walteur-kit/baseline.json"; ck "invalid JSON -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 12. bypass -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; brown "$t"; WALTEUR_ROOT="$t" WALTEUR_BASELINE=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  # 13. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/baselineca.XXXXXX")"; brown "$t"; goodbase "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "baseline-capture-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi
run_gate "${1:-}"
