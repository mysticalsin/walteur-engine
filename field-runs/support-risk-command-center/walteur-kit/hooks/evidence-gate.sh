#!/usr/bin/env bash
# WALTEUR evidence-gate - verifies that STATE evidence is real enough to support claims.
#
# Contract:
#   - STATE.json absent           => NOT_APPLICABLE, exit 0.
#   - jq absent                   => SKIP, exit 0, recorded loudly.
#   - malformed state             => FAIL, exit 2.
#   - broken evidence ledger      => FAIL, exit 2.
#   - summary-only PASS evidence  => FAIL, exit 2.
#   - coherent evidence ledger    => PASS, exit 0.
#   - walteur-kit/PAUSED          => exit 2.
#
# Report:
#   walteur-kit/evidence-gate-report.json
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
STATE="${WALTEUR_STATE_FILE:-$KIT/autopilot/STATE.json}"
REPORT="$KIT/evidence-gate-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  verdict="$1"
  reason="$2"
  findings="${3:-[]}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" --arg p "${STATE#"$ROOT"/}" \
      --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"evidence-gate", state_file:$p, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"evidence-gate","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
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
    echo "evidence-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    dst="$1"
    gate_status="$2"
    evidence_json="$3"
    mkdir -p "$(dirname "$dst")"
    cat > "$dst" <<JSON
{
  "schema_version": 1,
  "run_id": "evidence-selftest",
  "goal": "prove evidence ledger",
  "build_class": "software",
  "risk_tier": "medium",
  "phase": "verify",
  "autonomy_policy": "full_autopilot",
  "budgets": { "time_minutes": 60, "input_tokens": 1000, "output_tokens": 500, "cost_usd": 1.25 },
  "stages": [
    { "name": "verify", "status": "in_progress", "evidence_ids": ["ev-report"] }
  ],
  "gates": [
    { "id": "verify-gate", "stage": "verify", "status": "$gate_status", "evidence_ids": ["ev-report"] }
  ],
  "evidence": [$evidence_json],
  "updated_at": "2026-06-22T00:00:00Z"
}
JSON
  }

  echo "evidence-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/evidence-gate-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no STATE.json -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/evidence-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  cat > "$tmp/walteur-kit/autopilot/STATE.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "initial",
  "goal": "initial scaffold",
  "build_class": "software",
  "risk_tier": "medium",
  "phase": "intake",
  "autonomy_policy": "full_autopilot",
  "budgets": { "time_minutes": 0, "input_tokens": 0, "output_tokens": 0, "cost_usd": 0 },
  "stages": [{ "name": "intake", "status": "in_progress" }],
  "gates": [{ "id": "evidence-gate", "stage": "verify", "status": "SKIP", "reason": "Initial scaffold; evidence pending." }],
  "evidence": [],
  "updated_at": "2026-06-22T00:00:00Z"
}
JSON
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "initial scaffold with no PASS claims -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/evidence-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{"verdict":"PASS","gate":"verify-gate"}\n' > "$tmp/walteur-kit/verify-report.json"
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "PASS" '{ "id": "ev-report", "kind": "report", "verdict": "PASS", "path": "walteur-kit/verify-report.json" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PASS gate with existing PASS JSON report -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/evidence-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "PASS" '{ "id": "ev-report", "kind": "report", "verdict": "PASS", "summary": "I read the output" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PASS gate with summary-only evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/evidence-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'command output\n' > "$tmp/walteur-kit/command-output.log"
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "PASS" '{ "id": "ev-report", "kind": "command", "verdict": "PASS", "command": "true", "path": "walteur-kit/command-output.log", "timestamp": "2026-06-22T00:00:00Z" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PASS gate with command output proof -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/evidence-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "PASS" '{ "id": "ev-report", "kind": "manual_check", "verdict": "PASS", "summary": "QA owner read the output", "owner": "qa-lead", "timestamp": "2026-06-22T00:00:00Z" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PASS gate with signed manual proof -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/evidence-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  : > "$tmp/walteur-kit/empty-report.json"
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "PASS" '{ "id": "ev-report", "kind": "report", "verdict": "PASS", "path": "walteur-kit/empty-report.json" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PASS gate with empty evidence file -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/evidence-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "PASS" '{ "id": "ev-report", "kind": "report", "verdict": "PASS", "path": "walteur-kit/missing-report.json" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PASS evidence path missing -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/evidence-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{"verdict":"PASS","gate":"verify-gate"}\n' > "$tmp/walteur-kit/verify-report.json"
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "PASS" '{ "id": "ev-report", "kind": "report", "verdict": "FAIL", "path": "walteur-kit/verify-report.json" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PASS gate backed by FAIL evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/evidence-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{"verdict":"FAIL","gate":"verify-gate"}\n' > "$tmp/walteur-kit/verify-report.json"
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "PASS" '{ "id": "ev-report", "kind": "report", "verdict": "PASS", "path": "walteur-kit/verify-report.json" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PASS evidence report says FAIL -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/evidence-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{"verdict":"PASS","gate":"verify-gate"}\n' > "$tmp/walteur-kit/verify-report.json"
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "PASS" '{ "id": "ev-report", "kind": "report", "verdict": "PASS", "path": "walteur-kit/verify-report.json" }, { "id": "ev-report", "kind": "report", "verdict": "PASS", "path": "walteur-kit/verify-report.json" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "duplicate evidence ids -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/evidence-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  printf '{ bad json\n' > "$tmp/walteur-kit/autopilot/STATE.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "malformed JSON -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "evidence-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }

if [ ! -f "$STATE" ]; then
  echo "evidence-gate: no STATE.json found at ${STATE#"$ROOT"/} - gate not applicable." >&2
  write_report "NOT_APPLICABLE" "STATE.json absent" "[]"
  exit 0
fi

if ! have jq; then
  echo "evidence-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  write_report "SKIP" "jq not installed" "[]"
  exit 0
fi

if ! jq empty "$STATE" >/dev/null 2>&1; then
  findings='[{"check":"json","message":"STATE.json is not valid JSON"}]'
  write_report "FAIL" "STATE.json is not valid JSON" "$findings"
  echo "evidence-gate verdict: FAIL - STATE.json is not valid JSON -> $REPORT" >&2
  exit 2
fi

findings="$(jq -c '
  . as $s
  | [($s.evidence // [])[].id] as $ids
  | (
    [($ids | group_by(.)[] | select(length>1) | .[0]) as $id
      | {check:("evidence.unique." + $id), message:("duplicate evidence id: " + $id)}]
    +
    [
      (((($s.gates // [])[]? | (.evidence_ids // [])[]?), (($s.stages // [])[]? | (.evidence_ids // [])[]?)) | select(($ids | index(.)) | not)) as $id
      | {check:("evidence.ref." + $id), message:("referenced evidence id is missing: " + $id)}
    ]
	    +
	    [
	      ($s.evidence // [])[] as $ev
	      | select($ev.verdict == "PASS")
	      | ($ev.kind // "") as $kind
	      | ((($ev.path // "") | length) > 0) as $has_path
	      | ((($ev.command // "") | length) > 0) as $has_command
	      | ((($ev.summary // "") | length) > 0) as $has_summary
	      | ((($ev.owner // "") | length) > 0) as $has_owner
	      | ((($ev.timestamp // "") | length) > 0) as $has_timestamp
	      | (
	          (((["report","audit","screenshot","source"] | index($kind)) != null) and $has_path)
	          or ($kind == "command" and $has_command and $has_path and $has_timestamp)
	          or (((["review","decision","manual_check"] | index($kind)) != null) and ($has_path or ($has_owner and $has_timestamp and $has_summary)))
	        ) as $proof_ok
	      | select($proof_ok | not)
	      | {check:("evidence.replayable." + ($ev.id // "<missing>")), message:("PASS evidence " + ($ev.id // "<missing>") + " must be replayable: report/audit/screenshot/source need path; command needs command+path+timestamp; review/decision/manual_check need path or owner+timestamp+summary")}
	    ]
	    +
	    [
	      ($s.gates // [])[] as $gate
	      | select($gate.status == "PASS")
	      | [($gate.evidence_ids // [])[] as $eid | ($s.evidence // [])[] | select(.id == $eid and .verdict == "PASS")] as $pass_evidence
      | select(($pass_evidence | length) == 0)
      | {check:("gate.pass_evidence." + ($gate.id // "<missing>")), message:("PASS gate " + ($gate.id // "<missing>") + " needs at least one PASS evidence item")}
    ]
    +
    [
      ($s.stages // [])[] as $stage
      | select($stage.status == "passed")
      | [($stage.evidence_ids // [])[] as $eid | ($s.evidence // [])[] | select(.id == $eid and .verdict == "PASS")] as $pass_evidence
      | select(($pass_evidence | length) == 0)
      | {check:("stage.pass_evidence." + ($stage.name // "<missing>")), message:("passed stage " + ($stage.name // "<missing>") + " needs at least one PASS evidence item")}
    ]
    +
    [
      ($s.gates // [])[] as $gate
      | select($gate.status == "PASS")
      | ($gate.evidence_ids // [])[] as $eid
      | ($s.evidence // [])[] | select(.id == $eid and (.verdict != "PASS"))
      | {check:("gate.bad_evidence." + ($gate.id // "<missing>")), message:("PASS gate " + ($gate.id // "<missing>") + " references non-PASS evidence " + (.id // "<missing>") + " with verdict " + (.verdict // "<missing>"))}
    ]
  )
' "$STATE")"

failures="$(printf '%s' "$findings" | jq 'length')"

while IFS=$'\t' read -r evidence_id evidence_kind evidence_verdict evidence_path; do
  [ -n "$evidence_id" ] || continue
  [ -n "$evidence_path" ] || continue

  case "$evidence_path" in
    ../*|*/../*|..|*/..)
      add_finding "evidence.path_scope.$evidence_id" "evidence path must not contain parent traversal: $evidence_path"
      continue
      ;;
  esac

  case "$evidence_path" in
    /*) full_path="$evidence_path" ;;
    *) full_path="$ROOT/$evidence_path" ;;
  esac

  case "$full_path" in
    "$ROOT"/*) ;;
    *)
      add_finding "evidence.path_scope.$evidence_id" "evidence path must stay under project root: $evidence_path"
      continue
      ;;
  esac

  if [ ! -f "$full_path" ]; then
    add_finding "evidence.path_exists.$evidence_id" "evidence path does not exist: $evidence_path"
    continue
  fi

  if [ "$evidence_verdict" = "PASS" ] && [ ! -s "$full_path" ]; then
    add_finding "evidence.path_nonempty.$evidence_id" "PASS evidence path is empty: $evidence_path"
    continue
  fi

  if jq empty "$full_path" >/dev/null 2>&1; then
    report_verdict="$(jq -r '.verdict // empty' "$full_path")"
    if [ -n "$report_verdict" ] && [ "$report_verdict" != "$evidence_verdict" ]; then
      add_finding "evidence.report_verdict.$evidence_id" "evidence verdict '$evidence_verdict' does not match report verdict '$report_verdict' at $evidence_path"
    fi
  fi
done <<EOF
$(jq -r '(.evidence // [])[] | [.id, .kind, .verdict, (.path // "")] | @tsv' "$STATE")
EOF

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "$failures evidence finding(s)" "$findings"
  echo "evidence-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' >&2
  exit 2
fi

write_report "PASS" "evidence ledger supports current claims" "[]"
echo "evidence-gate verdict: PASS -> $REPORT" >&2
exit 0
