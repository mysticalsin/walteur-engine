#!/usr/bin/env bash
# WALTEUR docrun — ZERO-DEP HARD gate. Documented commands must be syntactically runnable.
# Extracts every fenced ```bash / ```sh / ```shell / ```console block across the repo's *.md
# files and checks each with `bash -n` (parse-only — NOTHING is executed). A real syntax error
# in any documented block is a real violation => exit 2. Clean => exit 0.
#
# Why this is a HARD gate: a README/runbook that ships a copy-paste block which does not even
# PARSE is a lie to the reader. `bash -n` is always present (it IS bash) so there is no
# missing-tool SKIP path — the only honest non-fail outcomes are NOT_APPLICABLE (no markdown,
# or no fenced shell blocks) and an explicit per-block skip marker.
#
# Skip markers (honor either, on the fence line or the line directly above it):
#   ```bash  walteur:skip        — skip this one block (e.g. illustrative pseudo-shell)
#   <!-- walteur:skip -->        — on the line immediately preceding the fence
# `console` blocks: lines beginning with a prompt ($ or #) have the prompt stripped before the
# parse check; output lines (no prompt) in a console block are ignored — that is how console
# transcripts are written.
#
# Tools used: bash, grep, awk, sed, find, jq (all zero-dep core). jq only formats the report;
# if jq is somehow absent the gate still runs and writes a plain-JSON report by hand.
# Report: walteur-kit/docrun-report.json {verdict, ts, gate, blocks_checked, blocks_skipped,
#          failures:[{file,fence_line,lang,error}]}.
# Bypass: WALTEUR_DOCRUN=off.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "docrun - ZERO-DEP HARD gate. Documented commands must be syntactically runnable."
  printf '%s\n' "usage: bash docrun.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/docrun-report.json - fix recipes: walteur-kit/REMEDIATION.md (## docrun)"
  printf '%s\n' "bypass: WALTEUR_DOCRUN=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/docrun-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  if have jq; then
    jq -n --arg v "$1" --arg ts "$TS" --arg reason "$2" \
          --argjson checked "$3" --argjson skipped "$4" --argjson fails "$5" \
      '{verdict:$v, ts:$ts, gate:"docrun", reason:$reason,
        blocks_checked:$checked, blocks_skipped:$skipped, failures:$fails}' > "$REPORT"
  else
    # Hand-rolled JSON fallback (jq absent). Failures array passed already-formed as compact JSON.
    printf '{"verdict":"%s","ts":"%s","gate":"docrun","reason":"%s","blocks_checked":%s,"blocks_skipped":%s,"failures":%s}\n' \
      "$1" "$TS" "$2" "$3" "$4" "$5" > "$REPORT"
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

  if ! have jq; then
    echo "docrun selftest SKIP - jq not installed."
    return 0
  fi

  echo "docrun selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/docrun-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no markdown -> NOT_APPLICABLE exit" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE" and .blocks_checked == 0' "$tmp/walteur-kit/docrun-report.json" >/dev/null 2>&1
  ck "no markdown report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/docrun-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/README.md" <<'MD'
# Docrun Good Fixture

```bash
echo ok
```

<!-- walteur:skip -->
```bash
if [
```

```console
$ echo ok
ok
```
MD
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "passing markdown blocks + skipped bad block -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .blocks_checked == 2 and .blocks_skipped == 1' "$tmp/walteur-kit/docrun-report.json" >/dev/null 2>&1
  ck "PASS report records checked and skipped blocks" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/docrun-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  cat > "$tmp/BAD.md" <<'MD'
# Docrun Bad Fixture

```bash
if [
```
MD
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "bad documented shell block -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.failures | length) == 1' "$tmp/walteur-kit/docrun-report.json" >/dev/null 2>&1
  ck "FAIL report records failing block" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/docrun-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '```bash\nif [\n```\n' > "$tmp/BAD.md"
  WALTEUR_ROOT="$tmp" WALTEUR_DOCRUN=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/docrun-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/docrun-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "docrun selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_DOCRUN:-on}" = "off" ] && {
  echo "docrun: bypassed (WALTEUR_DOCRUN=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_DOCRUN=off" 0 0 '[]'
  exit 0
}

# JSON-escape a string for hand-built objects (used for failure detail).
json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\r\n'; }

# ── collect markdown files (skip .git, node_modules, vendored dirs) ──────────────
MD_LIST="$(find "$ROOT" \
  \( -path "$ROOT/.git" -o -path "$ROOT/node_modules" -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/vendor' \) -prune -o \
  \( -iname '*.md' -o -iname '*.markdown' \) -type f -print 2>/dev/null | LC_ALL=C sort)"

if [ -z "$MD_LIST" ]; then
  echo "docrun: no markdown files found — gate not applicable." >&2
  write_report "NOT_APPLICABLE" "no markdown files present" 0 0 '[]'
  exit 0
fi

CHECKED=0
SKIPPED=0
FAILED=0
FAIL_OBJS=""   # accumulated compact JSON objects, newline-separated

# Per-file extraction via awk: emits a stream of records. For each fenced shell block it prints:
#   @@BLOCK <fence_line> <lang> <skip:0|1>
#   ...body lines (already prompt-stripped for console)...
#   @@END
# awk owns the fence state machine so quoting stays sane.
extract() {
  awk '
    function lower(s){ return tolower(s) }
    BEGIN { inblk=0; prevskip=0 }
    {
      raw=$0
      # Track a skip marker on the line just before a fence: <!-- walteur:skip -->
      if (inblk==0) {
        if (raw ~ /walteur:skip/ && raw ~ /^[[:space:]]*<!--/) { pending_skip=1; next }
      }
    }
    # Opening / closing fence detection. A fence is ``` or ~~~ at (optional ws) line start.
    /^[[:space:]]*(```|~~~)/ {
      fence=raw
      sub(/^[[:space:]]*/, "", fence)
      marker=substr(fence,1,3)
      rest=substr(fence,4)
      if (inblk==0) {
        # opening fence — parse info string (language + flags)
        gsub(/^[ \t]+|[ \t]+$/, "", rest)
        n=split(rest, parts, /[[:space:]]+/)
        lang=lower(parts[1])
        thisskip=0
        if (pending_skip==1) thisskip=1
        for (i=2;i<=n;i++) if (lower(parts[i])=="walteur:skip" || parts[i]=="walteur:skip") thisskip=1
        # also allow walteur:skip glued in the info string anywhere
        if (rest ~ /walteur:skip/) thisskip=1
        if (lang=="bash"||lang=="sh"||lang=="shell"||lang=="console"||lang=="shell-session") {
          inblk=1; blklang=lang; blkskip=thisskip; blkfence=marker; fence_ln=NR
          print "@@BLOCK " NR " " blklang " " blkskip
        }
        pending_skip=0
        next
      } else {
        # candidate closing fence — must match the opening marker family
        if (substr(fence,1,3)==blkfence) {
          print "@@END"
          inblk=0
          next
        }
        # different marker inside a block: treat as body
      }
    }
    {
      if (inblk==1) {
        line=raw
        if (blklang=="console" || blklang=="shell-session") {
          # strip a leading prompt: "$ ", "# ", "user@host:~$ " etc. Lines without a prompt are
          # transcript OUTPUT — emit a harmless no-op so bash -n still parses, by blanking them.
          if (line ~ /^[[:space:]]*[#$][[:space:]]?/) {
            sub(/^[[:space:]]*[#$][[:space:]]?/, "", line)
          } else if (line ~ /^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+.*[#$][[:space:]]?/) {
            sub(/^.*[#$][[:space:]]?/, "", line)
          } else {
            line=""   # output line — drop from the script under test
          }
        }
        print "  " line
      } else {
        pending_skip=0
      }
    }
  ' "$1"
}

# Process one markdown file: walk the extracted record stream, run bash -n per block.
process_file() {
  f="$1"
  stream="$(extract "$f")"
  [ -z "$stream" ] && return 0

  in_body=0
  fence_line=0
  lang=""
  skipflag=0
  body=""
  # Read the stream line by line. Keep a 2-space indent on body lines so we can strip it back.
  while IFS= read -r rec; do
    case "$rec" in
      "@@BLOCK "*)
        # finalize nothing here; just open
        set -- $rec
        fence_line="$2"; lang="$3"; skipflag="$4"
        in_body=1; body=""
        ;;
      "@@END")
        in_body=0
        if [ "$skipflag" = "1" ]; then
          SKIPPED=$((SKIPPED+1))
          echo "  skip — $f:$fence_line ($lang, walteur:skip)" >&2
          continue
        fi
        CHECKED=$((CHECKED+1))
        # Run parse-only check. bash -n NEVER executes; reads script from stdin.
        if errout="$(printf '%s' "$body" | bash -n /dev/stdin 2>&1)"; then
          : # clean
        else
          FAILED=$((FAILED+1))
          msg="$(json_esc "$errout")"
          obj="$(printf '{"file":"%s","fence_line":%s,"lang":"%s","error":"%s"}' \
                 "$(json_esc "$f")" "$fence_line" "$(json_esc "$lang")" "$msg")"
          FAIL_OBJS="$FAIL_OBJS$obj
"
          echo "  FAIL — $f:$fence_line ($lang) syntax error:" >&2
          printf '%s\n' "$errout" | sed 's/^/         /' >&2
        fi
        ;;
      "  "*)
        if [ "$in_body" = "1" ]; then
          body="$body${rec#  }
"
        fi
        ;;
    esac
  done <<EOF
$stream
EOF
}

echo "WALTEUR docrun @ $ROOT — checking documented shell blocks across *.md" >&2
while IFS= read -r f; do
  [ -z "$f" ] && continue
  process_file "$f"
done <<EOF
$MD_LIST
EOF

# ── assemble failures JSON array ─────────────────────────────────────────────────
if [ -n "$FAIL_OBJS" ]; then
  if have jq; then
    FAILS_JSON="$(printf '%s' "$FAIL_OBJS" | grep -v '^[[:space:]]*$' | jq -s '.')"
  else
    # join newline-separated objects into an array by hand
    joined="$(printf '%s' "$FAIL_OBJS" | grep -v '^[[:space:]]*$' | paste -sd, -)"
    FAILS_JSON="[$joined]"
  fi
else
  FAILS_JSON='[]'
fi

if [ "$CHECKED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]; then
  echo "docrun: markdown present but no fenced bash/sh/console blocks — gate not applicable." >&2
  write_report "NOT_APPLICABLE" "no fenced shell blocks in any markdown" 0 0 '[]'
  exit 0
fi

if [ "$FAILED" -gt 0 ]; then
  write_report "FAIL" "$FAILED documented shell block(s) failed bash -n" "$CHECKED" "$SKIPPED" "$FAILS_JSON"
  echo "docrun verdict: FAIL — $FAILED of $CHECKED checked block(s) have syntax errors (skipped $SKIPPED) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "all $CHECKED documented shell block(s) parse cleanly" "$CHECKED" "$SKIPPED" '[]'
echo "docrun verdict: PASS — $CHECKED block(s) parse cleanly (skipped $SKIPPED) -> $REPORT" >&2
exit 0
