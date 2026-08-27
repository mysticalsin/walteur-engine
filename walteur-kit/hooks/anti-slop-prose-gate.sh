#!/usr/bin/env bash
# WALTEUR anti-slop-prose-gate — HARD gate (intake: hardikpandya/stop-slop, MIT). WALTEUR already fails AI-slop
# in CODE (anti-slop-code) and UI (anti-slop-ui); user-facing PROSE was unguarded. A $50-100M product ships
# landing copy, onboarding, empty/error microcopy, release notes and in-app email that read like a human wrote
# them — not ChatGPT throat-clearing ("Here's the thing:"), telegraphed binary contrasts ("it's not X, it's
# Y"), false agency ("the data tells us"), or meta-commentary ("let me walk you through"). This gate scans the
# DESIGNATED copy surface against a high-precision slop denylist ported from stop-slop and FAILs on hits.
#
# Scope is precise to avoid false-firing on technical docs: it scans only user-facing COPY (paths under
# copy/ content/ marketing/ landing/ onboarding/ microcopy/ emails/ + files listed in walteur-kit/copy-manifest.json),
# never code, internal docs, tests, or walteur-kit. Per-line override: append  <!-- slop-ok -->  (or  // slop-ok ).
# Applies when a copy surface exists. CONTRACT: slop hit over threshold => FAIL exit 2 · no copy surface =>
# NOT_APPLICABLE · PAUSED => exit 2 · bypass WALTEUR_PROSESLOP=off · tunable WALTEUR_PROSESLOP_MAX (default 0).
# Report: walteur-kit/anti-slop-prose-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "anti-slop-prose-gate - HARD gate (intake: hardikpandya/stop-slop, MIT). WALTEUR already fails AI-slop"
  printf '%s\n' "usage: bash anti-slop-prose-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/anti-slop-prose-report.json - fix recipes: walteur-kit/REMEDIATION.md (## anti-slop-prose-gate)"
  printf '%s\n' "bypass: WALTEUR_PROSESLOP=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
MANIFEST="$KIT/copy-manifest.json"
REPORT="$KIT/anti-slop-prose-report.json"
MAXHITS="${WALTEUR_PROSESLOP_MAX:-0}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"anti-slop-prose", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"anti-slop-prose","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

# Copy surface: files under a user-facing copy path, OR listed in copy-manifest.json. Never code/internal.
copy_files() {
  if [ -f "$MANIFEST" ] && have jq; then
    jq -r '.files[]? // empty' "$MANIFEST" 2>/dev/null | while IFS= read -r rel; do [ -f "$ROOT/$rel" ] && printf '%s\n' "$ROOT/$rel"; done
  fi
  command -v find >/dev/null 2>&1 || return 0
  find "$ROOT" -type d \( -name node_modules -o -name .git -o -name walteur-kit -o -name .claude -o -name dist -o -name build -o -name tests -o -name __tests__ \) -prune -o \
    -type f \( -name '*.md' -o -name '*.mdx' -o -name '*.html' -o -name '*.txt' \) -print 2>/dev/null | \
    grep -iE '/(copy|content|marketing|landing|onboarding|microcopy|emails?|release-notes)/' 2>/dev/null
}

applies() { [ -n "$(copy_files | head -1)" ]; }

# High-precision slop signatures (PCRE via perl -0777 per line; grep -P is locale-broken on Git-Bash). Only the
# UNAMBIGUOUS tells — fuzzy single adverbs ("just"/"really") are NOT hard-failed (too common in legit copy).
# Each entry: "label|||perl-regex" (case-insensitive, anchored where it matters).
SIGS=(
  "throat-clearing-opener|||(^|[.!?]\s+)(here\x27s (the thing|what|why|this|that)|the uncomfortable truth is|it turns out|let me be clear|the truth is|make no mistake|let that sink in|at the end of the day|in a world where|in today\x27s|at its core|when it comes to)\b"
  "binary-contrast|||\b(it\x27?s not |it is not |isn\x27?t |not just |the answer is ?n.?.?t |the question is ?n.?.?t )[^.?!]{1,70}?(\bit\x27?s\b|\bit is\b|\bbut\b)"
  "false-agency|||\b(the (data|market|culture|conversation|decision|complaint))\s+(tells us|rewards|shifts|moves|emerges|becomes|lives or dies)\b"
  "meta-commentary|||\b(let me walk you through|in this section,? we\x27?ll|as we\x27?ll see|here\x27s what i mean|plot twist:|spoiler:)\b"
  "emphasis-crutch|||(^|\s)(full stop\.|period\.|this matters because\b|here\x27s why that matters\b)"
)

scan_file() {
  local f="$1" rel; rel="$(printf '%s' "$f" | sed "s#$ROOT/##")"
  have perl || return 0
  local sig label re hit
  for sig in "${SIGS[@]}"; do
    label="${sig%%|||*}"; re="${sig##*|||}"
    # find first matching line that does NOT carry an override marker
    hit="$(re="$re" perl -0777 -ne '
      my $re = $ENV{re};
      for my $ln (split /\n/, $_) {
        next if $ln =~ /(slop-ok|<!--\s*slop-ok|\/\/\s*slop-ok)/i;
        if ($ln =~ /$re/i) { print $ln; last; }
      }' "$f" 2>/dev/null)"
    [ -n "$hit" ] && add_finding "$rel" "$label: \"$(printf '%s' "$hit" | sed 's/^[[:space:]]*//' | cut -c1-90)\" — write it plainly (override on the line with <!-- slop-ok --> if intentional)"
  done
}

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused; echo "anti-slop-prose-gate: PAUSED -> exit 2"; exit 2; }
  [ "${WALTEUR_PROSESLOP:-}" = "off" ] && { write_report SKIP "bypassed"; echo "anti-slop-prose-gate: bypassed"; exit 0; }
  if ! applies; then write_report NOT_APPLICABLE "no user-facing copy surface (copy/ content/ marketing/ landing/ onboarding/ or copy-manifest.json)"; echo "anti-slop-prose-gate: NOT_APPLICABLE"; exit 0; fi
  local f
  while IFS= read -r f; do [ -n "$f" ] && scan_file "$f"; done < <(copy_files | sort -u)
  if [ "$failures" -gt "$MAXHITS" ]; then
    write_report FAIL "$failures prose-slop hit(s) over threshold $MAXHITS"
    echo "anti-slop-prose-gate: FAIL ($failures slop hits) -> exit 2"
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null | head -20 || true
    exit 2
  fi
  write_report PASS "user-facing copy clean ($failures hits <= threshold $MAXHITS)"
  echo "anti-slop-prose-gate: PASS"
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq || ! have perl; then echo "anti-slop-prose selftest SKIP - need jq+perl."; return 0; fi
  echo "anti-slop-prose-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  seed() { mkdir -p "$1/walteur-kit" "$1/marketing"; }

  # 1. no copy surface -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/antisloppr.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf 'const x=1;\n' > "$t/src/a.ts"; ck "no copy surface -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. clean marketing copy -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/antisloppr.XXXXXX")"; seed "$t"; printf '# Ship faster\nMomentum tracks your daily habits and shows your streak. Start in ten seconds.\n' > "$t/marketing/landing.md"; ck "clean copy -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. throat-clearing opener -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antisloppr.XXXXXX")"; seed "$t"; printf "# Welcome\nHere's the thing: most habit apps fail you.\n" > "$t/marketing/hero.md"; ck "G1 throat-clearing -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. binary contrast -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antisloppr.XXXXXX")"; seed "$t"; printf '# Pricing\nIt is not about features, it is about momentum.\n' > "$t/marketing/pricing.md"; ck "G2 binary-contrast -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. false agency -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antisloppr.XXXXXX")"; seed "$t"; printf '# Data\nThe data tells us you are more consistent on weekdays.\n' > "$t/marketing/about.md"; ck "G3 false-agency -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. meta-commentary -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antisloppr.XXXXXX")"; seed "$t"; mkdir -p "$t/onboarding"; printf '# Guide\nLet me walk you through how streaks work.\n' > "$t/onboarding/guide.md"; ck "G4 meta-commentary -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. override marker -> PASS (intentional)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antisloppr.XXXXXX")"; seed "$t"; printf "# Welcome\nHere's the thing: this line is intentional. <!-- slop-ok -->\n" > "$t/marketing/hero.md"; ck "G5 override marker -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 8. FP guard: a technical README under docs/ is NOT scanned (not a copy path)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antisloppr.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/docs"; printf "# API\nHere's the thing: the endpoint returns 200.\n" > "$t/docs/api.md"; ck "G6 technical doc (not copy path) -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 9. FP guard: normal copy with the word 'just' once does NOT fail (fuzzy adverbs not hard-failed)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antisloppr.XXXXXX")"; seed "$t"; printf '# Hero\nTrack habits in just a few taps. Your streak grows every day.\n' > "$t/marketing/h.md"; ck "G7 benign adverb -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 10. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/antisloppr.XXXXXX")"; seed "$t"; printf "Here's the thing: x\n" > "$t/marketing/h.md"; WALTEUR_ROOT="$t" WALTEUR_PROSESLOP=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antisloppr.XXXXXX")"; seed "$t"; printf "Here's the thing: x\n" > "$t/marketing/h.md"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "anti-slop-prose-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
