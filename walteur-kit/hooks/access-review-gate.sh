#!/usr/bin/env bash
# WALTEUR access-review-gate — HARD gate (enterprise backlog rank 7). SOC2 CC6.1-6.3 / ISO A.9.2.5 require
# periodic recertification of who can reach production. WALTEUR proves a role matrix exists but never that
# human + service access was actually reviewed on a cadence. An auditor asks for the last quarterly review
# on day one. Requires walteur-kit/access-review.json with a cadence + a FRESH last review + a signoff.
#
# Applies when has_auth (signal) or access-review.json exists.
# CONTRACT: missing/stale review => FAIL exit 2 · non-auth => NOT_APPLICABLE · jq absent => SKIP ·
# PAUSED => exit 2 · bypass WALTEUR_ACCESS_REVIEW=off.
# Report: walteur-kit/access-review-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "access-review-gate - HARD gate (enterprise backlog rank 7). SOC2 CC6.1-6.3 / ISO A.9.2.5 require"
  printf '%s\n' "usage: bash access-review-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/access-review-report.json - fix recipes: walteur-kit/REMEDIATION.md (## access-review-gate)"
  printf '%s\n' "bypass: WALTEUR_ACCESS_REVIEW=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
MANIFEST="${WALTEUR_ACCESS_REVIEW_FILE:-$KIT/access-review.json}"
REPORT="$KIT/access-review-report.json"
MAX_CADENCE="${WALTEUR_ACCESS_REVIEW_MAX_CADENCE_DAYS:-90}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"access-review", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"access-review","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

applies() { [ -f "$MANIFEST" ] && return 0; [ -f "$SIGNALS" ] && have jq && jq -e '.has_auth==true' "$SIGNALS" >/dev/null 2>&1; }
epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d %H:%M:%S" "$1 00:00:00" +%s 2>/dev/null || echo ""; }

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "access-review selftest SKIP - jq not installed."; return 0; fi
  echo "access-review-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  au() { mkdir -p "$1/walteur-kit"; printf '{"has_auth":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  goodman() { jq -n --arg d "$(date -u +%Y-%m-%d)" '{review_cadence_days:90,last_review_date:$d,reviewer:"Tony",scope:{human_principals:["alice","bob"],service_accounts:["ci-deployer"],admin_roles:["superadmin"]},deprovisioning_proof_ref:"walteur-kit/jml.log",signoff:{owner:"Tony",date:$d}}' > "$1/walteur-kit/access-review.json"; }

  # 1. non-auth -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"has_auth":false}\n' > "$t/walteur-kit/preflight-signals.json"; ck "non-auth -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. auth + fresh review -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; goodman "$t"; ck "fresh review -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. manifest absent -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; ck "no review -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. cadence > 90 -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; goodman "$t"; jq '.review_cadence_days=180' "$t/walteur-kit/access-review.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/access-review.json"; ck "cadence > 90 -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. stale last_review_date -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; goodman "$t"; jq '.last_review_date="2024-01-01"' "$t/walteur-kit/access-review.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/access-review.json"; ck "stale review -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. missing signoff -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; goodman "$t"; jq 'del(.signoff)' "$t/walteur-kit/access-review.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/access-review.json"; ck "no signoff -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. empty scope -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; goodman "$t"; jq '.scope.human_principals=[]|.scope.service_accounts=[]' "$t/walteur-kit/access-review.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/access-review.json"; ck "empty scope -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; WALTEUR_ROOT="$t" WALTEUR_ACCESS_REVIEW=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # G1 (regression: future-dated last_review +365d / signoff future) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; goodman "$t"; f="$(date -u -d '+365 days' +%Y-%m-%d 2>/dev/null || date -u -v+365d +%Y-%m-%d)"; jq --arg d "$f" '.last_review_date=$d|.signoff.date=$d' "$t/walteur-kit/access-review.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/access-review.json"; ck "G1 future-dated review (+365d) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G1b (regression: far-future last_review 2099 + signoff 2099) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; goodman "$t"; jq '.last_review_date="2099-01-01"|.signoff.date="2099-01-01"' "$t/walteur-kit/access-review.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/access-review.json"; ck "G1b far-future review (2099) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2 (regression: type-confused scope — string + bare number instead of arrays) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; goodman "$t"; jq '.scope.human_principals="none reviewed yet"|.scope.service_accounts=7' "$t/walteur-kit/access-review.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/access-review.json"; ck "G2 type-confused scope (string+number) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2b (regression: scope object/number shapes) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; goodman "$t"; jq '.scope.human_principals={"a":1}|.scope.service_accounts=3' "$t/walteur-kit/access-review.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/access-review.json"; ck "G2b type-confused scope (object+number) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3 (false-positive guard: future signoff only, valid past last_review) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; goodman "$t"; jq '.signoff.date="2099-01-01"' "$t/walteur-kit/access-review.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/access-review.json"; ck "G3 future signoff.date only -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G4 (false-positive guard: one array empty, one array non-empty -> still PASS)
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; goodman "$t"; jq '.scope.human_principals=[]|.scope.service_accounts=["ci-deployer"]' "$t/walteur-kit/access-review.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/access-review.json"; ck "G4 one-empty-one-full array scope -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # G5 (false-positive guard: non-strict date format) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/accessrevi.XXXXXX")"; au "$t"; goodman "$t"; jq '.last_review_date="06/27/2026"' "$t/walteur-kit/access-review.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/access-review.json"; ck "G5 non-ISO date format -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  echo "access-review-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_ACCESS_REVIEW:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_ACCESS_REVIEW=off"; echo "access-review-gate: bypassed." >&2; exit 0; }

if ! applies; then write_report "NOT_APPLICABLE" "no auth surface (has_auth!=true, no access-review.json)"; echo "access-review-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "access-review-gate: SKIP." >&2; exit 0; fi

if [ ! -s "$MANIFEST" ]; then
  add_finding "manifest" "auth/prod-access build but walteur-kit/access-review.json absent — SOC2 CC6 requires a periodic access recertification"
  write_report "FAIL" "access-review manifest absent"; echo "access-review-gate: FAIL - manifest absent" >&2; exit 2
fi
cad="$(jq -r '.review_cadence_days // 0' "$MANIFEST")"
lrd="$(jq -r '.last_review_date // ""' "$MANIFEST")"
[ "$cad" -ge 1 ] 2>/dev/null && [ "$cad" -le "$MAX_CADENCE" ] 2>/dev/null || add_finding "cadence" "review_cadence_days ($cad) must be 1..$MAX_CADENCE (quarterly or tighter)"
now="$(date -u +%s)"
if [ -z "$lrd" ]; then add_finding "last_review" "no last_review_date"
elif ! printf '%s' "$lrd" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then add_finding "last_review" "last_review_date must be a strict ISO YYYY-MM-DD date: $lrd"
else
  le="$(epoch "$lrd")"
  if [ -z "$le" ]; then add_finding "last_review" "last_review_date not parseable: $lrd"
  elif [ "$le" -gt "$now" ]; then add_finding "last_review" "last_review_date ($lrd) is in the FUTURE — a recertification cannot have occurred on a date that has not happened (fabricated review)"
  elif [ -n "$cad" ] && [ "$cad" -ge 1 ] 2>/dev/null && [ $(( (now - le) / 86400 )) -gt "$cad" ]; then add_finding "last_review" "last review ($lrd) is older than the $cad-day cadence — overdue recertification"; fi
fi
jq -e '.reviewer | type=="string" and length>0' "$MANIFEST" >/dev/null 2>&1 || add_finding "reviewer" "no reviewer/approver named"
jq -e '
  ((.scope.human_principals) as $h | (.scope.service_accounts) as $s
   | (($h|type=="array") or ($s|type=="array"))
   and (($h|type=="array") or ($h==null))
   and (($s|type=="array") or ($s==null))
   and ((if ($h|type=="array") then ($h|length) else 0 end) + (if ($s|type=="array") then ($s|length) else 0 end) >= 1))
' "$MANIFEST" >/dev/null 2>&1 || add_finding "scope" "scope must enumerate human_principals and/or service_accounts as non-empty ARRAYS of reviewed identities"
jq -e '(.signoff.owner|type=="string" and length>0) and (.signoff.date|type=="string")' "$MANIFEST" >/dev/null 2>&1 || add_finding "signoff" "review must be signed off (owner + date)"
sod="$(jq -r '.signoff.date // ""' "$MANIFEST")"
if [ -n "$sod" ]; then
  if ! printf '%s' "$sod" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then add_finding "signoff" "signoff.date must be a strict ISO YYYY-MM-DD date: $sod"
  else
    se="$(epoch "$sod")"
    if [ -z "$se" ]; then add_finding "signoff" "signoff.date not parseable: $sod"
    elif [ "$se" -gt "$now" ]; then add_finding "signoff" "signoff.date ($sod) is in the FUTURE — a sign-off cannot have occurred on a date that has not happened"; fi
  fi
fi

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures access-review violation(s)"
  echo "access-review-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "access recertified within cadence, scoped to human + service principals, signed off"
echo "access-review-gate: PASS" >&2
exit 0
