#!/usr/bin/env bash
# WALTEUR blast-radius-gate — HARD gate. Closes the 80% cross-cutting-miss gap: an edit touches a
# shared/cross-cutting symbol (a util, a base class, an env reader, a shared type) and the build never
# checks who CALLS it, so a "local" change silently breaks N callers. This gate requires that every
# cross-cutting symbol an edit touched recorded callers_checked:true AND a non-empty impact assessment.
#
# Applies when walteur-kit/blast-radius.json exists OR preflight-signals.json .is_brownfield==true.
# CONTRACT: any edit with callers_checked!=true or empty impact => FAIL exit 2 · is_brownfield but no
# blast-radius.json at high/regulated risk => FAIL · greenfield with no manifest => NOT_APPLICABLE ·
# jq absent => fail-CLOSED FAIL when applicable · PAUSED => exit 2 · bypass WALTEUR_BLASTRADIUS=off.
# Report: walteur-kit/blast-radius-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "blast-radius-gate - HARD gate. Closes the 80% cross-cutting-miss gap: an edit touches a"
  printf '%s\n' "usage: bash blast-radius-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/blast-radius-report.json - fix recipes: walteur-kit/REMEDIATION.md (## blast-radius-gate)"
  printf '%s\n' "bypass: WALTEUR_BLASTRADIUS=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
MANIFEST="${WALTEUR_BLASTRADIUS_FILE:-$KIT/blast-radius.json}"
REPORT="$KIT/blast-radius-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"blast-radius", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"blast-radius","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }
brownfield() { [ -f "$SIGNALS" ] && have jq && jq -e '.is_brownfield==true' "$SIGNALS" >/dev/null 2>&1; }
applies() { [ -f "$MANIFEST" ] && return 0; brownfield; }

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "blast-radius selftest SKIP - jq not installed."; return 0; fi
  echo "blast-radius-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  # brownfield signal at a given risk tier
  brown() { mkdir -p "$1/walteur-kit"; printf '{"is_brownfield":true}\n' > "$1/walteur-kit/preflight-signals.json"; printf '{"risk_tier":"%s"}\n' "${2:-high}" > "$1/walteur-kit/build-contract.json"; }
  # a clean, fully-checked manifest (the false-positive guard fixture)
  goodman() { jq -n '{edits:[{symbol:"shared/config.readEnv",callers_checked:true,impact:"3 callers in api/* re-read at boot; verified all tolerate the new default"},{symbol:"core/BaseRepo.save",callers_checked:true,impact:"no behavior change, signature stable; 12 subclasses unaffected"}]}' > "$1/walteur-kit/blast-radius.json"; }

  # 1. greenfield, no manifest -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"is_brownfield":false}\n' > "$t/walteur-kit/preflight-signals.json"; ck "greenfield, no manifest -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. FALSE-POSITIVE GUARD: clean fully-checked manifest -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high; goodman "$t"; ck "clean manifest (every edit checked) -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. brownfield high-risk, NO manifest -> FAIL (the 80% gap, unrecorded)
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high; ck "brownfield high-risk, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. POISONED: an edit with callers_checked=false -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high; goodman "$t"; jq '.edits[1].callers_checked=false' "$t/walteur-kit/blast-radius.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/blast-radius.json"; ck "edit callers_checked=false -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. POISONED: an edit with empty impact -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high; goodman "$t"; jq '.edits[0].impact=""' "$t/walteur-kit/blast-radius.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/blast-radius.json"; ck "edit empty impact -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. POISONED: callers_checked missing entirely (defaults false) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high; goodman "$t"; jq 'del(.edits[0].callers_checked)' "$t/walteur-kit/blast-radius.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/blast-radius.json"; ck "edit callers_checked missing -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. POISONED: impact whitespace-only -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high; goodman "$t"; jq '.edits[1].impact="   "' "$t/walteur-kit/blast-radius.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/blast-radius.json"; ck "edit whitespace-only impact -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. manifest present but edits not an array -> FAIL (fail-closed on malformed)
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high; printf '{"edits":"checked them all, trust me"}\n' > "$t/walteur-kit/blast-radius.json"; ck "edits not an array -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. manifest present, empty edits array -> FAIL (must enumerate, fail-closed)
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high; printf '{"edits":[]}\n' > "$t/walteur-kit/blast-radius.json"; ck "empty edits array -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10. brownfield LOW-risk, no manifest -> NOT_APPLICABLE (high/regulated floor only)
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" low; ck "brownfield low-risk, no manifest -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 11. brownfield REGULATED, no manifest -> FAIL (regulated is above the floor)
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" regulated; ck "brownfield regulated, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 12. clean manifest even at low risk -> PASS (manifest presence => evaluate)
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" low; goodman "$t"; ck "clean manifest at low risk -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 13. bypass -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high; WALTEUR_ROOT="$t" WALTEUR_BLASTRADIUS=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  # 14. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high; goodman "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # 15. REGRESSION (NBSP evasion): impact is three U+00A0 non-breaking spaces (NOT ASCII whitespace) -> FAIL.
  #     `tr -d '[:space:]'` is ASCII-only so this used to read as non-empty and PASS. Strip Unicode WS too.
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high
  printf '{"edits":[{"symbol":"shared/config.readEnv","callers_checked":true,"impact":"\xc2\xa0\xc2\xa0\xc2\xa0","impact_notes":"NOT DONE - callers NOT verified"}]}\n' > "$t/walteur-kit/blast-radius.json"
  ck "impact = U+00A0 non-breaking spaces -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 16. REGRESSION (duplicate-key evasion): manifest declares "edits" twice; jq keeps the LAST (benign) array
  #     and parses away the dangerous first. A duplicate key is malformed => reject fail-closed.
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high
  printf '{\n  "edits": [ { "symbol": "shared/auth.verifyToken", "callers_checked": false, "impact": "" } ],\n  "edits": [ { "symbol": "docs/typo-fix.md", "callers_checked": true, "impact": "doc-only string fix in docs/typo-fix.md, no callers" } ]\n}\n' > "$t/walteur-kit/blast-radius.json"
  ck "duplicate 'edits' key -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 17. REGRESSION (semantic/vacuous evasion): all fields present & well-typed but impact is a tautological lie
  #     ("no impact expected / should be safe") with zero caller-graph evidence -> FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high
  printf '{"edits":[{"symbol":"shared/auth.parseToken","callers_checked":true,"impact":"Looks fine. No impact expected. Should be safe - callers will adapt."}]}\n' > "$t/walteur-kit/blast-radius.json"
  ck "vacuous filler impact (no caller evidence) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 18. FALSE-POSITIVE GUARD for the substance check: a real impact whose only whitespace is a leading NBSP
  #     but which DOES cite caller-graph evidence (path token + caller count) -> PASS (not over-blocked).
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high
  printf '{"edits":[{"symbol":"shared/config.readEnv","callers_checked":true,"impact":"\xc2\xa0verified 7 callers in api/* re-read at boot; all tolerate the new default"}]}\n' > "$t/walteur-kit/blast-radius.json"
  ck "substanceful impact with NBSP padding -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 19. malformed JSON / multi-doc stream (two concatenated objects) -> FAIL (single-object rule, fail-closed)
  t="$(mktemp -d "${TMPDIR:-/tmp}/blastradiu.XXXXXX")"; brown "$t" high
  printf '{"edits":[{"symbol":"a/b","callers_checked":true,"impact":"3 callers in a/b checked"}]}\n{"edits":[]}\n' > "$t/walteur-kit/blast-radius.json"
  ck "multi-doc JSON stream -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  echo "blast-radius-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_BLASTRADIUS:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_BLASTRADIUS=off"; echo "blast-radius-gate: bypassed." >&2; exit 0; }

RISK="$(risk)"

if ! applies; then write_report "NOT_APPLICABLE" "greenfield (is_brownfield!=true) and no blast-radius.json"; echo "blast-radius-gate: NOT_APPLICABLE"; exit 0; fi

# jq is required to evaluate the manifest. When the gate applies, no jq means we cannot prove safety -> fail CLOSED.
if ! have jq; then
  write_report "FAIL" "blast-radius gate applies but jq is unavailable — cannot evaluate caller-impact, failing closed"
  echo "blast-radius-gate: FAIL - jq unavailable (fail-closed)" >&2; exit 2
fi

# Manifest absent path: only HARD at high/regulated; below the floor it is NOT_APPLICABLE.
if [ ! -s "$MANIFEST" ]; then
  case "$RISK" in
    high|regulated)
      add_finding "manifest" "brownfield build at $RISK risk but no walteur-kit/blast-radius.json — for every edit touching a cross-cutting symbol, record callers_checked:true and a non-empty impact assessment"
      write_report "FAIL" "brownfield blast-radius manifest absent at $RISK risk"
      echo "blast-radius-gate: FAIL - manifest absent ($RISK risk)" >&2; exit 2 ;;
    *)
      write_report "NOT_APPLICABLE" "no blast-radius.json and risk_tier=$RISK below the high/regulated floor"
      echo "blast-radius-gate: NOT_APPLICABLE ($RISK risk)"; exit 0 ;;
  esac
fi

# Manifest present: it MUST parse as exactly ONE valid JSON object (no stream / multi-doc / array wrapper).
# `jq -s 'length==1'` over the slurped input forces a single document; a stream or concatenated docs => length!=1.
if ! jq -e -s 'length==1 and (.[0]|type=="object")' "$MANIFEST" >/dev/null 2>&1; then
  add_finding "manifest" "blast-radius.json must be a single JSON object — not a stream, multiple documents, or a top-level array"
  write_report "FAIL" "blast-radius.json is not a single JSON object (stream/multi-doc/array)"
  echo "blast-radius-gate: FAIL - manifest not a single object" >&2; exit 2
fi

# DUPLICATE-KEY DEFENSE (fail CLOSED): jq silently keeps the LAST of any duplicated key, so a manifest that
# declares "edits" (or any key) twice can hide the dangerous array behind a benign one. `jq --stream` re-emits
# the SAME leaf path for every occurrence, so a duplicated key produces a duplicated leaf path. ANY duplicate
# leaf path => malformed manifest => reject. (Legitimate multi-edit manifests use distinct array indices, so
# their leaf paths stay unique.)
dupkey="$(jq -c --stream 'select(length==2) | .[0]' "$MANIFEST" 2>/dev/null | sort | uniq -d | head -1)"
if [ -n "$dupkey" ]; then
  add_finding "manifest" "blast-radius.json contains a DUPLICATE key (path $dupkey) — duplicate keys let a checked edit mask an unchecked one; rewrite with unique keys"
  write_report "FAIL" "blast-radius.json contains duplicate key(s) — rejected fail-closed"
  echo "blast-radius-gate: FAIL - duplicate key in manifest ($dupkey)" >&2; exit 2
fi

# It MUST be a non-empty array of edits. Malformed/empty => fail CLOSED.
if ! jq -e '.edits | type=="array" and length>=1' "$MANIFEST" >/dev/null 2>&1; then
  add_finding "edits" "blast-radius.json must list >=1 edit in an 'edits' array — each with symbol, callers_checked, impact"
  write_report "FAIL" "blast-radius.json edits missing, empty, or not an array"
  echo "blast-radius-gate: FAIL - edits malformed" >&2; exit 2
fi

# Unicode-aware whitespace/zero-width/BOM character class for the non-empty check. `tr -d '[:space:]'` is
# ASCII-only in the C locale, so a U+00A0 NBSP (or figure-space, narrow-NBSP, ideographic space, BOM, zero-
# width joiner, etc.) survives and reads as "non-empty". jq accepts \uXXXX escapes; \p{Z} does NOT compile in
# jq 1.8.x string literals, so the codepoints are enumerated explicitly.
WS_CLASS='\u0009\u000a\u000b\u000c\u000d\u0020\u0085\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\u200b\u200c\u200d\u2060\ufeff'
# SUBSTANCE predicate (closes the SEMANTIC hole): a non-empty impact must ALSO show evidence of a real
# caller-graph review — a module/path token, a code filename, or a digit tied to a caller noun — and must not
# be a known vacuous filler ("no impact", "should be safe", "n/a", ...). A bare non-empty string is NOT proof.
SUBSTANCE_JQ='(.impact // "") | (if type=="string" then . else "" end) | ascii_downcase | gsub("['"$WS_CLASS"']";" ") | gsub("[ ]+";" ") | gsub("^ +| +$";"") as $s | (($s=="n/a" or $s=="na" or $s=="tbd" or $s=="none" or $s=="-" or $s=="" or $s=="no impact" or $s=="no callers" or $s=="should be safe" or $s=="looks fine" or $s=="all good" or $s=="trust me") | not) and (($s | test("[a-z0-9_*.-]{2,}/[a-z0-9_.*-]+")) or ($s | test("[.](js|jsx|ts|tsx|mjs|cjs|mts|cts|py|go|rb|java|rs|php|cs|kt|swift|scala|cc|cpp|hpp)([^a-z]|$)")) or ($s | test("[0-9]+ *(caller|callers|call ?site|call ?sites|subclass|subclasses|consumer|consumers|usage|usages|reference|references|dependent|dependents|import|imports|site|sites)")))'

idx=-1
while IFS= read -r ed; do
  [ -n "$ed" ] || continue
  idx=$((idx+1))
  sym="$(printf '%s' "$ed" | jq -r '.symbol // ""')"
  label="${sym:-edit#$idx}"
  # callers_checked must be the boolean true; anything else (false, missing, "true" string, null) fails CLOSED.
  chk="$(printf '%s' "$ed" | jq -r 'if (.callers_checked == true) then "yes" else "no" end' 2>/dev/null || echo no)"
  # impact must be a non-empty string AFTER Unicode-whitespace normalization (not just ASCII).
  imp_trimmed="$(printf '%s' "$ed" | jq -r '(.impact // "") | (if type=="string" then . else "" end) | gsub("['"$WS_CLASS"']";"")' 2>/dev/null || echo "")"
  # ...and it must carry SEMANTIC substance, not vacuous filler.
  sub="$(printf '%s' "$ed" | jq -r "if ($SUBSTANCE_JQ) then \"yes\" else \"no\" end" 2>/dev/null || echo no)"
  [ -n "$sym" ] || add_finding "$label.symbol" "edit #$idx has no symbol — name the cross-cutting symbol it touched"
  [ "$chk" = "yes" ] || add_finding "$label.callers_checked" "callers_checked is not true — find and verify every caller of '$label' before this edit ships (the cross-cutting-miss gap)"
  if [ -z "$imp_trimmed" ]; then
    add_finding "$label.impact" "impact assessment is empty (after Unicode-whitespace normalization) — record what the caller-graph review concluded for '$label'"
  elif [ "$sub" != "yes" ]; then
    add_finding "$label.impact" "impact assessment is vacuous filler for '$label' — cite the actual caller-graph evidence (the caller paths/files you checked or a caller count like '7 callers in api/*'), not a tautology like 'no impact / should be safe'"
  fi
done < <(jq -c '.edits[]?' "$MANIFEST" 2>/dev/null)

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures blast-radius violation(s)"
  echo "blast-radius-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "every edit recorded callers_checked:true and a non-empty impact assessment"
echo "blast-radius-gate: PASS" >&2
exit 0
