#!/usr/bin/env bash
# WALTEUR ai-tool-governance-gate - AI/tool inventory, approval, and boundary proof.
#
# Contract:
#   - No ai-tool-governance.json and no ship/reflect requirement       => NOT_APPLICABLE, exit 0.
#   - Ship/reflect or WALTEUR_AI_TOOL_GOVERNANCE_REQUIRED=1 without it => FAIL, exit 2.
#   - Weak/malformed/stale AI-tool governance proof                    => FAIL, exit 2.
#   - Complete AI-tool governance proof                                => PASS, exit 0.
#
# Report:
#   walteur-kit/ai-tool-governance-report.json
#
# Bypass:
#   WALTEUR_AI_TOOL_GOVERNANCE=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "ai-tool-governance-gate - AI/tool inventory, approval, and boundary proof."
  printf '%s\n' "usage: bash ai-tool-governance-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/ai-tool-governance-report.json - fix recipes: walteur-kit/REMEDIATION.md (## ai-tool-governance-gate)"
  printf '%s\n' "bypass: WALTEUR_AI_TOOL_GOVERNANCE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

input_dir="${1:-}"
if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "$WALTEUR_ROOT" ]; then
  ROOT="$(cd "$WALTEUR_ROOT" && pwd)"
elif [ -n "$input_dir" ] && [ -d "$input_dir" ]; then
  ROOT="$(cd "$input_dir" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
PROOF="$KIT/ai-tool-governance.json"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/ai-tool-governance-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MAX_AGE_DAYS="${WALTEUR_AI_TOOL_GOVERNANCE_MAX_AGE_DAYS:-14}"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  local verdict="$1" reason="$2" extra="${3-}"
  [ -n "$extra" ] || extra='{}'
  if have jq && printf '%s\n' "$extra" | jq -e . >/dev/null 2>&1; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg reason "$reason" --arg proof "${PROOF#"$ROOT"/}" --argjson extra "$extra" \
      '{verdict:$v, ts:$ts, gate:"ai-tool-governance-gate", proof_file:$proof, reason:$reason} + $extra' > "$REPORT" 2>/dev/null \
      && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"ai-tool-governance-gate","proof_file":"%s","reason":"%s"}\n' \
    "$verdict" "$TS" "${PROOF#"$ROOT"/}" "$reason" > "$REPORT" 2>/dev/null || true
}

detect_required() {
  REQUIRED=0
  REQUIRED_REASON=""

  if [ "${WALTEUR_AI_TOOL_GOVERNANCE_REQUIRED:-}" = "1" ]; then
    REQUIRED=1
    REQUIRED_REASON="WALTEUR_AI_TOOL_GOVERNANCE_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && have jq && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      ship|reflect)
        REQUIRED=1
        REQUIRED_REASON="STATE.phase=$phase"
        return 0
        ;;
    esac
  fi
}

selftest() {
  local pass=0 fail=0 tmp today self_path
  self_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  today="$(date -u +%F)"

  ck() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  if ! have jq; then
    echo "ai-tool-governance-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    local dst="$1" phase="${2:-ship}"
    mkdir -p "$dst/walteur-kit/autopilot"
    jq -n --arg phase "$phase" '{
      schema_version: 1,
      run_id: "ai-tool-governance-selftest",
      goal: "AI tool governance selftest",
      owner: "release-owner",
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
      next_action: "ship",
      baton_path: "walteur-kit/autopilot/STATE.json",
      updated_at: "2026-06-23T00:00:00Z"
    }' > "$dst/walteur-kit/autopilot/STATE.json"
  }

  write_evidence() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit/ai-tools"
    for f in inventory data-boundary confidentiality prompt-injection allowlist model-routing cost audit revoke approval output-gate tool-contract rollback signoff evidence; do
      printf '%s evidence\n' "$f" > "$dst/walteur-kit/ai-tools/$f.txt"
    done
  }

  write_good_proof() {
    local dst="$1" run_date="${2:-$today}" client_tier="${3:-tier_3_standard}" runtime_boundary="${4:-general_purpose}" data_classification="${5:-public}" model_tier="${6:-sonnet}"
    mkdir -p "$dst/walteur-kit"
    cat > "$dst/walteur-kit/ai-tool-governance.json" <<JSON
{
  "schema_version": 1,
  "governance_id": "ai-tool-governance-selftest",
  "run_date": "$run_date",
  "build_class": "software",
  "risk_tier": "medium",
  "verdict": "PASS",
  "policy": {
    "client_tier": "$client_tier",
    "ai_tool_steward": "tool-steward",
    "data_policy": "No client confidential data enters a general-purpose model.",
    "explicit_approval_required": true
  },
  "controls": {
    "inventory_ref": "walteur-kit/ai-tools/inventory.txt",
    "data_boundary_ref": "walteur-kit/ai-tools/data-boundary.txt",
    "confidentiality_ref": "walteur-kit/ai-tools/confidentiality.txt",
    "prompt_injection_ref": "walteur-kit/ai-tools/prompt-injection.txt",
    "tool_allowlist_ref": "walteur-kit/ai-tools/allowlist.txt",
    "model_routing_ref": "walteur-kit/ai-tools/model-routing.txt",
    "cost_budget_ref": "walteur-kit/ai-tools/cost.txt",
    "audit_log_ref": "walteur-kit/ai-tools/audit.txt",
    "revoke_plan_ref": "walteur-kit/ai-tools/revoke.txt"
  },
  "tools": [
    {
      "id": "codex-sonnet",
      "name": "Codex Sonnet builder",
      "category": "model",
      "purpose": "Software implementation under WALTEUR gates.",
      "data_classification": "$data_classification",
      "client_data_access": false,
      "runtime_boundary": "$runtime_boundary",
      "approval_status": "approved",
      "approval_ref": "walteur-kit/ai-tools/approval.txt",
      "allowlist_ref": "walteur-kit/ai-tools/allowlist.txt",
      "output_gate_ref": "walteur-kit/ai-tools/output-gate.txt",
      "tool_contract_ref": "walteur-kit/ai-tools/tool-contract.txt",
      "audit_log_ref": "walteur-kit/ai-tools/audit.txt",
      "cost_budget_ref": "walteur-kit/ai-tools/cost.txt",
      "rollback_ref": "walteur-kit/ai-tools/rollback.txt",
      "human_review_required": true,
      "model_tier": "$model_tier",
      "execution_stages": ["plan", "review"]
    }
  ],
  "evidence_refs": ["walteur-kit/ai-tools/evidence.txt"],
  "signoff": {
    "required": true,
    "signoff_ref": "walteur-kit/ai-tools/signoff.txt",
    "owner": "release-owner"
  }
}
JSON
  }

  echo "ai-tool-governance-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "no phase and no ai-tool-governance.json -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "ship phase without ai-tool-governance.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  mkdir -p "$tmp/walteur-kit"
  printf '{not json\n' > "$tmp/walteur-kit/ai-tool-governance.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "invalid ai-tool-governance.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "valid AI tool governance proof -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq 'del(.tools[0].approval_ref)' "$tmp/walteur-kit/ai-tool-governance.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/ai-tool-governance.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "missing tool approval ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp" "$today" tier_1_regulated general_purpose confidential sonnet
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "tier-1 confidential data on general-purpose model -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp" "$today" tier_3_standard general_purpose public opus
  jq '.tools[0].execution_stages = ["local_build"]' "$tmp/walteur-kit/ai-tool-governance.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/ai-tool-governance.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "opus model assigned to execution stage -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq '.tools[0].human_review_required = false' "$tmp/walteur-kit/ai-tool-governance.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/ai-tool-governance.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "missing human review on AI output -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp" "2000-01-01"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "stale governance proof -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq '.controls.audit_log_ref = "../outside.txt"' "$tmp/walteur-kit/ai-tool-governance.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/ai-tool-governance.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "unsafe evidence ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq '.signoff.required = false' "$tmp/walteur-kit/ai-tool-governance.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/ai-tool-governance.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "missing required signoff -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp"
  : > "$tmp/walteur-kit/ai-tools/audit.txt"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "empty local evidence ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  WALTEUR_AI_TOOL_GOVERNANCE=off WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ai-tool-governance-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  : > "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  if [ "$fail" -eq 0 ]; then
    echo "ai-tool-governance-gate selftest: $pass/$pass passed"
    return 0
  fi
  echo "ai-tool-governance-gate selftest: $fail failed, $pass passed"
  return 1
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

if [ "${WALTEUR_AI_TOOL_GOVERNANCE:-}" = "off" ]; then
  write_report "SKIP" "WALTEUR_AI_TOOL_GOVERNANCE=off"
  exit 0
fi

if [ -f "$KIT/PAUSED" ]; then
  write_report "FAIL" "WALTEUR is paused"
  exit 2
fi

detect_required

if [ ! -s "$PROOF" ]; then
  if [ "$REQUIRED" -eq 1 ]; then
    write_report "FAIL" "ai-tool-governance.json required: $REQUIRED_REASON"
    exit 2
  fi
  write_report "NOT_APPLICABLE" "ai-tool-governance.json absent and no ship/reflect requirement"
  exit 0
fi

if ! have jq; then
  write_report "FAIL" "jq is required to validate ai-tool-governance.json"
  exit 2
fi

if ! jq empty "$PROOF" >/dev/null 2>&1; then
  write_report "FAIL" "ai-tool-governance.json is not valid JSON"
  exit 2
fi

if ! jq -e '
  type == "object"
  and .schema_version == 1
  and (.governance_id | type == "string" and length > 0)
  and (.run_date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
  and (.build_class | type == "string" and length > 0)
  and (.risk_tier | type == "string" and length > 0)
  and .verdict == "PASS"
  and (.policy | type == "object")
  and (.policy.client_tier as $tier | ["tier_1_regulated","tier_2_compliant","tier_3_standard","tier_4_unrestricted"] | index($tier))
  and (.policy.ai_tool_steward | type == "string" and length > 0)
  and (.policy.data_policy | type == "string" and length > 0)
  and (.policy.explicit_approval_required == true)
  and (.controls | type == "object")
  and (.controls.inventory_ref | type == "string" and length > 0)
  and (.controls.data_boundary_ref | type == "string" and length > 0)
  and (.controls.confidentiality_ref | type == "string" and length > 0)
  and (.controls.prompt_injection_ref | type == "string" and length > 0)
  and (.controls.tool_allowlist_ref | type == "string" and length > 0)
  and (.controls.model_routing_ref | type == "string" and length > 0)
  and (.controls.cost_budget_ref | type == "string" and length > 0)
  and (.controls.audit_log_ref | type == "string" and length > 0)
  and (.controls.revoke_plan_ref | type == "string" and length > 0)
  and (.tools | type == "array" and length >= 1)
  and all(.tools[]; 
    (.id | type == "string" and length > 0)
    and (.name | type == "string" and length > 0)
    and (.category as $category | ["model","agent","mcp_server","plugin","connector","browser","external_tool","local_tool","ci"] | index($category))
    and (.purpose | type == "string" and length > 0)
    and (.data_classification as $dc | ["public","internal","synthetic","confidential","restricted"] | index($dc))
    and (.client_data_access | type == "boolean")
    and (.runtime_boundary as $rb | ["general_purpose","private_tenant","client_sanctioned","local_only"] | index($rb))
    and .approval_status == "approved"
    and (.approval_ref | type == "string" and length > 0)
    and (.allowlist_ref | type == "string" and length > 0)
    and (.output_gate_ref | type == "string" and length > 0)
    and (.tool_contract_ref | type == "string" and length > 0)
    and (.audit_log_ref | type == "string" and length > 0)
    and (.cost_budget_ref | type == "string" and length > 0)
    and (.rollback_ref | type == "string" and length > 0)
    and (.human_review_required == true)
    and ((.execution_stages // []) | type == "array" and length >= 1)
  )
  and (.evidence_refs | type == "array" and length >= 1)
  and (.signoff | type == "object")
  and (.signoff.required == true)
  and (.signoff.signoff_ref | type == "string" and length > 0)
' "$PROOF" >/dev/null; then
  write_report "FAIL" "ai-tool-governance.json missing required governance fields"
  exit 2
fi

client_tier="$(jq -r '.policy.client_tier' "$PROOF")"
bad_boundary_count="$(jq '[.tools[] | select((.data_classification == "confidential" or .data_classification == "restricted") and .runtime_boundary == "general_purpose")] | length' "$PROOF")"
if [ "$bad_boundary_count" -gt 0 ]; then
  details="$(jq -n --argjson count "$bad_boundary_count" '{bad_boundary_tools:$count}')"
  write_report "FAIL" "confidential or restricted data cannot use a general-purpose runtime boundary" "$details"
  exit 2
fi

case "$client_tier" in
  tier_1_regulated|tier_2_compliant)
    tier_violation_count="$(jq '[.tools[] | select(.approval_status != "approved" or .human_review_required != true or (.client_data_access == true and (.runtime_boundary != "private_tenant" and .runtime_boundary != "client_sanctioned" and .runtime_boundary != "local_only")))] | length' "$PROOF")"
    if [ "$tier_violation_count" -gt 0 ]; then
      details="$(jq -n --argjson count "$tier_violation_count" '{tier_policy_violations:$count}')"
      write_report "FAIL" "regulated/compliant AI tools need approval, human review, and a sanctioned runtime boundary for client data" "$details"
      exit 2
    fi
    ;;
esac

opus_execution_count="$(jq '[.tools[] | select((.model_tier // "") == "opus") | select(((.execution_stages // []) | map(select(["local_build","shared_dev","staging","beta","production","build","test","ship","operate","deploy"] | index(.))) | length) > 0)] | length' "$PROOF")"
if [ "$opus_execution_count" -gt 0 ]; then
  details="$(jq -n --argjson count "$opus_execution_count" '{opus_execution_tools:$count}')"
  write_report "FAIL" "Opus is planning/review only and cannot be assigned to execution stages" "$details"
  exit 2
fi

run_date="$(jq -r '.run_date' "$PROOF")"
if ! proof_epoch="$(date -u -j -f %F "$run_date" +%s 2>/dev/null)"; then
  if ! proof_epoch="$(date -u -d "$run_date" +%s 2>/dev/null)"; then
    proof_epoch=0
  fi
fi
now_epoch="$(date -u +%s)"
max_age_seconds=$((MAX_AGE_DAYS * 86400))
if [ "$proof_epoch" -le 0 ] || [ $((now_epoch - proof_epoch)) -gt "$max_age_seconds" ]; then
  details="$(jq -n --arg run_date "$run_date" --argjson max_age_days "$MAX_AGE_DAYS" '{run_date:$run_date, max_age_days:$max_age_days}')"
  write_report "FAIL" "AI tool governance proof is stale or invalid" "$details"
  exit 2
fi

refs="$(jq -r '
  [
    .controls.inventory_ref,
    .controls.data_boundary_ref,
    .controls.confidentiality_ref,
    .controls.prompt_injection_ref,
    .controls.tool_allowlist_ref,
    .controls.model_routing_ref,
    .controls.cost_budget_ref,
    .controls.audit_log_ref,
    .controls.revoke_plan_ref,
    .signoff.signoff_ref,
    (.evidence_refs[]?),
    (.tools[]? | .approval_ref, .allowlist_ref, .output_gate_ref, .tool_contract_ref, .audit_log_ref, .cost_budget_ref, .rollback_ref)
  ] | map(select(type == "string")) | unique | .[]
' "$PROOF")"

missing_refs=""
unsafe_refs=""
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    /*|*..*)
      unsafe_refs="${unsafe_refs}${ref}
"
      continue
      ;;
  esac
  if [ ! -s "$ROOT/$ref" ]; then
    missing_refs="${missing_refs}${ref}
"
  fi
done <<EOF
$refs
EOF

if [ -n "$unsafe_refs" ]; then
  details="$(printf '%s\n' "$unsafe_refs" | jq -R -s 'split("\n") | map(select(length > 0)) | {unsafe_refs:.}')"
  write_report "FAIL" "AI tool governance proof has unsafe refs" "$details"
  exit 2
fi

if [ -n "$missing_refs" ]; then
  details="$(printf '%s\n' "$missing_refs" | jq -R -s 'split("\n") | map(select(length > 0)) | {missing_or_empty_refs:.}')"
  write_report "FAIL" "AI tool governance proof refs are missing or empty" "$details"
  exit 2
fi

details="$(jq -n --arg run_date "$run_date" --argjson tool_count "$(jq '.tools | length' "$PROOF")" '{run_date:$run_date, tool_count:$tool_count}')"
write_report "PASS" "AI tool governance proof is valid" "$details"
exit 0
