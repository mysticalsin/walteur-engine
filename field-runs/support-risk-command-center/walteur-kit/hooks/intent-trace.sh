#!/usr/bin/env bash
# WALTEUR intent-trace — the DETERMINISTIC structural arm of §5.5 (intended-vs-implemented).
# For each PRD acceptance-criterion that PINS an enforceable construct (ast_proof block), run the
# ast-grep pattern and PROVE the construct EXISTS at a concrete file:line. Lands a proof object into
# walteur-kit/audit.json intent_vs_impl[].ast_proof and HARD-fails (exit 2) on a claimed-but-ABSENT construct.
#
# HONESTY BOUNDARY (load-bearing — do not erode):
#   * HARD: ast-grep proves the construct EXISTS at a file:line (a tree-sitter AST match — deterministic,
#     not an LLM read). matched:true|false is mechanical.
#   * NOT a correctness guarantee: it does NOT prove the construct is semantically correct or that it actually
#     enforces the rule on the LIVE path. That stays PROTOCOL — the §5.4 Logic-Correctness QA arm + the
#     policy-shadow guard. This hook DE-CIRCULARIZES EXISTENCE, never correctness. Every proof object carries
#     proves:"existence" so a downstream reader can never mistake it for a correctness claim.
#   * Absence of a match = NOT-FOUND (a real finding), never PROVEN-ABSENT of the *behavior*.
#
# Applicability (detect-or-LOUD-SKIP, mirrors prd-gate.sh idiom):
#   * no PRD proofs sidecar, or zero ast_proof blocks => NOT_APPLICABLE (exit 0, loud).
#   * ast-grep binary absent BUT >=1 ast_proof exists => LOUD SKIP recorded (exit 0) UNLESS
#     WALTEUR_INTENT_TRACE=strict, in which case missing-tool => exit 2 (ship-gate posture).
#   * jq absent => recorded SKIP (not silent-green).
# Bypass: WALTEUR_INTENT_TRACE=off. Kill switch: walteur-kit/PAUSED.
# Self-test: bash walteur-kit/hooks/intent-trace.sh --selftest  (requires ast-grep + jq).
# Report: merged into walteur-kit/audit.json under intent_vs_impl[]; standalone log to stderr.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
AUDIT="$KIT/audit.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MODE="${WALTEUR_INTENT_TRACE:-on}"
mkdir -p "$KIT"

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "$MODE" = "off" ] && { echo "intent-trace: bypassed (WALTEUR_INTENT_TRACE=off)." >&2; exit 0; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── embedded self-test (good + poisoned twins; hermetic temp project) ────────────
# Requires ast-grep on PATH; if absent, the selftest SKIPs loudly (CI declares ast-grep required here).
selftest() {
  local fails=0 total=0 tmp rc
  local SELF; SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  command -v ast-grep >/dev/null 2>&1 || { echo "intent-trace selftest SKIP — ast-grep not installed (CI must install it)."; return 0; }
  command -v jq       >/dev/null 2>&1 || { echo "intent-trace selftest SKIP — jq not installed."; return 0; }

  run_one() { # $1=label $2=want-rc $3=setup-fn
    total=$((total+1))
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/intent-trace-selftest.XXXXXX")" || { echo "  FAIL — $1 (mktemp)"; fails=$((fails+1)); return; }
    mkdir -p "$tmp/walteur-kit" "$tmp/src/routes/admin"
    "$3" "$tmp"
    set +e
    WALTEUR_ROOT="$tmp" WALTEUR_INTENT_TRACE=on bash "$SELF" >/dev/null 2>&1; rc=$?
    set -e
    if [ "$rc" -eq "$2" ]; then echo "  ok   — $1 (rc=$rc)"; else echo "  FAIL — $1 (rc=$rc, want $2)"; fails=$((fails+1)); fi
    rm -rf "$tmp"
  }

  # GOOD twin — the pinned authz construct EXISTS in code => MUST PASS (exit 0).
  good_setup() {
    printf "export function h(req,res){ requireRole('admin'); res.send('ok'); }\n" > "$1/src/routes/admin/users.ts"
    cat > "$1/walteur-kit/prd.proofs.json" <<'JSON'
[ { "story":"STORY-7","ac":"AC2","construct":"authz-check",
    "text":"every /admin route enforces requireRole('admin')",
    "lang":"ts","glob":"src/routes/admin/**/*.ts","pattern":"requireRole('admin')" } ]
JSON
  }
  # POISONED twin — SAME pinned construct, but the code OMITS the authz call (build silently dropped it)
  #   => the AST match is empty => matched:false => MUST be CAUGHT (exit 2).
  poisoned_setup() {
    printf "export function h(req,res){ res.send('ok'); }\n" > "$1/src/routes/admin/users.ts"   # NO requireRole
    cat > "$1/walteur-kit/prd.proofs.json" <<'JSON'
[ { "story":"STORY-7","ac":"AC2","construct":"authz-check",
    "text":"every /admin route enforces requireRole('admin')",
    "lang":"ts","glob":"src/routes/admin/**/*.ts","pattern":"requireRole('admin')" } ]
JSON
  }
  # NOT_APPLICABLE twin — no proofs file => exit 0 (legacy path untouched).
  na_setup() { :; }

  echo "intent-trace selftest:"
  run_one "good twin: pinned authz construct EXISTS -> PASS"      0 good_setup
  run_one "poisoned twin: construct DROPPED from code -> CAUGHT" 2 poisoned_setup
  run_one "no proofs file -> NOT_APPLICABLE"                      0 na_setup
  echo "intent-trace selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}
if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

# proofs MUST come from a structured PRD. We read ast_proof blocks from a JSON sidecar the PRD-author
# emits (walteur-kit/prd.proofs.json) — derived from the PRD front-matter stories[].acceptance[].ast_proof.
PROOFS="$KIT/prd.proofs.json"
if ! have jq; then echo "intent-trace SKIP — jq absent (recorded, not silent-green)." >&2; exit 0; fi
if [ ! -f "$PROOFS" ]; then echo "intent-trace NOT_APPLICABLE — no $PROOFS (no AC pins a construct)." >&2; exit 0; fi
COUNT="$(jq 'length' "$PROOFS" 2>/dev/null || echo 0)"
[ "${COUNT:-0}" -eq 0 ] && { echo "intent-trace NOT_APPLICABLE — zero ast_proof blocks." >&2; exit 0; }

if ! have ast-grep; then
  if [ "$MODE" = "strict" ]; then
    echo "intent-trace FAIL (strict) — $COUNT AC(s) declare an ast_proof but ast-grep is not installed." >&2
    exit 2
  fi
  echo "intent-trace SKIP — ast-grep absent but $COUNT AC(s) pin a construct (recorded, not silent-green; set WALTEUR_INTENT_TRACE=strict to fail-closed)." >&2
  exit 0
fi

# run each proof; build intent_vs_impl[] entries
RESULTS='[]'
FAILS=0
for i in $(seq 0 $((COUNT-1))); do
  story="$(jq -r ".[$i].story"     "$PROOFS")"
  ac="$(jq -r ".[$i].ac"           "$PROOFS")"
  construct="$(jq -r ".[$i].construct" "$PROOFS")"
  intent="$(jq -r ".[$i].text"      "$PROOFS")"
  lang="$(jq -r ".[$i].lang"        "$PROOFS")"
  pattern="$(jq -r ".[$i].pattern // empty" "$PROOFS")"
  rule="$(jq -r ".[$i].rule // empty"       "$PROOFS")"
  glob="$(jq -r ".[$i].glob // empty"       "$PROOFS")"
  minm="$(jq -r ".[$i].min_matches // 1"    "$PROOFS")"

  # VERIFIED flags: run -p/-l/--globs/--json=compact ; scan -r/--json=compact.
  # NB: ast-grep searches the CWD by default, so we cd into $ROOT (the project under audit) first —
  # otherwise the proof would scan whatever dir the hook was invoked from (a real bug if omitted).
  if [ -n "$rule" ]; then
    OUT="$(cd "$ROOT" && ast-grep scan -r "$ROOT/$rule" --json=compact 2>/dev/null || echo '[]')"
    probe="rule:$rule"
  else
    if [ -n "$glob" ]; then
      OUT="$(cd "$ROOT" && ast-grep run -p "$pattern" -l "$lang" --globs "$glob" --json=compact 2>/dev/null || echo '[]')"
    else
      OUT="$(cd "$ROOT" && ast-grep run -p "$pattern" -l "$lang" --json=compact 2>/dev/null || echo '[]')"
    fi
    probe="pattern:$pattern"
  fi

  # JSON fields are VERIFIED: .[0].file, .[0].range.start.line (0-based -> +1 for grep-parity 1-based).
  mc="$(printf '%s' "$OUT" | jq 'length' 2>/dev/null || echo 0)"
  if [ "${mc:-0}" -ge "$minm" ]; then
    file="$(printf '%s' "$OUT" | jq -r '.[0].file')"
    line="$(printf '%s' "$OUT" | jq -r '.[0].range.start.line + 1')"
    matched=true
  else
    file=""; line=0; matched=false; FAILS=$((FAILS+1))
    echo "  FAIL intent-trace — $story/$ac construct '$construct' NOT-FOUND ($probe). Intent unproven in code." >&2
  fi

  ENTRY="$(jq -n \
    --arg story "$story" --arg ac "$ac" --arg construct "$construct" --arg intent "$intent" \
    --arg lang "$lang" --arg pat "$pattern" --arg rule "$rule" \
    --arg file "$file" --argjson line "$line" --argjson matched "$matched" --argjson mc "${mc:-0}" \
    '{story:$story, ac:$ac, construct:$construct, intent:$intent,
      ast_proof:{ (if $rule=="" then "pattern" else "rule" end): (if $rule=="" then $pat else $rule end),
                  lang:$lang, file:$file, line:$line, matched:$matched, match_count:$mc,
                  tool:"ast-grep", proves:"existence",
                  not_proven:"semantic correctness / live-path enforcement (PROTOCOL: §5.4 Logic-Correctness + policy-shadow)" } }')"
  RESULTS="$(printf '%s' "$RESULTS" | jq --argjson e "$ENTRY" '. + [$e]')"
done

# merge into audit.json (create if absent) under .intent_vs_impl, preserving any LLM-authored entries.
if [ -f "$AUDIT" ]; then BASE="$(cat "$AUDIT")"; else BASE='{}'; fi
printf '%s' "$BASE" | jq --argjson r "$RESULTS" --arg ts "$TS" \
  '.intent_vs_impl = ((.intent_vs_impl // []) + $r) | .intent_trace_ts = $ts' > "$AUDIT.tmp" && mv "$AUDIT.tmp" "$AUDIT"

if [ "$FAILS" -gt 0 ]; then
  echo "intent-trace verdict: FAIL — $FAILS pinned construct(s) NOT-FOUND in code (existence-arm). -> $AUDIT" >&2
  exit 2
fi
echo "intent-trace verdict: PASS — $COUNT pinned construct(s) proven to EXIST (existence only; correctness=PROTOCOL). -> $AUDIT" >&2
exit 0
