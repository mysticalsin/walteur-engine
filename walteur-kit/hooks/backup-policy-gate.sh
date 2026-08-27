#!/usr/bin/env bash
# WALTEUR backup-policy-gate — HARD gate (enterprise backlog rank 5). restore-proof proves ONE dump
# restores; nothing fails a build with a prod DB but no backup cadence, no off-region/immutable copy, no
# PITR, or a cadence whose data-loss window exceeds the declared RPO. Those are contract-breaching outages.
# Requires walteur-kit/backup-policy.json per datastore and cross-checks cadence vs RPO.
#
# Applies when has_db (signal) or backup-policy.json exists.
# CONTRACT: missing/weak policy => FAIL exit 2 · no datastore => NOT_APPLICABLE · jq absent => SKIP ·
# PAUSED => exit 2 · bypass WALTEUR_BACKUP=off.
# Report: walteur-kit/backup-policy-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "backup-policy-gate - HARD gate (enterprise backlog rank 5). restore-proof proves ONE dump"
  printf '%s\n' "usage: bash backup-policy-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/backup-policy-report.json - fix recipes: walteur-kit/REMEDIATION.md (## backup-policy-gate)"
  printf '%s\n' "bypass: WALTEUR_BACKUP=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
MANIFEST="${WALTEUR_BACKUP_FILE:-$KIT/backup-policy.json}"
OPERATE="$KIT/operate-readiness.json"
MIN_RETENTION="${WALTEUR_BACKUP_MIN_RETENTION_DAYS:-7}"
REPORT="$KIT/backup-policy-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
# normalize a region id: fold case + strip ALL whitespace so "EU-WEST-1" / "eu-west-1 " == "eu-west-1"
norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '[:space:]'; }
# is the value a REAL JSON boolean true (not the string "true")? reads the datastore object from stdin.
json_true() { jq -e "($1) == true" >/dev/null 2>&1; }
# a deferral is VALID only if owner + ticket are real, substantive (non-placeholder) strings.
# rejects null/non-string/empty/whitespace and placeholder tokens (TBD, N/A, none, tbc, pending, ?, -, xxx).
defer_valid() {
  jq -e '
    def clean: (. // "") | ascii_downcase | gsub("[[:space:]]";"");
    def placeholder: . as $v | (["","tbd","tba","tbc","n/a","na","none","null","pending","?","-","--","xxx","todo","fixme","wip","later"] | index($v)) != null;
    (.deferral|type)=="object"
    and (.deferral.owner|type)=="string" and (.deferral.ticket|type)=="string"
    and ((.deferral.owner|clean) | (. != "" and (placeholder|not)))
    and ((.deferral.ticket|clean) | (. != "" and (placeholder|not)))
    # ticket must look like a real tracker ref: a letter-prefixed id (JIRA-123, OPS-42), a #number, or a URL.
    and ((.deferral.ticket|ascii_downcase) | test("([a-z]+-[0-9]+)|(#[0-9]+)|(https?://)|([0-9]{3,})"))
  ' >/dev/null 2>&1
}

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"backup-policy", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"backup-policy","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

applies() { [ -f "$MANIFEST" ] && return 0; [ -f "$SIGNALS" ] && have jq && jq -e '.has_db==true' "$SIGNALS" >/dev/null 2>&1; }
cad_min() { case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in continuous|streaming|cdc) echo 0;; *min*) echo 15;; hourly|*hour*) echo 60;; daily|nightly|*day*) echo 1440;; weekly|*week*) echo 10080;; *) echo 1440;; esac; }

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "backup-policy selftest SKIP - jq not installed."; return 0; fi
  echo "backup-policy-gate selftest:"
  # absolute path to this script BEFORE any cd, so sub-invocations resolve regardless of cwd.
  SELF="$0"; case "$SELF" in /*|?:[\/]*) :;; *) SELF="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")";; esac
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  db() { mkdir -p "$1/walteur-kit"; printf '{"has_db":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  goodman() { jq -n '{datastores:[{name:"main-pg",cadence:"hourly",retention_days:30,pitr_enabled:true,primary_region:"eu-west-1",offsite_region:"eu-central-1",encrypted:true,last_backup_evidence_ref:"walteur-kit/backups-main.log"}]}' > "$1/walteur-kit/backup-policy.json"; printf 'ok\n' > "$1/walteur-kit/backups-main.log"; }

  # 1. no datastore -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"has_db":false}\n' > "$t/walteur-kit/preflight-signals.json"; ck "no datastore -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. good policy -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; goodman "$t"; ck "good backup policy -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. manifest absent -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; ck "has_db, no policy -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. offsite == primary -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; goodman "$t"; jq '.datastores[0].offsite_region="eu-west-1"' "$t/walteur-kit/backup-policy.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/backup-policy.json"; ck "offsite==primary -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. not encrypted -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; goodman "$t"; jq '.datastores[0].encrypted=false' "$t/walteur-kit/backup-policy.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/backup-policy.json"; ck "backups not encrypted -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. no PITR + no deferral -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; goodman "$t"; jq '.datastores[0].pitr_enabled=false' "$t/walteur-kit/backup-policy.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/backup-policy.json"; ck "no PITR, no deferral -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. cadence (daily) exceeds RPO (15m) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; goodman "$t"; jq '.datastores[0].cadence="daily"' "$t/walteur-kit/backup-policy.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/backup-policy.json"; printf '{"rpo_minutes":15}\n' > "$t/walteur-kit/operate-readiness.json"; ck "cadence > RPO -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; WALTEUR_ROOT="$t" WALTEUR_BACKUP=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ---- G# regressions (proven red-team false-negatives) ----
  # G1. case-disguised offsite==primary (EU-WEST-1 == eu-west-1) -> must FAIL (was exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; goodman "$t"; jq '.datastores[0].offsite_region="EU-WEST-1"' "$t/walteur-kit/backup-policy.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/backup-policy.json"; ck "G1 case-disguised offsite==primary -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G1b. trailing-whitespace-disguised offsite==primary ("eu-west-1 ") -> must FAIL (was exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; goodman "$t"; jq '.datastores[0].offsite_region="eu-west-1 "' "$t/walteur-kit/backup-policy.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/backup-policy.json"; ck "G1b ws-disguised offsite==primary -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2. string-typed booleans ("true") are NOT proof -> must FAIL (was exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; goodman "$t"; jq '.datastores[0].pitr_enabled="true" | .datastores[0].encrypted="true"' "$t/walteur-kit/backup-policy.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/backup-policy.json"; ck "G2 string booleans -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2b. string "false" / numeric 1 for encrypted -> must FAIL (only real boolean true passes)
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; goodman "$t"; jq '.datastores[0].encrypted=1' "$t/walteur-kit/backup-policy.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/backup-policy.json"; ck "G2b numeric encrypted -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3. vacuous deferral (owner=TBD, ticket=N/A) waives nothing -> must FAIL (was exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; jq -n '{datastores:[{name:"orders-pg",cadence:"hourly",retention_days:30,pitr_enabled:false,primary_region:"eu-west-1",encrypted:true,deferral:{owner:"TBD",ticket:"N/A"}}]}' > "$t/walteur-kit/backup-policy.json"; ck "G3 vacuous deferral -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3b. deferral with placeholder ticket "pending" -> must FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; jq -n '{datastores:[{name:"orders-pg",cadence:"hourly",retention_days:30,pitr_enabled:false,primary_region:"eu-west-1",encrypted:true,deferral:{owner:"jane.doe",ticket:"pending"}}]}' > "$t/walteur-kit/backup-policy.json"; ck "G3b placeholder ticket -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3c. FALSE-POSITIVE GUARD: a REAL signed deferral (named owner + tracker ref) waives PITR/offsite -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/backuppoli.XXXXXX")"; db "$t"; jq -n '{datastores:[{name:"orders-pg",cadence:"hourly",retention_days:30,pitr_enabled:false,primary_region:"eu-west-1",encrypted:true,deferral:{owner:"jane.doe@corp",ticket:"OPS-1234"}}]}' > "$t/walteur-kit/backup-policy.json"; ck "G3c real signed deferral -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "backup-policy-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_BACKUP:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_BACKUP=off"; echo "backup-policy-gate: bypassed." >&2; exit 0; }

if ! applies; then write_report "NOT_APPLICABLE" "no datastore (has_db!=true, no backup-policy.json)"; echo "backup-policy-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "backup-policy-gate: SKIP." >&2; exit 0; fi

if [ ! -s "$MANIFEST" ]; then
  add_finding "manifest" "has_db build but walteur-kit/backup-policy.json absent — declare cadence/retention/PITR/offsite/encryption per datastore"
  write_report "FAIL" "backup policy absent"; echo "backup-policy-gate: FAIL - manifest absent" >&2; exit 2
fi
jq -e '.datastores | type=="array" and length>=1' "$MANIFEST" >/dev/null 2>&1 || add_finding "datastores" "backup-policy.json must list >=1 datastore"

rpo="$( { [ -f "$OPERATE" ] && jq -r '.rpo_minutes // empty' "$OPERATE"; } 2>/dev/null; jq -r '.rpo_minutes // empty' "$MANIFEST" 2>/dev/null | head -1)"
rpo="$(printf '%s' "$rpo" | grep -oE '^[0-9]+' | head -1)"

while IFS= read -r ds; do
  [ -n "$ds" ] || continue
  nm="$(printf '%s' "$ds" | jq -r '.name // "?"')"
  cad="$(printf '%s' "$ds" | jq -r '.cadence // ""')"
  ret="$(printf '%s' "$ds" | jq -r '.retention_days // 0')"
  # REAL JSON booleans only — a string "true" is NOT proof the flag is enabled (fail-closed on type).
  if printf '%s' "$ds" | json_true '.pitr_enabled'; then pitr=true; else pitr=false; fi
  pri="$(printf '%s' "$ds" | jq -r '.primary_region // ""')"
  off="$(printf '%s' "$ds" | jq -r '.offsite_region // ""')"
  if printf '%s' "$ds" | json_true '.encrypted'; then enc=true; else enc=false; fi
  # a deferral waives PITR/offsite ONLY if it is a substantive, non-placeholder signed approval.
  if printf '%s' "$ds" | defer_valid; then defer=yes; else defer=no; fi
  # surface a present-but-vacuous deferral so the build sees WHY the waiver did not apply.
  if [ "$defer" = "no" ] && printf '%s' "$ds" | jq -e '.deferral != null' >/dev/null 2>&1; then
    add_finding "$nm.deferral" "deferral present but not a valid signed approval — owner/ticket missing, placeholder (TBD/N-A/none), or ticket not a real tracker ref"
  fi
  [ -n "$cad" ] || add_finding "$nm.cadence" "no backup cadence declared"
  [ "$ret" -ge "$MIN_RETENTION" ] 2>/dev/null || add_finding "$nm.retention" "retention_days ($ret) below $MIN_RETENTION-day floor"
  [ "$pitr" = "true" ] || [ "$defer" = "yes" ] || add_finding "$nm.pitr" "point-in-time-recovery not enabled and no signed deferral"
  [ "$enc" = "true" ] || add_finding "$nm.encrypted" "backups not encrypted at rest"
  if [ -n "$off" ] && [ -n "$pri" ] && [ "$(norm "$off")" = "$(norm "$pri")" ]; then add_finding "$nm.offsite" "offsite_region == primary_region ($pri) — no geographic redundancy (case/whitespace-normalized)"; fi
  [ -n "$off" ] || [ "$defer" = "yes" ] || add_finding "$nm.offsite" "no offsite_region and no signed deferral — a single-region failure loses the backups too"
  if [ -n "$rpo" ] && [ -n "$cad" ]; then
    cm="$(cad_min "$cad")"
    [ "$cm" -le "$rpo" ] 2>/dev/null || add_finding "$nm.rpo" "cadence '$cad' (~${cm}m data-loss window) exceeds declared RPO of ${rpo}m — the policy cannot meet the RPO"
  fi
done < <(jq -c '.datastores[]?' "$MANIFEST" 2>/dev/null)

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures backup-policy violation(s)"
  echo "backup-policy-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "every datastore has cadence + retention + PITR + offsite + encryption consistent with the RPO"
echo "backup-policy-gate: PASS" >&2
exit 0
