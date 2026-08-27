#!/usr/bin/env bash
# WALTEUR skill-frontmatter-gate — HARD gate (intake: anthropics/skills skill-creator quick_validate.py).
# skill-quality-gate SCORES skill usefulness; this enforces the structural UPLOAD CONTRACT every SKILL.md must
# satisfy to be a valid, routable skill: a present kebab-case `name` (<=64, no leading/trailing/double hyphen),
# a present `description` (<=1024 chars, no raw < or > which break the loader), and no UNKNOWN frontmatter keys.
# A skill that violates the contract silently fails to load/route — so this fails closed on the BROKEN ones.
#
# Applies when SKILL.md files exist (under ROOT or WALTEUR_SKILLS_DIR). CONTRACT: any skill with a contract
# violation (bad/missing name, missing/oversized/angle-bracket description) => FAIL exit 2 · unknown keys =>
# advisory (reported, non-blocking unless WALTEUR_SKILLFM_STRICT=on) · no skills => NOT_APPLICABLE ·
# PAUSED => exit 2 · bypass WALTEUR_SKILLFM=off. Report: walteur-kit/skill-frontmatter-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "skill-frontmatter-gate - HARD gate (intake: anthropics/skills skill-creator quick_validate.py)."
  printf '%s\n' "usage: bash skill-frontmatter-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/skill-frontmatter-report.json - fix recipes: walteur-kit/REMEDIATION.md (## skill-frontmatter-gate)"
  printf '%s\n' "bypass: WALTEUR_SKILLFM=off (recorded, not free)"
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
REPORT="$KIT/skill-frontmatter-report.json"
SKILLS_DIR="${WALTEUR_SKILLS_DIR:-$ROOT}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

# allowed frontmatter keys: the official set + WALTEUR's documented extensions (creator/phase/type/etc.)
ALLOWED="name description license allowed-tools allowed_tools metadata compatibility version creator phase suggested_stage suggested-stage type priority discipline tags model"

findings='[]'; failures=0; advisories=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" --arg s "$3" '. + [{skill:$c, message:$m, severity:$s}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; [ "$3" = "violation" ] && failures=$((failures+1)) || advisories=$((advisories+1)); }

skill_files() { command -v find >/dev/null 2>&1 || return 0; find "$SKILLS_DIR" -type d \( -name node_modules -o -name .git \) -prune -o -type f -name 'SKILL.md' -print 2>/dev/null; }

check_one() {
  local f="$1" rel out; rel="$(printf '%s' "$f" | sed "s#$SKILLS_DIR/##")"
  have perl || return 0
  # capture FIRST (a `perl | { ... }` pipe runs the block in a SUBSHELL, losing the failures counter).
  out="$(ALLOWED="$ALLOWED" perl -0777 -ne '
    my ($fm) = /\A---\s*\n(.*?)\n---\s*\n/s; $fm //= "";
    if ($fm eq "") { print "NOFM\n"; exit; }
    my ($name) = $fm =~ /^name:\s*(.+?)\s*$/m;       $name //= "";
    my ($desc) = $fm =~ /^description:\s*(.+?)\s*$/m; $desc //= "";
    print "NAME\t$name\n";
    print "DESC\t".length($desc)."\t".($desc=~/[<>]/?"ANGLE":"ok")."\n";
    my %ok = map { $_ => 1 } split /\s+/, $ENV{ALLOWED};
    for my $line (split /\n/, $fm) {
      if ($line =~ /^([A-Za-z][A-Za-z0-9_-]*):/) { print "KEY\t$1\n" unless $ok{$1}; }
    }
  ' "$f" 2>/dev/null)"
  local name="" desclen=0 angle="ok" nofm=0 unknown="" tag a b
  while IFS=$'\t' read -r tag a b; do
    case "$tag" in
      NOFM) nofm=1 ;;
      NAME) name="$a" ;;
      DESC) desclen="$a"; angle="$b" ;;
      KEY) unknown="$unknown $a" ;;
    esac
  done <<< "$out"
  if [ "$nofm" = 1 ]; then add_finding "$rel" "no YAML frontmatter (--- ... ---) — unloadable skill" violation; return; fi
  [ -z "$name" ] && add_finding "$rel" "missing 'name'" violation
  if [ -n "$name" ]; then
    printf '%s' "$name" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' || add_finding "$rel" "name '$name' is not kebab-case ^[a-z0-9-]+\$ (no caps/spaces/underscores, no leading/trailing/double hyphen)" violation
    [ "${#name}" -gt 64 ] && add_finding "$rel" "name '$name' exceeds 64 chars" violation
    printf '%s' "$name" | grep -q -- '--' && add_finding "$rel" "name '$name' has a double hyphen" violation
  fi
  [ "${desclen:-0}" -lt 1 ] && add_finding "$rel" "missing 'description'" violation
  [ "${desclen:-0}" -gt 1024 ] && add_finding "$rel" "description is $desclen chars (>1024 limit)" violation
  [ "$angle" = "ANGLE" ] && add_finding "$rel" "description contains a raw < or > (breaks the loader)" violation
  [ -n "$unknown" ] && add_finding "$rel" "unknown frontmatter key(s):$unknown" advisory
}

main() {
  [ -f "$KIT/PAUSED" ] && { printf '{"verdict":"FAIL","reason":"paused"}\n' > "$REPORT"; echo "skill-frontmatter-gate: PAUSED -> exit 2"; exit 2; }
  [ "${WALTEUR_SKILLFM:-}" = "off" ] && { printf '{"verdict":"SKIP"}\n' > "$REPORT"; echo "skill-frontmatter-gate: bypassed"; exit 0; }
  if ! have perl || ! have jq; then printf '{"verdict":"SKIP","reason":"need perl+jq"}\n' > "$REPORT"; echo "skill-frontmatter-gate: SKIP"; exit 0; fi
  local list; list="$(skill_files)"; [ -z "$list" ] && { printf '{"verdict":"NOT_APPLICABLE"}\n' > "$REPORT"; echo "skill-frontmatter-gate: NOT_APPLICABLE"; exit 0; }
  local f n=0; while IFS= read -r f; do [ -n "$f" ] || continue; n=$((n+1)); check_one "$f"; done <<< "$list"

  jq -n --arg ts "$TS" --argjson n "$n" --argjson fv "$failures" --argjson av "$advisories" --argjson f "$findings" \
    '{verdict:(if $fv>0 then "FAIL" else "PASS" end), ts:$ts, gate:"skill-frontmatter", skills:$n, violations:$fv, advisories:$av, findings:$f}' > "$REPORT" 2>/dev/null

  if [ "$failures" -gt 0 ] || { [ "${WALTEUR_SKILLFM_STRICT:-}" = "on" ] && [ "$advisories" -gt 0 ]; }; then
    echo "skill-frontmatter-gate: FAIL ($failures contract violation(s) of $n skills, $advisories advisory) -> exit 2"
    printf '%s\n' "$findings" | jq -r '.[] | select(.severity=="violation") | "  ✗ " + .skill + ": " + .message' 2>/dev/null | head -12 || true
    exit 2
  fi
  echo "skill-frontmatter-gate: PASS ($n skills conform; $advisories advisory)"
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq || ! have perl; then echo "skill-frontmatter selftest SKIP - need jq+perl."; return 0; fi
  echo "skill-frontmatter-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" WALTEUR_SKILLS_DIR="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  good() { mkdir -p "$1/$2"; printf -- '---\nname: %s\ndescription: %s\ncreator: Tony\nphase: build\n---\n\n# %s\nbody\n' "$2" "$3" "$2" > "$1/$2/SKILL.md"; }

  # 1. no skills -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillfront.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no skills -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. valid skills (kebab name, good desc, known+extension keys) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillfront.XXXXXX")"; mkdir -p "$t/walteur-kit"; good "$t" alpha-skill "Use this when you start a build."; good "$t" beta-two "Use when reviewing code, a clear trigger."; ck "valid skills -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. G1 non-kebab name (caps/underscore) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillfront.XXXXXX")"; mkdir -p "$t/walteur-kit/Bad_Skill"; printf -- '---\nname: Bad_Skill\ndescription: ok desc here long enough.\n---\nx\n' > "$t/walteur-kit/Bad_Skill/SKILL.md"; ck "G1 non-kebab name -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. G2 description with angle brackets -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillfront.XXXXXX")"; mkdir -p "$t/walteur-kit/ang"; printf -- '---\nname: ang\ndescription: use the <Component> when needed here.\n---\nx\n' > "$t/walteur-kit/ang/SKILL.md"; ck "G2 angle-bracket desc -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. G3 missing description -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillfront.XXXXXX")"; mkdir -p "$t/walteur-kit/nodesc"; printf -- '---\nname: nodesc\n---\nx\n' > "$t/walteur-kit/nodesc/SKILL.md"; ck "G3 missing description -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. G4 double hyphen name -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillfront.XXXXXX")"; mkdir -p "$t/walteur-kit/db"; printf -- '---\nname: bad--name\ndescription: a long enough description for the check.\n---\nx\n' > "$t/walteur-kit/db/SKILL.md"; ck "G4 double-hyphen name -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. FP guard: unknown key is ADVISORY not a violation -> PASS (non-strict)
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillfront.XXXXXX")"; mkdir -p "$t/walteur-kit/uk"; printf -- '---\nname: uk\ndescription: fine description that is long enough.\nwobble: yes\n---\nx\n' > "$t/walteur-kit/uk/SKILL.md"; ck "G5 unknown key -> PASS (advisory)" 0 "$(run "$t")"; rm -rf "$t"
  # 8. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillfront.XXXXXX")"; mkdir -p "$t/walteur-kit/bs"; printf -- '---\nname: Bad_Skill\ndescription: x\n---\nx\n' > "$t/walteur-kit/bs/SKILL.md"; WALTEUR_ROOT="$t" WALTEUR_SKILLS_DIR="$t" WALTEUR_SKILLFM=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/skillfront.XXXXXX")"; mkdir -p "$t/walteur-kit"; good "$t" a-skill "Use this when building."; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "skill-frontmatter-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
