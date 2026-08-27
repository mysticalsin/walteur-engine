#!/usr/bin/env bash
# WALTEUR audit-contract-gate - typed terminal audit certificate gate.
#
# Contract:
#   - No audit and not in ship/reflect phase      => NOT_APPLICABLE, exit 0.
#   - Empty runtime audit stub before ship        => NOT_APPLICABLE, exit 0.
#   - Ship/reflect phase without a valid audit    => FAIL, exit 2.
#   - Certified audit with blockers, gaps in core shape, stale evidence, or missing intent/layer proof => FAIL, exit 2.
#   - Complete audit certificate                  => PASS, exit 0.
#
# Report:
#   walteur-kit/audit-contract-report.json
#
# Bypass:
#   WALTEUR_AUDIT_CONTRACT=off
set -uo pipefail

input_dir="${1:-}"
if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "$WALTEUR_ROOT" ]; then
  ROOT="$(cd "$WALTEUR_ROOT" && pwd)"
elif [ -n "$input_dir" ] && [ -d "$input_dir" ]; then
  ROOT="$(cd "$input_dir" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
KIT="$ROOT/walteur-kit"
AUDIT="$KIT/audit.json"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/audit-contract-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_report() {
  verdict="$1"
  mode="$2"
  reason="$3"
  findings_json="${4:-[]}"
  if have jq; then
    jq -n \
      --arg v "$verdict" --arg ts "$TS" --arg mode "$mode" --arg reason "$reason" \
      --arg audit "${AUDIT#"$ROOT"/}" --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"audit-contract-gate", mode:$mode, audit_file:$audit, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"audit-contract-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0\n'
}

detect_audit_required() {
  AUDIT_REQUIRED=0
  AUDIT_REQUIRED_REASON=""

  if [ "${WALTEUR_AUDIT_REQUIRED:-}" = "1" ]; then
    AUDIT_REQUIRED=1
    AUDIT_REQUIRED_REASON="WALTEUR_AUDIT_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      ship|reflect)
        AUDIT_REQUIRED=1
        AUDIT_REQUIRED_REASON="STATE.phase=$phase"
        return 0 ;;
    esac
  fi
}

latest_source_mtime() {
  latest=0
  update_latest() {
    f="$1"
    [ -f "$f" ] || return 0
    case "$f" in
      "$REPORT"|"$AUDIT") return 0 ;;
    esac
    mt="$(mtime "$f")"
    [ "${mt:-0}" -gt "$latest" ] && latest="$mt"
  }

  if [ -d "$ROOT" ]; then
    while IFS= read -r -d '' f; do
      update_latest "$f"
    done < <(find "$ROOT" \
      \( -path '*/.git/*' -o -path '*/node_modules/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path "$KIT/*" \) -prune -o \
      -type f -print0 2>/dev/null)
  fi

  for f in \
    "$ROOT/PLAN.md" \
    "$ROOT/DESIGN.md" \
    "$KIT/PRD.md" \
    "$KIT/build-contract.json" \
    "$KIT/layers.json" \
    "$KIT/qa-report.json" \
    "$KIT/scoreboard.json" \
    "$KIT/DEFINITION-OF-DONE.md"
  do
    update_latest "$f"
  done

  printf '%s\n' "$latest"
}

check_string() {
  check="$1"
  filter="$2"
  if ! jq -e "$filter | type == \"string\" and length > 0" "$AUDIT" >/dev/null 2>&1; then
    add_finding "$check" "$check must be a non-empty string"
  fi
}

check_array() {
  check="$1"
  filter="$2"
  if ! jq -e "$filter | type == \"array\"" "$AUDIT" >/dev/null 2>&1; then
    add_finding "$check" "$check must be an array"
  fi
}

check_scored_dims() {
  for dim in design infrastructure security ux_ui performance features data_architecture devex; do
    if ! jq -e --arg d "$dim" '.scored_dims[$d] | type == "object"' "$AUDIT" >/dev/null 2>&1; then
      add_finding "scored_dims.$dim" "scored_dims.$dim is required"
      continue
    fi
    if ! jq -e --arg d "$dim" '(.scored_dims[$d].score | type == "number" and . >= 0 and . <= 10)' "$AUDIT" >/dev/null 2>&1; then
      add_finding "scored_dims.$dim.score" "scored_dims.$dim.score must be a number from 0 to 10"
    elif [ "$CERTIFIED" = "true" ] && ! jq -e --arg d "$dim" '.scored_dims[$d].score >= 8' "$AUDIT" >/dev/null 2>&1; then
      add_finding "scored_dims.$dim.floor" "certified audits require scored_dims.$dim.score >= 8"
    fi
    if ! jq -e --arg d "$dim" '(.scored_dims[$d].rationale // "" | type == "string" and length > 0)' "$AUDIT" >/dev/null 2>&1; then
      add_finding "scored_dims.$dim.rationale" "scored_dims.$dim.rationale is required"
    fi
    if ! jq -e --arg d "$dim" '(.scored_dims[$d].evidence_ref // "" | type == "string" and length > 0)' "$AUDIT" >/dev/null 2>&1; then
      add_finding "scored_dims.$dim.evidence_ref" "scored_dims.$dim.evidence_ref is required"
    fi
  done
}

check_layer_walk() {
  if jq -e '.layer_walk | type == "object"' "$AUDIT" >/dev/null 2>&1; then
    for id in $(seq 1 13); do
      if ! jq -e --arg id "$id" '.layer_walk[$id] | type == "object"' "$AUDIT" >/dev/null 2>&1; then
        add_finding "layer_walk.$id" "layer_walk must include layer $id"
        continue
      fi
      if ! jq -e --arg id "$id" '((.layer_walk[$id].status // .layer_walk[$id].verdict // "") | type == "string" and length > 0)' "$AUDIT" >/dev/null 2>&1; then
        add_finding "layer_walk.$id.status" "layer $id needs status or verdict"
      fi
      if ! jq -e --arg id "$id" '((.layer_walk[$id].evidence_ref // .layer_walk[$id].evidence // "") | type == "string" and length > 0)' "$AUDIT" >/dev/null 2>&1; then
        add_finding "layer_walk.$id.evidence" "layer $id needs evidence_ref or evidence"
      fi
    done
  elif jq -e '.layer_walk | type == "array"' "$AUDIT" >/dev/null 2>&1; then
    if ! jq -e '.layer_walk | length == 13' "$AUDIT" >/dev/null 2>&1; then
      add_finding "layer_walk.count" "layer_walk array must contain exactly 13 layers"
    fi
    for id in $(seq 1 13); do
      if ! jq -e --argjson id "$id" '.layer_walk[]? | select(.id == $id)' "$AUDIT" >/dev/null 2>&1; then
        add_finding "layer_walk.$id" "layer_walk must include layer id $id"
        continue
      fi
      if ! jq -e --argjson id "$id" '(.layer_walk[]? | select(.id == $id) | ((.status // .verdict // "") | type == "string" and length > 0))' "$AUDIT" >/dev/null 2>&1; then
        add_finding "layer_walk.$id.status" "layer $id needs status or verdict"
      fi
      if ! jq -e --argjson id "$id" '(.layer_walk[]? | select(.id == $id) | ((.evidence_ref // .evidence // "") | type == "string" and length > 0))' "$AUDIT" >/dev/null 2>&1; then
        add_finding "layer_walk.$id.evidence" "layer $id needs evidence_ref or evidence"
      fi
    done
  else
    add_finding "layer_walk.shape" "layer_walk must be an object keyed 1..13 or an array of 13 layer verdicts"
  fi
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
    echo "audit-contract-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    root="$1"
    phase="$2"
    mkdir -p "$root/walteur-kit/autopilot"
    jq -n --arg phase "$phase" '{
      schema_version: 1,
      run_id: "audit-selftest",
      goal: "Audit selftest",
      owner: "QA",
      build_class: "software",
      risk_tier: "medium",
      phase: $phase,
      autonomy_policy: "full_autopilot",
      budgets: { time_minutes: 1, input_tokens: 1, output_tokens: 1, cost_usd: 0 },
      protected_paths: [],
      stages: [],
      gates: [],
      evidence: [],
      decisions: [],
      signoffs: [],
      authority_boundaries: [],
      blockers: [],
      known_gaps: [],
      next_action: "audit",
      baton_path: "walteur-kit/autopilot/STATE.json",
      updated_at: "2026-06-22T00:00:00Z"
    }' > "$root/walteur-kit/autopilot/STATE.json"
  }

  write_source() {
    root="$1"
    mkdir -p "$root/src" "$root/walteur-kit"
    printf 'export const App = () => "ok";\n' > "$root/src/App.tsx"
    printf '# PRD\n\n## Story\nSTORY-1 says the app shows status.\n' > "$root/walteur-kit/PRD.md"
    printf '{"verdict":"PASS"}\n' > "$root/walteur-kit/qa-report.json"
    printf '{"target":8.5,"composite":9.1}\n' > "$root/walteur-kit/scoreboard.json"
    printf '{"schema_version":1,"production_layers":[]}\n' > "$root/walteur-kit/layers.json"
  }

  write_good_audit() {
    root="$1"
    mode="${2:-good}"
    mkdir -p "$root/walteur-kit"
    jq -n --arg mode "$mode" --arg ts "2026-06-22T00:00:00Z" '
      def dim($score): { score: $score, rationale: "Evidence was re-read and accepted.", evidence_ref: "walteur-kit/qa-report.json" };
      def layer($id): { id: $id, status: "verified", evidence_ref: "walteur-kit/layers.json", notes: ("Layer " + ($id|tostring) + " reviewed.") };
      {
        schema_version: 1,
        certified: true,
        model: "opus",
        scored_dims: {
          design: dim(9),
          infrastructure: dim(9),
          security: dim(9),
          ux_ui: dim(9),
          performance: dim(9),
          features: dim(9),
          data_architecture: dim(9),
          devex: dim(9)
        },
        layer_walk: [range(1;14) | layer(.)],
        adr_recheck: [],
        intent_vs_impl: [
          {
            intent_quote: "STORY-1 says the app shows status.",
            intent_source: "walteur-kit/PRD.md#story",
            code_evidence: "src/App.tsx:1",
            attacker: "none",
            victim: "user",
            fix: "none",
            severity: "none",
            verdict: "PASS"
          }
        ],
        launch_blockers: [],
        shortfalls: [],
        known_gaps: [],
        evidence_reproduced: true,
        ts: $ts
      }
      | if $mode == "blocker" then .launch_blockers = [{dimension:"ship", gap:"Missing rollback", fix:"Add rollback", severity:"high"}] else . end
      | if $mode == "uncertified-empty" then .certified = false else . end
      | if $mode == "empty-intent" then .intent_vs_impl = [] else . end
    ' > "$root/walteur-kit/audit.json"
  }

  echo "audit-contract-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-contract-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "no audit and not shipping -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-contract-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ship phase missing audit -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-contract-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  : > "$tmp/walteur-kit/audit.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "zero-byte runtime stub before ship -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-contract-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{ bad json\n' > "$tmp/walteur-kit/audit.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "malformed audit -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-contract-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{"certified":true,"model":"opus"}\n' > "$tmp/walteur-kit/audit.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "certified stub audit -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "ship"
  write_good_audit "$tmp" "blocker"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "certified audit with launch blocker -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "ship"
  write_good_audit "$tmp" "uncertified-empty"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "uncertified audit without shortfalls or blockers -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "ship"
  write_good_audit "$tmp" "empty-intent"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "PRD present but certified audit has no intent evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "ship"
  write_good_audit "$tmp" "good"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "complete certified audit -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "ship"
  write_good_audit "$tmp" "good"
  touch -t 202001010000 "$tmp/walteur-kit/audit.json" 2>/dev/null || true
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "stale certified audit after source edit -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "audit-contract-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && {
  write_report "FAIL" "paused" "walteur-kit/PAUSED present" '[{"check":"paused","message":"WALTEUR is paused"}]'
  echo "audit-contract-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
}

if [ "${WALTEUR_AUDIT_CONTRACT:-on}" = "off" ]; then
  write_report "SKIP" "bypass" "WALTEUR_AUDIT_CONTRACT=off" "[]"
  echo "audit-contract-gate verdict: SKIP - bypassed via WALTEUR_AUDIT_CONTRACT=off -> $REPORT" >&2
  exit 0
fi

if ! have jq; then
  write_report "SKIP" "tool-missing" "jq not installed" "[]"
  echo "audit-contract-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  exit 0
fi

detect_audit_required

if [ ! -f "$AUDIT" ]; then
  if [ "$AUDIT_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "missing" "terminal audit required ($AUDIT_REQUIRED_REASON) but walteur-kit/audit.json is absent" \
      '[{"check":"audit.present","message":"ship/reflect requires walteur-kit/audit.json shaped by walteur-kit/schemas/audit.schema.json"}]'
    echo "audit-contract-gate verdict: FAIL - audit missing while required ($AUDIT_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "not-applicable" "no audit file and current phase does not require one" "[]"
  echo "audit-contract-gate verdict: NOT_APPLICABLE - no audit file before ship -> $REPORT" >&2
  exit 0
fi

if [ ! -s "$AUDIT" ]; then
  if [ "$AUDIT_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "empty" "terminal audit required ($AUDIT_REQUIRED_REASON) but walteur-kit/audit.json is empty" \
      '[{"check":"audit.nonempty","message":"zero-byte audit stubs cannot satisfy ship/reflect"}]'
    echo "audit-contract-gate verdict: FAIL - empty audit while required ($AUDIT_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "runtime-stub" "zero-byte runtime stub before ship" "[]"
  echo "audit-contract-gate verdict: NOT_APPLICABLE - zero-byte runtime stub before ship -> $REPORT" >&2
  exit 0
fi

if ! jq empty "$AUDIT" >/dev/null 2>&1; then
  write_report "FAIL" "invalid-json" "walteur-kit/audit.json is invalid JSON" \
    '[{"check":"audit.json","message":"walteur-kit/audit.json must be valid JSON"}]'
  echo "audit-contract-gate verdict: FAIL - audit JSON invalid -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0
CERTIFIED="$(jq -r 'if has("certified") then (.certified | tostring) else "" end' "$AUDIT" 2>/dev/null || true)"

if ! jq -e '.schema_version == 1' "$AUDIT" >/dev/null 2>&1; then
  add_finding "schema_version" "schema_version must be 1"
fi
if ! jq -e '.certified | type == "boolean"' "$AUDIT" >/dev/null 2>&1; then
  add_finding "certified" "certified must be a boolean"
fi
if ! jq -e '.model == "opus"' "$AUDIT" >/dev/null 2>&1; then
  add_finding "model" "terminal audit must record model:\"opus\""
fi

check_string "ts" '.ts'
if ! jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$AUDIT" >/dev/null 2>&1; then
  add_finding "ts.format" "ts must be UTC ISO format YYYY-MM-DDTHH:MM:SSZ"
fi

if ! jq -e '.scored_dims | type == "object"' "$AUDIT" >/dev/null 2>&1; then
  add_finding "scored_dims.shape" "scored_dims must be an object with the eight score dimensions"
else
  check_scored_dims
fi

check_layer_walk

if ! jq -e '(.adr_recheck | type == "array") or (.adr_recheck | type == "object")' "$AUDIT" >/dev/null 2>&1; then
  add_finding "adr_recheck" "adr_recheck must be an array or object"
fi

check_array "intent_vs_impl" '.intent_vs_impl'
if [ "$CERTIFIED" = "true" ] && { [ -f "$KIT/PRD.md" ] || [ -f "$KIT/prd.proofs.json" ]; }; then
  if ! jq -e '.intent_vs_impl | type == "array" and length > 0' "$AUDIT" >/dev/null 2>&1; then
    add_finding "intent_vs_impl.required" "certified product/PRD audits require at least one intended-vs-implemented evidence entry"
  fi
fi

bad_intent_entries="$(jq -r '
  (.intent_vs_impl // []) | to_entries[]
  | select(
      ((.value.intent_quote // .value.intent // "") | tostring | length == 0)
      or ((.value.intent_source // .value.story // .value.ac // "") | tostring | length == 0)
      or ((.value.code_evidence // .value.ast_proof.file // "") | tostring | length == 0)
    )
  | .key
' "$AUDIT" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_intent_entries" ] && add_finding "intent_vs_impl.shape" "intent_vs_impl entries need intended side, source, and implemented evidence at indexes: $bad_intent_entries"

if [ "$CERTIFIED" = "true" ] && ! jq -e '
  [(.intent_vs_impl // [])[]?
   | select(
      (.ast_proof.matched? == false)
      or (.launch_blocker == true)
      or (((.verdict // "") | ascii_downcase) | test("fail|veto|block"))
    )] | length == 0
' "$AUDIT" >/dev/null 2>&1; then
  add_finding "intent_vs_impl.blocking" "certified audits cannot carry failed, vetoed, blocked, launch-blocking, or unmatched intent evidence"
fi

check_array "launch_blockers" '.launch_blockers'
check_array "shortfalls" '.shortfalls'
check_array "known_gaps" '.known_gaps'

if [ "$CERTIFIED" = "true" ]; then
  if ! jq -e '.launch_blockers | type == "array" and length == 0' "$AUDIT" >/dev/null 2>&1; then
    add_finding "launch_blockers.empty" "certified audits require launch_blockers to be empty"
  fi
  if ! jq -e '.shortfalls | type == "array" and length == 0' "$AUDIT" >/dev/null 2>&1; then
    add_finding "shortfalls.empty" "certified audits require shortfalls to be empty"
  fi
  if ! jq -e '.evidence_reproduced == true' "$AUDIT" >/dev/null 2>&1; then
    add_finding "evidence_reproduced" "certified audits require evidence_reproduced:true"
  fi
elif [ "$CERTIFIED" = "false" ]; then
  if jq -e '((.launch_blockers // []) | length == 0) and ((.shortfalls // []) | length == 0)' "$AUDIT" >/dev/null 2>&1; then
    add_finding "uncertified.detail" "uncertified audits must list at least one launch_blocker or shortfall"
  fi
fi

bad_known_gaps="$(jq -r '
  (.known_gaps // []) | to_entries[]
  | select(
      (.value | type) != "object"
      or ((.value.gap // "") | tostring | length == 0)
      or ((.value.severity // "") | tostring | length == 0)
      or ((.value.owner // "") | tostring | length == 0)
    )
  | .key
' "$AUDIT" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_known_gaps" ] && add_finding "known_gaps.shape" "known_gaps entries require gap, severity, and owner at indexes: $bad_known_gaps"

placeholder_hits="$(jq -r '
  .. | strings
  | select(test("(^|\\b)(TODO|TBD|FIXME|placeholder|lorem ipsum)(\\b|$)|<[^>]+>"; "i"))
' "$AUDIT" 2>/dev/null | head -5 | paste -sd ' | ' -)"
[ -n "$placeholder_hits" ] && add_finding "placeholder" "audit contains placeholder text: $placeholder_hits"

if [ "$CERTIFIED" = "true" ]; then
  audit_mtime="$(mtime "$AUDIT")"
  latest_mtime="$(latest_source_mtime)"
  if [ "${latest_mtime:-0}" -gt "${audit_mtime:-0}" ]; then
    add_finding "freshness" "certified audit is older than at least one source, spec, QA, score, or layer artifact"
  fi
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "strict terminal audit contract failed with $failures finding(s)" "$findings"
  echo "audit-contract-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "pass" "terminal audit certificate is complete, fresh, and blocker-free" "$findings"
echo "audit-contract-gate verdict: PASS - terminal audit certificate is complete, fresh, and blocker-free -> $REPORT" >&2
exit 0
