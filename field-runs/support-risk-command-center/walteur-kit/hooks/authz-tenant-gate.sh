#!/usr/bin/env bash
# WALTEUR authz-tenant-gate - access-control and tenant-isolation proof.
#
# Contract:
#   - No authz/tenant signal and no ship/reflect requirement             => NOT_APPLICABLE, exit 0.
#   - Authz/tenant signal, ship/reflect, or WALTEUR_AUTHZ_TENANT_REQUIRED=1 without proof => FAIL, exit 2.
#   - Weak/malformed/stale authz/tenant proof                            => FAIL, exit 2.
#   - Complete authz/tenant proof                                        => PASS, exit 0.
#
# Report:
#   walteur-kit/authz-tenant-report.json
#
# Bypass:
#   WALTEUR_AUTHZ_TENANT=off
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
PROOF="$KIT/authz-tenant.json"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/authz-tenant-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MAX_AGE_DAYS="${WALTEUR_AUTHZ_TENANT_MAX_AGE_DAYS:-14}"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  local verdict="$1" reason="$2" extra="${3:-{}}"
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

details="$(jq -n --arg run_date "$run_date" --arg tenant_surface "$tenant_surface" '{run_date:$run_date, tenant_surface:($tenant_surface == "true")}')"
write_report "PASS" "authz tenant proof is valid" "$details"
exit 0
