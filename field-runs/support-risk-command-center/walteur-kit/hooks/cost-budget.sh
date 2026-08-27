#!/usr/bin/env bash
# WALTEUR cost-budget — honest budget gate for any app that spends money to serve a request.
#
# APPLICABILITY (critical — checked FIRST):
#   An LLM / paid-cloud-cost context must exist. We grep the project's own source (dependency, VCS
#   and build dirs pruned) for a money-spending signal:
#     openai | anthropic | bedrock | vertex | \bllm\b | completion | chat.completions
#     | boto3 | aws-sdk | @google-cloud/
#   If NONE match => a bare/minimal project with no spend context => NOT_APPLICABLE, exit 0.
#   exit 2 is reserved for a real violation in an applicable (spends-money) project.
#
# ZERO-DEP HARD RULE (bash + grep + find + jq only — always real exit 2 when applicable):
#   1. walteur-kit/cost-budget.json MUST exist. An app that spends $ per request / per LLM call with
#      NO budget is the slop. Absent (and applicable) => exit 2.
#   2. The budget must be valid JSON and satisfy the shape required by
#      schemas/cost-budget.schema.json: at least one of
#        units[]:{name, (max_usd_per_request XOR max_usd_per_run)}
#        llm[]:{feature, max_usd_per_task, max_tokens}
#      Malformed / empty / missing-required-keys => exit 2.
#
# ADDITIVE (runs only after the static budget PASSES — never weakens the primary gate):
#   3. codeburn token-burn DETECT-OR-SKIP. IF 'codeburn' is on PATH, run 'codeburn report --json'
#      and read today's spend; if today-spend > MAX_BUILD_COST_USD (default 25) => real violation,
#      exit 2. codeburn absent OR erroring/non-JSON/no-spend => LOUD recorded SKIP of this sub-check
#      (the primary budget verdict stays PASS — never silent-green, never exit 2 for a tool fault).
#
# Exit: 2 on any real violation; 0 on clean / not-applicable.
# Report: walteur-kit/cost-report.json {verdict, ts, gate, reason, details}.
# Bypass: WALTEUR_COST=off. Pause: walteur-kit/PAUSED present. Cap env: MAX_BUILD_COST_USD (default 25).
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/cost-report.json"
BUDGET="$KIT/cost-budget.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# write_report <verdict> <reason> <details-json-object>
write_report() {
  local v="$1" reason="$2" details="${3:-}"
  [ -n "$details" ] || details="{}"
  if have jq; then
    local details_file
    details_file="$(mktemp "${TMPDIR:-/tmp}/cost-report-details.XXXXXX")" || details_file=""
    if [ -n "$details_file" ]; then
      printf '%s\n' "$details" > "$details_file"
      if jq -e . "$details_file" >/dev/null 2>&1; then
        jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --slurpfile d "$details_file" \
          '{verdict:$v, ts:$ts, gate:"cost-budget", reason:$reason, details:$d[0]}' > "$REPORT" 2>/dev/null
        rc=$?
        rm -f "$details_file"
        [ "$rc" -eq 0 ] && return 0
      else
        rm -f "$details_file"
      fi
    fi
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"cost-budget","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
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

  for t in jq grep find awk sed; do
    if ! have "$t"; then
      echo "cost-budget selftest SKIP - required tool '$t' not installed."
      return 0
    fi
  done

  make_spend_signal() {
    mkdir -p "$1/src"
    printf 'import OpenAI from "openai";\nexport const model = "gpt";\n' > "$1/src/llm.ts"
  }
  make_valid_budget() {
    cat > "$1/walteur-kit/cost-budget.json" <<'JSON'
{
  "units": [
    {
      "name": "api_request",
      "max_usd_per_request": 0.05
    }
  ],
  "llm": [
    {
      "feature": "chat",
      "max_usd_per_task": 0.2,
      "max_tokens": 2000
    }
  ]
}
JSON
  }

  echo "cost-budget selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cost-budget-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'console.log("hello");\n' > "$tmp/app.js"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no cost context -> NOT_APPLICABLE exit" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/cost-report.json" >/dev/null 2>&1
  ck "no cost context report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cost-budget-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  make_spend_signal "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "spend signal without budget -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.reason | contains("missing"))' "$tmp/walteur-kit/cost-report.json" >/dev/null 2>&1
  ck "missing budget report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cost-budget-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  make_spend_signal "$tmp"
  make_valid_budget "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "valid budget -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .details.budget_present == true and .details.units_count == 1 and .details.llm_count == 1' "$tmp/walteur-kit/cost-report.json" >/dev/null 2>&1
  ck "valid budget report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cost-budget-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  make_spend_signal "$tmp"
  printf '{"units":[{"name":"api_request"}]}\n' > "$tmp/walteur-kit/cost-budget.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "invalid budget shape -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.reason | contains("shape"))' "$tmp/walteur-kit/cost-report.json" >/dev/null 2>&1
  ck "invalid budget shape report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cost-budget-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_spend_signal "$tmp"
  make_valid_budget "$tmp"
  cat > "$tmp/bin/codeburn" <<'SH'
#!/usr/bin/env bash
printf '{"today_spend_usd":99}\n'
SH
  chmod +x "$tmp/bin/codeburn"
  PATH="$tmp/bin:$PATH" WALTEUR_ROOT="$tmp" MAX_BUILD_COST_USD=25 bash "$0" >/dev/null 2>&1
  ck "codeburn spend over cap -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .details.codeburn.status == "FAIL"' "$tmp/walteur-kit/cost-report.json" >/dev/null 2>&1
  ck "over-cap report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cost-budget-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  make_spend_signal "$tmp"
  WALTEUR_ROOT="$tmp" WALTEUR_COST=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/cost-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cost-budget-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "cost-budget selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

# ── APPLICABILITY: scan source for an LLM / paid-cloud-cost signal ────────────
# Pattern is case-insensitive and word-bounded where it matters (\bllm\b avoids 'collmate' etc).
COST_PATTERN='openai|anthropic|bedrock|vertex|\bllm\b|completion|chat\.completions|boto3|aws-sdk|@google-cloud/'

# Source-y file extensions only — we read code/config, not the kit's own reports or lockfiles.
SIGNAL_FILE=""
SIGNAL_MATCH=""

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
if [ "${WALTEUR_COST:-on}" = "off" ]; then
  echo "cost-budget: bypassed (WALTEUR_COST=off)." >&2
  bypass_details='{}'
  have jq && bypass_details="$(jq -n '{bypassed:true}')"
  write_report "SKIP" "bypassed via WALTEUR_COST=off" "$bypass_details"
  exit 0
fi

while IFS= read -r f; do
  [ -z "$f" ] && continue
  m="$(grep -iEoh "$COST_PATTERN" "$f" 2>/dev/null | head -1)"
  if [ -n "$m" ]; then SIGNAL_FILE="$f"; SIGNAL_MATCH="$m"; break; fi
done < <(find "$ROOT" \
            \( -path "$ROOT/.git" -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/venv' \
               -o -path '*/vendor' -o -path '*/dist' -o -path '*/build' -o -path '*/target' \
               -o -path "$KIT" \) -prune -o \
            -type f \( -name '*.py' -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \
               -o -name '*.ts' -o -name '*.tsx' -o -name '*.jsx' -o -name '*.go' \
               -o -name '*.rs' -o -name '*.java' -o -name '*.rb' -o -name '*.php' \
               -o -name '*.cs' -o -name '*.json' -o -name '*.toml' -o -name '*.yaml' \
               -o -name '*.yml' -o -name '*.env' -o -name '*.txt' -o -name '*.md' \) \
            -print 2>/dev/null)

if [ -z "$SIGNAL_FILE" ]; then
  echo "cost-budget: no LLM / paid-cloud-cost context found (no openai/anthropic/bedrock/vertex/llm/completion/boto3/aws-sdk/@google-cloud) — gate not applicable." >&2
  write_report "NOT_APPLICABLE" "no LLM/cloud-cost context in source" \
    "$(have jq && jq -n '{cost_context:false}' || echo '{}')"
  exit 0
fi

rel() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}";; *) printf '%s' "$1";; esac; }
echo "WALTEUR cost-budget @ $ROOT — spend signal '$SIGNAL_MATCH' in $(rel "$SIGNAL_FILE")" >&2

# ── ZERO-DEP HARD #1: a budget MUST exist ─────────────────────────────────────
if [ ! -f "$BUDGET" ]; then
  echo "cost-budget: FAIL — app spends money (LLM/cloud calls) but walteur-kit/cost-budget.json is MISSING." >&2
  echo "  An app that spends \$ per request / per LLM call with no budget is unbounded slop. Declare one" >&2
  echo "  against schemas/cost-budget.schema.json: {units:[{name, max_usd_per_request|max_usd_per_run}],"  >&2
  echo "  llm:[{feature, max_usd_per_task, max_tokens}]} (at least one block required)." >&2
  write_report "FAIL" "cost-budget.json missing (app spends \$ with no budget)" \
    "$(have jq && jq -n --arg sf "$(rel "$SIGNAL_FILE")" --arg sm "$SIGNAL_MATCH" \
        '{cost_context:true, signal_file:$sf, signal_match:$sm, budget_present:false}' || echo '{}')"
  exit 2
fi

# heavy-tool note: zero-dep core requires jq for shape validation. Loud SKIP if absent — never silent-green.
if ! have jq; then
  echo "WALTEUR cost-budget SKIP — jq not installed; cannot validate budget shape (recorded, not silent-green)." >&2
  write_report "SKIP" "jq not installed"
  exit 0
fi

# ── ZERO-DEP HARD #2: budget valid JSON ───────────────────────────────────────
if ! jq -e . "$BUDGET" >/dev/null 2>&1; then
  echo "cost-budget: FAIL — walteur-kit/cost-budget.json is not valid JSON." >&2
  write_report "FAIL" "cost-budget.json is not valid JSON" \
    "$(jq -n '{cost_context:true, budget_present:true, valid_json:false}')"
  exit 2
fi

# ── ZERO-DEP HARD #2 (cont): required shape (mirrors the JSON-Schema; jq can't run JSON-Schema) ──
SHAPE_ERR="$(jq -r '
  def err(c;m): if c then m else empty end;
  ( (.units // null) ) as $u
  | ( (.llm // null) ) as $l
  | [ # at least one block present
      err(($u==null) and ($l==null); "at least one of units[] or llm[] must be declared")
    # units block, if present, must be a non-empty array of well-formed entries
    , err(($u!=null) and (($u|type)!="array"); "units must be an array")
    , err(($u!=null) and (($u|type)=="array") and (($u|length)<1); "units must have at least one entry")
    , err(($u!=null) and (($u|type)=="array") and
          ([ $u[]? | select((.name|type)!="string" or ((.name|tostring)|length)<1) ]|length>0);
          "every unit needs a non-empty string name")
    , err(($u!=null) and (($u|type)=="array") and
          ([ $u[]? | select((has("max_usd_per_request")|not) and (has("max_usd_per_run")|not)) ]|length>0);
          "every unit needs max_usd_per_request OR max_usd_per_run")
    , err(($u!=null) and (($u|type)=="array") and
          ([ $u[]? | select((has("max_usd_per_request")) and (has("max_usd_per_run"))) ]|length>0);
          "a unit must not set BOTH max_usd_per_request and max_usd_per_run")
    , err(($u!=null) and (($u|type)=="array") and
          ([ $u[]? | select(has("max_usd_per_request")) | select((.max_usd_per_request|type)!="number" or (.max_usd_per_request<=0)) ]|length>0);
          "max_usd_per_request must be a number > 0")
    , err(($u!=null) and (($u|type)=="array") and
          ([ $u[]? | select(has("max_usd_per_run")) | select((.max_usd_per_run|type)!="number" or (.max_usd_per_run<=0)) ]|length>0);
          "max_usd_per_run must be a number > 0")
    # llm block, if present, must be a non-empty array of well-formed entries
    , err(($l!=null) and (($l|type)!="array"); "llm must be an array")
    , err(($l!=null) and (($l|type)=="array") and (($l|length)<1); "llm must have at least one entry")
    , err(($l!=null) and (($l|type)=="array") and
          ([ $l[]? | select((.feature|type)!="string" or ((.feature|tostring)|length)<1) ]|length>0);
          "every llm entry needs a non-empty string feature")
    , err(($l!=null) and (($l|type)=="array") and
          ([ $l[]? | select((.max_usd_per_task|type)!="number" or (.max_usd_per_task<=0)) ]|length>0);
          "every llm entry needs max_usd_per_task as a number > 0")
    , err(($l!=null) and (($l|type)=="array") and
          ([ $l[]? | select((.max_tokens|type)!="number" or (.max_tokens<=0) or ((.max_tokens|floor)!=.max_tokens)) ]|length>0);
          "every llm entry needs max_tokens as an integer > 0")
    ] | map(select(. != null)) | .[]' "$BUDGET" 2>/dev/null)"

if [ -n "$SHAPE_ERR" ]; then
  echo "cost-budget: FAIL — cost-budget.json violates the required shape:" >&2
  printf '%s\n' "$SHAPE_ERR" | sed 's/^/  - /' >&2
  ERR_JSON="$(printf '%s\n' "$SHAPE_ERR" | jq -R . | jq -s '{cost_context:true, budget_present:true, valid_json:true, shape_errors:.}')"
  write_report "FAIL" "cost-budget.json fails required shape" "$ERR_JSON"
  echo "cost-budget verdict: FAIL (shape) -> $REPORT" >&2
  exit 2
fi

# ── budget declared and well-formed (per-request / LLM-task shape is the PRIMARY gate) ──
UNITS_N="$(jq '(.units // []) | length' "$BUDGET")"
LLM_N="$(jq '(.llm // []) | length' "$BUDGET")"
echo "  ok   — cost-budget.json valid: ${UNITS_N} unit budget(s), ${LLM_N} llm budget(s)." >&2

# ── ADDITIVE: codeburn token-burn DETECT-OR-SKIP ──────────────────────────────
# The static budget above bounds per-request/per-task spend. This adds a LIVE check of
# today's actual build spend IF (and only if) 'codeburn' is on PATH. It never silent-greens:
#   - codeburn absent          => recorded SKIP of this sub-check (primary gate already PASS).
#   - codeburn errors/no-spend => LOUD recorded SKIP of this sub-check (never exit 2 for a tool fault).
#   - today_spend > MAX_BUILD_COST_USD (default 25) => REAL violation => exit 2.
MAX_BUILD_COST_USD="${MAX_BUILD_COST_USD:-25}"
BURN_STATUS="skipped"; BURN_SPEND=""; BURN_REASON=""
if have codeburn; then
  CB_OUT="$(codeburn report --json 2>/dev/null)"; CB_RC=$?
  if [ "$CB_RC" -ne 0 ] || [ -z "$CB_OUT" ] || ! printf '%s' "$CB_OUT" | jq -e . >/dev/null 2>&1; then
    BURN_STATUS="skipped"; BURN_REASON="codeburn present but 'codeburn report --json' failed/empty/non-JSON (rc=$CB_RC)"
    echo "WALTEUR cost-budget SKIP(sub) — $BURN_REASON (recorded, not silent-green; primary budget gate still PASS)." >&2
  else
    # tolerate common shapes: .today_spend_usd | .today.spend_usd | .today.spend | .spend_today_usd
    BURN_SPEND="$(printf '%s' "$CB_OUT" | jq -r '
      (.today_spend_usd // .today.spend_usd // .today.spend // .spend_today_usd // empty) | tostring' 2>/dev/null)"
    if [ -z "$BURN_SPEND" ] || ! printf '%s' "$BURN_SPEND" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
      BURN_STATUS="skipped"; BURN_REASON="codeburn JSON lacked a numeric today-spend field"
      echo "WALTEUR cost-budget SKIP(sub) — $BURN_REASON (recorded, not silent-green)." >&2
    elif awk -v s="$BURN_SPEND" -v m="$MAX_BUILD_COST_USD" 'BEGIN{exit !(s+0>m+0)}'; then
      echo "cost-budget: FAIL — codeburn today-spend \$$BURN_SPEND exceeds MAX_BUILD_COST_USD \$$MAX_BUILD_COST_USD." >&2
      write_report "FAIL" "codeburn today-spend exceeds MAX_BUILD_COST_USD" \
        "$(jq -c -n --arg sf "$(rel "$SIGNAL_FILE")" --arg sm "$SIGNAL_MATCH" \
                --argjson un "$UNITS_N" --argjson ln "$LLM_N" \
                --argjson spend "$BURN_SPEND" --argjson cap "$MAX_BUILD_COST_USD" \
          '{cost_context:true, signal_file:$sf, signal_match:$sm,
            budget_present:true, valid_json:true, units_count:$un, llm_count:$ln,
            codeburn:{status:"FAIL", today_spend_usd:$spend, max_build_cost_usd:$cap}}')"
      echo "cost-budget verdict: FAIL (codeburn) -> $REPORT" >&2
      exit 2
    else
      BURN_STATUS="ok"
      echo "  ok   — codeburn today-spend \$$BURN_SPEND within cap \$$MAX_BUILD_COST_USD." >&2
    fi
  fi
else
  BURN_REASON="codeburn not on PATH"
  echo "WALTEUR cost-budget SKIP(sub) — codeburn not on PATH; live token-burn check skipped (recorded, not silent-green)." >&2
fi

# ── PASS: budget declared and well-formed (+ codeburn ok/skipped) ─────────────
CB_JSON="$(jq -c -n --arg st "$BURN_STATUS" --arg rs "$BURN_REASON" --arg sp "$BURN_SPEND" --argjson cap "$MAX_BUILD_COST_USD" \
  '{status:$st, max_build_cost_usd:$cap}
   + (if $sp != "" then {today_spend_usd:($sp|tonumber)} else {} end)
   + (if $rs != "" then {reason:$rs} else {} end)')"
write_report "PASS" "cost budget declared and well-formed" \
  "$(jq -c -n --arg sf "$(rel "$SIGNAL_FILE")" --arg sm "$SIGNAL_MATCH" \
          --argjson un "$UNITS_N" --argjson ln "$LLM_N" \
          --argjson units "$(jq -c '.units // []' "$BUDGET")" \
          --argjson llm "$(jq -c '.llm // []' "$BUDGET")" \
          --argjson cb "$CB_JSON" \
    '{cost_context:true, signal_file:$sf, signal_match:$sm,
      budget_present:true, valid_json:true,
      units_count:$un, llm_count:$ln, units:$units, llm:$llm, codeburn:$cb}')"

echo "cost-budget verdict: PASS -> $REPORT" >&2
exit 0
