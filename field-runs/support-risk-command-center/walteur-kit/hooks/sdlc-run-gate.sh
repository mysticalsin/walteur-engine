#!/usr/bin/env bash
# WALTEUR sdlc-run-gate - runtime proof that the full enterprise SDLC executed.
#
# Contract:
#   - No sdlc-run.json and no ship/reflect requirement       => NOT_APPLICABLE, exit 0.
#   - Ship/reflect or WALTEUR_SDLC_RUN_REQUIRED=1 without it => FAIL, exit 2.
#   - Weak/malformed/stale five-stage proof                  => FAIL, exit 2.
#   - Complete ordered five-stage proof                      => PASS, exit 0.
#
# Required stages:
#   local_build -> shared_dev -> staging -> beta -> production
#
# Report:
#   walteur-kit/sdlc-run-report.json
#
# Bypass:
#   WALTEUR_SDLC_RUN=off
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
PROOF="$KIT/sdlc-run.json"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/sdlc-run-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MAX_AGE_DAYS="${WALTEUR_SDLC_RUN_MAX_AGE_DAYS:-14}"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  local verdict="$1" reason="$2" extra="${3:-{}}"
  if have jq && printf '%s\n' "$extra" | jq -e . >/dev/null 2>&1; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg reason "$reason" --arg proof "${PROOF#"$ROOT"/}" --argjson extra "$extra" \
      '{verdict:$v, ts:$ts, gate:"sdlc-run-gate", proof_file:$proof, reason:$reason} + $extra' > "$REPORT" 2>/dev/null \
      && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"sdlc-run-gate","proof_file":"%s","reason":"%s"}\n' \
    "$verdict" "$TS" "${PROOF#"$ROOT"/}" "$reason" > "$REPORT" 2>/dev/null || true
}

detect_required() {
  SDLC_REQUIRED=0
  SDLC_REQUIRED_REASON=""

  if [ "${WALTEUR_SDLC_RUN_REQUIRED:-}" = "1" ]; then
    SDLC_REQUIRED=1
    SDLC_REQUIRED_REASON="WALTEUR_SDLC_RUN_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && have jq && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      ship|reflect)
        SDLC_REQUIRED=1
        SDLC_REQUIRED_REASON="STATE.phase=$phase"
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
    echo "sdlc-run-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    local dst="$1" phase="${2:-ship}"
    mkdir -p "$dst/walteur-kit/autopilot"
    jq -n --arg phase "$phase" '{
      schema_version: 1,
      run_id: "sdlc-selftest",
      goal: "SDLC run proof selftest",
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
    mkdir -p "$dst/walteur-kit/sdlc" "$dst/walteur-kit/reports"
    for f in \
      tdd unit lint build local-gate local-evidence code-review security-review integration shared-gate shared-evidence \
      qa e2e parity performance staging-gate staging-evidence adversarial accessibility docs rollback beta-signoff beta-gate beta-evidence \
      deploy smoke monitoring rollback-trigger production-gate production-evidence signoff retro lessons code-review-independence \
      security-review-independence qa-review-independence
    do
      printf '%s evidence\n' "$f" > "$dst/walteur-kit/sdlc/$f.txt"
    done
  }

  write_good_proof() {
    local dst="$1" run_date="${2:-$today}"
    mkdir -p "$dst/walteur-kit"
    cat > "$dst/walteur-kit/sdlc-run.json" <<JSON
{
  "schema_version": 1,
  "run_id": "sdlc-selftest-run",
  "run_date": "$run_date",
  "build_class": "software",
  "risk_tier": "medium",
  "verdict": "PASS",
  "participants": {
    "builder_ids": ["frontend-dev", "backend-dev"],
    "reviewer_ids": ["code-reviewer", "security-reviewer", "qa-lead"],
    "release_owner": "release-owner"
  },
  "stages": [
    {
      "stage": "local_build",
      "owner": "frontend-dev",
      "verdict": "PASS",
      "started_at": "2026-06-23T00:00:00Z",
      "completed_at": "2026-06-23T00:10:00Z",
      "gate_refs": ["walteur-kit/sdlc/local-gate.txt"],
      "evidence_refs": ["walteur-kit/sdlc/local-evidence.txt"],
      "required_refs": {
        "tdd_ref": "walteur-kit/sdlc/tdd.txt",
        "unit_ref": "walteur-kit/sdlc/unit.txt",
        "lint_ref": "walteur-kit/sdlc/lint.txt",
        "build_ref": "walteur-kit/sdlc/build.txt"
      }
    },
    {
      "stage": "shared_dev",
      "owner": "code-reviewer",
      "verdict": "PASS",
      "started_at": "2026-06-23T00:11:00Z",
      "completed_at": "2026-06-23T00:20:00Z",
      "gate_refs": ["walteur-kit/sdlc/shared-gate.txt"],
      "evidence_refs": ["walteur-kit/sdlc/shared-evidence.txt"],
      "required_refs": {
        "code_review_ref": "walteur-kit/sdlc/code-review.txt",
        "security_review_ref": "walteur-kit/sdlc/security-review.txt",
        "integration_ref": "walteur-kit/sdlc/integration.txt"
      }
    },
    {
      "stage": "staging",
      "owner": "qa-lead",
      "verdict": "PASS",
      "started_at": "2026-06-23T00:21:00Z",
      "completed_at": "2026-06-23T00:30:00Z",
      "gate_refs": ["walteur-kit/sdlc/staging-gate.txt"],
      "evidence_refs": ["walteur-kit/sdlc/staging-evidence.txt"],
      "required_refs": {
        "qa_ref": "walteur-kit/sdlc/qa.txt",
        "e2e_ref": "walteur-kit/sdlc/e2e.txt",
        "environment_parity_ref": "walteur-kit/sdlc/parity.txt",
        "performance_ref": "walteur-kit/sdlc/performance.txt"
      }
    },
    {
      "stage": "beta",
      "owner": "release-owner",
      "verdict": "PASS",
      "started_at": "2026-06-23T00:31:00Z",
      "completed_at": "2026-06-23T00:40:00Z",
      "gate_refs": ["walteur-kit/sdlc/beta-gate.txt"],
      "evidence_refs": ["walteur-kit/sdlc/beta-evidence.txt"],
      "required_refs": {
        "adversarial_ref": "walteur-kit/sdlc/adversarial.txt",
        "accessibility_ref": "walteur-kit/sdlc/accessibility.txt",
        "docs_ref": "walteur-kit/sdlc/docs.txt",
        "rollback_ref": "walteur-kit/sdlc/rollback.txt",
        "signoff_ref": "walteur-kit/sdlc/beta-signoff.txt"
      }
    },
    {
      "stage": "production",
      "owner": "release-owner",
      "verdict": "PASS",
      "started_at": "2026-06-23T00:41:00Z",
      "completed_at": "2026-06-23T00:50:00Z",
      "gate_refs": ["walteur-kit/sdlc/production-gate.txt"],
      "evidence_refs": ["walteur-kit/sdlc/production-evidence.txt"],
      "required_refs": {
        "deploy_ref": "walteur-kit/sdlc/deploy.txt",
        "smoke_ref": "walteur-kit/sdlc/smoke.txt",
        "monitoring_ref": "walteur-kit/sdlc/monitoring.txt",
        "rollback_trigger_ref": "walteur-kit/sdlc/rollback-trigger.txt"
      }
    }
  ],
  "independence": {
    "code_review": {
      "reviewer_id": "code-reviewer",
      "independent_from": ["frontend-dev", "backend-dev"],
      "evidence_ref": "walteur-kit/sdlc/code-review-independence.txt"
    },
    "security_review": {
      "reviewer_id": "security-reviewer",
      "independent_from": ["frontend-dev", "backend-dev"],
      "evidence_ref": "walteur-kit/sdlc/security-review-independence.txt"
    },
    "qa_review": {
      "reviewer_id": "qa-lead",
      "independent_from": ["frontend-dev", "backend-dev"],
      "evidence_ref": "walteur-kit/sdlc/qa-review-independence.txt"
    }
  },
  "signoff": {
    "required": true,
    "approver": "release-owner",
    "signoff_ref": "walteur-kit/sdlc/signoff.txt"
  },
  "retro": {
    "retro_ref": "walteur-kit/sdlc/retro.txt",
    "lessons_ref": "walteur-kit/sdlc/lessons.txt"
  },
  "metrics": {
    "total_agent_spawns": 6,
    "gate_failures": 0,
    "figure_it_out_recoveries": 1
  }
}
JSON
  }

  echo "sdlc-run-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "no phase and no sdlc-run.json -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "ship phase without sdlc-run.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  printf '{ bad json\n' > "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "invalid sdlc-run.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "valid SDLC run proof -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.stages[1].stage = "staging" | .stages[2].stage = "shared_dev"' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "wrong stage order -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq 'del(.stages[0].required_refs.tdd_ref)' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "missing local TDD ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.independence.code_review.reviewer_id = "frontend-dev"' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "reviewer overlaps builder -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  rm -f "$tmp/walteur-kit/sdlc/qa.txt"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "missing staging QA evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq 'del(.stages[3].required_refs.signoff_ref)' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "missing beta signoff ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.stages[4].verdict = "FAIL"' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "non-PASS production stage -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp" "2000-01-01"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "stale SDLC run proof -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.stages[4].required_refs.deploy_ref = "../outside.txt"' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "unsafe evidence ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  WALTEUR_ROOT="$tmp" WALTEUR_SDLC_RUN=off bash "$self_path" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"; touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "sdlc-run-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

if [ -f "$KIT/PAUSED" ]; then
  write_report "FAIL" "walteur-kit/PAUSED present" '{"paused":true}'
  echo "sdlc-run-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
fi

if [ "${WALTEUR_SDLC_RUN:-on}" = "off" ]; then
  write_report "SKIP" "bypassed via WALTEUR_SDLC_RUN=off" '{"bypassed":true}'
  echo "sdlc-run-gate verdict: SKIP - bypassed -> $REPORT" >&2
  exit 0
fi

for t in jq date; do
  if ! have "$t"; then
    write_report "SKIP" "$t not installed" "$(printf '{"missing_tool":"%s"}' "$t")"
    echo "sdlc-run-gate SKIP - required tool '$t' not installed." >&2
    exit 0
  fi
done

detect_required

if [ ! -f "$PROOF" ]; then
  if [ "$SDLC_REQUIRED" -eq 1 ]; then
    details="$(jq -n --arg reason "$SDLC_REQUIRED_REASON" '{required_reason:$reason}')"
    write_report "FAIL" "sdlc-run.json missing for ship/reflect phase" "$details"
    echo "sdlc-run-gate verdict: FAIL - missing sdlc-run.json -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "no sdlc-run.json and no ship/reflect requirement" '{"required":false}'
  echo "sdlc-run-gate verdict: NOT_APPLICABLE - no required SDLC run proof -> $REPORT" >&2
  exit 0
fi

if ! jq -e . "$PROOF" >/dev/null 2>&1; then
  write_report "FAIL" "sdlc-run.json is not valid JSON" "{}"
  echo "sdlc-run-gate verdict: FAIL - invalid JSON -> $REPORT" >&2
  exit 2
fi

shape_err="$(jq -r '
  def err(c;m): if c then m else empty end;
  def nonempty($x): ($x|type) == "string" and ($x|length) > 0;
  def ref_at($i;$k): (.stages[$i].required_refs[$k] // "");
  def covers_builders($review):
    (.participants.builder_ids // []) as $builders
    | ($review.independent_from // []) as $ind
    | all($builders[]?; . as $b | ($ind | index($b)) != null);
  . as $doc
  | [
      err($doc.schema_version != 1; "schema_version must be 1"),
      err((nonempty($doc.run_id)|not); "run_id must be non-empty"),
      err(($doc.run_date|type)!="string" or ($doc.run_date|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")|not); "run_date must be YYYY-MM-DD"),
      err(($doc.build_class as $v | ["software","workflow","data-ai","cloud-iac","mixed"] | index($v) | not); "build_class must be software/workflow/data-ai/cloud-iac/mixed"),
      err(($doc.risk_tier as $v | ["low","medium","high","regulated"] | index($v) | not); "risk_tier must be low/medium/high/regulated"),
      err($doc.verdict != "PASS"; "top-level verdict must be PASS"),
      err(($doc.participants.builder_ids|type)!="array" or ($doc.participants.builder_ids|length)<1; "participants.builder_ids must contain at least one builder"),
      err((($doc.participants.builder_ids // []) | length) != ((($doc.participants.builder_ids // []) | unique) | length); "participants.builder_ids must be unique"),
      err(($doc.participants.reviewer_ids|type)!="array" or ($doc.participants.reviewer_ids|length)<3; "participants.reviewer_ids must contain code, security, and QA reviewers"),
      err((nonempty($doc.participants.release_owner)|not); "participants.release_owner must be non-empty"),
      err(($doc.stages|type)!="array" or ($doc.stages|length)!=5; "stages must contain exactly five stages"),
      err((($doc.stages|type)=="array" and ($doc.stages|length)==5 and ([$doc.stages[].stage] != ["local_build","shared_dev","staging","beta","production"])); "stages must be ordered local_build -> shared_dev -> staging -> beta -> production"),
      err(any($doc.stages[]?; .verdict != "PASS"); "every stage verdict must be PASS"),
      err(any($doc.stages[]?; (nonempty(.owner)|not) or (nonempty(.started_at)|not) or (nonempty(.completed_at)|not) or (.started_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")|not) or (.completed_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")|not) or (.completed_at < .started_at)); "every stage needs owner plus ordered UTC timestamps"),
      err(any($doc.stages[]?; (.gate_refs|type)!="array" or (.gate_refs|length)<1 or (.evidence_refs|type)!="array" or (.evidence_refs|length)<1 or (.required_refs|type)!="object"); "every stage needs gate_refs, evidence_refs, and required_refs"),
      err((($doc.stages|type)=="array" and ($doc.stages|length)==5 and ($doc.stages[0].completed_at > $doc.stages[1].started_at or $doc.stages[1].completed_at > $doc.stages[2].started_at or $doc.stages[2].completed_at > $doc.stages[3].started_at or $doc.stages[3].completed_at > $doc.stages[4].started_at)); "stage timestamps must preserve stage order"),
      err((nonempty(ref_at(0;"tdd_ref"))|not) or (nonempty(ref_at(0;"unit_ref"))|not) or (nonempty(ref_at(0;"lint_ref"))|not) or (nonempty(ref_at(0;"build_ref"))|not); "local_build requires tdd_ref, unit_ref, lint_ref, and build_ref"),
      err((nonempty(ref_at(1;"code_review_ref"))|not) or (nonempty(ref_at(1;"security_review_ref"))|not) or (nonempty(ref_at(1;"integration_ref"))|not); "shared_dev requires code_review_ref, security_review_ref, and integration_ref"),
      err((nonempty(ref_at(2;"qa_ref"))|not) or (nonempty(ref_at(2;"e2e_ref"))|not) or (nonempty(ref_at(2;"environment_parity_ref"))|not) or (nonempty(ref_at(2;"performance_ref"))|not); "staging requires qa_ref, e2e_ref, environment_parity_ref, and performance_ref"),
      err((nonempty(ref_at(3;"adversarial_ref"))|not) or (nonempty(ref_at(3;"accessibility_ref"))|not) or (nonempty(ref_at(3;"docs_ref"))|not) or (nonempty(ref_at(3;"rollback_ref"))|not) or (nonempty(ref_at(3;"signoff_ref"))|not); "beta requires adversarial_ref, accessibility_ref, docs_ref, rollback_ref, and signoff_ref"),
      err((nonempty(ref_at(4;"deploy_ref"))|not) or (nonempty(ref_at(4;"smoke_ref"))|not) or (nonempty(ref_at(4;"monitoring_ref"))|not) or (nonempty(ref_at(4;"rollback_trigger_ref"))|not); "production requires deploy_ref, smoke_ref, monitoring_ref, and rollback_trigger_ref"),
      err((nonempty($doc.independence.code_review.reviewer_id)|not) or (($doc.participants.builder_ids // []) | index($doc.independence.code_review.reviewer_id)) != null or (covers_builders($doc.independence.code_review)|not) or (nonempty($doc.independence.code_review.evidence_ref)|not); "code_review must be independent from every builder and have evidence_ref"),
      err((nonempty($doc.independence.security_review.reviewer_id)|not) or (($doc.participants.builder_ids // []) | index($doc.independence.security_review.reviewer_id)) != null or (covers_builders($doc.independence.security_review)|not) or (nonempty($doc.independence.security_review.evidence_ref)|not); "security_review must be independent from every builder and have evidence_ref"),
      err((nonempty($doc.independence.qa_review.reviewer_id)|not) or (($doc.participants.builder_ids // []) | index($doc.independence.qa_review.reviewer_id)) != null or (covers_builders($doc.independence.qa_review)|not) or (nonempty($doc.independence.qa_review.evidence_ref)|not); "qa_review must be independent from every builder and have evidence_ref"),
      err($doc.signoff.required != true or (nonempty($doc.signoff.approver)|not) or (nonempty($doc.signoff.signoff_ref)|not); "signoff.required must be true with approver and signoff_ref"),
      err((nonempty($doc.retro.retro_ref)|not) or (nonempty($doc.retro.lessons_ref)|not); "retro requires retro_ref and lessons_ref"),
      err(($doc.metrics.total_agent_spawns|type)!="number" or $doc.metrics.total_agent_spawns < 1; "metrics.total_agent_spawns must be >= 1"),
      err(($doc.metrics.gate_failures|type)!="number" or $doc.metrics.gate_failures < 0; "metrics.gate_failures must be >= 0"),
      err(($doc.metrics.figure_it_out_recoveries|type)!="number" or $doc.metrics.figure_it_out_recoveries < 0; "metrics.figure_it_out_recoveries must be >= 0")
    ] | map(select(. != null)) | .[]
' "$PROOF" 2>/dev/null)"

if [ -n "$shape_err" ]; then
  findings="$(printf '%s\n' "$shape_err" | jq -R -s 'split("\n") | map(select(length > 0)) | map({check:"shape", message:.})')"
  write_report "FAIL" "sdlc-run.json missing required SDLC run proof" "$(jq -n --argjson findings "$findings" '{findings:$findings}')"
  echo "sdlc-run-gate verdict: FAIL - missing required SDLC run proof -> $REPORT" >&2
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
  write_report "FAIL" "sdlc-run.json is stale" "$details"
  echo "sdlc-run-gate verdict: FAIL - stale proof -> $REPORT" >&2
  exit 2
fi

refs="$(jq -r '
  [
    (.stages[]?.gate_refs[]?),
    (.stages[]?.evidence_refs[]?),
    (.stages[]?.required_refs? | .[]?),
    .independence.code_review.evidence_ref,
    .independence.security_review.evidence_ref,
    .independence.qa_review.evidence_ref,
    .signoff.signoff_ref,
    .retro.retro_ref,
    .retro.lessons_ref
  ] | .[] | select(type == "string" and length > 0)
' "$PROOF")"

bad_refs=""
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    /*|*../*|../*) bad_refs="${bad_refs}${ref}: unsafe path"$'\n'; continue ;;
  esac
  path="$ROOT/$ref"
  if [ ! -f "$path" ]; then
    bad_refs="${bad_refs}${ref}: missing"$'\n'
  elif [ ! -s "$path" ]; then
    bad_refs="${bad_refs}${ref}: empty"$'\n'
  fi
done <<EOF
$refs
EOF

if [ -n "$bad_refs" ]; then
  findings="$(printf '%s' "$bad_refs" | jq -R -s 'split("\n") | map(select(length > 0)) | map({check:"evidence_ref", message:.})')"
  write_report "FAIL" "SDLC run evidence refs are missing, empty, or unsafe" "$(jq -n --argjson findings "$findings" '{findings:$findings}')"
  echo "sdlc-run-gate verdict: FAIL - evidence refs invalid -> $REPORT" >&2
  exit 2
fi

details="$(jq -n --arg run_date "$run_date" '{run_date:$run_date, stage_count:5}')"
write_report "PASS" "SDLC run proof passes" "$details"
echo "sdlc-run-gate verdict: PASS - SDLC run proof passes -> $REPORT" >&2
exit 0
