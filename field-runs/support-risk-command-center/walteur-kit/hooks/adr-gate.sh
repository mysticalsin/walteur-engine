#!/usr/bin/env bash
# WALTEUR adr-gate - unresolved fork and decision-record gate.
#
# Contract:
#   - No debate/ADR signal and not in ship/reflect phase => NOT_APPLICABLE, exit 0.
#   - Ship/reflect without debate/OPEN.json             => FAIL, exit 2.
#   - Any unresolved fork in debate/OPEN.json            => FAIL, exit 2.
#   - ADR files without typed INDEX.json                 => FAIL, exit 2.
#   - Thin ADRs with no rejected alternatives or dissent => FAIL, exit 2.
#   - Empty OPEN.json plus valid ADR records             => PASS, exit 0.
#
# Report:
#   walteur-kit/adr-report.json
#
# Bypass:
#   WALTEUR_ADR=off
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
OPEN="$KIT/debate/OPEN.json"
ADR_DIR="$KIT/adr"
INDEX="$ADR_DIR/INDEX.json"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/adr-report.json"
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
      --arg open_file "${OPEN#"$ROOT"/}" --arg adr_dir "${ADR_DIR#"$ROOT"/}" \
      --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"adr-gate", mode:$mode, open_file:$open_file, adr_dir:$adr_dir, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"adr-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

detect_adr_required() {
  ADR_REQUIRED=0
  ADR_REQUIRED_REASON=""

  if [ "${WALTEUR_ADR_REQUIRED:-}" = "1" ]; then
    ADR_REQUIRED=1
    ADR_REQUIRED_REASON="WALTEUR_ADR_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      ship|reflect)
        ADR_REQUIRED=1
        ADR_REQUIRED_REASON="STATE.phase=$phase"
        return 0 ;;
    esac
  fi
}

adr_file_count() {
  [ -d "$ADR_DIR" ] || { printf '0\n'; return 0; }
  find "$ADR_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]'
}

open_count() {
  jq -r '
    def unresolved_count:
      if type == "array" then length
      elif type == "object" then
        if (.open_forks? | type) == "array" then (.open_forks | length)
        elif (.forks? | type) == "array" then
          (.forks | map(select((((.status // "open") | ascii_downcase) != "closed") and ((.resolved // false) != true))) | length)
        elif ((.fork_id? // "") | tostring | length) > 0 then 1
        else 0 end
      else 0 end;
    unresolved_count
  ' "$OPEN"
}

section_has_body() {
  file="$1"
  heading_re="$2"
  awk -v h="$heading_re" '
    BEGIN { inside=0; body=0 }
    $0 ~ h { inside=1; next }
    inside && /^##[[:space:]]+/ { exit }
    inside {
      line=$0
      gsub(/^[[:space:]>#*-]+/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      if (length(line) > 0) body=1
    }
    END { exit body ? 0 : 1 }
  ' "$file"
}

validate_adr_markdown() {
  file="$1"
  short="${file#"$ROOT"/}"
  base="$(basename "$file")"

  case "$base" in
    [0-9][0-9][0-9][0-9]-*.md) ;;
    *) add_finding "adr.filename.$base" "$short must use NNNN-slug.md naming" ;;
  esac

  [ -s "$file" ] || {
    add_finding "adr.nonempty.$base" "$short must not be empty"
    return 0
  }

  if ! grep -Eq '^#[[:space:]]+.+' "$file"; then
    add_finding "adr.title.$base" "$short needs a top-level title"
  fi
  if ! grep -Eiq '^##[[:space:]]+Context' "$file"; then
    add_finding "adr.context.$base" "$short needs a Context section"
  fi
  if ! grep -Eiq '^##[[:space:]]+Decision' "$file"; then
    add_finding "adr.decision.$base" "$short needs a Decision section"
  fi
  if ! grep -Eiq '^##[[:space:]]+Rationale' "$file"; then
    add_finding "adr.rationale.$base" "$short needs a Rationale section"
  fi
  if ! grep -Eiq '^##[[:space:]]+Rejected Alternatives?' "$file"; then
    add_finding "adr.rejected_alternatives.$base" "$short needs Rejected Alternatives"
  fi
  if ! grep -Eiq '^##[[:space:]]+Dissent' "$file"; then
    add_finding "adr.dissent.$base" "$short needs Dissent or Dissent Overruled"
  fi

  section_has_body "$file" '^##[[:space:]]+Decision' || add_finding "adr.decision_body.$base" "$short Decision section must be non-empty"
  section_has_body "$file" '^##[[:space:]]+Rationale' || add_finding "adr.rationale_body.$base" "$short Rationale section must be non-empty"
  section_has_body "$file" '^##[[:space:]]+Rejected Alternatives?' || add_finding "adr.rejected_body.$base" "$short must record at least one rejected alternative"
  section_has_body "$file" '^##[[:space:]]+Dissent' || add_finding "adr.dissent_body.$base" "$short must record dissent or explicitly say none"

  if grep -Eiq '(^|[[:space:][:punct:]])(TODO|TBD|FIXME|placeholder|lorem ipsum)([[:space:][:punct:]]|$)|<[^>]+>' "$file"; then
    add_finding "adr.placeholder.$base" "$short contains placeholder text"
  fi
}

validate_index() {
  if [ ! -f "$INDEX" ]; then
    add_finding "index.present" "ADR markdown exists, but walteur-kit/adr/INDEX.json is missing"
    return 0
  fi

  if [ ! -s "$INDEX" ]; then
    add_finding "index.nonempty" "walteur-kit/adr/INDEX.json must not be empty"
    return 0
  fi

  if ! jq empty "$INDEX" >/dev/null 2>&1; then
    add_finding "index.json" "walteur-kit/adr/INDEX.json must be valid JSON"
    return 0
  fi

  if ! jq -e '.schema_version == 1 and (.records | type == "array" and length > 0)' "$INDEX" >/dev/null 2>&1; then
    add_finding "index.shape" "INDEX.json must match walteur-kit/schemas/adr.schema.json with schema_version:1 and records[]"
    return 0
  fi

  bad_records="$(jq '
    [.records[]? | select(
      ((.id // "") | type != "string" or length == 0) or
      ((.path // "") | type != "string" or length == 0) or
      ((.decision // "") | type != "string" or length == 0) or
      ((.owner // "") | type != "string" or length == 0) or
      ((.date // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not) or
      ((.context // "") | type != "string" or length == 0) or
      ((.dissent // "") | type != "string" or length == 0) or
      ((.rejected_alternatives // []) | type != "array" or length == 0) or
      (.status as $s | ["accepted","superseded","rejected"] | index($s) | not)
    )] | length
  ' "$INDEX")"
  if [ "${bad_records:-0}" -gt 0 ]; then
    add_finding "index.records" "INDEX.json has $bad_records malformed record(s)"
  fi

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      /*|*..*)
        add_finding "index.path.$ref" "ADR index path must be relative and cannot contain traversal"
        continue ;;
      walteur-kit/adr/*) candidate="$ROOT/$ref" ;;
      *) candidate="$ADR_DIR/$ref" ;;
    esac
    [ -f "$candidate" ] || add_finding "index.path_exists.$ref" "ADR index path points to a missing file"
  done < <(jq -r '.records[]?.path // empty' "$INDEX")

  while IFS= read -r file; do
    base="$(basename "$file")"
    if ! jq -e --arg base "$base" '.records[]? | select((.path == $base) or (.path | endswith("/" + $base)))' "$INDEX" >/dev/null 2>&1; then
      add_finding "index.covers.$base" "INDEX.json must include $base"
    fi
  done < <(find "$ADR_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
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
    echo "adr-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    root="$1"
    phase="$2"
    mkdir -p "$root/walteur-kit/autopilot"
    jq -n --arg phase "$phase" '{phase:$phase}' > "$root/walteur-kit/autopilot/STATE.json"
  }

  write_open() {
    root="$1"
    body="$2"
    mkdir -p "$root/walteur-kit/debate"
    printf '%s\n' "$body" > "$root/walteur-kit/debate/OPEN.json"
  }

  write_good_adr() {
    root="$1"
    mode="${2:-good}"
    mkdir -p "$root/walteur-kit/adr" "$root/walteur-kit/debate"
    printf '[]\n' > "$root/walteur-kit/debate/OPEN.json"
    cat > "$root/walteur-kit/adr/0001-postgres.md" <<'MD'
# ADR 0001 - Postgres for the workflow store

## Context
The product needs multi-user transactional updates and audit-friendly records.

## Decision
Use Postgres as the workflow store for the first production release.

## Rationale
Postgres gives transactional safety, relational reporting, and a common operating model for the team.

## Rejected Alternatives
- SQLite: weaker concurrent write behavior for the target usage pattern.
- MongoDB: less direct fit for the reporting shape and transactional joins.

## Dissent Overruled
The strongest dissent favored SQLite for setup speed, but concurrency and reporting needs decide this fork.
MD
    if [ "$mode" = "missing-rejected" ]; then
      awk 'BEGIN{skip=0} /^## Rejected Alternatives/{skip=1; next} /^## Dissent/{skip=0} !skip{print}' "$root/walteur-kit/adr/0001-postgres.md" > "$root/adr.tmp"
      mv "$root/adr.tmp" "$root/walteur-kit/adr/0001-postgres.md"
    fi
    if [ "$mode" = "placeholder" ]; then
      printf '\nTODO: fill this later.\n' >> "$root/walteur-kit/adr/0001-postgres.md"
    fi
    jq -n '{
      schema_version: 1,
      records: [
        {
          id: "0001-postgres",
          fork_id: "store-choice",
          path: "0001-postgres.md",
          status: "accepted",
          decision: "Use Postgres as the workflow store.",
          owner: "Architecture",
          date: "2026-06-22",
          context: "Workflow store selection.",
          rejected_alternatives: ["SQLite", "MongoDB"],
          dissent: "SQLite setup speed was outweighed by concurrent write and reporting needs."
        }
      ]
    }' > "$root/walteur-kit/adr/INDEX.json"
    if [ "$mode" = "bad-index" ]; then
      jq '.records[0].path = "9999-missing.md"' "$root/walteur-kit/adr/INDEX.json" > "$root/index.tmp"
      mv "$root/index.tmp" "$root/walteur-kit/adr/INDEX.json"
    fi
    if [ "$mode" = "thin-index" ]; then
      jq 'del(.records[0].rejected_alternatives)' "$root/walteur-kit/adr/INDEX.json" > "$root/index.tmp"
      mv "$root/index.tmp" "$root/walteur-kit/adr/INDEX.json"
    fi
  }

  echo "adr-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/adr-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "no debate signal before ship -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/adr-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ship phase missing OPEN.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/adr-selftest.XXXXXX")" || return 1
  write_open "$tmp" '{ bad json'
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "invalid OPEN.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/adr-selftest.XXXXXX")" || return 1
  write_open "$tmp" '[{"fork_id":"db-choice","question":"Which store?","options":["A","B"]}]'
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "unresolved OPEN fork -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/adr-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  write_open "$tmp" '[]'
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "empty OPEN at ship with no forks -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/adr-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  write_good_adr "$tmp" "good"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "good ADR plus empty OPEN -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/adr-selftest.XXXXXX")" || return 1
  write_good_adr "$tmp" "missing-rejected"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ADR missing rejected alternatives -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/adr-selftest.XXXXXX")" || return 1
  write_good_adr "$tmp" "placeholder"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ADR placeholder -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/adr-selftest.XXXXXX")" || return 1
  write_good_adr "$tmp" "bad-index"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "INDEX references missing ADR -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/adr-selftest.XXXXXX")" || return 1
  write_good_adr "$tmp" "thin-index"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "INDEX missing required decision metadata -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "adr-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && {
  write_report "FAIL" "paused" "walteur-kit/PAUSED present" '[{"check":"paused","message":"WALTEUR is paused"}]'
  echo "adr-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
}

if [ "${WALTEUR_ADR:-on}" = "off" ]; then
  write_report "SKIP" "bypass" "WALTEUR_ADR=off" "[]"
  echo "adr-gate verdict: SKIP - bypassed via WALTEUR_ADR=off -> $REPORT" >&2
  exit 0
fi

if ! have jq; then
  write_report "SKIP" "tool-missing" "jq not installed" "[]"
  echo "adr-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  exit 0
fi

detect_adr_required
findings='[]'
failures=0
adr_count="$(adr_file_count)"

if [ ! -f "$OPEN" ]; then
  if [ "$ADR_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "missing" "ADR control file required ($ADR_REQUIRED_REASON) but walteur-kit/debate/OPEN.json is absent" \
      '[{"check":"debate.open.present","message":"ship/reflect requires walteur-kit/debate/OPEN.json, normally [] after all forks are resolved"}]'
    echo "adr-gate verdict: FAIL - debate/OPEN.json missing while required ($ADR_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  if [ "$adr_count" -eq 0 ]; then
    write_report "NOT_APPLICABLE" "not-applicable" "no debate/ADR signal before ship" "[]"
    echo "adr-gate verdict: NOT_APPLICABLE - no debate/ADR signal before ship -> $REPORT" >&2
    exit 0
  fi
else
  if [ ! -s "$OPEN" ]; then
    if [ "$ADR_REQUIRED" -eq 1 ]; then
      write_report "FAIL" "empty" "ADR control file required ($ADR_REQUIRED_REASON) but walteur-kit/debate/OPEN.json is empty" \
        '[{"check":"debate.open.nonempty","message":"use [] for no unresolved forks, not a zero-byte file"}]'
      echo "adr-gate verdict: FAIL - empty debate/OPEN.json while required ($ADR_REQUIRED_REASON) -> $REPORT" >&2
      exit 2
    fi
    if [ "$adr_count" -eq 0 ]; then
      write_report "NOT_APPLICABLE" "runtime-stub" "zero-byte debate/OPEN.json before ship" "[]"
      echo "adr-gate verdict: NOT_APPLICABLE - zero-byte debate/OPEN.json before ship -> $REPORT" >&2
      exit 0
    fi
    add_finding "debate.open.nonempty" "walteur-kit/debate/OPEN.json must be [] or a valid fork list"
  elif ! jq empty "$OPEN" >/dev/null 2>&1; then
    write_report "FAIL" "invalid-json" "walteur-kit/debate/OPEN.json is invalid JSON" \
      '[{"check":"debate.open.json","message":"walteur-kit/debate/OPEN.json must be valid JSON"}]'
    echo "adr-gate verdict: FAIL - debate/OPEN.json invalid -> $REPORT" >&2
    exit 2
  else
    unresolved="$(open_count)"
    if [ "${unresolved:-0}" -gt 0 ]; then
      add_finding "debate.open.unresolved" "walteur-kit/debate/OPEN.json contains $unresolved unresolved fork(s)"
    fi
  fi
fi

if [ "$adr_count" -gt 0 ]; then
  validate_index
  while IFS= read -r adr_file; do
    validate_adr_markdown "$adr_file"
  done < <(find "$ADR_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "strict ADR contract failed with $failures finding(s)" "$findings"
  echo "adr-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "pass" "no unresolved forks; ADR records are indexed and shaped where present" "$findings"
echo "adr-gate verdict: PASS - no unresolved forks; ADR records are indexed and shaped where present -> $REPORT" >&2
exit 0
