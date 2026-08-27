#!/usr/bin/env bash
# WALTEUR gate-utilization — the SUBTRACTIVE audit (v9.2 quick win). The one report that asks what to REMOVE.
#
# PURPOSE: WALTEUR accretes gates. This is the only surface that mines real builds for which hooks ever EARNED
#   their place — and produces a retire-or-justify list. It reads walteur-kit/run-trace.jsonl (the v9.2 span
#   ledger), classifies every gate that appeared into USED (ever engaged with a real verdict) vs ONLY-SKIP
#   (appeared but never did anything but skip), and cross-references the hooks/ directory to list gates that
#   NEVER appeared in any trace at all.
#
# HONESTY LAW — the load-bearing distinction this report MUST never blur:
#   * USED            = the gate appeared in run-trace with a NON-SKIP verdict on at least one real build.
#                       Proven to engage. Keep.
#   * ONLY-SKIP       = the gate appeared but EVERY appearance was SKIP/NOT_APPLICABLE. A retire-or-justify
#                       candidate: either it is genuinely inapplicable to this project's stack (legitimate —
#                       justify and keep) or it is dead weight (retire). Human judgment, not auto-action.
#   * NOT-FOUND       = the gate has ZERO spans in the trace. This is NOT proof it is unused. Absence of a
#                       signal is NOT-FOUND, never PROVEN-unused (the trace may be short/young, or the gate
#                       runs on a stack this project doesn't have). The report states this explicitly and
#                       NEVER lists a NOT-FOUND gate as "retire".
#
# NEVER auto-deletes anything. NEVER recommends retiring a HARD security/floor gate even if it shows ONLY-SKIP
#   (a security gate that skipped just means no finding THIS run — absence of a finding is NOT-FOUND). The
#   protected set is named below and is hard-coded to "JUSTIFY (security floor — never retire)".
#
# CONTRACT (PROTOCOL report, not a HARD gate):
#   no run-trace.jsonl  => verdict:NO_TRACE, exit 0  (nothing built yet through the tracer; can't audit utilization).
#   trace present        => verdict:REPORT, exit 0   (prints the three buckets + writes a JSON report).
#   This script is READ-ONLY: it never writes to run-trace.jsonl, never deletes a hook, never exits 2 on findings.
#   exit 2 is reserved ONLY for the PAUSED kill switch and a --selftest failure.
#
# Universal controls:
#   kill switch  walteur-kit/PAUSED present  => exit 2.
#   bypass       WALTEUR_GATEUTIL=off        => LOUD skip, exit 0.
#   override the trace path (selftest/CI):   WALTEUR_TRACE_FILE=<path>.
#
# Zero-dep: bash + jq (jq mandated — it parses the JSONL spans; LOUD-SKIP exit 0 if jq absent).
# Report: walteur-kit/gate-utilization-report.json. Read-only against run-trace.jsonl. graphify stays the brain.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
HOOKS_DIR="$KIT/hooks"
TRACE="${WALTEUR_TRACE_FILE:-$KIT/run-trace.jsonl}"
REPORT="$KIT/gate-utilization-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# HARD security/floor gates — NEVER recommended for retirement, even if ONLY-SKIP (absence of a finding is
# NOT-FOUND, not proof the gate is dead). Matched by hook basename WITHOUT the .sh suffix, as a gate name.
is_security_floor() { # $1=gate-name (no .sh)
  case "$1" in
    security-gate|osv-gate|container-scan|iac-scan|compliance-gate|confidentiality-gate|ai-safety-gate|skill-readiness)
      return 0 ;;
    *) return 1 ;;
  esac
}

# verdicts that count as "the gate did nothing" (not engagement)
is_skip_verdict() { # $1=verdict
  case "$1" in
    SKIP|skip|NOT_APPLICABLE|not_applicable|""|null|NONE) return 0 ;;
    *) return 1 ;;
  esac
}

# ── embedded selftest ────────────────────────────────────────────────────────────
selftest() {
  local fails=0 total=0 tmp rc
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  ck() { # $1=label $2=want $3=got
    total=$((total+1))
    if [ "$3" = "$2" ]; then echo "  ok   — $1"
    else echo "  FAIL — $1 (want=$2, got=$3)"; fails=$((fails+1)); fi
  }

  echo "gate-utilization selftest:"

  if ! have jq; then
    echo "  SKIP — jq absent; selftest needs jq to build the synthetic trace. (recorded, not silent-green)"
    echo "gate-utilization selftest: 0/0 passed (jq missing)"
    return 0
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gateutil-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/hooks"

  # A synthetic run-trace.jsonl: perf-gate USED (FAIL once, PASS once), i18n-lint ONLY-SKIP, security-gate ONLY-SKIP.
  # maintainability-gate has a hook file but NO spans -> NOT-FOUND.
  local TF="$tmp/walteur-kit/run-trace.jsonl"
  emit_span() { # $1=tool(gate)  $2=verdict
    jq -cn --arg tool "$1" --arg gv "$2" \
      '{ts:"2026-06-20T00:00:00Z",phase:"ship",model:"sonnet",tool:$tool,exit_code:"0",gate_verdict:$gv,tokens:{estimate:0}}' >> "$TF"
  }
  emit_span perf-gate FAIL
  emit_span perf-gate PASS
  emit_span perf-gate SKIP
  emit_span i18n-lint SKIP
  emit_span i18n-lint SKIP
  emit_span security-gate SKIP
  # a non-gate span (empty gate_verdict, tool=Bash) must be ignored entirely
  jq -cn '{ts:"2026-06-20T00:00:00Z",phase:"build",model:"sonnet",tool:"Bash",exit_code:"0",gate_verdict:"",tokens:{estimate:10}}' >> "$TF"

  # hooks present on disk (for NOT-FOUND cross-reference)
  for g in perf-gate i18n-lint security-gate maintainability-gate; do
    printf '#!/usr/bin/env bash\n' > "$tmp/walteur-kit/hooks/$g.sh"
  done

  # run the audit
  set +e
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  set -e
  ck "report run: exit 0" 0 "$rc"

  local rep="$tmp/walteur-kit/gate-utilization-report.json"
  ck "report written" 0 "$([ -f "$rep" ] && echo 0 || echo 1)"

  # perf-gate -> USED
  ck "perf-gate classified USED" "USED" "$(jq -r '.used[]?' "$rep" 2>/dev/null | grep -x perf-gate >/dev/null && echo USED || echo MISSING)"
  # i18n-lint -> ONLY-SKIP (retire-or-justify candidate)
  ck "i18n-lint classified ONLY-SKIP" "ONLY-SKIP" "$(jq -r '.only_skip[]?.gate' "$rep" 2>/dev/null | grep -x i18n-lint >/dev/null && echo ONLY-SKIP || echo MISSING)"
  # security-gate -> ONLY-SKIP but marked JUSTIFY (never retire)
  ck "security-gate ONLY-SKIP but protected (never retire)" "PROTECTED" "$(jq -r --arg g security-gate '.only_skip[]? | select(.gate==$g) | .recommendation' "$rep" 2>/dev/null | grep -qi 'never retire\|justify' && echo PROTECTED || echo NOT-PROTECTED)"
  # security-gate must NOT appear in any retire list
  ck "security-gate NOT in retire candidates" 0 "$(jq -r '.retire_candidates[]?' "$rep" 2>/dev/null | grep -x security-gate >/dev/null && echo 1 || echo 0)"
  # i18n-lint IS a retire candidate (non-protected ONLY-SKIP)
  ck "i18n-lint IS a retire candidate" 0 "$(jq -r '.retire_candidates[]?' "$rep" 2>/dev/null | grep -x i18n-lint >/dev/null && echo 0 || echo 1)"
  # maintainability-gate -> NOT-FOUND (hook on disk, zero spans)
  ck "maintainability-gate classified NOT-FOUND" "NOT-FOUND" "$(jq -r '.not_found[]?' "$rep" 2>/dev/null | grep -x maintainability-gate >/dev/null && echo NOT-FOUND || echo MISSING)"
  # NOT-FOUND must NEVER be a retire candidate (absence != proven-unused)
  ck "maintainability-gate NOT-FOUND is NOT a retire candidate" 0 "$(jq -r '.retire_candidates[]?' "$rep" 2>/dev/null | grep -x maintainability-gate >/dev/null && echo 1 || echo 0)"
  # honesty flag present
  ck "report carries the NOT-FOUND honesty note" 0 "$(jq -e '.honesty | test("NOT-FOUND")' "$rep" >/dev/null 2>&1 && echo 0 || echo 1)"
  rm -rf "$tmp"

  # NO TRACE -> verdict NO_TRACE, exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gateutil-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/hooks"
  set +e
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  set -e
  ck "no trace: exit 0" 0 "$rc"
  ck "no trace: verdict NO_TRACE" "NO_TRACE" "$(jq -r .verdict "$tmp/walteur-kit/gate-utilization-report.json" 2>/dev/null || echo NO_TRACE)"
  rm -rf "$tmp"

  # bypass WALTEUR_GATEUTIL=off -> exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gateutil-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  echo '{}' > "$tmp/walteur-kit/run-trace.jsonl"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_GATEUTIL=off bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  set -e
  ck "bypass off: exit 0" 0 "$rc"
  rm -rf "$tmp"

  # PAUSED -> exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gateutil-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  set +e
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  set -e
  ck "PAUSED: exit 2" 2 "$rc"
  rm -rf "$tmp"

  echo "gate-utilization selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest; exit $?
fi

# ── universal controls ───────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). gate-utilization exiting 2." >&2; exit 2; }

if [ "${WALTEUR_GATEUTIL:-on}" = "off" ]; then
  echo "gate-utilization: SKIP — WALTEUR_GATEUTIL=off (loud skip, not silent-green)." >&2
  exit 0
fi

if ! have jq; then
  echo "gate-utilization: SKIP — jq not installed (needed to parse run-trace.jsonl spans). recorded, not silent-green." >&2
  printf '{"verdict":"SKIP","ts":"%s","gate":"gate-utilization","reason":"jq missing"}\n' "$TS" > "$REPORT" 2>/dev/null || true
  exit 0
fi

if [ ! -f "$TRACE" ]; then
  echo "gate-utilization: NO_TRACE — no run-trace.jsonl at $TRACE. Nothing built through the tracer yet; cannot audit utilization." >&2
  echo "  (Absence of a trace is NOT-FOUND, never proof a gate is unused.)" >&2
  jq -n --arg ts "$TS" --arg trace "$TRACE" \
    '{verdict:"NO_TRACE", ts:$ts, gate:"gate-utilization",
      reason:"run-trace.jsonl absent — cannot audit which gates earned their place",
      honesty:"Absence of a trace is NOT-FOUND, never PROVEN-unused. No gate is recommended for retirement without real spans.",
      trace_path:$trace}' > "$REPORT" 2>/dev/null || true
  exit 0
fi

echo "WALTEUR gate-utilization (subtractive audit) @ $TRACE" >&2

# ── 1. classify gates that APPEARED in the trace (per gate: did any span engage non-SKIP?) ──
# A "gate span" = a span whose gate_verdict is set AND tool is a gate-ish name. We treat .tool as the gate
# identity for spans that carry a non-empty gate_verdict (run-trace puts the gate name in .tool when it
# emits a gate verdict; non-gate spans leave gate_verdict empty and are filtered out below).
#
# For each distinct gate: USED if MAX-engagement seen (any non-skip verdict), else ONLY-SKIP.
USED_JSON='[]'
ONLY_SKIP_JSON='[]'
RETIRE_JSON='[]'

# Build a TSV: gate \t had_non_skip(0|1) \t span_count \t verdicts_csv
GATE_TSV="$(jq -rs '
  [ .[] | select((.gate_verdict // "") != "") | {gate:(.tool // ""), v:(.gate_verdict // "")} ]
  | map(select(.gate != ""))
  | group_by(.gate)
  | map({
      gate: .[0].gate,
      span_count: length,
      verdicts: (map(.v) | unique | join(",")),
      non_skip: ( ( map(.v) | map(select(. != "SKIP" and . != "skip" and . != "NOT_APPLICABLE" and . != "not_applicable" and . != "NONE")) | length ) > 0 )
    })
  | .[] | [.gate, (if .non_skip then "1" else "0" end), (.span_count|tostring), .verdicts] | @tsv
' "$TRACE" 2>/dev/null || true)"

echo "  Gates that appeared in the trace:" >&2
while IFS=$'\t' read -r gate non_skip span_count verdicts; do
  [ -n "$gate" ] || continue
  if [ "$non_skip" = "1" ]; then
    echo "    USED       $gate  ($span_count spans; verdicts: $verdicts)" >&2
    USED_JSON="$(printf '%s' "$USED_JSON" | jq --arg g "$gate" '. + [$g]')"
  else
    # ONLY-SKIP. Protected security floor => JUSTIFY, never retire. Else => retire candidate.
    if is_security_floor "$gate"; then
      rec="JUSTIFY — security floor; a SKIP means no finding THIS run (NOT-FOUND), never retire."
      echo "    ONLY-SKIP  $gate  ($span_count spans; PROTECTED security floor — never retire)" >&2
    else
      rec="RETIRE-OR-JUSTIFY — appeared but never engaged; confirm it applies to this stack or retire."
      echo "    ONLY-SKIP  $gate  ($span_count spans; retire-or-justify candidate)" >&2
      RETIRE_JSON="$(printf '%s' "$RETIRE_JSON" | jq --arg g "$gate" '. + [$g]')"
    fi
    ONLY_SKIP_JSON="$(printf '%s' "$ONLY_SKIP_JSON" | jq \
      --arg g "$gate" --arg sc "$span_count" --arg v "$verdicts" --arg r "$rec" \
      '. + [{gate:$g, span_count:($sc|tonumber), verdicts:$v, recommendation:$r}]')"
  fi
done <<< "$GATE_TSV"

# ── 2. cross-reference hooks/ on disk → gates with ZERO spans = NOT-FOUND (never proven-unused) ──
NOT_FOUND_JSON='[]'
SEEN_GATES="$(printf '%s' "$GATE_TSV" | cut -f1 | sort -u)"
if [ -d "$HOOKS_DIR" ]; then
  echo "  Gates on disk with ZERO spans (NOT-FOUND — never proven-unused, never auto-retire):" >&2
  while IFS= read -r hookpath; do
    [ -n "$hookpath" ] || continue
    gname="$(basename "$hookpath" .sh)"
    # only consider gate-ish hooks (skip the machinery / non-gate helpers by name convention)
    case "$gname" in
      _*|run-trace|kill-switch|gate-guard|tdd-guard|ship-gate) continue ;;
    esac
    if ! printf '%s\n' "$SEEN_GATES" | grep -qx "$gname"; then
      echo "    NOT-FOUND  $gname" >&2
      NOT_FOUND_JSON="$(printf '%s' "$NOT_FOUND_JSON" | jq --arg g "$gname" '. + [$g]')"
    fi
  done < <(find "$HOOKS_DIR" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | sort)
fi

USED_N="$(printf '%s' "$USED_JSON" | jq 'length')"
SKIP_N="$(printf '%s' "$ONLY_SKIP_JSON" | jq 'length')"
RETIRE_N="$(printf '%s' "$RETIRE_JSON" | jq 'length')"
NF_N="$(printf '%s' "$NOT_FOUND_JSON" | jq 'length')"

echo "gate-utilization: REPORT — $USED_N used · $SKIP_N only-skip ($RETIRE_N retire-or-justify) · $NF_N not-found (never auto-retired). -> $REPORT" >&2

jq -n \
  --arg ts "$TS" --arg trace "$TRACE" \
  --argjson used "$USED_JSON" --argjson only_skip "$ONLY_SKIP_JSON" \
  --argjson retire "$RETIRE_JSON" --argjson not_found "$NOT_FOUND_JSON" \
  '{verdict:"REPORT", ts:$ts, gate:"gate-utilization", trace_path:$trace,
    summary:{used:($used|length), only_skip:($only_skip|length),
             retire_candidates:($retire|length), not_found:($not_found|length)},
    used:$used,
    only_skip:$only_skip,
    retire_candidates:$retire,
    not_found:$not_found,
    honesty:"A NOT-FOUND gate has ZERO spans — absence of a signal is NOT-FOUND, never PROVEN-unused; it is never listed for retirement. ONLY-SKIP security-floor gates are PROTECTED (a SKIP = no finding this run, not a dead gate). This report recommends; a human ratifies. It NEVER auto-deletes a hook."}' \
  > "$REPORT" 2>/dev/null || {
    printf '{"verdict":"REPORT","ts":"%s","gate":"gate-utilization","summary":{"used":%s,"only_skip":%s,"retire_candidates":%s,"not_found":%s}}\n' \
      "$TS" "$USED_N" "$SKIP_N" "$RETIRE_N" "$NF_N" > "$REPORT"
  }
exit 0
