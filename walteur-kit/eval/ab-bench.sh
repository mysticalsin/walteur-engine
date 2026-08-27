#!/usr/bin/env bash
# WALTEUR ab-bench — the "prove-the-pillar-pays" A/B benchmark runner (methodology: eval/prove-pillar.md).
# Runs a task TWICE per repeat — a `with-X` arm and a `without-X` arm, single-variable, on a BALANCED
# order — captures real cost/token/time/tool-call telemetry from `claude -p`, and prints the delta so a
# human can decide if pillar X earns its place. This is the first WALTEUR machinery that MEASURES whether a
# connection/pillar actually pays (HONESTY law §1) instead of asserting it.
#
# HONEST CONTRACT (matches the kit idiom):
#   * detect-or-LOUD-SKIP: if the `claude` CLI is ABSENT, print a LOUD skip line to stderr and exit 0
#     (recorded, NOT silent-green) — UNLESS WALTEUR_ABBENCH=strict, in which case missing-CLI => exit 2.
#   * this is PROTOCOL, not a HARD discipline-gate: a real paired run exits 0 (it produces a verdict to
#     READ, it does not block a build). exit 2 is reserved for the strict-mode tool-missing posture, the
#     PAUSED kill switch, and a self-test failure.
#   * Kill switch: walteur-kit/PAUSED present => exit 2.   Bypass: WALTEUR_ABBENCH=off => LOUD skip, exit 0.
#   * the verdict (PAYS / COSTS / INCONCLUSIVE) is COMPUTED mechanically but RATIFIED by a human — net-value
#     under noise is judgment, never a mechanical certification. A measurement absent = NOT-MEASURED.
#
# Telemetry per arm (read from the `claude -p` result object; stream-json preferred, json fallback):
#   total_cost_usd · usage.input_tokens(+cache) · usage.output_tokens · duration_ms · tool_calls · num_turns · is_error
# Appended (one row per arm) to: walteur-kit/eval/ab-results.jsonl  (append-only; opt-in infra, no daemon).
#
# RUN ISOLATION (so the off-arm can't secretly have the pillar): each arm is a COLD `-p` call in a clean
# temp CWD, --strict-mcp-config so only the arm's own --mcp-config loads (off-arm = empty config), the
# pillar injected ONLY via --append-system-prompt on the with-arm, same --model both arms, never --resume.
#
# Usage:
#   bash walteur-kit/eval/ab-bench.sh --task <task.json> [--repeats N] [--model M] [--judge]
#   bash walteur-kit/eval/ab-bench.sh --selftest        # HERMETIC: parses + exercises arm-toggling with a
#                                                       # MOCK runner (NO real claude call) => exit 0
# Zero-dep beyond bash; jq used when present (fallback to printf for the JSONL row — jq is NOT mandated).
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
EVAL_DIR="$KIT/eval"
RESULTS="${WALTEUR_ABBENCH_RESULTS:-$EVAL_DIR/ab-results.jsonl}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MODE="${WALTEUR_ABBENCH:-on}"
mkdir -p "$EVAL_DIR"

have() { command -v "$1" >/dev/null 2>&1; }

# ── kill switch + bypass (checked before any work) ───────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }
if [ "$MODE" = "off" ]; then
  echo "WALTEUR ab-bench SKIP — bypass WALTEUR_ABBENCH=off (recorded, not silent-green)." >&2
  exit 0
fi

# =================================================================================
# ARM-TOGGLING LOGIC — the heart of the harness, factored out so --selftest can drive
# it with a MOCK runner (no real claude). Given (arm, task-json), it builds the exact
# flag set that differs between with/without, and emits a single-line "plan" string.
# This is the single-variable discipline: the ONLY thing that changes between arms is
# the pillar injection (append-system-prompt) and the mcp-config the arm carries.
# =================================================================================

# read_task_field <task.json> <jq-path> <fallback>  — jq when present; tiny grep/sed fallback otherwise.
read_task_field() {
  local f="$1" path="$2" fb="${3:-}"
  if have jq; then
    local v; v="$(jq -r "$path // empty" "$f" 2>/dev/null)"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    printf '%s' "$fb"; return 0
  fi
  # zero-jq fallback: only handles the flat top-level string fields the selftest needs.
  local key; key="$(printf '%s' "$path" | sed -E 's/^\.//; s/\?$//')"
  local v; v="$(grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$f" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  printf '%s' "$fb"
}

# build_arm_plan <arm:with|without> <task.json> <model>
#   Emits a TAB-separated plan line:  ARM \t MODEL \t MCP_CONFIG \t APPEND_SP_PRESENT(0|1) \t APPEND_SP_TEXT
#   The off-arm NEVER carries the pillar's append-system-prompt and passes an EMPTY mcp-config (strict).
build_arm_plan() {
  local arm="$1" task="$2" model="$3"
  local sp="" mcp="" sp_present=0
  if [ "$arm" = "with" ]; then
    sp="$(read_task_field "$task" '.pillar.with.append_system_prompt' '')"
    mcp="$(read_task_field "$task" '.pillar.mcp_config_with' '')"
    [ -n "$sp" ] && sp_present=1
  else
    # control arm: pillar OFF. No append-system-prompt; empty mcp-config under --strict-mcp-config.
    sp="$(read_task_field "$task" '.pillar.without.append_system_prompt' '')"
    mcp="$(read_task_field "$task" '.pillar.mcp_config_without' '')"
    [ -n "$sp" ] && sp_present=1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$arm" "$model" "${mcp:-NONE}" "$sp_present" "$sp"
}

# balanced_order <repeat-index>  — alternate arm order to cancel time/cache order-bias (prove-pillar §2).
balanced_order() {
  if [ $(( $1 % 2 )) -eq 0 ]; then printf 'with without'; else printf 'without with'; fi
}

# ── arm runner: REAL claude unless overridden. The override is a PATH to a sourceable file that defines a
#    shell function `ab_runner` (NOT a bare function name — a name would not survive the recursive `bash`
#    process boundary, since env vars carry strings, not function bodies; this is why the selftest's MOCK
#    is shipped as a sourced file). Contract of the runner function:
#      ab_runner <arm> <model> <mcp-config-or-NONE> <append-sp-present 0|1> <append-sp-text> <prompt> <out-json-path>
#      must WRITE a claude-style result JSON to <out-json-path> and exit 0 (non-zero on failure).
RUNNER="real_claude_runner"
if [ -n "${WALTEUR_ABBENCH_RUNNER:-}" ] && [ -r "${WALTEUR_ABBENCH_RUNNER}" ]; then
  # shellcheck disable=SC1090
  . "${WALTEUR_ABBENCH_RUNNER}"
  if command -v ab_runner >/dev/null 2>&1; then RUNNER="ab_runner"; fi
fi

real_claude_runner() {
  local arm="$1" model="$2" mcp="$3" sp_present="$4" sp_text="$5" prompt="$6" out="$7"
  local args=( -p "$prompt" --output-format json --model "$model" --strict-mcp-config )
  [ "$sp_present" = "1" ] && args+=( --append-system-prompt "$sp_text" )
  if [ "$mcp" != "NONE" ] && [ -n "$mcp" ]; then args+=( --mcp-config "$mcp" ); fi
  # cold call in an isolated temp CWD so no project .claude/ or .mcp.json leaks into either arm.
  local sbox; sbox="$(mktemp -d "${TMPDIR:-/tmp}/ab-arm.XXXXXX")" || return 3
  ( cd "$sbox" && claude "${args[@]}" ) > "$out" 2>/dev/null
  local rc=$?
  rm -rf "$sbox"
  return $rc
}

# parse_metric <result.json> <field>  — pull a telemetry field from a claude result object (jq or grep).
parse_metric() {
  local f="$1" field="$2"
  if have jq; then
    case "$field" in
      cost)    jq -r '.total_cost_usd // .cost_usd // 0' "$f" 2>/dev/null ;;
      in_tok)  jq -r '((.usage.input_tokens // 0) + (.usage.cache_read_input_tokens // 0) + (.usage.cache_creation_input_tokens // 0))' "$f" 2>/dev/null ;;
      out_tok) jq -r '.usage.output_tokens // 0' "$f" 2>/dev/null ;;
      dur_ms)  jq -r '.duration_ms // 0' "$f" 2>/dev/null ;;
      turns)   jq -r '.num_turns // 0' "$f" 2>/dev/null ;;
      is_err)  jq -r 'if (.is_error // false) then 1 else 0 end' "$f" 2>/dev/null ;;
      *) echo 0 ;;
    esac
  else
    # minimal grep fallback for flat numeric fields (the selftest's mock emits flat json).
    local key
    case "$field" in cost) key="total_cost_usd";; in_tok) key="input_tokens";; out_tok) key="output_tokens";; dur_ms) key="duration_ms";; turns) key="num_turns";; is_err) key="is_error";; *) echo 0; return;; esac
    local v; v="$(grep -oE "\"$key\"[[:space:]]*:[[:space:]]*[0-9.]+|\"$key\"[[:space:]]*:[[:space:]]*(true|false)" "$f" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*//')"
    case "$v" in true) echo 1;; false) echo 0;; ''|*[!0-9.]*) echo "${v:-0}";; *) echo "$v";; esac
  fi
}

# append_row — one JSONL telemetry row per arm (jq when present; printf fallback — jq not mandated).
append_row() { # $1=task-id $2=arm $3=repeat $4=order $5..=cost in_tok out_tok dur_ms turns is_err
  local id="$1" arm="$2" rep="$3" order="$4" cost="$5" intok="$6" outtok="$7" dur="$8" turns="$9" iserr="${10}"
  if have jq; then
    jq -nc --arg ts "$TS" --arg id "$id" --arg arm "$arm" --argjson rep "$rep" --arg order "$order" \
      --argjson cost "${cost:-0}" --argjson intok "${intok:-0}" --argjson outtok "${outtok:-0}" \
      --argjson dur "${dur:-0}" --argjson turns "${turns:-0}" --argjson iserr "${iserr:-0}" \
      '{ts:$ts, task:$id, arm:$arm, repeat:$rep, order:$order,
        cost_usd:$cost, input_tokens:$intok, output_tokens:$outtok, duration_ms:$dur,
        num_turns:$turns, is_error:$iserr}' >> "$RESULTS"
  else
    printf '{"ts":"%s","task":"%s","arm":"%s","repeat":%s,"order":"%s","cost_usd":%s,"input_tokens":%s,"output_tokens":%s,"duration_ms":%s,"num_turns":%s,"is_error":%s}\n' \
      "$TS" "$id" "$arm" "$rep" "$order" "${cost:-0}" "${intok:-0}" "${outtok:-0}" "${dur:-0}" "${turns:-0}" "${iserr:-0}" >> "$RESULTS"
  fi
}

# ── the paired run over N repeats ────────────────────────────────────────────────
run_bench() {
  local task="$1" repeats="$2" model_override="$3"
  [ -f "$task" ] || { echo "WALTEUR ab-bench SKIP — task file not found: $task" >&2; exit 0; }

  local id model prompt
  id="$(read_task_field "$task" '.id' "$(basename "$task" .json)")"
  model="${model_override:-$(read_task_field "$task" '.model' 'claude-sonnet-4-6')}"
  prompt="$(read_task_field "$task" '.prompt' '')"
  [ -n "$prompt" ] || { echo "WALTEUR ab-bench SKIP — task '$id' has no .prompt." >&2; exit 0; }

  echo "WALTEUR ab-bench: task='$id' model='$model' repeats=$repeats -> $RESULTS" >&2

  local rep order arm
  for rep in $(seq 1 "$repeats"); do
    order="$(balanced_order "$rep")"
    for arm in $order; do
      # build the arm plan (single-variable toggle), then run it via the (possibly mocked) RUNNER.
      local plan; plan="$(build_arm_plan "$arm" "$task" "$model")"
      local p_arm p_model p_mcp p_sp_present p_sp_text
      IFS=$'\t' read -r p_arm p_model p_mcp p_sp_present p_sp_text <<EOF
$plan
EOF
      local out; out="$(mktemp "${TMPDIR:-/tmp}/ab-out.XXXXXX")"
      "$RUNNER" "$p_arm" "$p_model" "$p_mcp" "$p_sp_present" "$p_sp_text" "$prompt" "$out"
      local rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "  arm=$p_arm repeat=$rep order=$order: runner FAILED (rc=$rc) — recorded is_error=1." >&2
        append_row "$id" "$p_arm" "$rep" "$order" 0 0 0 0 0 1
      else
        append_row "$id" "$p_arm" "$rep" "$order" \
          "$(parse_metric "$out" cost)" "$(parse_metric "$out" in_tok)" "$(parse_metric "$out" out_tok)" \
          "$(parse_metric "$out" dur_ms)" "$(parse_metric "$out" turns)" "$(parse_metric "$out" is_err)"
      fi
      rm -f "$out"
    done
  done

  print_comparison "$id"
}

# print_comparison <task-id> — mean per arm + delta, read straight off the JSONL. jq path; awk fallback.
print_comparison() {
  local id="$1"
  echo "" >&2
  echo "── ab-bench comparison — task '$id' (means across repeats) ──" >&2
  if have jq; then
    jq -rs --arg id "$id" '
      map(select(.task==$id)) as $rows
      | ["with","without"] as $arms
      | $arms[] as $a
      | ($rows | map(select(.arm==$a))) as $g
      | ($g|length) as $n
      | if $n==0 then "  \($a): (no rows)"
        else
          "  \($a)  n=\($n)  cost=$\(( ($g|map(.cost_usd)|add)/$n )|.*10000|round/10000)  in_tok=\(( ($g|map(.input_tokens)|add)/$n )|round)  out_tok=\(( ($g|map(.output_tokens)|add)/$n )|round)  dur_ms=\(( ($g|map(.duration_ms)|add)/$n )|round)  err=\(( $g|map(.is_error)|add ))"
        end
    ' "$RESULTS" >&2 2>/dev/null || echo "  (comparison unavailable — malformed rows)" >&2
    echo "  verdict: PROTOCOL — read cost/token/time/quality deltas vs the noise band; a human ratifies PAYS/COSTS/INCONCLUSIVE (eval/prove-pillar.md §6)." >&2
    # v9.2 — refine-cycle count per arm from run-trace.jsonl (#2 substrate).
    local trace_file="$KIT/run-trace.jsonl"
    if [ -f "$trace_file" ]; then
      echo "  refine-cycle counts from run-trace.jsonl (Refine phase spans):" >&2
      jq -r 'select(.phase=="Refine") | .tool' "$trace_file" 2>/dev/null | sort | uniq -c | awk '{print "    "$0" refine span(s)"}' >&2 || true
      local refine_total; refine_total="$(jq -r 'select(.phase=="Refine") | .phase' "$trace_file" 2>/dev/null | wc -l | tr -d ' ')"
      echo "    total Refine spans in trace: $refine_total" >&2
    else
      echo "  (run-trace.jsonl absent — refine-cycle counts unavailable)" >&2
    fi
  else
    echo "  (install jq for the mean/delta table; rows are in $RESULTS)" >&2
  fi
}

# =================================================================================
# HERMETIC SELF-TEST — verifies (a) the script parses (bash -n is run separately by the
# caller), (b) arm-toggling produces the correct single-variable difference, and (c) the
# full paired run + JSONL telemetry works END-TO-END with a MOCK runner (NO real claude).
# Tests are hermetic: WALTEUR_ROOT + RESULTS redirected into mktemp; never touch the real repo.
# =================================================================================
selftest() {
  local fails=0 total=0
  local SELF; SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/ab-bench-selftest.XXXXXX")" || { echo "  FAIL — mktemp"; return 1; }
  trap 'rm -rf "$tmp"' RETURN

  check() { # $1=label $2=cond(0=pass)
    total=$((total+1))
    if [ "$2" -eq 0 ]; then echo "  ok   — $1"; else echo "  FAIL — $1"; fails=$((fails+1)); fi
  }

  echo "ab-bench selftest:"

  # ---- a GOOD task file ----
  local task="$tmp/task.json"
  cat > "$task" <<'JSON'
{
  "id": "selftest-pillar",
  "prompt": "do the thing",
  "model": "claude-test-model",
  "pillar": {
    "name": "ctx",
    "with":    { "append_system_prompt": "PILLAR-CONTEXT-INJECTED" },
    "without": {},
    "mcp_config_with": null,
    "mcp_config_without": null
  }
}
JSON

  # (1) ARM-TOGGLE: with-arm carries the pillar (append-sp present=1), without-arm does NOT (present=0).
  #     This is the single-variable invariant the whole methodology rests on.
  local with_plan without_plan
  with_plan="$(build_arm_plan with "$task" claude-test-model)"
  without_plan="$(build_arm_plan without "$task" claude-test-model)"
  local with_present without_present with_text
  with_present="$(printf '%s' "$with_plan" | cut -f4)"
  without_present="$(printf '%s' "$without_plan" | cut -f4)"
  with_text="$(printf '%s' "$with_plan" | cut -f5)"
  check "with-arm carries the pillar (append-sp present)"    "$([ "$with_present" = "1" ] && echo 0 || echo 1)"
  check "without-arm does NOT carry the pillar (control)"     "$([ "$without_present" = "0" ] && echo 0 || echo 1)"
  check "with-arm append-sp text is the pillar injection"     "$([ "$with_text" = "PILLAR-CONTEXT-INJECTED" ] && echo 0 || echo 1)"

  # (2) BALANCED ORDER: even repeat = 'with without', odd repeat = 'without with' (cancels order bias).
  check "balanced order: even repeat -> 'with without'"  "$([ "$(balanced_order 2)" = "with without" ] && echo 0 || echo 1)"
  check "balanced order: odd repeat  -> 'without with'"  "$([ "$(balanced_order 3)" = "without with" ] && echo 0 || echo 1)"

  # (3) END-TO-END with a MOCK runner — NO real claude. The mock is a SOURCEABLE file defining `ab_runner`
  #     (so it survives the recursive `bash` process boundary that a bare function name would not). It
  #     emits a claude-style result JSON whose cost differs by arm, so we assert the JSONL captured the
  #     toggle-attributable delta. Deterministic, hermetic, no network.
  cat > "$tmp/mock-runner.sh" <<'MOCK'
# ab_runner <arm> <model> <mcp> <sp_present> <sp_text> <prompt> <out>
ab_runner() {
  local arm="$1" out="$7"
  if [ "$arm" = "with" ]; then
    printf '{"total_cost_usd":0.010,"usage":{"input_tokens":1000,"output_tokens":200},"duration_ms":1200,"num_turns":1,"is_error":false}\n' > "$out"
  else
    printf '{"total_cost_usd":0.030,"usage":{"input_tokens":3000,"output_tokens":500},"duration_ms":3400,"num_turns":2,"is_error":false}\n' > "$out"
  fi
  return 0
}
MOCK

  local results="$tmp/ab-results.jsonl"
  set +e
  WALTEUR_ROOT="$tmp" \
  WALTEUR_ABBENCH_RESULTS="$results" \
  WALTEUR_ABBENCH_RUNNER="$tmp/mock-runner.sh" \
  bash "$SELF" --task "$task" --repeats 2 >/dev/null 2>&1
  local run_rc=$?
  set -e
  check "paired run via MOCK runner exits 0 (no real claude)"  "$([ "$run_rc" -eq 0 ] && echo 0 || echo 1)"
  check "JSONL telemetry file was written"                     "$([ -s "$results" ] && echo 0 || echo 1)"

  # 2 repeats x 2 arms = 4 rows.  (grep -c can emit a trailing newline -> $(( )) coerces to a clean int.)
  local nrows; nrows=$(( $(grep -c . "$results" 2>/dev/null || echo 0) ))
  check "JSONL has 4 telemetry rows (2 repeats x 2 arms)"      "$([ "$nrows" -eq 4 ] && echo 0 || echo 1)"

  # the with-arm rows must have recorded the cheaper cost the mock emitted (toggle-attributable).
  local nwith_cheap
  nwith_cheap=$(( $(grep '"arm":"with"' "$results" 2>/dev/null | grep -c '"cost_usd":0.01' || echo 0) ))
  check "with-arm rows captured the cheaper (pillar-on) cost"  "$([ "$nwith_cheap" -eq 2 ] && echo 0 || echo 1)"

  # balanced order must have produced BOTH orderings across the 2 repeats.
  local has_ab has_ba
  has_ab=$(( $(grep -c '"order":"with without"' "$results" 2>/dev/null || echo 0) ))
  has_ba=$(( $(grep -c '"order":"without with"' "$results" 2>/dev/null || echo 0) ))
  check "balanced order produced both arm orderings"           "$([ "$has_ab" -ge 1 ] && [ "$has_ba" -ge 1 ] && echo 0 || echo 1)"

  echo "ab-bench selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

# ── arg parse ─────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

TASK=""; REPEATS=3; MODEL_OVERRIDE=""; JUDGE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task)    TASK="${2:-}"; shift 2 ;;
    --repeats) REPEATS="${2:-3}"; shift 2 ;;
    --model)   MODEL_OVERRIDE="${2:-}"; shift 2 ;;
    --judge)   JUDGE=1; shift ;;
    -h|--help) sed -n '1,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "WALTEUR ab-bench SKIP — unknown arg '$1' (try --selftest or --task <f>)." >&2; exit 0 ;;
  esac
done

[ "$JUDGE" = "1" ] && echo "WALTEUR ab-bench: --judge requested — LLM-judge is opt-in PROTOCOL (eval/prove-pillar.md §4b); scoring is left to the judge call, not this skeleton." >&2

# ── detect-or-LOUD-SKIP: the real runner needs the `claude` CLI ────────────────────
if [ -z "$TASK" ]; then
  echo "WALTEUR ab-bench SKIP — no --task given. Usage: ab-bench.sh --task <task.json> [--repeats N] | --selftest" >&2
  exit 0
fi
if ! have claude; then
  if [ "$MODE" = "strict" ]; then
    echo "WALTEUR ab-bench FAIL (strict) — 'claude' CLI absent; cannot run the paired arms (WALTEUR_ABBENCH=strict)." >&2
    exit 2
  fi
  echo "WALTEUR ab-bench SKIP — 'claude' CLI not on PATH; cannot run real arms (recorded, not silent-green;" >&2
  echo "  set WALTEUR_ABBENCH=strict to fail-closed, or run --selftest for the hermetic mock check)." >&2
  exit 0
fi

run_bench "$TASK" "$REPEATS" "$MODEL_OVERRIDE"
exit 0
