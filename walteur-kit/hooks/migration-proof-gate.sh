#!/usr/bin/env bash
# WALTEUR migration-proof-gate - evidence contract for database migration work.
#
# APPLICABILITY:
#   A migration surface exists when the project has common migration directories/files:
#   db/migrate, migrations, alembic, versions, prisma/migrations, or *.sql inside a *migrat* path.
#   No migration surface -> NOT_APPLICABLE, exit 0.
#
# HARD CHECK:
#   Migration work requires walteur-kit/migration-proof.json.
#   The proof must be fresh and include owner, scope, rollout strategy, forward command,
#   rollback command, verification refs, rollback refs, lock-risk evidence, and backfill plan.
#   Every referenced local proof file must exist, be inside the repo, and be non-empty.
#
# Report: walteur-kit/migration-proof-report.json.
# Bypass: WALTEUR_MIGRATION_PROOF=off. Pause: walteur-kit/PAUSED present.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "migration-proof-gate - evidence contract for database migration work."
  printf '%s\n' "usage: bash migration-proof-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/migration-proof-report.json - fix recipes: walteur-kit/REMEDIATION.md (## migration-proof-gate)"
  printf '%s\n' "bypass: WALTEUR_MIGRATION_PROOF=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
PROOF="$KIT/migration-proof.json"
REPORT="$KIT/migration-proof-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MAX_AGE_DAYS="${WALTEUR_MIGRATION_PROOF_MAX_AGE_DAYS:-14}"
mkdir -p "$KIT"

write_report() {
  local verdict="$1" reason="$2" extra="${3-}"
  [ -n "$extra" ] || extra='{}'
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg reason "$reason" --argjson extra "$extra" \
      '{verdict:$v, ts:$ts, gate:"migration-proof-gate", reason:$reason} + $extra' > "$REPORT" 2>/dev/null \
      || printf '{"verdict":"%s","ts":"%s","gate":"migration-proof-gate","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT"
  else
    printf '{"verdict":"%s","ts":"%s","gate":"migration-proof-gate","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT"
  fi
}

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_MIGRATION_PROOF:-on}" = "off" ] && { write_report "SKIP" "WALTEUR_MIGRATION_PROOF=off"; echo "migration-proof-gate: bypassed (WALTEUR_MIGRATION_PROOF=off)." >&2; exit 0; }

selftest() {
  local pass=0 fail=0 tmp today
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  today="$(date -u +%F)"

  ck() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  make_migration() {
    local dst="$1"
    mkdir -p "$dst/db/migrate" "$dst/walteur-kit/migrations"
    cat > "$dst/db/migrate/001_add_accounts.sql" <<'SQL'
-- migrate:up
CREATE TABLE accounts (id bigint primary key);
CREATE INDEX CONCURRENTLY idx_accounts_id ON accounts(id);

-- migrate:down
DROP TABLE accounts;
SQL
  }

  make_evidence() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit/migrations"
    printf 'dbmate up completed on ephemeral database\n' > "$dst/walteur-kit/migrations/forward.txt"
    printf 'dbmate rollback completed on ephemeral database\n' > "$dst/walteur-kit/migrations/rollback.txt"
    printf 'schema diff clean and smoke tests passed\n' > "$dst/walteur-kit/migrations/verify.txt"
    printf 'lock timeout stayed below 500 ms in dry run\n' > "$dst/walteur-kit/migrations/lock-risk.txt"
    printf 'no backfill required for metadata-only migration\n' > "$dst/walteur-kit/migrations/backfill.txt"
  }

  make_proof() {
    local dst="$1" run_date="${2:-$today}"
    cat > "$dst/walteur-kit/migration-proof.json" <<JSON
{
  "schema_version": 1,
  "run_date": "$run_date",
  "owner": "database-owner",
  "migration_scope": "accounts table initial migration",
  "strategy": "expand-contract",
  "forward_command": "dbmate up",
  "rollback_command": "dbmate rollback",
  "verification_refs": ["walteur-kit/migrations/forward.txt", "walteur-kit/migrations/verify.txt"],
  "rollback_refs": ["walteur-kit/migrations/rollback.txt"],
  "lock_risk": {
    "assessed": true,
    "max_lock_ms": 500,
    "evidence_ref": "walteur-kit/migrations/lock-risk.txt"
  },
  "data_backfill": {
    "required": false,
    "plan_ref": "walteur-kit/migrations/backfill.txt"
  }
}
JSON
  }

  echo "migration-proof-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-proof-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no migrations -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-proof-selftest.XXXXXX")" || return 1
  make_migration "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "migrations without migration-proof.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-proof-selftest.XXXXXX")" || return 1
  make_migration "$tmp"
  printf '{ bad json\n' > "$tmp/walteur-kit/migration-proof.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "invalid migration-proof.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-proof-selftest.XXXXXX")" || return 1
  make_migration "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  jq 'del(.rollback_command)' "$tmp/walteur-kit/migration-proof.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/migration-proof.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "proof missing rollback_command -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-proof-selftest.XXXXXX")" || return 1
  make_migration "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "valid migration proof -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-proof-selftest.XXXXXX")" || return 1
  make_migration "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  rm -f "$tmp/walteur-kit/migrations/verify.txt"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "missing verification evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-proof-selftest.XXXXXX")" || return 1
  make_migration "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  jq '.verification_refs[0] = "../outside.txt"' "$tmp/walteur-kit/migration-proof.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/migration-proof.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "unsafe parent traversal ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-proof-selftest.XXXXXX")" || return 1
  make_migration "$tmp"; make_evidence "$tmp"; make_proof "$tmp" "2000-01-01"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "stale proof -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-proof-selftest.XXXXXX")" || return 1
  make_migration "$tmp"
  WALTEUR_ROOT="$tmp" WALTEUR_MIGRATION_PROOF=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-proof-selftest.XXXXXX")" || return 1
  make_migration "$tmp"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "migration-proof-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

for t in find jq date; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "migration-proof-gate SKIP - required tool '$t' not installed." >&2
    write_report "SKIP" "$t not installed"
    exit 0
  fi
done

PRUNE=( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' \
        -o -path '*/out/*' -o -path '*/.next/*' -o -path '*/.output/*' -o -path '*/.svelte-kit/*' \
        -o -path '*/coverage/*' -o -path '*/vendor/*' -o -path '*/.venv/*' )

migration_hit="$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \
  \( -type d \( -path '*/db/migrate' -o -path '*/migrations' -o -path '*/alembic' -o -path '*/versions' -o -path '*/prisma/migrations' \) \
     -o -type f \( -name '*.sql' -path '*migrat*' \) \) -print 2>/dev/null | head -1)"

if [ -z "$migration_hit" ]; then
  echo "migration-proof-gate: no migration surface - gate not applicable." >&2
  write_report "NOT_APPLICABLE" "no migration surface present"
  exit 0
fi

if [ ! -f "$PROOF" ]; then
  echo "migration-proof-gate: FAIL - migration surface exists but walteur-kit/migration-proof.json is missing." >&2
  write_report "FAIL" "migration-proof.json missing for migration surface"
  exit 2
fi

if ! jq -e . "$PROOF" >/dev/null 2>&1; then
  echo "migration-proof-gate: FAIL - migration-proof.json is not valid JSON." >&2
  write_report "FAIL" "migration-proof.json is not valid JSON"
  exit 2
fi

shape_err="$(jq -r '
  def err(c;m): if c then m else empty end;
  . as $doc
  | [ err(($doc.schema_version != 1); "schema_version must be 1")
  , err(($doc.run_date|type)!="string" or ($doc.run_date|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")|not); "run_date must be YYYY-MM-DD")
  , err(($doc.owner|type)!="string" or ($doc.owner|length)<1; "owner must be a non-empty string")
  , err(($doc.migration_scope|type)!="string" or ($doc.migration_scope|length)<10; "migration_scope must describe the migration scope")
  , err((["expand-contract","online-compatible","no-data-change"] | index($doc.strategy) | not); "strategy must be expand-contract, online-compatible, or no-data-change")
  , err(($doc.forward_command|type)!="string" or ($doc.forward_command|length)<1; "forward_command must be non-empty")
  , err(($doc.rollback_command|type)!="string" or ($doc.rollback_command|length)<1; "rollback_command must be non-empty")
  , err(($doc.verification_refs|type)!="array"; "verification_refs must be an array")
  , err((($doc.verification_refs|type)=="array") and (($doc.verification_refs|length)<1); "verification_refs must contain at least one ref")
  , err((($doc.verification_refs|type)=="array") and ([$doc.verification_refs[]? | select(type!="string" or length<1)] | length>0); "verification_refs must contain non-empty strings")
  , err((($doc.verification_refs|type)=="array") and (($doc.verification_refs|length) != ($doc.verification_refs|unique|length)); "verification_refs must be unique")
  , err(($doc.rollback_refs|type)!="array"; "rollback_refs must be an array")
  , err((($doc.rollback_refs|type)=="array") and (($doc.rollback_refs|length)<1); "rollback_refs must contain at least one ref")
  , err((($doc.rollback_refs|type)=="array") and ([$doc.rollback_refs[]? | select(type!="string" or length<1)] | length>0); "rollback_refs must contain non-empty strings")
  , err((($doc.rollback_refs|type)=="array") and (($doc.rollback_refs|length) != ($doc.rollback_refs|unique|length)); "rollback_refs must be unique")
  , err(($doc.lock_risk|type)!="object"; "lock_risk must be an object")
  , err(($doc.lock_risk.assessed != true); "lock_risk.assessed must be true")
  , err(($doc.lock_risk.max_lock_ms|type)!="number" or ($doc.lock_risk.max_lock_ms<0) or (($doc.lock_risk.max_lock_ms|floor) != $doc.lock_risk.max_lock_ms); "lock_risk.max_lock_ms must be integer >= 0")
  , err(($doc.lock_risk.evidence_ref|type)!="string" or ($doc.lock_risk.evidence_ref|length)<1; "lock_risk.evidence_ref must be non-empty")
  , err(($doc.data_backfill|type)!="object"; "data_backfill must be an object")
  , err(($doc.data_backfill.required|type)!="boolean"; "data_backfill.required must be boolean")
  , err(($doc.data_backfill.plan_ref|type)!="string" or ($doc.data_backfill.plan_ref|length)<1; "data_backfill.plan_ref must be non-empty")
  ] | map(select(length>0)) | .[]' "$PROOF")"

if [ "$?" -ne 0 ]; then
  echo "migration-proof-gate: FAIL - migration-proof.json shape checker failed closed." >&2
  write_report "FAIL" "migration-proof.json shape checker failed closed"
  exit 2
fi

if [ -n "$shape_err" ]; then
  echo "migration-proof-gate: FAIL - migration-proof.json shape is invalid." >&2
  printf '%s\n' "$shape_err" >&2
  write_report "FAIL" "migration-proof.json shape invalid" "$(printf '%s\n' "$shape_err" | jq -R -s '{errors: split("\n") | map(select(length>0))}')"
  exit 2
fi

run_date="$(jq -r '.run_date' "$PROOF")"
today="$(date -u +%F)"
if [ "$run_date" \> "$today" ]; then
  echo "migration-proof-gate: FAIL - run_date is in the future: $run_date." >&2
  write_report "FAIL" "run_date is in the future"
  exit 2
fi

if command -v python3 >/dev/null 2>&1; then
  age_days="$(python3 - "$run_date" "$today" <<'PY' 2>/dev/null
import datetime
import sys
run = datetime.date.fromisoformat(sys.argv[1])
today = datetime.date.fromisoformat(sys.argv[2])
print((today - run).days)
PY
)"
  if [ -n "$age_days" ] && [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
    echo "migration-proof-gate: FAIL - migration proof is stale ($age_days days old, max $MAX_AGE_DAYS)." >&2
    write_report "FAIL" "migration proof is stale" "$(jq -n --argjson age "$age_days" --argjson max "$MAX_AGE_DAYS" '{age_days:$age, max_age_days:$max}')"
    exit 2
  fi
fi

bad_refs=0
refs="$(jq -r '
  (.verification_refs[]?),
  (.rollback_refs[]?),
  .lock_risk.evidence_ref,
  .data_backfill.plan_ref
' "$PROOF" | sort -u)"

while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    /*|*'..'*)
      echo "migration-proof-gate: FAIL - unsafe evidence ref outside project: $ref" >&2
      bad_refs=$((bad_refs+1))
      continue
      ;;
  esac
  full="$ROOT/$ref"
  case "$(cd "$(dirname "$full")" 2>/dev/null && pwd)/$(basename "$full")" in
    "$ROOT"/*) ;;
    *)
      echo "migration-proof-gate: FAIL - evidence ref escapes project: $ref" >&2
      bad_refs=$((bad_refs+1))
      continue
      ;;
  esac
  if [ ! -s "$full" ]; then
    echo "migration-proof-gate: FAIL - evidence ref missing or empty: $ref" >&2
    bad_refs=$((bad_refs+1))
  fi
done <<EOF
$refs
EOF

if [ "$bad_refs" -gt 0 ]; then
  write_report "FAIL" "migration proof has missing or unsafe evidence refs" "$(jq -n --argjson bad "$bad_refs" '{bad_refs:$bad}')"
  exit 2
fi

echo "migration-proof-gate verdict: PASS - migration proof is fresh and evidence refs exist." >&2
write_report "PASS" "migration proof is fresh and evidence refs exist" "$(jq -n --arg hit "${migration_hit#"$ROOT"/}" '{migration_surface:$hit}')"
exit 0
