# Rule — Memory Discipline (recall before act, capture on the spot)

> PROTOCOL rule (judgment, not a hook). Pure-prompt: zero infra, zero deps. The agent obeys it; nothing
> mechanically enforces it. Lifted from getzep/graphiti `cursor_rules` (MIT) — adapted to the WALTEUR /
> CLAUDE.md mandated nav order. Provenance kept credit-clean.

## 1. BEFORE acting — SEARCH recall surfaces first.

Per the global CLAUDE.md CONTEXT NAVIGATION order (graphify query FIRST, then lessons/sidecars, raw `Read`
last). graphify is the ONE retrieval brain — do not stand up a second index.

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

Per the global HONESTY law (CLAUDE.md / WALTEUR §1): label recall confidence verified · assumed · unknown;
absence from a surface = NOT-FOUND, never PROVEN-ABSENT; re-query a load-bearing memory before relying on it.

---
*Provenance: getzep/graphiti agent-memory `cursor_rules` (MIT) — the search-before-act + capture-preference/
procedure + explicit-update-vs-add spine. Re-pointed at the CLAUDE.md / WALTEUR mandated nav order (graphify
FIRST). PROTOCOL, not HARD — no hook enforces this; it is an operating discipline.*
