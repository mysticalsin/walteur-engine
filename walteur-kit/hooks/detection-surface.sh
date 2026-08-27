#!/usr/bin/env bash
# walteur-apex detection-surface — measures the TERRITORY, not the map.
#
# THE CRITICISM THIS ANSWERS (adversarial review, verbatim): "Coverage is a per-gate boolean, and that
# overstates protection by close to an order of magnitude at the path level. security-baseline-gate.sh
# emits 7 distinct violation families ... apex's twin exercises exactly one (rls). A gate can be
# 'covered' and blind on ~85% of its detection surface. 25% is 25% of gates touched, not 25% of the
# regression surface guarded."
#
# That was correct, and `eval-coverage-gate.sh` cannot see it: it counts manifest rows. This measures
# the real thing, by execution rather than assertion:
#
#   DECLARED families — statically enumerated from each gate's own `add_finding "<family>"` call sites.
#                       The gate declares its own detection surface; nothing is hand-maintained.
#   EXERCISED families — collected by RUNNING each poisoned fixture through its gate and reading the
#                        `findings[].check` values the gate actually emitted. Observed, not claimed.
#
# The ratio is honest coverage of the regression surface. On the 2026-08-25 suite it is far below the
# 25% gate-level number, which is the point: the metric should embarrass the optimistic one.
#
# CONTRACT: measures and reports => exit 0 · below --min threshold => exit 2 · jq absent => exit 2
#           no manifest => NOT_APPLICABLE exit 0 · PAUSED => exit 2 · bypass WALTEUR_DETSURF=off
#
# --help: self-documentation BEFORE any side effect
case "${1:-}" in
  -h|--help)
    printf '%s\n' "detection-surface - measures exercised/declared finding families per gate, by execution."
    printf '%s\n' "usage: bash detection-surface.sh [--min N] [--selftest|--help]"
    printf '%s\n' "  --min N   fail (exit 2) if overall exercised-family coverage is below N percent"
    printf '%s\n' "report: walteur-kit/eval-harness/detection-surface-report.json"
    printf '%s\n' "bypass: WALTEUR_DETSURF=off (recorded, not free)"
    exit 0 ;;
esac

set -uo pipefail
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
have() { command -v "$1" >/dev/null 2>&1; }
jqr() { jq -r "$@" 2>/dev/null | tr -d '\r'; }

# Statically enumerate a gate's own declared finding families.
#
# THE FIRST VERSION MATCHED ONLY `add_finding "<double-quoted lowercase word>"`, and that narrowness
# was itself a silent cap — the exact defect this tool exists to expose, in this tool. Real gates use
# four shapes, and the ones it could not see were dropped from BOTH sides of the ratio by the
# `ndec -eq 0` guard below, contributing 0/0 and vanishing from the report:
#   add_finding "family"     — the documented shape
#   add_finding 'family'     — same, single-quoted
#   add_finding family       — bare word; test-claim-verifier-gate declares all 7 of its families this
#                              way (paused, unverifiable, runner, danger, guard, noop, test-run) and
#                              scored 0/0 as a result
#   scan "family" / scan_cs "family" — anti-slop-code-gate's idiom, where the scan label IS the family
# Dots and dashes are part of real family names (`playbook.shape`, `test-run`) and were excluded too.
#
# Variable family names stay excluded, deliberately: ci-hardening-gate and structured-output-gate call
# `add_finding "$rel"` — the family is the offending FILE PATH, so the taxonomy is unbounded and no
# fixture could ever be shown to have covered it. Those gates are now reported as UNENUMERABLE with
# that reason rather than silently skipped.
declared_families() {
  {
    sed -nE 's/.*[^A-Za-z0-9_]add_finding[[:space:]]+"([^"$]+)".*/\1/p'  "$1"
    sed -nE "s/.*[^A-Za-z0-9_]add_finding[[:space:]]+'([^'\$]+)'.*/\1/p" "$1"
    sed -nE 's/.*[^A-Za-z0-9_]add_finding[[:space:]]+([A-Za-z][A-Za-z0-9_.-]*).*/\1/p' "$1"
    sed -nE 's/.*[^A-Za-z0-9_]scan(_cs)?[[:space:]]+"([^"$]+)".*/\2/p' "$1"
    sed -nE 's/^add_finding[[:space:]]+([A-Za-z][A-Za-z0-9_.-]*).*/\1/p' "$1"
    sed -nE 's/^scan(_cs)?[[:space:]]+"([^"$]+)".*/\2/p' "$1"
  } 2>/dev/null | grep -v '[$ ]' | sort -u
}

# Turn newline-separated text into a JSON array, ALWAYS emitting valid JSON — `[]` for empty input.
# Under `set -o pipefail` a `grep .` on empty input fails the whole pipeline, so the naive inline form
# yielded an empty string and `jq --argjson` rejected it, killing the report write while the measurement
# itself was correct. Never let a formatting helper fail the thing it is formatting.
to_json_array() {
  local v="${1:-}"
  if [ -z "$(printf '%s' "$v" | tr -d '[:space:]')" ]; then printf '[]'; return 0; fi
  printf '%s\n' "$v" | grep . | jq -R . | jq -cs . 2>/dev/null || printf '[]'
}

main() {
  local MIN=0
  while [ $# -gt 0 ]; do
    case "$1" in --min) MIN="${2:-0}"; shift 2 ;; *) shift ;; esac
  done
  case "$MIN" in ''|*[!0-9]*) MIN=0 ;; esac

  local ROOT KIT EH MAN HOOKS REPORT TS
  ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  KIT="$ROOT/walteur-kit"; EH="$KIT/eval-harness"; HOOKS="$KIT/hooks"
  MAN="$EH/manifest.json"; REPORT="$EH/detection-surface-report.json"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  [ -f "$KIT/PAUSED" ] && { echo "detection-surface: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_DETSURF:-on}" = "off" ] && { echo "detection-surface: bypassed" >&2; exit 0; }
  [ -f "$MAN" ] || { echo "detection-surface: NOT_APPLICABLE (no eval-harness manifest)"; exit 0; }
  have jq || { echo "detection-surface: FAIL - jq absent; cannot measure (fail-closed)" >&2; exit 2; }
  jq -e . "$MAN" >/dev/null 2>&1 || { echo "detection-surface: FAIL - manifest is not valid JSON" >&2; exit 2; }

  # THE DENOMINATOR MUST BE EVERY HARD GATE, NOT ONLY THE FIXTURED ONES.
  # The first version of this tool iterated the manifest, so a gate with no fixture contributed nothing
  # to either side of the ratio — and it published 20% (6/30) when the framework-wide truth was 6/97 =
  # 6%. That is precisely the silent-cap pattern this tool was written to destroy, reproduced inside it.
  # Caught by an adversarial reviewer and confirmed by hand: 31 hard gates use the add_finding idiom and
  # declare 97 distinct families, against 10 fixtured gates declaring 30.
  # Headline `surface_pct` is now framework-wide. `fixtured_surface_pct` keeps the narrower view, which
  # is a fair question ("how deeply are the gates I DO cover, covered?") but is not the headline.
  local REG="$KIT/gate-registry.json"
  all_hard_gates() {
    if [ -f "$REG" ] && have jq; then
      jqr '[.gates[]|select(.hardness=="hard")|.hook]|unique|.[]' "$REG"
    else
      jqr '[.[] | select(.expect=="FAIL") | .gate] | unique | .[]' "$MAN"
    fi
  }
  resolve_gate() { # gates live in walteur-kit/hooks AND .claude/hooks
    if [ -f "$HOOKS/$1" ]; then printf '%s' "$HOOKS/$1"
    elif [ -f "$ROOT/.claude/hooks/$1" ]; then printf '%s' "$ROOT/.claude/hooks/$1"
    fi
  }

  local rows='[]' tot_dec=0 tot_exe=0 fx_dec=0 fx_exe=0 unenumerable=""
  # Only POISONED fixtures can exercise a family — a clean twin is expected to emit nothing.
  while IFS= read -r gate; do
    [ -n "$gate" ] || continue
    local gpath; gpath="$(resolve_gate "$gate")"
    [ -n "$gpath" ] || continue
    local dec; dec="$(declared_families "$gpath")"
    local ndec; ndec="$(printf '%s\n' "$dec" | grep -c . || true)"
    # A gate with no statically-enumerable family is NAMED, not skipped. `continue` alone made five
    # fixtured gates contribute 0/0 and disappear from the report — a silent cap inside the tool built
    # to find silent caps. Two causes, both reported: the gate emits no findings at all, or its family
    # names are computed at runtime (`add_finding "$rel"`) so no finite denominator exists.
    if [ "$ndec" -eq 0 ]; then
      local why="emits-no-findings"
      grep -q 'add_finding[[:space:]]*"\?\$' "$gpath" 2>/dev/null && why="dynamic-family-names"
      unenumerable="$(printf '%s\n%s' "$unenumerable" "$gate ($why)" | grep . || true)"
      rows="$(printf '%s' "$rows" | jq --arg g "$gate" --arg w "$why" \
        '. + [{gate:$g, declared:0, exercised:0, pct:null, enumerable:false, reason:$w, families:[], unexercised:[]}]' \
        2>/dev/null || printf '%s' "$rows")"
      continue
    fi

    local seen=""
    while IFS= read -r fx; do
      [ -n "$fx" ] || continue
      local fxdir="$EH/fixtures/$fx"
      [ -d "$fxdir" ] || continue
      local t; t="$(mktemp -d)"; cp -R "$fxdir/." "$t"/ 2>/dev/null
      local err="$t/.detsurf-stderr"
      WALTEUR_ROOT="$t" bash "$gpath" >"$err" 2>&1
      # Collect exercised families from BOTH surfaces and union them:
      #   (a) the JSON report's findings[].check — the intended machine-readable channel, and
      #   (b) the gate's own console output (stdout AND stderr combined), which follows the framework-wide
      #       "  - <family>: <msg>" shape. Both streams are captured because gates split their output:
      #       the summary line goes to stderr while the per-finding lines go to stdout.
      # (b) is not belt-and-braces: security-baseline-gate.sh writes a report with NO findings array at
      # all (a pre-existing framework bug this folder recorded but does not modify), while printing
      # "- rls: ACTIVE scan ..." to stderr. Reading only the report scored it 0/7 when it had genuinely
      # detected rls — the measurement tool must observe what the gate really did, not what its report
      # format was supposed to say.
      local hit_json hit_err hit
      hit_json="$(find "$t/walteur-kit" -maxdepth 2 -name '*-report.json' 2>/dev/null \
             | while IFS= read -r r; do jqr '.findings[]?.check // empty' "$r"; done | sort -u)"
      # Family names contain dots and dashes (`playbook.shape`, `test-run`); `[a-z0-9_]+` matched a
      # PREFIX of those and then failed to intersect with the declared list, scoring a real hit as a miss.
      hit_err="$(sed -nE 's/^[[:space:]]*-[[:space:]]+([A-Za-z0-9_.#-]+):.*/\1/p' "$err" 2>/dev/null | sort -u)"
      hit="$(printf '%s\n%s\n' "$hit_json" "$hit_err" | grep . | sort -u || true)"
      seen="$(printf '%s\n%s\n' "$seen" "$hit" | grep . | sort -u)"
      rm -rf "$t"
    done < <(jqr --arg g "$gate" '.[] | select(.gate==$g and .expect=="FAIL") | .fixture' "$MAN")

    # Only count families the gate actually declares; a stray check id is not part of its surface.
    local exercised
    exercised="$(comm -12 <(printf '%s\n' "$dec" | sort -u) <(printf '%s\n' "$seen" | grep . | sort -u) 2>/dev/null | grep . || true)"
    local nexe; nexe="$(printf '%s\n' "$exercised" | grep -c . || true)"
    tot_dec=$((tot_dec + ndec)); tot_exe=$((tot_exe + nexe))
    # Track the narrower "among gates that have a fixture" view separately.
    if [ -n "$(jqr --arg g "$gate" '.[] | select(.gate==$g and .expect=="FAIL") | .fixture' "$MAN" | head -1)" ]; then
      fx_dec=$((fx_dec + ndec)); fx_exe=$((fx_exe + nexe))
    fi
    local missed
    missed="$(comm -23 <(printf '%s\n' "$dec" | sort -u) <(printf '%s\n' "$exercised" | grep . | sort -u) 2>/dev/null | grep . || true)"
    rows="$(printf '%s' "$rows" | jq \
      --arg g "$gate" --argjson d "$ndec" --argjson e "$nexe" \
      --argjson dl "$(to_json_array "$dec")" \
      --argjson ms "$(to_json_array "$missed")" \
      '. + [{gate:$g, declared:$d, exercised:$e, pct:(if $d>0 then (($e*100)/$d|floor) else 0 end), enumerable:true, families:$dl, unexercised:$ms}]' 2>/dev/null || printf '%s' "$rows")"
  done < <(all_hard_gates)

  local pct=0 fxpct=0
  [ "$tot_dec" -gt 0 ] && pct=$(( tot_exe * 100 / tot_dec ))
  [ "$fx_dec" -gt 0 ] && fxpct=$(( fx_exe * 100 / fx_dec ))

  jq -n --arg ts "$TS" --argjson p "$pct" --argjson e "$tot_exe" --argjson d "$tot_dec" \
    --argjson fp "$fxpct" --argjson fe "$fx_exe" --argjson fd "$fx_dec" \
    --argjson r "$rows" --argjson m "$MIN" --argjson un "$(to_json_array "$unenumerable")" \
    '{verdict:(if $p >= $m then "PASS" else "FAIL" end), ts:$ts, gate:"detection-surface",
      surface_pct:$p, families_exercised:$e, families_declared:$d,
      fixtured_surface_pct:$fp, fixtured_families_exercised:$fe, fixtured_families_declared:$fd,
      unenumerable_gates:$un, min_required:$m, gates:$r}' \
    > "$REPORT" 2>/dev/null || true

  local nenum nunenum
  nenum="$(printf '%s' "$rows" | jq '[.[]|select(.enumerable)]|length' 2>/dev/null || echo 0)"
  nunenum="$(printf '%s\n' "$unenumerable" | grep -c . || true)"
  echo "detection-surface: ${pct}% of ALL declared finding families are exercised (${tot_exe}/${tot_dec} across ${nenum} enumerable hard gates)"
  echo "                   ${fxpct}% among gates that have a fixture at all (${fx_exe}/${fx_dec}) — the narrower, flattering view"
  printf '%s' "$rows" | jq -r '.[] | select(.enumerable) | "  \(.gate): \(.exercised)/\(.declared) (\(.pct)%)" + (if (.unexercised|length)>0 then "  unexercised: " + (.unexercised|join(", ")) else "" end)' 2>/dev/null
  # Never let an unmeasurable gate leave the run silently. It is not covered; it is not measured.
  if [ "$nunenum" -gt 0 ]; then
    echo "  ${nunenum} hard gate(s) have NO statically-enumerable family and are outside this ratio entirely:"
    printf '%s\n' "$unenumerable" | grep . | sed 's/^/    /'
  fi
  if [ "$pct" -lt "$MIN" ]; then
    echo "detection-surface: FAIL - ${pct}% below required ${MIN}% -> exit 2" >&2; exit 2
  fi
  exit 0
}

selftest() {
  local pass=0 fail=0
  have jq || { echo "detection-surface selftest SKIP - no jq."; return 0; }
  echo "detection-surface selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }

  # A synthetic gate declaring 3 families, firing whichever the fixture asks for via a marker file.
  mkworld() {
    local d="$1"; mkdir -p "$d/walteur-kit/hooks" "$d/walteur-kit/eval-harness/fixtures"
    cat > "$d/walteur-kit/hooks/g.sh" <<'GATE'
#!/usr/bin/env bash
R="${WALTEUR_ROOT:-$1}"; K="$R/walteur-kit"; mkdir -p "$K"
findings='[]'; n=0
add_finding() { findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"; n=$((n+1)); }
[ -f "$R/HIT_alpha" ] && add_finding "alpha" "alpha found"
[ -f "$R/HIT_beta" ]  && add_finding "beta"  "beta found"
[ -f "$R/HIT_gamma" ] && add_finding "gamma" "gamma found"
jq -n --argjson f "$findings" '{verdict:(if ($f|length)>0 then "FAIL" else "PASS" end), findings:$f}' > "$K/g-report.json"
[ "$n" -gt 0 ] && exit 2 || exit 0
GATE
  }
  addfx() { mkdir -p "$1/walteur-kit/eval-harness/fixtures/$2/walteur-kit"; [ -n "${3:-}" ] && touch "$1/walteur-kit/eval-harness/fixtures/$2/HIT_$3"; }
  setman() { printf '%s' "$2" > "$1/walteur-kit/eval-harness/manifest.json"; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" "${@:2}" 2>/dev/null; }

  # 1. one of three families exercised -> 33%
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/detsurf.XXXXXX")"; mkworld "$t"; addfx "$t" fx-a alpha
  setman "$t" '[{"fixture":"fx-a","gate":"g.sh","expect":"FAIL"}]'
  run "$t" >/dev/null
  jq -e '.surface_pct==33 and .families_declared==3 and .families_exercised==1' "$t/walteur-kit/eval-harness/detection-surface-report.json" >/dev/null 2>&1
  ck "1 of 3 families exercised -> 33%" 0 "$?"

  # 2. it NAMES the unexercised families — the actionable part
  jq -e '(.gates[0].unexercised|sort) == ["beta","gamma"]' "$t/walteur-kit/eval-harness/detection-surface-report.json" >/dev/null 2>&1
  ck "names the unexercised families" 0 "$?"; rm -rf "$t"

  # 3. all three exercised across three fixtures -> 100%
  t="$(mktemp -d "${TMPDIR:-/tmp}/detsurf.XXXXXX")"; mkworld "$t"
  addfx "$t" fx-a alpha; addfx "$t" fx-b beta; addfx "$t" fx-c gamma
  setman "$t" '[{"fixture":"fx-a","gate":"g.sh","expect":"FAIL"},{"fixture":"fx-b","gate":"g.sh","expect":"FAIL"},{"fixture":"fx-c","gate":"g.sh","expect":"FAIL"}]'
  run "$t" >/dev/null
  jq -e '.surface_pct==100 and .families_exercised==3' "$t/walteur-kit/eval-harness/detection-surface-report.json" >/dev/null 2>&1
  ck "all 3 families exercised -> 100%" 0 "$?"; rm -rf "$t"

  # 4. a CLEAN fixture must not count as exercising anything
  t="$(mktemp -d "${TMPDIR:-/tmp}/detsurf.XXXXXX")"; mkworld "$t"; addfx "$t" fx-clean ""
  setman "$t" '[{"fixture":"fx-clean","gate":"g.sh","expect":"PASS"}]'
  run "$t" >/dev/null
  jq -e '.families_exercised==0' "$t/walteur-kit/eval-harness/detection-surface-report.json" >/dev/null 2>&1
  ck "clean fixture exercises nothing" 0 "$?"; rm -rf "$t"

  # 5. --min enforcement fails below threshold
  t="$(mktemp -d "${TMPDIR:-/tmp}/detsurf.XXXXXX")"; mkworld "$t"; addfx "$t" fx-a alpha
  setman "$t" '[{"fixture":"fx-a","gate":"g.sh","expect":"FAIL"}]'
  WALTEUR_ROOT="$t" bash "$SELF" --min 90 >/dev/null 2>&1
  ck "--min 90 with 33% -> FAIL" 2 "$?"
  WALTEUR_ROOT="$t" bash "$SELF" --min 30 >/dev/null 2>&1
  ck "--min 30 with 33% -> PASS" 0 "$?"; rm -rf "$t"

  # 6. no manifest -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/detsurf.XXXXXX")"; mkdir -p "$t/walteur-kit"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  ck "no manifest -> NOT_APPLICABLE" 0 "$?"; rm -rf "$t"

  # 7. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/detsurf.XXXXXX")"; mkworld "$t"; addfx "$t" fx-a alpha
  setman "$t" '[{"fixture":"fx-a","gate":"g.sh","expect":"FAIL"}]'
  WALTEUR_ROOT="$t" WALTEUR_DETSURF=off bash "$SELF" --min 99 >/dev/null 2>&1
  ck "bypass -> exit 0" 0 "$?"
  touch "$t/walteur-kit/PAUSED"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  ck "PAUSED -> exit 2" 2 "$?"; rm -rf "$t"

  # 8. THE ENUMERATOR HOLE. Real gates declare families four ways; the first version saw only one, and
  #    the other three were silently dropped from both sides of the ratio. test-claim-verifier-gate
  #    declares all 7 of its families as BARE WORDS and scored 0/0 because of it.
  t="$(mktemp -d "${TMPDIR:-/tmp}/detsurf.XXXXXX")"; mkworld "$t"
  cat > "$t/walteur-kit/hooks/g.sh" <<'GATE'
#!/usr/bin/env bash
R="${WALTEUR_ROOT:-$1}"; n=0
add_finding() { echo "  - $1: $2" >&2; n=$((n+1)); }
scan() { [ -f "$R/HIT_$1" ] && add_finding "$1" "scanned"; }
[ -f "$R/HIT_bareword" ] && add_finding bareword "bare word family"
[ -f "$R/HIT_sq" ] && add_finding 'sq' "single quoted"
[ -f "$R/HIT_dq" ] && add_finding "dq" "double quoted"
[ -f "$R/HIT_test-run" ] && add_finding test-run "dashed name"
scan "scanlabel"
[ "$n" -gt 0 ] && exit 2 || exit 0
GATE
  addfx "$t" fx-a bareword
  setman "$t" '[{"fixture":"fx-a","gate":"g.sh","expect":"FAIL"}]'
  run "$t" >/dev/null
  jq -e '(.gates[0].families|sort) == ["bareword","dq","scanlabel","sq","test-run"]' \
    "$t/walteur-kit/eval-harness/detection-surface-report.json" >/dev/null 2>&1
  ck "enumerates bare / single-quoted / dashed / scan-label families" 0 "$?"
  # And the dashed/bare family must actually INTERSECT with what the console emitted, not just be listed.
  jq -e '.families_exercised == 1 and (.gates[0].unexercised|index("bareword")) == null' \
    "$t/walteur-kit/eval-harness/detection-surface-report.json" >/dev/null 2>&1
  ck "a bare-word family emitted on the console counts as exercised" 0 "$?"; rm -rf "$t"

  # 9. UNENUMERABLE GATES ARE NAMED, NOT SKIPPED. `add_finding "$rel"` has no finite family set, so the
  #    gate cannot join the ratio — but vanishing from the report is how five fixtured gates silently
  #    contributed 0/0. Assert it appears with a reason.
  t="$(mktemp -d "${TMPDIR:-/tmp}/detsurf.XXXXXX")"; mkworld "$t"
  cat > "$t/walteur-kit/hooks/g.sh" <<'GATE'
#!/usr/bin/env bash
R="${WALTEUR_ROOT:-$1}"
add_finding() { echo "  - $1: $2" >&2; }
for f in "$R"/BAD_*; do [ -e "$f" ] || continue; rel="$(basename "$f")"; add_finding "$rel" "bad file"; done
exit 0
GATE
  addfx "$t" fx-a ""; touch "$t/walteur-kit/eval-harness/fixtures/fx-a/BAD_one"
  setman "$t" '[{"fixture":"fx-a","gate":"g.sh","expect":"FAIL"}]'
  run "$t" >/dev/null
  jq -e '.unenumerable_gates == ["g.sh (dynamic-family-names)"]
         and (.gates[0].enumerable == false) and (.gates[0].reason == "dynamic-family-names")' \
    "$t/walteur-kit/eval-harness/detection-surface-report.json" >/dev/null 2>&1
  ck "dynamic-family gate is NAMED unenumerable, not silently dropped" 0 "$?"; rm -rf "$t"

  echo "detection-surface selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
