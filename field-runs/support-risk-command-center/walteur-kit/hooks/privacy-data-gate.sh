#!/usr/bin/env bash
# WALTEUR privacy-data-gate - personal/sensitive/regulated data lifecycle proof.
#
# Contract:
#   - No data/privacy signal and no ship/reflect requirement                  => NOT_APPLICABLE, exit 0.
#   - Data/privacy signal, ship/reflect, or WALTEUR_PRIVACY_DATA_REQUIRED=1 without proof => FAIL, exit 2.
#   - Weak/malformed/stale privacy-data proof                                 => FAIL, exit 2.
#   - Complete privacy-data proof                                             => PASS, exit 0.
#
# Report:
#   walteur-kit/privacy-data-report.json
#
# Bypass:
#   WALTEUR_PRIVACY_DATA=off
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
PROOF="$KIT/privacy-data.json"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/privacy-data-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MAX_AGE_DAYS="${WALTEUR_PRIVACY_DATA_MAX_AGE_DAYS:-14}"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  local verdict="$1" reason="$2" extra="${3:-{}}"
  if have jq && printf '%s\n' "$extra" | jq -e . >/dev/null 2>&1; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg reason "$reason" --arg proof "${PROOF#"$ROOT"/}" --argjson extra "$extra" \
      '{verdict:$v, ts:$ts, gate:"privacy-data-gate", proof_file:$proof, reason:$reason} + $extra' > "$REPORT" 2>/dev/null \
      && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"privacy-data-gate","proof_file":"%s","reason":"%s"}\n' \
    "$verdict" "$TS" "${PROOF#"$ROOT"/}" "$reason" > "$REPORT" 2>/dev/null || true
}

detect_privacy_surface() {
  PRIVACY_SIGNAL=0
  PRIVACY_SIGNAL_REASON=""
  signal_file="${TMPDIR:-/tmp}/privacy-data-signal.$$"
  : > "$signal_file"
  while IFS= read -r candidate; do
    if grep -Eli '(pii|personal[_ -]?data|sensitive[_ -]?data|email|ssn|phone|dob|passport|credit.?card|first_?name|last_?name|gdpr|ccpa|consent|cookie|tracking|analytics|retention|delete[_ -]?user|export[_ -]?user|data_subject|subprocessor|breach|dpia|ai[_ -]?context)' "$candidate" >> "$signal_file" 2>/dev/null; then
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
    PRIVACY_SIGNAL=1
    PRIVACY_SIGNAL_REASON="$(head -n 1 "$signal_file" | sed "s#^$ROOT/##")"
  fi
  rm -f "$signal_file"
}

detect_required() {
  REQUIRED=0
  REQUIRED_REASON=""

  if [ "${WALTEUR_PRIVACY_DATA_REQUIRED:-}" = "1" ]; then
    REQUIRED=1
    REQUIRED_REASON="WALTEUR_PRIVACY_DATA_REQUIRED=1"
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

  detect_privacy_surface
  if [ "$PRIVACY_SIGNAL" -eq 1 ]; then
    REQUIRED=1
    REQUIRED_REASON="privacy/data signal: $PRIVACY_SIGNAL_REASON"
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
    echo "privacy-data-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    local dst="$1" phase="${2:-ship}"
    mkdir -p "$dst/walteur-kit/autopilot"
    jq -n --arg phase "$phase" '{phase:$phase}' > "$dst/walteur-kit/autopilot/STATE.json"
  }

  write_evidence() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit/privacy"
    for f in inventory processing purposes minimization lawful retention deletion dsar backup encrypt-rest encrypt-transit logging access breach subprocessors transfer safeguards risks acceptance scan retention-test deletion-test redaction-test regression signoff dpia evidence; do
      printf '%s evidence\n' "$f" > "$dst/walteur-kit/privacy/$f.txt"
    done
  }

  write_good_proof() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit"
    cat > "$dst/walteur-kit/privacy-data.json" <<JSON
{
  "schema_version": 1,
  "proof_id": "privacy-data-selftest",
  "run_date": "$today",
  "build_class": "software",
  "risk_tier": "high",
  "verdict": "PASS",
  "applicability": {
    "personal_data": true,
    "sensitive_data": true,
    "regulated_data": true,
    "ai_context_data": false,
    "children_data": false
  },
  "inventory": {
    "data_inventory_ref": "walteur-kit/privacy/inventory.txt",
    "processing_records_ref": "walteur-kit/privacy/processing.txt",
    "purposes_ref": "walteur-kit/privacy/purposes.txt",
    "data_minimization_ref": "walteur-kit/privacy/minimization.txt",
    "lawful_basis_ref": "walteur-kit/privacy/lawful.txt"
  },
  "retention_deletion": {
    "retention_schedule_ref": "walteur-kit/privacy/retention.txt",
    "deletion_path_ref": "walteur-kit/privacy/deletion.txt",
    "dsar_access_modify_export_ref": "walteur-kit/privacy/dsar.txt",
    "backup_deletion_policy_ref": "walteur-kit/privacy/backup.txt"
  },
  "protection": {
    "encryption_at_rest_ref": "walteur-kit/privacy/encrypt-rest.txt",
    "encryption_in_transit_ref": "walteur-kit/privacy/encrypt-transit.txt",
    "logging_redaction_ref": "walteur-kit/privacy/logging.txt",
    "access_control_ref": "walteur-kit/privacy/access.txt",
    "breach_response_ref": "walteur-kit/privacy/breach.txt"
  },
  "transfers": {
    "subprocessors_ref": "walteur-kit/privacy/subprocessors.txt",
    "third_country_transfer_ref": "walteur-kit/privacy/transfer.txt",
    "safeguards_ref": "walteur-kit/privacy/safeguards.txt"
  },
  "risk": {
    "dpia_required": true,
    "dpia_ref": "walteur-kit/privacy/dpia.txt",
    "residual_risks_ref": "walteur-kit/privacy/risks.txt",
    "owner_acceptance_ref": "walteur-kit/privacy/acceptance.txt"
  },
  "tests": {
    "pii_scan_ref": "walteur-kit/privacy/scan.txt",
    "retention_test_ref": "walteur-kit/privacy/retention-test.txt",
    "deletion_test_ref": "walteur-kit/privacy/deletion-test.txt",
    "logging_redaction_test_ref": "walteur-kit/privacy/redaction-test.txt",
    "regression_command_ref": "walteur-kit/privacy/regression.txt"
  },
  "evidence_refs": ["walteur-kit/privacy/evidence.txt"],
  "signoff": {
    "required": true,
    "owner": "privacy-owner",
    "signoff_ref": "walteur-kit/privacy/signoff.txt"
  }
}
JSON
  }

  echo "privacy-data-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'print("hello")\n' > "$tmp/src/app.py"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "no signal and no privacy-data.json -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'email = request["email"]\n' > "$tmp/src/app.py"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "privacy signal without privacy-data.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "ship phase without privacy-data.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{not json\n' > "$tmp/walteur-kit/privacy-data.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "invalid privacy-data.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  write_evidence "$tmp"
  write_good_proof "$tmp"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "valid privacy data proof -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq 'del(.inventory.data_inventory_ref)' "$tmp/walteur-kit/privacy-data.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/privacy-data.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "missing data inventory ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq 'del(.inventory.lawful_basis_ref)' "$tmp/walteur-kit/privacy-data.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/privacy-data.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "missing lawful basis ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq 'del(.retention_deletion.deletion_path_ref)' "$tmp/walteur-kit/privacy-data.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/privacy-data.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "missing deletion path ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq '.risk.dpia_required = true | .risk.dpia_ref = ""' "$tmp/walteur-kit/privacy-data.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/privacy-data.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "high-risk missing DPIA ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq '.protection.breach_response_ref = "../outside.txt"' "$tmp/walteur-kit/privacy-data.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/privacy-data.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "unsafe evidence ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  write_evidence "$tmp"
  write_good_proof "$tmp"
  old_date="$(date -u -v-30d +%F 2>/dev/null || date -u -d '30 days ago' +%F)"
  jq --arg d "$old_date" '.run_date = $d' "$tmp/walteur-kit/privacy-data.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/privacy-data.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "stale privacy data proof -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  write_evidence "$tmp"
  write_good_proof "$tmp"
  jq '.signoff.required = false' "$tmp/walteur-kit/privacy-data.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/privacy-data.json"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "missing required signoff -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  write_evidence "$tmp"
  write_good_proof "$tmp"
  : > "$tmp/walteur-kit/privacy/deletion-test.txt"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "empty deletion-test evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  write_state "$tmp" ship
  WALTEUR_PRIVACY_DATA=off WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/privacy-data-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  : > "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$self_path" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  if [ "$fail" -eq 0 ]; then
    echo "privacy-data-gate selftest: $pass/$pass passed"
    return 0
  fi
  echo "privacy-data-gate selftest: $fail failed, $pass passed"
  return 1
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

if [ "${WALTEUR_PRIVACY_DATA:-}" = "off" ]; then
  write_report "SKIP" "WALTEUR_PRIVACY_DATA=off"
  exit 0
fi

if [ -f "$KIT/PAUSED" ]; then
  write_report "FAIL" "WALTEUR is paused"
  exit 2
fi

detect_required

if [ ! -s "$PROOF" ]; then
  if [ "$REQUIRED" -eq 1 ]; then
    write_report "FAIL" "privacy-data.json required: $REQUIRED_REASON"
    exit 2
  fi
  write_report "NOT_APPLICABLE" "privacy-data.json absent and no data/privacy signal"
  exit 0
fi

if ! have jq; then
  write_report "FAIL" "jq is required to validate privacy-data.json"
  exit 2
fi

if ! jq empty "$PROOF" >/dev/null 2>&1; then
  write_report "FAIL" "privacy-data.json is not valid JSON"
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
  and (.applicability.personal_data | type == "boolean")
  and (.applicability.sensitive_data | type == "boolean")
  and (.applicability.regulated_data | type == "boolean")
  and (.applicability.ai_context_data | type == "boolean")
  and (.applicability.children_data | type == "boolean")
  and (.inventory | type == "object")
  and (.inventory.data_inventory_ref | type == "string" and length > 0)
  and (.inventory.processing_records_ref | type == "string" and length > 0)
  and (.inventory.purposes_ref | type == "string" and length > 0)
  and (.inventory.data_minimization_ref | type == "string" and length > 0)
  and (.inventory.lawful_basis_ref | type == "string" and length > 0)
  and (.retention_deletion | type == "object")
  and (.retention_deletion.retention_schedule_ref | type == "string" and length > 0)
  and (.retention_deletion.deletion_path_ref | type == "string" and length > 0)
  and (.retention_deletion.dsar_access_modify_export_ref | type == "string" and length > 0)
  and (.retention_deletion.backup_deletion_policy_ref | type == "string" and length > 0)
  and (.protection | type == "object")
  and (.protection.encryption_at_rest_ref | type == "string" and length > 0)
  and (.protection.encryption_in_transit_ref | type == "string" and length > 0)
  and (.protection.logging_redaction_ref | type == "string" and length > 0)
  and (.protection.access_control_ref | type == "string" and length > 0)
  and (.protection.breach_response_ref | type == "string" and length > 0)
  and (.transfers | type == "object")
  and (.transfers.subprocessors_ref | type == "string" and length > 0)
  and (.transfers.third_country_transfer_ref | type == "string" and length > 0)
  and (.transfers.safeguards_ref | type == "string" and length > 0)
  and (.risk | type == "object")
  and (.risk.dpia_required | type == "boolean")
  and (.risk.residual_risks_ref | type == "string" and length > 0)
  and (.risk.owner_acceptance_ref | type == "string" and length > 0)
  and (.tests | type == "object")
  and (.tests.pii_scan_ref | type == "string" and length > 0)
  and (.tests.retention_test_ref | type == "string" and length > 0)
  and (.tests.deletion_test_ref | type == "string" and length > 0)
  and (.tests.logging_redaction_test_ref | type == "string" and length > 0)
  and (.tests.regression_command_ref | type == "string" and length > 0)
  and (.evidence_refs | type == "array" and length >= 1)
  and (.signoff | type == "object")
  and (.signoff.required == true)
  and (.signoff.owner | type == "string" and length > 0)
  and (.signoff.signoff_ref | type == "string" and length > 0)
' "$PROOF" >/dev/null; then
  write_report "FAIL" "privacy-data.json missing required privacy lifecycle fields"
  exit 2
fi

dpia_required="$(jq -r '.risk.dpia_required' "$PROOF")"
if [ "$dpia_required" = "true" ]; then
  if ! jq -e '.risk.dpia_ref | type == "string" and length > 0' "$PROOF" >/dev/null; then
    write_report "FAIL" "high-risk privacy proof requires dpia_ref"
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
  write_report "FAIL" "privacy data proof is stale or invalid" "$details"
  exit 2
fi

refs="$(jq -r '
  [
    .inventory.data_inventory_ref,
    .inventory.processing_records_ref,
    .inventory.purposes_ref,
    .inventory.data_minimization_ref,
    .inventory.lawful_basis_ref,
    .retention_deletion.retention_schedule_ref,
    .retention_deletion.deletion_path_ref,
    .retention_deletion.dsar_access_modify_export_ref,
    .retention_deletion.backup_deletion_policy_ref,
    .protection.encryption_at_rest_ref,
    .protection.encryption_in_transit_ref,
    .protection.logging_redaction_ref,
    .protection.access_control_ref,
    .protection.breach_response_ref,
    .transfers.subprocessors_ref,
    .transfers.third_country_transfer_ref,
    .transfers.safeguards_ref,
    .risk.dpia_ref,
    .risk.residual_risks_ref,
    .risk.owner_acceptance_ref,
    .tests.pii_scan_ref,
    .tests.retention_test_ref,
    .tests.deletion_test_ref,
    .tests.logging_redaction_test_ref,
    .tests.regression_command_ref,
    .signoff.signoff_ref,
    (.evidence_refs[]?)
  ] | map(select(type == "string" and length > 0)) | .[]
' "$PROOF")"

bad_refs=""
missing_refs=""
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    /*|*../*|../*|*~*|*'//'*) bad_refs="${bad_refs}${ref}
" ;;
  esac
  if [ ! -s "$ROOT/$ref" ]; then
    missing_refs="${missing_refs}${ref}
"
  fi
done <<EOF
$refs
EOF

if [ -n "$bad_refs" ] || [ -n "$missing_refs" ]; then
  details="$(jq -n --arg bad "$bad_refs" --arg missing "$missing_refs" '{bad_refs:($bad|split("\n")|map(select(length>0))), missing_refs:($missing|split("\n")|map(select(length>0)))}')"
  write_report "FAIL" "privacy data evidence refs invalid" "$details"
  exit 2
fi

write_report "PASS" "privacy data proof passes" "$(jq -n --arg run_date "$run_date" '{run_date:$run_date}')"
exit 0
