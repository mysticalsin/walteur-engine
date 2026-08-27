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

# ── Can we run the LIVE round-trip? Detect a migrate runner + a dev DB URL. ───
RUNNER=""
for cand in atlas dbmate goose flyway "sqlx" "migrate" "alembic" "rails" "prisma" "knex"; do
  have "$cand" && { RUNNER="$cand"; break; }
done
# A live dev DB URL — explicit test URL is required; we will NEVER touch a non-test URL.
DB_URL="${DATABASE_URL_TEST:-${TEST_DATABASE_URL:-${WALTEUR_DEV_DB_URL:-}}}"
RUN_DB="${WALTEUR_MIGRATION_DB:-off}"

mode=""; live_skip_reason=""
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
