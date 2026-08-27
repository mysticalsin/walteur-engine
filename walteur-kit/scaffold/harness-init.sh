#!/usr/bin/env bash
# WALTEUR harness-init - bootstrap the contract/state control surface for a build.
#
# Creates:
#   walteur-kit/self-heal.sh
#   walteur-kit/source-manifest.json
#   walteur-kit/SOURCE-ROUTER.md
#   walteur-kit/required-skills.json
#   walteur-kit/gate-registry.json
#   walteur-kit/build-contract.json
#   walteur-kit/enterprise-blueprint.json
#   walteur-kit/estimate.json
#   walteur-kit/autopilot/STATE.json
#   walteur-kit/debate/OPEN.json
#   LOG.md
#   signals/README.md
#   docs/README.md
#   domains/README.md
#
# Then runs the bootstrap-safe reconciliation subset:
#   build-contract-lint.sh
#   gate-registry-lint.sh
#   estimate-gate.sh
#   current-stack-gate.sh
#   harness-state-lint.sh
#   phase-gate.sh
#   evidence-gate.sh
#   risk-acceptance-gate.sh
#   adr-gate.sh
#   prompt-refinement-gate.sh
#   enterprise-blueprint-gate.sh
#   delivery-orchestration-gate.sh
#   project-context-gate.sh
#   source-use-gate.sh
#   loop-workspace-gate.sh
#   self-improvement-gate.sh
#   outcome-eval-gate.sh
#   definition-of-done-gate.sh
#   skill-readiness.sh
#   trace-mine.sh
#   release-ledger-lint.sh
# The generated build contract separately lists every selected spec-shipped
# gate hook in verification.commands; stage-blocking gates may fail until
# their required PLAN/VERIFY/SHIP artifacts exist.
set -uo pipefail

SRC_KIT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  bash walteur-kit/scaffold/harness-init.sh --goal "..." [options]

Options:
  --root DIR          Project root to initialize. Defaults to git top-level or cwd.
  --goal TEXT         Requested outcome. Required unless WALTEUR_GOAL is set.
  --class NAME        software | workflow | document | data-ai | cloud-iac | mixed. Default: software.
  --risk NAME         low | medium | high | regulated. Default: medium.
  --data NAME         public | internal | confidential | restricted | regulated. Default: internal.
  --owner TEXT        Primary user or owner. Default: User.
  --autonomy NAME     full_autopilot | pause_at_plan_and_audit | pause_at_review | pause_per_task.
  --no-run-gates      Write files without running the harness gates.
  --selftest          Run harness-init twin checks.
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }

fail() {
  echo "harness-init verdict: FAIL - $1" >&2
  exit 2
}

contains_line() {
  value="$1"
  allowed="$2"
  printf '%s\n' "$allowed" | grep -qxF "$value"
}

copy_template_if_absent() {
  src="$1"
  dst="$2"
  [ -f "$src" ] || fail "missing scaffold template: $src"
  if [ -e "$dst" ] && [ ! -f "$dst" ]; then
    fail "cannot write template over non-file path: $dst"
  fi
  if [ ! -e "$dst" ]; then
    cp -p "$src" "$dst" || fail "could not copy template to $dst"
  fi
}

selftest() {
  pass=0
  fail_count=0
  ck() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail_count=$((fail_count+1))
    fi
  }

  if ! have jq; then
    echo "harness-init selftest SKIP - jq not installed."
    return 0
  fi

  echo "harness-init selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-init-selftest.XXXXXX")" || return 1
  bash "$0" --root "$tmp" --goal "Build a verified support dashboard" --class software --risk medium --owner "Support lead" >/dev/null 2>&1
  ck "software medium scaffold -> PASS" 0 "$?"
  for f in \
    "$tmp/walteur-kit/self-heal.sh" \
	    "$tmp/walteur-kit/source-manifest.json" \
	    "$tmp/walteur-kit/SOURCE-ROUTER.md" \
	    "$tmp/walteur-kit/required-skills.json" \
	    "$tmp/walteur-kit/DEFINITION-OF-DONE.md" \
    "$tmp/LOG.md" \
    "$tmp/signals/README.md" \
    "$tmp/docs/README.md" \
    "$tmp/domains/README.md" \
    "$tmp/walteur-kit/gate-registry.json" \
    "$tmp/walteur-kit/model-routing.json" \
    "$tmp/walteur-kit/build-contract.json" \
    "$tmp/walteur-kit/enterprise-blueprint.json" \
    "$tmp/walteur-kit/estimate.json" \
    "$tmp/walteur-kit/autopilot/STATE.json" \
    "$tmp/walteur-kit/debate/OPEN.json" \
	    "$tmp/walteur-kit/build-contract-report.json" \
	    "$tmp/walteur-kit/gate-registry-report.json" \
	    "$tmp/walteur-kit/estimate-report.json" \
	    "$tmp/walteur-kit/current-stack-report.json" \
	    "$tmp/walteur-kit/harness-state-report.json" \
    "$tmp/walteur-kit/phase-gate-report.json" \
    "$tmp/walteur-kit/evidence-gate-report.json" \
    "$tmp/walteur-kit/risk-acceptance-report.json" \
    "$tmp/walteur-kit/adr-report.json" \
    "$tmp/walteur-kit/prompt-refinement-report.json" \
    "$tmp/walteur-kit/enterprise-blueprint-report.json" \
    "$tmp/walteur-kit/delivery-orchestration-report.json" \
    "$tmp/walteur-kit/project-context-report.json" \
    "$tmp/walteur-kit/source-use-report.json" \
    "$tmp/walteur-kit/loop-workspace-report.json" \
    "$tmp/walteur-kit/self-improvement-report.json" \
    "$tmp/walteur-kit/outcome-eval-report.json" \
    "$tmp/walteur-kit/definition-of-done-report.json" \
    "$tmp/walteur-kit/trace-mine-report.json" \
    "$tmp/walteur-kit/release-ledger-report.json" \
    "$tmp/walteur-kit/skill-readiness-report.json"
  do
    if [ -f "$f" ]; then
      echo "  ok   - ${f#"$tmp"/} exists"
      pass=$((pass+1))
    else
      echo "  FAIL - ${f#"$tmp"/} missing"
      fail_count=$((fail_count+1))
    fi
  done
  if grep -q '^## Entry Grammar' "$tmp/LOG.md"; then
    echo "  ok   - LOG.md has work-log entry grammar"
    pass=$((pass+1))
  else
    echo "  FAIL - LOG.md missing work-log entry grammar"
    fail_count=$((fail_count+1))
  fi
  if grep -q '^kind: signal' "$tmp/signals/README.md"; then
    echo "  ok   - signals README has signal frontmatter schema"
    pass=$((pass+1))
  else
    echo "  FAIL - signals README missing signal frontmatter schema"
    fail_count=$((fail_count+1))
  fi
  if grep -q '^kind: doc' "$tmp/docs/README.md"; then
    echo "  ok   - docs README has doc frontmatter schema"
    pass=$((pass+1))
  else
    echo "  FAIL - docs README missing doc frontmatter schema"
    fail_count=$((fail_count+1))
  fi
  if grep -q '^kind: domain' "$tmp/domains/README.md"; then
    echo "  ok   - domains README has domain frontmatter schema"
    pass=$((pass+1))
  else
    echo "  FAIL - domains README missing domain frontmatter schema"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="tool-readiness")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1; then
    echo "  ok   - medium risk selected tool-readiness"
    pass=$((pass+1))
  else
    echo "  FAIL - medium risk did not select tool-readiness"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="devenv-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="devenv-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - software selected devenv-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - software did not select devenv-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="config-validation")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="config-validation")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - software selected config-validation in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - software did not select config-validation in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="quickstart-check")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="quickstart-check")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - software selected quickstart-check in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - software did not select quickstart-check in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="nfr-lint")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="nfr-lint")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - software selected nfr-lint in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - software did not select nfr-lint in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="observe-lint")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="observe-lint")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - software selected observe-lint in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - software did not select observe-lint in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="perf-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="perf-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - software selected perf-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - software did not select perf-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="benchmark-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.verification.gates[] | select(.id=="product-standard-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="benchmark-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="product-standard-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - software selected benchmark-gate and product-standard-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - software did not select benchmark-gate and product-standard-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="production-layers-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="production-layers-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - software selected production-layers-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - software did not select production-layers-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="audit-contract-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="audit-contract-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected audit-contract-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select audit-contract-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="scoreboard-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="scoreboard-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected scoreboard-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select scoreboard-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="definition-of-done-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="definition-of-done-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected definition-of-done-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select definition-of-done-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
	  if jq -e '.verification.gates[] | select(.id=="estimate-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
	    && jq -e '.gates[] | select(.id=="estimate-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
	    echo "  ok   - baseline selected estimate-gate in contract and state"
	    pass=$((pass+1))
	  else
	    echo "  FAIL - baseline did not select estimate-gate in contract and state"
	    fail_count=$((fail_count+1))
	  fi
	  if jq -e '.verification.gates[] | select(.id=="current-stack-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
	    && jq -e '.gates[] | select(.id=="current-stack-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
	    echo "  ok   - baseline selected current-stack-gate in contract and state"
	    pass=$((pass+1))
	  else
	    echo "  FAIL - baseline did not select current-stack-gate in contract and state"
	    fail_count=$((fail_count+1))
	  fi
  if jq -e '.verification.gates[] | select(.id=="phase-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="phase-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected phase-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select phase-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="evidence-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="evidence-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected evidence-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select evidence-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="risk-acceptance-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="risk-acceptance-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected risk-acceptance-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select risk-acceptance-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="qa-contract-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="qa-contract-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected qa-contract-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select qa-contract-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="adr-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="adr-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1 \
    && jq -e 'type == "array" and length == 0' "$tmp/walteur-kit/debate/OPEN.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected adr-gate and initialized empty debate/OPEN.json"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select adr-gate or initialize empty debate/OPEN.json"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="self-improvement-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="self-improvement-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected self-improvement-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select self-improvement-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="prompt-refinement-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="prompt-refinement-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected prompt-refinement-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select prompt-refinement-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="enterprise-blueprint-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="enterprise-blueprint-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1 \
    && jq -e '.artifact_map | length >= 2' "$tmp/walteur-kit/enterprise-blueprint.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected enterprise-blueprint-gate and generated concrete blueprint"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select enterprise-blueprint-gate or generate concrete blueprint"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="delivery-orchestration-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="delivery-orchestration-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected delivery-orchestration-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select delivery-orchestration-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="project-context-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="project-context-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected project-context-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select project-context-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="source-use-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="source-use-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected source-use-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select source-use-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="loop-workspace-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="loop-workspace-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected loop-workspace-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select loop-workspace-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="outcome-eval-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="outcome-eval-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected outcome-eval-gate in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select outcome-eval-gate in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="trace-mine")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="trace-mine")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected trace-mine in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select trace-mine in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="release-ledger-lint")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="release-ledger-lint")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected release-ledger-lint in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select release-ledger-lint in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.gates[] | select(.id=="skill-readiness")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="skill-readiness")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - baseline selected skill-readiness in contract and state"
    pass=$((pass+1))
  else
    echo "  FAIL - baseline did not select skill-readiness in contract and state"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verdict=="PASS"' "$tmp/walteur-kit/skill-readiness-report.json" >/dev/null 2>&1; then
    echo "  ok   - generated skill-readiness report is PASS, not SKIP"
    pass=$((pass+1))
  else
    echo "  FAIL - generated skill-readiness report did not PASS"
    fail_count=$((fail_count+1))
  fi
  missing_command_coverage="$(jq -r --slurpfile registry "$tmp/walteur-kit/gate-registry.json" '
    ([.verification.commands[]?.command] | join("\n")) as $commands
    | ($registry[0].gates | map({(.id): .}) | add) as $by_id
    | [
        .verification.gates[]
        | $by_id[.id] as $gate
        | select($gate.availability == "spec")
        | select(($commands | contains($gate.hook)) | not)
        | $gate.id
      ]
    | join(", ")
  ' "$tmp/walteur-kit/build-contract.json")"
  if [ -z "$missing_command_coverage" ]; then
    echo "  ok   - generated verification command covers every selected spec-shipped gate"
    pass=$((pass+1))
  else
    echo "  FAIL - generated verification command missing selected gates: $missing_command_coverage"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.recovery_policy.posture=="i_will_figure_it_out" and .recovery_policy.paths_required==3 and (.recovery_policy.dimensions_required | length >= 6)' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - state includes figure-it-out recovery policy"
    pass=$((pass+1))
  else
    echo "  FAIL - state missing figure-it-out recovery policy"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.context_sentinel.user_name=="Tony" and .context_sentinel.response_prefix=="Tony," and .context_sentinel.every_response==true and .context_sentinel.missing_prefix_action=="compact_and_resume"' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - state includes Tony response-prefix context sentinel"
    pass=$((pass+1))
  else
    echo "  FAIL - state missing Tony response-prefix context sentinel"
    fail_count=$((fail_count+1))
  fi
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-init-selftest.XXXXXX")" || return 1
  bash "$0" --root "$tmp" --goal "Prepare a regulated AI claims agent" --class data-ai --risk regulated --data regulated >/dev/null 2>&1
  ck "regulated data-ai scaffold -> PASS" 0 "$?"
  if jq -e '.verification.gates[] | select(.id=="ai-safety-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.verification.gates[] | select(.id=="compliance-gate")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1 \
    && jq -e '.gates[] | select(.id=="audit-gate")' "$tmp/walteur-kit/autopilot/STATE.json" >/dev/null 2>&1; then
    echo "  ok   - regulated data-ai selected AI, compliance, and audit gates"
    pass=$((pass+1))
  else
    echo "  FAIL - regulated data-ai gate selection incomplete"
    fail_count=$((fail_count+1))
  fi
  if jq -e '.verification.manual_checks[] | contains("audit-gate") and contains("ship-gate.sh")' "$tmp/walteur-kit/build-contract.json" >/dev/null 2>&1; then
    echo "  ok   - canonical audit-gate is covered by manual check"
    pass=$((pass+1))
  else
    echo "  FAIL - canonical audit-gate missing manual coverage"
    fail_count=$((fail_count+1))
  fi
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-init-selftest.XXXXXX")" || return 1
  bash "$0" --root "$tmp" --goal "bad class" --class vibes >/dev/null 2>&1
  ck "invalid build class -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "harness-init selftest: $pass/$((pass+fail_count)) passed"
  [ "$fail_count" -eq 0 ]
}

ROOT="${WALTEUR_ROOT:-}"
GOAL="${WALTEUR_GOAL:-}"
BUILD_CLASS="${WALTEUR_BUILD_CLASS:-software}"
RISK_TIER="${WALTEUR_RISK_TIER:-medium}"
DATA_CLASSIFICATION="${WALTEUR_DATA_CLASSIFICATION:-internal}"
OWNER="${WALTEUR_OWNER:-User}"
AUTONOMY_POLICY="${WALTEUR_AUTONOMY_POLICY:-full_autopilot}"
RUN_GATES=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || fail "--root requires a value"
      ROOT="$2"; shift 2 ;;
    --goal)
      [ "$#" -ge 2 ] || fail "--goal requires a value"
      GOAL="$2"; shift 2 ;;
    --class)
      [ "$#" -ge 2 ] || fail "--class requires a value"
      BUILD_CLASS="$2"; shift 2 ;;
    --risk)
      [ "$#" -ge 2 ] || fail "--risk requires a value"
      RISK_TIER="$2"; shift 2 ;;
    --data)
      [ "$#" -ge 2 ] || fail "--data requires a value"
      DATA_CLASSIFICATION="$2"; shift 2 ;;
    --owner)
      [ "$#" -ge 2 ] || fail "--owner requires a value"
      OWNER="$2"; shift 2 ;;
    --autonomy)
      [ "$#" -ge 2 ] || fail "--autonomy requires a value"
      AUTONOMY_POLICY="$2"; shift 2 ;;
    --no-run-gates)
      RUN_GATES=0; shift ;;
    --selftest)
      selftest
      exit $? ;;
    -h|--help)
      usage
      exit 0 ;;
    *)
      fail "unknown argument: $1" ;;
  esac
done

[ -n "$GOAL" ] || { usage >&2; fail "--goal is required"; }

contains_line "$BUILD_CLASS" "software
workflow
document
data-ai
cloud-iac
mixed" || fail "invalid --class '$BUILD_CLASS'"

contains_line "$RISK_TIER" "low
medium
high
regulated" || fail "invalid --risk '$RISK_TIER'"

contains_line "$DATA_CLASSIFICATION" "public
internal
confidential
restricted
regulated" || fail "invalid --data '$DATA_CLASSIFICATION'"

contains_line "$AUTONOMY_POLICY" "full_autopilot
pause_at_plan_and_audit
pause_at_review
pause_per_task" || fail "invalid --autonomy '$AUTONOMY_POLICY'"

if ! have jq; then
  fail "jq is required to generate typed harness JSON"
fi

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
mkdir -p "$ROOT" || fail "could not create root: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT/hooks" "$KIT/schemas" "$KIT/scaffold" "$KIT/autopilot" "$KIT/debate" "$KIT/adr" "$ROOT/signals" "$ROOT/docs" "$ROOT/domains" || fail "could not create walteur-kit folders"

if [ "$SRC_KIT" != "$KIT" ]; then
  cp -p "$SRC_KIT/gate-registry.json" "$KIT/gate-registry.json" || fail "could not copy gate-registry.json"
  cp -p "$SRC_KIT/model-routing.json" "$KIT/model-routing.json" || fail "could not copy model-routing.json"
  [ -f "$SRC_KIT/skill-index.json" ] && cp -p "$SRC_KIT/skill-index.json" "$KIT/skill-index.json"
  cp -p "$SRC_KIT/self-heal.sh" "$KIT/self-heal.sh" || fail "could not copy self-heal.sh"
  cp -p "$SRC_KIT/source-manifest.json" "$KIT/source-manifest.json" || fail "could not copy source-manifest.json"
  cp -p "$SRC_KIT/SOURCE-ROUTER.md" "$KIT/SOURCE-ROUTER.md" || fail "could not copy SOURCE-ROUTER.md"
  chmod +x "$KIT/self-heal.sh" 2>/dev/null || fail "could not make self-heal.sh executable"
  # Only distribute hooks the registry marks as "spec" or "optional". A
  # "canonical" hook (e.g. ship-gate.sh) is deliberately kept out of every
  # scaffold: it lives in the canonical kit only, and build-contract-lint's
  # command/manual-coverage split depends on its absence here (see
  # HARNESS-LOOP.md: "does not make absent canonical-kit hooks pretend to
  # exist").
  canonical_hooks="$(jq -r '.gates[] | select(.availability=="canonical") | .hook' "$SRC_KIT/gate-registry.json" 2>/dev/null)"
  for hookfile in "$SRC_KIT/hooks/"*.sh; do
    hookbase="$(basename "$hookfile")"
    if printf '%s\n' "$canonical_hooks" | grep -qxF "$hookbase"; then
      continue
    fi
    cp -p "$hookfile" "$KIT/hooks/" || fail "could not copy hook: $hookbase"
  done
  cp -p "$SRC_KIT/hooks/"*.mjs "$KIT/hooks/" 2>/dev/null || true
  cp -p "$SRC_KIT/schemas/"*.schema.json "$KIT/schemas/" || fail "could not copy schemas"
	  cp -p "$SRC_KIT/scaffold/build-contract.template.json" "$KIT/scaffold/build-contract.template.json" || fail "could not copy build-contract template"
	  cp -p "$SRC_KIT/scaffold/layers.template.json" "$KIT/scaffold/layers.template.json" || fail "could not copy layers template"
	  cp -p "$SRC_KIT/scaffold/required-skills.template.json" "$KIT/scaffold/required-skills.template.json" || fail "could not copy required-skills template"
	  cp -p "$SRC_KIT/scaffold/security-baseline.template.json" "$KIT/scaffold/security-baseline.template.json" 2>/dev/null || true
	fi

copy_template_if_absent "$SRC_KIT/scaffold/required-skills.template.json" "$KIT/required-skills.json"
copy_template_if_absent "$SRC_KIT/DEFINITION-OF-DONE.md" "$KIT/DEFINITION-OF-DONE.md"
copy_template_if_absent "$SRC_KIT/scaffold/loop-workspace/LOG.md" "$ROOT/LOG.md"
copy_template_if_absent "$SRC_KIT/scaffold/loop-workspace/signals/README.md" "$ROOT/signals/README.md"
copy_template_if_absent "$SRC_KIT/scaffold/loop-workspace/docs/README.md" "$ROOT/docs/README.md"
copy_template_if_absent "$SRC_KIT/scaffold/loop-workspace/domains/README.md" "$ROOT/domains/README.md"

REGISTRY="$KIT/gate-registry.json"
CONTRACT="$KIT/build-contract.json"
BLUEPRINT="$KIT/enterprise-blueprint.json"
ESTIMATE="$KIT/estimate.json"
STATE="$KIT/autopilot/STATE.json"
OPEN="$KIT/debate/OPEN.json"
REPORT="$KIT/harness-init-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
slug="$(printf '%s' "$GOAL" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-48)"
[ -n "$slug" ] || slug="build"
contract_id="walteur-${slug}-$(date -u +%Y%m%d%H%M%S)"

gates_json="$(jq -c --arg c "$BUILD_CLASS" --arg r "$RISK_TIER" '
  ((.requirements.all // []) + (.requirements.by_build_class[$c] // []) + (.requirements.by_risk_tier[$r] // []) | unique) as $ids
  | [.gates[] | select(.id as $id | $ids | index($id)) | {
      id,
      stage,
      hardness,
      expected_evidence: .evidence
    }]
' "$REGISTRY")" || fail "could not derive required gates from registry"

gate_count="$(printf '%s' "$gates_json" | jq 'length')"
[ "$gate_count" -gt 0 ] || fail "registry selected no gates"

commands_json="$(jq -n -c --argjson gates "$gates_json" --slurpfile registry "$REGISTRY" '
  ($registry[0].gates | map({(.id): .}) | add) as $by_id
  | [
      $gates[]
      | $by_id[.id]
      | select(.availability == "spec")
      | "bash walteur-kit/hooks/" + .hook
    ] as $commands
  | if ($commands | length) > 0 then
      [{
        command: ($commands | join(" && ")),
        purpose: "Run every selected spec-shipped gate hook in registry order; stage-blocking gates may fail until their required artifacts exist."
      }]
    else
      []
    end
' "$REGISTRY")" || fail "could not derive verification commands from registry"

manual_checks_json="$(jq -n -c --argjson gates "$gates_json" --slurpfile registry "$REGISTRY" '
  ($registry[0].gates | map({(.id): .}) | add) as $by_id
  | ["Read every selected gate report before claiming completion."]
    + [
        $gates[]
        | $by_id[.id]
        | select(.availability != "spec")
        | "Selected gate " + .id + " uses " + .hook + " (" + .availability + "); run it in the canonical kit or attach signed evidence before ship."
      ]
')" || fail "could not derive verification manual checks from registry"

jq -n \
  --arg contract_id "$contract_id" \
  --arg goal "$GOAL" \
  --arg owner "$OWNER" \
  --arg build_class "$BUILD_CLASS" \
  --arg risk_tier "$RISK_TIER" \
  --arg data_classification "$DATA_CLASSIFICATION" \
  --arg created_at "$TS" \
  --argjson gates "$gates_json" \
  --argjson commands "$commands_json" \
  --argjson manual_checks "$manual_checks_json" \
  '{
    schema_version: 1,
    contract_id: $contract_id,
    request: {
      summary: $goal,
      user_outcome: ("Deliver verified outcome: " + $goal),
      primary_user: $owner,
      non_goals: ["Do not expand beyond the stated outcome without approval."]
    },
    build_class: $build_class,
    risk_tier: $risk_tier,
    data_classification: $data_classification,
    success_metrics: [
      {
        name: "Outcome verified",
        target: "The requested outcome is satisfied by fresh evidence.",
        check: "Run the verification gates listed in this contract and read their reports."
      }
    ],
    constraints: [
      {
        id: "scope-1",
        kind: "business",
        description: "Keep the first delivery to the smallest useful slice that proves the outcome.",
        status: "active"
      }
    ],
    interfaces: [
      {
        name: "Primary deliverable",
        type: (if $build_class == "workflow" then "workflow" elif $build_class == "document" then "document" elif $build_class == "data-ai" then "agent" elif $build_class == "cloud-iac" then "external-service" else "ui" end),
        owner: $owner,
        contract: "The delivered artifact must expose the requested outcome with a clear verification path."
      }
    ],
    verification: {
      gates: $gates,
      commands: $commands,
      manual_checks: $manual_checks
    },
    evidence_required: [
      "Gate reports",
      "Fresh verification output",
      "Known gaps or accepted risks"
    ],
    unknowns: [
      {
        question: "Which domain-specific constraints or owners must be added before build starts?",
        owner: $owner,
        resolution_status: "open"
      }
    ],
    created_at: $created_at
  }' > "$CONTRACT" || fail "could not write build-contract.json"

jq -n \
  --arg blueprint_id "$contract_id-blueprint" \
  --arg goal "$GOAL" \
  --arg owner "$OWNER" \
  --arg build_class "$BUILD_CLASS" \
  --arg risk_tier "$RISK_TIER" \
  --arg ts "$TS" \
  '
    def deliverable_type($c):
      if $c == "workflow" then "workflow"
      elif $c == "document" then "document"
      elif $c == "data-ai" then "ai"
      elif $c == "cloud-iac" then "iac"
      else "ui" end;
    {
      schema_version: 1,
      blueprint_id: $blueprint_id,
      raw_goal: $goal,
      enterprise_goal: ("Deliver a concrete, verified " + $build_class + " outcome for: " + $goal + ". The first slice must name the user, surfaces, proof, owner, trust controls, recovery path, and final handoff."),
      primary_user: {
        role: $owner,
        pain: "The requested outcome is not yet captured as a concrete workflow, surface, proof path, and owner model.",
        success_moment: "The owner can inspect the delivered artifact, run the listed checks, and decide the next action without rediscovery."
      },
      owner_or_buyer: {
        role: $owner,
        decision_metric: "The requested outcome is accepted only after the gate reports and final delivery packet prove the agreed behavior."
      },
      job_map: [
        {
          job: "Turn the raw request into a verified deliverable",
          current_workaround: "Rely on a loose prompt, ad-hoc checks, or a generic scaffold that does not name concrete proof.",
          desired_outcome: "Work from a typed blueprint that names artifacts, acceptance criteria, trust controls, operations, cuts, and proof refs."
        }
      ],
      artifact_map: [
        {
          artifact: "Primary deliverable",
          type: deliverable_type($build_class),
          purpose: "Expose the requested outcome through the smallest useful artifact that can be verified.",
          owner: $owner,
          done_when: "The artifact satisfies the acceptance suite and its evidence refs are read before completion.",
          evidence_ref: "walteur-kit/build-contract.json#request"
        },
        {
          artifact: "Verification and handoff packet",
          type: "test",
          purpose: "Prove the delivery works and make the result reviewable by the owner.",
          owner: $owner,
          done_when: "The final response includes what changed, how to use it, proof read, known gaps, rollback or recovery, and next action.",
          evidence_ref: "walteur-kit/build-contract.json#verification"
        }
      ],
      surface_map: {
        ui: (if $build_class == "software" or $build_class == "mixed" then ["Primary user surface"] else [] end),
        api: (if $build_class == "software" or $build_class == "mixed" then ["Declared integration contract when applicable"] else [] end),
        data: ["Inputs, outputs, data class, and evidence refs named in the build contract"],
        jobs: ["Plan, verify, review, ship, and reflect stage work"],
        docs: ["Build contract", "Final delivery packet"],
        ops: ["Owner", "rollback or recovery path", "known gaps review"]
      },
      acceptance_suite: [
        {
          id: "AC-001",
          statement: "The primary deliverable satisfies the raw user outcome without expanding beyond approved scope.",
          verification: "Read the build contract and final gate reports before claiming completion.",
          evidence_ref: "walteur-kit/build-contract.json#request"
        },
        {
          id: "AC-002",
          statement: "The verification path includes fresh command, report, screenshot, audit, or signed evidence appropriate to the build class.",
          verification: "Run the selected registry gates and inspect their report files.",
          evidence_ref: "walteur-kit/build-contract.json#verification"
        },
        {
          id: "AC-003",
          statement: "The final handoff names what changed, how to use it, proof read, known gaps, rollback or recovery, and next action.",
          verification: "Compare the final delivery packet against this blueprint and the definition of done.",
          evidence_ref: "walteur-kit/build-contract.json#evidence_required"
        }
      ],
      trust_model: {
        authn: "Use the target project identity boundary or record why authentication is not applicable to this slice.",
        authz: "Deny by default for restricted actions and record role or owner boundaries before ship.",
        data_policy: "Respect the declared data classification and avoid logging secrets or personal data in proof artifacts.",
        privacy: "Use redacted or synthetic evidence when screenshots, logs, or examples could expose sensitive data.",
        security: "Run selected security, dependency, tool, and configuration checks before release where applicable.",
        auditability: "Every PASS claim cites a report, command output, local artifact, or signed manual evidence."
      },
      operating_model: {
        observability: "Name logs, metrics, traces, reports, or manual checks that prove the artifact remains understandable after handoff.",
        support: "Name the owner who receives questions and the path for defects or unresolved gaps.",
        rollback: "Name how to revert, disable, restore, or replace the artifact if the delivery is wrong.",
        incident_response: "Record the escalation trigger for failures that affect users, data, production, or external commitments.",
        ownership: "The build owner accepts scope, cuts, proof standards, and next action before ship."
      },
      quality_bar: {
        must_feel_like: "A specific, owner-ready delivery with concrete surfaces, commands, proof, and recovery path.",
        must_not_feel_like: "A generic scaffold, vague recommendation, proof-free summary, or ceremony that hides missing decisions.",
        reference_quality: "The standard is a staff-engineer handoff: narrow scope, clear owner, fresh evidence, explicit risk, and readable next step.",
        concreteness_floor: "Every meaningful claim names a user, artifact, acceptance criterion, control, command, or evidence reference."
      },
      explicit_cuts: [
        {
          item: "Unapproved scope expansion",
          reason: "The first delivery must prove the stated outcome before adding adjacent features or speculative polish.",
          risk: "Some desirable follow-up work remains outside this run and must be named in known gaps.",
          review_trigger: "Revisit when the owner accepts the verified first slice or changes the outcome."
        }
      ],
      final_delivery_packet: {
        must_include: [
          "what changed",
          "how to use it",
          "files changed",
          "commands run",
          "proof read",
          "known gaps",
          "rollback or recovery",
          "next action"
        ]
      },
      ts: $ts
    }
  ' > "$BLUEPRINT" || fail "could not write enterprise-blueprint.json"

jq -n \
  --arg estimate_id "$contract_id-estimate" \
  --arg goal "$GOAL" \
  --arg created_at "$TS" \
  '{
    schema_version: 1,
    estimate_id: $estimate_id,
    goal: $goal,
    phase: "intake",
    minutes: { best: 0, expected: 0, worst: 0 },
    tokens: { best: 0, expected: 0, worst: 0, input: 0, output: 0 },
    usd: { best: 0, expected: 0, worst: 0 },
    assumptions: [
      "Initial intake estimate. Replace expected values before plan or build work starts."
    ],
    created_at: $created_at
  }' > "$ESTIMATE" || fail "could not write estimate.json"

state_gates_json="$(printf '%s' "$gates_json" | jq -c --arg owner "$OWNER" --arg ts "$TS" '
  map({
    id,
    stage,
    status: "SKIP",
    reason: "Initial scaffold; evidence pending.",
    owner: $owner,
    timestamp: $ts
  })
')"

jq -n \
  --arg run_id "$contract_id" \
  --arg goal "$GOAL" \
  --arg owner "$OWNER" \
  --arg build_class "$BUILD_CLASS" \
  --arg risk_tier "$RISK_TIER" \
  --arg autonomy_policy "$AUTONOMY_POLICY" \
  --arg updated_at "$TS" \
  --argjson gates "$state_gates_json" \
  '{
    schema_version: 1,
    run_id: $run_id,
    goal: $goal,
    owner: $owner,
    build_class: $build_class,
    risk_tier: $risk_tier,
    phase: "intake",
    autonomy_policy: $autonomy_policy,
    recovery_policy: {
      posture: "i_will_figure_it_out",
      obstacle_trigger: "At every blocker, tool failure, missing input, contradiction, or stalled stage.",
      paths_required: 3,
      dimensions_required: ["what", "artefact", "assumption", "cost", "failure_mode", "validation"],
      decision_log_path: "walteur-kit/figure-it-out.jsonl",
      validation_required: true,
      escalation_rule: "Escalate only after three paths are scored, one path is chosen, validation fails, and the escalation question is specific."
    },
    context_sentinel: {
      user_name: "Tony",
      response_prefix: "Tony,",
      every_response: true,
      missing_prefix_action: "compact_and_resume",
      compaction_target: "_relay/BATON.md",
      baton_path: "_relay/BATON.md",
      degradation_signal: "If a WALTEUR agent stops starting responses with Tony, treat it as context drift and compact before continuing."
    },
    budgets: {
      time_minutes: 0,
      input_tokens: 0,
      output_tokens: 0,
      cost_usd: 0
    },
    protected_paths: [
      { path: "walteur-kit/build-contract.json", reason: "Typed promise for the run" },
      { path: "walteur-kit/estimate.json", reason: "Pre-build budget discipline" },
      { path: "walteur-kit/autopilot/STATE.json", reason: "Runtime control surface" },
      { path: "walteur-kit/debate/OPEN.json", reason: "Open fork control surface" }
    ],
    stages: [
      { name: "intake", status: "in_progress", owner: $owner },
      { name: "discover", status: "not_started", owner: $owner },
      { name: "plan", status: "not_started", owner: $owner },
      { name: "build", status: "not_started", owner: $owner },
      { name: "verify", status: "not_started", owner: $owner },
      { name: "review", status: "not_started", owner: $owner },
      { name: "ship", status: "not_started", owner: $owner },
      { name: "reflect", status: "not_started", owner: $owner }
    ],
    gates: $gates,
    evidence: [],
    signoffs: [],
    authority_boundaries: [],
    decisions: [
      {
        decision: ("Classified request as " + $build_class + " with " + $risk_tier + " risk."),
        why: "harness-init received explicit inputs or safe defaults.",
        owner: $owner,
        timestamp: $updated_at
      }
    ],
    blockers: [],
    known_gaps: [
      {
        gap: "Domain-specific success metrics, owners, and stage-specific evidence still need review before build.",
        severity: "medium",
        owner: $owner
      }
    ],
    next_action: "Review build-contract.json, resolve unknowns, then advance to discover or plan.",
    baton_path: "walteur-kit/autopilot/STATE.json",
    updated_at: $updated_at
  }' > "$STATE" || fail "could not write STATE.json"

printf '[]\n' > "$OPEN" || fail "could not write debate/OPEN.json"

if [ "$RUN_GATES" -eq 1 ]; then
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/build-contract-lint.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/gate-registry-lint.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/estimate-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/current-stack-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/harness-state-lint.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/phase-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/evidence-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/risk-acceptance-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/adr-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/prompt-refinement-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/enterprise-blueprint-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/delivery-orchestration-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/project-context-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/source-use-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/loop-workspace-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/self-improvement-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/outcome-eval-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/definition-of-done-gate.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/skill-readiness.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/trace-mine.sh" >/dev/null || exit $?
  WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/release-ledger-lint.sh" >/dev/null || exit $?
fi

jq -n --arg ts "$TS" --arg root "$ROOT" --arg class "$BUILD_CLASS" --arg risk "$RISK_TIER" --argjson gate_count "$gate_count" '{
  verdict: "PASS",
  ts: $ts,
  gate: "harness-init",
  root: $root,
  build_class: $class,
  risk_tier: $risk,
  required_gate_count: $gate_count,
  files: [
    "walteur-kit/self-heal.sh",
    "walteur-kit/source-manifest.json",
    "walteur-kit/SOURCE-ROUTER.md",
    "walteur-kit/DEFINITION-OF-DONE.md",
    "walteur-kit/gate-registry.json",
    "walteur-kit/model-routing.json",
    "walteur-kit/build-contract.json",
    "walteur-kit/enterprise-blueprint.json",
    "walteur-kit/estimate.json",
    "walteur-kit/autopilot/STATE.json",
    "walteur-kit/debate/OPEN.json",
    "LOG.md",
    "signals/README.md",
    "docs/README.md",
    "domains/README.md"
  ]
}' > "$REPORT" || true

echo "harness-init verdict: PASS - wrote contract, registry, estimate, state, and fork control for $BUILD_CLASS/$RISK_TIER -> ${REPORT#"$ROOT"/}" >&2
exit 0
