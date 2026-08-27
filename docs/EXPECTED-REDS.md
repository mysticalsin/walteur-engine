# Expected reds — why this tree is not all-green, and what that does and does not mean

The second command most newcomers run is `bash walteur-kit/hooks/doctor.sh`. **It exits 1.** On
2026-07-25 it reported **29 FAIL gate reports** against this very repo. That is not a broken install and
it is not something to "fix" before you can use the framework — but it is also **not fine**, and this
file refuses to tell you it is. It exists so your first red is *predicted* instead of alarming, and so
you can tell the two very different kinds of red apart.

## Reproduce it yourself (never trust the numbers below — regenerate them)

```sh
bash walteur-kit/hooks/doctor.sh >/dev/null 2>&1; echo "doctor rc=$?"        # -> 1 today
jq -r '.failing_gates, (.triage[]|"\(.gate) | \(.reason)")' walteur-kit/doctor-report.json
jq -c '{verdict,failing_gates,declared_gates,ts}' walteur-kit/doctor-report.json
```

The count moves as agents work the tree (it was 28 earlier the same day, 29 by 19:27Z). Treat the live
`doctor-report.json` as truth and this page as orientation. **Capture the exit code directly** — never
read `$?` after a pipe, it reports the last stage.

## What doctor.sh actually measures

It counts **FAIL reports sitting on disk**, from whenever they were written — timestamps in the current
set span 2026-06-13 to today. It does not re-run the suite. So a red here means "the last time this gate
ran against this tree it failed", not "your machine is broken".

This is the distinction to hold on to:

| Claim | Surface | State today |
|---|---|---|
| the gate machinery **fires** correctly | `walteur-kit/selftest-report.json` | **243 passed / 0 failed / 0 skipped** |
| this repo's own gate reports are green | `walteur-kit/doctor-report.json` | **FAIL — 29 reds** |

Both are true at once. The first is the framework's proof-of-function; the second is this repository's
own debt ledger.

## Class 1 — the tree is a harness, not a product (7 reds)

These gates arm on a *product* manifest. This repo is a build harness, so the manifest legitimately does
not exist here, and the gate reports absence rather than staying quiet. Verbatim reasons from
`doctor-report.json`:

- `cost-budget` — `cost-budget.json missing (app spends $ with no budget)`
- `frontend-budget` — `frontend-budget.json missing (frontend ships JS with no budget)`
- `sso` — `sso manifest absent`
- `access-lifecycle` — `access-lifecycle manifest absent`
- `agent-security` — `agent-security.json absent`
- `estimate-gate` — `estimate.json missing while STATE.json exists`
- `current-stack-gate` — `current-stack.json missing while required by STATE.phase=build`

Fire the same gate inside a real build (`field-runs/*/`, each of which carries its own
`walteur-kit/preflight-signals.json` and manifests) and the behaviour changes — that is the intended
contract. **This is an explanation, not an exemption:** whether a harness tree should carry these
manifests, or whether these gates should report NOT_APPLICABLE outside a product build, is an open
design question, not a settled one. Nobody has signed a risk acceptance for them.

## Class 2 — substantive findings (the rest)

Everything else in the triage list is a real finding with real content behind it, and it is **debt, not
decoration**. Examples from the current set: `docrun` (10 documented shell blocks fail `bash -n`),
`anti-slop-code` (3 markers in source), `supply-chain` (1 violation), `resilience` (24 anti-patterns),
`ai-safety` (3 rules: injection-corpus, loop-cap, model-pin), `a11y-content` (an unlabeled `<input>` in
the generated `graphify-out/graph.html`), `spec` (2 violations at risk_tier=high), `execution-ratio`
(46 skips exceed the cannot-measure budget — a toolless box must not look more executed).

Read one before judging it:

```sh
jq -c '{verdict,reason}' walteur-kit/docrun-report.json          # the claim
jq -c '.failures[0]' walteur-kit/docrun-report.json              # the first piece of evidence
grep -n '^## docrun' walteur-kit/REMEDIATION.md                  # the fix recipe (line 156 today)
```

Every triage line carries a `walteur-kit/REMEDIATION.md#<anchor>` fix recipe, and all 29 anchors resolve
to a real heading in that file (verified 2026-07-25). Use them:

```sh
jq -r '.triage[]|"\(.gate) -> \(.remediation)"' walteur-kit/doctor-report.json
```

## The rules this page does not bend

- No red is excluded, downgraded, or annotated away to make a gate pass. Nothing here changes gate code,
  thresholds, or the registry.
- A red that *should* be red stays red. The honest state of this tree is "29 reports failing", and that
  is what `doctor.sh`, `doctor-report.json` and `STAMP.md` all say.
- The number is expected to **fall**. If it rises after your change, you caused a regression — find it
  before you ship.
- The green claim you may quote is the aggregate selftest (243/0/0, gates proven to fire). You may not
  quote "doctor is green", because it is not.

Ownership and history: `walteur-kit/REMEDIATION.md` (fix recipes per gate), `STAMP.md` (score of record
and the panel that scored it), `CHANGELOG.md` → "Known reds" entries for how previous reds were closed.
