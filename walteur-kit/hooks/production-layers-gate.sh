#!/usr/bin/env bash
# WALTEUR production-layers-gate - typed 13-layer production reality contract.
#
# Contract:
#   - No production/code/product signal => NOT_APPLICABLE, exit 0.
#   - Signal but walteur-kit/layers.json absent => FAIL, exit 2.
#   - Missing, duplicate, placeholder, malformed, or unsigned deferred layer => FAIL, exit 2.
#   - All 13 layers present and owned => PASS, exit 0.
#
# Report:
#   walteur-kit/production-layers-report.json
#
# Bypass:
#   WALTEUR_PRODUCTION_LAYERS=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "production-layers-gate - typed 13-layer production reality contract."
  printf '%s\n' "usage: bash production-layers-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/production-layers-report.json - fix recipes: walteur-kit/REMEDIATION.md (## production-layers-gate)"
  printf '%s\n' "bypass: WALTEUR_PRODUCTION_LAYERS=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

input_dir="${1:-}"
if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "$WALTEUR_ROOT" ]; then
  ROOT="$(cd "$WALTEUR_ROOT" && pwd)"
elif [ -n "$input_dir" ] && [ -d "$input_dir" ]; then
  ROOT="$(cd "$input_dir" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
KIT="$ROOT/walteur-kit"
LAYERS="$KIT/layers.json"
REPORT="$KIT/production-layers-report.json"
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
      --arg layers "${LAYERS#"$ROOT"/}" --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"production-layers-gate", mode:$mode, layers_file:$layers, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"production-layers-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

detect_signal() {
  SIGNAL=0
  SIGNAL_REASON=""
  scan_dir="${1:-$ROOT}"
  [ -d "$scan_dir" ] || scan_dir="$ROOT"

  if [ -f "$KIT/build-contract.json" ] && have jq; then
    class="$(jq -r '.build_class // empty' "$KIT/build-contract.json" 2>/dev/null || true)"
    case "$class" in
      software|data-ai|cloud-iac|mixed)
        SIGNAL=1
        SIGNAL_REASON="build-contract class '$class'"
        return 0 ;;
    esac
  fi

  for product_file in "$KIT/PRD.md" "$KIT/benchmark.md" "$KIT/PRODUCT-STANDARD.md"; do
    if [ -f "$product_file" ]; then
      SIGNAL=1
      SIGNAL_REASON="$(basename "$product_file") exists"
      return 0
    fi
  done

  if find "$scan_dir" \
      \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/walteur-kit/*' \) -prune -o \
      -type f \( -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' -o -name '*.html' -o -name 'Dockerfile' -o -name '*.tf' -o -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null \
      | grep -q .; then
    SIGNAL=1
    SIGNAL_REASON="source, UI, or infrastructure files present"
    return 0
  fi
}

# Scale guard (WALTEUR §14: never impose a SaaS/enterprise skeleton on a simple build).
# The 13-layer production-reality manifest is an enterprise artifact. It is only WARRANTED
# when the build actually operates at production-layer scale: a high/regulated risk tier, OR
# a preflight signal that puts a server/infra/multi-tenant layer in scope (auth, db, payments,
# api boundary, async, external surface, cloud/IaC, regulated, agent). A low/medium-risk build
# whose preflight declares every such layer out of scope (e.g. a local single-user UI app) is
# NOT_APPLICABLE: it has a software signal but no production layers to contract.
# If no build-contract / preflight evidence exists at all, we are conservative and stay APPLICABLE
# (a bare source tree with no contract gets the full gate — absence of preflight is not proof of
# small scale). This guard only DOWNGRADES when the build itself attests it is small.
production_scale_applicable() {
  SCALE_REASON=""
  contract="$KIT/build-contract.json"
  preflight="$KIT/preflight-signals.json"

  # No evidence to judge scale => stay applicable (fail-closed for real software).
  if [ ! -f "$contract" ] && [ ! -f "$preflight" ]; then
    SCALE_REASON="no build-contract/preflight; default to applicable"
    return 0
  fi
  have jq || { SCALE_REASON="jq unavailable; default to applicable"; return 0; }

  # High/regulated risk tier => always applicable (a genuine $50-100M SaaS must face this).
  if [ -f "$contract" ]; then
    tier="$(jq -r '.risk_tier // empty' "$contract" 2>/dev/null || true)"
    case "$tier" in
      high|regulated)
        SCALE_REASON="risk_tier '$tier'"
        return 0 ;;
    esac
  fi

  # Any production-scale preflight signal true => applicable.
  if [ -f "$preflight" ]; then
    scale_sig="$(jq -r '
      [ (.has_auth // false), (.has_db // false), (.has_payments // false),
        (.has_api_boundary // false), (.has_async // false),
        (.external_surface // false), (.is_cloud_iac // false),
        (.regulated // false), (.is_ai_agent // false) ]
      | any
    ' "$preflight" 2>/dev/null || echo "false")"
    if [ "$scale_sig" = "true" ]; then
      on="$(jq -r '
        to_entries
        | map(select(.key as $k
            | (["has_auth","has_db","has_payments","has_api_boundary","has_async",
                "external_surface","is_cloud_iac","regulated","is_ai_agent"] | index($k)))
            | select(.value == true) | .key)
        | join(", ")
      ' "$preflight" 2>/dev/null || true)"
      SCALE_REASON="production-scale preflight signal(s): ${on:-set}"
      return 0
    fi
    # Preflight exists and every production-scale layer is out of scope, and tier is low/medium
    # => NOT applicable.
    SCALE_REASON="low/medium risk and no production-scale layer in scope (preflight declares auth/db/payments/api/async/external/cloud/regulated/agent all false)"
    return 1
  fi

  # Contract present without preflight: only low/medium tier reaches here (high/regulated
  # returned applicable above). Without preflight we cannot prove layers are out of scope,
  # so stay applicable (conservative).
  SCALE_REASON="contract present, no preflight; default to applicable"
  return 0
}

expected_name() {
  case "$1" in
    1) echo "client_experience" ;;
    2) echo "application_core" ;;
    3) echo "data_model" ;;
    4) echo "auth_permissions" ;;
    5) echo "external_integrations" ;;
    6) echo "hosting_runtime" ;;
    7) echo "ci_cd" ;;
    8) echo "security_supply_chain" ;;
    9) echo "rate_limiting" ;;
    10) echo "caching_cdn" ;;
    11) echo "scaling_capacity" ;;
    12) echo "observability_support" ;;
    13) echo "backup_restore_dr" ;;
    *) echo "" ;;
  esac
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
    echo "production-layers-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_layers() {
    root="$1"
    mode="${2:-good}"
    mkdir -p "$root/walteur-kit" "$root/src"
    printf '<div>app</div>\n' > "$root/src/App.tsx"
    jq -n --arg mode "$mode" '
      def layer($id; $name):
        {
          id: $id,
          name: $name,
          status: "planned",
          owner: "Owner",
          rationale: ("Layer " + ($id|tostring) + " is addressed for this build."),
          folder_or_artifact: "PLAN.md",
          evidence_ref: "PLAN.md",
          verification: "Review PLAN.md and run the matching gate."
        };
      {
        schema_version: 1,
        contract_id: "selftest-layers",
        date: "2026-06-22",
        production_layers: [
          layer(1;"client_experience"),
          layer(2;"application_core"),
          layer(3;"data_model"),
          layer(4;"auth_permissions"),
          layer(5;"external_integrations"),
          layer(6;"hosting_runtime"),
          layer(7;"ci_cd"),
          layer(8;"security_supply_chain"),
          layer(9;"rate_limiting"),
          layer(10;"caching_cdn"),
          layer(11;"scaling_capacity"),
          layer(12;"observability_support"),
          layer(13;"backup_restore_dr")
        ]
      }
      | if $mode == "missing" then .production_layers = (.production_layers | map(select(.id != 13))) else . end
      | if $mode == "duplicate" then .production_layers[12].id = 12 else . end
      | if $mode == "unsigned_deferred" then .production_layers[8].status = "deferred" | del(.production_layers[8].risk_owner, .production_layers[8].review_trigger) else . end
      | if $mode == "placeholder" then .production_layers[0].owner = "TODO" else . end
    ' > "$root/walteur-kit/layers.json"
    printf '# Plan\n' > "$root/PLAN.md"
  }

  echo "production-layers-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/production-layers-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src"
  printf 'print("cli")\n' > "$tmp/src/main.py"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "no production signal -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/production-layers-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "signal without layers.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/production-layers-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  printf '{ bad json\n' > "$tmp/walteur-kit/layers.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "malformed layers.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/production-layers-selftest.XXXXXX")" || return 1
  write_layers "$tmp" good
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "complete 13-layer contract -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/production-layers-selftest.XXXXXX")" || return 1
  write_layers "$tmp" missing
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "missing layer -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/production-layers-selftest.XXXXXX")" || return 1
  write_layers "$tmp" duplicate
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "duplicate layer id -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/production-layers-selftest.XXXXXX")" || return 1
  write_layers "$tmp" unsigned_deferred
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "deferred layer without risk owner -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/production-layers-selftest.XXXXXX")" || return 1
  write_layers "$tmp" placeholder
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "placeholder layer field -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # §14 scale guard regressions ------------------------------------------------

  # Simple local app: software signal + UI files, but low/medium risk and every
  # production-scale preflight signal false, and NO layers.json. Must be
  # NOT_APPLICABLE (exit 0), not FAIL - we don't impose the 13-layer SaaS skeleton.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/production-layers-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  printf '{"id":"local","build_class":"software","risk_tier":"medium"}\n' > "$tmp/walteur-kit/build-contract.json"
  printf '{"has_ui":true,"is_user_facing":true,"external_surface":false,"has_db":false,"has_auth":false,"has_payments":false,"has_api_boundary":false,"has_async":false,"is_ai_agent":false,"is_cloud_iac":false,"regulated":false}\n' > "$tmp/walteur-kit/preflight-signals.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "simple local app (no prod-scale signal) -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  # Genuine production SaaS: high risk + has_auth + has_db in scope, but layers.json
  # absent. The gate MUST still bite (FAIL, exit 2) - the scale guard does not let
  # real production software off the hook.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/production-layers-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  printf '{"id":"saas","build_class":"software","risk_tier":"high"}\n' > "$tmp/walteur-kit/build-contract.json"
  printf '{"has_ui":true,"is_user_facing":true,"external_surface":true,"has_db":true,"has_auth":true,"has_payments":true,"has_api_boundary":true,"has_async":true,"is_ai_agent":false,"is_cloud_iac":true,"regulated":false}\n' > "$tmp/walteur-kit/preflight-signals.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "high-risk SaaS without layers.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # Medium-risk build that nonetheless has a production-scale layer in scope
  # (has_db true) but no layers.json => still applicable, FAIL. Proves the guard
  # keys on actual layers-in-scope, not on risk_tier alone.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/production-layers-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  printf '{"id":"svc","build_class":"software","risk_tier":"medium"}\n' > "$tmp/walteur-kit/build-contract.json"
  printf '{"has_ui":true,"is_user_facing":true,"external_surface":false,"has_db":true,"has_auth":false,"has_payments":false,"has_api_boundary":false,"has_async":false,"is_ai_agent":false,"is_cloud_iac":false,"regulated":false}\n' > "$tmp/walteur-kit/preflight-signals.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "medium-risk with has_db in scope, no layers.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "production-layers-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && {
  write_report "FAIL" "paused" "walteur-kit/PAUSED present" '[{"check":"paused","message":"WALTEUR is paused"}]'
  echo "production-layers-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
}

if [ "${WALTEUR_PRODUCTION_LAYERS:-on}" = "off" ]; then
  write_report "SKIP" "bypass" "WALTEUR_PRODUCTION_LAYERS=off" "[]"
  echo "production-layers-gate verdict: SKIP - bypassed via WALTEUR_PRODUCTION_LAYERS=off -> $REPORT" >&2
  exit 0
fi

for t in jq grep find sed; do
  if ! have "$t"; then
    write_report "SKIP" "tool-missing" "$t not installed" "[]"
    echo "production-layers-gate SKIP - required tool '$t' not installed (recorded, not silent-green)." >&2
    exit 0
  fi
done

DIR="${input_dir:-$ROOT}"
if [ ! -d "$DIR" ]; then
  write_report "SKIP" "bad-arg" "not a directory: $DIR" "[]"
  echo "production-layers-gate SKIP - '$DIR' is not a directory." >&2
  exit 0
fi

detect_signal "$DIR"
if [ "$SIGNAL" -eq 0 ]; then
  write_report "NOT_APPLICABLE" "not-applicable" "no production-layer signal" "[]"
  echo "production-layers-gate verdict: NOT_APPLICABLE - no production-layer signal under '$DIR' -> $REPORT" >&2
  exit 0
fi

# §14 scale guard: software signal present, but if the build attests it has no production-scale
# layers (low/medium risk + every server/infra/multi-tenant preflight signal false), the 13-layer
# enterprise manifest is out of scope. Emit NOT_APPLICABLE rather than imposing a SaaS skeleton.
if ! production_scale_applicable; then
  write_report "NOT_APPLICABLE" "not-applicable" \
    "software signal ($SIGNAL_REASON) but no production-layer scale: $SCALE_REASON" "[]"
  echo "production-layers-gate verdict: NOT_APPLICABLE - $SCALE_REASON ($SIGNAL_REASON) -> $REPORT" >&2
  exit 0
fi

if [ ! -f "$LAYERS" ]; then
  write_report "FAIL" "missing" "production signal present ($SIGNAL_REASON) but walteur-kit/layers.json is absent" \
    '[{"check":"layers.present","message":"Create walteur-kit/layers.json from walteur-kit/scaffold/layers.template.json and mark every layer owned, evidenced, or deferred."}]'
  echo "production-layers-gate verdict: FAIL - production signal present ($SIGNAL_REASON) but layers.json is absent -> $REPORT" >&2
  exit 2
fi

if ! jq empty "$LAYERS" >/dev/null 2>&1; then
  write_report "FAIL" "invalid-json" "walteur-kit/layers.json is invalid JSON" \
    '[{"check":"layers.json","message":"walteur-kit/layers.json must be valid JSON"}]'
  echo "production-layers-gate verdict: FAIL - layers.json invalid -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

extra_root="$(jq -r '
  keys[] | select(([
    "schema_version","contract_id","date","production_layers","layers","edges","forbidden",
    "9","10","confidentiality","ai-safety-R1","ai-safety-R2","ai-safety-R3"
  ] | index(.)) | not)
' "$LAYERS" 2>/dev/null | paste -sd ', ' -)"
[ -n "$extra_root" ] && add_finding "additional_properties" "unknown root fields are not allowed: $extra_root"

if ! jq -e '.schema_version == 1' "$LAYERS" >/dev/null 2>&1; then
  add_finding "schema_version" "schema_version must be 1"
fi

for field in contract_id date; do
  if ! jq -e --arg f "$field" '.[$f] | type=="string" and length>0' "$LAYERS" >/dev/null 2>&1; then
    add_finding "$field" "$field must be a non-empty string"
  fi
done

date_val="$(jq -r '.date // empty' "$LAYERS" 2>/dev/null || true)"
if ! printf '%s' "$date_val" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  add_finding "date.format" "date must be YYYY-MM-DD"
fi

if ! jq -e '.production_layers | type=="array"' "$LAYERS" >/dev/null 2>&1; then
  add_finding "production_layers.shape" "production_layers must be an array"
else
  count="$(jq '.production_layers | length' "$LAYERS" 2>/dev/null || echo 0)"
  [ "$count" -eq 13 ] || add_finding "production_layers.count" "production_layers must contain exactly 13 entries, got $count"

  duplicate_ids="$(jq -r '.production_layers[]?.id // empty' "$LAYERS" 2>/dev/null | sort | uniq -d | paste -sd ', ' -)"
  [ -n "$duplicate_ids" ] && add_finding "production_layers.unique" "duplicate layer id(s): $duplicate_ids"

  for id in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
    expected="$(expected_name "$id")"
    if ! jq -e --argjson id "$id" '[.production_layers[]? | select(.id == $id)] | length == 1' "$LAYERS" >/dev/null 2>&1; then
      add_finding "production_layers.$id" "missing required production layer id $id ($expected)"
      continue
    fi
    actual="$(jq -r --argjson id "$id" '.production_layers[] | select(.id == $id) | .name // empty' "$LAYERS" 2>/dev/null || true)"
    [ "$actual" = "$expected" ] || add_finding "production_layers.$id.name" "layer $id name must be '$expected', got '${actual:-<empty>}'"
  done

  bad_entries="$(jq -r '
    (.production_layers // [])[]
    | select((.id|type!="number")
        or (.name|type!="string" or length==0)
        or (.owner|type!="string" or length==0)
        or (.rationale|type!="string" or length==0)
        or (.evidence_ref|type!="string" or length==0)
        or (.verification|type!="string" or length==0)
        or (.status as $s | ["in_scope","planned","built","verified","out_of_scope","deferred"] | index($s) | not))
    | (.id|tostring)
  ' "$LAYERS" 2>/dev/null | paste -sd ', ' -)"
  [ -n "$bad_entries" ] && add_finding "production_layers.entries" "invalid layer entries: $bad_entries"

  active_missing_artifact="$(jq -r '
    (.production_layers // [])[]
    | select((.status | IN("in_scope","planned","built","verified")) and ((.folder_or_artifact // "") | length == 0))
    | (.id|tostring)
  ' "$LAYERS" 2>/dev/null | paste -sd ', ' -)"
  [ -n "$active_missing_artifact" ] && add_finding "production_layers.folder_or_artifact" "active layers need folder_or_artifact: $active_missing_artifact"

  unsigned_deferrals="$(jq -r '
    (.production_layers // [])[]
    | select((.status | IN("out_of_scope","deferred"))
        and (((.risk_owner // "") | length == 0) or ((.review_trigger // "") | length == 0)))
    | (.id|tostring)
  ' "$LAYERS" 2>/dev/null | paste -sd ', ' -)"
  [ -n "$unsigned_deferrals" ] && add_finding "production_layers.deferrals" "out_of_scope/deferred layers need risk_owner and review_trigger: $unsigned_deferrals"
fi

if jq -e 'any(.. | strings; test("(<[^>]+>|\\b(todo|tbd|lorem|placeholder|dummy)\\b)"; "i"))' "$LAYERS" >/dev/null 2>&1; then
  add_finding "placeholder" "layers.json contains placeholder text"
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "applicable" "$failures production-layer violation(s)" "$findings"
  echo "production-layers-gate verdict: FAIL - $failures violation(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "applicable" "13-layer production contract complete for signal: $SIGNAL_REASON" "$findings"
echo "production-layers-gate verdict: PASS - 13-layer production contract complete -> $REPORT" >&2
exit 0
