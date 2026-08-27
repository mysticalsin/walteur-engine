#!/usr/bin/env bash
# WALTEUR eval-coverage-gate — closes the measurement half of R6 (ULTIMATE-UPGRADE-2026.md P2:
# "eval-harness self-regression ... block self-mods that regress").
#
# THE HOLE THIS CLOSES: self-regress.sh proves that every gate WITH a fixture still behaves. It says
# nothing about how many gates have NO fixture at all. Measured 2026-08-25 on walteur-framework:
# 6 of 59 HARD (fail-closed) gates carried fixture coverage — 10%. self-regress.sh reported
# "PASS - 11/11 fixtures behaved per baseline" the whole time, which reads as all-clear. It was
# a true statement about a 10% sample. That is the silent-cap failure mode the project's own
# doctrine forbids ("No silent caps: if a workflow bounds coverage, log what was dropped").
#
# WHAT IT DOES: counts HARD gates in gate-registry.json, counts how many appear as a `gate` in
# eval-harness/manifest.json, and compares the ratio against a committed baseline. Coverage going
# DOWN (a fixture deleted, a hard gate added with no fixture) is a self-regression => FAIL.
# Coverage going UP rewrites nothing automatically — rebaseline is explicit, so a drop can never be
# laundered into a new normal by the same run that caused it.
#
# CONTRACT:
#   no gate-registry.json or no eval-harness/manifest.json  => verdict:NOT_APPLICABLE, exit 0
#     (a built product, not the framework repo — same convention as self-regress.sh)
#   no baseline file                                        => writes one, verdict:BASELINED, exit 0
#   coverage >= baseline                                    => verdict:PASS, exit 0
#   coverage <  baseline (beyond tolerance)                 => verdict:FAIL, exit 2 (FAIL-CLOSED)
#   a gate that HAD a fixture lost it                       => verdict:FAIL, exit 2, named to stderr
#   jq absent                                               => verdict:FAIL, exit 2 (cannot measure;
#                                                              fail-closed, matching self-regress.sh)
#   PAUSED present                                          => exit 2
#   bypass WALTEUR_EVALCOV=off                              => verdict:SKIP, exit 0 (recorded, not free)
#
# Tolerance: WALTEUR_EVALCOV_TOLERANCE (percentage points, default 0 — any regression fails).
# Rebaseline: WALTEUR_EVALCOV=rebaseline (deliberate, explicit, never automatic on a drop).
# Report: walteur-kit/eval-harness/eval-coverage-report.json
#
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
    printf '%s\n' "eval-coverage-gate - measures fixture coverage of HARD gates; fails on regression."
    printf '%s\n' "usage: bash eval-coverage-gate.sh [--selftest|--help|<default run>]"
    printf '%s\n' "report: walteur-kit/eval-harness/eval-coverage-report.json"
    printf '%s\n' "bypass: WALTEUR_EVALCOV=off (recorded, not free) - rebaseline: WALTEUR_EVALCOV=rebaseline"
    exit 0 ;;
esac

set -uo pipefail

SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
have() { command -v "$1" >/dev/null 2>&1; }
# The Windows jq build emits CRLF. Un-stripped, every `comm`/`grep -c` against jq output silently
# matches nothing and this gate reports 0% coverage on a fully-covered tree — a false FAIL that looks
# like a real regression. Strip CR on every jq read. (Proven on this machine 2026-08-25; the failure
# mode is recorded as `win-jq-defender-crlf` in walteur-kit/playbook.jsonl.)
jqr() { jq -r "$@" 2>/dev/null | tr -d '\r'; }

# Single report writer — every framework gate defines one; three inline `jq -n > $REPORT` copies was
# duplication against Build Law rule 4, and the bypass path skipped writing entirely, leaving a stale
# green report behind. Accepts optional extra jq fields as $3.
write_report() {
  local v="$1" r="${2:-}" extra="${3:-}"
  mkdir -p "$EH" 2>/dev/null
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson x "${extra:-\{\}}" \
      '{verdict:$v, ts:$ts, gate:"eval-coverage", reason:$r} + $x' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"eval-coverage","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true
}

main() {
  local ROOT KIT EH MAN REG BASE REPORT TS TOL
  ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  KIT="$ROOT/walteur-kit"; EH="$KIT/eval-harness"
  MAN="$EH/manifest.json"; REG="$KIT/gate-registry.json"
  BASE="$EH/coverage-baseline.json"; REPORT="$EH/eval-coverage-report.json"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  TOL="${WALTEUR_EVALCOV_TOLERANCE:-0}"

  # TOL must be validated BEFORE any arithmetic: under `set -u`, a non-numeric value inside $(( ))
  # is treated as a variable name and aborts with exit 1 — a third exit code no hook runner expects.
  case "$TOL" in ''|*[!0-9]*) echo "eval-coverage: FAIL - WALTEUR_EVALCOV_TOLERANCE must be a non-negative integer (got '$TOL')" >&2; write_report "FAIL" "invalid tolerance '$TOL'"; exit 2 ;; esac

  [ -f "$KIT/PAUSED" ] && { echo "eval-coverage: PAUSED -> exit 2" >&2; exit 2; }
  # Bypass is RECORDED, not free — write the SKIP report so a stale green never survives a bypass,
  # and echo to stderr like every other gate in the framework.
  if [ "${WALTEUR_EVALCOV:-on}" = "off" ]; then
    echo "eval-coverage: bypassed (WALTEUR_EVALCOV=off)" >&2
    write_report "SKIP" "bypassed via WALTEUR_EVALCOV=off"
    exit 0
  fi

  # NOT_APPLICABLE on a built product (no framework registry / no eval-harness) — never a false fail.
  if [ ! -f "$REG" ] || [ ! -f "$MAN" ]; then
    echo "eval-coverage: NOT_APPLICABLE (no gate-registry.json or no eval-harness manifest)"
    write_report "NOT_APPLICABLE" "no gate-registry.json or no eval-harness manifest"
    exit 0
  fi
  have jq || { echo "eval-coverage: FAIL - jq absent; cannot measure (fail-closed)" >&2; exit 2; }

  # UNPARSEABLE inputs are a "cannot measure" condition, exactly like jq being absent — so they must
  # fail CLOSED. Previously jqr() swallowed the parse error and an unreadable registry yielded an empty
  # hard-gate list -> total=0 -> NOT_APPLICABLE exit 0: green meaning unmeasured, the precise failure
  # mode this gate exists to eliminate, reproduced inside the gate itself.
  jq -e . "$REG" >/dev/null 2>&1 || { echo "eval-coverage: FAIL - gate-registry.json is not valid JSON; cannot measure (fail-closed)" >&2; write_report "FAIL" "gate-registry.json unparseable"; exit 2; }
  jq -e . "$MAN" >/dev/null 2>&1 || { echo "eval-coverage: FAIL - eval-harness manifest is not valid JSON; cannot measure (fail-closed)" >&2; write_report "FAIL" "eval-harness manifest unparseable"; exit 2; }

  # HARD gates are the fail-closed blockers — a hard gate going blind means a real defect ships green.
  # detect_or_skip gates are advisory by construction, so coverage is measured against HARD only.
  local hard covered total ncov pct lost
  # SELF-REFERENTIAL MEASUREMENT GATES ARE EXCLUDED FROM THE DENOMINATOR, deliberately and visibly.
  # These gates' subject is the harness itself, not a defect class in a source tree, so there is no
  # poisoned/clean twin that could ever cover them — a fixture for "did the fixtures run" is circular.
  # Without this, registering a measurement gate MECHANICALLY LOWERS the metric it computes: adding
  # self-regress as a 61st hard gate took coverage 25% -> 24% and failed the gate against its own
  # committed baseline, so the adoption of this work was red on arrival. A metric that punishes you for
  # measuring more is broken. The excluded set is listed in the report so it cannot be quietly grown.
  local SELF_GATES="eval-coverage-gate.sh self-regress.sh detection-surface.sh gate-mutation.sh fixture-integrity.sh"
  local self_re; self_re="$(printf '%s\n' $SELF_GATES | paste -sd'|' -)"
  hard="$(jqr '[.gates[]|select(.hardness=="hard")|.hook]|unique|.[]' "$REG" | grep -Ev "^(${self_re})$" || true)"
  covered="$(jqr '[.[].gate]|unique|.[]' "$MAN")"
  total="$(printf '%s\n' "$hard" | grep -c . || true)"
  # A registry that parses but declares zero hard gates is genuinely NOT_APPLICABLE (a bare product
  # tree). Reachable only after the parse check above, so it can no longer mask a corrupt registry.
  [ "$total" -eq 0 ] && { echo "eval-coverage: NOT_APPLICABLE (no hard gates in registry)"; write_report "NOT_APPLICABLE" "registry declares no hard gates"; exit 0; }

  ncov="$(comm -12 <(printf '%s\n' "$hard" | sort -u) <(printf '%s\n' "$covered" | sort -u) | grep -c . || true)"
  pct=$(( ncov * 100 / total ))

  # First run (or explicit rebaseline): record and pass. Never auto-rebaseline on a drop.
  if [ ! -f "$BASE" ] || [ "${WALTEUR_EVALCOV:-}" = "rebaseline" ]; then
    jq -n --argjson p "$pct" --argjson c "$ncov" --argjson t "$total" --arg ts "$TS" \
      --argjson g "$(printf '%s\n' "$hard" | sort -u | jq -R . | jq -s .)" \
      --argjson cg "$(comm -12 <(printf '%s\n' "$hard" | sort -u) <(printf '%s\n' "$covered" | sort -u) | jq -R . | jq -s .)" \
      '{coverage_pct:$p, covered:$c, hard_total:$t, ts:$ts, hard_gates:$g, covered_gates:$cg}' > "$BASE" 2>/dev/null
    echo "eval-coverage: BASELINED at ${pct}% (${ncov}/${total} hard gates carry a fixture)"
    jq -n --arg v "BASELINED" --arg ts "$TS" --argjson p "$pct" --argjson c "$ncov" --argjson t "$total" \
      '{verdict:$v, ts:$ts, gate:"eval-coverage", coverage_pct:$p, covered:$c, hard_total:$t, findings:[]}' > "$REPORT" 2>/dev/null || true
    exit 0
  fi

  local bpct bcov findings='[]' fail=0
  # A corrupt/truncated baseline is "cannot measure", not "baseline is 0%". Defaulting to 0 silently
  # DISARMED the gate — coverage could collapse 50% -> 0% and still report PASS, because everything is
  # >= 0. ADOPTION.md calls this file the anti-regression anchor; a damaged anchor must block, not wave through.
  jq -e . "$BASE" >/dev/null 2>&1 || { echo "eval-coverage: FAIL - coverage-baseline.json is not valid JSON; cannot compare (fail-closed)" >&2; write_report "FAIL" "coverage-baseline.json unparseable"; exit 2; }
  bpct="$(jqr '.coverage_pct // empty' "$BASE")"
  case "$bpct" in
    ''|*[!0-9]*) echo "eval-coverage: FAIL - coverage-baseline.json has no usable coverage_pct (got '$bpct'); cannot compare (fail-closed)" >&2; write_report "FAIL" "baseline coverage_pct missing or non-numeric"; exit 2 ;;
  esac

  # A gate that HAD a fixture and lost it is a regression even if the percentage held (e.g. a hard
  # gate was also removed). Name it explicitly — a silent swap is exactly what this gate exists to catch.
  # Two independent conditions, deliberately not conflated:
  #   pct_regressed  — the percentage fell below (baseline - tolerance). Always blocking.
  #   lost fixtures  — a gate that HAD a fixture no longer does. Blocking under the default strict
  #                    TOL=0, including when the percentage is unchanged (gate A lost a fixture and
  #                    gate B gained one — exactly the laundering this gate exists to catch).
  #                    An explicitly declared TOL>0 downgrades these to recorded-but-non-blocking;
  #                    they are never silently dropped from the report. Tolerance is opt-in.
  local pct_regressed=0 lost_blocking=1
  [ "$pct" -lt $(( bpct - TOL )) ] && pct_regressed=1
  [ "$TOL" -gt 0 ] && [ "$pct_regressed" -eq 0 ] && lost_blocking=0

  bcov="$(jqr '.covered_gates[]?' "$BASE" | sort -u)"
  lost="$(comm -23 <(printf '%s\n' "$bcov" | grep . | sort -u) <(printf '%s\n' "$covered" | sort -u) | grep . || true)"
  if [ -n "$lost" ]; then
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      findings="$(printf '%s' "$findings" | jq --arg g "$g" --argjson b "$lost_blocking" \
        '. + [{kind:"fixture-lost", gate:$g, blocking:($b==1), message:("gate lost its fixture coverage since baseline: " + $g)}]')"
      [ "$lost_blocking" -eq 1 ] && fail=1
    done <<< "$lost"
  fi

  # EXECUTION freshness — the "map vs territory" hole. Counting manifest rows says the fixtures EXIST;
  # it says nothing about whether they have ever RUN. Coverage could read a healthy 25% while no fixture
  # had been executed in months, which is the same shape as the "11/11 PASS" this gate exists to debunk.
  # So: require a recent self-regress-report.json. Default 30 days; WALTEUR_EVALCOV_MAXAGE=0 disables.
  local SRR maxage
  SRR="$EH/self-regress-report.json"
  maxage="${WALTEUR_EVALCOV_MAXAGE:-30}"
  case "$maxage" in ''|*[!0-9]*) maxage=30 ;; esac
  if [ "$maxage" -gt 0 ]; then
    if [ ! -f "$SRR" ]; then
      findings="$(printf '%s' "$findings" | jq '. + [{kind:"never-executed", blocking:true, message:"no eval-harness/self-regress-report.json — the fixtures are declared but have never been run; coverage counts rows, not executions"}]')"
      fail=1
    else
      local age_days now_s rep_s
      now_s="$(date -u +%s)"
      rep_s="$(date -u -r "$SRR" +%s 2>/dev/null || echo "$now_s")"
      age_days=$(( (now_s - rep_s) / 86400 ))
      if [ "$age_days" -gt "$maxage" ]; then
        findings="$(printf '%s' "$findings" | jq --argjson a "$age_days" --argjson m "$maxage" \
          '. + [{kind:"execution-stale", blocking:true, message:("self-regress last ran " + ($a|tostring) + " days ago (max " + ($m|tostring) + ") — coverage is green but unexercised")}]')"
        fail=1
      fi
    fi
  fi

  if [ "$pct_regressed" -eq 1 ]; then
    findings="$(printf '%s' "$findings" | jq --argjson p "$pct" --argjson b "$bpct" \
      '. + [{kind:"coverage-regressed", blocking:true, message:("hard-gate fixture coverage fell from " + ($b|tostring) + "% to " + ($p|tostring) + "%")}]')"
    fail=1
  fi

  jq -n --arg v "$([ "$fail" -eq 0 ] && echo PASS || echo FAIL)" --arg ts "$TS" \
    --argjson p "$pct" --argjson b "$bpct" --argjson c "$ncov" --argjson t "$total" --argjson f "$findings" \
    '{verdict:$v, ts:$ts, gate:"eval-coverage", coverage_pct:$p, baseline_pct:$b, covered:$c, hard_total:$t, findings:$f}' \
    > "$REPORT" 2>/dev/null || true

  if [ "$fail" -ne 0 ]; then
    echo "eval-coverage: FAIL - hard-gate fixture coverage ${pct}% vs baseline ${bpct}% (${ncov}/${total}) -> exit 2" >&2
    printf '%s' "$findings" | jq -r '.[] | "  x " + .message' 2>/dev/null >&2
    exit 2
  fi
  echo "eval-coverage: PASS - ${pct}% of hard gates carry a fixture (${ncov}/${total}, baseline ${bpct}%; ${SELF_GATES// /, } excluded as self-referential)"
  exit 0
}

selftest() {
  local pass=0 fail=0
  have jq || { echo "eval-coverage selftest SKIP - jq not installed."; return 0; }
  echo "eval-coverage-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }

  # world: N hard gates in the registry, M of them covered by a manifest fixture row.
  mkworld() {
    local d="$1" nhard="$2" ncov="$3" i
    mkdir -p "$d/walteur-kit/eval-harness"
    local gates='[]'
    for i in $(seq 1 "$nhard"); do
      gates="$(printf '%s' "$gates" | jq --arg h "g$i.sh" '. + [{id:("g"+($h|split(".")[0]|ltrimstr("g"))), hardness:"hard", hook:$h}]')"
    done
    jq -n --argjson g "$gates" '{schema_version:1, gates:$g}' > "$d/walteur-kit/gate-registry.json"
    local man='[]'
    for i in $(seq 1 "$ncov"); do
      man="$(printf '%s' "$man" | jq --arg h "g$i.sh" '. + [{fixture:("fx"+$h), gate:$h, expect:"FAIL"}]')"
    done
    printf '%s' "$man" > "$d/walteur-kit/eval-harness/manifest.json"
    # A fresh self-regress report by default, so the execution-freshness check (G18-G21) does not
    # confound the coverage cases. Tests that target freshness remove or back-date it explicitly.
    printf '{"verdict":"PASS"}' > "$d/walteur-kit/eval-harness/self-regress-report.json"
  }

  # 1. no registry/manifest -> NOT_APPLICABLE (a built product, never a false fail)
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkdir -p "$t/walteur-kit"
  ck "no registry -> NOT_APPLICABLE" 0 "$(run "$t")"; rm -rf "$t"

  # 2. first run -> BASELINED, exit 0, baseline written
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  ck "first run -> BASELINED" 0 "$(run "$t")"
  jq -e '.coverage_pct==50 and .hard_total==10 and .covered==5' "$t/walteur-kit/eval-harness/coverage-baseline.json" >/dev/null 2>&1
  ck "baseline records 50% (5/10)" 0 "$?"; rm -rf "$t"

  # 3. coverage held -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null   # baseline
  ck "unchanged coverage -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 4. coverage IMPROVED -> PASS (never punish an improvement)
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null
  mkworld "$t" 10 8
  ck "coverage improved 50->80 -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 5. coverage REGRESSED (fixture removed) -> FAIL, exit 2  [the core case]
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null
  mkworld "$t" 10 3
  ck "coverage regressed 50->30 -> FAIL" 2 "$(run "$t")"
  jq -e '.verdict=="FAIL" and ([.findings[]|select(.kind=="coverage-regressed")]|length)==1' \
    "$t/walteur-kit/eval-harness/eval-coverage-report.json" >/dev/null 2>&1
  ck "report records the coverage regression" 0 "$?"; rm -rf "$t"

  # 6. a hard gate ADDED with no fixture (denominator grew) -> coverage fell -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null
  mkworld "$t" 20 5
  ck "hard gate added w/o fixture 50->25 -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 7. a SPECIFIC covered gate lost its fixture while pct held (swap) -> FAIL, named
  #    baseline covers g1..g5 of 10. Now cover g2..g6: still 5/10 = 50%, but g1 lost coverage.
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null
  printf '%s' '[{"fixture":"fxg2.sh","gate":"g2.sh","expect":"FAIL"},{"fixture":"fxg3.sh","gate":"g3.sh","expect":"FAIL"},{"fixture":"fxg4.sh","gate":"g4.sh","expect":"FAIL"},{"fixture":"fxg5.sh","gate":"g5.sh","expect":"FAIL"},{"fixture":"fxg6.sh","gate":"g6.sh","expect":"FAIL"}]' \
    > "$t/walteur-kit/eval-harness/manifest.json"
  ck "swapped fixture (pct held, g1 lost) -> FAIL" 2 "$(run "$t")"
  jq -e '[.findings[]|select(.kind=="fixture-lost" and .gate=="g1.sh")]|length==1' \
    "$t/walteur-kit/eval-harness/eval-coverage-report.json" >/dev/null 2>&1
  ck "report names the specific gate that lost coverage" 0 "$?"; rm -rf "$t"

  # 8. tolerance allows a declared slip
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null
  mkworld "$t" 10 4
  WALTEUR_ROOT="$t" WALTEUR_EVALCOV_TOLERANCE=10 bash "$SELF" >/dev/null 2>&1
  ck "tolerance 10pp absorbs 50->40 -> PASS" 0 "$?"; rm -rf "$t"

  # 9. explicit rebaseline after a real drop -> exit 0 and baseline rewritten
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null
  mkworld "$t" 10 3
  WALTEUR_ROOT="$t" WALTEUR_EVALCOV=rebaseline bash "$SELF" >/dev/null 2>&1
  ck "explicit rebaseline -> exit 0" 0 "$?"
  jq -e '.coverage_pct==30' "$t/walteur-kit/eval-harness/coverage-baseline.json" >/dev/null 2>&1
  ck "rebaseline rewrote baseline to 30%" 0 "$?"; rm -rf "$t"

  # 10. bypass
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null; mkworld "$t" 10 1
  WALTEUR_ROOT="$t" WALTEUR_EVALCOV=off bash "$SELF" >/dev/null 2>&1
  ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"

  # 11. PAUSED kill switch -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  touch "$t/walteur-kit/PAUSED"
  ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ---- REGRESSION cases for the fail-OPEN holes an adversarial review reproduced (2026-08-25) ----
  # G12: corrupt registry must FAIL closed, not NOT_APPLICABLE exit 0. Previously jqr() swallowed the
  #      parse error -> empty hard list -> total=0 -> exit 0: green meaning unmeasured.
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  printf 'NOT JSON AT ALL {{{' > "$t/walteur-kit/gate-registry.json"
  ck "G12 corrupt registry -> FAIL (was exit 0)" 2 "$(run "$t")"; rm -rf "$t"

  # G13: corrupt manifest must FAIL closed too.
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  printf '[[[ broken' > "$t/walteur-kit/eval-harness/manifest.json"
  ck "G13 corrupt manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G14: corrupt BASELINE must FAIL closed. Previously bpct defaulted to 0 and every coverage
  #      collapse compared >= 0 -> PASS, silently disarming the anti-regression anchor.
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null   # write a real baseline first
  printf 'garbage' > "$t/walteur-kit/eval-harness/coverage-baseline.json"
  ck "G14 corrupt baseline -> FAIL (was PASS at 0%)" 2 "$(run "$t")"; rm -rf "$t"

  # G15: baseline present but coverage_pct missing -> FAIL, never a permissive 0.
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null
  jq 'del(.coverage_pct)' "$t/walteur-kit/eval-harness/coverage-baseline.json" > "$t/b" && mv "$t/b" "$t/walteur-kit/eval-harness/coverage-baseline.json"
  ck "G15 baseline missing coverage_pct -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G16: non-numeric tolerance must FAIL(2), not crash with exit 1 from `set -u` inside $(( )).
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null
  WALTEUR_ROOT="$t" WALTEUR_EVALCOV_TOLERANCE=abc bash "$SELF" >/dev/null 2>&1
  ck "G16 non-numeric tolerance -> FAIL not crash" 2 "$?"; rm -rf "$t"

  # G17: bypass must RECORD a SKIP report — a stale green must never survive a bypass.
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null   # leaves a BASELINED report behind
  WALTEUR_ROOT="$t" WALTEUR_EVALCOV=off bash "$SELF" >/dev/null 2>&1
  jq -e '.verdict=="SKIP"' "$t/walteur-kit/eval-harness/eval-coverage-report.json" >/dev/null 2>&1
  ck "G17 bypass writes SKIP report (no stale green)" 0 "$?"; rm -rf "$t"

  # ---- EXECUTION-freshness: coverage must measure the territory, not just the map ----
  # G18: fixtures declared but never executed (no self-regress-report.json) -> FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null
  rm -f "$t/walteur-kit/eval-harness/self-regress-report.json"
  ck "G18 never-executed fixtures -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G19: a fresh self-regress report satisfies it -> PASS (false-positive guard).
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null
  ck "G19 fresh self-regress report -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # G20: a report older than the window -> FAIL (green but unexercised).
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null
  printf '{"verdict":"PASS"}' > "$t/walteur-kit/eval-harness/self-regress-report.json"
  touch -d '2020-01-01' "$t/walteur-kit/eval-harness/self-regress-report.json" 2>/dev/null || touch -t 202001010000 "$t/walteur-kit/eval-harness/self-regress-report.json"
  ck "G20 stale self-regress report -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G21: the freshness check is disableable for trees that run it out-of-band.
  t="$(mktemp -d "${TMPDIR:-/tmp}/evalcov.XXXXXX")"; mkworld "$t" 10 5
  run "$t" >/dev/null
  WALTEUR_ROOT="$t" WALTEUR_EVALCOV_MAXAGE=0 bash "$SELF" >/dev/null 2>&1
  ck "G21 MAXAGE=0 disables the freshness check" 0 "$?"; rm -rf "$t"

  echo "eval-coverage-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
