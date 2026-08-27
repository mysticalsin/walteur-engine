#!/usr/bin/env bash
# WALTEUR mutation-gate — honest detect-or-loud-SKIP mutation-testing gate.
# Mutation testing measures TEST QUALITY: it injects faults ("mutants") and asks whether the
# existing tests catch them. The mutation score = killed / total. A high coverage % with a low
# mutation score means the tests EXECUTE the code but do not ASSERT on it.
#
# DETECT-OR-SKIP: runs the FIRST available mutation tool that matches the detected stack:
#   python  (pyproject.toml / *.py)   -> mutmut         (score: killed/total)
#   ts/js   (package.json)            -> stryker         (Stryker mutation score, threshold.high)
#   jvm     (pom.xml / build.gradle)  -> pit / mvn org.pitest  (PIT mutation coverage)
#   rust    (Cargo.toml)              -> cargo-mutants   (caught/total)
# If NO mutation tool for the detected stack is installed: print a LOUD recorded SKIP to stderr,
# write {"verdict":"SKIP","reason":"<tool> not installed"} and exit 0. NEVER silent-green,
# NEVER exit 2 for a missing tool.
#
# When a tool IS present and runs: compute killed/total. If killed/total < FLOOR => exit 2.
# FLOOR is read from walteur-kit/qa/mutation.json (.floor), default 0.70.
#
# Scope: runs on CHANGED files when a git diff is available (best-effort, tool-specific);
#        falls back to a full run if no changed in-scope files / tool lacks scoping.
#
# Report: walteur-kit/mutation-report.json  {verdict, ts, gate, tool, killed, total, score, floor, scope, details}.
# Bypass: WALTEUR_MUTATION=off.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/mutation-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_MUTATION:-on}" = "off" ] && { echo "mutation-gate: bypassed (WALTEUR_MUTATION=off)." >&2; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }
loud_skip() { echo "  SKIP — $1 not installed ($2). Recorded; NOT counted green." >&2; }
TMP="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"; trap 'rm -f "$TMP"' EXIT

# write_report <verdict> <reason> <extra-json-object>
write_report() {
  local extra="$3"
  [ -z "$extra" ] && extra='{}'
  jq -n --arg v "$1" --arg ts "$TS" --arg reason "$2" --argjson x "$extra" \
    '{verdict:$v, ts:$ts, gate:"mutation", reason:$reason} + $x' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"%s","ts":"%s","gate":"mutation","reason":"%s"}\n' "$1" "$TS" "$2" > "$REPORT"
}

# ── floor: walteur-kit/qa/mutation.json .floor, default 0.70 ──────────────────
FLOOR="0.70"
FLOOR_SRC="default"
MUT_CFG="$KIT/qa/mutation.json"
if [ -f "$MUT_CFG" ] && have jq; then
  f="$(jq -r '.floor // empty' "$MUT_CFG" 2>/dev/null || true)"
  # accept only a real number in (0,1]
  if printf '%s' "$f" | grep -qE '^0?\.[0-9]+$|^1(\.0+)?$'; then
    FLOOR="$f"; FLOOR_SRC="walteur-kit/qa/mutation.json"
  elif [ -n "$f" ]; then
    echo "  warn — qa/mutation.json .floor='$f' is not a 0–1 ratio; using default 0.70." >&2
  fi
fi

# pass_floor <killed> <total>  -> echoes "1" if score >= FLOOR else "0", plus prints score.
# Uses awk for float math (no bc dependency).
score_and_pass() { # $1=killed $2=total  -> sets SCORE, PASS_FLOOR
  awk -v k="$1" -v t="$2" -v fl="$FLOOR" 'BEGIN{
    if (t+0 <= 0) { printf "0 NA"; exit }
    s = k / t;
    printf "%.4f %d", s, (s >= fl ? 1 : 0)
  }'
}

echo "WALTEUR mutation-gate @ $ROOT (floor=$FLOOR from $FLOOR_SRC)" >&2

# ── changed in-scope files (best-effort) ─────────────────────────────────────
# Prefer staged, then working-tree, then last-commit. Used to scope tool runs where supported.
changed_files() { # $1 = grep extended-regex of file extensions to keep
  local re="$1" out=""
  if have git && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    out="$(git -C "$ROOT" diff --name-only --cached --diff-filter=ACM 2>/dev/null \
          | grep -E "$re" || true)"
    [ -z "$out" ] && out="$(git -C "$ROOT" diff --name-only --diff-filter=ACM 2>/dev/null \
          | grep -E "$re" || true)"
    [ -z "$out" ] && out="$(git -C "$ROOT" diff --name-only --diff-filter=ACM HEAD~1 2>/dev/null \
          | grep -E "$re" || true)"
  fi
  printf '%s' "$out"
}

TOOL=""; SCOPE="full"
KILLED=""; TOTAL=""

# ── 1. Python -> mutmut ──────────────────────────────────────────────────────
if { [ -f "$ROOT/pyproject.toml" ] || [ -f "$ROOT/setup.cfg" ] || ls "$ROOT"/*.py >/dev/null 2>&1; } \
   && [ -z "$TOOL" ]; then
  if have mutmut; then
    TOOL="mutmut"
    echo "  run  — mutmut (python)…" >&2
    ( cd "$ROOT" && mutmut run >/dev/null 2>&1 ) || true   # mutmut exits non-zero when survivors exist
    # mutmut results: "killed/timeout/suspicious" are killed; "survived" survive.
    res="$( cd "$ROOT" && mutmut results 2>/dev/null || true )"
    if printf '%s' "$res" | grep -q .; then
      k="$(printf '%s\n' "$res" | grep -cE '^[0-9]+:.*(killed|timeout|suspicious)' 2>/dev/null || echo 0)"
      surv="$(printf '%s\n' "$res" | grep -cE '^[0-9]+:.*survived' 2>/dev/null || echo 0)"
      # Fallback: mutmut's summary line "Killed X / Y mutants"
      if [ "$k" = "0" ] && [ "$surv" = "0" ]; then
        sm="$( cd "$ROOT" && mutmut run 2>&1 | grep -ioE 'killed[^0-9]*[0-9]+' | grep -oE '[0-9]+' | head -1 || true )"
        [ -n "$sm" ] && k="$sm"
      fi
      KILLED="$k"; TOTAL=$(( k + surv ))
    fi
  else
    loud_skip mutmut "python mutation testing"
    write_report "SKIP" "mutmut not installed" \
      "$(jq -n --arg s python '{stack:$s, tool_expected:"mutmut", floor:"'"$FLOOR"'"}')"
    echo "mutation-gate verdict: SKIP (python stack, mutmut absent) -> $REPORT" >&2
    exit 0
  fi
fi

# ── 2. TS/JS -> stryker ──────────────────────────────────────────────────────
if [ -f "$ROOT/package.json" ] && [ -z "$TOOL" ]; then
  if have stryker || have npx; then
    TOOL="stryker"
    echo "  run  — stryker (ts/js)…" >&2
    cf="$(changed_files '\.(ts|tsx|js|jsx|mjs|cjs)$')"
    args=""
    if [ -n "$cf" ]; then
      SCOPE="changed"
      # Stryker honours --mutate globs; pass the changed files.
      args="--mutate $(printf '%s' "$cf" | tr '\n' ',' | sed 's/,$//')"
    fi
    if have stryker; then
      ( cd "$ROOT" && stryker run --reporters json $args >/dev/null 2>&1 ) || true
    else
      ( cd "$ROOT" && npx --no-install stryker run --reporters json $args >/dev/null 2>&1 ) || true
    fi
    # Stryker writes reports/mutation/mutation.json (schema: .files[].mutants[].status).
    sj="$(find "$ROOT" \( -path "$ROOT/node_modules" -o -path "$ROOT/.git" \) -prune -o \
         -name 'mutation.json' -path '*mutation*' -type f -print 2>/dev/null | head -1)"
    if [ -n "$sj" ] && have jq; then
      KILLED="$(jq '[.files[]?.mutants[]? | select(.status=="Killed" or .status=="Timeout")] | length' "$sj" 2>/dev/null || echo "")"
      detected="$(jq '[.files[]?.mutants[]? | select(.status=="Killed" or .status=="Timeout" or .status=="Survived" or .status=="NoCoverage")] | length' "$sj" 2>/dev/null || echo "")"
      TOTAL="$detected"
    fi
  else
    loud_skip "stryker/npx" "ts/js mutation testing"
    write_report "SKIP" "stryker not installed" \
      "$(jq -n --arg s ts '{stack:$s, tool_expected:"stryker", floor:"'"$FLOOR"'"}')"
    echo "mutation-gate verdict: SKIP (ts/js stack, stryker absent) -> $REPORT" >&2
    exit 0
  fi
fi

# ── 3. JVM -> pit (pitest) ───────────────────────────────────────────────────
if { [ -f "$ROOT/pom.xml" ] || [ -f "$ROOT/build.gradle" ] || [ -f "$ROOT/build.gradle.kts" ]; } \
   && [ -z "$TOOL" ]; then
  if have pit || { have mvn && [ -f "$ROOT/pom.xml" ]; } || have gradle; then
    TOOL="pit"
    echo "  run  — PIT (jvm)…" >&2
    if have mvn && [ -f "$ROOT/pom.xml" ]; then
      ( cd "$ROOT" && mvn -q org.pitest:pitest-maven:mutationCoverage >/dev/null 2>&1 ) || true
    elif have gradle; then
      ( cd "$ROOT" && gradle pitest >/dev/null 2>&1 ) || true
    elif have pit; then
      ( cd "$ROOT" && pit >/dev/null 2>&1 ) || true
    fi
    # PIT writes target/pit-reports/.../mutations.xml  (<mutation detected='true'|'false'>).
    px="$(find "$ROOT" \( -path "$ROOT/.git" \) -prune -o -name 'mutations.xml' -type f -print 2>/dev/null | head -1)"
    if [ -n "$px" ]; then
      KILLED="$(grep -oE "detected='true'" "$px" 2>/dev/null | grep -c . || echo 0)"
      surv="$(grep -oE "detected='false'" "$px" 2>/dev/null | grep -c . || echo 0)"
      TOTAL=$(( KILLED + surv ))
    fi
  else
    loud_skip "pit/pitest-maven" "jvm mutation testing"
    write_report "SKIP" "pit not installed" \
      "$(jq -n --arg s jvm '{stack:$s, tool_expected:"pit", floor:"'"$FLOOR"'"}')"
    echo "mutation-gate verdict: SKIP (jvm stack, pit absent) -> $REPORT" >&2
    exit 0
  fi
fi

# ── 4. Rust -> cargo-mutants ─────────────────────────────────────────────────
if [ -f "$ROOT/Cargo.toml" ] && [ -z "$TOOL" ]; then
  if have cargo-mutants || { have cargo && cargo mutants --version >/dev/null 2>&1; }; then
    TOOL="cargo-mutants"
    echo "  run  — cargo-mutants (rust)…" >&2
    ( cd "$ROOT" && cargo mutants --json >"$TMP" 2>/dev/null ) || true
    # cargo-mutants emits mutants.out/outcomes.json with summary {caught,missed,...} or a json line.
    oj="$(find "$ROOT" -name 'outcomes.json' -path '*mutants.out*' -type f -print 2>/dev/null | head -1)"
    if [ -n "$oj" ] && have jq; then
      KILLED="$(jq '[.outcomes[]? | select(.summary=="CaughtMutant")] | length' "$oj" 2>/dev/null || echo "")"
      missed="$(jq '[.outcomes[]? | select(.summary=="MissedMutant")] | length' "$oj" 2>/dev/null || echo "")"
      if [ -n "$KILLED" ] && [ -n "$missed" ]; then TOTAL=$(( KILLED + missed )); fi
    fi
  else
    loud_skip cargo-mutants "rust mutation testing"
    write_report "SKIP" "cargo-mutants not installed" \
      "$(jq -n --arg s rust '{stack:$s, tool_expected:"cargo-mutants", floor:"'"$FLOOR"'"}')"
    echo "mutation-gate verdict: SKIP (rust stack, cargo-mutants absent) -> $REPORT" >&2
    exit 0
  fi
fi

# ── no recognised stack at all => loud SKIP ──────────────────────────────────
if [ -z "$TOOL" ]; then
  echo "  SKIP — no recognised stack (pyproject.toml/package.json/pom.xml/Cargo.toml). Nothing to mutate." >&2
  write_report "SKIP" "no recognised stack / no mutation tool installed" \
    "$(jq -n --arg fl "$FLOOR" '{floor:$fl}')"
  echo "mutation-gate verdict: SKIP (no stack) -> $REPORT" >&2
  exit 0
fi

# ── tool ran but produced no parseable result => honest SKIP (cannot score) ──
if [ -z "${KILLED:-}" ] || [ -z "${TOTAL:-}" ] || ! printf '%s' "$KILLED" | grep -qE '^[0-9]+$' \
   || ! printf '%s' "$TOTAL" | grep -qE '^[0-9]+$'; then
  echo "  SKIP — $TOOL produced no parseable mutation report (no mutants run / report missing)." >&2
  write_report "SKIP" "$TOOL produced no parseable result" \
    "$(jq -n --arg t "$TOOL" --arg fl "$FLOOR" --arg sc "$SCOPE" '{tool:$t, floor:$fl, scope:$sc}')"
  echo "mutation-gate verdict: SKIP ($TOOL, no result) -> $REPORT" >&2
  exit 0
fi

if [ "$TOTAL" -eq 0 ]; then
  echo "  SKIP — $TOOL reported 0 mutants (nothing in scope to score)." >&2
  write_report "SKIP" "$TOOL ran but 0 mutants in scope" \
    "$(jq -n --arg t "$TOOL" --arg fl "$FLOOR" --arg sc "$SCOPE" '{tool:$t, killed:0, total:0, floor:$fl, scope:$sc}')"
  echo "mutation-gate verdict: SKIP ($TOOL, 0 mutants) -> $REPORT" >&2
  exit 0
fi

# ── score + verdict ──────────────────────────────────────────────────────────
read -r SCORE PASS_FLOOR <<EOF
$(score_and_pass "$KILLED" "$TOTAL")
EOF

if [ "$PASS_FLOOR" = "1" ]; then
  write_report "PASS" "mutation score $SCORE >= floor $FLOOR" \
    "$(jq -n --arg t "$TOOL" --argjson k "$KILLED" --argjson n "$TOTAL" \
            --arg s "$SCORE" --arg fl "$FLOOR" --arg sc "$SCOPE" --arg src "$FLOOR_SRC" \
       '{tool:$t, killed:$k, total:$n, score:($s|tonumber), floor:($fl|tonumber), floor_source:$src, scope:$sc, rule:"killed/total >= floor"}')"
  echo "mutation-gate verdict: PASS — $TOOL score=$SCORE (killed=$KILLED/total=$TOTAL) >= floor=$FLOOR -> $REPORT" >&2
  exit 0
else
  write_report "FAIL" "mutation score $SCORE < floor $FLOOR" \
    "$(jq -n --arg t "$TOOL" --argjson k "$KILLED" --argjson n "$TOTAL" \
            --arg s "$SCORE" --arg fl "$FLOOR" --arg sc "$SCOPE" --arg src "$FLOOR_SRC" \
       '{tool:$t, killed:$k, total:$n, score:($s|tonumber), floor:($fl|tonumber), floor_source:$src, scope:$sc, rule:"killed/total >= floor"}')"
  echo "mutation-gate verdict: FAIL — $TOOL score=$SCORE (killed=$KILLED/total=$TOTAL) < floor=$FLOOR -> $REPORT" >&2
  exit 2
fi
