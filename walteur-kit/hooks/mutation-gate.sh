#!/usr/bin/env bash
# WALTEUR mutation-gate — HARD gate. Mutation testing proves the test suite actually KILLS bugs, not just
# executes lines. Line coverage is theater: a suite can run every line and assert nothing. A mutation score
# is the antidote — it injects faults and counts how many the tests catch. This gate CONSUMES a recorded
# walteur-kit/mutation-report.json and FAILs when its .score is below WALTEUR_MUT_MIN, and FAILs when a
# high/regulated build that HAS tests ships NO mutation-report.json at all (coverage never proven to kill).
#
# Applies when walteur-kit/mutation-report.json exists, OR (tests exist AND risk high/regulated).
# CONTRACT: score < min => FAIL exit 2 · high/regulated + tests + no report => FAIL exit 2 ·
#   non-numeric/unparseable score => FAIL-CLOSED exit 2 · below high w/o report => NOT_APPLICABLE ·
#   jq absent => SKIP · PAUSED => exit 2 · bypass WALTEUR_MUTATION=off.
# Report: walteur-kit/mutation-report-gate.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "mutation-gate - HARD gate. Mutation testing proves the test suite actually KILLS bugs, not just"
  printf '%s\n' "usage: bash mutation-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/mutation-report-gate.json - fix recipes: walteur-kit/REMEDIATION.md (## mutation-gate)"
  printf '%s\n' "bypass: WALTEUR_MUTATION=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
MANIFEST="${WALTEUR_MUT_FILE:-$KIT/mutation-report.json}"
MIN="${WALTEUR_MUT_MIN:-80}"
REPORT="$KIT/mutation-report-gate.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"mutation", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"mutation","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }

# tests exist? the has_tests signal flag wins; else probe the tree for test/spec files.
has_tests() {
  if [ -f "$SIGNALS" ] && have jq; then
    # NOTE: `.has_tests // empty` is WRONG — jq's // treats `false` as empty. Read the raw value.
    case "$(jq -r 'if has("has_tests") then .has_tests else "absent" end' "$SIGNALS" 2>/dev/null)" in
      true) return 0;; false) return 1;;
    esac
  fi
  found="$(find "$ROOT" \
      \( -path '*/node_modules' -o -path '*/.git' -o -path '*/walteur-kit' -o -path '*/dist' -o -path '*/build' -o -path '*/.next' -o -path '*/vendor' \) -prune -o \
      -type f \( -name '*.test.*' -o -name '*.spec.*' -o -name '*_test.*' -o -name 'test_*.py' \) -print 2>/dev/null | head -1)"
  [ -n "$found" ]
}

high_risk() { case "$(risk)" in high|regulated) return 0;; *) return 1;; esac; }

applies() {
  [ -f "$MANIFEST" ] && return 0
  if high_risk; then has_tests && return 0; fi
  return 1
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "mutation selftest SKIP - jq not installed."; return 0; fi
  echo "mutation-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  # twin fixtures
  contract() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${2:-high}" > "$1/walteur-kit/build-contract.json"; }
  tests() { mkdir -p "$1/src"; printf 'test("x",()=>{});\n' > "$1/src/a.test.ts"; }
  report() { mkdir -p "$1/walteur-kit"; printf '%s\n' "$2" > "$1/walteur-kit/mutation-report.json"; }

  # ── FALSE-POSITIVE GUARDS — clean fixtures that MUST pass ──────────────────────
  # 1. good report, score >= min -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; contract "$t" high; tests "$t"; report "$t" '{"score":92,"metrics":{"totalMutants":50,"killed":46,"survived":4}}'; ck "score 92 >= 80 -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 2. report-only (no risk/tests), good score -> PASS (report presence applies on its own)
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":85,"metrics":{"totalMutants":40,"killed":34,"survived":6}}'; ck "report-only, score 85 -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. .mutationScore alias accepted -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"mutationScore":81,"tool":"stryker"}'; ck "mutationScore alias 81 -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 4. score exactly == min -> PASS (>= boundary)
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":80,"tool":"mutmut"}'; ck "score == min (80) -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 5. numeric-string score coerced -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":"88","tool":"pitest"}'; ck "numeric-string 88 -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 6. float score above floor -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":84.7,"tool":"stryker"}'; ck "float 84.7 >= 80 -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # ── POISONED TWINS — must FAIL ────────────────────────────────────────────────
  # 7. score below min -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":61,"tool":"stryker"}'; ck "score 61 < 80 -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. high + tests + NO report -> FAIL (coverage theater unproven)
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; contract "$t" high; tests "$t"; ck "high+tests, no report -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. regulated + tests + NO report -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; contract "$t" regulated; tests "$t"; ck "regulated+tests, no report -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10. non-numeric score -> FAIL-CLOSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":"N/A","tool":"stryker"}'; ck "non-numeric score -> FAIL-CLOSED" 2 "$(run "$t")"; rm -rf "$t"
  # 11. score field missing -> FAIL-CLOSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"coverage":99,"tool":"stryker"}'; ck "no score field -> FAIL-CLOSED" 2 "$(run "$t")"; rm -rf "$t"
  # 12. null score -> FAIL-CLOSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":null,"tool":"stryker"}'; ck "null score -> FAIL-CLOSED" 2 "$(run "$t")"; rm -rf "$t"
  # 13. malformed JSON -> FAIL-CLOSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{not json'; ck "malformed report -> FAIL-CLOSED" 2 "$(run "$t")"; rm -rf "$t"

  # ── NOT_APPLICABLE (clean, must exit 0 without a verdict of FAIL) ──────────────
  # 14. medium + tests + no report -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; contract "$t" medium; tests "$t"; ck "medium+tests, no report -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 15. high risk but NO tests + no report -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; contract "$t" high; ck "high, no tests, no report -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 16. default risk (no contract) + tests + no report -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; tests "$t"; ck "default-risk+tests, no report -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 17. has_tests=false signal overrides probe: high + report-absent -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; contract "$t" high; tests "$t"; printf '{"has_tests":false}\n' > "$t/walteur-kit/preflight-signals.json"; ck "has_tests=false signal -> NA" 0 "$(run "$t")"; rm -rf "$t"

  # ── env-driven min ────────────────────────────────────────────────────────────
  # 18. score 70, min 65 -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":70,"tool":"stryker"}'; ck "score 70, min 65 -> PASS" 0 "$(WALTEUR_MUT_MIN=65 run "$t")"; rm -rf "$t"
  # 19. score 70, min 90 -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":70,"tool":"stryker"}'; ck "score 70, min 90 -> FAIL" 2 "$(WALTEUR_MUT_MIN=90 run "$t")"; rm -rf "$t"

  # ── bypass + PAUSED ───────────────────────────────────────────────────────────
  # 20. bypass -> exit 0 even with a failing score
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":1}'; WALTEUR_ROOT="$t" WALTEUR_MUTATION=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  # 21. PAUSED -> exit 2 even with a passing score
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":99,"tool":"stryker"}'; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ── G-REGRESSIONS — the 3 PROVEN red-team false-negatives, each must now FAIL ──
  # G1. sibling-key smuggle: passing decoy .score="95.0" while metrics.mutationScore=23.53 (12 killed
  #     /39 survived). Declared score disagrees with authoritative metrics -> FAIL-CLOSED (was EXIT 0).
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"schemaVersion":"1","score":"95.0","files":{"src/auth.js":{"metrics":{"mutationScore":23.53,"killed":12,"survived":39,"noCoverage":0}}},"metrics":{"mutationScore":23.53,"killed":12,"survived":39,"totalMutants":51},"thresholds":{"high":80,"low":60,"break":50}}'; ck "G1 sibling-key smuggle (score!=metrics) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2. duplicate-key smuggle: {"score":12,"score":99} — honest first value 12 masked by appended 99.
  #     jq last-wins collapses to 99; --stream dup-key detector must catch it -> FAIL (was EXIT 0).
  #     (bare, no tool markers either — dup-key check fires first regardless.)
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":12,"score":99}'; ck "G2 duplicate score key -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3. vacuous 0/0 score: score:100 with metrics.totalMutants:0/killed:0 — nothing was mutated, so the
  #     'perfect' score proves nothing -> FAIL-CLOSED (was EXIT 0).
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"schemaVersion":"1.0","tool":"stryker","thresholds":{"high":80,"low":60,"break":50},"score":100,"mutationScore":100,"metrics":{"totalMutants":0,"killed":0,"survived":0,"timeout":0,"noCoverage":0,"ignored":0,"compileErrors":0},"files":{},"comment":"no mutants"}'; ck "G3 vacuous 0/0 score:100 -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # ── G-REGRESSION false-positive guards — honest reports of the SAME SHAPE must still PASS ──
  # G1b. full report whose declared score RECONCILES with metrics (90 == metrics, 90 killed/10 survived) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":90,"mutationScore":90,"metrics":{"mutationScore":90,"killed":90,"survived":10,"totalMutants":100},"files":{"src/a.js":{}}}'; ck "G1b consistent full report -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # G2b. single (non-duplicate) score key with the same value 99 -> PASS (proves dup-check is key-count, not value)
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":99,"tool":"stryker"}'; ck "G2b single score:99 (no dup) -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # G2c. array with repeated values is NOT a duplicate key -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":90,"samples":[5,5,5],"metrics":{"killed":90,"survived":10}}'; ck "G2c repeated array values (no dup key) -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # G3b. real mutants run, score reconciles, totalMutants>0 -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":92,"metrics":{"totalMutants":50,"killed":46,"survived":4}}'; ck "G3b real mutants, consistent -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # ── AUTHENTICITY FLOOR (C6) — bare hand-written scores must be rejected ────────
  # A1. NEGATIVE CONTROL: bare {"score":95} with zero corroborating shape -> FAIL (the exact forged
  #     shape the spec calls out: "reject a bare hand-written {score: 95} shape").
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":95}'; ck "A1 bare {score:95} no markers -> FAIL (forged)" 2 "$(run "$t")"; rm -rf "$t"
  # A2. NEGATIVE CONTROL: bare score plus an unrelated free-text field still has no tool markers -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":97,"note":"ran mutation tests locally"}'; ck "A2 bare score + prose note -> FAIL (forged)" 2 "$(run "$t")"; rm -rf "$t"
  # A3. per-file kill list alone (no top metrics/tool field) satisfies the floor -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":88,"files":{"src/x.js":{"killed":9,"survived":1,"mutants":10}}}'; ck "A3 per-file kill list -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # A4. known tool name alone (cargo-mutants) satisfies the floor -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":83,"tool":"cargo-mutants"}'; ck "A4 known tool field -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # A5. schemaVersion + any tool string satisfies the floor -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":81,"schemaVersion":"2","tool":"custom-runner"}'; ck "A5 schemaVersion+tool -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # A6. metrics object with only totalMutants satisfies the floor -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":86,"metrics":{"totalMutants":20}}'; ck "A6 metrics.totalMutants only -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # A7. empty files object ({}) is NOT a kill list and no other marker present -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":90,"files":{}}'; ck "A7 empty files object, no marker -> FAIL (forged)" 2 "$(run "$t")"; rm -rf "$t"

  # ── NATIVE-REF RE-VERIFY (C6) ──────────────────────────────────────────────────
  # A8. native ref present and file exists+non-empty -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":90,"tool":"stryker","nativeReportRef":"walteur-kit/native-mutation.json"}'; printf '{"raw":true}\n' > "$t/walteur-kit/native-mutation.json"; ck "A8 native ref exists -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # A9. NEGATIVE CONTROL: native ref present but file missing -> FAIL (cannot re-verify a claimed artifact)
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":90,"tool":"stryker","nativeReportRef":"walteur-kit/missing-native.json"}'; ck "A9 native ref missing file -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # A10. NEGATIVE CONTROL: native ref present but points at an escape path -> FAIL (unsafe ref)
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":90,"tool":"stryker","nativeReportRef":"../outside.json"}'; ck "A10 native ref path escape -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # A11. NEGATIVE CONTROL: native ref .json file exists but is not valid JSON -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/mutationga.XXXXXX")"; report "$t" '{"score":90,"tool":"stryker","nativeReportRef":"walteur-kit/bad-native.json"}'; printf 'not json' > "$t/walteur-kit/bad-native.json"; ck "A11 native ref invalid JSON -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  echo "mutation-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_MUTATION:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_MUTATION=off"; echo "mutation-gate: bypassed." >&2; exit 0; }

if ! applies; then write_report "NOT_APPLICABLE" "no mutation proof required (not high/regulated with tests, no mutation-report.json)"; echo "mutation-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "mutation-gate: SKIP." >&2; exit 0; fi

# Forced surface (high/regulated + tests) but report ABSENT => coverage theater unproven.
if [ ! -s "$MANIFEST" ]; then
  add_finding "manifest" "$(risk)-risk build with tests but walteur-kit/mutation-report.json absent — line coverage proves nothing kills; run a mutation suite (Stryker/mutmut/PIT/cargo-mutants) and record a numeric .score"
  write_report "FAIL" "mutation report absent at forced surface"
  echo "mutation-gate: FAIL - mutation-report.json absent" >&2
  exit 2
fi

# Unparseable JSON => FAIL-CLOSED (never trust an unreadable proof).
if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
  add_finding "parse" "mutation-report.json is not valid JSON — cannot read a score; treating as unproven"
  write_report "FAIL" "mutation report unparseable"
  echo "mutation-gate: FAIL - report not valid JSON" >&2
  exit 2
fi

# SHAPE 1: exactly ONE JSON document, and it must be an OBJECT. Reject concatenated multi-doc
# streams ({...}{...}), top-level arrays, and scalars — any of which lets a producer smuggle a
# second value past a single-object reader. `jq -s` slurps every doc into an array; demand length 1
# and an object root. Fail-CLOSED on any deviation.
docshape="$(jq -s -r 'if (length==1 and (.[0]|type)=="object") then "ok" else "bad" end' "$MANIFEST" 2>/dev/null)"
if [ "$docshape" != "ok" ]; then
  add_finding "shape" "mutation-report.json is not a single JSON object (multi-document stream, top-level array, or scalar) — a single authoritative report is required; treating as unproven"
  write_report "FAIL" "mutation report is not a single JSON object"
  echo "mutation-gate: FAIL - report not a single JSON object" >&2
  exit 2
fi

# SHAPE 2: reject DUPLICATE keys anywhere in the report. jq's object reader silently keeps the LAST
# value for a repeated key, so {"score":12,"score":99} collapses to 99 and the honest first value 12
# is destroyed before any downstream defense sees it. `jq --stream` is the ONLY reader that exposes
# every key event: a duplicate key emits the SAME leaf-path twice. Count paths that appear >1 time.
# (Array elements have DISTINCT indexed paths, so repeated array values do NOT trip this.)
dupkeys="$(jq -n --stream '
    [ inputs | select(length==2) | .[0] | tojson ]
    | reduce .[] as $p ({}; .[$p] += 1)
    | [ to_entries[] | select(.value > 1) ] | length' "$MANIFEST" 2>/dev/null)"
if [ -z "$dupkeys" ] || [ "$dupkeys" != "0" ]; then
  add_finding "shape" "mutation-report.json contains duplicate JSON keys — a repeated key lets a sub-threshold score be masked by an appended decoy (jq keeps last-wins); fail-closed on ambiguous reports"
  write_report "FAIL" "mutation report contains duplicate JSON keys"
  echo "mutation-gate: FAIL - report contains duplicate keys" >&2
  exit 2
fi

# AUTHENTICITY FLOOR: a bare hand-written {"score":95} is indistinguishable from a real mutation run
# unless the report also carries at least one TOOL-EMISSION marker — a field shape that a human faking
# a number would not bother reproducing. Recognised markers (any ONE is sufficient):
#   - a per-file kill-list: an object at .files (or .mutationTestResult.files) whose entries expose
#     killed/survived/mutants/detected counts (Stryker JSON schema, mutmut --json, PIT-style).
#   - a schemaVersion/tool field naming a known mutation tool (stryker, mutmut, pit/pitest,
#     cargo-mutants, mutpy, humbug/infection, stryker-net).
#   - a metrics object with numeric totalMutants/killed/survived (already used by the VACUOUS/DISAGREE
#     consistency check above, but its PRESENCE alone is evidence of real tool emission).
# None present => FAIL-CLOSED: "authenticity floor" — a bare score with zero corroborating shape is
# rejected regardless of its numeric value (a hand-typed {"score":95} must not pass).
authentic="$(jq -r '
    def isnum(x): (x|type)=="number" or ((x|type)=="string" and (x|tonumber?)!=null);
    def files_obj: (.files // .mutationTestResult.files // {});
    def has_filelist:
      (files_obj|type)=="object" and (files_obj|length) > 0 and
      ([ files_obj | to_entries[] | select(
           (.value|type)=="object" and (
             isnum(.value.killed) or isnum(.value.survived) or isnum(.value.mutants) or
             isnum(.value.detected) or ((.value.metrics|type)=="object")
           )
         ) ] | length) > 0;
    def known_tool:
      ((.tool // "" ) | ascii_downcase) as $t
      | ($t | test("stryker|mutmut|pit(est)?|cargo-mutants|mutpy|infection|humbug")) or
        (has("schemaVersion") and ($t != ""));
    def has_metrics:
      (.metrics|type)=="object" and
      (isnum(.metrics.totalMutants) or (isnum(.metrics.killed) and isnum(.metrics.survived)));
    if has_filelist or known_tool or has_metrics then "yes" else "no" end' "$MANIFEST" 2>/dev/null)"
if [ "$authentic" != "yes" ]; then
  add_finding "authenticity" "mutation-report.json is a bare score with no tool-emission markers (no per-file kill list, no recognised tool/schemaVersion field, no metrics object) — indistinguishable from a hand-written {score:N}; fail-closed until a real mutation tool's shape is present"
  write_report "FAIL" "mutation report lacks tool-emission authenticity markers"
  echo "mutation-gate: FAIL - report has no tool-emission markers (bare score rejected)" >&2
  exit 2
fi

# OPTIONAL RE-VERIFY: if the report references the mutation tool's own NATIVE output file (the raw
# artifact the tool itself wrote, e.g. Stryker's mutation.json/reports/mutation/mutation.json, or a
# mutmut cache), and that native file exists on disk, cross-check it is non-empty parseable JSON (when
# jq-parseable) so a report that CLAIMS a native artifact but points at nothing/garbage is caught. This
# only fires when such a reference field is actually present — reports with no such field are
# unaffected (most CI setups only emit the summary report, not the raw tool output).
native_ref="$(jq -r '(.nativeReportRef // .rawReportRef // .sourceReportRef // .reportFile // empty)' "$MANIFEST" 2>/dev/null)"
if [ -n "$native_ref" ]; then
  case "$native_ref" in
    /*|*../*|../*|*'/..'|*'//'*) native_path="" ;;
    *) native_path="$ROOT/$native_ref" ;;
  esac
  if [ -z "$native_path" ] || [ ! -s "$native_path" ]; then
    add_finding "native-ref" "mutation-report.json references a native tool output ($native_ref) that is missing, unsafe, or empty — cannot re-verify the claimed run"
    write_report "FAIL" "mutation report native reference missing or empty"
    echo "mutation-gate: FAIL - native report ref '$native_ref' missing/empty" >&2
    exit 2
  fi
  if [[ "$native_path" == *.json ]] && ! jq -e . "$native_path" >/dev/null 2>&1; then
    add_finding "native-ref" "mutation-report.json's native reference ($native_ref) is not valid JSON — cannot re-verify the claimed run"
    write_report "FAIL" "mutation report native reference is not valid JSON"
    echo "mutation-gate: FAIL - native report ref '$native_ref' not valid JSON" >&2
    exit 2
  fi
fi

# Is there a numeric score (in .score or .mutationScore)?  jq tonumber coercion; fail-CLOSED otherwise.
numeric="$(jq -r '
    def n(x): if (x|type)=="number" then true
              elif (x|type)=="string" then ((x|tonumber? ) != null)
              else false end;
    if n(.score) or n(.mutationScore) then "yes" else "no" end' "$MANIFEST" 2>/dev/null)"

if [ "$numeric" != "yes" ]; then
  add_finding "score" "mutation score (.score / .mutationScore) is missing or non-numeric — fail-closed: an unreadable score is an unproven suite"
  write_report "FAIL" "mutation score missing or non-numeric"
  echo "mutation-gate: FAIL - score not numeric" >&2
  exit 2
fi

score="$(jq -r '
    def num(x): if (x|type)=="number" then x
                elif (x|type)=="string" then (x|tonumber? // empty)
                else empty end;
    (num(.score) // num(.mutationScore)) // empty' "$MANIFEST" 2>/dev/null)"
# belt-and-suspenders: strip to a leading number; fail-CLOSED if nothing survives.
score="$(printf '%s' "$score" | grep -oE '^-?[0-9]+(\.[0-9]+)?' | head -1)"
if [ -z "$score" ]; then
  add_finding "score" "could not coerce a numeric mutation score — fail-closed"
  write_report "FAIL" "mutation score uncoercible"
  echo "mutation-gate: FAIL - score uncoercible" >&2
  exit 2
fi

# SEMANTIC consistency: a reported score is only evidence if it RECONCILES with the report's own
# authoritative metrics. Two ways a green score lies even when it parses cleanly:
#   VACUOUS  — metrics.totalMutants==0 (or killed+survived==0): no mutants were ever run, so the
#              score (often a tautological 100) proves nothing. Coverage theater by another name.
#   DISAGREE — the declared .score/.mutationScore conflicts (> 1.0 pt) with metrics.mutationScore or
#              with the score derived from killed/survived. A passing decoy smuggled at one key while
#              the real failing score sits in metrics is exactly this. Fail-CLOSED on either.
# Only fires when the relevant metrics fields are PRESENT & numeric — a minimal {"score":92} with no
# metrics is left untouched (false-positive guard).
consistency="$(jq -r '
    def num(x): if (x|type)=="number" then x
                elif (x|type)=="string" then (x|tonumber? // null)
                else null end;
    def isnum(x): (x|type)=="number" or ((x|type)=="string" and (x|tonumber?)!=null);
    (num(.score) // num(.mutationScore)) as $declared
    | (if (.metrics|type)=="object" then .metrics else {} end) as $m
    | ($declared // 0) as $d
    | if ($declared==null) then "OK"
      elif (isnum($m.totalMutants) and (num($m.totalMutants)==0)) then "VACUOUS"
      elif (isnum($m.killed) and isnum($m.survived) and ((num($m.killed)+num($m.survived))==0) and (isnum($m.totalMutants)|not)) then "VACUOUS"
      elif (isnum($m.killed) and isnum($m.survived) and ((num($m.killed)+num($m.survived))>0)
            and (((num($m.killed)/(num($m.killed)+num($m.survived))*100) - $d) | (if .<0 then -. else . end) > 1.0)) then "DISAGREE"
      elif (isnum($m.mutationScore) and (.score!=null) and (((num($m.mutationScore)) - $d) | (if .<0 then -. else . end) > 1.0)) then "DISAGREE"
      else "OK" end' "$MANIFEST" 2>/dev/null)"

case "$consistency" in
  VACUOUS)
    add_finding "metrics" "mutation score $score is VACUOUS — metrics report 0 mutants run (totalMutants/killed+survived == 0); a score with no mutants proves nothing was killed; record a real mutation run that generates mutants"
    write_report "FAIL" "mutation score vacuous (no mutants run)"
    echo "mutation-gate: FAIL - score $score is vacuous (0 mutants run)" >&2
    exit 2;;
  DISAGREE)
    add_finding "metrics" "declared mutation score $score DISAGREES with the report's own metrics (metrics.mutationScore / killed-survived) — the top-level score does not reconcile with authoritative counts; fail-closed on a self-contradicting report"
    write_report "FAIL" "mutation score disagrees with report metrics"
    echo "mutation-gate: FAIL - score $score disagrees with report metrics" >&2
    exit 2;;
esac

# Float-safe score >= MIN comparison via awk (scores may be e.g. 84.7).
below="$(awk -v s="$score" -v m="$MIN" 'BEGIN{ if (s+0 < m+0) print "yes"; else print "no" }')"
if [ "$below" = "yes" ]; then
  add_finding "score" "mutation score $score is below the WALTEUR_MUT_MIN floor of $MIN — the suite leaves surviving mutants; tighten assertions until they die"
  write_report "FAIL" "mutation score $score < $MIN"
  echo "mutation-gate: FAIL - score $score < $MIN" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi

write_report "PASS" "mutation score $score >= $MIN (suite kills mutants)"
echo "mutation-gate: PASS - score $score >= $MIN" >&2
exit 0
