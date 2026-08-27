# TEAM MODE — real end-to-end run evidence (S034)

`node walteur-kit/team/run-demo.mjs` drove 3 named peers as REAL separate peerbus MCP
processes (ATLAS/FORGE/SENTINEL, each with its own WALTEUR_PEER_NAME identity, real JSON-RPC
2.0 over stdio) through a genuine coordinated micro-build:

1. ATLAS registered, posted task t001 ("add /health endpoint") with a contract in the detail.
2. FORGE registered, claimed t001, wrote a REAL src/health.mjs + test, ran `node --test`
   (observed exit 0), messaged SENTINEL, moved t001 -> review. **Never self-marked done.**
3. SENTINEL registered, drained its inbox (1 msg), INDEPENDENTLY re-ran `node --test`
   (observed exit 0), moved t001 review -> done (recorded reviewed_by: SENTINEL).

Real bus produced: 3 peers, 1 task, 5 board transitions, 1 message — all in
`_team/{registry,board,board-log,messages-log}.json*`.

**team-coordination-gate PASS on this REAL bus** (not selftest fixtures): "3 peers, 1 done
task(s), receipts coherent".

**Negative control on the real bus:** tampering board-log so the builder (FORGE) self-approves
-> gate FAILs `[T4-self-done] review is mandatory`. Restore -> PASS. Real teeth on real data.

Honest scope: SCRIPTED peers (3 real node processes on one machine, real bus, real protocol),
NOT 7 humans in 7 terminals. Proves the coordination SURFACE runs end-to-end and the gate
verifies real receipts; does not prove human-driven multi-terminal use.
