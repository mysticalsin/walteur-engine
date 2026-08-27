#!/usr/bin/env bash
# WALTEUR tool-contract-lint — ZERO-DEP HARD gate on agent tool contracts.
#
# WHY: an AI/agent build that lets a model invoke tools is only as safe as the contracts on
# those tools. An unbounded, schema-less, side-effect-unlabelled tool is the single largest
# blast-radius hole in an agentic system — it is how a prompt-injection turns into a wire
# transfer or an irreversible delete. This gate makes the contract a HARD, checkable artefact.
#
# APPLICABILITY (checked FIRST — the #1 past bug is a gate that exit-2s a project the discipline
# does not even apply to). This gate is APPLICABLE iff the build is an AI/agent build, i.e. ANY of:
#   - walteur-kit/tool-contracts/ directory exists, OR
#   - any tool-contract file is present anywhere (walteur-kit/tool-contracts/*.json or *.tool.json), OR
#   - a project file/dir NAME matches  agent|llm|prompt|mcp|rag|embedding|tool.?contract
#     (case-insensitive), under the project, excluding vcs/deps/build/the kit itself.
# If NONE of those hold => bare/non-AI project => {"verdict":"NOT_APPLICABLE"} + exit 0.
#
# WHEN APPLICABLE, validate EVERY tool-contract file (walteur-kit/tool-contracts/*.json + *.tool.json
# anywhere in the project) against the SHAPE of walteur-kit/schemas/tool-contract.schema.json:
#   R1  required keys present: name, input, output, side_effect_class, idempotent,
#       error_taxonomy, oversight_gate.
#   R2  side_effect_class is one of the schema enum: read | write_undoable | write_irreversible
#       | external_money.
#   R3  THE INVARIANT: side_effect_class in {write_irreversible, external_money} REQUIRES
#       oversight_gate == true. A dangerous tool with no human gate is the violation we exist for.
#   R4  input must be a STRUCTURED JSON-Schema object (has "type" or "properties" or "$ref").
#       A free-form / missing / non-object input (e.g. "input": "any string", {}, or absent) is a
#       contract violation — an agent tool with no typed input is unbounded.
# ANY violation in an applicable project => exit 2. Clean => exit 0.
#
# Validation engine: jq (part of WALTEUR's zero-dep baseline) => this is a HARD gate (real exit 2),
# not a detect-or-skip gate. If jq is genuinely absent we LOUD-SKIP (never silent-green, never exit 2).
#
# Report: walteur-kit/tool-contract-report.json {verdict, ts, gate, details}.
# Bypass: WALTEUR_TOOL_CONTRACT=off. Honors walteur-kit/PAUSED.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/tool-contract-report.json"
SCHEMA="$KIT/schemas/tool-contract.schema.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# write_report <verdict> <reason> <details-json-object-or-array>
# jq-first; printf fallback so a report ALWAYS lands.
write_report() {
  local v="$1" reason="$2" details="${3:-}"
  [ -n "$details" ] || details="{}"
  if have jq; then
    local details_file
    details_file="$(mktemp "${TMPDIR:-/tmp}/tool-contract-report-details.XXXXXX")" || details_file=""
    if [ -n "$details_file" ]; then
      printf '%s\n' "$details" > "$details_file"
      if jq -e . "$details_file" >/dev/null 2>&1; then
        jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --slurpfile d "$details_file" \
          '{verdict:$v, ts:$ts, gate:"tool-contract", reason:$reason, details:$d[0]}' > "$REPORT" 2>/dev/null
        rc=$?
        rm -f "$details_file"
        [ "$rc" -eq 0 ] && return 0
      else
        rm -f "$details_file"
      fi
    fi
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"tool-contract","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
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
      echo "tool-contract-lint selftest SKIP - required tool '$t' not installed."
      return 0
    fi
  done

  make_valid_contract() {
    mkdir -p "$1/walteur-kit/tool-contracts"
    cat > "$1/walteur-kit/tool-contracts/search.json" <<'JSON'
{
  "name": "search_docs",
  "input": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string"
      }
    },
    "required": ["query"]
  },
  "output": {
    "type": "object",
    "properties": {
      "results": {
        "type": "array"
      }
    }
  },
  "side_effect_class": "read",
  "idempotent": true,
  "error_taxonomy": {
    "retryable": ["timeout"],
    "fatal": ["permission_denied"]
  },
  "oversight_gate": false
}
JSON
  }

  echo "tool-contract-lint selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tclint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'console.log("hello");\n' > "$tmp/app.js"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "non-AI project -> NOT_APPLICABLE exit" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/tool-contract-report.json" >/dev/null 2>&1
  ck "non-AI report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tclint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  printf 'export const agentRunner = true;\n' > "$tmp/src/agent-runner.ts"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "AI signal without contracts -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .details.contract_files == 0' "$tmp/walteur-kit/tool-contract-report.json" >/dev/null 2>&1
  ck "missing contracts report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tclint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  make_valid_contract "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "valid tool contract -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .details.files_checked == 1 and .details.violations == 0' "$tmp/walteur-kit/tool-contract-report.json" >/dev/null 2>&1
  ck "valid contract report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tclint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/tool-contracts"
  cat > "$tmp/walteur-kit/tool-contracts/pay.json" <<'JSON'
{
  "name": "send_payment",
  "input": {
    "type": "object",
    "properties": {
      "amount": {
        "type": "number"
      }
    }
  },
  "output": {
    "type": "object"
  },
  "side_effect_class": "external_money",
  "idempotent": false,
  "error_taxonomy": {},
  "oversight_gate": false
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "dangerous tool without oversight -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.details.items[]?.rule == "R3")' "$tmp/walteur-kit/tool-contract-report.json" >/dev/null 2>&1
  ck "dangerous tool report records R3" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tclint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/tool-contracts"
  cat > "$tmp/walteur-kit/tool-contracts/freeform.json" <<'JSON'
{
  "name": "write_note",
  "input": "anything",
  "output": {
    "type": "object"
  },
  "side_effect_class": "write_undoable",
  "idempotent": false,
  "error_taxonomy": {},
  "oversight_gate": false
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "free-form input -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.details.items[]?.rule == "R4")' "$tmp/walteur-kit/tool-contract-report.json" >/dev/null 2>&1
  ck "free-form input report records R4" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tclint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'export const agentRunner = true;\n' > "$tmp/agent-runner.ts"
  WALTEUR_ROOT="$tmp" WALTEUR_TOOL_CONTRACT=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/tool-contract-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tclint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "tool-contract-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
if [ "${WALTEUR_TOOL_CONTRACT:-on}" = "off" ]; then
  echo "tool-contract-lint: bypassed (WALTEUR_TOOL_CONTRACT=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_TOOL_CONTRACT=off" '{"bypassed":true}'
  exit 0
fi

# Dirs we never scan for either applicability signals or contract files.
PRUNE=( -path "$ROOT/.git" -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/venv' \
        -o -path '*/dist' -o -path '*/build' -o -path '*/vendor' )

# ── collect tool-contract files ───────────────────────────────────────────────
# (a) every *.json directly under walteur-kit/tool-contracts/ , and
# (b) every *.tool.json anywhere in the project (minus pruned dirs and the report itself).
CONTRACT_FILES=()
if [ -d "$KIT/tool-contracts" ]; then
  while IFS= read -r f; do [ -n "$f" ] && CONTRACT_FILES+=("$f"); done < <(
    find "$KIT/tool-contracts" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort
  )
fi
while IFS= read -r f; do
  [ -z "$f" ] && continue
  CONTRACT_FILES+=("$f")
done < <(
  find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -type f -name '*.tool.json' -print 2>/dev/null | sort
)
# De-dup (a *.tool.json could live under tool-contracts/ and match both finds).
if [ "${#CONTRACT_FILES[@]}" -gt 0 ]; then
  UNIQ=()
  while IFS= read -r f; do [ -n "$f" ] && UNIQ+=("$f"); done < <(printf '%s\n' "${CONTRACT_FILES[@]}" | awk 'NF' | sort -u)
  CONTRACT_FILES=("${UNIQ[@]}")
fi

# ── applicability ─────────────────────────────────────────────────────────────
APPLICABLE="no"
APP_REASON=""
if [ -d "$KIT/tool-contracts" ]; then APPLICABLE="yes"; APP_REASON="walteur-kit/tool-contracts/ present"; fi
if [ "$APPLICABLE" = "no" ] && [ "${#CONTRACT_FILES[@]}" -gt 0 ]; then
  APPLICABLE="yes"; APP_REASON="tool-contract file(s) present"
fi
if [ "$APPLICABLE" = "no" ]; then
  # Name-based AI/agent signal anywhere in the project tree.
  NAME_HIT="$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \
      \( -type f -o -type d \) \
      -print 2>/dev/null \
    | grep -viE '(^|/)walteur-kit/' \
    | grep -iE '(^|/)[^/]*(agent|llm|prompt|mcp|rag|embedding|tool.?contract)[^/]*$' \
    | head -1)"
  if [ -n "$NAME_HIT" ]; then
    APPLICABLE="yes"; APP_REASON="AI/agent file name match: $NAME_HIT"
  fi
fi

if [ "$APPLICABLE" = "no" ]; then
  echo "tool-contract-lint: not an AI/agent build (no tool-contracts/, no *.tool.json, no agent|llm|prompt|mcp|rag|embedding|tool-contract name) — gate not applicable." >&2
  if have jq; then
    write_report "NOT_APPLICABLE" "no AI/agent build signals" "$(jq -n '{applicable:false, contract_files:0}')"
  else
    write_report "NOT_APPLICABLE" "no AI/agent build signals" '{}'
  fi
  exit 0
fi

echo "WALTEUR tool-contract-lint @ $ROOT — applicable ($APP_REASON)." >&2

# ── jq is the validator: absent => LOUD SKIP (never silent-green, never exit 2) ─
if ! have jq; then
  echo "WALTEUR tool-contract-lint SKIP — jq not installed; cannot validate tool contracts (recorded, NOT silent-green)." >&2
  write_report "SKIP" "jq not installed" '{}'
  exit 0
fi

# Applicable (AI/agent build) but ZERO contract files anywhere => the contracts are MISSING.
# An agentic build with no declared tool contracts is itself the violation.
if [ "${#CONTRACT_FILES[@]}" -eq 0 ]; then
  echo "WALTEUR tool-contract-lint: FAIL — AI/agent build detected ($APP_REASON) but NO tool-contract files found." >&2
  echo "  Required: walteur-kit/tool-contracts/*.json or *.tool.json declaring each agent-callable tool's contract." >&2
  write_report "FAIL" "AI/agent build with no tool contracts" \
    "$(jq -n --arg r "$APP_REASON" '{applicable:true, reason:$r, contract_files:0, rule:"agent-build-requires-tool-contracts"}')"
  exit 2
fi

# Valid enum for side_effect_class — read straight from the schema so we stay in lock-step with it.
ENUM_JSON="$(jq -c '.properties.side_effect_class.enum' "$SCHEMA" 2>/dev/null)"
[ -z "$ENUM_JSON" ] || [ "$ENUM_JSON" = "null" ] && ENUM_JSON='["read","write_undoable","write_irreversible","external_money"]'

VIOLATIONS=()          # human-readable lines
VIOL_JSON='[]'         # structured array for the report
add_violation() {      # add_violation <file> <rule> <message>
  local file="$1" rule="$2" msg="$3"
  VIOLATIONS+=("$file [$rule] $msg")
  VIOL_JSON="$(jq -c --arg f "$file" --arg r "$rule" --arg m "$msg" '. + [{file:$f, rule:$r, message:$m}]' <<<"$VIOL_JSON")"
}

# The validation program. A contract file may hold ONE tool object OR an ARRAY of tool objects;
# we normalise to a stream and emit one "RULE::message" line per failing rule per tool.
# NOTE: inside jq string-interpolation \(...) the inner string uses PLAIN quotes ", " — escaping
# them as \" is invalid jq and was the silent-green bug this gate is hardened against.
JQ_PROG='
  ( ["name","input","output","side_effect_class","idempotent","error_taxonomy","oversight_gate"] ) as $req
  | (if type=="array" then . else [.] end)
  | to_entries[]
  | .key as $i | .value as $t
  | ($t.name // ("#"+($i|tostring))) as $tn
  | (
      # R1 — missing required keys
      ( $req - ($t | keys) ) as $missing
      | (if ($missing|length) > 0
           then "R1::tool \($tn): missing required key(s): \($missing|join(", "))"
           else empty end),

      # R2 — side_effect_class must be in the schema enum (only if present)
      (if ($t|has("side_effect_class"))
         then (if ($enum | index($t.side_effect_class)) == null
                 then "R2::tool \($tn): side_effect_class \"\($t.side_effect_class)\" not in [\($enum|join(", "))]"
                 else empty end)
         else empty end),

      # R3 — THE INVARIANT: dangerous side effect REQUIRES oversight_gate==true
      (if ($t.side_effect_class == "write_irreversible" or $t.side_effect_class == "external_money")
         then (if ($t.oversight_gate == true)
                 then empty
                 else "R3::tool \($tn): side_effect_class \"\($t.side_effect_class)\" REQUIRES oversight_gate==true (got \($t.oversight_gate|tojson))"
               end)
         else empty end),

      # R4 — input must be a structured JSON-Schema object (type | properties | $ref)
      (if ($t|has("input")|not)
         then empty
         else (if ($t.input|type) != "object"
                 then "R4::tool \($tn): input is not a structured object (free-form input is forbidden; got \($t.input|type))"
                 else (if (($t.input|has("type")) or ($t.input|has("properties")) or ($t.input|has("$ref")))
                         then empty
                         else "R4::tool \($tn): input object has no JSON-Schema shape (needs type/properties/$ref) — free-form input is forbidden"
                       end)
               end)
       end)
    )
'

# Fail-fast: if the jq program does not even COMPILE, refuse to run — a non-compiling validator that
# swallows its error is exactly how a gate silently-greens. Verify once against a trivial input.
if ! printf '{}' | jq -e --argjson enum "$ENUM_JSON" "$JQ_PROG" >/dev/null 2>"$KIT/.tcl-jqerr" \
     && grep -qiE 'compile error|syntax error' "$KIT/.tcl-jqerr" 2>/dev/null; then
  echo "WALTEUR tool-contract-lint: INTERNAL ERROR — validation program failed to compile:" >&2
  sed 's/^/    /' "$KIT/.tcl-jqerr" >&2
  write_report "FAIL" "validator program compile error (internal)" \
    "$(jq -n --rawfile e "$KIT/.tcl-jqerr" '{internal_error:$e}')"
  rm -f "$KIT/.tcl-jqerr"
  exit 2
fi
rm -f "$KIT/.tcl-jqerr"

CHECKED=0
for f in "${CONTRACT_FILES[@]}"; do
  CHECKED=$((CHECKED+1))
  # Parse-level: must be valid JSON at all.
  if ! jq -e . "$f" >/dev/null 2>&1; then
    add_violation "$f" "parse" "not valid JSON"
    continue
  fi
  ERRF="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"
  OUTL="$(jq -r --argjson enum "$ENUM_JSON" "$JQ_PROG" "$f" 2>"$ERRF")"
  RC=$?
  if [ "$RC" -ne 0 ]; then
    # jq ran but errored on this file (e.g. runtime error) — surface it, never swallow.
    add_violation "$f" "validate-error" "jq validation failed: $(tr '\n' ' ' < "$ERRF" | sed 's/  */ /g')"
    rm -f "$ERRF"
    continue
  fi
  rm -f "$ERRF"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rule="${line%%::*}"; msg="${line#*::}"
    add_violation "$f" "$rule" "$msg"
  done <<EOF
$OUTL
EOF
done

# ── verdict ───────────────────────────────────────────────────────────────────
N_VIOL="${#VIOLATIONS[@]}"
DETAILS="$(jq -n --argjson checked "$CHECKED" --argjson nv "$N_VIOL" --argjson v "$VIOL_JSON" \
  '{applicable:true, files_checked:$checked, violations:$nv, items:$v}')"

if [ "$N_VIOL" -gt 0 ]; then
  echo "WALTEUR tool-contract-lint: FAIL — $N_VIOL violation(s) across $CHECKED contract file(s):" >&2
  for v in "${VIOLATIONS[@]}"; do echo "  - $v" >&2; done
  write_report "FAIL" "$N_VIOL tool-contract violation(s)" "$DETAILS"
  echo "tool-contract-lint verdict: FAIL -> $REPORT" >&2
  exit 2
fi

echo "tool-contract-lint: ok — $CHECKED contract file(s) valid (required keys, enum, oversight invariant, typed input)." >&2
write_report "PASS" "all tool contracts valid" "$DETAILS"
echo "tool-contract-lint verdict: PASS -> $REPORT" >&2
exit 0
