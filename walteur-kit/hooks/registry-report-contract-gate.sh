#!/usr/bin/env bash
# registry-report-contract-gate.sh
#
# WHY THIS EXISTS
#   gate-registry.json gives every gate a `report` field naming the file that carries its verdict. An
#   oracle that decides "is the build done" by reading the registry reads THAT path. If the registry
#   names a file the hook never writes, the gate is UNOBSERVABLE: the report is permanently absent, and
#   depending on how the reader classifies absence the gate either blocks forever or — far worse — reads
#   as green because nothing said FAIL.
#
#   Found live on 2026-07-25 in 3 of 148 gates, one of them HARD:
#     mutation-gate        registry said mutation-report.json   hook writes mutation-report-gate.json
#     restore-proof        registry said restore-proof-report.json  hook writes restore-report.json
#     maintainability-gate registry said debt-ledger.json       hook writes maintainability-report.json
#   In all three the registry-declared file did not exist after the hook ran. mutation-gate is HARD, so
#   a blocking gate could never be observed through its own registry contract.
#
#   The remaining 145 gates all satisfy registry.report == the hook's own REPORT variable, which is what
#   makes this a contract rather than a preference: the convention is already near-universal, and the
#   outliers were bugs, not intent.
#
# WHAT IT CHECKS
#   For every gate in gate-registry.json whose hook exists and declares a top-level REPORT="$KIT/..."
#   assignment: registry.report MUST equal that path. Hooks that build their report path dynamically
#   (no static top-level REPORT= line) are not checkable this way and are counted as UNCHECKABLE, never
#   as passing — a gate this test cannot see is not a gate this test approved.
#
# CONTRACT
#   HARD-eligible. Exit 2 on any mismatch. Exit 0 when every checkable gate agrees.
#   detect-or-LOUD-SKIP: no jq, or no registry -> SKIP with the reason stated, never a silent pass.
#
# USAGE
#   bash walteur-kit/hooks/registry-report-contract-gate.sh [--selftest|--help]

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REGISTRY="$KIT/gate-registry.json"
REPORT="$KIT/registry-report-contract-report.json"
TS="$(date -u +%FT%TZ)"

have() { command -v "$1" >/dev/null 2>&1; }

case "${1:-}" in
  --help|-h) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

write_report() {
  local verdict="$1" reason="$2" findings="${3:-[]}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"registry-report-contract", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"registry-report-contract","reason":"%s"}\n' \
    "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

# Extract the static verdict-report path a hook declares, or empty if it has none.
hook_report_path() {
  sed -n 's/^REPORT="\{0,1\}\$KIT\/\([A-Za-z0-9._-]*\).*/walteur-kit\/\1/p' "$1" 2>/dev/null | head -1
}

run_check() {
  local reg="$1" kitdir="$2"
  local checked=0 unchecked=0 nohook=0
  local findings="[]"

  while IFS=$'\t' read -r id hook rep hardness; do
    [ -n "${id:-}" ] || continue
    local h="$kitdir/hooks/$hook"
    if [ ! -f "$h" ]; then nohook=$((nohook+1)); continue; fi
    local actual; actual="$(hook_report_path "$h")"
    if [ -z "$actual" ]; then unchecked=$((unchecked+1)); continue; fi
    checked=$((checked+1))
    if [ "$actual" != "$rep" ]; then
      # -c is load-bearing: run_check returns tab-separated fields and findings is the last one, so a
      # pretty-printed multi-line array would break the field contract for every caller.
      findings="$(printf '%s' "$findings" | jq -c --arg id "$id" --arg hook "$hook" \
        --arg declared "$rep" --arg actual "$actual" --arg hard "$hardness" \
        '. + [{gate:$id, hook:$hook, hardness:$hard, registry_declares:$declared, hook_writes:$actual}]')"
    fi
  done < <(jq -r '.gates[]|[.id,.hook,(.report//""),.hardness]|@tsv' "$reg")

  local n; n="$(printf '%s' "$findings" | jq 'length')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$checked" "$unchecked" "$nohook" "$findings"
}

selftest() {
  local pass=0 fail=0
  t() { if eval "$2"; then printf '  ok   - %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL - %s\n' "$1"; fail=$((fail+1)); fi; }
  printf 'registry-report-contract-gate selftest\n'

  have jq || { printf '  SKIP - jq absent, selftest cannot run\n'; return 0; }
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/rrc.XXXXXX")" || return 2
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  mkdir -p "$tmp/walteur-kit/hooks"

  # A good hook: registry and hook agree.
  printf 'REPORT="$KIT/good-report.json"\n' > "$tmp/walteur-kit/hooks/good.sh"
  # A bad hook: registry names a different file (the mutation-gate shape).
  printf 'REPORT="$KIT/bad-report-gate.json"\n' > "$tmp/walteur-kit/hooks/bad.sh"
  # A dynamic hook: no static REPORT= line, so it is UNCHECKABLE, not passing.
  printf 'R="$KIT/$(date +%%s)-report.json"\n' > "$tmp/walteur-kit/hooks/dyn.sh"

  jq -n '{schema_version:1, gates:[
      {id:"good", hook:"good.sh", report:"walteur-kit/good-report.json", hardness:"hard"},
      {id:"dyn",  hook:"dyn.sh",  report:"walteur-kit/dyn-report.json",  hardness:"detect_or_skip"}
    ]}' > "$tmp/clean.json"
  jq -n '{schema_version:1, gates:[
      {id:"good", hook:"good.sh", report:"walteur-kit/good-report.json",   hardness:"hard"},
      {id:"bad",  hook:"bad.sh",  report:"walteur-kit/bad-report.json",    hardness:"hard"}
    ]}' > "$tmp/poisoned.json"

  # Extract every value to a plain scalar BEFORE asserting. Embedding the raw run_check output into the
  # eval'd assertion string breaks the shell, because the findings field is JSON containing quotes and
  # spaces — that produced "[: too many arguments" on first run. eval expands in-scope variables, so the
  # assertions below reference them by name inside single quotes and never interpolate JSON.
  local clean poisoned
  clean="$(run_check "$tmp/clean.json" "$tmp/walteur-kit")"
  poisoned="$(run_check "$tmp/poisoned.json" "$tmp/walteur-kit")"

  local c_n c_checked c_unchecked p_n p_keys p_hard
  c_n="$(printf '%s' "$clean"    | cut -f1)"
  c_checked="$(printf '%s' "$clean" | cut -f2)"
  c_unchecked="$(printf '%s' "$clean" | cut -f3)"
  p_n="$(printf '%s' "$poisoned" | cut -f1)"
  p_keys="$(printf '%s' "$poisoned" | cut -f5 | jq -r 'if (.[0]|has("registry_declares") and has("hook_writes")) then "yes" else "no" end' 2>/dev/null)"
  p_hard="$(printf '%s' "$poisoned" | cut -f5 | jq -r '.[0].hardness // "none"' 2>/dev/null)"

  t "a clean registry yields 0 findings"                        '[ "$c_n" = "0" ]'
  t "a poisoned registry is CAUGHT (1 finding)"                 '[ "$p_n" = "1" ]'
  t "the dynamic-path hook counts as UNCHECKABLE, not checked"  '[ "$c_unchecked" = "1" ]'
  t "the clean case still actually checked the good hook"       '[ "$c_checked" = "1" ]'
  t "the finding names both paths so it is actionable"          '[ "$p_keys" = "yes" ]'
  t "the finding carries hardness so a HARD mismatch is prioritisable" '[ "$p_hard" = "hard" ]'

  # Regression guard: the 3 real gates found on 2026-07-25 must stay fixed in the live registry.
  if [ -f "$REGISTRY" ]; then
    local live_n; live_n="$(run_check "$REGISTRY" "$KIT" | cut -f1)"
    t "the LIVE registry has 0 mismatches (regression guard: mutation-gate, restore-proof, maintainability-gate)" \
      '[ "$live_n" = "0" ]'
  fi

  printf 'registry-report-contract-gate selftest: %d/%d passed\n' "$pass" "$((pass+fail))"
  [ "$fail" -eq 0 ] || return 2
  return 0
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

have jq || { write_report "SKIP" "jq absent — cannot parse gate-registry.json (LOUD SKIP, not a pass)"; \
  echo "registry-report-contract: SKIP (jq absent)"; exit 0; }
[ -f "$REGISTRY" ] || { write_report "SKIP" "no gate-registry.json at $REGISTRY (LOUD SKIP, not a pass)"; \
  echo "registry-report-contract: SKIP (no registry)"; exit 0; }

result="$(run_check "$REGISTRY" "$KIT")"
n="$(printf '%s' "$result" | cut -f1)"
checked="$(printf '%s' "$result" | cut -f2)"
unchecked="$(printf '%s' "$result" | cut -f3)"
nohook="$(printf '%s' "$result" | cut -f4)"
findings="$(printf '%s' "$result" | cut -f5)"

if [ "$n" -gt 0 ]; then
  write_report "FAIL" "$n gate(s) declare a report path their hook never writes — those gates are unobservable through the registry contract ($checked checked, $unchecked dynamic/uncheckable, $nohook hook-absent)" "$findings"
  echo "registry-report-contract verdict: FAIL — $n mismatch(es) -> $REPORT" >&2
  printf '%s' "$findings" | jq -r '.[]|"  " + .gate + " (" + .hardness + "): registry says " + .registry_declares + ", hook writes " + .hook_writes' >&2
  exit 2
fi

write_report "PASS" "all $checked checkable gates declare the report path their hook writes ($unchecked dynamic/uncheckable, $nohook hook-absent)" "[]"
echo "registry-report-contract verdict: PASS ($checked checked, $unchecked uncheckable, $nohook hook-absent)"
exit 0
