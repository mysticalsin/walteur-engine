#!/usr/bin/env bash
# WALTEUR harness-state-lint - HARD gate on the typed run state when STATE.json exists.
#
# Purpose:
#   The harness loop needs a real control surface, not prose. If
#   walteur-kit/autopilot/STATE.json exists, it must be well-formed, carry the
#   enterprise loop fields, and prove gate verdicts with evidence references.
#
# Contract:
#   - STATE.json absent        => NOT_APPLICABLE, exit 0.
#   - jq absent               => SKIP, exit 0, recorded loudly.
#   - malformed state         => FAIL, exit 2.
#   - valid state             => PASS, exit 0.
#   - walteur-kit/PAUSED      => exit 2.
#
# Report:
#   walteur-kit/harness-state-report.json
#
# Bypass:
#   WALTEUR_HARNESS_STATE=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "harness-state-lint - HARD gate on the typed run state when STATE.json exists."
  printf '%s\n' "usage: bash harness-state-lint.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/harness-state-report.json - fix recipes: walteur-kit/REMEDIATION.md (## harness-state-lint)"
  printf '%s\n' "bypass: WALTEUR_HARNESS_STATE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
STATE="${WALTEUR_STATE_FILE:-$KIT/autopilot/STATE.json}"
CONTRACT="${WALTEUR_BUILD_CONTRACT_FILE:-$KIT/build-contract.json}"
REGISTRY="${WALTEUR_GATE_REGISTRY_FILE:-$KIT/gate-registry.json}"
REPORT="$KIT/harness-state-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  verdict="$1"
  reason="$2"
  findings="${3:-[]}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" --arg p "${STATE#"$ROOT"/}" \
      --arg contract "${CONTRACT#"$ROOT"/}" --arg registry "${REGISTRY#"$ROOT"/}" \
      --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"harness-state", state_file:$p, build_contract_file:$contract, gate_registry_file:$registry, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"harness-state","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
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
    echo "harness-state-lint selftest SKIP - jq not installed."
    return 0
  fi

  echo "harness-state-lint selftest:"

  write_reconcile_registry() {
    dst="$1"
    cat > "$dst" <<'JSON'
{
  "schema_version": 1,
  "registry_id": "state-reconcile-selftest",
  "gates": [
    { "id": "base-gate", "stage": "intake", "hardness": "hard", "availability": "spec", "hook": "base-gate.sh", "report": "base.json", "evidence": "base evidence" },
    { "id": "software-gate", "stage": "verify", "hardness": "hard", "availability": "spec", "hook": "software-gate.sh", "report": "software.json", "evidence": "software evidence" },
    { "id": "medium-gate", "stage": "plan", "hardness": "detect_or_skip", "availability": "spec", "hook": "medium-gate.sh", "report": "medium.json", "evidence": "medium evidence" }
  ],
  "requirements": {
    "all": ["base-gate"],
    "by_build_class": {
      "software": ["software-gate"],
      "workflow": [],
      "document": [],
      "data-ai": [],
      "cloud-iac": [],
      "mixed": []
    },
    "by_risk_tier": {
      "low": [],
      "medium": ["medium-gate"],
      "high": [],
      "regulated": []
    }
  }
}
JSON
  }

  write_reconcile_contract() {
    dst="$1"
    build_class="$2"
    risk_tier="$3"
    cat > "$dst" <<JSON
{
  "schema_version": 1,
  "contract_id": "state-reconcile",
  "build_class": "$build_class",
  "risk_tier": "$risk_tier"
}
JSON
  }

  write_reconcile_state() {
    dst="$1"
    gate_json="$2"
    cat > "$dst" <<JSON
{
  "schema_version": 1,
  "run_id": "state-reconcile",
  "goal": "ship verified harness",
  "build_class": "software",
  "risk_tier": "medium",
  "phase": "verify",
  "autonomy_policy": "full_autopilot",
  "recovery_policy": {
    "posture": "i_will_figure_it_out",
    "obstacle_trigger": "At every blocker, tool failure, missing input, contradiction, or stalled stage.",
    "paths_required": 3,
    "dimensions_required": ["what", "artefact", "assumption", "cost", "failure_mode", "validation"],
    "decision_log_path": "walteur-kit/figure-it-out.jsonl",
    "validation_required": true,
    "escalation_rule": "Escalate only after three paths are scored, one path is chosen, validation fails, and the escalation question is specific."
  },
  "context_sentinel": {
    "user_name": "Tony",
    "response_prefix": "Tony,",
    "every_response": true,
    "missing_prefix_action": "compact_and_resume",
    "compaction_target": "_relay/BATON.md",
    "baton_path": "_relay/BATON.md",
    "degradation_signal": "If a WALTEUR agent stops starting responses with Tony, treat it as context drift and compact before continuing."
  },
  "budgets": { "time_minutes": 60, "input_tokens": 1000, "output_tokens": 500, "cost_usd": 1.25 },
  "stages": [
    { "name": "verify", "status": "in_progress", "evidence_ids": ["ev-state"] }
  ],
  "gates": [$gate_json],
  "evidence": [
    { "id": "ev-state", "kind": "report", "verdict": "PASS", "path": "walteur-kit/harness-state-report.json", "summary": "state reconciliation evidence" }
  ],
  "updated_at": "2026-06-22T00:00:00Z"
}
JSON
  }

  write_recovery_log() {
    dst="$1"
    mkdir -p "$(dirname "$dst")"
    cat > "$dst" <<'JSONL'
{"decision_id":"fio-1","obstacle":"Verification tool failed during the blocked run.","paths":[{"id":"path-a","what":"Retry with the local hook after checking inputs.","artefact":"walteur-kit/harness-state-report.json","assumption":"The hook failed because the input state was incomplete.","cost":"Low, under five minutes.","failure_mode":"The retry hides a real state contract issue.","validation":"Run harness-state-lint and inspect the report."},{"id":"path-b","what":"Create a minimal poisoned twin to isolate the failure.","artefact":"walteur-kit/autopilot/STATE.json","assumption":"A smaller fixture will expose the missing field.","cost":"Medium, one focused fixture.","failure_mode":"The fixture misses the live blocker shape.","validation":"The poisoned twin must fail for the expected check."},{"id":"path-c","what":"Escalate with the exact failing state and three tried paths.","artefact":"_relay/BATON.md","assumption":"External input is needed after validated attempts fail.","cost":"Higher because it pauses the run.","failure_mode":"Escalation is vague and creates context churn.","validation":"Escalation includes the failed validation output and requested decision."}],"chosen_path_id":"path-a","reasoning":"path-a is cheapest and validates the current blocker without changing scope.","validation_test":"bash walteur-kit/hooks/harness-state-lint.sh","escalation_trigger":"Escalate only if the chosen path fails with the same blocker after validation.","ts":"2026-06-22T00:00:00Z"}
JSONL
  }

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no STATE.json -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  cat > "$tmp/walteur-kit/autopilot/STATE.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "demo",
  "goal": "ship verified harness",
  "build_class": "software",
  "risk_tier": "medium",
  "phase": "verify",
  "autonomy_policy": "full_autopilot",
  "recovery_policy": {
    "posture": "i_will_figure_it_out",
    "obstacle_trigger": "At every blocker, tool failure, missing input, contradiction, or stalled stage.",
    "paths_required": 3,
    "dimensions_required": ["what", "artefact", "assumption", "cost", "failure_mode", "validation"],
    "decision_log_path": "walteur-kit/figure-it-out.jsonl",
    "validation_required": true,
    "escalation_rule": "Escalate only after three paths are scored, one path is chosen, validation fails, and the escalation question is specific."
  },
  "context_sentinel": {
    "user_name": "Tony",
    "response_prefix": "Tony,",
    "every_response": true,
    "missing_prefix_action": "compact_and_resume",
    "compaction_target": "_relay/BATON.md",
    "baton_path": "_relay/BATON.md",
    "degradation_signal": "If a WALTEUR agent stops starting responses with Tony, treat it as context drift and compact before continuing."
  },
  "budgets": { "time_minutes": 60, "input_tokens": 1000, "output_tokens": 500, "cost_usd": 1.25 },
  "stages": [
    { "name": "plan", "status": "passed", "evidence_ids": ["ev-plan"] },
    { "name": "verify", "status": "in_progress", "evidence_ids": ["ev-test"] }
  ],
  "gates": [
    { "id": "plan-gate", "stage": "plan", "status": "PASS", "evidence_ids": ["ev-plan"] },
    { "id": "verify-gate", "stage": "verify", "status": "PASS", "evidence_ids": ["ev-test"] }
  ],
  "evidence": [
    { "id": "ev-plan", "kind": "review", "verdict": "PASS", "summary": "plan read", "owner": "reviewer", "timestamp": "2026-06-22T00:00:00Z" },
    { "id": "ev-test", "kind": "command", "verdict": "PASS", "command": "true", "path": "walteur-kit/command-output.log", "timestamp": "2026-06-22T00:00:00Z" }
  ],
  "updated_at": "2026-06-22T00:00:00Z"
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "valid STATE.json -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  state_file="$tmp/walteur-kit/autopilot/STATE.json"
  write_reconcile_state "$state_file" '{ "id": "verify-gate", "stage": "verify", "status": "PASS", "evidence_ids": ["ev-state"] }'
  jq '.evidence=[{"id":"ev-state","kind":"report","verdict":"PASS","summary":"I read the output"}]' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "summary-only PASS evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  write_reconcile_registry "$tmp/walteur-kit/gate-registry.json"
  write_reconcile_contract "$tmp/walteur-kit/build-contract.json" "software" "medium"
  write_reconcile_state "$tmp/walteur-kit/autopilot/STATE.json" '{ "id": "base-gate", "stage": "intake", "status": "PASS", "evidence_ids": ["ev-state"] }, { "id": "software-gate", "stage": "verify", "status": "PASS", "evidence_ids": ["ev-state"] }, { "id": "medium-gate", "stage": "plan", "status": "PASS", "evidence_ids": ["ev-state"] }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "state reconciles with contract and registry -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  write_reconcile_registry "$tmp/walteur-kit/gate-registry.json"
  write_reconcile_contract "$tmp/walteur-kit/build-contract.json" "workflow" "medium"
  write_reconcile_state "$tmp/walteur-kit/autopilot/STATE.json" '{ "id": "base-gate", "stage": "intake", "status": "PASS", "evidence_ids": ["ev-state"] }, { "id": "medium-gate", "stage": "plan", "status": "PASS", "evidence_ids": ["ev-state"] }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "state build_class mismatch -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  write_reconcile_registry "$tmp/walteur-kit/gate-registry.json"
  write_reconcile_contract "$tmp/walteur-kit/build-contract.json" "software" "medium"
  write_reconcile_state "$tmp/walteur-kit/autopilot/STATE.json" '{ "id": "base-gate", "stage": "intake", "status": "PASS", "evidence_ids": ["ev-state"] }, { "id": "medium-gate", "stage": "plan", "status": "PASS", "evidence_ids": ["ev-state"] }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "state missing required registry gate -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  cat > "$tmp/walteur-kit/autopilot/STATE.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "bad",
  "goal": "bad state",
  "build_class": "vibes",
  "risk_tier": "medium",
  "phase": "verify",
  "autonomy_policy": "full_autopilot",
  "budgets": { "time_minutes": 60, "input_tokens": 1000, "output_tokens": 500, "cost_usd": 1.25 },
  "stages": [{ "name": "verify", "status": "in_progress" }],
  "gates": [{ "id": "verify-gate", "stage": "verify", "status": "PASS" }],
  "evidence": [],
  "updated_at": "2026-06-22T00:00:00Z"
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "poisoned STATE.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  printf '{ bad json\n' > "$tmp/walteur-kit/autopilot/STATE.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "malformed JSON -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  cat > "$tmp/walteur-kit/autopilot/STATE.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "bad-signoff",
  "goal": "bad signoff shape",
  "build_class": "software",
  "risk_tier": "medium",
  "phase": "verify",
  "autonomy_policy": "full_autopilot",
  "budgets": { "time_minutes": 60, "input_tokens": 1000, "output_tokens": 500, "cost_usd": 1.25 },
  "stages": [{ "name": "verify", "status": "in_progress" }],
  "gates": [{ "id": "verify-gate", "stage": "verify", "status": "SKIP", "reason": "No verification gate for this state-shape twin." }],
  "evidence": [],
  "signoffs": [{ "id": "bad", "kind": "ship", "owner": "Owner", "status": "approved", "reason": "Missing timestamp" }],
  "updated_at": "2026-06-22T00:00:00Z"
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
	  ck "malformed signoff shape -> FAIL" 2 "$?"
	  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  cat > "$tmp/walteur-kit/autopilot/STATE.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "bad-authority-boundary",
  "goal": "bad authority boundary shape",
  "build_class": "software",
  "risk_tier": "medium",
  "phase": "verify",
  "autonomy_policy": "full_autopilot",
  "budgets": { "time_minutes": 60, "input_tokens": 1000, "output_tokens": 500, "cost_usd": 1.25 },
  "stages": [{ "name": "verify", "status": "in_progress" }],
  "gates": [{ "id": "verify-gate", "stage": "verify", "status": "SKIP", "reason": "No verification gate for this state-shape twin." }],
  "evidence": [],
  "authority_boundaries": [{ "id": "pay", "kind": "money", "description": "Missing owner" }],
  "updated_at": "2026-06-22T00:00:00Z"
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "malformed authority boundary shape -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  cat > "$tmp/walteur-kit/autopilot/STATE.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "bad-recovery-policy",
  "goal": "bad recovery policy shape",
  "build_class": "software",
  "risk_tier": "medium",
  "phase": "verify",
  "autonomy_policy": "full_autopilot",
  "recovery_policy": {
    "posture": "ask_tony_first",
    "obstacle_trigger": "Only when totally blocked.",
    "paths_required": 2,
    "dimensions_required": ["what", "artefact"],
    "decision_log_path": "walteur-kit/figure-it-out.jsonl",
    "validation_required": false,
    "escalation_rule": "Ask Tony."
  },
  "context_sentinel": {
    "user_name": "Tony",
    "response_prefix": "Tony,",
    "every_response": true,
    "missing_prefix_action": "compact_and_resume",
    "compaction_target": "_relay/BATON.md",
    "baton_path": "_relay/BATON.md"
  },
  "budgets": { "time_minutes": 60, "input_tokens": 1000, "output_tokens": 500, "cost_usd": 1.25 },
  "stages": [{ "name": "verify", "status": "in_progress" }],
  "gates": [{ "id": "verify-gate", "stage": "verify", "status": "SKIP", "reason": "No verification gate for this recovery-policy twin." }],
  "evidence": [],
  "updated_at": "2026-06-22T00:00:00Z"
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "malformed recovery policy -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  cat > "$tmp/walteur-kit/autopilot/STATE.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "bad-context-sentinel",
  "goal": "bad context sentinel shape",
  "build_class": "software",
  "risk_tier": "medium",
  "phase": "verify",
  "autonomy_policy": "full_autopilot",
  "recovery_policy": {
    "posture": "i_will_figure_it_out",
    "obstacle_trigger": "At every blocker, tool failure, missing input, contradiction, or stalled stage.",
    "paths_required": 3,
    "dimensions_required": ["what", "artefact", "assumption", "cost", "failure_mode", "validation"],
    "decision_log_path": "walteur-kit/figure-it-out.jsonl",
    "validation_required": true,
    "escalation_rule": "Escalate only after three paths are scored, one path is chosen, validation fails, and the escalation question is specific."
  },
  "context_sentinel": {
    "user_name": "Tony",
    "response_prefix": "Hello",
    "every_response": false,
    "missing_prefix_action": "ignore",
    "compaction_target": "",
    "baton_path": ""
  },
  "budgets": { "time_minutes": 60, "input_tokens": 1000, "output_tokens": 500, "cost_usd": 1.25 },
  "stages": [{ "name": "verify", "status": "in_progress" }],
  "gates": [{ "id": "verify-gate", "stage": "verify", "status": "SKIP", "reason": "No verification gate for this context-sentinel twin." }],
  "evidence": [],
  "updated_at": "2026-06-22T00:00:00Z"
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "malformed context sentinel -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  state_file="$tmp/walteur-kit/autopilot/STATE.json"
  write_reconcile_state "$state_file" '{ "id": "blocked-gate", "stage": "verify", "status": "BLOCKED", "reason": "Verification tool unavailable.", "recovery_decision_id": "fio-1" }'
  jq '.blockers=[{"blocker":"Verification tool unavailable.","next_action":"Retry after validating state inputs.","recovery_decision_id":"fio-1"}]' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  write_recovery_log "$tmp/walteur-kit/figure-it-out.jsonl"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "blocked state with recovery decision -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  state_file="$tmp/walteur-kit/autopilot/STATE.json"
  write_reconcile_state "$state_file" '{ "id": "verify-gate", "stage": "verify", "status": "PASS", "evidence_ids": ["ev-state"] }'
  jq '.blockers=[{"blocker":"Missing API key.","next_action":"Check local env."}]' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "blocker without recovery decision -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  state_file="$tmp/walteur-kit/autopilot/STATE.json"
  write_reconcile_state "$state_file" '{ "id": "blocked-gate", "stage": "verify", "status": "BLOCKED", "reason": "Verification tool unavailable." }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "blocked gate without recovery decision -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  state_file="$tmp/walteur-kit/autopilot/STATE.json"
  write_reconcile_state "$state_file" '{ "id": "verify-gate", "stage": "verify", "status": "PASS", "evidence_ids": ["ev-state"] }'
  jq '.phase="stopped" | .stages=[{"name":"verify","status":"blocked","evidence_ids":["ev-state"]}]' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "blocked stage without recovery decision -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  state_file="$tmp/walteur-kit/autopilot/STATE.json"
  write_reconcile_state "$state_file" '{ "id": "verify-gate", "stage": "verify", "status": "PASS", "evidence_ids": ["ev-state"] }'
  jq '.blockers=[{"blocker":"Missing dependency.","next_action":"Use the local cache or install path.","recovery_decision_id":"fio-1"}]' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "recovery decision log missing -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  state_file="$tmp/walteur-kit/autopilot/STATE.json"
  write_reconcile_state "$state_file" '{ "id": "verify-gate", "stage": "verify", "status": "PASS", "evidence_ids": ["ev-state"] }'
  jq '.blockers=[{"blocker":"Missing dependency.","next_action":"Use the local cache or install path.","recovery_decision_id":"fio-1"}]' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  cat > "$tmp/walteur-kit/figure-it-out.jsonl" <<'JSONL'
{"decision_id":"fio-1","obstacle":"Missing dependency.","paths":[{"id":"path-a","what":"Retry","artefact":"report","assumption":"cache exists","cost":"low","failure_mode":"same failure","validation":"run lint"},{"id":"path-b","what":"Escalate","artefact":"baton","assumption":"input required","cost":"medium","failure_mode":"vague ask","validation":"specific ask"}],"chosen_path_id":"path-a","reasoning":"Try the cheapest local path.","validation_test":"bash walteur-kit/hooks/harness-state-lint.sh","escalation_trigger":"Escalate if validation fails.","ts":"2026-06-22T00:00:00Z"}
JSONL
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "recovery decision log with fewer than three paths -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-state-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  cat > "$tmp/walteur-kit/autopilot/STATE.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "extra-fields",
  "goal": "reject schema drift",
  "build_class": "software",
  "risk_tier": "medium",
  "phase": "verify",
  "autonomy_policy": "full_autopilot",
  "recovery_policy": {
    "posture": "i_will_figure_it_out",
    "obstacle_trigger": "At every blocker, tool failure, missing input, contradiction, or stalled stage.",
    "paths_required": 3,
    "dimensions_required": ["what", "artefact", "assumption", "cost", "failure_mode", "validation"],
    "decision_log_path": "walteur-kit/figure-it-out.jsonl",
    "validation_required": true,
    "escalation_rule": "Escalate only after three paths are scored, one path is chosen, validation fails, and the escalation question is specific.",
    "extra": "not in schema"
  },
  "context_sentinel": {
    "user_name": "Tony",
    "response_prefix": "Tony,",
    "every_response": true,
    "missing_prefix_action": "compact_and_resume",
    "compaction_target": "_relay/BATON.md",
    "baton_path": "_relay/BATON.md",
    "degradation_signal": "If a WALTEUR agent stops starting responses with Tony, treat it as context drift and compact before continuing.",
    "extra": "not in schema"
  },
  "budgets": { "time_minutes": 60, "input_tokens": 1000, "output_tokens": 500, "cost_usd": 1.25, "extra": 1 },
  "protected_paths": [{ "path": "prod.env", "reason": "do not overwrite", "extra": "not in schema" }],
  "stages": [{ "name": "verify", "status": "in_progress", "evidence_ids": ["ev-state"], "extra": "not in schema" }],
  "gates": [{ "id": "verify-gate", "stage": "verify", "status": "PASS", "evidence_ids": ["ev-state"], "extra": "not in schema" }],
  "evidence": [{ "id": "ev-state", "kind": "report", "verdict": "PASS", "summary": "state evidence", "extra": "not in schema" }],
  "decisions": [{ "decision": "Keep strict state", "why": "Avoid drift", "extra": "not in schema" }],
  "signoffs": [{ "id": "ship-ok", "kind": "ship", "owner": "Owner", "status": "approved", "reason": "Approved", "timestamp": "2026-06-22T00:00:00Z", "extra": "not in schema" }],
  "authority_boundaries": [{ "id": "email", "kind": "external", "description": "Send customer email", "owner": "Owner", "extra": "not in schema" }],
  "blockers": [{ "blocker": "None", "next_action": "Proceed", "extra": "not in schema" }],
  "known_gaps": [{ "gap": "None", "severity": "low", "extra": "not in schema" }],
  "next_action": "ship",
  "baton_path": "walteur-kit/autopilot/STATE.json",
  "updated_at": "2026-06-22T00:00:00Z",
  "extra_root": "not in schema"
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "extra root and nested fields -> FAIL" 2 "$?"
  rm -rf "$tmp"

	  echo "harness-state-lint selftest: $pass/$((pass+fail)) passed"
	  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_HARNESS_STATE:-on}" = "off" ] && {
  echo "harness-state-lint: bypassed (WALTEUR_HARNESS_STATE=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_HARNESS_STATE=off" "[]"
  exit 0
}

if [ ! -f "$STATE" ]; then
  echo "harness-state-lint: no STATE.json found at ${STATE#"$ROOT"/} - gate not applicable." >&2
  write_report "NOT_APPLICABLE" "STATE.json absent" "[]"
  exit 0
fi

if ! have jq; then
  echo "harness-state-lint SKIP - jq not installed (recorded, not silent-green)." >&2
  write_report "SKIP" "jq not installed" "[]"
  exit 0
fi

if ! jq empty "$STATE" >/dev/null 2>&1; then
  findings='[{"check":"json","message":"STATE.json is not valid JSON"}]'
  write_report "FAIL" "STATE.json is not valid JSON" "$findings"
  echo "harness-state-lint verdict: FAIL - STATE.json is not valid JSON -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

for key in schema_version run_id goal build_class risk_tier phase autonomy_policy recovery_policy context_sentinel budgets stages gates evidence updated_at; do
  if ! jq -e --arg k "$key" 'has($k)' "$STATE" >/dev/null; then
    add_finding "required.$key" "missing required key: $key"
  fi
done

check_enum() {
  key="$1"; allowed="$2"
  value="$(jq -r --arg k "$key" '.[$k] // empty' "$STATE")"
  [ -n "$value" ] || return 0
  if ! printf '%s\n' "$allowed" | grep -qxF "$value"; then
    add_finding "enum.$key" "$key has invalid value '$value'"
  fi
}

check_enum "build_class" "software
workflow
document
data-ai
cloud-iac
mixed"
check_enum "risk_tier" "low
medium
high
regulated"
check_enum "phase" "intake
discover
plan
build
verify
review
ship
reflect
stopped"
check_enum "autonomy_policy" "full_autopilot
pause_at_plan_and_audit
pause_at_review
pause_per_task"

if ! jq -e '.budgets | type=="object" and (.time_minutes|type=="number") and (.input_tokens|type=="number") and (.output_tokens|type=="number") and (.cost_usd|type=="number")' "$STATE" >/dev/null 2>&1; then
  add_finding "budgets.shape" "budgets must include numeric time_minutes, input_tokens, output_tokens, and cost_usd"
fi

if ! jq -e '
  .recovery_policy
  | type=="object"
    and .posture=="i_will_figure_it_out"
    and .paths_required==3
    and .validation_required==true
    and ((.obstacle_trigger // "") | length > 0)
    and ((.decision_log_path // "") | length > 0)
    and ((.escalation_rule // "") | length > 0)
    and ((["what","artefact","assumption","cost","failure_mode","validation"] - (.dimensions_required // [])) | length == 0)
' "$STATE" >/dev/null 2>&1; then
  add_finding "recovery_policy.shape" "recovery_policy must enforce i_will_figure_it_out, exactly three paths, six decision dimensions, validation, log path, and escalation rule"
fi

if ! jq -e '
  .context_sentinel
  | type=="object"
    and .user_name=="Tony"
    and .response_prefix=="Tony,"
    and .every_response==true
    and .missing_prefix_action=="compact_and_resume"
    and ((.compaction_target // "") | length > 0)
    and ((.baton_path // "") | length > 0)
' "$STATE" >/dev/null 2>&1; then
  add_finding "context_sentinel.shape" "context_sentinel must require every response to start with Tony, and compact/resume through a baton when the prefix is missing"
fi

if ! jq -e '.stages | type=="array" and length>0' "$STATE" >/dev/null 2>&1; then
  add_finding "stages.shape" "stages must be a non-empty array"
fi
if ! jq -e '.gates | type=="array"' "$STATE" >/dev/null 2>&1; then
  add_finding "gates.shape" "gates must be an array"
fi
if ! jq -e '.evidence | type=="array"' "$STATE" >/dev/null 2>&1; then
  add_finding "evidence.shape" "evidence must be an array"
fi
if ! jq -e '(.signoffs // []) | type=="array"' "$STATE" >/dev/null 2>&1; then
  add_finding "signoffs.shape" "signoffs must be an array when present"
fi
if ! jq -e '(.authority_boundaries // []) | type=="array"' "$STATE" >/dev/null 2>&1; then
  add_finding "authority_boundaries.shape" "authority_boundaries must be an array when present"
fi

extra_fields="$(jq -r '
  def extra_keys($obj; $allowed; $prefix):
    if ($obj | type) == "object" then
      $obj
      | keys_unsorted[] as $key
      | select(($allowed | index($key)) | not)
      | if $prefix == "" then $key else ($prefix + "." + $key) end
    else empty end;

  extra_keys(.; ["schema_version","run_id","goal","owner","build_class","risk_tier","phase","autonomy_policy","recovery_policy","context_sentinel","budgets","protected_paths","stages","gates","evidence","decisions","signoffs","authority_boundaries","blockers","known_gaps","next_action","baton_path","updated_at"]; ""),
  extra_keys((.recovery_policy // {}); ["posture","obstacle_trigger","paths_required","dimensions_required","decision_log_path","validation_required","escalation_rule"]; "recovery_policy"),
  extra_keys((.context_sentinel // {}); ["user_name","response_prefix","every_response","missing_prefix_action","compaction_target","baton_path","degradation_signal"]; "context_sentinel"),
  extra_keys((.budgets // {}); ["time_minutes","input_tokens","output_tokens","cost_usd"]; "budgets"),
  (if (.protected_paths | type) == "array" then
    (.protected_paths | to_entries[] | extra_keys(.value; ["path","reason"]; ("protected_paths[" + (.key|tostring) + "]")))
  else empty end),
  (if (.stages | type) == "array" then
    (.stages | to_entries[] | extra_keys(.value; ["name","status","owner","started_at","completed_at","evidence_ids","recovery_decision_id","notes"]; ("stages[" + (.key|tostring) + "]")))
  else empty end),
  (if (.gates | type) == "array" then
    (.gates | to_entries[] | extra_keys(.value; ["id","stage","status","evidence_ids","reason","recovery_decision_id","owner","timestamp"]; ("gates[" + (.key|tostring) + "]")))
  else empty end),
  (if (.evidence | type) == "array" then
    (.evidence | to_entries[] | extra_keys(.value; ["id","kind","verdict","command","path","summary","owner","timestamp"]; ("evidence[" + (.key|tostring) + "]")))
  else empty end),
  (if (.decisions | type) == "array" then
    (.decisions | to_entries[] | extra_keys(.value; ["decision","why","rejected","owner","timestamp"]; ("decisions[" + (.key|tostring) + "]")))
  else empty end),
  (if (.signoffs | type) == "array" then
    (.signoffs | to_entries[] | extra_keys(.value; ["id","kind","owner","status","reason","covers","evidence_ids","timestamp"]; ("signoffs[" + (.key|tostring) + "]")))
  else empty end),
  (if (.authority_boundaries | type) == "array" then
    (.authority_boundaries | to_entries[] | extra_keys(.value; ["id","kind","description","owner","requires_signoff","status"]; ("authority_boundaries[" + (.key|tostring) + "]")))
  else empty end),
  (if (.blockers | type) == "array" then
    (.blockers | to_entries[] | extra_keys(.value; ["blocker","next_action","recovery_decision_id","owner","deadline"]; ("blockers[" + (.key|tostring) + "]")))
  else empty end),
  (if (.known_gaps | type) == "array" then
    (.known_gaps | to_entries[] | extra_keys(.value; ["gap","severity","owner","accepted_reason"]; ("known_gaps[" + (.key|tostring) + "]")))
  else empty end)
' "$STATE" 2>/dev/null | paste -sd ',' - | sed 's/,/, /g')"
[ -n "$extra_fields" ] && add_finding "additional_properties" "unknown fields are not allowed: $extra_fields"

bad_stages="$(jq -r '
  def valid_name: ["intake","discover","plan","build","verify","review","ship","reflect"] | index(.);
  def valid_status: ["not_started","in_progress","passed","failed","skipped","blocked"] | index(.);
  (.stages // [])[]
  | select((.name as $n | ["intake","discover","plan","build","verify","review","ship","reflect"] | index($n) | not)
      or (.status as $s | ["not_started","in_progress","passed","failed","skipped","blocked"] | index($s) | not))
  | "\(.name // "<missing>"):\(.status // "<missing>")"
' "$STATE" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_stages" ] && add_finding "stages.enums" "invalid stage name/status: $bad_stages"

bad_gates="$(jq -r '
  (.gates // [])[]
  | select((.stage as $s | ["intake","discover","plan","build","verify","review","ship","reflect"] | index($s) | not)
      or (.status as $v | ["PASS","FAIL","SKIP","BLOCKED","ACCEPTED_RISK"] | index($v) | not))
  | "\(.id // "<missing>"):\(.stage // "<missing>"):\(.status // "<missing>")"
' "$STATE" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_gates" ] && add_finding "gates.enums" "invalid gate stage/status: $bad_gates"

bad_evidence="$(jq -r '
  (.evidence // [])[]
  | select((.kind as $k | ["command","report","screenshot","review","audit","decision","source","manual_check"] | index($k) | not)
      or (.verdict as $v | ["PASS","FAIL","SKIP","NOT_FOUND","ACCEPTED_RISK"] | index($v) | not))
  | "\(.id // "<missing>"):\(.kind // "<missing>"):\(.verdict // "<missing>")"
' "$STATE" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_evidence" ] && add_finding "evidence.enums" "invalid evidence kind/verdict: $bad_evidence"

summary_only_pass_evidence="$(jq -r '
  (.evidence // [])[]
  | select(.verdict=="PASS")
  | (.kind // "") as $kind
  | (((.path // "") | length) > 0) as $has_path
  | (((.command // "") | length) > 0) as $has_command
  | (((.summary // "") | length) > 0) as $has_summary
  | (((.owner // "") | length) > 0) as $has_owner
  | (((.timestamp // "") | length) > 0) as $has_timestamp
  | (
      (((["report","audit","screenshot","source"] | index($kind)) != null) and $has_path)
      or ($kind == "command" and $has_command and $has_path and $has_timestamp)
      or (((["review","decision","manual_check"] | index($kind)) != null) and ($has_path or ($has_owner and $has_timestamp and $has_summary)))
    ) as $proof_ok
  | select($proof_ok | not)
  | .id
' "$STATE" 2>/dev/null | paste -sd ', ' -)"
[ -n "$summary_only_pass_evidence" ] && add_finding "evidence.replayable" "PASS evidence must be replayable or signed, not summary-only: $summary_only_pass_evidence"

bad_signoffs="$(jq -r '
  (.signoffs // [])[]
  | select(
      ((.id // "") | length) == 0
      or (.kind as $k | ["ship","high_risk","regulated","accepted_risk","scope_change","external","production","data","money","contract","irreversible","confidential_data"] | index($k) | not)
      or (.status as $s | ["approved","rejected","pending"] | index($s) | not)
      or ((.owner // "") | length) == 0
      or ((.reason // "") | length) == 0
      or ((.timestamp // "") | length) == 0
    )
  | "\(.id // "<missing>"):\(.kind // "<missing>"):\(.status // "<missing>")"
' "$STATE" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_signoffs" ] && add_finding "signoffs.enums" "invalid signoff entries: $bad_signoffs"

bad_authority_boundaries="$(jq -r '
  (.authority_boundaries // [])[]
  | select(
      ((.id // "") | length) == 0
      or (.kind as $k | ["external","money","contract","production","irreversible","confidential_data","data"] | index($k) | not)
      or ((.description // "") | length) == 0
      or ((.owner // "") | length) == 0
      or ((has("requires_signoff") and (.requires_signoff | type != "boolean")))
      or ((has("status") and (.status as $s | ["active","not_applicable","accepted_risk","closed"] | index($s) | not)))
    )
  | "\(.id // "<missing>"):\(.kind // "<missing>")"
' "$STATE" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_authority_boundaries" ] && add_finding "authority_boundaries.enums" "invalid authority boundary entries: $bad_authority_boundaries"

pass_without_evidence="$(jq -r '
  (.gates // [])[]
  | select(.status=="PASS" and ((.evidence_ids // []) | length == 0))
  | .id
' "$STATE" 2>/dev/null | paste -sd ', ' -)"
[ -n "$pass_without_evidence" ] && add_finding "gates.pass_evidence" "PASS gates must reference evidence_ids: $pass_without_evidence"

status_without_reason="$(jq -r '
  (.gates // [])[]
  | select((.status=="SKIP" or .status=="BLOCKED" or .status=="ACCEPTED_RISK") and ((.reason // "") | length == 0))
  | .id
' "$STATE" 2>/dev/null | paste -sd ', ' -)"
[ -n "$status_without_reason" ] && add_finding "gates.reason" "SKIP/BLOCKED/ACCEPTED_RISK gates must include reason: $status_without_reason"

blocked_without_recovery="$(jq -r '
  [
    ((.stages // []) | to_entries[]? | select(.value.status=="blocked" and ((.value.recovery_decision_id // "") | length == 0)) | "stage:" + (.value.name // ("#" + (.key|tostring)))),
    ((.gates // []) | to_entries[]? | select(.value.status=="BLOCKED" and ((.value.recovery_decision_id // "") | length == 0)) | "gate:" + (.value.id // ("#" + (.key|tostring)))),
    ((.blockers // []) | to_entries[]? | select(((.value.recovery_decision_id // "") | length == 0)) | "blocker:" + (.value.blocker // ("#" + (.key|tostring))))
  ]
  | .[]
' "$STATE" 2>/dev/null | paste -sd ', ' -)"
[ -n "$blocked_without_recovery" ] && add_finding "recovery.refs" "blocked stages, BLOCKED gates, and blockers must reference recovery_decision_id: $blocked_without_recovery"

blocked_decision_ids="$(jq -r '
  [
    ((.stages // [])[]? | select(.status=="blocked") | .recovery_decision_id? // empty),
    ((.gates // [])[]? | select(.status=="BLOCKED") | .recovery_decision_id? // empty),
    ((.blockers // [])[]? | .recovery_decision_id? // empty)
  ]
  | unique
  | .[]
' "$STATE" 2>/dev/null)"
if [ -n "$blocked_decision_ids" ]; then
  decision_log_path="$(jq -r '.recovery_policy.decision_log_path // empty' "$STATE" 2>/dev/null)"
  case "$decision_log_path" in
    /*) decision_log="$decision_log_path" ;;
    *) decision_log="$ROOT/$decision_log_path" ;;
  esac

  if [ ! -f "$decision_log" ]; then
    add_finding "recovery.log_present" "blocked work references recovery decisions, but decision log is missing: $decision_log_path"
  elif ! jq -s empty "$decision_log" >/dev/null 2>&1; then
    add_finding "recovery.log_jsonl" "recovery decision log must be valid JSONL: $decision_log_path"
  else
    while IFS= read -r decision_id; do
      [ -n "$decision_id" ] || continue
      if ! jq -s -e --arg id "$decision_id" '
        def nonempty_string: type=="string" and length > 0;
        map(select(.decision_id == $id)) as $matches
        | (($matches | length) == 1)
          and (
            $matches[0] as $d
            | (($d.obstacle // "") | nonempty_string)
              and (($d.paths // []) | type=="array" and length==3)
              and all(($d.paths // [])[]; ((.id // "") | nonempty_string)
                and ((.what // "") | nonempty_string)
                and ((.artefact // "") | nonempty_string)
                and ((.assumption // "") | nonempty_string)
                and ((.cost // "") | nonempty_string)
                and ((.failure_mode // "") | nonempty_string)
                and ((.validation // "") | nonempty_string))
              and (($d.chosen_path_id // "") | nonempty_string)
              and (([$d.paths[]?.id] | index($d.chosen_path_id)) != null)
              and (($d.reasoning // "") | nonempty_string)
              and (($d.validation_test // "") | nonempty_string)
              and (($d.escalation_trigger // "") | nonempty_string)
              and (($d.ts // "") | nonempty_string)
          )
      ' "$decision_log" >/dev/null 2>&1; then
        add_finding "recovery.decision.$decision_id" "recovery decision '$decision_id' must exist once and include obstacle, exactly three complete paths, chosen path, reasoning, validation_test, escalation_trigger, and ts"
      fi
    done <<EOF
$blocked_decision_ids
EOF
  fi
fi

unresolved_evidence="$(jq -r '
  [(.evidence // [])[].id] as $ids
  | [
      ((.gates // [])[]? | (.evidence_ids // [])[]?),
      ((.stages // [])[]? | (.evidence_ids // [])[]?)
    ]
  | unique
  | map(select(($ids | index(.)) | not))
  | .[]
' "$STATE" 2>/dev/null | paste -sd ', ' -)"
[ -n "$unresolved_evidence" ] && add_finding "evidence.refs" "evidence_ids referenced but not defined in evidence[]: $unresolved_evidence"

thin_evidence="$(jq -r '
  (.evidence // [])[]
  | select((.path // "" | length)==0 and (.command // "" | length)==0 and (.summary // "" | length)==0)
  | .id
' "$STATE" 2>/dev/null | paste -sd ', ' -)"
[ -n "$thin_evidence" ] && add_finding "evidence.thin" "each evidence item needs path, command, or summary: $thin_evidence"

current_phase="$(jq -r '.phase // empty' "$STATE")"
if [ "$current_phase" != "stopped" ] && [ -n "$current_phase" ]; then
  if ! jq -e --arg p "$current_phase" '(.stages // []) | any(.name==$p and (.status=="in_progress" or .status=="passed"))' "$STATE" >/dev/null 2>&1; then
    add_finding "phase.stage" "current phase '$current_phase' must have an in_progress or passed stage entry"
  fi
fi

if [ -f "$CONTRACT" ]; then
  if ! jq empty "$CONTRACT" >/dev/null 2>&1; then
    add_finding "contract.json" "build-contract.json is not valid JSON, so state cannot be reconciled"
  else
    contract_class="$(jq -r '.build_class // empty' "$CONTRACT")"
    contract_risk="$(jq -r '.risk_tier // empty' "$CONTRACT")"
    state_class="$(jq -r '.build_class // empty' "$STATE")"
    state_risk="$(jq -r '.risk_tier // empty' "$STATE")"

    if [ -n "$contract_class" ] && [ -n "$state_class" ] && [ "$contract_class" != "$state_class" ]; then
      add_finding "contract.build_class" "STATE build_class '$state_class' does not match build-contract '$contract_class'"
    fi
    if [ -n "$contract_risk" ] && [ -n "$state_risk" ] && [ "$contract_risk" != "$state_risk" ]; then
      add_finding "contract.risk_tier" "STATE risk_tier '$state_risk' does not match build-contract '$contract_risk'"
    fi

    if [ -f "$REGISTRY" ]; then
      if ! jq empty "$REGISTRY" >/dev/null 2>&1; then
        add_finding "registry.json" "gate-registry.json is not valid JSON, so required runtime gates cannot be checked"
      else
        declared_state_gates="$(jq -r '.gates[]?.id // empty' "$STATE" 2>/dev/null | sort -u)"
        while IFS= read -r req; do
          [ -n "$req" ] || continue
          if ! printf '%s\n' "$declared_state_gates" | grep -qxF "$req"; then
            add_finding "registry.required_gate.$req" "STATE is missing required gate '$req' for class '$contract_class' and risk '$contract_risk'"
          fi
        done <<EOF
$(jq -r --arg c "$contract_class" --arg r "$contract_risk" '((.requirements.all // []) + (.requirements.by_build_class[$c] // []) + (.requirements.by_risk_tier[$r] // [])) | unique[]' "$REGISTRY" 2>/dev/null)
EOF
      fi
    else
      add_finding "registry.present" "build-contract.json exists but gate-registry.json is missing, so required runtime gates cannot be checked"
    fi
  fi
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "$failures harness state finding(s)" "$findings"
  echo "harness-state-lint verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' >&2
  exit 2
fi

write_report "PASS" "STATE.json satisfies harness state contract" "[]"
echo "harness-state-lint verdict: PASS -> $REPORT" >&2
exit 0
