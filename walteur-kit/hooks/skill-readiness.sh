#!/usr/bin/env bash
# WALTEUR skill-readiness — fail-closed gate (v9.3). Modeled on tool-readiness.sh.
#
# PURPOSE: assert each declared-required skill left a CONTENT-BOUND receipt before ship, not
#   merely an existing file. A skill invoked as PROTOCOL but leaving no verifiable trace of what
#   it concluded means the law ran in name only. v9.2 closed "no breadcrumb at all"; v9.3 closes
#   the follow-on hole PROVEN this session: an empty file or literal garbage content ("GARBAGE NOT
#   EVEN JSON") satisfied the old "file existence is sufficient" branch for every skill except the
#   one that happens to declare breadcrumb_verdict_key. Existence-crumbs become RECEIPTS.
#
# CONTRACT (mirrors tool-readiness.sh's contract):
#   required-skills.json ABSENT           => verdict:SKIP, exit 0   (bare/legacy projects unaffected).
#   required-skills.json malformed        => verdict:FAIL, exit 2.
#   explicit empty skills[] manifest      => verdict:PASS, exit 0.
#   all required:true skills have receipts=> verdict:PASS, exit 0.
#   ANY required:true skill missing/invalid receipt => verdict:FAIL, exit 2 (FAIL-CLOSED; named to stderr).
#   required:false skills                  => recorded, never block.
#
# RECEIPT SHAPE (schemas/skill-receipt.schema.json) — the default contract for any manifest entry
# that does NOT declare breadcrumb_verdict_key:
#   - breadcrumb file must exist and parse as valid JSON.
#   - .skill        non-empty string (informational; not cross-checked against the manifest key).
#   - .fired_at     ISO-8601 UTC timestamp ("YYYY-MM-DDTHH:MM:SSZ"), and not older than
#                   WALTEUR_SKILL_RECEIPT_MAXAGE hours (default 168 = 7 days).
#   - .phase        non-empty string.
#   - .artifacts    array with >=1 entries; EVERY entry must be a repo-relative path that EXISTS
#                   on disk under $ROOT (this is the content-bound part — the receipt must point
#                   at something real, not merely assert it happened).
#   - .summary      string of >=40 characters (rules out placeholder/empty "done" summaries).
#   - .verdict      optional; if present and manifest declares no verdict_key, no value check is
#                   forced (freeform), but the field must still be present per schema when included.
#
# LEGACY VERDICT-KEY CONTRACT (unchanged, still supported side-by-side with receipts):
#   org-confidentiality-guard  -> walteur-kit/confidentiality-pass.json (verdict:"PASS")
#   Any manifest entry declaring breadcrumb_verdict_key/breadcrumb_pass_value is checked by that
#   declared key/value pair instead of the receipt schema above (existing stamp-shaped artifacts,
#   e.g. confidentiality-pass.json, are not required to carry fired_at/phase/artifacts/summary).
#
# Universal controls:
#   kill switch  walteur-kit/PAUSED present   => exit 2.
#   bypass       WALTEUR_SKILLREADY=off       => verdict:SKIP, exit 0.
#
# Transitional override: WALTEUR_SKILLREADY_HARD=0 keeps missing/invalid receipts warning-only.
# Receipt max-age override: WALTEUR_SKILL_RECEIPT_MAXAGE=<hours> (default 168).
#
# Zero-dep: bash + jq. Report: walteur-kit/skill-readiness-report.json.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "skill-readiness - fail-closed gate (v9.3). Modeled on tool-readiness.sh."
  printf '%s\n' "usage: bash skill-readiness.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/skill-readiness-report.json - fix recipes: walteur-kit/REMEDIATION.md (## skill-readiness)"
  printf '%s\n' "bypass: WALTEUR_SKILLREADY=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/skill-readiness-report.json"
MANIFEST="$KIT/required-skills.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }
HARD_MODE="${WALTEUR_SKILLREADY_HARD:-1}"
MAXAGE_HOURS="${WALTEUR_SKILL_RECEIPT_MAXAGE:-168}"

# epoch(): parse an ISO-8601 UTC timestamp to epoch seconds. GNU date first (git-bash/Linux),
# BSD date fallback (macOS). Empty output on parse failure (caller treats as invalid).
epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo ""
}

# ── embedded selftest ──────────────────────────────────────────────────────────
selftest() {
  local fails=0 total=0 tmp rc
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  ck() { # $1=label $2=want $3=got
    total=$((total+1))
    if [ "$3" -eq "$2" ]; then echo "  ok   — $1"
    else echo "  FAIL — $1 (want=$2, got=$3)"; fails=$((fails+1)); fi
  }

  echo "skill-readiness selftest:"

  # GOOD: manifest lists confidentiality-guard required + PASS stamp present → exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-confidentiality-guard","required":true,"breadcrumb":"walteur-kit/confidentiality-pass.json","discipline":"security"},{"skill":"some-optional-skill","required":false,"breadcrumb":"optional-crumb.json","discipline":"quality"}]}
JSON
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"verdict":"PASS","doc_id":"test","audience":"public","scanned_ts":"%s","lists_fresh":true,"guard_version":"v9.2"}\n' \
    "$ts" > "$tmp/walteur-kit/confidentiality-pass.json"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "good: manifest + PASS stamp -> exit 0" 0 "$rc"
  rm -rf "$tmp"

  # POISONED: manifest lists confidentiality-guard required + breadcrumb ABSENT → exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-confidentiality-guard","required":true,"breadcrumb":"walteur-kit/confidentiality-pass.json","discipline":"security"}]}
JSON
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "poisoned: manifest + NO stamp -> exit 2" 2 "$rc"
  rm -rf "$tmp"

  # DEFAULT HARD: required breadcrumb missing without WALTEUR_SKILLREADY_HARD override -> exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-confidentiality-guard","required":true,"breadcrumb":"walteur-kit/confidentiality-pass.json","discipline":"security"}]}
JSON
  set +e
  (unset WALTEUR_SKILLREADY_HARD; WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on \
    bash "$SELF_PATH" >/dev/null 2>&1); rc=$?
  ck "default hard: missing required breadcrumb -> exit 2" 2 "$rc"
  rm -rf "$tmp"

  # MANIFEST ABSENT: no required-skills.json → SKIP exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "manifest absent -> SKIP exit 0" 0 "$rc"
  rm -rf "$tmp"

  # EMPTY MANIFEST: explicit no required skill floor yet → PASS exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"schema_version":1,"skills":[]}
JSON
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "empty manifest -> explicit PASS exit 0" 0 "$rc"
  rm -rf "$tmp"

  # MALFORMED MANIFEST: parse/shape errors fail closed
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  printf '{ bad json\n' > "$tmp/walteur-kit/required-skills.json"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "malformed manifest -> exit 2" 2 "$rc"
  rm -rf "$tmp"

  # REQUIRED:FALSE: optional skill missing breadcrumb → never blocks (exit 0)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"some-optional-skill","required":false,"breadcrumb":"nonexistent-crumb.json","discipline":"quality"}]}
JSON
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "required:false missing breadcrumb -> never blocks (exit 0)" 0 "$rc"
  rm -rf "$tmp"

  # BYPASS: WALTEUR_SKILLREADY=off → exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-confidentiality-guard","required":true,"breadcrumb":"walteur-kit/confidentiality-pass.json","discipline":"security"}]}
JSON
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=off WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "bypass: WALTEUR_SKILLREADY=off -> exit 0" 0 "$rc"
  rm -rf "$tmp"

  # PAUSED: → exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "PAUSED -> exit 2" 2 "$rc"
  rm -rf "$tmp"

  # ROUTING GOOD: routing requires a skill, manifest has it required + a VALID RECEIPT → exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/skills"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-prd-builder","required":true,"breadcrumb":"walteur-kit/skills/org-prd-builder.json","discipline":"engineering"}]}
JSON
  cat > "$tmp/walteur-kit/skill-routing.json" << 'JSON'
{"routed":[{"skill":"org-prd-builder","required":true,"phase":"Plan"}]}
JSON
  touch "$tmp/walteur-kit/prd.md"
  rts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg ts "$rts" '{skill:"org-prd-builder", fired_at:$ts, phase:"Plan", artifacts:["walteur-kit/prd.md"], summary:"Wrote the PRD covering scope, non-goals, success metrics, and open risks for review.", verdict:"PASS"}' \
    > "$tmp/walteur-kit/skills/org-prd-builder.json"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "routing good: routed+manifest+valid receipt -> exit 0" 0 "$rc"
  rm -rf "$tmp"

  # ROUTING MISMATCH: routing requires a skill the manifest does NOT list → exit 2
  #   (the closure of "empty PASS on a build that needs a skill")
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"schema_version":1,"skills":[]}
JSON
  cat > "$tmp/walteur-kit/skill-routing.json" << 'JSON'
{"routed":[{"skill":"org-prd-builder","required":true,"phase":"Plan"}]}
JSON
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "routing mismatch: routed-required not in manifest -> exit 2" 2 "$rc"
  rm -rf "$tmp"

  # VERDICT KEY: manifest declares breadcrumb_verdict_key, crumb carries the wrong value → exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-confidentiality-guard","required":true,"breadcrumb":"walteur-kit/confidentiality-pass.json","discipline":"security","breadcrumb_verdict_key":"verdict","breadcrumb_pass_value":"PASS"}]}
JSON
  printf '{"verdict":"FAIL"}\n' > "$tmp/walteur-kit/confidentiality-pass.json"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "verdict-key: crumb present but verdict FAIL -> exit 2" 2 "$rc"
  rm -rf "$tmp"

  # ── RECEIPT negative-control set (proves the "empty/garbage breadcrumb passes" hole is closed) ──

  # RECEIPT EMPTY FILE: required skill's breadcrumb exists but is a 0-byte file → exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/skills"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-tdd-discipline","required":true,"breadcrumb":"walteur-kit/skills/org-tdd-discipline.json","discipline":"engineering"}]}
JSON
  : > "$tmp/walteur-kit/skills/org-tdd-discipline.json"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "receipt: empty breadcrumb file -> exit 2 (today's proven hole)" 2 "$rc"
  rm -rf "$tmp"

  # RECEIPT PROSE/GARBAGE: breadcrumb contains literal non-JSON text → exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/skills"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-tdd-discipline","required":true,"breadcrumb":"walteur-kit/skills/org-tdd-discipline.json","discipline":"engineering"}]}
JSON
  printf 'GARBAGE NOT EVEN JSON\n' > "$tmp/walteur-kit/skills/org-tdd-discipline.json"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "receipt: prose/garbage (not JSON) breadcrumb -> exit 2" 2 "$rc"
  rm -rf "$tmp"

  # RECEIPT MISSING ARTIFACT: well-formed receipt but artifacts[] path does not exist → exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/skills"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-tdd-discipline","required":true,"breadcrumb":"walteur-kit/skills/org-tdd-discipline.json","discipline":"engineering"}]}
JSON
  ats="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg ts "$ats" '{skill:"org-tdd-discipline", fired_at:$ts, phase:"Build", artifacts:["walteur-kit/does-not-exist.md"], summary:"Applied TDD discipline: wrote failing tests first, then implementation, then refactor pass."}' \
    > "$tmp/walteur-kit/skills/org-tdd-discipline.json"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "receipt: artifacts[] path does not exist on disk -> exit 2" 2 "$rc"
  rm -rf "$tmp"

  # RECEIPT STALE: well-formed receipt but fired_at is older than WALTEUR_SKILL_RECEIPT_MAXAGE → exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/skills"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-tdd-discipline","required":true,"breadcrumb":"walteur-kit/skills/org-tdd-discipline.json","discipline":"engineering"}]}
JSON
  touch "$tmp/walteur-kit/impl.js"
  stale_ts="$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  jq -n --arg ts "$stale_ts" '{skill:"org-tdd-discipline", fired_at:$ts, phase:"Build", artifacts:["walteur-kit/impl.js"], summary:"Applied TDD discipline: wrote failing tests first, then implementation, then refactor pass."}' \
    > "$tmp/walteur-kit/skills/org-tdd-discipline.json"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "receipt: fired_at older than max-age (default 168h) -> exit 2" 2 "$rc"
  rm -rf "$tmp"

  # RECEIPT SHORT SUMMARY: well-formed receipt but summary < 40 chars → exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/skills"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-tdd-discipline","required":true,"breadcrumb":"walteur-kit/skills/org-tdd-discipline.json","discipline":"engineering"}]}
JSON
  touch "$tmp/walteur-kit/impl.js"
  sts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg ts "$sts" '{skill:"org-tdd-discipline", fired_at:$ts, phase:"Build", artifacts:["walteur-kit/impl.js"], summary:"done"}' \
    > "$tmp/walteur-kit/skills/org-tdd-discipline.json"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "receipt: summary under 40 chars -> exit 2" 2 "$rc"
  rm -rf "$tmp"

  # RECEIPT VALID: fully-shaped, fresh, artifact-backed receipt → exit 0 (positive control)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/skills"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-tdd-discipline","required":true,"breadcrumb":"walteur-kit/skills/org-tdd-discipline.json","discipline":"engineering"}]}
JSON
  touch "$tmp/walteur-kit/impl.js"
  vts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg ts "$vts" '{skill:"org-tdd-discipline", fired_at:$ts, phase:"Build", artifacts:["walteur-kit/impl.js"], summary:"Applied TDD discipline: wrote failing tests first, then implementation, then refactor pass.", verdict:"PASS"}' \
    > "$tmp/walteur-kit/skills/org-tdd-discipline.json"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "receipt: valid fresh artifact-backed receipt -> exit 0" 0 "$rc"
  rm -rf "$tmp"

  # RECEIPT WITHIN MAXAGE OVERRIDE: fired_at 10h old, WALTEUR_SKILL_RECEIPT_MAXAGE=1 -> exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillready-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/skills"
  cat > "$tmp/walteur-kit/required-skills.json" << 'JSON'
{"skills":[{"skill":"org-tdd-discipline","required":true,"breadcrumb":"walteur-kit/skills/org-tdd-discipline.json","discipline":"engineering"}]}
JSON
  touch "$tmp/walteur-kit/impl.js"
  ots="$(date -u -d '10 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  jq -n --arg ts "$ots" '{skill:"org-tdd-discipline", fired_at:$ts, phase:"Build", artifacts:["walteur-kit/impl.js"], summary:"Applied TDD discipline: wrote failing tests first, then implementation, then refactor pass."}' \
    > "$tmp/walteur-kit/skills/org-tdd-discipline.json"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_SKILLREADY=on WALTEUR_SKILLREADY_HARD=1 WALTEUR_SKILL_RECEIPT_MAXAGE=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "receipt: WALTEUR_SKILL_RECEIPT_MAXAGE=1 tightens the window -> exit 2" 2 "$rc"
  rm -rf "$tmp"

  echo "skill-readiness selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest; exit $?
fi

# ── main gate flow ─────────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }

if [ "${WALTEUR_SKILLREADY:-on}" = "off" ]; then
  echo "skill-readiness: SKIP — WALTEUR_SKILLREADY=off (loud skip, not silent-green)." >&2
  printf '{"verdict":"SKIP","ts":"%s","gate":"skill-readiness","reason":"bypassed via WALTEUR_SKILLREADY=off"}\n' "$TS" \
    > "$REPORT" 2>/dev/null || true
  exit 0
fi

# Manifest absent → bare/legacy project; no skill floor imposed (same as tool-readiness)
if [ ! -f "$MANIFEST" ]; then
  echo "skill-readiness: SKIP — no walteur-kit/required-skills.json (bare/legacy project; no skill floor imposed)." >&2
  printf '{"verdict":"SKIP","ts":"%s","gate":"skill-readiness","reason":"required-skills.json absent"}\n' "$TS" \
    > "$REPORT" 2>/dev/null || true
  exit 0
fi

echo "WALTEUR skill-readiness @ $ROOT" >&2

if ! have jq; then
  echo "  FAIL — required tool 'jq' is MISSING (needed to parse required-skills.json)." >&2
  printf '{"verdict":"FAIL","ts":"%s","gate":"skill-readiness","reason":"jq missing (cannot parse manifest)"}\n' "$TS" \
    > "$REPORT" 2>/dev/null || true
  if [ "$HARD_MODE" = "1" ]; then exit 2; fi
  echo "  [WARNING-FIRST] Set WALTEUR_SKILLREADY_HARD=1 to arm exit-2." >&2
  exit 0
fi

if ! jq empty "$MANIFEST" >/dev/null 2>&1; then
  echo "  FAIL — required-skills.json is not valid JSON." >&2
  printf '{"verdict":"FAIL","ts":"%s","gate":"skill-readiness","reason":"required-skills.json is not valid JSON"}\n' "$TS" \
    > "$REPORT" 2>/dev/null || true
  if [ "$HARD_MODE" = "1" ]; then exit 2; fi
  echo "  [WARNING-FIRST] Set WALTEUR_SKILLREADY_HARD=1 to arm exit-2." >&2
  exit 0
fi

if ! jq -e '
  (.skills | type == "array")
  and all(.skills[]?;
    ((.skill // "") | length > 0)
    and (.required | type == "boolean")
    and ((.breadcrumb // "") | length > 0)
    and ((.discipline // "") | length > 0)
  )
' "$MANIFEST" >/dev/null 2>&1; then
  echo "  FAIL — required-skills.json must contain skills[] with skill, required:boolean, breadcrumb, and discipline." >&2
  jq -n --arg ts "$TS" '{
    verdict:"FAIL",
    ts:$ts,
    gate:"skill-readiness",
    reason:"required-skills.json shape is invalid"
  }' > "$REPORT" 2>/dev/null || true
  if [ "$HARD_MODE" = "1" ]; then exit 2; fi
  echo "  [WARNING-FIRST] Set WALTEUR_SKILLREADY_HARD=1 to arm exit-2." >&2
  exit 0
fi

missing_skills='[]'
present_skills='[]'
optional_skills='[]'
missing_count=0
mismatch_count=0
routing_mismatch='[]'

# receipt_check(): validate a breadcrumb file against schemas/skill-receipt.schema.json.
#   Echoes a single reason string on failure (empty string on success). Content-bound: every
#   artifacts[] entry must EXIST on disk under $ROOT, not merely be named.
receipt_check() {
  crumb_path="$1"
  if ! jq empty "$crumb_path" >/dev/null 2>&1; then
    echo "not valid JSON"; return
  fi
  if ! jq -e '(.skill // "") | length > 0' "$crumb_path" >/dev/null 2>&1; then
    echo "missing/empty .skill"; return
  fi
  fired_at="$(jq -r '.fired_at // ""' "$crumb_path" 2>/dev/null || echo "")"
  if ! printf '%s' "$fired_at" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    echo "fired_at missing or not ISO-8601 UTC ('$fired_at')"; return
  fi
  if ! jq -e '(.phase // "") | length > 0' "$crumb_path" >/dev/null 2>&1; then
    echo "missing/empty .phase"; return
  fi
  if ! jq -e '(.artifacts // []) | type == "array" and length >= 1' "$crumb_path" >/dev/null 2>&1; then
    echo "artifacts[] missing or empty (must reference >=1 real file)"; return
  fi
  while IFS= read -r art; do
    [ -n "$art" ] || { echo "artifacts[] contains an empty path"; return; }
    if [ ! -f "$ROOT/$art" ]; then
      echo "artifact does not exist on disk: $art"; return
    fi
  done < <(jq -r '.artifacts[]? // empty' "$crumb_path" 2>/dev/null)
  summary_len="$(jq -r '(.summary // "") | length' "$crumb_path" 2>/dev/null || echo 0)"
  if [ "${summary_len:-0}" -lt 40 ] 2>/dev/null; then
    echo "summary shorter than 40 chars (got ${summary_len:-0})"; return
  fi
  fe="$(epoch "$fired_at")"
  now_e="$(date -u +%s)"
  if [ -z "$fe" ] || [ "$fe" -le 0 ] 2>/dev/null; then
    echo "fired_at could not be parsed to a timestamp"; return
  fi
  max_age_seconds=$((MAXAGE_HOURS * 3600))
  age_seconds=$((now_e - fe))
  if [ "$age_seconds" -gt "$max_age_seconds" ]; then
    echo "fired_at is stale (age ${age_seconds}s > max ${max_age_seconds}s / ${MAXAGE_HOURS}h)"; return
  fi
  if [ "$age_seconds" -lt 0 ]; then
    echo "fired_at is in the future"; return
  fi
  echo ""  # valid receipt
}

# Walk required:true entries
while IFS=$'\t' read -r skill breadcrumb discipline vkey vval; do
  [ -n "$skill" ] || continue
  crumb_path="$ROOT/$breadcrumb"
  crumb_ok=0
  fail_reason=""
  if [ -f "$crumb_path" ]; then
    if [ -n "$vkey" ]; then
      # LEGACY: data-driven verdict check. The manifest entry declares the breadcrumb's pass
      # key/value (generalizes the confidentiality verdict==PASS special case so any
      # stamp-with-verdict skill is checked declaratively, not by hardcoded path). Stamp-shaped
      # artifacts on this contract are NOT required to match the skill-receipt schema.
      if jq empty "$crumb_path" >/dev/null 2>&1; then
        actual="$(jq -r --arg k "$vkey" '.[$k] // ""' "$crumb_path" 2>/dev/null || echo "")"
        if [ "$actual" = "$vval" ]; then crumb_ok=1; else fail_reason="verdict key '$vkey' != '$vval' (got '$actual')"; fi
      else
        fail_reason="not valid JSON"
      fi
    elif case "$breadcrumb" in */confidentiality-pass.json) true ;; *) false ;; esac; then
      # LEGACY: hardcoded confidentiality stamp shape, unchanged.
      if jq empty "$crumb_path" >/dev/null 2>&1; then
        verdict="$(jq -r '.verdict // ""' "$crumb_path" 2>/dev/null || echo "")"
        if [ "$verdict" = "PASS" ]; then crumb_ok=1; else fail_reason="verdict != PASS (got '$verdict')"; fi
      else
        fail_reason="not valid JSON"
      fi
    else
      # DEFAULT (v9.3): content-bound receipt validation against schemas/skill-receipt.schema.json.
      fail_reason="$(receipt_check "$crumb_path")"
      [ -z "$fail_reason" ] && crumb_ok=1
    fi
  else
    fail_reason="breadcrumb file absent"
  fi
  if [ "$crumb_ok" -eq 1 ]; then
    echo "  ok   — required skill '$skill' ($discipline): valid receipt ($breadcrumb)." >&2
    present_skills="$(printf '%s' "$present_skills" | jq --arg s "$skill" '. + [$s]' 2>/dev/null || printf '%s' "$present_skills")"
  else
    echo "  FAIL — required skill '$skill' ($discipline): $fail_reason ($breadcrumb)." >&2
    echo "         Run the skill and write a schemas/skill-receipt.schema.json-shaped receipt before ship." >&2
    missing_skills="$(printf '%s' "$missing_skills" | jq --arg s "$skill" --arg d "$discipline" --arg b "$breadcrumb" --arg r "$fail_reason" \
      '. + [{skill:$s, discipline:$d, breadcrumb:$b, reason:$r}]' 2>/dev/null || printf '%s' "$missing_skills")"
    missing_count=$((missing_count+1))
  fi
done < <(jq -r '.skills[]? | select(.required==true) | [.skill, (.breadcrumb // ""), (.discipline // "unknown"), (.breadcrumb_verdict_key // ""), (.breadcrumb_pass_value // "")] | @tsv' "$MANIFEST" 2>/dev/null)

# Walk required:false entries (record only, never block)
while IFS=$'\t' read -r skill breadcrumb discipline; do
  [ -n "$skill" ] || continue
  crumb_path="$ROOT/$breadcrumb"
  st="absent"; [ -f "$crumb_path" ] && st="present"
  optional_skills="$(printf '%s' "$optional_skills" | jq --arg s "$skill" --arg d "$discipline" --arg st "$st" \
    '. + [{skill:$s, discipline:$d, status:$st}]' 2>/dev/null || printf '%s' "$optional_skills")"
done < <(jq -r '.skills[]? | select(.required!=true) | [.skill, (.breadcrumb // ""), (.discipline // "")] | @tsv' "$MANIFEST" 2>/dev/null)

# ── routing cross-check ────────────────────────────────────────────────────────
# If the Preflight router committed a skill-routing.json, every skill it marked
# required MUST appear in required-skills.json as required:true. This closes the
# "router committed a required skill but the manifest is empty/stale/tampered" gap:
# an empty PASS on a build that NEEDS a skill now FAILS.
ROUTING="$KIT/skill-routing.json"
if [ -f "$ROUTING" ] && jq -e '.routed | type=="array"' "$ROUTING" >/dev/null 2>&1; then
  while IFS= read -r rskill; do
    [ -n "$rskill" ] || continue
    in_manifest="$(jq -r --arg s "$rskill" '[.skills[]? | select(.skill==$s and .required==true)] | length' "$MANIFEST" 2>/dev/null || echo 0)"
    if [ "$in_manifest" = "0" ]; then
      echo "  FAIL — routed-required skill '$rskill' is NOT required in required-skills.json (routing/manifest drift)." >&2
      routing_mismatch="$(printf '%s' "$routing_mismatch" | jq --arg s "$rskill" '. + [{skill:$s, cause:"routed_required_but_not_in_manifest"}]' 2>/dev/null || printf '%s' "$routing_mismatch")"
      mismatch_count=$((mismatch_count+1))
    fi
  done < <(jq -r '.routed[]? | select(.required==true) | .skill' "$ROUTING" 2>/dev/null)
fi

total_fail=$((missing_count + mismatch_count))
if [ "$total_fail" -gt 0 ]; then
  echo "skill-readiness verdict: FAIL — $missing_count missing breadcrumb(s), $mismatch_count routing mismatch(es). FAIL-CLOSED." >&2
  jq -n --arg ts "$TS" --argjson miss "$missing_skills" --argjson pres "$present_skills" --argjson opt "$optional_skills" --argjson rm "$routing_mismatch" \
    '{verdict:"FAIL", ts:$ts, gate:"skill-readiness",
      reason:"\($miss|length) required skill(s) missing breadcrumbs + \($rm|length) routing mismatch(es) (fail-closed)",
      details:{missing:$miss, present:$pres, optional:$opt, routing_mismatch:$rm}}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"FAIL","ts":"%s","gate":"skill-readiness","reason":"%s skill failure(s)"}\n' \
      "$TS" "$total_fail" > "$REPORT"
  if [ "$HARD_MODE" = "1" ]; then exit 2; fi
  echo "  [WARNING-FIRST] Set WALTEUR_SKILLREADY_HARD=1 to arm exit-2." >&2
  exit 0
fi

echo "skill-readiness verdict: PASS — all declared-required skills have breadcrumbs; routing consistent. -> $REPORT" >&2
jq -n --arg ts "$TS" --argjson pres "$present_skills" --argjson opt "$optional_skills" \
  '{verdict:"PASS", ts:$ts, gate:"skill-readiness",
    reason:"all declared-required skills have breadcrumbs; routing consistent",
    details:{present:$pres, optional:$opt, routing_mismatch:[]}}' > "$REPORT" 2>/dev/null \
  || printf '{"verdict":"PASS","ts":"%s","gate":"skill-readiness"}\n' "$TS" > "$REPORT"
exit 0
