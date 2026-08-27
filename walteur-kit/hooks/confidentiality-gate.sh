#!/usr/bin/env bash
# WALTEUR confidentiality-gate — HARD egress gate (v9.2). Companion to compliance-gate.sh.
#
# PURPOSE: detect outbound leakage of named-client / NDA / M&A identifiers in EXTERNAL artifacts.
#   compliance-gate.sh = AT-REST PII (stored/logged PII, data-inventory, log-redaction) — NOT duplicated.
#   confidentiality-gate.sh = EGRESS leakage (named-client/NDA/M&A codenames in external-facing output).
#
# ARMS ONLY when project produces an external artifact:
#   product-signal (prd-gate heuristic: UI files OR walteur-kit/benchmark.md) AND external-output signal
#   (release notes / case study / press / public docs). Both needed. No external signal → NOT_APPLICABLE
#   exit 0 (never stalls a legit internal/backend/CLI build — detect-or-SKIP).
#
# WHEN ARMED: requires fresh walteur-kit/confidentiality-pass.json with verdict:"PASS".
#   Absent or FAIL → WARNING (WARNING-FIRST mode) or exit 2 (HARD mode).
#
# BYPASS: signed layers.json "confidentiality":"deferred:<reason>"|"pass" → exit 0.
#   WALTEUR_CONFIDENTIALITY=off → loud SKIP exit 0. PAUSED → exit 2.
#
# WARNING-FIRST LAW: gate ships exit-0+WARN by default. To arm as HARD exit-2:
#   set WALTEUR_CONFIDENTIALITY_HARD=1 (or add run_gate dispatch to ship-gate.sh after twin proven).
#   NOTE: the HARD run_gate dispatch line is NOT yet in ship-gate.sh — this is intentional per plan §4.
#
# Zero-dep: bash + jq + find. Report: walteur-kit/confidentiality-report.json.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "confidentiality-gate - HARD egress gate (v9.2). Companion to compliance-gate.sh."
  printf '%s\n' "usage: bash confidentiality-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/confidentiality-report.json - fix recipes: walteur-kit/REMEDIATION.md (## confidentiality-gate)"
  printf '%s\n' "bypass: WALTEUR_CONFIDENTIALITY=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/confidentiality-report.json"
STAMP="$KIT/confidentiality-pass.json"
LAYERS="$KIT/layers.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() { # $1=verdict $2=mode $3=reason $4=details-json
  local d="${4-}"; [ -n "$d" ] || d='{}'
  if have jq; then
    jq -n --arg v "$1" --arg ts "$TS" --arg mode "$2" --arg reason "$3" --argjson d "$d" \
      '{verdict:$v, ts:$ts, gate:"confidentiality-gate", mode:$mode, reason:$reason, details:$d}' \
      > "$REPORT" 2>/dev/null || true
  else
    printf '{"verdict":"%s","ts":"%s","gate":"confidentiality-gate","mode":"%s","reason":"%s"}\n' \
      "$1" "$TS" "$2" "$3" > "$REPORT" 2>/dev/null || true
  fi
}

# ── embedded selftest (dispatch at top so --selftest works even without git root) ──
selftest() {
  local fails=0 total=0 tmp rc
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  run_one() { # $1=label $2=want-rc $3=setup-fn
    total=$((total+1))
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/conf-gate-selftest.XXXXXX")" || {
      echo "  FAIL — $1 (mktemp)"; fails=$((fails+1)); return; }
    mkdir -p "$tmp/walteur-kit" "$tmp/src"
    "$3" "$tmp"
    set +e
    WALTEUR_ROOT="$tmp" WALTEUR_CONFIDENTIALITY=on WALTEUR_CONFIDENTIALITY_HARD=1 \
      bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq "$2" ]; then echo "  ok   — $1 (rc=$rc)"
    else echo "  FAIL — $1 (rc=$rc, want $2)"; fails=$((fails+1)); fi
    rm -rf "$tmp"
  }

  # GOOD TWIN: external artifact + fresh PASS stamp → exit 0
  good_setup() {
    printf '<div>app</div>\n' > "$1/src/App.tsx"
    printf '# Release Notes\n## v1.0\n- Initial release\n' > "$1/RELEASE-NOTES.md"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"verdict":"PASS","doc_id":"test","audience":"public","scanned_ts":"%s","lists_fresh":true,"guard_version":"v9.2"}\n' \
      "$ts" > "$1/walteur-kit/confidentiality-pass.json"
  }
  # POISONED TWIN A: external artifact + NO stamp → exit 2
  no_stamp_setup() {
    printf '<div>app</div>\n' > "$1/src/App.tsx"
    printf '# Release Notes\n## v1.0\n- Initial release\n' > "$1/RELEASE-NOTES.md"
  }
  # POISONED TWIN B: external artifact + FAIL stamp → exit 2
  fail_stamp_setup() {
    printf '<div>app</div>\n' > "$1/src/App.tsx"
    printf '# Release Notes\n## v1.0\n- Initial release\n' > "$1/RELEASE-NOTES.md"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"verdict":"FAIL","doc_id":"test","audience":"public","scanned_ts":"%s","lists_fresh":true,"guard_version":"v9.2"}\n' \
      "$ts" > "$1/walteur-kit/confidentiality-pass.json"
  }
  # NON-EXTERNAL: backend-only CLI → NOT_APPLICABLE exit 0
  non_external_setup() {
    printf 'package main\nfunc main() {}\n' > "$1/src/main.go"
  }
  # DEFERRAL: external + FAIL stamp + signed layers.json deferral → exit 0
  deferral_setup() {
    printf '<div>app</div>\n' > "$1/src/App.tsx"
    printf '# Release Notes\n' > "$1/RELEASE-NOTES.md"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"verdict":"FAIL","doc_id":"test","audience":"public","scanned_ts":"%s","lists_fresh":true,"guard_version":"v9.2"}\n' \
      "$ts" > "$1/walteur-kit/confidentiality-pass.json"
    printf '{"confidentiality":"deferred:internal-only-use-approved"}\n' > "$1/walteur-kit/layers.json"
  }

  echo "confidentiality-gate selftest:"
  run_one "good: external + PASS stamp -> exit 0"          0 good_setup
  run_one "poisoned: external + NO stamp -> exit 2"        2 no_stamp_setup
  run_one "poisoned: external + FAIL stamp -> exit 2"      2 fail_stamp_setup
  run_one "non-external (backend/CLI) -> NOT_APPLICABLE 0" 0 non_external_setup
  run_one "deferral: layers.json deferred -> exit 0"       0 deferral_setup

  # BYPASS test
  total=$((total+1))
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/conf-gate-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  no_stamp_setup "$tmp"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_CONFIDENTIALITY=off WALTEUR_CONFIDENTIALITY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && echo "  ok   — bypass: WALTEUR_CONFIDENTIALITY=off -> exit 0" \
    || { echo "  FAIL — bypass (rc=$rc, want 0)"; fails=$((fails+1)); }
  rm -rf "$tmp"

  # PAUSED test
  total=$((total+1))
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/conf-gate-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_CONFIDENTIALITY=on WALTEUR_CONFIDENTIALITY_HARD=1 \
    bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && echo "  ok   — PAUSED kill switch -> exit 2" \
    || { echo "  FAIL — PAUSED (rc=$rc, want 2)"; fails=$((fails+1)); }
  rm -rf "$tmp"

  echo "confidentiality-gate selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest; exit $?
fi

# ── main gate flow ─────────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }

if [ "${WALTEUR_CONFIDENTIALITY:-on}" = "off" ]; then
  echo "confidentiality-gate: SKIP — WALTEUR_CONFIDENTIALITY=off (loud skip, not silent-green)." >&2
  write_report "SKIP" "bypass" "bypassed via WALTEUR_CONFIDENTIALITY=off" '{}'
  exit 0
fi

echo "WALTEUR confidentiality-gate @ $ROOT" >&2
HARD_MODE="${WALTEUR_CONFIDENTIALITY_HARD:-0}"

# ── signed deferral lookup ─────────────────────────────────────────────────────
confidentiality_deferred=0
deferral_value=""
if [ -f "$LAYERS" ] && have jq; then
  deferral_value="$(jq -r '.confidentiality // ""' "$LAYERS" 2>/dev/null || echo "")"
  case "$deferral_value" in pass|deferred:*)
    confidentiality_deferred=1 ;;
  esac
fi
if [ "$confidentiality_deferred" -eq 1 ]; then
  echo "  ok   — signed deferral: layers.json[\"confidentiality\"]=\"$deferral_value\"." >&2
  write_report "PASS" "deferred" "signed deferral: layers.json confidentiality=$deferral_value" \
    "$(have jq && jq -n --arg d "$deferral_value" '{deferral:$d}' || echo '{}')"
  exit 0
fi

# ── applicability: product signal (prd-gate heuristic) ────────────────────────
PRUNE=( \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' \
           -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/storybook-static/*' \
           -o -path '*/walteur-kit/*' \) -prune -o )
UI_COUNT=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  base="$(basename "$f")"
  case "$base" in *.test.*|*.spec.*|*.stories.*) continue ;; esac
  UI_COUNT=$((UI_COUNT+1))
done < <(find "$ROOT" "${PRUNE[@]}" -type f \
  \( -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' -o -name '*.html' \) -print 2>/dev/null)
HAS_BENCHMARK=0; [ -f "$KIT/benchmark.md" ] && HAS_BENCHMARK=1
HAS_PRODUCT_SIGNAL=$(( UI_COUNT > 0 || HAS_BENCHMARK == 1 ))

# ── external-output signal ────────────────────────────────────────────────────
HAS_EXTERNAL_OUTPUT=0; EXT_FILE=""
for cand in "$ROOT/RELEASE-NOTES.md" "$ROOT/release-notes.md" "$ROOT/CHANGELOG.md" \
            "$ROOT/CASE-STUDY.md" "$ROOT/case-study.md" \
            "$ROOT/PRESS-RELEASE.md" "$ROOT/press-release.md" \
            "$KIT/release-notes.md" "$KIT/case-study.md"; do
  [ -f "$cand" ] && { HAS_EXTERNAL_OUTPUT=1; EXT_FILE="$cand"; break; }
done
if [ "$HAS_EXTERNAL_OUTPUT" -eq 0 ]; then
  for d in public docs marketing press; do
    [ -d "$ROOT/$d" ] && { HAS_EXTERNAL_OUTPUT=1; EXT_FILE="$ROOT/$d/ (dir)"; break; }
  done
fi

if [ "$HAS_PRODUCT_SIGNAL" -eq 0 ] || [ "$HAS_EXTERNAL_OUTPUT" -eq 0 ]; then
  [ "$HAS_PRODUCT_SIGNAL" -eq 0 ] && reason="no product signal (no UI files, no benchmark.md)" \
    || reason="no external-output artifact (no release-notes/case-study/press/public-docs)"
  echo "  NOT_APPLICABLE — $reason." >&2
  write_report "NOT_APPLICABLE" "not-applicable" "$reason" \
    "$(have jq && jq -n --argjson ui "$UI_COUNT" --argjson bm "$HAS_BENCHMARK" --argjson ext "$HAS_EXTERNAL_OUTPUT" \
      '{ui_files:$ui, has_benchmark:$bm, has_external_output:$ext}' || echo '{}')"
  exit 0
fi

echo "  ARMED — product(ui=$UI_COUNT,benchmark=$HAS_BENCHMARK) + external($EXT_FILE)." >&2

# ── fresh confidentiality-pass.json with PASS verdict ─────────────────────────
STAMP_VERDICT=""
STAMP_TS_VAL=""
if [ -f "$STAMP" ] && have jq; then
  STAMP_VERDICT="$(jq -r '.verdict // ""' "$STAMP" 2>/dev/null || echo "")"
  STAMP_TS_VAL="$(jq -r '.scanned_ts // ""' "$STAMP" 2>/dev/null || echo "")"
fi

STAMP_STALE=0
if [ -n "$STAMP_TS_VAL" ]; then
  STAMP_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$STAMP_TS_VAL" +%s 2>/dev/null || \
                date -d "$STAMP_TS_VAL" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  AGE_HOURS=$(( (NOW_EPOCH - STAMP_EPOCH) / 3600 ))
  [ "$AGE_HOURS" -gt 48 ] && STAMP_STALE=1
fi

do_fail() { # $1=reason $2=details-json
  echo "  FAIL — $1" >&2
  write_report "FAIL" "armed" "$1" "${2-}"
  if [ "$HARD_MODE" = "1" ]; then exit 2; fi
  echo "  [WARNING-FIRST] Set WALTEUR_CONFIDENTIALITY_HARD=1 or add run_gate dispatch to arm exit-2." >&2
  exit 0
}

if [ ! -f "$STAMP" ] || [ -z "$STAMP_VERDICT" ]; then
  do_fail "confidentiality-pass.json absent — run org-confidentiality-guard before shipping" \
    "$(have jq && jq -n --arg ext "$EXT_FILE" '{stamp:"absent",external_artifact:$ext}' || echo '{}')"
fi
if [ "$STAMP_VERDICT" != "PASS" ]; then
  do_fail "confidentiality-pass.json verdict=$STAMP_VERDICT (PASS required — re-run guard + fix findings)" \
    "$(have jq && jq -n --arg v "$STAMP_VERDICT" --arg ext "$EXT_FILE" \
      '{stamp_verdict:$v,external_artifact:$ext}' || echo '{}')"
fi
if [ "$STAMP_STALE" -eq 1 ]; then
  do_fail "confidentiality-pass.json stale (age=${AGE_HOURS:-?}h > 48h — re-run guard on current version)" \
    "$(have jq && jq -n --arg ts "$STAMP_TS_VAL" --argjson age "${AGE_HOURS:-0}" --arg ext "$EXT_FILE" \
      '{stamp_ts:$ts,age_hours:$age,external_artifact:$ext}' || echo '{}')"
fi

echo "  PASS — fresh PASS stamp (scanned_ts=$STAMP_TS_VAL)." >&2
write_report "PASS" "armed" "fresh confidentiality PASS stamp for external artifact" \
  "$(have jq && jq -n --arg ts "$STAMP_TS_VAL" --arg ext "$EXT_FILE" \
    '{stamp_ts:$ts,external_artifact:$ext}' || echo '{}')"
echo "confidentiality-gate verdict: PASS -> $REPORT" >&2
exit 0
