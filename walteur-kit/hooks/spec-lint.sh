#!/usr/bin/env bash
# WALTEUR spec-lint — HARD gate on a PLAN.md spec. exit 2 on any failing rule, 0 on clean.
# Usage: bash walteur-kit/hooks/spec-lint.sh <PLAN.md>
#
# Rules (R1–R4 core — all must pass; R5–R6 optional — applicability-gated, skipped silently when N/A):
#   R1  An "## Out of scope" / "Out of scope" section with >=1 named non-goal (a non-empty,
#       non-heading line beneath it — a bullet or prose line that actually names something).
#   R2  ZERO banned-vagueness hits, case-insensitive:
#         \bTBD\b | \bTODO\b | \betc\.? | as appropriate |
#         should be (fast|scalable|secure|robust|intuitive) |
#         gracefully | handle edge cases | and more
#   R3  A "## Success metric" line (or any line containing "success metric") whose section carries
#       a number+unit (e.g. 200ms, 99.9%, 3s, 5 req) OR the words "baseline" AND "target".
#   R4  At least one comparator (<, >, ==, >=, <=) OR a "Given/When/Then" somewhere in the
#       acceptance / tasks area (the whole file is scanned — the acceptance/tasks live in it).
#   R5  (OPTIONAL) Constitution alignment: IF constitution.md exists at repo root or walteur-kit/
#       AND it mandates test-first/TDD, THEN PLAN.md must carry a "Test matrix" section. No
#       constitution.md => skipped silently (R1..R4-only behavior unchanged). Low false positive.
#   R6  (OPTIONAL) PRD reference: IF walteur-kit/PRD.md (or PRD.md) exists, PLAN.md must REFERENCE it
#       (cite the PRD — WALTEUR §4.1 "Why → PRD reference, never restate"; spec drift = rewrite). No
#       PRD => skipped silently (existing behavior unchanged). Low false positive (front-funnel v9.0).
#   R7  (TWINNED WARNING-FIRST EARS CHECK): IF the plan has an acceptance-criteria area but NONE of
#       its ACs use EARS grammar (WHEN <trigger>, THE <system> SHALL <response>), emit a warning.
#       Pure-regex path always runs; Vale optional (detect-or-SKIP if vale absent or vale-rules/ absent).
#       Default: WARN only (add_advisory — never enters FAILED, never blocks, never changes exit code).
#       HARD mode: set WALTEUR_EARS=hard to promote R7 to a blocking rule (adds to FAILED → exit 2).
#       Free-form ACs remain fully valid in default mode.
#
# Zero-dep: bash + grep + awk + sed + jq only. HARD: real exit 2 on an R1..R6 violation (R7 advisory
#           by default; promote with WALTEUR_EARS=hard).
# HONESTY: this tool (grep/awk) is always present, so there is no SKIP path for a missing tool —
#          the only honest SKIP is "no PLAN file given / file absent" (cannot lint nothing).
# Report: walteur-kit/spec-lint-report.json  {verdict, ts, failed_rules, details, advisories}.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "spec-lint - HARD gate on a PLAN.md spec. exit 2 on any failing rule, 0 on clean."
  printf '%s\n' "usage: bash spec-lint.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/spec-lint-report.json - fix recipes: walteur-kit/REMEDIATION.md (## spec-lint)"
  exit 0 ;;
esac

set -uo pipefail

# ── --selftest: twin R7 regression tests (pure bash/grep; no Vale required) ────
if [ "${1:-}" = "--selftest" ]; then
  _PASS=0; _FAIL=0
  # Use $TMPDIR if set (sandbox-friendly), fall back to /tmp.
  _BASE="${TMPDIR:-/tmp}"
  _TMPDIR="$_BASE/walteur-selftest-$$"
  mkdir -p "$_TMPDIR"
  trap 'rm -rf "$_TMPDIR"' EXIT

  # ── Selftest 1 (PASS): EARS-shaped AC — R7 advisory must NOT fire ──────────
  cat > "$_TMPDIR/plan_ears.md" <<'EARS_EOF'
## Acceptance criteria

- AC1: WHEN the user submits the login form, THE system SHALL validate credentials and redirect to dashboard.
- AC2: WHILE the session is active, THE system SHALL refresh the token every 15 min.

## Out of scope
- Password reset flow

## Success metric
- Latency < 200ms at p95
EARS_EOF

  R7_WARN=""
  if grep -qiE '#{0,6}[[:space:]]*acceptance|acceptance[[:space:]]+criteria|\bAC[0-9]+\b|^[[:space:]]*-[[:space:]]*AC[0-9: ]' "$_TMPDIR/plan_ears.md" 2>/dev/null; then
    if ! grep -qiE '\b(WHEN|WHILE|SHALL)\b' "$_TMPDIR/plan_ears.md" 2>/dev/null; then
      R7_WARN="yes"
    fi
  fi
  if [ -z "$R7_WARN" ]; then
    echo "  SELFTEST R7/PASS: OK — EARS-shaped AC suppresses advisory (correct)" >&2
    _PASS=$((_PASS+1))
  else
    echo "  SELFTEST R7/PASS: FAIL — advisory fired on an EARS-shaped AC (bug)" >&2
    _FAIL=$((_FAIL+1))
  fi

  # ── Selftest 2 (WARN): vague AC — R7 advisory MUST fire ────────────────────
  cat > "$_TMPDIR/plan_vague.md" <<'VAGUE_EOF'
## Acceptance criteria

- AC1: The login should work correctly.
- AC2: Errors should be handled gracefully.

## Out of scope
- Password reset flow

## Success metric
- Response time baseline 500ms, target 200ms
VAGUE_EOF

  R7_WARN2=""
  if grep -qiE '#{0,6}[[:space:]]*acceptance|acceptance[[:space:]]+criteria|\bAC[0-9]+\b|^[[:space:]]*-[[:space:]]*AC[0-9: ]' "$_TMPDIR/plan_vague.md" 2>/dev/null; then
    if ! grep -qiE '\b(WHEN|WHILE|SHALL)\b' "$_TMPDIR/plan_vague.md" 2>/dev/null; then
      R7_WARN2="yes"
    fi
  fi
  if [ -n "$R7_WARN2" ]; then
    echo "  SELFTEST R7/WARN: OK — vague AC correctly triggers R7 advisory (correct)" >&2
    _PASS=$((_PASS+1))
  else
    echo "  SELFTEST R7/WARN: FAIL — advisory did not fire on a vague AC (bug)" >&2
    _FAIL=$((_FAIL+1))
  fi

  echo "WALTEUR spec-lint selftest: $_PASS passed, $_FAIL failed." >&2
  exit 0
fi

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/spec-lint-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_report() { # $1=verdict  $2=reason  $3=failed-rules-json-array  $4=findings-json-array  [$5=advisories-json-array]
  jq -n \
    --arg v "$1" --arg ts "$TS" --arg reason "$2" --arg plan "${PLAN:-}" \
    --argjson rules "${3:-[]}" --argjson findings "${4:-[]}" --argjson advisories "${5:-[]}" \
    '{verdict:$v, ts:$ts, gate:"spec-lint", plan:$plan, reason:$reason,
      failed_rules:$rules, details:$findings, advisories:$advisories}' > "$REPORT"
}

# ── tool / applicability guard ───────────────────────────────────────────────
for t in grep awk sed jq; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR spec-lint SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
    write_report "SKIP" "$t not installed" '[]' '[]'
    exit 0
  fi
done

PLAN="${1:-}"
if [ -z "$PLAN" ]; then
  echo "WALTEUR spec-lint SKIP — no PLAN.md argument given. Usage: spec-lint.sh <PLAN.md>" >&2
  write_report "SKIP" "no plan file argument" '[]' '[]'
  exit 0
fi
if [ ! -f "$PLAN" ]; then
  echo "WALTEUR spec-lint SKIP — '$PLAN' not found (nothing to lint)." >&2
  write_report "SKIP" "plan file not found: $PLAN" '[]' '[]'
  exit 0
fi

FAILED=()        # rule IDs (HARD — R1..R6). R7 joins this set ONLY when WALTEUR_EARS=hard.
declare -a FINDINGS_JSON=()
add_finding() { # $1=rule  $2=line(int or 0)  $3=message
  FINDINGS_JSON+=("$(jq -n --arg r "$1" --argjson ln "$2" --arg m "$3" \
    '{rule:$r, line:$ln, message:$m}')")
}
declare -a ADVISORY_JSON=()
add_advisory() { # $1=rule  $2=line(int or 0)  $3=message  (advisory: recorded + printed, never blocks)
  ADVISORY_JSON+=("$(jq -n --arg r "$1" --argjson ln "$2" --arg m "$3" \
    '{rule:$r, line:$ln, message:$m}')")
}

# ── R1: "Out of scope" section with >=1 named non-goal ───────────────────────
# Find the heading line, then require a non-empty content line before the next heading.
R1_LINE="$(grep -niE '^[[:space:]]*#{0,6}[[:space:]]*out of scope' "$PLAN" | head -1 | cut -d: -f1)"
if [ -z "$R1_LINE" ]; then
  FAILED+=("R1"); add_finding "R1" 0 "No 'Out of scope' section heading found."
else
  # Scan lines after the heading until the next markdown heading; a non-goal = a non-blank,
  # non-heading line (bullet or prose) that contains at least one word character.
  NONGOAL="$(awk -v start="$R1_LINE" '
    NR>start {
      if ($0 ~ /^[[:space:]]*#{1,6}[[:space:]]/) exit          # next heading -> section ends
      line=$0
      gsub(/^[[:space:]]*[-*+][[:space:]]+/, "", line)         # strip bullet marker
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)            # trim
      if (line ~ /[A-Za-z0-9]/) { print NR; exit }
    }' "$PLAN")"
  if [ -z "$NONGOAL" ]; then
    FAILED+=("R1")
    add_finding "R1" "$R1_LINE" "'Out of scope' section present but lists no named non-goal."
  fi
fi

# ── R2: ZERO banned-vagueness hits (case-insensitive) ────────────────────────
R2_RE='\bTBD\b|\bTODO\b|\betc\.?|as appropriate|should be (fast|scalable|secure|robust|intuitive)|gracefully|handle edge cases|and more'
R2_HITS="$(grep -niE "$R2_RE" "$PLAN" || true)"
if [ -n "$R2_HITS" ]; then
  FAILED+=("R2")
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    hln="${hit%%:*}"
    htxt="${hit#*:}"; htxt="${htxt#*:}"   # strip "line:" and the second field artefact safely below
    # grep -n output is "LINE:TEXT"; recover text robustly:
    htxt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://')"
    add_finding "R2" "$hln" "Banned-vagueness phrase: $(printf '%s' "$htxt" | sed -E 's/^[[:space:]]+//')"
  done <<< "$R2_HITS"
fi

# ── R3: Success metric with number+unit OR (baseline AND target) ─────────────
R3_LINE="$(grep -niE 'success metric' "$PLAN" | head -1 | cut -d: -f1)"
if [ -z "$R3_LINE" ]; then
  FAILED+=("R3"); add_finding "R3" 0 "No 'Success metric' line/section found."
else
  # Gather the metric section: from the heading line to the next heading (or 25 lines if it is a
  # bare line rather than a heading). Then test for number+unit OR baseline&target.
  SECTION="$(awk -v start="$R3_LINE" '
    NR>=start {
      if (NR>start && $0 ~ /^[[:space:]]*#{1,6}[[:space:]]/) exit
      print
      if (NR-start>40) exit
    }' "$PLAN")"
  NUM_UNIT="$(printf '%s' "$SECTION" | grep -ioE '[0-9]+(\.[0-9]+)?[[:space:]]*(ms|s|m|h|%|x|rps|qps|req|requests|gb|mb|kb|tb|bytes|users|p50|p95|p99|fps|days|day|hrs|hours|min|mins|seconds|€|\$|usd|eur)' | head -1 || true)"
  HAS_BASELINE="$(printf '%s' "$SECTION" | grep -iqE '\bbaseline\b' && echo y || echo n)"
  HAS_TARGET="$(printf '%s' "$SECTION" | grep -iqE '\btarget\b' && echo y || echo n)"
  if [ -z "$NUM_UNIT" ] && ! { [ "$HAS_BASELINE" = y ] && [ "$HAS_TARGET" = y ]; }; then
    FAILED+=("R3")
    add_finding "R3" "$R3_LINE" "Success-metric section has no number+unit and not both 'baseline' and 'target'."
  fi
fi

# ── R4: comparator OR Given/When/Then anywhere in acceptance/tasks area ───────
# Whole-file scan: the acceptance criteria + task list live inside PLAN.md.
# Comparator regex matches GENUINE comparisons only: <=,>=,== always; bare <,> only in a
# comparison shape (adjacent to a digit, or space-flanked). This deliberately does NOT match
# HTML/JSX tags (<code>, </button>, /r/<id>) or generics (list<string>) — those are not comparators.
R4_CMP_RE='(<=|>=|==)|([<>][[:space:]]*[0-9])|([0-9][[:space:]]*[<>])|([[:space:]][<>][[:space:]])'
R4_CMP_LINE="$(grep -nE "$R4_CMP_RE" "$PLAN" | head -1 | cut -d: -f1 || true)"
# Given/When/Then: require at least Given+When+Then keywords present (BDD form).
HAS_GIVEN="$(grep -iqE '\bgiven\b' "$PLAN" && echo y || echo n)"
HAS_WHEN="$(grep -iqE '\bwhen\b' "$PLAN" && echo y || echo n)"
HAS_THEN="$(grep -iqE '\bthen\b' "$PLAN" && echo y || echo n)"
if [ -z "$R4_CMP_LINE" ] && ! { [ "$HAS_GIVEN" = y ] && [ "$HAS_WHEN" = y ] && [ "$HAS_THEN" = y ]; }; then
  FAILED+=("R4")
  add_finding "R4" 0 "No comparator (<,>,==,>=,<=) and no Given/When/Then in acceptance/tasks area."
fi

# ── R5 (OPTIONAL): constitution alignment ─────────────────────────────────────
# IF a constitution.md exists at repo root or walteur-kit/, enforce a trivially-checkable
# non-violation: a test-first constitution requires PLAN.md to carry a "Test matrix" section.
# No constitution.md => skip silently (existing R1..R4-only behavior unchanged). Low false
# positive by design: only fires on an explicit test-first constitution AND a missing matrix.
CONSTITUTION=""
for c in "$ROOT/constitution.md" "$KIT/constitution.md"; do
  [ -f "$c" ] && { CONSTITUTION="$c"; break; }
done
if [ -n "$CONSTITUTION" ]; then
  if grep -qiE 'test[ -]?first|tests[ -]?first|test[ -]?driven|\bTDD\b|tests before code|test[ -]?before[ -]?code' "$CONSTITUTION" 2>/dev/null; then
    if ! grep -qiE '#{0,6}[[:space:]]*test[ -]?matrix|\btest matrix\b' "$PLAN" 2>/dev/null; then
      FAILED+=("R5")
      add_finding "R5" 0 "Constitution ($(basename "$CONSTITUTION")) mandates test-first, but PLAN.md has no 'Test matrix' section."
    fi
  fi
fi

# ── R6 (OPTIONAL): PRD reference ──────────────────────────────────────────────
# IF walteur-kit/PRD.md (or PRD.md at root) exists, PLAN.md must cite it (the §4.1 Why→PRD law).
# No PRD => skip silently (R1..R5-only behavior unchanged). Low false positive: only fires when a
# PRD is actually on record and the plan never names it.
PRD_FILE=""
for p in "$KIT/PRD.md" "$ROOT/PRD.md"; do
  [ -f "$p" ] && { PRD_FILE="$p"; break; }
done
if [ -n "$PRD_FILE" ]; then
  if ! grep -qiE 'PRD\.md|walteur-kit/PRD|\bPRD\b' "$PLAN" 2>/dev/null; then
    FAILED+=("R6")
    add_finding "R6" 0 "walteur-kit/PRD.md exists but PLAN.md does not reference it — cite the PRD in 'Why', do not restate it (WALTEUR §4.1; spec drift = rewrite)."
  fi
fi

# ── R7 (TWINNED WARNING-FIRST EARS CHECK): twinned warning-first; pure-regex always; Vale optional ──
# Detection strategy: two-tier.
#   Tier 1 — pure regex (always runs): checks for WHEN/WHILE/SHALL keywords in EARS positions.
#   Tier 2 — Vale (optional): runs ONLY if `vale` is installed AND walteur-kit/vale-rules/ exists;
#            silently SKIPPED otherwise (detect-or-SKIP). Vale findings are advisory-only in default mode.
# Escalation: default = add_advisory (WARN, never blocks). WALTEUR_EARS=hard => also add to FAILED.
HAS_AC_AREA="n"
if grep -qiE '#{0,6}[[:space:]]*acceptance|acceptance[[:space:]]+criteria|\bAC[0-9]+\b|^[[:space:]]*-[[:space:]]*AC[0-9: ]' "$PLAN" 2>/dev/null; then
  HAS_AC_AREA="y"
fi
if [ "$HAS_AC_AREA" = "y" ]; then
  R7_FIRED="n"

  # Tier 1 — pure-regex EARS check (WHEN/WHILE/SHALL — core EARS trigger+response shape).
  if ! grep -qiE '\b(WHEN|WHILE|SHALL)\b' "$PLAN" 2>/dev/null; then
    R7_FIRED="y"
    R7_MSG="Acceptance criteria present but none use EARS grammar (WHEN <trigger>, THE <system> SHALL <response>). EARS makes each AC's trigger+response testable verbatim."
  fi

  # Tier 2 — Vale check (detect-or-SKIP): runs only if vale binary AND vale-rules/ both present.
  VALE_RULES_DIR="$KIT/vale-rules"
  if [ "$R7_FIRED" = "n" ] && command -v vale >/dev/null 2>&1 && [ -d "$VALE_RULES_DIR" ]; then
    # Run vale against the plan with our EARS rules; capture output (ignore vale exit code — advisory).
    VALE_OUT="$(vale --config /dev/null --minAlertLevel warning "$PLAN" 2>/dev/null || true)"
    if printf '%s' "$VALE_OUT" | grep -qiE 'EARS'; then
      R7_FIRED="y"
      R7_MSG="Vale EARS check: acceptance criteria present but Vale detected non-EARS AC phrasing. (WHEN <trigger>, THE <system> SHALL <response> is the target shape.)"
    fi
  fi

  if [ "$R7_FIRED" = "y" ]; then
    R7_SUFFIX="ADVISORY only — free-form ACs are valid; this never blocks in default mode."
    [ "${WALTEUR_EARS:-}" = "hard" ] && R7_SUFFIX="HARD mode active (WALTEUR_EARS=hard) — this blocks."
    add_advisory "R7" 0 "$R7_MSG $R7_SUFFIX"
    # Escalate to FAILED only when WALTEUR_EARS=hard is explicitly set.
    if [ "${WALTEUR_EARS:-}" = "hard" ]; then
      FAILED+=("R7")
      add_finding "R7" 0 "$R7_MSG (promoted to HARD by WALTEUR_EARS=hard)"
    fi
  fi
fi

# ── verdict ──────────────────────────────────────────────────────────────────
# Build JSON arrays.
if [ "${#FAILED[@]}" -gt 0 ]; then
  RULES_JSON="$(printf '%s\n' "${FAILED[@]}" | jq -R . | jq -s 'unique')"
else
  RULES_JSON='[]'
fi
if [ "${#FINDINGS_JSON[@]}" -gt 0 ]; then
  FIND_JSON="$(printf '%s\n' "${FINDINGS_JSON[@]}" | jq -s '.')"
else
  FIND_JSON='[]'
fi
if [ "${#ADVISORY_JSON[@]}" -gt 0 ]; then
  ADV_JSON="$(printf '%s\n' "${ADVISORY_JSON[@]}" | jq -s '.')"
else
  ADV_JSON='[]'
fi

# Advisories (R7) print LOUDLY but NEVER affect the verdict or exit code.
print_advisories() {
  for a in "${ADVISORY_JSON[@]}"; do
    r="$(printf '%s' "$a" | jq -r '.rule')"; m="$(printf '%s' "$a" | jq -r '.message')"
    echo "  ADVISORY $r — $m" >&2
  done
}

if [ "${#FAILED[@]}" -eq 0 ]; then
  write_report "PASS" "all applicable rules satisfied (R1..R4 core; R5/R6 optional; R7 advisory by default, hard via WALTEUR_EARS=hard)" '[]' "$FIND_JSON" "$ADV_JSON"
  echo "WALTEUR spec-lint: PASS — R1..R4 core + any applicable R5/R6 satisfied ($PLAN)." >&2
  [ "${#ADVISORY_JSON[@]}" -gt 0 ] && print_advisories
  exit 0
fi

UNIQ_FAILED="$(printf '%s\n' "${FAILED[@]}" | sort -u | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
write_report "FAIL" "failing rules: $UNIQ_FAILED" "$RULES_JSON" "$FIND_JSON" "$ADV_JSON"
echo "WALTEUR spec-lint: FAIL — failing rule(s): $UNIQ_FAILED" >&2
[ "${#ADVISORY_JSON[@]}" -gt 0 ] && print_advisories
for f in "${FINDINGS_JSON[@]}"; do
  r="$(printf '%s' "$f" | jq -r '.rule')"
  l="$(printf '%s' "$f" | jq -r '.line')"
  m="$(printf '%s' "$f" | jq -r '.message')"
  if [ "$l" != "0" ]; then echo "  $r  $PLAN:$l  $m" >&2; else echo "  $r  $m" >&2; fi
done
exit 2
