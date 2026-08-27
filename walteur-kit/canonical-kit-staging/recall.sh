#!/usr/bin/env bash
# WALTEUR RECALL — pull ONLY currently-valid lessons before PLAN. Targets walteur-starter/walteur-kit/memory/.
# The single behavioural change from before: a CLOSED window (invalidated_at != null) is never served.
# Back-compat: an OLD lesson missing the field reads as null => current => served (no migration).
# Usage:  recall.sh [N]   (default 12, matching the soft store cap)
set -uo pipefail
MEM="${WALTEUR_MEM:-$HOME/.walteur/memory/lessons.jsonl}"
N="${1:-12}"
[ -s "$MEM" ] || { echo '[]'; exit 0; }

# current-only filter + rank by (helpful-harmful) desc then newest; emit a compact JSON array for the PLAN prompt.
jq -c -s '
  map(select((.invalidated_at // null) == null))                 # THE FILTER: open windows only (missing field == open)
  | sort_by(((.helpful // 0) - (.harmful // 0)), (.ts // ""))     # most-proven-helpful first
  | reverse
  | .[0:'"$N"']
  | map({id, lesson, helpful, harmful, applied, source_build})    # provenance travels to PLAN so applied-ids can be attributed
' "$MEM"
