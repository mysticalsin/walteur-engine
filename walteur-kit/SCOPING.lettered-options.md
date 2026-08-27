# Scoping convention — lettered options (A/B/C/D)

> The clarifying-question format for WALTEUR's ≤5 scoping questions (§ ask-before-build). Pure-prompt, zero
> infra. Lifted from snarktank/ai-dev-tasks `create-prd` (MIT) — the "provide options in letter/number lists
> so the user can respond easily" convention. Credit-clean.

## The rule

Every clarifying question that is ENUMERABLE (the answer is a choice from a small set) MUST offer lettered
options — **A / B / C / D**. The human then replies COMPACTLY by number+letter: `1A, 2C, 3B`. No prose answer
required, no re-typing the question. This is what keeps the ≤5-question budget cheap for the human.

- One question per line, numbered. Options lettered A–D under it (or inline if short).
- Always include an escape hatch as the last option: **D) other / none / not sure — I'll explain.** Never
  force a false choice; "not sure" is a valid, captured answer.
- Only letter the ENUMERABLE questions. A genuinely open question (free-text only — a name, a URL, a number)
  stays open; do not fake options for it.
- The human's compact reply (`1A, 2C…`) is the recorded scoping answer — feed it straight into the PRD /
  PLAN. Unanswered numbers = NOT-FOUND, never assume a default silently (state any default you fall back to).

## Example (2 lines — paste-shaped)

```markdown
1. Who is the primary user of this in v1?
   A) internal ops team   B) end customers (self-serve)   C) a partner via API   D) other / not sure — I'll explain
2. When the upstream call times out, what should happen?
   A) fail fast + surface the error   B) retry with backoff   C) serve stale cache   D) other / not sure — I'll explain
```

Human replies: `1A, 2B` — done. Two forks closed in five characters.

---
*HONESTY: PROTOCOL (judgment) — no hook enforces the format; it is a question-asking discipline. An unanswered
question is an open scope item, not a resolved one — never infer the user's choice from silence. Provenance:
snarktank/ai-dev-tasks (MIT).*
