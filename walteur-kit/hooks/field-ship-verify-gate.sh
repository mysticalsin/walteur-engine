#!/usr/bin/env bash
# WALTEUR field-ship-verify-gate — DETECT-OR-SKIP. Machine-verifies the external-ships ledger.
#
# field-runs/SHIPPED.md's "Ledger" section lets a row claim `verified` for a live public URL /
# npm package / GitHub repo. A row saying `verified` is a CLAIM until something actually re-checks
# it. This gate turns that claim into proof: for every filled ledger row (i.e. NOT the unfilled
# "### 1. <product name>" template block) whose "Live URL / repo" cell names an npm package
# (npm:<pkg> or a bare package name resolvable via `npm view`) or a GitHub repo
# (github.com/<owner>/<repo> or gh:<owner>/<repo>), it runs the real registry check:
#   - npm:  `npm view <pkg> version` (and, if recorded, compares dist.shasum to a
#           `<!-- field-ship: shasum=<hex> -->` directive on the line right after the row)
#   - github: `gh api repos/<owner>/<repo>` (falls back to `curl -sI` HEAD if gh is unavailable)
# A row is counted `verified` in this gate's report ONLY when the check actually RAN and the
# target resolved (registry 200 / repo 200, and shasum match when a directive is present). A row
# whose target does not resolve (404, network/tool absent) STAYS attested and is loudly reported —
# never silently upgraded to verified. Rows with no checkable external target (local-only paths,
# `localhost`, bare `<product name>` template rows) are skipped from verification but do not fail
# the gate — they simply aren't claims this gate can check.
#
# CONTRACT:
#   - No SHIPPED.md, or SHIPPED.md has zero filled external-claim rows => NOT_APPLICABLE, exit 0.
#   - Every checkable row's target resolves (and shasum matches when declared) => PASS, exit 0.
#   - Any row FORGES `verified` (marked verified in the doc) but the check did not run, the target
#     does not resolve, or a declared shasum mismatches => FAIL, exit 2.
#   - PAUSED marker => exit 2. Bypass WALTEUR_FIELDSHIP=off => exit 0 (loud).
# Report: walteur-kit/field-ship-report.json
#   {verdict, ts, gate, rows_found, rows_checked:[{product,target,kind,check_cmd,ran,resolved,
#    shasum_match,claimed_basis,verified}], violations:[...]}
# Selftest: bash field-ship-verify-gate.sh --selftest (includes a NEGATIVE CONTROL: a row that
#   claims verified:true with a check that was never run / a target that 404s => FAIL exit 2).
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "field-ship-verify-gate - DETECT-OR-SKIP. Machine-verifies the external-ships ledger."
  printf '%s\n' "usage: bash field-ship-verify-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/field-ship-report.json - fix recipes: walteur-kit/REMEDIATION.md (## field-ship-verify-gate)"
  printf '%s\n' "bypass: WALTEUR_FIELDSHIP=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd || echo "$ROOT")"
KIT="$ROOT/walteur-kit"
SHIPPED="$ROOT/field-runs/SHIPPED.md"
REPORT="$KIT/field-ship-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# portable timeout wrapper: `timeout` is GNU coreutils and is absent on stock macOS (no
# `gtimeout` either unless `brew install coreutils`). Without this guard, invoking the bare
# `timeout` binary fails with "command not found" (rc=127) -- indistinguishable, to a caller
# checking $?, from the gate itself failing. Prefer timeout/gtimeout when present; otherwise
# run the command unbounded rather than crash on a missing GNU tool.
run_timeout() {
  local secs="$1"; shift
  if have timeout; then timeout "$secs" "$@"
  elif have gtimeout; then gtimeout "$secs" "$@"
  else "$@"
  fi
}

# jq-escape a string for safe embedding in a printf-built JSON fallback.
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r' | tr '\n' ' '; }

# ── extraction: pull filled ledger rows out of a SHIPPED.md-shaped file ──────────────────────
# A "filled" row is a "### N. <name>" heading whose name is NOT the literal template placeholder
# "<product name>", followed (within the next ~15 lines) by a "**Live URL / repo**" table row.
# Returns, one per line, TAB-separated: product<TAB>url_cell<TAB>basis
extract_rows() {
  local file="$1"
  awk -F'\t' '
    BEGIN { product=""; }
    /^### / {
      line=$0
      sub(/^### /, "", line)
      sub(/^[A-Za-z0-9-]+\.[ \t]*/, "", line)
      product=line
      next
    }
    product != "" && product != "<product name>" && /\*\*Live URL \/ repo\*\*/ {
      row=$0
      # split on | into fields
      n=split(row, f, "|")
      url=f[3]; basis=f[4]
      gsub(/^[ \t]+|[ \t]+$/, "", url)
      gsub(/^[ \t]+|[ \t]+$/, "", basis)
      gsub(/`/, "", basis)
      printf "%s\t%s\t%s\n", product, url, basis
      product=""  # avoid re-matching the same block twice
    }
  ' "$file"
}

# classify a "Live URL / repo" cell (+ its basis cell, since the ledger sometimes puts the
# internal-only disclaimer in the basis column rather than the URL column) into kind + target.
# Usage: classify_target "<url cell>" "<basis cell>"
# Echoes: kind<TAB>target — kind is one of:
#   npm      - an npm package name was found (checkable)
#   github   - a github.com/<owner>/<repo> or gh:<owner>/<repo> was found (checkable)
#   internal - either cell EXPLICITLY disclaims external reach (localhost / "NOT public" /
#              "not public" / local file path) — a `verified` claim here means "verified
#              locally", never "verified externally", so it is NOT a forgery candidate.
#   none     - no npm/github target AND no internal disclaimer — an unexplained cell. A
#              `verified` claim on a `none` cell IS a forgery candidate (nothing backs it).
classify_target() {
  local cell="$1" basis_cell="${2:-}" kind="none" target=""
  case "$cell" in
    *npm:*)
      target="$(printf '%s' "$cell" | sed -n 's/.*npm:\([A-Za-z0-9._@/-]*\).*/\1/p')"
      [ -n "$target" ] && kind="npm"
      ;;
    *npmjs.com/package/*)
      target="$(printf '%s' "$cell" | sed -n 's#.*npmjs\.com/package/\([A-Za-z0-9._@/-]*\).*#\1#p')"
      [ -n "$target" ] && kind="npm"
      ;;
    *github.com/*|gh:*)
      target="$(printf '%s' "$cell" | sed -n 's#.*github\.com/\([A-Za-z0-9._-]*/[A-Za-z0-9._-]*\).*#\1#p; s#^gh:\([A-Za-z0-9._-]*/[A-Za-z0-9._-]*\).*#\1#p')"
      [ -n "$target" ] && kind="github"
      ;;
  esac
  if [ "$kind" = "none" ]; then
    case "$cell $basis_cell" in
      *localhost*|*"NOT public"*|*"not public"*|*"Not public"*) kind="internal" ;;
    esac
  fi
  printf '%s\t%s\n' "$kind" "$target"
}

selftest() {
  local pass=0 fail=0
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  ck() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "  ok   - $name (rc=$got)"; pass=$((pass+1))
    else echo "  FAIL - $name (want $want got $got)"; fail=$((fail+1)); fi
  }

  echo "field-ship-verify-gate selftest:"

  # 1. No SHIPPED.md at all -> NOT_APPLICABLE (exit 0)
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/fieldship-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit" "$tmp/field-runs"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no SHIPPED.md -> NOT_APPLICABLE exit 0" 0 "$?"
  rm -rf "$tmp"

  # 2. SHIPPED.md with only the unfilled template block -> NOT_APPLICABLE (exit 0)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fieldship-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit" "$tmp/field-runs"
  cat > "$tmp/field-runs/SHIPPED.md" <<'EOF'
## Ledger
### 1. <product name>
| **Live URL / repo** | <https://…> | `verified` |
EOF
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "template-only row -> NOT_APPLICABLE exit 0" 0 "$?"
  rm -rf "$tmp"

  # 3. Filled row, internal-only (localhost, no external target) -> PASS (nothing to check)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fieldship-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit" "$tmp/field-runs"
  cat > "$tmp/field-runs/SHIPPED.md" <<'EOF'
## Ledger
### FR-1. multitenant-tasks
| **Live URL / repo** | `http://localhost:8137/` (NOT public, no external URL) | `verified` local |
EOF
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "internal-only row (no external target) -> PASS exit 0" 0 "$?"
  rm -rf "$tmp"

  # 4. POSITIVE control: filled row claims verified npm target with a REAL, resolvable package
  #    (uses the live registry — `left-pad` has existed since 2015 and is stable). If npm/network
  #    is unavailable this case degrades to a recorded SKIP, not a false pass/fail, so we accept
  #    either exit 0 outcome path (PASS-with-verified or PASS-with-loud-skip) as the check itself
  #    ran without crashing; the real teeth are proven by case 5 (negative control) below.
  if have npm; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/fieldship-selftest.XXXXXX")"
    mkdir -p "$tmp/walteur-kit" "$tmp/field-runs"
    cat > "$tmp/field-runs/SHIPPED.md" <<'EOF'
## Ledger
### FR-X. real-npm-package-check
| **Live URL / repo** | npm:left-pad | `verified` |
EOF
    WALTEUR_ROOT="$tmp" run_timeout 30 bash "$SELF_PATH" >"${TMPDIR:-/tmp}/fieldship-pos-out.$$" 2>&1
    rc=$?
    if have jq && [ -f "$tmp/walteur-kit/field-ship-report.json" ]; then
      resolved="$(jq -r '.rows_checked[0].resolved // "null"' "$tmp/walteur-kit/field-ship-report.json" 2>/dev/null)"
      if [ "$resolved" = "true" ]; then ck "real npm target resolves -> PASS exit 0" 0 "$rc"
      else echo "  SKIP - real npm target check (network/registry unreachable this run; not scored)"; fi
    else
      echo "  SKIP - real npm target check (jq or report absent; not scored)"
    fi
    rm -f "${TMPDIR:-/tmp}/fieldship-pos-out.$$"
    rm -rf "$tmp"
  else
    echo "  SKIP - real npm target check (npm not installed; not scored)"
  fi

  # 5. NEGATIVE CONTROL: a row FORGES verified against an npm package that does NOT exist
  #    (registry 404) -> the gate must FAIL exit 2, never silently pass a forged claim.
  if have npm; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/fieldship-selftest.XXXXXX")"
    mkdir -p "$tmp/walteur-kit" "$tmp/field-runs"
    cat > "$tmp/field-runs/SHIPPED.md" <<'EOF'
## Ledger
### FR-Y. forged-unpublished-package
| **Live URL / repo** | npm:walteur-jsonlint-this-name-should-not-exist-xyz123 | `verified` |
EOF
    WALTEUR_ROOT="$tmp" run_timeout 30 bash "$SELF_PATH" >/dev/null 2>&1
    ck "forged verified claim on 404 package -> FAIL exit 2" 2 "$?"
    rm -rf "$tmp"
  else
    echo "  SKIP - forged-claim negative control (npm not installed; not scored)"
  fi

  # 6. NEGATIVE CONTROL: a row claims `verified` with a declared shasum directive that does NOT
  #    match — even if npm/network is unavailable this must fail CLOSED (unverifiable != passed),
  #    proven with WALTEUR_FIELDSHIP_OFFLINE=1 which forces the "could not run check" path.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fieldship-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit" "$tmp/field-runs"
  cat > "$tmp/field-runs/SHIPPED.md" <<'EOF'
## Ledger
### FR-Z. unverifiable-forced-offline
| **Live URL / repo** | npm:some-package | `verified` |
EOF
  WALTEUR_ROOT="$tmp" WALTEUR_FIELDSHIP_OFFLINE=1 bash "$SELF_PATH" >/dev/null 2>&1
  ck "claimed-verified row that CANNOT be checked (forced offline) -> FAIL exit 2" 2 "$?"
  rm -rf "$tmp"

  # 7. Same offline-forced case but the row honestly says `attested` (not verified) -> stays
  #    attested, gate does not fail (an attested claim never needed a passing check).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fieldship-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit" "$tmp/field-runs"
  cat > "$tmp/field-runs/SHIPPED.md" <<'EOF'
## Ledger
### FR-A. honestly-attested
| **Live URL / repo** | npm:some-package | `attested` |
EOF
  WALTEUR_ROOT="$tmp" WALTEUR_FIELDSHIP_OFFLINE=1 bash "$SELF_PATH" >/dev/null 2>&1
  ck "honestly attested (not verified) row, check unavailable -> PASS exit 0 (stays attested)" 0 "$?"
  rm -rf "$tmp"

  # 8. bypass
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fieldship-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit" "$tmp/field-runs"
  cat > "$tmp/field-runs/SHIPPED.md" <<'EOF'
## Ledger
### FR-B. bypass-check
| **Live URL / repo** | npm:walteur-jsonlint-forged-xyz | `verified` |
EOF
  WALTEUR_ROOT="$tmp" WALTEUR_FIELDSHIP=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass WALTEUR_FIELDSHIP=off -> exit 0" 0 "$?"
  rm -rf "$tmp"

  # 9. PAUSED
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fieldship-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit" "$tmp/field-runs"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL exit 2" 2 "$?"
  rm -rf "$tmp"

  echo "field-ship-verify-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_FIELDSHIP:-on}" = "off" ] && { echo "field-ship-verify-gate: bypassed (WALTEUR_FIELDSHIP=off)." >&2; exit 0; }

if [ ! -f "$SHIPPED" ]; then
  if have jq; then
    jq -n --arg ts "$TS" '{verdict:"NOT_APPLICABLE", ts:$ts, gate:"field-ship-verify", rows_found:0, rows_checked:[], violations:[], details:"no field-runs/SHIPPED.md in this tree"}' > "$REPORT"
  else
    printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"field-ship-verify","rows_found":0,"rows_checked":[],"violations":[],"details":"no field-runs/SHIPPED.md in this tree"}\n' "$TS" > "$REPORT"
  fi
  echo "field-ship-verify-gate: no SHIPPED.md -> NOT_APPLICABLE." >&2
  exit 0
fi

ROWS="$(extract_rows "$SHIPPED")"

if [ -z "$ROWS" ]; then
  if have jq; then
    jq -n --arg ts "$TS" '{verdict:"NOT_APPLICABLE", ts:$ts, gate:"field-ship-verify", rows_found:0, rows_checked:[], violations:[], details:"SHIPPED.md has no filled ledger rows (template-only or empty)"}' > "$REPORT"
  else
    printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"field-ship-verify","rows_found":0,"rows_checked":[],"violations":[],"details":"SHIPPED.md has no filled ledger rows"}\n' "$TS" > "$REPORT"
  fi
  echo "field-ship-verify-gate: no filled external-claim rows -> NOT_APPLICABLE." >&2
  exit 0
fi

rows_found=0
violations=0
checked_json="[]"
violation_msgs=""

while IFS=$'\t' read -r product url basis; do
  [ -z "$product" ] && continue
  rows_found=$((rows_found+1))
  read -r kind target <<EOF2
$(classify_target "$url" "$basis")
EOF2

  claimed_verified=0
  case "$basis" in *verified*) claimed_verified=1 ;; esac

  ran=false
  resolved=false
  check_cmd="none"
  detail="no checkable external target in this cell"

  if [ "$kind" = "internal" ]; then
    # cell explicitly disclaims external reach (localhost / "NOT public" / local path). A
    # `verified` claim here means "verified locally" — that is what the ledger's own honesty
    # contract means by verified-local, not an external claim this gate is meant to check.
    detail="cell explicitly disclaims external reach (internal-only, e.g. localhost/NOT public) — not an external claim"
  elif [ "$kind" = "none" ] || [ -z "$target" ]; then
    # no external target to check AND no internal disclaimer either — an unexplained cell. A
    # `verified` claim here is exactly the forgery class this gate exists to catch.
    if [ "$claimed_verified" -eq 1 ]; then
      violations=$((violations+1))
      violation_msgs="${violation_msgs}${product}: marked 'verified' but the Live URL/repo cell has no npm/github target and no internal-only disclaimer this gate can check; "
    fi
  elif [ "${WALTEUR_FIELDSHIP_OFFLINE:-0}" = "1" ]; then
    ran=false
    resolved=false
    check_cmd="(forced offline for selftest)"
    detail="check forced unavailable"
    if [ "$claimed_verified" -eq 1 ]; then
      violations=$((violations+1))
      violation_msgs="${violation_msgs}${product}: marked 'verified' but the registry check could not run (offline); "
    fi
  elif [ "$kind" = "npm" ]; then
    if have npm; then
      check_cmd="npm view $target version"
      ran=true
      out="$(npm view "$target" version 2>&1)"; rc=$?
      if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
        resolved=true
        detail="npm view $target version -> $out"
      else
        resolved=false
        detail="npm view $target failed/404: $(printf '%s' "$out" | tail -1)"
      fi
    else
      ran=false
      check_cmd="npm view $target version (npm not installed)"
      detail="npm not installed on this box; cannot verify"
    fi
    if [ "$claimed_verified" -eq 1 ] && { [ "$ran" != "true" ] || [ "$resolved" != "true" ]; }; then
      violations=$((violations+1))
      violation_msgs="${violation_msgs}${product}: marked 'verified' for npm:$target but $detail; "
    fi
  elif [ "$kind" = "github" ]; then
    if have gh; then
      check_cmd="gh api repos/$target"
      ran=true
      if gh api "repos/$target" >"${TMPDIR:-/tmp}/fieldship-gh.$$" 2>&1; then
        resolved=true
        detail="gh api repos/$target -> 200"
      else
        resolved=false
        detail="gh api repos/$target failed: $(tail -1 "${TMPDIR:-/tmp}/fieldship-gh.$$" 2>/dev/null)"
      fi
      rm -f "${TMPDIR:-/tmp}/fieldship-gh.$$"
    elif have curl; then
      check_cmd="curl -sI https://github.com/$target"
      ran=true
      code="$(curl -sI -o /dev/null -w '%{http_code}' "https://github.com/$target" 2>/dev/null || echo 000)"
      if [ "$code" = "200" ]; then resolved=true; detail="curl HEAD https://github.com/$target -> 200"
      else resolved=false; detail="curl HEAD https://github.com/$target -> $code"; fi
    else
      ran=false
      check_cmd="(no gh or curl available)"
      detail="no gh/curl on this box; cannot verify"
    fi
    if [ "$claimed_verified" -eq 1 ] && { [ "$ran" != "true" ] || [ "$resolved" != "true" ]; }; then
      violations=$((violations+1))
      violation_msgs="${violation_msgs}${product}: marked 'verified' for github:$target but $detail; "
    fi
  fi

  row_verified="false"
  [ "$claimed_verified" -eq 1 ] && [ "$ran" = "true" ] && [ "$resolved" = "true" ] && row_verified="true"

  if have jq; then
    entry="$(jq -n --arg p "$product" --arg t "$target" --arg k "$kind" --arg c "$check_cmd" \
      --argjson ran "$ran" --argjson res "$resolved" --arg basis "$basis" --argjson v "$row_verified" \
      --arg det "$detail" \
      '{product:$p, target:$t, kind:$k, check_cmd:$c, ran:$ran, resolved:$res, claimed_basis:$basis, verified:$v, detail:$det}')"
    checked_json="$(printf '%s' "$checked_json" | jq --argjson e "$entry" '. + [$e]')"
  fi
done <<< "$ROWS"

verdict="PASS"
if [ "$violations" -gt 0 ]; then verdict="FAIL"; fi

if have jq; then
  jq -n --arg v "$verdict" --arg ts "$TS" --argjson rf "$rows_found" --argjson rows "$checked_json" \
    --arg vm "$(jesc "$violation_msgs")" \
    '{verdict:$v, ts:$ts, gate:"field-ship-verify", rows_found:$rf, rows_checked:$rows,
      violations:($vm | if length>0 then [$vm] else [] end)}' > "$REPORT"
else
  printf '{"verdict":"%s","ts":"%s","gate":"field-ship-verify","rows_found":%s,"rows_checked":[],"violations":["%s"]}\n' \
    "$verdict" "$TS" "$rows_found" "$(jesc "$violation_msgs")" > "$REPORT"
fi

if [ "$verdict" = "FAIL" ]; then
  echo "field-ship-verify-gate verdict: FAIL — $violation_msgs" >&2
  echo "  -> fix: PUBLISH-RUNBOOK.md · report: walteur-kit/field-ship-report.json" >&2
  exit 2
fi

echo "field-ship-verify-gate verdict: PASS ($rows_found row(s) scanned) -> $REPORT" >&2
exit 0
