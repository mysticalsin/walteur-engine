#!/usr/bin/env bash
# WALTEUR data-correctness-gate — HARD gate (intake: ECC/everything-claude-code data/validate-data skill).
# Analytics bugs are silent: the dashboard renders a number, the number is wrong, nobody notices until a
# decision is made on it. A $50-100M product's metrics must be RIGHT. This gate statically flags the classic
# SQL/analytics correctness pitfalls in generated query/reporting code: join-explosion (COUNT(*)/SUM over a
# JOIN without DISTINCT => row inflation), average-of-averages (AVG over an already-averaged/rate column),
# nested aggregate (AVG(AVG())/SUM(SUM())), and an unguarded division denominator (/ without NULLIF => div-by-
# zero / silent NULL). Per-line override:  -- data-ok  (or  // data-ok  /  # data-ok ).
#
# Applies when SQL/analytics code is present (.sql, or SELECT..FROM in source, or metrics/report/dashboard paths).
# CONTRACT: a pitfall over threshold => FAIL exit 2 · no SQL => NOT_APPLICABLE · PAUSED => exit 2 ·
# bypass WALTEUR_DATAQA=off · tunable WALTEUR_DATAQA_MAX (default 0).
# Report: walteur-kit/data-correctness-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "data-correctness-gate - HARD gate (intake: ECC/everything-claude-code data/validate-data skill)."
  printf '%s\n' "usage: bash data-correctness-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/data-correctness-report.json - fix recipes: walteur-kit/REMEDIATION.md (## data-correctness-gate)"
  printf '%s\n' "bypass: WALTEUR_DATAQA=off (recorded, not free)"
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
REPORT="$KIT/data-correctness-report.json"
MAXHITS="${WALTEUR_DATAQA_MAX:-0}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"data-correctness", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","reason":"%s"}\n' "$v" "$r" > "$REPORT" 2>/dev/null || true; }

sql_files() {
  command -v find >/dev/null 2>&1 || return 0
  find "$ROOT" -type d \( -name node_modules -o -name .git -o -name walteur-kit -o -name dist -o -name build -o -name tests -o -name __tests__ \) -prune -o \
    -type f \( -name '*.sql' -o -name '*.ts' -o -name '*.js' -o -name '*.py' -o -name '*.rb' -o -name '*.go' \) -print 2>/dev/null | \
    while IFS= read -r f; do
      case "$f" in *.sql) printf '%s\n' "$f" ;; *) grep -liE 'select[[:space:]].+[[:space:]]from[[:space:]]' "$f" 2>/dev/null ;; esac
    done
}

applies() { [ -n "$(sql_files | head -1)" ]; }

scan_file() {
  local f="$1" rel; rel="$(printf '%s' "$f" | sed "s#$ROOT/##")"
  have perl || return 0
  local res
  res="$(perl -0777 -ne '
    my %seen;
    for my $stmt (split /;/, $_) {
      next unless $stmt =~ /select/i && $stmt =~ /from/i;     # SQL-ish statement only
      for my $ln (split /\n/, $stmt) {
        next if $ln =~ /(--|\#|\/\/)\s*data-ok/i;             # per-line override
        my $L = $ln; $L =~ s/--.*$//; $L =~ s/\#.*$//;        # strip trailing comment
        # 1. nested aggregate
        if ($L =~ /\b(AVG|SUM|COUNT|MAX|MIN)\s*\(\s*(AVG|SUM|COUNT)\s*\(/i) { $seen{"NESTED_AGGREGATE: $ln"}=1; }
        # 2. average-of-averages: AVG over an already-rate/avg column
        if ($L =~ /\bAVG\s*\(\s*[A-Za-z0-9_.]*(?:_(?:rate|pct|percent|avg|average|ratio|mean)\b|\b(?:rate|pct|avg|ratio)_)/i) { $seen{"AVERAGE_OF_AVERAGES: $ln"}=1; }
        # 3. unguarded division denominator: dividing by an aggregate (could be 0) without NULLIF
        if ($L =~ m{/\s*(count|sum|avg|min|max)\s*\(}i && $L !~ /nullif/i) { $seen{"DENOMINATOR_NO_NULLIF: $ln"}=1; }
      }
      # 4. join-explosion: COUNT(*)/SUM(col) + a JOIN, no COUNT(DISTINCT/SUM(DISTINCT
      if ($stmt =~ /\bjoin\b/i && $stmt =~ /\b(count\s*\(\s*\*|sum\s*\()/i && $stmt !~ /\b(count|sum)\s*\(\s*distinct/i) {
        my ($l) = $stmt =~ /((?:count\s*\(\s*\*|sum\s*\()[^\n]*)/i; $l //= "aggregate over JOIN without DISTINCT";
        # honor a data-ok marker on the same physical line as the aggregate (even after the ;)
        my $ok = 0; my $needle = substr($l, 0, 12);
        for my $orig (split /\n/, $_) { if (index($orig, $needle) >= 0 && $orig =~ /data-ok/i) { $ok = 1; last; } }
        $seen{"JOIN_EXPLOSION: $l"}=1 unless $ok;
      }
    }
    for (keys %seen) { print "$_\n"; }
  ' "$f" 2>/dev/null)"
  [ -z "$res" ] && return 0
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && add_finding "$rel" "$(printf '%s' "$line" | cut -c1-120)"
  done <<< "$res"
}

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused; echo "data-correctness-gate: PAUSED -> exit 2"; exit 2; }
  [ "${WALTEUR_DATAQA:-}" = "off" ] && { write_report SKIP bypassed; echo "data-correctness-gate: bypassed"; exit 0; }
  if ! applies; then write_report NOT_APPLICABLE "no SQL/analytics code"; echo "data-correctness-gate: NOT_APPLICABLE"; exit 0; fi
  local f
  while IFS= read -r f; do [ -n "$f" ] && scan_file "$f"; done < <(sql_files | sort -u)
  if [ "$failures" -gt "$MAXHITS" ]; then
    write_report FAIL "$failures analytics-correctness pitfall(s) over threshold $MAXHITS"
    echo "data-correctness-gate: FAIL ($failures pitfalls) -> exit 2"
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null | head -15 || true
    exit 2
  fi
  write_report PASS "analytics code clean ($failures pitfalls <= $MAXHITS)"
  echo "data-correctness-gate: PASS"
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq || ! have perl; then echo "data-correctness selftest SKIP - need jq+perl."; return 0; fi
  echo "data-correctness-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  seed() { mkdir -p "$1/walteur-kit" "$1/sql"; }

  # 1. no SQL -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/datacorrec.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf 'const x=1;\n' > "$t/src/a.ts"; ck "no SQL -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. clean aggregation -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/datacorrec.XXXXXX")"; seed "$t"; printf 'SELECT user_id, COUNT(DISTINCT order_id) AS orders FROM users JOIN orders USING (user_id) GROUP BY user_id;\n' > "$t/sql/q.sql"; ck "clean COUNT(DISTINCT)+JOIN -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. G1 join-explosion: COUNT(*) over JOIN, no DISTINCT -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/datacorrec.XXXXXX")"; seed "$t"; printf 'SELECT u.id, COUNT(*) AS n FROM users u JOIN orders o ON o.user_id = u.id GROUP BY u.id;\n' > "$t/sql/q.sql"; ck "G1 COUNT(*)+JOIN -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. G2 average-of-averages -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/datacorrec.XXXXXX")"; seed "$t"; printf 'SELECT region, AVG(conversion_rate) AS r FROM daily_metrics GROUP BY region;\n' > "$t/sql/q.sql"; ck "G2 AVG(rate col) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. G3 unguarded denominator -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/datacorrec.XXXXXX")"; seed "$t"; printf 'SELECT SUM(revenue) / COUNT(orders) AS aov FROM sales;\n' > "$t/sql/q.sql"; ck "G3 division no NULLIF -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. FP guard: division WITH NULLIF -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/datacorrec.XXXXXX")"; seed "$t"; printf 'SELECT SUM(revenue) / NULLIF(COUNT(orders),0) AS aov FROM sales;\n' > "$t/sql/q.sql"; ck "G4 division WITH NULLIF -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 7. G5 nested aggregate -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/datacorrec.XXXXXX")"; seed "$t"; printf 'SELECT AVG(SUM(amount)) FROM ledger GROUP BY acct;\n' > "$t/sql/q.sql"; ck "G5 nested aggregate -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. FP guard: data-ok override -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/datacorrec.XXXXXX")"; seed "$t"; printf 'SELECT u.id, COUNT(*) AS n FROM users u JOIN orders o ON o.user_id=u.id GROUP BY u.id; -- data-ok intentional\n' > "$t/sql/q.sql"; ck "G6 data-ok override -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 9. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/datacorrec.XXXXXX")"; seed "$t"; printf 'SELECT COUNT(*) FROM a JOIN b ON a.id=b.a;\n' > "$t/sql/q.sql"; WALTEUR_ROOT="$t" WALTEUR_DATAQA=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/datacorrec.XXXXXX")"; seed "$t"; printf 'SELECT 1 FROM x;\n' > "$t/sql/q.sql"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "data-correctness-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
