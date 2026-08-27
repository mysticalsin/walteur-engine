# QUICKSTART — WALTEUR (canonical repo) in 10 minutes

This is the honest first-run path through **this repo** (`Pro Coding`, the canonical WALTEUR spec +
kit). Every command below was run on this box before being written down — none are guesses.
For the *runnable, hook-wired* drop-in kit (a fresh project scaffold), see
[`walteur-starter/QUICKSTART.md`](../walteur-starter/QUICKSTART.md) instead; this doc is for people
working **on WALTEUR itself**.

## 1. Verify your toolchain (30 seconds)

Windows: use **Git Bash** (not PowerShell/cmd — every gate is a bash script). macOS: any Terminal
with bash works out of the box.

```bash
bash --version   # need bash present at all — this box: GNU bash 5.2
jq --version     # gates read/write JSON reports — this box: jq-1.8.2
node --version   # test re-runs + tooling — this box: v24
git --version    # this box: git 2.53
```

If `jq` is missing: **Windows** `winget install jqlang.jq` (Git Bash), **macOS** `brew install jq`.
If any of the four are absent, gates fail closed with a loud SKIP — they never silently pass on a
degraded box.

## 2. Run the fast health check (~10 seconds)

```bash
bash walteur-kit/hooks/gate-suite.sh --selftest
```

Verified 2026-07-25: **14/14 passed** in ~7s. This is the meta-suite's own selftest — it exercises
the twin-drift check, the skip-budget math, and the aggregator itself with synthetic fixtures. It is
fast and safe to run anytime.

> **Do not** run `bash walteur-kit/hooks/gate-suite.sh` (no `--selftest`) as a quick check — that mode
> walks every registered gate's own `--selftest` in sequence and, verified on this box, did **not**
> finish inside 4 minutes. Reserve the plain run for CI or a dedicated pass, not the onboarding budget.

**Fast core health check (`< 2 min`, real-tree):**

```bash
bash walteur-kit/selftest.sh --fast
```

Runs a CORE subset — the load-bearing gate `--selftest`s plus the three real-file lints
(harness-self-audit, gate-registry, release-ledger) and the hermetic twin-invariant guard — against the
**real repo**, and writes `walteur-kit/selftest-fast-report.json`. It takes ~70s.

**This page deliberately does not print the pass count**, because the count moves — it was observed at
both `26/0 PASS` and `25/1 FAIL` within a single day (2026-07-25) as agents worked the tree, and a
hand-typed number in a doc is how a red gets read as a green. Read it out of the artifact the command
just wrote, which is the only thing that cannot go stale:

```bash
# what --fast actually recorded, verdict first
jq -c '{verdict, partial, counts, ts}' walteur-kit/selftest-fast-report.json
# what the FULL suite last recorded — this is the aggregate certification proof
jq -c '{verdict, counts, ts}' walteur-kit/selftest-report.json
# how many gates are declared right now
jq '[.gates[]]|length' walteur-kit/gate-registry.json
```

Ballpark, so you can spot something wildly wrong: the fast lane is **26 core checks**, the full suite
last recorded **PASS 243 / 0 / 0** (2026-07-11), and there are around **150** declared gates. Those are
orientation, not claims — the `jq` output above overrides every one of them.

Three honesty rules that this page has broken before, so they are written down:

- `--fast` is `partial:true` **by construction**. A green `--fast` is not the certification proof; the
  full `bash walteur-kit/selftest.sh` is, and it is the one CI runs.
- A **pass count is not a total.** `24 passed` out of 26 checks with `verdict:"FAIL"` is a FAIL, and
  writing it as "24/24" turns a red into a green. Always read `verdict` before `counts`.
- **Capture the exit code directly**, never `$?` after a pipe — a pipe reports the *last* stage's status,
  so `cmd | tail; echo $?` will happily tell you a failing command succeeded. Use
  `cmd >/dev/null 2>&1; rc=$?` or `${PIPESTATUS[0]}`.

## 3. Run doctor (health + failure triage)

```bash
bash walteur-kit/hooks/doctor.sh
```

`doctor.sh` checks bash/jq/node are on PATH, that `walteur-kit/gate-registry.json` parses (150 declared
gates on 2026-07-25 — read the live count with the `jq` command in step 2), counts hook scripts on disk,
and re-runs a core gate's own `--selftest` as a smoke test. It then scans every
`walteur-kit/*-report.json` for `verdict:"FAIL"` and prints each one — gate id, reason, and a
`walteur-kit/REMEDIATION.md#<gate-id>` fix pointer — so a failing gate is never silent.

Exit codes: **0** clean · **1** a problem or at least one FAIL report exists · **2**
`walteur-kit/PAUSED` is present · **64** you passed an unrecognised flag.

### What your first run on THIS repo will actually look like

**It exits 1, and it names roughly 30 failing gates.** That is the honest state of the canonical tree,
not a broken install — 2026-07-25: `EXIT=1`, `Failing gates (29) — triage`. Do not read it as "the
harness is broken", and do not read it as "these are fine" either. They are **real recorded FAILs on
this repo today**: partly manifests a build-harness tree has no product reason to carry
(`cost-budget.json`, `sso`, `agent-security.json`, `frontend-budget.json`), partly genuine open debt.

**Read [`docs/EXPECTED-REDS.md`](docs/EXPECTED-REDS.md) before you triage anything.** It splits the
current reds into "harness, not a product" and "substantive finding", quotes each gate's own reason, and
gives you the commands to regenerate the list rather than trust a written-down number.

What does **not** exist, on purpose: a machine-readable known-red allowlist that suppresses any of them.
An "expected" list is exactly how a real regression hides inside an accepted one, so the count stays
loud, and the only sanctioned way it goes down is closing a finding. The number is expected to **fall**;
if it rises after your change, you caused a regression.

To see whether a red is *new*, diff the gate list against a saved run rather than trusting memory:

```bash
bash walteur-kit/hooks/doctor.sh --dry-run 2>/dev/null | jq -r '.triage[].gate' | sort > /tmp/reds.now
# ... after your change ...
bash walteur-kit/hooks/doctor.sh --dry-run 2>/dev/null | jq -r '.triage[].gate' | sort | diff /tmp/reds.now -
```

### Read-only mode (CI probes, or when you must not touch the tree)

```bash
bash walteur-kit/hooks/doctor.sh --dry-run > report.json   # alias: --stdout
```

`--dry-run` runs the same checks, prints the report JSON on stdout, sends every human line to stderr,
and **writes nothing** — no `doctor-report.json`, no directory created. It still fails closed: a missing
registry is exit 1 in dry-run too, because read-only is not a free pass.

Two operator mistakes doctor now refuses to swallow:

- **Wrong directory.** Run it from outside the repo and it says `run from the repo root (walteur-kit/
  not found here)`, names the path it looked in, and exits 1 without creating a `walteur-kit/` or
  littering a report into the unrelated tree.
- **Flag typo.** `--self-test` (one hyphen too many) exits **64** with `unknown option: --self-test`.
  It used to run the default health check and exit 1, so a typo looked like a failing selftest.

Prove doctor itself works:
```bash
bash walteur-kit/hooks/doctor.sh --selftest
```
Verified 2026-07-25: **38/38 passed**, including a seeded-FAIL-report twin (doctor must name the gate +
point at REMEDIATION.md), a reason-less structured-FAIL twin (doctor must DERIVE a concise reason from
the report's structured fields), a negative control (a healthy tree with zero FAIL reports must print no
triage section), and the four new controls behind the paragraphs above — unknown flag → 64, `--dry-run`
writes no file, wrong cwd creates nothing, and every REMEDIATION alias targets a live heading.

## 4. Read the current score

```bash
sed -n '/STAMP-CURRENT-START/,/STAMP-CURRENT-END/p' STAMP.md
```

`STAMP.md` (repo root) is the **append-only, immutable ledger** — the `Current` block is the live
score; `Stamp history` below it is a permanent, hash-chained record of every re-score (verified by
`stamp-integrity-gate.sh`; a deleted or altered row fails closed). Never trust a score claimed in
chat over what this file says.

## 5. When a gate fails: REMEDIATION.md

```bash
bash walteur-kit/hooks/gate-suite.sh --selftest   # fast — names any broken gate's selftest
jq . walteur-kit/<gate>-report.json               # the gate's own verdict + reason
bash walteur-kit/hooks/<gate>.sh --help           # the gate's contract + its fix-recipe pointer
```

`walteur-kit/REMEDIATION.md` is the "a gate failed, now what?" guide — one `## <gate-id>` section per
gate, each with **Enforces / Common failure / Fix / Bypass**. Jump straight to the section
(`Ctrl+F "## <gate-id>"`); `doctor.sh` (step 3) prints the anchor for you on every failing gate.

Those pointers are themselves link-checked, because a fix pointer that 404s spends your trust and then
your time:

```bash
bash walteur-kit/hooks/doctor-anchors.sh
```

It runs every hook's `--help`, extracts the `REMEDIATION.md (## X)` pointer, asks `doctor.sh --dry-run`
for the anchors it would print on the current FAIL reports, and requires every one to resolve to a live
`## ` heading. Exit 2 on any dead pointer. Verified 2026-07-25: **186 pointers checked across 164 hooks,
0 dead** — up from 10 dead `--help` pointers and 2 dead triage anchors before this checker existed.
If it ever fails, **write the missing section**; do not delete the pointer and do not add an exclude.

## 6. Run WALTEUR itself

WALTEUR is **not** a CLI script you run with `node walteur.js` — the lifecycle engine is a Claude Code
**Workflow**, invoked from inside an agent session. There is more than one advertised way in, so here is
the authoritative table with what actually ships in this repo:

| Entrypoint | What it is | Ships in this repo? |
|---|---|---|
| `Workflow({ name: 'walteur', args: {…} })` | **CURRENT — the one that is guaranteed to resolve.** Calls `.claude/workflows/walteur.js` directly. | **yes** — `.claude/workflows/walteur.js` |
| `/goal <idea>` | The documented front door for a full product build. A slash command must be defined somewhere the session can see (a `.claude/commands/` entry or a user-level command). | **no** — `find .claude -name '*goal*'` returns nothing and there is no `.claude/commands/` directory. On a fresh clone `/goal` resolves only if *your* environment already provides it. |
| `/walteur`, `/plan`, `/discover`, `/build`, `/refine`, `/debate`, `/qa`, `/audit` | The trigger list `walteur/SKILL.md` advertises. Same caveat as `/goal`. | **as skill triggers**, not as shipped command files |
| `/feature` | A lighter Planner→Coder→Tester→Reviewer lane named in `README.md`. Not in `SKILL.md`'s trigger list. | **no** shipped definition |
| `node .claude/workflows/walteur-run.mjs` | A real **shell-only** runner — no agent session needed. See 6b. | **yes**, and it exits 0 |

So: if you are inside a Claude Code session with the skill loaded, use `/goal`. If you want something
that provably resolves from a bare clone, use the `Workflow({…})` call or the 6b runner. The full
argument contract (`idea`, `projectPath`, `mode`, `scopeAnswers`, `maxRefine`) is in the
`.claude/workflows/walteur.js` header comment. The engine runs scope → think → team → plan → build →
review → refine → validate → audit behind the fail-closed gates in `walteur-kit/hooks/`.

## 6a. Start, stop, and resume

A halted run is normal — the engine pauses on purpose. There are **four** different resume paths and
they are not interchangeable. Read the log line: it names which one you are in.

| The run stopped because… | You will see | Resume with |
|---|---|---|
| The kill switch is set | Any gate exits 2: `WALTEUR PAUSED (walteur-kit/PAUSED)` | `rm walteur-kit/PAUSED` |
| A phase wants **human approval** | `⏸ PAUSED for human approval after PLAN / after build wave N / after REVIEW / before SHIP` | `touch walteur-kit/APPROVED`, then re-run the entrypoint. The engine requires the file to be **newer** than `walteur-kit/APPROVAL-REQUEST.json`, and it **consumes** it (`rm -f`) on resume — so one file authorises exactly one gate, never all of them |
| The **budget ceiling** was hit | resume instructions written into `_relay/ISSUES.md` | Work the issues, raise the ceiling deliberately, then re-run |
| You are picking up **someone else's** (or another model's) session | `_relay/BATON.md` holds a RESUME SNAPSHOT block | Read `_relay/BATON.md` + `PLAN.md` + `_relay/ISSUES.md`, then re-run. `walteur-kit/hooks/compact-context.sh` writes that snapshot on the Stop hook so no prior chat is needed |

Re-running is safe and is the intended motion: `walteur-kit/autopilot/STATE.json` records
`completed_task_ids`, and the build phase logs `A2 resume · STATE.json shows N task(s) already built —
skipping those, rebuilding only the rest`. You do not lose finished work by re-invoking.

A worked example of the approval path:

```bash
bash walteur-kit/hooks/doctor.sh                 # confirm nothing else is red first
cat walteur-kit/APPROVAL-REQUEST.json            # what the engine is asking you to approve
cat PLAN.md                                      # ... read the actual plan, that is the point
touch walteur-kit/APPROVED                       # must be NEWER than APPROVAL-REQUEST.json
[ walteur-kit/APPROVED -nt walteur-kit/APPROVAL-REQUEST.json ] && echo "approval will be accepted"
# then re-run /goal (or the Workflow call). The engine consumes APPROVED and continues.
```

Do not pre-place `walteur-kit/APPROVED` "to save time". The freshness + consume rules exist so an
approval cannot silently carry across every later gate, and defeating them turns a human checkpoint
into a no-op.

## 6b. Shell-only end-to-end smoke (no agent session)

If you want to see the engine's real cost/routing/trace machinery execute before you trust any of it,
this runs with nothing but `node`:

```bash
TEMP="$TMPDIR" node .claude/workflows/walteur-run.mjs; echo "RUNNER_EXIT=$?"
```

Verified 2026-07-25: `RUNNER_EXIT=0`, 81 output lines — it slices the **real** cost and routing regions
out of `walteur.js`, executes the inline contract assertions, checks the routing mirror against
`walteur-kit/model-routing.json`, walks 11 phase spans (Self-Heal → Scope → Think → Plan → Build →
Review → Refine → Validate → Audit), and emits a real `run-trace.jsonl`. It includes a
routing-mismatch negative control, so it is a check that can fail.

**The `TEMP="$TMPDIR"` prefix is not optional inside a command sandbox.** `walteur-run.mjs` picks its
scratch directory with `process.env.TEMP || '/tmp'`, and a bare `/tmp` write is denied — without the
prefix you get `Error: EPERM: operation not permitted, mkdir '/tmp/walteur-run-trace-proof-procoding/…'`
and `RUNNER_EXIT=1`. That is an environment fault, not a harness fault. (The engine should honour
`TMPDIR` directly; until it does, use the prefix.)

## 7. See it take a vague prompt

FR-7 (`jsonlint-cli`) is the one run on record where the orchestrator went idea → shipped artifact
unattended — see `field-runs/SHIPPED.md` (search `FR-7`). Replay the phases yourself:

```bash
wc -l field-runs/jsonlint-cli/walteur-kit/run-trace.jsonl                    # 12
jq -r '.phase' field-runs/jsonlint-cli/walteur-kit/run-trace.jsonl           # Scope … Audit
jq -c '{certified, model}' field-runs/jsonlint-cli/walteur-kit/audit.json    # {"certified":true,"model":"opus"}
```

12 timestamped spans, Scope→Think→Team→Plan→Preflight→Debate→Build(5 parallel waves)→Review→Refine
(×2)→Validate→Audit, 2026-06-30 20:48Z→22:46Z.

> **If you read `README.md` first, you saw the opposite claim.** Its Status section says the full
> autonomous orchestrator "has **not yet run end-to-end on a fresh idea**". That line is **stale** and
> this section is the accurate one. The three commands above are the arbiter: a 12-span
> `run-trace.jsonl` and an `audit.json` with `certified:true, model:"opus"` are on disk, and
> `field-runs/SHIPPED.md` records FR-7 (2026-06-30) as "**THE FIRST REAL END-TO-END ORCHESTRATOR RUN**
> — 97 agents, 118 min, 5 git commits one-per-wave". Trust the artifacts, then the ledger, then this
> page; never a prose status line. What remains genuinely unproven is different and narrower: no run
> has shipped to a **public URL with real users**, and a vague-prompt → *enterprise*-scope one-shot has
> not been done.

DISCOVER/PRD intake shows up as `walteur-kit/scope-track.json` (`"track":"complex"`,
`"demand_prd":true`) and a "PRD slice" folded into each per-task brief (e.g.
`walteur-kit/briefs/1.md`). Honestly: no standalone `PRD.md` survived the rescue out of the build's
Temp scratchpad into this repo — the brief's PRD slice is the closest artifact that does.

The beat worth seeing: `walteur-kit/audit.json` is `certified:true` but still lists a real shortfall
— `--fix` silently stripped a leading BOM — and `_relay/ISSUES.md` codified it instead of calling the
build done. `_relay/receipt.json`'s note preserves the original verdict, `shippable:false, issues:1`,
before a follow-up fix pass made it genuinely shippable. The engine catching its own bug and refusing
to ship is the point, not a marketing gloss.

Scope, honestly: this is one small zero-dependency CLI, not an enterprise system — no
`enterprise-blueprint.json` exists for this run, and a vague-prompt → enterprise-scope one-shot is
still unproven future work.

## Troubleshooting

- **A gate SKIPs / says `cannot_measure`** — a required tool or artifact is absent (e.g. `jq`, `knip`).
  Install it or produce the artifact; gates never turn green on missing evidence. A SKIP is not a pass.
- **Everything is blocked** — check for `walteur-kit/PAUSED`; `rm walteur-kit/PAUSED` to resume (step 6a).
- **A run halted and I don't know which resume path I'm in** — read the log line, then step 6a's table.
  If it mentions approval you need `walteur-kit/APPROVED`, not `rm PAUSED`.
- **A gate is misbehaving** — run it directly: `bash walteur-kit/hooks/<gate>.sh --selftest`. If the
  gate's own selftest is green, the gate is not the bug.
- **Not sure what's wrong right now** — run `bash walteur-kit/hooks/doctor.sh`; it triages failing
  gate reports for you (step 3). Expect exit 1 with ~30 reds on this repo today — see step 3.
- **`doctor: run from the repo root (walteur-kit/ not found here)`** — you are in the wrong directory.
  `cd "$(git rev-parse --show-toplevel)"`, or pass `WALTEUR_ROOT=/path/to/repo`.
- **`doctor: unknown option: …` / exit 64** — flag typo. Valid: `--selftest`, `--dry-run` (alias
  `--stdout`), `--help`, or no argument.
- **A `REMEDIATION.md#…` fix pointer goes nowhere** — run `bash walteur-kit/hooks/doctor-anchors.sh`;
  it names every dead pointer. Then write the missing section (step 5).
- **`EPERM … mkdir '/tmp/walteur-run-trace-proof-procoding'`** — sandbox denied `/tmp`. Prefix the
  runner with `TEMP="$TMPDIR"` (step 6b).
- **A number on this page disagrees with a report file** — the report file wins. Re-derive with the `jq`
  commands in step 2 and treat this page as stale.

## Where things live
| Question | Answer |
|---|---|
| What's the current score? | `STAMP.md` (repo root) — step 4 |
| A gate failed, how do I fix it? | `walteur-kit/REMEDIATION.md` — step 5 |
| Is the kit healthy right now? | `bash walteur-kit/hooks/doctor.sh` — step 3 |
| Are the fix pointers live? | `bash walteur-kit/hooks/doctor-anchors.sh` — step 5 |
| What are the real pass/fail counts? | `walteur-kit/selftest-report.json` (full) and `selftest-fast-report.json` (partial) — step 2 |
| The full gate/skill/schema index | `walteur-kit/README.md` |
| How do I run WALTEUR on an idea? | `/goal <idea>` in a session, or `Workflow({name:'walteur',…})` — step 6 |
| How do I resume a halted run? | step 6a — four paths, `rm PAUSED` is only one of them |
| Can I prove the engine runs without an agent? | `TEMP="$TMPDIR" node .claude/workflows/walteur-run.mjs` — step 6b |
| Has the orchestrator ever run end-to-end? | Yes — FR-7, 2026-06-30. Artifacts in step 7; `README.md`'s Status line saying otherwise is stale |
