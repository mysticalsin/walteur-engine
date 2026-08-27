#!/usr/bin/env bash
# WALTEUR prd-gate — HARD gate on the PRD.md artifact (the DISCOVER-phase contract, walteur-discover skill).
# Missing/stub PRD on a user-facing-or-new product = fail (exit 2). Non-product / clean = exit 0.
# Usage:  bash walteur-kit/hooks/prd-gate.sh <dir>      (scan <dir> for a product signal)
#         bash walteur-kit/hooks/prd-gate.sh --selftest  (hermetic good/poisoned-twin self-test)
#
# Intent: a build optimized to an Opus-certified bar is still slop if it is the WRONG thing. The front-funnel
# twin of the plan-before-build and design-before-UI laws: NO PLAN WITHOUT A VALIDATED PROBLEM. The contract
# is satisfied by a non-stub walteur-kit/PRD.md (or PRD.md at root) carrying the create-prd spine.
#
# Applicability (detect-or-LOUD-SKIP — when does this gate demand a PRD?). A "product signal" is EITHER:
#   - UI source files under <dir>: *.tsx/*.jsx/*.vue/*.svelte (anywhere except vendor/build/test) or *.html, OR
#   - walteur-kit/benchmark.md exists (its presence means §2.0b ran => a user-facing product).
#   NEITHER => NOT_APPLICABLE (exit 0, loud): typo / pure-backend-CLI / brownfield-where-intent-exists.
#   By design this gate FAILS TOWARD NOT-BLOCKING (the opposite of fail-closed tool-readiness) — the front
#   funnel should never stall a legitimately-PRD-less internal build; the Senior PM veto + DISCOVER protocol
#   are the judgment-level safeguard. The PLAN-cites-PRD linkage is enforced separately by spec-lint R6.
#
# Quality floor (anti-stub) — when applicable, PRD.md must carry ALL of:
#   (1) >=12 non-empty lines,            (2) a problem/background signal,
#   (3) >=1 target-user/JTBD signal,     (4) >=1 success metric carrying a number+unit,
#   (5) a prioritized-scope signal,      (6) a NOT-doing / out-of-scope signal.
#   Any missing => FAIL (exit 2) with the missing list. A `touch PRD.md` stub does not satisfy the law.
#
# Bypass: WALTEUR_PRD=off => write SKIP report, exit 0.   Kill switch: walteur-kit/PAUSED present => exit 2.
# Zero-dep: bash + grep + awk + sed + jq + find only. HARD: real exit 2 on a real violation.
# HONESTY: the applicability SKIP = "no product signal" — honest, not silent-green. The gate is HARD on the
# PRD's EXISTENCE and NON-STUB SHAPE; whether the bet is RIGHT is PROTOCOL (red-team + Senior PM, §1).
# Report: walteur-kit/prd-gate-report.json {verdict, ts, gate, mode, prd, reason, missing_sections, details}.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "prd-gate - HARD gate on the PRD.md artifact (the DISCOVER-phase contract, walteur-discover skill)."
  printf '%s\n' "usage: bash prd-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/prd-gate-report.json - fix recipes: walteur-kit/REMEDIATION.md (## prd-gate)"
  printf '%s\n' "bypass: WALTEUR_PRD=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/prd-gate-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_report() { # $1=verdict $2=mode $3=reason $4=missing-json-array $5=details-json
  jq -n \
    --arg v "$1" --arg ts "$TS" --arg mode "$2" --arg reason "$3" --arg prd "${PRD_REL:-walteur-kit/PRD.md}" \
    --argjson missing "${4:-[]}" --argjson details "${5:-[]}" \
    '{verdict:$v, ts:$ts, gate:"prd-gate", mode:$mode, prd:$prd, reason:$reason,
      missing_sections:$missing, details:$details}' > "$REPORT"
}

run_gate() { # $1 = dir to scan for a product signal
  DIR="${1:-}"

  # ── kill switch ──────────────────────────────────────────────────────────────
  [ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }

  # ── tool guard ───────────────────────────────────────────────────────────────
  for t in grep awk sed jq find; do
    if ! command -v "$t" >/dev/null 2>&1; then
      echo "WALTEUR prd-gate SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
      write_report "SKIP" "tool-missing" "$t not installed" '[]' '[]'; exit 0
    fi
  done

  # ── bypass ───────────────────────────────────────────────────────────────────
  if [ "${WALTEUR_PRD:-on}" = "off" ]; then
    echo "WALTEUR prd-gate SKIP — bypass WALTEUR_PRD=off (recorded, not silent-green)." >&2
    write_report "SKIP" "bypass" "bypass WALTEUR_PRD=off" '[]' '[]'; exit 0
  fi

  if [ -z "$DIR" ]; then
    echo "WALTEUR prd-gate SKIP — no directory argument. Usage: prd-gate.sh <dir>" >&2
    write_report "SKIP" "no-arg" "no directory argument" '[]' '[]'; exit 0
  fi
  if [ ! -d "$DIR" ]; then
    echo "WALTEUR prd-gate SKIP — '$DIR' is not a directory (nothing to scan)." >&2
    write_report "SKIP" "bad-arg" "not a directory: $DIR" '[]' '[]'; exit 0
  fi

  # ── quick-fix track bypass (S6 — demand_prd:false for quick-fix) ───────────────
  # When walteur.js classified this build as a quick-fix (scope-track.json track=quick-fix), the CEREMONY
  # deliberately does NOT demand a PRD (demand_prd:false). Blocking on a missing PRD here would deadlock
  # quick-fix builds that touch UI files. The judgment safeguard is the Senior PM veto + the scope-track
  # classifier, which requires a very small scope (<=2 files / <=3 scope items). LOUD SKIP (not silent-green).
  if [ -f "$KIT/scope-track.json" ] && command -v jq >/dev/null 2>&1; then
    local track; track="$(jq -r '.track // ""' "$KIT/scope-track.json" 2>/dev/null || echo '')"
    if [ "$track" = "quick-fix" ]; then
      echo "WALTEUR prd-gate SKIP — scope-track=quick-fix (demand_prd:false; Senior PM veto is the safeguard)." >&2
      write_report "SKIP" "quick-fix-track" "quick-fix track does not demand a PRD (ceremony.demand_prd=false)" '[]' '[]'
      exit 0
    fi
  fi

  # ── applicability: is there a product signal? ─────────────────────────────────
  PRUNE=( \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/storybook-static/*' -o -path '*/walteur-kit/*' \) -prune -o )
  UI_COUNT=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    base="$(basename "$f")"
    case "$base" in *.test.*|*.spec.*|*.stories.*) continue ;; esac
    UI_COUNT=$((UI_COUNT+1))
  done < <(find "$DIR" "${PRUNE[@]}" \
    -type f \( -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' -o -name '*.html' \) -print 2>/dev/null)

  HAS_BENCHMARK=0
  [ -f "$KIT/benchmark.md" ] && HAS_BENCHMARK=1

  if [ "$UI_COUNT" -eq 0 ] && [ "$HAS_BENCHMARK" -eq 0 ]; then
    echo "WALTEUR prd-gate NOT_APPLICABLE — no product signal (no UI files under '$DIR', no walteur-kit/benchmark.md)." >&2
    write_report "NOT_APPLICABLE" "not-applicable" \
      "no product signal: no UI files and no benchmark.md (typo/CLI/brownfield-where-intent-exists tier)" '[]' '[]'
    exit 0
  fi

  # ── locate the PRD contract ───────────────────────────────────────────────────
  PRD=""
  for cand in "$KIT/PRD.md" "$ROOT/PRD.md" "$DIR/PRD.md"; do
    [ -f "$cand" ] && { PRD="$cand"; break; }
  done
  PRD_REL="${PRD#"$ROOT"/}"

  if [ -z "$PRD" ]; then
    PRD_REL="walteur-kit/PRD.md"
    write_report "FAIL" "applicable" \
      "product signal present (ui=$UI_COUNT benchmark=$HAS_BENCHMARK) but no PRD.md (walteur-kit/PRD.md or PRD.md)" \
      '["problem","target-user","success-metric","prioritized-scope","not-doing"]' \
      '[{"rule":"missing-prd","message":"product signal exists but no PRD — no PLAN without a validated problem (WALTEUR §2.5 / walteur-discover). Write walteur-kit/PRD.md from PRD.template.md."}]'
    echo "WALTEUR prd-gate: FAIL — product signal (ui=$UI_COUNT, benchmark=$HAS_BENCHMARK) but NO PRD.md." >&2
    echo "  Fix: author walteur-kit/PRD.md (copy walteur-kit/PRD.template.md; run DISCOVER, walteur-discover skill)." >&2
    exit 2
  fi

  # ── anti-stub quality floor (zero-dep, grep/awk) ──────────────────────────────
  NONEMPTY="$(grep -cv '^[[:space:]]*$' "$PRD" 2>/dev/null)"; NONEMPTY="${NONEMPTY:-0}"
  MISSING=()
  [ "$NONEMPTY" -lt 12 ] && MISSING+=("min-lines(>=12, got $NONEMPTY)")
  grep -Eqi 'problem|background|why[ -]?now' "$PRD" || MISSING+=("problem/background")
  grep -Eqi 'when .*(so i can|so they can|so that)|jtbd|target user|job[ -]?to[ -]?be[ -]?done' "$PRD" || MISSING+=("target-user/JTBD")
  # success metric: a number+unit OR an explicit baseline+target pair (same relaxation as spec-lint R3 —
  # keeps the two gates' floors identical and avoids a false-positive on metrics stated as baseline/target).
  if ! grep -Eqi '[0-9]+(\.[0-9]+)?[[:space:]]*(ms|s|m|h|%|x|rps|qps|req|requests|gb|mb|kb|tb|users|p50|p95|p99|fps|days?|hrs?|hours?|mins?|min|seconds?|€|\$|usd|eur)' "$PRD" \
       && ! { grep -qiE '\bbaseline\b' "$PRD" && grep -qiE '\btarget\b' "$PRD"; }; then
    MISSING+=("success-metric(number+unit or baseline+target)")
  fi
  grep -Eqi 'scope|prioriti|wedge|RICE|ICE|opportunity score|scope_ranked' "$PRD" || MISSING+=("prioritized-scope")
  grep -Eqi 'not[- ]?doing|out[- ]?of[- ]?scope|deprioriti|not for|anti-persona' "$PRD" || MISSING+=("not-doing/out-of-scope")

  if [ "${#MISSING[@]}" -gt 0 ]; then
    MISS_JSON="$(printf '%s\n' "${MISSING[@]}" | jq -R . | jq -s '.')"
    write_report "FAIL" "applicable" \
      "PRD '$PRD_REL' is a stub — missing: $(printf '%s; ' "${MISSING[@]}")" "$MISS_JSON" \
      "$(jq -n --arg f "$PRD_REL" --argjson m "$MISS_JSON" \
        '[{"rule":"stub-prd","file":$f,"missing":$m,"message":"PRD does not satisfy the non-stub floor — a touch-stub does not validate the bet; fill PRD.template.md (problem · JTBD · metric+unit · prioritized scope · NOT-doing)."}]')"
    echo "WALTEUR prd-gate: FAIL — PRD '$PRD_REL' is a stub. Missing: ${MISSING[*]}" >&2
    exit 2
  fi

  write_report "PASS" "applicable" "PRD present + non-stub: $PRD_REL ($NONEMPTY non-empty lines)" '[]' '[]'
  echo "WALTEUR prd-gate: PASS — product signal governed by '$PRD_REL' ($NONEMPTY non-empty lines)." >&2
  exit 0
}

# ── embedded self-test (good + poisoned twins; hermetic temp project) ────────────
selftest() {
  local fails=0 total=0 tmp rc
  local SELF; SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  run_one() { # $1=label $2=want-rc $3=setup-fn
    total=$((total+1))
    # macOS `mktemp -d` ignores $TMPDIR; give it an explicit template so it lands in a writable dir.
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/prd-gate-selftest.XXXXXX")" || {
      echo "  FAIL — $1 (mktemp could not create a temp dir under ${TMPDIR:-/tmp})"; fails=$((fails+1)); return; }
    mkdir -p "$tmp/walteur-kit" "$tmp/src"
    "$3" "$tmp"
    set +e
    WALTEUR_ROOT="$tmp" WALTEUR_PRD=on bash "$SELF" "$tmp/src" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq "$2" ]; then
      echo "  ok   — $1 (rc=$rc)"
    else
      echo "  FAIL — $1 (rc=$rc, want $2)"; fails=$((fails+1))
    fi
    rm -rf "$tmp"
  }

  good_setup() { # complete PRD + a UI file => PASS (0)
    printf '<div>app</div>\n' > "$1/src/App.tsx"
    cat > "$1/walteur-kit/PRD.md" <<'EOF'
---
prd_version: 1
product: demo
---
# PRD — demo
## 1. Summary
A tool to do the thing.
## 2. Background — why now?
The problem just became tractable.
## 3. Objective
North-star: activation rate, target 40%. Leading: time-to-first-value < 5 min.
## 4. Target user (JTBD + anti-persona)
When onboarding a new repo, I want to validate a bet, so I can avoid building the wrong thing.
Anti-persona: not for casual browsers.
## 6. Prioritized scope (the wedge)
RICE-ranked. v1 = the validator. NOT-doing: no GTM in v1 (out of scope).
## 7. Load-bearing assumptions
Claim: activation is the constraint. Fails if churn is at onboarding. Kill-criterion: <2/5 reach value.
EOF
  }
  stub_setup() { # stub PRD + a UI file => FAIL (2)
    printf '<div>app</div>\n' > "$1/src/App.tsx"
    printf '# PRD\nTODO\n' > "$1/walteur-kit/PRD.md"
  }
  none_setup() { # no UI, no benchmark, no PRD => NOT_APPLICABLE (0)
    printf 'print("cli")\n' > "$1/src/main.py"
  }
  missing_setup() { # UI present but NO PRD => FAIL (2)
    printf '<div>app</div>\n' > "$1/src/App.tsx"
  }
  good_bt_setup() { # complete PRD, metric as baseline/target prose (NO number+unit) => PASS via R3-parity relaxation
    printf '<div>app</div>\n' > "$1/src/App.tsx"
    cat > "$1/walteur-kit/PRD.md" <<'EOF'
---
prd_version: 1
product: demo
---
# PRD — demo
## 1. Summary
A tool to do the thing.
## 2. Background — why now?
The problem just became tractable.
## 3. Objective
Success metric: baseline activation is low; the target is to roughly double it.
## 4. Target user (JTBD + anti-persona)
When onboarding a repo, I want to validate a bet, so I can avoid building the wrong thing.
Anti-persona: not for casual browsers.
## 6. Prioritized scope (the wedge)
RICE-ranked. v1 = the validator. NOT-doing: no GTM in v1 (out of scope).
## 7. Load-bearing assumptions
Claim: activation is the constraint. Fails if churn is at onboarding. Kill-criterion: low reach.
EOF
  }

  echo "prd-gate selftest:"
  run_one "good twin: complete PRD + UI -> PASS"        0 good_setup
  run_one "good twin: baseline+target prose (no num+unit) -> PASS" 0 good_bt_setup
  run_one "poisoned twin: stub PRD + UI -> FAIL"        2 stub_setup
  run_one "no product signal (CLI) -> NOT_APPLICABLE"   0 none_setup
  run_one "UI present, PRD absent -> FAIL"              2 missing_setup
  echo "prd-gate selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest; exit $?
fi
run_gate "${1:-}"
