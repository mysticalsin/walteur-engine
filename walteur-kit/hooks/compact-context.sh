#!/usr/bin/env bash
# WALTEUR compact-context — Stop-hook resume-pointer writer.
#
# HONEST CONTRACT: this hook writes a CHEAP resume POINTER, not a full context dump.
# Full context summarization is the harness's built-in auto-compaction job (Claude Code's
# /compact command). This hook writes a small, machine-readable snapshot so that after a
# session ends — due to context limit, manual stop, or crash — the next session can resume
# quickly by reading _relay/BATON.md without re-reading the full transcript.
#
# CONTRACT:
#   Stop hook target — must be fail-safe and silent: ALWAYS exit 0, NEVER block, NEVER error.
#   A Stop hook that errors is worse than none.
#
# SELF-SKIP when not a WALTEUR project:
#   If no walteur-kit/ dir exists in the cwd (or $CLAUDE_PROJECT_DIR), exit 0 silently.
#
# WHEN IN A WALTEUR PROJECT:
#   Write/refresh a compact resume-snapshot to _relay/BATON.md. Creates _relay/ if absent.
#   The snapshot (inside a fenced "RESUME SNAPSHOT" block) contains:
#     - timestamp
#     - current walteur-kit/autopilot/STATE.json phase + completed_task_ids (if file exists)
#     - tail of walteur-kit/refine-log.json open-issues (if file exists, truncated)
#     - a one-line "next action" pointer derived from phase
#
# CONTROLS:
#   kill switch: walteur-kit/PAUSED present => still exit 0 (do NOT write — session paused)
#   bypass:      WALTEUR_COMPACT=off => loud skip, exit 0
#
# STDIN: reads the Stop hook JSON payload (carries transcript_path) but does NOT depend on it.
#
# --selftest: hermetic; builds mktemp WALTEUR + non-WALTEUR dirs, asserts behaviour.
#             Exits 0 on all-pass, 1 on any failure.
#
# Zero-dep: bash + standard coreutils. jq optional (grep/sed fallback provided).
# Report written: _relay/BATON.md (append/overwrite the RESUME SNAPSHOT fenced block only)
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "compact-context - Stop-hook resume-pointer writer."
  printf '%s\n' "usage: bash compact-context.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: see hook header - fix recipes: walteur-kit/REMEDIATION.md (## compact-context)"
  printf '%s\n' "bypass: WALTEUR_COMPACT=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ── helpers ─────────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# Determine the project root: CLAUDE_PROJECT_DIR > cwd.
project_root() {
  local r="${CLAUDE_PROJECT_DIR:-$PWD}"
  # Normalise: strip trailing slash.
  printf '%s' "${r%/}"
}

# Quietly read one JSON field from a file — jq when present, grep/sed fallback.
# Usage: json_field <file> <key> [<default>]
json_field() {
  local file="$1" key="$2" default="${3:-}"
  [ -f "$file" ] || { printf '%s' "$default"; return; }
  if have jq; then
    local v; v="$(jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null)"
    printf '%s' "${v:-$default}"
  else
    # grep/sed fallback: "key": "value"  or "key": null
    local v
    v="$(grep -m1 "\"$key\"" "$file" 2>/dev/null \
         | sed 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*//' \
         | sed 's/[",].*$//' \
         | tr -d '[:space:]')"
    printf '%s' "${v:-$default}"
  fi
}

# ── selftest ─────────────────────────────────────────────────────────────────────
selftest() {
  local fails=0 total=0
  local tmp1 tmp2 tmp3

  ck() { # $1=label $2=want(0=pass) $3=got
    total=$((total+1))
    if [ "${3:-1}" -eq "${2:-0}" ]; then
      echo "  ok   — $1"
    else
      echo "  FAIL — $1 (want=$2, got=${3:-1})"
      fails=$((fails+1))
    fi
  }

  echo "compact-context selftest:"

  # ── TEST 1: WALTEUR project => BATON.md written with RESUME SNAPSHOT block ──
  tmp1="$(mktemp -d "${TMPDIR:-/tmp}/compact-selftest-walteur.XXXXXX")"
  mkdir -p "$tmp1/walteur-kit/autopilot" "$tmp1/_relay"
  # Write a minimal STATE.json
  printf '{"phase":"BUILD","autonomy_policy":"full_autopilot","scope_answers":{"completed_task_ids":["T1","T2"]}}\n' \
    > "$tmp1/walteur-kit/autopilot/STATE.json"

  set +e
  CLAUDE_PROJECT_DIR="$tmp1" bash "$SELF" </dev/null >/dev/null 2>&1
  local rc1=$?
  set -e
  ck "WALTEUR project: hook exits 0" 0 "$rc1"
  ck "WALTEUR project: _relay/BATON.md created" 0 "$([ -f "$tmp1/_relay/BATON.md" ] && echo 0 || echo 1)"
  ck "WALTEUR project: BATON.md contains RESUME SNAPSHOT block" \
     0 "$(grep -q 'RESUME SNAPSHOT' "$tmp1/_relay/BATON.md" 2>/dev/null && echo 0 || echo 1)"
  ck "WALTEUR project: BATON.md contains timestamp field" \
     0 "$(grep -q 'timestamp' "$tmp1/_relay/BATON.md" 2>/dev/null && echo 0 || echo 1)"
  ck "WALTEUR project: BATON.md contains phase from STATE.json" \
     0 "$(grep -q 'BUILD' "$tmp1/_relay/BATON.md" 2>/dev/null && echo 0 || echo 1)"
  rm -rf "$tmp1"

  # ── TEST 2: Non-WALTEUR project => nothing written, exit 0 ──
  tmp2="$(mktemp -d "${TMPDIR:-/tmp}/compact-selftest-nonwalteur.XXXXXX")"
  set +e
  CLAUDE_PROJECT_DIR="$tmp2" bash "$SELF" </dev/null >/dev/null 2>&1
  local rc2=$?
  set -e
  ck "non-WALTEUR: exit 0 (self-skip)" 0 "$rc2"
  ck "non-WALTEUR: _relay/BATON.md NOT written" \
     0 "$([ ! -f "$tmp2/_relay/BATON.md" ] && echo 0 || echo 1)"
  rm -rf "$tmp2"

  # ── TEST 3: WALTEUR_COMPACT=off => loud skip, exit 0, nothing written ──
  tmp3="$(mktemp -d "${TMPDIR:-/tmp}/compact-selftest-off.XXXXXX")"
  mkdir -p "$tmp3/walteur-kit"
  set +e
  CLAUDE_PROJECT_DIR="$tmp3" WALTEUR_COMPACT=off bash "$SELF" </dev/null >/dev/null 2>&1
  local rc3=$?
  set -e
  ck "WALTEUR_COMPACT=off: exit 0" 0 "$rc3"
  ck "WALTEUR_COMPACT=off: nothing written" \
     0 "$([ ! -f "$tmp3/_relay/BATON.md" ] && echo 0 || echo 1)"
  rm -rf "$tmp3"

  echo "compact-context selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

# ── dispatch selftest early ───────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  selftest; exit $?
fi

# ── main: fail-safe wrapper — ALWAYS exit 0 regardless ───────────────────────────
# Everything below is wrapped so no failure can cause the hook to return non-zero.
_compact_main() {
  local ROOT; ROOT="$(project_root)"
  local KIT="$ROOT/walteur-kit"
  local RELAY="$ROOT/_relay"
  local BATON="$RELAY/BATON.md"

  # ── WALTEUR_COMPACT=off bypass (loud skip) ────────────────────────────────────
  if [ "${WALTEUR_COMPACT:-on}" = "off" ]; then
    echo "compact-context: SKIP — WALTEUR_COMPACT=off (loud skip, nothing written)." >&2
    return 0
  fi

  # ── Self-skip: not a WALTEUR project ─────────────────────────────────────────
  if [ ! -d "$KIT" ]; then
    return 0   # silent: project has no walteur-kit/, hook is harmless globally
  fi

  # ── Kill switch: PAUSED means do not write ───────────────────────────────────
  if [ -f "$KIT/PAUSED" ]; then
    echo "compact-context: SKIP — walteur-kit/PAUSED present (session paused, no BATON write)." >&2
    return 0
  fi

  # ── Drain stdin (Stop hook payload: JSON with transcript_path etc.) ──────────
  # Read it but do not depend on it. Ignore errors.
  local _payload; _payload="$(cat 2>/dev/null || true)"

  # ── Gather snapshot data ─────────────────────────────────────────────────────
  local TS; TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # STATE.json: phase + completed_task_ids
  local STATE_FILE="$KIT/autopilot/STATE.json"
  local PHASE="" COMPLETED_IDS=""
  if [ -f "$STATE_FILE" ]; then
    PHASE="$(json_field "$STATE_FILE" "phase" "UNKNOWN")"
    if have jq; then
      # Try scope_answers.completed_task_ids first, then top-level
      COMPLETED_IDS="$(jq -r '
        ([
          (.scope_answers.completed_task_ids // []),
          (.completed_task_ids // [])
        ] | add // [] | if length > 0 then join(", ") else "none" end)
      ' "$STATE_FILE" 2>/dev/null || echo "")"
    else
      # grep fallback: extract array or scalar
      COMPLETED_IDS="$(grep -o '"completed_task_ids"[^]]*]' "$STATE_FILE" 2>/dev/null \
        | sed 's/"completed_task_ids"[[:space:]]*:[[:space:]]*//' \
        | tr -d '[]"' | tr ',' ' ' | xargs 2>/dev/null || echo "")"
    fi
    COMPLETED_IDS="${COMPLETED_IDS:-none}"
  fi

  # refine-log.json: last open-issues entry (tail)
  local REFINE_FILE="$KIT/refine-log.json"
  local REFINE_TAIL=""
  if [ -f "$REFINE_FILE" ]; then
    if have jq; then
      REFINE_TAIL="$(jq -r '
        if type == "array" and length > 0 then
          last | (
            if type == "object" then
              "iter \(.iter // "?") | verdict: \(.verdict // "?") | open: \((.open_issues // []) | join("; "))"
            else tostring end
          )
        else "[]"
        end
      ' "$REFINE_FILE" 2>/dev/null || echo "")"
    else
      REFINE_TAIL="$(tail -c 300 "$REFINE_FILE" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
    fi
    REFINE_TAIL="${REFINE_TAIL:-(empty)}"
  fi

  # ── Derive next-action pointer from phase ────────────────────────────────────
  local NEXT_ACTION
  case "$PHASE" in
    IDLE)      NEXT_ACTION="Run /goal to start a new build." ;;
    THINK)     NEXT_ACTION="Awaiting THINK phase completion (discovery / clarification)." ;;
    PLAN)      NEXT_ACTION="Awaiting PLAN approval (place walteur-kit/APPROVED + re-run /goal)." ;;
    BUILD)     NEXT_ACTION="Resume BUILD: re-run /goal (reads STATE.json + BATON.md)." ;;
    REVIEW)    NEXT_ACTION="Awaiting REVIEW phase (panel evaluation in progress)." ;;
    REFINE)    NEXT_ACTION="Awaiting REFINE loop completion (re-run /goal to continue)." ;;
    VALIDATE)  NEXT_ACTION="Awaiting VALIDATE phase gate completion." ;;
    REVIEW2)   NEXT_ACTION="Awaiting REVIEW2 panel." ;;
    AUDIT)     NEXT_ACTION="Awaiting AUDIT certification (place walteur-kit/APPROVED + re-run /goal)." ;;
    DONE)      NEXT_ACTION="Build DONE. Start a new goal with /goal." ;;
    STOPPED)   NEXT_ACTION="Build STOPPED. Check walteur-kit/ for gate verdicts." ;;
    BLOCKED)   NEXT_ACTION="Build BLOCKED. Resolve last_gate_red in STATE.json then re-run /goal." ;;
    UNKNOWN|"") NEXT_ACTION="Phase unknown — inspect walteur-kit/autopilot/STATE.json directly." ;;
    *)         NEXT_ACTION="Re-run /goal (phase=$PHASE)." ;;
  esac

  # ── Write BATON.md — create _relay/ if absent ────────────────────────────────
  mkdir -p "$RELAY"

  # Preserve any content ABOVE our fenced block (e.g. earlier hand-written notes).
  # Strategy: strip any previous RESUME SNAPSHOT block, then append the fresh one.
  local EXISTING=""
  if [ -f "$BATON" ]; then
    # Remove everything from ``` RESUME SNAPSHOT to the closing ``` (inclusive, greedy-last).
    EXISTING="$(awk '
      /^```.*RESUME SNAPSHOT/ { in_block=1; next }
      in_block && /^```/ { in_block=0; next }
      !in_block { print }
    ' "$BATON" 2>/dev/null | sed '/^[[:space:]]*$/d' | head -20)"
    # Cap preserved preamble at 20 lines to keep the file small.
  fi

  {
    if [ -n "$EXISTING" ]; then
      printf '%s\n\n' "$EXISTING"
    fi
    printf '```RESUME SNAPSHOT\n'
    printf 'timestamp:         %s\n' "$TS"
    printf 'phase:             %s\n' "${PHASE:-UNKNOWN}"
    printf 'completed_tasks:   %s\n' "${COMPLETED_IDS:-none}"
    if [ -n "$REFINE_TAIL" ]; then
      printf 'refine_last:       %s\n' "$REFINE_TAIL"
    fi
    printf 'next_action:       %s\n' "$NEXT_ACTION"
    printf '```\n'
  } > "$BATON"

  echo "compact-context: wrote resume pointer -> $BATON (phase=$PHASE)" >&2
  return 0
}

# ── fail-safe wrapper: ANY error inside _compact_main must NOT propagate ─────────
{
  _compact_main "$@" 2>&1 | grep -v '^$' >&2 || true
} 2>/dev/null || true

exit 0
