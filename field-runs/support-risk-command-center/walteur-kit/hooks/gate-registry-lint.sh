#!/usr/bin/env bash
# WALTEUR gate-registry-lint - validates the class/risk gate matrix.
#
# Contract:
#   - gate-registry.json absent       => FAIL, exit 2.
#   - jq absent                       => SKIP, exit 0, recorded loudly.
#   - malformed registry              => FAIL, exit 2.
#   - valid registry, no build contract => PASS, exit 0.
#   - build contract present but missing required gates => FAIL, exit 2.
#   - walteur-kit/PAUSED              => exit 2.
#
# Report:
#   walteur-kit/gate-registry-report.json
#
# Bypass:
#   WALTEUR_GATE_REGISTRY=off
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REGISTRY="${WALTEUR_GATE_REGISTRY_FILE:-$KIT/gate-registry.json}"
CONTRACT="${WALTEUR_BUILD_CONTRACT_FILE:-$KIT/build-contract.json}"
REPORT="$KIT/gate-registry-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  verdict="$1"
  reason="$2"
  findings="${3:-[]}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" \
      --arg registry "${REGISTRY#"$ROOT"/}" --arg contract "${CONTRACT#"$ROOT"/}" \
      --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"gate-registry", registry_file:$registry, build_contract_file:$contract, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"gate-registry","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
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
    echo "gate-registry-lint selftest SKIP - jq not installed."
    return 0
  fi

  make_registry() {
    dst="$1"
    cat > "$dst" <<'JSON'
{
  "schema_version": 1,
  "registry_id": "selftest",
  "gates": [
    { "id": "base-gate", "stage": "intake", "hardness": "hard", "availability": "spec", "hook": "base-gate.sh", "report": "base.json", "evidence": "base evidence" },
    { "id": "software-gate", "stage": "verify", "hardness": "hard", "availability": "spec", "hook": "software-gate.sh", "report": "software.json", "evidence": "software evidence" },
    { "id": "medium-gate", "stage": "plan", "hardness": "detect_or_skip", "availability": "spec", "hook": "medium-gate.sh", "report": "medium.json", "evidence": "medium evidence" }
  ],
  "requirements": {
    "all": ["base-gate"],
    "by_build_class": {
      "software": ["software-gate"],
      "workflow": [],
      "document": [],
      "data-ai": [],
      "cloud-iac": [],
      "mixed": []
    },
    "by_risk_tier": {
      "low": [],
      "medium": ["medium-gate"],
      "high": [],
      "regulated": []
    }
  }
}
JSON
  }

  make_contract() {
    dst="$1"
    gates="$2"
    cat > "$dst" <<JSON
{
  "schema_version": 1,
  "contract_id": "selftest",
  "request": {
    "summary": "Build a verified app",
    "user_outcome": "User can complete the core workflow",
    "primary_user": "Operator",
    "non_goals": ["Do not add billing"]
  },
  "build_class": "software",
  "risk_tier": "medium",
  "data_classification": "internal",
  "success_metrics": [
    { "name": "Core flow", "target": "Completes", "check": "Run test" }
  ],
  "constraints": [],
  "interfaces": [
    { "name": "App", "type": "ui", "owner": "Ops", "contract": "Core workflow" }
  ],
  "verification": {
    "gates": [$gates],
    "commands": [],
    "manual_checks": []
  },
  "evidence_required": ["test output"],
  "unknowns": [],
  "created_at": "2026-06-22T00:00:00Z"
}
JSON
  }

  echo "gate-registry-lint selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-registry-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/hooks"
  make_registry "$tmp/walteur-kit/gate-registry.json"
  for h in base-gate software-gate medium-gate; do printf '#!/usr/bin/env bash\n' > "$tmp/walteur-kit/hooks/$h.sh"; done
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "valid registry, no contract -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-registry-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/hooks"
  make_registry "$tmp/walteur-kit/gate-registry.json"
  for h in base-gate software-gate medium-gate; do printf '#!/usr/bin/env bash\n' > "$tmp/walteur-kit/hooks/$h.sh"; done
  make_contract "$tmp/walteur-kit/build-contract.json" '{ "id": "base-gate", "stage": "intake", "hardness": "hard", "expected_evidence": "base" }, { "id": "software-gate", "stage": "verify", "hardness": "hard", "expected_evidence": "software" }, { "id": "medium-gate", "stage": "plan", "hardness": "detect_or_skip", "expected_evidence": "medium" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "valid registry and contract -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-registry-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/hooks"
  make_registry "$tmp/walteur-kit/gate-registry.json"
  for h in base-gate software-gate medium-gate; do printf '#!/usr/bin/env bash\n' > "$tmp/walteur-kit/hooks/$h.sh"; done
  make_contract "$tmp/walteur-kit/build-contract.json" '{ "id": "base-gate", "stage": "intake", "hardness": "hard", "expected_evidence": "base" }, { "id": "medium-gate", "stage": "plan", "hardness": "detect_or_skip", "expected_evidence": "medium" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "contract missing required class gate -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-registry-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/hooks"
  make_registry "$tmp/walteur-kit/gate-registry.json"
  jq '.requirements.all += ["missing-gate"]' "$tmp/walteur-kit/gate-registry.json" > "$tmp/r.json" && mv "$tmp/r.json" "$tmp/walteur-kit/gate-registry.json"
  for h in base-gate software-gate medium-gate; do printf '#!/usr/bin/env bash\n' > "$tmp/walteur-kit/hooks/$h.sh"; done
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "registry references unknown gate -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-registry-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/hooks"
  make_registry "$tmp/walteur-kit/gate-registry.json"
  jq 'del(.requirements.by_build_class["data-ai"])' "$tmp/walteur-kit/gate-registry.json" > "$tmp/r.json" && mv "$tmp/r.json" "$tmp/walteur-kit/gate-registry.json"
  for h in base-gate software-gate medium-gate; do printf '#!/usr/bin/env bash\n' > "$tmp/walteur-kit/hooks/$h.sh"; done
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "registry missing data-ai bucket -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-registry-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/hooks"
  make_registry "$tmp/walteur-kit/gate-registry.json"
  jq 'del(.requirements.by_risk_tier.regulated)' "$tmp/walteur-kit/gate-registry.json" > "$tmp/r.json" && mv "$tmp/r.json" "$tmp/walteur-kit/gate-registry.json"
  for h in base-gate software-gate medium-gate; do printf '#!/usr/bin/env bash\n' > "$tmp/walteur-kit/hooks/$h.sh"; done
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "registry missing regulated bucket -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-registry-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/hooks"
  make_registry "$tmp/walteur-kit/gate-registry.json"
  jq '. + {extra_root:"not in schema"} | .gates[0].extra = "not in schema" | .requirements.extra = []' "$tmp/walteur-kit/gate-registry.json" > "$tmp/r.json" && mv "$tmp/r.json" "$tmp/walteur-kit/gate-registry.json"
  for h in base-gate software-gate medium-gate; do printf '#!/usr/bin/env bash\n' > "$tmp/walteur-kit/hooks/$h.sh"; done
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "registry extra root and nested fields -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-registry-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{ bad json\n' > "$tmp/walteur-kit/gate-registry.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "malformed registry -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "gate-registry-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_GATE_REGISTRY:-on}" = "off" ] && {
  echo "gate-registry-lint: bypassed (WALTEUR_GATE_REGISTRY=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_GATE_REGISTRY=off" "[]"
  exit 0
}

if [ ! -f "$REGISTRY" ]; then
  write_report "FAIL" "gate-registry.json absent" '[{"check":"registry.present","message":"gate-registry.json is required"}]'
  echo "gate-registry-lint verdict: FAIL - gate-registry.json absent -> $REPORT" >&2
  exit 2
fi

if ! have jq; then
  echo "gate-registry-lint SKIP - jq not installed (recorded, not silent-green)." >&2
  write_report "SKIP" "jq not installed" "[]"
  exit 0
fi

if ! jq empty "$REGISTRY" >/dev/null 2>&1; then
  findings='[{"check":"json","message":"gate-registry.json is not valid JSON"}]'
  write_report "FAIL" "gate-registry.json is not valid JSON" "$findings"
  echo "gate-registry-lint verdict: FAIL - gate-registry.json is not valid JSON -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

for key in schema_version registry_id gates requirements; do
  if ! jq -e --arg k "$key" 'has($k)' "$REGISTRY" >/dev/null; then
    add_finding "required.$key" "missing required key: $key"
  fi
done

if ! jq -e '.gates | type=="array" and length>0' "$REGISTRY" >/dev/null 2>&1; then
  add_finding "gates.shape" "gates must be a non-empty array"
fi

duplicate_ids="$(jq -r '.gates[]?.id // empty' "$REGISTRY" 2>/dev/null | sort | uniq -d | paste -sd ', ' -)"
[ -n "$duplicate_ids" ] && add_finding "gates.unique" "duplicate gate ids: $duplicate_ids"

bad_gates="$(jq -r '
  (.gates // [])[]
  | select((.id|type!="string") or (.hook|type!="string") or (.report|type!="string") or (.evidence|type!="string")
      or (.stage as $s | ["intake","discover","plan","build","verify","review","ship","reflect"] | index($s) | not)
      or (.hardness as $h | ["hard","detect_or_skip","protocol","manual"] | index($h) | not)
      or (.availability as $a | ["spec","canonical","optional"] | index($a) | not))
  | (.id // "<missing>")
' "$REGISTRY" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_gates" ] && add_finding "gates.enums" "invalid gate entries: $bad_gates"

while IFS=$'\t' read -r gate_id hook availability; do
  [ -n "$gate_id" ] || continue
  if [ "$availability" = "spec" ] && [ ! -f "$KIT/hooks/$hook" ]; then
    add_finding "hooks.present.$gate_id" "spec gate '$gate_id' declares missing hook: walteur-kit/hooks/$hook"
  fi
done <<EOF
$(jq -r '.gates[]? | [.id, (.hook // ""), (.availability // "")] | @tsv' "$REGISTRY" 2>/dev/null)
EOF

if ! jq -e '.requirements | type=="object" and (.all|type=="array") and (.by_build_class|type=="object") and (.by_risk_tier|type=="object")' "$REGISTRY" >/dev/null 2>&1; then
  add_finding "requirements.shape" "requirements must include all, by_build_class, and by_risk_tier"
fi

extra_fields="$(jq -r '
  def extra_keys($obj; $allowed; $prefix):
    if ($obj | type) == "object" then
      $obj
      | keys_unsorted[] as $key
      | select(($allowed | index($key)) | not)
      | if $prefix == "" then $key else ($prefix + "." + $key) end
    else empty end;

  extra_keys(.; ["schema_version","registry_id","gates","requirements"]; ""),
  (if (.gates | type) == "array" then
    (.gates | to_entries[] | extra_keys(.value; ["id","stage","hardness","availability","hook","report","evidence"]; ("gates[" + (.key|tostring) + "]")))
  else empty end),
  extra_keys((.requirements // {}); ["all","by_build_class","by_risk_tier"]; "requirements")
' "$REGISTRY" 2>/dev/null | paste -sd ',' - | sed 's/,/, /g')"
[ -n "$extra_fields" ] && add_finding "additional_properties" "unknown fields are not allowed: $extra_fields"

if jq -e '(.requirements.by_build_class // null) | type=="object"' "$REGISTRY" >/dev/null 2>&1; then
  for bucket in software workflow document data-ai cloud-iac mixed; do
    if ! jq -e --arg b "$bucket" '(.requirements.by_build_class // {}) | has($b)' "$REGISTRY" >/dev/null 2>&1; then
      add_finding "requirements.by_build_class.$bucket" "missing by_build_class bucket: $bucket"
    elif ! jq -e --arg b "$bucket" '.requirements.by_build_class[$b] | type=="array"' "$REGISTRY" >/dev/null 2>&1; then
      add_finding "requirements.by_build_class.$bucket" "by_build_class bucket '$bucket' must be an array"
    fi
  done
  extra_class_buckets="$(jq -r '
    (.requirements.by_build_class // {}) | keys[]
    | select((["software","workflow","document","data-ai","cloud-iac","mixed"] | index(.)) | not)
  ' "$REGISTRY" 2>/dev/null | paste -sd ', ' -)"
  [ -n "$extra_class_buckets" ] && add_finding "requirements.by_build_class.extra" "unknown by_build_class buckets: $extra_class_buckets"
fi

if jq -e '(.requirements.by_risk_tier // null) | type=="object"' "$REGISTRY" >/dev/null 2>&1; then
  for bucket in low medium high regulated; do
    if ! jq -e --arg b "$bucket" '(.requirements.by_risk_tier // {}) | has($b)' "$REGISTRY" >/dev/null 2>&1; then
      add_finding "requirements.by_risk_tier.$bucket" "missing by_risk_tier bucket: $bucket"
    elif ! jq -e --arg b "$bucket" '.requirements.by_risk_tier[$b] | type=="array"' "$REGISTRY" >/dev/null 2>&1; then
      add_finding "requirements.by_risk_tier.$bucket" "by_risk_tier bucket '$bucket' must be an array"
    fi
  done
  extra_risk_buckets="$(jq -r '
    (.requirements.by_risk_tier // {}) | keys[]
    | select((["low","medium","high","regulated"] | index(.)) | not)
  ' "$REGISTRY" 2>/dev/null | paste -sd ', ' -)"
  [ -n "$extra_risk_buckets" ] && add_finding "requirements.by_risk_tier.extra" "unknown by_risk_tier buckets: $extra_risk_buckets"
fi

known_ids="$(jq -r '.gates[]?.id // empty' "$REGISTRY" 2>/dev/null | sort -u)"
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  if ! printf '%s\n' "$known_ids" | grep -qxF "$ref"; then
    add_finding "requirements.reference.$ref" "requirement references unknown gate id: $ref"
  fi
done <<EOF
$(jq -r '(.requirements.all // [])[], (.requirements.by_build_class // {} | .[]?[]), (.requirements.by_risk_tier // {} | .[]?[])' "$REGISTRY" 2>/dev/null | sort -u)
EOF

if [ -f "$CONTRACT" ]; then
  if ! jq empty "$CONTRACT" >/dev/null 2>&1; then
    add_finding "build_contract.json" "build-contract.json is not valid JSON, so required gates cannot be checked"
  else
    build_class="$(jq -r '.build_class // empty' "$CONTRACT")"
    risk_tier="$(jq -r '.risk_tier // empty' "$CONTRACT")"
    declared_gates="$(jq -r '.verification.gates[]?.id // empty' "$CONTRACT" 2>/dev/null | sort -u)"
    while IFS= read -r req; do
      [ -n "$req" ] || continue
      if ! printf '%s\n' "$declared_gates" | grep -qxF "$req"; then
        add_finding "build_contract.required_gate.$req" "build-contract.json is missing required gate '$req' for class '$build_class' and risk '$risk_tier'"
      fi
    done <<EOF
$(jq -r --arg c "$build_class" --arg r "$risk_tier" '((.requirements.all // []) + (.requirements.by_build_class[$c] // []) + (.requirements.by_risk_tier[$r] // [])) | unique[]' "$REGISTRY" 2>/dev/null)
EOF
  fi
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "$failures gate-registry violation(s)" "$findings"
  echo "gate-registry-lint verdict: FAIL - $failures violation(s) -> $REPORT" >&2
  exit 2
fi

if [ -f "$CONTRACT" ]; then
  reason="registry valid and build contract declares required gates"
else
  reason="registry valid; build-contract.json absent"
fi
write_report "PASS" "$reason" "$findings"
echo "gate-registry-lint verdict: PASS - $reason -> $REPORT" >&2
exit 0
