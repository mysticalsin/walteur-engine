#!/usr/bin/env bash
# WALTEUR security-scan-gate — EXECUTING gate (intake: Pantheon-Security/medusa, AGPL-3.0).
#
# Runs MEDUSA and OBSERVES its REAL findings/exit — not a shape-read. MEDUSA is an AI-first security scanner
# (40k+ patterns: Log4Shell/Spring4Shell/LangChain RCE/MCP tool poisoning/prompt injection + a secrets scan).
# WALTEUR cannot fake the result — the findings count + exit ARE the observation. This is the "run a real
# scanner before calling it finished" pass, complementing security-gate/agent-security/osv/cve.
#
# GOVERNANCE: MEDUSA is AGPL-3.0. This gate runs it ONLY as an EXTERNAL CLI (mere aggregation/use — does NOT
# taint WALTEUR's code); NEVER vendor or modify its source into the product. The gate NEVER fetches from the
# network (no auto-install); it requires medusa present (acquire via tool-acquisition). Absent => loud SKIP.
#
# Applies: any source-bearing project. Else NOT_APPLICABLE.
# CONTRACT: medusa findings (parsed count, or non-zero exit) over WALTEUR_MEDUSA_MAX (default 0) => FAIL ·
#   clean => PASS · medusa absent => SKIP exit 0 (loud, couldn't-measure) · PAUSED => exit 2 ·
#   bypass WALTEUR_SECSCAN=off · command override WALTEUR_MEDUSA_CMD (default "medusa scan . --json").
# Report: walteur-kit/security-scan-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "security-scan-gate - EXECUTING gate (intake: Pantheon-Security/medusa, AGPL-3.0)."
  printf '%s\n' "usage: bash security-scan-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/security-scan-report.json - fix recipes: walteur-kit/REMEDIATION.md (## security-scan-gate)"
  printf '%s\n' "bypass: WALTEUR_SECSCAN=off (recorded, not free)"
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
REPORT="$KIT/security-scan-report.json"
MAX="${WALTEUR_MEDUSA_MAX:-0}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
write_report() { v="$1"; r="$2"; ex="${3-}"; [ -n "$ex" ] || ex='{}'; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson ex "$ex" '{verdict:$v, ts:$ts, gate:"security-scan", reason:$r} + $ex' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","reason":"%s"}\n' "$v" "$r" > "$REPORT" 2>/dev/null || true; }

resolve_tool() {
  command -v medusa >/dev/null 2>&1 && { echo "medusa"; return; }
  [ -x "$ROOT/node_modules/.bin/medusa" ] && { echo "$ROOT/node_modules/.bin/medusa"; return; }
  echo ""
}

applies() {
  command -v find >/dev/null 2>&1 || { [ -f "$ROOT/package.json" ] && return 0; return 1; }
  [ -n "$(find "$ROOT" -type d \( -name node_modules -o -name .git -o -name walteur-kit -o -name dist -o -name build \) -prune -o \
        -type f \( -name '*.ts' -o -name '*.js' -o -name '*.mjs' -o -name '*.py' -o -name '*.go' -o -name '*.rb' -o -name '*.php' -o -name '*.java' -o -name '*.rs' \) -print 2>/dev/null | head -1)" ]
}

main() {
  [ -f "$KIT/PAUSED" ] && { write_report FAIL paused; echo "security-scan-gate: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_SECSCAN:-}" = "off" ] && { write_report SKIP "bypassed via WALTEUR_SECSCAN=off"; echo "security-scan-gate: SKIP — WALTEUR_SECSCAN=off (loud skip)" >&2; exit 0; }
  if ! applies; then write_report NOT_APPLICABLE "no source-bearing project"; echo "security-scan-gate: NOT_APPLICABLE" >&2; exit 0; fi
  local TOOL; TOOL="$(resolve_tool)"
  if [ -z "$TOOL" ]; then
    # STRICT mode (S008 skill fix): a source surface is present but medusa is absent — an unmeasured pass is
    # a silent hole. With WALTEUR_SECSCAN_STRICT=1 (or global WALTEUR_TOOLGATE_STRICT=1) FAIL.
    if [ "${WALTEUR_SECSCAN_STRICT:-${WALTEUR_TOOLGATE_STRICT:-0}}" = "1" ]; then
      write_report FAIL "source present but medusa not installed — STRICT mode rejects an unmeasured security pass (acquire medusa via tool-acquisition)"
      echo "security-scan-gate: FAIL — medusa absent in STRICT mode -> exit 2" >&2; exit 2
    fi
    write_report SKIP "medusa not installed — acquire via tool-acquisition (couldn't run the security scan, NOT a pass)"
    echo "security-scan-gate: SKIP — medusa not installed (cannot_measure)" >&2; exit 0
  fi
  if ! have jq; then write_report SKIP "jq not installed"; echo "security-scan-gate: SKIP (no jq)" >&2; exit 0; fi

  local cmd out rc count
  cmd="${WALTEUR_MEDUSA_CMD:-$TOOL scan . --json}"
  out="$( ( cd "$ROOT" && eval "$cmd" 2>/dev/null ) )"; rc=$?
  out="$(printf '%s' "$out" | tr -d '\r')"
  # parse a findings count from JSON if available; else fall back to exit code
  count="$(printf '%s' "$out" | jq -r '((.findings // .issues // .results // []) | length) // empty' 2>/dev/null || echo "")"
  if [ -z "$count" ]; then [ "$rc" -eq 0 ] && count=0 || count=1; fi

  if [ "$count" -gt "$MAX" ] 2>/dev/null; then
    write_report FAIL "MEDUSA found $count security finding(s) > threshold $MAX (CVEs/secrets/injection/MCP-poisoning)" "$(jq -n --argjson c "$count" --argjson m "$MAX" --argjson rc "$rc" '{findings:$c, threshold:$m, medusa_exit:$rc}')"
    echo "security-scan-gate: FAIL — $count finding(s) > $MAX -> exit 2" >&2; exit 2
  fi
  if [ "$rc" -ge 2 ]; then
    write_report FAIL "MEDUSA exited $rc (scanner error — couldn't trust the result)" "$(jq -n --argjson rc "$rc" '{medusa_exit:$rc}')"
    echo "security-scan-gate: FAIL — medusa error exit $rc -> exit 2" >&2; exit 2
  fi
  write_report PASS "MEDUSA clean ($count finding(s) <= $MAX)" "$(jq -n --argjson c "$count" --argjson m "$MAX" '{findings:$c, threshold:$m, medusa_exit:'"$rc"'}')"
  echo "security-scan-gate: PASS — MEDUSA $count finding(s) <= $MAX" >&2; exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "security-scan selftest SKIP — need jq."; return 0; fi
  echo "security-scan-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  seedsrc() { mkdir -p "$1"; printf 'export const a = 1;\n' > "$1/index.ts"; }
  shim() { mkdir -p "$1/bin"; { printf '#!/usr/bin/env bash\n'; printf "cat <<'J'\n%s\nJ\n" "$2"; printf 'exit %s\n' "$3"; } > "$1/bin/medusa"; chmod +x "$1/bin/medusa"; }
  runp() { PATH="$1/bin:$PATH" WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }

  # 1. no source -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/securitysc.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf 'hi\n' > "$t/readme.md"; ck "no source -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. source + medusa clean (exit 0) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/securitysc.XXXXXX")"; seedsrc "$t"; shim "$t" '{"findings":[]}' 0; ck "medusa clean -> PASS" 0 "$(runp "$t")"; rm -rf "$t"
  # 3. source + medusa findings -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securitysc.XXXXXX")"; seedsrc "$t"; shim "$t" '{"findings":[{"severity":"critical","rule":"prompt-injection"}]}' 1; ck "medusa findings -> FAIL" 2 "$(runp "$t")"; rm -rf "$t"
  # 4. source + medusa scanner error (exit 2, no parseable findings) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securitysc.XXXXXX")"; seedsrc "$t"; shim "$t" 'not json' 2; ck "medusa scanner error -> FAIL" 2 "$(runp "$t")"; rm -rf "$t"
  # 5. source + medusa ABSENT -> loud SKIP exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/securitysc.XXXXXX")"; seedsrc "$t"; ck "medusa absent -> SKIP exit 0" 0 "$(run "$t")"
  jq -e '.verdict=="SKIP"' "$t/walteur-kit/security-scan-report.json" >/dev/null 2>&1; ck "absent report verdict SKIP (loud)" 0 "$?"; rm -rf "$t"
  # 5b. source + medusa ABSENT + STRICT -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securitysc.XXXXXX")"; seedsrc "$t"; WALTEUR_SECSCAN_STRICT=1 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "medusa absent + STRICT -> FAIL" 2 "$?"; rm -rf "$t"
  # 6. findings within raised threshold -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/securitysc.XXXXXX")"; seedsrc "$t"; shim "$t" '{"findings":[{"severity":"low"}]}' 1; PATH="$t/bin:$PATH" WALTEUR_MEDUSA_MAX=3 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "findings within threshold -> PASS" 0 "$?"; rm -rf "$t"
  # 7. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/securitysc.XXXXXX")"; seedsrc "$t"; shim "$t" '{"findings":[{"x":1}]}' 1; PATH="$t/bin:$PATH" WALTEUR_SECSCAN=off WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/securitysc.XXXXXX")"; seedsrc "$t"; mkdir -p "$t/walteur-kit"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "security-scan-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
