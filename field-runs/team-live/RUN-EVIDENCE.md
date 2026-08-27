# TEAM MODE — REAL-AGENT run evidence (S035)

Three REAL Claude agents (not scripts, not the peerbus selftest fixtures) coordinated a live
micro-build over the peerbus, each driving it via `node peerbus-mcp.mjs --cli <tool> <json>`
with its own WALTEUR_PEER_NAME identity:

- **ATLAS** (real agent, lead) set_summary, decomposed the ask, board_post'd t001 with full
  acceptance criteria, list_peers. (Hit a bash JSON-quoting rough edge on the CLI and
  problem-solved around it by serializing the payload to a file — real agent judgment.)
- **FORGE** (real agent, builder) claimed t001, wrote real src/slug.mjs + src/slug.test.mjs,
  ran `node --test` (observed exit 0, 8/8), moved t001 -> review. **Never self-closed.**
  Caught a real contract mismatch (its brief said `slug`, the board contract said `slugify`)
  and honored the board contract — genuine reasoning, not a script.
- **SENTINEL** (real agent, reviewer) checked messages, INDEPENDENTLY re-ran the tests twice
  (did not trust FORGE), did an unprompted security read incl. a ReDoS analysis of both
  regexes, then closed t001 -> done (reviewed_by: SENTINEL).

Real bus: 3 peers, 1 task done (owner FORGE, reviewed_by SENTINEL), 6 board transitions,
3 messages. Product test passes on independent re-run (fail 0).

**team-coordination-gate PASS** on this real-agent bus. **Negative control:** tamper the
board-log so the builder self-approves -> `[T4-self-done]` FAIL exit 2 -> restore -> PASS.

This closes the S034 orchestration dock "team mode never run with REAL AGENTS" — the peers here
are real Claude agents exercising real judgment over the real bus. Remaining honest limit: they
ran as a SEQUENTIAL pipeline (ATLAS->FORGE->SENTINEL), so real concurrent contention across
co-live agents is still unproven, and it was a single 1-task micro-build.
