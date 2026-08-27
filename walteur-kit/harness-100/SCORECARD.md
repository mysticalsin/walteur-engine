# HARNESS-100 Scorecard

> **▶ LOOP RUNNING (cycle 46, 2026-07-06). PANEL #10 = 70.0/100 (clean single-pass, all 10 dims), DOWN −2.3 vs #9 (72.3), reported straight.** The **critic died on a session limit** → no dry-vs-lever ruling this panel, but the scored dims are complete (critic is separate) so the score is valid — and the **experts handed 2 genuine VERIFIED reachable defects** (well NOT dry). Up: code 8.0→9.0 (B67 CONFIRMED — expert independently ran the FP-guard tree → PASS + real slop still FAILs), uxdx 6.8→9.0. Down mostly inter-panel re-judgment variance (reliability 7.6→6.0, memory 6.5→5.5, docs 7.5→6.5) + security 8.4→7.4 (the real FN below). oneshot 5.5→4.5 (ship-gated floor). **Cycle 46 fixed BOTH expert findings:** **B69** closed a *verified* secret-scanner blind spot (`secret-rotation-gate` omitted `.mjs/.cjs/.mts/.cts` — a hardcoded secret in a `.mjs` file, exactly what `apikeys-vault/core.mjs` ships, slipped the `committed_secret` check; the expert's headline was muddied by a policy-shape confound, so I isolated `findings[].check` to confirm — *verify the specific check, not the exit code*); **B69b** closed the residual bare-lowercase-`todo` FN that B67 opened, comment-anchored so `Todo`/`todo list` stay free (never-weaken). Both internal → no count change, ledger 10.16→10.17, aggregate 241/0/0. **Score still gated on Tony's two actions:** `unblock-tdd-guard.txt` (memory w12 + gated source wave) + a real external ship (oneshot w15 + design field-half); ~25% of weight capped <9, so cert (2× ≥98, no dim <9) stays arithmetically unreachable. Genuine non-gated capability still surfacing each panel → loop continues.

- Rubric v1 (`RUBRIC.md`) · certification: 2 consecutive blind panels ≥98, no dim <9, drill green, fresh audit PASS
- **Panel #11 (2026-07-06, `wf_299b6d78-ebf`): 71.7 / 100** (clean single-pass, **critic survived**) · #10: 70.0 · #9: 72.3 · #7: 65.7 · #6: 67.9 · #5: 69.2 · #4: 72.1 · #3: 67.1 · #2: 69.6 · #1: 65.8 · (#8 degraded, unrecorded)
- **Panel #11: critic RULED capability well DRY** (owner-gated, `reachable_nongated_lever:""`), but two experts found real defects in existing gates → **B71** (secret-rotation STRICT fail-open, security-critical) + **B72** (`changeme`-substring FP + `//todo`-no-space FN), both fixed. Design 6.5→8.2 (B70 registered). Next: tool-absence fail-open sweep audit (B71 revealed it may be systematic). Full evidence: `panel-11.json`.
- **Panel #10 (2026-07-06, `wf_f7e71bee-f5a`): 70.0 / 100** (clean single-pass; critic died on session limit) · #9: 72.3 · #7: 65.7 · #6: 67.9 · #5: 69.2 · #4: 72.1 · #3: 67.1 · #2: 69.6 · #1: 65.8 · (#8 degraded, unrecorded)
- **Panel #10 per-dim (P10 vs P9):** oneshot 4.5 (−1.0) · code **9.0 (+1.0, B67 confirmed)** · security 7.4 (−1.0, found the .mjs FN) · memory 5.5 (−1.0) · design 6.5 (−0.2) · **uxdx 9.0 (+2.2)** · qa 8.8 (+0.1) · orchestration 7.5 (0.0) · reliability 6.0 (−1.6) · docs 6.5 (−1.0). Two VERIFIED expert findings → **B69** (secret-scan .mjs/.cjs blind spot) + **B69b** (bare-lowercase-todo FN from B67), both fixed this cycle. Full evidence: `panel-10.json`.
- **Panel #9 (2026-07-05, `wf_3fcabcf1-a5e`): 72.3 / 100** (authoritative; first-pass read 73.35, within 1.1pt) · #7: 65.7 · #6: 67.9 · #5: 69.2 · #4: 72.1 · #3: 67.1 · #2: 69.6 · #1: 65.8 · (#8 degraded, unrecorded)
- **Panel #9 authoritative per-dim (P9 vs P7):** oneshot 5.5 (−0.7) · code 8.0 (+0.6) · security 8.4 (+0.6) · **memory 6.5 (+2.2)** · design 6.7 (+0.7) · uxdx 6.8 (−1.0, noisy vs first-pass 9.0) · qa 8.7 (+1.4) · orchestration 7.5 (+0.7) · reliability 7.6 (+2.2) · docs 7.5 (+0.7). Lowest = oneshot 5.5 (ship-gated). Full evidence + two-read reconciliation: `panel-9.json`.
- **Δ vs panel #6: −2.2 — a DOWN-MOVE, reported straight (never smoothed).** But the panel *validated the last three cycles*: **code fail-open CONFIRMED fixed** (the expert ran anti-slop-code-gate against a 3202-file tree → exit 2, slop caught), **security adoption CONFIRMED genuine** (ran the injection probe against jsonlint + apikeys-vault, the leaky-core refutation PASSED), **uxdx +0.3** (the `--fast` lane registered). The fall was **reliability −1.4 to 5.4** (tdd-guard deadlock + no watchdog + self-audit sandbox-fragility), **design −1.0 to 6.0** (still checklist-not-vision), and **memory −0.2 to 4.3** — still the gated floor.
- **The critic PROVED certification is arithmetically impossible in the current state — on BOTH clauses.** "No dimension <9" is unsatisfiable: oneshot (w15) + design (w10) are capped <9 until a public URL exists (B30), and memory (w12) is human-gated at ~4.5 until `walteur.js` is unblocked (B58) — **37 of 100 weight**, two of the top-three dimensions, Tony-gated. And the **98 number itself is unreachable**: with oneshot+design pinned at their ~8.9 ceiling the forced loss is ≥2.75, so the weighted ceiling is ≤**97.25** even with all eight other dimensions perfect; memory's gate drops the realistic ceiling to ≤**~91.4**. No internal lever changes this.
- **B61 — the critic's #1 NON-gated lever, built this cycle (partial memory fix I'd wrongly written off as fully gated):** `walteur.js` consolidate/self-optimize *reference* `walteur-kit/memory/lesson-gate.sh` + `lesson-feedback.sh`, both of which were **missing** — so the consolidate write-path fell through to the wrong store and the helpful/harmful loop was vaporware. Created both, co-located + honest: a **deduping** capture wrapper (writes to the correct store) and a **real** `--drain` that bumps helpful/harmful per applied lesson from build outcomes (7/7 selftest). Fixes the WRITE side + makes the feedback loop real; wired into the aggregate (237→**238**). The READ side (`walteur.js:439` recall hardcodes `~/.walteur`) stays gated (B58).
- Full evidence: `panel-baseline.json` … `panel-6.json` · `panel-7.json` (each 10/10 experts, blind, no prior score shown)

| Dimension | W | P3 | P4 | P5 | P6 | P7 | Δ(P7−P6) | Panel-7 headline |
|---|---|---|---|---|---|---|---|---|
| oneshot | 15 | 5.7 | 6.7 | 5.7 | 6.5 | 6.2 | −0.3 | jsonlint 247/247 + BOM-fix reproduce; only ONE orchestrator-built app, rest hand/subagent-built; SHIPPED.md high band is an empty template — zero EXTERNAL ships (structural cap, B30) |
| code | 12 | 7.3 | 7.8 | **8.2** | 7.4 | 7.4 | 0.0 | **B57 fail-open FIX CONFIRMED** (expert ran anti-slop vs 3202 files → exit 2, slop caught); all 180 shells `bash -n` clean. New finding: perl-absent fail-open at :79 (reachable, queued) |
| security | 12 | 6.4 | 6.6 | 6.7 | **7.9** | 7.8 | −0.1 | **B59 adoption CONFIRMED genuine** — injection probe run vs jsonlint + apikeys-vault, leaky-core refutation PASSED; all 7 security gates' selftests pass incl jq-absent floors. Gap: only 2/13 adopted; no persisted field-scan evidence |
| design | 10 | 6.6 | 5.7 | 6.4 | **7.0** | 6.0 | −1.0 | Cadence genuine; but zero computed-contrast anywhere, browser_probe_executed:false by default, screenshot never pixel-analyzed — checklist-not-vision; capped <9 w/o external URL (B30) |
| uxdx | 10 | 6.6 | 8.0 | 7.8 | 7.5 | **7.8** | +0.3 | **B60 `--fast` lane registered** (real-tree <2min health check); doctor + REMEDIATION solid; some FAIL reports still `reason:null` |
| memory | 12 | 6.3 | 7.3 | 6.7 | 4.5 | **4.3** | −0.2 | **GATED FLOOR:** recall (`walteur.js:439`) reads `~/.walteur/memory` (absent) not `walteur-kit/memory` (30 lessons) → returns [] on a real build. **B61 fixed the WRITE side** (co-located wrappers + real feedback drain); READ side stays gated (B58, Tony) |
| qa | 10 | 7.6 | 7.8 | 7.3 | 7.4 | 7.3 | −0.1 | Suite honest 238/0/0; real-file coverage still thinner than synthetic fixtures |
| orchestration | 7 | 7.0 | 7.8 | 6.8 | 6.5 | 6.8 | +0.3 | `walteur-run.mjs` honest stub; "97 agents/118 min" prose-asserted (trace = 12 rows, `estimate:0`); no `.workflow.lock` concurrency guard |
| reliability | 7 | 7.4 | 7.4 | 7.0 | 6.8 | **5.4** | −1.4 | tdd-guard SIGPIPE deadlock (10/10 blocks, human-gated); no runtime watchdog/heartbeat; kill-switch manual-only; self-audit selftest uses bare `mktemp -d` (sandbox-fragile) |
| docs | 5 | 7.4 | 7.7 | 7.1 | 6.4 | **6.8** | +0.4 | Load-bearing counts accurate (144 gates, 238/0/0); `--fast` documented honestly; embedded README changelog still works against fast orientation |

## Read — honest (panel #7)
**Panel #7 is a −2.2 down-move (67.9 → 65.7), reported straight — never smoothed.** The seven panels sit in a **65.7–72.1**
band (~6 points of blind-variance), and this one landed at the low end. But the panel's real value was confirmation and proof,
not the number:
- **It confirmed the last three build cycles landed.** The code expert independently reproduced the B57 fix (anti-slop-code-gate
  now catches slop on a 3202-file tree, exit 2 — the fail-open is genuinely closed). The security expert ran the injection probe
  against both adopted field-runs and passed the leaky-core refutation — B59 is real. And `--fast` lifted uxdx +0.3.
- **The critic proved the ceiling with arithmetic** (see the header bullet). This is the definitive answer to "can internal work
  certify": **no.** Two of the top-three weighted dimensions are Tony-gated; the weighted ceiling is ≤97.25, realistically ≤~91.4.

The falls were honest signal, and I acted on what was reachable:
1. **Reliability −1.4 to 5.4** — the tdd-guard SIGPIPE deadlock (reproduced 10/10) and the absence of a runtime watchdog. The
   guard fix and a watchdog both live in `.claude/hooks` / `walteur.js` (sandbox-denied, `unblock-tdd-guard`), so this is gated.
2. **Memory −0.2 to 4.3 (the floor)** — but the critic caught a NON-gated slice I'd missed: `walteur.js` references two
   memory scripts that didn't exist, so its write-path fell through and the feedback loop was vaporware. **B61 built both**
   (deduping capture wrapper + a real helpful/harmful drainer, 7/7) — the write side is fixed and the loop now genuinely scores.
   The read side (recall's hardcoded `~/.walteur` path) is still gated.

**The ceiling is now proven, not just asserted.** Certification waits on B30 (external ship → oneshot + design) and B58
(`unblock-tdd-guard` → memory + the reliability/orchestration source wave). The loop keeps closing every reachable item; those
two gates are the only things that move the number now.

## (archived) Read — panel #6
**Panel #6 is a −1.3 down-move (69.2 → 67.9), reported straight — never smoothed.** But unlike a noisy swing, this
panel *validated the last two cycles of work*: **security rose +1.2 to 7.9** because the executed injection-resistance
gate (B56) is exactly what the previous panels said was missing — the expert independently ran its 12/12 refutation
selftest and the real jsonlint corpus and called it "a GENUINE executed adversarial probe, not a posture-claim." And
**design rose +0.6 to 7.0** because the B53–B55 evidence-integrity fixes made the Cadence proof bundle consistent.
Those are the intended uplifts landing.

The number fell anyway, on two things:
1. **Memory cratered to 4.5 (the new floor) — and it is a GENUINE, confirmed defect I could not reach.** The recall
   agent reads `~/.walteur/memory/lessons.jsonl` (absent) while the 27 real lessons live in `walteur-kit/memory` — so
   recall-before-act returns `[]` on a real build, and the helpful/harmful feedback loop is unbuilt. I verified all of
   this by reading `walteur.js:439/1672/1676-1683`. The fix is a small path change, but `walteur.js` is sandbox-denied
   and behind the `unblock-tdd-guard` human gate (a no-op write returned `Operation not permitted`). I did **not**
   bypass the sandbox to force it — that gate is working as designed. **B58 is parked for Tony.**
2. **Code fell to 7.4 because the panel EMPIRICALLY reproduced a fail-OPEN** — `anti-slop-code-gate` returning
   NOT_APPLICABLE (slop undetected) on a large tree, a SIGPIPE regression of the harness's own documented lesson. That
   one I *could* reach: **B57 class-swept all 7 vulnerable sites** (including a secret-detection vector), verified by
   refutation (the tree now FAILs, exit 2), aggregate re-run 237/0/0. A fail-open in a gate is the worst kind of
   defect — a gate that gives false confidence — so this was the right thing to fix immediately.

**The ceiling is unchanged and structural.** 98-with-no-dimension-below-9 stays arithmetically out of reach while the
external-ship ledger is empty (oneshot w15 + design w10 capped <9 without a public URL = B30). And now a *second*
dimension is gated: memory (w12) cannot rise off 4.5 until `walteur.js` is unblocked (`unblock-tdd-guard.txt`, Tony).
Two of the top-three weighted dimensions are now Tony-gated. The loop closed every reachable defect this panel
surfaced (B57); the remaining floor-movers are B58 (memory, unblock-tdd-guard) and B30 (external ship).

## (archived) Read — panel #3
The −2.5 was real and not hidden. Two things were true at once: (1) that cycle materially hardened the
engine — the aggregate suite went from 204/6 (with masked flakes) to a genuinely honest **210/0/0**, B33/B34
closed, fresh truthful ledger proof — and (2) the blind re-score still came out **lower**, because a fresh
independent panel judged `oneshot` (weight 15) much harder (5.7 vs 7.3) on the SAME field-runs, and marked
`security`/`qa` down within normal ±1–2 blind-panel variance. Blind panels are noisy per-dimension; the signal
is the **structural ceiling**, and it is unambiguous.

**The load-bearing gap (critic's #1): the open tdd-guard human gate.** The SIGPIPE false-negative in
`.claude/hooks/tdd-guard.sh` blocks all `.sh/.js/.mjs` **Edit/Write-tool** edits repo-wide, and the
self-modification classifier refuses to let the agent fix its own guard. This freezes the source edits that
would lift the floor dimensions — design (B31 image check), security (B03 denylist), memory (B32 recall),
oneshot (B29 Discover span). **No dimension can reach 9.0 while the gate is shut.** One human action clears it:
`bash walteur-kit/harness-100/unblock-tdd-guard.txt`.

**The structural cap (critic's co-blocker): oneshot cannot clear 9.0 on internal demos.** Weight 15 = 15% of
the total, and every field-run is localhost-only. It needs one real, publicly verifiable external ship —
`field-runs/SHIPPED.md`'s own high band requires it and the row is empty. That is B30 (npm publish), an
external action reserved for Tony.

Net: the engine got more honest and more correct this cycle; the score is gated by two things only Tony can
open. Everything reachable without the gate, the loop is still driving (see cycle-17 work + code-hygiene
cleanup this cycle).

## New gaps from panel #3 (added to loop-state backlog)
- **B35 (code, non-blocked):** remove orphan `walteur-kit/walteur-kit/` dup tree (49 drifted hook copies, 0 refs) + untrack git-tracked scratch files (`*.log`, `*.tmp-audit`, `q.tmp`, mis-pathed nested `qa-report.json`)
- **B36 (design, verify-then-fix):** determine whether the dispatched `apple-grade-design-gate.sh` is the Bash-editable `walteur-kit/hooks` copy; if so, add the image-content check there (B31 without the human gate)
- **B37 (memory, verify):** panel says every lesson is `applied:0` — confirm and, if the lessons schema supports it, wire an applied-counter bump into the recall path that is reachable without `.claude/hooks`
- Re-affirmed gated: B29 (oneshot Discover span), B31 (design image check, if `.claude/hooks`-only), B03 (denylist), B32 (session recall), B30 (external ship — Tony)
