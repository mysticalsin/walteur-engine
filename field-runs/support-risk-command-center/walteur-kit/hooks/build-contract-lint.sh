#!/usr/bin/env bash
# WALTEUR build-contract-lint - typed intake gate for any enterprise build.
#
# Contract:
#   - walteur-kit/build-contract.json absent => NOT_APPLICABLE, exit 0.
#   - jq absent                             => SKIP, exit 0, recorded loudly.
#   - malformed contract                    => FAIL, exit 2.
#   - valid contract                        => PASS, exit 0.
#   - walteur-kit/PAUSED                    => exit 2.
#
# Report:
#   walteur-kit/build-contract-report.json
#
# Bypass:
#   WALTEUR_BUILD_CONTRACT_GATE=off
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
CONTRACT="${WALTEUR_BUILD_CONTRACT_FILE:-$KIT/build-contract.json}"
REGISTRY="${WALTEUR_GATE_REGISTRY_FILE:-$KIT/gate-registry.json}"
REPORT="$KIT/build-contract-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  verdict="$1"
  reason="$2"
  findings="${3:-[]}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" --arg p "${CONTRACT#"$ROOT"/}" \
      --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"build-contract", contract_file:$p, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"build-contract","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
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
    echo "build-contract-lint selftest SKIP - jq not installed."
    return 0
  fi

  echo "build-contract-lint selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/build-contract-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no build-contract.json -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/build-contract-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/walteur-kit/build-contract.json" <<'JSON'
{
  "schema_version": 1,
  "contract_id": "demo",
  "request": {
    "summary": "Build a support dashboard",
    "user_outcome": "Support leads can see workload and blocked cases",
    "primary_user": "Support lead",
    "non_goals": ["Do not replace the ticketing system"]
  },
  "build_class": "mixed",
  "risk_tier": "medium",
  "data_classification": "internal",
  "success_metrics": [
    { "name": "Freshness", "target": "Under 15 minutes old", "check": "Run freshness report" }
  ],
  "constraints": [
    { "id": "c1", "kind": "privacy", "description": "No PII in demos", "status": "active" }
  ],
  "interfaces": [
    { "name": "Dashboard", "type": "ui", "owner": "Support ops", "contract": "Workload, aging, and blocked views" }
  ],
  "verification": {
    "gates": [
      { "id": "verify-dashboard", "stage": "verify", "hardness": "hard", "expected_evidence": "test output" }
    ],
    "commands": [
      { "command": "true", "purpose": "selftest command" }
    ],
    "manual_checks": ["Review handoff"]
  },
  "evidence_required": ["test output", "handoff"],
  "unknowns": [
    { "question": "Which fields are safe?", "owner": "Support ops", "resolution_status": "open" }
  ],
  "created_at": "2026-06-22T00:00:00Z"
}
JSON
	  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "valid build-contract.json -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/build-contract-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/walteur-kit/build-contract.json" <<'JSON'
{
  "schema_version": 1,
  "contract_id": "extra-fields",
  "request": {
    "summary": "Build a support dashboard",
    "user_outcome": "Support leads can see workload and blocked cases",
    "primary_user": "Support lead",
    "non_goals": ["Do not replace the ticketing system"],
    "surprise": "not in schema"
  },
  "build_class": "software",
  "risk_tier": "medium",
  "data_classification": "internal",
  "success_metrics": [
    { "name": "Freshness", "target": "Under 15 minutes old", "check": "Run freshness report", "extra": "not in schema" }
  ],
  "constraints": [],
  "interfaces": [
    { "name": "Dashboard", "type": "ui", "owner": "Support ops", "contract": "Workload, aging, and blocked views" }
  ],
  "verification": {
    "gates": [
      { "id": "verify-dashboard", "stage": "verify", "hardness": "hard", "expected_evidence": "test output", "extra": "not in schema" }
    ],
    "commands": [
      { "command": "true", "purpose": "selftest command" }
    ],
    "manual_checks": ["Review handoff"]
  },
  "evidence_required": ["test output", "handoff"],
  "unknowns": [
    { "question": "Which fields are safe?", "owner": "Support ops", "resolution_status": "open" }
  ],
  "created_at": "2026-06-22T00:00:00Z",
  "extra_root": "not in schema"
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "extra root and nested fields -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/build-contract-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/walteur-kit/build-contract.json" <<'JSON'
{
  "schema_version": 1,
  "contract_id": "bad",
  "request": {
    "summary": "TODO",
    "user_outcome": "Build something",
    "primary_user": "User",
    "non_goals": []
  },
  "build_class": "vibes",
  "risk_tier": "medium",
  "data_classification": "internal",
  "success_metrics": [],
  "constraints": [],
  "interfaces": [],
  "verification": {
    "gates": [
      { "id": "talk-about-tests", "stage": "review", "hardness": "protocol", "expected_evidence": "<evidence>" }
    ],
    "commands": [],
    "manual_checks": []
  },
  "evidence_required": [],
  "unknowns": [],
  "created_at": "2026-06-22T00:00:00Z"
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "poisoned build-contract.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/build-contract-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{ bad json\n' > "$tmp/walteur-kit/build-contract.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "malformed JSON -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/build-contract-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/hooks"
  printf '#!/usr/bin/env bash\n' > "$tmp/walteur-kit/hooks/verify-a.sh"
  cat > "$tmp/walteur-kit/gate-registry.json" <<'JSON'
{
  "schema_version": 1,
  "registry_id": "selftest",
  "gates": [
    { "id": "verify-a", "stage": "verify", "hardness": "hard", "availability": "spec", "hook": "verify-a.sh", "report": "verify-a.json", "evidence": "verify evidence" }
  ],
  "requirements": {
    "all": ["verify-a"],
    "by_build_class": { "software": [], "workflow": [], "document": [], "data-ai": [], "cloud-iac": [], "mixed": [] },
    "by_risk_tier": { "low": [], "medium": [], "high": [], "regulated": [] }
  }
}
JSON
  cat > "$tmp/walteur-kit/build-contract.json" <<'JSON'
{
  "schema_version": 1,
  "contract_id": "missing-command-coverage",
  "request": {
    "summary": "Build a support dashboard",
    "user_outcome": "Support leads can see workload and blocked cases",
    "primary_user": "Support lead",
    "non_goals": ["Do not replace the ticketing system"]
  },
  "build_class": "software",
  "risk_tier": "low",
  "data_classification": "internal",
  "success_metrics": [
    { "name": "Freshness", "target": "Under 15 minutes old", "check": "Run freshness report" }
  ],
  "constraints": [],
  "interfaces": [
    { "name": "Dashboard", "type": "ui", "owner": "Support ops", "contract": "Workload, aging, and blocked views" }
  ],
  "verification": {
    "gates": [
      { "id": "verify-a", "stage": "verify", "hardness": "hard", "expected_evidence": "verify evidence" }
    ],
    "commands": [
      { "command": "true", "purpose": "missing verify-a hook" }
    ],
    "manual_checks": ["Review handoff"]
  },
  "evidence_required": ["test output"],
  "unknowns": [],
  "created_at": "2026-06-22T00:00:00Z"
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "selected runnable gate missing from commands -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/build-contract-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/hooks"
  printf '#!/usr/bin/env bash\n' > "$tmp/walteur-kit/hooks/verify-a.sh"
  cat > "$tmp/walteur-kit/gate-registry.json" <<'JSON'
{
  "schema_version": 1,
  "registry_id": "selftest",
  "gates": [
    { "id": "verify-a", "stage": "verify", "hardness": "hard", "availability": "spec", "hook": "verify-a.sh", "report": "verify-a.json", "evidence": "verify evidence" },
    { "id": "canonical-ship", "stage": "ship", "hardness": "hard", "availability": "canonical", "hook": "ship-gate.sh", "report": "audit.json", "evidence": "canonical ship proof" }
  ],
  "requirements": {
    "all": ["verify-a", "canonical-ship"],
    "by_build_class": { "software": [], "workflow": [], "document": [], "data-ai": [], "cloud-iac": [], "mixed": [] },
    "by_risk_tier": { "low": [], "medium": [], "high": [], "regulated": [] }
  }
}
JSON
  cat > "$tmp/walteur-kit/build-contract.json" <<'JSON'
{
  "schema_version": 1,
  "contract_id": "covered-command-and-manual",
  "request": {
    "summary": "Build a support dashboard",
    "user_outcome": "Support leads can see workload and blocked cases",
    "primary_user": "Support lead",
    "non_goals": ["Do not replace the ticketing system"]
  },
  "build_class": "software",
  "risk_tier": "low",
  "data_classification": "internal",
  "success_metrics": [
    { "name": "Freshness", "target": "Under 15 minutes old", "check": "Run freshness report" }
  ],
  "constraints": [],
  "interfaces": [
    { "name": "Dashboard", "type": "ui", "owner": "Support ops", "contract": "Workload, aging, and blocked views" }
  ],
  "verification": {
    "gates": [
      { "id": "verify-a", "stage": "verify", "hardness": "hard", "expected_evidence": "verify evidence" },
      { "id": "canonical-ship", "stage": "ship", "hardness": "hard", "expected_evidence": "canonical ship proof" }
    ],
    "commands": [
      { "command": "bash walteur-kit/hooks/verify-a.sh", "purpose": "Run selected runnable hooks" }
    ],
    "manual_checks": ["Selected gate canonical-ship uses ship-gate.sh in the canonical kit; attach signed evidence before ship."]
  },
  "evidence_required": ["test output"],
  "unknowns": [],
  "created_at": "2026-06-22T00:00:00Z"
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "selected runnable command and canonical manual coverage -> PASS" 0 "$?"
  rm -rf "$tmp"

  echo "build-contract-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_BUILD_CONTRACT_GATE:-on}" = "off" ] && {
  echo "build-contract-lint: bypassed (WALTEUR_BUILD_CONTRACT_GATE=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_BUILD_CONTRACT_GATE=off" "[]"
  exit 0
}

if [ ! -f "$CONTRACT" ]; then
  echo "build-contract-lint: no build-contract.json found at ${CONTRACT#"$ROOT"/} - gate not applicable." >&2
  write_report "NOT_APPLICABLE" "build-contract.json absent" "[]"
  exit 0
fi

if ! have jq; then
  echo "build-contract-lint SKIP - jq not installed (recorded, not silent-green)." >&2
  write_report "SKIP" "jq not installed" "[]"
  exit 0
fi

if ! jq empty "$CONTRACT" >/dev/null 2>&1; then
  findings='[{"check":"json","message":"build-contract.json is not valid JSON"}]'
  write_report "FAIL" "build-contract.json is not valid JSON" "$findings"
  echo "build-contract-lint verdict: FAIL - build-contract.json is not valid JSON -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

for key in schema_version contract_id request build_class risk_tier data_classification success_metrics constraints interfaces verification evidence_required unknowns created_at; do
  if ! jq -e --arg k "$key" 'has($k)' "$CONTRACT" >/dev/null; then
    add_finding "required.$key" "missing required key: $key"
  fi
done

check_enum() {
  key="$1"; allowed="$2"
  value="$(jq -r --arg k "$key" '.[$k] // empty' "$CONTRACT")"
  [ -n "$value" ] || return 0
  if ! printf '%s\n' "$allowed" | grep -qxF "$value"; then
    add_finding "enum.$key" "$key has invalid value '$value'"
  fi
}

check_enum "build_class" "software
workflow
document
data-ai
cloud-iac
mixed"
check_enum "risk_tier" "low
medium
high
regulated"
check_enum "data_classification" "public
internal
confidential
restricted
regulated"

if ! jq -e '.request | type=="object" and (.summary|type=="string" and length>0) and (.user_outcome|type=="string" and length>0) and (.primary_user|type=="string" and length>0) and (.non_goals|type=="array" and length>0)' "$CONTRACT" >/dev/null 2>&1; then
  add_finding "request.shape" "request must include summary, user_outcome, primary_user, and at least one non_goal"
fi

if ! jq -e '.success_metrics | type=="array" and length>0 and all(.[]; (.name|type=="string" and length>0) and (.target|type=="string" and length>0) and (.check|type=="string" and length>0))' "$CONTRACT" >/dev/null 2>&1; then
  add_finding "success_metrics.shape" "success_metrics must be a non-empty array of name, target, and check"
fi

if ! jq -e '.constraints | type=="array"' "$CONTRACT" >/dev/null 2>&1; then
  add_finding "constraints.shape" "constraints must be an array"
fi

bad_constraints="$(jq -r '
  (.constraints // [])[]
  | select((.id|type!="string") or (.description|type!="string")
      or (.kind as $k | ["business","technical","legal","security","privacy","performance","design","operational"] | index($k) | not)
      or (.status as $s | ["active","accepted_risk","deferred","out_of_scope"] | index($s) | not))
  | (.id // "<missing>")
' "$CONTRACT" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_constraints" ] && add_finding "constraints.enums" "invalid constraint entries: $bad_constraints"

if ! jq -e '.interfaces | type=="array" and length>0' "$CONTRACT" >/dev/null 2>&1; then
  add_finding "interfaces.shape" "interfaces must be a non-empty array"
fi

bad_interfaces="$(jq -r '
  (.interfaces // [])[]
  | select((.name|type!="string") or (.owner|type!="string") or (.contract|type!="string")
      or (.type as $t | ["ui","api","database","event","file","cli","agent","workflow","document","external-service"] | index($t) | not))
  | (.name // "<missing>")
' "$CONTRACT" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_interfaces" ] && add_finding "interfaces.enums" "invalid interface entries: $bad_interfaces"

if ! jq -e '.verification | type=="object" and (.gates|type=="array" and length>0) and (.commands|type=="array") and (.manual_checks|type=="array")' "$CONTRACT" >/dev/null 2>&1; then
  add_finding "verification.shape" "verification must include gates, commands, and manual_checks arrays"
fi

bad_gates="$(jq -r '
  (.verification.gates // [])[]
  | select((.id|type!="string") or (.expected_evidence|type!="string")
      or (.stage as $s | ["intake","discover","plan","build","verify","review","ship","reflect"] | index($s) | not)
      or (.hardness as $h | ["hard","detect_or_skip","protocol","manual"] | index($h) | not))
  | (.id // "<missing>")
' "$CONTRACT" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_gates" ] && add_finding "verification.gate.enums" "invalid gate entries: $bad_gates"

if ! jq -e '.verification.gates | any(.stage=="verify" and (.hardness=="hard" or .hardness=="detect_or_skip"))' "$CONTRACT" >/dev/null 2>&1; then
  add_finding "verification.verify_gate" "at least one verify gate must be hard or detect_or_skip"
fi

if ! jq -e '.evidence_required | type=="array" and length>0 and all(.[]; type=="string" and length>0)' "$CONTRACT" >/dev/null 2>&1; then
  add_finding "evidence_required.shape" "evidence_required must be a non-empty string array"
fi

bad_unknowns="$(jq -r '
  (.unknowns // [])[]
  | select((.question|type!="string") or (.owner|type!="string")
      or (.resolution_status as $s | ["open","answered","accepted_risk"] | index($s) | not))
  | (.question // "<missing>")
' "$CONTRACT" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_unknowns" ] && add_finding "unknowns.enums" "invalid unknown entries: $bad_unknowns"

extra_fields="$(jq -r '
  def extra_keys($obj; $allowed; $prefix):
    if ($obj | type) == "object" then
      $obj
      | keys_unsorted[] as $key
      | select(($allowed | index($key)) | not)
      | if $prefix == "" then $key else ($prefix + "." + $key) end
    else empty end;

  extra_keys(.; ["schema_version","contract_id","request","build_class","risk_tier","data_classification","success_metrics","constraints","interfaces","verification","evidence_required","unknowns","created_at"]; ""),
  extra_keys((.request // {}); ["summary","user_outcome","primary_user","non_goals"]; "request"),
  (if (.success_metrics | type) == "array" then
    (.success_metrics | to_entries[] | extra_keys(.value; ["name","target","check"]; ("success_metrics[" + (.key|tostring) + "]")))
  else empty end),
  (if (.constraints | type) == "array" then
    (.constraints | to_entries[] | extra_keys(.value; ["id","kind","description","status"]; ("constraints[" + (.key|tostring) + "]")))
  else empty end),
  (if (.interfaces | type) == "array" then
    (.interfaces | to_entries[] | extra_keys(.value; ["name","type","owner","contract"]; ("interfaces[" + (.key|tostring) + "]")))
  else empty end),
  extra_keys((.verification // {}); ["gates","commands","manual_checks"]; "verification"),
  (if (.verification.gates | type) == "array" then
    (.verification.gates | to_entries[] | extra_keys(.value; ["id","stage","hardness","expected_evidence"]; ("verification.gates[" + (.key|tostring) + "]")))
  else empty end),
  (if (.verification.commands | type) == "array" then
    (.verification.commands | to_entries[] | extra_keys(.value; ["command","purpose"]; ("verification.commands[" + (.key|tostring) + "]")))
  else empty end),
  (if (.unknowns | type) == "array" then
    (.unknowns | to_entries[] | extra_keys(.value; ["question","owner","resolution_status"]; ("unknowns[" + (.key|tostring) + "]")))
  else empty end)
' "$CONTRACT" 2>/dev/null | paste -sd ',' - | sed 's/,/, /g')"
[ -n "$extra_fields" ] && add_finding "additional_properties" "unknown fields are not allowed: $extra_fields"

placeholder_hits="$(jq -r '
  paths(scalars) as $p
  | (getpath($p) | tostring) as $v
  | select(($v | test("<[^>]+>")) or ($v | test("\\b(TODO|TBD|FIXME)\\b"; "i")))
  | ($p | map(tostring) | join("."))
' "$CONTRACT" 2>/dev/null | paste -sd ', ' -)"
[ -n "$placeholder_hits" ] && add_finding "placeholders" "placeholder text remains at: $placeholder_hits"

if [ -f "$REGISTRY" ] && jq empty "$REGISTRY" >/dev/null 2>&1 && jq -e '.gates | type=="array"' "$REGISTRY" >/dev/null 2>&1; then
  command_blob="$(jq -r '(.verification.commands // [])[]?.command // empty' "$CONTRACT" 2>/dev/null)"
  manual_blob="$(jq -r '(.verification.manual_checks // [])[]? // empty' "$CONTRACT" 2>/dev/null)"
  while IFS=$'\t' read -r gate_id hook availability; do
    [ -n "$gate_id" ] || continue
    [ -n "$hook" ] || continue
    if [ -f "$KIT/hooks/$hook" ]; then
      if ! printf '%s\n' "$command_blob" | grep -qF "$hook"; then
        add_finding "verification.command_coverage.$gate_id" "selected runnable gate '$gate_id' must appear in verification.commands via hook '$hook'"
      fi
    else
      if ! printf '%s\n' "$manual_blob" | grep -qF "$gate_id" || ! printf '%s\n' "$manual_blob" | grep -qF "$hook"; then
        add_finding "verification.manual_coverage.$gate_id" "selected non-runnable gate '$gate_id' must be named in manual_checks with hook '$hook' and evidence instructions"
      fi
    fi
  done <<EOF
$(jq -r --slurpfile contract "$CONTRACT" '
  ($contract[0].verification.gates // [] | map(.id)) as $selected
  | (.gates // [])[]
  | select(.id as $id | $selected | index($id))
  | [.id, (.hook // ""), (.availability // "")] | @tsv
' "$REGISTRY" 2>/dev/null)
EOF
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "$failures contract violation(s)" "$findings"
  echo "build-contract-lint verdict: FAIL - $failures violation(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "build contract is valid" "$findings"
echo "build-contract-lint verdict: PASS -> $REPORT" >&2
exit 0
