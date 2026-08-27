#!/usr/bin/env bash
# WALTEUR skill-quality-gate — HARD gate (intake: addyosmani/agent-skills + ECC plugin-eval static analyzer).
# WALTEUR routes ~190 Org skills "MUST-use-if-applies" — but a skill with no description, no activation
# trigger, or a 900-line body never routes reliably (the model can't tell when to fire it, or drowns in it).
# This gate statically lints every SKILL.md and fails closed when the library's quality composite drops below a
# floor OR any skill is structurally BROKEN (no name/description => unroutable). Anthropic's own guidance: a
# skill description must be specific about WHEN to trigger, and bodies should use progressive disclosure.
#
# Applies when SKILL.md files exist under ROOT (a build's .claude/skills) or WALTEUR_SKILLS_DIR (the library).
# CONTRACT: any BROKEN skill (score<40) OR library composite < floor (default 70) => FAIL exit 2 ·
# no skills => NOT_APPLICABLE · PAUSED => exit 2 · bypass WALTEUR_SKILLQUAL=off · tunable WALTEUR_SKILLQUAL_FLOOR.
# Report: walteur-kit/skill-quality-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "skill-quality-gate - HARD gate (intake: addyosmani/agent-skills + ECC plugin-eval static analyzer)."
  printf '%s\n' "usage: bash skill-quality-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/skill-quality-report.json - fix recipes: walteur-kit/REMEDIATION.md (## skill-quality-gate)"
  printf '%s\n' "bypass: WALTEUR_SKILLQUAL=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/skill-quality-report.json"
FLOOR="${WALTEUR_SKILLQUAL_FLOOR:-70}"
SKILLS_DIR="${WALTEUR_SKILLS_DIR:-$ROOT}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }

skill_files() {
  command -v find >/dev/null 2>&1 || return 0
  find "$SKILLS_DIR" -type d \( -name node_modules -o -name .git \) -prune -o -type f -name 'SKILL.md' -print 2>/dev/null
}

# score one SKILL.md -> "score<TAB>name<TAB>issue,issue"  (perl: self-contained, no fs side effects)
score_skill() {
  perl -0777 -ne '
    my $t = $_;
    my ($fm) = $t =~ /\A---\s*\n(.*?)\n---\s*\n/s;  $fm //= "";
    my $body = $t; $body =~ s/\A---\s*\n.*?\n---\s*\n//s;
    my ($name) = $fm =~ /^name:\s*(.+?)\s*$/m;       $name //= "";
    my ($desc) = $fm =~ /^description:\s*(.+?)\s*$/m; $desc //= "";
    my $blines = ($body =~ tr/\n//);
    my $score = 100; my @iss;
    if ($name eq "") { $score -= 70; push @iss, "MISSING_NAME"; }
    if (length($desc) < 15) { $score -= 70; push @iss, "EMPTY_DESCRIPTION"; }
    else {
      push(@iss, "NO_TRIGGER") , ($score -= 35)
        unless $desc =~ /\b(when|before|after|if|use (this|when|it)|any ?time|whenever|during|for [a-z]|to [a-z]|on [a-z])/i;
      if (length($desc) > 700) { $score -= 10; push @iss, "OVER_CONSTRAINED"; }
    }
    if ($blines > 500) { $score -= 20; push @iss, "BLOATED_BODY"; }
    if ($blines < 5)   { $score -= 25; push @iss, "STUB_BODY"; }
    $score = 0 if $score < 0;
    print "$score\t$name\t", join(",",@iss), "\n";
  ' "$1" 2>/dev/null
}

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; echo '{"verdict":"FAIL","reason":"paused"}' > "$REPORT"; echo "skill-quality-gate: PAUSED -> exit 2"; exit 2; }
  [ "${WALTEUR_SKILLQUAL:-}" = "off" ] && { echo '{"verdict":"SKIP"}' > "$REPORT"; echo "skill-quality-gate: bypassed"; exit 0; }
  if ! have perl || ! have jq; then echo '{"verdict":"SKIP","reason":"need perl+jq"}' > "$REPORT"; echo "skill-quality-gate: SKIP"; exit 0; fi
  local list; list="$(skill_files)"
  if [ -z "$list" ]; then echo '{"verdict":"NOT_APPLICABLE","reason":"no SKILL.md"}' > "$REPORT"; echo "skill-quality-gate: NOT_APPLICABLE"; exit 0; fi

  local n=0 sum=0 broken=0 f line sc nm iss
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    line="$(score_skill "$f")"; [ -n "$line" ] || continue
    IFS=$'\t' read -r sc nm iss <<< "$line"
    case "$sc" in ''|*[!0-9]*) continue ;; esac
    n=$((n+1)); sum=$((sum+sc))
    if [ "$sc" -lt 40 ]; then broken=$((broken+1)); add_finding "${nm:-$(basename "$(dirname "$f")")}" "BROKEN skill (score $sc): ${iss:-?} — $(printf '%s' "$f" | sed "s#$SKILLS_DIR/##")"; fi
  done <<< "$list"

  local avg=0; [ "$n" -gt 0 ] && avg=$((sum / n))
  jq -n --argjson avg "$avg" --argjson n "$n" --argjson broken "$broken" --argjson floor "$FLOOR" --arg ts "$TS" --argjson f "$findings" \
    '{verdict:(if ($broken>0 or $avg<$floor) then "FAIL" else "PASS" end), ts:$ts, gate:"skill-quality", composite:$avg, skills:$n, broken:$broken, floor:$floor, findings:$f}' > "$REPORT" 2>/dev/null

  if [ "$broken" -gt 0 ] || [ "$avg" -lt "$FLOOR" ]; then
    echo "skill-quality-gate: FAIL (composite $avg/100, $broken broken of $n) -> exit 2"
    printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null | head -15 || true
    exit 2
  fi
  echo "skill-quality-gate: PASS (composite $avg/100, $n skills, 0 broken)"
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq || ! have perl; then echo "skill-quality selftest SKIP - need jq+perl."; return 0; fi
  echo "skill-quality-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" WALTEUR_SKILLS_DIR="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  good() { mkdir -p "$1/$2"; printf -- '---\nname: %s\ndescription: Use this when %s — a clear, specific trigger that tells the model exactly when to fire this skill.\n---\n\n# %s\n\n## Overview\nReal body content.\n\n## Steps\n1. do x\n2. do y\n3. verify\n' "$2" "$3" "$2" > "$1/$2/SKILL.md"; }

  # 1. no skills -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillquali.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no SKILL.md -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. all good skills -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillquali.XXXXXX")"; mkdir -p "$t/walteur-kit"; good "$t" alpha "you start a build"; good "$t" beta "you review code"; good "$t" gamma "you ship an artefact"; ck "good library -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. G1 a skill with no description -> BROKEN -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillquali.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/broken"; good "$t" alpha "you start a build"; printf -- '---\nname: broken\n---\n\n# Broken\nbody\nbody\nbody\nbody\nbody\n' > "$t/broken/SKILL.md"; ck "G1 empty-description -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. G2 a skill with no name -> BROKEN -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillquali.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/noname"; good "$t" alpha "you start a build"; printf -- '---\ndescription: Use this when you do something specific and clear enough to route on.\n---\n\n# x\nbody\nbody\nbody\nbody\nbody\n' > "$t/noname/SKILL.md"; ck "G2 missing-name -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. G3 composite below floor (all skills lack triggers) -> FAIL even if not "broken"
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillquali.XXXXXX")"; mkdir -p "$t/walteur-kit"; for s in a b c; do mkdir -p "$t/$s"; printf -- '---\nname: %s\ndescription: This skill does assorted general things across the codebase generally and broadly always.\n---\n\n# %s\nbody\nbody\nbody\nbody\nbody\n' "$s" "$s" > "$t/$s/SKILL.md"; done; ck "G3 no-trigger library below floor -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. FP guard: a long but well-formed skill (good desc+trigger, body 200 lines) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillquali.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/big"; { printf -- '---\nname: big\ndescription: Use this when you need the big workflow — a clear specific trigger condition.\n---\n\n# Big\n'; for i in $(seq 1 200); do echo "line $i"; done; } > "$t/big/SKILL.md"; good "$t" alpha "you start a build"; ck "G4 long well-formed skill -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 7. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillquali.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/noname"; printf -- '---\ndescription: x\n---\nb\n' > "$t/noname/SKILL.md"; WALTEUR_ROOT="$t" WALTEUR_SKILLS_DIR="$t" WALTEUR_SKILLQUAL=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillquali.XXXXXX")"; mkdir -p "$t/walteur-kit"; good "$t" a "you build"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "skill-quality-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
