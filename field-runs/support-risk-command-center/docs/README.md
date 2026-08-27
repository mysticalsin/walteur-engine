# docs/ - Durable Knowledge

One file per durable item: analysis, decision, learning, runbook, architecture note, or
post-review finding. Signals are raw evidence; docs are worked-through knowledge.

## Frontmatter

```yaml
---
kind: doc
domain: []
status: draft | adopted | superseded
links: []
---
```

Optional fields are allowed when they help query the knowledge, for example `type:
analysis | decision | learning | runbook`.

## Body

Main body means what is true now. Add a Timeline only for revision history or later
evidence.

```text
## Timeline
YYYY-MM-DD | source - what changed
```

## Rules

- Use docs for decisions and lessons that should survive one run.
- Link the evidence that proves the claim.
- Supersede stale docs instead of silently editing away history.
- Keep numeric data traceable to a source or a generated report.

