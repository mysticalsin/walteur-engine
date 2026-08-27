#!/usr/bin/env bash
# WALTEUR dead-code-gate — EXECUTING gate (intake: webpro-nl/knip, ISC).
#
# Runs Knip and OBSERVES its REAL exit code — not a shape-read. Knip parses the JS/TS module graph and
# reports unused files / exports / dependencies; WALTEUR cannot fake that verdict, and Knip's exit code IS
# the observation (contract: 0 = clean, 1 = issues found, 2 = internal/bad-input error). This is the
# run+observe+fail-closed pattern that closes the PROOF gap on JS/TS builds.
#
# GOVERNED: the gate NEVER fetches from the network (no `npx`-download inside a gate). It requires Knip to
# already be present (a `knip` on PATH or node_modules/.bin/knip — acquire it via the lockfile-backed
# tool-acquisition flow). If Knip is absent it LOUD-SKIPs (couldn't-measure, never silent-green).
#
# Applies: a JS/TS project (package.json OR JS/TS sources). Else NOT_APPLICABLE.
# CONTRACT: knip exit>=2 => FAIL (tool error, never trust) · exit 1 with issue-count > WALTEUR_KNIP_MAX
#   (default 0) => FAIL · exit 0 (or count<=MAX) => PASS · knip absent => SKIP exit 0 (loud) ·
#   PAUSED => exit 2 · bypass WALTEUR_DEADCODE=off. Report: walteur-kit/dead-code-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "dead-code-gate - EXECUTING gate (intake: webpro-nl/knip, ISC)."
  printf '%s\n' "usage: bash dead-code-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/dead-code-report.json - fix recipes: walteur-kit/REMEDIATION.md (## dead-code-gate)"
  printf '%s\n' "bypass: WALTEUR_DEADCODE=off (recorded, not free)"
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
REPORT="$KIT/dead-code-report.json"
MAX="${WALTEUR_KNIP_MAX:-0}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
write_report() { v="$1"; r="$2"; ex="${3-}"; [ -n "$ex" ] || ex='{}'; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson ex "$ex" '{verdict:$v, ts:$ts, gate:"dead-code", reason:$r} + $ex' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","reason":"%s"}\n' "$v" "$r" > "$REPORT" 2>/dev/null || true; }

resolve_knip() {
  command -v knip >/dev/null 2>&1 && { echo "knip"; return; }
  [ -x "$ROOT/node_modules/.bin/knip" ] && { echo "$ROOT/node_modules/.bin/knip"; return; }
  echo ""
}

applies() {
  [ -f "$ROOT/package.json" ] && return 0
  command -v find >/dev/null 2>&1 || return 1
  [ -n "$(find "$ROOT" -type d \( -name node_modules -o -name .git -o -name walteur-kit -o -name dist -o -name build \) -prune -o \
        -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.mjs' -o -name '*.jsx' \) -print 2>/dev/null | head -1)" ]
}

main() {
  [ -f "$KIT/PAUSED" ] && { write_report FAIL paused; echo "dead-code-gate: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_DEADCODE:-}" = "off" ] && { write_report SKIP "bypassed via WALTEUR_DEADCODE=off"; echo "dead-code-gate: SKIP — WALTEUR_DEADCODE=off (loud skip)" >&2; exit 0; }
  if ! applies; then write_report NOT_APPLICABLE "no JS/TS project (no package.json, no JS/TS sources)"; echo "dead-code-gate: NOT_APPLICABLE" >&2; exit 0; fi
  local KNIP; KNIP="$(resolve_knip)"
  if [ -z "$KNIP" ]; then
    # STRICT mode (S008 skill fix): a JS/TS surface is present but knip is absent — an unmeasured pass is a
    # silent enforcement hole. With WALTEUR_DEADCODE_STRICT=1 (or global WALTEUR_TOOLGATE_STRICT=1) FAIL.
    if [ "${WALTEUR_DEADCODE_STRICT:-${WALTEUR_TOOLGATE_STRICT:-0}}" = "1" ]; then
      write_report FAIL "JS/TS surface present but knip not installed — STRICT mode rejects an unmeasured pass (acquire knip via tool-acquisition)"
      echo "dead-code-gate: FAIL — knip absent in STRICT mode -> exit 2" >&2
      exit 2
    fi
    write_report SKIP "knip not installed — acquire via tool-acquisition (couldn't measure dead code, NOT a pass)"
    echo "dead-code-gate: SKIP — knip not installed (cannot_measure; acquire knip to run this gate)" >&2
    exit 0
  fi
  if ! have jq; then write_report SKIP "jq not installed"; echo "dead-code-gate: SKIP (no jq)" >&2; exit 0; fi

  local out rc count
  out="$( ( cd "$ROOT" && "$KNIP" --reporter json 2>/dev/null ) )"; rc=$?
  out="$(printf '%s' "$out" | tr -d '\r')"   # Windows CRLF: strip before jq

  if [ "$rc" -ge 2 ]; then
    write_report FAIL "knip exited $rc (internal/bad-input error — couldn't trust the analysis)" "$(jq -n --argjson rc "$rc" '{knip_exit:$rc}')"
    echo "dead-code-gate: FAIL — knip error exit $rc -> exit 2" >&2
    exit 2
  fi

  count="$(printf '%s' "$out" | jq '([.issues[]? | ((.files//[])+(.dependencies//[])+(.exports//[])+(.unlisted//[])+(.unresolved//[])+(.nsExports//[])+(.classMembers//[]))] | add | length) // 0' 2>/dev/null || echo "")"
  [ -z "$count" ] && { [ "$rc" -eq 0 ] && count=0 || count=1; }   # fall back to exit code if JSON unparseable

  if [ "$rc" -eq 0 ] || { [ -n "$count" ] && [ "$count" -le "$MAX" ]; }; then
    write_report PASS "knip clean ($count dead-code issue(s) <= $MAX)" "$(jq -n --argjson c "${count:-0}" --argjson m "$MAX" '{issues:$c, threshold:$m, knip_exit:'"$rc"'}')"
    echo "dead-code-gate: PASS — knip $count issue(s) <= $MAX (exit $rc)" >&2
    exit 0
  fi
  write_report FAIL "knip found $count dead-code issue(s) > threshold $MAX (unused files/exports/deps)" "$(jq -n --argjson c "${count:-0}" --argjson m "$MAX" '{issues:$c, threshold:$m, knip_exit:1}')"
  echo "dead-code-gate: FAIL — knip $count dead-code issue(s) > $MAX -> exit 2" >&2
  exit 2
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "dead-code selftest SKIP — need jq."; return 0; fi
  echo "dead-code-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  seedjs() { mkdir -p "$1"; printf '{"name":"x","version":"1.0.0"}\n' > "$1/package.json"; printf 'export const a = 1;\n' > "$1/index.js"; }
  # synthetic knip shim on PATH: emits $2 as JSON, exits $3 — proves the gate's run+observe logic OFFLINE
  shim() { mkdir -p "$1/bin"; { printf '#!/usr/bin/env bash\n'; printf "cat <<'J'\n%s\nJ\n" "$2"; printf 'exit %s\n' "$3"; } > "$1/bin/knip"; chmod +x "$1/bin/knip"; }
  runp() { PATH="$1/bin:$PATH" WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }

  # 1. no JS project -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/deadcodega.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf 'hi\n' > "$t/readme.txt"; ck "no JS project -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. JS + knip exit 0 clean -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/deadcodega.XXXXXX")"; seedjs "$t"; shim "$t" '{"issues":[]}' 0; ck "knip exit 0 clean -> PASS" 0 "$(runp "$t")"; rm -rf "$t"
  # 3. JS + knip exit 1 findings -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/deadcodega.XXXXXX")"; seedjs "$t"; shim "$t" '{"issues":[{"file":"index.js","exports":["a"]}]}' 1; ck "knip exit 1 findings -> FAIL" 2 "$(runp "$t")"; rm -rf "$t"
  # 4. JS + knip exit 2 tool error -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/deadcodega.XXXXXX")"; seedjs "$t"; shim "$t" '{}' 2; ck "knip exit 2 tool error -> FAIL" 2 "$(runp "$t")"; rm -rf "$t"
  # 5. JS + knip ABSENT -> loud SKIP exit 0 (cannot_measure, not a pass)
  t="$(mktemp -d "${TMPDIR:-/tmp}/deadcodega.XXXXXX")"; seedjs "$t"; ck "knip absent -> SKIP exit 0" 0 "$(run "$t")"
  jq -e '.verdict=="SKIP"' "$t/walteur-kit/dead-code-report.json" >/dev/null 2>&1; ck "absent report verdict SKIP (loud)" 0 "$?"; rm -rf "$t"
  # 5b. JS + knip ABSENT + STRICT -> FAIL (no unmeasured pass at ship)
  t="$(mktemp -d "${TMPDIR:-/tmp}/deadcodega.XXXXXX")"; seedjs "$t"; WALTEUR_DEADCODE_STRICT=1 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "knip absent + STRICT -> FAIL" 2 "$?"; rm -rf "$t"
  # 6. JS + knip exit 1 but WALTEUR_KNIP_MAX=5 (count 1 <= 5) -> PASS (threshold)
  t="$(mktemp -d "${TMPDIR:-/tmp}/deadcodega.XXXXXX")"; seedjs "$t"; shim "$t" '{"issues":[{"file":"index.js","exports":["a"]}]}' 1; PATH="$t/bin:$PATH" WALTEUR_KNIP_MAX=5 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "exit 1 within KNIP_MAX threshold -> PASS" 0 "$?"; rm -rf "$t"
  # 7. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/deadcodega.XXXXXX")"; seedjs "$t"; shim "$t" '{}' 1; PATH="$t/bin:$PATH" WALTEUR_DEADCODE=off WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/deadcodega.XXXXXX")"; seedjs "$t"; mkdir -p "$t/walteur-kit"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "dead-code-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
