#!/usr/bin/env bash
# run-gates.sh — drive the 8 WALTEUR proof gates against this build with the EXEC flags armed.
# Exports WALTEUR_ROOT, the per-gate *_EXEC flags (so denials are OBSERVED by execution, not shape-only),
# and WALTEUR_TENANT_TOKENS (env-injected; NO token VALUES are committed anywhere). Prints each gate's
# verdict line + exit code. Usage:  bash ops/run-gates.sh   (run from $ROOT or anywhere)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$(cd "$ROOT/../../.." && pwd)/walteur-kit/hooks"   # Pro Coding/walteur-kit/hooks
if [ ! -d "$HOOKS" ]; then
  # fall back to a search if the relative layout differs
  HOOKS="$(find "$(cd "$ROOT/../../.." && pwd)" -maxdepth 3 -type d -name hooks -path '*walteur-kit*' 2>/dev/null | head -1)"
fi

export WALTEUR_ROOT="$ROOT"
export WALTEUR_AUTHZ_TENANT_EXEC=1
export WALTEUR_PRIVACY_EXEC=1
export WALTEUR_SDLC_EXEC=1
export WALTEUR_AUDIT_EXEC=1
export WALTEUR_CUTOVER_EXEC=1
export WALTEUR_CUTOVER_REQUIRED=1
# env-injected tenant tokens (short, low-entropy on purpose; never written to any file)
export WALTEUR_TENANT_TOKENS='{"tenantA":"tokA","tenantB":"tokB"}'

echo "WALTEUR_ROOT=$WALTEUR_ROOT"
echo "hooks=$HOOKS"
echo

declare -a GATES=(
  "authz-tenant-gate.sh"
  "privacy-data-gate.sh"
  "sdlc-run-gate.sh"
  "audit-contract-gate.sh"
  "zero-downtime-cutover-gate.sh"
  "chaos-resilience-gate.sh"
  "secret-rotation-gate.sh"
  "slo-error-budget-gate.sh"
)

overall=0
for g in "${GATES[@]}"; do
  if [ ! -f "$HOOKS/$g" ]; then
    printf '%-34s SKIP (gate not found)\n' "$g"
    continue
  fi
  out="$(bash "$HOOKS/$g" "$ROOT" 2>&1)"; rc=$?
  verdict="$(printf '%s' "$out" | grep -oiE 'verdict[: ]+[A-Z_]+|: (PASS|FAIL|SKIP|NOT_APPLICABLE)' | head -1)"
  [ -n "$verdict" ] || verdict="(exit $rc)"
  printf '%-34s exit=%s  %s\n' "$g" "$rc" "$verdict"
  [ "$rc" -ne 0 ] && overall=1
done

echo
if [ "$overall" -eq 0 ]; then echo "run-gates: ALL GATES exit 0"; else echo "run-gates: at least one gate non-zero"; fi
exit "$overall"
