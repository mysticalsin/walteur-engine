#!/usr/bin/env bash
# WALTEUR schema-lint — honest zero-dep schema/model/migration safety gate (+ detect-or-loud-SKIP live DB).
# Applies ONLY if schema/model/migration source is present:
#   *.sql | models.py | schema.prisma | *.entity.ts | a migrations/ directory.
# If none present: gate not applicable (verdict NOT_APPLICABLE, exit 0) — a bare project is NOT a violation.
#
# ZERO-DEP HARD checks (bash/grep/awk/sed/find/jq only — ALWAYS run when applicable, real exit 2):
#   S1  Money precision: FAIL on a FLOAT/REAL/DOUBLE (or Prisma Float / TS number) declared for a money
#       column whose NAME matches /price|amount|cost|balance|total|fee/. Binary floats can't represent
#       cents exactly — money must be NUMERIC/DECIMAL (or an integer-cents type), never float.
#   S2  Timestamp without timezone: FAIL on a timestamp/datetime column that is NOT timezone-aware —
#       i.e. no 'timestamptz' / 'timestamp with time zone' / 'with time zone' / DateTime(timezone=True) /
#       Prisma '@db.Timestamptz'. A naive timestamp silently corrupts cross-zone data.
#   S3  No primary key: FAIL on a CREATE TABLE / SQLAlchemy model / Prisma model / @Entity class that
#       declares no primary key (PRIMARY KEY / primary_key=True / @id / @PrimaryColumn|@PrimaryGeneratedColumn).
#   S4  Free-text status/enum: FAIL on a column whose NAME is status/type/state/kind/role/...-ish declared
#       as a free-text VARCHAR/TEXT/String with NO CHECK constraint, NO enum type, and NO lookup/FK —
#       an unconstrained status column is a bug magnet.
#
# DETECT-OR-SKIP (live DB introspection): if a DSN env var is set AND psql/sqlite3 is on PATH, the gate
# WOULD additionally introspect the live catalog (information_schema / pragma) to confirm the running
# schema matches these rules. Tool/DSN absent => that sub-check is a LOUD recorded SKIP (never green,
# never exit 2 for a missing tool). The zero-dep checks need only POSIX tools, so they decide the verdict.
#
# NEVER silent-green; NEVER exit 2 for a MISSING tool or an inapplicable project. Applicable + real
# violation => exit 2.  Report: walteur-kit/schema-report.json  {verdict, ts, gate, violations, details, findings}.
# Bypass: WALTEUR_SCHEMA=off.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "schema-lint - honest zero-dep schema/model/migration safety gate (+ detect-or-loud-SKIP live DB)."
  printf '%s\n' "usage: bash schema-lint.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/schema-report.json - fix recipes: walteur-kit/REMEDIATION.md (## schema-lint)"
  printf '%s\n' "bypass: WALTEUR_SCHEMA=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/schema-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

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

  if ! have jq; then
    echo "schema-lint selftest SKIP - jq not installed."
    return 0
  fi

  echo "schema-lint selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/schema-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no schema source -> NOT_APPLICABLE exit" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/schema-report.json" >/dev/null 2>&1
  ck "no schema source report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/schema-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/schema.sql" <<'SQL'
CREATE TABLE orders (
  id BIGSERIAL PRIMARY KEY,
  total_amount NUMERIC(12,2) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  status TEXT CHECK (status IN ('open', 'closed'))
);
SQL
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "valid SQL schema -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .schema_files == 1 and .violations == 0' "$tmp/walteur-kit/schema-report.json" >/dev/null 2>&1
  ck "valid SQL schema report records PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/schema-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/schema.sql" <<'SQL'
CREATE TABLE payments (
  amount FLOAT,
  created_at TIMESTAMP,
  status VARCHAR(20)
);
SQL
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "bad SQL schema -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .violations >= 1 and (.findings | length) >= 1' "$tmp/walteur-kit/schema-report.json" >/dev/null 2>&1
  ck "bad SQL schema report records findings" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/schema-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'CREATE TABLE x (amount FLOAT);\n' > "$tmp/schema.sql"
  WALTEUR_ROOT="$tmp" WALTEUR_SCHEMA=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/schema-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/schema-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "schema-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_SCHEMA:-on}" = "off" ] && {
  echo "schema-lint: bypassed (WALTEUR_SCHEMA=off)." >&2
  printf '{"verdict":"SKIP","ts":"%s","gate":"schema","reason":"bypassed via WALTEUR_SCHEMA=off"}\n' "$TS" > "$REPORT" 2>/dev/null || true
  exit 0
}

# jq is needed to emit the structured report; if even jq is missing, emit a literal SKIP and stop honestly.
if ! have jq; then
  echo "WALTEUR schema-lint SKIP — required tool 'jq' not installed (recorded, not silent-green)." >&2
  printf '{"verdict":"SKIP","ts":"%s","gate":"schema","reason":"jq not installed"}\n' "$TS" > "$REPORT"
  exit 0
fi

PRUNE='( -path */.git -o -path */node_modules -o -path */.venv -o -path */vendor -o -path */dist -o -path */build )'

# ── applicability detection ───────────────────────────────────────────────────
# Collect schema/model/migration source files: *.sql, models.py, schema.prisma, *.entity.ts,
# and any *.sql/*.py inside a migrations/ directory.
SCHEMA_FILES=()
files_raw="$(
  find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' -o -path '*/dist' -o -path '*/build' \) -prune -o \
    -type f \( -name '*.sql' -o -name 'models.py' -o -name 'schema.prisma' -o -name '*.entity.ts' \) -print 2>/dev/null
  # any *.py/*.sql living under a migrations/ directory
  find "$ROOT" \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' -o -path '*/dist' -o -path '*/build' \) -prune -o \
    -type f \( -name '*.sql' -o -name '*.py' \) -path '*/migrations/*' -print 2>/dev/null
)"
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] && SCHEMA_FILES+=("$f")
done <<< "$(printf '%s\n' "$files_raw" | sort -u)"

if [ "${#SCHEMA_FILES[@]}" -eq 0 ]; then
  echo "schema-lint: no schema/model/migration source (*.sql, models.py, schema.prisma, *.entity.ts, migrations/) — gate not applicable." >&2
  jq -n --arg ts "$TS" '{verdict:"NOT_APPLICABLE", ts:$ts, gate:"schema", reason:"no schema/model/migration source present"}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"schema"}\n' "$TS" > "$REPORT"
  exit 0
fi

echo "WALTEUR schema-lint @ $ROOT (${#SCHEMA_FILES[@]} schema source file(s))" >&2

violations=0
J='{}'
add() { J="$(printf '%s' "$J" | jq --argjson v "$2" --arg k "$1" '.[$k]=$v' 2>/dev/null || printf '%s' "$J")"; }
FINDINGS_JSON=()
add_finding() { # $1=check  $2=file  $3=line(int)  $4=message
  FINDINGS_JSON+=("$(jq -n --arg c "$1" --arg f "$2" --argjson ln "$3" --arg m "$4" \
    '{check:$c, file:$f, line:$ln, message:$m}')")
}

MONEY_RE='(price|amount|cost|balance|total|fee)'
STATUS_RE='(status|state|kind|role|category|severity|priority|stage|phase|level|tier|visibility|type)'

# ── S1 money column declared as a binary float ────────────────────────────────
# SQL: a line declaring a money-named column with FLOAT/REAL/DOUBLE.
# Prisma/TS: a money-named field typed Float (Prisma) or number (TS entity).
s1_fail=0
for f in "${SCHEMA_FILES[@]}"; do
  case "$(basename "$f")" in
    *.sql)
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        hln="${hit%%:*}"
        add_finding "S1" "$f" "$hln" "Money-named column uses a binary float (FLOAT/REAL/DOUBLE) — use NUMERIC/DECIMAL or integer cents; floats can't represent money exactly."
        s1_fail=$((s1_fail+1))
      done <<EOF
$(grep -niE "[a-z_]*${MONEY_RE}[a-z_]*[[:space:]]+(FLOAT|REAL|DOUBLE([[:space:]]+PRECISION)?)\b" "$f" 2>/dev/null || true)
EOF
      ;;
    schema.prisma)
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        hln="${hit%%:*}"
        add_finding "S1" "$f" "$hln" "Money-named Prisma field typed Float — use Decimal @db.Decimal; floats can't represent money exactly."
        s1_fail=$((s1_fail+1))
      done <<EOF
$(grep -niE "^[[:space:]]*[a-zA-Z_]*${MONEY_RE}[a-zA-Z_]*[[:space:]]+Float\b" "$f" 2>/dev/null || true)
EOF
      ;;
    *.entity.ts)
      # @Column('float'|'real'|'double'|...) OR a money-named property typed : number
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        hln="${hit%%:*}"
        add_finding "S1" "$f" "$hln" "Money-named TS column typed as float/number — use a decimal column type ('decimal'/'numeric') with precision/scale."
        s1_fail=$((s1_fail+1))
      done <<EOF
$(grep -niE "^[[:space:]]*[a-zA-Z_]*${MONEY_RE}[a-zA-Z_]*[[:space:]]*:[[:space:]]*number\b" "$f" 2>/dev/null || true)
$(grep -niE "@Column\([^)]*(['\"](float|real|double[[:space:]]*precision)['\"])" "$f" 2>/dev/null | grep -iE "${MONEY_RE}" || true)
EOF
      ;;
  esac
done
[ "$s1_fail" -gt 0 ] && violations=$((violations+1))
add s1_money_float "$(jq -n --argjson n "$s1_fail" --arg v "$([ "$s1_fail" -gt 0 ] && echo FAIL || echo PASS)" '{verdict:$v, check:"S1 money column as binary float", findings:$n}')"

# ── S2 timestamp/datetime column without timezone awareness ───────────────────
s2_fail=0
for f in "${SCHEMA_FILES[@]}"; do
  case "$(basename "$f")" in
    *.sql)
      # Each line declaring a TIMESTAMP / DATETIME that is NOT timezone-aware.
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        hln="${hit%%:*}"
        add_finding "S2" "$f" "$hln" "TIMESTAMP/DATETIME without timezone — use 'timestamptz' / 'timestamp with time zone'; naive timestamps corrupt cross-zone data."
        s2_fail=$((s2_fail+1))
      done <<EOF
$(grep -niE '\b(TIMESTAMP|DATETIME)\b' "$f" 2>/dev/null | grep -viE 'timestamptz|with[[:space:]]+time[[:space:]]+zone|timestamp[[:space:]]+with' || true)
EOF
      ;;
    models.py)
      # SQLAlchemy DateTime() / TIMESTAMP() without timezone=True. Match the DateTime(...) call.
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        hln="${hit%%:*}"
        add_finding "S2" "$f" "$hln" "SQLAlchemy DateTime/TIMESTAMP without timezone=True — pass timezone=True so the column is tz-aware."
        s2_fail=$((s2_fail+1))
      done <<EOF
$(grep -niE '\b(DateTime|TIMESTAMP)[[:space:]]*\(' "$f" 2>/dev/null | grep -viE 'timezone[[:space:]]*=[[:space:]]*True' || true)
EOF
      ;;
    schema.prisma)
      # Prisma DateTime field without @db.Timestamptz (the tz-aware native mapping).
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        hln="${hit%%:*}"
        add_finding "S2" "$f" "$hln" "Prisma DateTime without @db.Timestamptz — map to a timezone-aware column (@db.Timestamptz)."
        s2_fail=$((s2_fail+1))
      done <<EOF
$(grep -niE '^[[:space:]]*[a-zA-Z_]+[[:space:]]+DateTime\b' "$f" 2>/dev/null | grep -viE 'Timestamptz|@db.Timestamp[(]?[0-9]*[)]?[[:space:]]*$' | grep -viE 'Timestamptz' || true)
EOF
      ;;
    *.entity.ts)
      # @Column('timestamp'|'datetime') without 'timestamptz'/'with time zone' on the same line.
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        hln="${hit%%:*}"
        add_finding "S2" "$f" "$hln" "TypeORM timestamp/datetime column without timezone — use 'timestamptz' (or 'timestamp with time zone')."
        s2_fail=$((s2_fail+1))
      done <<EOF
$(grep -niE "@Column\([^)]*['\"](timestamp|datetime)['\"]" "$f" 2>/dev/null | grep -viE 'timestamptz|with[[:space:]]+time[[:space:]]+zone' || true)
EOF
      ;;
  esac
done
[ "$s2_fail" -gt 0 ] && violations=$((violations+1))
add s2_timestamp_no_tz "$(jq -n --argjson n "$s2_fail" --arg v "$([ "$s2_fail" -gt 0 ] && echo FAIL || echo PASS)" '{verdict:$v, check:"S2 timestamp/datetime without timezone", findings:$n}')"

# ── S3 table/model without a primary key ──────────────────────────────────────
# Reconstruct each CREATE TABLE (...) statement (multi-line, terminated by ');') and check for a PK.
# For Python/Prisma/TS we scan per model/class block.
s3_fail=0
for f in "${SCHEMA_FILES[@]}"; do
  case "$(basename "$f")" in
    *.sql)
      # awk accumulates a CREATE TABLE statement until the matching ');' then checks for PRIMARY KEY.
      while IFS= read -r out; do
        [ -z "$out" ] && continue
        ln="${out%%|*}"; tbl="${out#*|}"
        add_finding "S3" "$f" "$ln" "CREATE TABLE '$tbl' has no PRIMARY KEY — every table needs a primary key."
        s3_fail=$((s3_fail+1))
      done <<EOF
$(awk '
  BEGIN{IGNORECASE=1; intbl=0; depth=0; stmt=""; startln=0; tname="?"}
  {
    line=$0
    if (intbl==0 && line ~ /CREATE[ \t]+TABLE/) {
      intbl=1; stmt=""; startln=NR
      t=line; sub(/.*CREATE[ \t]+TABLE[ \t]+(IF[ \t]+NOT[ \t]+EXISTS[ \t]+)?/,"",t)
      sub(/[ \t(].*/,"",t); gsub(/["\x60\[\]]/,"",t); tname=t
    }
    if (intbl==1) {
      stmt=stmt " " line
      n=gsub(/\(/,"(",line); m=gsub(/\)/,")",line); depth=depth+n-m
      if (depth<=0 && stmt ~ /\)/) {
        if (stmt !~ /PRIMARY[ \t]+KEY/ && stmt !~ /[ \t,(]PRIMARY[ \t]+KEY/) print startln "|" tname
        intbl=0; depth=0; stmt=""
      }
    }
  }' "$f" 2>/dev/null || true)
EOF
      ;;
    models.py)
      # Each SQLAlchemy-style class block (class X(Base): ... __tablename__) must contain primary_key=True.
      while IFS= read -r out; do
        [ -z "$out" ] && continue
        ln="${out%%|*}"; cls="${out#*|}"
        add_finding "S3" "$f" "$ln" "Model class '$cls' declares a table but no primary_key=True column."
        s3_fail=$((s3_fail+1))
      done <<EOF
$(awk '
  BEGIN{inc=0; startln=0; cname="?"; buf=""; hastable=0; haspk=0}
  function flush(){
    if (inc && hastable && !haspk) print startln "|" cname
    inc=0; hastable=0; haspk=0; buf=""
  }
  /^class[ \t]+[A-Za-z_]/ {
    flush()
    inc=1; startln=NR; cname=$2; sub(/[(:].*/,"",cname)
  }
  inc==1 {
    if ($0 ~ /__tablename__/) hastable=1
    if ($0 ~ /primary_key[ \t]*=[ \t]*True/) haspk=1
  }
  END{ flush() }
' "$f" 2>/dev/null || true)
EOF
      ;;
    schema.prisma)
      # Each 'model X { ... }' block must contain @id or @@id.
      while IFS= read -r out; do
        [ -z "$out" ] && continue
        ln="${out%%|*}"; mdl="${out#*|}"
        add_finding "S3" "$f" "$ln" "Prisma model '$mdl' has no @id / @@id primary key."
        s3_fail=$((s3_fail+1))
      done <<EOF
$(awk '
  BEGIN{inm=0; startln=0; mname="?"; haspk=0}
  /^[ \t]*model[ \t]+[A-Za-z_]/ { inm=1; startln=NR; mname=$2; haspk=0 }
  inm==1 {
    # POSIX awk has no reliable \b; match @id / @@id followed by a non-word char or end-of-line.
    if ($0 ~ /@id([^a-zA-Z0-9_]|$)/ || $0 ~ /@@id([^a-zA-Z0-9_]|$)/) haspk=1
    if ($0 ~ /^[ \t]*\}/) { if (!haspk) print startln "|" mname; inm=0 }
  }
' "$f" 2>/dev/null || true)
EOF
      ;;
    *.entity.ts)
      # Each @Entity()-decorated class must declare a @PrimaryColumn/@PrimaryGeneratedColumn/@ObjectIdColumn.
      if grep -qiE '@Entity\b' "$f" 2>/dev/null; then
        if ! grep -qiE '@(PrimaryColumn|PrimaryGeneratedColumn|ObjectIdColumn)\b' "$f" 2>/dev/null; then
          eln="$(grep -niE '@Entity\b' "$f" 2>/dev/null | head -1 | cut -d: -f1)"
          add_finding "S3" "$f" "${eln:-0}" "@Entity class has no @PrimaryColumn / @PrimaryGeneratedColumn primary key."
          s3_fail=$((s3_fail+1))
        fi
      fi
      ;;
  esac
done
[ "$s3_fail" -gt 0 ] && violations=$((violations+1))
add s3_no_primary_key "$(jq -n --argjson n "$s3_fail" --arg v "$([ "$s3_fail" -gt 0 ] && echo FAIL || echo PASS)" '{verdict:$v, check:"S3 table/model without primary key", findings:$n}')"

# ── S4 status/type column as free-text VARCHAR with no CHECK/enum/lookup ───────
# Only meaningful for SQL DDL where we can see the column type + nearby constraints.
s4_fail=0
for f in "${SCHEMA_FILES[@]}"; do
  case "$(basename "$f")" in
    *.sql)
      # For each line declaring a status-ish column as VARCHAR/TEXT/CHAR/String, the FILE must contain a
      # constraint that bounds it: a CHECK on that column, an enum type, or a foreign key/lookup reference.
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        hln="${hit%%:*}"
        # Pull the column name token out of the matched line for a targeted CHECK/REFERENCES search.
        col="$(printf '%s' "${hit#*:}" | sed -E 's/^[[:space:]]*//' | awk '{print $1}' | tr -d '",`[]')"
        [ -z "$col" ] && continue
        # Does the SAME line carry an inline CHECK / REFERENCES / enum? (line-local fast path)
        if printf '%s' "$hit" | grep -qiE 'CHECK[[:space:]]*\(|REFERENCES|ENUM\b'; then continue; fi
        # Does the file declare a CHECK or FK or enum type that names this column? (table-wide)
        if grep -qiE "CHECK[[:space:]]*\([^)]*\b${col}\b" "$f" 2>/dev/null; then continue; fi
        if grep -qiE "\b${col}\b[^,;]*REFERENCES" "$f" 2>/dev/null; then continue; fi
        if grep -qiE "\b${col}\b[^,;]*\b[a-z_]*${STATUS_RE}[a-z_]*_(enum|type)\b" "$f" 2>/dev/null; then continue; fi
        if grep -qiE "CREATE[[:space:]]+TYPE[[:space:]]+[a-z_]*${STATUS_RE}[a-z_]*[[:space:]]+AS[[:space:]]+ENUM" "$f" 2>/dev/null && \
           grep -qiE "\b${col}\b[[:space:]]+[a-z_]*${STATUS_RE}" "$f" 2>/dev/null; then continue; fi
        add_finding "S4" "$f" "$hln" "Status/type column '$col' is free-text VARCHAR/TEXT with no CHECK constraint, enum type, or lookup/FK — constrain its allowed values."
        s4_fail=$((s4_fail+1))
      done <<EOF
$(grep -niE "[a-z_]*${STATUS_RE}[a-z_]*[[:space:]]+(VARCHAR|VARYING|CHARACTER[[:space:]]+VARYING|TEXT|CHAR|STRING|NVARCHAR)\b" "$f" 2>/dev/null | grep -viE 'ENUM\b' || true)
EOF
      ;;
  esac
done
[ "$s4_fail" -gt 0 ] && violations=$((violations+1))
add s4_freetext_status "$(jq -n --argjson n "$s4_fail" --arg v "$([ "$s4_fail" -gt 0 ] && echo FAIL || echo PASS)" '{verdict:$v, check:"S4 free-text status/type VARCHAR without CHECK/enum/lookup", findings:$n}')"

# ── DETECT-OR-SKIP: live DB introspection ─────────────────────────────────────
# If a DSN env is set and psql/sqlite3 is present, the gate WOULD introspect the live catalog to verify
# these same rules against the running schema. Document the exact query path; SKIP loudly if unavailable.
DSN="${DATABASE_URL:-${POSTGRES_DSN:-${PG_DSN:-${DATABASE_DSN:-}}}}"
SQLITE_DB="${SQLITE_DB:-${SQLITE_DSN:-}}"
introspect_skip_reason=""
introspect_mode=""
if [ -n "$DSN" ] && have psql; then
  introspect_mode="psql"
  echo "  introspect: DSN + psql present — live catalog check AVAILABLE (information_schema.columns: data_type for money/timestamp; pg_constraint for PK/CHECK)." >&2
elif [ -n "$SQLITE_DB" ] && have sqlite3; then
  introspect_mode="sqlite3"
  echo "  introspect: SQLITE_DB + sqlite3 present — live catalog check AVAILABLE (PRAGMA table_info: pk flag, declared types)." >&2
else
  if [ -z "$DSN" ] && [ -z "$SQLITE_DB" ]; then
    introspect_skip_reason="no DSN env (set DATABASE_URL/POSTGRES_DSN or SQLITE_DB) for live introspection"
  elif [ -n "$DSN" ] && ! have psql; then
    introspect_skip_reason="DSN set but psql not installed"
  else
    introspect_skip_reason="SQLITE_DB set but sqlite3 not installed"
  fi
  echo "  SKIP — live DB introspection: $introspect_skip_reason. Recorded; NOT counted green." >&2
fi
if [ -n "$introspect_mode" ]; then
  add introspect "$(jq -n --arg m "$introspect_mode" '{verdict:"AVAILABLE", tool:$m, note:"live catalog introspection available; static zero-dep checks decided the verdict this run"}')"
else
  add introspect "$(jq -n --arg r "$introspect_skip_reason" '{verdict:"SKIP", reason:$r, would_run:"introspect live catalog (information_schema.columns / PRAGMA table_info) for money-float, naive-timestamp, missing-PK, free-text-status"}')"
fi

# ── verdict ──────────────────────────────────────────────────────────────────
# Zero-dep checks always run when applicable, so OVERALL is never SKIP here: FAIL on any violation, else PASS.
if [ "$violations" -gt 0 ]; then OVERALL=FAIL; else OVERALL=PASS; fi

if [ "${#FINDINGS_JSON[@]}" -gt 0 ]; then
  FIND_JSON="$(printf '%s\n' "${FINDINGS_JSON[@]}" | jq -s '.')"
else
  FIND_JSON='[]'
fi

jq -n --arg v "$OVERALL" --arg ts "$TS" --argjson viol "$violations" \
      --argjson nf "${#SCHEMA_FILES[@]}" --argjson details "$J" --argjson find "$FIND_JSON" \
  '{verdict:$v, ts:$ts, gate:"schema", schema_files:$nf, violations:$viol, details:$details, findings:$find}' \
  > "$REPORT" 2>/dev/null \
  || printf '{"verdict":"%s","ts":"%s","gate":"schema","violations":%s}\n' "$OVERALL" "$TS" "$violations" > "$REPORT"

echo "schema-lint verdict: $OVERALL (schema_files=${#SCHEMA_FILES[@]}, violations=$violations) -> $REPORT" >&2
if [ "$OVERALL" = "FAIL" ]; then
  for fj in "${FINDINGS_JSON[@]}"; do
    c="$(printf '%s' "$fj" | jq -r '.check')"
    fl="$(printf '%s' "$fj" | jq -r '.file')"
    l="$(printf '%s' "$fj" | jq -r '.line')"
    m="$(printf '%s' "$fj" | jq -r '.message')"
    if [ "$l" != "0" ]; then echo "  $c  $fl:$l  $m" >&2; else echo "  $c  $fl  $m" >&2; fi
  done
  exit 2
fi
exit 0
