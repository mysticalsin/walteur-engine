#!/usr/bin/env bash
# WALTEUR context-compaction-gate — HARD gate (Tony's standing rule). Quality degrades with ABSOLUTE context
# size, not percent of the window — on a 1M window a percent ladder keeps agents reasoning in a degraded zone
# far too long. This enforces automatic, hands-free compaction at absolute token thresholds: the inherited
# working context (briefs + SUMMARY + BATON + STATE — what a fresh turn/agent reads) MUST stay under the
# handoff ceiling, and a build carrying real context MUST declare an automatic compaction policy. This is the
# mechanical half of compaction-policy.json + walteur.js maybeCompact() + the BATON checkpoint vehicle.
#
# Applies when inherited context (briefs/SUMMARY/BATON/STATE) or a LOOP/policy is present. Short build => NA.
# CONTRACT: aggregate context > handoff_at (200k) => FAIL (not compacted) · policy present but misconfigured
# (mode!=automatic / compact_at>150k / handoff_at>200k / human_required) => FAIL · aggregate > compact_at (150k)
# AND no policy => FAIL (must declare auto-compaction at this size) · PAUSED => exit 2 · bypass WALTEUR_COMPACT=off.
# Report: walteur-kit/context-compaction-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "context-compaction-gate - HARD gate (Tonys standing rule). Quality degrades with ABSOLUTE context"
  printf '%s\n' "usage: bash context-compaction-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/context-compaction-report.json - fix recipes: walteur-kit/REMEDIATION.md (## context-compaction-gate)"
  printf '%s\n' "bypass: WALTEUR_COMPACT=off (recorded, not free)"
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
POLICY="$KIT/compaction-policy.json"
REPORT="$KIT/context-compaction-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

# defaults if no policy file (Tony's rule)
DEF_COMPACT=150000; DEF_HANDOFF=200000

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; tok="${3:-0}"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson tok "$tok" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"context-compaction", aggregate_tokens:$tok, findings:$f, reason:$r}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","aggregate_tokens":%s}\n' "$v" "$tok" > "$REPORT" 2>/dev/null || true; }

# inherited working-context files (what a fresh turn/agent reads in)
ctx_files() {
  [ -d "$KIT/briefs" ] && { have find && find "$KIT/briefs" -type f -name '*.md' 2>/dev/null; }
  for p in "$KIT/SUMMARY.jsonl" "$ROOT/_relay/BATON.md" "$ROOT/STATE.json" "$ROOT/STATE.md" "$KIT/loop-state.json"; do [ -f "$p" ] && printf '%s\n' "$p"; done
}
agg_tokens() {
  local total=0 f sz
  while IFS= read -r f; do [ -n "$f" ] || continue; sz=$(wc -c < "$f" 2>/dev/null || echo 0); total=$((total + sz)); done < <(ctx_files)
  echo $((total / 4))   # bytes/4 token proxy
}

applies() { [ -n "$(ctx_files | head -1)" ] || [ -f "$POLICY" ] || [ -f "$ROOT/LOOP.md" ]; }

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused 0; echo "context-compaction-gate: PAUSED -> exit 2"; exit 2; }
  [ "${WALTEUR_COMPACT:-}" = "off" ] && { write_report SKIP bypassed 0; echo "context-compaction-gate: bypassed"; exit 0; }
  if ! have jq; then write_report SKIP "no jq" 0; echo "context-compaction-gate: SKIP"; exit 0; fi
  if ! applies; then write_report NOT_APPLICABLE "no inherited context / loop / policy" 0; echo "context-compaction-gate: NOT_APPLICABLE"; exit 0; fi

  local compact handoff has_policy=0
  compact="$DEF_COMPACT"; handoff="$DEF_HANDOFF"
  if [ -f "$POLICY" ]; then
    has_policy=1
    local mode ca ha hr
    mode="$(jq -r '.mode // ""' "$POLICY" 2>/dev/null)"
    ca="$(jq -r '.compact_at_tokens // empty' "$POLICY" 2>/dev/null | tr -dc '0-9')"
    ha="$(jq -r '.handoff_at_tokens // empty' "$POLICY" 2>/dev/null | tr -dc '0-9')"
    hr="$(jq -r '.human_required // false' "$POLICY" 2>/dev/null)"
    [ -n "$ca" ] && compact="$ca"; [ -n "$ha" ] && handoff="$ha"
    [ "$mode" = "automatic" ] || add_finding policy "compaction-policy.json mode='$mode' (must be 'automatic' — no human in the loop)"
    [ "$hr" = "true" ] && add_finding policy "compaction-policy.json human_required=true — compaction must be hands-free"
    { [ -n "$ca" ] && [ "$ca" -le 150000 ]; } || add_finding policy "compact_at_tokens=${ca:-unset} must be <= 150000 (absolute, not percent)"
    { [ -n "$ha" ] && [ "$ha" -le 200000 ]; } || add_finding policy "handoff_at_tokens=${ha:-unset} must be <= 200000 (quality degrades past this regardless of window)"
  fi

  local tok; tok="$(agg_tokens)"
  if [ "$tok" -gt "$handoff" ]; then
    add_finding ceiling "inherited working context ~${tok} tokens EXCEEDS handoff ceiling ${handoff} — it was not compacted; write the BATON checkpoint and continue fresh"
  elif [ "$tok" -gt "$compact" ] && [ "$has_policy" -eq 0 ]; then
    add_finding policy "inherited context ~${tok} tokens is past the ${compact} compact threshold but no compaction-policy.json declares automatic compaction — add one"
  fi

  if [ "$failures" -gt 0 ]; then
    write_report FAIL "context-compaction policy/ceiling violated (agg ~${tok} tok)" "$tok"
    echo "context-compaction-gate: FAIL (agg ~${tok} tok, compact ${compact}/handoff ${handoff}) -> exit 2"
    printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null | head -12 || true
    exit 2
  fi
  write_report PASS "context ~${tok} tok within compact ${compact}/handoff ${handoff}; auto policy ok" "$tok"
  echo "context-compaction-gate: PASS (~${tok} tok <= ${handoff})"
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "context-compaction selftest SKIP - no jq."; return 0; fi
  echo "context-compaction-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  goodpol() { printf '{"mode":"automatic","compact_at_tokens":150000,"handoff_at_tokens":200000,"human_required":false}\n' > "$1/walteur-kit/compaction-policy.json"; }
  brief() { mkdir -p "$1/walteur-kit/briefs"; perl -e "print 'x' x $2" > "$1/walteur-kit/briefs/w.md"; }   # $2 bytes

  # 1. no context -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/ctxcomp.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no context -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. good policy + small context -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/ctxcomp.XXXXXX")"; mkdir -p "$t/walteur-kit"; goodpol "$t"; brief "$t" 40000; ck "good policy, small ctx -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. G1 policy mode=manual -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/ctxcomp.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"mode":"manual","compact_at_tokens":150000,"handoff_at_tokens":200000,"human_required":false}\n' > "$t/walteur-kit/compaction-policy.json"; brief "$t" 1000; ck "G1 mode=manual -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. G2 handoff_at too high (500k) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/ctxcomp.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"mode":"automatic","compact_at_tokens":150000,"handoff_at_tokens":500000,"human_required":false}\n' > "$t/walteur-kit/compaction-policy.json"; brief "$t" 1000; ck "G2 handoff_at>200k -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. G3 aggregate context over 200k ceiling (900KB ~225k tok) + good policy -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/ctxcomp.XXXXXX")"; mkdir -p "$t/walteur-kit"; goodpol "$t"; brief "$t" 900000; ck "G3 ctx>200k -> FAIL (must compact)" 2 "$(run "$t")"; rm -rf "$t"
  # 6. G4 aggregate over 150k compact threshold but no policy -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/ctxcomp.XXXXXX")"; mkdir -p "$t/walteur-kit"; brief "$t" 700000; ck "G4 ctx>150k, no policy -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. FP guard: small context, no policy -> PASS (short build needs no policy)
  t="$(mktemp -d "${TMPDIR:-/tmp}/ctxcomp.XXXXXX")"; mkdir -p "$t/walteur-kit"; brief "$t" 40000; ck "G5 small ctx, no policy -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 8. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/ctxcomp.XXXXXX")"; mkdir -p "$t/walteur-kit"; brief "$t" 900000; WALTEUR_ROOT="$t" WALTEUR_COMPACT=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/ctxcomp.XXXXXX")"; mkdir -p "$t/walteur-kit"; goodpol "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "context-compaction-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
