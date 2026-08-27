#!/usr/bin/env bash
# WALTEUR flaky-test-gate — a DECIDABLE static guard that catches tests which MASK flakiness
# instead of fixing the race. Vendored-concept from loopkit `flaky-hunter` (MIT) folded into a
# real HARD-armable gate: `retry(3)` on a flaky test hides a real race that will bite in prod.
#
# WHAT IT FLAGS (decidable, exit-2-checkable facts — a grep match in a test file):
#   * retryTimes( ...           jest.retryTimes / test.retryTimes — re-runs a test until it passes
#   * this.retries( ...         mocha per-test retry
#   * .retry( ...               vitest/playwright test.retry()
#   * retries: <N>              jest/cypress/playwright config retry count >= 1
# These constructs make a red test go green by re-running it — the canonical flakiness mask.
#
# HONEST CONTRACT (kit idiom):
#   * HARD = the patterns above are decidable facts; when ARMED the gate exits 2 on any match.
#     warning-first by default (a new guard ships exit-0 + loud WARN per the WALTEUR build law);
#     arm blocking with WALTEUR_FLAKY=hard.
#   * detect-or-LOUD-SKIP: no test files found => loud skip to stderr (recorded, not silent-green), exit 0.
#   * --selftest is ALWAYS hard: a clean test tree PASSES; a tree with a retry-mask MUST be CAUGHT (exit 2).
#   * Kill switch: walteur-kit/PAUSED => exit 2. Bypass: WALTEUR_FLAKY=off => loud skip, exit 0.
# Zero-dep: bash + find + grep (+ jq for the report, with a printf fallback). Read-only over the tree;
# writes ONLY its report JSON. NOT YET registered in gate-registry/ship-gate — lands selftest-only +
# detect-or-skip first (the documented additive->twin-prove->arm-HARD rollout).
#
# REPORT: walteur-kit/flaky-test-report.json (overwrite; the kit write_report idiom)
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/flaky-test-report.json"
MODE="${WALTEUR_FLAKY:-on}"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

# the retry-masking pattern (extended regex). Tight enough to avoid matching unrelated code:
# retryTimes(/this.retries(/.retry( are test-runner retry calls; retries:<N> is a config retry count >=1.
FLAKY_RE='retryTimes\(|this\.retries\(|\.retry\(|retries:[[:space:]]*[1-9]'

# ── kill switch + bypass ─────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). flaky-test-gate exiting 2." >&2; exit 2; }
if [ "$MODE" = "off" ]; then
  echo "WALTEUR flaky-test-gate SKIP — bypass WALTEUR_FLAKY=off (recorded, not silent-green)." >&2
  exit 0
fi

# ── collect test files (name patterns + test dirs), excluding deps/vcs ────────────
list_test_files() {
  find "$ROOT" -type f \
    \( -name '*.test.*' -o -name '*.spec.*' -o -path '*/__tests__/*' -o -path '*/test/*' -o -path '*/tests/*' \) \
    -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | sort -u
}

write_report() {
  local verdict="$1" scanned="$2"; shift 2
  local findings_json="[" first=1 x
  for x in "$@"; do
    [ -z "$x" ] && continue
    local e="${x//\\/\\\\}"; e="${e//\"/\\\"}"
    if [ "$first" -eq 1 ]; then findings_json="$findings_json\"$e\""; first=0
    else findings_json="$findings_json,\"$e\""; fi
  done
  findings_json="$findings_json]"
  local n=$(( $# ))
  if have jq; then
    jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg verdict "$verdict" --arg mode "$MODE" \
      --argjson scanned "$scanned" --argjson count "$n" --argjson findings "$findings_json" \
      '{tool:"flaky-test-gate", ts:$ts, verdict:$verdict, mode:$mode, scanned_files:$scanned, findings_count:$count, findings:$findings}' > "$REPORT"
  else
    printf '{"tool":"flaky-test-gate","ts":"%s","verdict":"%s","mode":"%s","scanned_files":%s,"findings_count":%s,"findings":%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$verdict" "$MODE" "$scanned" "$n" "$findings_json" > "$REPORT"
  fi
}

run_normal() {
  local files; files="$(list_test_files)"
  if [ -z "$files" ]; then
    echo "WALTEUR flaky-test-gate SKIP — no test files found under $ROOT (recorded, not silent-green)." >&2
    write_report "SKIP" 0
    return 0
  fi
  local scanned=0 f line
  declare -a FINDINGS=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    scanned=$((scanned+1))
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      FINDINGS+=("${f#$ROOT/}:$line")
    done < <(grep -nE "$FLAKY_RE" "$f" 2>/dev/null)
  done <<EOF
$files
EOF

  local n=${#FINDINGS[@]}
  echo "flaky-test-gate: scanned=$scanned retry_masks=$n (mode=$MODE)" >&2
  if [ "$n" -eq 0 ]; then
    write_report "PASS" "$scanned"
    echo "flaky-test-gate: PASS — no retry-masking constructs in $scanned test file(s)." >&2
    return 0
  fi
  local x; for x in "${FINDINGS[@]}"; do echo "  retry-mask — $x" >&2; done
  write_report "FLAKY_MASK" "$scanned" "${FINDINGS[@]}"
  if [ "$MODE" = "hard" ]; then
    echo "flaky-test-gate: FAIL (WALTEUR_FLAKY=hard) — $n retry-masking construct(s). Fix the race, don't retry it. exit 2." >&2
    return 2
  fi
  echo "WALTEUR flaky-test-gate WARN — $n retry-masking construct(s) (report: $REPORT)." >&2
  echo "  warning-first: exit 0 by default. Arm HARD blocking with WALTEUR_FLAKY=hard." >&2
  return 0
}

selftest() {
  local fails=0 total=0 tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/flaky-gate-selftest.XXXXXX")" || { echo "  FAIL — mktemp"; exit 1; }
  trap 'rm -rf "$tmp"' RETURN
  ck() { total=$((total+1)); if [ "$2" -eq 0 ]; then echo "  ok   — $1"; else echo "  FAIL — $1"; fails=$((fails+1)); fi; }
  echo "flaky-test-gate selftest:"

  # GOOD tree: a clean test that awaits the real condition, no retry mask.
  local g="$tmp/good"; mkdir -p "$g/walteur-kit" "$g/test"
  printf 'import test from "node:test";\ntest("adds", async () => { await ready(); assert.equal(1+1,2); });\n' > "$g/test/math.test.mjs"
  WALTEUR_ROOT="$g" WALTEUR_FLAKY=hard bash "$SELF" >/dev/null 2>&1
  ck "GOOD tree (no retry mask) PASSES under hard mode (exit 0)" "$?"
  if have jq; then
    local gv; gv="$(jq -r '.verdict' "$g/walteur-kit/flaky-test-report.json" 2>/dev/null)"
    ck "GOOD tree report verdict=PASS" "$([ "$gv" = "PASS" ] && echo 0 || echo 1)"
  fi

  # POISON 1: jest retryTimes — must be CAUGHT.
  local p1="$tmp/p1"; mkdir -p "$p1/walteur-kit" "$p1/test"
  printf 'jest.retryTimes(3);\ntest("flaky", () => expect(rand()).toBe(1));\n' > "$p1/test/a.test.js"
  WALTEUR_ROOT="$p1" WALTEUR_FLAKY=hard bash "$SELF" >/dev/null 2>&1
  ck "POISON jest.retryTimes( is CAUGHT (exit 2 under hard)" "$([ "$?" -eq 2 ] && echo 0 || echo 1)"

  # POISON 2: mocha this.retries — must be CAUGHT.
  local p2="$tmp/p2"; mkdir -p "$p2/walteur-kit" "$p2/test"
  printf 'describe("x", function(){ this.retries(2); it("y", ()=>{}); });\n' > "$p2/test/b.spec.js"
  WALTEUR_ROOT="$p2" WALTEUR_FLAKY=hard bash "$SELF" >/dev/null 2>&1
  ck "POISON this.retries( is CAUGHT (exit 2 under hard)" "$([ "$?" -eq 2 ] && echo 0 || echo 1)"

  # POISON 3: config retries: N — must be CAUGHT.
  local p3="$tmp/p3"; mkdir -p "$p3/walteur-kit" "$p3/__tests__"
  printf 'export default { retries: 2, testDir: "./e2e" };\n' > "$p3/__tests__/playwright.config.test.ts"
  WALTEUR_ROOT="$p3" WALTEUR_FLAKY=hard bash "$SELF" >/dev/null 2>&1
  ck "POISON 'retries: 2' is CAUGHT (exit 2 under hard)" "$([ "$?" -eq 2 ] && echo 0 || echo 1)"

  # WARNING-FIRST: the SAME poison in DEFAULT mode WARNs but exits 0 (build law).
  WALTEUR_ROOT="$p1" WALTEUR_FLAKY=on bash "$SELF" >/dev/null 2>&1
  ck "warning-first: retry mask in DEFAULT mode WARNs but exits 0" "$([ "$?" -eq 0 ] && echo 0 || echo 1)"

  # DETECT-OR-SKIP: no test files => loud skip, exit 0, verdict SKIP.
  local e="$tmp/empty"; mkdir -p "$e/walteur-kit" "$e/src"
  printf 'export const x = 1;\n' > "$e/src/app.mjs"
  WALTEUR_ROOT="$e" WALTEUR_FLAKY=hard bash "$SELF" >/dev/null 2>&1
  ck "no test files => SKIP exit 0 (detect-or-skip, not a false PASS/FAIL)" "$([ "$?" -eq 0 ] && echo 0 || echo 1)"
  if have jq; then
    local ev; ev="$(jq -r '.verdict' "$e/walteur-kit/flaky-test-report.json" 2>/dev/null)"
    ck "no-test report verdict=SKIP (recorded, not silent-green)" "$([ "$ev" = "SKIP" ] && echo 0 || echo 1)"
  fi

  # NEGATIVE CONTROL on the real pattern: a NON-retry 'retries' word (e.g. a var named retriesLeft) must NOT trip.
  local nc="$tmp/nc"; mkdir -p "$nc/walteur-kit" "$nc/test"
  printf 'test("counts", () => { let retriesLeft = 0; assert.equal(retriesLeft,0); });\n' > "$nc/test/c.test.mjs"
  WALTEUR_ROOT="$nc" WALTEUR_FLAKY=hard bash "$SELF" >/dev/null 2>&1
  ck "NEGATIVE CONTROL: 'retriesLeft' var (not a retry mask) does NOT trip (exit 0)" "$([ "$?" -eq 0 ] && echo 0 || echo 1)"

  # PAUSED kill switch => exit 2
  : > "$g/walteur-kit/PAUSED"
  WALTEUR_ROOT="$g" WALTEUR_FLAKY=on bash "$SELF" >/dev/null 2>&1
  ck "PAUSED kill switch => exit 2" "$([ "$?" -eq 2 ] && echo 0 || echo 1)"
  rm -f "$g/walteur-kit/PAUSED"

  echo "flaky-test-gate selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  -h|--help)  sed -n '1,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")         run_normal; exit $? ;;
  *)          echo "flaky-test-gate: unknown arg '$1' (try --selftest or no-arg normal run)." >&2; exit 1 ;;
esac
