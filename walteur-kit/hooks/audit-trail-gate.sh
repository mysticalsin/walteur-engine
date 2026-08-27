#!/usr/bin/env bash
# WALTEUR audit-trail-gate — HARD gate (enterprise backlog rank 11). A $50-100M ARR SaaS must keep a
# tamper-evident, retained audit trail of privileged actions (SOC2 CC7.2/7.3, ISO A.12.4). This gate
# requires walteur-kit/audit-trail.json (immutability + retention + captured fields + required events)
# AND actively scans the source: if privileged actions exist in code with NO audit emit anywhere, FAIL.
#
# Applies when has_auth (signal) or auth/admin code is present.
# CONTRACT: missing manifest/field or privileged-action-without-audit => FAIL exit 2 · non-auth build =>
# NOT_APPLICABLE · jq absent => SKIP · PAUSED => exit 2 · bypass WALTEUR_AUDIT_TRAIL=off.
# Report: walteur-kit/audit-trail-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "audit-trail-gate - HARD gate (enterprise backlog rank 11). A $50-100M ARR SaaS must keep a"
  printf '%s\n' "usage: bash audit-trail-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/audit-trail-report.json - fix recipes: walteur-kit/REMEDIATION.md (## audit-trail-gate)"
  printf '%s\n' "bypass: WALTEUR_AUDIT_TRAIL=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
MANIFEST="${WALTEUR_AUDIT_TRAIL_FILE:-$KIT/audit-trail.json}"
REPORT="$KIT/audit-trail-report.json"
MIN_RETENTION="${WALTEUR_AUDIT_MIN_RETENTION_DAYS:-365}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
# auth_surface grep still uses the (broad) text allowlist below for the cheap library-token sniff.
INC="--include=*.ts --include=*.tsx --include=*.js --include=*.jsx --include=*.mjs --include=*.cjs --include=*.py --include=*.go --include=*.rb --include=*.php --include=*.java --include=*.cs --include=*.kt --include=*.kts --include=*.scala --include=*.rs --include=*.swift --include=*.c --include=*.cc --include=*.cpp --include=*.cxx --include=*.h --include=*.hpp --include=*.m --include=*.mm --include=*.dart --include=*.ex --include=*.exs --include=*.clj --include=*.sql"
X="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit --exclude-dir=dist --exclude-dir=build --exclude-dir=.next --exclude-dir=tests --exclude-dir=__tests__"
# Source-file extensions the ACTIVE audit-emit scan inspects (comment-stripped). Widened beyond the
# JS/TS/Py core to every first-class backend language so a privileged action can't hide in an
# unscanned extension (.kt/.scala/.rs/.swift/.go/.rb/.php/.java/.cs/.c/.cpp/.m/.dart/.ex + SQL migrations).
SCAN_EXTS="ts tsx js jsx mjs cjs py go rb php java cs kt kts scala rs swift c cc cpp cxx h hpp m mm dart ex exs clj sql"

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"audit-trail", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"audit-trail","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

# Is this build a high-stakes one whose declared signals we should NOT take at face value?
# (genuine $50-100M SaaS: risk high/regulated -> the code-scan safety net still applies even if signals look thin.)
high_stakes() {
  [ -f "$CONTRACT" ] && have jq && jq -e '(.risk_tier // "") | ascii_downcase | (.=="high" or .=="regulated")' "$CONTRACT" >/dev/null 2>&1
}
auth_surface() {
  # 1. explicit preflight signal is AUTHORITATIVE.
  if [ -f "$SIGNALS" ] && have jq && jq -e '.has_auth' "$SIGNALS" >/dev/null 2>&1; then
    jq -e '.has_auth==true' "$SIGNALS" >/dev/null 2>&1 && return 0          # declared auth -> applies
    # declared has_auth:false. Trust it for non-high-stakes builds (§14: don't impose on a simple build).
    high_stakes || return 1                                                  # explicit no-auth + not high-risk -> NOT_APPLICABLE
    # high/regulated build that declared no auth -> fall through to the code-scan safety net below.
  fi
  command -v grep >/dev/null 2>&1 || return 1
  # auth-SPECIFIC tokens only. NB: bare 'role'/'session' removed — they false-match ARIA role="..." /
  # setAttribute('role',...) and benign session-storage in clean UI code. Require real auth libs/flows.
  grep -rIilE $INC $X 'passport|next-auth|@auth|jsonwebtoken|jwt\.|bcrypt|argon2|oauth2?|signin|sign_?in|sign_?up|\blogin\b|\brbac\b|getServerSession|withAuth|requireAuth|authenticate|authorize|access_?token|id_?token|role_?(grant|assign|check)|grant_?role|assign_?role|has_?role|user_?role' "$ROOT" >/dev/null 2>&1
}
rel() { printf '%s' "${1#"$ROOT"/}"; }

# Enumerate scannable source files under ROOT (widened extension set; same prune list as $X).
scan_files() {
  local args=() e
  for e in $SCAN_EXTS; do args+=( -iname "*.$e" -o ); done
  unset 'args[${#args[@]}-1]'
  find "$ROOT" \( -name node_modules -o -name .git -o -name walteur-kit -o -name dist -o -name build \
      -o -name .next -o -name tests -o -name __tests__ -o -name vendor -o -name target \) -prune \
      -o -type f \( "${args[@]}" \) -print 2>/dev/null
}
# Strip comments so audit/privileged tokens that live ONLY inside comments don't launder the scan:
#  - C-family line comments  // ... EOL   (ts/js/java/kt/scala/rs/swift/go/c/cpp/cs/php/dart)
#  - C-family block comments /* ... */    (incl. multi-line)
#  - hash line comments      # ... EOL    (py/rb/ex; only when # starts a token, not inside a value)
#  - SQL line comments       -- ... EOL
# perl -0777 (whole-file slurp) is the Windows-safe multiline path; grep -P locale-breaks on Git-Bash.
strip_comments() {
  perl -0777 -pe 's{/\*.*?\*/}{ }gs; s{//[^\n]*}{}g; s{(^|[ \t;{}()\[\]])#[^\n]*}{$1}mg; s{(^|[ \t])--[^\n]*}{$1}mg;' 2>/dev/null
}
# active scan: privileged actions present but no audit emit anywhere in the codebase.
# Builds a single comment-STRIPPED corpus from the WIDENED file set, then runs both detectors on it:
# a token that survives stripping is real code, not a // TODO or a future-promise comment.
scan_audit_emit() {
  command -v grep >/dev/null 2>&1 || return 0
  have perl || return 0   # without perl we cannot strip comments safely; defer (manifest checks still apply)
  local corpus f
  corpus="$( { scan_files | while IFS= read -r f; do cat "$f" 2>/dev/null; printf '\n'; done; } | strip_comments )"
  printf '%s' "$corpus" | grep -qiE 'grant_?role|assign_?role|set_?role|delete_?user|remove_?user|impersonate|export_?data|deactivate_?user|disable_?user|make_?admin|is_?admin[[:space:]]*=[[:space:]]*true|/admin' || return 0   # no real privileged actions -> nothing to require
  printf '%s' "$corpus" | grep -qiE 'audit_?log|auditlog|audit_?event|audit_?trail|log_?event|security_?log|emit_?audit|write_?audit|record_?audit' || printf 'no_audit_emit'
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "audit-trail selftest SKIP - jq not installed."; return 0; fi
  echo "audit-trail-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  authsig() { mkdir -p "$1/walteur-kit" "$1/src"; printf '{"has_auth":true,"has_db":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  goodman() { jq -n --argjson ret "$MIN_RETENTION" '{required_events:["login","role_grant","data_export","user_deprovision"],immutability_mechanism:"append-only",retention_days:$ret,captured_fields:["actor_id","tenant_id","ts","action","target","source_ip"]}' > "$1/walteur-kit/audit-trail.json"; }

  # 1. non-auth build -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf 'export const x=1;\n' > "$t/src/a.ts"; ck "non-auth -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. auth build, good manifest, audit emit present -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; authsig "$t"; goodman "$t"; printf 'export function login(){ auditLog("login"); }\nexport function grantRole(){ auditLog("role_grant"); }\n' > "$t/src/auth.ts"; ck "good manifest + audit emit -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. auth build, manifest absent -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; authsig "$t"; printf 'export function grantRole(){}\n' > "$t/src/auth.ts"; ck "manifest absent -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. retention below floor -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; authsig "$t"; goodman "$t"; jq '.retention_days=30' "$t/walteur-kit/audit-trail.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/audit-trail.json"; printf 'auditLog("x"); grantRole();\n' > "$t/src/a.ts"; ck "retention < 365 -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. missing captured field (actor_id) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; authsig "$t"; goodman "$t"; jq '.captured_fields=["ts","action"]' "$t/walteur-kit/audit-trail.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/audit-trail.json"; printf 'auditLog("x"); grantRole();\n' > "$t/src/a.ts"; ck "missing actor/tenant field -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. privileged actions but NO audit emit anywhere -> FAIL (active scan)
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; authsig "$t"; goodman "$t"; printf 'export function grantRole(uid){ db.users.update(uid,{role:"admin"}); }\nexport function deleteUser(uid){ db.users.delete(uid); }\n' > "$t/src/admin.ts"; ck "privileged action, no audit emit -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. bypass -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; authsig "$t"; printf 'grantRole();\n' > "$t/src/a.ts"; WALTEUR_ROOT="$t" WALTEUR_AUDIT_TRAIL=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  # 8. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; authsig "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # 9. REGRESSION: simple local app, explicit has_auth:false, ARIA role="..." in clean UI code -> NOT_APPLICABLE
  #    (this is the Momentum false-positive: bare 'role'/'session' must NOT masquerade as auth.)
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf '{"has_ui":true,"has_auth":false,"has_db":false}\n' > "$t/walteur-kit/preflight-signals.json"; printf '{"risk_tier":"medium","build_class":"software"}\n' > "$t/walteur-kit/build-contract.json"; printf 'const grid=el("div");grid.setAttribute("role","img");\nsessionStorage.setItem("streak",1);\n' > "$t/src/app.mjs"; ck "simple local app (has_auth:false + ARIA role) -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 10. SAFETY NET: high-risk build that declared has_auth:false but ships REAL auth code -> still scanned -> FAIL (no manifest)
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf '{"has_ui":true,"has_auth":false}\n' > "$t/walteur-kit/preflight-signals.json"; printf '{"risk_tier":"high","build_class":"software"}\n' > "$t/walteur-kit/build-contract.json"; printf 'import jwt from "jsonwebtoken";\nexport function grantRole(){}\n' > "$t/src/auth.ts"; ck "high-risk + declared no-auth but real auth code -> FAIL (safety net)" 2 "$(run "$t")"; rm -rf "$t"
  # 11. SCOPING: no signals file at all, clean UI with only ARIA role -> NA (grep no longer matches bare 'role')
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf 'const g=document.createElement("div");g.setAttribute("role","grid");\n' > "$t/src/ui.jsx"; ck "no signals + only ARIA role -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 12. G12 REGRESSION (comment-laundering miss): privileged actions ship with audit tokens ONLY inside
  #     // comments (future-promise / TODO). Comment-stripped scan must still see no_audit_emit -> FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; authsig "$t"; goodman "$t"; printf 'export function grantRole(uid){\n  // TODO: wire up auditLog() here in a future sprint — not implemented yet\n  db.users.update(uid,{role:"admin"});\n}\nexport function deleteUser(uid){\n  db.users.delete(uid);  // no audit_log emitted, intentionally deferred\n}\n' > "$t/src/admin.ts"; ck "G12 audit tokens only in // comments -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 13. G13 REGRESSION (comment-only disabling tokens): every audit token sits in a comment that disables it.
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; authsig "$t"; goodman "$t"; printf 'export function grantRole(uid){\n  // auditLog("role_grant")  <-- TODO: audit emit intentionally disabled, do NOT call\n  db.users.update(uid,{role:"admin"});\n}\nexport function deleteUser(uid){\n  // security_log -- placeholder, no audit trail wired up yet\n  db.users.delete(uid);\n}\n' > "$t/src/admin.ts"; ck "G13 comment-only-disabled audit tokens -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 14. G14 REGRESSION (extension blind-spot miss): privileged actions live in a NON-allowlisted language
  #     (.kt). Widened scan must read it and FAIL (no real audit emit anywhere).
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; authsig "$t"; goodman "$t"; printf 'package com.acme.admin\nclass AdminService(val db: Db) {\n  fun grantRole(userId: String, role: String) { db.users.update(userId, mapOf("role" to role)) }\n  fun deleteUser(userId: String) { db.users.delete(userId) }\n  fun impersonate(userId: String) { session.assume(userId) }\n}\n' > "$t/src/AdminService.kt"; printf 'export const version="1.0";\n' > "$t/src/version.ts"; ck "G14 privileged action in unscanned .kt -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 15. G14b also for Go block-comment laundering: privileged action in .go, audit token only in /* */.
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; authsig "$t"; goodman "$t"; printf 'package admin\n/* auditLog will be wired later — record_audit() */\nfunc GrantRole(uid string){ db.Update(uid) }\nfunc DeleteUser(uid string){ db.Delete(uid) }\n' > "$t/src/admin.go"; ck "G15 audit token only in /* */ block comment -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 16. FALSE-POSITIVE GUARD: privileged action in .kt WITH a real (non-comment) audit emit -> PASS.
  t="$(mktemp -d "${TMPDIR:-/tmp}/audittrail.XXXXXX")"; authsig "$t"; goodman "$t"; printf 'class AdminService(val db: Db) {\n  fun grantRole(userId: String) { auditLog("role_grant"); db.users.update(userId) }\n  fun deleteUser(userId: String) { recordAudit("user_deprovision"); db.users.delete(userId) }\n}\n' > "$t/src/AdminService.kt"; ck "G16 .kt privileged + REAL audit emit -> PASS (no false positive)" 0 "$(run "$t")"; rm -rf "$t"

  echo "audit-trail-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_AUDIT_TRAIL:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_AUDIT_TRAIL=off"; echo "audit-trail-gate: bypassed." >&2; exit 0; }

if ! auth_surface; then
  write_report "NOT_APPLICABLE" "no auth surface (has_auth!=true and no auth code)"
  echo "audit-trail-gate: NOT_APPLICABLE"; exit 0
fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "audit-trail-gate: SKIP - jq unavailable." >&2; exit 0; fi

if [ ! -s "$MANIFEST" ]; then
  add_finding "manifest" "auth build but walteur-kit/audit-trail.json absent — a privileged-action audit trail is required (SOC2 CC7.2)"
elif ! jq -e '.' "$MANIFEST" >/dev/null 2>&1; then
  add_finding "manifest" "audit-trail.json is not valid JSON"
else
  jq -e '.required_events | type=="array" and length>=1' "$MANIFEST" >/dev/null 2>&1 || add_finding "required_events" "required_events must list the privileged event types logged"
  imm="$(jq -r '.immutability_mechanism // ""' "$MANIFEST")"
  case "$imm" in append-only|WORM|hash-chain|external-siem|immutable) : ;; *) add_finding "immutability" "immutability_mechanism must be append-only|WORM|hash-chain|external-siem (got '${imm:-empty}') — a forgeable log fails SOC2" ;; esac
  ret="$(jq -r '.retention_days // 0' "$MANIFEST")"
  [ "$ret" -ge "$MIN_RETENTION" ] 2>/dev/null || jq -e '.retention_deferral.owner and .retention_deferral.ticket' "$MANIFEST" >/dev/null 2>&1 || add_finding "retention" "retention_days ($ret) below the $MIN_RETENTION-day floor and no signed retention_deferral"
  for fld in actor_id tenant_id ts action; do
    jq -e --arg f "$fld" '[.captured_fields[]?]|index($f)' "$MANIFEST" >/dev/null 2>&1 || add_finding "captured_fields" "audit events must capture '$fld' (who/which-tenant/when/what) — missing"
  done
fi

[ "$(scan_audit_emit)" = "no_audit_emit" ] && add_finding "no_audit_emit" "ACTIVE scan: privileged actions (role grant / user delete / export / impersonate) exist in source with NO audit emit anywhere — there is no audit trail (overrides attestation)"

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures audit-trail violation(s)"
  echo "audit-trail-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null || true
  exit 2
fi
write_report "PASS" "audit trail manifest complete (immutable + retained + actor/tenant/ts/action) and privileged actions are audited"
echo "audit-trail-gate: PASS" >&2
exit 0
