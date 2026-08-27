#!/usr/bin/env bash
# WALTEUR data-acquisition-gate — HARD gate (v10.2). GOVERNED external data sourcing.
#
# PURPOSE: a $50-100M product that scrapes/crawls the web carries REAL legal exposure (robots.txt, target-site
#   ToS, anti-circumvention/CFAA when bot defenses are defeated, and PII/GDPR on captured content). Adding
#   powerful crawlers (Firecrawl/Crawl4AI/browser-use/Crawlee/Scrapy/curl_cffi/MarkItDown) is only safe if the
#   USE is governed. This gate enforces that: when a build acquires external web/file data, every source must
#   route through a VETTED tool (walteur-kit/data-tools.json), record PROVENANCE, prove robots/PII handling,
#   and — for high-risk anti-bot/auth-bypass tools — carry a recorded LEGAL SIGN-OFF.
#
# ARMS when walteur-kit/data-acquisition.json is present (a build that declares it pulled external data).
#   Absent => NOT_APPLICABLE exit 0 (detect-or-SKIP; never stalls a build with no external acquisition).
#
# CONTRACT (armed) — FAIL exit 2 if ANY:
#   · data-tools.json catalog absent/invalid (cannot vet tools)
#   · sources[] empty (acquisition declared with no recorded source)
#   · a source's tool_id is NOT in the vetted catalog (ad-hoc/unvetted scraper)
#   · a source's output_ref is missing/empty (no provenance of what was captured)
#   · robots_checked != true on a non-owned source (robots.txt ignored)
#   · pii_scanned != true on any source (captured content not screened for PII)
#   · a HIGH-RISK tool (catalog risk=="high": curl_cffi/browser-use/crawlee — TLS/fingerprint/auth bypass)
#     is used without a non-empty top-level legal_signoff
#   PAUSED => exit 2 · bypass WALTEUR_DATAACQ=off => loud SKIP exit 0.
# Zero-dep: bash + jq. Report: walteur-kit/data-acquisition-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "data-acquisition-gate - HARD gate (v10.2). GOVERNED external data sourcing."
  printf '%s\n' "usage: bash data-acquisition-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/data-acquisition-report.json - fix recipes: walteur-kit/REMEDIATION.md (## data-acquisition-gate)"
  printf '%s\n' "bypass: WALTEUR_DATAACQ=off (recorded, not free)"
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
MANIFEST="$KIT/data-acquisition.json"
CATALOG="$KIT/data-tools.json"
REPORT="$KIT/data-acquisition-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"data-acquisition", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","reason":"%s"}\n' "$v" "$r" > "$REPORT" 2>/dev/null || true; }

applies() { [ -f "$MANIFEST" ]; }

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused; echo "data-acquisition-gate: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_DATAACQ:-}" = "off" ] && { write_report SKIP "bypassed via WALTEUR_DATAACQ=off"; echo "data-acquisition-gate: SKIP — WALTEUR_DATAACQ=off (loud skip)" >&2; exit 0; }
  if ! applies; then write_report NOT_APPLICABLE "no data-acquisition.json (build declares no external data sourcing)"; echo "data-acquisition-gate: NOT_APPLICABLE" >&2; exit 0; fi
  if ! have jq; then write_report SKIP "jq not installed"; echo "data-acquisition-gate: SKIP (no jq)" >&2; exit 0; fi

  if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
    add_finding manifest "data-acquisition.json is not valid JSON"; write_report FAIL "invalid manifest"; echo "data-acquisition-gate: FAIL (invalid manifest) -> exit 2" >&2; exit 2
  fi
  if [ ! -f "$CATALOG" ] || ! jq -e '.tools' "$CATALOG" >/dev/null 2>&1; then
    add_finding catalog "walteur-kit/data-tools.json catalog absent/invalid — cannot vet acquisition tools"; write_report FAIL "catalog missing"; echo "data-acquisition-gate: FAIL (catalog missing) -> exit 2" >&2; exit 2
  fi

  # vetted + high-risk tool id sets from the catalog
  local valid_ids high_ids n signoff
  valid_ids=" $(jq -r '.tools[].id' "$CATALOG" | tr '\n' ' ') "
  high_ids=" $(jq -r '.tools[] | select(.risk=="high") | .id' "$CATALOG" | tr '\n' ' ') "
  signoff="$(jq -r '.legal_signoff // ""' "$MANIFEST")"

  n="$(jq '.sources | length' "$MANIFEST" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -eq 0 ]; then
    add_finding sources "data-acquisition.json declares no sources[] — an armed acquisition must record at least one source receipt"
    write_report FAIL "no sources"; echo "data-acquisition-gate: FAIL (no sources) -> exit 2" >&2; exit 2
  fi

  local i=0
  while [ "$i" -lt "$n" ]; do
    local tid url oref robots pii owned full
    tid="$(jq -r ".sources[$i].tool_id // \"\"" "$MANIFEST")"
    url="$(jq -r ".sources[$i].url // \"(no-url)\"" "$MANIFEST")"
    oref="$(jq -r ".sources[$i].output_ref // \"\"" "$MANIFEST")"
    robots="$(jq -r ".sources[$i].robots_checked // false" "$MANIFEST")"
    pii="$(jq -r ".sources[$i].pii_scanned // false" "$MANIFEST")"
    owned="$(jq -r ".sources[$i].owned // false" "$MANIFEST")"

    if [ -z "$tid" ]; then
      add_finding "source[$url].tool" "source has no tool_id — every acquisition must name the tool used"
    elif [ "${valid_ids#* $tid }" = "$valid_ids" ] && [ "${valid_ids%% $tid *}" = "$valid_ids" ]; then
      add_finding "source[$url].tool" "tool_id '$tid' is NOT in the vetted data-tools.json catalog — no ad-hoc/unvetted scrapers"
    else
      # high-risk tool requires a recorded legal sign-off
      if [ "${high_ids#* $tid }" != "$high_ids" ] || [ "${high_ids%% $tid *}" != "$high_ids" ]; then
        [ -z "$signoff" ] && add_finding "source[$url].signoff" "high-risk tool '$tid' (anti-bot/auth-bypass) requires a non-empty top-level legal_signoff in data-acquisition.json"
      fi
    fi

    if [ -z "$oref" ]; then
      add_finding "source[$url].output" "no output_ref — cannot prove what was captured"
    else
      full="$ROOT/$oref"; [ -f "$oref" ] && full="$oref"
      { [ ! -f "$full" ] || [ ! -s "$full" ]; } && add_finding "source[$url].output" "output_ref '$oref' missing or empty"
    fi

    [ "$robots" != "true" ] && [ "$owned" != "true" ] && add_finding "source[$url].robots" "robots_checked != true on a non-owned source — robots.txt must be honored (or mark owned:true)"
    [ "$pii" != "true" ] && add_finding "source[$url].pii" "pii_scanned != true — captured content must be screened for PII before ingestion"

    i=$((i+1))
  done

  if [ "$failures" -gt 0 ]; then
    write_report FAIL "$failures data-acquisition governance violation(s)"
    echo "data-acquisition-gate: FAIL ($failures) -> exit 2" >&2
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null | head -15 >&2 || true
    exit 2
  fi
  write_report PASS "$n source(s): vetted tools, provenance recorded, robots+PII handled, high-risk signed off"
  echo "data-acquisition-gate: PASS ($n governed source(s))" >&2
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "data-acquisition selftest SKIP — need jq."; return 0; fi
  echo "data-acquisition-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  # seed a minimal catalog (firecrawl=medium, curl_cffi=high) + an output file
  seed() {
    mkdir -p "$1/walteur-kit/data"
    jq -n '{schema_version:1, tools:[{id:"firecrawl",risk:"medium"},{id:"curl_cffi",risk:"high"},{id:"markitdown",risk:"low"}]}' > "$1/walteur-kit/data-tools.json"
    printf '# captured\nclean research markdown\n' > "$1/walteur-kit/data/cap1.md"
  }
  # write a manifest: $2=tool_id $3=robots $4=pii $5=signoff $6=output_ref $7=owned
  manifest() {
    jq -n --arg t "$2" --argjson r "$3" --argjson p "$4" --arg s "$5" --arg o "$6" --argjson own "${7:-false}" \
      '{legal_signoff:$s, sources:[{tool_id:$t, url:"https://example.com/docs", captured_ts:"2026-06-28T00:00:00Z", output_ref:$o, robots_checked:$r, pii_scanned:$p, owned:$own}]}' \
      > "$1/walteur-kit/data-acquisition.json"
  }

  # 1. no manifest -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/dataacquis.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no manifest -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. GOOD: vetted medium tool, robots+pii, output exists -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/dataacquis.XXXXXX")"; seed "$t"; manifest "$t" firecrawl true true "" walteur-kit/data/cap1.md; ck "vetted firecrawl + robots+pii + output -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. G1 unvetted tool -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/dataacquis.XXXXXX")"; seed "$t"; manifest "$t" randomscraper true true "" walteur-kit/data/cap1.md; ck "G1 unvetted tool -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. G2 output_ref missing on disk -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/dataacquis.XXXXXX")"; seed "$t"; manifest "$t" firecrawl true true "" walteur-kit/data/nope.md; ck "G2 output_ref absent -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. G3 robots not checked, not owned -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/dataacquis.XXXXXX")"; seed "$t"; manifest "$t" firecrawl false true "" walteur-kit/data/cap1.md; ck "G3 robots unchecked + not owned -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. G4 pii not scanned -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/dataacquis.XXXXXX")"; seed "$t"; manifest "$t" firecrawl true false "" walteur-kit/data/cap1.md; ck "G4 pii unscanned -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. G5 high-risk tool WITHOUT legal_signoff -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/dataacquis.XXXXXX")"; seed "$t"; manifest "$t" curl_cffi true true "" walteur-kit/data/cap1.md; ck "G5 high-risk curl_cffi no signoff -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. G6 high-risk tool WITH legal_signoff (+robots+pii) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/dataacquis.XXXXXX")"; seed "$t"; manifest "$t" curl_cffi true true "Legal approved 2026-06-28 (owned target)" walteur-kit/data/cap1.md; ck "G6 high-risk + signoff -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 9. G7 robots unchecked but owned:true -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/dataacquis.XXXXXX")"; seed "$t"; manifest "$t" firecrawl false true "" walteur-kit/data/cap1.md true; ck "G7 robots unchecked but owned -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 10. catalog missing -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/dataacquis.XXXXXX")"; mkdir -p "$t/walteur-kit/data"; printf 'x\n' > "$t/walteur-kit/data/cap1.md"; manifest "$t" firecrawl true true "" walteur-kit/data/cap1.md; ck "G8 catalog missing -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 11. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/dataacquis.XXXXXX")"; seed "$t"; manifest "$t" randomscraper false false "" walteur-kit/data/nope.md; WALTEUR_ROOT="$t" WALTEUR_DATAACQ=off bash "$SELF" >/dev/null 2>&1; ck "bypass WALTEUR_DATAACQ=off -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/dataacquis.XXXXXX")"; seed "$t"; manifest "$t" firecrawl true true "" walteur-kit/data/cap1.md; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "data-acquisition-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
