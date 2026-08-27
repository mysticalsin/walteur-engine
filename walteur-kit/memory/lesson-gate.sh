#!/usr/bin/env bash
# walteur-kit/memory/lesson-gate.sh — the CO-LOCATED consolidate write-path that .claude/workflows/walteur.js
# references at line ~1672: `echo '<lesson-json>' | bash walteur-kit/memory/lesson-gate.sh`. Before this file
# existed, that `if exists` branch never fired and walteur.js fell through to a hand-rolled append into the
# WRONG store (~/.walteur/memory), fragmenting the corpus from the co-located walteur-kit/memory/lessons.jsonl
# that recall + the memory gates actually read (panel #6/#7 memory-floor root cause, write side).
#
# What it genuinely does (no overclaim): reads ONE lesson JSON on stdin, DEDUPES against the co-located store
# by normalized .lesson text (case-insensitive, whitespace-collapsed) — a duplicate is skipped, exit 0 — then
# delegates the append to the REAL gate (../hooks/lesson-gate.sh --capture), which stamps id/ts/helpful:0/
# harmful:0/applied:0 and appends one line. Contradiction-hold (conflicts.jsonl) is NOT implemented here and is
# not claimed; scoring lives in the sibling lesson-feedback.sh --drain. jq required (exit 1 if absent).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_GATE="$SELF_DIR/../hooks/lesson-gate.sh"
STORE="$SELF_DIR/lessons.jsonl"
command -v jq >/dev/null 2>&1 || { echo "memory/lesson-gate: jq required, none found — not captured." >&2; exit 1; }
[ -f "$REAL_GATE" ] || { echo "memory/lesson-gate: real gate missing at $REAL_GATE — not captured." >&2; exit 1; }

payload="$(cat)"
new_norm="$(printf '%s' "$payload" | jq -r '(.lesson // "") | ascii_downcase | gsub("\\s+";" ") | gsub("^ | $";"")' 2>/dev/null)"
if [ -z "$new_norm" ]; then
  echo "memory/lesson-gate: invalid input — need JSON with a non-empty .lesson. Not captured." >&2; exit 1
fi
if [ -f "$STORE" ] && jq -e --arg n "$new_norm" '(.lesson // "") | ascii_downcase | gsub("\\s+";" ") | gsub("^ | $";"") | . == $n' "$STORE" >/dev/null 2>&1; then
  echo "memory/lesson-gate: duplicate lesson (same normalized text already in store) — skipped." >&2; exit 0
fi
printf '%s' "$payload" | WALTEUR_MEM="$SELF_DIR" bash "$REAL_GATE" --capture
