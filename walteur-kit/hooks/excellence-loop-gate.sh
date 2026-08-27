#!/usr/bin/env bash
# WALTEUR excellence-loop-gate - plateau law over the refine loop (rocket-fuel port, HARD at ship).
#
# Green is the FLOOR, not the exit. Rocket-fuel loop law (GENERATE→BACKTEST→SCORE→REFINE→GATE):
# a build may exit the §3.x refine loop ONLY via
#   (a) PLATEAU - the trailing TWO rounds are all_green AND refined AND reproved, both carrying a NUMERIC
#       composite, with no composite improvement. An unrefined repeat is idling, not a plateau. The baseline
#       generate is refined:false, so it can never be one of the two; a green-on-arrival build runs up to
#       two falsification rounds to establish the pair. A first-round all-green — even a 100/100 — is never
#       terminal; or
#   (b) CAP - the count of actual REFINE CYCLES (refined:true rounds) reaches refine_max (default 6) AND
#       EITHER the residual deductions are PRESENTED (scoreboard.residuals non-empty, or STATE.known_gaps
#       with owners) OR the final round is all-green (nothing left to present) — never fake convergence.
#
# Evidence: walteur-kit/scoreboard.json refine_history:[{round, composite:number, all_green, refined, reproved}] + refine_max.
#
# Contract:
#   - Not required (no ship/reflect phase, no WALTEUR_EXCELLENCE_REQUIRED=1) => NOT_APPLICABLE, exit 0.
#   - Required + missing/empty/invalid refine_history                        => FAIL, exit 2.
#   - Rounds not strictly increasing, or refined-cycle count > refine_max    => FAIL, exit 2.
#   - Single-round history (even all-green), idle repeats, still-improving
#     last round, null trailing composite, cap without residuals AND not
#     all-green                                                              => FAIL, exit 2.
#   - Legitimate plateau, or cap with residuals presented / all-green final  => PASS, exit 0.
#
# Report: walteur-kit/excellence-loop-report.json
# Bypass: WALTEUR_EXCELLENCE=off (recorded, not free). PAUSED => exit 2.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "excellence-loop-gate - plateau law over the refine loop (rocket-fuel port, HARD at ship)."
  printf '%s\n' "usage: bash excellence-loop-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/excellence-loop-report.json - fix recipes: walteur-kit/REMEDIATION.md (## excellence-loop-gate)"
  printf '%s\n' "bypass: WALTEUR_EXCELLENCE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

input_dir="${1:-}"
if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "$WALTEUR_ROOT" ]; then
  ROOT="$(cd "$WALTEUR_ROOT" && pwd)"
elif [ -n "$input_dir" ] && [ -d "$input_dir" ]; then
  ROOT="$(cd "$input_dir" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
KIT="$ROOT/walteur-kit"
SCOREBOARD="$KIT/scoreboard.json"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/excellence-loop-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

have() { command -v "$1" >/dev/null 2>&1; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

findings='[]'; failures=0
add_finding() {
  findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"
  failures=$((failures+1))
}

write_report() { # verdict mode reason [exit_path]
  v="$1"; mode="$2"; reason="$3"; xp="${4:-}"
  mkdir -p "$KIT" 2>/dev/null
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --arg mode "$mode" --arg reason "$reason" --arg xp "$xp" --argjson findings "$findings" \
      '{verdict:$v, ts:$ts, gate:"excellence-loop", mode:$mode, exit_path:$xp, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"excellence-loop","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$v")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

detect_required() {
  REQUIRED=0; REQUIRED_REASON=""
  if [ "${WALTEUR_EXCELLENCE_REQUIRED:-}" = "1" ]; then
    REQUIRED=1; REQUIRED_REASON="WALTEUR_EXCELLENCE_REQUIRED=1"; return 0
  fi
  if [ -s "$STATE" ] && have jq && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      ship|reflect) REQUIRED=1; REQUIRED_REASON="STATE.phase=$phase"; return 0 ;;
    esac
  fi
}

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused "kill switch"; echo "excellence-loop-gate: PAUSED -> exit 2"; exit 2; }
  [ "${WALTEUR_EXCELLENCE:-}" = "off" ] && { write_report SKIP bypassed "WALTEUR_EXCELLENCE=off"; echo "excellence-loop-gate: bypassed (recorded)"; exit 0; }
  if ! have jq; then write_report FAIL degraded "missing dependency: jq (a ship gate cannot run degraded)"; echo "excellence-loop-gate: FAIL - missing dependency: jq (fail-closed)" >&2; exit 2; fi

  detect_required
  if [ "$REQUIRED" -ne 1 ]; then
    write_report NOT_APPLICABLE pre-ship "plateau proof due at ship/reflect (or WALTEUR_EXCELLENCE_REQUIRED=1)"
    echo "excellence-loop-gate: NOT_APPLICABLE (not required yet)"; exit 0
  fi

  if [ ! -s "$SCOREBOARD" ] || ! jq empty "$SCOREBOARD" >/dev/null 2>&1; then
    add_finding scoreboard.missing "no valid scoreboard.json — the refine loop leaves refine_history evidence there"
    write_report FAIL required "scoreboard missing/invalid"; echo "excellence-loop-gate: FAIL (no scoreboard.json) -> exit 2" >&2; exit 2
  fi

  hist_len="$(jq -r '(.refine_history // []) | length' "$SCOREBOARD" 2>/dev/null || echo 0)"
  refine_max="$(jq -r '.refine_max // 6' "$SCOREBOARD" 2>/dev/null || echo 6)"
  case "$refine_max" in ''|*[!0-9]*) refine_max=6 ;; esac
  # B9 fix: the cap is measured in actual REFINE CYCLES (refined:true rounds), not total history length —
  # the baseline generate (refined:false) and the recorded rounds are not refine cycles, so counting them
  # against refine_max false-tripped the cap. A self-authored refine_max that is exceeded by real refined
  # rounds is the runaway signal.
  refined_count="$(jq -r '[(.refine_history // [])[] | select(.refined == true)] | length' "$SCOREBOARD" 2>/dev/null || echo 0)"

  if [ "$hist_len" -eq 0 ]; then
    add_finding history.missing "refine_history absent/empty — no evidence the excellence loop ran (green is the floor, not the exit)"
    write_report FAIL required "no refine_history"; echo "excellence-loop-gate: FAIL (no refine_history) -> exit 2" >&2; exit 2
  fi

  # shape: every entry needs round/all_green/refined/reproved; rounds strictly increasing
  jq -e '(.refine_history // []) | all(
      (.round | type == "number") and (.all_green | type == "boolean")
      and (.refined | type == "boolean") and (.reproved | type == "boolean"))' "$SCOREBOARD" >/dev/null 2>&1 || {
    add_finding history.shape "refine_history entries need {round:number, composite, all_green:bool, refined:bool, reproved:bool}"
    write_report FAIL required "malformed refine_history"; echo "excellence-loop-gate: FAIL (malformed refine_history) -> exit 2" >&2; exit 2; }
  jq -e '(.refine_history // []) | [.[].round] | . == (sort) and (length == (unique | length))' "$SCOREBOARD" >/dev/null 2>&1 || {
    add_finding history.order "refine_history rounds must be strictly increasing — reordered/duplicated rounds are not a loop"
    write_report FAIL required "rounds not strictly increasing"; echo "excellence-loop-gate: FAIL (rounds not increasing) -> exit 2" >&2; exit 2; }

  if [ "$refined_count" -gt "$refine_max" ]; then
    add_finding history.overcap "refined cycles $refined_count > refine_max $refine_max — caps are IMMUTABLE mid-run (Iron Law 12)"
    write_report FAIL required "over cap"; echo "excellence-loop-gate: FAIL (over refine_max) -> exit 2" >&2; exit 2
  fi

  # exit path (a): PLATEAU — trailing two rounds all_green+refined+reproved, with NUMERIC composites and
  # no improvement. B6 fix: the deciding pair MUST carry numeric composites — a null/absent composite can
  # no longer trivially satisfy the no-improvement law (that was the escape hatch).
  if [ "$hist_len" -ge 2 ]; then
    if jq -e '
        (.refine_history) as $h | ($h[-1]) as $last | ($h[-2]) as $prev |
        ($last.all_green and $last.refined and $last.reproved)
        and ($prev.all_green and $prev.refined and $prev.reproved)
        and ($last.composite | type == "number") and ($prev.composite | type == "number")
        and ($last.composite <= $prev.composite)' "$SCOREBOARD" >/dev/null 2>&1; then
      write_report PASS required "plateau: two consecutive refined-and-re-proved all-green rounds, numeric composites, no improvement (rounds $hist_len/$refine_max)" plateau
      echo "excellence-loop-gate: PASS (plateau after $hist_len rounds)"; exit 0
    fi
  fi

  # exit path (b): CAP — refine cycles exhausted. Honest stop needs EITHER presented residuals OR an
  # all-green final round (nothing left to present). Not-green + no residuals at the cap = fake convergence.
  if [ "$refined_count" -ge "$refine_max" ]; then
    if jq -e '((.residuals // []) | length) > 0 or ((.refine_history[-1].all_green) == true)' "$SCOREBOARD" >/dev/null 2>&1 \
       || { [ -s "$STATE" ] && jq -e '((.known_gaps // []) | length) > 0 and ((.known_gaps // []) | all((.owner // "") | length > 0))' "$STATE" >/dev/null 2>&1; }; then
      write_report PASS required "cap reached ($refined_count/$refine_max refine cycles) — residuals presented or final round all-green — honest stop, not fake convergence" cap-with-residuals
      echo "excellence-loop-gate: PASS (cap + residuals/green)"; exit 0
    fi
    add_finding cap.silent "cap reached with NO residuals presented and final round not green (scoreboard.residuals empty, no owned STATE.known_gaps) — a capped loop must present its residual deductions, never claim convergence"
    write_report FAIL required "cap without residuals"; echo "excellence-loop-gate: FAIL (cap without presented residuals) -> exit 2" >&2; exit 2
  fi

  # neither exit path: say precisely why
  if [ "$hist_len" -eq 1 ]; then
    add_finding plateau.single "single-round history — a first-round all-green (even 100/100) gets exactly one refined-and-re-proved falsification round before it may exit"
  elif jq -e '(.refine_history[-1]) | (.refined and .reproved) | not' "$SCOREBOARD" >/dev/null 2>&1; then
    add_finding plateau.idle "trailing round is an unrefined/unre-proved repeat — idling is not a plateau"
  elif jq -e '
      (.refine_history) as $h | ($h[-1]) as $last | ($h[-2]) as $prev |
      (($last.composite | type == "number") and ($prev.composite | type == "number")) and ($last.composite > $prev.composite)' "$SCOREBOARD" >/dev/null 2>&1; then
    add_finding plateau.rising "score still improving ($(jq -r '.refine_history[-2].composite' "$SCOREBOARD") -> $(jq -r '.refine_history[-1].composite' "$SCOREBOARD")) — gate green on a rising score means KEEP LOOPING"
  else
    add_finding plateau.notgreen "trailing rounds are not consecutively all_green+refined+reproved — the loop has not legitimately converged"
  fi
  write_report FAIL required "no legitimate exit: neither plateau nor cap-with-residuals (rounds $hist_len/$refine_max)"
  echo "excellence-loop-gate: FAIL (no legitimate loop exit) -> exit 2" >&2; exit 2
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "excellence-loop-gate selftest FAIL - no jq (fail-closed)."; return 1; fi
  echo "excellence-loop-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  SELF_PATH="$0"
  run() { WALTEUR_ROOT="$1" bash "$SELF_PATH" >/dev/null 2>&1; echo $?; }
  mkfix() { # $1=dir $2=phase $3=scoreboard-json (empty = none)
    local d="$1" phase="$2" sb="${3:-}"
    mkdir -p "$d/walteur-kit/autopilot"
    printf '{"phase":"%s"}\n' "$phase" > "$d/walteur-kit/autopilot/STATE.json"
    [ -n "$sb" ] && printf '%s\n' "$sb" > "$d/walteur-kit/scoreboard.json"
  }
  H() { printf '{"refine_max":%s,"refine_history":%s%s}' "$1" "$2" "${3:-}"; }

  # 1. no kit -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkdir -p "$t/src"; ck "no kit -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. pre-ship -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" build "$(H 6 '[]')"; ck "pre-ship -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 3. ship + no history -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 6 '[]')"; ck "ship + empty history -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. plateau -> 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 6 '[{"round":1,"composite":8.4,"all_green":false,"refined":true,"reproved":true},{"round":2,"composite":9.1,"all_green":true,"refined":true,"reproved":true},{"round":3,"composite":9.1,"all_green":true,"refined":true,"reproved":true}]')"
  ck "plateau -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 5. last round improved -> 2 (keep looping)
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 6 '[{"round":1,"composite":8.4,"all_green":true,"refined":true,"reproved":true},{"round":2,"composite":9.1,"all_green":true,"refined":true,"reproved":true}]')"
  ck "still improving -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. idle repeat (unrefined trailing round) -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 6 '[{"round":1,"composite":9.1,"all_green":true,"refined":true,"reproved":true},{"round":2,"composite":9.1,"all_green":true,"refined":false,"reproved":false}]')"
  ck "idle repeat -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. first-round all-green single history -> 2 (needs a falsification round)
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 6 '[{"round":1,"composite":10,"all_green":true,"refined":true,"reproved":true}]')"
  ck "first-green single round -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. cap + residuals presented -> 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 3 '[{"round":1,"composite":7.0,"all_green":false,"refined":true,"reproved":true},{"round":2,"composite":7.5,"all_green":false,"refined":true,"reproved":true},{"round":3,"composite":8.0,"all_green":false,"refined":true,"reproved":true}]' ',"residuals":[{"dim":"performance","deduction":"p99 180ms vs 150ms budget","evidence":"perf-report.json"}]')"
  ck "cap + residuals -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 9. cap without residuals -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 3 '[{"round":1,"composite":7.0,"all_green":false,"refined":true,"reproved":true},{"round":2,"composite":7.5,"all_green":false,"refined":true,"reproved":true},{"round":3,"composite":8.0,"all_green":false,"refined":true,"reproved":true}]')"
  ck "cap without residuals -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10. rounds not strictly increasing -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 6 '[{"round":2,"composite":9.0,"all_green":true,"refined":true,"reproved":true},{"round":1,"composite":9.0,"all_green":true,"refined":true,"reproved":true}]')"
  ck "non-increasing rounds -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 11. over cap -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 2 '[{"round":1,"composite":9.0,"all_green":true,"refined":true,"reproved":true},{"round":2,"composite":9.0,"all_green":true,"refined":true,"reproved":true},{"round":3,"composite":9.0,"all_green":true,"refined":true,"reproved":true}]')"
  ck "over refine_max -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 12. cap==2 with trailing plateau -> PASS via plateau (plateau precedence over cap)
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 2 '[{"round":1,"composite":9.0,"all_green":true,"refined":true,"reproved":true},{"round":2,"composite":9.0,"all_green":true,"refined":true,"reproved":true}]')"
  ck "plateau at cap -> PASS (plateau path)" 0 "$(run "$t")"; rm -rf "$t"
  # 13. PAUSED -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 6 '[]')"; touch "$t/walteur-kit/PAUSED"
  ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # 14. bypass -> 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 6 '[]')"
  rc=0; WALTEUR_ROOT="$t" WALTEUR_EXCELLENCE=off bash "$SELF_PATH" >/dev/null 2>&1 || rc=$?
  ck "bypass -> exit 0" 0 "$rc"; rm -rf "$t"
  # 15. B6 hole closed: two green refined rounds but trailing composite NULL -> FAIL (no numeric-composite escape)
  t="$(mktemp -d "${TMPDIR:-/tmp}/elg.XXXXXX")"; mkfix "$t" ship "$(H 6 '[{"round":1,"composite":9.1,"all_green":true,"refined":true,"reproved":true},{"round":2,"composite":null,"all_green":true,"refined":true,"reproved":true}]')"
  ck "null trailing composite -> FAIL (B6)" 2 "$(run "$t")"; rm -rf "$t"

  echo "excellence-loop-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
