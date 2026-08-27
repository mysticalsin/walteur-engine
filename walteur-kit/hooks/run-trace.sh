#!/usr/bin/env bash
# WALTEUR run-trace — flat append-only telemetry ledger. NOT a retrieval store; graphify is the one brain.
#
# CONTRACT:
#   no args Default gate mode. Writes run-trace-report.json. NOT_APPLICABLE before
#           trace enforcement is due; FAIL for non-intake runs with no usable trace.
#   emit    Append one span: {ts,phase,model,tool,exit_code,gate_verdict,tokens}.
#           Optional: tool_signature, a normalized command/tool-input signature for redundancy mining.
#           Optional: --command derives a conservative tool_signature for known-safe equivalent command forms.
#           tokens field is ALWAYS labeled "estimate" — never "metered".
#           Does NOT log build outcomes (shippable/applied_ids/composite) — those belong to pending-feedback.jsonl.
#   --rollup  Derive usage.jsonl grouped by {phase,model}, sum estimate tokens. Idempotent (overwrite).
#   --read    Pretty-print spans table (read-only, exits 0).
#   --spawn-roi  Advisory recommendation summary from spawn-justification.json (S8 — recorded-only advisory,
#               NOT a realized-vs-actual measurement). Read-only. Does NOT report per-task token ROI: run-trace
#               has no per-task-id spans — the BUILD phase emits one span per phase, not one per task.
#   --selftest  Hermetic: emit 3 spans / 2 phases → validate 7 keys + optional signature + rollup + WALTEUR_TRACE=off + spawn-roi + gate mode.
#
# Respects:
#   walteur-kit/PAUSED        exit 2 (gate law — paused means not green)
#   WALTEUR_TRACE=off         loud skip, exit 0, no file written
#
# Zero-dep: bash + jq (printf fallback for emit). No daemon. Synchronous append only.
# Never indexed: only grep/jq-scanned. Flat file, kit idiom (like ab-results.jsonl).
#
# LEDGER: walteur-kit/run-trace.jsonl  (append-only; never truncated by this script)
# ROLLUP: walteur-kit/usage.jsonl      (derived on demand; overwrite)
set -uo pipefail

# ── self-root ──────────────────────────────────────────────────────────────────
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
TRACE="$KIT/run-trace.jsonl"
USAGE="$KIT/usage.jsonl"
STATE="${WALTEUR_STATE_FILE:-$KIT/autopilot/STATE.json}"
REPORT="$KIT/run-trace-report.json"
SPAWNJUST="$KIT/spawn-justification.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

trim_collapse() {
  printf '%s' "${1-}" | tr '\n\r\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

strip_outer_quotes() {
  local s="${1-}"
  while :; do
    case "$s" in
      \"*\")
        [ "${s%\"}" != "$s" ] || break
        s="${s#\"}"
        s="${s%\"}"
        ;;
      \'*\')
        [ "${s%\'}" != "$s" ] || break
        s="${s#\'}"
        s="${s%\'}"
        ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

normalize_command_signature() {
  local cmd rest manager
  cmd="$(trim_collapse "${1-}")"
  [ -n "$cmd" ] || return 0

  # Strip one or more shell command wrappers. The inner command must still match
  # a known-safe command family before any signature is emitted.
  while [[ "$cmd" =~ ^(bash|sh|zsh)[[:space:]]+-(lc|c)[[:space:]]+(.+)$ ]]; do
    cmd="$(strip_outer_quotes "${BASH_REMATCH[3]}")"
    cmd="$(trim_collapse "$cmd")"
  done

  for manager in npm pnpm yarn; do
    if [[ "$cmd" =~ ^${manager}[[:space:]]+test($|[[:space:]]+(.+)$) ]]; then
      rest="$(trim_collapse "${BASH_REMATCH[2]:-}")"
      if [ -n "$rest" ]; then
        printf 'cmd:%s:test %s' "$manager" "$rest"
      else
        printf 'cmd:%s:test' "$manager"
      fi
      return 0
    fi
    if [[ "$cmd" =~ ^${manager}[[:space:]]+run[[:space:]]+test($|[[:space:]]+(.+)$) ]]; then
      rest="$(trim_collapse "${BASH_REMATCH[2]:-}")"
      if [ -n "$rest" ]; then
        printf 'cmd:%s:test %s' "$manager" "$rest"
      else
        printf 'cmd:%s:test' "$manager"
      fi
      return 0
    fi
  done
}

# ── PAUSED kill switch ─────────────────────────────────────────────────────────
check_paused() {
  [ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). run-trace exiting 2." >&2; exit 2; }
}

# ── WALTEUR_TRACE=off bypass ───────────────────────────────────────────────────
check_trace_off() {
  if [ "${WALTEUR_TRACE:-on}" = "off" ]; then
    echo "run-trace: SKIP — WALTEUR_TRACE=off (no span written)." >&2
    exit 0
  fi
}

write_report() {
  local verdict="$1"
  local reason="$2"
  local findings="${3:-[]}"
  local spans="${4:-0}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" \
      --arg trace "${TRACE#"$ROOT"/}" --arg state "${STATE#"$ROOT"/}" \
      --argjson findings "$findings" --argjson spans "$spans" \
      '{verdict:$v, ts:$ts, gate:"run-trace", trace_file:$trace, state_file:$state, reason:$r, spans:$spans, findings:$findings}' \
      > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"run-trace","reason":"%s","spans":%s}\n' \
    "$verdict" "$TS" "$reason" "$spans" > "$REPORT" 2>/dev/null || true
}

gate_check() {
  check_paused

  if [ "${WALTEUR_TRACE:-on}" = "off" ]; then
    write_report "SKIP" "WALTEUR_TRACE=off" "[]" 0
    echo "run-trace gate: SKIP - WALTEUR_TRACE=off -> $REPORT" >&2
    exit 0
  fi

  if ! have jq; then
    write_report "SKIP" "jq not installed" "[]" 0
    echo "run-trace gate: SKIP - jq not installed (recorded, not silent-green)." >&2
    exit 0
  fi

  if [ ! -f "$STATE" ]; then
    write_report "NOT_APPLICABLE" "STATE.json absent" "[]" 0
    echo "run-trace gate: no STATE.json found at ${STATE#"$ROOT"/} - gate not applicable." >&2
    exit 0
  fi

  if ! jq empty "$STATE" >/dev/null 2>&1; then
    write_report "FAIL" "STATE.json is not valid JSON" '[{"check":"state.json","message":"STATE.json is not valid JSON"}]' 0
    echo "run-trace gate verdict: FAIL - STATE.json is not valid JSON -> $REPORT" >&2
    exit 2
  fi

  local phase
  phase="$(jq -r '.phase // empty' "$STATE")"
  if [ -z "$phase" ] || [ "$phase" = "intake" ] || [ "$phase" = "stopped" ]; then
    write_report "NOT_APPLICABLE" "trace gate not due for phase '${phase:-missing}'" "[]" 0
    echo "run-trace gate: phase '${phase:-missing}' is not due for trace enforcement -> $REPORT" >&2
    exit 0
  fi

  if [ ! -s "$TRACE" ]; then
    write_report "FAIL" "non-intake run has no run-trace.jsonl" '[{"check":"trace.present","message":"non-intake run needs an append-only trace ledger"}]' 0
    echo "run-trace gate verdict: FAIL - non-intake run has no trace ledger -> $REPORT" >&2
    exit 2
  fi

  if ! jq -s '.' "$TRACE" >/dev/null 2>&1; then
    write_report "FAIL" "run-trace.jsonl contains malformed JSON" '[{"check":"trace.jsonl","message":"each trace line must be valid JSON"}]' 0
    echo "run-trace gate verdict: FAIL - malformed trace ledger -> $REPORT" >&2
    exit 2
  fi

  local spans bad_keys due_spans
  spans="$(jq -s 'length' "$TRACE")"
  bad_keys="$(jq -s '
    [.[] | select(
      (has("ts") and has("phase") and has("model") and has("tool")
        and has("exit_code") and has("gate_verdict") and has("tokens")
        and ((.tokens // null) | type == "object")
        and ((.tokens.estimate // null) | type == "number")) | not
    )] | length
  ' "$TRACE")"
  if [ "$bad_keys" -gt 0 ]; then
    write_report "FAIL" "$bad_keys trace span(s) missing required keys" '[{"check":"trace.keys","message":"spans need ts, phase, model, tool, exit_code, gate_verdict, and tokens.estimate"}]' "$spans"
    echo "run-trace gate verdict: FAIL - $bad_keys span(s) missing required keys -> $REPORT" >&2
    exit 2
  fi

  due_spans="$(jq -s --arg phase "$phase" '
    def idx($p): ["intake","discover","plan","build","verify","review","ship","reflect"] | index($p);
    (idx($phase)) as $current
    | [.[] | ((.phase // "") | ascii_downcase) as $p | select((idx($p) != null) and (idx($p) <= $current))]
    | length
  ' "$TRACE")"
  if [ "$due_spans" -eq 0 ]; then
    write_report "FAIL" "trace exists but has no spans for current or prior phase" '[{"check":"trace.phase","message":"non-intake run needs spans for the current or prior phase"}]' "$spans"
    echo "run-trace gate verdict: FAIL - no due-phase spans -> $REPORT" >&2
    exit 2
  fi

  write_report "PASS" "trace ledger has usable spans for current or prior phase" "[]" "$spans"
  echo "run-trace gate verdict: PASS - $spans span(s), $due_spans due-phase span(s) -> $REPORT" >&2
  exit 0
}

# ── emit one span ──────────────────────────────────────────────────────────────
# Usage: run-trace.sh emit --phase <name> --model <name> [--tool <name>] [--exit_code <n>]
#                          [--gate_verdict <str>] [--tokens <n>] [--signature <normalized-call>]
#                          [--command <shell-command>]
emit() {
  check_paused
  check_trace_off

  local phase="" model="unknown" tool="" exit_code="" gate_verdict="" tokens="0" tool_signature="" command_input=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)        phase="$2";        shift 2 ;;
      --model)        model="$2";        shift 2 ;;
      --tool)         tool="$2";         shift 2 ;;
      --exit_code)    exit_code="$2";    shift 2 ;;
      --gate_verdict) gate_verdict="$2"; shift 2 ;;
      --tokens)       tokens="$2";       shift 2 ;;
      --signature|--tool_signature)
                      tool_signature="$2"; shift 2 ;;
      --command|--tool_input)
                      command_input="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -z "$tool_signature" ] && [ -n "$command_input" ]; then
    tool_signature="$(normalize_command_signature "$command_input")"
  fi

  if have jq; then
    jq -cn \
      --arg ts "$ts" \
      --arg phase "$phase" \
      --arg model "$model" \
      --arg tool "$tool" \
      --arg exit_code "$exit_code" \
      --arg gate_verdict "$gate_verdict" \
      --arg tool_signature "$tool_signature" \
      --argjson tokens "$tokens" \
      '{ts:$ts, phase:$phase, model:$model, tool:$tool, exit_code:$exit_code,
        gate_verdict:$gate_verdict, tokens:{estimate:$tokens}}
        + (if $tool_signature == "" then {} else {tool_signature:$tool_signature} end)' \
      >> "$TRACE"
  else
    # printf fallback — no jq
    local e_ts e_phase e_model e_tool e_exit_code e_gate_verdict e_tool_signature
    e_ts="$(json_escape "$ts")"
    e_phase="$(json_escape "$phase")"
    e_model="$(json_escape "$model")"
    e_tool="$(json_escape "$tool")"
    e_exit_code="$(json_escape "$exit_code")"
    e_gate_verdict="$(json_escape "$gate_verdict")"
    e_tool_signature="$(json_escape "$tool_signature")"
    if [ -n "$tool_signature" ]; then
      printf '{"ts":"%s","phase":"%s","model":"%s","tool":"%s","exit_code":"%s","gate_verdict":"%s","tool_signature":"%s","tokens":{"estimate":%s}}\n' \
        "$e_ts" "$e_phase" "$e_model" "$e_tool" "$e_exit_code" "$e_gate_verdict" "$e_tool_signature" "$tokens" \
        >> "$TRACE"
    else
      printf '{"ts":"%s","phase":"%s","model":"%s","tool":"%s","exit_code":"%s","gate_verdict":"%s","tokens":{"estimate":%s}}\n' \
        "$e_ts" "$e_phase" "$e_model" "$e_tool" "$e_exit_code" "$e_gate_verdict" "$tokens" \
        >> "$TRACE"
    fi
  fi
}

# ── rollup: derive usage.jsonl grouped by {phase,model} ───────────────────────
rollup() {
  check_paused

  if [ ! -f "$TRACE" ]; then
    echo "run-trace --rollup: no trace file at $TRACE — nothing to roll up." >&2
    exit 0
  fi

  if ! have jq; then
    echo "run-trace --rollup: jq not installed — rollup requires jq." >&2
    exit 1
  fi

  jq -rs '
    group_by({phase:.phase, model:.model}) |
    map({
      phase: .[0].phase,
      model: .[0].model,
      span_count: length,
      tokens_estimate: (map(.tokens.estimate // 0) | add)
    })
  ' "$TRACE" > "$USAGE"
  local groups; groups="$(jq 'length' "$USAGE" 2>/dev/null || echo "?")"
  echo "run-trace --rollup: wrote $USAGE ($groups phase-model groups)." >&2
}

# ── read: pretty-print trace table ────────────────────────────────────────────
read_trace() {
  if [ ! -f "$TRACE" ]; then
    echo "run-trace --read: no trace file at $TRACE." >&2
    exit 0
  fi

  if have jq; then
    echo "run-trace spans @ $TRACE"
    printf '%-26s %-16s %-20s %-14s %-12s %-16s %s\n' \
      "ts" "phase" "model" "exit_code" "gate_verdict" "tool" "tokens(est)"
    jq -r '. | [.ts, .phase, .model, (.exit_code//""), (.gate_verdict//""), (.tool//""), (.tokens.estimate|tostring)] | @tsv' \
      "$TRACE" | while IFS=$'\t' read -r ts phase model ec gv tool tok; do
      printf '%-26s %-16s %-20s %-14s %-12s %-16s %s\n' \
        "$ts" "$phase" "$model" "$ec" "$gv" "$tool" "$tok"
    done
  else
    cat "$TRACE"
  fi
  exit 0
}

# ── spawn-roi: advisory recommendation summary (S8) ──────────────────────────
# The spawn-justification.json (written by walteur.js BUILD) records, per task, the 6-criteria check and the
# "prefer in-session" vs "spawn" recommendation. HONESTY (recorded-only advisory, NOT a realized measurement):
# per-task wall/token attribution is NOT reported because run-trace.jsonl carries NO per-task-id spans (the
# BUILD phase emits ONE span per phase, never per task). This reader shows the RECOMMENDATION distribution only
# (how many tasks were recommended in-session vs spawn, average criteria met, per-task breakdown). It does NOT
# and CANNOT claim a "realized" saving — that would require per-task spans, which is a behavior change.
# Read-only. Exits 0 even when the artifact is absent (loud skip).
spawn_roi() {
  if [ ! -f "$SPAWNJUST" ]; then
    echo "run-trace --spawn-roi: no spawn-justification.json at $SPAWNJUST — run a build first (BUILD phase writes it)." >&2
    exit 0
  fi
  if ! have jq; then
    echo "run-trace --spawn-roi: jq not installed — spawn-roi requires jq." >&2
    exit 1
  fi
  echo "spawn-justification advisory (v9.2 #10 recommendation summary — recorded-only, NOT a realized measurement) @ $SPAWNJUST"
  jq -r '
    (.tasks // []) as $t |
    ($t | length) as $n |
    ($t | map(select(.recommend == "in-session")) | length) as $insession |
    ($t | map(select(.recommend == "spawn")) | length) as $spawn |
    ($t | map(.criteria_met // 0) | add // 0) as $sumc |
    "  tasks checked        : \($n)",
    "  recommended spawn    : \($spawn)",
    "  recommended in-sess. : \($insession)  (small + weak criteria — candidate ROI saving)",
    "  avg criteria met /6  : \(if $n > 0 then (($sumc / $n) * 100 | round / 100) else 0 end)",
    "",
    "  per-task recommendation:",
    ($t[] | "    T\(.["task-id"]) wave \(.wave): \(.recommend)  (criteria_met=\(.criteria_met // 0)/6, small=\(.small // false))")
  ' "$SPAWNJUST"
  echo "  note: per-task token/time ROI is NOT shown — run-trace.jsonl has no per-task-id spans (BUILD emits one span per phase)." >&2
  exit 0
}

# ── selftest: hermetic verification ───────────────────────────────────────────
selftest() {
  local fails=0 total=0
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/run-trace-selftest.XXXXXX")" || {
    echo "  FAIL — mktemp failed"; exit 1; }
  trap 'rm -rf "$tmp"' RETURN

  ck() { # $1=label $2=want $3=got
    total=$((total+1))
    if [ "$3" -eq "$2" ]; then
      echo "  ok   — $1"
    else
      echo "  FAIL — $1 (want=$2, got=$3)"
      fails=$((fails+1))
    fi
  }

  echo "run-trace selftest:"

  # (1) emit 3 spans / 2 phases
  WALTEUR_ROOT="$tmp" WALTEUR_TRACE=on bash "$SELF" emit \
    --phase Build --model sonnet --tool Bash --exit_code 0 --gate_verdict "" --tokens 100 --signature "bash -lc make test"
  WALTEUR_ROOT="$tmp" WALTEUR_TRACE=on bash "$SELF" emit \
    --phase Build --model sonnet --tool Write --exit_code 0 --gate_verdict "" --tokens 50
  WALTEUR_ROOT="$tmp" WALTEUR_TRACE=on bash "$SELF" emit \
    --phase Audit --model opus --tool Bash --exit_code 2 --gate_verdict "FAIL" --tokens 200

  local trace_file="$tmp/walteur-kit/run-trace.jsonl"

  # (2) 3 valid JSON lines with all 7 keys
  local line_count; line_count="$(wc -l < "$trace_file" | tr -d ' ')"
  ck "emit: 3 lines written" 3 "$line_count"

  if have jq; then
    local valid_keys; valid_keys="$(jq -r 'select(has("ts") and has("phase") and has("model") and has("tool") and has("exit_code") and has("gate_verdict") and has("tokens")) | "ok"' "$trace_file" | wc -l | tr -d ' ')"
    ck "emit: all 3 lines have 7 required keys" 3 "$valid_keys"

    local sig_count; sig_count="$(jq -r 'select(.tool_signature=="bash -lc make test") | "ok"' "$trace_file" | wc -l | tr -d ' ')"
    ck "emit: optional tool_signature recorded when supplied" 1 "$sig_count"

    WALTEUR_ROOT="$tmp" WALTEUR_TRACE=on bash "$SELF" emit \
      --phase Build --model sonnet --tool Bash --exit_code 0 --gate_verdict "" --tokens 25 \
      --command "bash -lc 'npm test -- --watch=false'"
    WALTEUR_ROOT="$tmp" WALTEUR_TRACE=on bash "$SELF" emit \
      --phase Build --model sonnet --tool Bash --exit_code 0 --gate_verdict "" --tokens 25 \
      --command "npm run test -- --watch=false"
    local normalized_count; normalized_count="$(jq -r 'select(.tool_signature=="cmd:npm:test -- --watch=false") | "ok"' "$trace_file" | wc -l | tr -d ' ')"
    ck "emit: known-equivalent npm test commands share normalized signature" 2 "$normalized_count"

    WALTEUR_ROOT="$tmp" WALTEUR_TRACE=on bash "$SELF" emit \
      --phase Build --model sonnet --tool Bash --exit_code 0 --gate_verdict "" --tokens 25 \
      --command "npm run lint"
    local unknown_normalized; unknown_normalized="$(tail -n 1 "$trace_file" | jq -r 'has("tool_signature")')"
    ck "emit: unknown command family does not receive inferred signature" 0 "$([ "$unknown_normalized" = "false" ] && echo 0 || echo 1)"

    WALTEUR_ROOT="$tmp" WALTEUR_TRACE=on bash "$SELF" emit \
      --phase Build --model sonnet --tool Bash --exit_code 0 --gate_verdict "" --tokens 25 \
      --signature "explicit:kept" --command "npm test"
    local explicit_kept; explicit_kept="$(tail -n 1 "$trace_file" | jq -r '.tool_signature')"
    ck "emit: explicit tool_signature overrides derived command signature" 0 "$([ "$explicit_kept" = "explicit:kept" ] && echo 0 || echo 1)"

    # (3) tokens always under 'estimate' label — zero 'metered'
    local metered_count; metered_count="$(grep -c '"metered"' "$trace_file" 2>/dev/null | tr -d ' \n' || echo 0)"
    ck "emit: zero metered tokens labels" 0 "$metered_count"

    # (4) zero outcome fields
    local outcome_count; outcome_count="$(grep -cE '"shippable"|"applied_ids"|"composite"' "$trace_file" 2>/dev/null | tr -d ' \n' || echo 0)"
    ck "emit: zero outcome fields in trace" 0 "$outcome_count"

    # (5) --rollup writes usage.jsonl with correct sums
    WALTEUR_ROOT="$tmp" bash "$SELF" --rollup
    local usage_file="$tmp/walteur-kit/usage.jsonl"
    ck "--rollup: usage.jsonl written" 0 "$([ -f "$usage_file" ] && echo 0 || echo 1)"

    local build_sum; build_sum="$(jq -r '.[] | select(.phase=="Build") | .tokens_estimate' "$usage_file" 2>/dev/null || echo 0)"
    ck "--rollup: Build phase tokens sum = 250" 0 "$([ "$build_sum" = "250" ] && echo 0 || echo 1)"

    local audit_sum; audit_sum="$(jq -r '.[] | select(.phase=="Audit") | .tokens_estimate' "$usage_file" 2>/dev/null || echo 0)"
    ck "--rollup: Audit phase tokens sum = 200" 0 "$([ "$audit_sum" = "200" ] && echo 0 || echo 1)"

    # (6) rollup is idempotent (second run produces byte-identical output)
    WALTEUR_ROOT="$tmp" bash "$SELF" --rollup
    local dup_sum; dup_sum="$(jq -r '.[] | select(.phase=="Build") | .tokens_estimate' "$usage_file" 2>/dev/null || echo 0)"
    ck "--rollup idempotent: Build tokens still 250 on second run" 0 "$([ "$dup_sum" = "250" ] && echo 0 || echo 1)"
  fi

  # (7) WALTEUR_TRACE=off → no file written, exit 0
  local tmp2; tmp2="$(mktemp -d "${TMPDIR:-/tmp}/run-trace-off.XXXXXX")"
  WALTEUR_ROOT="$tmp2" WALTEUR_TRACE=off bash "$SELF" emit \
    --phase Build --model sonnet --exit_code 0 --tokens 50 >/dev/null 2>&1
  local trace_off_rc=$?
  ck "WALTEUR_TRACE=off: exit 0" 0 "$trace_off_rc"
  ck "WALTEUR_TRACE=off: no trace file written" 0 "$([ ! -f "$tmp2/walteur-kit/run-trace.jsonl" ] && echo 0 || echo 1)"
  rm -rf "$tmp2"

	  # (8) --spawn-roi (S8): reads spawn-justification.json, reports advisory recommendation summary (recorded-only, not realized), exits 0.
	  if have jq; then
    local tmp3; tmp3="$(mktemp -d "${TMPDIR:-/tmp}/run-trace-spawnroi.XXXXXX")"
    mkdir -p "$tmp3/walteur-kit"
    cat > "$tmp3/walteur-kit/spawn-justification.json" <<'SJ'
{"note":"test","tasks":[
  {"task-id":1,"wave":1,"recommend":"spawn","criteria_met":6,"small":false},
  {"task-id":2,"wave":1,"recommend":"in-session","criteria_met":3,"small":true}
]}
SJ
    local roi_out; roi_out="$(WALTEUR_ROOT="$tmp3" bash "$SELF" --spawn-roi 2>/dev/null)"
    local roi_rc=$?
    ck "--spawn-roi: exit 0" 0 "$roi_rc"
    ck "--spawn-roi: counts 2 tasks checked" 0 "$(echo "$roi_out" | grep -q 'tasks checked        : 2' && echo 0 || echo 1)"
    ck "--spawn-roi: reports 1 in-session candidate" 0 "$(echo "$roi_out" | grep -q 'recommended in-sess. : 1' && echo 0 || echo 1)"
    # absent artifact → loud skip, still exit 0
    local tmp4; tmp4="$(mktemp -d "${TMPDIR:-/tmp}/run-trace-spawnroi-none.XXXXXX")"
    WALTEUR_ROOT="$tmp4" bash "$SELF" --spawn-roi >/dev/null 2>&1
    ck "--spawn-roi: absent artifact exits 0" 0 "$?"
	    rm -rf "$tmp3" "$tmp4"

	    write_gate_state() {
	      local dst="$1"
	      local phase="$2"
	      mkdir -p "$(dirname "$dst")"
	      jq -n --arg phase "$phase" '{
	        schema_version: 1,
	        run_id: "run-trace-gate-selftest",
	        goal: "prove run-trace gate mode",
	        build_class: "software",
	        risk_tier: "medium",
	        phase: $phase,
	        autonomy_policy: "full_autopilot",
	        budgets: {time_minutes: 60, input_tokens: 1000, output_tokens: 500, cost_usd: 1.25},
	        stages: [{name: $phase, status: "in_progress"}],
	        gates: [],
	        evidence: [],
	        updated_at: "2026-06-22T00:00:00Z"
	      }' > "$dst"
	    }

	    local tmp5; tmp5="$(mktemp -d "${TMPDIR:-/tmp}/run-trace-gate-none.XXXXXX")"
	    WALTEUR_ROOT="$tmp5" bash "$SELF" >/dev/null 2>&1
	    ck "gate mode: no STATE exits 0" 0 "$?"
	    ck "gate mode: no STATE reports NOT_APPLICABLE" 0 "$(jq -e '.verdict=="NOT_APPLICABLE"' "$tmp5/walteur-kit/run-trace-report.json" >/dev/null 2>&1 && echo 0 || echo 1)"
	    rm -rf "$tmp5"

	    local tmp6; tmp6="$(mktemp -d "${TMPDIR:-/tmp}/run-trace-gate-intake.XXXXXX")"
	    write_gate_state "$tmp6/walteur-kit/autopilot/STATE.json" "intake"
	    WALTEUR_ROOT="$tmp6" bash "$SELF" >/dev/null 2>&1
	    ck "gate mode: intake without trace exits 0" 0 "$?"
	    rm -rf "$tmp6"

	    local tmp7; tmp7="$(mktemp -d "${TMPDIR:-/tmp}/run-trace-gate-missing.XXXXXX")"
	    write_gate_state "$tmp7/walteur-kit/autopilot/STATE.json" "build"
	    WALTEUR_ROOT="$tmp7" bash "$SELF" >/dev/null 2>&1
	    ck "gate mode: build without trace fails" 2 "$?"
	    rm -rf "$tmp7"

	    local tmp8; tmp8="$(mktemp -d "${TMPDIR:-/tmp}/run-trace-gate-malformed.XXXXXX")"
	    write_gate_state "$tmp8/walteur-kit/autopilot/STATE.json" "build"
	    printf '{ bad json\n' > "$tmp8/walteur-kit/run-trace.jsonl"
	    WALTEUR_ROOT="$tmp8" bash "$SELF" >/dev/null 2>&1
	    ck "gate mode: malformed trace fails" 2 "$?"
	    rm -rf "$tmp8"

	    local tmp9; tmp9="$(mktemp -d "${TMPDIR:-/tmp}/run-trace-gate-valid.XXXXXX")"
	    write_gate_state "$tmp9/walteur-kit/autopilot/STATE.json" "build"
	    WALTEUR_ROOT="$tmp9" bash "$SELF" emit --phase build --model sonnet --tool Bash --exit_code 0 --gate_verdict PASS --tokens 42 >/dev/null 2>&1
	    WALTEUR_ROOT="$tmp9" bash "$SELF" >/dev/null 2>&1
	    ck "gate mode: build with usable trace passes" 0 "$?"
	    ck "gate mode: PASS report records one span" 0 "$(jq -e '.verdict=="PASS" and .spans==1' "$tmp9/walteur-kit/run-trace-report.json" >/dev/null 2>&1 && echo 0 || echo 1)"
	    rm -rf "$tmp9"
	  fi

  echo "run-trace selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

# ── dispatch ───────────────────────────────────────────────────────────────────
case "${1:-}" in
  "")           gate_check ;;
  emit)         shift; emit "$@" ;;
  --rollup)     rollup ;;
  --read)       read_trace ;;
  --spawn-roi)  spawn_roi ;;
  --selftest)   selftest; exit $? ;;
  -h|--help)
    echo "run-trace usage:" >&2
    echo "  run-trace.sh              # gate mode: verify trace ledger when due" >&2
    echo "  run-trace.sh emit --phase <name> --model <name> [--tool <name>] [--exit_code <n>] [--gate_verdict <str>] [--tokens <n>] [--signature <normalized-call>] [--command <shell-command>]" >&2
    echo "  run-trace.sh --rollup     # derive usage.jsonl" >&2
    echo "  run-trace.sh --read       # pretty-print spans" >&2
    echo "  run-trace.sh --spawn-roi  # advisory recommendation summary from spawn-justification.json (recorded-only, S8)" >&2
    echo "  run-trace.sh --selftest   # hermetic self-test" >&2
    exit 0
    ;;
  *)
    echo "run-trace usage:" >&2
    echo "  run-trace.sh              # gate mode: verify trace ledger when due" >&2
    echo "  run-trace.sh emit --phase <name> --model <name> [--tool <name>] [--exit_code <n>] [--gate_verdict <str>] [--tokens <n>] [--signature <normalized-call>] [--command <shell-command>]" >&2
    echo "  run-trace.sh --rollup     # derive usage.jsonl" >&2
    echo "  run-trace.sh --read       # pretty-print spans" >&2
    echo "  run-trace.sh --spawn-roi  # advisory recommendation summary from spawn-justification.json (recorded-only, S8)" >&2
    echo "  run-trace.sh --selftest   # hermetic self-test" >&2
    exit 1
    ;;
esac
