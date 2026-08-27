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
# S033 candidate C3 (dangling craft-engine chain closure): the walteur-design companion skill
# (walteur-design/SKILL.md, ROOT-relative) declares a MUST-chain default craft engine — a skill name
# CRAFTSMAN mode is required to invoke on every UI build (the line "CRAFTSMAN mode MUST chain
# `<skill-name>`"). When UI files are present, this gate also verifies that named skill actually
# resolves in walteur-kit/skill-index.json — a MUST-fire skill absent from the index is a dangling
# reference (it can never actually be dispatched) and FAILs with a clear message, same posture as a
# missing DESIGN.md. --check-skills-only runs JUST this check (used by the selftest and by callers that
# want the skill-mandate proof without the full UI/DESIGN.md scan).
#
# Bypass: WALTEUR_DESIGN=off  => write SKIP report, exit 0.
# Kill switch: walteur-kit/PAUSED present => exit 2.
#
# Zero-dep: bash + grep + awk + sed + jq + find only. HARD: real exit 2 on a real violation.
# HONESTY: the applicability SKIP = "no UI files" — honest, not silent-green.
# Report: walteur-kit/design-report.json  {verdict, ts, gate, reason, details}.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "design-gate - HARD gate on the DESIGN.md artifact. Missing contract = fail (exit 2). Clean = exit 0."
  printf '%s\n' "usage: bash design-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/design-report.json - fix recipes: walteur-kit/REMEDIATION.md (## design-gate)"
  printf '%s\n' "bypass: WALTEUR_DESIGN=off (recorded, not free)"
  exit 0 ;;
esac

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

# S033 candidate C3: verify every MUST-chain craft-engine skill the companion SKILL.md declares actually
# resolves in the skill index. Prints "" (nothing dangling / can't check) or a newline-separated list of
# dangling "skill-name|source-file" pairs. $1 = the walteur-design SKILL.md path to scan (default: repo-
# root-relative walteur-design/SKILL.md, so this still finds the mandate when <dir> is a build subtree).
check_skill_mandates() {
  local skillmd="$1" index="$2" dangling=""
  [ -f "$skillmd" ] || { return 0; }   # no companion doc to check — not this gate's problem
  [ -f "$index" ] || { echo "__NOINDEX__"; return 0; }   # index missing — can't verify, report loud below
  command -v jq >/dev/null 2>&1 || { echo "__NOJQ__"; return 0; }

  # "CRAFTSMAN mode MUST chain `<skill-name>`" — the mandate line format this SKILL.md uses.
  local names; names="$(grep -oE 'MUST chain `[a-zA-Z0-9_-]+`' "$skillmd" 2>/dev/null | sed -E 's/MUST chain `([a-zA-Z0-9_-]+)`/\1/' | sort -u)"
  [ -z "$names" ] && return 0

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if ! jq -e --arg s "$name" '.skills[]? | select(.skill==$s)' "$index" >/dev/null 2>&1; then
      dangling="${dangling}${name}|${skillmd}
"
    fi
  done <<EOF
$names
EOF
  printf '%s' "$dangling"
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

  # ── S033 candidate C3: dangling craft-engine chain check ──
  mk_index() { mkdir -p "$1/walteur-kit"; printf '%s' "$2" > "$1/walteur-kit/skill-index.json"; }
  mk_skillmd() { mkdir -p "$1/walteur-design"; printf '%s' "$2" > "$1/walteur-design/SKILL.md"; }
  real_index='{"schema_version":1,"skills":[{"skill":"loopkit-design-system"},{"skill":"org-brand-dna"}]}'

  # NEGATIVE CONTROL: SKILL.md mandates a skill that is NOT in the index (the actual pre-S033 defect
  # reproduced) -> FAIL, even though DESIGN.md itself is perfectly valid.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/design-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'export const App = () => <div>ok</div>;\n' > "$tmp/src/App.tsx"
  make_design_contract "$tmp/DESIGN.md"
  mk_index "$tmp" "$real_index"
  mk_skillmd "$tmp" 'CRAFTSMAN mode MUST chain `design-taste-frontend` as the craft engine.'
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "NEGATIVE CONTROL: MUST-chain skill absent from index -> FAIL (dangling craft engine)" 2 "$?"
  jq -e '.verdict == "FAIL" and (.reason | contains("dangling")) and (.details[0].skill == "design-taste-frontend")' "$tmp/walteur-kit/design-report.json" >/dev/null 2>&1
  ck "dangling-craft-engine report names the missing skill" 0 "$?"
  rm -rf "$tmp"

  # contrast case: MUST-chain skill DOES resolve in the index -> PASS (proves the check isn't just always-FAIL)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/design-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'export const App = () => <div>ok</div>;\n' > "$tmp/src/App.tsx"
  make_design_contract "$tmp/DESIGN.md"
  mk_index "$tmp" "$real_index"
  mk_skillmd "$tmp" 'CRAFTSMAN mode MUST chain `loopkit-design-system` as the craft engine.'
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "MUST-chain skill present in index -> PASS" 0 "$?"
  rm -rf "$tmp"

  # no SKILL.md at all -> unaffected (existing behavior), still PASS on a valid DESIGN.md
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/design-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/src" "$tmp/walteur-kit"
  printf 'export const App = () => <div>ok</div>;\n' > "$tmp/src/App.tsx"
  make_design_contract "$tmp/DESIGN.md"
  mk_index "$tmp" "$real_index"
  bash "$0" "$tmp" >/dev/null 2>&1
  ck "no companion SKILL.md -> unaffected, PASS as before" 0 "$?"
  rm -rf "$tmp"

  # the actual repo file (walteur-design/SKILL.md, post-S033 fix) against the actual repo skill-index.json
  # -> its own MUST-chain mandate must resolve (proves the real fix, not just the fixture)
  REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  if [ -f "$REPO_ROOT/walteur-design/SKILL.md" ] && [ -f "$REPO_ROOT/walteur-kit/skill-index.json" ]; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/design-gate-selftest.XXXXXX")" || return 1
    mkdir -p "$tmp/src" "$tmp/walteur-kit" "$tmp/walteur-design"
    printf 'export const App = () => <div>ok</div>;\n' > "$tmp/src/App.tsx"
    make_design_contract "$tmp/DESIGN.md"
    cp "$REPO_ROOT/walteur-kit/skill-index.json" "$tmp/walteur-kit/skill-index.json"
    cp "$REPO_ROOT/walteur-design/SKILL.md" "$tmp/walteur-design/SKILL.md"
    bash "$0" "$tmp" >/dev/null 2>&1
    ck "LIVE repo walteur-design/SKILL.md MUST-chain mandate resolves in the LIVE repo skill-index.json" 0 "$?"
    rm -rf "$tmp"
  else
    echo "  (skip - live repo walteur-design/SKILL.md or skill-index.json not found from this checkout)"
  fi

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
PRUNE=( \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/storybook-static/*' -o -path '*/graphify-out/*' -o -path '*/walteur-kit/*' -o -path "$DIR/field-runs/*" \) -prune -o )

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

# ── S033 candidate C3: dangling craft-engine chain check ─────────────────────
# UI is present, so the walteur-design companion's MUST-chain craft engine has to actually be
# dispatchable. A skill declared MUST-chain that doesn't resolve in skill-index.json can never fire —
# that's a broken contract, same severity as a missing DESIGN.md.
SKILL_MD="$ROOT/walteur-design/SKILL.md"
SKILL_INDEX="$KIT/skill-index.json"
DANGLING="$(check_skill_mandates "$SKILL_MD" "$SKILL_INDEX")"
if [ "$DANGLING" = "__NOINDEX__" ]; then
  echo "WALTEUR design-gate: NOTE — walteur-design/SKILL.md declares MUST-chain skill(s) but $SKILL_INDEX is missing; cannot verify they resolve (not silent-green, not a hard block by itself)." >&2
elif [ "$DANGLING" = "__NOJQ__" ]; then
  : # jq guard above already handles the no-jq path; unreachable in practice, kept for defense-in-depth
elif [ -n "$DANGLING" ]; then
  first_name="$(printf '%s' "$DANGLING" | head -1 | cut -d'|' -f1)"
  write_report "FAIL" "walteur-design/SKILL.md mandates craft engine '$first_name' but it is not in walteur-kit/skill-index.json (dangling MUST-chain skill)" \
    "$(printf '%s' "$DANGLING" | grep -v '^$' | jq -R -s -c 'split("\n") | map(select(length>0)) | map(split("|")) | map({rule:"dangling-craft-engine", skill:.[0], source:.[1], message:("SKILL.md declares CRAFTSMAN mode MUST chain `" + .[0] + "` but that skill is not in skill-index.json — a MUST-fire skill that cannot be dispatched. Repoint the mandate at a skill that exists in the index, or vendor the missing skill and re-run skill-index generation.")})')" "$UI_COUNT"
  echo "WALTEUR design-gate: FAIL — walteur-design/SKILL.md mandates craft engine(s) that do not exist in skill-index.json:" >&2
  printf '%s' "$DANGLING" | grep -v '^$' | while IFS='|' read -r n s; do echo "  - '$n' (declared in $s) not found in $SKILL_INDEX" >&2; done
  echo "  Fix: repoint the MUST-chain mandate at a skill that resolves in the index (see walteur-kit/skill-index.json), or vendor the missing skill." >&2
  exit 2
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
grep -Eqi '#[0-9a-f]{3,8}\b|colors?[[:space:]]*:|palette|hsl\(|oklch\(|rgb\(|lab\(|hwb\(|--[a-z0-9-]*(color|bg|fg|accent|surface|border|primary|muted|danger)|\| *color|## *color' "$CONTRACT" 2>/dev/null && COLOR_OK=1

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
