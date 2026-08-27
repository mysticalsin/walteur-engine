#!/usr/bin/env bash
# WALTEUR design-gate — HARD gate on the DESIGN.md artifact. Missing contract = fail (exit 2). Clean = exit 0.
# Usage: bash walteur-kit/hooks/design-gate.sh <dir>
#
# Intent: UI code without a written design contract is how AI-slop ships — every screen re-invents the
# palette, the type scale drifts, and the result is generic. The design-side counterpart of the
# plan-before-build law: NO UI CODE WITHOUT A WRITTEN DESIGN SYSTEM. The contract is satisfied by EITHER:
#   - DESIGN.md at the repo root (the Google-Stitch / awesome-design-md standard: token frontmatter +
#     colors/typography/components/layout/elevation/do-don'ts sections), OR
#   - design-system/MASTER.md (the ui-ux-pro-max "Master + page overrides" persistence pattern).
#
# Scope (applicability — when does this gate demand the contract?):
#   - UI source files exist under <dir>: *.tsx / *.jsx / *.vue / *.svelte (anywhere except vendor/build
#     dirs) or *.html outside vendor/build — excluding *.test.* / *.spec.* / *.stories.* files.
#   - ZERO UI files => SKIP (project has no UI; recorded, never silent-green).
#
# Quality floor (anti-stub): the found contract file must be non-trivial — >= 10 non-empty lines AND
# mention at least one color (hex value or `colors`/`palette` token) — a `touch DESIGN.md` stub does
# not satisfy the law.
#
# Bypass: WALTEUR_DESIGN=off  => write SKIP report, exit 0.
# Kill switch: walteur-kit/PAUSED present => exit 2.
#
# Zero-dep: bash + grep + awk + sed + jq + find only. HARD: real exit 2 on a real violation.
# HONESTY: the applicability SKIP = "no UI files" — honest, not silent-green.
# Report: walteur-kit/design-report.json  {verdict, ts, gate, reason, details}.
set -uo pipefail

_arg="${1:-}"
if [ -n "$_arg" ] && [ -d "$_arg" ]; then
  ROOT="$(cd "$_arg" && pwd)"
else
  ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
fi
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/design-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_report() { # $1=verdict  $2=reason  $3=details-json  $4=ui-file-count
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg v "$1" --arg ts "$TS" --arg reason "$2" --arg dir "${DIR:-}" \
      --argjson details "${3:-[]}" --argjson ui "${4:-0}" \
      '{verdict:$v, ts:$ts, gate:"design-gate", dir:$dir, reason:$reason,
        ui_files:$ui, details:$details}' > "$REPORT"
  else
    printf '{"verdict":"%s","ts":"%s","gate":"design-gate","reason":"%s","ui_files":%s,"details":[]}\n' \
      "$1" "$TS" "$2" "${4:-0}" > "$REPORT"
  fi
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

  for t in grep awk sed jq find; do
    if ! command -v "$t" >/dev/null 2>&1; then
      echo "design-gate selftest SKIP - required tool '$t' not installed."
      return 0
    fi
  done

  make_design_contract() {
    dst="$1"
    cat > "$dst" <<'DESIGN'
# Design contract
colors:
  primary: "#2563eb"
  canvas: "#ffffff"
typography:
  body: Inter 16/24
components:
  button: primary token
layout:
  spacing: 4px scale
elevation:
  surface: flat
donts:
  no generic gradient blobs
DESIGN
  }

  echo "design-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/design-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'print("hello")\n' > "$tmp/tool.py"
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "non-UI dir -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP" and .reason == "no UI source files found"' "$tmp/walteur-kit/design-report.json" >/dev/null 2>&1
  ck "non-UI report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/design-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'export const App = () => <div>ok</div>;\n' > "$tmp/src/App.tsx"
  make_design_contract "$tmp/DESIGN.md"
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "UI with valid design contract -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .ui_files == 1' "$tmp/walteur-kit/design-report.json" >/dev/null 2>&1
  ck "valid design report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/design-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'export const App = () => <div>ok</div>;\n' > "$tmp/src/App.tsx"
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "UI without design contract -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.reason | contains("no design contract"))' "$tmp/walteur-kit/design-report.json" >/dev/null 2>&1
  ck "missing design report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/design-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'export const App = () => <div>ok</div>;\n' > "$tmp/src/App.tsx"
  printf '# D\ncolors: x\n' > "$tmp/DESIGN.md"
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "UI with stub design contract -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.reason | contains("stub"))' "$tmp/walteur-kit/design-report.json" >/dev/null 2>&1
  ck "stub design report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/design-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'export const App = () => <div>ok</div>;\n' > "$tmp/src/App.tsx"
  WALTEUR_DESIGN=off bash "$0" "$tmp" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/design-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/design-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "design-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

# ── kill switch ──────────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }

# ── tool guard ───────────────────────────────────────────────────────────────
for t in grep awk sed jq find; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR design-gate SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
    write_report "SKIP" "$t not installed" '[]' 0
    exit 0
  fi
done

# ── bypass ───────────────────────────────────────────────────────────────────
if [ "${WALTEUR_DESIGN:-on}" = "off" ]; then
  echo "WALTEUR design-gate SKIP — bypass WALTEUR_DESIGN=off (recorded, not silent-green)." >&2
  write_report "SKIP" "bypass WALTEUR_DESIGN=off" '[]' 0
  exit 0
fi

DIR="${1:-}"
if [ -z "$DIR" ]; then
  echo "WALTEUR design-gate SKIP — no directory argument. Usage: design-gate.sh <dir>" >&2
  write_report "SKIP" "no directory argument" '[]' 0
  exit 0
fi
if [ ! -d "$DIR" ]; then
  echo "WALTEUR design-gate SKIP — '$DIR' is not a directory (nothing to scan)." >&2
  write_report "SKIP" "not a directory: $DIR" '[]' 0
  exit 0
fi

# ── applicability: any UI source files? (prune vendor/build dirs) ────────────
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

if [ "$UI_COUNT" -eq 0 ]; then
  echo "WALTEUR design-gate SKIP — no UI source files under '$DIR' (no frontend to govern)." >&2
  write_report "SKIP" "no UI source files found" '[]' 0
  exit 0
fi

# ── locate the design contract ───────────────────────────────────────────────
CONTRACT=""
for cand in "$ROOT/DESIGN.md" "$ROOT/design-system/MASTER.md" "$DIR/DESIGN.md" "$DIR/design-system/MASTER.md"; do
  if [ -f "$cand" ]; then CONTRACT="$cand"; break; fi
done

if [ -z "$CONTRACT" ]; then
  write_report "FAIL" "UI files present but no design contract (DESIGN.md or design-system/MASTER.md)" \
    '[{"rule":"missing-design-contract","message":"UI source exists but neither DESIGN.md nor design-system/MASTER.md found — no UI code without a written design system (WALTEUR §6.2 / walteur-design skill)"}]' "$UI_COUNT"
  echo "WALTEUR design-gate: FAIL — $UI_COUNT UI file(s) but NO design contract." >&2
  echo "  Fix: write DESIGN.md at the repo root (token frontmatter + colors/typography/components/layout" >&2
  echo "  /elevation/do-don'ts) or design-system/MASTER.md. See the walteur-design companion skill." >&2
  exit 2
fi

# ── anti-stub quality floor: >=10 non-empty lines AND at least one color signal ──
NONEMPTY="$(grep -c -v '^[[:space:]]*$' "$CONTRACT" 2>/dev/null || echo 0)"
COLOR_OK=0
grep -Eqi '#[0-9a-f]{3,8}\b|colors[[:space:]]*:|palette' "$CONTRACT" 2>/dev/null && COLOR_OK=1

if [ "$NONEMPTY" -lt 10 ] || [ "$COLOR_OK" -ne 1 ]; then
  rel="${CONTRACT#"$ROOT"/}"
  write_report "FAIL" "design contract '$rel' is a stub (lines=$NONEMPTY, color-tokens=$COLOR_OK)" \
    "$(jq -n --arg f "$rel" --argjson n "$NONEMPTY" \
      '[{"rule":"stub-design-contract","file":$f,"message":("contract has only " + ($n|tostring) + " non-empty line(s) or no color tokens — a touch-stub does not satisfy the design law; write real tokens (colors/typography/components)")}]')" "$UI_COUNT"
  echo "WALTEUR design-gate: FAIL — design contract '$rel' is a stub ($NONEMPTY non-empty lines, color-tokens=$COLOR_OK)." >&2
  exit 2
fi

rel="${CONTRACT#"$ROOT"/}"
write_report "PASS" "design contract present + non-trivial: $rel ($NONEMPTY non-empty lines)" '[]' "$UI_COUNT"
echo "WALTEUR design-gate: PASS — $UI_COUNT UI file(s) governed by '$rel'." >&2
exit 0
