# Agent inventory — what is actually spawnable, and what "68 personas" really means

*Lives in `.claude/workflows/` (next to `walteur.js`, the dispatcher this describes) rather than in
`.claude/agents/`, because `walteur-kit/selftest.sh:1657` asserts that every `.md` directly under
`.claude/agents/` carries agent frontmatter (`name`/`description`/`model`) — a docs file there would
either fail that curation check or have to disguise itself as an agent.*

This file exists because the two numbers in this repo do not mean the same thing and were being read as
if they did. A panel audit of the orchestration dimension put it bluntly: the skill advertises a
"68-PERSONA SENIOR ORG" while `.claude/agents/` held **one** agent definition. Both facts were true. The
gap was in the word "persona", not in the count.

## The honest inventory

Reproduce it yourself, from the repo root:

```bash
# spawnable subagent definitions (this directory)
find .claude/agents -name '*.md' -not -name 'README.md' | sort

# persona records in the roster
jq '[.personas[]] | length'                       walteur-kit/personas.json   # -> 68
jq '[.personas[] | select(.enforcement=="required")] | length' walteur-kit/personas.json   # -> 22

# how personas are actually invoked: they are NOT read from this directory
grep -c 'personas.json' .claude/workflows/walteur.js   # -> 0
```

## Two different mechanisms, deliberately

**1. Personas (68) — prompt-level roles, enforced by breadcrumb.**
`walteur-kit/personas.json` is a roster of senior roles (`id`, `title`, `discipline`, `phase`,
`spawn_when`, `enforcement`, `model_tier`, `mandate`). They are *not* subagent files and the engine never
loads them from `.claude/agents/`. A persona is engaged by writing its mandate into an `agent()` dispatch
prompt during the phase that needs it; the engagement is *proved* by the breadcrumb it leaves at
`walteur-kit/personas/<id>.json` (`{verdict, evidence}`), and `walteur-kit/hooks/persona-coverage-gate.sh`
hard-fails when a `required` persona whose `spawn_when` signal matched left no breadcrumb.

So the enforcement path for personas is: **roster → signal match → prompt-level engagement → breadcrumb →
coverage gate.** Nothing in that chain needs a file in this directory, which is why 67 of them do not have
one. What the roster buys is coverage discipline (22 roles cannot be skipped when their signal fires), not
67 separate context windows.

**2. Agent definitions (this directory) — real spawnable subagents with their own tool allowlist.**
A file here exists only when a role needs something a prompt cannot give it: its own isolated context, a
narrowed tool allowlist, and a protocol stable enough to be dispatched identically across builds. Today
that is two roles, both advisory and both outside the veto path by construction:

| file | role | dispatched from | why it needs a file |
| --- | --- | --- | --- |
| `.claude/agents/specialists/intent-auditor.md` | documented-vs-enforced gap pass at §5.5 | `/audit`, §5.5 AUDIT | read-only allowlist (`Read`/`Grep`/`Glob`), findings appended to `walteur-kit/audit.json` |
| `.claude/agents/blind-reviewer.md` | §5.2a diff-only review with zero intent context | `walteur.js` `label: 'blind-review'` | its value depends on *withholding* context, so the contract must be written down, not improvised per build |

`walteur-kit/selftest.sh` asserts `blind-reviewer.md` exists **and** that the `blind-review` label appears
in `walteur.js` **and** that the label is never pushed into the `panel` array — i.e. the harness proves the
advisory reviewer is wired and still cannot veto.

## The rule going forward

Say "68 senior roles / prompt-level personas, coverage-enforced" — not "68 agents". A number that counts
roster entries must never be reported in a unit that implies 68 spawnable subagents with 68 context
windows. When a persona genuinely needs isolation or a narrowed allowlist, promote it: add a definition
under `.claude/agents/`, wire the dispatch label in `walteur.js`, and keep the roster entry as the coverage
record — then update the table above so this inventory stays the one place the real count lives.
