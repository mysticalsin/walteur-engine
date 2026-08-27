#!/usr/bin/env bash
# WALTEUR qa-contract-gate - typed multi-dimension QA report gate.
#
# Contract:
#   - No QA report and not in verify/ship/reflect phase => NOT_APPLICABLE, exit 0.
#   - Empty runtime QA stub before verify              => NOT_APPLICABLE, exit 0.
#   - Verify/ship/reflect without a valid QA report    => FAIL, exit 2.
#   - PASS report with missing dimensions, VETO/FAIL lines, unsafe unit command, stale evidence, or missing PRD coverage => FAIL, exit 2.
#   - Complete QA proof                                => PASS, exit 0.
#
# EXEC default (S033, test-claim-verifier pattern): build-class-aware. When walteur-kit/build-contract.json
# exists and its build_class is a code class (software|data-ai|cloud-iac|mixed), WALTEUR_QA_EXEC defaults to
# ARMED (1) — a top-PASS QA report's unit_integration.recorded_command is RE-RUN via _probe-proof.sh
# validation and the observed exit is required to be 0. No contract, or a non-code class, keeps the legacy
# default of 0 (shape-read only). An explicit WALTEUR_QA_EXEC env value always wins over this default, so
# WALTEUR_QA_EXEC=0 still opts out even on a code-class contract. A no-op/constant recorded_command (true,
# bash -lc 'exit 0', etc.) is refused under EXEC — a green no-op proves nothing.
#
# Report:
#   walteur-kit/qa-contract-report.json
#
# Bypass:
#   WALTEUR_QA_CONTRACT=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "qa-contract-gate - typed multi-dimension QA report gate."
  printf '%s\n' "usage: bash qa-contract-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/qa-contract-report.json - fix recipes: walteur-kit/REMEDIATION.md (## qa-contract-gate)"
  printf '%s\n' "bypass: WALTEUR_QA_CONTRACT=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

# Fail-closed shared guard: the constant-exit / no-op probe CLASS is closed by _probe-proof.sh
# (probe_proves_something) — same guard test-claim-verifier-gate.sh and audit-contract-gate.sh source.
if [ -f "${SELF%/*}/_probe-proof.sh" ]; then . "${SELF%/*}/_probe-proof.sh"; fi

input_dir="${1:-}"
if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "$WALTEUR_ROOT" ]; then
  ROOT="$(cd "$WALTEUR_ROOT" && pwd)"
elif [ -n "$input_dir" ] && [ -d "$input_dir" ]; then
  ROOT="$(cd "$input_dir" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
KIT="$ROOT/walteur-kit"
QA="$KIT/qa-report.json"
STATE="$KIT/autopilot/STATE.json"
CONTRACT="$KIT/build-contract.json"
REPORT="$KIT/qa-contract-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# EXEC default: build-class-aware (S033) — mirrors audit-contract-gate.sh's default_audit_exec_armed.
default_qa_exec_armed() {
  [ -f "$CONTRACT" ] || return 1
  have jq || return 1
  _qbc="$(jq -r '.build_class // ""' "$CONTRACT" 2>/dev/null)"
  case "$_qbc" in software|data-ai|cloud-iac|mixed) return 0;; *) return 1;; esac
}
if [ -z "${WALTEUR_QA_EXEC:-}" ] && default_qa_exec_armed; then
  WALTEUR_QA_EXEC=1
fi

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# write_report VERDICT MODE REASON [FINDINGS_JSON] — when qa_probe_executed is set (1) by the EXEC block
# below, the report carries qa_probe_executed:true + observed_exit, the marker execution-ratio-gate counts.
write_report() {
  verdict="$1"
  mode="$2"
  reason="$3"
  findings_json="${4:-[]}"
  if have jq; then
    if [ "${qa_probe_executed:-0}" = "1" ]; then
      jq -n \
        --arg v "$verdict" --arg ts "$TS" --arg mode "$mode" --arg reason "$reason" \
        --arg qa "${QA#"$ROOT"/}" --argjson findings "$findings_json" --argjson oe "${qa_observed_exit:-null}" \
        '{verdict:$v, ts:$ts, gate:"qa-contract-gate", mode:$mode, qa_file:$qa, reason:$reason, findings:$findings, qa_probe_executed:true, observed_exit:$oe}' > "$REPORT" 2>/dev/null && return 0
    fi
    jq -n \
      --arg v "$verdict" --arg ts "$TS" --arg mode "$mode" --arg reason "$reason" \
      --arg qa "${QA#"$ROOT"/}" --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"qa-contract-gate", mode:$mode, qa_file:$qa, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"qa-contract-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0\n'
}

detect_qa_required() {
  QA_REQUIRED=0
  QA_REQUIRED_REASON=""

  if [ "${WALTEUR_QA_REQUIRED:-}" = "1" ]; then
    QA_REQUIRED=1
    QA_REQUIRED_REASON="WALTEUR_QA_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      verify|review|ship|reflect)
        QA_REQUIRED=1
        QA_REQUIRED_REASON="STATE.phase=$phase"
        return 0 ;;
    esac
  fi
}

latest_source_mtime() {
  latest=0
  update_latest() {
    f="$1"
    [ -f "$f" ] || return 0
    case "$f" in
      "$REPORT"|"$QA") return 0 ;;
    esac
    mt="$(mtime "$f")"
    [ "${mt:-0}" -gt "$latest" ] && latest="$mt"
  }

  if [ -d "$ROOT" ]; then
    while IFS= read -r -d '' f; do
      update_latest "$f"
    done < <(find "$ROOT" \
      \( -path '*/.git/*' -o -path '*/node_modules/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path "$KIT/*" \) -prune -o \
      -type f -print0 2>/dev/null)
  fi

  for f in \
    "$ROOT/PLAN.md" \
    "$ROOT/DESIGN.md" \
    "$KIT/PRD.md" \
    "$KIT/build-contract.json" \
    "$KIT/layers.json" \
    "$KIT/DEFINITION-OF-DONE.md"
  do
    update_latest "$f"
  done

  printf '%s\n' "$latest"
}

dim_value() {
  dim="$1"
  filter="$2"
  jq -r --arg d "$dim" "(.dimensions[\$d] // .[\$d])$filter" "$QA" 2>/dev/null || true
}

check_dimension() {
  dim="$1"
  if ! jq -e --arg d "$dim" '(.dimensions[$d] // .[$d]) | type == "object"' "$QA" >/dev/null 2>&1; then
    add_finding "dimensions.$dim" "QA dimension '$dim' is required"
    return 0
  fi

  verdict="$(dim_value "$dim" '.verdict // "" | ascii_upcase')"
  case "$verdict" in
    PASS|WAIVED|FAIL|VETO|BLOCKED) ;;
    *) add_finding "dimensions.$dim.verdict" "dimension '$dim' has invalid or missing verdict" ;;
  esac

  owner="$(dim_value "$dim" '.owner // ""')"
  [ -z "$owner" ] && add_finding "dimensions.$dim.owner" "dimension '$dim' requires owner"

  summary="$(dim_value "$dim" '.summary // ""')"
  [ -z "$summary" ] && add_finding "dimensions.$dim.summary" "dimension '$dim' requires summary"

  evidence="$(dim_value "$dim" '.evidence_ref // ""')"
  if [ "$verdict" = "PASS" ] && [ -z "$evidence" ]; then
    add_finding "dimensions.$dim.evidence_ref" "PASS dimension '$dim' requires evidence_ref"
  fi
  if [ -n "$evidence" ]; then
    evidence_file="${evidence%%#*}"
    case "$evidence_file" in
      /*) evidence_path="$evidence_file" ;;
      *) evidence_path="$ROOT/$evidence_file" ;;
    esac
    if [ ! -f "$evidence_path" ]; then
      add_finding "dimensions.$dim.evidence_exists" "dimension '$dim' evidence_ref points to missing file: $evidence"
    fi
  fi

  if [ "$verdict" = "WAIVED" ]; then
    reason="$(dim_value "$dim" '.waiver_reason // .reason // ""')"
    [ -z "$reason" ] && add_finding "dimensions.$dim.waiver_reason" "WAIVED dimension '$dim' requires waiver_reason or reason"
  fi

  if [ "$TOP_VERDICT" = "PASS" ]; then
    case "$verdict" in
      PASS|WAIVED) ;;
      *) add_finding "dimensions.$dim.blocking" "top PASS report cannot contain $verdict in '$dim'" ;;
    esac
  fi
}

check_unit_command() {
  cmd="$(dim_value "unit_integration" '.recorded_command // ""')"
  exit_code="$(dim_value "unit_integration" '.exit_code // empty')"
  [ -z "$cmd" ] && add_finding "unit_integration.recorded_command" "unit_integration requires recorded_command"
  if [ -n "$cmd" ] && printf '%s' "$cmd" | grep -Eq '[;&|`$<>]|\$\(|[[:cntrl:]]'; then
    add_finding "unit_integration.command_guard" "recorded_command contains shell metacharacters or indirection"
  fi
  if [ "$TOP_VERDICT" = "PASS" ] && [ "${exit_code:-}" != "0" ]; then
    add_finding "unit_integration.exit_code" "top PASS report requires unit_integration.exit_code == 0"
  fi
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
    echo "qa-contract-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    root="$1"
    phase="$2"
    mkdir -p "$root/walteur-kit/autopilot"
    jq -n --arg phase "$phase" '{
      schema_version: 1,
      run_id: "qa-selftest",
      goal: "QA selftest",
      owner: "QA",
      build_class: "software",
      risk_tier: "medium",
      phase: $phase,
      autonomy_policy: "full_autopilot",
      budgets: { time_minutes: 1, input_tokens: 1, output_tokens: 1, cost_usd: 0 },
      protected_paths: [],
      stages: [],
      gates: [],
      evidence: [],
      decisions: [],
      signoffs: [],
      authority_boundaries: [],
      blockers: [],
      known_gaps: [],
      next_action: "qa",
      baton_path: "walteur-kit/autopilot/STATE.json",
      updated_at: "2026-06-22T00:00:00Z"
    }' > "$root/walteur-kit/autopilot/STATE.json"
  }

  write_source() {
    root="$1"
    mkdir -p "$root/src" "$root/walteur-kit"
    printf 'export const App = () => "ok";\n' > "$root/src/App.tsx"
    printf '# PRD\n\n## Story\nSTORY-1 AC1 says the app shows status.\n' > "$root/walteur-kit/PRD.md"
    printf 'test evidence\n' > "$root/walteur-kit/test-output.txt"
  }

  write_good_qa() {
    root="$1"
    mode="${2:-good}"
    mkdir -p "$root/walteur-kit"
    jq -n --arg mode "$mode" '
      def dim($summary): { verdict: "PASS", owner: "QA", summary: $summary, evidence_ref: "walteur-kit/test-output.txt" };
      {
        schema_version: 1,
        verdict: "PASS",
        dimensions: {
          unit_integration: (dim("Unit and integration command passed.") + { recorded_command: "npm test", exit_code: 0 }),
          functional: dim("Functional flows passed."),
          logic: dim("Logic and invariants passed."),
          integration: dim("Integration seams passed."),
          data_integrity: dim("Data invariants passed."),
          security: dim("Security adversarial checks passed."),
          ux_resilience: dim("UX, accessibility, performance, and resilience checks passed.")
        },
        acceptance_criteria_coverage: [
          { story: "STORY-1", ac: "AC1", verdict: "PASS", evidence_ref: "walteur-kit/test-output.txt" }
        ],
        blockers: [],
        known_gaps: [],
        ts: "2026-06-22T00:00:00Z"
      }
      | if $mode == "logic-veto" then .dimensions.logic.verdict = "VETO" else . end
      | if $mode == "bad-unit" then .dimensions.unit_integration.exit_code = 1 else . end
      | if $mode == "empty-ac" then .acceptance_criteria_coverage = [] else . end
      | if $mode == "fail-empty" then .verdict = "FAIL" else . end
    ' > "$root/walteur-kit/qa-report.json"
  }

  echo "qa-contract-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "no QA and not verifying -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  write_state "$tmp" "verify"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "verify phase missing QA report -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  : > "$tmp/walteur-kit/qa-report.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "zero-byte runtime QA stub before verify -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{ bad json\n' > "$tmp/walteur-kit/qa-report.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "malformed QA report -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{"verdict":"PASS"}\n' > "$tmp/walteur-kit/qa-report.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "PASS stub QA report -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "verify"
  write_good_qa "$tmp" "logic-veto"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "top PASS with logic VETO -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "verify"
  write_good_qa "$tmp" "bad-unit"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "top PASS with unit exit_code 1 -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "verify"
  write_good_qa "$tmp" "empty-ac"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "PRD present but no acceptance coverage -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "verify"
  write_good_qa "$tmp" "fail-empty"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "FAIL QA report without blockers or failing dimension -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "verify"
  write_good_qa "$tmp" "good"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "complete QA report -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "verify"
  write_good_qa "$tmp" "good"
  touch -t 202001010000 "$tmp/walteur-kit/qa-report.json" 2>/dev/null || true
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "stale PASS QA report after source edit -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # ── EXEC-mode selftests (S033): re-run the recorded unit command, observe the real exit ──────────────
  # helper: write a "good" top-PASS QA report whose unit_integration.recorded_command is $1
  write_exec_qa() {
    root="$1"; cmd="$2"
    mkdir -p "$root/walteur-kit"
    jq -n --arg cmd "$cmd" '
      def dim($summary): { verdict: "PASS", owner: "QA", summary: $summary, evidence_ref: "walteur-kit/test-output.txt" };
      {
        schema_version: 1,
        verdict: "PASS",
        dimensions: {
          unit_integration: (dim("Unit and integration command passed.") + { recorded_command: $cmd, exit_code: 0 }),
          functional: dim("Functional flows passed."),
          logic: dim("Logic and invariants passed."),
          integration: dim("Integration seams passed."),
          data_integrity: dim("Data invariants passed."),
          security: dim("Security adversarial checks passed."),
          ux_resilience: dim("UX, accessibility, performance, and resilience checks passed.")
        },
        acceptance_criteria_coverage: [
          { story: "STORY-1", ac: "AC1", verdict: "PASS", evidence_ref: "walteur-kit/test-output.txt" }
        ],
        blockers: [],
        known_gaps: [],
        ts: "2026-06-22T00:00:00Z"
      }' > "$root/walteur-kit/qa-report.json"
  }

  # NEGATIVE CONTROL: WALTEUR_QA_EXEC=1 + no-op claim command (command:true) -> FAIL (refused, never blessed)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"; write_exec_qa "$tmp" "true"
  WALTEUR_QA_EXEC=1 WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "EXEC=1 no-op recorded_command 'true' -> FAIL (refused)" 2 "$?"
  rm -rf "$tmp"

  # NEGATIVE CONTROL: WALTEUR_QA_EXEC=1 + injected FAILING command -> FAIL (observed nonzero, false claim caught)
  if have node; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
    write_source "$tmp"; mkdir -p "$tmp/test"
    printf 'import test from "node:test";\nimport assert from "node:assert";\ntest("boom", () => { assert.equal(1, 2); });\n' > "$tmp/test/boom.test.mjs"
    write_exec_qa "$tmp" "node --test"
    WALTEUR_QA_EXEC=1 WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
    ck "EXEC=1 injected failing command -> FAIL (observed nonzero exit)" 2 "$?"
    jq -e '.qa_probe_executed==true and .observed_exit==1' "$tmp/walteur-kit/qa-contract-report.json" >/dev/null 2>&1
    ck "FAIL report records qa_probe_executed+observed_exit=1" 0 "$?"
    rm -rf "$tmp"
  fi

  # GENUINE PASS: WALTEUR_QA_EXEC=1 + a real passing test command -> PASS with exec markers recorded
  if have node; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
    write_source "$tmp"; mkdir -p "$tmp/test"
    printf 'import test from "node:test";\ntest("ok", () => {});\n' > "$tmp/test/ok.test.mjs"
    write_exec_qa "$tmp" "node --test"
    WALTEUR_QA_EXEC=1 WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
    ck "EXEC=1 genuine passing command -> PASS" 0 "$?"
    jq -e '.qa_probe_executed==true and .observed_exit==0' "$tmp/walteur-kit/qa-contract-report.json" >/dev/null 2>&1
    ck "PASS report records qa_probe_executed+observed_exit=0 (exec marker)" 0 "$?"
    rm -rf "$tmp"
  fi

  # build_class-armed default: software build_class + no explicit WALTEUR_QA_EXEC + no-op command -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"; write_exec_qa "$tmp" "true"
  printf '{"build_class":"software"}\n' > "$tmp/walteur-kit/build-contract.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "software build_class ARMS EXEC by default (no env) -> FAIL on no-op" 2 "$?"
  rm -rf "$tmp"

  # explicit WALTEUR_QA_EXEC=0 overrides the code-class default -> legacy shape-read PASS (no-op not run)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"; write_exec_qa "$tmp" "true"
  printf '{"build_class":"software"}\n' > "$tmp/walteur-kit/build-contract.json"
  WALTEUR_QA_EXEC=0 WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "explicit WALTEUR_QA_EXEC=0 overrides code-class default -> PASS (shape-read only)" 0 "$?"
  rm -rf "$tmp"

  # non-code build_class (document) keeps legacy default (EXEC stays 0) even though contract exists
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-contract-selftest.XXXXXX")" || return 1
  write_source "$tmp"; write_exec_qa "$tmp" "true"
  printf '{"build_class":"document"}\n' > "$tmp/walteur-kit/build-contract.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "document build_class -> legacy default (unaffected by EXEC-default change)" 0 "$?"
  rm -rf "$tmp"

  echo "qa-contract-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && {
  write_report "FAIL" "paused" "walteur-kit/PAUSED present" '[{"check":"paused","message":"WALTEUR is paused"}]'
  echo "qa-contract-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
}

if [ "${WALTEUR_QA_CONTRACT:-on}" = "off" ]; then
  write_report "SKIP" "bypass" "WALTEUR_QA_CONTRACT=off" "[]"
  echo "qa-contract-gate verdict: SKIP - bypassed via WALTEUR_QA_CONTRACT=off -> $REPORT" >&2
  exit 0
fi

if ! have jq; then
  write_report "SKIP" "tool-missing" "jq not installed" "[]"
  echo "qa-contract-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  exit 0
fi

detect_qa_required

if [ ! -f "$QA" ]; then
  if [ "$QA_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "missing" "QA report required ($QA_REQUIRED_REASON) but walteur-kit/qa-report.json is absent" \
      '[{"check":"qa.present","message":"verify/review/ship/reflect requires walteur-kit/qa-report.json shaped by walteur-kit/schemas/qa-report.schema.json"}]'
    echo "qa-contract-gate verdict: FAIL - QA report missing while required ($QA_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "not-applicable" "no QA report and current phase does not require one" "[]"
  echo "qa-contract-gate verdict: NOT_APPLICABLE - no QA report before verify -> $REPORT" >&2
  exit 0
fi

if [ ! -s "$QA" ]; then
  if [ "$QA_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "empty" "QA report required ($QA_REQUIRED_REASON) but walteur-kit/qa-report.json is empty" \
      '[{"check":"qa.nonempty","message":"zero-byte QA stubs cannot satisfy verify/review/ship/reflect"}]'
    echo "qa-contract-gate verdict: FAIL - empty QA report while required ($QA_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "runtime-stub" "zero-byte runtime QA stub before verify" "[]"
  echo "qa-contract-gate verdict: NOT_APPLICABLE - zero-byte runtime QA stub before verify -> $REPORT" >&2
  exit 0
fi

if ! jq empty "$QA" >/dev/null 2>&1; then
  write_report "FAIL" "invalid-json" "walteur-kit/qa-report.json is invalid JSON" \
    '[{"check":"qa.json","message":"walteur-kit/qa-report.json must be valid JSON"}]'
  echo "qa-contract-gate verdict: FAIL - QA JSON invalid -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0
TOP_VERDICT="$(jq -r 'if has("verdict") then (.verdict | tostring | ascii_upcase) else "" end' "$QA" 2>/dev/null || true)"

if ! jq -e '.schema_version == 1' "$QA" >/dev/null 2>&1; then
  add_finding "schema_version" "schema_version must be 1"
fi
case "$TOP_VERDICT" in
  PASS|FAIL|VETO|BLOCKED) ;;
  *) add_finding "verdict" "top-level verdict must be PASS, FAIL, VETO, or BLOCKED" ;;
esac
if ! jq -e '.ts | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$QA" >/dev/null 2>&1; then
  add_finding "ts" "ts must be UTC ISO format YYYY-MM-DDTHH:MM:SSZ"
fi
if ! jq -e '.dimensions | type == "object"' "$QA" >/dev/null 2>&1; then
  add_finding "dimensions.shape" "dimensions must be an object"
fi

for dim in unit_integration functional logic integration data_integrity security ux_resilience; do
  check_dimension "$dim"
done
check_unit_command

# ── EXECUTE PROBE — re-run the recorded unit command and OBSERVE the real exit (S033, test-claim pattern) ─
# A QA report can CLAIM unit_integration.exit_code==0 with nothing re-running it. When TOP_VERDICT is PASS
# and a recorded_command is present, this re-runs it through _probe-proof.sh validation (rejects no-op/
# constant-exit commands — a green no-op proves NOTHING) and requires the OBSERVED exit to be 0.
# WALTEUR_QA_EXEC=1 (build-class-armed by default, see top-of-file) makes this REQUIRED for a top-PASS
# report; WALTEUR_QA_EXEC=0 keeps the legacy shape-read-only behavior.
qa_probe_executed=0; qa_observed_exit="null"
if [ "$TOP_VERDICT" = "PASS" ]; then
  qa_cmd="$(dim_value "unit_integration" '.recorded_command // ""')"
  if [ "${WALTEUR_QA_EXEC:-0}" = "1" ]; then
    if [ -z "$qa_cmd" ] || [ "$qa_cmd" = "null" ]; then
      add_finding "unit_integration.exec_required" "WALTEUR_QA_EXEC=1: a top-PASS QA report requires unit_integration.recorded_command (re-runnable proof), not a trust-only exit_code claim"
    else
      qa_first="$(printf '%s' "$qa_cmd" | awk '{print $1}')"
      case "$qa_first" in
        npm|pnpm|yarn|npx|node|deno|bun|python|python3|pytest|tox|uv|go|cargo|make|just|task|bash|sh|jest|vitest|mocha|rspec|rake|phpunit|composer|dotnet|mvn|gradle|./gradlew|ctest|cmake) : ;;
        *) add_finding "unit_integration.runner" "recorded_command runner '$qa_first' is not an allowlisted test runner — refusing to execute an unrecognized claim command"; qa_first="__BLOCKED__" ;;
      esac
      if printf '%s' "$qa_cmd" | grep -Eqi 'curl|wget|/dev/tcp|base64|netcat|ncat|rm[[:space:]]+-rf|sudo|mkfs|[[:space:]]dd[[:space:]]|ssh[[:space:]]|scp[[:space:]]|\$\(|`|/etc/(passwd|shadow)|>[[:space:]]*/dev/sd'; then
        add_finding "unit_integration.danger" "recorded_command contains a dangerous/exfil token — refusing to run"; qa_first="__BLOCKED__"
      fi
      if [ "$qa_first" != "__BLOCKED__" ]; then
        if ! command -v probe_proves_something >/dev/null 2>&1; then
          add_finding "unit_integration.guard" "shared probe guard (_probe-proof.sh) unavailable — cannot prove recorded_command is non-trivial; failing closed"
        elif ! probe_proves_something "$qa_cmd"; then
          add_finding "unit_integration.noop" "recorded_command '$qa_cmd' invokes no recognized test runner and references no real artifact — a constant-exit/no-op whose green exit proves NOTHING; refusing to accept the claim"
        else
          qa_out="$( (cd "$ROOT" && eval "$qa_cmd") 2>&1 )"; qa_rc=$?
          qa_probe_executed=1; qa_observed_exit="$qa_rc"
          if [ "$qa_rc" -ne 0 ]; then
            qa_tail5="$(printf '%s\n' "$qa_out" | tail -5 | tr '\n' '|')"
            add_finding "unit_integration.exec" "top-PASS QA claimed unit_integration passed but the recorded_command was RE-RUN and exited $qa_rc — the claim is FALSE. cmd: $qa_cmd · last lines: ${qa_tail5:0:300}"
          fi
        fi
      fi
    fi
  fi
fi

if ! jq -e '.acceptance_criteria_coverage | type == "array"' "$QA" >/dev/null 2>&1; then
  add_finding "acceptance_criteria_coverage" "acceptance_criteria_coverage must be an array"
elif [ "$TOP_VERDICT" = "PASS" ] && { [ -f "$KIT/PRD.md" ] || [ -f "$KIT/prd.proofs.json" ]; }; then
  if ! jq -e '.acceptance_criteria_coverage | length > 0' "$QA" >/dev/null 2>&1; then
    add_finding "acceptance_criteria_coverage.required" "PASS QA with a PRD requires acceptance criteria coverage"
  fi
fi

bad_ac="$(jq -r '
  (.acceptance_criteria_coverage // []) | to_entries[]
  | select(
      ((.value.story // "") | tostring | length == 0)
      or ((.value.ac // "") | tostring | length == 0)
      or ((.value.evidence_ref // "") | tostring | length == 0)
      or (((.value.verdict // "") | ascii_upcase) as $v | ["PASS","WAIVED","FAIL","VETO","BLOCKED"] | index($v) | not)
    )
  | .key
' "$QA" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_ac" ] && add_finding "acceptance_criteria_coverage.shape" "coverage entries need story, ac, verdict, and evidence_ref at indexes: $bad_ac"

if ! jq -e '.blockers | type == "array"' "$QA" >/dev/null 2>&1; then
  add_finding "blockers" "blockers must be an array"
fi
if ! jq -e '.known_gaps | type == "array"' "$QA" >/dev/null 2>&1; then
  add_finding "known_gaps" "known_gaps must be an array"
fi

if [ "$TOP_VERDICT" = "PASS" ]; then
  if ! jq -e '.blockers | type == "array" and length == 0' "$QA" >/dev/null 2>&1; then
    add_finding "blockers.empty" "PASS QA reports require blockers to be empty"
  fi
else
  if jq -e '((.blockers // []) | length == 0)' "$QA" >/dev/null 2>&1 \
    && jq -e '[((.dimensions // {})[]? // empty), (.unit_integration? // empty), (.functional? // empty), (.logic? // empty), (.integration? // empty), (.data_integrity? // empty), (.security? // empty), (.ux_resilience? // empty)] | map(select(((.verdict // "") | ascii_upcase) | test("FAIL|VETO|BLOCKED"))) | length == 0' "$QA" >/dev/null 2>&1; then
    add_finding "nonpass.detail" "non-PASS QA reports need blockers or at least one FAIL/VETO/BLOCKED dimension"
  fi
fi

bad_known_gaps="$(jq -r '
  (.known_gaps // []) | to_entries[]
  | select(
      (.value | type) != "object"
      or ((.value.gap // "") | tostring | length == 0)
      or ((.value.severity // "") | tostring | length == 0)
      or ((.value.owner // "") | tostring | length == 0)
    )
  | .key
' "$QA" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_known_gaps" ] && add_finding "known_gaps.shape" "known_gaps entries require gap, severity, and owner at indexes: $bad_known_gaps"

placeholder_hits="$(jq -r '
  .. | strings
  | select(test("(^|\\b)(TODO|TBD|FIXME|placeholder|lorem ipsum)(\\b|$)|<[^>]+>"; "i"))
' "$QA" 2>/dev/null | head -5 | paste -sd ' | ' -)"
[ -n "$placeholder_hits" ] && add_finding "placeholder" "QA report contains placeholder text: $placeholder_hits"

if [ "$TOP_VERDICT" = "PASS" ]; then
  qa_mtime="$(mtime "$QA")"
  latest_mtime="$(latest_source_mtime)"
  if [ "${latest_mtime:-0}" -gt "${qa_mtime:-0}" ]; then
    add_finding "freshness" "PASS QA report is older than at least one source, spec, or layer artifact"
  fi
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "strict QA contract failed with $failures finding(s)" "$findings"
  echo "qa-contract-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "pass" "QA report is complete, fresh, and blocker-free" "$findings"
echo "qa-contract-gate verdict: PASS - QA report is complete, fresh, and blocker-free -> $REPORT" >&2
exit 0
