#!/usr/bin/env bash
# WALTEUR skill-readiness — fail-closed gate (v9.2). Modeled on tool-readiness.sh.
#
# PURPOSE: assert each declared-required skill left a machine-readable breadcrumb before ship.
#   A skill invoked as PROTOCOL but leaving NO trace means the law ran in name only.
#   This gate closes the "skill-invocation is PROTOCOL, nothing HARD" gap.
#
# CONTRACT (mirrors tool-readiness.sh's contract):
#   required-skills.json ABSENT          => verdict:SKIP, exit 0   (bare/legacy projects unaffected).
#   required-skills.json malformed       => verdict:FAIL, exit 2.
#   explicit empty skills[] manifest     => verdict:PASS, exit 0.
#   all required:true skills have crumbs => verdict:PASS, exit 0.
#   ANY required:true skill missing crumb => verdict:FAIL, exit 2   (FAIL-CLOSED by default; skill named to stderr).
#   required:false skills                 => recorded, never block.
#
# BREADCRUMBS (paths where each skill's evidence file lives):
#   org-confidentiality-guard  -> walteur-kit/confidentiality-pass.json (verdict:"PASS")
#   graphify-first-recall        -> graphify-out/wiki/index.md (file exists = evidence of recall)
#   (future skills: add to required-skills.json with breadcrumb path)
#
# Universal controls:
#   kill switch  walteur-kit/PAUSED present   => exit 2.
#   bypass       WALTEUR_SKILLREADY=off       => verdict:SKIP, exit 0.
#
# Transitional override: WALTEUR_SKILLREADY_HARD=0 keeps missing breadcrumbs warning-only.
#
# Zero-dep: bash + jq. Report: walteur-kit/skill-readiness-report.json.
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

# Walk required:true entries
while IFS=$'\t' read -r skill breadcrumb discipline; do
  [ -n "$skill" ] || continue
  crumb_path="$ROOT/$breadcrumb"
  # Special: confidentiality-pass.json requires verdict:"PASS"
  crumb_ok=0
  if [ -f "$crumb_path" ]; then
    case "$breadcrumb" in
      */confidentiality-pass.json)
        verdict="$(jq -r '.verdict // ""' "$crumb_path" 2>/dev/null || echo "")"
        [ "$verdict" = "PASS" ] && crumb_ok=1
        ;;
      *)
        crumb_ok=1  # other breadcrumbs: file existence is sufficient
        ;;
    esac
  fi
  if [ "$crumb_ok" -eq 1 ]; then
    echo "  ok   — required skill '$skill' ($discipline): breadcrumb found ($breadcrumb)." >&2
    present_skills="$(printf '%s' "$present_skills" | jq --arg s "$skill" '. + [$s]' 2>/dev/null || printf '%s' "$present_skills")"
  else
    echo "  FAIL — required skill '$skill' ($discipline): breadcrumb MISSING ($breadcrumb)." >&2
    echo "         Run the skill and ensure it writes its breadcrumb before ship." >&2
    missing_skills="$(printf '%s' "$missing_skills" | jq --arg s "$skill" --arg d "$discipline" --arg b "$breadcrumb" \
      '. + [{skill:$s, discipline:$d, breadcrumb:$b}]' 2>/dev/null || printf '%s' "$missing_skills")"
    missing_count=$((missing_count+1))
  fi
done < <(jq -r '.skills[]? | select(.required==true) | [.skill, (.breadcrumb // ""), (.discipline // "unknown")] | @tsv' "$MANIFEST" 2>/dev/null)

# Walk required:false entries (record only, never block)
while IFS=$'\t' read -r skill breadcrumb discipline; do
  [ -n "$skill" ] || continue
  crumb_path="$ROOT/$breadcrumb"
  st="absent"; [ -f "$crumb_path" ] && st="present"
  optional_skills="$(printf '%s' "$optional_skills" | jq --arg s "$skill" --arg d "$discipline" --arg st "$st" \
    '. + [{skill:$s, discipline:$d, status:$st}]' 2>/dev/null || printf '%s' "$optional_skills")"
done < <(jq -r '.skills[]? | select(.required!=true) | [.skill, (.breadcrumb // ""), (.discipline // "")] | @tsv' "$MANIFEST" 2>/dev/null)

if [ "$missing_count" -gt 0 ]; then
  echo "skill-readiness verdict: FAIL — $missing_count required skill(s) missing breadcrumbs. FAIL-CLOSED." >&2
  jq -n --arg ts "$TS" --argjson miss "$missing_skills" --argjson pres "$present_skills" --argjson opt "$optional_skills" \
    '{verdict:"FAIL", ts:$ts, gate:"skill-readiness",
      reason:"\($miss|length) declared-required skill(s) missing breadcrumbs (fail-closed)",
      details:{missing:$miss, present:$pres, optional:$opt}}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"FAIL","ts":"%s","gate":"skill-readiness","reason":"%s required skill(s) missing"}\n' \
      "$TS" "$missing_count" > "$REPORT"
  if [ "$HARD_MODE" = "1" ]; then exit 2; fi
  echo "  [WARNING-FIRST] Set WALTEUR_SKILLREADY_HARD=1 to arm exit-2." >&2
  exit 0
fi

echo "skill-readiness verdict: PASS — all declared-required skills have breadcrumbs. -> $REPORT" >&2
jq -n --arg ts "$TS" --argjson pres "$present_skills" --argjson opt "$optional_skills" \
  '{verdict:"PASS", ts:$ts, gate:"skill-readiness",
    reason:"all declared-required skills have breadcrumbs",
    details:{present:$pres, optional:$opt}}' > "$REPORT" 2>/dev/null \
  || printf '{"verdict":"PASS","ts":"%s","gate":"skill-readiness"}\n' "$TS" > "$REPORT"
exit 0
