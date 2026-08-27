#!/usr/bin/env bash
# WALTEUR tool-readiness — the ONE fail-closed gate (GAP 1: enforcement must not be silently conditional).
#
# Every OTHER gate does a LOUD-SKIP when its tool is absent (honest, but conditional). This gate is the
# floor that makes a *declared-required* tool non-optional: if walteur-kit/required-tools.json marks a
# tool required:true and 'command -v <tool>' is MISSING, the build is NOT ready and we HARD-FAIL (exit 2)
# with the install hints printed. That is the whole point — it closes the "conditional enforcement" gap.
#
# CONTRACT (the deliberate exception to the house "missing tool => SKIP exit 0" rule):
#   - required-tools.json ABSENT            => verdict:SKIP, exit 0   (bare/legacy projects unaffected).
#   - every required:true tool PRESENT      => verdict:PASS, exit 0.
#   - ANY required:true tool MISSING        => verdict:FAIL, exit 2   (FAIL-CLOSED; install hints to stderr).
#   - required:false tools                  => recorded, never block  (projects opt-in to make them required).
#
# Still honors the universal controls:
#   - kill switch  walteur-kit/PAUSED present        => exit 2 (paused == not green).
#   - bypass       WALTEUR_TOOLREADY=off             => verdict:SKIP, exit 0.
#
# Zero-dep (bash + jq). Special-case: jq is itself a declared core dep — if jq is missing we cannot parse
# the manifest, but a missing required tool is exactly the fail-closed condition, so we fail loudly without it.
# Report: walteur-kit/tool-readiness-report.json {verdict, ts, gate, reason, details}.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "tool-readiness - the ONE fail-closed gate (GAP 1: enforcement must not be silently conditional)."
  printf '%s\n' "usage: bash tool-readiness.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/tool-readiness-report.json - fix recipes: walteur-kit/REMEDIATION.md (## tool-readiness)"
  printf '%s\n' "bypass: WALTEUR_TOOLREADY=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/tool-readiness-report.json"
MANIFEST="$KIT/required-tools.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

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
    echo "tool-readiness selftest SKIP - jq not installed."
    return 0
  fi

  echo "tool-readiness selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tool-readiness-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "absent required-tools.json -> SKIP/PASS exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/tool-readiness-report.json" >/dev/null 2>&1
  ck "absent manifest report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tool-readiness-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '%s\n' '{"tools":[{"discipline":"core","tool":"jq","required":true,"install":"brew install jq"},{"discipline":"core","tool":"bash","required":true,"install":"install bash"},{"discipline":"optional","tool":"walteur_absent_optional_tool_xyz","required":false,"install":"no-op"}]}' > "$tmp/walteur-kit/required-tools.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "required present tools -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and (.details.present | index("jq")) and (.details.optional[] | select(.tool == "walteur_absent_optional_tool_xyz" and .status == "absent"))' "$tmp/walteur-kit/tool-readiness-report.json" >/dev/null 2>&1
  ck "PASS report records present and optional tools" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tool-readiness-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '%s\n' '{"tools":[{"discipline":"core","tool":"walteur_missing_required_tool_xyz","required":true,"install":"echo install"}]}' > "$tmp/walteur-kit/required-tools.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing required tool -> FAIL-CLOSED" 2 "$?"
  jq -e '.verdict == "FAIL" and (.details.missing[] | select(.tool == "walteur_missing_required_tool_xyz"))' "$tmp/walteur-kit/tool-readiness-report.json" >/dev/null 2>&1
  ck "FAIL report records missing required tool" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tool-readiness-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '%s\n' '{"tools":[{"discipline":"core","tool":"walteur_missing_required_tool_xyz","required":true,"install":"echo install"}]}' > "$tmp/walteur-kit/required-tools.json"
  WALTEUR_ROOT="$tmp" WALTEUR_TOOLREADY=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit even with missing required tool" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/tool-readiness-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tool-readiness-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "tool-readiness selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_TOOLREADY:-on}" = "off" ] && {
  echo "tool-readiness: bypassed (WALTEUR_TOOLREADY=off)." >&2
  printf '{"verdict":"SKIP","ts":"%s","gate":"tool-readiness","reason":"bypassed via WALTEUR_TOOLREADY=off"}\n' "$TS" > "$REPORT" 2>/dev/null || true
  exit 0
}

# Manifest absent => bare/legacy project; do NOT impose a tool floor.
if [ ! -f "$MANIFEST" ]; then
  echo "tool-readiness: SKIP — no walteur-kit/required-tools.json (bare/legacy project; no tool floor imposed)." >&2
  printf '{"verdict":"SKIP","ts":"%s","gate":"tool-readiness","reason":"required-tools.json absent"}\n' "$TS" > "$REPORT" 2>/dev/null || true
  exit 0
fi

echo "WALTEUR tool-readiness @ $ROOT" >&2

# jq is itself a declared core dependency. If it is missing we cannot parse the manifest — but a missing
# required tool IS the fail-closed condition, so fail loudly and explicitly rather than degrade to a SKIP.
if ! have jq; then
  echo "  FAIL — required tool 'jq' is MISSING (and is needed to read required-tools.json)." >&2
  echo "         install: brew install jq" >&2
  printf '{"verdict":"FAIL","ts":"%s","gate":"tool-readiness","reason":"required tool jq is missing (cannot parse manifest)","details":{"missing":[{"tool":"jq","discipline":"core","install":"brew install jq"}]}}\n' "$TS" > "$REPORT" 2>/dev/null || true
  exit 2
fi

# Walk every required:true entry; collect the ones whose binary is not on PATH.
missing='[]'   # JSON array of {tool,discipline,install}
present='[]'   # JSON array of tool names (required:true, found)
missing_count=0

while IFS=$'\t' read -r tool discipline install; do
  [ -n "$tool" ] || continue
  if have "$tool"; then
    echo "  ok   — required '$tool' ($discipline) present." >&2
    present="$(printf '%s' "$present" | jq --arg t "$tool" '. + [$t]' 2>/dev/null || printf '%s' "$present")"
  else
    echo "  FAIL — required '$tool' ($discipline) MISSING. install: $install" >&2
    missing="$(printf '%s' "$missing" | jq --arg t "$tool" --arg d "$discipline" --arg i "$install" \
      '. + [{tool:$t, discipline:$d, install:$i}]' 2>/dev/null || printf '%s' "$missing")"
    missing_count=$((missing_count+1))
  fi
done < <(jq -r '.tools[]? | select(.required==true) | [.tool, (.discipline // "core"), (.install // "")] | @tsv' "$MANIFEST" 2>/dev/null)

# required:false tools — recorded for visibility, never block (projects opt-in to make them required).
optional='[]'
while IFS=$'\t' read -r tool discipline install; do
  [ -n "$tool" ] || continue
  st="absent"; have "$tool" && st="present"
  optional="$(printf '%s' "$optional" | jq --arg t "$tool" --arg d "$discipline" --arg s "$st" \
    '. + [{tool:$t, discipline:$d, status:$s}]' 2>/dev/null || printf '%s' "$optional")"
done < <(jq -r '.tools[]? | select(.required!=true) | [.tool, (.discipline // ""), (.install // "")] | @tsv' "$MANIFEST" 2>/dev/null)

if [ "$missing_count" -gt 0 ]; then
  echo "tool-readiness verdict: FAIL — $missing_count required tool(s) missing. FAIL-CLOSED (exit 2)." >&2
  echo "  install the missing tools above (or run walteur-kit/bootstrap.sh), then re-ship." >&2
  jq -n --arg ts "$TS" --argjson miss "$missing" --argjson pres "$present" --argjson opt "$optional" \
    '{verdict:"FAIL", ts:$ts, gate:"tool-readiness",
      reason:"\($miss|length) declared-required tool(s) missing (fail-closed)",
      details:{missing:$miss, present:$pres, optional:$opt}}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"FAIL","ts":"%s","gate":"tool-readiness","reason":"%s required tool(s) missing"}\n' "$TS" "$missing_count" > "$REPORT"
  exit 2
fi

echo "tool-readiness verdict: PASS — all declared-required tools present. -> $REPORT" >&2
jq -n --arg ts "$TS" --argjson pres "$present" --argjson opt "$optional" \
  '{verdict:"PASS", ts:$ts, gate:"tool-readiness",
    reason:"all declared-required tools present",
    details:{present:$pres, optional:$opt}}' > "$REPORT" 2>/dev/null \
  || printf '{"verdict":"PASS","ts":"%s","gate":"tool-readiness"}\n' "$TS" > "$REPORT"
exit 0
