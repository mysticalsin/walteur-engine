#!/usr/bin/env bash
# WALTEUR current-stack-gate - hard proof that planning used current stack facts.
#
# Contract:
#   - Before plan and no current-stack.json       => NOT_APPLICABLE, exit 0.
#   - Plan/build/verify/review/ship/reflect
#     without current-stack.json                  => FAIL, exit 2.
#   - Stale run date, weak sources, missing
#     evidence, or unacknowledged stack drift      => FAIL, exit 2.
#   - Current dated stack proof                    => PASS, exit 0.
#
# Report:
#   walteur-kit/current-stack-report.json
#
# Bypass:
#   WALTEUR_CURRENT_STACK=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "current-stack-gate - hard proof that planning used current stack facts."
  printf '%s\n' "usage: bash current-stack-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/current-stack-report.json - fix recipes: walteur-kit/REMEDIATION.md (## current-stack-gate)"
  printf '%s\n' "bypass: WALTEUR_CURRENT_STACK=off (recorded, not free)"
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
STACK="$KIT/current-stack.json"
STATE="$KIT/autopilot/STATE.json"
CONTRACT="$KIT/build-contract.json"
FINGERPRINT_REPORT="$KIT/stack-fingerprint-report.json"
REPORT="$KIT/current-stack-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_DATE="$(date -u +%Y-%m-%d)"
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
      --arg stack "${STACK#"$ROOT"/}" --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"current-stack-gate", mode:$mode, current_stack_file:$stack, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"current-stack-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

detect_required() {
  CURRENT_STACK_REQUIRED=0
  CURRENT_STACK_REQUIRED_REASON=""

  if [ "${WALTEUR_CURRENT_STACK_REQUIRED:-}" = "1" ]; then
    CURRENT_STACK_REQUIRED=1
    CURRENT_STACK_REQUIRED_REASON="WALTEUR_CURRENT_STACK_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      plan|build|verify|review|ship|reflect)
        CURRENT_STACK_REQUIRED=1
        CURRENT_STACK_REQUIRED_REASON="STATE.phase=$phase"
        return 0 ;;
    esac
  fi
}

resolve_ref() {
  ref="$1"
  ref_file="${ref%%#*}"
  [ -n "$ref_file" ] || return 1
  case "$ref_file" in
    /*)
      case "$ref_file" in "$ROOT"/*) printf '%s\n' "$ref_file"; return 0 ;; *) return 1 ;; esac ;;
    *..*) return 1 ;;
    *) printf '%s\n' "$ROOT/$ref_file"; return 0 ;;
  esac
}

check_ref() {
  label="$1"
  ref="$2"
  path="$(resolve_ref "$ref" 2>/dev/null || true)"
  if [ -z "$path" ]; then
    add_finding "$label" "$label must be a relative path inside the project: $ref"
    return 0
  fi
  [ -f "$path" ] || add_finding "$label" "$label points to missing file: $ref"
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
    echo "current-stack-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    root="$1"
    phase="$2"
    build_class="${3:-software}"
    mkdir -p "$root/walteur-kit/autopilot"
    jq -n --arg phase "$phase" --arg build_class "$build_class" '{phase:$phase, build_class:$build_class}' > "$root/walteur-kit/autopilot/STATE.json"
  }

  write_contract() {
    root="$1"
    build_class="${2:-software}"
    mkdir -p "$root/walteur-kit"
    jq -n --arg build_class "$build_class" '{build_class:$build_class}' > "$root/walteur-kit/build-contract.json"
  }

  write_evidence() {
    root="$1"
    mkdir -p "$root/walteur-kit/evidence/current-stack"
    printf 'official docs captured\n' > "$root/walteur-kit/evidence/current-stack/official-doc.md"
    printf 'stale training check captured\n' > "$root/walteur-kit/evidence/current-stack/stale-check.md"
  }

  write_valid_stack() {
    root="$1"
    run_date="${2:-$RUN_DATE}"
    ts="${3:-${run_date}T00:00:00Z}"
    mkdir -p "$root/walteur-kit"
    jq -n \
      --arg run_date "$run_date" \
      --arg ts "$ts" \
      '{
        schema_version: 1,
        verdict: "PASS",
        run_date: $run_date,
        build_class: "software",
        domain: "support dashboard",
        stack_items: [
          {
            id: "react",
            category: "framework",
            name: "React",
            version_or_constraint: "current stable",
            decision: "use",
            source_ids: ["react-docs"],
            evidence_refs: ["walteur-kit/evidence/current-stack/official-doc.md"],
            rationale: "Use the framework documented in current official docs for the UI layer."
          }
        ],
        sources: [
          {
            id: "react-docs",
            kind: "official_docs",
            name: "React docs",
            url: "https://react.dev/",
            official: true,
            last_checked: $run_date,
            captured_ref: "walteur-kit/evidence/current-stack/official-doc.md"
          }
        ],
        stale_training_checks: [
          {
            claim: "Use current React documentation instead of frozen model memory.",
            checked_against_source_ids: ["react-docs"],
            verdict: "current",
            action: "Plan from the captured current docs.",
            evidence_refs: ["walteur-kit/evidence/current-stack/stale-check.md"]
          }
        ],
        evidence_refs: [
          "walteur-kit/evidence/current-stack/official-doc.md",
          "walteur-kit/evidence/current-stack/stale-check.md"
        ],
        ts: $ts
      }' > "$root/walteur-kit/current-stack.json"
  }

  echo "current-stack-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/current-stack-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no current-stack before plan -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/current-stack-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "plan without current-stack -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/current-stack-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_contract "$tmp" "software"
  write_evidence "$tmp"
  write_valid_stack "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "valid current-stack -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/current-stack-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_evidence "$tmp"
  write_valid_stack "$tmp" "2000-01-01" "2000-01-01T00:00:00Z"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "stale run date -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/current-stack-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_evidence "$tmp"
  write_valid_stack "$tmp"
  jq '.stack_items=[]' "$tmp/walteur-kit/current-stack.json" > "$tmp/walteur-kit/current-stack.tmp" && mv "$tmp/walteur-kit/current-stack.tmp" "$tmp/walteur-kit/current-stack.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "zero stack items -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/current-stack-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_evidence "$tmp"
  write_valid_stack "$tmp"
  rm -f "$tmp/walteur-kit/evidence/current-stack/official-doc.md"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing evidence ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/current-stack-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_evidence "$tmp"
  write_valid_stack "$tmp"
  jq -n --arg ts "$TS" '{verdict:"DRIFT", ts:$ts, gate:"stack-fingerprint", moved:["package.json"]}' > "$tmp/walteur-kit/stack-fingerprint-report.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "stack drift without acknowledgement -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/current-stack-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_evidence "$tmp"
  write_valid_stack "$tmp" "$RUN_DATE" "$TS"
  jq -n --arg ts "$TS" '{verdict:"DRIFT", ts:$ts, gate:"stack-fingerprint", moved:["package.json"]}' > "$tmp/walteur-kit/stack-fingerprint-report.json"
  jq --arg ts "$TS" '.stack_fingerprint={report_ref:"walteur-kit/stack-fingerprint-report.json", drift_ts:$ts, acknowledged_drift:true, acknowledgement:"Rechecked current stack after manifest drift."}' "$tmp/walteur-kit/current-stack.json" > "$tmp/walteur-kit/current-stack.tmp" && mv "$tmp/walteur-kit/current-stack.tmp" "$tmp/walteur-kit/current-stack.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "stack drift acknowledged -> PASS" 0 "$?"
  rm -rf "$tmp"

  echo "current-stack-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_CURRENT_STACK:-on}" = "off" ] && {
  echo "current-stack-gate: bypassed (WALTEUR_CURRENT_STACK=off)." >&2
  write_report "SKIP" "bypassed" "bypassed via WALTEUR_CURRENT_STACK=off" "[]"
  exit 0
}

if ! have jq; then
  echo "current-stack-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  write_report "SKIP" "tooling" "jq not installed" "[]"
  exit 0
fi

detect_required

if [ ! -s "$STACK" ]; then
  if [ "$CURRENT_STACK_REQUIRED" -eq 1 ]; then
    findings='[{"check":"current_stack.present","message":"walteur-kit/current-stack.json is required from plan onward"}]'
    write_report "FAIL" "missing" "current-stack.json missing while required by $CURRENT_STACK_REQUIRED_REASON" "$findings"
    echo "current-stack-gate verdict: FAIL - current-stack.json missing -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "not_required" "current-stack.json absent before plan" "[]"
  echo "current-stack-gate: no current-stack.json found before plan - gate not applicable." >&2
  exit 0
fi

if ! jq empty "$STACK" >/dev/null 2>&1; then
  findings='[{"check":"json","message":"current-stack.json is not valid JSON"}]'
  write_report "FAIL" "malformed" "current-stack.json malformed" "$findings"
  echo "current-stack-gate verdict: FAIL - current-stack.json is not valid JSON -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

if ! jq -e --arg today "$RUN_DATE" '
  .schema_version == 1
  and .verdict == "PASS"
  and .run_date == $today
  and (.build_class as $c | ["software","workflow","document","data-ai","cloud-iac","mixed"] | index($c) != null)
  and ((.domain // "") | length > 0)
  and ((.stack_items // []) | type == "array" and length > 0)
  and ((.sources // []) | type == "array" and length > 0)
  and ((.stale_training_checks // []) | type == "array" and length > 0)
  and ((.evidence_refs // []) | type == "array" and length > 0)
  and ((.ts // "") | length > 0)
' "$STACK" >/dev/null 2>&1; then
  add_finding "current_stack.shape" "current-stack.json must be PASS, dated today, and include build_class, domain, stack_items, sources, stale_training_checks, evidence_refs, and ts"
fi

bad_sources="$(jq -r --arg today "$RUN_DATE" '
  (.sources // [])[]
  | select(
      ((.id // "") | length) == 0
      or (.kind as $k | ["official_docs","source_repo","release_notes","github_repo","security_advisory","standards_doc","local"] | index($k) | not)
      or ((.name // "") | length) == 0
      or ((.url // "") | length) == 0
      or (.last_checked != $today)
      or ((.captured_ref // "") | length) == 0
    )
  | .id // "<missing>"
' "$STACK" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_sources" ] && add_finding "sources.shape" "sources must have id, kind, name, url, last_checked=today, and captured_ref: $bad_sources"

if ! jq -e '(.sources // []) | any((.official == true) or (.kind as $k | ["official_docs","source_repo","release_notes","standards_doc"] | index($k) != null))' "$STACK" >/dev/null 2>&1; then
  add_finding "sources.official" "at least one source must be official docs, source repo, release notes, standards doc, or marked official=true"
fi

bad_items="$(jq -r '
  [(.sources // [])[].id] as $source_ids
  | (.stack_items // [])[]
  | select(
      ((.id // "") | length) == 0
      or (.category as $c | ["runtime","framework","database","infra","ai_model","library","tooling","standard","other"] | index($c) | not)
      or ((.name // "") | length) == 0
      or (.decision as $d | ["use","evaluate","reject","not_applicable"] | index($d) | not)
      or ((.source_ids // []) | length == 0)
      or ((.evidence_refs // []) | length == 0)
      or ((.rationale // "") | length) == 0
      or ((.source_ids // []) | any(($source_ids | index(.)) | not))
    )
  | .id // "<missing>"
' "$STACK" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_items" ] && add_finding "stack_items.shape" "stack_items must cite known sources, evidence, decision, and rationale: $bad_items"

bad_training_checks="$(jq -r '
  [(.sources // [])[].id] as $source_ids
  | (.stale_training_checks // [])[]
  | select(
      ((.claim // "") | length) == 0
      or ((.checked_against_source_ids // []) | length == 0)
      or (.verdict as $v | ["current","changed","unknown"] | index($v) | not)
      or ((.action // "") | length) == 0
      or ((.evidence_refs // []) | length == 0)
      or ((.checked_against_source_ids // []) | any(($source_ids | index(.)) | not))
    )
  | .claim // "<missing>"
' "$STACK" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_training_checks" ] && add_finding "stale_training_checks.shape" "stale training checks must cite known sources, verdict, action, and evidence: $bad_training_checks"

placeholder_hits="$(jq -r '
  [
    (.domain // ""),
    ((.stack_items // [])[]? | .name, .rationale, (.version_or_constraint // "")),
    ((.sources // [])[]? | .name, .url, .captured_ref),
    ((.stale_training_checks // [])[]? | .claim, .action)
  ]
  | map(select(test("(?i)(todo|tbd|placeholder|lorem|dummy|example\\.com)")))
  | unique
  | .[]
' "$STACK" 2>/dev/null | paste -sd ', ' -)"
[ -n "$placeholder_hits" ] && add_finding "placeholder_text" "current-stack.json contains placeholder text: $placeholder_hits"

state_class=""
if [ -s "$STATE" ] && jq empty "$STATE" >/dev/null 2>&1; then
  state_class="$(jq -r '.build_class // empty' "$STATE" 2>/dev/null || true)"
fi
contract_class=""
if [ -s "$CONTRACT" ] && jq empty "$CONTRACT" >/dev/null 2>&1; then
  contract_class="$(jq -r '.build_class // empty' "$CONTRACT" 2>/dev/null || true)"
fi
stack_class="$(jq -r '.build_class // empty' "$STACK" 2>/dev/null || true)"
[ -n "$state_class" ] && [ -n "$stack_class" ] && [ "$state_class" != "$stack_class" ] && add_finding "class.state" "current-stack build_class '$stack_class' does not match STATE build_class '$state_class'"
[ -n "$contract_class" ] && [ -n "$stack_class" ] && [ "$contract_class" != "$stack_class" ] && add_finding "class.contract" "current-stack build_class '$stack_class' does not match build-contract build_class '$contract_class'"

refs="$(jq -r '
  [
    (.evidence_refs // [])[]?,
    ((.stack_items // [])[]? | (.evidence_refs // [])[]?),
    ((.sources // [])[]? | .captured_ref? // empty),
    ((.stale_training_checks // [])[]? | (.evidence_refs // [])[]?)
  ]
  | unique
  | .[]
' "$STACK" 2>/dev/null)"
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  check_ref "evidence_ref" "$ref"
done <<EOF
$refs
EOF

if [ -s "$FINGERPRINT_REPORT" ] && jq empty "$FINGERPRINT_REPORT" >/dev/null 2>&1; then
  fp_verdict="$(jq -r '.verdict // empty' "$FINGERPRINT_REPORT")"
  if [ "$fp_verdict" = "DRIFT" ]; then
    drift_ts="$(jq -r '.ts // empty' "$FINGERPRINT_REPORT")"
    stack_ts="$(jq -r '.ts // empty' "$STACK")"
    if ! jq -e --arg ts "$drift_ts" '
      .stack_fingerprint
      | type == "object"
      and .report_ref == "walteur-kit/stack-fingerprint-report.json"
      and .drift_ts == $ts
      and .acknowledged_drift == true
      and ((.acknowledgement // "") | length > 0)
    ' "$STACK" >/dev/null 2>&1; then
      add_finding "stack_fingerprint.drift_ack" "stack-fingerprint DRIFT requires matching acknowledged_drift proof in current-stack.json"
    fi
    if [ -n "$drift_ts" ] && [ -n "$stack_ts" ] && [[ "$stack_ts" < "$drift_ts" ]]; then
      add_finding "stack_fingerprint.freshness" "current-stack ts must be at or after stack-fingerprint drift ts"
    fi
  fi
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "validation" "$failures current-stack finding(s)" "$findings"
  echo "current-stack-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' >&2
  exit 2
fi

write_report "PASS" "validated" "current stack proof is dated, sourced, and evidenced" "[]"
echo "current-stack-gate verdict: PASS -> $REPORT" >&2
exit 0
