# Rule — Memory Discipline (recall before act, capture on the spot)

> PROTOCOL rule (judgment, not a hook). Pure-prompt: zero infra, zero deps. The agent obeys it; nothing
> mechanically enforces it. Lifted from getzep/graphiti `cursor_rules` (MIT) — adapted to the WALTEUR /
> CLAUDE.md mandated nav order. Provenance kept credit-clean.

## 1. BEFORE acting — SEARCH recall surfaces, in this order. Skip none.

The order is the CLAUDE.md mandated nav order. graphify is the ONE retrieval brain — do not stand up a
second index. Recall is a graphify query first, then the cheaper local sidecars.

1. `/graphify query "<the thing you are about to do / decide>"` — FIRST, always. The knowledge graph is
   the canonical recall surface. A partial memory of a fact is NOT recall — query it.
2. `lessons.jsonl` (and `_agent_state/<agent>/memory.json:recent_learnings`) — the lessons loop. Read the
   relevant past corrections before repeating one. Absence of a lesson = NOT-FOUND, never proven-safe.
3. subconscious / session sidecars — last, only if 1–2 returned nothing useful.

Raw `Read` of source files is the LAST resort, per the mandated order — not the first move.

## 2. CAPTURE the moment the user states a durable fact. Do not wait for the end of the turn.

The instant the user states a lasting want, name a convention, or correct you — capture it THEN, before
you act on it. A preference stated and not captured is a preference you will violate next session.

- **Preference** — a standing want about HOW (style, tool, tone, a "from now on / always / never / I
  prefer"). Capture verbatim-ish, ≤25 words.
- **Procedure** — a standing want about a SEQUENCE (a repeatable how-to, an ordering, a checklist step).
  Capture as ordered steps.

A correction is both a lesson (§1.2) AND usually a Preference/Procedure. Capture both.

## 3. Be EXPLICIT about update-vs-add. Never silently overwrite, never silently duplicate.

Before writing memory, decide and SAY which one:

- **UPDATE** — the new fact supersedes an existing one (same subject, changed value). Edit in place; note
  what changed. Do not leave the stale fact to contradict the fresh one.
- **ADD** — the fact is new (no prior entry for this subject). Append.

If unsure whether a prior entry exists → query the surface (§1) first. Adding a duplicate that contradicts
an old entry is a recall failure, not a capture win.

## 4. Honesty law (binds memory like every WALTEUR surface).

Label recall confidence: `verified` (read it this session) · `assumed` (recalled, not re-checked) ·
`unknown`. Absence from a surface = NOT-FOUND, never PROVEN-ABSENT. Never sell "I have a memory of X" as
"X is current" — re-query if it is load-bearing.

---
*Provenance: getzep/graphiti agent-memory `cursor_rules` (MIT) — the search-before-act + capture-preference/
procedure + explicit-update-vs-add spine. Re-pointed at the CLAUDE.md / WALTEUR mandated nav order (graphify
FIRST). PROTOCOL, not HARD — no hook enforces this; it is an operating discipline.*
