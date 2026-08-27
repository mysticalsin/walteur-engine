#!/usr/bin/env bash
# WALTEUR product-standard-gate - product/company completeness gate.
#
# Contract:
#   - No product signal                         => NOT_APPLICABLE, exit 0.
#   - Product signal but PRODUCT-STANDARD absent => FAIL, exit 2.
#   - Stub, placeholder, malformed, or incomplete standard => FAIL, exit 2.
#   - Complete standard with existing evidence refs => PASS, exit 0.
#
# Product signal:
#   - UI source files exist, OR
#   - walteur-kit/PRD.md, walteur-kit/benchmark.md, or walteur-kit/PRODUCT-STANDARD.md exists, OR
#   - PLAN.md or build-contract.json declares a non-tooling category/product interface.
#
# Report:
#   walteur-kit/product-standard-report.json
#
# Bypass:
#   WALTEUR_PRODUCT_STANDARD=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "product-standard-gate - product/company completeness gate."
  printf '%s\n' "usage: bash product-standard-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/product-standard-report.json - fix recipes: walteur-kit/REMEDIATION.md (## product-standard-gate)"
  printf '%s\n' "bypass: WALTEUR_PRODUCT_STANDARD=off (recorded, not free)"
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
REPORT="$KIT/product-standard-report.json"
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
      --arg standard "${STANDARD_REL:-walteur-kit/PRODUCT-STANDARD.md}" \
      --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"product-standard-gate", mode:$mode, standard:$standard, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"product-standard-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

jq_json() {
  printf '%s' "$JSON_BLOCK" | jq -r "$1" 2>/dev/null || true
}

require_string() {
  label="$1"
  filter="$2"
  value="$(jq_json "$filter // empty")"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    add_finding "$label" "$label must be a non-empty string"
  fi
}

check_ref_exists() {
  label="$1"
  filter="$2"
  ref="$(jq_json "$filter // empty")"
  [ -n "$ref" ] && [ "$ref" != "null" ] || return 0
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

detect_product_signal() {
  PRODUCT_SIGNAL=0
  SIGNAL_REASON=""
  UI_COUNT=0

  scan_dir="${1:-$ROOT}"
  [ -d "$scan_dir" ] || scan_dir="$ROOT"

  PRUNE=( \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/storybook-static/*' -o -path '*/walteur-kit/*' \) -prune -o )
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      *.test.*|*.spec.*|*.stories.*) continue ;;
    esac
    UI_COUNT=$((UI_COUNT+1))
  done < <(find "$scan_dir" "${PRUNE[@]}" \
    -type f \( -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' -o -name '*.html' \) -print 2>/dev/null)

  if [ "$UI_COUNT" -gt 0 ]; then
    PRODUCT_SIGNAL=1
    SIGNAL_REASON="UI source files present (count=$UI_COUNT)"
    return 0
  fi

  for product_file in "$KIT/PRODUCT-STANDARD.md" "$KIT/PRD.md" "$KIT/benchmark.md"; do
    if [ -f "$product_file" ]; then
      PRODUCT_SIGNAL=1
      SIGNAL_REASON="$(basename "$product_file") exists"
      return 0
    fi
  done

  for candidate in "$ROOT/PLAN.md" "$KIT/build-contract.json"; do
    [ -f "$candidate" ] || continue
    if [ "$(basename "$candidate")" = "build-contract.json" ]; then
      if jq -e '(.interfaces // [])[]? | select(.type == "ui")' "$candidate" >/dev/null 2>&1; then
        PRODUCT_SIGNAL=1
        SIGNAL_REASON="build-contract.json declares a ui interface"
        return 0
      fi
      continue
    fi
    cat_val="$(grep -i '^category:' "$candidate" 2>/dev/null | head -1 | sed 's/^[Cc]ategory:[[:space:]]*//' | tr -d '"' || true)"
    if [ -n "$cat_val" ] && ! printf '%s' "$cat_val" | grep -Eqi '^(cli|library|script|internal-tool|cron|sdk)$'; then
      PRODUCT_SIGNAL=1
      SIGNAL_REASON="PLAN.md declares product category '$cat_val'"
      return 0
    fi
  done
}

# scale_warrants_standard: returns 0 (applies) / 1 (NOT_APPLICABLE).
#
# The PRODUCT-STANDARD manifest is a COMMERCIAL/company-scale artifact: business model,
# unit economics, authn/authz, launch go-to-market, billing surface, multi-role users.
# Per WALTEUR §14 ("adapt to the idea; NEVER impose a SaaS/enterprise skeleton on a simple
# build") it must SCALE to the build. A local, single-user, no-auth, no-server,
# dependency-free app must NOT be forced to author a go-to-market/business-model manifest
# merely because one UI file exists.
#
# Policy: the manifest applies UNLESS the build PROVES it is low-scale. "Low-scale proven"
# means a build-contract.json or preflight-signals.json is present AND it shows:
#   - risk_tier is NOT high/regulated, AND
#   - none of the commercial-scale signals are set:
#       has_auth, has_payments, has_db, external_surface, has_api_boundary
# Absent any signals file we DO NOT assume low-scale (fail-closed: gate still applies), so
# a bare UI build with no contract keeps facing the standard, and a genuine $50-100M SaaS
# (risk high/regulated, or has_auth+has_db+external_surface) always faces it.
scale_warrants_standard() {
  APPLY_REASON=""
  bc="$KIT/build-contract.json"
  ps="$KIT/preflight-signals.json"

  # No machine-readable scale profile at all -> cannot prove low-scale -> gate applies.
  if [ ! -f "$bc" ] && [ ! -f "$ps" ]; then
    APPLY_REASON="no scale profile present; standard applies (fail-closed)"
    return 0
  fi

  risk=""
  if [ -f "$bc" ]; then
    risk="$(jq -r '(.risk_tier // "") | ascii_downcase' "$bc" 2>/dev/null || true)"
  fi
  case "$risk" in
    high|regulated)
      APPLY_REASON="risk_tier '$risk' warrants product standard"
      return 0
      ;;
  esac

  # Any commercial-scale signal (auth, payments, shared db, external/public surface,
  # api boundary) means this is a real product, not a local single-user app.
  if [ -f "$ps" ]; then
    for sig in has_auth has_payments has_db external_surface has_api_boundary; do
      val="$(jq -r --arg k "$sig" '(.[$k] // false) | tostring' "$ps" 2>/dev/null || echo false)"
      if [ "$val" = "true" ]; then
        APPLY_REASON="preflight signal '$sig'=true warrants product standard"
        return 0
      fi
    done
  fi

  # Profile present and proves low scale: local/single-user, no auth/payments/db/surface,
  # risk below high/regulated -> the commercial product-standard manifest is out of scope.
  APPLY_REASON="low-scale local build (risk_tier '${risk:-unset}', no auth/payments/db/external_surface/api_boundary)"
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
    echo "product-standard-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_refs() {
    root="$1"
    mkdir -p "$root/walteur-kit" "$root/src"
    printf '# Plan\nCategory: support-saas\n\n## Tasks\n- T1 onboarding\n' > "$root/PLAN.md"
    printf '# Design\ncolors: black white\nlayout: app shell\n' > "$root/DESIGN.md"
    printf '# PRD\n\n## Problem\nSupport leaders need faster decisions.\n\n## Target user\nWhen managing queues, they want current risk, so they can act.\n\n## Success metric\nTarget 40%% activation.\n\n## Scope\nRICE-ranked scope.\n\n## Not doing\nNo marketplace.\n' > "$root/walteur-kit/PRD.md"
    cat > "$root/walteur-kit/benchmark.md" <<'EOF'
# Benchmark
```json
{
  "category": "support operations",
  "date": "2026-06-22",
  "leaders": ["Zendesk", "Intercom", "Freshdesk"],
  "table_stakes": [
    { "feature": "queue visibility", "status": "planned", "ref": "PLAN.md#T1" }
  ]
}
```
EOF
  }

  write_standard() {
    root="$1"
    omit_area="${2:-}"
    placeholder="${3:-no}"
    mkdir -p "$root/walteur-kit"
    cat > "$root/walteur-kit/PRODUCT-STANDARD.md" <<EOF
# Product Standard

\`\`\`json
{
  "schema_version": 1,
  "product": "Support Command Center",
  "category": "support operations",
  "date": "2026-06-22",
  "ambition": {
    "stage": "commercial_product",
    "target_scale": "100000 users with tenant-aware operations",
    "value_thesis": "Reduce queue risk and manual reporting for support leaders",
    "differentiation_thesis": "Decision-grade aging, risk, and blocker visibility in one operating view"
  },
  "evidence": {
    "prd_ref": "walteur-kit/PRD.md",
    "benchmark_ref": "walteur-kit/benchmark.md",
    "plan_ref": "PLAN.md",
    "design_ref": "DESIGN.md"
  },
  "core_value_loop": {
    "pain": "Leaders discover aging or blocked work too late",
    "promise": "Show the next operational decision in under 2 min",
    "activation_event": "First saved view with current queue risk",
    "habit_loop": "Daily queue review and weekly service-health review",
    "retention_mechanism": "Historical decisions, alerts, and saved operating views",
    "north_star_metric": { "name": "weekly active decision reviews", "target": "50 reviews/week", "check": "Read analytics event count" }
  },
  "users": {
    "primary": "Support lead",
    "buyer": "Support operations director",
    "admin": "Operations admin",
    "support_operator": "Internal support owner"
  },
  "product_surface": [
EOF
    first=1
    for area in onboarding core_workflow data_model auth_permissions settings empty_loading_error_states analytics_telemetry admin_ops billing_or_value_exchange support_docs security_privacy release_ops; do
      [ "$area" = "$omit_area" ] && continue
      if [ "$first" -eq 0 ]; then printf ',\n' >> "$root/walteur-kit/PRODUCT-STANDARD.md"; fi
      first=0
      printf '    { "area": "%s", "status": "planned", "ref": "PLAN.md#%s" }' "$area" "$area" >> "$root/walteur-kit/PRODUCT-STANDARD.md"
    done
    cat >> "$root/walteur-kit/PRODUCT-STANDARD.md" <<EOF

  ],
  "business_model": {
    "value_capture": "Seat-based subscription or internal productivity ROI",
    "pricing_or_funding": "Budget owner funds first team rollout",
    "cost_drivers": "Data sync, analytics storage, and support operations",
    "unit_economics_assumption": "Support time saved exceeds 10 hours/week per team",
    "expansion_path": "Expand from queue health to forecasting and coaching"
  },
  "trust_and_ops": {
    "authn_authz": "Role-based access for leads, admins, and viewers",
    "data_policy": "Internal data only; redact customer PII in logs and demos",
    "observability": "Structured logs, product analytics, queue freshness metric, alert owner",
    "reliability_target": "99.5% monthly availability for operating dashboard",
    "support_model": "Runbook plus escalation to support operations owner",
    "incident_response": "Owner pages ops lead and rolls back connector changes"
  },
  "launch_readiness": {
    "first_segment": "Support leads managing multi-channel queues",
    "acquisition_or_distribution": "Private rollout to one operations team",
    "activation_metric": "40% of invited leads save one view in 7 days",
    "feedback_channel": "In-app feedback plus weekly operations review",
    "release_plan": "Private beta, measured rollout, then broader team launch"
  },
  "out_of_scope": [
    { "item": "Marketplace integrations", "reason": "Not needed for first queue-risk proof", "owner": "Support operations", "review_trigger": "After 3 teams activate" }
  ],
  "signoff": { "owner": "Support operations", "status": "self_signed", "date": "2026-06-22" }
}
\`\`\`
EOF
    if [ "$placeholder" = "yes" ]; then
      sed 's/Support Command Center/TODO/' "$root/walteur-kit/PRODUCT-STANDARD.md" > "$root/tmp.md" && mv "$root/tmp.md" "$root/walteur-kit/PRODUCT-STANDARD.md"
    fi
  }

  echo "product-standard-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/product-standard-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src"
  printf 'print("cli")\n' > "$tmp/src/main.py"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "no product signal -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/product-standard-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "UI signal without PRODUCT-STANDARD -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/product-standard-selftest.XXXXXX")" || return 1
  write_refs "$tmp"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  printf '# Product Standard\nTODO\n' > "$tmp/walteur-kit/PRODUCT-STANDARD.md"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "stub PRODUCT-STANDARD -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/product-standard-selftest.XXXXXX")" || return 1
  write_refs "$tmp"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  write_standard "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "complete PRODUCT-STANDARD -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/product-standard-selftest.XXXXXX")" || return 1
  write_refs "$tmp"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  write_standard "$tmp" "support_docs"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "missing required surface -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/product-standard-selftest.XXXXXX")" || return 1
  write_refs "$tmp"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  write_standard "$tmp" "" "yes"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "placeholder content -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/product-standard-selftest.XXXXXX")" || return 1
  write_refs "$tmp"
  rm -f "$tmp/PLAN.md"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  write_standard "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "missing referenced evidence file -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # §14 scale guard: a UI signal on a low-scale local app (no auth/payments/db/external
  # surface, risk below high/regulated) is NOT_APPLICABLE even with NO PRODUCT-STANDARD.
  # This is the Momentum case: a local single-user habit tracker must not be forced to
  # author a commercial business-model/go-to-market manifest.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/product-standard-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '<!doctype html><div>app</div>\n' > "$tmp/index.html"
  printf '{ "id":"local-app", "build_class":"software", "risk_tier":"medium", "interfaces":[] }\n' > "$tmp/walteur-kit/build-contract.json"
  printf '{ "has_ui":true, "is_user_facing":true, "external_surface":false, "has_db":false, "has_auth":false, "has_payments":false, "has_api_boundary":false, "has_async":false, "is_ai_agent":false, "is_cloud_iac":false, "regulated":false }\n' > "$tmp/walteur-kit/preflight-signals.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "low-scale local app (UI, no signals) -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  # Conservatism: a genuine commercial SaaS (risk high, has_auth+has_db) with a UI but NO
  # PRODUCT-STANDARD MUST still FAIL. The scale guard must not let real products slip.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/product-standard-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  printf '{ "id":"saas", "build_class":"software", "risk_tier":"high", "interfaces":[] }\n' > "$tmp/walteur-kit/build-contract.json"
  printf '{ "has_ui":true, "is_user_facing":true, "external_surface":true, "has_db":true, "has_auth":true, "has_payments":true, "has_api_boundary":true, "has_async":true, "is_ai_agent":false, "is_cloud_iac":true, "regulated":false }\n' > "$tmp/walteur-kit/preflight-signals.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "commercial SaaS (risk high, has_auth) without PRODUCT-STANDARD -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # Conservatism via signal-only: medium risk but has_auth=true is a real multi-user
  # product (auth implies accounts) -> standard still applies -> FAIL without it.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/product-standard-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  printf '<div>app</div>\n' > "$tmp/src/App.tsx"
  printf '{ "id":"authapp", "build_class":"software", "risk_tier":"medium", "interfaces":[] }\n' > "$tmp/walteur-kit/build-contract.json"
  printf '{ "has_ui":true, "is_user_facing":true, "external_surface":false, "has_db":true, "has_auth":true, "has_payments":false, "has_api_boundary":false, "has_async":false, "is_ai_agent":false, "is_cloud_iac":false, "regulated":false }\n' > "$tmp/walteur-kit/preflight-signals.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "medium risk + has_auth/has_db without PRODUCT-STANDARD -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "product-standard-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && {
  write_report "FAIL" "paused" "walteur-kit/PAUSED present" '[{"check":"paused","message":"WALTEUR is paused"}]'
  echo "product-standard-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
}

if [ "${WALTEUR_PRODUCT_STANDARD:-on}" = "off" ]; then
  write_report "SKIP" "bypass" "WALTEUR_PRODUCT_STANDARD=off" "[]"
  echo "product-standard-gate verdict: SKIP - bypassed via WALTEUR_PRODUCT_STANDARD=off -> $REPORT" >&2
  exit 0
fi

for t in jq grep awk sed find; do
  if ! have "$t"; then
    write_report "SKIP" "tool-missing" "$t not installed" "[]"
    echo "product-standard-gate SKIP - required tool '$t' not installed (recorded, not silent-green)." >&2
    exit 0
  fi
done

DIR="${input_dir:-$ROOT}"
if [ ! -d "$DIR" ]; then
  write_report "SKIP" "bad-arg" "not a directory: $DIR" "[]"
  echo "product-standard-gate SKIP - '$DIR' is not a directory." >&2
  exit 0
fi

detect_product_signal "$DIR"
if [ "$PRODUCT_SIGNAL" -eq 0 ]; then
  write_report "NOT_APPLICABLE" "not-applicable" "no product signal" "[]"
  echo "product-standard-gate verdict: NOT_APPLICABLE - no product signal under '$DIR' -> $REPORT" >&2
  exit 0
fi

# §14 scale guard: a product signal alone (e.g. one UI file) does NOT warrant a
# commercial/company-scale PRODUCT-STANDARD manifest. Skip when the build proves it is a
# low-scale local app (no auth/payments/db/external surface, risk below high/regulated).
if ! scale_warrants_standard; then
  write_report "NOT_APPLICABLE" "out-of-scale" "product signal present ($SIGNAL_REASON) but $APPLY_REASON" "[]"
  echo "product-standard-gate verdict: NOT_APPLICABLE - $APPLY_REASON (signal: $SIGNAL_REASON) -> $REPORT" >&2
  exit 0
fi

STANDARD=""
for cand in "$KIT/PRODUCT-STANDARD.md" "$ROOT/PRODUCT-STANDARD.md" "$DIR/walteur-kit/PRODUCT-STANDARD.md" "$DIR/PRODUCT-STANDARD.md"; do
  if [ -f "$cand" ]; then
    STANDARD="$cand"
    break
  fi
done
STANDARD_REL="${STANDARD#"$ROOT"/}"

if [ -z "$STANDARD" ]; then
  STANDARD_REL="walteur-kit/PRODUCT-STANDARD.md"
  write_report "FAIL" "missing" "product signal present ($SIGNAL_REASON) but PRODUCT-STANDARD.md is absent" \
    '[{"check":"product-standard.present","message":"Create walteur-kit/PRODUCT-STANDARD.md from the template so product/company scope is explicit."}]'
  echo "product-standard-gate verdict: FAIL - product signal present ($SIGNAL_REASON) but PRODUCT-STANDARD.md is absent -> $REPORT" >&2
  exit 2
fi

NONEMPTY="$(grep -cv '^[[:space:]]*$' "$STANDARD" 2>/dev/null || echo 0)"
JSON_BLOCK=""
if grep -q '```json' "$STANDARD" 2>/dev/null; then
  JSON_BLOCK="$(awk '/^```json/{found=1; next} found && /^```/{found=0} found{print}' "$STANDARD" | tr -d '\r')"
fi

if [ "$NONEMPTY" -lt 20 ] || [ -z "$JSON_BLOCK" ]; then
  write_report "FAIL" "stub" "PRODUCT-STANDARD.md '$STANDARD_REL' is a stub or lacks a fenced json block" \
    "$(jq -n --arg f "$STANDARD_REL" '[{"check":"product-standard.stub","file":$f,"message":"PRODUCT-STANDARD.md needs a non-stub fenced json block."}]')"
  echo "product-standard-gate verdict: FAIL - '$STANDARD_REL' is a stub -> $REPORT" >&2
  exit 2
fi

if ! printf '%s' "$JSON_BLOCK" | jq empty >/dev/null 2>&1; then
  write_report "FAIL" "invalid-json" "PRODUCT-STANDARD.md '$STANDARD_REL' json block is invalid" \
    "$(jq -n --arg f "$STANDARD_REL" '[{"check":"product-standard.json","file":$f,"message":"The fenced json block is not valid JSON."}]')"
  echo "product-standard-gate verdict: FAIL - '$STANDARD_REL' json block is invalid -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

extra_root="$(printf '%s' "$JSON_BLOCK" | jq -r '
  keys[] | select(([
    "schema_version","product","category","date","ambition","evidence","core_value_loop","users",
    "product_surface","business_model","trust_and_ops","launch_readiness","out_of_scope","signoff"
  ] | index(.)) | not)
' 2>/dev/null | paste -sd ', ' -)"
[ -n "$extra_root" ] && add_finding "additional_properties" "unknown root fields are not allowed: $extra_root"

require_string "product" ".product"
require_string "category" ".category"
require_string "ambition.target_scale" ".ambition.target_scale"
require_string "ambition.value_thesis" ".ambition.value_thesis"
require_string "ambition.differentiation_thesis" ".ambition.differentiation_thesis"
require_string "evidence.prd_ref" ".evidence.prd_ref"
require_string "evidence.benchmark_ref" ".evidence.benchmark_ref"
require_string "evidence.plan_ref" ".evidence.plan_ref"
if [ "$UI_COUNT" -gt 0 ]; then
  require_string "evidence.design_ref" ".evidence.design_ref"
fi
require_string "core_value_loop.pain" ".core_value_loop.pain"
require_string "core_value_loop.promise" ".core_value_loop.promise"
require_string "core_value_loop.activation_event" ".core_value_loop.activation_event"
require_string "core_value_loop.habit_loop" ".core_value_loop.habit_loop"
require_string "core_value_loop.retention_mechanism" ".core_value_loop.retention_mechanism"
require_string "core_value_loop.north_star_metric.name" ".core_value_loop.north_star_metric.name"
require_string "core_value_loop.north_star_metric.target" ".core_value_loop.north_star_metric.target"
require_string "core_value_loop.north_star_metric.check" ".core_value_loop.north_star_metric.check"
require_string "users.primary" ".users.primary"
require_string "users.buyer" ".users.buyer"
require_string "users.admin" ".users.admin"
require_string "users.support_operator" ".users.support_operator"
require_string "business_model.value_capture" ".business_model.value_capture"
require_string "business_model.pricing_or_funding" ".business_model.pricing_or_funding"
require_string "business_model.cost_drivers" ".business_model.cost_drivers"
require_string "business_model.unit_economics_assumption" ".business_model.unit_economics_assumption"
require_string "business_model.expansion_path" ".business_model.expansion_path"
require_string "trust_and_ops.authn_authz" ".trust_and_ops.authn_authz"
require_string "trust_and_ops.data_policy" ".trust_and_ops.data_policy"
require_string "trust_and_ops.observability" ".trust_and_ops.observability"
require_string "trust_and_ops.reliability_target" ".trust_and_ops.reliability_target"
require_string "trust_and_ops.support_model" ".trust_and_ops.support_model"
require_string "trust_and_ops.incident_response" ".trust_and_ops.incident_response"
require_string "launch_readiness.first_segment" ".launch_readiness.first_segment"
require_string "launch_readiness.acquisition_or_distribution" ".launch_readiness.acquisition_or_distribution"
require_string "launch_readiness.activation_metric" ".launch_readiness.activation_metric"
require_string "launch_readiness.feedback_channel" ".launch_readiness.feedback_channel"
require_string "launch_readiness.release_plan" ".launch_readiness.release_plan"
require_string "signoff.owner" ".signoff.owner"
require_string "signoff.status" ".signoff.status"

date_val="$(jq_json '.date // empty')"
if ! printf '%s' "$date_val" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  add_finding "date" "date must be YYYY-MM-DD"
fi
signoff_date="$(jq_json '.signoff.date // empty')"
if ! printf '%s' "$signoff_date" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  add_finding "signoff.date" "signoff.date must be YYYY-MM-DD"
fi

stage_val="$(jq_json '.ambition.stage // empty')"
if ! printf '%s' "$stage_val" | grep -Eq '^(internal_tool|full_product|commercial_product|venture_grade)$'; then
  add_finding "ambition.stage" "ambition.stage must be internal_tool, full_product, commercial_product, or venture_grade"
fi
signoff_status="$(jq_json '.signoff.status // empty')"
if ! printf '%s' "$signoff_status" | grep -Eq '^(draft|self_signed|approved)$'; then
  add_finding "signoff.status" "signoff.status must be draft, self_signed, or approved"
fi

metric_target="$(jq_json '.core_value_loop.north_star_metric.target // empty')"
if ! printf '%s' "$metric_target" | grep -Eiq '[0-9]+(\.[0-9]+)?[[:space:]]*(ms|s|m|h|%|x|rps|qps|req|requests|gb|mb|kb|tb|users|p50|p95|p99|fps|days?|hrs?|hours?|mins?|min|seconds?|\$|usd|eur|reviews?|events?|teams?)'; then
  add_finding "north_star_metric.target" "north-star target must include a number and unit"
fi
activation_metric="$(jq_json '.launch_readiness.activation_metric // empty')"
if ! printf '%s' "$activation_metric" | grep -Eiq '[0-9]+(\.[0-9]+)?[[:space:]]*(ms|s|m|h|%|x|users|days?|hrs?|hours?|mins?|min|seconds?|events?|teams?|signups?|activations?)'; then
  add_finding "launch_readiness.activation_metric" "activation metric must include a number and unit"
fi

if printf '%s' "$JSON_BLOCK" | grep -Eiq '(<[^>]+>|\b(todo|tbd|lorem|placeholder|dummy)\b)'; then
  add_finding "placeholder" "PRODUCT-STANDARD json block contains placeholder text"
fi

check_ref_exists "evidence.prd_ref" ".evidence.prd_ref"
check_ref_exists "evidence.benchmark_ref" ".evidence.benchmark_ref"
check_ref_exists "evidence.plan_ref" ".evidence.plan_ref"
if [ "$UI_COUNT" -gt 0 ]; then
  check_ref_exists "evidence.design_ref" ".evidence.design_ref"
fi

if ! printf '%s' "$JSON_BLOCK" | jq -e '.product_surface | type=="array"' >/dev/null 2>&1; then
  add_finding "product_surface.shape" "product_surface must be an array"
else
  for area in onboarding core_workflow data_model auth_permissions settings empty_loading_error_states analytics_telemetry admin_ops billing_or_value_exchange support_docs security_privacy release_ops; do
    if ! printf '%s' "$JSON_BLOCK" | jq -e --arg area "$area" '[.product_surface[]? | select(.area == $area)] | length > 0' >/dev/null 2>&1; then
      add_finding "product_surface.$area" "missing product surface area: $area"
    fi
  done

  bad_surface="$(printf '%s' "$JSON_BLOCK" | jq -r '
    (.product_surface // [])[]
    | select((.area|type!="string")
        or (.status as $s | ["planned","built","verified","out_of_scope"] | index($s) | not)
        or (.ref|type!="string" or length==0))
    | (.area // "<missing-area>")
  ' 2>/dev/null | paste -sd ', ' -)"
  [ -n "$bad_surface" ] && add_finding "product_surface.entries" "invalid product surface entries: $bad_surface"
fi

if ! printf '%s' "$JSON_BLOCK" | jq -e '.out_of_scope | type=="array" and length > 0' >/dev/null 2>&1; then
  add_finding "out_of_scope.shape" "out_of_scope must contain at least one explicit cut"
else
  bad_oos="$(printf '%s' "$JSON_BLOCK" | jq -r '
    (.out_of_scope // [])[]
    | select((.item|type!="string" or length==0)
        or (.reason|type!="string" or length==0)
        or (.owner|type!="string" or length==0)
        or (.review_trigger|type!="string" or length==0))
    | (.item // "<missing-item>")
  ' 2>/dev/null | paste -sd ', ' -)"
  [ -n "$bad_oos" ] && add_finding "out_of_scope.entries" "invalid out_of_scope entries: $bad_oos"
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "applicable" "$failures product-standard violation(s)" "$findings"
  echo "product-standard-gate verdict: FAIL - $failures violation(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "applicable" "product standard complete for signal: $SIGNAL_REASON" "$findings"
echo "product-standard-gate verdict: PASS - product standard complete -> $REPORT" >&2
exit 0
