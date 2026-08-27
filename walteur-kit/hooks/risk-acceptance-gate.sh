#!/usr/bin/env bash
# WALTEUR risk-acceptance-gate - proves high-risk ship and accepted-risk claims have owner signoff.
#
# Contract:
#   - STATE.json absent        => NOT_APPLICABLE, exit 0.
#   - jq absent                => SKIP, exit 0, recorded loudly.
#   - malformed state          => FAIL, exit 2.
#   - high/regulated ship without approved signoff => FAIL, exit 2.
#   - active authority boundary without approved signoff => FAIL, exit 2.
#   - ACCEPTED_RISK gate without owner signoff     => FAIL, exit 2.
#   - accepted high/critical known gap without owner signoff => FAIL, exit 2.
#   - clean state              => PASS, exit 0.
#   - walteur-kit/PAUSED       => exit 2.
#
# Report:
#   walteur-kit/risk-acceptance-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "risk-acceptance-gate - proves high-risk ship and accepted-risk claims have owner signoff."
  printf '%s\n' "usage: bash risk-acceptance-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/risk-acceptance-report.json - fix recipes: walteur-kit/REMEDIATION.md (## risk-acceptance-gate)"
  printf '%s\n' "bypass: WALTEUR_RISK_ACCEPTANCE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
STATE="${WALTEUR_STATE_FILE:-$KIT/autopilot/STATE.json}"
CONTRACT="${WALTEUR_BUILD_CONTRACT_FILE:-$KIT/build-contract.json}"
REPORT="$KIT/risk-acceptance-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  verdict="$1"
  reason="$2"
  findings="${3:-[]}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" \
      --arg state "${STATE#"$ROOT"/}" --arg contract "${CONTRACT#"$ROOT"/}" \
      --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"risk-acceptance", state_file:$state, build_contract_file:$contract, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"risk-acceptance","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
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
    echo "risk-acceptance-gate selftest SKIP - jq not installed."
    return 0
  fi

	  write_state() {
    dst="$1"
    phase="$2"
    risk="$3"
    gates="$4"
    gaps="$5"
    signoffs="$6"
    authority_boundaries="${7:-}"
    mkdir -p "$(dirname "$dst")"
    cat > "$dst" <<JSON
{
  "schema_version": 1,
  "run_id": "risk-acceptance-selftest",
  "goal": "prove signoff discipline",
  "build_class": "software",
  "risk_tier": "$risk",
  "phase": "$phase",
  "autonomy_policy": "full_autopilot",
  "budgets": { "time_minutes": 60, "input_tokens": 1000, "output_tokens": 500, "cost_usd": 1.25 },
  "stages": [
    { "name": "$phase", "status": "in_progress" }
  ],
  "gates": [$gates],
  "evidence": [
    { "id": "ev-risk", "kind": "manual_check", "verdict": "PASS", "summary": "owner approved risk" },
    { "id": "ev-accepted", "kind": "decision", "verdict": "ACCEPTED_RISK", "summary": "risk accepted by owner" }
  ],
  "signoffs": [$signoffs],
  "authority_boundaries": [$authority_boundaries],
  "known_gaps": [$gaps],
  "updated_at": "2026-06-22T00:00:00Z"
}
JSON
  }

  echo "risk-acceptance-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/risk-acceptance-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no STATE.json -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/risk-acceptance-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "intake" "high" "" "" ""
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "high-risk intake without signoff -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/risk-acceptance-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "ship" "low" '{ "id": "release-gate", "stage": "ship", "status": "PASS", "evidence_ids": ["ev-risk"] }' "" ""
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "low-risk ship without accepted risk -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/risk-acceptance-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "ship" "high" '{ "id": "release-gate", "stage": "ship", "status": "PASS", "evidence_ids": ["ev-risk"] }' "" ""
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "high-risk ship without signoff -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/risk-acceptance-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "ship" "high" '{ "id": "release-gate", "stage": "ship", "status": "PASS", "evidence_ids": ["ev-risk"] }' "" '{ "id": "ship-approval", "kind": "high_risk", "owner": "Risk owner", "status": "approved", "reason": "Release risk accepted with rollback ready.", "covers": ["ship"], "evidence_ids": ["ev-risk"], "timestamp": "2026-06-22T00:00:00Z" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "high-risk ship with approved signoff -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/risk-acceptance-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "verify" "medium" '{ "id": "security-gate", "stage": "verify", "status": "ACCEPTED_RISK", "owner": "Security", "reason": "Deferred scanner until network access.", "evidence_ids": ["ev-accepted"] }' "" ""
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "ACCEPTED_RISK gate without signoff -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/risk-acceptance-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "verify" "medium" '{ "id": "security-gate", "stage": "verify", "status": "ACCEPTED_RISK", "owner": "Security", "reason": "Deferred scanner until network access.", "evidence_ids": ["ev-accepted"] }' "" '{ "id": "security-risk", "kind": "accepted_risk", "owner": "Security", "status": "approved", "reason": "Accepted with follow-up owner.", "covers": ["security-gate"], "evidence_ids": ["ev-accepted"], "timestamp": "2026-06-22T00:00:00Z" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "ACCEPTED_RISK gate with signoff -> PASS" 0 "$?"
  rm -rf "$tmp"

	  tmp="$(mktemp -d "${TMPDIR:-/tmp}/risk-acceptance-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "ship" "medium" '{ "id": "release-gate", "stage": "ship", "status": "PASS", "evidence_ids": ["ev-risk"] }' '{ "gap": "No automated rollback rehearsal", "severity": "high", "owner": "SRE", "accepted_reason": "Manual rollback exists." }' ""
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "accepted high gap without signoff -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/risk-acceptance-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "ship" "medium" '{ "id": "release-gate", "stage": "ship", "status": "PASS", "evidence_ids": ["ev-risk"] }' "" "" '{ "id": "send-email", "kind": "external", "description": "Send a customer-facing email.", "owner": "Comms", "requires_signoff": true, "status": "active" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "external authority boundary without signoff -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/risk-acceptance-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "ship" "medium" '{ "id": "release-gate", "stage": "ship", "status": "PASS", "evidence_ids": ["ev-risk"] }' "" '{ "id": "charge-approval", "kind": "money", "owner": "Finance", "status": "approved", "reason": "Approved one-time charge with receipt evidence.", "covers": ["charge-card"], "evidence_ids": ["ev-risk"], "timestamp": "2026-06-22T00:00:00Z" }' '{ "id": "charge-card", "kind": "money", "description": "Charge a customer payment method.", "owner": "Finance", "requires_signoff": true, "status": "active" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "money authority boundary with signoff -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/risk-acceptance-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  printf '{ bad json\n' > "$tmp/walteur-kit/autopilot/STATE.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "malformed STATE.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "risk-acceptance-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_RISK_ACCEPTANCE:-on}" = "off" ] && {
  echo "risk-acceptance-gate: bypassed (WALTEUR_RISK_ACCEPTANCE=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_RISK_ACCEPTANCE=off" "[]"
  exit 0
}

if [ ! -f "$STATE" ]; then
  echo "risk-acceptance-gate: no STATE.json found at ${STATE#"$ROOT"/} - gate not applicable." >&2
  write_report "NOT_APPLICABLE" "STATE.json absent" "[]"
  exit 0
fi

if ! have jq; then
  echo "risk-acceptance-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  write_report "SKIP" "jq not installed" "[]"
  exit 0
fi

if ! jq empty "$STATE" >/dev/null 2>&1; then
  findings='[{"check":"json","message":"STATE.json is not valid JSON"}]'
  write_report "FAIL" "STATE.json is not valid JSON" "$findings"
  echo "risk-acceptance-gate verdict: FAIL - STATE.json is not valid JSON -> $REPORT" >&2
  exit 2
fi

data_classification=""
if [ -f "$CONTRACT" ] && jq empty "$CONTRACT" >/dev/null 2>&1; then
  data_classification="$(jq -r '.data_classification // ""' "$CONTRACT")"
fi

findings="$(jq -c --arg data "$data_classification" '
  def phase_due:
    (.phase // "") | IN("ship","reflect");
  def pending_text:
    test("(pending|todo|tbd|unknown|placeholder|not yet|missing proof)"; "i");
  def approved_signoffs:
    (.signoffs // []) | map(select(.status == "approved"));
  def evidence_ids:
    [(.evidence // [])[] | select(.verdict == "PASS" or .verdict == "ACCEPTED_RISK") | .id];
  def signoff_valid($s):
    (($s.owner // "") | length) > 0
    and (($s.reason // "") | length) > 0
    and (($s.reason // "") | pending_text | not)
    and (($s.timestamp // "") | length) > 0
    and ((($s.evidence_ids // []) | length) > 0)
    and (($s.evidence_ids // []) | all(. as $id | evidence_ids | index($id)));
  def has_ship_signoff:
    approved_signoffs
    | any((.kind | IN("ship","high_risk","regulated","production","external","data"))
        and signoff_valid(.));
	  def has_acceptance_signoff($target):
	    approved_signoffs
	    | any(.kind == "accepted_risk"
	        and signoff_valid(.)
	        and ((((.covers // []) | index($target)) != null) or (((.covers // []) | index("all")) != null)));
	  . as $root
	  |
	  (
  [
	    if ((.signoffs // []) | type) != "array" then
	      {check:"signoffs.shape", message:"signoffs must be an array when present"}
	    else empty end,
	    if ((.authority_boundaries // []) | type) != "array" then
	      {check:"authority_boundaries.shape", message:"authority_boundaries must be an array when present"}
	    else empty end,
	    if phase_due and ((.risk_tier // "") | IN("high","regulated") or ($data | IN("restricted","regulated"))) and (has_ship_signoff | not) then
	      {check:"ship.signoff", message:"high, regulated, restricted-data, or regulated-data ship needs approved owner signoff with evidence"}
	    else empty end
  ]
  +
  [
	    (.signoffs // [])[]?
	    | select(
	        ((.id // "") | length) == 0
	        or (.kind | IN("ship","high_risk","regulated","accepted_risk","scope_change","external","production","data","money","contract","irreversible","confidential_data") | not)
	        or (.status | IN("approved","rejected","pending") | not)
	        or ((.owner // "") | length) == 0
	        or ((.reason // "") | length) == 0
        or ((.timestamp // "") | length) == 0
      )
	    | {check:("signoff.shape." + (.id // "<missing>")), message:"signoff needs id, valid kind, owner, valid status, reason, and timestamp"}
	  ]
	  +
	  [
	    (.authority_boundaries // [])[]?
	    | select(
	        ((.id // "") | length) == 0
	        or (.kind | IN("external","money","contract","production","irreversible","confidential_data","data") | not)
	        or ((.description // "") | length) == 0
	        or ((.owner // "") | length) == 0
	        or (has("requires_signoff") and (.requires_signoff | type != "boolean"))
	        or (has("status") and (.status | IN("active","not_applicable","accepted_risk","closed") | not))
	      )
	    | {check:("authority_boundary.shape." + (.id // "<missing>")), message:"authority boundary needs id, valid kind, description, owner, optional boolean requires_signoff, and valid status"}
	  ]
	  +
	  [
	    (.signoffs // [])[]?
	    | select(.status == "approved" and (signoff_valid(.) | not))
	    | {check:("signoff.evidence." + (.id // "<missing>")), message:"approved signoff needs non-pending reason and PASS or ACCEPTED_RISK evidence_ids"}
  ]
  +
  [
    (.gates // [])[]?
    | select(.status == "ACCEPTED_RISK")
    | select((((.owner // "") | length) == 0) or (((.reason // "") | length) == 0))
    | {check:("accepted_risk.owner." + (.id // "<missing>")), message:"ACCEPTED_RISK gate needs owner and reason"}
  ]
  +
  [
    (.gates // [])[]?
    | select(.status == "ACCEPTED_RISK")
    | select(has_acceptance_signoff(.id // "") | not)
    | {check:("accepted_risk.signoff." + (.id // "<missing>")), message:"ACCEPTED_RISK gate needs approved accepted_risk signoff covering the gate id"}
  ]
  +
  [
    (.known_gaps // [])[]?
    | select(((.accepted_reason // "") | length) > 0 or (phase_due and ((.severity // "") | IN("high","critical"))))
    | select((((.owner // "") | length) == 0) or (((.accepted_reason // "") | length) == 0))
    | {check:("known_gap.acceptance." + ((.gap // "<missing>") | gsub("[^A-Za-z0-9_-]"; "-"))), message:"accepted or high/critical ship gap needs owner and accepted_reason"}
  ]
  +
  [
    (.known_gaps // [])[]?
    | select(((.accepted_reason // "") | length) > 0 or (phase_due and ((.severity // "") | IN("high","critical"))))
	    | select(has_acceptance_signoff(.gap // "") | not)
	    | {check:("known_gap.signoff." + ((.gap // "<missing>") | gsub("[^A-Za-z0-9_-]"; "-"))), message:"accepted or high/critical ship gap needs approved accepted_risk signoff covering the gap text"}
	  ]
	  +
	  [
	    (.authority_boundaries // [])[]?
	    | select((($root.phase // "") | IN("ship","reflect")))
	    | select((.requires_signoff // true) == true)
	    | select((.status // "active") | IN("active","accepted_risk"))
	    | . as $boundary
	    | select(
	        approved_signoffs
	        | any(
	            signoff_valid(.)
	            and (
	              (.kind == ($boundary.kind // ""))
	              or (($boundary.kind // "") == "confidential_data" and .kind == "data")
	              or (.kind == "ship")
	            )
	            and (
	              (((.covers // []) | index($boundary.id // "")) != null)
	              or (((.covers // []) | index($boundary.kind // "")) != null)
	              or (((.covers // []) | index("all")) != null)
	            )
	          )
	        | not
	      )
	    | {check:("authority_boundary.signoff." + (($boundary.id // "<missing>") | gsub("[^A-Za-z0-9_-]"; "-"))), message:("authority boundary " + ($boundary.id // "<missing>") + " (" + ($boundary.kind // "<missing>") + ") needs approved owner signoff with evidence")}
	  ]
	  )
	' "$STATE")"

failures="$(printf '%s' "$findings" | jq 'length')"
if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "$failures risk acceptance finding(s)" "$findings"
  echo "risk-acceptance-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' >&2
  exit 2
fi

write_report "PASS" "risk acceptance and signoff requirements satisfied" "[]"
echo "risk-acceptance-gate verdict: PASS -> $REPORT" >&2
exit 0
