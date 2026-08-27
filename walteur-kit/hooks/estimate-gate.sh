#!/usr/bin/env bash
# WALTEUR estimate-gate - proves the build has an upfront time, token, and cost estimate.
#
# Contract:
#   - estimate.json and STATE.json absent => NOT_APPLICABLE, exit 0.
#   - STATE.json present but estimate missing => FAIL, exit 2.
#   - jq absent => SKIP, exit 0, recorded loudly.
#   - malformed estimate or state => FAIL, exit 2.
#   - phase beyond intake with zero placeholder estimate => FAIL, exit 2.
#   - STATE.budgets mismatch estimate expected values => FAIL, exit 2.
#   - valid estimate => PASS, exit 0.
#   - walteur-kit/PAUSED => exit 2.
#
# Report:
#   walteur-kit/estimate-report.json
#
# Bypass:
#   WALTEUR_ESTIMATE_GATE=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "estimate-gate - proves the build has an upfront time, token, and cost estimate."
  printf '%s\n' "usage: bash estimate-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/estimate-report.json - fix recipes: walteur-kit/REMEDIATION.md (## estimate-gate)"
  printf '%s\n' "bypass: WALTEUR_ESTIMATE_GATE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
ESTIMATE="${WALTEUR_ESTIMATE_FILE:-$KIT/estimate.json}"
STATE="${WALTEUR_STATE_FILE:-$KIT/autopilot/STATE.json}"
REPORT="$KIT/estimate-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  verdict="$1"
  reason="$2"
  findings="${3:-[]}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" \
      --arg estimate "${ESTIMATE#"$ROOT"/}" --arg state "${STATE#"$ROOT"/}" \
      --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"estimate-gate", estimate_file:$estimate, state_file:$state, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"estimate-gate","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

selftest() {
  pass=0
  fail=0
  ck() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  if ! have jq; then
    echo "estimate-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    dst="$1"
    phase="$2"
    minutes="$3"
    input_tokens="$4"
    output_tokens="$5"
    cost_usd="$6"
    mkdir -p "$(dirname "$dst")"
    cat > "$dst" <<JSON
{
  "schema_version": 1,
  "run_id": "estimate-selftest",
  "goal": "prove estimate discipline",
  "build_class": "software",
  "risk_tier": "medium",
  "phase": "$phase",
  "autonomy_policy": "full_autopilot",
  "budgets": {
    "time_minutes": $minutes,
    "input_tokens": $input_tokens,
    "output_tokens": $output_tokens,
    "cost_usd": $cost_usd
  },
  "stages": [],
  "gates": [],
  "evidence": [],
  "updated_at": "2026-06-22T00:00:00Z"
}
JSON
  }

  write_estimate() {
    dst="$1"
    phase="$2"
    best_minutes="$3"
    expected_minutes="$4"
    worst_minutes="$5"
    best_tokens="$6"
    expected_tokens="$7"
    worst_tokens="$8"
    input_tokens="$9"
    output_tokens="${10}"
    best_usd="${11}"
    expected_usd="${12}"
    worst_usd="${13}"
    mkdir -p "$(dirname "$dst")"
    cat > "$dst" <<JSON
{
  "schema_version": 1,
  "estimate_id": "estimate-selftest",
  "goal": "prove estimate discipline",
  "phase": "$phase",
  "minutes": { "best": $best_minutes, "expected": $expected_minutes, "worst": $worst_minutes },
  "tokens": {
    "best": $best_tokens,
    "expected": $expected_tokens,
    "worst": $worst_tokens,
    "input": $input_tokens,
    "output": $output_tokens
  },
  "usd": { "best": $best_usd, "expected": $expected_usd, "worst": $worst_usd },
  "assumptions": ["Selftest estimate assumptions are explicit."],
  "created_at": "2026-06-22T00:00:00Z"
}
JSON
  }

  echo "estimate-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/estimate-gate-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no estimate and no STATE -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/estimate-gate-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "intake" 0 0 0 0
  write_estimate "$tmp/walteur-kit/estimate.json" "intake" 0 0 0 0 0 0 0 0 0 0 0
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "intake zero estimate -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/estimate-gate-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "plan" 60 1200 300 1.25
  write_estimate "$tmp/walteur-kit/estimate.json" "plan" 30 60 90 1000 1500 2500 1200 300 0.50 1.25 2.00
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "plan estimate matches STATE budgets -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/estimate-gate-selftest.XXXXXX")" || return 1
  write_estimate "$tmp/walteur-kit/estimate.json" "plan" 0 0 0 0 0 0 0 0 0 0 0
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "standalone plan zero estimate -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/estimate-gate-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "plan" 60 1200 300 1.25
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "STATE present but estimate missing -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/estimate-gate-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "plan" 0 0 0 0
  write_estimate "$tmp/walteur-kit/estimate.json" "plan" 0 0 0 0 0 0 0 0 0 0 0
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "post-intake zero estimate -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/estimate-gate-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "plan" 61 1200 300 1.25
  write_estimate "$tmp/walteur-kit/estimate.json" "plan" 30 60 90 1000 1500 2500 1200 300 0.50 1.25 2.00
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "STATE budget mismatch -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/estimate-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{ bad json\n' > "$tmp/walteur-kit/estimate.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "malformed estimate JSON -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/estimate-gate-selftest.XXXXXX")" || return 1
  write_estimate "$tmp/walteur-kit/estimate.json" "plan" 90 60 30 1000 1500 2500 1200 300 0.50 1.25 2.00
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "invalid estimate ranges -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "estimate-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_ESTIMATE_GATE:-on}" = "off" ] && {
  echo "estimate-gate: bypassed (WALTEUR_ESTIMATE_GATE=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_ESTIMATE_GATE=off" "[]"
  exit 0
}

if [ ! -f "$ESTIMATE" ]; then
  if [ ! -f "$STATE" ]; then
    echo "estimate-gate: no estimate.json or STATE.json found - gate not applicable." >&2
    write_report "NOT_APPLICABLE" "estimate.json and STATE.json absent" "[]"
    exit 0
  fi
  findings='[{"check":"estimate.present","message":"STATE.json exists, so walteur-kit/estimate.json is required"}]'
  write_report "FAIL" "estimate.json missing while STATE.json exists" "$findings"
  echo "estimate-gate verdict: FAIL - estimate.json missing while STATE.json exists -> $REPORT" >&2
  exit 2
fi

if ! have jq; then
  echo "estimate-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  write_report "SKIP" "jq not installed" "[]"
  exit 0
fi

if ! jq empty "$ESTIMATE" >/dev/null 2>&1; then
  findings='[{"check":"json","message":"estimate.json is not valid JSON"}]'
  write_report "FAIL" "estimate.json is not valid JSON" "$findings"
  echo "estimate-gate verdict: FAIL - estimate.json is not valid JSON -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

if ! jq -e '
  type == "object"
  and .schema_version == 1
  and (.estimate_id | type == "string" and length > 0)
  and (.goal | type == "string" and length > 0)
  and (.phase as $p | ["intake","discover","plan"] | index($p))
  and (.minutes | type == "object")
  and (.minutes.best | type == "number" and . >= 0)
  and (.minutes.expected | type == "number" and . >= 0)
  and (.minutes.worst | type == "number" and . >= 0)
  and (.tokens | type == "object")
  and (.tokens.best | type == "number" and . >= 0 and floor == .)
  and (.tokens.expected | type == "number" and . >= 0 and floor == .)
  and (.tokens.worst | type == "number" and . >= 0 and floor == .)
  and ((.tokens | has("input") | not) or (.tokens.input | type == "number" and . >= 0 and floor == .))
  and ((.tokens | has("output") | not) or (.tokens.output | type == "number" and . >= 0 and floor == .))
  and (.usd | type == "object")
  and (.usd.best | type == "number" and . >= 0)
  and (.usd.expected | type == "number" and . >= 0)
  and (.usd.worst | type == "number" and . >= 0)
  and (.assumptions | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
  and (.created_at | type == "string" and length > 0)
' "$ESTIMATE" >/dev/null 2>&1; then
  add_finding "estimate.shape" "estimate.json must match walteur-kit/schemas/estimate.schema.json"
fi

if ! jq -e '
  .minutes.best <= .minutes.expected
  and .minutes.expected <= .minutes.worst
  and .tokens.best <= .tokens.expected
  and .tokens.expected <= .tokens.worst
  and .usd.best <= .usd.expected
  and .usd.expected <= .usd.worst
  and (((.tokens.input // 0) + (.tokens.output // 0)) <= .tokens.expected)
' "$ESTIMATE" >/dev/null 2>&1; then
  add_finding "estimate.ranges" "estimate ranges must be best <= expected <= worst, with input+output <= expected tokens"
fi

placeholder_hits="$(jq -r '
  [.. | strings | select(test("(todo|tbd|placeholder|estimate pending|unknown)"; "i"))] | length
' "$ESTIMATE" 2>/dev/null || echo 1)"
if [ "$placeholder_hits" -gt 0 ]; then
  add_finding "estimate.placeholders" "estimate.json must not contain TODO, TBD, placeholder, pending, or unknown text"
fi

effective_phase="$(jq -r '.phase // ""' "$ESTIMATE" 2>/dev/null || echo "")"

if [ -f "$STATE" ]; then
  if ! jq empty "$STATE" >/dev/null 2>&1; then
    add_finding "state.json" "STATE.json is not valid JSON, so budgets cannot be reconciled"
  else
    effective_phase="$(jq -r '.phase // ""' "$STATE")"

    if ! jq -e -n --slurpfile e "$ESTIMATE" --slurpfile s "$STATE" '
      def abs: if . < 0 then -. else . end;
      def close($a; $b): (($a - $b) | abs) <= 0.000001;
      ($e[0]) as $e
      | ($s[0]) as $s
      | (($e.tokens.input // $e.tokens.expected) | floor) as $input_tokens
      | (($e.tokens.output // 0) | floor) as $output_tokens
      | close($e.minutes.expected; $s.budgets.time_minutes)
        and ($input_tokens == $s.budgets.input_tokens)
        and ($output_tokens == $s.budgets.output_tokens)
        and close($e.usd.expected; $s.budgets.cost_usd)
    ' >/dev/null 2>&1; then
      add_finding "state.budgets" "STATE.budgets must match estimate expected minutes, tokens, and cost"
    fi
  fi
fi

if ! jq -e --arg phase "$effective_phase" '
  if $phase == "intake" or $phase == "stopped" then true
  else (.minutes.expected > 0 and .tokens.expected > 0)
  end
' "$ESTIMATE" >/dev/null 2>&1; then
  add_finding "estimate.nonzero" "phase beyond intake requires positive expected minutes and tokens"
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "$failures estimate violation(s)" "$findings"
  echo "estimate-gate verdict: FAIL - $failures violation(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "estimate valid and reconciled" "$findings"
echo "estimate-gate verdict: PASS -> $REPORT" >&2
exit 0
