#!/usr/bin/env bash
# WALTEUR a11y-content-lint — honest zero-dep cognitive/content accessibility gate.
#
# Goes BEYOND axe-core's automated DOM checks: these are content-level a11y rules a linter usually
# misses. APPLIES ONLY if frontend files exist (.html/.jsx/.tsx/.vue/.svelte). A bare repo or a
# CLI/back-end-only project => verdict NOT_APPLICABLE, exit 0 (we do NOT force a11y on a CLI tool).
#
# ZERO-DEP HARD checks (bash/grep/awk/sed/find/jq only — real exit 2 on a real violation):
#   A1  <img> without an alt attribute            (screen-reader sees nothing).
#   A2  a form <input> with no associated label    — no aria-label / aria-labelledby on the input,
#         and no id that a <label for="..."> references in the same file (and not type=hidden/submit/button).
#   A3  link with generic text ("click here" / "read more" / "learn more" / "here") — meaningless out of context.
#   A4  a <button> with no accessible name         — empty text content AND no aria-label / aria-labelledby / title.
#
# DETECT-OR-LOUD-SKIP: uses only always-present tools (grep/awk/sed/find/jq). If one is genuinely
# absent => loud SKIP + exit 0 (never silent-green, never exit 2 on a missing tool).
#
# Report: walteur-kit/a11y-content-report.json  {verdict, ts, gate, details}.
# Honors walteur-kit/PAUSED and WALTEUR_A11Y=off.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "a11y-content-lint - honest zero-dep cognitive/content accessibility gate."
  printf '%s\n' "usage: bash a11y-content-lint.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/a11y-content-report.json - fix recipes: walteur-kit/REMEDIATION.md (## a11y-content-lint)"
  printf '%s\n' "bypass: WALTEUR_A11Y=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/a11y-content-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_simple_report() {
  verdict="$1"
  reason="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" \
      '{verdict:$v, ts:$ts, gate:"a11y-content", reason:$r, details:[]}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"a11y-content","reason":"%s","details":[]}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

selftest() {
  pass=0
  fail=0

  ck() {
    name="$1"
    want="$2"
    got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  run_gate() {
    root="$1"
    WALTEUR_ROOT="$root" bash "$0" >/dev/null 2>&1
  }

  verdict() {
    jq -r '.verdict // "MISSING"' "$1/walteur-kit/a11y-content-report.json" 2>/dev/null || echo "MISSING"
  }

  make_root() {
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/a11y-content-selftest.XXXXXX")" || return 1
    mkdir -p "$tmp/walteur-kit" "$tmp/src"
    printf '%s\n' "$tmp"
  }

  write_valid_html() {
    cat > "$1/src/App.html" <<'HTML'
<main>
  <img src="/logo.png" alt="Company logo">
  <label for="email">Email</label>
  <input id="email" type="email">
  <a href="/docs">Read the product documentation</a>
  <button type="button">Save</button>
</main>
HTML
  }

  if ! command -v jq >/dev/null 2>&1; then
    echo "a11y-content-lint selftest SKIP - jq not installed."
    return 0
  fi

  echo "a11y-content-lint selftest:"

  tmp="$(make_root)"
  run_gate "$tmp"
  rc=$?
  [ "$(verdict "$tmp")" = "NOT_APPLICABLE" ] || rc=99
  ck "no frontend files -> NOT_APPLICABLE" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_html "$tmp"
  run_gate "$tmp"
  rc=$?
  [ "$(verdict "$tmp")" = "PASS" ] || rc=99
  ck "valid content accessibility -> PASS" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_html "$tmp"
  sed 's/ alt="Company logo"//' "$tmp/src/App.html" > "$tmp/src/App.next" && mv "$tmp/src/App.next" "$tmp/src/App.html"
  run_gate "$tmp"
  ck "image missing alt -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_html "$tmp"
  grep -v '<label for="email">' "$tmp/src/App.html" > "$tmp/src/App.next" && mv "$tmp/src/App.next" "$tmp/src/App.html"
  run_gate "$tmp"
  ck "input missing label -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_html "$tmp"
  perl -0pi -e 's/Read the product documentation/Click here/' "$tmp/src/App.html"
  run_gate "$tmp"
  ck "generic link text -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_html "$tmp"
  perl -0pi -e 's|<button type="button">Save</button>|<button type="button"></button>|' "$tmp/src/App.html"
  run_gate "$tmp"
  ck "button missing accessible name -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_html "$tmp"
  WALTEUR_A11Y=off run_gate "$tmp"
  rc=$?
  [ "$(verdict "$tmp")" = "SKIP" ] || rc=99
  ck "bypass writes SKIP report -> PASS" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_html "$tmp"
  touch "$tmp/walteur-kit/PAUSED"
  run_gate "$tmp"
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "a11y-content-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

# ── bypass + pause ────────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_A11Y:-on}" = "off" ] && {
  echo "a11y-content-lint: bypassed (WALTEUR_A11Y=off)." >&2
  write_simple_report "SKIP" "bypassed via WALTEUR_A11Y=off"
  exit 0
}

# ── tool guard (detect-or-loud-SKIP) ─────────────────────────────────────────
for t in grep awk sed jq find; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR a11y-content-lint SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
    jq -n --arg ts "$TS" --arg t "$t" \
      '{verdict:"SKIP", ts:$ts, gate:"a11y-content", reason:($t+" not installed")}' > "$REPORT" 2>/dev/null \
      || printf '{"verdict":"SKIP","ts":"%s","gate":"a11y-content","reason":"%s not installed"}\n' "$TS" "$t" > "$REPORT"
    exit 0
  fi
done

# ── collect frontend files (prune vendor dirs) ───────────────────────────────
FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$f")
done < <(find "$ROOT" \
  \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/vendor/*' \) -prune -o \
  -type f \( -name '*.html' -o -name '*.htm' -o -name '*.jsx' -o -name '*.tsx' -o -name '*.vue' -o -name '*.svelte' \) -print 2>/dev/null)

# ── APPLICABILITY: no frontend files => NOT_APPLICABLE ───────────────────────
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "a11y-content-lint: no frontend files (.html/.jsx/.tsx/.vue/.svelte) present — gate not applicable." >&2
  jq -n --arg ts "$TS" '{verdict:"NOT_APPLICABLE", ts:$ts, gate:"a11y-content", reason:"no frontend files present"}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"a11y-content"}\n' "$TS" > "$REPORT"
  exit 0
fi

echo "WALTEUR a11y-content-lint @ $ROOT (${#FILES[@]} frontend file(s))" >&2

declare -a FINDINGS_JSON=()
add() { # $1=file  $2=line  $3=rule  $4=message
  FINDINGS_JSON+=("$(jq -n --arg f "$1" --argjson ln "$2" --arg r "$3" --arg m "$4" \
    '{file:$f, line:$ln, rule:$r, message:$m}')")
}

for file in "${FILES[@]}"; do
  rel="${file#"$ROOT"/}"

  # ── A1: <img> without alt ──────────────────────────────────────────────────
  # Match an <img ...> tag that does NOT contain alt= anywhere in the tag. awk handles the
  # opening-tag span (it may wrap lines) and reports at the line where <img starts.
  while IFS= read -r ln; do
    [ -z "$ln" ] && continue
    txt="$(awk -v n="$ln" 'NR==n{print}' "$file" | sed -E 's/^[[:space:]]+//')"
    add "$rel" "$ln" "img-missing-alt" "<img> without alt attribute (invisible to screen readers): $txt"
  done < <(LC_ALL=C awk '
    { line[NR]=$0 }
    END {
      inimg=0; openln=0; buf=""
      for (i=1;i<=NR;i++) {
        rest=line[i]
        while (length(rest)>0) {
          if (!inimg) {
            p=index(tolower(rest), "<img")
            if (p==0) break
            # ensure <img is a tag start (next char is space, >, / or end)
            after=substr(rest, p+4, 1)
            if (after!="" && after!=" " && after!="\t" && after!=">" && after!="/" && after!="\r") {
              rest=substr(rest, p+4); continue
            }
            inimg=1; openln=i; buf=substr(rest, p)
            rest=substr(rest, p+4)
          } else {
            c=index(rest, ">")
            if (c==0) { buf=buf rest; rest="" }
            else {
              buf=buf substr(rest,1,c)
              if (tolower(buf) !~ /alt[[:space:]]*=/) print openln
              inimg=0; openln=0; buf=""
              rest=substr(rest, c+1)
            }
          }
        }
        if (inimg) buf=buf " "
      }
    }' "$file" 2>/dev/null | sort -un)

  # ── A3: generic link / link-like text ──────────────────────────────────────
  # Flag anchor/link text that is generic ("click here", "read more", "learn more", "here",
  # "more", "this link", "click"). Match >TEXT< right after an <a ...> opening or a generic
  # phrase on a line containing an anchor.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
    add "$rel" "$ln" "generic-link-text" "Link text is generic / non-descriptive: $txt"
  done < <(grep -niE '<a[[:space:]][^>]*>[[:space:]]*(click here|read more|learn more|click|here|more|this link|details)[[:space:]]*</a>' "$file" 2>/dev/null || true)

  # ── A2: form <input> with no associated label ──────────────────────────────
  # Strategy (per file): build the set of label-for targets, then for each <input> tag:
  #   - skip type in {hidden, submit, button, image, reset}  (no visible label needed)
  #   - PASS if the tag itself has aria-label / aria-labelledby / title / placeholder-is-not-a-label-but-we-still-require-real-label
  #   - PASS if it has an id that some <label for="ID"> references
  #   - else => violation
  # Accept BOTH HTML `for="..."` and JSX `htmlFor="..."` on <label> elements.
  # NOTE: BSD sed does not honor the `I` substitution flag, so we lowercase the matched snippet
  # first, then strip the `for=`/`htmlfor=` prefix with a portable case-stable pattern.
  LABEL_FORS="$(grep -oiE '<label[^>]*\b(html)?for=["'\''][^"'\'']+["'\'']' "$file" 2>/dev/null \
                  | grep -oiE '(html)?for=["'\''][^"'\'']+["'\'']' \
                  | sed -E 's/^[^"'\'']*["'\'']//; s/["'\''].*$//' | sort -u || true)"
  # also: an <input> nested inside <label>...</label> is acceptable; detect "wrapped" lines.
  while IFS= read -r ln; do
    [ -z "$ln" ] && continue
    tag="$(awk -v n="$ln" 'NR==n{print}' "$file")"
    low="$(printf '%s' "$tag" | tr 'A-Z' 'a-z')"
    # type exemptions
    case "$low" in
      *type=\"hidden\"*|*type=\'hidden\'*|*type=\"submit\"*|*type=\'submit\'*|*type=\"button\"*|*type=\'button\'*|*type=\"image\"*|*type=\'image\'*|*type=\"reset\"*|*type=\'reset\'*) continue;;
    esac
    # accessible-name on the input itself
    if printf '%s' "$low" | grep -qE 'aria-label|aria-labelledby|title='; then continue; fi
    # input wrapped inside a <label> on the same line
    if printf '%s' "$low" | grep -qE '<label[^>]*>.*<input'; then continue; fi
    # id referenced by a <label for>
    id="$(printf '%s' "$tag" | grep -oiE '\bid=["'\''][^"'\'']+["'\'']' | head -n1 | sed -E 's/^[^"'\'']*["'\'']//; s/["'\''].*$//')"
    if [ -n "$id" ] && printf '%s\n' "$LABEL_FORS" | grep -qxF "$id"; then continue; fi
    add "$rel" "$ln" "input-no-label" "Form <input> has no associated <label>/aria-label: $(printf '%s' "$tag" | sed -E 's/^[[:space:]]+//')"
  done < <(grep -niE '<input([[:space:]]|>|/)' "$file" 2>/dev/null | cut -d: -f1 | sort -un)

  # ── A4: <button> with no accessible name ───────────────────────────────────
  # A button needs a name from: text content, aria-label, aria-labelledby, or title.
  # awk walks <button ...>CONTENT</button> spans; strip tags/whitespace from CONTENT; if empty AND
  # the opening tag has none of the aria-/title attributes => violation at the opening line.
  while IFS= read -r ln; do
    [ -z "$ln" ] && continue
    txt="$(awk -v n="$ln" 'NR==n{print}' "$file" | sed -E 's/^[[:space:]]+//')"
    add "$rel" "$ln" "button-no-name" "<button> has no accessible name (no text, aria-label, or title): $txt"
  done < <(LC_ALL=C awk '
    { line[NR]=$0 }
    END {
      inbtn=0; openln=0; opentag=""; buf=""
      for (i=1;i<=NR;i++) {
        rest=line[i]
        while (length(rest)>0) {
          if (!inbtn) {
            p=index(tolower(rest), "<button")
            if (p==0) break
            after=substr(rest, p+7, 1)
            if (after!="" && after!=" " && after!="\t" && after!=">" && after!="/" && after!="\r") {
              rest=substr(rest, p+7); continue
            }
            # capture opening tag up to its first ">"
            tagrest=substr(rest, p)
            gt=index(tagrest, ">")
            if (gt==0) { opentag=tagrest } else { opentag=substr(tagrest,1,gt) }
            inbtn=1; openln=i; buf=""
            # content begins after the opening ">"
            if (gt==0) { rest="" } else { rest=substr(rest, p+gt) }
          } else {
            c=index(tolower(rest), "</button")
            if (c==0) { buf=buf rest; rest="" }
            else {
              buf=buf substr(rest,1,c-1)
              # strip nested tags + whitespace + JSX braces from content
              content=buf
              gsub(/<[^>]*>/, "", content)
              gsub(/[ \t\r\n]+/, "", content)
              gsub(/[{}]/, "", content)
              tl=tolower(opentag)
              has_name = (tl ~ /aria-label/ || tl ~ /aria-labelledby/ || tl ~ /title[ \t]*=/)
              # JSX dynamic content like {label} counts as a possible name -> not flagged
              had_brace = (index(buf, "{") > 0)
              if (content=="" && has_name==0 && had_brace==0) print openln
              inbtn=0; openln=0; opentag=""; buf=""
              rest=substr(rest, c+8)
            }
          }
        }
        if (inbtn) buf=buf " "
      }
    }' "$file" 2>/dev/null | sort -un)

done

# ── verdict ──────────────────────────────────────────────────────────────────
SCANNED="${#FILES[@]}"
if [ "${#FINDINGS_JSON[@]}" -eq 0 ]; then
  jq -n --arg ts "$TS" --argjson scanned "$SCANNED" \
    '{verdict:"PASS", ts:$ts, gate:"a11y-content", files_scanned:$scanned, details:[]}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"PASS","ts":"%s","gate":"a11y-content"}\n' "$TS" > "$REPORT"
  echo "a11y-content-lint: PASS — $SCANNED frontend file(s) scanned, zero content-a11y violations." >&2
  exit 0
fi

FIND_JSON="$(printf '%s\n' "${FINDINGS_JSON[@]}" | jq -s '.')"
jq -n --arg ts "$TS" --argjson scanned "$SCANNED" --argjson findings "$FIND_JSON" \
  '{verdict:"FAIL", ts:$ts, gate:"a11y-content", files_scanned:$scanned,
    finding_count:($findings|length), details:$findings}' > "$REPORT" 2>/dev/null \
  || printf '{"verdict":"FAIL","ts":"%s","gate":"a11y-content"}\n' "$TS" > "$REPORT"

echo "a11y-content-lint: FAIL — ${#FINDINGS_JSON[@]} finding(s):" >&2
for f in "${FINDINGS_JSON[@]}"; do
  file="$(printf '%s' "$f" | jq -r '.file')"
  line="$(printf '%s' "$f" | jq -r '.line')"
  rule="$(printf '%s' "$f" | jq -r '.rule')"
  msg="$(printf '%s' "$f" | jq -r '.message')"
  echo "  [$rule] $file:$line  $msg" >&2
done
exit 2
