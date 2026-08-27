#!/usr/bin/env bash
# WALTEUR canonical-staging-lint - verifies staged runnable-kit adoption notes.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
STAGING="${WALTEUR_STAGING_DIR:-$KIT/canonical-kit-staging}"
REPORT="$KIT/canonical-staging-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

FALLBACK_REQUIRED_GATES=(
  build-contract-lint
  gate-registry-lint
  estimate-gate
  harness-state-lint
  phase-gate
  evidence-gate
  risk-acceptance-gate
  adr-gate
  prompt-refinement-gate
  delivery-orchestration-gate
  project-context-gate
  self-improvement-gate
  outcome-eval-gate
  qa-contract-gate
  skill-readiness
  docrun
  scoreboard-gate
  audit-contract-gate
)

RUNTIME_MARKERS=(
  build-contract.json
  gate-registry.json
  estimate.json
  autopilot/STATE.json
  prompt-refinement.json
  delivery-orchestration.json
  project-context.json
  self-improvement.json
  outcome-eval.json
  qa-report.json
  scoreboard.json
  audit.json
  build-contract-report.json
  gate-registry-report.json
  estimate-report.json
  prompt-refinement-report.json
  delivery-orchestration-report.json
  project-context-report.json
  self-improvement-report.json
  outcome-eval-report.json
  qa-contract-report.json
  scoreboard-report.json
  audit-contract-report.json
  harness-state-report.json
  phase-gate-report.json
  evidence-gate-report.json
  risk-acceptance-report.json
)

write_report() {
  verdict="$1"
  reason="$2"
  printf '{"verdict":"%s","ts":"%s","gate":"canonical-staging","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

failures=0
check_file() {
  rel="$1"
  if [ ! -f "$STAGING/$rel" ]; then
    echo "  FAIL - missing $rel" >&2
    failures=$((failures+1))
  fi
}

check_text() {
  rel="$1"; pattern="$2"; label="$3"
  if ! grep -Fq "$pattern" "$STAGING/$rel" 2>/dev/null; then
    echo "  FAIL - $label" >&2
    failures=$((failures+1))
  fi
}

load_required_gates() {
  REQUIRED_GATES=()
  if command -v jq >/dev/null 2>&1 && [ -f "$KIT/gate-registry.json" ]; then
    while IFS= read -r gate_id; do
      [ -n "$gate_id" ] && REQUIRED_GATES+=("$gate_id")
    done < <(jq -r '.requirements.all[]?' "$KIT/gate-registry.json" 2>/dev/null)
  fi
  if [ "${#REQUIRED_GATES[@]}" -eq 0 ]; then
    REQUIRED_GATES=("${FALLBACK_REQUIRED_GATES[@]}")
  fi
}

run_lint() {
  failures=0
  check_file "README.md"
  check_file "ship-gate.gate-registry.patch.md"
  check_file "walteur.gate-contract-state.md"

  load_required_gates
  for gate_id in "${REQUIRED_GATES[@]}"; do
    check_text "ship-gate.gate-registry.patch.md" "run_gate $gate_id.sh" "ship-gate patch must dispatch $gate_id"
    check_text "walteur.gate-contract-state.md" "$gate_id.sh" "orchestrator patch must run $gate_id"
  done

  for marker in "${RUNTIME_MARKERS[@]}"; do
    check_text "walteur.gate-contract-state.md" "$marker" "orchestrator patch must emit or verify $marker"
  done

  check_text "README.md" "ship-gate.gate-registry.patch.md" "README must list ship-gate patch"
  check_text "README.md" "walteur.gate-contract-state.md" "README must list orchestrator patch"

  if [ "$failures" -gt 0 ]; then
    write_report "FAIL" "$failures staging violation(s)"
    echo "canonical-staging-lint verdict: FAIL - $failures violation(s) -> $REPORT" >&2
    return 2
  fi
  write_report "PASS" "canonical staging notes contain required adoption markers"
  echo "canonical-staging-lint verdict: PASS -> $REPORT" >&2
  return 0
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

  echo "canonical-staging-lint selftest:"

  write_fixture() {
    fixture_root="$1"
    mode="$2"
    fixture_staging="$fixture_root/walteur-kit/canonical-kit-staging"
    mkdir -p "$fixture_staging"

    if [ "$mode" = "missing_readme_orchestrator" ]; then
      printf '%s\n' "ship-gate.gate-registry.patch.md" > "$fixture_staging/README.md"
    else
      printf '%s\n' "ship-gate.gate-registry.patch.md" "walteur.gate-contract-state.md" > "$fixture_staging/README.md"
    fi

    : > "$fixture_staging/ship-gate.gate-registry.patch.md"
    for gate_id in "${FALLBACK_REQUIRED_GATES[@]}"; do
      [ "$mode" = "missing_prompt_dispatch" ] && [ "$gate_id" = "prompt-refinement-gate" ] && continue
      printf 'run_gate %s.sh\n' "$gate_id" >> "$fixture_staging/ship-gate.gate-registry.patch.md"
    done

    : > "$fixture_staging/walteur.gate-contract-state.md"
    for gate_id in "${FALLBACK_REQUIRED_GATES[@]}"; do
      [ "$mode" = "missing_delivery_orchestrator_gate" ] && [ "$gate_id" = "delivery-orchestration-gate" ] && continue
      printf '%s.sh\n' "$gate_id" >> "$fixture_staging/walteur.gate-contract-state.md"
    done
    for marker in "${RUNTIME_MARKERS[@]}"; do
      [ "$mode" = "missing_self_improvement_runtime" ] && [ "$marker" = "self-improvement.json" ] && continue
      [ "$mode" = "missing_outcome_eval_report" ] && [ "$marker" = "outcome-eval-report.json" ] && continue
      printf '%s\n' "$marker" >> "$fixture_staging/walteur.gate-contract-state.md"
    done
  }

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/canonical-staging-selftest.XXXXXX")" || return 1
  write_fixture "$tmp" "complete"
  WALTEUR_ROOT="$tmp" WALTEUR_STAGING_DIR="$tmp/walteur-kit/canonical-kit-staging" bash "$0" >/dev/null 2>&1
  ck "complete staging notes -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/canonical-staging-selftest.XXXXXX")" || return 1
  write_fixture "$tmp" "missing_prompt_dispatch"
  WALTEUR_ROOT="$tmp" WALTEUR_STAGING_DIR="$tmp/walteur-kit/canonical-kit-staging" bash "$0" >/dev/null 2>&1
  ck "missing prompt-refinement dispatch -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/canonical-staging-selftest.XXXXXX")" || return 1
  write_fixture "$tmp" "missing_delivery_orchestrator_gate"
  WALTEUR_ROOT="$tmp" WALTEUR_STAGING_DIR="$tmp/walteur-kit/canonical-kit-staging" bash "$0" >/dev/null 2>&1
  ck "missing delivery-orchestration orchestrator gate -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/canonical-staging-selftest.XXXXXX")" || return 1
  write_fixture "$tmp" "missing_self_improvement_runtime"
  WALTEUR_ROOT="$tmp" WALTEUR_STAGING_DIR="$tmp/walteur-kit/canonical-kit-staging" bash "$0" >/dev/null 2>&1
  ck "missing self-improvement runtime file -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/canonical-staging-selftest.XXXXXX")" || return 1
  write_fixture "$tmp" "missing_outcome_eval_report"
  WALTEUR_ROOT="$tmp" WALTEUR_STAGING_DIR="$tmp/walteur-kit/canonical-kit-staging" bash "$0" >/dev/null 2>&1
  ck "missing outcome-eval report -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/canonical-staging-selftest.XXXXXX")" || return 1
  write_fixture "$tmp" "missing_readme_orchestrator"
  WALTEUR_ROOT="$tmp" WALTEUR_STAGING_DIR="$tmp/walteur-kit/canonical-kit-staging" bash "$0" >/dev/null 2>&1
  ck "missing README orchestrator listing -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "canonical-staging-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

run_lint
