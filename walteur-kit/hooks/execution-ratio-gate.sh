#!/usr/bin/env bash
# WALTEUR execution-ratio-gate — META gate (S008 robustness fix).
#
# The independent audit's robustness killer: gate-suite only proves each gate's HERMETIC --selftest, so a box
# missing every backing scanner (knip/orm-doctor/medusa absent, EXEC probes off) can show all-green while
# almost nothing actually EXECUTED against the real project. This gate reads the real per-gate reports in
# walteur-kit/ and measures, on THIS run, how many applicable gates EXECUTED+observed (re-ran a command /
# ran a tool / observed an exit) vs how many merely SHAPE-READ a self-written JSON. It loud-reports the
# ratio so "all-green but nothing ran" can't pass silently, and FAILs when the ratio is below a floor.
#
# An applicable gate = ANY report with a recognized verdict — PASS, FAIL, SKIP, or NOT_APPLICABLE (S033
# robustness fix: SKIP/NOT_APPLICABLE used to be EXCLUDED from the denominator entirely, which let
# tool-absent SKIPs inflate the ratio instead of denting it — a toolless box looked MORE executed, not
# less. Now every recognized-verdict report counts toward applicable, and SKIP/NOT_APPLICABLE reports are
# counted as unexecuted by construction (they cannot carry an execution marker) and tallied separately as
# skipped_count. EXECUTED = the report carries a marker a gate sets ONLY after a REAL computation/
# observation: cross_tenant_probe_executed, erasure_probe_executed, pipeline_probe_executed, knip_exit,
# orm_doctor_exit, medusa_exit, observed_exit, scan_executed:true (secret-rotation's active perl
# committed-secret scan — only written on the PASS/FAIL path the scan actually reached), or a reason
# that says it OBSERVED/RE-RAN. This is a PRECISE allow-list, not a blanket "any *_executed": a pure
# shape gate (which only re-reads its own self-written JSON) must never be counted. FRESHNESS (S033): a
# report whose .ts is older than WALTEUR_EXECRATIO_MAXAGE hours (default 72) does NOT count as executed
# even if it carries an execution marker — a stale execution isn't proof about THIS run. A report with no
# .ts at all is not hard-failed (legacy reports predate this field); it is tallied as stale_unexecuted
# instead of executed, same as a genuinely-stale one.
#
# CONTRACT: executed/applicable * 100 < floor_pct => FAIL exit 2 · executed < floor_count => FAIL exit 2 ·
#   skipped_count > WALTEUR_EXECRATIO_MAXSKIP (default 10, a cannot_measure budget) => FAIL exit 2 · else
#   PASS (always loud-reports the ratio) · no reports => NOT_APPLICABLE · PAUSED => exit 2 · bypass
#   WALTEUR_EXECRATIO=off.
#   PERCENTAGE FLOOR: an explicit WALTEUR_EXECRATIO_MIN always wins over the auto floor_pct (default 0).
#   COUNT FLOOR (S033): an explicit WALTEUR_EXECRATIO_MINCOUNT always wins. When UNSET, the floor is
#   BUILD-CLASS-AWARE (S024, raised in S033 from 1 to 3 — the panel killer was "1 genuine probe + 60
#   shape-read PASSes clears the floor"): a CODE build (build-contract.json build_class in
#   software|data-ai|cloud-iac|mixed) auto-arms floor_count=3, so it must EXECUTE at least 3 real probes.
#   A doc/content/unknown build OR no build-contract stays at floor_count=0 (detect-or-report) — a build
#   with legitimately no executors is never false-failed. Report records floor_pct + floor_count +
#   floor_source + skipped_count + cannot_measure_max + stale_unexecuted_count.
#   Report: walteur-kit/execution-ratio-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "execution-ratio-gate - META gate (S008 robustness fix)."
  printf '%s\n' "usage: bash execution-ratio-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/execution-ratio-report.json - fix recipes: walteur-kit/REMEDIATION.md (## execution-ratio-gate)"
  printf '%s\n' "bypass: WALTEUR_EXECRATIO=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/execution-ratio-report.json"
MIN="${WALTEUR_EXECRATIO_MIN:-0}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
write_report() { v="$1"; r="$2"; ex="${3-}"; [ -n "$ex" ] || ex='{}'; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson ex "$ex" '{verdict:$v, ts:$ts, gate:"execution-ratio", reason:$r} + $ex' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","reason":"%s"}\n' "$v" "$r" > "$REPORT" 2>/dev/null || true; }

# a report counts as EXECUTED if it carries a marker a gate sets ONLY after running a REAL
# computation/observation against the project. This is a PRECISE allow-list, NOT a blanket
# "any *_executed" — a shape gate must not be able to trivially set a recognized key.
#   scan_executed       — secret-rotation-gate sets it true ONLY on the PASS/FAIL path, which is
#                         reached only after the active perl committed-secret scan ran over the tree
#                         (perl-absent SKIPs earlier, before the marker is written). Genuine execution.
# NOT recognized (deliberately): a SHAPE-READ test-layer-coverage report. It self-declares
#   test_layers_executed:false / layers_reran:0 because it only re-read its self-written
#   test-coverage.json manifest (it never re-ran the commands). is_executed() SHORT-CIRCUITS such a
#   report to NOT-executed BEFORE the reason regex, so the remediation hint "...to re-run" in its
#   reason cannot be mistaken for genuine execution (the loose `re-run` alternative used to collide
#   with that hint and over-count by 1). A GENUINE test-layer EXEC run (WALTEUR_TEST_LAYERS_EXEC=1)
#   emits "RE-RAN N test layer(s); OBSERVED expected exit on N/N" with test_layers_executed:true and
#   layers_reran>0 — it actually re-ran the commands and observed their exits, so it IS recognized
#   (via RE-RAN, which the case-insensitive match already covers — no lowercase re-ran/re-run needed).
has_exec_marker() {
  jq -e '
    # Honor a report that self-declares non-execution: a shape-read carries test_layers_executed:false
    # (or layers_reran:0). Short-circuit it to NOT-executed before the reason regex can match a hint.
    if (.test_layers_executed == false) or (.layers_reran == 0) then false
    else
      ((.cross_tenant_probe_executed // .erasure_probe_executed // .pipeline_probe_executed
        // .knip_exit // .orm_doctor_exit // .medusa_exit // .observed_exit) != null)
      or (.scan_executed == true)
      or ((.reason // "") | test("OBSERVED by execution|RE-RAN|reproduced"; "i"))
    end
  ' "$1" >/dev/null 2>&1
}

# FRESHNESS (S033): a report is STALE if it has a .ts and that ts is older than MAXAGE hours. A report
# with NO .ts at all is treated as "no timestamp to prove freshness" — not hard-failed (legacy reports
# predate this field) but not counted as a fresh execution either; caller tallies it as stale_unexecuted.
# has_ts()/is_fresh() are split so main() can tell "no ts" apart from "old ts" for accurate tallying.
has_ts() { jq -e '(.ts // empty) != ""' "$1" >/dev/null 2>&1; }
is_fresh() {
  local maxage="$2"
  jq -e --arg maxage "$maxage" '
    (.ts // empty) as $t | if ($t // "") == "" then false else
      (($t | fromdateiso8601) as $rt |
       (now - $rt) <= (($maxage|tonumber) * 3600))
    end
  ' "$1" >/dev/null 2>&1
}
# is_executed: a genuine execution marker AND (no ts field OR ts is fresh). A stale ts demotes an
# otherwise-executed report to not-executed — a stale execution is not proof about THIS run.
is_executed() {
  local maxage="$2"
  has_exec_marker "$1" || return 1
  has_ts "$1" || return 0
  is_fresh "$1" "$maxage"
}

main() {
  [ -f "$KIT/PAUSED" ] && { write_report FAIL paused; echo "execution-ratio-gate: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_EXECRATIO:-}" = "off" ] && { write_report SKIP "bypassed via WALTEUR_EXECRATIO=off"; echo "execution-ratio-gate: SKIP (bypass)" >&2; exit 0; }
  if ! have jq; then write_report SKIP "jq not installed"; echo "execution-ratio-gate: SKIP (no jq)" >&2; exit 0; fi

  local MAXAGE="${WALTEUR_EXECRATIO_MAXAGE:-72}"
  local MAXSKIP="${WALTEUR_EXECRATIO_MAXSKIP:-10}"

  # Build-class-aware AUTO-FLOORS (S024, count floor raised in S033). An explicit WALTEUR_EXECRATIO_MIN
  # always wins for the PERCENTAGE floor; an explicit WALTEUR_EXECRATIO_MINCOUNT always wins for the
  # absolute COUNT floor. When MINCOUNT is UNSET, a CODE build_class must execute >=3 real probes (raised
  # from the S024 floor of 1 — "one genuine probe clears an entire code build" was the panel killer) so a
  # code build with too few real executions FAILs even at a high percentage. Doc/content/unknown/no-contract
  # stays at count-floor 0 (no false-fail).
  local floor_src="explicit"
  if [ -z "${WALTEUR_EXECRATIO_MIN:-}" ]; then
    floor_src="default(detect-or-report)"
  fi
  local count_floor_src="explicit"
  local MINCOUNT="${WALTEUR_EXECRATIO_MINCOUNT:-0}"
  if [ -z "${WALTEUR_EXECRATIO_MINCOUNT:-}" ]; then
    count_floor_src="default(detect-or-report)"
    if [ "$MINCOUNT" -eq 0 ] && [ -f "$KIT/build-contract.json" ]; then
      _bc="$(jq -r '.build_class // empty' "$KIT/build-contract.json" 2>/dev/null || true)"
      case "$_bc" in software|data-ai|cloud-iac|mixed) MINCOUNT=3; count_floor_src="code-build($_bc) auto-floor" ;; esac
    fi
  fi
  # legacy floor_source field mirrors whichever floor is armed (count floor takes narrative precedence
  # when it is the code-build auto-floor, matching the pre-S033 field consumers expect on code builds).
  case "$count_floor_src" in code-build*) floor_src="$count_floor_src" ;; esac

  local applicable=0 executed=0 skipped=0 stale_unexecuted=0 r v
  for r in "$KIT"/*-report.json; do
    [ -f "$r" ] || continue
    case "$(basename "$r")" in execution-ratio-report.json|gate-suite-report.json) continue ;; esac
    jq -e . "$r" >/dev/null 2>&1 || continue
    v="$(jq -r '.verdict // ""' "$r" 2>/dev/null)"
    case "$v" in
      PASS|FAIL)
        applicable=$((applicable+1))
        if is_executed "$r" "$MAXAGE"; then
          executed=$((executed+1))
        elif has_exec_marker "$r" && has_ts "$r"; then
          # carried a real marker but the ts is stale -> counted as unexecuted, tallied separately
          stale_unexecuted=$((stale_unexecuted+1))
        fi
        ;;
      SKIP|NOT_APPLICABLE)
        # S033: SKIP/NOT_APPLICABLE now count toward the denominator as unexecuted (previously excluded).
        applicable=$((applicable+1)); skipped=$((skipped+1)) ;;
    esac
  done

  if [ "$applicable" -eq 0 ]; then
    write_report NOT_APPLICABLE "no applicable gate reports on disk yet"
    echo "execution-ratio-gate: NOT_APPLICABLE (no reports)" >&2; exit 0
  fi

  # cannot_measure budget: too many tool-absent SKIPs must not let a toolless box look MORE executed.
  if [ "$skipped" -gt "$MAXSKIP" ]; then
    jq -n --arg ts "$TS" --argjson e "$executed" --argjson a "$applicable" --argjson sk "$skipped" \
      --argjson cap "$MAXSKIP" --argjson su "$stale_unexecuted" \
      '{verdict:"FAIL", ts:$ts, gate:"execution-ratio", reason:("skipped_count \($sk) exceeds cannot_measure budget \($cap) — too many tool-absent/inapplicable gates; a toolless box must not look more executed. acquire the backing tools"), executed:$e, applicable:$a, skipped_count:$sk, cannot_measure_max:$cap, stale_unexecuted_count:$su}' \
      > "$REPORT" 2>/dev/null || write_report FAIL "skip budget exceeded: $skipped > $MAXSKIP"
    echo "execution-ratio-gate: FAIL — skipped_count $skipped exceeds cannot_measure budget $MAXSKIP -> exit 2" >&2; exit 2
  fi

  local pct=$(( executed * 100 / applicable ))
  if [ "$pct" -lt "$MIN" ]; then
    jq -n --arg ts "$TS" --argjson e "$executed" --argjson a "$applicable" --argjson p "$pct" --argjson m "$MIN" --arg fs "$floor_src" \
      --argjson sk "$skipped" --argjson cap "$MAXSKIP" --argjson su "$stale_unexecuted" --argjson mc "$MINCOUNT" \
      '{verdict:"FAIL", ts:$ts, gate:"execution-ratio", reason:("only \($e)/\($a) applicable gates EXECUTED+observed (\($p)% < floor \($m)%) — most are shape-reads; acquire the backing tools / arm the EXEC probes"), executed:$e, applicable:$a, executed_pct:$p, floor_pct:$m, floor_source:$fs, skipped_count:$sk, cannot_measure_max:$cap, stale_unexecuted_count:$su, floor_count:$mc}' \
      > "$REPORT" 2>/dev/null || write_report FAIL "execution ratio $pct% < floor $MIN%"
    echo "execution-ratio-gate: FAIL — executed $executed/$applicable ($pct% < $MIN%) -> exit 2" >&2; exit 2
  fi
  if [ "$executed" -lt "$MINCOUNT" ]; then
    jq -n --arg ts "$TS" --argjson e "$executed" --argjson a "$applicable" --argjson p "$pct" --argjson mc "$MINCOUNT" --arg fs "$count_floor_src" \
      --argjson sk "$skipped" --argjson cap "$MAXSKIP" --argjson su "$stale_unexecuted" --argjson m "$MIN" \
      '{verdict:"FAIL", ts:$ts, gate:"execution-ratio", reason:("only \($e) gate(s) EXECUTED+observed, below the count floor of \($mc) — a code build needs \($mc) genuinely-executed gates, not shape-reads"), executed:$e, applicable:$a, executed_pct:$p, floor_pct:$m, floor_count:$mc, floor_source:$fs, skipped_count:$sk, cannot_measure_max:$cap, stale_unexecuted_count:$su}' \
      > "$REPORT" 2>/dev/null || write_report FAIL "executed count $executed < floor $MINCOUNT"
    echo "execution-ratio-gate: FAIL — executed count $executed < floor $MINCOUNT ($count_floor_src) -> exit 2" >&2; exit 2
  fi
  jq -n --arg ts "$TS" --argjson e "$executed" --argjson a "$applicable" --argjson p "$pct" --argjson m "$MIN" --arg fs "$floor_src" \
    --argjson sk "$skipped" --argjson cap "$MAXSKIP" --argjson su "$stale_unexecuted" --argjson mc "$MINCOUNT" \
    '{verdict:"PASS", ts:$ts, gate:"execution-ratio", reason:("\($e)/\($a) applicable gates EXECUTED+observed (\($p)% >= floor \($m)%, count \($e) >= floor \($mc))"), executed:$e, applicable:$a, executed_pct:$p, floor_pct:$m, floor_count:$mc, floor_source:$fs, skipped_count:$sk, cannot_measure_max:$cap, stale_unexecuted_count:$su}' \
    > "$REPORT" 2>/dev/null || write_report PASS "execution ratio $pct% >= floor $MIN%"
  echo "execution-ratio-gate: PASS — executed $executed/$applicable ($pct% >= $MIN%, count $executed >= $MINCOUNT)" >&2; exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "execution-ratio selftest SKIP — need jq."; return 0; fi
  echo "execution-ratio-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  # seed synthetic per-gate reports: $2=#executed $3=#shaperead $4=#skip
  seed() {
    mkdir -p "$1/walteur-kit"; local i
    for ((i=1; i<=${2:-0}; i++)); do jq -n '{verdict:"PASS", observed_exit:0}' > "$1/walteur-kit/exec$i-report.json"; done
    for ((i=1; i<=${3:-0}; i++)); do jq -n '{verdict:"PASS", reason:"shape ok"}' > "$1/walteur-kit/shape$i-report.json"; done
    for ((i=1; i<=${4:-0}; i++)); do jq -n '{verdict:"SKIP", reason:"tool absent"}' > "$1/walteur-kit/skip$i-report.json"; done
  }

  # 1. no reports -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no reports -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. 2 executed + 1 shape-read, floor 50 -> ratio 66% >= 50 -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 2 1 0; WALTEUR_EXECRATIO_MIN=50 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "66% >= floor 50 -> PASS" 0 "$?"
  jq -e '.executed==2 and .applicable==3 and .executed_pct==66' "$t/walteur-kit/execution-ratio-report.json" >/dev/null 2>&1; ck "report records 2/3 = 66%" 0 "$?"; rm -rf "$t"
  # 3. 0 executed + 3 shape-read, floor 50 -> 0% < 50 -> FAIL (the 'all-green but nothing ran' catch)
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 0 3 0; WALTEUR_EXECRATIO_MIN=50 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "0% < floor 50 -> FAIL" 2 "$?"; rm -rf "$t"
  # 4. default floor 0 -> PASS (detect-or-report, non-blocking until armed)
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 0 3 0; ck "default floor 0 -> PASS (reports ratio)" 0 "$(run "$t")"; rm -rf "$t"
  # 5. S033: SKIP reports now COUNT toward the denominator as unexecuted (previously excluded, which let
  #    tool-absent SKIPs inflate the ratio). 1 executed + 2 skip, floor 50 -> applicable=3, executed=1,
  #    33% < 50 -> FAIL. This is the exact inversion the S033 spec requires (was PASS pre-fix).
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 1 0 2; WALTEUR_EXECRATIO_MIN=50 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "skip reports now counted in denominator (1/3=33%) -> FAIL" 2 "$?"
  jq -e '.skipped_count==2 and .applicable==3 and .executed==1' "$t/walteur-kit/execution-ratio-report.json" >/dev/null 2>&1; ck "report records skipped_count:2, applicable:3" 0 "$?"; rm -rf "$t"
  # 5b. Same shape but a floor low enough that the diluted ratio still clears it -> PASS, proving SKIP
  #     reports are counted (not just excluded) rather than causing an unconditional FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 1 0 2; WALTEUR_EXECRATIO_MIN=10 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "skip-diluted ratio (1/3=33%) still clears a low floor -> PASS" 0 "$?"; rm -rf "$t"
  # 6. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 0 3 0; WALTEUR_EXECRATIO=off WALTEUR_EXECRATIO_MIN=50 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 1 0 0; mkdir -p "$t/walteur-kit"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # 7. scan_executed twins (broadened recognition). One genuine secret-rotation-shaped report carrying
  #    scan_executed:true MUST count as executed; a PURE SHAPE report MUST NOT — proving the broadening
  #    recognizes real execution without admitting a shape-read.
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; mkdir -p "$t/walteur-kit"
  jq -n '{verdict:"PASS", gate:"secret-rotation-gate", reason:"managed + fresh; static scan EXECUTED", scan_executed:true}' > "$t/walteur-kit/secret-rotation-report.json"   # (a) genuine execution marker
  jq -n '{verdict:"PASS", reason:"shape ok"}' > "$t/walteur-kit/shape1-report.json"                                                                                       # (b) pure shape-read
  WALTEUR_EXECRATIO_MIN=50 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "scan_executed counts, shape excluded (1/2=50%) -> PASS" 0 "$?"
  jq -e '.executed==1 and .applicable==2 and .executed_pct==50' "$t/walteur-kit/execution-ratio-report.json" >/dev/null 2>&1; ck "(a) scan_executed counted AND (b) shape NOT counted -> 1/2" 0 "$?"; rm -rf "$t"
  # 7c. NEGATIVE CONTROL — a PURE SHAPE report alone is 0% executed: with floor 50 it FAILs, proving a
  #     shape-read is still excluded even after the broadening. scan_executed:false must also not count.
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; mkdir -p "$t/walteur-kit"
  jq -n '{verdict:"PASS", reason:"shape ok"}' > "$t/walteur-kit/shape1-report.json"
  jq -n '{verdict:"PASS", reason:"scan not run", scan_executed:false}' > "$t/walteur-kit/secret-rotation-report.json"   # false must NOT count
  WALTEUR_EXECRATIO_MIN=50 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "pure shape (+scan_executed:false) is 0% -> FAIL (shape-read excluded)" 2 "$?"
  jq -e '.executed==0 and .applicable==2' "$t/walteur-kit/execution-ratio-report.json" >/dev/null 2>&1; ck "shape-read + scan_executed:false counted as 0 executed" 0 "$?"; rm -rf "$t"

  # 8. NEGATIVE CONTROL — test-layer-coverage SHAPE-READ must NOT count. The shape-read reason carries
  #    the remediation hint "...to re-run", which used to collide with the loose `re-run` regex
  #    alternative and over-count by 1. The report self-declares test_layers_executed:false /
  #    layers_reran:0 (it re-ran nothing); is_executed() must short-circuit it to 0 executed.
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; mkdir -p "$t/walteur-kit"
  jq -n '{verdict:"PASS", gate:"test-layer-coverage", reason:"all required test layers present with recorded exit 0 (shape-read; set WALTEUR_TEST_LAYERS_EXEC=1 to re-run)", test_layers_executed:false, layers_reran:0}' > "$t/walteur-kit/test-layer-coverage-report.json"
  jq -n '{verdict:"PASS", observed_exit:0}' > "$t/walteur-kit/exec1-report.json"   # one genuine exec so applicable=2
  WALTEUR_EXECRATIO_MIN=50 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "test-layer SHAPE-READ ('to re-run' hint) NOT counted (1/2=50%) -> PASS" 0 "$?"
  jq -e '.executed==1 and .applicable==2' "$t/walteur-kit/execution-ratio-report.json" >/dev/null 2>&1; ck "shape-read test-layer report counted as 0 executed (only genuine exec1 counts)" 0 "$?"; rm -rf "$t"
  # 8b. POSITIVE CONTROL — a GENUINE test-layer EXEC report (RE-RAN ... OBSERVED, test_layers_executed:true,
  #     layers_reran>0) MUST still count, proving the tightening didn't break real execution recognition.
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; mkdir -p "$t/walteur-kit"
  jq -n '{verdict:"PASS", gate:"test-layer-coverage", reason:"RE-RAN 3 test layer(s); OBSERVED expected exit on 3/3", test_layers_executed:true, layers_reran:3, layers_reran_pass:3}' > "$t/walteur-kit/test-layer-coverage-report.json"
  WALTEUR_EXECRATIO_MIN=50 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "genuine test-layer RE-RAN still counts (1/1=100%) -> PASS" 0 "$?"
  jq -e '.executed==1 and .applicable==1' "$t/walteur-kit/execution-ratio-report.json" >/dev/null 2>&1; ck "genuine RE-RAN+OBSERVED counted as executed" 0 "$?"; rm -rf "$t"

  # ── S024 BUILD-CLASS AUTO-FLOOR (the robustness-killer fix) ──────────────────────────────────────
  # runU = hermetic runner with WALTEUR_EXECRATIO_MIN explicitly UNSET, so the auto-floor path is exercised
  # regardless of the ambient env. bc() seeds a build-contract with a given build_class.
  runU() { ( unset WALTEUR_EXECRATIO_MIN; WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1 ); echo $?; }
  bc() { printf '{"id":"svc","build_class":"%s"}\n' "$2" > "$1/walteur-kit/build-contract.json"; }
  # 9. CODE build + 0 executed (only shape-reads) + NO explicit count floor -> auto-floor=3 -> FAIL (the killer caught).
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 0 3 0; bc "$t" software; ck "code build + 0 executed (auto-floor) -> FAIL" 2 "$(runU "$t")"
  jq -e '.floor_count==3 and (.floor_source|startswith("code-build"))' "$t/walteur-kit/execution-ratio-report.json" >/dev/null 2>&1; ck "report records auto-floor=3 + floor_source code-build" 0 "$?"; rm -rf "$t"
  # 9b. S033 NEGATIVE CONTROL — code build + 2 executed (below the raised floor of 3) -> still FAIL. Proves
  #     the S024 floor of 1 (which this exact shape used to PASS) is no longer sufficient.
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 2 3 0; bc "$t" software; ck "code build + 2 executed (< floor 3) -> FAIL" 2 "$(runU "$t")"; rm -rf "$t"
  # 10. CODE build + >=3 executed -> PASS (floor 3 demands 3 genuinely-executed gates).
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 3 3 0; bc "$t" data-ai; ck "code build + 3 executed (>= floor 3) -> PASS" 0 "$(runU "$t")"; rm -rf "$t"
  # 11. NO FALSE-FAIL: a DOC build with 0 executed is NOT armed -> PASS (count floor stays 0).
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 0 3 0; bc "$t" doc-deliverable; ck "doc build + 0 executed -> PASS (not armed)" 0 "$(runU "$t")"; rm -rf "$t"
  # 12. NO FALSE-FAIL: no build-contract at all + 0 executed -> PASS (conservative; absence is not a code signal).
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 0 3 0; ck "no contract + 0 executed -> PASS (conservative)" 0 "$(runU "$t")"; rm -rf "$t"
  # 13. EXPLICIT count floor ALWAYS wins: explicit MINCOUNT=0 on a code build with 0 executed -> PASS (override beats auto-floor).
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 0 3 0; bc "$t" software; WALTEUR_EXECRATIO_MINCOUNT=0 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "explicit MINCOUNT=0 overrides auto-floor on code build -> PASS" 0 "$?"; rm -rf "$t"

  # ── S033: cannot_measure SKIP budget ──────────────────────────────────────────────────────────────
  # 14. skip-flood: 11 SKIP reports (> default MAXSKIP=10) + 1 executed -> FAIL, even though the executed
  #     count and percentage would otherwise pass; a toolless box must not look MORE executed.
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 1 0 11; ck "skip-flood (11 > MAXSKIP 10) -> FAIL" 2 "$(run "$t")"
  jq -e '.skipped_count==11 and .cannot_measure_max==10' "$t/walteur-kit/execution-ratio-report.json" >/dev/null 2>&1; ck "report records skipped_count:11 > cannot_measure_max:10" 0 "$?"; rm -rf "$t"
  # 15. at the budget exactly (10 skips) -> does not trip the skip-flood FAIL (only percentage/count floors apply).
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 1 0 10; ck "skip_count==MAXSKIP (10) does not trip skip-flood -> PASS (floor 0 default)" 0 "$(run "$t")"; rm -rf "$t"
  # 16. custom budget via WALTEUR_EXECRATIO_MAXSKIP: 3 skips with MAXSKIP=2 -> FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; seed "$t" 1 0 3; WALTEUR_EXECRATIO_MAXSKIP=2 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "custom MAXSKIP=2 with 3 skips -> FAIL" 2 "$?"; rm -rf "$t"

  # ── S033: freshness (ts staleness demotes a marker-carrying report to unexecuted) ────────────────
  # 17. stale ts (100h old, default MAXAGE=72h) on an otherwise-genuine executed report -> NOT counted as
  #     executed; tallied as stale_unexecuted. floor 50 with only the stale report -> FAIL (0% executed).
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; mkdir -p "$t/walteur-kit"
  stale_ts="$(date -u -d '100 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-100H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  jq -n --arg ts "$stale_ts" '{verdict:"PASS", observed_exit:0, ts:$ts}' > "$t/walteur-kit/exec1-report.json"
  WALTEUR_EXECRATIO_MIN=50 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "stale ts (100h > MAXAGE 72h) marker NOT counted -> FAIL (0%)" 2 "$?"
  jq -e '.executed==0 and .stale_unexecuted_count==1' "$t/walteur-kit/execution-ratio-report.json" >/dev/null 2>&1; ck "report records executed:0, stale_unexecuted_count:1" 0 "$?"; rm -rf "$t"
  # 18. POSITIVE CONTROL — fresh ts (1h old) on the same shape of report -> counted as executed -> PASS.
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; mkdir -p "$t/walteur-kit"
  fresh_ts="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  jq -n --arg ts "$fresh_ts" '{verdict:"PASS", observed_exit:0, ts:$ts}' > "$t/walteur-kit/exec1-report.json"
  WALTEUR_EXECRATIO_MIN=50 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "fresh ts (1h < MAXAGE 72h) marker counted -> PASS (100%)" 0 "$?"; rm -rf "$t"
  # 19. NO FALSE-FAIL: a legacy report with NO ts field at all (pre-S033 report) is not hard-failed — it is
  #     simply not counted as executed (tallied as stale_unexecuted), same as case 3's plain shape-reads
  #     already prove for markerless reports; here it carries a marker but no ts.
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; mkdir -p "$t/walteur-kit"
  jq -n '{verdict:"PASS", observed_exit:0}' > "$t/walteur-kit/exec1-report.json"   # marker present, no ts
  ck "no-ts legacy report -> PASS at default floor 0 (not hard-failed)" 0 "$(run "$t")"
  jq -e '.executed==1' "$t/walteur-kit/execution-ratio-report.json" >/dev/null 2>&1; ck "no-ts report still counted as executed (legacy leniency, not stale)" 0 "$?"; rm -rf "$t"
  # 20. custom WALTEUR_EXECRATIO_MAXAGE widens the freshness window: the same 100h-stale report from case
  #     17 counts as executed when MAXAGE=200 -> PASS.
  t="$(mktemp -d "${TMPDIR:-/tmp}/executionr.XXXXXX")"; mkdir -p "$t/walteur-kit"
  stale_ts="$(date -u -d '100 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-100H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  jq -n --arg ts "$stale_ts" '{verdict:"PASS", observed_exit:0, ts:$ts}' > "$t/walteur-kit/exec1-report.json"
  WALTEUR_EXECRATIO_MIN=50 WALTEUR_EXECRATIO_MAXAGE=200 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "custom MAXAGE=200 widens window, same report now counts -> PASS" 0 "$?"; rm -rf "$t"

  echo "execution-ratio-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
