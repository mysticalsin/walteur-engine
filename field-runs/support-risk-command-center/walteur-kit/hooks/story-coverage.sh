#!/usr/bin/env bash
# WALTEUR story-coverage — HARD gate on Storybook story completeness. One finding = fail (exit 2). Clean = exit 0.
# Usage: bash walteur-kit/hooks/story-coverage.sh <dir>
#
# Intent: a component that ships WITH a Storybook stories file must document the three states that
# every interactive component has — the happy path, the in-flight path, and the failure path. The
# minimal contract: each sibling *.stories.* must expose named story exports for Default AND Loading
# AND Error (CSF named export `export const Default` OR a Component Story Format key `Default:`).
#
# Scope:
#   - component files: *.tsx / *.jsx under src/ components/ app/
#       excluding *.stories.* / *.test.* / *.spec.* and index files (index.tsx / index.jsx)
#   - for each component that HAS a sibling *.stories.* file (same dir, same basename), require that
#     stories file to contain Default AND Loading AND Error. Missing any => finding => exit 2.
#   - components WITHOUT a sibling stories file are not flagged here (that is opt-in Storybook usage;
#     this gate strengthens the stories that exist, it does not mandate that every component have one).
#
# Applicability SKIP (exit 0, recorded — NEVER silent-green):
#   - ZERO *.stories.* files anywhere in the repo  => project isn't using Storybook.
#   - ZERO component files                          => nothing to cover.
# Bypass: WALTEUR_STORY=off  => write SKIP report, exit 0.
# Kill switch: walteur-kit/PAUSED present => exit 2.
#
# Zero-dep: bash + grep + awk + sed + jq + find only. HARD: real exit 2 on any hit.
# HONESTY: the tools used are always present; a missing-tool SKIP only triggers if one is genuinely
#          absent. The applicability SKIP = "no stories / no components" — honest, not silent-green.
# Report: walteur-kit/story-report.json  {verdict, ts, gate, reason, details}.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/story-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_report() { # $1=verdict  $2=reason  $3=findings-json-array  $4=scanned-count
  jq -n \
    --arg v "$1" --arg ts "$TS" --arg reason "$2" --arg dir "${DIR:-}" \
    --argjson findings "${3:-[]}" --argjson scanned "${4:-0}" \
    '{verdict:$v, ts:$ts, gate:"story-coverage", dir:$dir, reason:$reason,
      files_scanned:$scanned, details:$findings}' > "$REPORT"
}

# ── kill switch ──────────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }

# ── tool guard ───────────────────────────────────────────────────────────────
for t in grep awk sed jq find; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR story-coverage SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
    write_report "SKIP" "$t not installed" '[]' 0
    exit 0
  fi
done

# ── bypass ───────────────────────────────────────────────────────────────────
if [ "${WALTEUR_STORY:-on}" = "off" ]; then
  echo "WALTEUR story-coverage SKIP — bypass WALTEUR_STORY=off (recorded, not silent-green)." >&2
  write_report "SKIP" "bypass WALTEUR_STORY=off" '[]' 0
  exit 0
fi

DIR="${1:-}"
if [ -z "$DIR" ]; then
  echo "WALTEUR story-coverage SKIP — no directory argument. Usage: story-coverage.sh <dir>" >&2
  write_report "SKIP" "no directory argument" '[]' 0
  exit 0
fi
if [ ! -d "$DIR" ]; then
  echo "WALTEUR story-coverage SKIP — '$DIR' is not a directory (nothing to scan)." >&2
  write_report "SKIP" "not a directory: $DIR" '[]' 0
  exit 0
fi

# ── applicability: any *.stories.* in the repo? (prune vendor/build dirs) ─────
PRUNE=( \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/storybook-static/*' \) -prune -o )

STORY_COUNT=0
while IFS= read -r f; do
  [ -n "$f" ] && STORY_COUNT=$((STORY_COUNT+1))
done < <(find "$DIR" "${PRUNE[@]}" \
  -type f \( -name '*.stories.tsx' -o -name '*.stories.jsx' -o -name '*.stories.ts' -o -name '*.stories.js' -o -name '*.stories.mdx' \) -print 2>/dev/null)

if [ "$STORY_COUNT" -eq 0 ]; then
  echo "WALTEUR story-coverage SKIP — no *.stories.* files under '$DIR' (project isn't using Storybook)." >&2
  write_report "SKIP" "no stories files found (not using Storybook)" '[]' 0
  exit 0
fi

# ── collect component files (*.tsx/*.jsx under src/ components/ app/; exclude stories/test/spec/index) ─
COMPONENTS=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  base="$(basename "$f")"
  case "$base" in
    *.stories.*|*.test.*|*.spec.*|index.tsx|index.jsx) continue ;;
  esac
  # only under src/ components/ app/
  case "$f" in
    */src/*|*/components/*|*/app/*) COMPONENTS+=("$f") ;;
  esac
done < <(find "$DIR" "${PRUNE[@]}" \
  -type f \( -name '*.tsx' -o -name '*.jsx' \) -print 2>/dev/null)

if [ "${#COMPONENTS[@]}" -eq 0 ]; then
  echo "WALTEUR story-coverage SKIP — no component files (*.tsx/*.jsx under src/|components/|app/) under '$DIR'." >&2
  write_report "SKIP" "no component files found" '[]' 0
  exit 0
fi

declare -a FINDINGS_JSON=()
add() { # $1=file  $2=stories-file  $3=rule  $4=message
  FINDINGS_JSON+=("$(jq -n --arg f "$1" --arg s "$2" --arg r "$3" --arg m "$4" \
    '{file:$f, stories:$s, rule:$r, message:$m}')")
}

# A story export exists if EITHER a CSF named export (`export const Default`) OR a CSF-key form
# (`Default:`) appears for that state name. Case-sensitive on the canonical names.
has_story() { # $1=stories-file  $2=StateName
  grep -Eq "(^|[^a-zA-Z0-9_])export[[:space:]]+const[[:space:]]+$2([^a-zA-Z0-9_]|$)" "$1" 2>/dev/null && return 0
  grep -Eq "(^|[[:space:]])$2[[:space:]]*:" "$1" 2>/dev/null && return 0
  return 1
}

SCANNED=0
for comp in "${COMPONENTS[@]}"; do
  dir="$(dirname "$comp")"
  base="$(basename "$comp")"
  stem="${base%.*}"   # strip .tsx/.jsx

  # find a sibling stories file: same dir, same stem, *.stories.*
  stories=""
  for ext in tsx jsx ts js mdx; do
    cand="$dir/$stem.stories.$ext"
    if [ -f "$cand" ]; then stories="$cand"; break; fi
  done
  [ -z "$stories" ] && continue   # no sibling stories file => not in scope for this gate

  SCANNED=$((SCANNED+1))
  rel="${comp#"$ROOT"/}"
  srel="${stories#"$ROOT"/}"

  missing=()
  for state in Default Loading Error; do
    has_story "$stories" "$state" || missing+=("$state")
  done

  if [ "${#missing[@]}" -ne 0 ]; then
    miss="$(IFS=', '; echo "${missing[*]}")"
    add "$rel" "$srel" "missing-story-state" "stories file is missing required story state(s): $miss (need Default + Loading + Error)"
  fi
done

# No component had a sibling stories file => applicability SKIP (stories exist elsewhere but none paired).
if [ "$SCANNED" -eq 0 ]; then
  echo "WALTEUR story-coverage SKIP — no component has a sibling *.stories.* file (nothing to enforce)." >&2
  write_report "SKIP" "no component/stories pairs found" '[]' 0
  exit 0
fi

if [ "${#FINDINGS_JSON[@]}" -eq 0 ]; then
  write_report "PASS" "all $SCANNED component/stories pair(s) cover Default + Loading + Error" '[]' "$SCANNED"
  echo "WALTEUR story-coverage: PASS — $SCANNED component/stories pair(s) checked, all cover Default+Loading+Error." >&2
  exit 0
fi

FIND_JSON="$(printf '%s\n' "${FINDINGS_JSON[@]}" | jq -s '.')"
write_report "FAIL" "${#FINDINGS_JSON[@]} story-coverage finding(s)" "$FIND_JSON" "$SCANNED"
echo "WALTEUR story-coverage: FAIL — ${#FINDINGS_JSON[@]} finding(s) across $SCANNED pair(s):" >&2
for f in "${FINDINGS_JSON[@]}"; do
  file="$(printf '%s' "$f" | jq -r '.file')"
  st="$(printf '%s' "$f" | jq -r '.stories')"
  rule="$(printf '%s' "$f" | jq -r '.rule')"
  msg="$(printf '%s' "$f" | jq -r '.message')"
  echo "  [$rule] $file (stories: $st)  $msg" >&2
done
exit 2
