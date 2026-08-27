#!/usr/bin/env bash
# WALTEUR tool-guardrail-gate — ZERO-DEP HARD gate on RUNTIME tool-call guardrails.
#
# WHY: tool-contract-lint.sh proves each agent tool has a STATIC contract (typed I/O,
# side_effect_class, error_taxonomy, oversight_gate). This gate proves the OTHER half:
# the runtime guardrail BANDS actually wired around every call, and that the coverage
# table includes EVERY declared tool. The three blast-radius holes this closes:
#   - pre-call:  args are validated / authorized / rate-limited / injection-scrubbed BEFORE the call.
#   - post-call: the tool RESULT is validated / scrubbed / size-bounded BEFORE the model consumes it
#                (an unchecked tool output is how a poisoned API response prompt-injects the agent).
#   - error-path: fatal errors are NOT silently retried/swallowed; dangerous ops halt or recover.
#
# APPLICABILITY (checked FIRST — the #1 past bug is a gate that exit-2s a project the discipline
# does not apply to). APPLICABLE iff the build is an AI/agent build, i.e. ANY of:
#   - walteur-kit/tool-guardrails.json present, OR
#   - walteur-kit/tool-contracts/ directory present, OR
#   - any *.tool.json present anywhere, OR
#   - a project file/dir NAME matches agent|llm|prompt|mcp|rag|embedding|tool.?contract
#     (case-insensitive), excluding vcs/deps/build/the kit itself.
# If NONE hold => bare/non-AI project => {"verdict":"NOT_APPLICABLE"} + exit 0.
#
# WHEN APPLICABLE, walteur-kit/tool-guardrails.json MUST exist (an agent build with no guardrail
# coverage table is itself the violation), the envelope is validated against the SHAPE of
# walteur-kit/schemas/tool-guardrails.schema.json, and EVERY tool entry is rule-checked:
#   G0  ENVELOPE: schema_version, manifest_id, updated_at, policy are strings; tools is an array; any
#       present `external` field is a JSON boolean (a quoted "true" is rejected, not trusted).
#   G1  required keys present: tool, side_effect_class, pre_call, post_call, error_path.
#   G2  side_effect_class is one of the schema enum (read | write_undoable | write_irreversible | external_money).
#   G3  pre_call.checks AND post_call.checks are each a NON-EMPTY array (every tool validates in and out).
#   G4  error_path.retryable and error_path.fatal are arrays, and on_fatal is a REAL action — never a
#       silent no-op ("", continue, ignore, swallow, none, noop, no-op).
#   G5  THE INVARIANT: a dangerous tool (side_effect_class in {write_irreversible, external_money}) OR
#       external==true REQUIRES a non-empty pre_call.checks, on_fatal in {halt, escalate, rollback,
#       compensate, abort, replan}, AND evidence_ref on every band (declaration must be wired, not asserted).
#       `replan` = route the failed call back to the planner (Loop-Engineering "Reject + Replan" limb).
#       Retrying a fatal money/irreversible op is the hole. NOTE: externality is author-asserted via
#       side_effect_class/external — the gate cannot infer it from code, so it trusts the declaration.
#   G6  COVERAGE: when tool-contracts exist, EVERY declared contract tool name MUST appear in the table.
#   G7  NO SILENT EMPTY TABLE: an applicable build with zero tools AND zero contracts must set
#       "no_external_tools": true to assert it invokes none — an empty table no longer greens by default.
# ANY violation in an applicable project => exit 2. Clean => exit 0.
#
# Validation engine: jq (WALTEUR's zero-dep baseline) => HARD gate (real exit 2). jq absent => LOUD SKIP.
# Report: walteur-kit/tool-guardrail-report.json {verdict, ts, gate, reason, details}.
# Bypass: WALTEUR_TOOL_GUARDRAIL=off. Honors walteur-kit/PAUSED.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "tool-guardrail-gate - ZERO-DEP HARD gate on RUNTIME tool-call guardrails."
  printf '%s\n' "usage: bash tool-guardrail-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/tool-guardrail-report.json - fix recipes: walteur-kit/REMEDIATION.md (## tool-guardrail-gate)"
  printf '%s\n' "bypass: WALTEUR_TOOL_GUARDRAIL=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/tool-guardrail-report.json"
SCHEMA="$KIT/schemas/tool-guardrails.schema.json"
MANIFEST="$KIT/tool-guardrails.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# write_report <verdict> <reason> <details-json-object-or-array>  (jq-first; printf fallback so a report ALWAYS lands)
write_report() {
  local v="$1" reason="$2" details="${3:-}"
  [ -n "$details" ] || details="{}"
  if have jq; then
    local details_file
    details_file="$(mktemp "${TMPDIR:-/tmp}/tool-guardrail-report-details.XXXXXX")" || details_file=""
    if [ -n "$details_file" ]; then
      printf '%s\n' "$details" > "$details_file"
      if jq -e . "$details_file" >/dev/null 2>&1; then
        jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --slurpfile d "$details_file" \
          '{verdict:$v, ts:$ts, gate:"tool-guardrail", reason:$reason, details:$d[0]}' > "$REPORT" 2>/dev/null
        rc=$?
        rm -f "$details_file"
        [ "$rc" -eq 0 ] && return 0
      else
        rm -f "$details_file"
      fi
    fi
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"tool-guardrail","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
}

# Collect declared tool-contract files (same idiom as tool-contract-lint): *.json under
# walteur-kit/tool-contracts/ plus *.tool.json anywhere (minus pruned dirs).
collect_contract_files() {
  local prune=( -path "$ROOT/.git" -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/venv' \
                -o -path '*/dist' -o -path '*/build' -o -path '*/vendor' )
  CONTRACT_FILES=()
  if [ -d "$KIT/tool-contracts" ]; then
    while IFS= read -r f; do [ -n "$f" ] && CONTRACT_FILES+=("$f"); done < <(
      find "$KIT/tool-contracts" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort
    )
  fi
  while IFS= read -r f; do [ -n "$f" ] && CONTRACT_FILES+=("$f"); done < <(
    find "$ROOT" \( "${prune[@]}" \) -prune -o -type f -name '*.tool.json' -print 2>/dev/null | sort
  )
  if [ "${#CONTRACT_FILES[@]}" -gt 0 ]; then
    local uniq=()
    while IFS= read -r f; do [ -n "$f" ] && uniq+=("$f"); done < <(printf '%s\n' "${CONTRACT_FILES[@]}" | awk 'NF' | sort -u)
    CONTRACT_FILES=("${uniq[@]}")
  fi
}

# The per-tool validation program (G1-G5). $enum carries the schema side_effect_class enum.
# NOTE: inside jq \(...) interpolation use PLAIN " for jq string literals; do NOT write \" — that
# was the silent-green compile bug tool-contract-lint is hardened against. Values that contain quotes
# are emitted via tojson, never hand-quoted.
JQ_PROG='
  (["tool","side_effect_class","pre_call","post_call","error_path"]) as $req
  | (.tools // [])
  | to_entries[]
  | .key as $i | .value as $t
  | ($t.tool // ("#"+($i|tostring))) as $tn
  | (
      # G1 — missing required keys
      ( ($req - ($t|keys)) as $m
        | if ($m|length) > 0 then "G1::tool \($tn): missing required key(s): \($m|join(", "))" else empty end ),

      # G2 — side_effect_class must be in the schema enum (only if present)
      ( if ($t|has("side_effect_class"))
          then ( if ($enum | index($t.side_effect_class)) == null
                   then "G2::tool \($tn): side_effect_class \($t.side_effect_class|tojson) not in enum"
                   else empty end )
          else empty end ),

      # G3 — pre_call.checks and post_call.checks must each be a non-empty array
      ( if (($t.pre_call.checks|type) == "array" and ($t.pre_call.checks|length) > 0) then empty
          else "G3::tool \($tn): pre_call.checks must be a non-empty array" end ),
      ( if (($t.post_call.checks|type) == "array" and ($t.post_call.checks|length) > 0) then empty
          else "G3::tool \($tn): post_call.checks must be a non-empty array (tool output must be validated before the model consumes it)" end ),

      # G4 — error_path arrays present + on_fatal is a real action, never a silent no-op
      ( if (($t.error_path.retryable|type) == "array" and ($t.error_path.fatal|type) == "array") then empty
          else "G4::tool \($tn): error_path.retryable and error_path.fatal must both be arrays" end ),
      ( ($t.error_path.on_fatal) as $of
        | if (($of|type) == "string" and ($of|length) > 0
               and ((["continue","ignore","swallow","none","noop","no-op"]) | index($of|ascii_downcase) | not))
            then empty
            else "G4::tool \($tn): error_path.on_fatal must be a real action, not a silent no-op (got \($of|tojson))" end ),

      # G5 — dangerous/external invariant
      ( ( ($t.side_effect_class == "write_irreversible")
          or ($t.side_effect_class == "external_money")
          or ($t.external == true) ) as $dangerous
        | if $dangerous
            then (
              ( if (($t.pre_call.checks|type) == "array" and ($t.pre_call.checks|length) > 0) then empty
                  else "G5::tool \($tn): dangerous/external tool REQUIRES a non-empty pre_call.checks guardrail" end ),
              ( ($t.error_path.on_fatal) as $of
                | if (($of|type) == "string"
                       and ((["halt","escalate","rollback","compensate","abort","replan"]) | index($of|ascii_downcase)))
                    then empty
                    else "G5::tool \($tn): dangerous/external tool REQUIRES on_fatal to halt/escalate/rollback/compensate/abort/replan (got \($of|tojson))" end ),
              # evidence_ref must point at the implementing code on every band (declaration must be wired)
              ( ( [ (if (($t.pre_call.evidence_ref|type) == "string" and ($t.pre_call.evidence_ref|length) > 0) then empty else "pre_call" end),
                    (if (($t.post_call.evidence_ref|type) == "string" and ($t.post_call.evidence_ref|length) > 0) then empty else "post_call" end),
                    (if (($t.error_path.evidence_ref|type) == "string" and ($t.error_path.evidence_ref|length) > 0) then empty else "error_path" end) ] ) as $missing
                | if ($missing|length) > 0
                    then "G5::tool \($tn): dangerous/external tool REQUIRES evidence_ref pointing at the implementing code; missing on: \($missing|join(", "))"
                    else empty end )
            )
            else empty end )
    )
'

VIOLATIONS=()
VIOL_JSON='[]'
add_violation() {  # add_violation <file> <rule> <message>
  local file="$1" rule="$2" msg="$3"
  VIOLATIONS+=("$file [$rule] $msg")
  VIOL_JSON="$(jq -c --arg f "$file" --arg r "$rule" --arg m "$msg" '. + [{file:$f, rule:$r, message:$m}]' <<<"$VIOL_JSON")"
}

selftest() {
  pass=0
  fail=0
  ck() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then echo "  ok   - $name (rc=$got)"; pass=$((pass+1));
    else echo "  FAIL - $name (want $want got $got)"; fail=$((fail+1)); fi
  }

  for t in jq grep find awk sed; do
    if ! have "$t"; then echo "tool-guardrail-gate selftest SKIP - required tool '$t' not installed."; return 0; fi
  done

  write_contract() {  # write_contract <dir> <name>
    mkdir -p "$1/walteur-kit/tool-contracts"
    cat > "$1/walteur-kit/tool-contracts/$2.json" <<JSON
{
  "name": "$2",
  "input": { "type": "object", "properties": { "q": { "type": "string" } } },
  "output": { "type": "object" },
  "side_effect_class": "read",
  "idempotent": true,
  "error_taxonomy": { "retryable": ["timeout"], "fatal": ["permission_denied"] },
  "oversight_gate": false
}
JSON
  }

  echo "tool-guardrail-gate selftest:"

  # 1. non-AI project -> NOT_APPLICABLE
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'console.log("hi");\n' > "$tmp/app.js"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "non-AI project -> NOT_APPLICABLE exit" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "non-AI report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  # 2. AI signal but NO guardrail manifest -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/schemas" "$tmp/src"
  cp "$SCHEMA" "$tmp/walteur-kit/schemas/tool-guardrails.schema.json"
  printf 'export const agentRunner = true;\n' > "$tmp/src/agent-runner.ts"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "AI signal without guardrail manifest -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.details.rule == "agent-build-requires-guardrail-coverage")' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "missing manifest report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  # 3. valid manifest covering the one contract tool -> PASS
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/schemas"
  cp "$SCHEMA" "$tmp/walteur-kit/schemas/tool-guardrails.schema.json"
  write_contract "$tmp" "search_docs"
  cat > "$tmp/walteur-kit/tool-guardrails.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "manifest_id": "tool-guardrails",
  "updated_at": "2026-06-23T00:00:00Z",
  "policy": "Every agent-callable tool guards its input, output, and error path.",
  "tools": [
    {
      "tool": "search_docs",
      "side_effect_class": "read",
      "external": true,
      "pre_call": { "checks": ["schema-validate args", "rate-limit"], "evidence_ref": "src/guards/search-pre.ts" },
      "post_call": { "checks": ["scrub injected instructions", "bound result size"], "evidence_ref": "src/guards/search-post.ts" },
      "error_path": { "retryable": ["timeout"], "fatal": ["permission_denied"], "on_fatal": "escalate", "evidence_ref": "src/guards/search-err.ts" }
    }
  ]
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "valid guardrail coverage -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .details.tools_checked == 1 and .details.violations == 0' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "valid coverage report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  # 4. dangerous tool (external_money) with EMPTY pre_call.checks -> FAIL (G5)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/schemas"
  cp "$SCHEMA" "$tmp/walteur-kit/schemas/tool-guardrails.schema.json"
  cat > "$tmp/walteur-kit/tool-guardrails.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "manifest_id": "tool-guardrails",
  "updated_at": "2026-06-23T00:00:00Z",
  "policy": "p",
  "tools": [
    {
      "tool": "send_payment",
      "side_effect_class": "external_money",
      "pre_call": { "checks": [] },
      "post_call": { "checks": ["validate receipt"] },
      "error_path": { "retryable": [], "fatal": ["declined"], "on_fatal": "halt" }
    }
  ]
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "dangerous tool with empty pre_call -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and ([.details.items[]?.rule] | index("G5"))' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "empty-pre_call report records G5" 0 "$?"
  rm -rf "$tmp"

  # 4b. dangerous tool with on_fatal:"replan" (Loop-Engineering Reject+Replan limb) + full guardrails -> PASS (G5)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/schemas"
  cp "$SCHEMA" "$tmp/walteur-kit/schemas/tool-guardrails.schema.json"
  cat > "$tmp/walteur-kit/tool-guardrails.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "manifest_id": "tool-guardrails",
  "updated_at": "2026-06-23T00:00:00Z",
  "policy": "p",
  "tools": [
    {
      "tool": "send_payment",
      "side_effect_class": "external_money",
      "pre_call": { "checks": ["validate amount within ceiling"], "evidence_ref": "src/guards/pay-pre.ts" },
      "post_call": { "checks": ["validate receipt"], "evidence_ref": "src/guards/pay-post.ts" },
      "error_path": { "retryable": ["timeout"], "fatal": ["declined"], "on_fatal": "replan", "evidence_ref": "src/guards/pay-err.ts" }
    }
  ]
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "dangerous tool on_fatal=replan (Reject+Replan) -> PASS" 0 "$?"
  jq -e '.verdict == "PASS"' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "replan-on-dangerous report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  # 5. on_fatal silent no-op ("continue") -> FAIL (G4)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/schemas"
  cp "$SCHEMA" "$tmp/walteur-kit/schemas/tool-guardrails.schema.json"
  cat > "$tmp/walteur-kit/tool-guardrails.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "manifest_id": "tool-guardrails",
  "updated_at": "2026-06-23T00:00:00Z",
  "policy": "p",
  "tools": [
    {
      "tool": "write_note",
      "side_effect_class": "write_undoable",
      "pre_call": { "checks": ["validate args"] },
      "post_call": { "checks": ["validate result"] },
      "error_path": { "retryable": ["timeout"], "fatal": [], "on_fatal": "continue" }
    }
  ]
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "on_fatal silent no-op -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and ([.details.items[]?.rule] | index("G4"))' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "silent-no-op report records G4" 0 "$?"
  rm -rf "$tmp"

  # 6. contract tool present but missing from coverage table -> FAIL (G6)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/schemas"
  cp "$SCHEMA" "$tmp/walteur-kit/schemas/tool-guardrails.schema.json"
  write_contract "$tmp" "search_docs"
  cat > "$tmp/walteur-kit/tool-guardrails.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "manifest_id": "tool-guardrails",
  "updated_at": "2026-06-23T00:00:00Z",
  "policy": "p",
  "tools": [
    {
      "tool": "other_tool",
      "side_effect_class": "read",
      "pre_call": { "checks": ["validate args"] },
      "post_call": { "checks": ["validate result"] },
      "error_path": { "retryable": ["timeout"], "fatal": [], "on_fatal": "retry" }
    }
  ]
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "uncovered contract tool -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and ([.details.items[]?.rule] | index("G6"))' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "uncovered-tool report records G6" 0 "$?"
  rm -rf "$tmp"

  # write_manifest_tool <dir> <tool-json>  — valid envelope + one tool object
  write_manifest_tool() {
    mkdir -p "$1/walteur-kit/schemas"
    cp "$SCHEMA" "$1/walteur-kit/schemas/tool-guardrails.schema.json"
    cat > "$1/walteur-kit/tool-guardrails.json" <<JSON
{ "schema_version": "1.0.0", "manifest_id": "tool-guardrails", "updated_at": "2026-06-23T00:00:00Z", "policy": "p", "tools": [ $2 ] }
JSON
  }

  # 6a. G0 envelope — external as a quoted string is rejected (not trusted as boolean)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  write_manifest_tool "$tmp" '{ "tool": "t", "side_effect_class": "read", "external": "true", "pre_call": {"checks":["a"]}, "post_call": {"checks":["b"]}, "error_path": {"retryable":[],"fatal":[],"on_fatal":"retry"} }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "string external -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and ([.details.items[]?.rule] | index("G0"))' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "string-external report records G0" 0 "$?"
  rm -rf "$tmp"

  # 6b. G1 missing required key (error_path absent)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  write_manifest_tool "$tmp" '{ "tool": "t", "side_effect_class": "read", "pre_call": {"checks":["a"]}, "post_call": {"checks":["b"]} }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing required key -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and ([.details.items[]?.rule] | index("G1"))' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "missing-key report records G1" 0 "$?"
  rm -rf "$tmp"

  # 6c. G2 side_effect_class not in enum
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  write_manifest_tool "$tmp" '{ "tool": "t", "side_effect_class": "frobnicate", "pre_call": {"checks":["a"]}, "post_call": {"checks":["b"]}, "error_path": {"retryable":[],"fatal":[],"on_fatal":"retry"} }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "bad side_effect_class -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and ([.details.items[]?.rule] | index("G2"))' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "bad-enum report records G2" 0 "$?"
  rm -rf "$tmp"

  # 6d. G3 empty post_call.checks
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  write_manifest_tool "$tmp" '{ "tool": "t", "side_effect_class": "read", "pre_call": {"checks":["a"]}, "post_call": {"checks":[]}, "error_path": {"retryable":[],"fatal":[],"on_fatal":"retry"} }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "empty post_call.checks -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and ([.details.items[]?.rule] | index("G3"))' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "empty-post_call report records G3" 0 "$?"
  rm -rf "$tmp"

  # 6e. G7 empty table, no contracts, no ack -> FAIL (no silent green)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/schemas"
  cp "$SCHEMA" "$tmp/walteur-kit/schemas/tool-guardrails.schema.json"
  printf '%s\n' '{ "schema_version": "1.0.0", "manifest_id": "tool-guardrails", "updated_at": "2026-06-23T00:00:00Z", "policy": "p", "tools": [] }' > "$tmp/walteur-kit/tool-guardrails.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "empty table without ack -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and ([.details.items[]?.rule] | index("G7"))' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "empty-table report records G7" 0 "$?"
  rm -rf "$tmp"

  # 6f. G7 empty table WITH explicit no_external_tools ack -> PASS
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/schemas"
  cp "$SCHEMA" "$tmp/walteur-kit/schemas/tool-guardrails.schema.json"
  printf '%s\n' '{ "schema_version": "1.0.0", "manifest_id": "tool-guardrails", "updated_at": "2026-06-23T00:00:00Z", "policy": "p", "no_external_tools": true, "tools": [] }' > "$tmp/walteur-kit/tool-guardrails.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "empty table with ack -> PASS" 0 "$?"
  jq -e '.verdict == "PASS"' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "acked-empty-table report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  # 7. bypass -> SKIP
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'export const agentRunner = true;\n' > "$tmp/agent-runner.ts"
  WALTEUR_ROOT="$tmp" WALTEUR_TOOL_GUARDRAIL=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/tool-guardrail-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  # 8. PAUSED -> hard block
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tgg-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "tool-guardrail-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
if [ "${WALTEUR_TOOL_GUARDRAIL:-on}" = "off" ]; then
  echo "tool-guardrail-gate: bypassed (WALTEUR_TOOL_GUARDRAIL=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_TOOL_GUARDRAIL=off" '{"bypassed":true}'
  exit 0
fi

# ── applicability ───────────────────────────────────────────────────────────────
collect_contract_files
APPLICABLE="no"; APP_REASON=""
if [ -f "$MANIFEST" ]; then APPLICABLE="yes"; APP_REASON="tool-guardrails.json present"; fi
if [ "$APPLICABLE" = "no" ] && [ -d "$KIT/tool-contracts" ]; then APPLICABLE="yes"; APP_REASON="walteur-kit/tool-contracts/ present"; fi
if [ "$APPLICABLE" = "no" ] && [ "${#CONTRACT_FILES[@]}" -gt 0 ]; then APPLICABLE="yes"; APP_REASON="tool-contract file(s) present"; fi
if [ "$APPLICABLE" = "no" ]; then
  PRUNE=( -path "$ROOT/.git" -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/venv' \
          -o -path '*/dist' -o -path '*/build' -o -path '*/vendor' )
  NAME_HIT="$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \( -type f -o -type d \) -print 2>/dev/null \
    | grep -viE '(^|/)walteur-kit/' \
    | grep -iE '(^|/)[^/]*(agent|llm|prompt|mcp|rag|embedding|tool.?contract)[^/]*$' \
    | head -1)"
  if [ -n "$NAME_HIT" ]; then APPLICABLE="yes"; APP_REASON="AI/agent file name match: $NAME_HIT"; fi
fi

if [ "$APPLICABLE" = "no" ]; then
  echo "tool-guardrail-gate: not an AI/agent build — gate not applicable." >&2
  if have jq; then write_report "NOT_APPLICABLE" "no AI/agent build signals" "$(jq -n '{applicable:false}')";
  else write_report "NOT_APPLICABLE" "no AI/agent build signals" '{}'; fi
  exit 0
fi

echo "WALTEUR tool-guardrail-gate @ $ROOT — applicable ($APP_REASON)." >&2

# ── jq is the validator: absent => LOUD SKIP ──────────────────────────────────────
if ! have jq; then
  echo "WALTEUR tool-guardrail-gate SKIP — jq not installed; cannot validate guardrail coverage (recorded, NOT silent-green)." >&2
  write_report "SKIP" "jq not installed" '{}'
  exit 0
fi

# Applicable agent build but NO guardrail coverage table => the table is MISSING => violation.
if [ ! -f "$MANIFEST" ]; then
  echo "WALTEUR tool-guardrail-gate: FAIL — AI/agent build detected ($APP_REASON) but walteur-kit/tool-guardrails.json is absent." >&2
  echo "  Required: a guardrail coverage table declaring pre_call/post_call/error_path for every agent-callable tool." >&2
  write_report "FAIL" "AI/agent build with no guardrail coverage table" \
    "$(jq -n --arg r "$APP_REASON" '{applicable:true, reason:$r, guardrail_manifest:"absent", rule:"agent-build-requires-guardrail-coverage"}')"
  exit 2
fi

# Manifest must be valid JSON.
if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
  echo "WALTEUR tool-guardrail-gate: FAIL — tool-guardrails.json is not valid JSON." >&2
  write_report "FAIL" "tool-guardrails.json is not valid JSON" '{"applicable":true,"rule":"parse"}'
  exit 2
fi

# Valid enum for side_effect_class — read straight from the schema so we stay in lock-step.
ENUM_JSON="$(jq -c '.properties.tools.items.properties.side_effect_class.enum' "$SCHEMA" 2>/dev/null)"
{ [ -z "$ENUM_JSON" ] || [ "$ENUM_JSON" = "null" ]; } && ENUM_JSON='["read","write_undoable","write_irreversible","external_money"]'

# Fail-fast: if the jq program does not COMPILE, refuse to run (a non-compiling validator silently greens).
if ! printf '{"tools":[]}' | jq -e --argjson enum "$ENUM_JSON" "$JQ_PROG" >/dev/null 2>"$KIT/.tgg-jqerr" \
     && grep -qiE 'compile error|syntax error' "$KIT/.tgg-jqerr" 2>/dev/null; then
  echo "WALTEUR tool-guardrail-gate: INTERNAL ERROR — validation program failed to compile:" >&2
  sed 's/^/    /' "$KIT/.tgg-jqerr" >&2
  write_report "FAIL" "validator program compile error (internal)" "$(jq -n --rawfile e "$KIT/.tgg-jqerr" '{internal_error:$e}')"
  rm -f "$KIT/.tgg-jqerr"
  exit 2
fi
rm -f "$KIT/.tgg-jqerr"

# ── G0: envelope — required top-level keys present + correctly typed (the gate ENFORCES the
#        schema shape it reads from, not just the enum; this also rejects a quoted "external":"true"). ─
ENVELOPE_LINES="$(jq -r '
  [ (if (.schema_version|type) != "string" then "G0::envelope: schema_version must be a string" else empty end),
    (if (.manifest_id|type) != "string" then "G0::envelope: manifest_id must be a string" else empty end),
    (if (.updated_at|type) != "string" then "G0::envelope: updated_at must be a string" else empty end),
    (if (.policy|type) != "string" then "G0::envelope: policy must be a string" else empty end),
    (if (.tools|type) != "array" then "G0::envelope: tools must be an array" else empty end),
    ( (.tools // [])[]? | select(has("external") and (.external|type) != "boolean")
        | "G0::tool \(.tool // "?"): external must be a JSON boolean, not \(.external|type)" )
  ] | .[]' "$MANIFEST" 2>/dev/null)"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  rule="${line%%::*}"; msg="${line#*::}"
  add_violation "$MANIFEST" "$rule" "$msg"
done <<EOF
$ENVELOPE_LINES
EOF

# ── G1-G5: per-tool rules ─────────────────────────────────────────────────────────
TOOLS_CHECKED="$(jq -r '(.tools // []) | length' "$MANIFEST" 2>/dev/null)"
[ -n "$TOOLS_CHECKED" ] || TOOLS_CHECKED=0
ERRF="$(mktemp "${TMPDIR:-/tmp}/tool-guardrail-validate.XXXXXX")" || ERRF="$KIT/.tgg-validate.err"
OUTL="$(jq -r --argjson enum "$ENUM_JSON" "$JQ_PROG" "$MANIFEST" 2>"$ERRF")"
RC=$?
if [ "$RC" -ne 0 ]; then
  add_violation "$MANIFEST" "validate-error" "jq validation failed: $(tr '\n' ' ' < "$ERRF" | sed 's/  */ /g')"
fi
rm -f "$ERRF"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  rule="${line%%::*}"; msg="${line#*::}"
  add_violation "$MANIFEST" "$rule" "$msg"
done <<EOF
$OUTL
EOF

# ── G6: coverage — every declared tool-contract tool must appear in the table ───────
MANIFEST_TOOLS="$(jq -r '.tools[]?.tool // empty' "$MANIFEST" 2>/dev/null | awk 'NF' | sort -u)"
if [ "${#CONTRACT_FILES[@]}" -gt 0 ]; then
  for cf in "${CONTRACT_FILES[@]}"; do
    while IFS= read -r cname; do
      [ -z "$cname" ] && continue
      if ! printf '%s\n' "$MANIFEST_TOOLS" | grep -qxF "$cname"; then
        add_violation "$MANIFEST" "G6" "tool '$cname' declared in ${cf##*/} but missing from guardrail coverage table"
      fi
    done < <(jq -r 'if type=="array" then .[].name else .name end' "$cf" 2>/dev/null | awk 'NF' | sort -u)
  done
fi

# ── G7: an applicable agent build must not silently green an EMPTY guardrail table ──
# Tools are commonly defined in code (MCP servers, function-calling defs) with no *.tool.json,
# so an empty table + zero contracts cannot be assumed safe. Require an explicit, auditable ack.
if [ "$TOOLS_CHECKED" -eq 0 ] && [ "${#CONTRACT_FILES[@]}" -eq 0 ]; then
  ACK="$(jq -r 'if .no_external_tools == true then "yes" else "no" end' "$MANIFEST" 2>/dev/null)"
  if [ "$ACK" != "yes" ]; then
    add_violation "$MANIFEST" "G7" "applicable agent build declares an empty guardrail table and no tool-contracts; list each agent-callable tool, or set \"no_external_tools\": true to assert this build invokes no external tools"
  fi
fi

# ── verdict ─────────────────────────────────────────────────────────────────────
N_VIOL="${#VIOLATIONS[@]}"
DETAILS="$(jq -n --argjson checked "$TOOLS_CHECKED" --argjson nv "$N_VIOL" --argjson v "$VIOL_JSON" \
  '{applicable:true, tools_checked:$checked, violations:$nv, items:$v}')"

if [ "$N_VIOL" -gt 0 ]; then
  echo "WALTEUR tool-guardrail-gate: FAIL — $N_VIOL guardrail violation(s) across $TOOLS_CHECKED tool(s):" >&2
  for v in "${VIOLATIONS[@]}"; do echo "  - $v" >&2; done
  write_report "FAIL" "$N_VIOL tool-guardrail violation(s)" "$DETAILS"
  echo "tool-guardrail-gate verdict: FAIL -> $REPORT" >&2
  exit 2
fi

echo "tool-guardrail-gate: ok — $TOOLS_CHECKED tool(s) carry pre/post/error guardrails; coverage complete." >&2
write_report "PASS" "all tool guardrails valid and coverage complete" "$DETAILS"
echo "tool-guardrail-gate verdict: PASS -> $REPORT" >&2
exit 0
