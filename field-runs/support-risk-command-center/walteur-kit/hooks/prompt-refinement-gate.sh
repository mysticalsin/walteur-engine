#!/usr/bin/env bash
# WALTEUR prompt-refinement-gate - Improve-this-prompt before planning/building.
#
# Contract:
#   - No prompt-refinement.json before plan               => NOT_APPLICABLE, exit 0.
#   - Empty runtime stub before plan                      => NOT_APPLICABLE, exit 0.
#   - Plan/build/verify/review/ship/reflect without proof => FAIL, exit 2.
#   - Weak refined prompt, vague brief, missing routing,
#     thin acceptance criteria, or placeholder text        => FAIL, exit 2.
#   - Complete prompt refinement proof                     => PASS, exit 0.
#
# Report:
#   walteur-kit/prompt-refinement-report.json
#
# Bypass:
#   WALTEUR_PROMPT_REFINEMENT=off
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
PROMPT="$KIT/prompt-refinement.json"
STATE="$KIT/autopilot/STATE.json"
CONTRACT="$KIT/build-contract.json"
REPORT="$KIT/prompt-refinement-report.json"
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
      --arg prompt "${PROMPT#"$ROOT"/}" --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"prompt-refinement-gate", mode:$mode, prompt_file:$prompt, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"prompt-refinement-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0\n'
}

detect_required() {
  PROMPT_REQUIRED=0
  PROMPT_REQUIRED_REASON=""

  if [ "${WALTEUR_PROMPT_REFINEMENT_REQUIRED:-}" = "1" ]; then
    PROMPT_REQUIRED=1
    PROMPT_REQUIRED_REASON="WALTEUR_PROMPT_REFINEMENT_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      plan|build|verify|review|ship|reflect)
        PROMPT_REQUIRED=1
        PROMPT_REQUIRED_REASON="STATE.phase=$phase"
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
      "$REPORT"|"$PROMPT") return 0 ;;
    esac
    mt="$(mtime "$f")"
    [ "${mt:-0}" -gt "$latest" ] && latest="$mt"
  }

  for f in "$CONTRACT" "$STATE" "$ROOT/AGENTS.md" "$ROOT/README.md" "$ROOT/PLAN.md" "$KIT/PRD.md"; do
    update_latest "$f"
  done

  printf '%s\n' "$latest"
}

word_count() {
  printf '%s' "$1" | wc -w | tr -d ' '
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
    echo "prompt-refinement-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    root="$1"
    phase="$2"
    mkdir -p "$root/walteur-kit/autopilot"
    jq -n --arg phase "$phase" '{
      schema_version: 1,
      run_id: "prompt-selftest",
      goal: "Build a workflow dashboard",
      owner: "Operator",
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
      next_action: "prompt",
      baton_path: "walteur-kit/autopilot/STATE.json",
      updated_at: "2026-06-22T00:00:00Z"
    }' > "$root/walteur-kit/autopilot/STATE.json"
  }

  write_contract() {
    root="$1"
    mkdir -p "$root/walteur-kit"
    jq -n '{
      schema_version: 1,
      contract_id: "prompt-contract",
      request: {
        summary: "Build a verified workflow dashboard",
        user_outcome: "Operators see workload, blockers, and stale items without spreadsheets.",
        primary_user: "Operator",
        non_goals: ["No billing"]
      },
      build_class: "software",
      risk_tier: "medium",
      data_classification: "internal",
      success_metrics: [{name:"Core flow", target:"Completes", check:"Run test"}],
      constraints: [],
      interfaces: [{name:"Dashboard", type:"ui", owner:"Operator", contract:"Workflow dashboard"}],
      verification: {gates: [], commands: [], manual_checks: []},
      evidence_required: ["test output"],
      unknowns: [],
      created_at: "2026-06-22T00:00:00Z"
    }' > "$root/walteur-kit/build-contract.json"
  }

  write_good_prompt() {
    root="$1"
    mkdir -p "$root/walteur-kit"
    jq -n '{
      schema_version: 1,
      verdict: "PASS",
      raw_request: "Build me a workflow dashboard.",
      improved_prompt: "Build a production-ready workflow dashboard for operations leads. Start by locking the outcome, user, non-goals, success metrics, acceptance criteria, data boundaries, and verification plan. Then produce the smallest complete full-stack slice with frontend states, backend/API contract, persistence assumptions, security checks, QA evidence, release notes, rollback path, and independent outcome evaluation.",
      build_brief: {
        outcome: "Operations leads can see current workload, blocked items, and stale cases without manual spreadsheet work.",
        primary_user: "Operations lead",
        success_metrics: [
          {name:"Freshness", target:"Data is no older than 15 minutes", check:"Read freshness report"},
          {name:"Core flow", target:"Lead can filter and open a case", check:"Run E2E test"}
        ],
        non_goals: ["No billing", "No replacement of source ticketing system"],
        acceptance_criteria: [
          {id:"AC1", criterion:"Dashboard shows workload by status.", verification:"Run UI test and inspect screenshot."},
          {id:"AC2", criterion:"Blocked items are visible and sortable.", verification:"Run E2E blocked-item scenario."},
          {id:"AC3", criterion:"Errors and empty states are handled.", verification:"Run resilience checks."}
        ],
        constraints: ["No PII in screenshots", "All claims require evidence"],
        delivery_mode: "software"
      },
      routing: {
        build_class: "software",
        risk_tier: "medium",
        data_classification: "internal",
        requires_ui: true,
        requires_backend: true,
        requires_external_actions: false
      },
      specialist_plan: [
        {role:"product", reason:"Translate raw ask into outcome and acceptance criteria.", output:"PRD slice"},
        {role:"frontend", reason:"Build dashboard UI states.", output:"UI implementation"},
        {role:"backend", reason:"Build API and data contract.", output:"API implementation"},
        {role:"qa", reason:"Verify acceptance criteria.", output:"QA report"},
        {role:"security", reason:"Review data exposure and auth boundaries.", output:"Security verdict"}
      ],
      verification_plan: [
        {gate:"delivery-orchestration-gate", evidence:"Agent roster and SDLC proof", command_or_check:"bash walteur-kit/hooks/delivery-orchestration-gate.sh"},
        {gate:"qa-contract-gate", evidence:"QA report", command_or_check:"bash walteur-kit/hooks/qa-contract-gate.sh"},
        {gate:"outcome-eval-gate", evidence:"Independent outcome evaluation", command_or_check:"bash walteur-kit/hooks/outcome-eval-gate.sh"}
      ],
      quality_bar: {
        standard:"Enterprise-grade, complete, verified, secure, accessible, observable, and maintainable.",
        must_haves:["Frontend states", "Backend/API contract", "QA evidence", "Security review"],
        stop_conditions:["Missing acceptance criteria", "Unverified outcome", "Open blocker without owner"]
      },
      open_questions: [
        {question:"Which ticket fields are safe to display?", owner:"Operator", blocking:false}
      ],
      source_refs:["walteur-kit/build-contract.json"],
      ts:"2026-06-22T00:00:00Z"
    }' > "$root/walteur-kit/prompt-refinement.json"
  }

  echo "prompt-refinement-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/prompt-refinement-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no report before plan -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/prompt-refinement-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing report in plan -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/prompt-refinement-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  : > "$tmp/walteur-kit/prompt-refinement.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "empty stub before plan -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/prompt-refinement-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  : > "$tmp/walteur-kit/prompt-refinement.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "empty report in plan -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/prompt-refinement-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_good_prompt "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "good prompt refinement -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/prompt-refinement-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_good_prompt "$tmp"
  jq '.improved_prompt = "Build dashboard."' "$tmp/walteur-kit/prompt-refinement.json" > "$tmp/p.json" && mv "$tmp/p.json" "$tmp/walteur-kit/prompt-refinement.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "thin improved prompt -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/prompt-refinement-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_good_prompt "$tmp"
  jq '.build_brief.acceptance_criteria = [.build_brief.acceptance_criteria[0]]' "$tmp/walteur-kit/prompt-refinement.json" > "$tmp/p.json" && mv "$tmp/p.json" "$tmp/walteur-kit/prompt-refinement.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "too few acceptance criteria -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/prompt-refinement-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_good_prompt "$tmp"
  jq '.routing.requires_ui = false' "$tmp/walteur-kit/prompt-refinement.json" > "$tmp/p.json" && mv "$tmp/p.json" "$tmp/walteur-kit/prompt-refinement.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "UI contract but routing says no UI -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/prompt-refinement-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_good_prompt "$tmp"
  jq '.specialist_plan = [.specialist_plan[0], .specialist_plan[1]]' "$tmp/walteur-kit/prompt-refinement.json" > "$tmp/p.json" && mv "$tmp/p.json" "$tmp/walteur-kit/prompt-refinement.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "thin specialist plan -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/prompt-refinement-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_good_prompt "$tmp"
  jq '.source_refs = ["missing.md"]' "$tmp/walteur-kit/prompt-refinement.json" > "$tmp/p.json" && mv "$tmp/p.json" "$tmp/walteur-kit/prompt-refinement.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing source ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/prompt-refinement-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_good_prompt "$tmp"
  jq '.build_brief.outcome = "TODO decide later"' "$tmp/walteur-kit/prompt-refinement.json" > "$tmp/p.json" && mv "$tmp/p.json" "$tmp/walteur-kit/prompt-refinement.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "placeholder text -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "prompt-refinement-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && {
  write_report "FAIL" "paused" "walteur-kit/PAUSED present" '[{"check":"paused","message":"walteur-kit/PAUSED present"}]'
  echo "prompt-refinement-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
}

[ "${WALTEUR_PROMPT_REFINEMENT:-on}" = "off" ] && {
  write_report "SKIP" "bypass" "bypassed via WALTEUR_PROMPT_REFINEMENT=off" "[]"
  echo "prompt-refinement-gate verdict: SKIP - bypassed via WALTEUR_PROMPT_REFINEMENT=off -> $REPORT" >&2
  exit 0
}

if ! have jq; then
  write_report "SKIP" "tool_absent" "jq not installed" "[]"
  echo "prompt-refinement-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  exit 0
fi

detect_required

if [ ! -f "$PROMPT" ]; then
  if [ "$PROMPT_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "required_missing" "prompt refinement missing while required ($PROMPT_REQUIRED_REASON)" '[{"check":"prompt_refinement.present","message":"walteur-kit/prompt-refinement.json is required once plan starts"}]'
    echo "prompt-refinement-gate verdict: FAIL - prompt refinement missing while required ($PROMPT_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "not_required" "no prompt refinement before plan" "[]"
  echo "prompt-refinement-gate verdict: NOT_APPLICABLE - no report before plan -> $REPORT" >&2
  exit 0
fi

if [ ! -s "$PROMPT" ]; then
  if [ "$PROMPT_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "empty_required" "empty prompt refinement while required ($PROMPT_REQUIRED_REASON)" '[{"check":"prompt_refinement.nonempty","message":"walteur-kit/prompt-refinement.json is empty once plan starts"}]'
    echo "prompt-refinement-gate verdict: FAIL - empty prompt refinement while required ($PROMPT_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "runtime_stub" "zero-byte runtime stub before plan" "[]"
  echo "prompt-refinement-gate verdict: NOT_APPLICABLE - zero-byte runtime stub before plan -> $REPORT" >&2
  exit 0
fi

if ! jq empty "$PROMPT" >/dev/null 2>&1; then
  write_report "FAIL" "invalid_json" "prompt refinement JSON invalid" '[{"check":"json","message":"walteur-kit/prompt-refinement.json is not valid JSON"}]'
  echo "prompt-refinement-gate verdict: FAIL - prompt refinement JSON invalid -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

if ! jq -e '.schema_version == 1' "$PROMPT" >/dev/null 2>&1; then
  add_finding "schema_version" "schema_version must be 1"
fi

if ! jq -e '.verdict == "PASS"' "$PROMPT" >/dev/null 2>&1; then
  add_finding "verdict" "prompt refinement verdict must be PASS"
fi

for key in raw_request improved_prompt build_brief routing specialist_plan verification_plan quality_bar open_questions source_refs ts; do
  if ! jq -e --arg key "$key" 'has($key)' "$PROMPT" >/dev/null 2>&1; then
    add_finding "required.$key" "missing required key: $key"
  fi
done

improved_prompt="$(jq -r '.improved_prompt // ""' "$PROMPT")"
if [ "$(word_count "$improved_prompt")" -lt 30 ]; then
  add_finding "improved_prompt.depth" "improved_prompt must be at least 30 words"
fi

for phrase in outcome acceptance verification security frontend backend qa; do
  if ! printf '%s' "$improved_prompt" | grep -Eiq "$phrase"; then
    add_finding "improved_prompt.$phrase" "improved_prompt must explicitly mention $phrase"
  fi
done

if ! jq -e '.build_brief.outcome | type == "string" and length > 0' "$PROMPT" >/dev/null 2>&1; then
  add_finding "build_brief.outcome" "build_brief.outcome is required"
fi
if ! jq -e '.build_brief.success_metrics | type == "array" and length >= 1' "$PROMPT" >/dev/null 2>&1; then
  add_finding "build_brief.success_metrics" "at least one success metric is required"
fi
if ! jq -e '.build_brief.acceptance_criteria | type == "array" and length >= 3' "$PROMPT" >/dev/null 2>&1; then
  add_finding "build_brief.acceptance_criteria" "at least three acceptance criteria are required"
fi
if ! jq -e '.build_brief.non_goals | type == "array" and length >= 1' "$PROMPT" >/dev/null 2>&1; then
  add_finding "build_brief.non_goals" "at least one non-goal is required"
fi

bad_ac="$(jq -r '
  .build_brief.acceptance_criteria[]?
  | select((.id|type!="string") or (.criterion|type!="string") or (.verification|type!="string"))
  | (.id // "<missing>")
' "$PROMPT" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_ac" ] && add_finding "build_brief.acceptance_criteria.shape" "invalid acceptance criteria: $bad_ac"

if ! jq -e '.specialist_plan | type == "array" and length >= 3' "$PROMPT" >/dev/null 2>&1; then
  add_finding "specialist_plan" "at least three specialist roles are required"
fi
if ! jq -e '.verification_plan | type == "array" and length >= 3' "$PROMPT" >/dev/null 2>&1; then
  add_finding "verification_plan" "at least three verification steps are required"
fi

for gate in delivery-orchestration-gate qa-contract-gate outcome-eval-gate; do
  jq -e --arg gate "$gate" '.verification_plan[]? | select(.gate == $gate)' "$PROMPT" >/dev/null 2>&1 || add_finding "verification_plan.$gate" "verification_plan must include $gate"
done

if ! jq -e '.quality_bar.must_haves | type == "array" and length >= 3' "$PROMPT" >/dev/null 2>&1; then
  add_finding "quality_bar.must_haves" "quality_bar.must_haves requires at least three items"
fi
if ! jq -e '.quality_bar.stop_conditions | type == "array" and length >= 1' "$PROMPT" >/dev/null 2>&1; then
  add_finding "quality_bar.stop_conditions" "quality_bar.stop_conditions requires at least one item"
fi

bad_enums="$(jq -r '
  [
    (if (.routing.build_class as $v | ["software","workflow","document","data-ai","cloud-iac","mixed"] | index($v) | not) then "routing.build_class" else empty end),
    (if (.routing.risk_tier as $v | ["low","medium","high","regulated"] | index($v) | not) then "routing.risk_tier" else empty end),
    (if (.routing.data_classification as $v | ["public","internal","confidential","restricted","regulated"] | index($v) | not) then "routing.data_classification" else empty end)
  ] | join(", ")
' "$PROMPT" 2>/dev/null)"
[ -n "$bad_enums" ] && add_finding "routing.enums" "invalid routing fields: $bad_enums"

if [ -f "$CONTRACT" ] && jq empty "$CONTRACT" >/dev/null 2>&1; then
  contract_class="$(jq -r '.build_class // ""' "$CONTRACT")"
  prompt_class="$(jq -r '.routing.build_class // ""' "$PROMPT")"
  [ -n "$contract_class" ] && [ "$contract_class" != "$prompt_class" ] && add_finding "routing.build_class.contract" "routing.build_class must match build-contract.json build_class"

  contract_risk="$(jq -r '.risk_tier // ""' "$CONTRACT")"
  prompt_risk="$(jq -r '.routing.risk_tier // ""' "$PROMPT")"
  [ -n "$contract_risk" ] && [ "$contract_risk" != "$prompt_risk" ] && add_finding "routing.risk_tier.contract" "routing.risk_tier must match build-contract.json risk_tier"

  if jq -e '[.interfaces[]? | select(.type == "ui")] | length > 0' "$CONTRACT" >/dev/null 2>&1; then
    jq -e '.routing.requires_ui == true' "$PROMPT" >/dev/null 2>&1 || add_finding "routing.requires_ui" "UI interface in build contract requires routing.requires_ui true"
  fi
  if jq -e '[.interfaces[]? | select(.type == "api" or .type == "database" or .type == "event" or .type == "external-service")] | length > 0' "$CONTRACT" >/dev/null 2>&1; then
    jq -e '.routing.requires_backend == true' "$PROMPT" >/dev/null 2>&1 || add_finding "routing.requires_backend" "backend/API interface in build contract requires routing.requires_backend true"
  fi
fi

while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  ref_file="${ref%%#*}"
  case "$ref_file" in
    /*) path="$ref_file" ;;
    *) path="$ROOT/$ref_file" ;;
  esac
  [ -f "$path" ] || [ -d "$path" ] || add_finding "source_refs.exists" "source_ref points to missing file: $ref"
done <<EOF
$(jq -r '.source_refs[]? // empty' "$PROMPT" 2>/dev/null)
EOF

placeholder_hits="$(jq -r '
  .. | strings | select(test("(^|[^A-Z])(TODO|TBD|TK|PLACEHOLDER|FIXME|decide later|figure out later)([^A-Z]|$)"; "i"))
' "$PROMPT" 2>/dev/null | head -20 | paste -sd ' | ' -)"
[ -n "$placeholder_hits" ] && add_finding "placeholders" "placeholder text is not allowed: $placeholder_hits"

report_mtime="$(mtime "$PROMPT")"
latest_mtime="$(latest_source_mtime)"
if [ "${latest_mtime:-0}" -gt "${report_mtime:-0}" ]; then
  add_finding "freshness" "prompt-refinement.json is older than a source contract, plan, PRD, state, or instruction file"
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "validated" "$failures finding(s)" "$findings"
  echo "prompt-refinement-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "validated" "prompt refinement proof passes" "[]"
echo "prompt-refinement-gate verdict: PASS - prompt refinement proof passes -> $REPORT" >&2
exit 0
