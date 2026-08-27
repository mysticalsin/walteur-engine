#!/usr/bin/env bash
# WALTEUR migration-lint — honest zero-dep migration-safety gate + detect-or-loud-SKIP linters.
# Applies ONLY if a migrations directory is present:
#   db/migrate | migrations | alembic | prisma/migrations | a *.sql file inside any *migrate* path.
# If none present: gate not applicable (verdict NOT_APPLICABLE, exit 0).
#
# ZERO-DEP HARD checks (bash/grep/awk/sed/find/jq only — ALWAYS run when applicable, real exit 2):
#   C1  Reversibility: every migration file must carry a non-empty rollback.
#       FAIL if a migration has NO down/reverse at all, OR has a down/reverse whose body is
#       effectively empty: only 'NotImplementedError', 'pass', '-- no rollback', 'irreversible',
#       'raise', or blank.
#   C2  Expand→contract: FAIL if the SAME file both ADDs (ADD COLUMN / CREATE TABLE / create_table /
#       add_column) and DROPs (DROP COLUMN / DROP TABLE / drop_column / drop_table / remove_column).
#       Add and destroy in one migration breaks safe online rollout (Stripe/GitHub expand-contract).
#   C3  Postgres index lock: FAIL on 'CREATE INDEX' without 'CONCURRENTLY' (postgres dialect only).
#   C4  Unsafe NOT NULL: FAIL on 'SET NOT NULL' or 'ADD COLUMN ... NOT NULL' with no DEFAULT —
#       rewrites/locks the table on large data (table-rewrite hazard).
#
# DETECT-OR-SKIP linters (run only if the binary exists; absent => loud recorded SKIP, never green):
#   squawk <sql-files>      — Postgres migration linter (paule96/squawk). Any lint => violation.
#   atlas migrate lint      — Ariga Atlas schema-migration linter. Any diagnostic => violation.
#
# Tool ABSENT for the optional linters => SKIP that sub-check loudly (recorded). The zero-dep checks
# need only POSIX tools (always present), so they are HARD and always decide the verdict.
# NEVER silent-green; NEVER exit 2 for a MISSING optional tool. Applicable + real violation => exit 2.
# Report: walteur-kit/migration-report.json  {verdict, ts, gate, violations, details, files}.
# Bypass: WALTEUR_MIGRATION=off.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/migration-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

selftest() {
  local pass=0 fail=0 tmp
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

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
CREATE INDEX CONCURRENTLY idx_accounts_id ON accounts(id);

-- migrate:down
DROP TABLE accounts;'

  echo "migration-lint selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no migrations -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-lint-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "$valid_sql"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "valid reversible migration -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-lint-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "-- migrate:up
CREATE TABLE accounts (id bigint primary key);"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "missing rollback -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-lint-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "-- migrate:up
CREATE TABLE accounts (id bigint primary key);

-- migrate:down
-- no rollback"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "empty rollback -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-lint-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "-- migrate:up
CREATE TABLE accounts (id bigint primary key);
DROP TABLE old_accounts;

-- migrate:down
CREATE TABLE old_accounts (id bigint primary key);
DROP TABLE accounts;"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "expand and contract in up -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-lint-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "-- migrate:up
CREATE TABLE accounts (id bigint primary key);
CREATE INDEX idx_accounts_id ON accounts(id);

-- migrate:down
DROP TABLE accounts;"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "CREATE INDEX without CONCURRENTLY -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-lint-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "-- migrate:up
CREATE TABLE accounts (id bigint primary key);
ALTER TABLE accounts ADD COLUMN name text NOT NULL;

-- migrate:down
DROP TABLE accounts;"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "unsafe NOT NULL without DEFAULT -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-lint-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "$valid_sql"
  WALTEUR_ROOT="$tmp" WALTEUR_MIGRATION=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/migration-lint-selftest.XXXXXX")" || return 1
  make_sql "$tmp" "$valid_sql"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "migration-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_MIGRATION:-on}" = "off" ] && { echo "migration-lint: bypassed (WALTEUR_MIGRATION=off)." >&2; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }
# jq is needed to emit the report; if even jq is missing, emit a literal SKIP and stop honestly.
if ! have jq; then
  echo "WALTEUR migration-lint SKIP — required tool 'jq' not installed (recorded, not silent-green)." >&2
  printf '{"verdict":"SKIP","ts":"%s","gate":"migration","reason":"jq not installed"}\n' "$TS" > "$REPORT"
  exit 0
fi
TMP="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"; trap 'rm -f "$TMP"' EXIT

# ── applicability detection ───────────────────────────────────────────────────
# A migrations dir is one of the well-known names (db/migrate, migrations, alembic,
# prisma/migrations, …), OR any directory matching *migrat* that contains a *.sql file.
# Collect the set of migration FILES to lint from those dirs.
mig_dirs=""
add_dir() { [ -n "$1" ] && [ -d "$1" ] && mig_dirs="$mig_dirs
$1"; }

# Well-known directory layouts by basename (search anywhere under root).
while IFS= read -r d; do
  [ -z "$d" ] && continue
  case "$(basename "$d")" in migrate|migrations|alembic|versions) add_dir "$d" ;; esac
done <<EOF
$(find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' \) -prune -o -type d \( -name migrate -o -name migrations -o -name alembic -o -name versions \) -print 2>/dev/null)
EOF

# prisma/migrations specifically (a dir literally at prisma/migrations).
while IFS= read -r d; do
  add_dir "$d"
done <<EOF
$(find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' \) -prune -o -type d -path '*/prisma/migrations' -print 2>/dev/null)
EOF

# Any *migrat* path containing a *.sql file.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  add_dir "$(dirname "$f")"
done <<EOF
$(find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' \) -prune -o -type f -name '*.sql' -path '*migrat*' -print 2>/dev/null)
EOF

# Dedupe directories.
mig_dirs="$(printf '%s\n' "$mig_dirs" | sed '/^$/d' | sort -u)"

if [ -z "$mig_dirs" ]; then
  echo "migration-lint: no migrations dir (db/migrate, migrations, alembic, prisma/migrations, *.sql in a migrate path) — gate not applicable." >&2
  jq -n --arg ts "$TS" '{verdict:"NOT_APPLICABLE", ts:$ts, gate:"migration", reason:"no migrations directory present"}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"migration"}\n' "$TS" > "$REPORT"
  exit 0
fi

# Collect migration FILES from those directories (the lintable corpus).
# Nested dirs (e.g. alembic + alembic/versions) can surface the same file twice — dedupe with sort -u.
MIG_FILES=()
files_raw="$(while IFS= read -r d; do
  [ -z "$d" ] && continue
  find "$d" -maxdepth 4 -type f \( -name '*.sql' -o -name '*.rb' -o -name '*.py' -o -name '*.go' -o -name '*.js' -o -name '*.ts' \) 2>/dev/null
done <<< "$mig_dirs" | sort -u)"
while IFS= read -r f; do
  [ -z "$f" ] && continue
  MIG_FILES+=("$f")
done <<< "$files_raw"

if [ "${#MIG_FILES[@]}" -eq 0 ]; then
  echo "migration-lint: migrations dir present but no migration files (*.sql/*.rb/*.py/*.go/*.js/*.ts) inside — gate not applicable." >&2
  jq -n --arg ts "$TS" '{verdict:"NOT_APPLICABLE", ts:$ts, gate:"migration", reason:"migrations dir present but empty of migration files"}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"migration"}\n' "$TS" > "$REPORT"
  exit 0
fi

loud_skip() { echo "  SKIP — $1 not installed ($2). Recorded; NOT counted green." >&2; }
violations=0; ran=0
J='{}'
add() { J="$(printf '%s' "$J" | jq --argjson v "$2" --arg k "$1" '.[$k]=$v' 2>/dev/null || printf '%s' "$J")"; }

declare -a FINDINGS_JSON=()
add_finding() { # $1=check  $2=file  $3=line(int)  $4=message
  FINDINGS_JSON+=("$(jq -n --arg c "$1" --arg f "$2" --argjson ln "$3" --arg m "$4" \
    '{check:$c, file:$f, line:$ln, message:$m}')")
}

echo "WALTEUR migration-lint @ $ROOT (${#MIG_FILES[@]} migration file(s))" >&2

# Heuristic: is this file Postgres-dialect? Default to YES for *.sql (the strict, safe default) and
# for any file whose content mentions postgres/serial/CONCURRENTLY; downgrade only if it clearly
# names a non-postgres dialect (mysql/sqlite) and never says postgres.
is_postgres() { # $1=file
  local f="$1"
  case "$f" in *.sql) ;; *) ;; esac
  if grep -qiE 'postgre|::|CONCURRENTLY|serial|jsonb|using btree|tsvector' "$f" 2>/dev/null; then return 0; fi
  if grep -qiE '\b(mysql|mariadb|sqlite|sqlite3|innodb|auto_increment)\b' "$f" 2>/dev/null; then return 1; fi
  # default-strict: treat unknown SQL as postgres so CONCURRENTLY is enforced.
  case "$f" in *.sql) return 0 ;; *) return 0 ;; esac
}

# ── direction markers (centralised so every check agrees on what "up"/"down" looks like) ──
# Supports: dbmate '-- migrate:down' (colon), goose '-- +goose Down', plain '-- down',
# Rails 'def down', Alembic 'def downgrade', Go 'func Down', knex/node 'exports.down' /
# 'export function down' / '"down":', and a generic 'reverse'. The separator between
# migrate/goose and the direction word may be colon and/or whitespace.
UP_MARKER='^[[:space:]]*(--+[[:space:]]*\+?(migrate|goose)?[:[:space:]]*up\b|#+[[:space:]]*(migrate|goose)?[:[:space:]]*up\b|def[[:space:]]+up\b|def[[:space:]]+upgrade\b|func[[:space:]]+Up\b|exports\.up\b|export[[:space:]]+(async[[:space:]]+)?function[[:space:]]+up\b|"up"[[:space:]]*:)'
DOWN_MARKER='^[[:space:]]*(--+[[:space:]]*\+?(migrate|goose)?[:[:space:]]*down\b|#+[[:space:]]*(migrate|goose)?[:[:space:]]*down\b|def[[:space:]]+down\b|def[[:space:]]+downgrade\b|func[[:space:]]+Down\b|exports\.down\b|export[[:space:]]+(async[[:space:]]+)?function[[:space:]]+down\b|"down"[[:space:]]*:|reverse\b)'

# ── C1 reversibility: every migration carries a non-empty rollback ────────────
c1_fail=0
for f in "${MIG_FILES[@]}"; do
  # Locate a down/reverse marker.
  has_marker="$(grep -niE "$DOWN_MARKER" "$f" 2>/dev/null | head -1 || true)"

  # Rails reversible 'def change' counts as a present rollback (auto-reversible) UNLESS it contains
  # an irreversible op without a down (raw execute / drop without info). Treat 'def change' present
  # AND no raw 'execute(' as reversible.
  has_change="$(grep -niE '^[[:space:]]*def[[:space:]]+change\b' "$f" 2>/dev/null | head -1 || true)"

  if [ -z "$has_marker" ] && [ -z "$has_change" ]; then
    c1_fail=$((c1_fail+1))
    add_finding "C1" "$f" 0 "No down()/reverse rollback found (and no auto-reversible 'def change')."
    continue
  fi

  if [ -n "$has_change" ] && [ -z "$has_marker" ]; then
    # Rails 'def change' — reversible unless it uses raw execute( without a self-provided direction.
    if grep -qiE 'execute[[:space:]]*\(' "$f" 2>/dev/null; then
      c1_fail=$((c1_fail+1))
      add_finding "C1" "$f" 0 "'def change' uses raw execute() — not auto-reversible and no explicit down."
    fi
    continue
  fi

  # We have a down/reverse marker. Extract the body that follows the FIRST marker line and test it
  # for emptiness / known no-op placeholders.
  ml="${has_marker%%:*}"
  # Extract the body after the down marker, stopping at the NEXT up marker (some single-file formats
  # put up after down, e.g. a second '-- migrate:up'). Pass the up regex into awk as data.
  body="$(awk -v start="$ml" -v upre="$UP_MARKER" '
    NR>start {
      ln=$0
      if (ln ~ upre) exit
      print ln
    }' "$f")"
  # Normalise: strip comments-only/blank lines and obvious no-op tokens; what remains must be real.
  real="$(printf '%s\n' "$body" \
    | sed -E 's/--+[[:space:]]*no[[:space:]]*rollback.*//I' \
    | sed -E '/^[[:space:]]*$/d' \
    | grep -viE '^[[:space:]]*(--|#|//)' \
    | grep -viE '^[[:space:]]*(pass|NotImplementedError|raise[[:space:]]+NotImplementedError.*|raise\b.*|irreversible.*|ActiveRecord::IrreversibleMigration.*|return[[:space:]]*(nil|None)?[[:space:]]*;?)[[:space:]]*$' \
    | sed -E '/^[[:space:]]*[{}();,]*[[:space:]]*$/d' \
    | head -1 || true)"
  if [ -z "$real" ]; then
    c1_fail=$((c1_fail+1))
    add_finding "C1" "$f" "$ml" "Empty / no-op rollback (only blank, 'pass', 'NotImplementedError', '-- no rollback', or 'raise')."
  fi
done
[ "$c1_fail" -gt 0 ] && violations=$((violations+1))
add c1_reversibility "$(jq -n --argjson n "$c1_fail" --arg v "$([ "$c1_fail" -gt 0 ] && echo FAIL || echo PASS)" '{verdict:$v, check:"C1 reversibility (non-empty down/reverse)", failing_files:$n}')"

# ── C2 expand→contract violation in one file ─────────────────────────────────
c2_fail=0
ADD_RE='ADD[[:space:]]+COLUMN|CREATE[[:space:]]+TABLE|create_table|add_column|\.createTable|createTable\('
DROP_RE='DROP[[:space:]]+COLUMN|DROP[[:space:]]+TABLE|drop_column|drop_table|remove_column|\.dropTable|dropColumn\('
for f in "${MIG_FILES[@]}"; do
  has_add="$(grep -niE "$ADD_RE" "$f" 2>/dev/null | head -1 || true)"
  has_drop="$(grep -niE "$DROP_RE" "$f" 2>/dev/null | head -1 || true)"
  if [ -n "$has_add" ] && [ -n "$has_drop" ]; then
    # A DROP that lives in the down/reverse section is the LEGITIMATE inverse — not a violation.
    # Find the first down marker line; flag only the FIRST drop that appears at/above it (i.e. in 'up').
    dl="$(grep -niE "$DOWN_MARKER" "$f" 2>/dev/null | head -1 | cut -d: -f1 || true)"
    # First drop that sits in the up section (line < dl), if any.
    up_drop_line=""
    while IFS= read -r dhit; do
      [ -z "$dhit" ] && continue
      dn="${dhit%%:*}"
      if [ -z "$dl" ] || { [ "$dn" -lt "$dl" ] 2>/dev/null; }; then up_drop_line="$dn"; break; fi
    done <<EOF
$(grep -niE "$DROP_RE" "$f" 2>/dev/null)
EOF
    if [ -n "$up_drop_line" ]; then
      c2_fail=$((c2_fail+1))
      add_finding "C2" "$f" "$up_drop_line" "Same migration both ADDs and DROPs in the up direction (expand+contract together) — split into expand then contract."
    fi
  fi
done
[ "$c2_fail" -gt 0 ] && violations=$((violations+1))
add c2_expand_contract "$(jq -n --argjson n "$c2_fail" --arg v "$([ "$c2_fail" -gt 0 ] && echo FAIL || echo PASS)" '{verdict:$v, check:"C2 expand+contract in one migration", failing_files:$n}')"

# ── C3 CREATE INDEX without CONCURRENTLY (postgres) ──────────────────────────
c3_fail=0
for f in "${MIG_FILES[@]}"; do
  is_postgres "$f" || continue
  # Each CREATE INDEX line that lacks CONCURRENTLY (case-insensitive). Allow 'CREATE INDEX CONCURRENTLY'
  # and 'CREATE UNIQUE INDEX CONCURRENTLY'. add_index ..., algorithm: :concurrently counts as ok.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    hln="${hit%%:*}"
    add_finding "C3" "$f" "$hln" "CREATE INDEX without CONCURRENTLY (postgres) — locks writes on the table."
    c3_fail=$((c3_fail+1))
  done <<EOF
$(grep -niE 'CREATE([[:space:]]+UNIQUE)?[[:space:]]+INDEX' "$f" 2>/dev/null | grep -viE 'CONCURRENTLY' || true)
EOF
  # Rails add_index without concurrent algorithm (only if postgres-ish file).
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    hln="${hit%%:*}"
    add_finding "C3" "$f" "$hln" "add_index without algorithm: :concurrently (postgres) — locks writes."
    c3_fail=$((c3_fail+1))
  done <<EOF
$(grep -niE 'add_index' "$f" 2>/dev/null | grep -viE 'concurrent' || true)
EOF
done
[ "$c3_fail" -gt 0 ] && violations=$((violations+1))
add c3_index_concurrently "$(jq -n --argjson n "$c3_fail" --arg v "$([ "$c3_fail" -gt 0 ] && echo FAIL || echo PASS)" '{verdict:$v, check:"C3 CREATE INDEX without CONCURRENTLY (postgres)", findings:$n}')"

# ── C4 SET NOT NULL / ADD COLUMN ... NOT NULL without DEFAULT ─────────────────
c4_fail=0
for f in "${MIG_FILES[@]}"; do
  # (a) bare 'SET NOT NULL' is unsafe on a populated table (full validate/rewrite, locks).
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    hln="${hit%%:*}"
    add_finding "C4" "$f" "$hln" "ALTER ... SET NOT NULL on existing column — locks + scans the table; add a validated NOT VALID constraint instead."
    c4_fail=$((c4_fail+1))
  done <<EOF
$(grep -niE 'SET[[:space:]]+NOT[[:space:]]+NULL' "$f" 2>/dev/null || true)
EOF
  # (b) ADD COLUMN ... NOT NULL with NO DEFAULT on the same logical statement.
  #     awk reconstructs statements terminated by ';' so a multi-line ADD COLUMN is judged as a whole.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    hln="${hit%%|*}"
    add_finding "C4" "$f" "$hln" "ADD COLUMN ... NOT NULL without DEFAULT — table rewrite/lock; supply a DEFAULT or backfill+constraint."
    c4_fail=$((c4_fail+1))
  done <<EOF
$(awk '
  BEGIN{IGNORECASE=1; stmt=""; al=0}
  {
    stmt=stmt " " $0
    if (al==0 && $0 ~ /ADD[ \t]+COLUMN/) al=NR   # remember the line carrying ADD COLUMN
    if ($0 ~ /;/) {
      if (stmt ~ /ADD[ \t]+COLUMN/ && stmt ~ /NOT[ \t]+NULL/ && stmt !~ /DEFAULT/) print (al?al:NR) "|hit"
      stmt=""; al=0
    }
  }
  END{
    if (stmt ~ /ADD[ \t]+COLUMN/ && stmt ~ /NOT[ \t]+NULL/ && stmt !~ /DEFAULT/) print (al?al:NR) "|hit"
  }' "$f" 2>/dev/null || true)
EOF
  # (c) Rails add_column ..., null: false without default:
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    hln="${hit%%:*}"
    add_finding "C4" "$f" "$hln" "add_column ..., null: false without default: — unsafe NOT NULL backfill."
    c4_fail=$((c4_fail+1))
  done <<EOF
$(grep -niE 'add_column.*null:[[:space:]]*false' "$f" 2>/dev/null | grep -viE 'default:' || true)
EOF
done
[ "$c4_fail" -gt 0 ] && violations=$((violations+1))
add c4_not_null "$(jq -n --argjson n "$c4_fail" --arg v "$([ "$c4_fail" -gt 0 ] && echo FAIL || echo PASS)" '{verdict:$v, check:"C4 unsafe NOT NULL without default", findings:$n}')"

# zero-dep checks always ran:
ran=$((ran+4))

# ── DETECT-OR-SKIP: squawk (Postgres migration linter) ───────────────────────
SQL_FILES=()
for f in "${MIG_FILES[@]}"; do case "$f" in *.sql) SQL_FILES+=("$f") ;; esac; done
if have squawk; then
  if [ "${#SQL_FILES[@]}" -gt 0 ]; then
    ran=$((ran+1))
    if squawk "${SQL_FILES[@]}" >"$TMP" 2>&1; then
      echo "  ok   — squawk: no lint findings." >&2
      add squawk '{"verdict":"PASS","tool":"squawk"}'
    else
      echo "  FAIL — squawk: lint finding(s)." >&2
      violations=$((violations+1))
      add squawk "$(jq -n --arg n "${#SQL_FILES[@]}" '{verdict:"FAIL",tool:"squawk",sql_files:($n|tonumber)}')"
    fi
  else
    echo "  SKIP — squawk: installed but no *.sql migration files to lint." >&2
    add squawk '{"verdict":"SKIP","reason":"no *.sql migration files (squawk installed)"}'
  fi
else
  loud_skip squawk "Postgres migration linter"
  add squawk '{"verdict":"SKIP","reason":"squawk not installed"}'
fi

# ── DETECT-OR-SKIP: atlas migrate lint ───────────────────────────────────────
if have atlas; then
  # atlas lint needs a migrate dir + a dev DB URL; run best-effort against the first migrations dir.
  first_dir="$(printf '%s\n' "$mig_dirs" | head -1)"
  ran=$((ran+1))
  if atlas migrate lint --dir "file://$first_dir" --latest 1 >"$TMP" 2>&1; then
    echo "  ok   — atlas migrate lint: no diagnostics." >&2
    add atlas '{"verdict":"PASS","tool":"atlas migrate lint"}'
  else
    # atlas exits non-zero both for diagnostics AND for env problems (no dev DB). Distinguish:
    if grep -qiE 'dev.url|connect|driver|no such|unknown flag|Error:.*url' "$TMP" 2>/dev/null; then
      echo "  SKIP — atlas: installed but no dev DB / config to lint against (recorded, not green)." >&2
      add atlas '{"verdict":"SKIP","reason":"atlas installed but no dev DB / config available"}'
    else
      echo "  FAIL — atlas migrate lint: diagnostic(s)." >&2
      violations=$((violations+1))
      add atlas '{"verdict":"FAIL","tool":"atlas migrate lint"}'
    fi
  fi
else
  loud_skip atlas "schema-migration linter (Ariga Atlas)"
  add atlas '{"verdict":"SKIP","reason":"atlas not installed"}'
fi

# ── verdict ──────────────────────────────────────────────────────────────────
# Zero-dep checks always run, so OVERALL is never SKIP here: FAIL on any violation, else PASS.
if [ "$violations" -gt 0 ]; then OVERALL=FAIL; else OVERALL=PASS; fi

if [ "${#FINDINGS_JSON[@]}" -gt 0 ]; then
  FIND_JSON="$(printf '%s\n' "${FINDINGS_JSON[@]}" | jq -s '.')"
else
  FIND_JSON='[]'
fi

jq -n --arg v "$OVERALL" --arg ts "$TS" --argjson ran "$ran" \
      --argjson viol "$violations" --argjson tools "$J" --argjson find "$FIND_JSON" \
      --argjson nf "${#MIG_FILES[@]}" \
  '{verdict:$v, ts:$ts, gate:"migration", checks_ran:$ran, migration_files:$nf,
    violations:$viol, details:$tools, findings:$find}' \
  > "$REPORT" 2>/dev/null \
  || printf '{"verdict":"%s","ts":"%s","gate":"migration","checks_ran":%s,"violations":%s}\n' "$OVERALL" "$TS" "$ran" "$violations" > "$REPORT"

echo "migration-lint verdict: $OVERALL (checks_ran=$ran, violations=$violations) -> $REPORT" >&2
if [ "$OVERALL" = "FAIL" ]; then
  for f in "${FINDINGS_JSON[@]}"; do
    c="$(printf '%s' "$f" | jq -r '.check')"
    fl="$(printf '%s' "$f" | jq -r '.file')"
    l="$(printf '%s' "$f" | jq -r '.line')"
    m="$(printf '%s' "$f" | jq -r '.message')"
    if [ "$l" != "0" ]; then echo "  $c  $fl:$l  $m" >&2; else echo "  $c  $fl  $m" >&2; fi
  done
  exit 2
fi
exit 0
