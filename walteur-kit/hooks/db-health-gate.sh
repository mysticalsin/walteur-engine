#!/usr/bin/env bash
# WALTEUR db-health-gate — EXECUTING gate (intake: NoctisNova/orm-doctor, MIT).
#
# Runs orm-doctor and OBSERVES its REAL scored output + exit — not a shape-read. orm-doctor is an AST-based
# (ts-morph + prisma-ast) ORM/DB health scanner: N+1 queries, missing indexes on FKs, unsafe raw SQL
# ($queryRawUnsafe), mass mutations (updateMany/deleteMany without WHERE), unbounded queries, missing
# $transaction. It emits JSON {score:0-100, issueCount, issues[]} on STDOUT and exits non-zero on any
# CRITICAL finding. WALTEUR cannot fake that — the score + exit ARE the observation. This is the AST-grade
# executing layer above the regex-based data-correctness-gate.
#
# GOVERNED: the gate NEVER fetches from the network. It requires orm-doctor present (a `orm-doctor` on PATH
# or node_modules/.bin/orm-doctor — acquire via the lockfile-backed tool-acquisition flow). Absent => loud SKIP.
#
# Applies: a Prisma/Drizzle ORM project (schema.prisma, drizzle config, or @prisma/client / drizzle-orm in
# package.json). Else NOT_APPLICABLE.
# CONTRACT: orm-doctor exit != 0 (critical finding) => FAIL · .score < WALTEUR_ORMSCORE_MIN (default 90)
#   => FAIL · else PASS · orm-doctor absent => SKIP exit 0 (loud, couldn't-measure) · PAUSED => exit 2 ·
#   bypass WALTEUR_DBHEALTH=off. Report: walteur-kit/db-health-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "db-health-gate - EXECUTING gate (intake: NoctisNova/orm-doctor, MIT)."
  printf '%s\n' "usage: bash db-health-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/db-health-report.json - fix recipes: walteur-kit/REMEDIATION.md (## db-health-gate)"
  printf '%s\n' "bypass: WALTEUR_DBHEALTH=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/db-health-report.json"
MINSCORE="${WALTEUR_ORMSCORE_MIN:-90}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
write_report() { v="$1"; r="$2"; ex="${3-}"; [ -n "$ex" ] || ex='{}'; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson ex "$ex" '{verdict:$v, ts:$ts, gate:"db-health", reason:$r} + $ex' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","reason":"%s"}\n' "$v" "$r" > "$REPORT" 2>/dev/null || true; }

resolve_tool() {
  command -v orm-doctor >/dev/null 2>&1 && { echo "orm-doctor"; return; }
  [ -x "$ROOT/node_modules/.bin/orm-doctor" ] && { echo "$ROOT/node_modules/.bin/orm-doctor"; return; }
  echo ""
}

applies() {
  command -v find >/dev/null 2>&1 && [ -n "$(find "$ROOT" -type d \( -name node_modules -o -name .git \) -prune -o -type f -name '*.prisma' -print 2>/dev/null | head -1)" ] && return 0
  if [ -f "$ROOT/package.json" ] && have jq; then
    jq -e '((.dependencies//{}) + (.devDependencies//{})) | keys | any(. == "@prisma/client" or . == "prisma" or . == "drizzle-orm" or . == "drizzle-kit")' "$ROOT/package.json" >/dev/null 2>&1 && return 0
  fi
  return 1
}

main() {
  [ -f "$KIT/PAUSED" ] && { write_report FAIL paused; echo "db-health-gate: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_DBHEALTH:-}" = "off" ] && { write_report SKIP "bypassed via WALTEUR_DBHEALTH=off"; echo "db-health-gate: SKIP — WALTEUR_DBHEALTH=off (loud skip)" >&2; exit 0; }
  if ! applies; then write_report NOT_APPLICABLE "no Prisma/Drizzle ORM project detected"; echo "db-health-gate: NOT_APPLICABLE" >&2; exit 0; fi
  local TOOL; TOOL="$(resolve_tool)"
  if [ -z "$TOOL" ]; then
    # STRICT mode (S008 skill fix): an ORM surface is present but orm-doctor is absent — an unmeasured pass
    # is a silent hole. With WALTEUR_DBHEALTH_STRICT=1 (or global WALTEUR_TOOLGATE_STRICT=1) FAIL.
    if [ "${WALTEUR_DBHEALTH_STRICT:-${WALTEUR_TOOLGATE_STRICT:-0}}" = "1" ]; then
      write_report FAIL "ORM surface present but orm-doctor not installed — STRICT mode rejects an unmeasured pass (acquire orm-doctor via tool-acquisition)"
      echo "db-health-gate: FAIL — orm-doctor absent in STRICT mode -> exit 2" >&2; exit 2
    fi
    write_report SKIP "orm-doctor not installed — acquire via tool-acquisition (couldn't measure DB health, NOT a pass)"
    echo "db-health-gate: SKIP — orm-doctor not installed (cannot_measure)" >&2; exit 0
  fi
  if ! have jq; then write_report SKIP "jq not installed"; echo "db-health-gate: SKIP (no jq)" >&2; exit 0; fi

  local out rc score
  out="$( ( cd "$ROOT" && "$TOOL" --json --no-ai . 2>/dev/null ) )"; rc=$?
  out="$(printf '%s' "$out" | tr -d '\r')"
  score="$(printf '%s' "$out" | jq -r '.score // empty' 2>/dev/null || echo "")"

  if [ "$rc" -ne 0 ]; then
    write_report FAIL "orm-doctor exited $rc — a CRITICAL DB issue (unsafe raw SQL / table-wipe mutation / etc.)" "$(jq -n --argjson rc "$rc" --arg s "${score:-?}" '{orm_doctor_exit:$rc, score:$s}')"
    echo "db-health-gate: FAIL — orm-doctor critical (exit $rc) -> exit 2" >&2; exit 2
  fi
  if [ -n "$score" ] && [ "$score" -lt "$MINSCORE" ] 2>/dev/null; then
    write_report FAIL "DB health score $score < floor $MINSCORE (N+1 / missing indexes / unbounded queries)" "$(jq -n --argjson s "$score" --argjson m "$MINSCORE" '{score:$s, floor:$m}')"
    echo "db-health-gate: FAIL — score $score < $MINSCORE -> exit 2" >&2; exit 2
  fi
  write_report PASS "DB health score ${score:-100} >= floor $MINSCORE (exit 0, no critical findings)" "$(jq -n --arg s "${score:-100}" --argjson m "$MINSCORE" '{score:$s, floor:$m}')"
  echo "db-health-gate: PASS — score ${score:-100} >= $MINSCORE" >&2; exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "db-health selftest SKIP — need jq."; return 0; fi
  echo "db-health-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  seedorm() { mkdir -p "$1"; printf '{"name":"x","version":"1.0.0","dependencies":{"@prisma/client":"^5"}}\n' > "$1/package.json"; }
  shim() { mkdir -p "$1/bin"; { printf '#!/usr/bin/env bash\n'; printf "cat <<'J'\n%s\nJ\n" "$2"; printf 'exit %s\n' "$3"; } > "$1/bin/orm-doctor"; chmod +x "$1/bin/orm-doctor"; }
  runp() { PATH="$1/bin:$PATH" WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }

  # 1. non-ORM project -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/dbhealthga.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"name":"x"}\n' > "$t/package.json"; ck "non-ORM project -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. ORM + score 95 exit 0 -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/dbhealthga.XXXXXX")"; seedorm "$t"; shim "$t" '{"score":95,"issueCount":1,"issues":[]}' 0; ck "score 95 -> PASS" 0 "$(runp "$t")"; rm -rf "$t"
  # 3. ORM + score 70 exit 0 -> FAIL (below floor 90)
  t="$(mktemp -d "${TMPDIR:-/tmp}/dbhealthga.XXXXXX")"; seedorm "$t"; shim "$t" '{"score":70,"issueCount":9,"issues":[]}' 0; ck "score 70 < floor -> FAIL" 2 "$(runp "$t")"; rm -rf "$t"
  # 4. ORM + critical exit 1 -> FAIL (regardless of score)
  t="$(mktemp -d "${TMPDIR:-/tmp}/dbhealthga.XXXXXX")"; seedorm "$t"; shim "$t" '{"score":99,"issueCount":1,"issues":[{"severity":"critical"}]}' 1; ck "critical exit 1 -> FAIL" 2 "$(runp "$t")"; rm -rf "$t"
  # 5. ORM + orm-doctor ABSENT -> loud SKIP exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/dbhealthga.XXXXXX")"; seedorm "$t"; ck "orm-doctor absent -> SKIP exit 0" 0 "$(run "$t")"
  jq -e '.verdict=="SKIP"' "$t/walteur-kit/db-health-report.json" >/dev/null 2>&1; ck "absent report verdict SKIP (loud)" 0 "$?"; rm -rf "$t"
  # 5b. ORM + orm-doctor ABSENT + STRICT -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/dbhealthga.XXXXXX")"; seedorm "$t"; WALTEUR_DBHEALTH_STRICT=1 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "orm-doctor absent + STRICT -> FAIL" 2 "$?"; rm -rf "$t"
  # 6. ORM + score 70 but lowered floor 60 -> PASS (threshold)
  t="$(mktemp -d "${TMPDIR:-/tmp}/dbhealthga.XXXXXX")"; seedorm "$t"; shim "$t" '{"score":70,"issues":[]}' 0; PATH="$t/bin:$PATH" WALTEUR_ORMSCORE_MIN=60 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "score 70 within lowered floor -> PASS" 0 "$?"; rm -rf "$t"
  # 7. detect via .prisma file (no package.json dep) -> applies + PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/dbhealthga.XXXXXX")"; mkdir -p "$t/prisma"; printf 'model User { id Int @id }\n' > "$t/prisma/schema.prisma"; shim "$t" '{"score":98,"issues":[]}' 0; ck "detect via schema.prisma -> PASS" 0 "$(runp "$t")"; rm -rf "$t"
  # 8. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/dbhealthga.XXXXXX")"; seedorm "$t"; shim "$t" '{"score":10}' 1; PATH="$t/bin:$PATH" WALTEUR_DBHEALTH=off WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/dbhealthga.XXXXXX")"; seedorm "$t"; mkdir -p "$t/walteur-kit"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "db-health-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
