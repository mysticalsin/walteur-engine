#!/usr/bin/env bash
# walteur-apex fixture-integrity — guards the defect class that shipped once already: a fixture INPUT
# file silently untracked by .gitignore, so the working tree passes 29/29 while a clean clone fails
# with a FALSE "gate-went-blind" alarm.
#
# It checks the ARCHIVE (git archive HEAD), never the working tree — that distinction is the whole
# point. Every fixture named in manifest-additions.json must exist in the archive, and every fixture
# directory present on disk must survive into it byte-for-byte.
#
# CONTRACT: all fixtures intact => exit 0 · any missing/differing file => exit 2 (FAIL-CLOSED)
#           not a git repo => SKIP exit 0 · PAUSED => exit 2 · bypass WALTEUR_FIXINT=off
#
# --help: self-documentation BEFORE any side effect
case "${1:-}" in
  -h|--help)
    printf '%s\n' "fixture-integrity - asserts every fixture file survives 'git archive HEAD'."
    printf '%s\n' "usage: bash fixture-integrity.sh [--selftest|--help|<default run>]"
    printf '%s\n' "why: a .gitignore rule once ate 6 fixture INPUTS; the working tree passed while a clone failed."
    printf '%s\n' "bypass: WALTEUR_FIXINT=off (recorded, not free)"
    exit 0 ;;
esac

set -uo pipefail
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"

main() {
  local ROOT FX MAN missing=0 differing=0 checked=0
  # ROOT must be the REPOSITORY root, not "one level up from this script". Installed at
  # walteur-kit/eval-harness/, the old `dirname/..` gave ROOT=walteur-kit — and `git archive HEAD` run
  # from a subdirectory archives ONLY that subdirectory, un-prefixed, so the file scan lined up by
  # accident and reported PASS while the manifest resolved to a path that does not exist. Walk up to
  # the first directory that is a git top-level or contains walteur-kit/.
  if [ -n "${WALTEUR_APEX_ROOT:-}" ]; then
    ROOT="$WALTEUR_APEX_ROOT"
  else
    ROOT="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)"
    local up="$ROOT"
    while [ -n "$up" ] && [ "$up" != "/" ]; do
      if [ -d "$up/.git" ] || [ -f "$up/.git" ] || [ -d "$up/walteur-kit" ]; then ROOT="$up"; break; fi
      up="$(dirname "$up")"
    done
    [ "$up" = "/" ] && ROOT="$(cd "$(dirname "$SELF")/.." 2>/dev/null && pwd)"
  fi
  # Layout-aware, same as refresh-fixture-dates.sh. Hardcoding the apex path made this guard SKIP
  # silently on the very tree the defect was live in: adopted into walteur-kit/eval-harness/, it printed
  # "SKIP (no fixtures dir)" and exited 0 while .gitignore was eating a fixture input three directories
  # away. A guard that no-ops where it matters is worse than no guard — it reports success.
  FX=""
  for cand in \
    "$ROOT/eval-harness-additions/fixtures" \
    "$ROOT/walteur-kit/eval-harness/fixtures" \
    "$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)/fixtures" ; do
    [ -d "$cand" ] && { FX="$cand"; break; }
  done
  [ -n "$FX" ] || FX="$ROOT/eval-harness-additions/fixtures"
  MAN=""
  for m in "$ROOT/eval-harness-additions/manifest-additions.json" \
           "$ROOT/walteur-kit/eval-harness/manifest.json" \
           "$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)/manifest.json" ; do
    [ -f "$m" ] && { MAN="$m"; break; }
  done

  [ -f "$ROOT/walteur-kit/PAUSED" ] && { echo "fixture-integrity: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_FIXINT:-on}" = "off" ] && { echo "fixture-integrity: bypassed" >&2; exit 0; }
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "fixture-integrity: SKIP (not a git repo)"; exit 0; }
  [ -d "$FX" ] || { echo "fixture-integrity: SKIP (no fixtures dir)"; exit 0; }
  # A fixtures directory with no locatable manifest is CANNOT-VERIFY, not nothing-to-verify. Installed
  # one directory deeper than it was written for, this gate found 128 files, found no manifest, and
  # printed "PASS - all 128 fixture files survive (0 manifest fixtures present)". Green meaning
  # unchecked — the third time in this file's history, and the exact defect class it exists to stop.
  [ -n "$MAN" ] || {
    echo "fixture-integrity: FAIL - fixtures exist at $FX but no manifest was found; cannot verify coverage (fail-closed)" >&2
    echo "  looked for: <root>/eval-harness-additions/manifest-additions.json, <root>/walteur-kit/eval-harness/manifest.json, <script dir>/manifest.json" >&2
    exit 2
  }

  local A; A="$(mktemp -d)"
  git -C "$ROOT" archive HEAD 2>/dev/null | tar -x -C "$A" 2>/dev/null || { echo "fixture-integrity: FAIL - could not archive HEAD" >&2; rm -rf "$A"; exit 2; }

  # 1. every file on disk under fixtures/ must exist in the archive with identical content
  while IFS= read -r f; do
    local rel="${f#$ROOT/}"
    checked=$((checked+1))
    if [ ! -f "$A/$rel" ]; then
      echo "  MISSING FROM ARCHIVE: $rel" >&2; missing=$((missing+1))
    # Compare CR-insensitively. On Windows git checks the worktree out as CRLF while `git archive`
    # emits LF, so a raw byte compare reports every single file as differing — a false positive that
    # would make this gate useless on the platform it was written on. Content equality is what matters;
    # the clean-clone self-regress run proves LF fixtures work.
    elif ! diff -q --strip-trailing-cr "$f" "$A/$rel" >/dev/null 2>&1; then
      echo "  DIFFERS IN ARCHIVE:   $rel" >&2; differing=$((differing+1))
    fi
  done < <(find "$FX" -type f 2>/dev/null)

  # A corrupt manifest is "cannot verify", not "nothing to verify". Previously the jq read failed
  # silently and the manifest loop simply named zero fixtures, so a one-byte manifest produced
  # "PASS - all 102 fixture files survive". Green meaning unchecked, in the gate whose entire job is to
  # stop green meaning unchecked.
  if [ -f "$MAN" ] && command -v jq >/dev/null 2>&1; then
    jq -e . "$MAN" >/dev/null 2>&1 || {
      echo "fixture-integrity: FAIL - manifest is not valid JSON; cannot verify fixture coverage (fail-closed)" >&2
      rm -rf "$A"; exit 2
    }
  fi

  # 2. every fixture named in the manifest must be a real directory in the archive
  local named=0
  if [ -f "$MAN" ] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r fx; do
      [ -n "$fx" ] || continue
      named=$((named+1))
      # Resolve against the SAME layout the file scan used, not a hardcoded apex path. Leaving this
      # half hardcoded made every manifest row report "absent from archive" on an adopted tree — 30
      # false failures from a guard that had just been made layout-aware in its other half.
      local fx_rel="${FX#$ROOT/}"
      [ -d "$A/$fx_rel/$fx" ] || { echo "  MANIFEST NAMES A FIXTURE ABSENT FROM ARCHIVE: $fx" >&2; missing=$((missing+1)); }
    done < <(jq -r '.[].fixture' "$MAN" 2>/dev/null | tr -d '\r' | sort -u)
  fi
  rm -rf "$A"

  if [ "$missing" -gt 0 ] || [ "$differing" -gt 0 ]; then
    echo "fixture-integrity: FAIL - $missing missing, $differing differing of $checked files ($named manifest fixtures) -> exit 2" >&2
    echo "  A fixture that exists on disk but not in the archive means a clean clone CANNOT reproduce the suite." >&2
    echo "  Most likely cause: a .gitignore rule eating a fixture input (e.g. '*-report.json'). Add a negation and 'git add -f'." >&2
    exit 2
  fi
  echo "fixture-integrity: PASS - all $checked fixture files survive 'git archive HEAD' ($named manifest fixtures present)"
  exit 0
}

selftest() {
  local pass=0 fail=0
  command -v git >/dev/null 2>&1 || { echo "fixture-integrity selftest SKIP - no git."; return 0; }
  echo "fixture-integrity selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  mkrepo() {
    local d="$1"; mkdir -p "$d/eval-harness-additions/fixtures/fx-clean/walteur-kit"
    printf '{"risk_tier":"high"}' > "$d/eval-harness-additions/fixtures/fx-clean/walteur-kit/build-contract.json"
    printf '{"score":92}' > "$d/eval-harness-additions/fixtures/fx-clean/walteur-kit/mutation-report.json"
    printf '%s' '[{"fixture":"fx-clean","gate":"g.sh","expect":"PASS"}]' > "$d/eval-harness-additions/manifest-additions.json"
    cp "$SELF" "$d/eval-harness-additions/fixture-integrity.sh"
    git -C "$d" init -q 2>/dev/null
    git -C "$d" add -A 2>/dev/null
    git -C "$d" -c user.name=t -c user.email=t@t commit -qm init 2>/dev/null
  }
  run() { WALTEUR_APEX_ROOT="$1" bash "$1/eval-harness-additions/fixture-integrity.sh" >/dev/null 2>&1; echo $?; }

  # 1. everything tracked -> PASS
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/fixint.XXXXXX")"; mkrepo "$t"
  ck "all fixture files tracked -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 2. THE SHIPPED DEFECT: a fixture input eaten by .gitignore -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixint.XXXXXX")"; mkrepo "$t"
  printf '*-report.json\n' > "$t/.gitignore"
  git -C "$t" rm -q --cached "eval-harness-additions/fixtures/fx-clean/walteur-kit/mutation-report.json" 2>/dev/null
  git -C "$t" add -A 2>/dev/null; git -C "$t" -c user.name=t -c user.email=t@t commit -qm ignore 2>/dev/null
  ck "gitignored fixture INPUT -> FAIL (the shipped defect)" 2 "$(run "$t")"; rm -rf "$t"

  # 3. manifest names a fixture that does not exist -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixint.XXXXXX")"; mkrepo "$t"
  printf '%s' '[{"fixture":"fx-ghost","gate":"g.sh","expect":"PASS"}]' > "$t/eval-harness-additions/manifest-additions.json"
  git -C "$t" add -A 2>/dev/null; git -C "$t" -c user.name=t -c user.email=t@t commit -qm ghost 2>/dev/null
  ck "manifest names an absent fixture -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 4. uncommitted local edit (archive differs from disk) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixint.XXXXXX")"; mkrepo "$t"
  printf '{"score":11}' > "$t/eval-harness-additions/fixtures/fx-clean/walteur-kit/mutation-report.json"
  ck "uncommitted fixture edit -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 5. not a git repo -> SKIP, never a false fail
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixint.XXXXXX")"; mkdir -p "$t/eval-harness-additions/fixtures"
  cp "$SELF" "$t/eval-harness-additions/fixture-integrity.sh"
  ck "not a git repo -> SKIP" 0 "$(run "$t")"; rm -rf "$t"

  # 6. bypass
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixint.XXXXXX")"; mkrepo "$t"
  printf '*-report.json\n' > "$t/.gitignore"
  git -C "$t" rm -q --cached "eval-harness-additions/fixtures/fx-clean/walteur-kit/mutation-report.json" 2>/dev/null
  git -C "$t" add -A 2>/dev/null; git -C "$t" -c user.name=t -c user.email=t@t commit -qm ig 2>/dev/null
  WALTEUR_APEX_ROOT="$t" WALTEUR_FIXINT=off bash "$t/eval-harness-additions/fixture-integrity.sh" >/dev/null 2>&1
  ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"

  # 7. REGRESSION: a corrupt manifest must FAIL closed. It previously named zero fixtures and
  #    reported "PASS - all N fixture files survive" — green meaning unchecked, inside the gate whose
  #    whole job is to stop green meaning unchecked.
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixint.XXXXXX")"; mkrepo "$t"
  printf 'X' > "$t/eval-harness-additions/manifest-additions.json"
  git -C "$t" add -A 2>/dev/null; git -C "$t" -c user.name=t -c user.email=t@t commit -qm corrupt 2>/dev/null
  ck "corrupt manifest -> FAIL (was PASS)" 2 "$(run "$t")"; rm -rf "$t"

  # 8. ADOPTED LAYOUT, NO ENV VAR. Installed at walteur-kit/eval-harness/ and invoked plainly, this
  #    reported "PASS - all 128 fixture files survive (0 manifest fixtures present)": ROOT resolved to
  #    walteur-kit/, the manifest resolved to a path that does not exist, and the manifest half of the
  #    check silently did nothing. Assert the manifest count is actually non-zero.
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixint.XXXXXX")"
  mkdir -p "$t/walteur-kit/eval-harness/fixtures/fx-clean/walteur-kit"
  printf '{"risk_tier":"high"}' > "$t/walteur-kit/eval-harness/fixtures/fx-clean/walteur-kit/build-contract.json"
  printf '%s' '[{"fixture":"fx-clean","gate":"g.sh","expect":"PASS"}]' > "$t/walteur-kit/eval-harness/manifest.json"
  cp "$SELF" "$t/walteur-kit/eval-harness/fixture-integrity.sh"
  git -C "$t" init -q 2>/dev/null; git -C "$t" add -A 2>/dev/null
  git -C "$t" -c user.name=t -c user.email=t@t commit -qm init 2>/dev/null
  out="$(bash "$t/walteur-kit/eval-harness/fixture-integrity.sh" 2>&1)"; rc=$?
  ck "adopted layout, no env var -> PASS" 0 "$rc"
  case "$out" in *"(1 manifest fixtures present)"*) ck "adopted layout resolves the manifest (was 0)" 0 0 ;;
                 *) ck "adopted layout resolves the manifest (was 0)" 0 1; echo "      got: $out" ;; esac
  rm -rf "$t"

  # 9. fixtures present, manifest unreachable -> FAIL, never a silent PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixint.XXXXXX")"; mkrepo "$t"
  rm -f "$t/eval-harness-additions/manifest-additions.json"
  git -C "$t" add -A 2>/dev/null; git -C "$t" -c user.name=t -c user.email=t@t commit -qm nomanifest 2>/dev/null
  ck "fixtures but no manifest -> FAIL (was silent PASS)" 2 "$(run "$t")"; rm -rf "$t"

  echo "fixture-integrity selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
