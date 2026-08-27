# lessons.jsonl — schema bump (bi-temporal lite, stolen from graphiti's PATTERN not its engine)
# Targets: walteur-starter/walteur-kit/memory/  (the non-git canonical kit). Store: $WALTEUR_MEM (default ~/.walteur/memory/lessons.jsonl)
# ZERO new deps. Defers valid_from / point-in-time replay (YAGNI). Recall-scaling routes through graphify, never a 2nd KG.

## Existing per-lesson fields (DO NOT break — from lesson-gate.sh:56 + lesson-feedback.sh:35)
#   id, lesson, ts, helpful, harmful, applied   (+ whatever the candidate carried: why, domain, stack, confidence, ...)

## TWO new fields — both OPTIONAL and NULLABLE:
#   invalidated_at : ISO-8601 string  | null    null = the lesson's window is OPEN (currently valid / served by RECALL)
#                                              a timestamp = the window was CLOSED at that instant; RECALL stops serving it
#   source_build   : string (build id / audit ref, e.g. "audit-2026-06-15-a1b2c3") | null   provenance: which build PRODUCED this lesson
#
# Optional companion stamps written ONLY when a window is closed by supersession (audit-friendly, not required):
#   superseded_by  : the source_build (or id) of the lesson that closed this one

## BACK-COMPAT RULE (no migration, no break) — THE LOAD-BEARING INVARIANT
# An OLD row written before this bump has NEITHER field. Every reader treats a MISSING field as null:
#   current?      ->  (.invalidated_at // null) == null      # missing OR explicit null  => currently valid
#   provenance?   ->  (.source_build  // null)               # missing => unknown provenance, still served
# So: old lessons are served exactly as before; we NEVER rewrite a row to add the fields. A row only ever gains
# invalidated_at the moment it is actually superseded (lazy, lazy-write). No batch migration step exists or is needed.

## CONSOLIDATE writes the fields forward (new lessons only):
#   echo "$candidate" | jq -c --arg src "$BUILD_ID" '. + {invalidated_at:null, source_build:$src}' | lesson-gate.sh
# (lesson-gate.sh already passes through unknown keys, so this just flows in.)
