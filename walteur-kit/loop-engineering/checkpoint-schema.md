# Compaction checkpoint schema — the quality-preserving vehicle (Pi format)

> The canonical cross-model / cross-session / cross-compaction checkpoint. When the working context hits the
> compaction threshold (see `walteur-kit/compaction-policy.json`: compact 150k, hard-handoff 200k), the
> orchestrator/loop writes THIS to `_relay/BATON.md` and continues fresh from it — so compaction never costs
> quality. Folded from earendil-works/pi (compaction format) + WALTEUR's cross-model relay.

## The checkpoint (write to `_relay/BATON.md`)

```markdown
# BATON — <project> — checkpoint <ISO-ts>

## Goal
<the one outcome we are driving to — verbatim from the spec, not paraphrased>

## Constraints
- <hard requirement / iron law / budget ceiling / non-negotiable — one per line>

## Progress
### Done            (move items here as they finish; keep them — do not delete)
- <task> — <evidence: file path + the gate/test that proved it>
### In-Progress
- <task> — <exact next action; the file + function being edited>
### Blocked
- <task> — <what it's waiting on; the human gate or dependency>

## Key Decisions
- <decision> — <why; the ADR/debate ref if any>

## Next Steps
1. <the immediate next action, concrete enough to start cold>

## Critical Context (PRESERVE EXACTLY — never paraphrase)
- file paths: <exact paths touched>
- function/symbol names: <exact identifiers>
- error messages: <verbatim last error, if mid-fix>
- commands: <exact build/test/probe commands to re-run>
```

## Rules
1. **Preserve EXACTLY** — file paths, function names, error messages, and commands are copied verbatim. A
   paraphrased path is a broken handoff.
2. **UPDATE, don't re-summarize** — on the next compaction, MERGE: move In-Progress→Done (keep all prior Done),
   carry forward every unresolved item. Re-summarizing from scratch loses the tail (the comprehension-debt trap).
3. **Compact COMPLETED work, keep OPEN work** — summarize finished waves to one Done line each; keep the full
   detail of what's in flight.
4. **Automatic** — fired by the orchestrator at the threshold, not by a human (`compaction-policy.json`
   mode:automatic). This loop applies it to itself via the ScheduleWakeup continuation prompt + durable files.

---
*Provenance: checkpoint/compaction format from earendil-works/pi; relay discipline from WALTEUR `_relay/`.*
