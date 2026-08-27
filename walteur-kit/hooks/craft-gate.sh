#!/usr/bin/env bash
# WALTEUR craft-gate — honest detect-or-loud-SKIP formatter + linter + type-check gate.
# Detects the stack from manifest files and, for each stack present, runs the matching trio
# IF the tool exists. Missing tool => SKIP that sub-check (loud, recorded) — never silent-green.
#   python  (pyproject.toml): ruff format --check · ruff check · mypy --strict
#   ts/js   (package.json)  : prettier --check . · eslint . --max-warnings 0 · tsc --noEmit
#   go      (go.mod)        : gofmt -l . · go vet ./...
#   rust    (Cargo.toml)    : cargo fmt --check · cargo clippy -D warnings
# A present tool whose check FAILS is a real violation => exit 2.
# Report: walteur-kit/craft-report.json with per-check {verdict|SKIP}.
# Bypass: WALTEUR_CRAFT=off.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "craft-gate - honest detect-or-loud-SKIP formatter + linter + type-check gate."
  printf '%s\n' "usage: bash craft-gate.sh [--help|<default run>]   (no --selftest: this gate has none)"
  printf '%s\n' "report: walteur-kit/craft-report.json - fix recipes: walteur-kit/REMEDIATION.md (## craft-gate)"
  printf '%s\n' "bypass: WALTEUR_CRAFT=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# Argument guard. --help above advertised a --selftest this hook does not implement, and no case
# arm handled it — so `craft-gate.sh --selftest` fell through and performed a FULL GATE RUN,
# overwriting walteur-kit/craft-report.json and exiting 0. An operator (or gate-suite) asking for
# a selftest got a green that proved nothing plus a clobbered report. Unsupported flags now fail
# loudly. Wording avoids "not installed"/"selftest SKIP" so gate-suite's run_one classification
# (which keys off the output line, not the exit code) is unchanged: still no-selftest, not broken.
case "${1:-}" in
  -*) printf '%s\n' "craft-gate: unrecognized option '$1' — this hook implements --help only and has no selftest." >&2
      printf '%s\n' "usage: bash craft-gate.sh [--help|<default run>]" >&2
      exit 2 ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/craft-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_CRAFT:-on}" = "off" ] && { echo "craft-gate: bypassed (WALTEUR_CRAFT=off)." >&2; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }
TMP="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"; trap 'rm -f "$TMP"' EXIT

violations=0; ran=0
J='{}'
add() { J="$(printf '%s' "$J" | jq --argjson v "$2" --arg k "$1" '.[$k]=$v' 2>/dev/null || printf '%s' "$J")"; }

# run_check <report-key> <human-label> <tool-binary> <command...>
# - tool absent => loud SKIP + verdict SKIP
# - tool present + command exit 0 => PASS
# - tool present + command exit !=0 => FAIL (real violation)
run_check() {
  key="$1"; label="$2"; bin="$3"; shift 3
  if ! have "$bin"; then
    echo "  SKIP — $label ($bin not installed). Recorded; NOT counted green." >&2
    add "$key" "$(jq -n --arg t "$bin" --arg l "$label" '{verdict:"SKIP",check:$l,tool:$t,reason:($t+" not installed")}')"
    return 0
  fi
  ran=$((ran+1))
  if ( cd "$ROOT" && "$@" ) >"$TMP" 2>&1; then
    echo "  ok   — $label" >&2
    add "$key" "$(jq -n --arg t "$bin" --arg l "$label" '{verdict:"PASS",check:$l,tool:$t}')"
  else
    echo "  FAIL — $label" >&2
    violations=$((violations+1))
    add "$key" "$(jq -n --arg t "$bin" --arg l "$label" '{verdict:"FAIL",check:$l,tool:$t}')"
  fi
}

echo "WALTEUR craft-gate @ $ROOT" >&2
stacks=""

# gofmt prints offending files to STDOUT and exits 0 even when files are unformatted,
# so it needs a wrapper that fails when the output is non-empty.
gofmt_check() { out="$(gofmt -l "$ROOT")"; [ -z "$out" ] || { printf '%s\n' "$out"; return 1; }; }

# ── Python ────────────────────────────────────────────────────────────────────
if [ -f "$ROOT/pyproject.toml" ] || ls "$ROOT"/*.py >/dev/null 2>&1; then
  stacks="$stacks python"
  run_check py_format "python: ruff format --check"   ruff  ruff format --check .
  run_check py_lint   "python: ruff check"            ruff  ruff check .
  run_check py_types  "python: mypy --strict"         mypy  mypy --strict .
fi

# ── TypeScript / JavaScript ──────────────────────────────────────────────────
if [ -f "$ROOT/package.json" ]; then
  stacks="$stacks ts"
  run_check ts_format "ts: prettier --check"          prettier prettier --check .
  run_check ts_lint   "ts: eslint --max-warnings 0"   eslint   eslint . --max-warnings 0
  run_check ts_types  "ts: tsc --noEmit"              tsc      tsc --noEmit
fi

# ── Go ───────────────────────────────────────────────────────────────────────
if [ -f "$ROOT/go.mod" ]; then
  stacks="$stacks go"
  run_check go_format "go: gofmt -l (must be empty)"  gofmt gofmt_check
  run_check go_vet    "go: go vet ./..."              go    go vet ./...
fi

# ── Rust ─────────────────────────────────────────────────────────────────────
if [ -f "$ROOT/Cargo.toml" ]; then
  stacks="$stacks rust"
  run_check rust_format "rust: cargo fmt --check"           cargo cargo fmt --check
  run_check rust_lint   "rust: cargo clippy -D warnings"    cargo cargo clippy -- -D warnings
fi

stacks="$(echo "$stacks" | sed 's/^ //')"
if [ -z "$stacks" ]; then
  echo "  SKIP — no recognised stack (package.json/pyproject.toml/go.mod/Cargo.toml). Nothing to check." >&2
fi

if [ "$violations" -gt 0 ]; then
  OVERALL=FAIL
elif [ "$ran" -gt 0 ]; then
  OVERALL=PASS
else
  OVERALL=SKIP
fi

jq -n --arg v "$OVERALL" --arg ts "$TS" --arg stacks "$stacks" \
      --argjson ran "$ran" --argjson viol "$violations" --argjson tools "$J" \
  '{verdict:$v, ts:$ts, gate:"craft", stacks:($stacks|select(length>0)|split(" ")), checks_ran:$ran, violations:$viol, details:$tools}' \
  > "$REPORT" 2>/dev/null || printf '{"verdict":"%s","ts":"%s","gate":"craft","checks_ran":%s,"violations":%s}\n' "$OVERALL" "$TS" "$ran" "$violations" > "$REPORT"

echo "craft-gate verdict: $OVERALL (stacks='${stacks:-none}', ran=$ran, violations=$violations) -> $REPORT" >&2
[ "$OVERALL" = "FAIL" ] && exit 2
exit 0
