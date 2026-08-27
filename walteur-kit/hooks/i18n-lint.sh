#!/usr/bin/env bash
# WALTEUR i18n-lint — honest zero-dep internationalisation gate.
#
# APPLICABILITY FIRST: this gate runs ONLY if the project actually uses an i18n framework.
# Triggers (ANY one):
#   - package.json dependency on:  i18next | react-i18next | react-intl | vue-i18n | next-intl
#                                  | @lingui | svelte-i18n | formatjs | intl-messageformat
#   - a `locales/` or `lang/` or `i18n/` or `translations/` directory
#   - any *.po / *.pot file (gettext)
#   - a messages.json catalog (Chrome-extension / generic) or messages.*.json
#   - source that imports/uses i18next / useTranslation / FormattedMessage / vue-i18n $t / gettext
# If NONE of these exist => bare/no-i18n project => verdict NOT_APPLICABLE, exit 0.
# (Do NOT force i18n on every project — that is the #1 past WALTEUR bug.)
#
# ZERO-DEP HARD checks (bash/grep/awk/sed/find/jq only — real exit 2 on a real violation):
#   C1  Hardcoded user-facing strings that BYPASS the i18n catalog, in components:
#         - JSX text node literals (non-whitespace text between > and <) not wrapped by
#           {t(...)} / {i18n...} / <FormattedMessage>.
#         - alert("literal") / confirm("literal") / toast("literal") with a bare string literal.
#       Files whose path or content shows they ARE i18n-wired are still scanned (a wired file can
#       still leak a hardcoded string). Files with NO user-facing markup are skipped naturally.
#   C2  Locale catalog drift: every NON-default JSON locale catalog must contain every key that
#       the default locale defines. Missing keys => violation (untranslated UI in that locale).
#
# DETECT-OR-LOUD-SKIP: this gate uses only always-present tools (grep/awk/sed/find/jq). If one is
# genuinely absent it prints a loud SKIP and exits 0 — never silent-green, never exit 2 on absence.
#
# Report: walteur-kit/i18n-report.json  {verdict, ts, gate, details}.
# Honors walteur-kit/PAUSED and WALTEUR_I18N=off.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "i18n-lint - honest zero-dep internationalisation gate."
  printf '%s\n' "usage: bash i18n-lint.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/i18n-report.json - fix recipes: walteur-kit/REMEDIATION.md (## i18n-lint)"
  printf '%s\n' "bypass: WALTEUR_I18N=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/i18n-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_simple_report() {
  verdict="$1"
  reason="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" \
      '{verdict:$v, ts:$ts, gate:"i18n", reason:$r, details:[]}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"i18n","reason":"%s","details":[]}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
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
    jq -r '.verdict // "MISSING"' "$1/walteur-kit/i18n-report.json" 2>/dev/null || echo "MISSING"
  }

  make_root() {
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/i18n-lint-selftest.XXXXXX")" || return 1
    mkdir -p "$tmp/walteur-kit" "$tmp/src" "$tmp/locales"
    printf '%s\n' "$tmp"
  }

  write_package() {
    cat > "$1/package.json" <<'JSON'
{
  "dependencies": {
    "react-i18next": "latest"
  }
}
JSON
  }

  write_valid_i18n() {
    write_package "$1"
    cat > "$1/locales/en.json" <<'JSON'
{
  "save": "Save",
  "cancel": "Cancel"
}
JSON
    cat > "$1/locales/fr.json" <<'JSON'
{
  "save": "Enregistrer",
  "cancel": "Annuler"
}
JSON
    cat > "$1/src/App.tsx" <<'TSX'
import { useTranslation } from "react-i18next";

export function App() {
  const { t } = useTranslation();
  return <button>{t("save")}</button>;
}
TSX
  }

  if ! command -v jq >/dev/null 2>&1; then
    echo "i18n-lint selftest SKIP - jq not installed."
    return 0
  fi

  echo "i18n-lint selftest:"

  tmp="$(make_root)"
  rm -rf "$tmp/locales"
  run_gate "$tmp"
  rc=$?
  [ "$(verdict "$tmp")" = "NOT_APPLICABLE" ] || rc=99
  ck "no i18n framework -> NOT_APPLICABLE" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_i18n "$tmp"
  run_gate "$tmp"
  rc=$?
  [ "$(verdict "$tmp")" = "PASS" ] || rc=99
  ck "valid translated component and catalogs -> PASS" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_i18n "$tmp"
  cat > "$tmp/src/App.tsx" <<'TSX'
export function App() {
  return <button>Save</button>;
}
TSX
  run_gate "$tmp"
  ck "hardcoded JSX text -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_i18n "$tmp"
  cat > "$tmp/src/App.tsx" <<'TSX'
export function App() {
  alert("Saved");
  return null;
}
TSX
  run_gate "$tmp"
  ck "hardcoded dialog string -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_i18n "$tmp"
  cat > "$tmp/locales/fr.json" <<'JSON'
{
  "save": "Enregistrer"
}
JSON
  run_gate "$tmp"
  ck "missing locale key -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_i18n "$tmp"
  WALTEUR_I18N=off run_gate "$tmp"
  rc=$?
  [ "$(verdict "$tmp")" = "SKIP" ] || rc=99
  ck "bypass writes SKIP report -> PASS" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_valid_i18n "$tmp"
  touch "$tmp/walteur-kit/PAUSED"
  run_gate "$tmp"
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "i18n-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

# ── bypass + pause ────────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_I18N:-on}" = "off" ] && {
  echo "i18n-lint: bypassed (WALTEUR_I18N=off)." >&2
  write_simple_report "SKIP" "bypassed via WALTEUR_I18N=off"
  exit 0
}

# ── tool guard (detect-or-loud-SKIP) ─────────────────────────────────────────
for t in grep awk sed jq find; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR i18n-lint SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
    jq -n --arg ts "$TS" --arg t "$t" \
      '{verdict:"SKIP", ts:$ts, gate:"i18n", reason:($t+" not installed")}' > "$REPORT" 2>/dev/null \
      || printf '{"verdict":"SKIP","ts":"%s","gate":"i18n","reason":"%s not installed"}\n' "$TS" "$t" > "$REPORT"
    exit 0
  fi
done

PRUNE=( '(' -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/vendor/*' ')' -prune -o )

# ── APPLICABILITY: detect an i18n framework ──────────────────────────────────
applicable=0
why=""

# (a) package.json dependency
if [ -f "$ROOT/package.json" ]; then
  if grep -qE '"(i18next|react-i18next|react-intl|vue-i18n|next-intl|@lingui/[a-z-]+|svelte-i18n|@formatjs/[a-z-]+|formatjs|intl-messageformat)"[[:space:]]*:' "$ROOT/package.json" 2>/dev/null; then
    applicable=1; why="i18n dependency in package.json"
  fi
fi

# (b) locale / translations directory
if [ "$applicable" -eq 0 ]; then
  d="$(find "$ROOT" "${PRUNE[@]}" -type d \( -iname 'locales' -o -iname 'lang' -o -iname 'i18n' -o -iname 'translations' \) -print 2>/dev/null | head -n1)"
  [ -n "$d" ] && { applicable=1; why="locale/translations directory present"; }
fi

# (c) gettext .po/.pot files
if [ "$applicable" -eq 0 ]; then
  p="$(find "$ROOT" "${PRUNE[@]}" -type f \( -name '*.po' -o -name '*.pot' \) -print 2>/dev/null | head -n1)"
  [ -n "$p" ] && { applicable=1; why="gettext .po/.pot catalog present"; }
fi

# (d) messages.json / messages.*.json catalog
if [ "$applicable" -eq 0 ]; then
  m="$(find "$ROOT" "${PRUNE[@]}" -type f \( -name 'messages.json' -o -name 'messages.*.json' \) -print 2>/dev/null | head -n1)"
  [ -n "$m" ] && { applicable=1; why="messages.json catalog present"; }
fi

# (e) source actually uses an i18n API
if [ "$applicable" -eq 0 ]; then
  s="$(grep -rlEi --include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx' --include='*.vue' --include='*.svelte' \
        'useTranslation|FormattedMessage|from[[:space:]]+["'\'']i18next["'\'']|from[[:space:]]+["'\'']react-i18next["'\'']|from[[:space:]]+["'\'']vue-i18n["'\'']|\$gettext|i18n\.t\(|useIntl\(' \
        "$ROOT" 2>/dev/null \
        | grep -vE '/(node_modules|\.git|dist|build|\.next|coverage|vendor)/' | head -n1)"
  [ -n "$s" ] && { applicable=1; why="source uses an i18n API"; }
fi

if [ "$applicable" -eq 0 ]; then
  echo "i18n-lint: no i18n framework detected (no i18next/react-intl/vue-i18n/gettext/.po/messages.json/locales) — gate not applicable." >&2
  jq -n --arg ts "$TS" '{verdict:"NOT_APPLICABLE", ts:$ts, gate:"i18n", reason:"no i18n framework present"}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"i18n"}\n' "$TS" > "$REPORT"
  exit 0
fi

echo "WALTEUR i18n-lint @ $ROOT (applicable: $why)" >&2

# ── findings accumulator ─────────────────────────────────────────────────────
declare -a FINDINGS_JSON=()
add() { # $1=file  $2=line  $3=rule  $4=message
  FINDINGS_JSON+=("$(jq -n --arg f "$1" --argjson ln "$2" --arg r "$3" --arg m "$4" \
    '{file:$f, line:$ln, rule:$r, message:$m}')")
}

# ── C1: hardcoded user-facing strings in components ─────────────────────────
# Collect component / source files.
COMP_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && COMP_FILES+=("$f")
done < <(find "$ROOT" "${PRUNE[@]}" -type f \( -name '*.jsx' -o -name '*.tsx' -o -name '*.vue' -o -name '*.svelte' \) -print 2>/dev/null)

# A JSX text literal is meaningful only if it contains a letter (skip "{" "}" punctuation, numbers,
# and whitespace-only nodes). We flag a line that has a `>WORD...<` text node where WORD starts with
# a letter AND the line does NOT contain an i18n wrapper token (t( / i18n / FormattedMessage / $t /
# Trans / formatMessage / __( ). awk does the multi-condition logic deterministically.
scan_jsx() { # $1=file  $2=rel
  awk -v rel="$2" '
    {
      line=$0; low=tolower(line)
      # already-wrapped lines are exempt
      if (low ~ /t\(/ || low ~ /i18n/ || low ~ /formattedmessage/ || low ~ /\$t\(/ || \
          low ~ /<trans/ || low ~ /formatmessage/ || low ~ /__\(/ || low ~ /usetranslation/) next
      # JSX text node: ">  Some Text  <"  with a letter after >
      # strip self-closing/opening-only noise by requiring a closing < after the text.
      tmp=line
      while (match(tmp, />[^<>{}]*</)) {
        seg=substr(tmp, RSTART+1, RLENGTH-2)         # between > and <
        # meaningful if it has a letter and is not purely an entity/var
        gsub(/^[ \t]+|[ \t]+$/, "", seg)
        if (seg ~ /[A-Za-z]/ && seg !~ /^&[a-z]+;$/ && length(seg) >= 2) {
          # ignore segments that are clearly code-ish (contain = or ; or () )
          if (seg !~ /[=;]/ && seg !~ /\(\)/) {
            printf "%d\t%s\n", NR, seg
            break
          }
        }
        tmp=substr(tmp, RSTART+RLENGTH-1)             # advance past this match
      }
    }' "$1" 2>/dev/null
}

# NOTE: an applicable project may have zero component files (e.g. gettext .po-only or a
# messages.json-only catalog) — under `set -u` an empty-array expansion errors, so guard it.
for file in ${COMP_FILES[@]+"${COMP_FILES[@]}"}; do
  rel="${file#"$ROOT"/}"

  # JSX text literals (jsx/tsx). .vue/.svelte template text is harder to disambiguate from markup;
  # we still scan them but the same wrapper-exemption applies.
  while IFS=$'\t' read -r ln seg; do
    [ -z "$ln" ] && continue
    add "$rel" "$ln" "hardcoded-jsx-text" "User-facing text not in i18n catalog: \"$seg\""
  done < <(scan_jsx "$file" "$rel")

  # alert/confirm/toast with a bare string literal (not t(...))
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//')"
    add "$rel" "$ln" "hardcoded-dialog-string" "Dialog text not in i18n catalog: $txt"
  done < <(grep -nE '(alert|confirm|toast)\([[:space:]]*["'\''][^"'\'']*[A-Za-z]' "$file" 2>/dev/null \
            | grep -vE '(alert|confirm|toast)\([[:space:]]*[A-Za-z_$]+t\(' || true)
done

# ── C2: locale catalog drift (missing keys vs default locale) ───────────────
# Find JSON locale catalogs grouped under locale dirs / by language code. Default locale = en* if
# present, else the alphabetically-first. Compare flattened key sets; any key in default missing
# from another locale is a violation.
LOCALE_JSON=()
while IFS= read -r f; do
  [ -n "$f" ] && LOCALE_JSON+=("$f")
done < <(find "$ROOT" "${PRUNE[@]}" -type f \( \
            -path '*/locales/*.json' -o -path '*/lang/*.json' -o -path '*/i18n/*.json' -o -path '*/translations/*.json' \
            -o -name 'messages.*.json' \) -print 2>/dev/null)

# flatten a JSON object's leaf key-paths, one per line; non-object/invalid => nothing
flatten_keys() {
  jq -r '
    paths(scalars) as $p | $p | map(tostring) | join(".")
  ' "$1" 2>/dev/null || true
}

# locale code from a filename/dir:  locales/en.json -> en ; locales/en/foo.json -> en ;
# messages.fr.json -> fr ; lang/fr-FR.json -> fr-FR
locale_code() {
  base="$(basename "$1")"
  case "$base" in
    messages.*.json) echo "${base#messages.}" | sed 's/\.json$//'; return;;
  esac
  parent="$(basename "$(dirname "$1")")"
  case "$parent" in
    locales|lang|i18n|translations) echo "${base%.json}";;        # locales/en.json
    *) echo "$parent";;                                            # locales/en/foo.json
  esac
}

if [ "${#LOCALE_JSON[@]}" -ge 2 ]; then
  # group keys by locale code into temp files
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/walteur-i18n.XXXXXX")"; trap 'rm -rf "$WORKDIR"' EXIT
  locales_seen=""
  for f in "${LOCALE_JSON[@]}"; do
    code="$(locale_code "$f")"
    [ -z "$code" ] && continue
    flatten_keys "$f" >> "$WORKDIR/$code.keys" 2>/dev/null
    case " $locales_seen " in *" $code "*) :;; *) locales_seen="$locales_seen $code";; esac
  done
  locales_seen="$(echo "$locales_seen" | sed 's/^ //')"

  # pick default: an en* code if present, else first alphabetical
  default_code=""
  for c in $locales_seen; do case "$c" in en|en-*|en_*) default_code="$c"; break;; esac; done
  if [ -z "$default_code" ]; then
    default_code="$(echo "$locales_seen" | tr ' ' '\n' | sort | head -n1)"
  fi

  if [ -n "$default_code" ] && [ -f "$WORKDIR/$default_code.keys" ]; then
    sort -u "$WORKDIR/$default_code.keys" > "$WORKDIR/_default.sorted"
    for c in $locales_seen; do
      [ "$c" = "$default_code" ] && continue
      [ -f "$WORKDIR/$c.keys" ] || { touch "$WORKDIR/$c.keys"; }
      sort -u "$WORKDIR/$c.keys" > "$WORKDIR/_cmp.sorted"
      # keys present in default but missing in this locale
      missing="$(comm -23 "$WORKDIR/_default.sorted" "$WORKDIR/_cmp.sorted")"
      if [ -n "$missing" ]; then
        cnt="$(printf '%s\n' "$missing" | grep -c . || true)"
        sample="$(printf '%s\n' "$missing" | head -n5 | paste -sd ',' -)"
        add "locale:$c" 0 "missing-locale-keys" \
          "Locale '$c' is missing $cnt key(s) present in default '$default_code' (e.g. $sample)"
      fi
    done
  fi
fi

# ── verdict ──────────────────────────────────────────────────────────────────
SCANNED="${#COMP_FILES[@]}"
if [ "${#FINDINGS_JSON[@]}" -eq 0 ]; then
  jq -n --arg ts "$TS" --arg why "$why" --argjson scanned "$SCANNED" \
    '{verdict:"PASS", ts:$ts, gate:"i18n", applicable_because:$why, files_scanned:$scanned, details:[]}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"PASS","ts":"%s","gate":"i18n"}\n' "$TS" > "$REPORT"
  echo "i18n-lint: PASS — applicable ($why), $SCANNED component file(s) scanned, zero hardcoded strings / catalog drift." >&2
  exit 0
fi

FIND_JSON="$(printf '%s\n' "${FINDINGS_JSON[@]}" | jq -s '.')"
jq -n --arg ts "$TS" --arg why "$why" --argjson scanned "$SCANNED" --argjson findings "$FIND_JSON" \
  '{verdict:"FAIL", ts:$ts, gate:"i18n", applicable_because:$why, files_scanned:$scanned,
    finding_count:($findings|length), details:$findings}' > "$REPORT" 2>/dev/null \
  || printf '{"verdict":"FAIL","ts":"%s","gate":"i18n"}\n' "$TS" > "$REPORT"

echo "i18n-lint: FAIL — ${#FINDINGS_JSON[@]} finding(s):" >&2
for f in "${FINDINGS_JSON[@]}"; do
  file="$(printf '%s' "$f" | jq -r '.file')"
  line="$(printf '%s' "$f" | jq -r '.line')"
  rule="$(printf '%s' "$f" | jq -r '.rule')"
  msg="$(printf '%s' "$f" | jq -r '.message')"
  echo "  [$rule] $file:$line  $msg" >&2
done
exit 2
