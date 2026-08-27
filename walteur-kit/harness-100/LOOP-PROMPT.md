# HARNESS-100 IMPROVEMENT LOOP — cycle prompt (v1)

> The concrete self-improvement prompt for goal-2026-07-03-harness-100. One cycle = one verified
> improvement. Fable strategizes, Sonnet executes, an independent verifier refutes. The loop never
> marks its own work done (LOOP.md maker/checker law binds here).

## Cycle protocol — execute in order, skip nothing

**0 · Kill switch + budget.** If `walteur-kit/PAUSED` exists → do nothing, cancel next wakeup,
report to Tony why paused. If session budget exceeded → same. This is the only polite exit.

**1 · Recall before act** (memory-discipline rule): read `walteur-kit/harness-100/loop-state.json`
(cycle #, current score, backlog, dry_counter), `walteur-kit/harness-100/SCORECARD.md`,
`_relay/BATON.md`, memory `MEMORY.md` index. Query graphify once `graphify-out/` exists.
Re-read any file immediately before editing it (concurrent-linter-race lesson).

**2 · Pick ONE item.** Highest leverage = severity × rubric-weight ÷ effort_minutes, from the
scorecard backlog. Never two items per cycle. Never an item on the LOOP.md path denylist
(secrets, auth/, payments/, migrations, .env) — those escalate to Tony.

**3 · Execute with Sonnet.** Spawn Sonnet subagent(s) for the edit (Rule 0/7: never burn the big
model on execution). Minimal diff, one logical change. Ask before finishing the edit:
"is there a more elegant way?" — if yes and cheap, do the elegant one.

**4 · Verify by refutation (maker ≠ checker).** A SEPARATE agent must try to prove the fix wrong:
- gate/hook touched → run its `--selftest` AND `gate-registry-lint` + `release-ledger-lint`
  on REAL files AND the jq-absent PATH-shim verdict test (selftest-green ≠ real-green lesson)
- behavior claim → reproduce it live, quote real output
- reported pass is not a pass until reproduced. Failure → revert or fix, never ship broken.

**5 · Land + record.** Atomic commit (one change). Update `loop-state.json` (cycle++, item → done,
score_delta_estimate), refresh `_relay/BATON.md` so it always answers: state now · done · pending ·
pain points · how a fresh model (Codex/Gemini/Hermes/any) can help — any-model handoff is a
first-class quality dimension (Tony, 2026-07-03). Any correction discovered → capture lesson to
memory THEN continue (capture-on-the-spot rule).

**6 · Self-interrogate.** "Is this the best I can do for code, security, UX, design, memory, docs?"
One pass over the dimension just touched — any NEW gap found gets appended to the backlog with
severity + concrete fix. This is how the loop finds work the panel missed.

**7 · Re-panel trigger.** Every 10 cycles, or when all high-severity items are closed: run the blind
panel workflow (RUBRIC.md contract, fresh agents) → new SCORECARD.md → new backlog. Score must be
plotted honestly in loop-state.json history — down-moves are reported, never smoothed.

**8 · Stop conditions (hard).**
- 3 consecutive dry cycles (nothing verified landed) → PAUSE, write honest report to Tony, stop wakeups.
- Certification reached (2 consecutive panels ≥98, no dim <9, drill green, fresh audit PASS) →
  report COMPLETE, trigger engineering retro, stop.
- Any security tradeoff / new dependency / architecture fork / 3rd failed attempt on same item →
  escalate to Tony (LOOP.md human-gates), do not guess.

**9 · Schedule next wakeup** ~270s (stays inside prompt-cache window; Tony asked ≈5min cadence).

## Invariants
- Never fabricate a verification. Absence of evidence = NOT-FOUND, never proven-safe.
- Confidence labels on claims: verified / assumed / unknown.
- One workflow at a time (LOOP.md serialization law).
- The rubric file is the ONLY definition of done for scoring.
