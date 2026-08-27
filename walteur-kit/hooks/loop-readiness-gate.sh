#!/usr/bin/env bash
# WALTEUR loop-readiness-gate — HARD gate (ULTIMATE intake: loop-engineering, Cobus Greyling / Addy Osmani, MIT).
# Loop engineering: "Harness = single session setup; Loop = harness + schedule + state + verification chain."
# WALTEUR is a harness Tony runs as an AUTONOMOUS LOOP (the /loop self-improvement + gauntlet loops). An
# unattended loop with no maker/checker verifier, no state, no path-denylist, no token budget, and no kill
# switch is how loops cause S2/S3 incidents (failure-modes.md: infinite-fix loop, state rot, verifier theater,
# over-reach, parallel collision, escalation failure). This gate ports loop-audit's 0-100 Loop Readiness Score
# and L0-L3 levels into WALTEUR's fail-closed idiom: an autonomous loop that CLAIMS a level it has not earned
# FAILs, fail-closed, before it is allowed to run unattended.
#
# Applies when an autonomous-loop surface is declared (LOOP.md, walteur-kit/loop.json, build-contract
# .autonomous_loop/.loop_level, or preflight .is_autonomous_loop). A normal app build => NOT_APPLICABLE.
# CONTRACT: loop claims L2 but lacks state/verifier => FAIL. loop claims/needs L3 (unattended) but lacks any
# hard L3 control (verifier · state · safety denylist · budget · run log · kill switch) or scores < 78 => FAIL
# exit 2. otherwise report achieved level, exit 0. no loop surface => NOT_APPLICABLE. jq absent => SKIP.
# PAUSED => exit 2. bypass WALTEUR_LOOPREADY=off.
# Report: walteur-kit/loop-readiness-report.json
# Provenance: scoring weights + L0-L3 thresholds + signal set adapted from cobusgreyling/loop-engineering
# tools/loop-audit (MIT). Re-pointed at WALTEUR surfaces (STATE.json/BATON, the 7-senior review+audit panel as
# the maker/checker verifier, security gates as the denylist, cost-budget + release-ledger as budget/run-log,
# the PAUSED sentinel + WALTEUR_X=off as the kill switch).
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "loop-readiness-gate - HARD gate (ULTIMATE intake: loop-engineering, Cobus Greyling / Addy Osmani, MIT)."
  printf '%s\n' "usage: bash loop-readiness-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/loop-readiness-report.json - fix recipes: walteur-kit/REMEDIATION.md (## loop-readiness-gate)"
  printf '%s\n' "bypass: WALTEUR_LOOPREADY=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# Resolve an ABSOLUTE path to this script BEFORE any cd, so selftest re-invocation always finds it (Win-safe).
case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
CONTRACT="$KIT/build-contract.json"
SIGNALS="$KIT/preflight-signals.json"
LOOPMANIFEST="$KIT/loop.json"
REPORT="$KIT/loop-readiness-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; sc="${3:-0}"; lv="${4:-L0}"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson sc "$sc" --arg lv "$lv" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"loop-readiness", score:$sc, level:$lv, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"loop-readiness","score":%s,"level":"%s","reason":"%s"}\n' "$v" "$TS" "$sc" "$lv" "$r" > "$REPORT" 2>/dev/null || true; }

risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }

# A file (relative to ROOT) exists and matches a case-insensitive regex (comment-stripping not needed here —
# these are human docs/config, and a denylist/kill-switch mention is the signal regardless of context).
file_has() { local f="$ROOT/$1" re="$2"; [ -f "$f" ] && grep -qiE "$re" "$f" 2>/dev/null; }
any_file_has() { local re="$1"; shift; for f in "$@"; do file_has "$f" "$re" && return 0; done; return 1; }
exists() { for f in "$@"; do [ -e "$ROOT/$f" ] && return 0; done; return 1; }

# applies(): is this build an autonomous loop we must hold to loop discipline?
applies() {
  [ -f "$LOOPMANIFEST" ] && return 0
  exists "LOOP.md" && return 0
  if [ -f "$CONTRACT" ] && have jq; then
    jq -e '(.autonomous_loop==true) or (.loop_level != null) or (.build_class=="autonomous_loop")' "$CONTRACT" >/dev/null 2>&1 && return 0
  fi
  if [ -f "$SIGNALS" ] && have jq; then
    jq -e '(.is_autonomous_loop==true) or (.autonomous_loop==true)' "$SIGNALS" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# ── PAUSED / bypass ──────────────────────────────────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { add_finding "paused" "walteur-kit/PAUSED present — gate fails closed while paused"; write_report FAIL "paused" 0 L0; echo "loop-readiness-gate: PAUSED -> exit 2"; exit 2; }
[ "${WALTEUR_LOOPREADY:-}" = "off" ] && { write_report SKIP "bypassed via WALTEUR_LOOPREADY=off" 0 L0; echo "loop-readiness-gate: bypassed"; exit 0; }

main() {
  if ! have jq; then write_report SKIP "jq not installed" 0 L0; echo "loop-readiness-gate: SKIP (no jq)"; exit 0; fi
  if ! applies; then write_report NOT_APPLICABLE "no autonomous-loop surface (no LOOP.md / loop.json / loop_level / is_autonomous_loop)" 0 L0; echo "loop-readiness-gate: NOT_APPLICABLE"; exit 0; fi

  # ── Detect the readiness signals on WALTEUR surfaces ───────────────────────────────────────────────────
  local state verifier triage loopcfg conv safety_deny human_gate budget runlog killswitch activity
  state=0; verifier=0; triage=0; loopcfg=0; conv=0; safety_deny=0; human_gate=0; budget=0; runlog=0; killswitch=0; activity=0

  exists "STATE.json" "STATE.md" "BATON.md" "walteur-kit/loop-state.json" "loop-state.json" "walteur-kit/STATE.json" && state=1
  [ -f "$SIGNALS" ] && triage=1
  any_file_has 'triage|watchlist|signal[- ]?routing' "LOOP.md" "walteur-kit/loop.json" && triage=1
  # maker/checker verifier: a declared review/audit verifier (WALTEUR's 7-senior panel + terminal audit count)
  any_file_has 'verifier|maker.?checker|review panel|terminal audit|independent.{0,12}review|adversarial.{0,12}(gauntlet|verify)' "LOOP.md" "walteur-kit/loop.json" "CLAUDE.md" && verifier=1
  exists ".claude/agents/loop-verifier.md" "walteur-kit/hooks/audit-contract-gate.sh" && verifier=1
  exists "LOOP.md" "walteur-kit/loop.json" && loopcfg=1
  exists "CLAUDE.md" "AGENTS.md" "GEMINI.md" && conv=1
  # safety: a path denylist for autonomous edits + human gates
  any_file_has 'denylist|deny.?list|auto.?merge|do not (auto.?)?edit' "LOOP.md" "walteur-kit/loop.json" "docs/safety.md" "walteur-kit/loop-safety.md" "SECURITY.md" && safety_deny=1
  any_file_has 'human gate|escalate|escalation|interrupt by exception|waiting on human|HITL' "LOOP.md" "walteur-kit/loop.json" "docs/safety.md" "walteur-kit/loop-safety.md" "CLAUDE.md" && human_gate=1
  # budget / cost observability
  exists "loop-budget.md" "walteur-kit/loop-budget.md" && budget=1
  any_file_has 'token (budget|cap|ceiling)|max tokens|budget ceiling|cost budget' "LOOP.md" "walteur-kit/loop.json" "walteur-kit/build-contract.json" && budget=1
  exists "walteur-kit/hooks/cost-budget.sh" && file_has "LOOP.md" 'budget' && budget=1
  # run log / proven activity
  exists "loop-run-log.md" "walteur-kit/loop-run-log.md" "walteur-kit/release-ledger.json" && runlog=1
  any_file_has 'last run|run log|run-log|loop run' "LOOP.md" "STATE.md" "STATE.json" "BATON.md" && activity=1
  exists "walteur-kit/release-ledger.json" && activity=1
  # kill switch
  any_file_has 'kill switch|pause.?all|PAUSED|WALTEUR_[A-Z]*=off|scheduler_delete|stop the loop' "LOOP.md" "walteur-kit/loop.json" "docs/safety.md" "walteur-kit/loop-safety.md" && killswitch=1
  exists "walteur-kit/PAUSED" && killswitch=1   # sentinel mechanism exists in the kit

  # ── Score (weights ported from loop-audit computeScore; base 10) ───────────────────────────────────────
  local score=10
  [ "$state" = 1 ]      && score=$((score+18))
  [ "$triage" = 1 ]     && score=$((score+14))
  [ "$verifier" = 1 ]   && score=$((score+14))
  [ "$loopcfg" = 1 ]    && score=$((score+9))
  [ "$conv" = 1 ]       && score=$((score+9))
  [ "$safety_deny" = 1 ] && score=$((score+4))
  [ "$human_gate" = 1 ] && score=$((score+4))
  [ "$budget" = 1 ]     && score=$((score+6))
  [ "$runlog" = 1 ]     && score=$((score+5))
  [ "$killswitch" = 1 ] && score=$((score+4))
  [ "$activity" = 1 ]   && score=$((score+6))
  [ "$score" -gt 100 ] && score=100

  # achieved level (thresholds from loop-audit: L1=38 L2=58 L3=78; L3 also needs the hard controls)
  local l3_ready=0
  if [ "$verifier" = 1 ] && [ "$state" = 1 ] && [ "$safety_deny" = 1 ] && [ "$budget" = 1 ] && [ "$runlog" = 1 ] && [ "$killswitch" = 1 ]; then l3_ready=1; fi
  local achieved=L0
  if [ "$score" -ge 78 ] && [ "$l3_ready" = 1 ]; then achieved=L3
  elif [ "$score" -ge 58 ] && [ "$triage" = 1 ] && [ "$state" = 1 ]; then achieved=L2
  elif [ "$score" -ge 38 ] && [ "$state" = 1 ]; then achieved=L1
  else achieved=L0; fi

  # target level the loop INTENDS to run at (fail-closed default for high/regulated autonomous loops)
  local declared rt target
  declared="$(jq -r '.loop_level // empty' "$CONTRACT" 2>/dev/null | tr 'a-z' 'A-Z' | tr -d '[:space:]')"
  rt="$(risk)"
  if [ -n "$declared" ]; then target="$declared"
  elif [ "$rt" = "high" ] || [ "$rt" = "regulated" ]; then target=L3   # an unattended high-risk loop must be L3-safe
  else target=L1; fi
  case "$target" in L0|L1|L2|L3) ;; *) target=L1 ;; esac

  # ── Enforce: claiming a level you have not earned is fail-closed ────────────────────────────────────────
  local missing=""
  [ "$verifier" = 1 ]    || missing="$missing maker/checker-verifier"
  [ "$state" = 1 ]       || missing="$missing state-file(STATE.json/BATON)"
  [ "$safety_deny" = 1 ] || missing="$missing path-denylist"
  [ "$budget" = 1 ]      || missing="$missing token-budget"
  [ "$runlog" = 1 ]      || missing="$missing run-log"
  [ "$killswitch" = 1 ]  || missing="$missing kill-switch"

  local rank_target rank_achieved
  case "$target"   in L0) rank_target=0;; L1) rank_target=1;; L2) rank_target=2;; L3) rank_target=3;; esac
  case "$achieved" in L0) rank_achieved=0;; L1) rank_achieved=1;; L2) rank_achieved=2;; L3) rank_achieved=3;; esac

  if [ "$rank_target" -ge 3 ]; then
    if [ "$l3_ready" != 1 ] || [ "$score" -lt 78 ]; then
      add_finding "level" "autonomous loop targets L3 (unattended) but is only ${achieved} (score ${score}/100) — missing:${missing:- none}. An unattended loop without these controls causes S2/S3 incidents (infinite-fix loop, state rot, verifier theater, over-reach). Earn L3 or run at ${achieved}."
    fi
  elif [ "$rank_target" -ge 2 ]; then
    [ "$state" = 1 ] || add_finding "level" "loop targets L2 (assisted auto-fix) but has no durable state file (STATE.json/BATON) — the loop has amnesia every run (state rot)."
    [ "$verifier" = 1 ] || add_finding "level" "loop targets L2 but has no maker/checker verifier — the agent that wrote the code cannot be the judge of it (verifier theater)."
  elif [ "$rank_target" -ge 1 ]; then
    [ "$state" = 1 ] || add_finding "level" "loop targets L1 (report-only) but has no state file — every run starts cold."
  fi

  if [ "$failures" -gt 0 ]; then
    write_report FAIL "loop readiness ${achieved} (${score}/100) below target ${target}" "$score" "$achieved"
    echo "loop-readiness-gate: FAIL (achieved ${achieved} score ${score}/100, target ${target}) -> exit 2"
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
    exit 2
  fi
  write_report PASS "loop readiness ${achieved} (${score}/100) meets target ${target}" "$score" "$achieved"
  echo "loop-readiness-gate: PASS (${achieved}, score ${score}/100, target ${target})"
  exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
selftest() {
  pass=0; fail=0
  if ! have jq; then echo "loop-readiness selftest SKIP - jq not installed."; return 0; fi
  echo "loop-readiness-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  # Build a FULLY-ready L3 loop kit, then subtract one control per case.
  fullkit() {
    local d="$1"; mkdir -p "$d/walteur-kit" "$d/docs" "$d/.claude/agents"
    printf '{"risk_tier":"high","autonomous_loop":true,"loop_level":"L3"}\n' > "$d/walteur-kit/build-contract.json"
    printf '{"is_autonomous_loop":true}\n' > "$d/walteur-kit/preflight-signals.json"
    printf '{"name":"momentum-loop"}\n' > "$d/STATE.json"
    printf '# Loop\nCadence + limits. triage watchlist. maker/checker verifier + terminal audit. kill switch: PAUSED / WALTEUR_LOOPREADY=off. Token budget ceiling. Path denylist + human gate / escalate. Last run logged.\n' > "$d/LOOP.md"
    printf '# Conventions\n' > "$d/CLAUDE.md"
    printf '# Safety\nPath denylist for auto-edit; human gate; escalate; kill switch pause-all.\n' > "$d/docs/safety.md"
    printf '# budget\ntoken budget cap; kill switch.\n' > "$d/loop-budget.md"
    printf -- '- 2026-06-27 last run | 3 findings | 0 escalations\n' > "$d/loop-run-log.md"
    printf '{"runs":[]}\n' > "$d/walteur-kit/release-ledger.json"
  }

  # 1. no loop surface -> NOT_APPLICABLE (exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"risk_tier":"medium"}\n' > "$t/walteur-kit/build-contract.json"; ck "no loop surface -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. full L3-ready kit -> PASS (exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; fullkit "$t"; ck "full L3-ready loop -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; fullkit "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # 4. bypass -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; fullkit "$t"; printf '{"risk_tier":"high","autonomous_loop":true,"loop_level":"L3"}\n' > "$t/walteur-kit/build-contract.json"; rm -f "$t/STATE.json"; WALTEUR_ROOT="$t" WALTEUR_LOOPREADY=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"

  # ── G-regressions: an L3-claimed loop MISSING one hard control must FAIL ────────────────────────────────
  # G1: no state file
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; fullkit "$t"; rm -f "$t/STATE.json"; ck "G1 L3 claim, no state -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2: no verifier (strip verifier mentions + audit gate)
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; fullkit "$t"; printf '# Loop\nCadence. triage watchlist. kill switch PAUSED. token budget cap. denylist + human gate escalate. Last run.\n' > "$t/LOOP.md"; ck "G2 L3 claim, no verifier -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3: no path denylist / safety
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; fullkit "$t"; rm -f "$t/docs/safety.md"; printf '# Loop\nCadence. triage. maker/checker verifier + terminal audit. kill switch PAUSED. token budget cap. Last run.\n' > "$t/LOOP.md"; ck "G3 L3 claim, no denylist -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G4: no token budget
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; fullkit "$t"; rm -f "$t/loop-budget.md"; printf '# Loop\nCadence. triage. maker/checker verifier + terminal audit. kill switch PAUSED. denylist + human gate escalate. Last run.\n' > "$t/LOOP.md"; ck "G4 L3 claim, no budget -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G5: no run log / activity
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; fullkit "$t"; rm -f "$t/loop-run-log.md" "$t/walteur-kit/release-ledger.json"; printf '# Loop\nCadence. triage. maker/checker verifier + terminal audit. kill switch PAUSED. token budget cap. denylist + human gate escalate.\n' > "$t/LOOP.md"; ck "G5 L3 claim, no run-log -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G6: no kill switch (strip the kill-switch term from BOTH LOOP.md AND docs/safety.md; keep denylist+human gate)
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; fullkit "$t"; printf '# Loop\nCadence. triage. maker/checker verifier + terminal audit. token budget cap. denylist + human gate escalate. Last run.\n' > "$t/LOOP.md"; printf '# Safety\nPath denylist for auto-edit; human gate; escalate.\n' > "$t/docs/safety.md"; ck "G6 L3 claim, no kill-switch -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G7: L2 target missing verifier -> FAIL (lower target still enforced)
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"risk_tier":"medium","autonomous_loop":true,"loop_level":"L2"}\n' > "$t/walteur-kit/build-contract.json"; printf '{"is_autonomous_loop":true}\n' > "$t/walteur-kit/preflight-signals.json"; printf '{"x":1}\n' > "$t/STATE.json"; printf '# Loop\ntriage watchlist\n' > "$t/LOOP.md"; ck "G7 L2 claim, no verifier -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G8 (FP guard): L1 report-only loop with just a state file -> PASS (don't over-block low targets)
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"risk_tier":"low","autonomous_loop":true,"loop_level":"L1"}\n' > "$t/walteur-kit/build-contract.json"; printf '{"is_autonomous_loop":true}\n' > "$t/walteur-kit/preflight-signals.json"; printf '{"x":1}\n' > "$t/STATE.json"; printf '# Loop\ntriage\n' > "$t/LOOP.md"; ck "G8 L1 report-only + state -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # G9 (FP guard): full kit but high-risk with NO declared level (inferred L3) -> PASS (controls all present)
  t="$(mktemp -d "${TMPDIR:-/tmp}/loopready.XXXXXX")"; fullkit "$t"; printf '{"risk_tier":"high","autonomous_loop":true}\n' > "$t/walteur-kit/build-contract.json"; ck "G9 inferred-L3 high-risk, all controls -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "loop-readiness-gate selftest: $((pass+fail==0?0:pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
