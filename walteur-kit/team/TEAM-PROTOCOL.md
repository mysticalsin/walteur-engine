# WALTEUR TEAM MODE — coordination protocol

Seven named Claude Code terminals, working as **peers** — real sessions in real terminals,
not subagents. Discovery, messaging, and the task board ride the peerbus
(`peerbus-mcp.mjs`, wired per-project via `.mcp.json` by `launch-team.ps1`). Every hop
leaves a JSONL receipt; `team-coordination-gate.sh` verifies a team run was real,
fail-closed. Concept provenance: louislva/claude-peers-mcp (peer messaging); WALTEUR adds
the board, the roles, the loops, and the proof.

## 1. Identity

Each terminal starts with `WALTEUR_PEER_NAME` / `WALTEUR_PEER_ROLE` set by the launcher and
a role charter appended to its system prompt. Your name must exist in `team-manifest.json`
— the gate rejects board/registry rows from unknown peers.

## 2. The loop (every peer, every iteration)

1. `check_messages` — drain your inbox FIRST. Answer questions before starting new work.
2. `board_list` — anything in your lane? (`backlog` you can claim; `review` if you are
   SENTINEL/PROBE; stale claims if you are ATLAS/KEEPER.)
3. Work ONE task at a time: `board_claim` → `board_update building` → do the work →
   `board_update review` (builders never mark their own work `done`).
4. `set_summary` whenever your focus changes — peers see it via `list_peers`.
5. Idle? Re-loop on your manifest cadence (`/loop <idle_interval_min>m` or just keep
   polling). Blocked >2 iterations? Message ATLAS; don't spin silently.

## 3. The board

States: `backlog → claimed → building → review → done` (+ `blocked`, and release back to
`backlog`). Rules:
- **Disjoint files**: a task's `files` list is its ownership. ATLAS keeps task file-sets
  disjoint; builders touch nothing outside their claimed task's files.
- **Dependencies**: `board_claim` refuses tasks with open `depends_on`.
- **Review is mandatory**: only SENTINEL or PROBE moves a task `review → done`. A builder
  marking own work done is a protocol violation the gate can catch (owner==done-actor on
  build-lane tasks).
- **Stale claims**: no heartbeat from the owner for 30+ min → ATLAS/KEEPER releases the
  task to backlog with a note.

## 4. Contract-first integration (from build-with-agent-team)

When two tasks meet at a wire (API↔UI, producer↔consumer), ATLAS authors the integration
contract INTO the task detail BEFORE builders claim: exact URLs (trailing slashes!),
request/response JSON shapes, event names, envelope nesting, error bodies. Before
integration, the two builders run a contract-diff (backend curl vs frontend fetch) and
message each other the diff result. Mismatch = both tasks back to `building`.

## 5. Honesty law (binds every peer)

Claims need receipts: tests you say pass must have been RUN this session; screenshots
referenced must exist; skill receipts follow `skill-receipt.schema.json`. Never mark
`done` on someone's behalf, never inflate a summary. `NOT-FOUND ≠ proven-absent`.

## 6. Escalation

Tony is the only human. ATLAS owns the Tony channel: consolidated questions, honest
status, decisions needed. Other peers message ATLAS rather than blocking on Tony
directly. Anything outward-facing (publish, deploy, push) is CONSENT: staged, never
executed by a peer.

## 7. Bus files (evidence surface — do not hand-edit)

```
_team/registry.json       peers + heartbeats + summaries
_team/inbox/<NAME>.jsonl  your unread messages (drained by check_messages)
_team/board.json          current board state
_team/board-log.jsonl     append-only transitions (the gate's main evidence)
_team/messages-log.jsonl  append-only copy of every message
```
