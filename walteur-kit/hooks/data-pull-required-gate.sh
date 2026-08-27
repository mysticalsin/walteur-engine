#!/usr/bin/env bash
# WALTEUR data-pull-required-gate — HARD gate (S033 mcp-data U4). Kills the "passes-by-being-empty" hole:
# data-acquisition-gate.sh only arms when walteur-kit/data-acquisition.json EXISTS — but nothing forces a
# data-needing build to ever write that manifest, so a research report / market analysis / data pipeline
# that never pulled real data sails through every gate as NOT_APPLICABLE. This gate closes that gap from
# the OTHER direction: it arms on the build's OWN declaration that it needs live external data, independent
# of whether an acquisition manifest was ever produced, and demands a real, fresh breadcrumb trail.
#
# ARMS when EITHER:
#   · walteur-kit/build-contract.json has .data_needs == true, OR
#   · walteur-kit/preflight-signals.json has .needs_external_data == true
# Neither present/true => NOT_APPLICABLE exit 0 (detect-or-skip; a build with no declared data need is not
# a violation — mirrors the data-acquisition-gate convention exactly).
#
# CONTRACT (armed) — FAIL exit 2 if ANY:
#   · walteur-kit/acquisition-log.jsonl absent
#   · the log has zero well-formed lines
#   · every line's artifact is missing/empty/<64 bytes on disk (closes the 1-byte-stub hole that
#     data-acquisition-gate.sh's output_ref check alone does not: a content floor, not just non-empty)
#   · every line falls outside the freshness window (declared-but-stale is the same as declared-but-empty
#     for the purpose of this gate: proof the CURRENT build pulled data, not a prior one)
#   PASS when >=1 line is well-formed, has a real (>=64 byte) artifact on disk, AND is fresh.
#   PAUSED => exit 2 · bypass WALTEUR_DATAPULL=off => loud SKIP exit 0.
#
# Each acquisition-log.jsonl line: {ts, source, query_or_url, artifact, bytes}
#   ts            RFC3339 UTC timestamp of the pull
#   source        tool/channel used (e.g. a data-tools.json id, "WebSearch", "WebFetch")
#   query_or_url  the query string or URL pulled
#   artifact      path (repo-relative or absolute) to the captured file on disk — MUST exist, MUST be >=64B
#   bytes         declared byte count (informational; the gate independently stats the file — a mismatched
#                 declaration is not itself a failure, the on-disk floor is what's enforced)
#
# Freshness: a line's ts must fall within WALTEUR_DATAPULL_WINDOW_H hours (default 24) of "now", OR within
# that same window of build-contract.json's created_at if present (whichever anchor exists) — either anchor
# proves the pull happened inside THIS build's window, not a stale leftover from a previous run.
#
# Zero-dep: bash + jq. Report: walteur-kit/data-pull-required-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "data-pull-required-gate - HARD gate (S033 mcp-data U4). Kills the passes-by-being-empty hole:"
  printf '%s\n' "usage: bash data-pull-required-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/data-pull-required-report.json - fix recipes: walteur-kit/REMEDIATION.md (## data-pull-required-gate)"
  printf '%s\n' "bypass: WALTEUR_DATAPULL=off (recorded, not free)"
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
CONTRACT="$KIT/build-contract.json"
SIGNALS="$KIT/preflight-signals.json"
LOG="$KIT/acquisition-log.jsonl"
REPORT="$KIT/data-pull-required-report.json"
MIN_BYTES="${WALTEUR_DATAPULL_MIN_BYTES:-64}"
WINDOW_H="${WALTEUR_DATAPULL_WINDOW_H:-24}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
epoch() {
  # RFC3339 UTC ("...Z") -> epoch seconds. GNU date supports -d directly; BSD/macOS date has no -d
  # and needs -j -f with an explicit strptime format instead - try GNU first, then BSD, else empty.
  date -u -d "$1" +%s 2>/dev/null && return 0
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null && return 0
  echo ""
}

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"data-pull-required", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"data-pull-required","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

applies() {
  have jq || return 1
  [ -f "$CONTRACT" ] && jq -e '.data_needs == true' "$CONTRACT" >/dev/null 2>&1 && return 0
  [ -f "$SIGNALS" ] && jq -e '.needs_external_data == true' "$SIGNALS" >/dev/null 2>&1 && return 0
  return 1
}

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused; echo "data-pull-required-gate: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_DATAPULL:-}" = "off" ] && { write_report SKIP "bypassed via WALTEUR_DATAPULL=off"; echo "data-pull-required-gate: SKIP — WALTEUR_DATAPULL=off (loud skip)" >&2; exit 0; }
  if ! have jq; then write_report SKIP "jq not installed"; echo "data-pull-required-gate: SKIP (no jq)" >&2; exit 0; fi
  if ! applies; then write_report NOT_APPLICABLE "no data_needs (build-contract.json) or needs_external_data (preflight-signals.json) declared true"; echo "data-pull-required-gate: NOT_APPLICABLE" >&2; exit 0; fi

  if [ ! -f "$LOG" ]; then
    add_finding log "build declares data_needs/needs_external_data but walteur-kit/acquisition-log.jsonl is ABSENT — no acquisition breadcrumb exists for this build"
    write_report FAIL "no acquisition-log.jsonl"; echo "data-pull-required-gate: FAIL (no acquisition-log.jsonl) -> exit 2" >&2; exit 2
  fi

  # anchor for the freshness window: build-contract.json created_at if present and parseable, else "now"
  local anchor_epoch now_epoch
  now_epoch="$(date -u +%s)"
  anchor_epoch="$now_epoch"
  if [ -f "$CONTRACT" ]; then
    local created; created="$(jq -r '.created_at // ""' "$CONTRACT" 2>/dev/null)"
    if [ -n "$created" ]; then
      local ce; ce="$(epoch "$created")"
      [ -n "$ce" ] && anchor_epoch="$ce"
    fi
  fi
  local window_s=$(( WINDOW_H * 3600 ))

  local total=0 good=0 line lts lsrc lart lqu lbytes fullpath fsize lep diff
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "${line//[[:space:]]/}" ] && continue
    total=$((total+1))
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      add_finding "line[$total]" "acquisition-log.jsonl line $total is not valid JSON"
      continue
    fi
    lts="$(printf '%s' "$line" | jq -r '.ts // ""')"
    lsrc="$(printf '%s' "$line" | jq -r '.source // ""')"
    lqu="$(printf '%s' "$line" | jq -r '.query_or_url // ""')"
    lart="$(printf '%s' "$line" | jq -r '.artifact // ""')"
    lbytes="$(printf '%s' "$line" | jq -r '.bytes // 0')"

    if [ -z "$lts" ] || [ -z "$lsrc" ] || [ -z "$lqu" ] || [ -z "$lart" ]; then
      add_finding "line[$total]" "acquisition-log.jsonl line $total missing a required field (ts/source/query_or_url/artifact)"
      continue
    fi

    fullpath="$lart"; [ -f "$lart" ] || fullpath="$ROOT/$lart"
    if [ ! -f "$fullpath" ]; then
      add_finding "line[$total].artifact" "artifact '$lart' does not exist on disk — no proof of what was pulled"
      continue
    fi
    fsize="$(wc -c < "$fullpath" 2>/dev/null | tr -d ' ')"
    if [ -z "$fsize" ] || [ "$fsize" -lt "$MIN_BYTES" ]; then
      add_finding "line[$total].artifact" "artifact '$lart' is ${fsize:-0} bytes — below the ${MIN_BYTES}-byte content floor (a stub file is not a real pull)"
      continue
    fi

    lep="$(epoch "$lts")"
    if [ -z "$lep" ]; then
      add_finding "line[$total].ts" "acquisition-log.jsonl line $total has an unparseable ts '$lts'"
      continue
    fi
    diff=$(( anchor_epoch - lep )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
    if [ "$diff" -gt "$window_s" ]; then
      add_finding "line[$total].ts" "artifact '$lart' pulled at $lts is outside the ${WINDOW_H}h freshness window — looks like a stale leftover, not proof this build pulled data"
      continue
    fi

    good=$((good+1))
  done < "$LOG"

  if [ "$total" -eq 0 ]; then
    add_finding log "acquisition-log.jsonl exists but has zero lines — declared-but-empty is the exact hole this gate closes"
    write_report FAIL "acquisition-log.jsonl empty"; echo "data-pull-required-gate: FAIL (acquisition-log.jsonl empty) -> exit 2" >&2; exit 2
  fi

  if [ "$good" -eq 0 ]; then
    write_report FAIL "$failures acquisition breadcrumb violation(s) — no valid/fresh/real pull found among $total line(s)"
    echo "data-pull-required-gate: FAIL (0/$total lines valid — $failures issue(s)) -> exit 2" >&2
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null | head -15 >&2 || true
    exit 2
  fi

  write_report PASS "$good/$total acquisition breadcrumb(s) valid: real artifact >=${MIN_BYTES}B, fresh within ${WINDOW_H}h"
  echo "data-pull-required-gate: PASS ($good/$total valid breadcrumb(s))" >&2
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "data-pull-required selftest SKIP — need jq."; return 0; fi
  echo "data-pull-required-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
  seed_contract() { mkdir -p "$1/walteur-kit"; jq -n --argjson dn "$2" --arg ts "$(now)" '{schema_version:1, contract_id:"selftest", request:{summary:"x",user_outcome:"x",primary_user:"x",non_goals:["x"]}, build_class:"software", risk_tier:"low", data_classification:"public", success_metrics:[], constraints:[], interfaces:[], verification:[], evidence_required:[], unknowns:[], created_at:$ts, data_needs:$dn}' > "$1/walteur-kit/build-contract.json"; }
  seed_signal() { mkdir -p "$1/walteur-kit"; jq -n --argjson n "$2" '{needs_external_data:$n}' > "$1/walteur-kit/preflight-signals.json"; }
  good_artifact() { mkdir -p "$1/walteur-kit/data"; printf '%s' "$(head -c 200 /dev/zero | tr '\0' 'x')captured research content here, well above the byte floor for a real pull, not a stub." > "$1/walteur-kit/data/cap1.md"; }
  log_line() { # $1=root $2=ts $3=source $4=query $5=artifact
    printf '{"ts":"%s","source":"%s","query_or_url":"%s","artifact":"%s","bytes":300}\n' "$2" "$3" "$4" "$5" >> "$1/walteur-kit/acquisition-log.jsonl"
  }

  # 1. neither contract nor signal declares data need -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no data_needs / needs_external_data -> NA" 0 "$(run "$t")"; rm -rf "$t"

  # 2. data_needs=false explicitly -> NA (declared, but declared false)
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; seed_contract "$t" false; ck "data_needs:false -> NA" 0 "$(run "$t")"; rm -rf "$t"

  # 3. THE KEY CASE: data_needs true, NO acquisition-log.jsonl at all -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; seed_contract "$t" true; ck "data_needs true + NO log -> FAIL (no gate could catch this before)" 2 "$(run "$t")"; rm -rf "$t"

  # 4. data_needs true + log with 1 real, fresh artifact -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; seed_contract "$t" true; good_artifact "$t"; log_line "$t" "$(now)" "firecrawl" "https://example.com/docs" "walteur-kit/data/cap1.md"; ck "data_needs true + 1 real fresh breadcrumb -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 5. declared true + acquisition-log.jsonl EXISTS but EMPTY -> FAIL (declared-but-empty, the exact hole)
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; seed_contract "$t" true; mkdir -p "$t/walteur-kit"; : > "$t/walteur-kit/acquisition-log.jsonl"; ck "declared true + empty log -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 6. content floor: artifact exists but is a 1-byte stub -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; seed_contract "$t" true; mkdir -p "$t/walteur-kit/data"; printf 'x' > "$t/walteur-kit/data/stub.md"; log_line "$t" "$(now)" "firecrawl" "https://example.com" "walteur-kit/data/stub.md"; ck "1-byte stub artifact -> FAIL (content floor)" 2 "$(run "$t")"; rm -rf "$t"

  # 7. artifact path missing entirely -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; seed_contract "$t" true; mkdir -p "$t/walteur-kit"; log_line "$t" "$(now)" "firecrawl" "https://example.com" "walteur-kit/data/nope.md"; ck "artifact missing on disk -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 8. stale breadcrumb (outside freshness window) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; seed_contract "$t" true; good_artifact "$t"; log_line "$t" "2020-01-01T00:00:00Z" "firecrawl" "https://example.com" "walteur-kit/data/cap1.md"; ck "stale ts (2020) -> FAIL (freshness window)" 2 "$(run "$t")"; rm -rf "$t"

  # 9. preflight-signals.json needs_external_data:true (no build-contract.json at all) + real breadcrumb -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; seed_signal "$t" true; good_artifact "$t"; log_line "$t" "$(now)" "WebSearch" "site:example.com pricing" "walteur-kit/data/cap1.md"; ck "signals-only needs_external_data true + breadcrumb -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 10. preflight-signals.json needs_external_data:false, no contract -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; seed_signal "$t" false; ck "signals needs_external_data:false -> NA" 0 "$(run "$t")"; rm -rf "$t"

  # 11. malformed JSONL line -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; seed_contract "$t" true; mkdir -p "$t/walteur-kit"; printf 'not-json-at-all\n' > "$t/walteur-kit/acquisition-log.jsonl"; ck "malformed JSONL line -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 12. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; seed_contract "$t" true; WALTEUR_ROOT="$t" WALTEUR_DATAPULL=off bash "$SELF" >/dev/null 2>&1; ck "bypass WALTEUR_DATAPULL=off -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/datapullre.XXXXXX")"; seed_contract "$t" true; good_artifact "$t"; log_line "$t" "$(now)" "firecrawl" "https://example.com" "walteur-kit/data/cap1.md"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "data-pull-required-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
