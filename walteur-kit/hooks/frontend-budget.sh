#!/usr/bin/env bash
# WALTEUR frontend-budget — honest budget gate for any frontend build that ships JS to a browser.
#
# APPLICABILITY: a frontend build exists =
#   a package.json with a "build" script (under any package.json, root or workspace)
#   AND at least one frontend source file (.tsx / .jsx / .vue / .svelte).
#   If not applicable: gate not relevant -> NOT_APPLICABLE, exit 0.
#
# ZERO-DEP HARD CHECK (bash + grep + jq + awk + sed + find + wc only — always real exit 2):
#   1. walteur-kit/frontend-budget.json MUST exist. A build that ships JS with NO bundle/CWV
#      budget is the slop. Absent (frontend present) => exit 2.
#   2. The budget file must be valid JSON and satisfy the shape required by
#      schemas/frontend-budget.schema.json: bundles[] (name, max_kb>0) + core_web_vitals
#      (lcp_ms>0, inp_ms>0, cls>=0). Malformed / missing required keys => exit 2.
#   3. If a built output dir exists (dist/ build/ out/ .next/ .output/ .svelte-kit/output),
#      sum the bytes of every shipped *.js / *.mjs / *.cjs file and compare against the sum of
#      bundles[].max_kb. Over budget => exit 2.  (No build dir yet => budget validated only,
#      size check skipped honestly — not green-washed.)
#
# DETECT-OR-SKIP (heavy tools — loud recorded SKIP when absent, NEVER silent-green, NEVER exit 2
# for a missing tool): lighthouse, bundlesize, size-limit. Run each that exists; a present tool's
# real finding contributes a FAIL. Missing tool => sub-check SKIP, recorded in the report.
#
# Report: walteur-kit/frontend-report.json {verdict, ts, gate, ...}.
# Bypass: WALTEUR_FRONTEND=off. Pause: walteur-kit/PAUSED present.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "frontend-budget - honest budget gate for any frontend build that ships JS to a browser."
  printf '%s\n' "usage: bash frontend-budget.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/frontend-report.json - fix recipes: walteur-kit/REMEDIATION.md (## frontend-budget)"
  printf '%s\n' "bypass: WALTEUR_FRONTEND=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/frontend-report.json"
BUDGET="$KIT/frontend-budget.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_FRONTEND:-on}" = "off" ] && { echo "frontend-budget: bypassed (WALTEUR_FRONTEND=off)." >&2; exit 0; }

# ── report writer (always best-effort; falls back to printf if jq somehow fails) ──────────────
write_report() { # $1=verdict  $2=reason  $3=extra-json-object(default {})
  local v="$1" reason="$2" extra="${3-}"
  [ -n "$extra" ] || extra='{}'
  jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --argjson extra "$extra" \
    '{verdict:$v, ts:$ts, gate:"frontend-budget", reason:$reason} + $extra' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"%s","ts":"%s","gate":"frontend-budget","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
}

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

  make_frontend() {
    local dst="$1"
    mkdir -p "$dst/src" "$dst/walteur-kit"
    printf '{"scripts":{"build":"vite build"}}\n' > "$dst/package.json"
    printf 'export function App(){ return <button>Ship</button>; }\n' > "$dst/src/App.tsx"
  }

  make_budget() {
    local dst="$1" max_kb="${2:-10}"
    cat > "$dst/walteur-kit/frontend-budget.json" <<JSON
{
  "bundles": [
    { "name": "main", "max_kb": $max_kb }
  ],
  "core_web_vitals": {
    "lcp_ms": 2500,
    "inp_ms": 200,
    "cls": 0.1
  }
}
JSON
  }

  echo "frontend-budget selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/frontend-budget-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no frontend build -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/frontend-budget-selftest.XXXXXX")" || return 1
  make_frontend "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "frontend build without budget -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/frontend-budget-selftest.XXXXXX")" || return 1
  make_frontend "$tmp"
  printf '{ bad json\n' > "$tmp/walteur-kit/frontend-budget.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "invalid frontend-budget.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/frontend-budget-selftest.XXXXXX")" || return 1
  make_frontend "$tmp"
  printf '{"bundles":[{"name":"main"}],"core_web_vitals":{"lcp_ms":2500,"inp_ms":200,"cls":0.1}}\n' > "$tmp/walteur-kit/frontend-budget.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "budget missing max_kb -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/frontend-budget-selftest.XXXXXX")" || return 1
  make_frontend "$tmp"
  make_budget "$tmp" 10
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "valid budget without build output -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/frontend-budget-selftest.XXXXXX")" || return 1
  make_frontend "$tmp"
  make_budget "$tmp" 1
  mkdir -p "$tmp/dist"
  perl -e 'print "x" x 2000' > "$tmp/dist/app.js"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "built JS over budget -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/frontend-budget-selftest.XXXXXX")" || return 1
  make_frontend "$tmp"
  WALTEUR_ROOT="$tmp" WALTEUR_FRONTEND=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/frontend-budget-selftest.XXXXXX")" || return 1
  make_frontend "$tmp"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "frontend-budget selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

# ── tool guard (zero-dep core) ────────────────────────────────────────────────────────────────
for t in grep jq awk sed find wc; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR frontend-budget SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
    write_report "SKIP" "$t not installed"
    exit 0
  fi
done

have() { command -v "$1" >/dev/null 2>&1; }

# prune-set used by every traversal: never descend node_modules / .git / built output dirs
PRUNE=( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' \
        -o -path '*/out/*' -o -path '*/.next/*' -o -path '*/.output/*' -o -path '*/.svelte-kit/*' \
        -o -path '*/coverage/*' )

# ── applicability: package.json with a build script + a frontend source file ─────────────────
pkg_with_build=""
while IFS= read -r pj; do
  [ -z "$pj" ] && continue
  # .scripts.build must be a non-empty string
  if jq -e '(.scripts.build // "") | type=="string" and (.|length>0)' "$pj" >/dev/null 2>&1; then
    pkg_with_build="$pj"; break
  fi
done < <(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -name 'package.json' -type f -print 2>/dev/null)

fe_src="$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \
  -type f \( -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' \) -print 2>/dev/null | head -1)"

if [ -z "$pkg_with_build" ] || [ -z "$fe_src" ]; then
  echo "frontend-budget: no frontend build (need a package.json with a build script + a .tsx/.jsx/.vue/.svelte source) — gate not applicable." >&2
  write_report "NOT_APPLICABLE" "no package.json build script + frontend source present"
  exit 0
fi

echo "WALTEUR frontend-budget @ $ROOT (build pkg: ${pkg_with_build#"$ROOT"/}, src: ${fe_src#"$ROOT"/})" >&2

# ── ZERO-DEP HARD #1: a budget MUST exist ────────────────────────────────────────────────────
if [ ! -f "$BUDGET" ]; then
  echo "frontend-budget: FAIL — frontend build ships JS but walteur-kit/frontend-budget.json is MISSING." >&2
  echo "  A build with no bundle-size / Core-Web-Vitals budget is unbounded slop. Declare one against" >&2
  echo "  schemas/frontend-budget.schema.json: {bundles:[{name,max_kb}], core_web_vitals:{lcp_ms,inp_ms,cls}}." >&2
  write_report "FAIL" "frontend-budget.json missing (frontend ships JS with no budget)"
  exit 2
fi

# ── ZERO-DEP HARD #2: budget valid JSON + required shape ─────────────────────────────────────
if ! jq -e . "$BUDGET" >/dev/null 2>&1; then
  echo "frontend-budget: FAIL — walteur-kit/frontend-budget.json is not valid JSON." >&2
  write_report "FAIL" "frontend-budget.json is not valid JSON"
  exit 2
fi

# Shape contract mirrors the schema (jq can't run JSON-Schema, so we assert the required invariants).
SHAPE_ERR="$(jq -r '
  def err(c;m): if c then m else empty end;
  [ err((.bundles|type)!="array";                                         "bundles must be an array")
  , err(((.bundles|type)=="array") and ((.bundles|length)<1);             "bundles must have at least one entry")
  , err([ .bundles[]? | select((.name|type)!="string" or (.name|length)<1) ] | length>0;
                                                                          "every bundle needs a non-empty string name")
  , err([ .bundles[]? | select((.max_kb|type)!="number" or .max_kb<=0) ] | length>0;
                                                                          "every bundle needs a numeric max_kb > 0")
  , err((.core_web_vitals|type)!="object";                                "core_web_vitals must be an object")
  , err((.core_web_vitals.lcp_ms|type)!="number" or (.core_web_vitals.lcp_ms<=0); "core_web_vitals.lcp_ms must be a number > 0")
  , err((.core_web_vitals.inp_ms|type)!="number" or (.core_web_vitals.inp_ms<=0); "core_web_vitals.inp_ms must be a number > 0")
  , err((.core_web_vitals.cls|type)!="number"   or (.core_web_vitals.cls<0);      "core_web_vitals.cls must be a number >= 0")
  ] | map(select(. != null)) | .[]' "$BUDGET" 2>/dev/null)"

if [ -n "$SHAPE_ERR" ]; then
  echo "frontend-budget: FAIL — frontend-budget.json violates the required shape:" >&2
  printf '  - %s\n' $(printf '%s\n' "$SHAPE_ERR" | sed 's/ /\x01/g') 2>/dev/null | sed 's/\x01/ /g' >&2 || \
    printf '%s\n' "$SHAPE_ERR" | sed 's/^/  - /' >&2
  ERR_JSON="$(printf '%s\n' "$SHAPE_ERR" | jq -R . | jq -s '{shape_errors:.}')"
  write_report "FAIL" "frontend-budget.json fails required shape" "$ERR_JSON"
  exit 2
fi

# budget total (KB -> bytes; 1 KB = 1000 bytes) and CWV echoed into the report
BUDGET_KB_TOTAL="$(jq '[.bundles[].max_kb] | add' "$BUDGET")"
BUDGET_BYTES_TOTAL="$(awk -v kb="$BUDGET_KB_TOTAL" 'BEGIN{ printf "%d", kb*1000 }')"
CWV_JSON="$(jq -c '.core_web_vitals' "$BUDGET")"
BUNDLES_JSON="$(jq -c '.bundles' "$BUDGET")"

violations=0
declare -a NOTES=()

# ── ZERO-DEP HARD #3: if a built output dir exists, sum shipped JS bytes vs budget ───────────
BUILD_DIR=""
for d in dist build out .next .output .svelte-kit/output; do
  if [ -d "$ROOT/$d" ]; then BUILD_DIR="$ROOT/$d"; break; fi
done

SIZE_JSON='{"checked":false,"reason":"no build output directory present yet (dist/build/out/.next/.output/.svelte-kit/output)"}'
if [ -n "$BUILD_DIR" ]; then
  SHIPPED_BYTES=0
  JS_COUNT=0
  while IFS= read -r jsf; do
    [ -z "$jsf" ] && continue
    sz="$(wc -c < "$jsf" 2>/dev/null | tr -d '[:space:]')"
    [ -z "$sz" ] && sz=0
    SHIPPED_BYTES="$(awk -v a="$SHIPPED_BYTES" -v b="$sz" 'BEGIN{ printf "%d", a+b }')"
    JS_COUNT=$((JS_COUNT+1))
  done < <(find "$BUILD_DIR" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) ! -name '*.map' -print 2>/dev/null)

  SHIPPED_KB="$(awk -v b="$SHIPPED_BYTES" 'BEGIN{ printf "%.1f", b/1000 }')"
  echo "  build dir: ${BUILD_DIR#"$ROOT"/}  shipped JS: ${JS_COUNT} file(s), ${SHIPPED_KB} KB  budget total: ${BUDGET_KB_TOTAL} KB" >&2

  OVER="$(awk -v s="$SHIPPED_BYTES" -v b="$BUDGET_BYTES_TOTAL" 'BEGIN{ print (s>b)?1:0 }')"
  if [ "$OVER" -eq 1 ]; then
    echo "  FAIL — shipped JS ${SHIPPED_KB} KB exceeds budget total ${BUDGET_KB_TOTAL} KB." >&2
    violations=$((violations+1))
    NOTES+=("shipped JS ${SHIPPED_KB} KB over budget ${BUDGET_KB_TOTAL} KB")
  else
    echo "  ok   — shipped JS within budget." >&2
  fi
  SIZE_JSON="$(jq -n --argjson checked true --arg dir "${BUILD_DIR#"$ROOT"/}" \
    --argjson files "$JS_COUNT" --argjson bytes "$SHIPPED_BYTES" \
    --argjson budget_bytes "$BUDGET_BYTES_TOTAL" --argjson over "$OVER" \
    '{checked:$checked, build_dir:$dir, js_files:$files, shipped_bytes:$bytes,
      budget_bytes:$budget_bytes, over_budget:($over==1)}')"
else
  echo "  size-check skipped honestly — no build output dir present yet (budget validated)." >&2
fi

# ── DETECT-OR-SKIP heavy tools ───────────────────────────────────────────────────────────────
loud_skip() { echo "  SKIP — $1 not installed ($2). Recorded; NOT counted green." >&2; }
TOOLS_JSON='{}'
tool_add() { TOOLS_JSON="$(printf '%s' "$TOOLS_JSON" | jq --arg k "$1" --argjson v "$2" '.[$k]=$v' 2>/dev/null || printf '%s' "$TOOLS_JSON")"; }
TMP="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"; trap 'rm -f "$TMP"' EXIT

# lighthouse — Core Web Vitals lab audit. We do NOT spin a server here (no URL contract); presence is
# recorded, and if a lighthouse JSON report already exists in the tree we read LCP/CLS/TBT from it and
# compare to the budget. Absent tool => loud SKIP.
if have lighthouse || have lhci; then
  lh_report="$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -type f \
    \( -iname 'lighthouse*.json' -o -iname 'lhr*.json' -o -path '*/.lighthouseci/*.json' \) -print 2>/dev/null | head -1)"
  if [ -n "$lh_report" ] && jq -e '.audits' "$lh_report" >/dev/null 2>&1; then
    lcp_ms="$(jq -r '(.audits["largest-contentful-paint"].numericValue // empty)' "$lh_report" 2>/dev/null)"
    cls_v="$(jq -r '(.audits["cumulative-layout-shift"].numericValue // empty)' "$lh_report" 2>/dev/null)"
    bud_lcp="$(jq -r '.core_web_vitals.lcp_ms' "$BUDGET")"
    bud_cls="$(jq -r '.core_web_vitals.cls' "$BUDGET")"
    lh_fail=0; lh_notes=""
    if [ -n "$lcp_ms" ] && awk -v a="$lcp_ms" -v b="$bud_lcp" 'BEGIN{exit !(a>b)}'; then
      lh_fail=1; lh_notes="LCP ${lcp_ms}ms > budget ${bud_lcp}ms; "; fi
    if [ -n "$cls_v" ] && awk -v a="$cls_v" -v b="$bud_cls" 'BEGIN{exit !(a>b)}'; then
      lh_fail=1; lh_notes="${lh_notes}CLS ${cls_v} > budget ${bud_cls}; "; fi
    if [ "$lh_fail" -eq 1 ]; then
      echo "  FAIL — lighthouse report exceeds CWV budget: ${lh_notes}" >&2
      violations=$((violations+1)); NOTES+=("lighthouse CWV: ${lh_notes}")
      tool_add lighthouse "$(jq -n --arg n "$lh_notes" --arg f "${lh_report#"$ROOT"/}" '{verdict:"FAIL",tool:"lighthouse",report:$f,detail:$n}')"
    else
      echo "  ok   — lighthouse report within CWV budget (${lh_report#"$ROOT"/})." >&2
      tool_add lighthouse "$(jq -n --arg f "${lh_report#"$ROOT"/}" '{verdict:"PASS",tool:"lighthouse",report:$f}')"
    fi
  else
    echo "  SKIP — lighthouse installed but no lighthouse JSON report found to evaluate." >&2
    tool_add lighthouse '{"verdict":"SKIP","reason":"lighthouse installed, no report JSON present to evaluate"}'
  fi
else
  loud_skip lighthouse "Core Web Vitals lab audit"
  tool_add lighthouse '{"verdict":"SKIP","reason":"lighthouse not installed"}'
fi

# bundlesize — reads its own .bundlesize config / package.json#bundlesize. Run if present.
if have bundlesize; then
  if bundlesize >"$TMP" 2>&1; then
    echo "  ok   — bundlesize: within configured limits." >&2
    tool_add bundlesize '{"verdict":"PASS","tool":"bundlesize"}'
  else
    echo "  FAIL — bundlesize: over configured limits." >&2
    violations=$((violations+1)); NOTES+=("bundlesize over its configured limit")
    tool_add bundlesize '{"verdict":"FAIL","tool":"bundlesize"}'
  fi
else
  loud_skip bundlesize "per-file gzipped bundle limit (optional)"
  tool_add bundlesize '{"verdict":"SKIP","reason":"bundlesize not installed"}'
fi

# size-limit — modern successor to bundlesize. Run if present.
if have size-limit; then
  if size-limit >"$TMP" 2>&1; then
    echo "  ok   — size-limit: within configured limits." >&2
    tool_add size_limit '{"verdict":"PASS","tool":"size-limit"}'
  else
    echo "  FAIL — size-limit: over configured limits." >&2
    violations=$((violations+1)); NOTES+=("size-limit over its configured limit")
    tool_add size_limit '{"verdict":"FAIL","tool":"size-limit"}'
  fi
else
  loud_skip size-limit "size-limit budget (optional)"
  tool_add size_limit '{"verdict":"SKIP","reason":"size-limit not installed"}'
fi

# ── verdict ──────────────────────────────────────────────────────────────────────────────────
NOTES_JSON="$(printf '%s\n' "${NOTES[@]:-}" | sed '/^$/d' | jq -R . | jq -s '.')"
EXTRA="$(jq -n \
  --argjson bundles "$BUNDLES_JSON" \
  --argjson cwv "$CWV_JSON" \
  --argjson budget_kb_total "$BUDGET_KB_TOTAL" \
  --argjson size "$SIZE_JSON" \
  --argjson tools "$TOOLS_JSON" \
  --argjson violations "$violations" \
  --argjson notes "$NOTES_JSON" \
  '{budget:{bundles:$bundles, core_web_vitals:$cwv, budget_kb_total:$budget_kb_total},
    size_check:$size, tools:$tools, violations:$violations, notes:$notes}')"

if [ "$violations" -gt 0 ]; then
  write_report "FAIL" "$violations frontend-budget violation(s)" "$EXTRA"
  echo "frontend-budget verdict: FAIL ($violations violation(s)) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "frontend budget declared and within limits" "$EXTRA"
echo "frontend-budget verdict: PASS -> $REPORT" >&2
exit 0
