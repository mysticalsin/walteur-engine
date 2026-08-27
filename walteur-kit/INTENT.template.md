---
# WALTEUR reconstructed-INTENT contract — the COMPREHEND-phase artifact (§2.6 BROWNFIELD UPGRADE).
# The symmetric twin of PRD.template.md: a PRD declares the intent of a NEW build; INTENT reverse-engineers
# the intent of an EXISTING one. Machine-checkable frontmatter validated against schemas/intent.schema.json.
# Enforced by intent-reconstruction-gate.sh (HARD existence/anti-stub for brownfield, detect-or-SKIP).
# THE LAW OF THIS ARTIFACT: never present a guess as a fact. Every claim is labeled confirmed / inferred /
# unknown; confirmed claims CITE evidence (file:line / path / commit). Write terse (caveman LITE).
# SHORT-CIRCUIT: if a non-stub walteur-kit/PRD.md already exists (a WALTEUR-built app), set reconstructed:false
# and READ + confirm the PRD instead of reverse-engineering from scratch.
intent_version: 1
product: <app/codebase name>
date: <run-date — bash: date -u +%Y-%m-%d>
reconstructed: true        # true = reverse-engineered; false = read from an existing PRD.md
what_it_is: <one or two sentences — what kind of thing this is>
original_goal: <the problem it was ORIGINALLY built to solve — reconstructed from evidence, not invented>
used_for: <what it is USED for today — the jobs it actually does>
users:                     # ≥1 — framed as jobs/situations, never demographics
  - <who uses it, as a job>
claims:                    # ≥1 — the reconstruction, claim by claim. confirmed ⇒ evidence REQUIRED.
  - { statement: "<a load-bearing fact about the app>", label: confirmed, evidence: "<file:line / path / commit>" }
  - { statement: "<a reasoned guess from the code shape>", label: inferred }
  - { statement: "<something evidence could not settle>", label: unknown }
success_metrics:           # OPTIONAL — the implicit metrics it was optimizing for, where reconstructable
  - { name: "<metric>", target: "<number+unit or —>", label: inferred }
open_questions:            # the unknowns Tony must confirm before an upgrade that depends on them
  - <[HUMAN/EXPERT REVIEW REQUIRED] — the question>
evidence_refs:             # the corpus the reconstruction READ — grounds the whole artifact
  - <README / docs / package manifest / key source file / git history, as a path or file:line>
---

# INTENT — <app> (reconstructed)

> Reconstructed by WALTEUR COMPREHEND (§2.6) on <run-date>. This is what the app **is**, what it **was built
> for**, and what it **is used for** — recovered from evidence, every claim labeled. It is the contract the
> upgrade preserves and extends; the §5.5 intended-vs-implemented audit anchors to it. **Not a wish-list —
> a recovered fact-base.** Where evidence ran out, the claim says `unknown`, not a confident guess.

## 1. What it is
<The system's identity. What kind of thing it is, in plain terms. Cite the evidence that establishes it
(README, entrypoint, package manifest) at a file:line.>

## 2. The original goal (why it was built)
<The problem it set out to solve — reconstructed from the README's framing, the earliest commits, the shape
of the core modules. Mark confirmed (evidence) vs inferred (reasoned from structure). NEVER invent a goal the
evidence does not support — say `unknown` and add it to open_questions.>

## 3. What it is used for (the jobs it does)
<The jobs the app actually performs for its users today, and who those users are (as situations/jobs). Trace
each job to the code that implements it (file:line) where confirmed.>

## 4. Reconstruction ledger (claim · label · evidence)
<Render the `claims` table. The discipline that separates this from a hallucination: every row carries a
confidence label, and every `confirmed` row cites a file:line / path / commit. This is the load-bearing
section — an INTENT whose claims are all `inferred` with no evidence is a guess, and the gate fails it.>

| Claim | Label | Evidence |
|---|---|---|
| <statement> | confirmed | <file:line> |
| <statement> | inferred | — |
| <statement> | unknown | (needs Tony) |

## 5. Implicit success metrics
<What the app was optimizing for, where the code/docs reveal it (a latency budget in config, an analytics
event, a stated SLA). Reconstructable metrics carry a number+unit; the rest are `inferred`/`unknown`.>

## 6. Open questions (Tony to confirm)
<The `open_questions` list — the unknowns evidence could not settle. An upgrade task that depends on one of
these MUST resolve it (ask Tony) before it proceeds; the upgrade preserves intent, and you cannot preserve
an intent you have not recovered.>

---
*Authored in COMPREHEND (§2.6). The upgrade PRESERVES this intent by default and EXTENDS it only via signed
decisions; the non-regression gate proves no recovered behavior was lost. Mark every claim confirmed /
inferred / unknown; add [HUMAN/EXPERT REVIEW REQUIRED] where evidence ran out. Never sell a guess as a fact (§1).*
