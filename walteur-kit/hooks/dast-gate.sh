#!/usr/bin/env bash
# WALTEUR dast-gate — HARD gate (enterprise backlog rank 13b). SAST/secret scans read source, but nothing
# runs a DYNAMIC scan against the deployed surface — the OWASP-style runtime attack (reflected XSS, missing
# security headers, injection, SSRF) an external app actually faces. This gate ingests a normalized DAST
# report (walteur-kit/dast-report.json, ZAP/Burp shape) and FAILs on any unexpired High/Critical alert; a
# live external surface at high/regulated risk with NO DAST run FAILs.
#
# Applies when external_surface (signal) or dast-report.json exists.
# CONTRACT: open High/Critical => FAIL exit 2 · no external surface => NOT_APPLICABLE · jq absent => SKIP ·
# PAUSED => exit 2 · bypass WALTEUR_DAST=off.
# Report: walteur-kit/dast-gate-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "dast-gate - HARD gate (enterprise backlog rank 13b). SAST/secret scans read source, but nothing"
  printf '%s\n' "usage: bash dast-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/dast-gate-report.json - fix recipes: walteur-kit/REMEDIATION.md (## dast-gate)"
  printf '%s\n' "bypass: WALTEUR_DAST=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
MANIFEST="${WALTEUR_DAST_FILE:-$KIT/dast-report.json}"
EXCEPTIONS="$KIT/dast-exceptions.json"
REPORT="$KIT/dast-gate-report.json"
MAX_AGE_DAYS="${WALTEUR_DAST_MAX_AGE_DAYS:-14}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"dast", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"dast","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }
external() { [ -f "$MANIFEST" ] && return 0; [ -f "$SIGNALS" ] && have jq && jq -e '.external_surface==true' "$SIGNALS" >/dev/null 2>&1; }
epoch() {
  local s="$1" out
  out="$(date -u -d "$s" +%s 2>/dev/null)" && { printf '%s' "$out"; return; }
  out="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$s" +%s 2>/dev/null)" && { printf '%s' "$out"; return; }
  out="$(date -u -j -f "%Y-%m-%d %H:%M:%S" "$s 00:00:00" +%s 2>/dev/null)" && { printf '%s' "$out"; return; }
  printf ''
}

excepted() {
  local id="$1" now exp e
  [ -f "$EXCEPTIONS" ] || { printf 'no dast-exceptions.json'; return; }
  e="$(jq -c --arg id "$id" '.exceptions[]? | select(.id==$id)' "$EXCEPTIONS" 2>/dev/null | head -1)"
  [ -n "$e" ] || { printf 'no exception entry'; return; }
  printf '%s' "$e" | jq -e '.reason and .owner and .ticket and .expires' >/dev/null 2>&1 || { printf 'exception missing reason/owner/ticket/expires'; return; }
  exp="$(printf '%s' "$e" | jq -r '.expires')"; exp="$(epoch "$exp")"; now="$(date -u +%s)"
  [ -n "$exp" ] || { printf 'exception expires not parseable'; return; }
  [ "$now" -le "$exp" ] || { printf 'exception EXPIRED'; return; }
  maxw=$(( now + ${WALTEUR_DAST_MAX_EXCEPTION_DAYS:-365} * 86400 ))
  [ "$exp" -le "$maxw" ] || { printf 'exception expiry too far out (>%sd) — a deferral must be time-boxed' "${WALTEUR_DAST_MAX_EXCEPTION_DAYS:-365}"; return; }
  printf ''
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "dast selftest SKIP - jq not installed."; return 0; fi
  echo "dast-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  ext() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${2:-high}" > "$1/walteur-kit/build-contract.json"; printf '{"external_surface":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  clean() { jq -n --arg d "$(date -u +%Y-%m-%d)" '{tool:"zap",scanned_at:$d,target_url:"https://app.example.com",alerts:[{name:"X-Content-Type-Options missing",risk:"Low"}]}' > "$1/walteur-kit/dast-report.json"; }
  high() { jq -n --arg d "$(date -u +%Y-%m-%d)" '{tool:"zap",scanned_at:$d,target_url:"https://app.example.com",alerts:[{id:"40012",name:"Reflected XSS",risk:"High",url:"/search"}]}' > "$1/walteur-kit/dast-report.json"; }

  # 1. no external surface -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"external_surface":false}\n' > "$t/walteur-kit/preflight-signals.json"; ck "no external surface -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. external + clean DAST -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; clean "$t"; ck "clean DAST -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. external + high-risk + no report -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t" high; ck "high-risk, no DAST -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. external + High alert -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; high "$t"; ck "open High alert -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. High alert with valid exception -> PASS
  fut30="$(date -u -d '+30 days' +%Y-%m-%d 2>/dev/null || date -u -v+30d +%Y-%m-%d)"
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; high "$t"; jq -n --arg e "$fut30" '{exceptions:[{id:"40012",reason:"WAF blocks, fix queued",owner:"Tony",ticket:"SEC-2",expires:$e}]}' > "$t/walteur-kit/dast-exceptions.json"; ck "High w/ valid exception -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 6. expired exception -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; high "$t"; jq -n '{exceptions:[{id:"40012",reason:"x",owner:"Tony",ticket:"SEC-2",expires:"2024-01-01"}]}' > "$t/walteur-kit/dast-exceptions.json"; ck "expired exception -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. stale scan -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; clean "$t"; jq '.scanned_at="2024-01-01"' "$t/walteur-kit/dast-report.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/dast-report.json"; ck "stale DAST -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. low-risk + no report -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t" low; ck "low-risk, no DAST -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 9. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; high "$t"; WALTEUR_ROOT="$t" WALTEUR_DAST=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ── D4 suite-gauntlet regressions ──
  D="$(date -u +%Y-%m-%d)"
  # G1 — "High " trailing space
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; jq -n --arg d "$D" '{tool:"zap",scanned_at:$d,alerts:[{id:"40012",name:"XSS",risk:"High "}]}' > "$t/walteur-kit/dast-report.json"; ck "G1 trailing-space risk -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2 — ZAP native {site:[{alerts:[...]}]} shape with riskcode
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; jq -n --arg d "$D" '{scanned_at:$d,site:[{alerts:[{pluginid:"40018",name:"SQLi",riskcode:"3"}]}]}' > "$t/walteur-kit/dast-report.json"; ck "G2 ZAP native shape -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3 — exception far-future expiry
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; high "$t"; jq -n '{exceptions:[{id:"40012",reason:"x",owner:"Tony",ticket:"SEC-2",expires:"2099-12-31"}]}' > "$t/walteur-kit/dast-exceptions.json"; ck "G3 far-future exception -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G4 — future-dated scan
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; jq -n '{tool:"zap",scanned_at:"2099-01-01",alerts:[]}' > "$t/walteur-kit/dast-report.json"; ck "G4 future-dated scan -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G5 — severity only under capital "Risk" field / "High (Medium)" riskdesc
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; jq -n --arg d "$D" '{scanned_at:$d,alerts:[{id:"40012",name:"XSS",riskdesc:"High (Medium)"}]}' > "$t/walteur-kit/dast-report.json"; ck "G5 riskdesc High (Medium) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G6 — FALSE-POSITIVE GUARD: Informational/Low-only native shape -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/dastgate.XXXXXX")"; ext "$t"; jq -n --arg d "$D" '{scanned_at:$d,site:[{alerts:[{name:"info disclosure",riskcode:"0",risk:"Informational"}]}]}' > "$t/walteur-kit/dast-report.json"; ck "G6 informational-only -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "dast-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_DAST:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_DAST=off"; echo "dast-gate: bypassed." >&2; exit 0; }

if ! external; then write_report "NOT_APPLICABLE" "no external surface (external_surface!=true, no dast-report.json)"; echo "dast-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "dast-gate: SKIP." >&2; exit 0; fi

RISK="$(risk)"
if [ ! -s "$MANIFEST" ]; then
  case "$RISK" in
    high|regulated) add_finding "scan" "external surface at $RISK risk but no walteur-kit/dast-report.json — run OWASP ZAP/Burp against the deployed URL and normalize the output"
      write_report "FAIL" "no DAST at $RISK risk"; echo "dast-gate: FAIL - no DAST at $RISK risk" >&2; exit 2 ;;
    *) write_report "NOT_APPLICABLE" "no dast-report.json and risk_tier=$RISK below the DAST-required floor"; echo "dast-gate: NOT_APPLICABLE (no DAST, $RISK risk)"; exit 0 ;;
  esac
fi

sa="$(jq -r '.scanned_at // ""' "$MANIFEST")"
if [ -z "$sa" ]; then add_finding "scanned_at" "dast-report.json has no scanned_at"
else
  se="$(epoch "$sa")"; now="$(date -u +%s)"
  if [ -z "$se" ]; then add_finding "scanned_at" "scanned_at not parseable: $sa"
  elif [ "$se" -gt "$((now + 86400))" ]; then add_finding "scanned_at" "scanned_at is in the FUTURE ($sa) — a fabricated scan timestamp cannot prove freshness"
  elif [ $(( (now - se) / 86400 )) -gt "$MAX_AGE_DAYS" ]; then add_finding "scanned_at" "DAST run is stale (>$MAX_AGE_DAYS days: $sa) — re-scan the deployed surface"; fi
fi

# NORMALIZE many ZAP/Burp shapes + derive risk robustly (D4 suite gauntlet: 5/5 evaded the old exact-token read).
# sevnorm: trims/uppercases, takes the leading word of a riskdesc ("High (Medium)"->HIGH), reads many fields.
NORM='
  def sevnorm:
    (((.risk // .Risk // .riskdesc // .riskcode // .severity // .Severity // .severity_level // .level // "") | tostring | ascii_upcase | gsub("^[^A-Z0-9]+";"") | split(" ")[0] | gsub("[^A-Z0-9]";"")) ) as $s
    | if ($s|test("CRITICAL")) or ($s=="4") then "CRITICAL"
      elif ($s|test("HIGH|IMPORTANT")) or ($s=="3") then "HIGH"
      elif ($s|test("MEDIUM|MODERATE")) or ($s=="2") then "MEDIUM"
      elif ($s=="" or $s=="INFORMATIONAL" or $s=="INFO" or $s=="LOW") then ($s|if .=="" then "UNKNOWN" else "LOW" end)
      else "UNKNOWN" end;
  def alerts:
    if (.alerts? | type)=="array" then .alerts[]
    elif (.site? | type)=="array" then (.site[] | (.alerts // [])[])
    elif (.site? | type)=="object" then ((.site.alerts // [])[])
    else empty end;
  alerts | [ ((.id // .pluginId // .pluginid // "") | tostring), ((.name // .alert // "alert") | tostring), sevnorm, ((.url // .uri // "") | tostring) ] | @tsv'

while IFS=$'\t' read -r id name cls url; do
  [ -n "$name" ] || continue
  case "$cls" in
    HIGH|CRITICAL)
      key="${id:-$name}"; why="$(excepted "$key")"
      [ -n "$why" ] && add_finding "$key" "$cls DAST alert '$name'${url:+ at $url} not accepted ($why) — remediate or sign a time-boxed exception" ;;
    UNKNOWN)
      case "$RISK" in high|regulated) key="${id:-$name}"; why="$(excepted "$key")"; [ -n "$why" ] && add_finding "$key" "DAST alert '$name' has unknown/empty risk — cannot prove it is below High at $RISK risk; classify or except it" ;; esac ;;
  esac
done < <(jq -r "$NORM" "$MANIFEST" 2>/dev/null)

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures DAST violation(s)"
  echo "dast-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "fresh DAST against the deployed surface; no unexpired High/Critical alert"
echo "dast-gate: PASS" >&2
exit 0
