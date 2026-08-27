#!/usr/bin/env bash
# walteur-kit/memory/memory-sync.sh — project the CANONICAL co-located lessons corpus into the
# GLOBAL read-replica that walteur.js's recall agent reads.
#
# WHY: walteur.js:439 recall does a raw `cat ~/.walteur/memory/lessons.jsonl`. But the campaign
# corpus lives CO-LOCATED at walteur-kit/memory/lessons.jsonl (B61's anti-fragmentation decision,
# write side). So recall reads an empty/absent global file and returns [] on every real build —
# panels #6/#7 memory-floor root cause, READ side. This projects canonical -> global so recall
# actually finds the corpus, WITHOUT editing the human-gated walteur.js.
#
# NOT fragmentation: the global file is a DERIVED read-replica, regenerated wholesale from canonical,
# never an independent write target. --verify enforces replica == canonical (drift fails closed).
# Idempotent, atomic (temp+mv), best-effort (a sandbox-denied global write must never fail a capture).
#
# Modes: (default|--project) project canonical->global · --verify assert replica==canonical ·
#        --selftest hermetic offline tests (never touches real ~/.walteur) · --help.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CANON="${WALTEUR_MEM:-$SELF_DIR}/lessons.jsonl"            # canonical co-located store
GLOBAL_DIR="${WALTEUR_GLOBAL_MEM:-$HOME/.walteur/memory}"  # exactly what walteur.js:439 recall reads
GLOBAL="$GLOBAL_DIR/lessons.jsonl"

abspath() { # dir/file -> canonical absolute; tolerant of a not-yet-existing file
  local d b; d="$(dirname "$1")"; b="$(basename "$1")"
  if [ -d "$d" ]; then printf '%s/%s' "$(cd "$d" && pwd)" "$b"; else printf '%s' "$1"; fi
}
same_file() { [ "$(abspath "$1")" = "$(abspath "$2")" ]; }

usage() {
  printf '%s\n' "memory-sync - project the canonical co-located lessons corpus into the global read-replica"
  printf '%s\n' "  that walteur.js recall reads (~/.walteur/memory/lessons.jsonl). One-directional, non-fragmenting."
  printf '%s\n' "usage: bash memory-sync.sh [--project(default)|--verify|--selftest|--help]"
  printf '%s\n' "canonical: \${WALTEUR_MEM:-<script dir>}/lessons.jsonl   global: \${WALTEUR_GLOBAL_MEM:-\$HOME/.walteur/memory}/lessons.jsonl"
}

project() {
  if [ ! -f "$CANON" ]; then
    echo "memory-sync: no canonical store at $CANON - nothing to project." >&2; return 0
  fi
  if same_file "$CANON" "$GLOBAL"; then
    return 0   # canonical already IS the global path (no co-located store) - nothing to do
  fi
  mkdir -p "$GLOBAL_DIR" 2>/dev/null || { echo "memory-sync: cannot create $GLOBAL_DIR" >&2; return 1; }
  local tmp
  tmp="$(mktemp "$GLOBAL_DIR/.lessons.XXXXXX" 2>/dev/null)" || { echo "memory-sync: mktemp failed in $GLOBAL_DIR" >&2; return 1; }
  if cat "$CANON" > "$tmp" 2>/dev/null && mv -f "$tmp" "$GLOBAL" 2>/dev/null; then
    echo "memory-sync: projected $(grep -c '' "$CANON" 2>/dev/null | tr -d ' ') lesson(s) -> $GLOBAL" >&2
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  echo "memory-sync: projection write failed ($GLOBAL)" >&2; return 1
}

verify() {  # replica must equal canonical byte-for-byte; drift/absence = fail closed
  if [ ! -f "$CANON" ]; then echo "memory-sync --verify: no canonical store at $CANON." >&2; return 1; fi
  if same_file "$CANON" "$GLOBAL"; then return 0; fi
  if [ ! -f "$GLOBAL" ]; then echo "memory-sync --verify: replica absent at $GLOBAL." >&2; return 1; fi
  if cmp -s "$CANON" "$GLOBAL"; then return 0; fi
  echo "memory-sync --verify: replica DRIFTED from canonical ($GLOBAL != $CANON)." >&2; return 1
}

selftest() {
  local base pass=0 fail=0
  base="$(mktemp -d "${TMPDIR:-/tmp}/memsync.XXXXXX")" || { echo "memory-sync --selftest: mktemp -d failed"; return 1; }
  local cd="$base/canon" gd="$base/global" sd="$base/same"
  mkdir -p "$cd" "$gd" "$sd"
  ok() { if [ "$1" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $2"; fi; }

  printf '{"id":"L1","lesson":"a"}\n{"id":"L2","lesson":"b"}\n{"id":"L3","lesson":"c"}\n' > "$cd/lessons.jsonl"

  # 1. project creates replica byte-identical to canonical
  WALTEUR_MEM="$cd" WALTEUR_GLOBAL_MEM="$gd" bash "$0" >/dev/null 2>&1
  cmp -s "$cd/lessons.jsonl" "$gd/lessons.jsonl"; ok $? "project did not create a matching replica"

  # 2. --verify passes when in sync
  WALTEUR_MEM="$cd" WALTEUR_GLOBAL_MEM="$gd" bash "$0" --verify >/dev/null 2>&1; ok $? "verify should pass when synced"

  # 3. re-projection after canonical grows leaves NO staleness
  printf '{"id":"L4","lesson":"d"}\n' >> "$cd/lessons.jsonl"
  WALTEUR_MEM="$cd" WALTEUR_GLOBAL_MEM="$gd" bash "$0" >/dev/null 2>&1
  cmp -s "$cd/lessons.jsonl" "$gd/lessons.jsonl"; ok $? "re-projection left a stale replica"

  # 4. REFUTATION: a divergent replica is overwritten to match canonical (no fork survives)
  printf 'GARBAGE DIVERGENT LINE\n' > "$gd/lessons.jsonl"
  WALTEUR_MEM="$cd" WALTEUR_GLOBAL_MEM="$gd" bash "$0" >/dev/null 2>&1
  cmp -s "$cd/lessons.jsonl" "$gd/lessons.jsonl"; ok $? "divergent replica not corrected (fragmentation)"

  # 5. REFUTATION: --verify FAILS on drift
  printf 'DRIFT\n' >> "$gd/lessons.jsonl"
  if WALTEUR_MEM="$cd" WALTEUR_GLOBAL_MEM="$gd" bash "$0" --verify >/dev/null 2>&1; then ok 1 "verify should catch drift"; else ok 0 ""; fi

  # 6. missing canonical -> project is a graceful no-op (exit 0)
  rm -f "$cd/lessons.jsonl"
  WALTEUR_MEM="$cd" WALTEUR_GLOBAL_MEM="$gd" bash "$0" >/dev/null 2>&1; ok $? "missing-canonical project should exit 0"

  # 7. same-file guard (canonical path == global path) is a no-op, exit 0, no clobber
  printf '{"id":"X","lesson":"x"}\n' > "$sd/lessons.jsonl"
  WALTEUR_MEM="$sd" WALTEUR_GLOBAL_MEM="$sd" bash "$0" >/dev/null 2>&1
  local r=$?; [ "$r" -eq 0 ] && [ "$(grep -c '' "$sd/lessons.jsonl")" -eq 1 ]; ok $? "same-file no-op mishandled"

  rm -rf "$base"
  echo "memory-sync --selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest ;;
  --verify)   verify ;;
  --help|-h)  usage ;;
  ""|--project) project ;;
  *) echo "memory-sync: unknown arg '$1'" >&2; usage; exit 2 ;;
esac
