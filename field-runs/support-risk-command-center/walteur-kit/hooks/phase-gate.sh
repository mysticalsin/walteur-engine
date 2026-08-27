#!/usr/bin/env bash
# WALTEUR phase-gate - enforces ordered movement through the harness loop.
#
# Contract:
#   - STATE.json absent        => NOT_APPLICABLE, exit 0.
#   - jq absent                => SKIP, exit 0, recorded loudly.
#   - malformed state          => FAIL, exit 2.
#   - phase order violation    => FAIL, exit 2.
#   - ordered state            => PASS, exit 0.
#   - walteur-kit/PAUSED       => exit 2.
#
# Report:
#   walteur-kit/phase-gate-report.json
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
STATE="${WALTEUR_STATE_FILE:-$KIT/autopilot/STATE.json}"
CONTRACT="${WALTEUR_BUILD_CONTRACT_FILE:-$KIT/build-contract.json}"
REGISTRY="${WALTEUR_GATE_REGISTRY_FILE:-$KIT/gate-registry.json}"
REPORT="$KIT/phase-gate-report.json"
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
      '{verdict:$v, ts:$ts, gate:"phase-gate", state_file:$p, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"phase-gate","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
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
    echo "phase-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    dst="$1"
    phase="$2"
    stages="$3"
    gates="$4"
    mkdir -p "$(dirname "$dst")"
    cat > "$dst" <<JSON
{
  "schema_version": 1,
  "run_id": "phase-selftest",
  "goal": "prove phase advancement",
  "build_class": "software",
  "risk_tier": "medium",
  "phase": "$phase",
  "autonomy_policy": "full_autopilot",
  "budgets": { "time_minutes": 60, "input_tokens": 1000, "output_tokens": 500, "cost_usd": 1.25 },
  "stages": [$stages],
  "gates": [$gates],
  "evidence": [
    { "id": "ev-intake", "kind": "report", "verdict": "PASS", "summary": "intake evidence" },
    { "id": "ev-discover", "kind": "report", "verdict": "PASS", "summary": "discover evidence" },
    { "id": "ev-plan", "kind": "command", "verdict": "PASS", "command": "true" },
    { "id": "ev-build", "kind": "report", "verdict": "PASS", "summary": "build evidence" },
    { "id": "ev-verify", "kind": "report", "verdict": "PASS", "summary": "verify evidence" },
    { "id": "ev-review", "kind": "review", "verdict": "PASS", "summary": "review evidence" }
  ],
  "updated_at": "2026-06-22T00:00:00Z"
}
JSON
  }

  write_contract() {
    dst="$1"
    gates="$2"
    mkdir -p "$(dirname "$dst")"
    cat > "$dst" <<JSON
{
  "schema_version": 1,
  "contract_id": "phase-selftest-contract",
  "verification": {
    "gates": [$gates]
  }
}
JSON
  }

  good_stages='{ "name": "intake", "status": "passed", "evidence_ids": ["ev-intake"] },
    { "name": "discover", "status": "passed", "evidence_ids": ["ev-discover"] },
    { "name": "plan", "status": "passed", "evidence_ids": ["ev-plan"] },
    { "name": "build", "status": "passed", "evidence_ids": ["ev-build"] },
    { "name": "verify", "status": "in_progress" },
    { "name": "review", "status": "not_started" },
    { "name": "ship", "status": "not_started" },
    { "name": "reflect", "status": "not_started" }'

  ship_stages='{ "name": "intake", "status": "passed", "evidence_ids": ["ev-intake"] },
    { "name": "discover", "status": "passed", "evidence_ids": ["ev-discover"] },
    { "name": "plan", "status": "passed", "evidence_ids": ["ev-plan"] },
    { "name": "build", "status": "passed", "evidence_ids": ["ev-build"] },
    { "name": "verify", "status": "passed", "evidence_ids": ["ev-verify"] },
    { "name": "review", "status": "passed", "evidence_ids": ["ev-review"] },
    { "name": "ship", "status": "in_progress" },
    { "name": "reflect", "status": "not_started" }'

  good_gates='{ "id": "build-contract-lint", "stage": "intake", "status": "PASS", "evidence_ids": ["ev-intake"] },
    { "id": "prd-gate", "stage": "discover", "status": "PASS", "evidence_ids": ["ev-discover"] },
    { "id": "spec-lint", "stage": "plan", "status": "PASS", "evidence_ids": ["ev-plan"] },
    { "id": "build-receipt", "stage": "build", "status": "PASS", "evidence_ids": ["ev-build"] },
    { "id": "release-gate", "stage": "ship", "status": "SKIP", "reason": "Ship stage has not started." }'

  echo "phase-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/phase-gate-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no STATE.json -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/phase-gate-selftest.XXXXXX")" || return 1
  stages='{ "name": "intake", "status": "in_progress" },
    { "name": "discover", "status": "not_started" },
    { "name": "plan", "status": "not_started" },
    { "name": "build", "status": "not_started" },
    { "name": "verify", "status": "not_started" },
    { "name": "review", "status": "not_started" },
    { "name": "ship", "status": "not_started" },
    { "name": "reflect", "status": "not_started" }'
  gates='{ "id": "build-contract-lint", "stage": "intake", "status": "SKIP", "reason": "Initial scaffold; evidence pending." },
    { "id": "phase-gate", "stage": "verify", "status": "SKIP", "reason": "Initial scaffold; evidence pending." }'
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "intake" "$stages" "$gates"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "intake scaffold -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/phase-gate-selftest.XXXXXX")" || return 1
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "verify" "$good_stages" "$good_gates"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "ordered verify state -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/phase-gate-selftest.XXXXXX")" || return 1
  detect_skip_gates='{ "id": "build-contract-lint", "stage": "intake", "status": "PASS", "evidence_ids": ["ev-intake"] },
    { "id": "prd-gate", "stage": "discover", "status": "SKIP", "reason": "No product discovery surface applies to this selftest." },
    { "id": "spec-lint", "stage": "plan", "status": "PASS", "evidence_ids": ["ev-plan"] }'
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "verify" "$good_stages" "$detect_skip_gates"
  write_contract "$tmp/walteur-kit/build-contract.json" '{ "id": "prd-gate", "stage": "discover", "hardness": "detect_or_skip", "expected_evidence": "PRD or explicit non-applicability" }, { "id": "spec-lint", "stage": "plan", "hardness": "hard", "expected_evidence": "plan lint evidence" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "detect_or_skip prior gate may skip with reason -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/phase-gate-selftest.XXXXXX")" || return 1
  hard_skip_gates='{ "id": "build-contract-lint", "stage": "intake", "status": "PASS", "evidence_ids": ["ev-intake"] },
    { "id": "spec-lint", "stage": "plan", "status": "SKIP", "reason": "Not applicable for this selftest." },
    { "id": "phase-gate", "stage": "verify", "status": "PASS", "evidence_ids": ["ev-verify"] }'
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "ship" "$ship_stages" "$hard_skip_gates"
  write_contract "$tmp/walteur-kit/build-contract.json" '{ "id": "spec-lint", "stage": "plan", "hardness": "hard", "expected_evidence": "plan lint evidence" }'
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "hard prior gate skipped after due phase -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/phase-gate-selftest.XXXXXX")" || return 1
  bad_stages='{ "name": "intake", "status": "passed", "evidence_ids": ["ev-intake"] },
    { "name": "discover", "status": "not_started" },
    { "name": "plan", "status": "not_started" },
    { "name": "build", "status": "not_started" },
    { "name": "verify", "status": "in_progress" },
    { "name": "review", "status": "not_started" },
    { "name": "ship", "status": "not_started" },
    { "name": "reflect", "status": "not_started" }'
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "verify" "$bad_stages" "$good_gates"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "jumped to verify with open prior stages -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/phase-gate-selftest.XXXXXX")" || return 1
  bad_skip='{ "name": "intake", "status": "skipped", "notes": "Initial scaffold; evidence pending." },
    { "name": "discover", "status": "in_progress" },
    { "name": "plan", "status": "not_started" },
    { "name": "build", "status": "not_started" },
    { "name": "verify", "status": "not_started" },
    { "name": "review", "status": "not_started" },
    { "name": "ship", "status": "not_started" },
    { "name": "reflect", "status": "not_started" }'
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "discover" "$bad_skip" "$gates"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "prior stage skipped with pending reason -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/phase-gate-selftest.XXXXXX")" || return 1
  future_pass='{ "name": "intake", "status": "in_progress" },
    { "name": "discover", "status": "not_started" },
    { "name": "plan", "status": "not_started" },
    { "name": "build", "status": "passed", "evidence_ids": ["ev-build"] },
    { "name": "verify", "status": "not_started" },
    { "name": "review", "status": "not_started" },
    { "name": "ship", "status": "not_started" },
    { "name": "reflect", "status": "not_started" }'
  write_state "$tmp/walteur-kit/autopilot/STATE.json" "intake" "$future_pass" "$gates"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "future stage already passed -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/phase-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit/autopilot"
  printf '{ bad json\n' > "$tmp/walteur-kit/autopilot/STATE.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "malformed JSON -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "phase-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }

if [ ! -f "$STATE" ]; then
  echo "phase-gate: no STATE.json found at ${STATE#"$ROOT"/} - gate not applicable." >&2
  write_report "NOT_APPLICABLE" "STATE.json absent" "[]"
  exit 0
fi

if ! have jq; then
  echo "phase-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  write_report "SKIP" "jq not installed" "[]"
  exit 0
fi

if ! jq empty "$STATE" >/dev/null 2>&1; then
  findings='[{"check":"json","message":"STATE.json is not valid JSON"}]'
  write_report "FAIL" "STATE.json is not valid JSON" "$findings"
  echo "phase-gate verdict: FAIL - STATE.json is not valid JSON -> $REPORT" >&2
  exit 2
fi

hard_gate_ids='[]'
if [ -f "$CONTRACT" ] && jq empty "$CONTRACT" >/dev/null 2>&1; then
  candidate="$(jq -c '[.verification.gates[]? | select(.hardness == "hard") | .id] | unique' "$CONTRACT" 2>/dev/null || printf '[]')"
  if printf '%s' "$candidate" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
    hard_gate_ids="$candidate"
  fi
fi
if [ "$hard_gate_ids" = "[]" ] && [ -f "$REGISTRY" ] && jq empty "$REGISTRY" >/dev/null 2>&1; then
  build_class="$(jq -r '.build_class // empty' "$STATE")"
  risk_tier="$(jq -r '.risk_tier // empty' "$STATE")"
  candidate="$(jq -c --arg c "$build_class" --arg r "$risk_tier" '
    ((.requirements.all // []) + (.requirements.by_build_class[$c] // []) + (.requirements.by_risk_tier[$r] // []) | unique) as $ids
    | [.gates[]? | select((.id as $id | $ids | index($id)) and (.hardness == "hard")) | .id] | unique
  ' "$REGISTRY" 2>/dev/null || printf '[]')"
  if printf '%s' "$candidate" | jq -e 'type=="array"' >/dev/null 2>&1; then
    hard_gate_ids="$candidate"
  fi
fi

findings="$(jq -c --argjson hard_ids "$hard_gate_ids" '
  def idx($p):
    ["intake","discover","plan","build","verify","review","ship","reflect"] | index($p);
  def hard_gate($id):
    ($hard_ids | index($id)) != null;
  def pending_text:
    test("(initial scaffold|evidence pending|pending|todo|tbd|not run|not yet|missing proof)"; "i");
  . as $s
  | ($s.phase // "") as $phase
  | (idx($phase)) as $current
  | ((($s.stages // []) | map(select(.name == $phase)) | .[0].status) // "") as $current_status
  | [($s.evidence // [])[].id] as $eids
  | if $phase == "stopped" then
      []
    elif $current == null then
      [{check:"phase.enum", message:("unknown phase: " + $phase)}]
    else
      (
        [(["intake","discover","plan","build","verify","review","ship","reflect"][] as $name
          | select((($s.stages // []) | map(.name) | index($name)) | not)
          | {check:("stage.present." + $name), message:("missing stage: " + $name)})]
        +
        [($s.stages // [])[] as $stage
          | (idx($stage.name)) as $si
          | select($si != null and $si < $current and (($stage.status // "") | IN("passed","skipped") | not))
          | {check:("stage.closed." + $stage.name), message:("prior stage " + $stage.name + " must be passed or skipped before phase " + $phase)}]
        +
        [($s.stages // [])[] as $stage
          | (idx($stage.name)) as $si
          | select($si != null and $si < $current and ($stage.status == "passed") and ((($stage.evidence_ids // []) | length) == 0))
          | {check:("stage.evidence." + $stage.name), message:("passed prior stage " + $stage.name + " needs evidence_ids")}]
        +
        [($s.stages // [])[] as $stage
          | (idx($stage.name)) as $si
          | select($si != null and $si < $current and ($stage.status == "skipped") and (((($stage.notes // "") | length) == 0) or (($stage.notes // "") | pending_text)))
          | {check:("stage.skip_reason." + $stage.name), message:("skipped prior stage " + $stage.name + " needs a real non-pending note")}]
        +
        [($s.stages // [])[] as $stage
          | (idx($stage.name)) as $si
          | select($si != null and $si == $current and (($stage.status // "") | IN("in_progress","passed") | not))
          | {check:("stage.current." + $stage.name), message:("current phase stage " + $stage.name + " must be in_progress or passed")}]
        +
        [($s.stages // [])[] as $stage
          | (idx($stage.name)) as $si
          | select($si != null and $si > $current and (($stage.status // "") | IN("passed","in_progress")))
          | {check:("stage.future." + $stage.name), message:("future stage " + $stage.name + " cannot be " + ($stage.status // "<missing>") + " while phase is " + $phase)}]
        +
        [($s.gates // [])[] as $gate
          | (idx($gate.stage)) as $gi
          | select($gi != null and $gi < $current and (($gate.status // "") | IN("PASS","SKIP","ACCEPTED_RISK") | not))
          | {check:("gate.closed." + ($gate.id // "<missing>")), message:("prior gate " + ($gate.id // "<missing>") + " is " + ($gate.status // "<missing>"))}]
        +
        [($s.gates // [])[] as $gate
          | (idx($gate.stage)) as $gi
          | select($gi != null and $gi < $current and ($gate.status == "SKIP") and (((($gate.reason // "") | length) == 0) or (($gate.reason // "") | pending_text)))
          | {check:("gate.skip_reason." + ($gate.id // "<missing>")), message:("prior skipped gate " + ($gate.id // "<missing>") + " needs a real non-pending reason")}]
        +
        [($s.gates // [])[] as $gate
          | (idx($gate.stage)) as $gi
          | select($gi != null
              and hard_gate($gate.id // "")
              and ($gate.status == "SKIP")
              and ($gi < $current or ($gi == $current and $current_status == "passed")))
          | {check:("gate.hard_skip." + ($gate.id // "<missing>")), message:("hard gate " + ($gate.id // "<missing>") + " cannot be skipped once its stage is due")}]
        +
        [($s.gates // [])[] as $gate
          | (idx($gate.stage)) as $gi
          | select($gi != null and $gi <= $current and (($gate.status // "") | IN("FAIL","BLOCKED")))
          | {check:("gate.red." + ($gate.id // "<missing>")), message:("gate " + ($gate.id // "<missing>") + " blocks phase " + $phase + " with status " + ($gate.status // "<missing>"))}]
        +
        [($s.gates // [])[] as $gate
          | (idx($gate.stage)) as $gi
          | select($gi != null and $gi < $current and ($gate.status == "PASS") and ((($gate.evidence_ids // []) | length) == 0))
          | {check:("gate.evidence." + ($gate.id // "<missing>")), message:("passed prior gate " + ($gate.id // "<missing>") + " needs evidence_ids")}]
        +
        [($s.stages // [])[] as $stage
          | (($stage.evidence_ids // [])[]?) as $eid
          | select(($eids | index($eid)) | not)
          | {check:("stage.evidence_ref." + ($stage.name // "<missing>")), message:("stage references missing evidence id " + $eid)}]
        +
        [($s.gates // [])[] as $gate
          | (($gate.evidence_ids // [])[]?) as $eid
          | select(($eids | index($eid)) | not)
          | {check:("gate.evidence_ref." + ($gate.id // "<missing>")), message:("gate references missing evidence id " + $eid)}]
      )
    end
' "$STATE")"

failures="$(printf '%s' "$findings" | jq 'length')"
if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "$failures phase gate finding(s)" "$findings"
  echo "phase-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' >&2
  exit 2
fi

write_report "PASS" "phase order and prior-stage evidence are valid" "[]"
echo "phase-gate verdict: PASS -> $REPORT" >&2
exit 0
