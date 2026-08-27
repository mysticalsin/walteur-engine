#!/usr/bin/env bash
# WALTEUR delivery-orchestration-gate - typed agent team and SDLC orchestration proof.
#
# Contract:
#   - No delivery-orchestration.json before plan                 => NOT_APPLICABLE, exit 0.
#   - Empty runtime stub before plan                             => NOT_APPLICABLE, exit 0.
#   - Plan/build/verify/review/ship/reflect without valid proof   => FAIL, exit 2.
#   - PASS proof with weak roster, stage gates, coverage,
#     independence, handoffs, worktree boundaries, or audit trail => FAIL, exit 2.
#   - Complete delivery orchestration proof                       => PASS, exit 0.
#
# Report:
#   walteur-kit/delivery-orchestration-report.json
#
# Bypass:
#   WALTEUR_DELIVERY_ORCHESTRATION=off
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
ORCH="$KIT/delivery-orchestration.json"
STATE="$KIT/autopilot/STATE.json"
CONTRACT="$KIT/build-contract.json"
REPORT="$KIT/delivery-orchestration-report.json"
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
      --arg orchestration "${ORCH#"$ROOT"/}" --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"delivery-orchestration-gate", mode:$mode, orchestration_file:$orchestration, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"delivery-orchestration-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0\n'
}

resolve_ref_path() {
  ref="$1"
  ref_file="${ref%%#*}"
  case "$ref_file" in
    /*) printf '%s\n' "$ref_file" ;;
    *) printf '%s\n' "$ROOT/$ref_file" ;;
  esac
}

ref_exists() {
  ref="$1"
  [ -n "$ref" ] || return 1
  path="$(resolve_ref_path "$ref")"
  [ -f "$path" ] || [ -d "$path" ]
}

detect_required() {
  ORCH_REQUIRED=0
  ORCH_REQUIRED_REASON=""

  if [ "${WALTEUR_DELIVERY_ORCHESTRATION_REQUIRED:-}" = "1" ]; then
    ORCH_REQUIRED=1
    ORCH_REQUIRED_REASON="WALTEUR_DELIVERY_ORCHESTRATION_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      plan|build|verify|review|ship|reflect)
        ORCH_REQUIRED=1
        ORCH_REQUIRED_REASON="STATE.phase=$phase"
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
      "$REPORT"|"$ORCH") return 0 ;;
    esac
    mt="$(mtime "$f")"
    [ "${mt:-0}" -gt "$latest" ] && latest="$mt"
  }

  for f in \
    "$CONTRACT" \
    "$STATE" \
    "$KIT/estimate.json" \
    "$KIT/self-improvement.json" \
    "$KIT/qa-report.json" \
    "$KIT/outcome-eval.json" \
    "$KIT/DEFINITION-OF-DONE.md" \
    "$ROOT/PLAN.md" \
    "$ROOT/README.md"
  do
    update_latest "$f"
  done

  printf '%s\n' "$latest"
}

has_role() {
  role="$1"
  jq -e --arg role "$role" '.roster[]? | select(.role == $role)' "$ORCH" >/dev/null 2>&1
}

coverage_required_pass() {
  key="$1"
  jq -e --arg key "$key" '
    .coverage[$key] as $c
    | ($c | type == "object")
    and ($c.required == true)
    and ($c.owner | type == "string" and length > 0)
    and ($c.status == "PLANNED" or $c.status == "PASS")
  ' "$ORCH" >/dev/null 2>&1
}

stage_present() {
  stage="$1"
  jq -e --arg stage "$stage" '.stage_gates[]? | select(.stage == $stage and (.status == "PLANNED" or .status == "PASS"))' "$ORCH" >/dev/null 2>&1
}

check_stage() {
  stage="$1"
  if ! stage_present "$stage"; then
    add_finding "stage_gates.$stage" "required SDLC stage '$stage' must be PLANNED or PASS"
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
    echo "delivery-orchestration-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    root="$1"
    phase="$2"
    class="${3:-software}"
    risk="${4:-medium}"
    mkdir -p "$root/walteur-kit/autopilot"
    jq -n --arg phase "$phase" --arg class "$class" --arg risk "$risk" '{
      schema_version: 1,
      run_id: "delivery-selftest",
      goal: "delivery orchestration selftest",
      owner: "QA",
      build_class: $class,
      risk_tier: $risk,
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
      next_action: "delivery",
      baton_path: "walteur-kit/autopilot/STATE.json",
      updated_at: "2026-06-22T00:00:00Z"
    }' > "$root/walteur-kit/autopilot/STATE.json"
  }

  write_contract() {
    root="$1"
    mkdir -p "$root/walteur-kit"
    jq -n '{
      schema_version: 1,
      contract_id: "delivery-contract",
      request: {
        summary: "Build a verified full-stack dashboard",
        user_outcome: "Operators complete the workflow",
        primary_user: "Operator",
        non_goals: ["No billing"]
      },
      build_class: "software",
      risk_tier: "medium",
      data_classification: "internal",
      success_metrics: [{name:"Core flow", target:"Completes", check:"Run test"}],
      constraints: [],
      interfaces: [
        {name:"Web UI", type:"ui", owner:"UX", contract:"Core flow UI"},
        {name:"Service API", type:"api", owner:"Backend", contract:"Core flow API"}
      ],
      verification: {gates: [], commands: [], manual_checks: []},
      evidence_required: ["test output"],
      unknowns: [],
      created_at: "2026-06-22T00:00:00Z"
    }' > "$root/walteur-kit/build-contract.json"
  }

  write_refs() {
    root="$1"
    mkdir -p "$root/walteur-kit" "$root/src/frontend" "$root/src/backend"
    printf '# Plan\n' > "$root/PLAN.md"
    printf '{"state":true}\n' > "$root/walteur-kit/autopilot/STATE.json.tmp"
    printf 'trace\n' > "$root/walteur-kit/run-trace.jsonl"
    printf 'review\n' > "$root/walteur-kit/review.md"
    printf 'eval\n' > "$root/walteur-kit/outcome-eval.json"
    printf 'tests\n' > "$root/walteur-kit/test-output.txt"
    printf 'ui\n' > "$root/src/frontend/App.tsx"
    printf 'api\n' > "$root/src/backend/api.ts"
  }

  write_good_orch() {
    root="$1"
    mkdir -p "$root/walteur-kit"
    jq -n '{
      schema_version: 1,
      verdict: "PASS",
      build_class: "software",
      risk_tier: "medium",
      coordination_pattern: "pipeline",
      sdlc_mode: "full_5_stage",
      roster: [
        {id:"orchestrator", role:"orchestrator", responsibility:"Decompose, delegate, validate, and synthesize.", model_tier:"standard", permission:"execute", independent_from:[]},
        {id:"frontend-dev", role:"frontend", responsibility:"Build UI states and interactions.", model_tier:"standard", permission:"write_code", independent_from:[]},
        {id:"backend-dev", role:"backend", responsibility:"Build API and persistence.", model_tier:"standard", permission:"write_code", independent_from:[]},
        {id:"security-reviewer", role:"security", responsibility:"Review auth, input handling, data exposure.", model_tier:"standard", permission:"read_only", independent_from:["frontend-dev","backend-dev"]},
        {id:"qa-lead", role:"qa", responsibility:"Own test matrix and QA verdict.", model_tier:"standard", permission:"read_only", independent_from:["frontend-dev","backend-dev"]},
        {id:"ux-reviewer", role:"ux", responsibility:"Review accessibility and user flow.", model_tier:"standard", permission:"read_only", independent_from:["frontend-dev"]},
        {id:"code-reviewer", role:"reviewer", responsibility:"Review diff and request changes.", model_tier:"standard", permission:"read_only", independent_from:["frontend-dev","backend-dev"]},
        {id:"outcome-evaluator", role:"evaluator", responsibility:"Score outcome independently.", model_tier:"standard", permission:"read_only", independent_from:["frontend-dev","backend-dev","code-reviewer"]},
        {id:"release-owner", role:"release", responsibility:"Own release notes and rollback.", model_tier:"human", permission:"approve", independent_from:[]}
      ],
      decomposition: {
        source_ref: "PLAN.md",
        tasks: [
          {id:"t1", title:"Build frontend flow", owner:"frontend-dev", workstream:"frontend", touch_refs:["src/frontend/App.tsx"], depends_on:[], parallel_group:"p1", verification_ref:"walteur-kit/test-output.txt"},
          {id:"t2", title:"Build backend API", owner:"backend-dev", workstream:"backend", touch_refs:["src/backend/api.ts"], depends_on:[], parallel_group:"p1", verification_ref:"walteur-kit/test-output.txt"},
          {id:"t3", title:"Run QA and review", owner:"qa-lead", workstream:"qa", touch_refs:["walteur-kit/test-output.txt"], depends_on:["t1","t2"], verification_ref:"walteur-kit/test-output.txt"}
        ]
      },
      stage_gates: [
        {stage:"discover", owner:"product", status:"PLANNED", criteria:["Problem and acceptance criteria are locked."]},
        {stage:"plan", owner:"orchestrator", status:"PLANNED", criteria:["Agent roster and handoff boundaries are locked."]},
        {stage:"local_build", owner:"frontend-dev", status:"PLANNED", criteria:["TDD, lint, build, and no secrets."]},
        {stage:"shared_dev", owner:"code-reviewer", status:"PLANNED", criteria:["Independent code and security review."]},
        {stage:"staging", owner:"qa-lead", status:"PLANNED", criteria:["Unit, integration, E2E, parity, performance."]},
        {stage:"beta", owner:"release-owner", status:"PLANNED", criteria:["Adversarial, a11y, docs, rollback, human signoff."]},
        {stage:"production", owner:"release-owner", status:"PLANNED", criteria:["Smoke, monitoring, rollback ready."]},
        {stage:"reflect", owner:"orchestrator", status:"PLANNED", criteria:["Retro and lesson capture."]}
      ],
      coverage: {
        frontend:{required:true, owner:"frontend-dev", status:"PLANNED"},
        backend:{required:true, owner:"backend-dev", status:"PLANNED"},
        api:{required:true, owner:"backend-dev", status:"PLANNED"},
        data:{required:true, owner:"backend-dev", status:"PLANNED"},
        security:{required:true, owner:"security-reviewer", status:"PLANNED"},
        qa:{required:true, owner:"qa-lead", status:"PLANNED"},
        devops:{required:true, owner:"release-owner", status:"PLANNED"},
        ux:{required:true, owner:"ux-reviewer", status:"PLANNED"},
        observability:{required:true, owner:"release-owner", status:"PLANNED"},
        docs:{required:true, owner:"release-owner", status:"PLANNED"},
        release:{required:true, owner:"release-owner", status:"PLANNED"},
        rollback:{required:true, owner:"release-owner", status:"PLANNED"}
      },
      handoffs: [
        {from:"frontend-dev", to:"code-reviewer", artifact_ref:"src/frontend/App.tsx", validation_ref:"walteur-kit/review.md"},
        {from:"backend-dev", to:"code-reviewer", artifact_ref:"src/backend/api.ts", validation_ref:"walteur-kit/review.md"},
        {from:"code-reviewer", to:"outcome-evaluator", artifact_ref:"walteur-kit/review.md", validation_ref:"walteur-kit/outcome-eval.json"}
      ],
      independence: {
        builder_ids:["frontend-dev","backend-dev"],
        reviewer_ids:["code-reviewer","security-reviewer","qa-lead","ux-reviewer"],
        evaluator_ids:["outcome-evaluator"],
        reviewer_independent:true,
        evaluator_independent:true
      },
      worktree_strategy: {
        mode:"isolated_worktrees",
        collision_policy:"Parallel code writers own disjoint paths; overlap collapses to sequential handoff.",
        boundaries:[
          {owner:"frontend-dev", paths:["src/frontend"]},
          {owner:"backend-dev", paths:["src/backend"]}
        ]
      },
      audit: {
        trace_ref:"walteur-kit/run-trace.jsonl",
        run_state_ref:"walteur-kit/autopilot/STATE.json",
        escalation_policy:"Retry once with scoped feedback, then escalate with blocker and options.",
        human_signoff_required:false
      },
      ts:"2026-06-22T00:00:00Z"
    }' > "$root/walteur-kit/delivery-orchestration.json"
  }

  echo "delivery-orchestration-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no report before plan -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing report in plan -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  : > "$tmp/walteur-kit/delivery-orchestration.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "empty stub before plan -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  : > "$tmp/walteur-kit/delivery-orchestration.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "empty report in plan -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_refs "$tmp"
  mv "$tmp/walteur-kit/autopilot/STATE.json.tmp" "$tmp/walteur-kit/autopilot/STATE.json"
  write_good_orch "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "good full-stack orchestration -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_refs "$tmp"
  mv "$tmp/walteur-kit/autopilot/STATE.json.tmp" "$tmp/walteur-kit/autopilot/STATE.json"
  write_good_orch "$tmp"
  jq '.independence.reviewer_ids += ["frontend-dev"]' "$tmp/walteur-kit/delivery-orchestration.json" > "$tmp/o.json" && mv "$tmp/o.json" "$tmp/walteur-kit/delivery-orchestration.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "reviewer overlaps builder -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_refs "$tmp"
  mv "$tmp/walteur-kit/autopilot/STATE.json.tmp" "$tmp/walteur-kit/autopilot/STATE.json"
  write_good_orch "$tmp"
  jq '.independence.evaluator_ids = ["backend-dev"] | .independence.evaluator_independent = false' "$tmp/walteur-kit/delivery-orchestration.json" > "$tmp/o.json" && mv "$tmp/o.json" "$tmp/walteur-kit/delivery-orchestration.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "evaluator self-review -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_refs "$tmp"
  mv "$tmp/walteur-kit/autopilot/STATE.json.tmp" "$tmp/walteur-kit/autopilot/STATE.json"
  write_good_orch "$tmp"
  jq '.stage_gates |= map(select(.stage != "beta" and .stage != "production"))' "$tmp/walteur-kit/delivery-orchestration.json" > "$tmp/o.json" && mv "$tmp/o.json" "$tmp/walteur-kit/delivery-orchestration.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing beta and production stages -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_refs "$tmp"
  mv "$tmp/walteur-kit/autopilot/STATE.json.tmp" "$tmp/walteur-kit/autopilot/STATE.json"
  write_good_orch "$tmp"
  jq '.coverage.frontend.required = false | .coverage.ux.required = false' "$tmp/walteur-kit/delivery-orchestration.json" > "$tmp/o.json" && mv "$tmp/o.json" "$tmp/walteur-kit/delivery-orchestration.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "UI contract without frontend and UX coverage -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_refs "$tmp"
  mv "$tmp/walteur-kit/autopilot/STATE.json.tmp" "$tmp/walteur-kit/autopilot/STATE.json"
  write_good_orch "$tmp"
  jq '.worktree_strategy.mode = "single" | .worktree_strategy.boundaries = []' "$tmp/walteur-kit/delivery-orchestration.json" > "$tmp/o.json" && mv "$tmp/o.json" "$tmp/walteur-kit/delivery-orchestration.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "parallel group without worktree isolation -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_refs "$tmp"
  mv "$tmp/walteur-kit/autopilot/STATE.json.tmp" "$tmp/walteur-kit/autopilot/STATE.json"
  write_good_orch "$tmp"
  jq '.handoffs[0].artifact_ref = "missing/file.ts"' "$tmp/walteur-kit/delivery-orchestration.json" > "$tmp/o.json" && mv "$tmp/o.json" "$tmp/walteur-kit/delivery-orchestration.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "handoff references missing artifact -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan" "software" "high"
  write_contract "$tmp"
  write_refs "$tmp"
  mv "$tmp/walteur-kit/autopilot/STATE.json.tmp" "$tmp/walteur-kit/autopilot/STATE.json"
  write_good_orch "$tmp"
  jq '.risk_tier = "high" | .audit.human_signoff_required = false' "$tmp/walteur-kit/delivery-orchestration.json" > "$tmp/o.json" && mv "$tmp/o.json" "$tmp/walteur-kit/delivery-orchestration.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "high risk without human signoff requirement -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/delivery-orch-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp"
  write_refs "$tmp"
  mv "$tmp/walteur-kit/autopilot/STATE.json.tmp" "$tmp/walteur-kit/autopilot/STATE.json"
  write_good_orch "$tmp"
  jq '.roster[0].responsibility = "TODO decide later"' "$tmp/walteur-kit/delivery-orchestration.json" > "$tmp/o.json" && mv "$tmp/o.json" "$tmp/walteur-kit/delivery-orchestration.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "placeholder text -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "delivery-orchestration-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && {
  write_report "FAIL" "paused" "walteur-kit/PAUSED present" '[{"check":"paused","message":"walteur-kit/PAUSED present"}]'
  echo "delivery-orchestration-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
}

[ "${WALTEUR_DELIVERY_ORCHESTRATION:-on}" = "off" ] && {
  write_report "SKIP" "bypass" "bypassed via WALTEUR_DELIVERY_ORCHESTRATION=off" "[]"
  echo "delivery-orchestration-gate verdict: SKIP - bypassed via WALTEUR_DELIVERY_ORCHESTRATION=off -> $REPORT" >&2
  exit 0
}

if ! have jq; then
  write_report "SKIP" "tool_absent" "jq not installed" "[]"
  echo "delivery-orchestration-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  exit 0
fi

detect_required

if [ ! -f "$ORCH" ]; then
  if [ "$ORCH_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "required_missing" "delivery orchestration missing while required ($ORCH_REQUIRED_REASON)" '[{"check":"delivery_orchestration.present","message":"walteur-kit/delivery-orchestration.json is required once plan starts"}]'
    echo "delivery-orchestration-gate verdict: FAIL - report missing while required ($ORCH_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "not_required" "no delivery orchestration before plan" "[]"
  echo "delivery-orchestration-gate verdict: NOT_APPLICABLE - no report before plan -> $REPORT" >&2
  exit 0
fi

if [ ! -s "$ORCH" ]; then
  if [ "$ORCH_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "empty_required" "empty delivery orchestration while required ($ORCH_REQUIRED_REASON)" '[{"check":"delivery_orchestration.nonempty","message":"walteur-kit/delivery-orchestration.json is empty once plan starts"}]'
    echo "delivery-orchestration-gate verdict: FAIL - empty report while required ($ORCH_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "runtime_stub" "zero-byte runtime stub before plan" "[]"
  echo "delivery-orchestration-gate verdict: NOT_APPLICABLE - zero-byte runtime stub before plan -> $REPORT" >&2
  exit 0
fi

if ! jq empty "$ORCH" >/dev/null 2>&1; then
  write_report "FAIL" "invalid_json" "delivery orchestration JSON invalid" '[{"check":"json","message":"walteur-kit/delivery-orchestration.json is not valid JSON"}]'
  echo "delivery-orchestration-gate verdict: FAIL - delivery orchestration JSON invalid -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

if ! jq -e '.schema_version == 1' "$ORCH" >/dev/null 2>&1; then
  add_finding "schema_version" "schema_version must be 1"
fi

if ! jq -e '.verdict == "PASS"' "$ORCH" >/dev/null 2>&1; then
  add_finding "verdict" "delivery orchestration verdict must be PASS"
fi

for key in build_class risk_tier coordination_pattern sdlc_mode roster decomposition stage_gates coverage handoffs independence worktree_strategy audit ts; do
  if ! jq -e --arg key "$key" 'has($key)' "$ORCH" >/dev/null 2>&1; then
    add_finding "required.$key" "missing required key: $key"
  fi
done

bad_enums="$(jq -r '
  [
    (if (.build_class as $v | ["software","workflow","document","data-ai","cloud-iac","mixed"] | index($v) | not) then "build_class" else empty end),
    (if (.risk_tier as $v | ["low","medium","high","regulated"] | index($v) | not) then "risk_tier" else empty end),
    (if (.coordination_pattern as $v | ["coordinator","pipeline","fanout_fanin","ensemble","debate","supervisor","hierarchical","solo"] | index($v) | not) then "coordination_pattern" else empty end),
    (if (.sdlc_mode as $v | ["full_5_stage","light","non_software","manual_exception"] | index($v) | not) then "sdlc_mode" else empty end)
  ] | join(", ")
' "$ORCH" 2>/dev/null)"
[ -n "$bad_enums" ] && add_finding "enums" "invalid enum fields: $bad_enums"

if ! jq -e '.roster | type == "array" and length > 0' "$ORCH" >/dev/null 2>&1; then
  add_finding "roster.shape" "roster must be a non-empty array"
fi

duplicate_roster="$(jq -r '.roster[]?.id // empty' "$ORCH" 2>/dev/null | sort | uniq -d | paste -sd ', ' -)"
[ -n "$duplicate_roster" ] && add_finding "roster.unique" "duplicate roster ids: $duplicate_roster"

for role in orchestrator reviewer evaluator; do
  has_role "$role" || add_finding "roster.role.$role" "roster requires role '$role'"
done

build_class="$(jq -r '.build_class // ""' "$ORCH")"
risk_tier="$(jq -r '.risk_tier // ""' "$ORCH")"
case "$build_class" in
  software|mixed|data-ai|cloud-iac)
    for role in security qa; do
      has_role "$role" || add_finding "roster.role.$role" "code-producing delivery requires role '$role'"
    done
    if ! jq -e '.sdlc_mode == "full_5_stage"' "$ORCH" >/dev/null 2>&1; then
      add_finding "sdlc_mode" "code-producing delivery requires sdlc_mode full_5_stage"
    fi
    for stage in local_build shared_dev staging beta production; do
      check_stage "$stage"
    done
    for cov in security qa devops observability docs release rollback; do
      coverage_required_pass "$cov" || add_finding "coverage.$cov" "code-producing delivery requires $cov coverage owned and PLANNED or PASS"
    done
    ;;
esac

if jq -e '.decomposition.tasks | type == "array" and length > 0' "$ORCH" >/dev/null 2>&1; then
  bad_tasks="$(jq -r '
    .decomposition.tasks[]
    | select((.id|type!="string") or (.title|type!="string") or (.owner|type!="string") or (.workstream|type!="string")
        or (.touch_refs|type!="array" or (.touch_refs|length == 0))
        or (.depends_on|type!="array")
        or (.verification_ref|type!="string"))
    | (.id // "<missing>")
  ' "$ORCH" 2>/dev/null | paste -sd ', ' -)"
  [ -n "$bad_tasks" ] && add_finding "decomposition.tasks.shape" "invalid task entries: $bad_tasks"
else
  add_finding "decomposition.tasks" "at least one decomposed task is required"
fi

if ! jq -e '.decomposition.source_ref | type == "string" and length > 0' "$ORCH" >/dev/null 2>&1; then
  add_finding "decomposition.source_ref" "decomposition.source_ref is required"
elif ! ref_exists "$(jq -r '.decomposition.source_ref' "$ORCH")"; then
  add_finding "decomposition.source_ref.exists" "decomposition.source_ref points to a missing file"
fi

while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  ref_exists "$ref" || add_finding "decomposition.verification_ref.exists" "task verification_ref points to missing file: $ref"
done <<EOF
$(jq -r '.decomposition.tasks[]?.verification_ref // empty' "$ORCH" 2>/dev/null)
EOF

if jq -e '[.decomposition.tasks[]? | select(.parallel_group? != null and .parallel_group != "")] | length > 0' "$ORCH" >/dev/null 2>&1; then
  if ! jq -e '.worktree_strategy.mode == "isolated_worktrees" and (.worktree_strategy.boundaries | type == "array" and length > 0)' "$ORCH" >/dev/null 2>&1; then
    add_finding "worktree_strategy.parallel" "parallel task groups require isolated_worktrees mode and ownership boundaries"
  fi
fi

if ! jq -e '.independence.reviewer_independent == true and .independence.evaluator_independent == true' "$ORCH" >/dev/null 2>&1; then
  add_finding "independence.flags" "reviewer_independent and evaluator_independent must both be true"
fi

overlap_reviewers="$(jq -r '
  (.independence.builder_ids // []) as $b
  | (.independence.reviewer_ids // [])[] as $id
  | select($b | index($id))
  | $id
' "$ORCH" 2>/dev/null | paste -sd ', ' -)"
[ -n "$overlap_reviewers" ] && add_finding "independence.reviewers" "reviewer ids overlap builder ids: $overlap_reviewers"

overlap_evaluators="$(jq -r '
  (.independence.builder_ids // []) as $b
  | (.independence.evaluator_ids // [])[] as $id
  | select($b | index($id))
  | $id
' "$ORCH" 2>/dev/null | paste -sd ', ' -)"
[ -n "$overlap_evaluators" ] && add_finding "independence.evaluators" "evaluator ids overlap builder ids: $overlap_evaluators"

if [ -f "$CONTRACT" ] && jq empty "$CONTRACT" >/dev/null 2>&1; then
  if jq -e '[.interfaces[]? | select(.type == "ui")] | length > 0' "$CONTRACT" >/dev/null 2>&1; then
    coverage_required_pass "frontend" || add_finding "coverage.frontend.ui" "build contract declares a UI interface, so frontend coverage is required"
    coverage_required_pass "ux" || add_finding "coverage.ux.ui" "build contract declares a UI interface, so UX/accessibility coverage is required"
    { has_role "frontend" || has_role "fullstack"; } || add_finding "roster.frontend.ui" "UI delivery requires a frontend or fullstack role"
    has_role "ux" || add_finding "roster.ux.ui" "UI delivery requires a UX/accessibility role"
  fi
  if jq -e '[.interfaces[]? | select(.type == "api" or .type == "database" or .type == "event" or .type == "external-service")] | length > 0' "$CONTRACT" >/dev/null 2>&1; then
    coverage_required_pass "backend" || add_finding "coverage.backend.api" "build contract declares a backend interface, so backend coverage is required"
    coverage_required_pass "api" || add_finding "coverage.api.api" "build contract declares an API-like interface, so API coverage is required"
    { has_role "backend" || has_role "api" || has_role "fullstack"; } || add_finding "roster.backend.api" "API/database/event delivery requires backend, API, or fullstack role"
  fi
fi

while IFS=$'\t' read -r from_id to_id artifact validation; do
  [ -n "$from_id" ] || continue
  jq -e --arg id "$from_id" '.roster[]? | select(.id == $id)' "$ORCH" >/dev/null 2>&1 || add_finding "handoffs.from" "handoff from unknown roster id: $from_id"
  jq -e --arg id "$to_id" '.roster[]? | select(.id == $id)' "$ORCH" >/dev/null 2>&1 || add_finding "handoffs.to" "handoff to unknown roster id: $to_id"
  ref_exists "$artifact" || add_finding "handoffs.artifact_ref" "handoff artifact_ref points to missing file: $artifact"
  ref_exists "$validation" || add_finding "handoffs.validation_ref" "handoff validation_ref points to missing file: $validation"
done <<EOF
$(jq -r '.handoffs[]? | [.from, .to, .artifact_ref, .validation_ref] | @tsv' "$ORCH" 2>/dev/null)
EOF

if ! jq -e '.audit.trace_ref | type == "string" and length > 0' "$ORCH" >/dev/null 2>&1 || ! ref_exists "$(jq -r '.audit.trace_ref // ""' "$ORCH")"; then
  add_finding "audit.trace_ref" "audit.trace_ref must point to an existing file"
fi
if ! jq -e '.audit.run_state_ref | type == "string" and length > 0' "$ORCH" >/dev/null 2>&1 || ! ref_exists "$(jq -r '.audit.run_state_ref // ""' "$ORCH")"; then
  add_finding "audit.run_state_ref" "audit.run_state_ref must point to an existing file"
fi

case "$risk_tier" in
  high|regulated)
    if ! jq -e '.audit.human_signoff_required == true' "$ORCH" >/dev/null 2>&1; then
      add_finding "audit.human_signoff_required" "high and regulated risk delivery must require human signoff"
    fi
    ;;
esac

placeholder_hits="$(jq -r '
  .. | strings | select(test("(^|[^A-Z])(TODO|TBD|TK|PLACEHOLDER|FIXME|decide later)([^A-Z]|$)"; "i"))
' "$ORCH" 2>/dev/null | head -20 | paste -sd ' | ' -)"
[ -n "$placeholder_hits" ] && add_finding "placeholders" "placeholder text is not allowed: $placeholder_hits"

report_mtime="$(mtime "$ORCH")"
latest_mtime="$(latest_source_mtime)"
if [ "${latest_mtime:-0}" -gt "${report_mtime:-0}" ]; then
  add_finding "freshness" "delivery-orchestration.json is older than a source contract, state, or verification artifact"
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "validated" "$failures finding(s)" "$findings"
  echo "delivery-orchestration-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "validated" "delivery orchestration proof passes" "[]"
echo "delivery-orchestration-gate verdict: PASS - delivery orchestration proof passes -> $REPORT" >&2
exit 0
