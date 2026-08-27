# signals/ - Evidence

One file per signal: feedback, idea, friction, observation, or repeated fact worth tracking.
If the same signal appears again, update the existing file, add a Timeline line, and bump
`frequency`.

## Frontmatter

```yaml
---
kind: signal
category: feedback | idea | friction | observation
frequency: 1
sources: []
domain: []
status: open | triaged | actioned | closed
---
```

## Body

State the signal, why it matters, and what decision or loop it may affect.

```text
## Timeline
YYYY-MM-DD | source - what happened
```

## Rules

- `frequency` equals the number of Timeline sightings.
- `domain` is a list field, not a folder decision.
- Link related docs, decisions, issues, or PRs.
- Do not duplicate a signal just because it affects more than one domain.

