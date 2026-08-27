#!/usr/bin/env bash
# walteur-kit/memory/lesson-feedback.sh — the CO-LOCATED feedback drainer that .claude/workflows/walteur.js
# references at line ~1678: `bash walteur-kit/memory/lesson-feedback.sh --drain`. Before this file existed,
# that path was missing, so the MEASURE->ATTRIBUTE half of the self-improvement loop never ran and every
# lesson stayed helpful:0/harmful:0 forever (panel #5/#6/#7: "the helpful/harmful loop is vaporware").
#
# --drain: reads a pending-outcome queue (pending-feedback.jsonl — one {applied_ids:[...], shippable, composite,
# target} per line, appended by a build's self-optimize step), and for each outcome bumps EACH applied lesson's
# counter: helpful++ when the build was good (shippable==true AND composite>=target), else harmful++. Rewrites
# the co-located lessons.jsonl atomically (temp+mv), then clears the drained queue. This is what turns the
# applied_ids telemetry into a real helpful/harmful signal. jq required.
#
# TWO QUEUE PATHS, ON PURPOSE (panel #12 memory finding). This script only ever looked at the CO-LOCATED
# queue ($SELF_DIR/pending-feedback.jsonl), but the only producer in the engine — walteur.js's self-optimize
# step — appends to the GLOBAL one (`>> ~/.walteur/memory/pending-feedback.jsonl`). So a real build's outcome
# landed in a file nothing drained, and helpful/harmful stayed 0 on every row forever. --drain now consumes
# BOTH queues (canonical + global read-replica dir, de-duplicated when they resolve to the same path); each
# queue it actually drains is cleared. Overrides: WALTEUR_MEM (canonical dir), WALTEUR_GLOBAL_MEM (global dir).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
MEM_DIR="${WALTEUR_MEM:-$SELF_DIR}"
GLOBAL_DIR="${WALTEUR_GLOBAL_MEM:-$HOME/.walteur/memory}"
STORE="$MEM_DIR/lessons.jsonl"
PENDING="$MEM_DIR/pending-feedback.jsonl"
GLOBAL_PENDING="$GLOBAL_DIR/pending-feedback.jsonl"

abspath() { # dir/file -> canonical absolute; tolerant of a not-yet-existing file
  local d b; d="$(dirname "$1")"; b="$(basename "$1")"
  if [ -d "$d" ]; then printf '%s/%s' "$(cd "$d" && pwd)" "$b"; else printf '%s' "$1"; fi
}

# Every queue file that EXISTS, de-duplicated by absolute path (canonical first). bash 3.2 safe: plain array.
queue_files() {
  QUEUES=()
  local q seen=""
  for q in "$PENDING" "$GLOBAL_PENDING"; do
    [ -f "$q" ] || continue
    local a; a="$(abspath "$q")"
    case " $seen " in *" $a "*) continue ;; esac
    seen="$seen $a"; QUEUES+=("$q")
  done
  [ "${#QUEUES[@]}" -gt 0 ]
}

drain() {
  command -v jq >/dev/null 2>&1 || { echo "lesson-feedback: jq required." >&2; return 1; }
  if ! queue_files; then
    echo "lesson-feedback: no pending queue at $PENDING or $GLOBAL_PENDING — nothing to drain." >&2; return 0
  fi
  [ -f "$STORE" ] || { echo "lesson-feedback: no store at $STORE." >&2; return 1; }
  local n; n="$(jq -s 'length' "${QUEUES[@]}" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -lt 1 ]; then
    echo "lesson-feedback: pending queue empty — nothing to drain." >&2
    local q; for q in "${QUEUES[@]}"; do : > "$q" 2>/dev/null || true; done
    return 0
  fi
  local deltas
  deltas="$(jq -s '
    reduce .[] as $o ({};
      (($o.applied_ids // [])) as $ids
      | (if ($o.shippable == true) and (($o.composite // 0) >= ($o.target // 0)) then "helpful" else "harmful" end) as $k
      | reduce $ids[] as $id (.; .[$id][$k] = ((.[$id][$k] // 0) + 1)) )
  ' "${QUEUES[@]}" 2>/dev/null)"
  [ -n "$deltas" ] || { echo "lesson-feedback: could not compute deltas." >&2; return 1; }
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/lesson-feedback.XXXXXX")" || return 1
  if jq -c --argjson d "$deltas" '
      .id as $id
      | .helpful = ((.helpful // 0) + ($d[$id].helpful // 0))
      | .harmful = ((.harmful // 0) + ($d[$id].harmful // 0))
    ' "$STORE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$STORE"
    local q; for q in "${QUEUES[@]}"; do : > "$q" 2>/dev/null || true; done
    echo "lesson-feedback: drained $n outcome(s) from ${#QUEUES[@]} queue(s); helpful/harmful counters updated -> $STORE" >&2
    return 0
  fi
  rm -f "$tmp"; echo "lesson-feedback: rewrite failed — store unchanged." >&2; return 1
}

# --status: HONEST observability for the MEASURE->ATTRIBUTE half. Reports the real counts (never invents any):
# store rows, rows with a non-zero helpful/harmful, and the depth of each queue. Exit 0 always; this is a
# read-only report, not a gate.
status() {
  command -v jq >/dev/null 2>&1 || { echo "lesson-feedback --status: jq required." >&2; return 1; }
  local rows=0 h=0 hm=0 ap=0
  if [ -f "$STORE" ]; then
    rows="$(jq -s 'length' "$STORE" 2>/dev/null || echo 0)"
    h="$(jq -s '[.[] | select((.helpful // 0) > 0)] | length' "$STORE" 2>/dev/null || echo 0)"
    hm="$(jq -s '[.[] | select((.harmful // 0) > 0)] | length' "$STORE" 2>/dev/null || echo 0)"
    ap="$(jq -s '[.[] | select((.applied // 0) > 0)] | length' "$STORE" 2>/dev/null || echo 0)"
  fi
  printf 'store: %s (%s rows) · applied>0: %s · helpful>0: %s · harmful>0: %s\n' "$STORE" "$rows" "$ap" "$h" "$hm"
  local q d
  for q in "$PENDING" "$GLOBAL_PENDING"; do
    if [ -f "$q" ]; then d="$(jq -s 'length' "$q" 2>/dev/null || echo 0)"; else d="absent"; fi
    printf 'queue: %s · pending outcomes: %s\n' "$q" "$d"
  done
  [ "$h" = "0" ] && [ "$hm" = "0" ] && printf '%s\n' "note: no lesson has been scored yet — attribution has produced no real signal on this store (not fabricated)."
  return 0
}

selftest() {
  local pass=0 fail=0 tmp
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  ck(){ if [ "$2" = "$3" ]; then echo "  ok   - $1"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  echo "lesson-feedback selftest:"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/lf-self.XXXXXX")" || return 1
  # Hermetic: every invocation pins BOTH dirs, so the selftest can never read or clear the real
  # ~/.walteur/memory queue.
  mkdir -p "$tmp/global"
  run() { WALTEUR_MEM="$tmp" WALTEUR_GLOBAL_MEM="$tmp/global" bash "$SELF_PATH" "$@"; }
  printf '%s\n' '{"id":"L1","lesson":"a","helpful":0,"harmful":0}' '{"id":"L2","lesson":"b","helpful":0,"harmful":0}' > "$tmp/lessons.jsonl"
  printf '%s\n' '{"applied_ids":["L1"],"shippable":true,"composite":9,"target":8.5}' '{"applied_ids":["L2"],"shippable":false,"composite":5,"target":8.5}' '{"applied_ids":["L1"],"shippable":true,"composite":8.6,"target":8.5}' > "$tmp/pending-feedback.jsonl"
  run --drain >/dev/null 2>&1; ck "drain exit 0" 0 "$?"
  ck "L1 helpful==2 (two good builds)" 2 "$(jq -r 'select(.id=="L1").helpful' "$tmp/lessons.jsonl")"
  ck "L1 harmful==0" 0 "$(jq -r 'select(.id=="L1").harmful' "$tmp/lessons.jsonl")"
  ck "L2 harmful==1 (one bad build)" 1 "$(jq -r 'select(.id=="L2").harmful' "$tmp/lessons.jsonl")"
  ck "pending queue cleared" 0 "$(wc -l < "$tmp/pending-feedback.jsonl" | tr -d ' ')"
  # empty-drain is a clean no-op
  run --drain >/dev/null 2>&1; ck "empty drain exit 0" 0 "$?"

  # ---- REGRESSION (panel #12): the GLOBAL queue is what walteur.js's self-optimize step actually writes
  # (`>> ~/.walteur/memory/pending-feedback.jsonl`). A drain that ignores it scores nothing. Prove it lands.
  rm -f "$tmp/pending-feedback.jsonl"
  printf '%s\n' '{"id":"L1","lesson":"a","helpful":0,"harmful":0}' '{"id":"L2","lesson":"b","helpful":0,"harmful":0}' > "$tmp/lessons.jsonl"
  printf '%s\n' '{"applied_ids":["L1","L2"],"shippable":true,"composite":9.1,"target":8.5}' > "$tmp/global/pending-feedback.jsonl"
  run --drain >/dev/null 2>&1; ck "global-only queue -> drain exit 0" 0 "$?"
  ck "global queue scored L1 helpful==1" 1 "$(jq -r 'select(.id=="L1").helpful' "$tmp/lessons.jsonl")"
  ck "global queue scored L2 helpful==1" 1 "$(jq -r 'select(.id=="L2").helpful' "$tmp/lessons.jsonl")"
  ck "global queue cleared after drain" 0 "$(wc -l < "$tmp/global/pending-feedback.jsonl" | tr -d ' ')"
  # BOTH queues at once, and no double-counting of a single outcome
  printf '%s\n' '{"id":"L1","lesson":"a","helpful":0,"harmful":0}' > "$tmp/lessons.jsonl"
  printf '%s\n' '{"applied_ids":["L1"],"shippable":true,"composite":9,"target":8.5}' > "$tmp/pending-feedback.jsonl"
  printf '%s\n' '{"applied_ids":["L1"],"shippable":false,"composite":4,"target":8.5}' > "$tmp/global/pending-feedback.jsonl"
  run --drain >/dev/null 2>&1; ck "both queues -> drain exit 0" 0 "$?"
  ck "both queues: helpful==1" 1 "$(jq -r 'select(.id=="L1").helpful' "$tmp/lessons.jsonl")"
  ck "both queues: harmful==1" 1 "$(jq -r 'select(.id=="L1").harmful' "$tmp/lessons.jsonl")"
  # same-path guard: canonical dir == global dir must not double-count one queue file
  printf '%s\n' '{"id":"L1","lesson":"a","helpful":0,"harmful":0}' > "$tmp/lessons.jsonl"
  printf '%s\n' '{"applied_ids":["L1"],"shippable":true,"composite":9,"target":8.5}' > "$tmp/pending-feedback.jsonl"
  WALTEUR_MEM="$tmp" WALTEUR_GLOBAL_MEM="$tmp" bash "$SELF_PATH" --drain >/dev/null 2>&1
  ck "same-dir queue counted once (helpful==1, not 2)" 1 "$(jq -r 'select(.id=="L1").helpful' "$tmp/lessons.jsonl")"
  # --status is read-only and reports the real, un-invented counts
  run --status >/dev/null 2>&1; ck "--status exit 0" 0 "$?"
  ck "--status did not mutate the store" 1 "$(jq -r 'select(.id=="L1").helpful' "$tmp/lessons.jsonl")"

  # no store -> fail
  rm -f "$tmp/lessons.jsonl"; printf '%s\n' '{"applied_ids":["L1"],"shippable":true,"composite":9,"target":8.5}' > "$tmp/pending-feedback.jsonl"
  run --drain >/dev/null 2>&1; ck "no store -> exit 1" 1 "$?"
  # no queue at all -> clean no-op exit 0
  rm -f "$tmp/pending-feedback.jsonl" "$tmp/global/pending-feedback.jsonl"
  run --drain >/dev/null 2>&1; ck "no queue anywhere -> exit 0" 0 "$?"
  rm -rf "$tmp"
  echo "lesson-feedback selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --drain) drain; exit $? ;;
  --status) status; exit $? ;;
  --selftest) selftest; exit $? ;;
  -h|--help) printf '%s\n' "lesson-feedback.sh --drain | --status | --selftest — bump helpful/harmful on applied lessons from the pending-outcome queue(s)." \
    "queues: \${WALTEUR_MEM:-<script dir>}/pending-feedback.jsonl AND \${WALTEUR_GLOBAL_MEM:-\$HOME/.walteur/memory}/pending-feedback.jsonl (walteur.js writes the latter)"; exit 0 ;;
  *) echo "usage: lesson-feedback.sh --drain | --status | --selftest" >&2; exit 2 ;;
esac
