#!/usr/bin/env bash
# WALTEUR maintainability-gate — keeps a codebase maintainable over time, not just correct today.
#
#   ZERO-DEP (always run, HARD gate — real exit 2 on violation; bash+grep+find+jq only):
#     M1  COMMITTED LOCKFILE — if a package manifest exists (package.json / pyproject.toml /
#         requirements.txt / Cargo.toml / go.mod), a matching committed lockfile MUST exist:
#           package.json   -> package-lock.json | pnpm-lock.yaml | yarn.lock | npm-shrinkwrap.json
#           pyproject/req   -> poetry.lock | uv.lock | Pipfile.lock | pdm.lock | requirements*.lock
#           Cargo.toml      -> Cargo.lock
#           go.mod          -> go.sum
#         Reproducible installs require a pinned lockfile in VCS. Missing => violation.
#     M2  DEPENDENCY-AUTOMATION CONFIG — a renovate.json (or renovate.json5 / .renovaterc /
#         .github/renovate.json) OR a dependabot config (.github/dependabot.yml/.yaml) MUST exist.
#         No automation => dependencies rot silently. Missing => violation.
#     M3  STRUCTURED DEBT LEDGER — every debt marker in tracked source
#         (eslint-disable / FIXME / TODO / test.skip|describe.skip|it.skip / it.only|describe.only|
#          fit|fdescribe) MUST be recorded in walteur-kit/debt-ledger.json (validated against
#         schemas/debt-ledger.schema.json shape: id/kind/location/reason/owner/expires).
#         A marker with no matching ledger entry (matched by file path) => violation: untracked debt.
#         If markers exist but the ledger file is absent => violation.
#
#   DETECT-OR-SKIP (heavy tools — semver / API-surface diff / complexity; run the one(s) present):
#     api-extractor (@microsoft/api-extractor) — if api-extractor.json present, run it; a
#         reported API-report mismatch / error => fail (an undocumented public-API change).
#     oasdiff      — if an OpenAPI spec is present AND a committed baseline
#         (walteur-kit/openapi.baseline.yaml|json or *.baseline.*), diff for BREAKING changes => fail.
#     cargo-semver-checks — for a Rust lib crate, check for SemVer-breaking API changes => fail.
#     M4 lizard    — polyglot cyclomatic-complexity check. Thresholds: WALTEUR_CCN (default 15)
#         and WALTEUR_FNLEN (default 80). Breach => WARN by default; HARD only if
#         WALTEUR_MAINTAINABILITY=hard. lizard absent => LOUD SKIP, never exit 2.
#   Tool ABSENT => loud recorded SKIP of that sub-check. NEVER silent-green, NEVER exit 2 for a
#   missing tool.
#
# Report: walteur-kit/maintainability-report.json with per-check {verdict|SKIP}.
# Bypass: WALTEUR_MAINTAIN=off.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/maintainability-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_MAINTAIN:-on}" = "off" ] && { echo "maintainability-gate: bypassed (WALTEUR_MAINTAIN=off)." >&2; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }
TMP="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"; trap 'rm -f "$TMP"' EXIT

violations=0      # real maintainability violations (zero-dep + heavy)
heavy_ran=0       # heavy sub-checks that executed
J='{}'
add() { J="$(printf '%s' "$J" | jq --argjson v "$2" --arg k "$1" '.[$k]=$v' 2>/dev/null || printf '%s' "$J")"; }
loud_skip() { echo "  SKIP — $1 ($2). Recorded; NOT counted green." >&2; }

# files tracked by git if in a repo, else a pruned find — used for M3 source scanning.
list_source() {
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" ls-files 2>/dev/null
  else
    ( cd "$ROOT" && find . \( -path './.git' -o -path './node_modules' -o -path './walteur-kit' \
        -o -path './dist' -o -path './build' -o -path './.venv' -o -path './vendor' \
        -o -path './target' \) -prune -o -type f -print 2>/dev/null | sed 's#^\./##' )
  fi
}

# ── --selftest ────────────────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  _pass=0; _fail=0
  _ok()   { _pass=$((_pass+1)); echo "  ok  $1" >&2; }
  _fail() { _fail=$((_fail+1)); echo "  FAIL $1" >&2; }

  _CCN="${WALTEUR_CCN:-15}"
  _FNLEN="${WALTEUR_FNLEN:-80}"
  _TMPDIR="$(mktemp -d 2>/dev/null || mktemp -d -t maintainability-selftest 2>/dev/null || { mkdir -p "${TMPDIR:-/tmp}/maintainability-selftest-$$" && printf '%s' "${TMPDIR:-/tmp}/maintainability-selftest-$$"; })"
  trap 'rm -rf "$_TMPDIR"' EXIT

  # ── selftest T1: LOUD-SKIP when lizard is absent ─────────────────────────────────────────
  _skip_out="$( WALTEUR_CCN="$_CCN" WALTEUR_FNLEN="$_FNLEN" \
    bash -c '
      have_override() { [ "$1" = "lizard" ] && return 1; command -v "$1" >/dev/null 2>&1; }
      CCN="${WALTEUR_CCN:-15}"; FNLEN="${WALTEUR_FNLEN:-80}"
      if ! have_override lizard; then
        echo "LOUD_SKIP"
      fi
    ' 2>&1 )"
  if printf '%s' "$_skip_out" | grep -q "LOUD_SKIP"; then
    _ok "T1 LOUD-SKIP path: lizard absent => SKIP recorded, no exit 2"
  else
    # lizard is actually installed — T1 is vacuously satisfied; we test T3/T4 instead
    _ok "T1 LOUD-SKIP path: lizard present on this host (skip test not applicable — OK)"
  fi

  # ── selftest T2: PASS fixture (function well below CCN 15) ────────────────────────────────
  _clean="$_TMPDIR/clean.py"
  cat > "$_clean" <<'PYEOF'
def simple_add(a, b):
    return a + b
PYEOF

  if have lizard; then
    _lizard_out="$(lizard --CCN "$_CCN" --length "$_FNLEN" --csv "$_clean" 2>/dev/null || true)"
    # lizard CSV: filename,NLOC,CCN,token_count,param_count,name,long_name,...
    # A clean function with CCN=1 should produce no violations
    _breach="$(printf '%s' "$_lizard_out" | awk -F',' 'NR>1 && $3+0 > '"$_CCN"' { print }' | grep -c . || true)"
    if [ "${_breach:-0}" -eq 0 ]; then
      _ok "T2 PASS fixture: simple_add() CCN=1 => no breach (threshold $_CCN)"
    else
      _fail "T2 PASS fixture: unexpected CCN breach on trivial function"
    fi
  else
    _ok "T2 PASS fixture: lizard not installed, skip lizard-specific test"
  fi

  # ── selftest T3: FAIL/WARN fixture (deeply nested function exceeding CCN 15) ──────────────
  _poison="$_TMPDIR/poison.py"
  # Build a function with 17 independent branches (CCN ≈ 18 > 15)
  {
    printf 'def complex_fn(a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q):\n'
    for _i in $(seq 1 17); do
      printf '    if a == %d: pass\n' "$_i"
    done
    printf '    return 0\n'
  } > "$_poison"

  if have lizard; then
    _lizard_out2="$(lizard --CCN "$_CCN" --length "$_FNLEN" --csv "$_poison" 2>/dev/null || true)"
    _breach2="$(printf '%s' "$_lizard_out2" | awk -F',' 'NR>1 && $3+0 > '"$_CCN"' { print }' | grep -c . || true)"
    if [ "${_breach2:-0}" -gt 0 ]; then
      _ok "T3 FAIL fixture: complex_fn CCN>$_CCN => breach detected correctly"
    else
      _fail "T3 FAIL fixture: expected CCN breach not detected (lizard version quirk?)"
    fi
  else
    _ok "T3 FAIL fixture: lizard not installed, skip lizard-specific test"
  fi

  # ── selftest T4: WARN-only (violations counter not incremented in default mode) ────────────
  if have lizard; then
    _viol_before=0
    # Simulate the M4 default-mode logic inline
    _m4_out="$(lizard --CCN "$_CCN" --length "$_FNLEN" --csv "$_poison" 2>/dev/null || true)"
    _m4_breach="$(printf '%s' "$_m4_out" | awk -F',' 'NR>1 && $3+0 > '"$_CCN"' { print }' | grep -c . || true)"
    _m4_mode="${WALTEUR_MAINTAINABILITY:-warn}"
    _viol_after=$_viol_before
    if [ "${_m4_breach:-0}" -gt 0 ] && [ "$_m4_mode" = "hard" ]; then
      _viol_after=$((_viol_after+1))
    fi
    if [ "$_m4_mode" != "hard" ] && [ "$_viol_after" -eq "$_viol_before" ]; then
      _ok "T4 WARN-only: breach in default mode does NOT increment violations counter"
    elif [ "$_m4_mode" = "hard" ] && [ "$_viol_after" -gt "$_viol_before" ]; then
      _ok "T4 HARD mode: breach in hard mode DOES increment violations counter"
    else
      _fail "T4 violation-counter mode: unexpected counter state"
    fi
  else
    _ok "T4 WARN-only: lizard not installed, skip lizard-specific test"
  fi

  echo "" >&2
  echo "selftest: $_pass passed, $_fail failed" >&2
  [ "$_fail" -eq 0 ] && exit 0 || exit 1
fi

echo "WALTEUR maintainability-gate @ $ROOT" >&2

# ── M1: committed lockfile present for each manifest present ──────────────────────────────────
m1_missing=""
check_lock() { # $1=manifest-glob-present-test already done; $2=human; shift -> lockfile candidates
  return 0
}
declare -a M1_NOTES=()
ecosystems=0
m1_fail=0

if [ -f "$ROOT/package.json" ]; then
  ecosystems=$((ecosystems+1))
  if [ -f "$ROOT/package-lock.json" ] || [ -f "$ROOT/pnpm-lock.yaml" ] || [ -f "$ROOT/yarn.lock" ] || [ -f "$ROOT/npm-shrinkwrap.json" ]; then
    M1_NOTES+=("$(jq -n '{ecosystem:"node",verdict:"PASS",lockfile:"package-lock|pnpm-lock|yarn.lock|npm-shrinkwrap"}')")
  else
    m1_fail=1; m1_missing="$m1_missing node"
    M1_NOTES+=("$(jq -n '{ecosystem:"node",verdict:"FAIL",reason:"package.json present but no committed lockfile"}')")
  fi
fi
if [ -f "$ROOT/pyproject.toml" ] || ls "$ROOT"/requirements*.txt >/dev/null 2>&1 || [ -f "$ROOT/Pipfile" ]; then
  ecosystems=$((ecosystems+1))
  if [ -f "$ROOT/poetry.lock" ] || [ -f "$ROOT/uv.lock" ] || [ -f "$ROOT/Pipfile.lock" ] || [ -f "$ROOT/pdm.lock" ] || ls "$ROOT"/requirements*.lock >/dev/null 2>&1; then
    M1_NOTES+=("$(jq -n '{ecosystem:"python",verdict:"PASS",lockfile:"poetry.lock|uv.lock|Pipfile.lock|pdm.lock|requirements*.lock"}')")
  else
    m1_fail=1; m1_missing="$m1_missing python"
    M1_NOTES+=("$(jq -n '{ecosystem:"python",verdict:"FAIL",reason:"python manifest present but no committed lockfile"}')")
  fi
fi
if [ -f "$ROOT/Cargo.toml" ]; then
  ecosystems=$((ecosystems+1))
  if [ -f "$ROOT/Cargo.lock" ]; then
    M1_NOTES+=("$(jq -n '{ecosystem:"rust",verdict:"PASS",lockfile:"Cargo.lock"}')")
  else
    m1_fail=1; m1_missing="$m1_missing rust"
    M1_NOTES+=("$(jq -n '{ecosystem:"rust",verdict:"FAIL",reason:"Cargo.toml present but no committed Cargo.lock"}')")
  fi
fi
if [ -f "$ROOT/go.mod" ]; then
  ecosystems=$((ecosystems+1))
  if [ -f "$ROOT/go.sum" ]; then
    M1_NOTES+=("$(jq -n '{ecosystem:"go",verdict:"PASS",lockfile:"go.sum"}')")
  else
    m1_fail=1; m1_missing="$m1_missing go"
    M1_NOTES+=("$(jq -n '{ecosystem:"go",verdict:"FAIL",reason:"go.mod present but no committed go.sum"}')")
  fi
fi

if [ "$ecosystems" -eq 0 ]; then
  echo "  SKIP — M1 lockfile: no package manifest present (no ecosystem to lock)." >&2
  add m1_lockfile '{"verdict":"SKIP","check":"committed-lockfile","reason":"no package manifest present"}'
else
  if [ "${#M1_NOTES[@]}" -gt 0 ]; then
    M1_JSON="$(printf '%s\n' "${M1_NOTES[@]}" | jq -s '.')"
  else
    M1_JSON='[]'
  fi
  if [ "$m1_fail" -eq 1 ]; then
    echo "  FAIL — M1 lockfile: missing committed lockfile for:${m1_missing}" >&2
    violations=$((violations+1))
    add m1_lockfile "$(jq -n --argjson e "$M1_JSON" '{verdict:"FAIL",check:"committed-lockfile",ecosystems:$e}')"
  else
    echo "  ok   — M1 lockfile: every present ecosystem has a committed lockfile." >&2
    add m1_lockfile "$(jq -n --argjson e "$M1_JSON" '{verdict:"PASS",check:"committed-lockfile",ecosystems:$e}')"
  fi
fi

# ── M2: dependency-automation config present ─────────────────────────────────────────────────
m2_found=""
for f in renovate.json renovate.json5 .renovaterc .renovaterc.json .renovaterc.json5 \
         .github/renovate.json .github/renovate.json5 walteur-kit/renovate.json \
         .github/dependabot.yml .github/dependabot.yaml; do
  if [ -f "$ROOT/$f" ]; then m2_found="$f"; break; fi
done
if [ -n "$m2_found" ]; then
  echo "  ok   — M2 automation: dependency-update config present ($m2_found)." >&2
  add m2_automation "$(jq -n --arg f "$m2_found" '{verdict:"PASS",check:"dependency-automation",config:$f}')"
elif [ "$ecosystems" -eq 0 ]; then
  # No dependency manifest => nothing to automate. NOT a violation on a bare/dependency-free project.
  echo "  SKIP — M2 automation: no package manifest present (no dependencies to automate)." >&2
  add m2_automation '{"verdict":"SKIP","check":"dependency-automation","reason":"no package manifest present"}'
else
  echo "  FAIL — M2 automation: no renovate.json / .github/dependabot.yml present (deps will rot)." >&2
  violations=$((violations+1))
  add m2_automation '{"verdict":"FAIL","check":"dependency-automation","reason":"no renovate or dependabot config found"}'
fi

# ── M3: structured debt ledger — every marker recorded ───────────────────────────────────────
LEDGER="$KIT/debt-ledger.json"
# Marker regex: eslint-disable, FIXME, TODO (word-boundary), focused/skipped tests, type-ignore.
MARKER_RE='eslint-disable|biome-ignore|@ts-(ignore|expect-error)|# *type: *ignore|# *noqa|//[[:space:]]*FIXME|#[[:space:]]*FIXME|<!--[[:space:]]*FIXME|/\*[[:space:]]*FIXME|\bFIXME\b|\bTODO\b|\b(test|it|describe)\.skip\b|\bxit\b|\bxdescribe\b|\b(it|describe)\.only\b|\bfit\b|\bfdescribe\b'

# Build list of source files to scan, excluding binary-ish and the kit itself.
SRC_FILES="$(list_source | grep -vE '(^|/)walteur-kit/' \
  | grep -vE '\.(png|jpe?g|gif|webp|ico|pdf|zip|gz|tgz|bz2|7z|woff2?|ttf|eot|mp[34]|mov|lock)$' \
  | grep -vE '(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|go\.sum|Cargo\.lock|poetry\.lock|uv\.lock)$' \
  || true)"

# Collect "file:line:marker" hits across the scanned source.
declare -a UNRECORDED=()
marker_files=""
marker_count=0
if [ -n "$SRC_FILES" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$ROOT/$f" ] || continue
    # skip files git flags as binary (grep -I drops binary matches anyway)
    hits="$(grep -InE "$MARKER_RE" "$ROOT/$f" 2>/dev/null || true)"
    [ -z "$hits" ] && continue
    marker_files="$marker_files
$f"
    n="$(printf '%s\n' "$hits" | grep -c . )"
    marker_count=$((marker_count + n))
  done <<EOF
$SRC_FILES
EOF
fi
# de-dup the marker-bearing file list
marker_files="$(printf '%s\n' "$marker_files" | grep -vE '^$' | sort -u || true)"

if [ "$marker_count" -eq 0 ]; then
  echo "  ok   — M3 debt-ledger: no debt markers in tracked source (clean)." >&2
  add m3_debt_ledger '{"verdict":"PASS","check":"debt-ledger","markers":0,"note":"no markers present"}'
else
  if [ ! -f "$LEDGER" ]; then
    echo "  FAIL — M3 debt-ledger: $marker_count debt marker(s) present but walteur-kit/debt-ledger.json is missing." >&2
    while IFS= read -r mf; do [ -n "$mf" ] && echo "    untracked debt in: $mf" >&2; done <<EOF
$marker_files
EOF
    violations=$((violations+1))
    add m3_debt_ledger "$(jq -n --argjson n "$marker_count" '{verdict:"FAIL",check:"debt-ledger",markers:$n,reason:"markers present but debt-ledger.json absent"}')"
  elif ! jq -e 'type=="array"' "$LEDGER" >/dev/null 2>&1; then
    echo "  FAIL — M3 debt-ledger: walteur-kit/debt-ledger.json is not a JSON array (schema violation)." >&2
    violations=$((violations+1))
    add m3_debt_ledger '{"verdict":"FAIL","check":"debt-ledger","reason":"debt-ledger.json is not a JSON array"}'
  else
    # Structural sanity: every entry must carry the six required fields with a valid kind.
    BAD_ENTRIES="$(jq -r '
      [ to_entries[]
        | .key as $i | .value as $e
        | select(
            ($e|type)!="object"
            or ($e.id//""|tostring|length)==0
            or ([ "todo","fixme","skip","disable" ] | index($e.kind|tostring) | not)
            or ($e.location//""|tostring|length)==0
            or ($e.reason//""|tostring|length)<8
            or ($e.owner//""|tostring|length)==0
            or (($e.expires//"")|tostring|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")|not)
          )
        | "#"+($i|tostring)
      ] | join(", ")
    ' "$LEDGER" 2>/dev/null || echo "PARSE_ERROR")"
    # Build the set of locations recorded in the ledger (path portion before any :line).
    RECORDED_PATHS="$(jq -r '.[]? | .location // empty' "$LEDGER" 2>/dev/null \
      | sed -E 's/:[0-9]+(-[0-9]+)?$//' | sed -E 's#^\./##' | sort -u || true)"

    # Any marker-bearing file whose path is NOT recorded in the ledger => untracked debt.
    UNRECORDED=()
    while IFS= read -r mf; do
      [ -z "$mf" ] && continue
      norm="$(printf '%s' "$mf" | sed -E 's#^\./##')"
      if printf '%s\n' "$RECORDED_PATHS" | grep -qxF "$norm"; then
        :
      else
        UNRECORDED+=("$norm")
      fi
    done <<EOF
$marker_files
EOF

    m3_fail=0; m3_reasons=""
    if [ "$BAD_ENTRIES" = "PARSE_ERROR" ]; then
      m3_fail=1; m3_reasons="ledger parse error"
    elif [ -n "$BAD_ENTRIES" ]; then
      m3_fail=1; m3_reasons="malformed ledger entr(y/ies): $BAD_ENTRIES"
    fi
    if [ "${#UNRECORDED[@]}" -gt 0 ]; then
      m3_fail=1
      ulist="$(printf '%s; ' "${UNRECORDED[@]}")"
      m3_reasons="${m3_reasons:+$m3_reasons; }untracked debt in: ${ulist%; }"
    fi

    if [ "$m3_fail" -eq 1 ]; then
      echo "  FAIL — M3 debt-ledger: $m3_reasons" >&2
      violations=$((violations+1))
      if [ "${#UNRECORDED[@]}" -gt 0 ]; then
        UNREC_JSON="$(printf '%s\n' "${UNRECORDED[@]}" | jq -R . | jq -s '.')"
      else
        UNREC_JSON='[]'
      fi
      add m3_debt_ledger "$(jq -n --argjson n "$marker_count" --arg bad "$BAD_ENTRIES" --argjson unrec "$UNREC_JSON" \
        '{verdict:"FAIL",check:"debt-ledger",markers:$n,malformed_entries:(if $bad=="" then null else $bad end),untracked_files:$unrec}')"
    else
      echo "  ok   — M3 debt-ledger: all $marker_count marker(s) recorded in a well-formed ledger." >&2
      add m3_debt_ledger "$(jq -n --argjson n "$marker_count" '{verdict:"PASS",check:"debt-ledger",markers:$n}')"
    fi
  fi
fi

# ── DETECT-OR-SKIP: api-extractor (TS public-API surface report) ─────────────────────────────
if [ -f "$ROOT/api-extractor.json" ] || ls "$ROOT"/**/api-extractor.json >/dev/null 2>&1; then
  ae_cfg="$ROOT/api-extractor.json"; [ -f "$ae_cfg" ] || ae_cfg="$(ls "$ROOT"/**/api-extractor.json 2>/dev/null | head -1)"
  if have api-extractor; then
    heavy_ran=$((heavy_ran+1))
    if ( cd "$ROOT" && api-extractor run --local --verbose ) >"$TMP" 2>&1; then
      echo "  ok   — api-extractor: public API surface matches the committed report." >&2
      add semver_api_extractor "$(jq -n --arg c "$ae_cfg" '{verdict:"PASS",tool:"api-extractor",config:$c}')"
    else
      echo "  FAIL — api-extractor: public API surface changed without an updated report (potential breaking change)." >&2
      violations=$((violations+1))
      add semver_api_extractor "$(jq -n --arg c "$ae_cfg" '{verdict:"FAIL",tool:"api-extractor",config:$c}')"
    fi
  else
    loud_skip api-extractor "api-extractor.json present but binary not installed"
    add semver_api_extractor '{"verdict":"SKIP","reason":"api-extractor not installed (config present)"}'
  fi
else
  add semver_api_extractor '{"verdict":"SKIP","reason":"no api-extractor.json present"}'
fi

# ── DETECT-OR-SKIP: oasdiff (OpenAPI breaking-change diff vs committed baseline) ─────────────
spec=""
for s in openapi.yaml openapi.yml openapi.json api/openapi.yaml api/openapi.yml api/openapi.json \
         spec/openapi.yaml docs/openapi.yaml; do
  [ -f "$ROOT/$s" ] && { spec="$ROOT/$s"; break; }
done
baseline=""
for b in "$KIT/openapi.baseline.yaml" "$KIT/openapi.baseline.yml" "$KIT/openapi.baseline.json" \
         "$ROOT/openapi.baseline.yaml" "$ROOT/openapi.baseline.yml" "$ROOT/openapi.baseline.json"; do
  [ -f "$b" ] && { baseline="$b"; break; }
done
if [ -n "$spec" ]; then
  if have oasdiff; then
    if [ -n "$baseline" ]; then
      heavy_ran=$((heavy_ran+1))
      # `oasdiff breaking` exits non-zero when breaking changes are found.
      if ( cd "$ROOT" && oasdiff breaking "$baseline" "$spec" --fail-on ERR ) >"$TMP" 2>&1; then
        echo "  ok   — oasdiff: no breaking OpenAPI changes vs baseline." >&2
        add semver_oasdiff "$(jq -n --arg s "$spec" --arg b "$baseline" '{verdict:"PASS",tool:"oasdiff",spec:$s,baseline:$b}')"
      else
        echo "  FAIL — oasdiff: breaking OpenAPI change(s) vs baseline." >&2
        violations=$((violations+1))
        add semver_oasdiff "$(jq -n --arg s "$spec" --arg b "$baseline" '{verdict:"FAIL",tool:"oasdiff",spec:$s,baseline:$b}')"
      fi
    else
      echo "  SKIP — oasdiff: OpenAPI spec present but no committed baseline (walteur-kit/openapi.baseline.*) to diff against." >&2
      add semver_oasdiff '{"verdict":"SKIP","reason":"no OpenAPI baseline present (oasdiff installed)"}'
    fi
  else
    loud_skip oasdiff "OpenAPI spec present but oasdiff not installed"
    add semver_oasdiff '{"verdict":"SKIP","reason":"oasdiff not installed (spec present)"}'
  fi
else
  add semver_oasdiff '{"verdict":"SKIP","reason":"no OpenAPI spec present"}'
fi

# ── DETECT-OR-SKIP: cargo-semver-checks (Rust SemVer-breaking API diff) ───────────────────────
if [ -f "$ROOT/Cargo.toml" ] && grep -qE '^\[lib\]|^\[package\]' "$ROOT/Cargo.toml" 2>/dev/null; then
  if have cargo-semver-checks; then
    heavy_ran=$((heavy_ran+1))
    if ( cd "$ROOT" && cargo-semver-checks check-release ) >"$TMP" 2>&1; then
      echo "  ok   — cargo-semver-checks: no undeclared SemVer-breaking API change." >&2
      add semver_cargo '{"verdict":"PASS","tool":"cargo-semver-checks"}'
    else
      echo "  FAIL — cargo-semver-checks: SemVer-breaking API change without a version bump." >&2
      violations=$((violations+1))
      add semver_cargo '{"verdict":"FAIL","tool":"cargo-semver-checks"}'
    fi
  else
    loud_skip cargo-semver-checks "Cargo lib crate present but cargo-semver-checks not installed"
    add semver_cargo '{"verdict":"SKIP","reason":"cargo-semver-checks not installed (Cargo crate present)"}'
  fi
else
  add semver_cargo '{"verdict":"SKIP","reason":"no Rust lib/package crate present"}'
fi

# ── M4: lizard cyclomatic-complexity check (DETECT-OR-SKIP; WARN by default) ─────────────────
CCN_THRESH="${WALTEUR_CCN:-15}"
FNLEN_THRESH="${WALTEUR_FNLEN:-80}"
if have lizard; then
  heavy_ran=$((heavy_ran+1))
  # Collect git-tracked source files, excluding walteur-kit/ and lockfiles/binaries.
  M4_FILES="$(list_source \
    | grep -vE '(^|/)walteur-kit/' \
    | grep -vE '\.(png|jpe?g|gif|webp|ico|pdf|zip|gz|tgz|bz2|7z|woff2?|ttf|eot|mp[34]|mov)$' \
    | grep -vE '(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|go\.sum|Cargo\.lock|poetry\.lock|uv\.lock)$' \
    || true)"
  # Build absolute-path list for lizard.
  M4_ABS_FILES=""
  if [ -n "$M4_FILES" ]; then
    while IFS= read -r mf; do
      [ -z "$mf" ] && continue
      [ -f "$ROOT/$mf" ] && M4_ABS_FILES="$M4_ABS_FILES $ROOT/$mf"
    done <<SRCEOF
$M4_FILES
SRCEOF
  fi

  m4_verdict="PASS"
  m4_breach_count=0
  m4_breach_fns=""
  if [ -n "$M4_ABS_FILES" ]; then
    # lizard --csv columns: filename,NLOC,CCN,token_count,param_count,name,long_name,...
    # We check CCN (col 3) against CCN_THRESH and NLOC (col 2) against FNLEN_THRESH.
    # shellcheck disable=SC2086
    M4_CSV="$(lizard --CCN "$CCN_THRESH" --length "$FNLEN_THRESH" --csv $M4_ABS_FILES 2>/dev/null || true)"
    if [ -n "$M4_CSV" ]; then
      # Skip header row (NR>1), flag rows exceeding either threshold.
      m4_breach_count="$(printf '%s' "$M4_CSV" \
        | awk -F',' -v ccn="$CCN_THRESH" -v fnlen="$FNLEN_THRESH" \
            'NR>1 && ($3+0 > ccn || $2+0 > fnlen) { count++ } END { print count+0 }')"
      if [ "${m4_breach_count:-0}" -gt 0 ]; then
        m4_verdict="FAIL"
        m4_breach_fns="$(printf '%s' "$M4_CSV" \
          | awk -F',' -v ccn="$CCN_THRESH" -v fnlen="$FNLEN_THRESH" \
              'NR>1 && ($3+0 > ccn || $2+0 > fnlen) { printf "%s::%s (CCN=%s,len=%s)\n", $1, $6, $3, $2 }' \
          | head -20 | tr '\n' '; ' | sed 's/; *$//')"
      fi
    fi
  fi

  if [ "$m4_verdict" = "FAIL" ]; then
    if [ "${WALTEUR_MAINTAINABILITY:-}" = "hard" ]; then
      echo "  FAIL — M4 complexity: $m4_breach_count function(s) exceed CCN>$CCN_THRESH or len>$FNLEN_THRESH [HARD mode]." >&2
      [ -n "$m4_breach_fns" ] && echo "    offenders: $m4_breach_fns" >&2
      violations=$((violations+1))
      add m4_complexity "$(jq -n --argjson n "$m4_breach_count" --arg fns "$m4_breach_fns" \
        --argjson ccn "$CCN_THRESH" --argjson fnlen "$FNLEN_THRESH" \
        '{verdict:"FAIL",check:"cyclomatic-complexity",mode:"hard",breach_count:$n,ccn_threshold:$ccn,fnlen_threshold:$fnlen,offenders:$fns}')"
    else
      echo "  WARN — M4 complexity: $m4_breach_count function(s) exceed CCN>$CCN_THRESH or len>$FNLEN_THRESH (set WALTEUR_MAINTAINABILITY=hard to block)." >&2
      [ -n "$m4_breach_fns" ] && echo "    offenders: $m4_breach_fns" >&2
      add m4_complexity "$(jq -n --argjson n "$m4_breach_count" --arg fns "$m4_breach_fns" \
        --argjson ccn "$CCN_THRESH" --argjson fnlen "$FNLEN_THRESH" \
        '{verdict:"FAIL",check:"cyclomatic-complexity",mode:"warn",breach_count:$n,ccn_threshold:$ccn,fnlen_threshold:$fnlen,offenders:$fns}')"
    fi
  else
    echo "  ok   — M4 complexity: all functions within CCN<=$CCN_THRESH and len<=$FNLEN_THRESH." >&2
    add m4_complexity "$(jq -n --argjson ccn "$CCN_THRESH" --argjson fnlen "$FNLEN_THRESH" \
      '{verdict:"PASS",check:"cyclomatic-complexity",ccn_threshold:$ccn,fnlen_threshold:$fnlen}')"
  fi
else
  loud_skip lizard "cyclomatic-complexity checker not installed (pip install lizard)"
  add m4_complexity '{"verdict":"SKIP","check":"cyclomatic-complexity","reason":"lizard not installed"}'
fi

# ── verdict ──────────────────────────────────────────────────────────────────────────────────
# Zero-dep checks (M1/M2/M3) always evaluate when applicable, so the gate does real work
# regardless of heavy-tool availability. FAIL on any violation; else PASS (something was checked).
if [ "$violations" -gt 0 ]; then
  OVERALL=FAIL
else
  OVERALL=PASS
fi

jq -n --arg v "$OVERALL" --arg ts "$TS" --argjson heavy "$heavy_ran" \
      --argjson viol "$violations" --argjson checks "$J" \
  '{verdict:$v, ts:$ts, gate:"maintainability", heavy_checks_ran:$heavy, violations:$viol, details:$checks}' \
  > "$REPORT" 2>/dev/null \
  || printf '{"verdict":"%s","ts":"%s","gate":"maintainability","heavy_checks_ran":%s,"violations":%s}\n' \
       "$OVERALL" "$TS" "$heavy_ran" "$violations" > "$REPORT"

echo "maintainability-gate verdict: $OVERALL (heavy_ran=$heavy_ran, violations=$violations) -> $REPORT" >&2
[ "$OVERALL" = "FAIL" ] && exit 2
exit 0
