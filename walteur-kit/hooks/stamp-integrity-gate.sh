#!/usr/bin/env bash
# WALTEUR stamp-integrity-gate — HARD gate (v10.2). Protects the immutable certification ledger.
#
# STAMP.md is the permanent score-of-record (written by stamp.sh). This gate guarantees it can be
# RE-STAMPED (score updates, history grows) but NEVER deleted, and no historical row ever removed or
# altered. Each history row's sha256 is recorded in walteur-kit/stamp-chain.json; this gate re-hashes the
# live STAMP.md rows and FAILs closed on any divergence. The "Current" score block is intentionally NOT
# chained, so re-stamping the score is allowed; the dated history is immutable.
#
# CONTRACT:
#   · stamp-chain.json absent or no rows      => NOT_APPLICABLE exit 0 (never stamped yet).
#   · stamp-chain.json has rows but STAMP.md missing => FAIL exit 2 (the ledger must never be deleted).
#   · any chained row id missing from STAMP.md => FAIL (row deleted).
#   · any chained row's live sha256 != recorded => FAIL (row altered).
#   · live history-row count < chained count   => FAIL.
#   PAUSED => exit 2 · bypass WALTEUR_STAMP=off => loud SKIP.
# Zero-dep: bash + jq + sha256sum/shasum. Report: walteur-kit/stamp-integrity-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "stamp-integrity-gate - HARD gate (v10.2). Protects the immutable certification ledger."
  printf '%s\n' "usage: bash stamp-integrity-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/stamp-integrity-report.json - fix recipes: walteur-kit/REMEDIATION.md (## stamp-integrity-gate)"
  printf '%s\n' "bypass: WALTEUR_STAMP=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STAMP="$ROOT/STAMP.md"
CHAIN="$ROOT/walteur-kit/stamp-chain.json"
REPORT="$ROOT/walteur-kit/stamp-integrity-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$ROOT/walteur-kit"
have() { command -v "$1" >/dev/null 2>&1; }
sha() { if have sha256sum; then sha256sum | awk '{print $1}'; elif have shasum; then shasum -a 256 | awk '{print $1}'; else cksum | awk '{print $1}'; fi; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"stamp-integrity", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","reason":"%s"}\n' "$v" "$r" > "$REPORT" 2>/dev/null || true; }

# extract the exact STAMP.md row line for a given id (e.g. "- S001 | ...")
row_for() { grep -E "^- $1 \| " "$STAMP" 2>/dev/null | head -1; }

main() {
  [ -f "$ROOT/walteur-kit/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused; echo "stamp-integrity-gate: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_STAMP:-}" = "off" ] && { write_report SKIP "bypassed via WALTEUR_STAMP=off"; echo "stamp-integrity-gate: SKIP — WALTEUR_STAMP=off (loud skip)" >&2; exit 0; }
  if ! have jq; then write_report SKIP "jq not installed"; echo "stamp-integrity-gate: SKIP (no jq)" >&2; exit 0; fi
  local nrows
  nrows="$( [ -f "$CHAIN" ] && jq '.rows | length' "$CHAIN" 2>/dev/null || echo 0)"
  if [ "${nrows:-0}" -eq 0 ]; then
    write_report NOT_APPLICABLE "no stamp chain yet (never stamped)"; echo "stamp-integrity-gate: NOT_APPLICABLE (no stamps)" >&2; exit 0
  fi

  if [ ! -f "$STAMP" ]; then
    add_finding deleted "STAMP.md is missing but stamp-chain.json has $nrows row(s) — the certification ledger must NEVER be deleted"
    write_report FAIL "stamp ledger deleted"; echo "stamp-integrity-gate: FAIL (ledger deleted) -> exit 2" >&2; exit 2
  fi

  local i=0 id want got
  while [ "$i" -lt "$nrows" ]; do
    id="$(jq -r ".rows[$i].id" "$CHAIN")"
    want="$(jq -r ".rows[$i].sha256" "$CHAIN")"
    local line; line="$(row_for "$id")"
    if [ -z "$line" ]; then
      add_finding "row.$id" "history row $id is recorded in the chain but missing from STAMP.md — rows are immutable, never delete one"
    else
      got="$(printf '%s' "$line" | sha)"
      [ "$got" != "$want" ] && add_finding "row.$id" "history row $id was ALTERED (sha mismatch) — stamp rows are immutable"
    fi
    i=$((i+1))
  done

  local live; live="$(grep -cE '^- S[0-9]+ \| ' "$STAMP" 2>/dev/null || echo 0)"
  [ "${live:-0}" -lt "$nrows" ] && add_finding count "STAMP.md has $live history rows but the chain recorded $nrows — a row was removed"

  if [ "$failures" -gt 0 ]; then
    write_report FAIL "$failures stamp-integrity violation(s)"
    echo "stamp-integrity-gate: FAIL ($failures) -> exit 2" >&2
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null | head -15 >&2 || true
    exit 2
  fi
  write_report PASS "$nrows stamp row(s) intact + ledger present"
  echo "stamp-integrity-gate: PASS ($nrows immutable stamp(s) intact)" >&2
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "stamp-integrity selftest SKIP — need jq."; return 0; fi
  local STAMPER; STAMPER="$(dirname "$SELF")/stamp.sh"
  if [ ! -f "$STAMPER" ]; then echo "stamp-integrity selftest SKIP — stamp.sh not found."; return 0; fi
  echo "stamp-integrity-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  mkstamp() { mkdir -p "$1/walteur-kit"; printf '{"verdict":"PASS","ts":"%s","gate":"gate-suite","total":10,"green":10}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$1/walteur-kit/gate-suite-report.json"; WALTEUR_ROOT="$1" WALTEUR_STAMP_SAMPLE=0 bash "$STAMPER" "$2" "$3" "$4" "$5" >/dev/null 2>&1; }

  # 1. no chain -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/stampinteg.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no chain -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. GOOD: one stamp, intact -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/stampinteg.XXXXXX")"; mkstamp "$t" "baseline" 45 127 "gate-suite PASS"; ck "intact single stamp -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. POISONED: STAMP.md deleted -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/stampinteg.XXXXXX")"; mkstamp "$t" "baseline" 45 127 "p"; rm -f "$t/STAMP.md"; ck "ledger deleted -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. POISONED: a history row removed -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/stampinteg.XXXXXX")"; mkstamp "$t" "baseline" 45 127 "p"; grep -v '^- S001 | ' "$t/STAMP.md" > "$t/STAMP.md.tmp" && mv "$t/STAMP.md.tmp" "$t/STAMP.md"; ck "row removed -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. POISONED: a history row altered (score tampered) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/stampinteg.XXXXXX")"; mkstamp "$t" "baseline" 45 127 "p"; perl -i -pe 's/score=45/score=99/' "$t/STAMP.md"; ck "row altered -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. GOOD: append a 2nd stamp -> PASS (history grows legitimately)
  t="$(mktemp -d "${TMPDIR:-/tmp}/stampinteg.XXXXXX")"; mkstamp "$t" "baseline" 45 127 "p"; mkstamp "$t" "phase1" 52 128 "teeth"; ck "two stamps appended -> PASS" 0 "$(run "$t")"; n2="$(jq '.rows|length' "$t/walteur-kit/stamp-chain.json")"; ck "chain has 2 rows" 2 "$n2"; rm -rf "$t"
  # 7. GOOD: edit ONLY the Current block (allowed) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/stampinteg.XXXXXX")"; mkstamp "$t" "baseline" 45 127 "p"; perl -i -pe 's{^- score:.*}{- score: 999/100 (manual current edit)}' "$t/STAMP.md"; ck "current-block edit allowed -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 8. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/stampinteg.XXXXXX")"; mkstamp "$t" "baseline" 45 127 "p"; rm -f "$t/STAMP.md"; WALTEUR_ROOT="$t" WALTEUR_STAMP=off bash "$SELF" >/dev/null 2>&1; ck "bypass WALTEUR_STAMP=off -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/stampinteg.XXXXXX")"; mkstamp "$t" "baseline" 45 127 "p"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "stamp-integrity-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
