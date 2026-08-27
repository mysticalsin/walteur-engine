#!/usr/bin/env bash
# WALTEUR anti-slop-ui — HARD gate on frontend source. One finding = fail (exit 2). Clean = exit 0.
# Usage: bash walteur-kit/hooks/anti-slop-ui.sh <dir>
#
# Scans .jsx .tsx .vue .svelte .html .css for AI-slop signatures:
#   1  purple/indigo gradient pairs:  (from-purple|to-indigo|from-violet) co-located with "gradient"
#   2  "lorem ipsum"
#   3  fake names/data:  Acme | John Doe | jane@example | pravatar | placeholder.com | $XX | $1,234
#   4  emoji inside a <button>...</button>
#   5  arbitrary-tailwind pixel sizing:  w-[NNNpx]
#   6  outline:none / outline: none  WITHOUT an accompanying focus-visible (in the same file)
#   7  alert(
#   8  "Something went wrong"
#   9  hand-rolled primitive (raw <button>/<input>/<select>/<dialog> with heavy inline styling, OR a
#      custom Button/Input/Dialog component definition) in a .tsx/.jsx file that does NOT import from
#      '@/components/ui/...' — ONLY when a shadcn/ui setup is present (components.json OR
#      @/components/ui/ dir under <dir>). Heuristic, low-false-positive, additive.
#  10  inline style={{...}} used for LAYOUT (width/height/color/padding) in .tsx/.jsx — prefer Tailwind
#      utility classes.
#
# No-op (exit 0, verdict SKIP) when no frontend files exist.
# Zero-dep: bash + grep + awk + sed + jq only. HARD: real exit 2 on any hit.
# HONESTY: the tools used (grep/awk) are always present, so a missing-tool SKIP only triggers if one
#          is genuinely absent. The applicability SKIP = "no frontend files" — honest, not silent-green.
# Report: walteur-kit/anti-slop-ui-report.json  {verdict, ts, details}.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "anti-slop-ui - HARD gate on frontend source. One finding = fail (exit 2). Clean = exit 0."
  printf '%s\n' "usage: bash anti-slop-ui.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/anti-slop-ui-report.json - fix recipes: walteur-kit/REMEDIATION.md (## anti-slop-ui)"
  printf '%s\n' "bypass: WALTEUR_ANTISLOPUI=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/anti-slop-ui-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_report() { # $1=verdict  $2=reason  $3=findings-json-array  $4=scanned-count
  jq -n \
    --arg v "$1" --arg ts "$TS" --arg reason "$2" --arg dir "${DIR:-}" \
    --argjson findings "${3:-[]}" --argjson scanned "${4:-0}" \
    '{verdict:$v, ts:$ts, gate:"anti-slop-ui", dir:$dir, reason:$reason,
      files_scanned:$scanned, details:$findings}' > "$REPORT"
}

# ── tool guard ───────────────────────────────────────────────────────────────
for t in grep awk sed jq find; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR anti-slop-ui SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
    write_report "SKIP" "$t not installed" '[]' 0
    exit 0
  fi
done

# ── twin-fixture --selftest (R2: lock the new 2026 slop tells + the floor) ───────────────────────────
selftest_antislopui() {
  local pass=0 fail=0 t
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  rn() { bash "$0" "$1" >/dev/null 2>&1; echo $?; }
  echo "anti-slop-ui selftest:"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopui.XXXXXX")"; printf 'export const C = () => <button className="rounded-lg bg-primary px-4 py-2 hover:bg-primary/90 focus-visible:ring">Go</button>;\n' > "$t/c.tsx"; ck "clean UI -> PASS" 0 "$(rn "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopui.XXXXXX")"; printf 'console.log(1)\n' > "$t/x.txt"; ck "no frontend files -> SKIP(0)" 0 "$(rn "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopui.XXXXXX")"; printf '<div className="bg-gradient-to-r from-purple-500 to-indigo-600">x</div>\n' > "$t/g.tsx"; ck "R1 purple gradient -> FAIL" 2 "$(rn "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopui.XXXXXX")"; printf '<p>lorem ipsum dolor sit</p>\n' > "$t/l.tsx"; ck "R2 lorem ipsum -> FAIL" 2 "$(rn "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopui.XXXXXX")"; printf '<h1 className="bg-clip-text text-transparent">Hi</h1>\n' > "$t/t.tsx"; ck "R11 gradient-text -> FAIL" 2 "$(rn "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopui.XXXXXX")"; printf '<div className="bg-[#ff0055] text-[#ffffff]">x</div>\n' > "$t/h.tsx"; ck "R12 arbitrary hex -> FAIL" 2 "$(rn "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopui.XXXXXX")"; printf '<div className="transition duration-1000">x</div>\n' > "$t/m.tsx"; ck "R13 sluggish motion -> FAIL" 2 "$(rn "$t")"; rm -rf "$t"
  # ── Panel #12 JSX BLIND SPOT: every case above uses the kebab-case HTML/Tailwind spelling, so none of them
  # could see the camelCase form real React code actually writes. Both of the prescribed tells passed in that
  # form. These four pin the camelCase spellings AND the negative control that keeps R14 honest.
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopui.XXXXXX")"; printf 'const A=()=><h1 style={{WebkitBackgroundClip:"text",backgroundImage:"linear-gradient(90deg,#a855f7,#6366f1)"}}>Hi</h1>;\n' > "$t/g1.tsx"; ck "R11 gradient-text in React camelCase -> FAIL (was PASS pre-panel-12)" 2 "$(rn "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopui.XXXXXX")"; printf 'const B=()=><div style={{boxShadow:"0 0 40px rgba(168,85,247,.6)"}}>g</div>;\n' > "$t/g2.tsx"; ck "R14 dark-glow in React camelCase -> FAIL (was PASS pre-panel-12)" 2 "$(rn "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopui.XXXXXX")"; printf 'const E=()=><div className="shadow-[0_0_40px_rgba(168,85,247,0.6)]">g</div>;\n' > "$t/g3.tsx"; ck "R14 dark-glow in a Tailwind arbitrary value -> FAIL" 2 "$(rn "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopui.XXXXXX")"; printf 'const F=()=><div style={{boxShadow:"0 1px 3px rgba(0,0,0,.12)"}} className="shadow-sm">ok</div>;\n' > "$t/ok.tsx"; ck "R14 FP guard: neutral downward-offset elevation shadow -> PASS" 0 "$(rn "$t")"; rm -rf "$t"
  echo "anti-slop-ui selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}
if [ "${1:-}" = "--selftest" ]; then selftest_antislopui; exit $?; fi
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_ANTISLOPUI:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_ANTISLOPUI=off" '[]' 0; echo "anti-slop-ui: bypassed." >&2; exit 0; }

# Default to scanning the build ROOT when invoked with no dir arg, so it works as a wired ship-gate
# (was: SKIP on no-arg, which left this gate ORPHANED/unenforced). An explicit non-dir arg still SKIPs.
DIR="${1:-$ROOT}"
if [ ! -d "$DIR" ]; then
  echo "WALTEUR anti-slop-ui SKIP — '$DIR' is not a directory (nothing to scan)." >&2
  write_report "SKIP" "not a directory: $DIR" '[]' 0
  exit 0
fi

# ── collect frontend files (prune node_modules / .git / dist / build) ────────
FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$f")
done < <(find "$DIR" \
  \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/graphify-out/*' -o -path '*/walteur-kit/*' -o -path "$DIR/field-runs/*" \) -prune -o \
  -type f \( -name '*.jsx' -o -name '*.tsx' -o -name '*.vue' -o -name '*.svelte' -o -name '*.html' -o -name '*.css' \) -print 2>/dev/null)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "WALTEUR anti-slop-ui SKIP — no frontend files (.jsx/.tsx/.vue/.svelte/.html/.css) under '$DIR'." >&2
  write_report "SKIP" "no frontend files found" '[]' 0
  exit 0
fi

declare -a FINDINGS_JSON=()
add() { # $1=file  $2=line  $3=rule  $4=message
  FINDINGS_JSON+=("$(jq -n --arg f "$1" --argjson ln "$2" --arg r "$3" --arg m "$4" \
    '{file:$f, line:$ln, rule:$r, message:$m}')")
}

# ── shadcn/ui setup detection (gates R9) ─────────────────────────────────────
# R9 only fires when the project demonstrably uses shadcn/ui: a components.json at the scan root
# OR an @/components/ui directory anywhere under <dir> (the conventional shadcn primitives folder).
# Heuristic + low-false-positive: with no shadcn setup, hand-rolled primitives are not slop.
SHADCN=0
if [ -f "$DIR/components.json" ]; then
  SHADCN=1
else
  if find "$DIR" \
      \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' \) -prune -o \
      -type d -path '*/components/ui' -print 2>/dev/null | grep -q .; then
    SHADCN=1
  fi
fi

# ── OPT-IN AST backend for the raw-primitive / inline-style signal (R9/R10), ADDITIVE ──
# Only meaningful when shadcn/ui is present (matches R9 applicability). AST finding => FAIL exit 2;
# AST-clean OR ast-grep absent => fall through to the existing grep R1..R10 floor below (no coverage lost).
# NOTE: the per-file '@/components/ui' import exemption stays in the grep floor; if the AST arm ever
# false-positives, port that exemption into raw-primitive-inline-style.yml (tracked in UPGRADE-v9.1.md).
if [ "$SHADCN" -eq 1 ] && [ -f "$(dirname "$0")/_ast-grep-preamble.sh" ]; then
  . "$(dirname "$0")/_ast-grep-preamble.sh"
  walteur_astgrep_pass "$KIT/sgconfig.yml" "$DIR" "anti-slop-ui"
  _ag_rc=$?
  if [ "$_ag_rc" -eq 2 ]; then
    write_report "FAIL" "ast-grep AST backend: raw-primitive/inline-style finding(s) (see stderr)" '[]' "${#FILES[@]}"
    exit 2
  fi
fi

# helper: emit "LINE\tTEXT" for an extended-regex, case-insensitive match in one file
matches() { grep -niE "$2" "$1" 2>/dev/null || true; }

for file in "${FILES[@]}"; do
  rel="${file#"$ROOT"/}"

  # ── R1: purple/indigo gradient pairs ──
  # A line that references a gradient AND one of the purple/indigo/violet tailwind direction classes.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
    add "$rel" "$ln" "gradient-purple-indigo" "AI-slop gradient: $txt"
  done < <(grep -niE 'gradient' "$file" 2>/dev/null | grep -iE 'from-purple|to-indigo|from-violet|to-violet|from-indigo|to-purple' || true)

  # ── R2: lorem ipsum ──
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
    add "$rel" "$ln" "lorem-ipsum" "Placeholder copy: $txt"
  done < <(matches "$file" 'lorem ipsum')

  # ── R3: fake names / data ──
  # $XX and $1,234 are literal-dollar patterns; escape the regex carefully.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
    add "$rel" "$ln" "fake-data" "Fake/placeholder data: $txt"
  done < <(grep -niE 'Acme|John Doe|jane@example|pravatar|placeholder\.com|\$XX|\$1,234' "$file" 2>/dev/null || true)

  # ── R4: emoji inside a <button> ──
  # Find <button ...> ... </button> spans (awk state machine, multi-line aware) and flag any EMOJI
  # / pictograph byte-signature inside the button content. Reported at the button's opening line.
  #
  # PORTABILITY: this runs under LC_ALL=C so awk treats input as raw single bytes (BSD awk on macOS
  # and gawk on Linux both honour this). We match UTF-8 emoji LEAD bytes by octal escape — robust
  # across awk flavours, unlike the multibyte \200-\377 class which BSD awk silently drops. We do
  # NOT flag plain accented Latin text (é = C3 A9) — only genuine emoji/pictographs:
  #   F0 9F (\360\237)        -> U+1F000..U+1FFFF  (emoji, symbols-and-pictographs)
  #   E2 98..9E (\342\230..\236) -> U+2600..U+27BF  (misc symbols + dingbats, incl. ★ ✓ ☂)
  #   E2 AC/AD (\342\254/\255)   -> arrows/stars subset (U+2B00 block lead)
  while IFS= read -r ln; do
    [ -z "$ln" ] && continue
    txt="$(awk -v n="$ln" 'NR==n{print}' "$file")"
    add "$rel" "$ln" "emoji-in-button" "Emoji inside <button>: $(printf '%s' "$txt" | sed -E 's/^[[:space:]]+//')"
  done < <(LC_ALL=C awk '
    function has_emoji(str,   i,n,c1,c2,d) {
      n=length(str)
      for (i=1;i<n;i++) {
        c1=substr(str,i,1); c2=substr(str,i+1,1)
        if (c1=="\360" && c2=="\237") return 1
        if (c1=="\342") {
          d=c2
          if (d=="\230"||d=="\231"||d=="\232"||d=="\233"||d=="\234"||d=="\235"||d=="\236"||d=="\254"||d=="\255") return 1
        }
      }
      return 0
    }
    { line[NR]=$0 }
    END {
      inbtn=0; openln=0; buf="";
      for (i=1;i<=NR;i++) {
        rest=line[i]
        while (length(rest)>0) {
          if (!inbtn) {
            p=index(tolower(rest), "<button")
            if (p==0) break
            inbtn=1; openln=i; buf=""
            rest=substr(rest, p+7)
          } else {
            c=index(tolower(rest), "</button")
            if (c==0) { buf=buf rest; rest=""; }
            else {
              buf=buf substr(rest,1,c-1)
              if (has_emoji(buf)) print openln
              inbtn=0; openln=0; buf="";
              rest=substr(rest, c+8)
            }
          }
        }
        if (inbtn) buf=buf " "   # span continues to next line
      }
    }' "$file" | sort -un)

  # ── R5: arbitrary tailwind pixel width  w-[NNNpx] ──
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
    add "$rel" "$ln" "arbitrary-tailwind-size" "Arbitrary pixel sizing (use a scale token): $txt"
  done < <(grep -niE 'w-\[[0-9]+px\]' "$file" 2>/dev/null || true)

  # ── R6: outline:none WITHOUT focus-visible in the SAME file ──
  OUTLINE_HITS="$(grep -niE 'outline:[[:space:]]*none' "$file" 2>/dev/null || true)"
  if [ -n "$OUTLINE_HITS" ]; then
    if ! grep -qiE 'focus-visible' "$file" 2>/dev/null; then
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
        add "$rel" "$ln" "outline-none-no-focus" "outline:none removes focus ring with no :focus-visible replacement: $txt"
      done <<< "$OUTLINE_HITS"
    fi
  fi

  # ── R7: alert( ──
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
    add "$rel" "$ln" "alert-call" "alert() is lazy UX: $txt"
  done < <(grep -niE 'alert\(' "$file" 2>/dev/null || true)

  # ── R8: "Something went wrong" ──
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
    add "$rel" "$ln" "generic-error" "Generic AI error copy: $txt"
  done < <(matches "$file" 'Something went wrong')

  # ── R9: hand-rolled primitive when shadcn/ui is present but file ignores @/components/ui ──
  # Only for .tsx/.jsx, only when SHADCN=1, and only when THIS file does not import a ui primitive.
  # Heuristic, low-false-positive: a file that already pulls from '@/components/ui/...' is exempt,
  # and so are the canonical shadcn primitives themselves (anything under a components/ui/ dir — that
  # IS the legitimate home of Button/Input/Dialog definitions).
  case "$file" in
    */components/ui/*) ;;  # shadcn primitive itself — never slop
    *.tsx|*.jsx)
      if [ "$SHADCN" -eq 1 ] && ! grep -qE "from[[:space:]]+['\"]@/components/ui/" "$file" 2>/dev/null; then
        # (a) raw <button>/<input>/<select>/<dialog> with heavy inline styling (style={{...}} or 2+ classes)
        while IFS= read -r hit; do
          [ -z "$hit" ] && continue
          ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
          add "$rel" "$ln" "hand-rolled-primitive" "Raw <button>/<input>/<select>/<dialog> heavily styled instead of @/components/ui: $txt"
        done < <(grep -niE '<(button|input|select|dialog)\b[^>]*(style=\{\{|className=("[^"]*[^"]+ [^"]+|[^"]*\{))' "$file" 2>/dev/null || true)
        # (b) custom Button/Input/Dialog component DEFINED in this project (not imported from ui)
        while IFS= read -r hit; do
          [ -z "$hit" ] && continue
          ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
          add "$rel" "$ln" "hand-rolled-primitive" "Custom Button/Input/Dialog component defined instead of using @/components/ui: $txt"
        done < <(grep -niE '(function|const)[[:space:]]+(Button|Input|Select|Dialog)\b[[:space:]]*([=(]|:)' "$file" 2>/dev/null || true)
      fi
      ;;
  esac

  # ── R10: inline style={{...}} used for LAYOUT (prefer Tailwind utilities) ──
  # .tsx/.jsx only. style={{ ... width/height/color/padding ... }} — layout properties belong in
  # Tailwind utility classes. Matches both quoted keys and JSX camelCase property names.
  case "$file" in
    *.tsx|*.jsx)
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
        add "$rel" "$ln" "inline-style-layout" "Inline style for layout; prefer Tailwind utility classes: $txt"
      done < <(grep -niE 'style=\{\{[^}]*(width|height|color|padding)' "$file" 2>/dev/null || true)
      ;;
  esac

  # ── R11: gradient TEXT (bg-clip-text + transparent) — the 2026 "AI gradient headline" tell (R2 upgrade) ──
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
    add "$rel" "$ln" "gradient-text" "Gradient-text headline — a top AI-slop tell; use a solid token color: $txt"
  done < <(grep -niE 'bg-clip-text|background-clip:[[:space:]]*text|-webkit-background-clip:[[:space:]]*text|(webkit)?backgroundclip[[:space:]]*:[[:space:]]*.?text' "$file" 2>/dev/null || true)
  # ^ Panel #12: the original pattern list was CSS-only (kebab-case). React writes inline styles as camelCase
  #   object keys — WebkitBackgroundClip:"text" / backgroundClip:'text' — so the exact tell this harness
  #   prescribes walked straight through in the form real .tsx code uses. Both spellings match now, both pinned.

  # ── R14: zero-offset COLORED GLOW (box-shadow / text-shadow "0 0 <blur> <saturated color>") ──
  # Panel #12 refutation: this is one of the three tells the harness explicitly names, and NO rule here
  # matched it in ANY form. A chromatic halo is the default "cool" look of AI-generated UIs; real elevation
  # shadows are neutral and offset downward. Matched in CSS (box-shadow: 0 0 40px rgba(168,85,247,.6)), in
  # React camelCase (boxShadow:"0 0 40px rgba(...)") and in Tailwind arbitrary values (shadow-[0_0_40px_...]).
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
    add "$rel" "$ln" "dark-glow" "Zero-offset colored glow — a chromatic halo is the default AI 'cool' look; use a neutral, downward-offset elevation shadow: $txt"
  done < <(perl -ne '
    my $l=$_; next if $l =~ /slop-ok/i;
    if ($l =~ /(?:box|text)[-_]?shadow\s*:\s*[\x22\x27]?\s*(?:inset\s+)?\b0\s*(?:px)?\s+0\s*(?:px)?\s+[0-9.]+\s*(?:px|rem)([^;}]*)/i) {
      my $rest=$1;
      if ($rest =~ /rgba?\(|hsla?\(|#[0-9a-fA-F]{3,8}\b|var\(--[a-zA-Z-]*(?:accent|brand|purple|violet|indigo|glow|primary)/) { print "$.:$l"; next; }
    }
    print "$.:$l" if $l =~ /shadow-\[[^]]*0_0_[0-9.]+(?:px|rem)_[^]]*(?:rgba?\(|hsla?\(|%23|#)[^]]*\]/;
  ' "$file" 2>/dev/null || true)

  # ── R12: arbitrary hex color in className/style — bypasses the design-token contract ──
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
    add "$rel" "$ln" "arbitrary-hex-color" "Raw hex color bypasses the DESIGN.md tokens — use a semantic token: $txt"
  done < <(grep -niE '(text|bg|border|from|to|via|ring|fill|stroke|shadow)-\[#[0-9a-fA-F]{3,8}\]' "$file" 2>/dev/null || true)

  # ── R13: sluggish UI motion (>=1000ms) — feels broken; AI builders default to slow fades ──
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
    add "$rel" "$ln" "sluggish-motion" "UI motion >=1000ms feels broken — use <300ms ease-out for interactions: $txt"
  done < <(grep -niE 'duration-(1000|1500|2000|3000)\b|(transition|animation)[^;{]*[^0-9]([1-9][0-9]{3,})ms' "$file" 2>/dev/null || true)

done

SCANNED="${#FILES[@]}"

if [ "${#FINDINGS_JSON[@]}" -eq 0 ]; then
  write_report "PASS" "no AI-slop signatures found" '[]' "$SCANNED"
  echo "WALTEUR anti-slop-ui: PASS — $SCANNED frontend file(s) scanned, zero slop signatures." >&2
  exit 0
fi

FIND_JSON="$(printf '%s\n' "${FINDINGS_JSON[@]}" | jq -s '.')"
write_report "FAIL" "${#FINDINGS_JSON[@]} AI-slop finding(s)" "$FIND_JSON" "$SCANNED"
echo "WALTEUR anti-slop-ui: FAIL — ${#FINDINGS_JSON[@]} finding(s) across $SCANNED file(s):" >&2
for f in "${FINDINGS_JSON[@]}"; do
  file="$(printf '%s' "$f" | jq -r '.file')"
  line="$(printf '%s' "$f" | jq -r '.line')"
  rule="$(printf '%s' "$f" | jq -r '.rule')"
  msg="$(printf '%s' "$f" | jq -r '.message')"
  echo "  [$rule] $file:$line  $msg" >&2
done
exit 2
