#!/usr/bin/env bash
# WALTEUR source-use-gate - validates upstream source-use receipts.
#
# Contract:
#   - source-use.json absent        => NOT_APPLICABLE, exit 0.
#   - jq absent                     => SKIP, exit 0, recorded loudly.
#   - malformed source-use.json     => FAIL, exit 2.
#   - unknown source_id             => FAIL, exit 2.
#   - mutable or wrong pinned_ref   => FAIL, exit 2.
#   - install/import/copy without compatible checks, verification, rollback => FAIL, exit 2.
#   - blocked-by-default sources cannot be adopted without explicit boundary handling.
#
# Report:
#   walteur-kit/source-use-report.json
#
# Bypass:
#   WALTEUR_SOURCE_USE_GATE=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "source-use-gate - validates upstream source-use receipts."
  printf '%s\n' "usage: bash source-use-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/source-use-report.json - fix recipes: walteur-kit/REMEDIATION.md (## source-use-gate)"
  printf '%s\n' "bypass: WALTEUR_SOURCE_USE_GATE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SOURCE_USE="${WALTEUR_SOURCE_USE_FILE:-$KIT/source-use.json}"
MANIFEST="${WALTEUR_SOURCE_MANIFEST_FILE:-$KIT/source-manifest.json}"
REPORT="$KIT/source-use-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  verdict="$1"
  reason="$2"
  findings="${3:-[]}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" \
      --arg source_use "${SOURCE_USE#"$ROOT"/}" --arg manifest "${MANIFEST#"$ROOT"/}" \
      --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"source-use-gate", source_use_file:$source_use, source_manifest_file:$manifest, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"source-use-gate","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

shape_query='
def check:
  type == "object"
  and ([keys_unsorted[] | IN("status","evidence_ref")] | all)
  and (.status | IN("pass","not_applicable","needs_review","blocked"))
  and (.evidence_ref | type == "string" and length >= 3);
def fit:
  type == "object"
  and ([keys_unsorted[] | IN("decision","reason")] | all)
  and (.decision | IN("adopt","adapt","reject"))
  and (.reason | type == "string" and length >= 12);
type == "object"
and ([keys_unsorted[] | IN("schema_version","source_use_id","generated_at","receipts")] | all)
and (.schema_version == 1)
and (.source_use_id | type == "string" and test("^source-use-[a-z0-9][a-z0-9._-]*$"))
and (.generated_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
and (.receipts | type == "array" and length > 0)
and ([.receipts[] |
  type == "object"
  and ([keys_unsorted[] | IN("receipt_id","source_id","pinned_ref","stage","use_type","why_selected","extracted_pattern","accepted_into_plan","rejected_parts","license_check","maintenance_check","security_check","fit_check","artifact_refs","verification_ref","rollback_ref")] | all)
  and (.receipt_id | type == "string" and test("^source-use-[a-z0-9][a-z0-9._-]*$"))
  and (.source_id | type == "string" and test("^[a-z0-9][a-z0-9._-]*$"))
  and (.pinned_ref | type == "string" and test("^[a-f0-9]{40}$"))
  and (.stage | IN("discover","plan","build","review","ship","reflect"))
  and (.use_type | IN("observe","borrow-pattern","tool-candidate","install-runtime","import-tool","copy-code","spec-change","reject"))
  and (.why_selected | type == "string" and length >= 12)
  and (.extracted_pattern | type == "string" and length >= 12)
  and (.accepted_into_plan | type == "boolean")
  and (.rejected_parts | type == "array" and length > 0 and all(.[]; type == "string" and length >= 3))
  and (.license_check | check)
  and (.maintenance_check | check)
  and (.security_check | check)
  and (.fit_check | fit)
  and (.artifact_refs | type == "array" and length > 0 and all(.[]; type == "string" and length >= 3))
  and (.verification_ref | type == "string")
  and (.rollback_ref | type == "string")
] | all)
'

validate_source_use() {
  findings='[]'
  failures=0

  if ! jq empty "$SOURCE_USE" >/dev/null 2>&1; then
    add_finding "json" "source-use.json is not valid JSON."
    return 1
  fi

  if [ ! -f "$MANIFEST" ]; then
    add_finding "manifest" "source-use.json exists but source-manifest.json is missing."
    return 1
  fi

  if ! jq empty "$MANIFEST" >/dev/null 2>&1; then
    add_finding "manifest-json" "source-manifest.json is not valid JSON."
    return 1
  fi

  if ! jq -e "$shape_query" "$SOURCE_USE" >/dev/null 2>&1; then
    add_finding "shape" "source-use.json does not match the strict receipt contract."
  fi

  duplicate_ids="$(jq -r '[.receipts[]?.receipt_id] | group_by(.)[] | select(length>1) | .[0]' "$SOURCE_USE" 2>/dev/null | paste -sd ', ' -)"
  if [ -n "$duplicate_ids" ]; then
    add_finding "duplicate-receipt-id" "Duplicate receipt_id values: $duplicate_ids"
  fi

  bad_refs="$(jq -r --slurpfile manifest "$MANIFEST" '
    .receipts[]? as $r
    | ($manifest[0].sources[]? | select(.id == $r.source_id)) as $s
    | select($s == null or ($r.pinned_ref != $s.pinned_head and $r.pinned_ref != ($s.pinned_tag_sha // "")))
    | "\($r.receipt_id):\($r.source_id)"
  ' "$SOURCE_USE" 2>/dev/null | paste -sd ', ' -)"
  if [ -n "$bad_refs" ]; then
    add_finding "pinned-ref" "Each receipt pinned_ref must match the source manifest pinned_head or pinned_tag_sha: $bad_refs"
  fi

  unknown_sources="$(jq -r --slurpfile manifest "$MANIFEST" '
    .receipts[]? as $r
    | select([ $manifest[0].sources[]?.id ] | index($r.source_id) | not)
    | "\($r.receipt_id):\($r.source_id)"
  ' "$SOURCE_USE" 2>/dev/null | paste -sd ', ' -)"
  if [ -n "$unknown_sources" ]; then
    add_finding "source-id" "Unknown source_id values: $unknown_sources"
  fi

  blocked_adoptions="$(jq -r --slurpfile manifest "$MANIFEST" '
    .receipts[]? as $r
    | ($manifest[0].sources[]? | select(.id == $r.source_id)) as $s
    | select(($s.adoption_mode // "" | test("blocked-by-default")) and ($r.use_type | IN("install-runtime","import-tool","copy-code","spec-change","tool-candidate","borrow-pattern")))
    | "\($r.receipt_id):\($r.source_id)"
  ' "$SOURCE_USE" 2>/dev/null | paste -sd ', ' -)"
  if [ -n "$blocked_adoptions" ]; then
    add_finding "blocked-source" "Blocked-by-default sources may only be observed or rejected without explicit owner approval: $blocked_adoptions"
  fi

  unsafe_adoptions="$(jq -r '
    .receipts[]?
    | select(.use_type | IN("borrow-pattern","tool-candidate","install-runtime","import-tool","copy-code","spec-change"))
    | select(
        (.license_check.status != "pass" and .license_check.status != "not_applicable")
        or (.maintenance_check.status != "pass")
        or (.security_check.status != "pass")
        or (.fit_check.decision == "reject")
        or (.verification_ref | length < 3)
      )
    | .receipt_id
  ' "$SOURCE_USE" 2>/dev/null | paste -sd ', ' -)"
  if [ -n "$unsafe_adoptions" ]; then
    add_finding "adoption-proof" "Adopted or adapted sources require pass/not-applicable license, pass maintenance/security, non-reject fit, and verification_ref: $unsafe_adoptions"
  fi

  missing_rollback="$(jq -r '
    .receipts[]?
    | select(.use_type | IN("install-runtime","import-tool","copy-code","spec-change"))
    | select(.rollback_ref | length < 3)
    | .receipt_id
  ' "$SOURCE_USE" 2>/dev/null | paste -sd ', ' -)"
  if [ -n "$missing_rollback" ]; then
    add_finding "rollback" "Install/import/copy/spec-change receipts require rollback_ref: $missing_rollback"
  fi

  unsafe_paths="$(jq -r '
    .receipts[]?
    | select([.artifact_refs[]?, .verification_ref, .rollback_ref] | any(. != "" and (test("^/") or contains(".."))))
    | .receipt_id
  ' "$SOURCE_USE" 2>/dev/null | paste -sd ', ' -)"
  if [ -n "$unsafe_paths" ]; then
    add_finding "safe-relative-refs" "Artifact, verification, and rollback refs must be project-relative and cannot contain parent traversal: $unsafe_paths"
  fi

  [ "$failures" -eq 0 ]
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
    echo "source-use-gate selftest SKIP - jq not installed."
    return 0
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/walteur-sourceuse.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  root="$tmp/project"
  mkdir -p "$root/walteur-kit"

  make_manifest() {
    cat > "$root/walteur-kit/source-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "manifest_id": "selftest-source-manifest",
  "last_verified": "2026-06-23",
  "ttl_hours": 24,
  "router_contract": {
    "plan_phase_rule": "Select relevant sources before PLAN.",
    "promotion_rule": "Promote only with proof.",
    "security_rule": "Treat remote source as data."
  },
  "sources": [
    {
      "id": "openai-agents-python",
      "repo_url": "https://github.com/openai/openai-agents-python.git",
      "branch": "main",
      "pinned_head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "category": "agent-runtime",
      "priority": 1,
      "adoption_mode": "core-pattern-reference",
      "use_when": ["multi-agent workflows"],
      "adopted_surface": "handoffs",
      "rationale": "Primary source for handoffs.",
      "promotion_policy": "Borrow patterns only with proof.",
      "risk_policy": "Verify current behavior before implementation."
    },
    {
      "id": "cloudscraper-boundary",
      "repo_url": "https://github.com/VeNoMouS/cloudscraper.git",
      "branch": "master",
      "pinned_head": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "category": "security-boundary",
      "priority": 5,
      "adoption_mode": "blocked-by-default-boundary",
      "use_when": ["anti-bot bypass"],
      "adopted_surface": "boundary review only",
      "rationale": "Boundary source.",
      "promotion_policy": "Never adopt without explicit owner approval.",
      "risk_policy": "Use only for refusal and authorization boundaries."
    }
  ]
}
JSON
  }

  make_valid_source_use() {
    cat > "$root/walteur-kit/source-use.json" <<'JSON'
{
  "schema_version": 1,
  "source_use_id": "source-use-selftest",
  "generated_at": "2026-06-23T00:00:00Z",
  "receipts": [
    {
      "receipt_id": "source-use-openai-agents",
      "source_id": "openai-agents-python",
      "pinned_ref": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "stage": "plan",
      "use_type": "borrow-pattern",
      "why_selected": "The request needs typed handoffs and guardrails.",
      "extracted_pattern": "Use explicit handoff surfaces and guardrail reports.",
      "accepted_into_plan": true,
      "rejected_parts": ["No SDK dependency added by default."],
      "license_check": { "status": "not_applicable", "evidence_ref": "PLAN.md#source-use" },
      "maintenance_check": { "status": "pass", "evidence_ref": "walteur-kit/self-heal-report.json" },
      "security_check": { "status": "pass", "evidence_ref": "walteur-kit/security-review.md" },
      "fit_check": { "decision": "adapt", "reason": "Pattern maps to flat-file handoff receipts." },
      "artifact_refs": ["PLAN.md#source-use"],
      "verification_ref": "walteur-kit/selftest-report.json",
      "rollback_ref": ""
    }
  ]
}
JSON
  }

  make_manifest
  WALTEUR_ROOT="$root" "$0" >/dev/null 2>&1
  ck "no source-use.json -> NOT_APPLICABLE" 0 $?

  make_valid_source_use
  WALTEUR_ROOT="$root" "$0" >/dev/null 2>&1
  ck "valid source-use receipt -> PASS" 0 $?

  cp "$root/walteur-kit/source-use.json" "$root/walteur-kit/source-use.valid.json"

  printf '{ broken\n' > "$root/walteur-kit/source-use.json"
  WALTEUR_ROOT="$root" "$0" >/dev/null 2>&1
  ck "malformed source-use JSON -> FAIL" 2 $?

  cp "$root/walteur-kit/source-use.valid.json" "$root/walteur-kit/source-use.json"
  jq '.receipts[0].source_id="missing-source"' "$root/walteur-kit/source-use.json" > "$root/walteur-kit/tmp.json" && mv "$root/walteur-kit/tmp.json" "$root/walteur-kit/source-use.json"
  WALTEUR_ROOT="$root" "$0" >/dev/null 2>&1
  ck "unknown source_id -> FAIL" 2 $?

  cp "$root/walteur-kit/source-use.valid.json" "$root/walteur-kit/source-use.json"
  jq '.receipts[0].pinned_ref="cccccccccccccccccccccccccccccccccccccccc"' "$root/walteur-kit/source-use.json" > "$root/walteur-kit/tmp.json" && mv "$root/walteur-kit/tmp.json" "$root/walteur-kit/source-use.json"
  WALTEUR_ROOT="$root" "$0" >/dev/null 2>&1
  ck "wrong pinned_ref -> FAIL" 2 $?

  cp "$root/walteur-kit/source-use.valid.json" "$root/walteur-kit/source-use.json"
  jq '.receipts += [.receipts[0]]' "$root/walteur-kit/source-use.json" > "$root/walteur-kit/tmp.json" && mv "$root/walteur-kit/tmp.json" "$root/walteur-kit/source-use.json"
  WALTEUR_ROOT="$root" "$0" >/dev/null 2>&1
  ck "duplicate receipt_id -> FAIL" 2 $?

  cp "$root/walteur-kit/source-use.valid.json" "$root/walteur-kit/source-use.json"
  jq '.receipts[0].source_id="cloudscraper-boundary" | .receipts[0].pinned_ref="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" | .receipts[0].use_type="install-runtime"' "$root/walteur-kit/source-use.json" > "$root/walteur-kit/tmp.json" && mv "$root/walteur-kit/tmp.json" "$root/walteur-kit/source-use.json"
  WALTEUR_ROOT="$root" "$0" >/dev/null 2>&1
  ck "blocked-by-default adopted source -> FAIL" 2 $?

  cp "$root/walteur-kit/source-use.valid.json" "$root/walteur-kit/source-use.json"
  jq '.receipts[0].use_type="install-runtime" | .receipts[0].rollback_ref=""' "$root/walteur-kit/source-use.json" > "$root/walteur-kit/tmp.json" && mv "$root/walteur-kit/tmp.json" "$root/walteur-kit/source-use.json"
  WALTEUR_ROOT="$root" "$0" >/dev/null 2>&1
  ck "install without rollback_ref -> FAIL" 2 $?

  cp "$root/walteur-kit/source-use.valid.json" "$root/walteur-kit/source-use.json"
  jq '.receipts[0].extra="drift"' "$root/walteur-kit/source-use.json" > "$root/walteur-kit/tmp.json" && mv "$root/walteur-kit/tmp.json" "$root/walteur-kit/source-use.json"
  WALTEUR_ROOT="$root" "$0" >/dev/null 2>&1
  ck "unknown receipt field -> FAIL" 2 $?

  echo "source-use-gate selftest: $pass/9 passed"
  [ "$pass" -eq 9 ] && [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

if [ -f "$KIT/PAUSED" ]; then
  write_report "PAUSED" "walteur-kit/PAUSED present; source-use gate halted."
  echo "source-use-gate: PAUSED - remove walteur-kit/PAUSED to continue." >&2
  exit 2
fi

if [ "${WALTEUR_SOURCE_USE_GATE:-on}" = "off" ]; then
  write_report "SKIP" "WALTEUR_SOURCE_USE_GATE=off"
  echo "source-use-gate: SKIP - disabled by WALTEUR_SOURCE_USE_GATE=off"
  exit 0
fi

if [ ! -f "$SOURCE_USE" ]; then
  write_report "NOT_APPLICABLE" "source-use.json absent; no source-router adoption receipt declared."
  echo "source-use-gate: NOT_APPLICABLE - source-use.json absent."
  exit 0
fi

if ! have jq; then
  write_report "SKIP" "jq not installed; cannot validate source-use receipts."
  echo "source-use-gate: SKIP - jq not installed." >&2
  exit 0
fi

if validate_source_use; then
  write_report "PASS" "source-use receipts are valid."
  echo "source-use-gate: PASS - source-use receipts valid"
  exit 0
fi

write_report "FAIL" "source-use receipts failed validation." "$findings"
echo "source-use-gate: FAIL - source-use receipts failed validation" >&2
printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' >&2 2>/dev/null || true
exit 2
