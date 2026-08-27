#!/usr/bin/env bash
# WALTEUR gate-suite — META harness (intake: mysticalsin/dotclaude hooks/tests + WALTEUR's own gauntlet).
# WALTEUR's fail-closed gates each carry an embedded --selftest — but nothing ran them ALL as one
# regression suite, so a careless regex/quoting edit could silently flip a gate OPEN and nobody would notice
# until a real build shipped broken. (This session alone caught 4 such silent false-PASS bugs: grep \n matching
# the letter n, an unquoted $PRUNE glob, stat -f mtime, and ${VAR:-{}} brace.) This harness runs every gate's
# --selftest from the registry, asserts each reports N/N, and FAILs closed if any gate's selftest is not green.
# Run it after editing any gate, in CI, and at reflect-stage. It is itself --selftest'd on synthetic gates.
#
# CONTRACT: any registry gate whose --selftest reports X/Y with X<Y (or errors) => FAIL exit 2 · all green or
# legitimately no-selftest/SKIP => PASS · PAUSED => exit 2 · bypass WALTEUR_GATESUITE=off.
# SKIP-BUDGET (anti-"couldn't-measure-reads-as-passed"): a selftest that SKIPs for a MISSING TOOL (jq/perl)
#   is classified cannot_measure (NOT a pass). If cannot_measure > WALTEUR_GATESUITE_MAXCANNOT (default 8)
#   => FAIL exit 2 — a degraded box must not show all-green. And if the aggregator's OWN jq is absent it
#   FAILs closed (exit 2), never self-disables to a silent SKIP.
# Per-gate timeout WALTEUR_GATESUITE_TIMEOUT (default 150s). Report: walteur-kit/gate-suite-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
    printf '%s
' "gate-suite - META harness: runs every registry gate's --selftest as one regression suite, fail-closed with skip-budget + real twin check"
    printf '%s
' "usage: bash gate-suite.sh [--selftest|--help|<default run>]"
    printf '%s
' "report: walteur-kit/gate-suite-report.json - fix recipes: walteur-kit/REMEDIATION.md (## gate-suite)"
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
HOOKS="$KIT/hooks"
REG="$KIT/gate-registry.json"
REPORT="$KIT/gate-suite-report.json"
PTIMEOUT="${WALTEUR_GATESUITE_TIMEOUT:-150}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
to() { if have timeout; then timeout "$PTIMEOUT" "$@"; else "$@"; fi; }

# parse a gate's --selftest output -> "green" | "fail:X/Y" | "noselftest" | "skip" | "cannot_measure"
run_one() {
  local hook="$1" out line
  [ -f "$HOOKS/$hook" ] || { echo "missing"; return; }
  ! bash -n "$HOOKS/$hook" 2>/dev/null && { echo "syntax"; return; }
  # </dev/null is LOAD-BEARING: run_one is called from a `while read` loop whose stdin IS the registry stream.
  # A gate whose --selftest reads stdin (cat/read/jq with no file arg) would otherwise drain the rest of the
  # registry — those gates are then never run, never counted, and the suite still returns a verdict (fail-open).
  out="$(WALTEUR_ROOT="$ROOT" to bash "$HOOKS/$hook" --selftest </dev/null 2>&1)"
  line="$(printf '%s' "$out" | grep -oiE '[0-9]+/[0-9]+ passed' | tail -1)"
  if [ -z "$line" ]; then
    # a TOOL-MISSING skip is NOT a pass — classify it cannot_measure so the skip-budget can catch it
    printf '%s' "$out" | grep -qiE 'no jq|need (jq|perl|jq\+perl)|not installed|need jq' && { echo "cannot_measure"; return; }
    printf '%s' "$out" | grep -qiE 'selftest (SKIP|skip)' && { echo "skip"; return; }
    echo "noselftest"; return
  fi
  local num den; num="${line%%/*}"; den="$(printf '%s' "$line" | sed -E 's#^[0-9]+/([0-9]+).*#\1#')"
  if [ "$num" = "$den" ] && [ "$den" -gt 0 ]; then echo "green"; else echo "fail:$line"; fi
}

# REAL-RUN twin check (NOT a --selftest, NOT a shape-read): actually runs twin-invariant in HARD mode against
# the two REAL canonical trees (Pro Coding/walteur-kit <-> walteur-starter/walteur-kit), cmp'ing every shared
# hook byte-for-byte. A live HOOK drift => exit 2 here => the suite FAILs. The doc-twin (SKILL.md vs
# WALTEUR-builder-CLAUDE.md) is a KNOWN, intentionally-allowed drift, so we scope the BLOCKING check to HOOK
# twins via WALTEUR_TWIN_SCOPE=hooks — the doc-twin is still checked + recorded, just never reds the suite.
# Returns: "green" (hooks identical) | "fail:<n>" (real hook drift/missing) | "skip:<why>" (twin surface
# absent — recorded, not green) | "cannot_measure:<why>" (twin tool missing -> fail-closed at the caller).
TWIN="$KIT/eval/twin-invariant.sh"
run_twin_real() {
  [ -f "$TWIN" ] || { echo "cannot_measure:twin-invariant.sh absent at $TWIN"; return; }
  ! bash -n "$TWIN" 2>/dev/null && { echo "cannot_measure:twin-invariant.sh syntax"; return; }
  local rep="$KIT/twin-invariant-report.json" rc
  # GENUINE execution: real cross-kit run (no --selftest), HARD blocking, scoped to HOOK twins.
  WALTEUR_ROOT="$ROOT" WALTEUR_TWIN=hard WALTEUR_TWIN_SCOPE=hooks to bash "$TWIN" >/dev/null 2>&1
  rc=$?
  # Bypassed at the tool (WALTEUR_TWIN=off) => exit 0 with no report change; treat as a recorded skip.
  if [ "${WALTEUR_TWIN:-}" = "off" ]; then echo "skip:twin bypassed via WALTEUR_TWIN=off"; return; fi
  if [ "$rc" -eq 2 ]; then
    local d m
    d="$(jq -r '.drift // 0' "$rep" 2>/dev/null || echo 0)"; m="$(jq -r '.missing // 0' "$rep" 2>/dev/null || echo 0)"
    echo "fail:${d:-?}drift+${m:-?}missing"; return
  fi
  if [ "$rc" -ne 0 ]; then echo "cannot_measure:twin run rc=$rc (unexpected)"; return; fi
  # rc==0: PASS. But "couldn't measure" (a wholly-absent twin surface) is NOT a green — read the report and
  # classify a fully-skipped distribution surface as skip (recorded), a real evaluation as green.
  if [ -f "$rep" ] && have jq; then
    local checked; checked="$(jq -r '.checked // 0' "$rep" 2>/dev/null || echo 0)"
    if [ "${checked:-0}" -le 1 ]; then echo "skip:twin surface absent (checked=$checked — starter tree not present)"; return; fi
    echo "green"; return
  fi
  echo "skip:twin ran rc=0 but no readable report"
}

main() {
  [ -f "$KIT/PAUSED" ] && { echo "gate-suite: PAUSED -> exit 2"; printf '{"verdict":"FAIL","reason":"paused"}\n' > "$REPORT"; exit 2; }
  [ "${WALTEUR_GATESUITE:-}" = "off" ] && { echo "gate-suite: bypassed"; printf '{"verdict":"SKIP"}\n' > "$REPORT"; exit 0; }
  # FAIL-CLOSED: the aggregator's own jq missing means it cannot measure the suite — couldn't-measure != passed.
  if ! have jq; then echo "gate-suite: FAIL — jq absent; aggregator cannot measure the suite (fail-closed, never a silent SKIP) -> exit 2"; printf '{"verdict":"FAIL","reason":"jq absent — aggregator cannot self-disable silently"}\n' > "$REPORT" 2>/dev/null || true; exit 2; fi
  [ -f "$REG" ] || { echo "gate-suite: NOT_APPLICABLE (no registry)"; printf '{"verdict":"NOT_APPLICABLE"}\n' > "$REPORT"; exit 0; }

  local MAXCANNOT="${WALTEUR_GATESUITE_MAXCANNOT:-8}"
  local total=0 green=0 skip=0 nost=0 cantmeasure=0 broken='[]' hook res
  # tr -d '\r' on the registry stream: a native-Windows jq writes stdout in TEXT mode (CRLF) and `read -r` keeps
  # the CR, so every hook name arrived as "<gate>.sh\r", failed [ -f ], and the whole registry read as "missing".
  while IFS= read -r hook; do
    [ -n "$hook" ] || continue
    total=$((total+1)); res="$(run_one "$hook")"
    case "$res" in
      green) green=$((green+1)) ;;
      skip) skip=$((skip+1)) ;;
      cannot_measure) cantmeasure=$((cantmeasure+1)) ;;
      noselftest) nost=$((nost+1)) ;;
      *) broken="$(printf '%s' "$broken" | jq --arg h "$hook" --arg r "$res" '. + [{gate:$h, result:$r}]')" ;;
    esac
  done < <(jq -r '.gates[].hook' "$REG" 2>/dev/null | tr -d '\r' | sort -u)

  # FAIL-CLOSED: a registry that EXISTS but yields ZERO gates (corrupt JSON / renamed schema — jq's parse error
  # is swallowed by the 2>/dev/null above) measured nothing, and "0/0 green" would silently disarm every gate.
  # Couldn't-measure != passed. (A genuinely absent registry is NOT_APPLICABLE and returned earlier.)
  if [ "$total" -eq 0 ]; then
    echo "gate-suite: FAIL — registry present at $REG but yielded 0 gates (corrupt JSON or schema drift); refusing to report 0/0 as green -> exit 2"
    printf '{"verdict":"FAIL","reason":"registry present but yielded 0 gates — aggregator measured nothing"}\n' > "$REPORT"
    exit 2
  fi

  # REAL-RUN twin guard: a live HOOK drift between the two canonical kits must RED the suite (genuine
  # cross-kit cmp, not a shape-read; doc-twin scoped out as the known allowed drift).
  local twin_res twin_drift_fail=0; twin_res="$(run_twin_real)"
  case "$twin_res" in
    green)               : ;;
    fail:*)              twin_drift_fail=1 ;;
    skip:*)              skip=$((skip+1)) ;;
    cannot_measure:*)    cantmeasure=$((cantmeasure+1)) ;;
  esac

  local nbroken over=0; nbroken="$(printf '%s' "$broken" | jq 'length')"
  [ "$cantmeasure" -gt "$MAXCANNOT" ] && over=1
  jq -n --argjson t "$total" --argjson g "$green" --argjson s "$skip" --argjson n "$nost" --argjson cm "$cantmeasure" \
        --argjson cap "$MAXCANNOT" --argjson b "$broken" --argjson over "$over" --arg ts "$TS" \
        --argjson tdf "$twin_drift_fail" --arg twin "$twin_res" \
    '{verdict:(if ($b|length)>0 or ($over==1) or ($tdf==1) then "FAIL" else "PASS" end), ts:$ts, gate:"gate-suite", total:$t, green:$g, skipped:$s, no_selftest:$n, cannot_measure:$cm, skip_budget:$cap, skip_budget_exceeded:($over==1), twin_hook_drift:($tdf==1), twin_result:$twin, broken:$b}' > "$REPORT" 2>/dev/null

  if [ "$nbroken" -gt 0 ]; then
    echo "gate-suite: FAIL — $nbroken/$total gate selftest(s) NOT green (green=$green skip=$skip cannot_measure=$cantmeasure no-selftest=$nost) -> exit 2"
    printf '%s' "$broken" | jq -r '.[] | "  ✗ " + .gate + " (" + .result + ")"' 2>/dev/null | head -20
    echo "  → how to fix: walteur-kit/REMEDIATION.md  ·  per-gate: bash walteur-kit/hooks/<gate>.sh --help  ·  read walteur-kit/<gate>-report.json"
    exit 2
  fi
  if [ "$twin_drift_fail" -eq 1 ]; then
    echo "gate-suite: FAIL — live HOOK twin drift between the two canonical kits ($twin_res); the two-kit mirror is broken. Re-sync canonical->starter byte-identical (cp + cmp -s). -> exit 2"
    exit 2
  fi
  if [ "$over" -eq 1 ]; then
    echo "gate-suite: FAIL — cannot_measure=$cantmeasure exceeds skip-budget $MAXCANNOT (a degraded env must not show all-green; install jq/perl) -> exit 2"
    exit 2
  fi
  echo "gate-suite: PASS — $green/$total gate selftests green ($skip skip, $cantmeasure cannot_measure<=$MAXCANNOT, $nost no-selftest); twin hooks: $twin_res"
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "gate-suite selftest SKIP - no jq."; return 0; fi
  echo "gate-suite selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  # synthetic gate kit: a passing gate, a SKIP gate, a no-selftest gate, a FAILING gate
  mkkit() { local d="$1"; mkdir -p "$d/walteur-kit/hooks"
    printf '#!/usr/bin/env bash\ncase "${1:-}" in --selftest) echo "good selftest: 3/3 passed"; exit 0;; *) exit 0;; esac\n' > "$d/walteur-kit/hooks/good.sh"
    printf '#!/usr/bin/env bash\ncase "${1:-}" in --selftest) echo "skipgate selftest SKIP - no jq."; exit 0;; *) exit 0;; esac\n' > "$d/walteur-kit/hooks/skipg.sh"
    printf '#!/usr/bin/env bash\ncase "${1:-}" in --selftest) echo "skipgate2 selftest SKIP - need perl."; exit 0;; *) exit 0;; esac\n' > "$d/walteur-kit/hooks/skipg2.sh"
    printf '#!/usr/bin/env bash\necho "i emit no selftest line"; exit 0\n' > "$d/walteur-kit/hooks/nost.sh"
    printf '#!/usr/bin/env bash\ncase "${1:-}" in --selftest) echo "bad selftest: 1/3 passed"; exit 1;; *) exit 0;; esac\n' > "$d/walteur-kit/hooks/bad.sh"
    mktwin "$d" clean   # hermetic twin-invariant stub: exercises the real-run twin path deterministically
  }
  # mktwin installs a hermetic eval/twin-invariant.sh stub so the suite's REAL-RUN twin check is exercised in
  # the synthetic worlds (not classified cannot_measure for a missing tool). $2=clean -> exit 0 + checked=99;
  # $2=drift -> exit 2 + drift=1 (a live hook drift); $2=absent-surface -> exit 0 + checked=1 (twin tree not present).
  mktwin() { local d="$1" kind="$2"; mkdir -p "$d/walteur-kit/eval"
    case "$kind" in
      drift) printf '#!/usr/bin/env bash\nprintf "{\\"verdict\\":\\"DRIFT\\",\\"checked\\":99,\\"drift\\":1,\\"missing\\":0}\\n" > "%s/walteur-kit/twin-invariant-report.json"\nexit 2\n' "$d" > "$d/walteur-kit/eval/twin-invariant.sh" ;;
      absent-surface) printf '#!/usr/bin/env bash\nprintf "{\\"verdict\\":\\"PASS\\",\\"checked\\":1,\\"drift\\":0,\\"missing\\":0}\\n" > "%s/walteur-kit/twin-invariant-report.json"\nexit 0\n' "$d" > "$d/walteur-kit/eval/twin-invariant.sh" ;;
      *) printf '#!/usr/bin/env bash\nprintf "{\\"verdict\\":\\"PASS\\",\\"checked\\":99,\\"drift\\":0,\\"missing\\":0,\\"doc_drift_allowed\\":1}\\n" > "%s/walteur-kit/twin-invariant-report.json"\nexit 0\n' "$d" > "$d/walteur-kit/eval/twin-invariant.sh" ;;
    esac
  }
  reg() { jq -n --argjson g "$1" '{gates: $g}' > "$2/walteur-kit/gate-registry.json"; }

  # 1. all green/skip/no-selftest (no failing gate) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"; reg '[{"hook":"good.sh"},{"hook":"skipg.sh"},{"hook":"nost.sh"}]' "$t"; ck "all green/skip -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 2. a FAILING gate selftest (1/3) -> FAIL exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"; reg '[{"hook":"good.sh"},{"hook":"bad.sh"}]' "$t"; ck "a failing gate selftest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 3. a syntax-broken gate -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"; printf 'if [ \n' > "$t/walteur-kit/hooks/broken.sh"; reg '[{"hook":"good.sh"},{"hook":"broken.sh"}]' "$t"; ck "a syntax-broken gate -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. a missing hook referenced by registry -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"; reg '[{"hook":"good.sh"},{"hook":"ghost.sh"}]' "$t"; ck "a missing registry hook -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. no registry -> NOT_APPLICABLE (exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no registry -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 5b. FAIL-OPEN GUARD: a registry that is PRESENT but unparseable (or zero-gate) measured nothing -> must FAIL
  #     closed. Before this guard it reported "PASS - 0/0 gate selftests green" and silently disarmed all 155 gates.
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"; printf 'not json - schema drift\n' > "$t/walteur-kit/gate-registry.json"
  ck "registry present but 0 gates -> FAIL (no 0/0 false-green)" 2 "$(run "$t")"; rm -rf "$t"
  # 6. SKIP-BUDGET: 2 cannot_measure (tool-missing) gates with budget 1 -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"; reg '[{"hook":"good.sh"},{"hook":"skipg.sh"},{"hook":"skipg2.sh"}]' "$t"
  WALTEUR_ROOT="$t" WALTEUR_GATESUITE_MAXCANNOT=1 bash "$SELF" >/dev/null 2>&1; ck "cannot_measure over budget -> FAIL" 2 "$?"
  jq -e '.cannot_measure==2 and .skip_budget_exceeded==true' "$t/walteur-kit/gate-suite-report.json" >/dev/null 2>&1; ck "report records cannot_measure=2 + budget exceeded" 0 "$?"; rm -rf "$t"
  # 7. SKIP-BUDGET: same 2 cannot_measure gates within budget 5 -> PASS (tool-missing counted, not failed)
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"; reg '[{"hook":"good.sh"},{"hook":"skipg.sh"},{"hook":"skipg2.sh"}]' "$t"
  WALTEUR_ROOT="$t" WALTEUR_GATESUITE_MAXCANNOT=5 bash "$SELF" >/dev/null 2>&1; ck "cannot_measure within budget -> PASS" 0 "$?"; rm -rf "$t"
  # 8. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"; reg '[{"hook":"bad.sh"}]' "$t"; WALTEUR_ROOT="$t" WALTEUR_GATESUITE=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"; reg '[{"hook":"good.sh"}]' "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # 9. REAL-RUN TWIN GUARD: a live HOOK drift (twin stub exits 2) reds the suite even when every gate selftest is green.
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"; mktwin "$t" drift; reg '[{"hook":"good.sh"}]' "$t"; ck "live HOOK twin drift -> suite FAIL" 2 "$(run "$t")"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; jq -e '.verdict=="FAIL" and .twin_hook_drift==true' "$t/walteur-kit/gate-suite-report.json" >/dev/null 2>&1; ck "report records twin_hook_drift=true" 0 "$?"; rm -rf "$t"
  # 10. twin guard does NOT red when hooks are clean (twin stub exits 0, checked>1) -> PASS + twin_hook_drift=false
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"; reg '[{"hook":"good.sh"}]' "$t"; WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  jq -e '.verdict=="PASS" and .twin_hook_drift==false and .twin_result=="green"' "$t/walteur-kit/gate-suite-report.json" >/dev/null 2>&1; ck "clean twins -> PASS + twin green (no false-red)" 0 "$?"; rm -rf "$t"
  # 11. absent twin surface (twin runs but checked<=1: starter tree not present) -> recorded skip, NOT a red.
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"; mktwin "$t" absent-surface; reg '[{"hook":"good.sh"}]' "$t"; ck "absent twin surface -> skip, not red (exit 0)" 0 "$(run "$t")"; rm -rf "$t"
  # 12. STDIN-HOG GUARD: a gate whose --selftest reads stdin must NOT drain the registry stream feeding the loop.
  #     Without the </dev/null in run_one, a-hog.sh (sorts first) ate the two gates behind it and the suite
  #     reported "PASS - 1/1 green" while bad.sh went unmeasured — a fail-open that hid 23 gates on the real tree.
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatesuite.XXXXXX")"; mkkit "$t"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --selftest) cat >/dev/null 2>&1; echo "hog selftest: 1/1 passed"; exit 0;; *) exit 0;; esac\n' > "$t/walteur-kit/hooks/a-hog.sh"
  reg '[{"hook":"a-hog.sh"},{"hook":"good.sh"},{"hook":"bad.sh"}]' "$t"
  ck "stdin-hog gate does not swallow the registry (bad.sh still caught)" 2 "$(run "$t")"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; jq -e '.total==3' "$t/walteur-kit/gate-suite-report.json" >/dev/null 2>&1; ck "all 3 registry gates measured despite stdin hog" 0 "$?"; rm -rf "$t"

  echo "gate-suite selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
