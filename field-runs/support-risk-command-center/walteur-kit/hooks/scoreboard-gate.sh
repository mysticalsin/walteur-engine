#!/usr/bin/env bash
# WALTEUR scoreboard-gate - typed eight-dimension score contract gate.
#
# Contract:
#   - No scoreboard and not in ship/reflect phase => NOT_APPLICABLE, exit 0.
#   - Empty runtime scoreboard stub before ship   => NOT_APPLICABLE, exit 0.
#   - Ship/reflect without a valid scoreboard     => FAIL, exit 2.
#   - Composite below target, dimension below floor, security below 8, missing dimension, or unlocked target => FAIL, exit 2.
#   - Complete scoreboard                         => PASS, exit 0.
#
# Report:
#   walteur-kit/scoreboard-report.json
#
# Bypass:
#   WALTEUR_SCOREBOARD=off
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
SCOREBOARD="$KIT/scoreboard.json"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/scoreboard-report.json"
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
      --arg scoreboard "${SCOREBOARD#"$ROOT"/}" --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"scoreboard-gate", mode:$mode, scoreboard_file:$scoreboard, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"scoreboard-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0\n'
}

detect_scoreboard_required() {
  SCOREBOARD_REQUIRED=0
  SCOREBOARD_REQUIRED_REASON=""

  if [ "${WALTEUR_SCOREBOARD_REQUIRED:-}" = "1" ]; then
    SCOREBOARD_REQUIRED=1
    SCOREBOARD_REQUIRED_REASON="WALTEUR_SCOREBOARD_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      ship|reflect)
        SCOREBOARD_REQUIRED=1
        SCOREBOARD_REQUIRED_REASON="STATE.phase=$phase"
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
      "$REPORT"|"$SCOREBOARD") return 0 ;;
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
    "$KIT/qa-report.json" \
    "$KIT/DEFINITION-OF-DONE.md"
  do
    update_latest "$f"
  done

  printf '%s\n' "$latest"
}

check_dimension() {
  dim="$1"
  if ! jq -e --arg d "$dim" '.dimensions[$d] | type == "object"' "$SCOREBOARD" >/dev/null 2>&1; then
    add_finding "dimensions.$dim" "dimension '$dim' is required"
    return 0
  fi
  if ! jq -e --arg d "$dim" '(.dimensions[$d].score | type == "number" and . >= 0 and . <= 10)' "$SCOREBOARD" >/dev/null 2>&1; then
    add_finding "dimensions.$dim.score" "dimension '$dim' score must be a number from 0 to 10"
  fi
  if ! jq -e --arg d "$dim" '(.dimensions[$d].floor | type == "number" and . >= 0 and . <= 10)' "$SCOREBOARD" >/dev/null 2>&1; then
    add_finding "dimensions.$dim.floor" "dimension '$dim' floor must be a number from 0 to 10"
  elif ! jq -e --arg d "$dim" '.dimensions[$d].score >= .dimensions[$d].floor' "$SCOREBOARD" >/dev/null 2>&1; then
    add_finding "dimensions.$dim.floor_met" "dimension '$dim' score is below its floor"
  fi
  if ! jq -e --arg d "$dim" '(.dimensions[$d].rationale // "" | type == "string" and length > 0)' "$SCOREBOARD" >/dev/null 2>&1; then
    add_finding "dimensions.$dim.rationale" "dimension '$dim' requires rationale"
  fi
  if ! jq -e --arg d "$dim" '(.dimensions[$d].evidence_ref // "" | type == "string" and length > 0)' "$SCOREBOARD" >/dev/null 2>&1; then
    add_finding "dimensions.$dim.evidence_ref" "dimension '$dim' requires evidence_ref"
  else
    evidence="$(jq -r --arg d "$dim" '.dimensions[$d].evidence_ref' "$SCOREBOARD")"
    evidence_file="${evidence%%#*}"
    case "$evidence_file" in
      /*) evidence_path="$evidence_file" ;;
      *) evidence_path="$ROOT/$evidence_file" ;;
    esac
    [ -f "$evidence_path" ] || add_finding "dimensions.$dim.evidence_exists" "dimension '$dim' evidence_ref points to missing file: $evidence"
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
    echo "scoreboard-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    root="$1"
    phase="$2"
    mkdir -p "$root/walteur-kit/autopilot"
    jq -n --arg phase "$phase" '{phase:$phase}' > "$root/walteur-kit/autopilot/STATE.json"
  }

  write_source() {
    root="$1"
    mkdir -p "$root/src" "$root/walteur-kit"
    printf 'export const App = () => "ok";\n' > "$root/src/App.tsx"
    printf 'qa evidence\n' > "$root/walteur-kit/qa-report.json"
  }

  write_good_scoreboard() {
    root="$1"
    mode="${2:-good}"
    mkdir -p "$root/walteur-kit"
    jq -n --arg mode "$mode" '
      def dim($score; $floor): { score: $score, floor: $floor, rationale: "Evidence reviewed.", evidence_ref: "walteur-kit/qa-report.json" };
      {
        schema_version: 1,
        target: 8.5,
        targets_locked: true,
        locked_at: "2026-06-22T00:00:00Z",
        locked_by: "QA",
        composite: 9.0,
        refine_max: 6,
        dimensions: {
          design: dim(9;8),
          infrastructure: dim(9;8),
          security: dim(9;8),
          ux_ui: dim(9;8),
          performance: dim(9;8),
          features: dim(9;8),
          data_architecture: dim(9;8),
          devex: dim(9;8)
        },
        ts: "2026-06-22T00:00:00Z"
      }
      | if $mode == "below-target" then .composite = 8.0 else . end
      | if $mode == "security-low" then .dimensions.security.score = 7.9 else . end
      | if $mode == "below-floor" then .dimensions.performance.score = 7.0 else . end
      | if $mode == "missing-dim" then del(.dimensions.devex) else . end
      | if $mode == "unlocked" then .targets_locked = false else . end
    ' > "$root/walteur-kit/scoreboard.json"
  }

  echo "scoreboard-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/scoreboard-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "no scoreboard and not shipping -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/scoreboard-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ship phase missing scoreboard -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/scoreboard-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{"target":8.5,"composite":9.0}\n' > "$tmp/walteur-kit/scoreboard.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "scoreboard stub -> FAIL" 2 "$?"
  rm -rf "$tmp"

  for mode in below-target security-low below-floor missing-dim unlocked; do
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/scoreboard-selftest.XXXXXX")" || return 1
    write_source "$tmp"
    write_state "$tmp" "ship"
    write_good_scoreboard "$tmp" "$mode"
    WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
    ck "$mode scoreboard -> FAIL" 2 "$?"
    rm -rf "$tmp"
  done

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/scoreboard-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "ship"
  write_good_scoreboard "$tmp" "good"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "complete scoreboard -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/scoreboard-selftest.XXXXXX")" || return 1
  write_source "$tmp"
  write_state "$tmp" "ship"
  write_good_scoreboard "$tmp" "good"
  touch -t 202001010000 "$tmp/walteur-kit/scoreboard.json" 2>/dev/null || true
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "stale scoreboard after source edit -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "scoreboard-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && {
  write_report "FAIL" "paused" "walteur-kit/PAUSED present" '[{"check":"paused","message":"WALTEUR is paused"}]'
  echo "scoreboard-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
}

if [ "${WALTEUR_SCOREBOARD:-on}" = "off" ]; then
  write_report "SKIP" "bypass" "WALTEUR_SCOREBOARD=off" "[]"
  echo "scoreboard-gate verdict: SKIP - bypassed via WALTEUR_SCOREBOARD=off -> $REPORT" >&2
  exit 0
fi

if ! have jq; then
  write_report "SKIP" "tool-missing" "jq not installed" "[]"
  echo "scoreboard-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  exit 0
fi

detect_scoreboard_required

if [ ! -f "$SCOREBOARD" ]; then
  if [ "$SCOREBOARD_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "missing" "scoreboard required ($SCOREBOARD_REQUIRED_REASON) but walteur-kit/scoreboard.json is absent" \
      '[{"check":"scoreboard.present","message":"ship/reflect requires walteur-kit/scoreboard.json shaped by walteur-kit/schemas/scoreboard.schema.json"}]'
    echo "scoreboard-gate verdict: FAIL - scoreboard missing while required ($SCOREBOARD_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "not-applicable" "no scoreboard and current phase does not require one" "[]"
  echo "scoreboard-gate verdict: NOT_APPLICABLE - no scoreboard before ship -> $REPORT" >&2
  exit 0
fi

if [ ! -s "$SCOREBOARD" ]; then
  if [ "$SCOREBOARD_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "empty" "scoreboard required ($SCOREBOARD_REQUIRED_REASON) but walteur-kit/scoreboard.json is empty" \
      '[{"check":"scoreboard.nonempty","message":"zero-byte scoreboard stubs cannot satisfy ship/reflect"}]'
    echo "scoreboard-gate verdict: FAIL - empty scoreboard while required ($SCOREBOARD_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "runtime-stub" "zero-byte runtime scoreboard stub before ship" "[]"
  echo "scoreboard-gate verdict: NOT_APPLICABLE - zero-byte runtime scoreboard stub before ship -> $REPORT" >&2
  exit 0
fi

if ! jq empty "$SCOREBOARD" >/dev/null 2>&1; then
  write_report "FAIL" "invalid-json" "walteur-kit/scoreboard.json is invalid JSON" \
    '[{"check":"scoreboard.json","message":"walteur-kit/scoreboard.json must be valid JSON"}]'
  echo "scoreboard-gate verdict: FAIL - scoreboard JSON invalid -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

if ! jq -e '.schema_version == 1' "$SCOREBOARD" >/dev/null 2>&1; then
  add_finding "schema_version" "schema_version must be 1"
fi
if ! jq -e '.target | type == "number" and . >= 0 and . <= 10' "$SCOREBOARD" >/dev/null 2>&1; then
  add_finding "target" "target must be a number from 0 to 10"
fi
if ! jq -e '.targets_locked == true' "$SCOREBOARD" >/dev/null 2>&1; then
  add_finding "targets_locked" "targets_locked must be true; never lower target/floors to exit"
fi
if ! jq -e '.locked_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$SCOREBOARD" >/dev/null 2>&1; then
  add_finding "locked_at" "locked_at must be UTC ISO format"
fi
if ! jq -e '.locked_by | type == "string" and length > 0' "$SCOREBOARD" >/dev/null 2>&1; then
  add_finding "locked_by" "locked_by is required"
fi
if ! jq -e '.composite | type == "number" and . >= 0 and . <= 10' "$SCOREBOARD" >/dev/null 2>&1; then
  add_finding "composite" "composite must be a number from 0 to 10"
elif ! jq -e '.composite >= .target' "$SCOREBOARD" >/dev/null 2>&1; then
  add_finding "composite.target" "composite score is below target"
fi
if jq -e 'has("refine_max")' "$SCOREBOARD" >/dev/null 2>&1 \
  && ! jq -e '.refine_max | type == "number" and . >= 1 and (. == floor)' "$SCOREBOARD" >/dev/null 2>&1; then
  add_finding "refine_max" "refine_max must be a positive integer"
fi
if ! jq -e '.dimensions | type == "object"' "$SCOREBOARD" >/dev/null 2>&1; then
  add_finding "dimensions.shape" "dimensions must be an object with the eight score dimensions"
else
  for dim in design infrastructure security ux_ui performance features data_architecture devex; do
    check_dimension "$dim"
  done
fi
if ! jq -e '.dimensions.security.score >= 8' "$SCOREBOARD" >/dev/null 2>&1; then
  add_finding "security.floor" "security dimension must be >= 8"
fi
if ! jq -e '.ts | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$SCOREBOARD" >/dev/null 2>&1; then
  add_finding "ts" "ts must be UTC ISO format YYYY-MM-DDTHH:MM:SSZ"
fi

placeholder_hits="$(jq -r '
  .. | strings
  | select(test("(^|\\b)(TODO|TBD|FIXME|placeholder|lorem ipsum)(\\b|$)|<[^>]+>"; "i"))
' "$SCOREBOARD" 2>/dev/null | head -5 | paste -sd ' | ' -)"
[ -n "$placeholder_hits" ] && add_finding "placeholder" "scoreboard contains placeholder text: $placeholder_hits"

scoreboard_mtime="$(mtime "$SCOREBOARD")"
latest_mtime="$(latest_source_mtime)"
if [ "${latest_mtime:-0}" -gt "${scoreboard_mtime:-0}" ]; then
  add_finding "freshness" "scoreboard is older than at least one source, spec, QA, or layer artifact"
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "strict scoreboard contract failed with $failures finding(s)" "$findings"
  echo "scoreboard-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "pass" "scoreboard meets target, floors, security floor, evidence, and freshness" "$findings"
echo "scoreboard-gate verdict: PASS - scoreboard meets target, floors, security floor, evidence, and freshness -> $REPORT" >&2
exit 0
