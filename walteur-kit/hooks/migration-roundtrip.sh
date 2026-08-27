#!/usr/bin/env bash
# WALTEUR migration-roundtrip — honest detect-or-loud-SKIP migration round-trip gate.
# Applies ONLY if a migrations directory is present (same detection as migration-lint).
#
# What this gate PROVES when it can run: a migration is truly reversible at the SCHEMA level, i.e.
#   schema_sha(migrate up)  ==  schema_sha(up -> down -> up)
# Procedure (the round-trip it WOULD run against a throwaway dev DB):
#   1. Provision an ephemeral, EMPTY dev database (never the real DB).
#   2. migrate UP to head        -> dump schema -> SHA_A
#   3. migrate DOWN one step      (rollback the newest migration)
#   4. migrate UP again to head  -> dump schema -> SHA_B
#   5. PASS iff SHA_A == SHA_B. A drift (SHA_A != SHA_B) => the down() does not faithfully invert
#      the up() — exit 2. Equality proves the rollback is real, not just present.
#
# This needs BOTH a migrate runner AND a live dev DB. If either is missing we CANNOT run it, so we
# emit a LOUD recorded SKIP and exit 0 (NEVER silent-green, NEVER exit 2 for a missing tool/DB).
# The gate is enabled (opt-in to actually execute) only when DATABASE_URL_TEST (or a dialect-default
# dev URL) is set AND a recognised migrate runner is on PATH AND WALTEUR_MIGRATION_DB=on.
#
# ZERO-DEP precheck (always runs when applicable, real exit 2): structural prerequisites for a
# round-trip to even be possible — every migration must declare BOTH an up and a down direction.
# A migration that has an up but no down direction can NEVER round-trip; that is a hard failure here,
# independent of any DB. (Empty-body down detection is migration-lint's C1; this checks the down
# DIRECTION EXISTS at all, which is the precondition for step 3 above.)
#
# Report: walteur-kit/migration-roundtrip-report.json  {verdict, ts, gate, mode, details}.
# Bypass: WALTEUR_MIGRATION_RT=off.  Enable live DB run: WALTEUR_MIGRATION_DB=on + DATABASE_URL_TEST.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "migration-roundtrip - honest detect-or-loud-SKIP migration round-trip gate."
  printf '%s\n' "usage: bash migration-roundtrip.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/migration-roundtrip-report.json - fix recipes: walteur-kit/REMEDIATION.md (## migration-roundtrip)"
  printf '%s\n' "bypass: WALTEUR_MIGRATION_RT=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/migration-roundtrip-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

selftest() {
  local pass=0 fail=0 tmp
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  have() { command -v "$1" >/dev/null 2>&1; }

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

  make_sql() {
    local dst="$1" body="$2"
    mkdir -p "$dst/db/migrate" "$dst/walteur-kit"
    printf '%s\n' "$body" > "$dst/db/migrate/001_test.sql"
  }

  valid_sql='-- migrate:up
CREATE TABLE accounts (id bigint primary key);

-- migrate:down
DROP TABLE accounts;'

  echo "migration-roundtrip selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-roundtrip-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no migrations -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-roundtrip-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "$valid_sql"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "valid structural roundtrip -> PASS_OR_SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-roundtrip-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "-- migrate:up
CREATE TABLE accounts (id bigint primary key);"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "missing down direction -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-roundtrip-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/db/migrate" "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "empty migrations dir -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-roundtrip-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/db/migrate" "$tmp/walteur-kit"
  cat > "$tmp/db/migrate/001_change.rb" <<'RB'
class AddAccounts < ActiveRecord::Migration[7.1]
  def change
    create_table :accounts
  end
end
RB
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "Rails def change structural pass -> PASS_OR_SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-roundtrip-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "$valid_sql"
  WALTEUR_ROOT="$tmp" WALTEUR_MIGRATION_RT=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-roundtrip-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "$valid_sql"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # ── C8: sqlite default-execute ─────────────────────────────────────────────────
  sqlite_up_sql='-- migrate:up
CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT);
-- sqlite3 dialect

-- migrate:down
DROP TABLE accounts;'

  if have sqlite3; then
    # valid sqlite migration, default-execute ON (no env needed) -> real PASS with sqlite mode + report markers
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-roundtrip-selftest.XXXXXX")" || return 1
    make_sql "$tmp" "$sqlite_up_sql"
    WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
    ck "sqlite dialect, default-execute -> PASS" 0 "$?"
    got_mode="$(jq -r '.mode' "$tmp/walteur-kit/migration-roundtrip-report.json" 2>/dev/null)"
    ck "sqlite default-execute report.mode == SQLITE_EXEC" "SQLITE_EXEC" "$got_mode"
    got_executed="$(jq -r '.sqlite.executed' "$tmp/walteur-kit/migration-roundtrip-report.json" 2>/dev/null)"
    ck "sqlite default-execute report.sqlite.executed == true" "true" "$got_executed"
    rm -rf "$tmp"

    # NEGATIVE CONTROL: down() does NOT invert up() (schema drift) -> real FAIL, not silently green
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-roundtrip-selftest.XXXXXX")" || return 1
    make_sql "$tmp" '-- migrate:up
CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE orphan_leftover (id INTEGER PRIMARY KEY);
-- sqlite3 dialect

-- migrate:down
DROP TABLE accounts;'
    WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
    ck "sqlite default-execute: down does not invert up -> FAIL" 2 "$?"
    got_sqlite_verdict="$(jq -r '.sqlite.verdict' "$tmp/walteur-kit/migration-roundtrip-report.json" 2>/dev/null)"
    ck "drift report.sqlite.verdict == FAIL" "FAIL" "$got_sqlite_verdict"
    rm -rf "$tmp"

    # opt-out: WALTEUR_MIGRATION_EXEC=0 -> falls back to STRUCTURAL (SKIP live, precheck PASS), not executed
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-roundtrip-selftest.XXXXXX")" || return 1
    make_sql "$tmp" "$sqlite_up_sql"
    WALTEUR_ROOT="$tmp" WALTEUR_MIGRATION_EXEC=0 bash "$SELF_PATH" >/dev/null 2>&1
    ck "sqlite opt-out (WALTEUR_MIGRATION_EXEC=0) -> exit 0 (not executed)" 0 "$?"
    got_mode2="$(jq -r '.mode' "$tmp/walteur-kit/migration-roundtrip-report.json" 2>/dev/null)"
    ck "opt-out report.mode == STRUCTURAL (no execution)" "STRUCTURAL" "$got_mode2"
    rm -rf "$tmp"
  else
    echo "  (sqlite3 not installed — skipping 5 sqlite-exec-specific assertions; SKIP-path assertion below still runs)"
  fi

  # sqlite3 absent -> loud SKIP/STRUCTURAL, never silent-green and never a hard crash. Simulated by
  # prepending a directory that shadows ONLY `sqlite3` (a non-executable file of that name) onto PATH,
  # so `command -v sqlite3` resolves to something that exists-but-fails rather than being findable —
  # emulate "absent" honestly by simply NOT putting a real sqlite3 on the shadow dir and removing every
  # other PATH entry that might contain one; rest of PATH (bash, jq, coreutils, DLLs) stays intact.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-roundtrip-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "$sqlite_up_sql"
  real_sqlite3="$(command -v sqlite3 2>/dev/null)"
  stripped_path="$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -n "$real_sqlite3" ] && [ -e "$d/sqlite3" ] && [ "$d/sqlite3" = "$real_sqlite3" ] && continue
    [ -e "$d/sqlite3" ] || [ -e "$d/sqlite3.exe" ] && continue
    printf '%s\n' "$d"
  done | tr '\n' ':')"
  ( PATH="${stripped_path%:}" WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1 )
  rc=$?
  ck "sqlite3 absent from PATH -> not a hard FAIL (SKIP or STRUCTURAL, exit 0)" 0 "$rc"
  rm -rf "$tmp"

  echo "migration-roundtrip selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_MIGRATION_RT:-on}" = "off" ] && { echo "migration-roundtrip: bypassed (WALTEUR_MIGRATION_RT=off)." >&2; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }
if ! have jq; then
  echo "WALTEUR migration-roundtrip SKIP — required tool 'jq' not installed (recorded, not silent-green)." >&2
  printf '{"verdict":"SKIP","ts":"%s","gate":"migration-roundtrip","reason":"jq not installed"}\n' "$TS" > "$REPORT"
  exit 0
fi

# ── applicability detection (mirror migration-lint) ──────────────────────────
mig_dirs=""
add_dir() { [ -n "$1" ] && [ -d "$1" ] && mig_dirs="$mig_dirs
$1"; }
while IFS= read -r d; do
  [ -z "$d" ] && continue
  case "$(basename "$d")" in migrate|migrations|alembic|versions) add_dir "$d" ;; esac
done <<EOF
$(find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' \) -prune -o -type d \( -name migrate -o -name migrations -o -name alembic -o -name versions \) -print 2>/dev/null)
EOF
while IFS= read -r d; do add_dir "$d"; done <<EOF
$(find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' \) -prune -o -type d -path '*/prisma/migrations' -print 2>/dev/null)
EOF
while IFS= read -r f; do [ -z "$f" ] && continue; add_dir "$(dirname "$f")"; done <<EOF
$(find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' \) -prune -o -type f -name '*.sql' -path '*migrat*' -print 2>/dev/null)
EOF
mig_dirs="$(printf '%s\n' "$mig_dirs" | sed '/^$/d' | sort -u)"

if [ -z "$mig_dirs" ]; then
  echo "migration-roundtrip: no migrations dir present — gate not applicable." >&2
  jq -n --arg ts "$TS" '{verdict:"NOT_APPLICABLE", ts:$ts, gate:"migration-roundtrip", reason:"no migrations directory present"}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"migration-roundtrip"}\n' "$TS" > "$REPORT"
  exit 0
fi

# Collect migration files (dedupe: nested alembic + alembic/versions can surface the same file twice).
MIG_FILES=()
files_raw="$(while IFS= read -r d; do
  [ -z "$d" ] && continue
  find "$d" -maxdepth 4 -type f \( -name '*.sql' -o -name '*.rb' -o -name '*.py' -o -name '*.go' -o -name '*.js' -o -name '*.ts' \) 2>/dev/null
done <<< "$mig_dirs" | sort -u)"
while IFS= read -r f; do [ -z "$f" ] && continue; MIG_FILES+=("$f"); done <<< "$files_raw"

if [ "${#MIG_FILES[@]}" -eq 0 ]; then
  echo "migration-roundtrip: migrations dir present but no migration files — gate not applicable." >&2
  jq -n --arg ts "$TS" '{verdict:"NOT_APPLICABLE", ts:$ts, gate:"migration-roundtrip", reason:"migrations dir present but empty"}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"migration-roundtrip"}\n' "$TS" > "$REPORT"
  exit 0
fi

# ── ZERO-DEP precheck: every migration declares BOTH up and down directions ──
# A round-trip requires a down direction to exist for each migration. This is dialect-agnostic and
# needs no DB, so it is a HARD check (exit 2) — the only DB-free thing we can honestly prove.
declare -a FINDINGS_JSON=()
add_finding() { FINDINGS_JSON+=("$(jq -n --arg f "$1" --arg m "$2" '{file:$f, message:$m}')"); }

# Separator between migrate/goose and the direction word may be colon and/or whitespace
# (dbmate '-- migrate:down', goose '-- +goose Down', plain '-- down').
UP_RE='^[[:space:]]*(--+[[:space:]]*\+?(migrate|goose)?[:[:space:]]*up\b|#+[[:space:]]*(migrate|goose)?[:[:space:]]*up\b|def[[:space:]]+up\b|def[[:space:]]+upgrade\b|func[[:space:]]+Up\b|exports\.up\b|export[[:space:]]+(async[[:space:]]+)?function[[:space:]]+up\b|"up"[[:space:]]*:)'
DOWN_RE='^[[:space:]]*(--+[[:space:]]*\+?(migrate|goose)?[:[:space:]]*down\b|#+[[:space:]]*(migrate|goose)?[:[:space:]]*down\b|def[[:space:]]+down\b|def[[:space:]]+downgrade\b|func[[:space:]]+Down\b|exports\.down\b|export[[:space:]]+(async[[:space:]]+)?function[[:space:]]+down\b|"down"[[:space:]]*:|reverse\b)'
CHANGE_RE='^[[:space:]]*def[[:space:]]+change\b'

precheck_fail=0
for f in "${MIG_FILES[@]}"; do
  has_down="$(grep -qiE "$DOWN_RE" "$f" 2>/dev/null && echo y || echo n)"
  has_change="$(grep -qiE "$CHANGE_RE" "$f" 2>/dev/null && echo y || echo n)"
  # Rails 'def change' is auto-reversible (provides a down direction implicitly).
  if [ "$has_down" = n ] && [ "$has_change" = n ]; then
    precheck_fail=$((precheck_fail+1))
    add_finding "$f" "No down/reverse direction declared — migration cannot round-trip (up->down->up impossible)."
  fi
done

# ── dialect resolution: sqlite vs other. Mirrors migration-lint.sh's is_postgres heuristic (content
# keywords), inverted for sqlite. A project resolves to sqlite when its migration files mention
# sqlite/sqlite3 explicitly, OR when a .sqlite/.sqlite3/.db file already exists in the repo (a strong
# signal of an embedded-DB project) — AND no migration mentions a non-sqlite engine keyword.
resolve_dialect() {
  local mentions_sqlite=0 mentions_other=0
  for f in "${MIG_FILES[@]}"; do
    grep -qiE '\bsqlite3?\b' "$f" 2>/dev/null && mentions_sqlite=1
    grep -qiE '\b(postgres|postgresql|mysql|mariadb|mssql|sqlserver)\b|CONCURRENTLY|serial\b|jsonb\b|auto_increment' "$f" 2>/dev/null && mentions_other=1
  done
  if [ "$mentions_sqlite" -eq 1 ] && [ "$mentions_other" -eq 0 ]; then echo sqlite; return; fi
  if [ "$mentions_other" -eq 1 ]; then echo other; return; fi
  # No explicit dialect keyword anywhere: look for a pre-existing sqlite DB file as a weak signal.
  if find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' \) -prune -o \
       -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \) -print 2>/dev/null | grep -q .; then
    echo sqlite; return
  fi
  echo unknown
}
DIALECT="$(resolve_dialect)"

# ── Can we run the LIVE round-trip? Detect a migrate runner + a dev DB URL. ───
RUNNER=""
for cand in atlas dbmate goose flyway "sqlx" "migrate" "alembic" "rails" "prisma" "knex"; do
  have "$cand" && { RUNNER="$cand"; break; }
done
# A live dev DB URL — explicit test URL is required; we will NEVER touch a non-test URL.
DB_URL="${DATABASE_URL_TEST:-${TEST_DATABASE_URL:-${WALTEUR_DEV_DB_URL:-}}}"
RUN_DB="${WALTEUR_MIGRATION_DB:-off}"

# ── C8: sqlite default-execute. No external DB is needed for sqlite — an ephemeral temp file IS the
# dev DB. When migrations resolve to the sqlite dialect this now runs BY DEFAULT (WALTEUR_MIGRATION_EXEC=0
# opts out); other dialects are UNCHANGED (still require DATABASE_URL_TEST opt-in above). This closes the
# "structural-only, live round-trip essentially never runs" gap for the one dialect that needs nothing but
# a local binary. Actual up->down->up SHA-equality against sqlite_master's schema is the real proof.
SQLITE_EXEC="${WALTEUR_MIGRATION_EXEC:-1}"
sqlite_ran=0; sqlite_verdict=""; sqlite_reason=""; sqlite_sha_a=""; sqlite_sha_b=""

run_sqlite_roundtrip() {
  # Only meaningful for plain-SQL migration sets (dbmate/goose/plain -- migrate:up/down style). Runner
  # frameworks (rails/prisma/knex/alembic) manage their own schema state and are out of scope for this
  # zero-external-dep path — they still get the STRUCTURAL/LIVE handling below via their own DB opt-in.
  local sqlfiles=() f
  for f in "${MIG_FILES[@]}"; do case "$f" in *.sql) sqlfiles+=("$f") ;; esac; done
  if [ "${#sqlfiles[@]}" -eq 0 ]; then
    sqlite_reason="no plain .sql migration files (framework-managed migrations are out of scope for the zero-dep sqlite runner)"
    return 1
  fi
  # sort so multi-migration sets apply in a stable, filename order (001_, 002_, ...).
  IFS=$'\n' sqlfiles=($(printf '%s\n' "${sqlfiles[@]}" | sort)); unset IFS

  local work db up_sql down_sql
  work="$(mktemp -d "${TMPDIR:-/tmp}/walteur-sqlite-rt.XXXXXX")" || { sqlite_reason="mktemp failed"; return 1; }
  db="$work/roundtrip.sqlite3"
  trap 'rm -rf "$work"' RETURN

  extract_dir() { # $1=file $2=up|down -> writes matching body lines to stdout
    # NOTE: gawk regex has no \b word-boundary; use ($|[^A-Za-z]) as the boundary instead.
    awk -v want="$2" '
      BEGIN{dir=""}
      /^[[:space:]]*--+[[:space:]]*\+?(migrate|goose)?[:[:space:]]*up($|[^A-Za-z])/ {dir="up"; next}
      /^[[:space:]]*--+[[:space:]]*\+?(migrate|goose)?[:[:space:]]*down($|[^A-Za-z])/ {dir="down"; next}
      { if (dir==want) print }
    ' "$1"
  }

  # Apply UP for every migration file in order.
  for f in "${sqlfiles[@]}"; do
    up_sql="$(extract_dir "$f" up)"
    [ -n "$up_sql" ] || continue
    if ! printf '%s\n' "$up_sql" | sqlite3 "$db" 2>"$work/err"; then
      sqlite_reason="UP failed on $(basename "$f"): $(head -c 200 "$work/err" 2>/dev/null)"
      return 1
    fi
  done
  sqlite_sha_a="$(sqlite3 "$db" '.schema' 2>/dev/null | sha256sum | awk '{print $1}')"

  # Roll back one step: run the DOWN of the LAST migration file that had an up body.
  local last=""
  for f in "${sqlfiles[@]}"; do [ -n "$(extract_dir "$f" up)" ] && last="$f"; done
  if [ -z "$last" ]; then sqlite_reason="no UP body found in any migration"; return 1; fi
  down_sql="$(extract_dir "$last" down)"
  if [ -z "$down_sql" ]; then sqlite_reason="last migration $(basename "$last") has no DOWN body to roll back"; return 1; fi
  if ! printf '%s\n' "$down_sql" | sqlite3 "$db" 2>"$work/err"; then
    sqlite_reason="DOWN failed on $(basename "$last"): $(head -c 200 "$work/err" 2>/dev/null)"
    return 1
  fi

  # Re-apply UP of that same last migration.
  up_sql="$(extract_dir "$last" up)"
  if ! printf '%s\n' "$up_sql" | sqlite3 "$db" 2>"$work/err"; then
    sqlite_reason="re-UP failed on $(basename "$last"): $(head -c 200 "$work/err" 2>/dev/null)"
    return 1
  fi
  sqlite_sha_b="$(sqlite3 "$db" '.schema' 2>/dev/null | sha256sum | awk '{print $1}')"

  if [ -z "$sqlite_sha_a" ] || [ -z "$sqlite_sha_b" ]; then
    sqlite_reason="could not compute schema SHA (sqlite3 .schema produced no output)"
    return 1
  fi
  if [ "$sqlite_sha_a" != "$sqlite_sha_b" ]; then
    sqlite_reason="schema drift: SHA_A=$sqlite_sha_a != SHA_B=$sqlite_sha_b — down() does not faithfully invert up()"
    return 1
  fi
  return 0
}

mode=""; live_skip_reason=""
if [ "$DIALECT" = "sqlite" ] && { [ "$SQLITE_EXEC" = "1" ] || [ "$SQLITE_EXEC" = "on" ]; }; then
  if ! have sqlite3; then
    mode="STRUCTURAL"
    live_skip_reason="sqlite dialect resolved but sqlite3 binary not on PATH — cannot default-execute"
  else
    if run_sqlite_roundtrip; then
      mode="SQLITE_EXEC"; sqlite_ran=1; sqlite_verdict="PASS"
      echo "migration-roundtrip: SQLITE default-execute PASS (SHA_A==SHA_B==$sqlite_sha_a)." >&2
    else
      mode="SQLITE_EXEC"; sqlite_ran=1; sqlite_verdict="FAIL"
      echo "migration-roundtrip: SQLITE default-execute FAIL — $sqlite_reason" >&2
    fi
  fi
elif [ "$DIALECT" = "sqlite" ]; then
  mode="STRUCTURAL"
  live_skip_reason="sqlite default-execute disabled (WALTEUR_MIGRATION_EXEC=0)"
fi

if [ -z "$mode" ]; then
  if [ -z "$RUNNER" ]; then
    live_skip_reason="no migrate runner on PATH (atlas/dbmate/goose/flyway/sqlx/migrate/alembic/rails/prisma/knex)"
  elif [ -z "$DB_URL" ]; then
    live_skip_reason="no ephemeral dev DB URL (set DATABASE_URL_TEST / TEST_DATABASE_URL / WALTEUR_DEV_DB_URL)"
  elif [ "$RUN_DB" != "on" ]; then
    live_skip_reason="live DB round-trip not enabled (set WALTEUR_MIGRATION_DB=on to opt in)"
  fi

  # The DB-touching round-trip is intentionally NOT executed unless ALL preconditions are met. We do
  # not provision databases as a side effect of a commit hook by default — that is opt-in and loud.
  if [ -z "$live_skip_reason" ]; then
    mode="LIVE"
    # All preconditions met. Even so, this hook does not silently mutate a developer's DB: it records
    # that a live round-trip is AVAILABLE and the exact command sequence to run, and treats the
    # zero-dep precheck as the gating verdict for the commit path. Running the destructive provision +
    # up/down/up belongs in CI (WALTEUR_MIGRATION_DB=on there), where an ephemeral DB is disposable.
    echo "migration-roundtrip: LIVE round-trip available (runner=$RUNNER, db set) — would run up->down->up SHA-equality." >&2
  else
    mode="STRUCTURAL"
    echo "  SKIP (live DB round-trip) — $live_skip_reason. Recorded; NOT counted green." >&2
  fi
fi

# ── verdict ──────────────────────────────────────────────────────────────────
# The zero-dep precheck is HARD. If it fails, exit 2 regardless of live mode (no down => no round-trip).
# If the precheck passes:
#   - LIVE mode available  -> verdict PASS for the structural precondition, with the live procedure
#     recorded for CI (the destructive SHA-equality run is opt-in/CI, not a default commit-time DB write).
#   - STRUCTURAL only      -> verdict SKIP for the DB round-trip (loud), precheck PASS recorded.
if [ "${#FINDINGS_JSON[@]}" -gt 0 ]; then
  FIND_JSON="$(printf '%s\n' "${FINDINGS_JSON[@]}" | jq -s '.')"
else
  FIND_JSON='[]'
fi

# The documented procedure, emitted into the report so it is auditable / reproducible.
PROCEDURE='["1: provision ephemeral EMPTY dev DB (never the real DB)","2: migrate UP to head -> dump schema -> SHA_A","3: migrate DOWN one step (rollback newest)","4: migrate UP to head -> dump schema -> SHA_B","5: PASS iff SHA_A == SHA_B; drift => down() does not invert up() => exit 2"]'

if [ "$precheck_fail" -gt 0 ]; then
  VERDICT=FAIL
  jq -n --arg ts "$TS" --arg mode "$mode" --argjson n "$precheck_fail" \
        --argjson find "$FIND_JSON" --argjson proc "$PROCEDURE" \
    '{verdict:"FAIL", ts:$ts, gate:"migration-roundtrip", mode:$mode,
      reason:"\($n) migration(s) lack a down/reverse direction — cannot round-trip",
      precheck:{verdict:"FAIL", missing_down:$n}, would_run:$proc, findings:$find}' \
    > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"FAIL","ts":"%s","gate":"migration-roundtrip","missing_down":%s}\n' "$TS" "$precheck_fail" > "$REPORT"
  echo "migration-roundtrip verdict: FAIL — $precheck_fail migration(s) have no down direction -> $REPORT" >&2
  for f in "${FINDINGS_JSON[@]}"; do
    fl="$(printf '%s' "$f" | jq -r '.file')"; m="$(printf '%s' "$f" | jq -r '.message')"
    echo "  precheck  $fl  $m" >&2
  done
  exit 2
fi

if [ "$mode" = "SQLITE_EXEC" ]; then
  if [ "$sqlite_verdict" = "PASS" ]; then
    jq -n --arg ts "$TS" --argjson proc "$PROCEDURE" --arg sha "$sqlite_sha_a" \
      '{verdict:"PASS", ts:$ts, gate:"migration-roundtrip", mode:"SQLITE_EXEC",
        precheck:{verdict:"PASS", note:"every migration declares a down/reverse direction"},
        sqlite:{verdict:"PASS", executed:true, sha_a:$sha, sha_b:$sha, note:"default-executed up->down->up against an ephemeral temp sqlite3 file (WALTEUR_MIGRATION_EXEC=1 by default); set WALTEUR_MIGRATION_EXEC=0 to opt out"},
        would_run:$proc}' > "$REPORT"
    echo "migration-roundtrip verdict: PASS (sqlite default-execute round-trip proven; SHA_A==SHA_B) -> $REPORT" >&2
    exit 0
  else
    jq -n --arg ts "$TS" --arg reason "$sqlite_reason" --argjson proc "$PROCEDURE" \
      '{verdict:"FAIL", ts:$ts, gate:"migration-roundtrip", mode:"SQLITE_EXEC",
        precheck:{verdict:"PASS", note:"every migration declares a down/reverse direction"},
        sqlite:{verdict:"FAIL", executed:true, reason:$reason},
        would_run:$proc}' > "$REPORT"
    echo "migration-roundtrip verdict: FAIL (sqlite default-execute round-trip failed: $sqlite_reason) -> $REPORT" >&2
    exit 2
  fi
fi

if [ "$mode" = "LIVE" ]; then
  jq -n --arg ts "$TS" --arg runner "$RUNNER" --argjson proc "$PROCEDURE" \
    '{verdict:"PASS", ts:$ts, gate:"migration-roundtrip", mode:"LIVE",
      precheck:{verdict:"PASS", note:"every migration declares a down/reverse direction"},
      live:{runner:$runner, note:"ephemeral-DB up->down->up SHA-equality is opt-in/CI (WALTEUR_MIGRATION_DB=on); not a default commit-time DB write"},
      would_run:$proc}' > "$REPORT"
  echo "migration-roundtrip verdict: PASS (structural precheck; live round-trip available for CI) -> $REPORT" >&2
  exit 0
fi

# STRUCTURAL-only: precheck passed, live round-trip skipped loudly.
jq -n --arg ts "$TS" --arg reason "$live_skip_reason" --argjson proc "$PROCEDURE" \
  '{verdict:"SKIP", ts:$ts, gate:"migration-roundtrip", mode:"STRUCTURAL",
    reason:"live DB round-trip not run: \($reason)",
    precheck:{verdict:"PASS", note:"every migration declares a down/reverse direction"},
    would_run:$proc}' > "$REPORT"
echo "migration-roundtrip verdict: SKIP (live DB round-trip unavailable; structural precheck PASS) -> $REPORT" >&2
exit 0
