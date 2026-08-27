#!/usr/bin/env bash
# WALTEUR benchmark-gate — HARD gate on the benchmark.md artifact. Missing/stub = fail (exit 2). Clean = exit 0.
# Usage: bash walteur-kit/hooks/benchmark-gate.sh <dir>
#
# Intent: a user-facing product must not silently ship missing a table-stakes feature, regardless of
# how the user under-asked. §2.0b BEST-IN-CLASS benchmark coverage requires naming >=3 competitors,
# declaring every table-stakes feature's disposition (planned-with-task-ref OR out_of_scope-with-reason
# + signer), and setting a date. The gate enforces this mechanically via a parseable benchmark.md block.
#
# Scope (applicability — POSITIVE-SIGNAL ONLY, fail-OPEN on tooling):
#   Treat as user-facing product ONLY when AT LEAST ONE positive signal exists:
#     (a) UI source files present (*.tsx / *.jsx / *.vue / *.svelte / *.html, excluding
#         vendor/build dirs and *.test.* / *.spec.* / *.stories.* files), OR
#     (b) PLAN.md or walteur-kit/benchmark.md declares a category that is NOT one of:
#         cli / library / script / internal-tool / cron / sdk.
#   NO positive signal (or ambiguous) => RECORDED SKIP, exit 0.
#   This is the load-bearing safety rule: CLIs, scripts, libraries MUST NOT false-fail.
#
# Contract file: walteur-kit/benchmark.md at the repo root.
# Anti-stub floor: >=3 leaders/competitors, >=1 table_stakes item, a machine-readable
# table_stakes block, a date.
#   a `touch benchmark.md` stub FAILS with exit 2.
#
# Coverage teeth: benchmark.md contains a fenced ```json block with the schema:
#   {
#     "category": "<string>",
#     "date": "<YYYY-MM-DD>",
#     "leaders": ["<name>", ...],               # >=3 required
#     "table_stakes": [
#       {"feature": "<name>", "status": "planned"|"out_of_scope", "ref": "<non-empty>"},
#       ...
#     ]
#   }
#   status=planned  => ref must be a non-empty PLAN task id (anything non-empty)
#   status=out_of_scope => ref must be a non-empty reason + signer string
#   ANY item with missing/empty status or ref => exit 2 naming the feature.
#
# Bypass: WALTEUR_BENCHMARK=off => write SKIP report, exit 0.
# Kill switch: walteur-kit/PAUSED present => exit 2.
#
# Zero-dep: bash + grep + jq + find only.  HARD: real exit 2 on a real violation.
# HONESTY: applicability SKIP = no product signal — honest, not silent-green.
# Report: walteur-kit/benchmark-gate-report.json  {verdict, ts, gate, mode, reason, items:[...]}.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "benchmark-gate - HARD gate on the benchmark.md artifact. Missing/stub = fail (exit 2). Clean = exit 0."
  printf '%s\n' "usage: bash benchmark-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/benchmark-gate-report.json - fix recipes: walteur-kit/REMEDIATION.md (## benchmark-gate)"
  printf '%s\n' "bypass: WALTEUR_BENCHMARK=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# Root from the DIR argument (the project being evaluated), NOT cwd — so the gate is self-consistent
# whether invoked as `benchmark-gate.sh "$ROOT"` by ship-gate or `benchmark-gate.sh <dir>` directly.
# Using cwd would read a stray benchmark.md/PLAN.md from the caller's dir (cross-contamination).
_arg="${1:-}"
if [ -n "$_arg" ] && [ -d "$_arg" ]; then
  ROOT="$(cd "$_arg" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/benchmark-gate-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_report() { # $1=verdict  $2=mode  $3=reason  $4=items-json
  jq -n \
    --arg v "$1" --arg ts "$TS" --arg mode "$2" --arg reason "$3" --arg dir "${DIR:-}" \
    --argjson items "${4:-[]}" \
    '{verdict:$v, ts:$ts, gate:"benchmark", mode:$mode, dir:$dir, reason:$reason, items:$items}' > "$REPORT"
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

  for t in grep jq find; do
    if ! command -v "$t" >/dev/null 2>&1; then
      echo "benchmark-gate selftest SKIP - required tool '$t' not installed."
      return 0
    fi
  done

  echo "benchmark-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchmark-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'print("hello")\n' > "$tmp/tool.py"
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "CLI-only dir -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP" and .mode == "not-applicable"' "$tmp/walteur-kit/benchmark-gate-report.json" >/dev/null 2>&1
  ck "CLI-only report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchmark-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'export const App = () => <div>ok</div>;\n' > "$tmp/src/App.tsx"
  cat > "$tmp/walteur-kit/benchmark.md" <<'BENCHEOF'
# Best-in-class benchmark
Category leaders and table-stakes coverage.
```json
{
  "category": "saas",
  "date": "2026-06-23",
  "leaders": ["Linear", "Notion", "Figma"],
  "table_stakes": [
    {"feature": "Core workflow", "status": "planned", "ref": "T1"}
  ]
}
```
BENCHEOF
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "valid product benchmark -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .mode == "full-coverage"' "$tmp/walteur-kit/benchmark-gate-report.json" >/dev/null 2>&1
  ck "valid benchmark report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchmark-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'export const App = () => <div>ok</div>;\n' > "$tmp/src/App.tsx"
  touch "$tmp/walteur-kit/benchmark.md"
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "touch-stub benchmark -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .mode == "stub"' "$tmp/walteur-kit/benchmark-gate-report.json" >/dev/null 2>&1
  ck "stub benchmark report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchmark-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'export const App = () => <div>ok</div>;\n' > "$tmp/src/App.tsx"
  cat > "$tmp/walteur-kit/benchmark.md" <<'BENCHEOF'
# Benchmark with zero table stakes
This fixture proves that an empty table_stakes array is not acceptable for a user-facing product.
```json
{
  "category": "saas",
  "date": "2026-06-23",
  "leaders": ["Linear", "Notion", "Figma"],
  "table_stakes": []
}
```
BENCHEOF
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "zero table_stakes benchmark -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .mode == "missing-table-stakes"' "$tmp/walteur-kit/benchmark-gate-report.json" >/dev/null 2>&1
  ck "zero table_stakes report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchmark-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'export const App = () => <div>ok</div>;\n' > "$tmp/src/App.tsx"
  WALTEUR_BENCHMARK=off bash "$0" "$tmp" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP" and .mode == "bypass"' "$tmp/walteur-kit/benchmark-gate-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchmark-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "benchmark-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

# ── kill switch ──────────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }

# ── tool guard ───────────────────────────────────────────────────────────────
for t in grep jq find; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR benchmark-gate SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
    write_report "SKIP" "tool-missing" "$t not installed" '[]'
    exit 0
  fi
done

# ── bypass ───────────────────────────────────────────────────────────────────
if [ "${WALTEUR_BENCHMARK:-on}" = "off" ]; then
  echo "WALTEUR benchmark-gate SKIP — bypass WALTEUR_BENCHMARK=off (recorded, not silent-green)." >&2
  write_report "SKIP" "bypass" "WALTEUR_BENCHMARK=off" '[]'
  exit 0
fi

DIR="${1:-}"
if [ -z "$DIR" ]; then
  echo "WALTEUR benchmark-gate SKIP — no directory argument. Usage: benchmark-gate.sh <dir>" >&2
  write_report "SKIP" "no-arg" "no directory argument" '[]'
  exit 0
fi
if [ ! -d "$DIR" ]; then
  echo "WALTEUR benchmark-gate SKIP — '$DIR' is not a directory (nothing to scan)." >&2
  write_report "SKIP" "not-a-directory" "not a directory: $DIR" '[]'
  exit 0
fi

# ── APPLICABILITY: positive-signal only ──────────────────────────────────────
# The load-bearing safety rule. We fail-OPEN on tooling (CLI/script/library) and
# fail-CLOSED on products. A product is detected only by a positive signal.

# (a) UI source files present?
PRUNE=( \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/storybook-static/*' -o -path '*/walteur-kit/*' \) -prune -o )

UI_COUNT=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  base="$(basename "$f")"
  case "$base" in
    *.test.*|*.spec.*|*.stories.*) continue ;;
  esac
  UI_COUNT=$((UI_COUNT+1))
done < <(find "$DIR" "${PRUNE[@]}" \
  -type f \( -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' -o -name '*.html' \) -print 2>/dev/null)

PRODUCT_SIGNAL=0
SIGNAL_REASON=""

if [ "$UI_COUNT" -gt 0 ]; then
  PRODUCT_SIGNAL=1
  SIGNAL_REASON="UI source files present (count=$UI_COUNT)"
fi

# (b) PLAN.md or walteur-kit/benchmark.md declares a non-tooling category?
# Non-tooling categories trigger the gate; tooling categories (cli/library/script/internal-tool/cron/sdk) do not.
# We look for a "category" key in either file.
TOOLING_CATEGORIES="cli|library|script|internal-tool|cron|sdk"

if [ "$PRODUCT_SIGNAL" -eq 0 ]; then
  for candidate in "$ROOT/PLAN.md" "$KIT/benchmark.md"; do
    [ -f "$candidate" ] || continue
    # Extract category from a fenced json block OR from a line like `category: <value>`
    cat_val=""
    # Try fenced json block first
    if grep -q '```json' "$candidate" 2>/dev/null; then
      cat_val="$(awk '/^```json/{found=1; next} found && /^```/{found=0} found{print}' "$candidate" \
        | jq -r '.category // empty' 2>/dev/null || true)"
    fi
    # Fallback: YAML-style `category: <value>`
    if [ -z "$cat_val" ]; then
      cat_val="$(grep -i '^category:' "$candidate" 2>/dev/null | head -1 | sed 's/^[Cc]ategory:[[:space:]]*//' | tr -d '"' || true)"
    fi
    if [ -n "$cat_val" ]; then
      if ! printf '%s' "$cat_val" | grep -Eqi "^($TOOLING_CATEGORIES)$"; then
        PRODUCT_SIGNAL=1
        SIGNAL_REASON="category '$cat_val' in $(basename "$candidate") is a product (not a tooling category)"
        break
      fi
    fi
  done
fi

if [ "$PRODUCT_SIGNAL" -eq 0 ]; then
  echo "WALTEUR benchmark-gate SKIP — no user-facing product signal under '$DIR' (CLI/library/script/no-UI — §16 safe)." >&2
  write_report "SKIP" "not-applicable" "no product signal: no UI files and no non-tooling category in PLAN.md/benchmark.md" '[]'
  exit 0
fi

echo "WALTEUR benchmark-gate: product signal detected — $SIGNAL_REASON" >&2

# ── locate the benchmark contract ────────────────────────────────────────────
BENCHMARK=""
for cand in "$KIT/benchmark.md" "$ROOT/benchmark.md" "$DIR/walteur-kit/benchmark.md" "$DIR/benchmark.md"; do
  if [ -f "$cand" ]; then BENCHMARK="$cand"; break; fi
done

if [ -z "$BENCHMARK" ]; then
  write_report "FAIL" "missing" "user-facing product detected but no walteur-kit/benchmark.md exists" \
    '[{"rule":"missing-benchmark","message":"A user-facing product must have walteur-kit/benchmark.md (§2.0b). Create it with >=3 leaders, a date, and every table_stakes feature dispositioned."}]'
  echo "WALTEUR benchmark-gate: FAIL — product detected ($SIGNAL_REASON) but walteur-kit/benchmark.md not found." >&2
  echo "  Fix: create walteur-kit/benchmark.md with the required schema." >&2
  exit 2
fi

rel="${BENCHMARK#"$ROOT"/}"

# ── anti-stub quality floor ───────────────────────────────────────────────────
# Must have: >=3 non-empty lines, a parseable json block, >=3 leaders, >=1 table_stakes item, a date.
NONEMPTY="$(grep -c -v '^[[:space:]]*$' "$BENCHMARK" 2>/dev/null; true)"

# Extract the fenced ```json block
JSON_BLOCK=""
if grep -q '```json' "$BENCHMARK" 2>/dev/null; then
  JSON_BLOCK="$(awk '/^```json/{found=1; next} found && /^```/{found=0} found{print}' "$BENCHMARK" | tr -d '\r')"
fi

if [ "$NONEMPTY" -lt 5 ] || [ -z "$JSON_BLOCK" ]; then
  write_report "FAIL" "stub" "benchmark.md '$rel' is a stub (lines=$NONEMPTY, has-json-block=$([ -n "$JSON_BLOCK" ] && echo true || echo false))" \
    "$(jq -n --arg f "$rel" --argjson n "$NONEMPTY" \
      '[{"rule":"stub-benchmark","file":$f,"message":("benchmark.md has only " + ($n|tostring) + " non-empty line(s) or no ```json block — a stub does not satisfy §2.0b; write a real schema with leaders, date, and table_stakes")}]')"
  echo "WALTEUR benchmark-gate: FAIL — '$rel' is a stub ($NONEMPTY non-empty lines, json-block=$([ -n "$JSON_BLOCK" ] && echo present || echo missing))." >&2
  exit 2
fi

# Validate the JSON block is parseable
if ! printf '%s' "$JSON_BLOCK" | jq '.' >/dev/null 2>&1; then
  write_report "FAIL" "invalid-json" "benchmark.md '$rel' json block is not valid JSON" \
    "[{\"rule\":\"invalid-json\",\"file\":\"$rel\",\"message\":\"The \\\`\\\`\\\`json block in benchmark.md could not be parsed. Fix the JSON syntax.\"}]"
  echo "WALTEUR benchmark-gate: FAIL — '$rel' json block is not valid JSON." >&2
  exit 2
fi

# ── structural checks ─────────────────────────────────────────────────────────
LEADER_COUNT="$(printf '%s' "$JSON_BLOCK" | jq '[.leaders // [] | .[] | select(. != null and . != "")] | length' 2>/dev/null || echo 0)"
DATE_VAL="$(printf '%s' "$JSON_BLOCK" | jq -r '.date // empty' 2>/dev/null || true)"
TS_COUNT="$(printf '%s' "$JSON_BLOCK" | jq '(.table_stakes // []) | length' 2>/dev/null || echo 0)"

if [ "$LEADER_COUNT" -lt 3 ]; then
  write_report "FAIL" "insufficient-leaders" "benchmark.md has $LEADER_COUNT leader(s); >=3 required (§2.0b)" \
    "$(jq -n --argjson n "$LEADER_COUNT" \
      '[{"rule":"insufficient-leaders","message":("benchmark.md names " + ($n|tostring) + " leader(s) — §2.0b requires >=3 named competitors/leaders")}]')"
  echo "WALTEUR benchmark-gate: FAIL — benchmark.md names $LEADER_COUNT leader(s); >=3 required." >&2
  exit 2
fi

if [ -z "$DATE_VAL" ] || [ "$DATE_VAL" = "null" ]; then
  write_report "FAIL" "missing-date" "benchmark.md missing date field (§2.0b requires a benchmark date)" \
    '[{"rule":"missing-date","message":"benchmark.md json block is missing a date field (YYYY-MM-DD required)"}]'
  echo "WALTEUR benchmark-gate: FAIL — benchmark.md missing date field." >&2
  exit 2
fi

if [ "$TS_COUNT" -lt 1 ]; then
  write_report "FAIL" "missing-table-stakes" "benchmark.md has zero table_stakes items; >=1 required (§2.0b)" \
    "$(jq -n \
      '[{"rule":"missing-table-stakes","message":"benchmark.md must name at least one table_stakes item for a user-facing product; each item must be planned or signed out_of_scope"}]')"
  echo "WALTEUR benchmark-gate: FAIL — benchmark.md has zero table_stakes items; >=1 required." >&2
  exit 2
fi

# ── coverage teeth: every table_stakes item must be dispositioned ─────────────
VIOLATIONS="[]"
VIOLATION_COUNT=0

# Parse each table_stakes item; any with missing/empty status or ref fails.
ITEM_COUNT=0
while IFS= read -r item; do
  ITEM_COUNT=$((ITEM_COUNT+1))
  feature="$(printf '%s' "$item" | jq -r '.feature // ""')"
  status="$(printf '%s' "$item" | jq -r '.status // ""')"
  ref="$(printf '%s' "$item" | jq -r '.ref // ""')"

  err=""
  if [ -z "$status" ] || [ "$status" = "null" ]; then
    err="missing status (must be 'planned' or 'out_of_scope')"
  elif [ "$status" != "planned" ] && [ "$status" != "out_of_scope" ]; then
    err="invalid status '$status' (must be 'planned' or 'out_of_scope')"
  elif [ -z "$ref" ] || [ "$ref" = "null" ]; then
    if [ "$status" = "planned" ]; then
      err="status=planned but ref is empty (ref must be a PLAN task id)"
    else
      err="status=out_of_scope but ref is empty (ref must be a reason + signer)"
    fi
  fi

  if [ -n "$err" ]; then
    VIOLATION_COUNT=$((VIOLATION_COUNT+1))
    feat_label="${feature:-<unnamed item $ITEM_COUNT>}"
    VIOLATIONS="$(printf '%s' "$VIOLATIONS" | jq \
      --arg f "$feat_label" --arg e "$err" \
      '. + [{"rule":"uncovered-table-stakes","feature":$f,"message":("table_stakes item '\''"+$f+"'\'' is not properly dispositioned: "+$e)}]')"
    echo "WALTEUR benchmark-gate: VIOLATION — table_stakes '${feat_label}': $err" >&2
  fi
done < <(printf '%s' "$JSON_BLOCK" | jq -c '.table_stakes // [] | .[]' 2>/dev/null || true)

if [ "$VIOLATION_COUNT" -gt 0 ]; then
  write_report "FAIL" "uncovered-table-stakes" "$VIOLATION_COUNT table_stakes item(s) not properly dispositioned" "$VIOLATIONS"
  echo "WALTEUR benchmark-gate: FAIL — $VIOLATION_COUNT table_stakes item(s) missing status/ref." >&2
  exit 2
fi

# ── PASS ─────────────────────────────────────────────────────────────────────
write_report "PASS" "full-coverage" "benchmark.md present + $LEADER_COUNT leaders + $ITEM_COUNT table_stakes items all dispositioned" '[]'
echo "WALTEUR benchmark-gate: PASS — '$rel' covers $ITEM_COUNT table_stakes item(s), $LEADER_COUNT leaders, date=$DATE_VAL." >&2
exit 0
