#!/usr/bin/env bash
# WALTEUR enterprise-blueprint-gate - concrete plan-stage build target gate.
#
# Contract:
#   - No meaningful build signal                       => NOT_APPLICABLE, exit 0.
#   - Build signal but enterprise-blueprint absent      => FAIL, exit 2.
#   - Placeholder, vague, malformed, or thin blueprint  => FAIL, exit 2.
#   - Concrete blueprint with usable evidence refs      => PASS, exit 0.
#
# Report:
#   walteur-kit/enterprise-blueprint-report.json
#
# Bypass:
#   WALTEUR_ENTERPRISE_BLUEPRINT=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "enterprise-blueprint-gate - concrete plan-stage build target gate."
  printf '%s\n' "usage: bash enterprise-blueprint-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/enterprise-blueprint-report.json - fix recipes: walteur-kit/REMEDIATION.md (## enterprise-blueprint-gate)"
  printf '%s\n' "bypass: WALTEUR_ENTERPRISE_BLUEPRINT=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

SCRIPT_KIT="$(cd "$(dirname "$0")/.." && pwd)"

input_dir="${1:-}"
if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "$WALTEUR_ROOT" ]; then
  ROOT="$(cd "$WALTEUR_ROOT" && pwd)"
elif [ -n "$input_dir" ] && [ -d "$input_dir" ]; then
  ROOT="$(cd "$input_dir" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
KIT="$ROOT/walteur-kit"
REPORT="$KIT/enterprise-blueprint-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_report() {
  verdict="$1"
  mode="$2"
  reason="$3"
  findings_json="${4:-[]}"
  if have jq; then
    jq -n \
      --arg v "$verdict" --arg ts "$TS" --arg mode "$mode" --arg reason "$reason" \
      --arg blueprint "${BLUEPRINT_REL:-walteur-kit/enterprise-blueprint.json}" \
      --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"enterprise-blueprint-gate", mode:$mode, blueprint:$blueprint, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"enterprise-blueprint-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

jq_file() {
  jq -r "$1" "$BLUEPRINT" 2>/dev/null || true
}

norm_text() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'
}

require_string() {
  label="$1"
  filter="$2"
  min_len="${3:-1}"
  value="$(jq_file "$filter // empty")"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    add_finding "$label" "$label must be a non-empty string"
    return 0
  fi
  if [ "${#value}" -lt "$min_len" ]; then
    add_finding "$label" "$label must be at least $min_len characters"
  fi
}

check_ref_exists() {
  label="$1"
  ref="$2"
  [ -n "$ref" ] && [ "$ref" != "null" ] || return 0
  case "$ref" in
    manual:*|signed:*|human:*|not_applicable:*|N/A|n/a) return 0 ;;
  esac
  file_ref="${ref%%#*}"
  [ -n "$file_ref" ] || return 0
  case "$file_ref" in
    /*) ref_path="$file_ref" ;;
    *) ref_path="$ROOT/$file_ref" ;;
  esac
  if [ ! -f "$ref_path" ]; then
    add_finding "$label" "$label points to missing file: $ref"
  fi
}

detect_build_signal() {
  BUILD_SIGNAL=0
  SIGNAL_REASON=""

  for f in "$KIT/enterprise-blueprint.json" "$KIT/build-contract.json" "$KIT/PRD.md" "$KIT/PRODUCT-STANDARD.md" "$ROOT/PLAN.md" "$ROOT/DESIGN.md"; do
    if [ -f "$f" ]; then
      BUILD_SIGNAL=1
      SIGNAL_REASON="$(basename "$f") exists"
      return 0
    fi
  done

  scan_dir="${1:-$ROOT}"
  [ -d "$scan_dir" ] || scan_dir="$ROOT"
  code_count="$(find "$scan_dir" \
    \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/walteur-kit/*' \) -prune -o \
    -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.py' -o -name '*.go' -o -name '*.rs' -o -name '*.java' -o -name '*.sh' \) -print 2>/dev/null | head -20 | wc -l | tr -d ' ')"
  if [ "${code_count:-0}" -gt 0 ]; then
    BUILD_SIGNAL=1
    SIGNAL_REASON="code files present (sample_count=$code_count)"
    return 0
  fi
}

# enterprise_warranted — an enterprise blueprint (trust_model.authn/authz, multi-tenant operating model,
# SOC2-style auditability) is an ENTERPRISE artifact. Per WALTEUR §14 ("adapt to the idea; NEVER impose a
# SaaS/enterprise skeleton on a simple build"), it is only warranted when the build is actually enterprise-
# scale. Warranting signals (any one):
#   - build-contract.json .risk_tier is "high" or "regulated"; OR
#   - preflight-signals.json .regulated == true; OR
#   - a real enterprise/SaaS surface: has_auth AND (has_db OR has_payments OR has_api_boundary); OR
#   - an explicit multi_tenant / is_saas / is_enterprise signal.
# A no-auth, single-user, local app at risk medium/low with everything else false is NOT_APPLICABLE.
# An explicit blueprint already present is itself a warranting signal (the build opted in).
enterprise_warranted() {
  WARRANT_REASON=""
  contract="$KIT/build-contract.json"
  signals="$KIT/preflight-signals.json"

  # Explicit opt-in: a blueprint already authored means the build chose to be held to this bar.
  if [ -f "$KIT/enterprise-blueprint.json" ] || [ -f "$ROOT/enterprise-blueprint.json" ]; then
    WARRANT_REASON="enterprise-blueprint.json present (explicit opt-in)"
    return 0
  fi

  if have jq && [ -f "$contract" ]; then
    rt="$(jq -r '.risk_tier // empty' "$contract" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    case "$rt" in
      high|regulated)
        WARRANT_REASON="build-contract.json risk_tier=$rt"
        return 0 ;;
    esac
  fi

  if have jq && [ -f "$signals" ]; then
    if jq -e '.regulated==true' "$signals" >/dev/null 2>&1; then
      WARRANT_REASON="preflight-signals.json regulated=true"
      return 0
    fi
    if jq -e '(.multi_tenant==true) or (.is_saas==true) or (.is_enterprise==true)' "$signals" >/dev/null 2>&1; then
      WARRANT_REASON="preflight-signals.json multi_tenant/is_saas/is_enterprise signal"
      return 0
    fi
    # A real enterprise/SaaS surface: authenticated AND a real backend boundary.
    if jq -e '.has_auth==true and ((.has_db==true) or (.has_payments==true) or (.has_api_boundary==true))' "$signals" >/dev/null 2>&1; then
      WARRANT_REASON="preflight-signals.json has_auth + backend surface (db/payments/api)"
      return 0
    fi
  fi

  return 1
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
    echo "enterprise-blueprint-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_contract_signal() {
    root="$1"
    mkdir -p "$root/walteur-kit"
    cat > "$root/walteur-kit/build-contract.json" <<'JSON'
{
  "schema_version": 1,
  "contract_id": "selftest",
  "request": {
    "summary": "Build a support risk dashboard.",
    "user_outcome": "Support leads can find aging and blocked cases before SLA breach.",
    "primary_user": "Support lead",
    "non_goals": ["Do not write back to the source ticketing system."]
  },
  "build_class": "software",
  "risk_tier": "high",
  "data_classification": "internal",
  "success_metrics": [{"name":"Risk review speed","target":"Review top queue risks in under 2 minutes","check":"Run browser proof and inspect seeded dashboard output."}],
  "constraints": [],
  "interfaces": [{"name":"Dashboard","type":"ui","owner":"Support operations","contract":"Read-only queue risk surface."}],
  "verification": {"gates":[],"commands":[],"manual_checks":[]},
  "evidence_required": ["Gate reports"],
  "unknowns": [],
  "created_at": "2026-06-24T00:00:00Z"
}
JSON
  }

  write_plan_refs() {
    root="$1"
    cat > "$root/PLAN.md" <<'EOF_PLAN'
# Plan

## dashboard
Build the support risk dashboard.

## verification
Run unit and browser proof checks.

## ac-001
Browser proof for the dashboard route.

## ac-002
Unit test for risk scoring.

## ac-003
Final delivery packet review.
EOF_PLAN
  }

  write_good() {
    root="$1"
    mkdir -p "$root/walteur-kit"
    cp "$SCRIPT_KIT/examples/enterprise-blueprint.good.json" "$root/walteur-kit/enterprise-blueprint.json"
    write_plan_refs "$root"
  }

  # A simple, single-user, no-auth, local app: build signal present (contract + code + PLAN/DESIGN) but
  # NO enterprise-scale warrant. Must be NOT_APPLICABLE, never FAIL (§14: do not impose enterprise skeleton).
  write_simple_local() {
    root="$1"
    mkdir -p "$root/walteur-kit"
    cat > "$root/walteur-kit/build-contract.json" <<'JSON'
{
  "id": "momentum",
  "build_class": "software",
  "risk_tier": "medium",
  "one_line": "A calm, local-first habit & streak tracker - dependency-free, runs from a static folder.",
  "interfaces": []
}
JSON
    cat > "$root/walteur-kit/preflight-signals.json" <<'JSON'
{
  "has_ui": true, "is_user_facing": true, "external_surface": false, "has_db": false,
  "has_auth": false, "has_payments": false, "has_api_boundary": false, "has_async": false,
  "is_ai_agent": false, "is_cloud_iac": false, "regulated": false
}
JSON
    printf '# Plan\nLocal habit tracker.\n' > "$root/PLAN.md"
    printf 'export const noop = () => 0;\n' > "$root/app.mjs"
  }

  echo "enterprise-blueprint-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/enterprise-blueprint-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "no build signal -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  # Regression (§14): a simple local single-user no-auth app has a build signal but no enterprise warrant.
  # It must NOT be forced to author an enterprise blueprint -> NOT_APPLICABLE (exit 0), not FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/enterprise-blueprint-selftest.XXXXXX")" || return 1
  write_simple_local "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "simple local no-auth app -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  # Regression: an enterprise-warranted build (risk high / auth+backend) still FAILs without a blueprint.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/enterprise-blueprint-selftest.XXXXXX")" || return 1
  write_contract_signal "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "build signal without blueprint -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/enterprise-blueprint-selftest.XXXXXX")" || return 1
  write_contract_signal "$tmp"
  write_good "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "concrete blueprint -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/enterprise-blueprint-selftest.XXXXXX")" || return 1
  write_contract_signal "$tmp"
  mkdir -p "$tmp/walteur-kit"
  cp "$SCRIPT_KIT/examples/enterprise-blueprint.vague.json" "$tmp/walteur-kit/enterprise-blueprint.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "vague blueprint -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/enterprise-blueprint-selftest.XXXXXX")" || return 1
  write_contract_signal "$tmp"
  write_good "$tmp"
  jq '.enterprise_goal = .raw_goal' "$tmp/walteur-kit/enterprise-blueprint.json" > "$tmp/b.json" && mv "$tmp/b.json" "$tmp/walteur-kit/enterprise-blueprint.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "restated raw goal -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/enterprise-blueprint-selftest.XXXXXX")" || return 1
  write_contract_signal "$tmp"
  write_good "$tmp"
  jq '.explicit_cuts = []' "$tmp/walteur-kit/enterprise-blueprint.json" > "$tmp/b.json" && mv "$tmp/b.json" "$tmp/walteur-kit/enterprise-blueprint.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "missing explicit cuts -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/enterprise-blueprint-selftest.XXXXXX")" || return 1
  write_contract_signal "$tmp"
  write_good "$tmp"
  jq '.artifact_map[0].evidence_ref = "missing-proof.md#x"' "$tmp/walteur-kit/enterprise-blueprint.json" > "$tmp/b.json" && mv "$tmp/b.json" "$tmp/walteur-kit/enterprise-blueprint.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "fake evidence ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/enterprise-blueprint-selftest.XXXXXX")" || return 1
  write_contract_signal "$tmp"
  write_good "$tmp"
  jq '.trust_model.security = "TODO"' "$tmp/walteur-kit/enterprise-blueprint.json" > "$tmp/b.json" && mv "$tmp/b.json" "$tmp/walteur-kit/enterprise-blueprint.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "placeholder content -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "enterprise-blueprint-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && {
  write_report "FAIL" "paused" "walteur-kit/PAUSED present" '[{"check":"paused","message":"WALTEUR is paused"}]'
  echo "enterprise-blueprint-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
}

if [ "${WALTEUR_ENTERPRISE_BLUEPRINT:-on}" = "off" ]; then
  write_report "SKIP" "bypass" "WALTEUR_ENTERPRISE_BLUEPRINT=off" "[]"
  echo "enterprise-blueprint-gate verdict: SKIP - bypassed via WALTEUR_ENTERPRISE_BLUEPRINT=off -> $REPORT" >&2
  exit 0
fi

for t in jq grep sed find wc tr; do
  if ! have "$t"; then
    write_report "SKIP" "tool-missing" "$t not installed" "[]"
    echo "enterprise-blueprint-gate SKIP - required tool '$t' not installed (recorded, not silent-green)." >&2
    exit 0
  fi
done

DIR="${input_dir:-$ROOT}"
if [ ! -d "$DIR" ]; then
  write_report "SKIP" "bad-arg" "not a directory: $DIR" "[]"
  echo "enterprise-blueprint-gate SKIP - '$DIR' is not a directory." >&2
  exit 0
fi

detect_build_signal "$DIR"
if [ "$BUILD_SIGNAL" -eq 0 ]; then
  write_report "NOT_APPLICABLE" "not-applicable" "no meaningful build signal" "[]"
  echo "enterprise-blueprint-gate verdict: NOT_APPLICABLE - no build signal under '$DIR' -> $REPORT" >&2
  exit 0
fi

# Applicability guard (§14: do not impose an enterprise skeleton on a simple build). A full enterprise
# blueprint (trust_model authn/authz, multi-tenant operating model, SOC2-style auditability) is only
# warranted for enterprise-scale builds. A simple local / single-user / no-auth app is NOT_APPLICABLE.
if ! enterprise_warranted; then
  write_report "NOT_APPLICABLE" "not-applicable" "build signal present ($SIGNAL_REASON) but no enterprise-scale warrant (risk_tier high/regulated, regulated, or auth+backend/SaaS surface absent)" "[]"
  echo "enterprise-blueprint-gate verdict: NOT_APPLICABLE - no enterprise-scale warrant; an enterprise blueprint is not imposed on a simple build -> $REPORT" >&2
  exit 0
fi

BLUEPRINT=""
for cand in "$KIT/enterprise-blueprint.json" "$ROOT/enterprise-blueprint.json" "$DIR/walteur-kit/enterprise-blueprint.json" "$DIR/enterprise-blueprint.json"; do
  if [ -f "$cand" ]; then
    BLUEPRINT="$cand"
    break
  fi
done
BLUEPRINT_REL="${BLUEPRINT#"$ROOT"/}"

if [ -z "$BLUEPRINT" ]; then
  BLUEPRINT_REL="walteur-kit/enterprise-blueprint.json"
  write_report "FAIL" "missing" "build signal present ($SIGNAL_REASON) but enterprise-blueprint.json is absent" \
    '[{"check":"enterprise-blueprint.present","message":"Create walteur-kit/enterprise-blueprint.json so the build target is concrete before PLAN advances."}]'
  echo "enterprise-blueprint-gate verdict: FAIL - build signal present ($SIGNAL_REASON) but enterprise-blueprint.json is absent -> $REPORT" >&2
  exit 2
fi

if ! jq empty "$BLUEPRINT" >/dev/null 2>&1; then
  write_report "FAIL" "invalid-json" "enterprise blueprint '$BLUEPRINT_REL' is invalid JSON" \
    "$(jq -n --arg f "$BLUEPRINT_REL" '[{"check":"enterprise-blueprint.json","file":$f,"message":"The blueprint is not valid JSON."}]')"
  echo "enterprise-blueprint-gate verdict: FAIL - '$BLUEPRINT_REL' invalid JSON -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

extra_root="$(jq -r '
  keys[] | select((["schema_version","blueprint_id","raw_goal","enterprise_goal","primary_user","owner_or_buyer","job_map","artifact_map","surface_map","acceptance_suite","trust_model","operating_model","quality_bar","explicit_cuts","final_delivery_packet","ts"] | index(.)) | not)
' "$BLUEPRINT" 2>/dev/null | paste -sd ', ' -)"
[ -n "$extra_root" ] && add_finding "additional_properties" "unknown root fields are not allowed: $extra_root"

schema_version="$(jq_file '.schema_version // empty')"
[ "$schema_version" = "1" ] || add_finding "schema_version" "schema_version must be 1"
require_string "blueprint_id" ".blueprint_id" 1
require_string "raw_goal" ".raw_goal" 8
require_string "enterprise_goal" ".enterprise_goal" 24
require_string "primary_user.role" ".primary_user.role" 3
require_string "primary_user.pain" ".primary_user.pain" 12
require_string "primary_user.success_moment" ".primary_user.success_moment" 12
require_string "owner_or_buyer.role" ".owner_or_buyer.role" 3
require_string "owner_or_buyer.decision_metric" ".owner_or_buyer.decision_metric" 12
require_string "trust_model.authn" ".trust_model.authn" 8
require_string "trust_model.authz" ".trust_model.authz" 8
require_string "trust_model.data_policy" ".trust_model.data_policy" 12
require_string "trust_model.privacy" ".trust_model.privacy" 12
require_string "trust_model.security" ".trust_model.security" 12
require_string "trust_model.auditability" ".trust_model.auditability" 12
require_string "operating_model.observability" ".operating_model.observability" 12
require_string "operating_model.support" ".operating_model.support" 12
require_string "operating_model.rollback" ".operating_model.rollback" 12
require_string "operating_model.incident_response" ".operating_model.incident_response" 12
require_string "operating_model.ownership" ".operating_model.ownership" 12
require_string "quality_bar.must_feel_like" ".quality_bar.must_feel_like" 12
require_string "quality_bar.must_not_feel_like" ".quality_bar.must_not_feel_like" 12
require_string "quality_bar.reference_quality" ".quality_bar.reference_quality" 12
require_string "quality_bar.concreteness_floor" ".quality_bar.concreteness_floor" 12

raw_goal="$(jq_file '.raw_goal // empty')"
enterprise_goal="$(jq_file '.enterprise_goal // empty')"
if [ -n "$raw_goal" ] && [ -n "$enterprise_goal" ] && [ "$(norm_text "$raw_goal")" = "$(norm_text "$enterprise_goal")" ]; then
  add_finding "enterprise_goal.restated" "enterprise_goal must upgrade the raw goal, not restate it"
fi

if ! jq -e '.job_map | type == "array" and length >= 1' "$BLUEPRINT" >/dev/null 2>&1; then
  add_finding "job_map.shape" "job_map must contain at least one job"
else
  bad_jobs="$(jq -r '
    (.job_map // [])[]
    | select((.job|type!="string" or length<8) or (.current_workaround|type!="string" or length<8) or (.desired_outcome|type!="string" or length<8))
    | (.job // "<missing-job>")
  ' "$BLUEPRINT" 2>/dev/null | paste -sd ', ' -)"
  [ -n "$bad_jobs" ] && add_finding "job_map.entries" "invalid job_map entries: $bad_jobs"
fi

if ! jq -e '.artifact_map | type == "array" and length >= 2' "$BLUEPRINT" >/dev/null 2>&1; then
  add_finding "artifact_map.shape" "artifact_map must contain at least two artifacts"
else
  bad_artifacts="$(jq -r '
    (.artifact_map // [])[]
    | select((.artifact|type!="string" or length<3)
        or (.type as $t | ["ui","api","workflow","document","data","ai","iac","test","ops"] | index($t) | not)
        or (.purpose|type!="string" or length<12)
        or (.owner|type!="string" or length<3)
        or (.done_when|type!="string" or length<12)
        or (.evidence_ref|type!="string" or length<1))
    | (.artifact // "<missing-artifact>")
  ' "$BLUEPRINT" 2>/dev/null | paste -sd ', ' -)"
  [ -n "$bad_artifacts" ] && add_finding "artifact_map.entries" "invalid artifact_map entries: $bad_artifacts"
fi

for surface in ui api data jobs docs ops; do
  if ! jq -e --arg s "$surface" '.surface_map[$s] | type == "array"' "$BLUEPRINT" >/dev/null 2>&1; then
    add_finding "surface_map.$surface" "surface_map.$surface must be an array"
  fi
done
surface_total="$(jq '[.surface_map.ui[]?, .surface_map.api[]?, .surface_map.data[]?, .surface_map.jobs[]?, .surface_map.docs[]?, .surface_map.ops[]?] | length' "$BLUEPRINT" 2>/dev/null || echo 0)"
if [ "${surface_total:-0}" -lt 3 ]; then
  add_finding "surface_map.concrete" "surface_map must name at least three concrete surfaces across the build"
fi

if ! jq -e '.acceptance_suite | type == "array" and length >= 3' "$BLUEPRINT" >/dev/null 2>&1; then
  add_finding "acceptance_suite.shape" "acceptance_suite must contain at least three acceptance criteria"
else
  bad_acceptance="$(jq -r '
    (.acceptance_suite // [])[]
    | select((.id|type!="string" or (test("^AC-[0-9]{3}$")|not))
        or (.statement|type!="string" or length<16)
        or (.verification|type!="string" or length<12)
        or (.evidence_ref|type!="string" or length<1))
    | (.id // "<missing-id>")
  ' "$BLUEPRINT" 2>/dev/null | paste -sd ', ' -)"
  [ -n "$bad_acceptance" ] && add_finding "acceptance_suite.entries" "invalid acceptance entries: $bad_acceptance"
  dup_acceptance="$(jq -r '(.acceptance_suite // [])[].id' "$BLUEPRINT" 2>/dev/null | sort | uniq -d | paste -sd ', ' -)"
  [ -n "$dup_acceptance" ] && add_finding "acceptance_suite.unique" "duplicate acceptance IDs: $dup_acceptance"
fi

if ! jq -e '.explicit_cuts | type == "array" and length >= 1' "$BLUEPRINT" >/dev/null 2>&1; then
  add_finding "explicit_cuts.shape" "explicit_cuts must contain at least one conscious cut"
else
  bad_cuts="$(jq -r '
    (.explicit_cuts // [])[]
    | select((.item|type!="string" or length<3) or (.reason|type!="string" or length<12) or (.risk|type!="string" or length<8) or (.review_trigger|type!="string" or length<8))
    | (.item // "<missing-item>")
  ' "$BLUEPRINT" 2>/dev/null | paste -sd ', ' -)"
  [ -n "$bad_cuts" ] && add_finding "explicit_cuts.entries" "invalid explicit_cuts entries: $bad_cuts"
fi

if ! jq -e '.final_delivery_packet.must_include | type == "array" and length >= 6' "$BLUEPRINT" >/dev/null 2>&1; then
  add_finding "final_delivery_packet.shape" "final_delivery_packet.must_include must contain at least six items"
fi
for item in "what changed" "how to use it" "proof read" "known gaps" "rollback or recovery" "next action"; do
  if ! jq -e --arg item "$item" '(.final_delivery_packet.must_include // []) | index($item)' "$BLUEPRINT" >/dev/null 2>&1; then
    add_finding "final_delivery_packet.$item" "final delivery packet must include: $item"
  fi
done

if ! jq -e '.ts | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$BLUEPRINT" >/dev/null 2>&1; then
  add_finding "ts" "ts must be an ISO-like timestamp"
fi

if grep -Eiq '(<[^>]+>|\b(todo|tbd|lorem|placeholder|dummy)\b)' "$BLUEPRINT"; then
  add_finding "placeholder" "enterprise blueprint contains placeholder text"
fi

thin_text="$(jq -r '[.. | strings] | join("\n")' "$BLUEPRINT" 2>/dev/null | grep -Eino '\b(better ux|it works|best practice|enterprise-grade|make it scalable|ensure security|improve user experience)\b' | head -10 | paste -sd '; ' -)"
[ -n "$thin_text" ] && add_finding "concreteness" "thin quality language needs concrete user, control, metric, or proof: $thin_text"

while IFS=$'\t' read -r label ref; do
  [ -n "$label" ] || continue
  check_ref_exists "$label" "$ref"
done <<EOF_REFS
$(jq -r '(.artifact_map // [])[]? | ["artifact_map.evidence_ref", .evidence_ref] | @tsv' "$BLUEPRINT" 2>/dev/null)
$(jq -r '(.acceptance_suite // [])[]? | ["acceptance_suite.evidence_ref", .evidence_ref] | @tsv' "$BLUEPRINT" 2>/dev/null)
EOF_REFS

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "applicable" "$failures enterprise-blueprint violation(s)" "$findings"
  echo "enterprise-blueprint-gate verdict: FAIL - $failures violation(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "applicable" "enterprise blueprint is concrete for signal: $SIGNAL_REASON" "$findings"
echo "enterprise-blueprint-gate verdict: PASS - enterprise blueprint concrete -> $REPORT" >&2
exit 0
