#!/usr/bin/env bash
# WALTEUR pbt-gate — HARD gate. Pure-logic modules — parsers, money/price/tax/currency math, auth/authz
# checks, validators, tokenizers, serializers — are exactly the code where a single unconsidered input
# (a negative amount, an empty string, a Unicode edge, an integer overflow) silently corrupts state or
# opens a hole. Example-based unit tests only prove the handful of inputs the author imagined. At
# high/regulated risk this gate REQUIRES at least one PROPERTY-BASED test — fast-check (fc.assert /
# fc.property), Hypothesis (@given), jsverify, or proptest — that hammers those modules with generated
# inputs. If such modules exist and NO property test is found, the build FAILs.
#
# Applies when risk is high/regulated AND >=1 pure-logic module exists (src non-test file whose name or
# content matches parse|calc|money|price|tax|currency|auth|authz|validate|tokeniz|serialize).
# CONTRACT: pure-logic modules at high/regulated risk with NO property test => FAIL exit 2 ·
# no such modules, or risk below high => NOT_APPLICABLE · grep absent => SKIP · PAUSED => exit 2 ·
# bypass WALTEUR_PBT=off.
# Report: walteur-kit/pbt-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "pbt-gate - HARD gate. Pure-logic modules - parsers, money/price/tax/currency math, auth/authz"
  printf '%s\n' "usage: bash pbt-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/pbt-report.json - fix recipes: walteur-kit/REMEDIATION.md (## pbt-gate)"
  printf '%s\n' "bypass: WALTEUR_PBT=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
CONTRACT="$KIT/build-contract.json"
REPORT="$KIT/pbt-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

# pure-logic surface: file NAME or CONTENT matching these stems
LOGIC='parse|calc|money|price|tax|currency|auth|authz|validate|tokeniz|serialize'
# source extensions worth scanning for both surface + property tests
INC='--include=*.ts --include=*.tsx --include=*.mts --include=*.cts --include=*.js --include=*.jsx --include=*.mjs --include=*.cjs --include=*.py --include=*.rs --include=*.go --include=*.java --include=*.rb --include=*.php --include=*.cs --include=*.kt --include=*.scala --include=*.swift'
# directories never part of the shipped/own surface
XD="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit --exclude-dir=dist --exclude-dir=build --exclude-dir=.next --exclude-dir=out --exclude-dir=target --exclude-dir=vendor --exclude-dir=.terraform --exclude-dir=coverage --exclude-dir=.venv --exclude-dir=venv --exclude-dir=__pycache__"
# test/spec/story/generated FILES — excluded from the MODULE surface (they are not the logic under test)
XF='(\.|_)(test|spec|stories|story|d|gen|generated)\.|(^|/)(test_|conftest)'

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"pbt", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"pbt","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

# risk tier from the build contract; fail-CLOSED to "medium" when unknown/unparseable so we never silently
# downgrade a real high-risk build, and so an absent contract simply yields NOT_APPLICABLE (medium<high).
risk() { local r; r="$( { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null; } || echo medium)"; r="$(printf '%s' "$r" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"; case "$r" in high|regulated|low|medium) printf '%s' "$r";; "") printf 'medium';; *) printf 'medium';; esac; }

# does a pure-logic MODULE (non-test src) exist? matches by FILENAME or by CONTENT. capture-then-test to
# stay clear of `cmd | grep -q` SIGPIPE flake under pipefail.
has_logic_module() {
  have grep || return 1
  local byname bycontent
  # by filename
  byname="$(grep -rIilE $INC $XD '.' "$ROOT" 2>/dev/null | grep -vE "$XF" | grep -iE "($LOGIC)" | head -1)"
  case "$byname" in ?*) return 0;; esac
  # by content (skip test-ish files so a property test alone never conjures the surface)
  bycontent="$(grep -rIlE $INC $XD "($LOGIC)" "$ROOT" 2>/dev/null | grep -vE "$XF" | head -1)"
  case "$bycontent" in ?*) return 0;; esac
  return 1
}

# is there at least one *LIVE & SUBSTANTIVE* PROPERTY-BASED test in the repo?
#   fast-check: fc.assert(...) or fc.property(...)        Hypothesis: @given(...)
#   jsverify: jsc.* / require('jsverify') / from 'jsverify'   proptest: proptest!{ ... } / use proptest
#
# A bare textual match is NOT enough — a red-team can fake compliance three ways, all now closed:
#   (1) TYPE/dead-code: paste the token inside a //-commented or /* */-block-commented dead test.
#       -> we STRIP comments (language-aware) before scanning, so a dead token does not count.
#   (2) SHAPE: hide the token in a string literal inside a NON-test file (a vendor/coverage report).
#       -> we only consider files whose NAME matches a real property-/test-file convention ($PTF).
#   (3) SEMANTIC: a vacuous `fc.property(..., () => true)` that imports/calls NO logic module.
#       -> the file must also reference a logic module — either CALL a logic-stem-named function
#          (e.g. calcTax(, calc_tax() or IMPORT/use/require a logic-stem-named module.
# All three must hold IN THE SAME FILE: live token AND test-file name AND logic-module reference.
PROP_TOKEN='fc\.(assert|property|asyncProperty)|@given[[:space:](]|jsverify|jsc\.(property|forall|check)|proptest!|proptest::'
# real property-/unit-test file naming conventions (js/ts/py/rs/go): *.test.*, *.spec.*, *.property.*,
# *_props.*, *_test.*, test_*, conftest.* — a plain source/report file never matches.
PTF='(\.|_)(test|spec|props|properties|property)\.|_props?\.|(^|/)(test_)|[._]test\.|(^|/)conftest\.'

# strip comments from one file, language-aware by extension, so a token buried in a comment is not "live".
# C-family (// and /* */) for ts/tsx/js/jsx/mjs/cjs/mts/cts/rs/go/java/cs/kt/scala/swift/php;
# hash (#) line comments ONLY for py/rb (so we never eat a '#' that is real code in a C-family string).
strip_comments() {
  local f="$1" ext="${1##*.}"
  case "$ext" in
    py|rb) perl -0777 -pe 's{\#[^\n]*}{}g' "$f" 2>/dev/null ;;
    *)     perl -0777 -pe 's{//[^\n]*}{}g; s{/\*.*?\*/}{}gs' "$f" 2>/dev/null ;;
  esac
}

has_property_test() {
  have grep || return 1
  have perl || return 1   # fail-closed: without perl we cannot strip comments to prove the token is live
  local f body
  # candidate test files: included extensions, not in excluded dirs, name matches a test convention.
  # -rIl over the token first to prune cheaply, then re-validate each candidate the strict way.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$f" | grep -qE "$PTF" || continue          # (2) must be a real test FILE
    body="$(strip_comments "$f")"                              # (1) drop comments — kill dead tokens
    printf '%s' "$body" | grep -qE "$PROP_TOKEN" || continue   #     live property token survives?
    # (3) must reference a logic module: CALL a logic-stem-named fn, or import/use/require one.
    if printf '%s' "$body" | grep -qiE "[A-Za-z_][A-Za-z0-9_]*($LOGIC)[A-Za-z0-9_]*[[:space:]]*\("; then
      return 0
    fi
    if printf '%s' "$body" | grep -qiE "(import|require|from|use|using|include)[^\n]*($LOGIC)"; then
      return 0
    fi
  done < <(grep -rIlE $INC $XD "$PROP_TOKEN" "$ROOT" 2>/dev/null)
  return 1
}

selftest() {
  pass=0; fail=0
  # make $0 ABSOLUTE before any temp-dir work, so the re-invoked `bash "$0"` resolves regardless of cwd
  # (Windows Git Bash: a relative $0 breaks once the harness/cwd moves).
  case "$0" in /*|?:[\/]*) SELF="$0";; *) SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")";; esac
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have grep; then echo "pbt selftest SKIP - grep not installed."; return 0; fi
  echo "pbt-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  contract() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${2:-high}" > "$1/walteur-kit/build-contract.json"; }
  # a pure-logic module (matches by both name AND content)
  logicmod() { mkdir -p "$1/src"; printf 'export function calcTax(amount){ if(amount<0) throw new Error("neg"); return amount*0.2; }\n' > "$1/src/tax.ts"; }
  # a plain non-logic module (no stem match)
  plainmod() { mkdir -p "$1/src"; printf 'export function greet(n){ return "hi "+n; }\n' > "$1/src/greet.ts"; }
  # a fast-check property test
  pbt_fc() { mkdir -p "$1/src"; printf 'import fc from "fast-check";\ntest("tax never negative", () => {\n  fc.assert(fc.property(fc.nat(), (a) => calcTax(a) >= 0));\n});\n' > "$1/src/tax.property.test.ts"; }
  # a Hypothesis property test
  pbt_hyp() { mkdir -p "$1/tests"; printf 'from hypothesis import given\nimport hypothesis.strategies as st\n@given(st.integers(min_value=0))\ndef test_tax(a):\n    assert calc_tax(a) >= 0\n' > "$1/tests/test_tax_props.py"; }
  # an EXAMPLE-based test only (no property test)
  unit_only() { mkdir -p "$1/src"; printf 'test("tax of 100", () => { expect(calcTax(100)).toBe(20); });\n' > "$1/src/tax.test.ts"; }
  # a regulated money logic module with real defects (the surface the 3 red-team misses ship unfuzzed)
  moneymod() { mkdir -p "$1/src"; printf 'export function applyTax(amount: number, rate: string): number {\n  const total = amount + amount * (rate as any);\n  return Math.round(total * 100) / 100;\n}\n' > "$1/src/money.ts"; }
  # MISS 1 (TYPE/dead-code evasion): property token present but ONLY inside a //-commented dead block;
  # the lone live test is an example-based smoke test. A live property test does NOT exist.
  pbt_commented() { mkdir -p "$1/src"; printf 'import { applyTax } from "./money";\n// TODO(re-enable): property test was flaky in CI, disabled for the release.\n// fc.assert(fc.property(fc.float(), fc.string(), (a, r) => {\n//   expect(applyTax(a, r)).toBeGreaterThanOrEqual(0);\n// }));\ntest("applyTax smoke", () => { expect(applyTax(100, "0.2")).toBe(120); });\n' > "$1/src/money.property.test.ts"; }
  # MISS 2 (SHAPE evasion): the token lives in a string field of a NON-test, report-shaped .ts object.
  pbt_in_report() { mkdir -p "$1/src"; printf 'export const report = { framework: "jest", observedAssertions: "fc.assert(fc.property(...)) // historical note, disabled" };\n' > "$1/src/coverage-report.ts"; }
  # MISS 3 (SEMANTIC evasion): a LIVE fast-check call whose body is the tautology () => true and which
  # imports/calls NO logic module (its only logic-stem occurrence is inside the test-name string).
  pbt_vacuous() { mkdir -p "$1/test"; printf 'import fc from "fast-check";\ntest("money properties hold (generated inputs)", () => {\n  fc.assert(fc.property(fc.nat(), fc.nat(), (a, b) => { return true; }));\n});\n' > "$1/test/money.property.test.ts"; }
  # a GENUINE fast-check property test that imports the money module AND calls applyTax (false-positive guard)
  pbt_money_real() { mkdir -p "$1/src"; printf 'import fc from "fast-check";\nimport { applyTax } from "./money";\ntest("applyTax never negative", () => {\n  fc.assert(fc.property(fc.nat(), (a) => applyTax(a, "0.2") >= 0));\n});\n' > "$1/src/money.property.test.ts"; }

  # 1. high risk + logic module + NO property test -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" high; logicmod "$t"; unit_only "$t"; ck "high + logic + no pbt -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 2. high risk + logic module + fast-check property test -> PASS  (false-positive guard)
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" high; logicmod "$t"; pbt_fc "$t"; ck "high + logic + fast-check -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. regulated + logic module + Hypothesis property test -> PASS  (false-positive guard)
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" regulated; logicmod "$t"; pbt_hyp "$t"; ck "regulated + logic + hypothesis -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 4. regulated + logic module + NO property test -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" regulated; logicmod "$t"; unit_only "$t"; ck "regulated + logic + no pbt -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. MEDIUM risk + logic module + no property test -> NOT_APPLICABLE (risk gate)
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" medium; logicmod "$t"; unit_only "$t"; ck "medium risk -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 6. high risk + NO logic module (plain only) -> NOT_APPLICABLE (surface absent)  (false-positive guard)
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" high; plainmod "$t"; ck "high + no logic module -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 7. high risk + only a test FILE name-matches the stem (no real module) -> NOT_APPLICABLE
  #    (the module surface must NOT be conjured by a test file alone)
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" high; plainmod "$t"; mkdir -p "$t/src"; printf 'test("noop", () => {});\n' > "$t/src/auth.test.ts"; ck "high + only auth.test.ts -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 8. high risk + logic module matched only by CONTENT (neutral filename) + no pbt -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" high; mkdir -p "$t/src"; printf 'export function compute(x){ return validate(x); }\n' > "$t/src/engine.ts"; ck "high + content-only logic + no pbt -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. no build contract at all -> NOT_APPLICABLE (risk fails closed to medium)
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; mkdir -p "$t/walteur-kit"; logicmod "$t"; ck "no contract -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 10. bypass WALTEUR_PBT=off on an otherwise-failing repo -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" high; logicmod "$t"; unit_only "$t"; WALTEUR_ROOT="$t" WALTEUR_PBT=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  # 11. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" high; logicmod "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # 12. high + logic module + proptest (Rust) -> PASS  (false-positive guard, alt framework)
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" high; mkdir -p "$t/src"; printf 'pub fn calc_tax(a: i64) -> i64 { a * 20 / 100 }\n' > "$t/src/tax.rs"; printf 'use proptest::prelude::*;\nproptest! {\n  #[test]\n  fn nonneg(a in 0i64..1000) { prop_assert!(calc_tax(a) >= 0); }\n}\n' > "$t/src/tax_props.rs"; ck "high + logic + proptest -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # ---- G# regression: 3 PROVEN red-team false-negatives the gate now closes ----
  # G1 (MISS 1, TYPE/dead-code): high + money module + property token ONLY in a //-COMMENTED dead block
  #     (live test is an example smoke test) -> must FAIL exit 2 (a commented token is not a live test).
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" high; moneymod "$t"; pbt_commented "$t"; ck "G1 commented-out fc.property -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2 (MISS 2, SHAPE): high + money module + property token only in a NON-test report-shaped .ts string
  #     -> must FAIL exit 2 (the token must live in a real test file, not a vendor/coverage report).
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" high; moneymod "$t"; pbt_in_report "$t"; ck "G2 token in non-test report file -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3 (MISS 3, SEMANTIC): high + money module + a LIVE but VACUOUS fc.property(() => true) that imports
  #     /calls no logic module -> must FAIL exit 2 (the test must reference the logic module under test).
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" high; moneymod "$t"; pbt_vacuous "$t"; ck "G3 vacuous fc.property (no module ref) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G4 false-positive guard: high + money module + a GENUINE fc.property that imports money AND calls
  #     applyTax with generated inputs -> must PASS exit 0 (we did not over-tighten into false positives).
  t="$(mktemp -d "${TMPDIR:-/tmp}/pbtgate.XXXXXX")"; contract "$t" high; moneymod "$t"; pbt_money_real "$t"; ck "G4 genuine money property test -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "pbt-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_PBT:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_PBT=off"; echo "pbt-gate: bypassed." >&2; exit 0; }

if ! have grep; then write_report "SKIP" "grep unavailable"; echo "pbt-gate: SKIP." >&2; exit 0; fi

RISK="$(risk)"
case "$RISK" in
  high|regulated) : ;;
  *) write_report "NOT_APPLICABLE" "risk_tier '$RISK' below high — property tests required only at high/regulated"; echo "pbt-gate: NOT_APPLICABLE (risk=$RISK)"; exit 0 ;;
esac

if ! has_logic_module; then
  write_report "NOT_APPLICABLE" "no pure-logic module (no non-test src matches $LOGIC by name or content)"
  echo "pbt-gate: NOT_APPLICABLE (no pure-logic module)"; exit 0
fi

if has_property_test; then
  write_report "PASS" "pure-logic modules present at $RISK risk and >=1 property-based test found"
  echo "pbt-gate: PASS" >&2; exit 0
fi

add_finding "property-test" "pure-logic modules (parse/calc/money/price/tax/currency/auth/authz/validate/tokeniz/serialize) exist at $RISK risk but NO property-based test was found — add fast-check (fc.assert/fc.property), Hypothesis (@given), jsverify, or proptest to fuzz these modules with generated inputs"
write_report "FAIL" "pure-logic modules at $RISK risk with no property-based test"
echo "pbt-gate: FAIL - no property-based test for pure-logic modules at $RISK risk" >&2
printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
exit 2
