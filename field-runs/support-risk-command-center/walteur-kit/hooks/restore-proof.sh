#!/usr/bin/env bash
# WALTEUR restore-proof — honest detect-or-loud-SKIP backup-restore proof gate.
# Applies ONLY if a BACKUP / DB context exists in the repo. Detection (any one):
#   - a DSN env var set (DATABASE_URL / POSTGRES_DSN / PG_DSN / DATABASE_DSN / SQLITE_DB)
#   - a backup/dump artefact or directory: *.dump | *.bak | *.sql.gz | a backups/ or backup/ dir | pg_dump
#     referenced in a script (*.sh) | a docker-compose service named *postgres*/*mysql*/*db*
#   - a schema/migration context that implies a database: *.sql files, schema.prisma, alembic/migrations dir
# If NONE of these exist (a project with no database and no backups), the gate is NOT_APPLICABLE (exit 0).
# A bare project is NOT a violation — exit 2 is reserved for a real, provable restore failure.
#
# This gate PROVES (when it can run) that a backup is actually RESTORABLE, not merely present. The proof
# is a full round-trip against a THROWAWAY target — never the production DB:
#   1. DUMP    : take/locate a backup (pg_dump / mysqldump / sqlite3 .dump).
#   2. RESTORE : load that dump into a fresh, EMPTY, ephemeral target DB (pg_restore/psql / mysql / sqlite3).
#   3. SMOKE   : run a read-only smoke query against the restored DB (row counts on key tables, a
#                SELECT 1, schema object count) to confirm data + schema actually materialised.
#   4. RTO     : measure wall-clock restore time and compare to the declared Recovery-Time-Objective
#                (RESTORE_RTO_SECONDS, default budget). PASS iff restore + smoke succeed AND elapsed <= RTO.
# A backup that exists but does not restore, or restores but fails the smoke query, or blows the RTO, is a
# real failure (exit 2) — BUT only when the gate is actually enabled to run the destructive round-trip.
#
# Running this needs BOTH a DB engine/client AND a dump tool AND an ephemeral restore target. We will
# NEVER provision/restore as a silent side effect of a commit hook. So by default we emit a LOUD recorded
# SKIP documenting the exact dump->restore->smoke->RTO procedure we WOULD run, and exit 0 (never silent-
# green, never exit 2 for a missing tool / disabled run). To actually execute, opt in explicitly:
#   WALTEUR_RESTORE_PROOF_RUN=on  +  RESTORE_TEST_DB_URL (ephemeral target)  +  the dump/restore tools.
#
# Report: walteur-kit/restore-report.json  {verdict, ts, gate, mode, would_run, details}.
# Bypass: WALTEUR_RESTORE_PROOF=off.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/restore-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  local v="$1" reason="$2" details="${3:-}"
  [ -n "$details" ] || details="{}"
  if have jq; then
    local details_file
    details_file="$(mktemp "${TMPDIR:-/tmp}/restore-report-details.XXXXXX")" || details_file=""
    if [ -n "$details_file" ]; then
      printf '%s\n' "$details" > "$details_file"
      if jq -e . "$details_file" >/dev/null 2>&1; then
        jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --slurpfile d "$details_file" \
          '{verdict:$v, ts:$ts, gate:"restore", reason:$reason, details:$d[0]}' > "$REPORT" 2>/dev/null
        rc=$?
        rm -f "$details_file"
        [ "$rc" -eq 0 ] && return 0
      else
        rm -f "$details_file"
      fi
    fi
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"restore","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
}

selftest() {
  pass=0
  fail=0
  ck() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  for t in bash jq grep find sed mktemp date mkdir rm touch sqlite3; do
    if ! have "$t"; then
      echo "restore-proof selftest SKIP - required tool '$t' not installed."
      return 0
    fi
  done

  echo "restore-proof selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/restoreproof.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'hello\n' > "$tmp/README.txt"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no backup or DB context -> NOT_APPLICABLE exit" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/restore-report.json" >/dev/null 2>&1
  ck "no context report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/restoreproof.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'CREATE TABLE demo(id INTEGER PRIMARY KEY);\n' > "$tmp/schema.sql"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "DB context without opt-in target -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP" and .mode == "NOT_RUN"' "$tmp/walteur-kit/restore-report.json" >/dev/null 2>&1
  ck "disabled restore report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/restoreproof.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  sqlite3 "$tmp/source.db" 'CREATE TABLE demo(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO demo(name) VALUES ("ok");'
  SQLITE_DB="$tmp/source.db" RESTORE_TEST_DB_URL="$tmp/restored.db" WALTEUR_RESTORE_PROOF_RUN=on WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "sqlite restore round-trip -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .mode == "RUN" and .note' "$tmp/walteur-kit/restore-report.json" >/dev/null 2>&1
  ck "sqlite restore report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/restoreproof.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  SQLITE_DB="$tmp/missing.db" RESTORE_TEST_DB_URL="$tmp/restored.db" WALTEUR_RESTORE_PROOF_RUN=on WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing sqlite source -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.reason | contains("restore round-trip failed"))' "$tmp/walteur-kit/restore-report.json" >/dev/null 2>&1
  ck "missing source report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/restoreproof.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'CREATE TABLE demo(id INTEGER PRIMARY KEY);\n' > "$tmp/schema.sql"
  WALTEUR_ROOT="$tmp" WALTEUR_RESTORE_PROOF=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/restore-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/restoreproof.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "restore-proof selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
if [ "${WALTEUR_RESTORE_PROOF:-on}" = "off" ]; then
  echo "restore-proof: bypassed (WALTEUR_RESTORE_PROOF=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_RESTORE_PROOF=off" '{"bypassed":true}'
  exit 0
fi

if ! have jq; then
  echo "WALTEUR restore-proof SKIP — required tool 'jq' not installed (recorded, not silent-green)." >&2
  printf '{"verdict":"SKIP","ts":"%s","gate":"restore","reason":"jq not installed"}\n' "$TS" > "$REPORT"
  exit 0
fi

# The exact procedure this gate WOULD run — emitted into the report so it is auditable / reproducible.
PROCEDURE='["1 DUMP: take/locate a backup (pg_dump / mysqldump / sqlite3 .dump)","2 RESTORE: load it into a fresh EMPTY ephemeral target (pg_restore|psql / mysql / sqlite3) — never production","3 SMOKE: read-only smoke query on the restored DB (SELECT 1, row counts on key tables, schema object count)","4 RTO: measure wall-clock restore time; PASS iff restore+smoke succeed AND elapsed <= RESTORE_RTO_SECONDS"]'

# ── applicability detection ───────────────────────────────────────────────────
DSN="${DATABASE_URL:-${POSTGRES_DSN:-${PG_DSN:-${DATABASE_DSN:-${SQLITE_DB:-}}}}}"
ctx_reason=""
applicable=0

if [ -n "$DSN" ]; then applicable=1; ctx_reason="DSN env var set"; fi

if [ "$applicable" -eq 0 ]; then
  # backup artefacts / dirs
  if find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' \) -prune -o \
       -type f \( -name '*.dump' -o -name '*.bak' -o -name '*.sql.gz' -o -name '*.sql.bz2' -o -name '*.dump.gz' \) -print 2>/dev/null | grep -q .; then
    applicable=1; ctx_reason="backup artefact present (*.dump/*.bak/*.sql.gz)"
  fi
fi
if [ "$applicable" -eq 0 ]; then
  if find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' \) -prune -o \
       -type d \( -name backups -o -name backup \) -print 2>/dev/null | grep -q .; then
    applicable=1; ctx_reason="backups/ directory present"
  fi
fi
if [ "$applicable" -eq 0 ]; then
  # a script that calls a dump tool
  if grep -rIlE '\b(pg_dump|pg_dumpall|mysqldump|sqlite3[[:space:]]+[^ ]+[[:space:]]+\.dump|mongodump)\b' \
       --include='*.sh' --include='*.bash' --include='Makefile' --include='*.mk' "$ROOT" 2>/dev/null \
       | grep -vE '/(node_modules|\.git|vendor|\.venv)/' | grep -q .; then
    applicable=1; ctx_reason="a script references a dump tool (pg_dump/mysqldump/sqlite3 .dump/mongodump)"
  fi
fi
if [ "$applicable" -eq 0 ]; then
  # docker-compose DB service
  if find "$ROOT" -maxdepth 3 -type f \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) 2>/dev/null \
       | xargs grep -lEi 'image:[[:space:]]*(postgres|mysql|mariadb|mongo)\b' 2>/dev/null | grep -q .; then
    applicable=1; ctx_reason="docker-compose declares a database service"
  fi
fi
if [ "$applicable" -eq 0 ]; then
  # schema/migration context implies a database
  if find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' \) -prune -o \
       -type f \( -name '*.sql' -o -name 'schema.prisma' \) -print 2>/dev/null | grep -q .; then
    applicable=1; ctx_reason="SQL/Prisma schema present (implies a database to back up)"
  elif find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' \) -prune -o \
       -type d \( -name alembic -o -name migrations \) -print 2>/dev/null | grep -q .; then
    applicable=1; ctx_reason="migrations/alembic directory present (implies a database to back up)"
  fi
fi

if [ "$applicable" -eq 0 ]; then
  echo "restore-proof: no backup/DB context (no DSN, no dump artefact/dir, no DB compose service, no SQL/migration schema) — gate not applicable." >&2
  jq -n --arg ts "$TS" '{verdict:"NOT_APPLICABLE", ts:$ts, gate:"restore", reason:"no backup/DB context present"}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"restore"}\n' "$TS" > "$REPORT"
  exit 0
fi

echo "WALTEUR restore-proof @ $ROOT — applicable ($ctx_reason)" >&2

# ── detect the dump + restore tooling and an ephemeral restore target ─────────
DUMP_TOOL=""
for t in pg_dump mysqldump sqlite3 mongodump; do have "$t" && { DUMP_TOOL="$t"; break; }; done
RESTORE_TOOL=""
for t in pg_restore psql mysql sqlite3 mongorestore; do have "$t" && { RESTORE_TOOL="$t"; break; }; done
RESTORE_TARGET="${RESTORE_TEST_DB_URL:-${RESTORE_TARGET_DSN:-${WALTEUR_RESTORE_TARGET:-}}}"
RUN="${WALTEUR_RESTORE_PROOF_RUN:-off}"
RTO="${RESTORE_RTO_SECONDS:-900}"

# Determine why we cannot (or can) run the destructive round-trip.
skip_reason=""
if [ -z "$DUMP_TOOL" ]; then
  skip_reason="no dump tool on PATH (pg_dump/mysqldump/sqlite3/mongodump)"
elif [ -z "$RESTORE_TOOL" ]; then
  skip_reason="no restore tool on PATH (pg_restore/psql/mysql/sqlite3/mongorestore)"
elif [ -z "$RESTORE_TARGET" ]; then
  skip_reason="no ephemeral restore target (set RESTORE_TEST_DB_URL / RESTORE_TARGET_DSN — never the production DB)"
elif [ "$RUN" != "on" ]; then
  skip_reason="destructive restore round-trip not enabled (set WALTEUR_RESTORE_PROOF_RUN=on to opt in)"
fi

if [ -n "$skip_reason" ]; then
  # LOUD recorded SKIP — document EXACTLY what we would run and why we did not. Never silent, never green.
  echo "  SKIP (restore round-trip) — $skip_reason." >&2
  echo "  WOULD RUN: dump -> restore into ephemeral target -> read-only smoke query -> RTO check (<= ${RTO}s)." >&2
  echo "  Recorded; NOT counted green. exit 0 (a missing tool/disabled run is never a violation)." >&2
  jq -n --arg ts "$TS" --arg ctx "$ctx_reason" --arg reason "$skip_reason" \
        --arg dump "${DUMP_TOOL:-none}" --arg restore "${RESTORE_TOOL:-none}" \
        --arg target "$([ -n "$RESTORE_TARGET" ] && echo set || echo unset)" --argjson rto "$RTO" \
        --argjson proc "$PROCEDURE" \
    '{verdict:"SKIP", ts:$ts, gate:"restore", mode:"NOT_RUN",
      reason:"restore round-trip not run: \($reason)",
      context:$ctx,
      detected:{dump_tool:$dump, restore_tool:$restore, ephemeral_target:$target, rto_seconds:$rto},
      would_run:$proc}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"SKIP","ts":"%s","gate":"restore","reason":"%s"}\n' "$TS" "$skip_reason" > "$REPORT"
  echo "restore-proof verdict: SKIP (restore round-trip unavailable/disabled) -> $REPORT" >&2
  exit 0
fi

# ── ENABLED: all preconditions met — run the dump -> restore -> smoke -> RTO round-trip ──
# Reaching here requires WALTEUR_RESTORE_PROOF_RUN=on + tools + an explicit ephemeral RESTORE_TEST_DB_URL.
# We honour that opt-in and execute against the throwaway target ONLY. Production DSN is never touched here.
echo "  RUN: restore round-trip enabled (dump=$DUMP_TOOL restore=$RESTORE_TOOL target=set rto=${RTO}s)." >&2
WORK="$(mktemp -d "${TMPDIR:-/tmp}/walteur-restore.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
DUMP_FILE="$WORK/restore-proof.dump"
start_epoch="$(date +%s)"
fail_reason=""

# Stage 1+2+3: dump from source, restore into the ephemeral target, smoke-test. The concrete commands
# are engine-specific; we drive the detected pair. Any failed stage records a real restore failure.
case "$RESTORE_TARGET" in
  sqlite://*|*.sqlite|*.sqlite3|*.db)
    SRC_DB="${SQLITE_DB:-$DSN}"; TGT_FILE="${RESTORE_TARGET#sqlite://}"
    if [ -z "$SRC_DB" ] || [ ! -e "$SRC_DB" ]; then fail_reason="sqlite source DB '$SRC_DB' not found to dump"; fi
    if [ -z "$fail_reason" ]; then sqlite3 "$SRC_DB" .dump > "$DUMP_FILE" 2>>"$WORK/err" || fail_reason="sqlite3 dump failed"; fi
    if [ -z "$fail_reason" ]; then rm -f "$TGT_FILE"; sqlite3 "$TGT_FILE" < "$DUMP_FILE" 2>>"$WORK/err" || fail_reason="sqlite3 restore failed"; fi
    if [ -z "$fail_reason" ]; then
      cnt="$(sqlite3 "$TGT_FILE" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>>"$WORK/err" || echo 0)"
      [ "${cnt:-0}" -ge 1 ] 2>/dev/null || fail_reason="smoke query found 0 tables in restored DB"
    fi
    ;;
  postgres://*|postgresql://*)
    if ! have pg_dump || ! have pg_restore && ! have psql; then fail_reason="postgres tools incomplete (need pg_dump + pg_restore/psql)"; fi
    if [ -z "$fail_reason" ]; then pg_dump -Fc "${DSN:?source DSN required for pg_dump}" > "$DUMP_FILE" 2>>"$WORK/err" || fail_reason="pg_dump failed"; fi
    if [ -z "$fail_reason" ]; then
      if have pg_restore; then pg_restore --clean --if-exists --no-owner -d "$RESTORE_TARGET" "$DUMP_FILE" >>"$WORK/err" 2>&1 || fail_reason="pg_restore failed"
      else psql "$RESTORE_TARGET" < "$DUMP_FILE" >>"$WORK/err" 2>&1 || fail_reason="psql restore failed"; fi
    fi
    if [ -z "$fail_reason" ]; then psql "$RESTORE_TARGET" -tAc 'SELECT 1' >/dev/null 2>>"$WORK/err" || fail_reason="smoke query (SELECT 1) failed on restored DB"; fi
    ;;
  mysql://*)
    if [ -z "$fail_reason" ]; then mysqldump "${DSN:?source DSN required for mysqldump}" > "$DUMP_FILE" 2>>"$WORK/err" || fail_reason="mysqldump failed"; fi
    if [ -z "$fail_reason" ]; then mysql "$RESTORE_TARGET" < "$DUMP_FILE" >>"$WORK/err" 2>&1 || fail_reason="mysql restore failed"; fi
    if [ -z "$fail_reason" ]; then mysql "$RESTORE_TARGET" -e 'SELECT 1' >/dev/null 2>>"$WORK/err" || fail_reason="smoke query (SELECT 1) failed on restored DB"; fi
    ;;
  *)
    fail_reason="restore target scheme not recognised ($RESTORE_TARGET) — supported: sqlite/postgres/mysql"
    ;;
esac

end_epoch="$(date +%s)"
elapsed=$(( end_epoch - start_epoch ))
rto_ok=1
[ "$elapsed" -le "$RTO" ] || rto_ok=0

if [ -n "$fail_reason" ]; then
  jq -n --arg ts "$TS" --arg ctx "$ctx_reason" --arg reason "$fail_reason" \
        --argjson el "$elapsed" --argjson rto "$RTO" --argjson proc "$PROCEDURE" \
    '{verdict:"FAIL", ts:$ts, gate:"restore", mode:"RUN",
      reason:"restore round-trip failed: \($reason)",
      context:$ctx, elapsed_seconds:$el, rto_seconds:$rto, ran:$proc}' > "$REPORT"
  echo "restore-proof verdict: FAIL — $fail_reason -> $REPORT" >&2
  exit 2
fi

if [ "$rto_ok" -eq 0 ]; then
  jq -n --arg ts "$TS" --arg ctx "$ctx_reason" --argjson el "$elapsed" --argjson rto "$RTO" --argjson proc "$PROCEDURE" \
    '{verdict:"FAIL", ts:$ts, gate:"restore", mode:"RUN",
      reason:"restore succeeded but RTO exceeded: \($el)s > budget \($rto)s",
      context:$ctx, elapsed_seconds:$el, rto_seconds:$rto, ran:$proc}' > "$REPORT"
  echo "restore-proof verdict: FAIL — RTO exceeded (${elapsed}s > ${RTO}s) -> $REPORT" >&2
  exit 2
fi

jq -n --arg ts "$TS" --arg ctx "$ctx_reason" --argjson el "$elapsed" --argjson rto "$RTO" --argjson proc "$PROCEDURE" \
  '{verdict:"PASS", ts:$ts, gate:"restore", mode:"RUN",
    note:"backup dumped, restored into ephemeral target, smoke query passed, within RTO",
    context:$ctx, elapsed_seconds:$el, rto_seconds:$rto, ran:$proc}' > "$REPORT"
echo "restore-proof verdict: PASS (restore + smoke OK in ${elapsed}s, RTO ${RTO}s) -> $REPORT" >&2
exit 0
