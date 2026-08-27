#!/usr/bin/env bash
# WALTEUR context-budget-gate — HARD gate. Handoff artifacts (briefs + the SUMMARY ledger) are the
# context a fresh agent inherits; bloated ones poison the next turn's reasoning. This enforces the
# "compress + keep quality" contract: each handoff artifact must stay under a token budget (~bytes/4),
# and PLAN.md must exist as the never-evict root whenever briefs are present.
#
# Applies when walteur-kit/briefs/*.md OR walteur-kit/SUMMARY.jsonl exist (handoff artifacts).
# CONTRACT: any artifact > WALTEUR_CTX_MAX tokens (default 8000) => FAIL exit 2 ·
#   briefs present but PLAN.md absent => FAIL · no handoff artifacts => NOT_APPLICABLE ·
#   PAUSED => exit 2 · bypass WALTEUR_CTXBUDGET=off.
# Report: walteur-kit/context-budget-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "context-budget-gate - HARD gate. Handoff artifacts (briefs + the SUMMARY ledger) are the"
  printf '%s\n' "usage: bash context-budget-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/context-budget-report.json - fix recipes: walteur-kit/REMEDIATION.md (## context-budget-gate)"
  printf '%s\n' "bypass: WALTEUR_CTXBUDGET=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
BRIEFS="$KIT/briefs"
SUMMARY="$KIT/SUMMARY.jsonl"
PLAN="$KIT/PLAN.md"
CTX_MAX="${WALTEUR_CTX_MAX:-8000}"
REPORT="$KIT/context-budget-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"context-budget", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"context-budget","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

# list of handoff artifacts (NUL-safe-ish: one path per line).
# RECURSIVE: briefs live in wave-namespaced subdirs (briefs/wave1/worker.md) under WALTEUR's
# parallel-wave swarm — a flat single-level glob would let a deep brief hide its bloat. We
# recurse with find (fallback: globstar) so EVERY *.md under briefs/ is measured, fail-closed.
list_artifacts() {
  [ -f "$SUMMARY" ] && printf '%s\n' "$SUMMARY"
  if [ -d "$BRIEFS" ]; then
    if have find; then
      find "$BRIEFS" -type f -name '*.md' 2>/dev/null
    else
      ( shopt -s globstar nullglob 2>/dev/null; for f in "$BRIEFS"/**/*.md "$BRIEFS"/*.md; do [ -f "$f" ] && printf '%s\n' "$f"; done )
    fi
  fi
}
applies() { [ -n "$(list_artifacts)" ]; }

# any *.md anywhere under briefs/ (recursive) => briefs are present.
briefs_present_fn() {
  [ -d "$BRIEFS" ] || return 1
  if have find; then
    [ -n "$(find "$BRIEFS" -type f -name '*.md' 2>/dev/null | head -1)" ]
  else
    ( shopt -s globstar nullglob 2>/dev/null; for f in "$BRIEFS"/**/*.md "$BRIEFS"/*.md; do [ -f "$f" ] && exit 0; done; exit 1 )
  fi
}

# bytes -> token estimate. fail-CLOSED: unreadable size => treat as over budget.
bytes_of() { wc -c < "$1" 2>/dev/null | tr -d ' \t\r'; }

# Token estimate that does NOT trust raw bytes/4 (a prose-only proxy that UNDER-counts the two
# evasions a fresh agent's context actually suffers from):
#   1. multi-byte UTF-8 (CJK/emoji): 3-4 bytes/glyph but >=2 BPE tokens => bytes/4 under-counts ~2.7x.
#   2. token-dense ASCII (JSON/code/ids/digits): ~2.4 bytes/token => bytes/4 under-counts ~1.6x.
# We take MAX(bytes/4 [keeps the prose boundary semantics], a structural BPE proxy that walks the
# decoded text: alpha-runs cost ceil(len/4), digit chars ~1 tok each, punctuation ~1 tok, and every
# non-ASCII glyph ~2 toks). MAX => fail-closed (never under-counts vs the old proxy).
# If perl is unavailable, fail CLOSED with a tighter bytes/3 proxy (non-prose ratio) instead of bytes/4.
tokens_of() {
  local f="$1" est
  if have perl; then
    est="$(perl -CSD -e '
      use Encode;
      local $/; open(my $fh, "<:raw", $ARGV[0]) or exit 3; my $raw = <$fh>;
      $raw = "" unless defined $raw;
      my $b = length($raw);
      my $txt = Encode::decode("UTF-8", $raw, Encode::FB_DEFAULT);
      my $toks = 0;
      while (length($txt)) {
        if    ($txt =~ s/^([A-Za-z]+)//)   { $toks += int((length($1)+3)/4); }
        elsif ($txt =~ s/^([0-9]+)//)      { $toks += length($1); }
        elsif ($txt =~ s/^(\s+)//)         { }
        elsif ($txt =~ s/^([\x00-\x7F])//) { $toks += 1; }
        else  { $txt =~ s/^.//; $toks += 2; }
      }
      my $prose = int($b/4);
      print( ($prose > $toks ? $prose : $toks), "\n" );
    ' "$f" 2>/dev/null)"
    case "$est" in ''|*[!0-9]*) est="";; esac
    if [ -n "$est" ]; then printf '%s\n' "$est"; return 0; fi
    return 1   # perl present but failed (unreadable/decode error) => fail-closed
  fi
  # no perl: tighter non-prose proxy bytes/3 (still fail-closed vs the old bytes/4).
  local b; b="$(bytes_of "$f")"
  case "$b" in ''|*[!0-9]*) return 1;; esac
  printf '%s\n' "$(( b / 3 ))"
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  echo "context-budget-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  mkbrief() { mkdir -p "$1/walteur-kit/briefs"; printf 'wave-1 worker brief: build the auth module.\n' > "$1/walteur-kit/briefs/w1.md"; }
  mkplan()  { mkdir -p "$1/walteur-kit"; printf '# PLAN\n- task A\n- task B\n' > "$1/walteur-kit/PLAN.md"; }
  # fill a file to ~N tokens => ~4N bytes
  fill() { c="$2"; b=$((c*4)); head -c "$b" /dev/zero 2>/dev/null | tr '\0' 'x' > "$1"; }

  # 1. no handoff artifacts -> NOT_APPLICABLE (exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no artifacts -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. FALSE-POSITIVE GUARD: small briefs + PLAN.md present -> PASS (clean fixture must pass)
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkbrief "$t"; mkplan "$t"; ck "clean: small briefs + PLAN -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. FALSE-POSITIVE GUARD: small SUMMARY.jsonl alone (no briefs) -> PASS (PLAN not required w/o briefs)
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"task":"a","status":"done"}\n{"task":"b","status":"done"}\n' > "$t/walteur-kit/SUMMARY.jsonl"; ck "clean: small SUMMARY alone -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 4. POISONED: a brief over budget -> FAIL (twin of case 2)
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkbrief "$t"; mkplan "$t"; fill "$t/walteur-kit/briefs/w1.md" 9000; ck "poisoned: oversize brief -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. POISONED: SUMMARY.jsonl over budget -> FAIL (twin of case 3)
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkdir -p "$t/walteur-kit"; fill "$t/walteur-kit/SUMMARY.jsonl" 9000; ck "poisoned: oversize SUMMARY -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. POISONED: briefs present but PLAN.md absent -> FAIL (never-evict root missing)
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkbrief "$t"; ck "briefs present, no PLAN -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. boundary: brief exactly at budget (CTX_MAX tokens) -> PASS (<= is ok)
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkbrief "$t"; mkplan "$t"; fill "$t/walteur-kit/briefs/w1.md" 8000; ck "boundary: exactly at budget -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 8. boundary: one token over budget -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkbrief "$t"; mkplan "$t"; fill "$t/walteur-kit/briefs/w1.md" 8001; ck "boundary: one token over -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. custom budget via WALTEUR_CTX_MAX -> small brief now over a tiny budget -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkbrief "$t"; mkplan "$t"; ck "custom budget too small -> FAIL" 2 "$(WALTEUR_ROOT="$t" WALTEUR_CTX_MAX=2 bash "$0" >/dev/null 2>&1; echo $?)"; rm -rf "$t"
  # 10. bypass -> exit 0 even when over budget
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkbrief "$t"; mkplan "$t"; fill "$t/walteur-kit/briefs/w1.md" 9000; WALTEUR_ROOT="$t" WALTEUR_CTXBUDGET=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  # 11. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkbrief "$t"; mkplan "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ---- G# regressions: 3 PROVEN false-negatives a red-team gauntlet found (each must now FAIL exit 2) ----

  # G1. ENCODING evasion: a brief of 10000 CJK glyphs (U+6F22) = 30001 bytes => old bytes/4 = 7500 (PASS),
  #     but ~20001 REAL tokens (each 3-byte glyph >=2 BPE tokens). Encoding-aware estimate must FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkbrief "$t"; mkplan "$t"
  one=$'\xe6\xbc\xa2'; chunk=""; for i in $(seq 1 100); do chunk="$chunk$one"; done
  { for i in $(seq 1 100); do printf '%s' "$chunk"; done; printf '\n'; } > "$t/walteur-kit/briefs/w1.md"
  ck "G1 CJK encoding evasion (bytes/4 under-counts) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G1b. FALSE-POSITIVE GUARD: a SMALL multi-byte brief (a little CJK) must still PASS (not over budget).
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkbrief "$t"; mkplan "$t"
  printf '%s\n' "wave-1 brief: 漢字 build the auth module 認証." > "$t/walteur-kit/briefs/w1.md"
  ck "G1b small multibyte brief -> PASS (no false-positive)" 0 "$(run "$t")"; rm -rf "$t"

  # G2. SHAPE evasion: a 160000-byte (~40000-token) brief hidden one level deep at briefs/wave1/worker.md.
  #     Non-recursive glob never saw it; recursive enumeration must measure it => FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkdir -p "$t/walteur-kit/briefs/wave1"; mkplan "$t"
  printf 'wave-1 index brief: workers under briefs/wave1/\n' > "$t/walteur-kit/briefs/index.md"
  fill "$t/walteur-kit/briefs/wave1/worker.md" 40000
  ck "G2 oversize brief in briefs/wave1/ subdir -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G2b. FALSE-POSITIVE GUARD: SMALL briefs in a subdir (recursive scan) must still PASS, and PLAN-root
  #      requirement must trigger off a subdir-only brief too.
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkdir -p "$t/walteur-kit/briefs/wave1"; mkplan "$t"
  printf 'small wave-1 worker brief\n' > "$t/walteur-kit/briefs/wave1/worker.md"
  ck "G2b small subdir brief + PLAN -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # G3. DENSITY evasion: a token-dense SUMMARY.jsonl ~31874 ascii bytes => old bytes/4 = 7968 (PASS),
  #     but ~13136 REAL tokens (distinct ids/digits/JSON punctuation ~2.4 bytes/token). Density-aware FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/contextbud.XXXXXX")"; mkdir -p "$t/walteur-kit/briefs"; mkplan "$t"
  printf 'wave-2 brief: implement T-7.\n' > "$t/walteur-kit/briefs/w2.md"
  awk 'BEGIN{t=0;n=0;L=31900; while(1){s=sprintf("{\"task\":\"T-%d\",\"st\":\"ok\"}",n); if(t+length(s)+1>L)break; printf "%s\n",s; t+=length(s)+1; n++}}' > "$t/walteur-kit/SUMMARY.jsonl"
  ck "G3 token-dense SUMMARY.jsonl (bytes/4 under-counts) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  echo "context-budget-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_CTXBUDGET:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_CTXBUDGET=off"; echo "context-budget-gate: bypassed." >&2; exit 0; }

if ! applies; then write_report "NOT_APPLICABLE" "no handoff artifacts (no briefs/*.md, no SUMMARY.jsonl)"; echo "context-budget-gate: NOT_APPLICABLE"; exit 0; fi

# coerce budget to an integer; fail-CLOSED on an unparseable budget (treat as 0 => everything over).
max="$(printf '%s' "$CTX_MAX" | grep -oE '^[0-9]+' | head -1)"; max="${max:-0}"

# PLAN.md is the never-evict root: required whenever briefs exist (recursive scan).
briefs_present=no
briefs_present_fn && briefs_present=yes
if [ "$briefs_present" = "yes" ] && [ ! -f "$PLAN" ]; then
  add_finding "plan-root" "briefs/ exist but walteur-kit/PLAN.md is absent — the never-evict root must be present so a fresh agent can re-anchor"
fi

# per-artifact budget check (token estimate is encoding-aware + dense-content-aware, not raw bytes/4)
while IFS= read -r art; do
  [ -n "$art" ] || continue
  rel="${art#$ROOT/}"
  b="$(bytes_of "$art")"
  toks="$(tokens_of "$art")"
  # fail-CLOSED: if we cannot measure size OR tokens, treat the artifact as over budget.
  case "$b" in ''|*[!0-9]*) add_finding "$rel" "could not measure artifact size — treating as over budget (fail-closed)"; continue;; esac
  case "$toks" in ''|*[!0-9]*) add_finding "$rel" "could not estimate artifact tokens — treating as over budget (fail-closed)"; continue;; esac
  if [ "$toks" -gt "$max" ]; then
    add_finding "$rel" "~${toks} tokens (encoding/density-aware estimate; ${b} bytes) exceeds budget of ${max} tokens — compress this handoff artifact"
  fi
done < <(list_artifacts)

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures context-budget violation(s)"
  echo "context-budget-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "every handoff artifact within the ${max}-token budget; PLAN.md root present when briefs exist"
echo "context-budget-gate: PASS" >&2
exit 0
