#!/usr/bin/env bash
# WALTEUR harness-self-audit-gate — HARD gate (intake: affaan-m/ECC harness-audit + ruvnet/ruflo drift-detect).
# loop-readiness-gate scores the LOOP; this scores the whole HARNESS scaffold (0-100, six dimensions) AND
# fail-closes on REGRESSION: if a gate silently disappears, the gate count drops, or the score falls below the
# floor vs the committed baseline, the build fails. This is how "is the harness actually getting better?" stops
# being a vibe and becomes a tracked number — and how an upgrade can never quietly erode coverage.
#
# Applies when run against a WALTEUR kit (walteur-kit/gate-registry.json + hooks/ present). App builds => NA.
# CONTRACT: score < floor (default 70) OR a baseline gate vanished OR gate_count regressed => FAIL exit 2.
# First run with no baseline => snapshots it + PASS. no kit => NOT_APPLICABLE. PAUSED => exit 2.
# bypass WALTEUR_SELFAUDIT=off. Re-baseline intentionally: WALTEUR_SELFAUDIT=rebaseline (records current as new floor).
# Report: walteur-kit/harness-audit-report.json · Baseline: walteur-kit/harness-audit-baseline.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "harness-self-audit-gate - HARD gate (intake: affaan-m/ECC harness-audit + ruvnet/ruflo drift-detect)."
  printf '%s\n' "usage: bash harness-self-audit-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/harness-audit-report.json - fix recipes: walteur-kit/REMEDIATION.md (## harness-self-audit-gate)"
  printf '%s\n' "bypass: WALTEUR_SELFAUDIT=off (recorded, not free)"
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
BASE="$KIT/harness-audit-baseline.json"
REPORT="$KIT/harness-audit-report.json"
FLOOR="${WALTEUR_SELFAUDIT_FLOOR:-70}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; sc="${3:-0}"; jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson sc "$sc" --argjson dims "$DIMS" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"harness-self-audit", score:$sc, dims:$dims, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null || printf '{"verdict":"%s","score":%s}\n' "$v" "$sc" > "$REPORT"; }

hook_exists() { [ -f "$HOOKS/$1.sh" ]; }
DIMS='{}'

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused 0; echo "harness-self-audit-gate: PAUSED -> exit 2"; exit 2; }
  [ "${WALTEUR_SELFAUDIT:-}" = "off" ] && { write_report SKIP bypassed 0; echo "harness-self-audit-gate: bypassed"; exit 0; }
  if ! have jq; then write_report FAIL "missing dependency: jq (self-audit cannot run degraded)" 0; echo "harness-self-audit-gate: FAIL - missing dependency: jq (fail-closed; install jq)" >&2; exit 2; fi
  if [ ! -f "$REG" ] || [ ! -d "$HOOKS" ]; then write_report NOT_APPLICABLE "no WALTEUR kit (gate-registry.json + hooks/)" 0; echo "harness-self-audit-gate: NOT_APPLICABLE"; exit 0; fi

  local gates ids d_gate d_sec d_skill d_ctx d_mem d_self score
  gates="$(jq '.gates | length' "$REG" 2>/dev/null || echo 0)"
  ids="$(jq -r '[.gates[].id] | sort | join(",")' "$REG" 2>/dev/null || echo '')"

  # DIM 1 — gate coverage (25): scaled by count (100 gates = full) + ledger/registry count parity.
  d_gate=0
  [ "$gates" -ge 1 ] && d_gate=$(( gates > 100 ? 22 : gates / 5 ))
  local ledger="$KIT/release-ledger.json" exp
  exp="$(jq -r '.registry.expected_gate_count // empty' "$ledger" 2>/dev/null || echo '')"
  if [ -n "$exp" ] && [ "$exp" = "$gates" ]; then d_gate=$((d_gate+3)); else add_finding parity "ledger expected_gate_count ($exp) != registry gates ($gates)"; fi
  [ "$d_gate" -gt 25 ] && d_gate=25

  # DIM 2 — security (20): the load-bearing security gates exist. 8 named × 3 pts, cap 20 —
  # full credit needs ≥7 present. (v10.20 bug-fix: the prior 6-gate list maxed at 18, making the
  # declared 20-pt cap — and therefore 100/100 — unreachable; the fix RAISES the bar to 7 gates.)
  d_sec=0
  for g in security-baseline-gate authz-tenant-gate supply-chain-gate agent-security-gate ci-hardening-gate cross-tenant-probe-gate injection-resistance-gate dast-gate; do
    hook_exists "$g" && d_sec=$((d_sec+3))
  done
  [ "$d_sec" -gt 20 ] && d_sec=20

  # DIM 3 — skill routing (15): skill-index + skill-routing surfaces.
  d_skill=0
  [ -f "$KIT/skill-index.json" ] && d_skill=$((d_skill+8))
  hook_exists skill-readiness && d_skill=$((d_skill+7))
  [ "$d_skill" -gt 15 ] && d_skill=15

  # DIM 4 — context economy (15): the token/context discipline.
  d_ctx=0
  hook_exists context-budget-gate && d_ctx=$((d_ctx+5))
  hook_exists cost-budget && d_ctx=$((d_ctx+4))
  [ -f "$KIT/loop-engineering/context-economics.md" ] && d_ctx=$((d_ctx+6))
  [ "$d_ctx" -gt 15 ] && d_ctx=15

  # DIM 5 — memory (10): durable state + index.
  d_mem=0
  [ -f "$KIT/loop-state.json" ] && d_mem=$((d_mem+4))
  { [ -f "$ROOT/LOOP.md" ] || [ -f "$KIT/LOOP.md" ]; } && d_mem=$((d_mem+3))
  [ -d "$KIT/loop-engineering" ] && d_mem=$((d_mem+3))
  [ "$d_mem" -gt 10 ] && d_mem=10

  # DIM 6 — self-improvement (15): readiness + gauntlet + eval discipline.
  d_self=0
  hook_exists loop-readiness-gate && d_self=$((d_self+5))
  hook_exists gate-registry-lint && d_self=$((d_self+3))
  [ -f "$KIT/ULTIMATE-UPGRADE-2026.md" ] && d_self=$((d_self+4))
  [ -d "$KIT/eval-harness" ] && d_self=$((d_self+3))
  [ "$d_self" -gt 15 ] && d_self=15

  score=$((d_gate + d_sec + d_skill + d_ctx + d_mem + d_self))
  DIMS="$(jq -n --argjson g "$d_gate" --argjson s "$d_sec" --argjson k "$d_skill" --argjson c "$d_ctx" --argjson m "$d_mem" --argjson f "$d_self" --argjson gc "$gates" '{gate_coverage:$g, security:$s, skill_routing:$k, context_economy:$c, memory:$m, self_improvement:$f, gate_count:$gc}')"

  # ── Regression check vs committed baseline ─────────────────────────────────────────────────────────────
  if [ "${WALTEUR_SELFAUDIT:-}" = "rebaseline" ] || [ ! -f "$BASE" ]; then
    jq -n --argjson sc "$score" --argjson gc "$gates" --arg ids "$ids" --arg ts "$TS" '{score:$sc, gate_count:$gc, gate_ids:$ids, ts:$ts}' > "$BASE" 2>/dev/null
    add_note() { :; }
  else
    local b_score b_gc b_ids
    b_score="$(jq -r '.score // 0' "$BASE" 2>/dev/null || echo 0)"
    b_gc="$(jq -r '.gate_count // 0' "$BASE" 2>/dev/null || echo 0)"
    b_ids="$(jq -r '.gate_ids // ""' "$BASE" 2>/dev/null || echo '')"
    [ "$gates" -lt "$b_gc" ] && add_finding drift "gate count REGRESSED: $gates < baseline $b_gc — a gate silently disappeared"
    # any baseline gate id missing now?
    local missing
    missing="$(comm -23 <(printf '%s' "$b_ids" | tr ',' '\n' | sort -u) <(printf '%s' "$ids" | tr ',' '\n' | sort -u) 2>/dev/null | grep -v '^$' | paste -sd, - 2>/dev/null || echo '')"
    [ -n "$missing" ] && add_finding drift "baseline gate(s) vanished from registry: $missing"
    [ "$score" -lt "$b_score" ] && add_finding regression "harness score DROPPED: $score < baseline $b_score (an upgrade eroded coverage — investigate or WALTEUR_SELFAUDIT=rebaseline if intentional)"
  fi

  [ "$score" -lt "$FLOOR" ] && add_finding floor "harness score $score < floor $FLOOR"

  if [ "$failures" -gt 0 ]; then
    write_report FAIL "harness score $score/100 below floor or regressed" "$score"
    echo "harness-self-audit-gate: FAIL (score $score/100) -> exit 2"
    printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null | head -12 || true
    exit 2
  fi
  write_report PASS "harness score $score/100 (gate_cov $d_gate sec $d_sec skill $d_skill ctx $d_ctx mem $d_mem self $d_self)" "$score"
  echo "harness-self-audit-gate: PASS (score $score/100, $gates gates)"
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "harness-self-audit selftest FAIL - no jq (fail-closed)."; return 1; fi
  echo "harness-self-audit-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  # build a minimal "kit" with N gate hooks + registry/ledger
  mkkit() { # $1=dir  $2=ngates
    local d="$1" n="$2" i; mkdir -p "$d/walteur-kit/hooks" "$d/walteur-kit/loop-engineering" "$d/walteur-kit/eval-harness"
    : > "$d/walteur-kit/gate-registry.json"
    local ids='['; for i in $(seq 1 "$n"); do ids="$ids{\"id\":\"g$i\"}"; [ "$i" -lt "$n" ] && ids="$ids,"; done; ids="$ids]"
    printf '{"gates":%s}\n' "$ids" > "$d/walteur-kit/gate-registry.json"
    printf '{"registry":{"expected_gate_count":%s}}\n' "$n" > "$d/walteur-kit/release-ledger.json"
    for g in security-baseline-gate authz-tenant-gate supply-chain-gate agent-security-gate ci-hardening-gate cross-tenant-probe-gate injection-resistance-gate dast-gate skill-readiness context-budget-gate cost-budget loop-readiness-gate gate-registry-lint; do printf '#x\n' > "$d/walteur-kit/hooks/$g.sh"; done
    printf '{}\n' > "$d/walteur-kit/skill-index.json"; printf 'x\n' > "$d/walteur-kit/loop-engineering/context-economics.md"
    printf '{}\n' > "$d/walteur-kit/loop-state.json"; printf 'x\n' > "$d/LOOP.md"; printf 'x\n' > "$d/walteur-kit/ULTIMATE-UPGRADE-2026.md"
  }

  # 1. no kit -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/hsag.XXXXXX")"; mkdir -p "$t/src"; ck "no kit -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. healthy kit (110 gates) first run -> PASS + snapshots baseline + security dim reaches the full 20
  t="$(mktemp -d "${TMPDIR:-/tmp}/hsag.XXXXXX")"; mkkit "$t" 110; ck "healthy kit first run -> PASS" 0 "$(run "$t")"; [ -f "$t/walteur-kit/harness-audit-baseline.json" ] && { echo "  ok   - baseline snapshotted"; pass=$((pass+1)); } || { echo "  FAIL - no baseline"; fail=$((fail+1)); }
  sec="$(jq -r '.dims.security // -1' "$t/walteur-kit/harness-audit-report.json" 2>/dev/null)"
  if [ "$sec" = "20" ]; then echo "  ok   - healthy kit dims.security==20 (cap reachable)"; pass=$((pass+1)); else echo "  FAIL - healthy kit dims.security==$sec (want 20)"; fail=$((fail+1)); fi
  # 2b. legacy kit (only the original 6 security gates) -> sec caps at 18, still PASS (no false FAIL)
  t2="$(mktemp -d "${TMPDIR:-/tmp}/hsag.XXXXXX")"; mkkit "$t2" 110; rm -f "$t2/walteur-kit/hooks/injection-resistance-gate.sh" "$t2/walteur-kit/hooks/dast-gate.sh"
  rc2="$(run "$t2")"; sec2="$(jq -r '.dims.security // -1' "$t2/walteur-kit/harness-audit-report.json" 2>/dev/null)"
  if [ "$rc2" = "0" ] && [ "$sec2" = "18" ]; then echo "  ok   - legacy 6-gate kit sec==18, still PASS"; pass=$((pass+1)); else echo "  FAIL - legacy kit rc=$rc2 sec=$sec2 (want rc 0, sec 18)"; fail=$((fail+1)); fi; rm -rf "$t2"
  # 3. G1 drift: a gate vanished (110 -> 108) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/hsag.XXXXXX")"; mkkit "$t" 110; run "$t" >/dev/null; mkkit "$t" 108; ck "G1 gate count regressed -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. G2 floor: a tiny kit (5 gates, missing dims) -> FAIL (score < floor)
  t="$(mktemp -d "${TMPDIR:-/tmp}/hsag.XXXXXX")"; mkdir -p "$t/walteur-kit/hooks"; printf '{"gates":[{"id":"g1"},{"id":"g2"},{"id":"g3"},{"id":"g4"},{"id":"g5"}]}\n' > "$t/walteur-kit/gate-registry.json"; printf '{"registry":{"expected_gate_count":5}}\n' > "$t/walteur-kit/release-ledger.json"; ck "G2 thin kit -> FAIL (below floor)" 2 "$(run "$t")"; rm -rf "$t"
  # 5. G3 rebaseline: thin kit with rebaseline records new baseline -> PASS only if >= floor; thin is < floor so still FAIL-on-floor. Use healthy kit rebaseline -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/hsag.XXXXXX")"; mkkit "$t" 110; WALTEUR_ROOT="$t" WALTEUR_SELFAUDIT=rebaseline bash "$SELF" >/dev/null 2>&1; ck "G3 rebaseline healthy -> PASS" 0 "$?"; rm -rf "$t"
  # 6. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/hsag.XXXXXX")"; mkkit "$t" 110; WALTEUR_ROOT="$t" WALTEUR_SELFAUDIT=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/hsag.XXXXXX")"; mkkit "$t" 110; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # 7. FP guard: healthy kit re-run with unchanged baseline -> PASS (no false drift)
  t="$(mktemp -d "${TMPDIR:-/tmp}/hsag.XXXXXX")"; mkkit "$t" 110; run "$t" >/dev/null; ck "G4 unchanged re-run -> PASS (no false drift)" 0 "$(run "$t")"; rm -rf "$t"

  # 8. jq absent -> fail-closed exit 2 (jq is a hard dependency for a self-audit; never silent-skip)
  t="$(mktemp -d "${TMPDIR:-/tmp}/hsag.XXXXXX")"; mkkit "$t" 110
  nojq="$(IFS=:; np=""; for d in $PATH; do [ -x "$d/jq" ] || np="${np:+$np:}$d"; done; printf '%s' "$np")"
  rc=0; PATH="$nojq" WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1 || rc=$?
  ck "jq absent -> FAIL exit 2 (fail-closed)" 2 "$rc"; rm -rf "$t"

  echo "harness-self-audit-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
