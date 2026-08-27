#!/usr/bin/env bash
# non-generic-design-gate.sh
#
# WHY THIS EXISTS
#   "Avoid generic-looking apps" was, until now, an ASSERTION in this harness — prose in a skill telling
#   an agent to have taste. Nothing measured it. This gate makes it a MEASUREMENT by delegating to
#   pbakaus/impeccable (Apache-2.0), whose detector engine carries 65 machine-identified anti-pattern
#   rules and runs with NO LLM and NO API KEY. Deterministic, offline, repeatable — the only kind of
#   design check that belongs in a fail-closed gate.
#
# WHY THIS PARSES THE COUNT RATHER THAN TRUSTING THE EXIT CODE
#   To be accurate about the upstream tool: `impeccable detect` IS correctly fail-closed. Measured
#   directly, with no pipe in the way: a slop fixture returns rc=2 and clean markup returns rc=0.
#   (An earlier draft of this header claimed it returned 0 with findings. That was wrong — it came from
#   reading $? after piping the command into `tail`, which reports tail's status, not the tool's. The
#   same mistake is what makes Ralph's loop unable to see a crashed agent, so it is worth naming twice.)
#
#   This gate still parses the finding COUNT and the per-rule ids, for three reasons a boolean cannot
#   serve: a WALTEUR_SLOP_MAX threshold above zero needs a number; the report has to name WHICH rules
#   fired so the finding is actionable; and an aggregate across many files needs a sum. The exit code is
#   used as a cross-check, and output this gate cannot parse is treated as a failure to VERIFY rather
#   than as a pass — an unreadable result is not a clean result.
#
# CONTRACT
#   detect-or-LOUD-SKIP. No impeccable checkout, no node, or no UI files -> SKIP with the reason stated,
#   never a silent pass. Findings above WALTEUR_SLOP_MAX (default 0) -> exit 2.
#
# CONFIG
#   WALTEUR_IMPECCABLE   path to the impeccable checkout (default: ~/AI-Brain-build/impeccable)
#   WALTEUR_SLOP_MAX     max tolerated anti-patterns before failing (default 0)
#   WALTEUR_UI_GLOB_DIR  directory to scan (default: auto-detect, repo root)
#
# USAGE
#   bash walteur-kit/hooks/non-generic-design-gate.sh [--selftest|--help]

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/non-generic-design-report.json"
IMPECCABLE="${WALTEUR_IMPECCABLE:-$HOME/AI-Brain-build/impeccable}"
SLOP_MAX="${WALTEUR_SLOP_MAX:-0}"
TS="$(date -u +%FT%TZ)"

have() { command -v "$1" >/dev/null 2>&1; }

case "${1:-}" in --help|-h) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

write_report() {
  local verdict="$1" reason="$2" count="${3:-0}" findings="${4:-[]}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" --argjson n "$count" --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"non-generic-design", reason:$r, anti_patterns:$n, findings:$f,
        engine:"pbakaus/impeccable (Apache-2.0) detector — deterministic, no LLM"}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"non-generic-design","reason":"%s","anti_patterns":%s}\n' \
    "$verdict" "$TS" "$reason" "$count" > "$REPORT" 2>/dev/null || true
}

cli_path() { printf '%s/cli/bin/cli.js' "$IMPECCABLE"; }

# Echo "<count>\t<compact-json-findings>" for a target. Count -1 means "could not parse".
scan() {
  local target="$1" out count rules
  out="$(node "$(cli_path)" detect "$target" 2>&1)" || true
  # The engine prints "N anti-patterns found." / "1 anti-pattern found." on success, nothing when clean.
  if printf '%s' "$out" | grep -qE '[0-9]+ anti-pattern'; then
    count="$(printf '%s' "$out" | sed -n 's/.*[^0-9]\{0,\}\([0-9]\{1,\}\) anti-pattern.*/\1/p' | tail -1)"
  elif [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
    count=0
  else
    # Output present but no recognisable tally: refuse to guess.
    count=-1
  fi
  # The detector emits TWO finding formats and this parser must accept both. For .html it prints
  #   "  [gradient-text] background-clip: text + gradient"
  # but for .tsx/.jsx — the dominant file type in any real build — it prefixes the line number:
  #   "  line 5: [side-tab] borderLeft:\"4px solid"
  # Panel #12: only the first form was matched, so a FAIL on a React file reported findings:[] and named no
  # rule at all — an un-actionable failure. The .html-only selftest fixture is why the "findings carry
  # machine rule ids" assertion passed anyway; a .tsx fixture now exercises the format that actually ships.
  rules="$(printf '%s' "$out" \
    | sed -n -e 's/^ *\[\([a-z0-9-]\{1,\}\)\] *\(.*\)$/\1	\2/p' \
             -e 's/^ *line \([0-9]\{1,\}\): *\[\([a-z0-9-]\{1,\}\)\] *\(.*\)$/\2	line \1: \3/p' \
    | { if have jq; then jq -R -s -c 'split("\n")|map(select(length>0))|map(split("\t"))|map({rule:.[0], detail:(.[1]//"")})'; else printf '[]'; fi; })"
  printf '%s\t%s\n' "${count:-0}" "${rules:-[]}"
}

selftest() {
  local pass=0 fail=0
  t() { if eval "$2"; then printf '  ok   - %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL - %s\n' "$1"; fail=$((fail+1)); fi; }
  printf 'non-generic-design-gate selftest\n'

  if [ ! -f "$(cli_path)" ] || ! have node; then
    printf '  SKIP - impeccable checkout or node absent (LOUD SKIP, not a pass)\n'; return 0
  fi
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/ngd.XXXXXX")" || return 2
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # A known-slop fixture: gradient text, zero-offset colored glow, thick colored border-left.
  cat > "$tmp/slop.html" <<'EOF'
<div style="background:linear-gradient(90deg,#a855f7,#6366f1);-webkit-background-clip:text;color:transparent">Headline</div>
<div style="box-shadow:0 0 40px rgba(168,85,247,.6)">glow</div>
<div style="border-left:4px solid #a855f7">side tab</div>
EOF
  # A clean fixture: plain semantic markup with none of the tells.
  cat > "$tmp/clean.html" <<'EOF'
<main><h1>Quarterly report</h1><p style="max-width:68ch;padding:16px">Body copy at a readable measure.</p></main>
EOF

  # Panel #12: a .tsx fixture, because .tsx is what real builds are made of and the detector formats its
  # findings differently there ("line N: [rule] …"). Without this the rule-id assertion below was only ever
  # exercised on .html and the parser's blind spot on the dominant file type stayed invisible.
  cat > "$tmp/slop.tsx" <<'EOF'
export const Hero = () => (
  <aside style={{borderLeft:"4px solid #a855f7"}}>side tab</aside>
);
EOF

  local slop_n clean_n slop_rules tsx_n tsx_rules
  slop_n="$(scan "$tmp/slop.html" | cut -f1)"
  slop_rules="$(scan "$tmp/slop.html" | cut -f2)"
  clean_n="$(scan "$tmp/clean.html" | cut -f1)"
  tsx_n="$(scan "$tmp/slop.tsx" | cut -f1)"
  tsx_rules="$(scan "$tmp/slop.tsx" | cut -f2)"

  t "the detector BITES on known slop (>0 findings)"        '[ "$slop_n" -gt 0 ]'
  t "the detector does NOT fire on clean markup (0 findings)" '[ "$clean_n" -eq 0 ]'
  t "findings carry machine rule ids so they are actionable" 'printf "%s" "$slop_rules" | jq -e "length > 0 and (.[0].rule|length > 0)" >/dev/null'
  t "gradient-text specifically is caught"                    'printf "%s" "$slop_rules" | jq -e "map(.rule)|index(\"gradient-text\") != null" >/dev/null'
  t ".tsx findings are counted at all"                        '[ "$tsx_n" -gt 0 ]'
  t ".tsx rule ids PARSE from the line-prefixed format (was findings:[] pre-panel-12)" \
     'printf "%s" "$tsx_rules" | jq -e "length > 0 and (.[0].rule|test(\"^[a-z0-9-]+$\"))" >/dev/null'
  t ".tsx rule count matches the .tsx finding count (no silently dropped findings)" \
     '[ "$(printf "%s" "$tsx_rules" | jq -r "length")" -eq "$tsx_n" ]'
  # Pin the upstream engine's real contract, measured with no pipe in the way. If a future impeccable
  # release changes this, these two assertions fail loudly instead of the gate silently mis-reading it.
  local slop_rc clean_rc
  node "$(cli_path)" detect "$tmp/slop.html"  >/dev/null 2>&1; slop_rc=$?
  node "$(cli_path)" detect "$tmp/clean.html" >/dev/null 2>&1; clean_rc=$?
  t "engine exits 2 on findings (upstream is correctly fail-closed)"  '[ "$slop_rc" -eq 2 ]'
  t "engine exits 0 on clean markup"                                  '[ "$clean_rc" -eq 0 ]'
  t "count and exit code AGREE on slop (cross-check, not redundancy)"  '[ "$slop_n" -gt 0 ] && [ "$slop_rc" -ne 0 ]'
  t "unparseable output is treated as -1 (refuse to guess), never as 0" 'grep -q "count=-1" "'"$0"'"'

  printf 'non-generic-design-gate selftest: %d/%d passed\n' "$pass" "$((pass+fail))"
  [ "$fail" -eq 0 ] || return 2
  return 0
}

[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

have node || { write_report "SKIP" "node absent — cannot run the impeccable detector (LOUD SKIP, not a pass)"; \
  echo "non-generic-design: SKIP (no node)"; exit 0; }
[ -f "$(cli_path)" ] || { write_report "SKIP" "impeccable checkout not found at $IMPECCABLE — set WALTEUR_IMPECCABLE (LOUD SKIP, not a pass)"; \
  echo "non-generic-design: SKIP (no impeccable at $IMPECCABLE)"; exit 0; }

SCAN_DIR="${WALTEUR_UI_GLOB_DIR:-$ROOT}"
# Only scan real UI surfaces; skip vendored trees.
#
# NOTE: no `mapfile`. macOS ships /bin/bash 3.2, where mapfile does not exist — it failed here with
# "mapfile: command not found" followed by "targets: unbound variable" under `set -u`, i.e. rc=1 rather
# than a clean verdict. Every hook in this kit has to run on stock macOS bash, so the file list goes to
# a temp file and is read with a plain while-read loop.
TARGETS_FILE="$(mktemp "${TMPDIR:-/tmp}/ngd-targets.XXXXXX")" || {
  write_report "SKIP" "cannot create a temp file for the scan list (LOUD SKIP, not a pass)"; exit 0; }
trap 'rm -f "$TARGETS_FILE"' EXIT
find "$SCAN_DIR" \
  -path '*/node_modules' -prune -o -path '*/.git' -prune -o -path '*/dist' -prune -o \
  \( -name '*.html' -o -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' \) -type f -print 2>/dev/null \
  | head -40 > "$TARGETS_FILE"

n_targets="$(grep -c . "$TARGETS_FILE" 2>/dev/null || printf '0')"
if [ "$n_targets" -eq 0 ]; then
  write_report "NOT_APPLICABLE" "no UI files (.html/.tsx/.jsx/.vue/.svelte) found under $SCAN_DIR — not a UI build"
  echo "non-generic-design: NOT_APPLICABLE (no UI files)"; exit 0
fi

total=0; unparsed=0; all='[]'
while IFS= read -r f; do
  [ -n "$f" ] || continue
  line="$(scan "$f")"
  n="$(printf '%s' "$line" | cut -f1)"
  r="$(printf '%s' "$line" | cut -f2)"
  if [ "$n" = "-1" ]; then unparsed=$((unparsed+1)); continue; fi
  total=$((total + n))
  if [ "$n" -gt 0 ] && have jq; then
    all="$(printf '%s' "$all" | jq -c --arg file "${f#$ROOT/}" --argjson r "$r" '. + [{file:$file, findings:$r}]')"
  fi
done < "$TARGETS_FILE"

if [ "$unparsed" -gt 0 ]; then
  write_report "FAIL" "$unparsed file(s) produced detector output this gate could not parse — refusing to report a pass it cannot verify" "$total" "$all"
  echo "non-generic-design verdict: FAIL — $unparsed unparseable scan(s)" >&2; exit 2
fi

if [ "$total" -gt "$SLOP_MAX" ]; then
  write_report "FAIL" "$total anti-pattern(s) across $n_targets UI file(s), max allowed $SLOP_MAX — generic-UI tells present" "$total" "$all"
  echo "non-generic-design verdict: FAIL — $total anti-pattern(s) > max $SLOP_MAX -> $REPORT" >&2
  have jq && printf '%s' "$all" | jq -r '.[]|.file as $f|.findings[]|"  " + $f + ": [" + .rule + "]"' >&2
  exit 2
fi

write_report "PASS" "0 anti-patterns across $n_targets UI file(s) scanned by the impeccable detector" "$total" '[]'
echo "non-generic-design verdict: PASS ($n_targets UI file(s), $total anti-patterns)"
exit 0
