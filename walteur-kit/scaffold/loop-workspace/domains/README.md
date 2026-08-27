# domains/ - Loops

Each subfolder is one long-lived loop: a separable workstream with a goal, cadence,
owner, current focus, backlog, metrics, and Timeline. Domain folders hold only the loop
README plus optional deterministic machinery such as metrics collectors.

## Domain README Template

```markdown
---
kind: domain
domain: <loop-name>
status: active | paused | archived
goal: <one-line outcome>
cadence: manual | daily | weekly | cron
owner: <person-or-role>
---

# <loop-name> - <short tagline>

What this loop consumes, what it produces, and how it proves progress.

## Current Focus
The single most useful next outcome.

## Backlog
- [ ] Work item linked to a signal, doc, issue, or PR when available.

## Evidence And Analysis
Links to docs, signals, reports, dashboards, or PRs.

## Metrics
`metrics/` - which numbers exist and what collector writes them.

## Timeline
YYYY-MM-DD | run/source - what happened this run
```

## Rules

- Create a domain only for a real workstream with its own cadence or owner.
- Cross-cutting work uses `domain: []` links, not duplicate folders.
- Backlog starts inline in the domain README.
- Promote tasks to their own kind only after the README backlog becomes too large.

