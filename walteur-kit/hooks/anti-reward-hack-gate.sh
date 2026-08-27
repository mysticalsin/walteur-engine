#!/usr/bin/env bash
# WALTEUR anti-reward-hack-gate — HARD gate. Tests are the reward signal; a tautological assertion games
# coverage/green without proving anything. A $50-100M build's test suite must EARN its green. This gate
# scans ONLY test files (*.test.* / *.spec.* / test_*.py / *_test.go) for assertions that always pass and
# for tests that are counted-but-don't-run, and FAILs the build.
#
# Catches: expect(true).toBe(true) / expect(1).toBe(1) (always-true literal expect+matcher),
# assert True / assert 1 == 1 / assertTrue(true) (python/junit tautology), toBe(<same expr both sides>)
# (expect(X).toBe(X) — comparing a value to itself), an EMPTY test body
# (it("x",()=>{}) / test("x",()=>{}) with no assertion inside), and a skipped-but-counted test
# (it.skip / xit / test.skip / describe.skip / @pytest.mark.skip WITHOUT a reason= justification).
#
# FALSE-POSITIVE guard: a real assertion — expect(sum(2,3)).toBe(5), assert total == 5 — must PASS.
# Applies only when test files exist (else NOT_APPLICABLE). Bypass WALTEUR_NOREWARDHACK=off. PAUSED => exit 2.
# Report: walteur-kit/anti-reward-hack-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "anti-reward-hack-gate - HARD gate. Tests are the reward signal; a tautological assertion games"
  printf '%s\n' "usage: bash anti-reward-hack-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/anti-reward-hack-report.json - fix recipes: walteur-kit/REMEDIATION.md (## anti-reward-hack-gate)"
  printf '%s\n' "bypass: WALTEUR_NOREWARDHACK=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/anti-reward-hack-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

# A file is a TEST file iff its path matches one of these. We do not scan production source — a
# tautology in app code is anti-slop's job; here we only police the reward signal (the tests).
# *.test.* / *.spec.* (js/ts/mts/cts/mjs/cjs etc), test_*.py / *_test.py (pytest), *_test.go / *_test.*
# (go & friends), AND any code file living inside a __tests__/ / __test__/ / tests/ dir — Jest/Vitest run
# those by config regardless of basename suffix, so a tautology hidden there (__tests__/billing.ts) is a
# real, runner-counted reward signal and must be scanned (a structural false-negative otherwise).
TESTRE='(^|/)(test_[^/]+\.py$|[^/]+_test\.(go|py|rb|exs?)$|[^/]+\.(test|spec)\.[A-Za-z0-9]+$|(__tests__|__test__|tests)/[^/]*\.([cm]?[jt]sx?|py)$)'
# Dirs that never hold first-party tests.
XD="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit --exclude-dir=dist --exclude-dir=build --exclude-dir=.next --exclude-dir=out --exclude-dir=vendor --exclude-dir=.terraform"

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"anti-reward-hack", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"anti-reward-hack","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

# list every test file (newline-separated, ROOT-relative-safe absolute paths)
test_files() {
  have grep || return 0
  grep -rIl $XD -- '' "$ROOT" 2>/dev/null | grep -E "$TESTRE"
}
applies() { [ -n "$(test_files | head -1)" ]; }

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  echo "anti-reward-hack-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  mkts() { mkdir -p "$1/src"; }

  # 1. no test files -> NOT_APPLICABLE (prod source only, no tests)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'export const sum=(a,b)=>a+b;\n' > "$t/src/sum.ts"; ck "no test files -> NA" 0 "$(run "$t")"; rm -rf "$t"

  # 2. FALSE-POSITIVE GUARD: a real, honest assertion -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'import {sum} from "./sum";\ntest("adds", () => {\n  expect(sum(2,3)).toBe(5);\n});\n' > "$t/src/sum.test.ts"; ck "real assertion -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 3. expect(true).toBe(true) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'test("x", () => {\n  expect(true).toBe(true);\n});\n' > "$t/src/a.test.ts"; ck "expect(true).toBe(true) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 4. expect(1).toBe(1) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'test("x", () => {\n  expect(1).toBe(1);\n});\n' > "$t/src/b.test.ts"; ck "expect(1).toBe(1) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 5. assert True (python) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'def test_thing():\n    assert True\n' > "$t/src/test_thing.py"; ck "assert True -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 6. assertTrue(true) (junit) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'public class T {\n  @Test void t() { assertTrue(true); }\n}\n' > "$t/src/T.test.java"; ck "assertTrue(true) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 7. assert 1 == 1 -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'def test_math():\n    assert 1 == 1\n' > "$t/src/test_math.py"; ck "assert 1 == 1 -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 8. toBe(<same expr both sides>) — expect(x).toBe(x) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'test("x", () => {\n  const user = getUser();\n  expect(user.id).toBe(user.id);\n});\n' > "$t/src/c.test.ts"; ck "expect(X).toBe(X) self-compare -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 9. empty test body it("x",()=>{}) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'it("does the thing", () => {});\n' > "$t/src/d.test.ts"; ck "empty it() body -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 10. empty test body test("x",()=>{}) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'test("important path", () => {\n});\n' > "$t/src/e.test.ts"; ck "empty test() body -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 11. it.skip without a reason -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'it.skip("flaky", () => {\n  expect(charge()).toBe(true);\n});\n' > "$t/src/f.test.ts"; ck "it.skip no reason -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 12. xit -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'xit("refund path", () => {\n  expect(refund()).toBe(true);\n});\n' > "$t/src/g.test.ts"; ck "xit -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 13. describe.skip -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'describe.skip("billing", () => {\n  it("charges", () => { expect(charge()).toBe(true); });\n});\n' > "$t/src/h.test.ts"; ck "describe.skip -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 14. @pytest.mark.skip without a reason -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'import pytest\n@pytest.mark.skip\ndef test_dsar():\n    assert export_user() is not None\n' > "$t/src/test_dsar.py"; ck "pytest skip no reason -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 15. FALSE-POSITIVE GUARD: pytest skip WITH a reason -> PASS (justified, not gaming)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'import pytest\n@pytest.mark.skip(reason="blocked on upstream API GA, ticket OPS-441")\ndef test_dsar():\n    assert export_user() is not None\n' > "$t/src/test_dsar.py"; ck "pytest skip WITH reason -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 16. FALSE-POSITIVE GUARD: it.skip WITH a reason comment -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'it.skip("slow e2e — runs nightly only, see ci/nightly.yml", () => {\n  expect(bigPipeline()).toBe(true);\n});\n' > "$t/src/i.test.ts"; ck "it.skip WITH reason -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 17. tautology in PRODUCTION (non-test) file -> PASS (out of scope; anti-slop handles app code)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'export function check(){ return true === true; }\n' > "$t/src/check.ts"; printf 'test("real", () => { expect(check()).toBe(true); });\n' > "$t/src/check.test.ts"; ck "tautology in prod file -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 18. go: assert.True(t, true) tautology -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'package x\nfunc TestThing(t *testing.T){\n\tassert.True(t, true)\n}\n' > "$t/src/thing_test.go"; ck "go assert.True(true) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 19. FALSE-POSITIVE GUARD: realistic multi-assertion suite -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'import {invoice} from "./billing";\ndescribe("invoice", () => {\n  it("sums line items", () => {\n    const inv = invoice([{cents: 100}, {cents: 250}]);\n    expect(inv.total).toBe(350);\n    expect(inv.currency).toBe("USD");\n  });\n  it("applies tax", () => {\n    expect(invoice([{cents: 1000}], 0.1).total).toBe(1100);\n  });\n});\n' > "$t/src/billing.spec.ts"; ck "realistic suite -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 20. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'test("x",()=>{ expect(true).toBe(true); });\n' > "$t/src/z.test.ts"; WALTEUR_ROOT="$t" WALTEUR_NOREWARDHACK=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf 'test("x",()=>{ expect(true).toBe(true); });\n' > "$t/src/z.test.ts"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ---- G# REGRESSION cases for the 3 PROVEN gauntlet false-negatives ----

  # G1. TYPE evasion: expect(<string sentinel>).toBeTruthy() -> FAIL (Boolean("x") is always true)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'import { refund } from "./billing";\ntest("refund reverses the charge", () => {\n  refund("c1");\n  expect("refunded").toBeTruthy();\n});\n' > "$t/src/billing.test.ts"; ck "G1 string-truthy sentinel -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G1b. object-literal sentinel: expect({}).toBeTruthy() -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'test("x", () => {\n  expect({}).toBeTruthy();\n});\n' > "$t/src/o.test.ts"; ck "G1b object-truthy sentinel -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G1c. FALSE-POSITIVE GUARD: a REAL toBeTruthy on a call result -> PASS (inspects the SUT)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'import { refund } from "./billing";\ntest("refund ok", () => {\n  expect(refund("c1").ok).toBeTruthy();\n});\n' > "$t/src/billing.test.ts"; ck "G1c real toBeTruthy(call) -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # G2. SHAPE evasion: tautology in __tests__/billing.ts (no .test/.spec suffix) -> FAIL (Jest runs it)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkdir -p "$t/src/billing/__tests__"; printf 'import { charge } from "../charge";\ndescribe("billing.charge", () => {\n  test("declines are not recorded as paid", () => {\n    expect(true).toBe(true);\n  });\n});\n' > "$t/src/billing/__tests__/billing.ts"; ck "G2 hidden __tests__/ surface -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2b. FALSE-POSITIVE GUARD: an HONEST test inside __tests__/ -> PASS (scanned but clean)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkdir -p "$t/src/__tests__"; printf 'import { sum } from "../sum";\ntest("adds", () => { expect(sum(2,3)).toBe(5); });\n' > "$t/src/__tests__/sum.ts"; ck "G2b honest test in __tests__/ -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # G3. SEMANTIC evasion: it.skip with a VACUOUS bare "see" token in the title -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'import { authorizeRefund } from "./refund";\nit.skip("authorizes refund only for the original payer — see", () => {\n  expect(authorizeRefund({ payer: "alice", caller: "mallory", amount: 9999 })).toBe(false);\n});\n' > "$t/src/refund.test.ts"; ck "G3 vacuous skip token (see) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3b. FALSE-POSITIVE GUARD: it.skip with a real TICKET id -> PASS (substantive justification)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antireward.XXXXXX")"; mkts "$t"; printf 'it.skip("auth bypass repro — blocked on SEC-204", () => {\n  expect(authz()).toBe(false);\n});\n' > "$t/src/sk.test.ts"; ck "G3b skip with ticket id -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "anti-reward-hack-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_NOREWARDHACK:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_NOREWARDHACK=off"; echo "anti-reward-hack-gate: bypassed." >&2; exit 0; }
if ! applies; then write_report "NOT_APPLICABLE" "no test files (*.test.* / *.spec.* / test_*.py / *_test.go)"; echo "anti-reward-hack-gate: NOT_APPLICABLE"; exit 0; fi
if ! have perl; then write_report "SKIP" "perl unavailable (need multiline scan)"; echo "anti-reward-hack-gate: SKIP." >&2; exit 0; fi

# Perl multiline detector. grep -P is locale-broken in this Git-Bash, so we slurp each test file with
# perl -0777 and look for the reward-hacks. Each alternative is a PROVEN game-the-signal pattern. A real
# assertion (expect(sum(2,3)).toBe(5)) does NOT match any branch, so honest suites pass.
#
# Implementation notes:
#  - literal-expect tautology: expect(<bool/number literal>).toBe/toEqual/toStrictEqual(<same kind literal>)
#    where the literal is true/false or a number — i.e. asserting a constant against a constant.
#  - self-compare: expect(EXPR).toBe(EXPR) / toEqual / toStrictEqual with byte-identical, non-trivial EXPR
#    on both sides (comparing a value to itself proves nothing).
#  - python/junit/go tautology: assert True / assert 1 == 1 / assertTrue(true) / assert.True(t, true).
#  - empty body: it/test("...", ...=>{ <whitespace only> }) — a counted test with no assertion.
#  - skipped-but-counted: it.skip / xit / fit.skip / test.skip / describe.skip / @pytest.mark.skip with
#    NO reason= and NO trailing justification text — a green test that never ran.
scan_file() {
  local f rel hit
  f="$1"; rel="$(printf '%s' "$f" | sed "s#$ROOT/##")"
  hit="$(perl -0777 -ne '
    my $why = "";
    # 1) expect(<literal>).toBe/toEqual/toStrictEqual(<literal>) where both are true/false or numbers
    if (/\bexpect\s*\(\s*(true|false|-?\d+(?:\.\d+)?)\s*\)\s*\.(?:toBe|toEqual|toStrictEqual|toBeTruthy|toBeFalsy)\s*\(\s*(?:true|false|-?\d+(?:\.\d+)?)?\s*\)/) {
      $why = "literal-expect tautology: expect(<constant>).toBe(<constant>) asserts nothing";
    }
    # 1b) truthy/falsy sentinel: expect(<any constant literal>).toBeTruthy/toBeFalsy(). A string ("x"),
    #     template literal, object {}, array [], bool, null/undefined/NaN, or number is unconditionally
    #     truthy/falsy, so the assertion can NEVER inspect the system under test (Boolean("refunded") is
    #     always true). Constant alternatives: dq-string | sq-string | template | obj | arr | keyword | num.
    #     (No /x mode + no inline comments here: a literal "/" inside an /x comment would close this
    #      /-delimited pattern early — a perl gotcha. Kept as one flat pattern.)
    elsif (/\bexpect\s*\(\s*(?:"[^"]*"|'\''[^'\'']*'\''|`[^`]*`|\{[^{}]*\}|\[[^\][]*\]|true|false|null|undefined|NaN|-?\d+(?:\.\d+)?(?:[eE]-?\d+)?)\s*\)\s*\.(?:toBeTruthy|toBeFalsy)\s*\(\s*\)/) {
      $why = "truthy-sentinel tautology: expect(<constant>).toBeTruthy()/toBeFalsy() — a constant literal is unconditionally truthy/falsy and never inspects the value under test";
    }
    # 2) self-compare: expect(EXPR).toBe(EXPR) — byte-identical, non-trivial EXPR both sides
    elsif (/\bexpect\s*\(\s*([^()]{2,}?)\s*\)\s*\.(?:toBe|toEqual|toStrictEqual)\s*\(\s*([^()]+?)\s*\)/ and $1 eq $2 and $1 !~ /^(true|false|-?\d+(?:\.\d+)?|null|undefined|""|'\'''\'')$/) {
      $why = "self-compare: expect(X).toBe(X) — comparing a value to itself";
    }
    # 3) python/junit/go literal tautology
    elsif (/^\s*assert\s+True\s*$/m or /^\s*assert\s+(-?\d+)\s*==\s*\1\s*$/m or /\bassertTrue\s*\(\s*true\s*\)/ or /\bassert\.True\s*\([^,]*,\s*true\s*\)/ or /\bassertEquals\s*\(\s*(-?\d+|true|false|"[^"]*")\s*,\s*\1\s*\)/) {
      $why = "literal tautology: assert True / assert N == N / assertTrue(true) / assert.True(t,true)";
    }
    # 4) empty test/it body — counted but no assertion
    elsif (/\b(?:it|test)\s*\(\s*(["'\''`])(?:(?!\1).)*\1\s*,\s*(?:async\s*)?\(\s*\)\s*=>\s*\{\s*\}\s*\)/s) {
      $why = "empty test body: it/test(\"...\", () => {}) is counted but asserts nothing";
    }
    # 5) skipped-but-counted (JS): it.skip/xit/fit.skip/test.skip/describe.skip with NO reason text
    #    in a leading comment on the same/prev line and NO TODO/reason inside the title-adjacent comment.
    #    We require a justification: either a // comment ON THE skip line, or text after the title that
    #    references a ticket/why. Simplest robust rule: a bare skip with only a quoted title + arrow fn.
    elsif (/(?:\b(?:x?it|x?describe|test)\.skip|\bxit|\bxdescribe)\s*\(\s*(["'\''`])((?:(?!\1).)*)\1/s) {
      my $title = $2;
      my $line = $&;
      # A justification must carry SUBSTANCE, not a bare keyword. A lone "see" / "why" / "blocked" with
      # no object is vacuous and ships a never-run test. We accept the skip as justified ONLY if it has:
      #   (a) a ticket id  [A-Z]{2,}-\d+  (JIRA-123, OPS-441), OR
      #   (b) a referenced path/file      (foo/bar, ci/nightly.yml, a *.ext), OR
      #   (c) a reason marker word FOLLOWED BY real text (>= 3 more word-chars after it), OR
      #   (d) a // or /* comment trailing the skip call that itself carries substance.
      # A long DESCRIPTIVE title (what the test does) is NOT a justification (why it is skipped); and a
      # single bare marker token (e.g. trailing " — see" with nothing after it) is NOT enough.
      my $has_ticket = ($title =~ /\b[A-Z]{2,}-\d+\b/);
      my $has_path   = ($title =~ m{[\w.-]+/[\w./-]+} or $title =~ /\b[\w-]+\.(ya?ml|md|txt|json|ts|js|py|go|rb|sh|html?|csv|sql)\b/i);
      my $marker_with_text = ($title =~ /\b(reason|because|blocked\s+on|ticket|nightly|see|todo|fixme|upstream|skip|why|waiting|pending|tracked|flaky\s+in)\b\s*[:#-]?\s+\S*\w{3,}/i);
      my $comment_sub = ($line =~ m{\.skip\s*\([^)]*\)[^\n]*(?://|/\*)\s*\S*\w{3,}});
      unless ($has_ticket or $has_path or $marker_with_text or $comment_sub) {
        $why = "skipped-but-counted: a .skip/xit with no SUBSTANTIVE reason (need a ticket id, a referenced path, or a reason marker followed by real text — a bare keyword like \"see\" does not justify a never-run test)";
      }
    }
    # 6) skipped-but-counted (pytest): @pytest.mark.skip with no reason=
    if (!$why and /\@pytest\.mark\.skip\b/) {
      # collect every skip decorator; flag if ANY lacks reason=
      while (/\@pytest\.mark\.skip\s*(\([^)]*\))?/g) {
        my $args = $1 // "";
        unless ($args =~ /\breason\s*=/) { $why = "skipped-but-counted: \@pytest.mark.skip without reason="; last; }
      }
    }
    if ($why) { print "$why\n"; exit 0; }
    END { exit 0 }
  ' "$f" 2>/dev/null)"
  if [ -n "$hit" ]; then
    add_finding "reward_hack" "$rel — $hit"
  fi
}

# Walk every test file. Capture the list first (avoid `func | grep` under pipefail), then iterate.
files="$(test_files)"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  scan_file "$f"
done <<< "$files"

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures reward-hack / always-pass assertion(s) in test files"
  echo "anti-reward-hack-gate: FAIL - $failures tautological/skipped test(s) — tests must EARN their green" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "no tautological/always-pass/skipped-but-counted assertions in test files"
echo "anti-reward-hack-gate: PASS" >&2
exit 0
