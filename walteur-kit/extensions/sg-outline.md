# graphify EXTENSION — `sg outline` as a cheaper-than-Read structural pass

> **One brain.** graphify stays the single retrieval brain. `sg outline` (ast-grep) is NOT an index, NOT
> a cache, NOT a second store — it builds nothing and persists nothing. It is a **stateless, on-demand
> structural skim** of a single file or a small fan of files, used to spend fewer tokens than a full
> `Read` once graphify and the wiki have already pointed you at the right place.

Provenance: ast-grep (`sg`, MIT) — already a WALTEUR pillar tool (`required:false`, registered in
`required-tools.json`, used by `intent-trace.sh`). No new dependency. Adapted as a navigation aid.

---

## 0. Where it sits — the §7 context-nav order is LAW (do not reorder)

WALTEUR's context-navigation discipline (mirrors the global CLAUDE.md CONTEXT NAVIGATION contract):

1. **`/graphify query "…"`** — ALWAYS first. The one retrieval brain answers "what relates to what,
   where does this live, who calls this."
2. **`graphify-out/wiki/index.md`** — the structural navigation entrypoint; follow it to the relevant
   subsystem / file.
3. **THEN `sg outline` (this extension) — or raw `Read`** — only once 1+2 have narrowed you to a
   *specific file or a handful of files*, take a cheap structural first pass to decide WHERE in the file
   to look before spending tokens reading it whole.

`sg outline` slots at **position 3, as a cheaper alternative to a blind full-file `Read`** — never at
position 1, never instead of a graphify query. It does not answer "where does this live across the
codebase" (that is graphify's job and it would be wrong to use `sg` for it — `sg` has no cross-file edge
model). It answers, for a file graphify already surfaced: *what are the top-level shapes here, and at
which line, so I read the right 30 lines instead of all 800?*

**Forbidden framing:** "use `sg outline` to find X in the repo" / "skip graphify, just outline the tree."
That makes it a competing index. It is not one. If you catch yourself reaching for `sg` before graphify,
stop — that ordering is the violation.

---

## 1. What it does (and the honest limits)

`sg outline` (and the equivalent `ast-grep` structural skim) walks a file's tree-sitter AST and prints the
declaration skeleton — functions, classes, methods, exports — with line numbers, dropping bodies. For a
large file that is a few hundred tokens instead of the thousands a full `Read` costs.

```bash
# structural skim of ONE file graphify+wiki already pointed you at (position 3 of the nav order):
sg run -p 'function $NAME($$$ARGS) { $$$ }' -l ts src/services/billing.ts --json=compact \
  | jq -r '.[] | "\(.range.start.line + 1)\t\(.text | split("\n")[0])"'
# -> "42  function applyDiscount(order, coupon) {"  ... a line-numbered map; Read only the lines you need.
```

(If your ast-grep build ships the `outline` subcommand directly, `sg outline FILE` is the ergonomic form;
the `sg run -p` pattern above is the portable equivalent and is what `intent-trace.sh` already relies on.)

**HARD vs PROTOCOL.** The outline is **HARD** in the same narrow sense intent-trace is: a tree-sitter
match proves a declaration *exists at a line* — deterministic, not an LLM read. It is **NOT** a
correctness or completeness claim: it does not prove the function does what its name says, does not follow
dynamic dispatch, and does not see anything the parser doesn't model (macros, codegen, runtime wiring).
Absence of a node in the outline = NOT-FOUND in *this file*, never proven-absent from the system.

**Where it loses to graphify, every time:** cross-file relationships, call graphs, "who imports this,"
semantic clustering, the wiki's curated narrative. Never reach for `sg` to answer those — that is exactly
the second-index anti-pattern this extension exists to forbid.

---

## 2. When to use vs skip

Use it when: graphify + wiki have already narrowed you to a **specific large file** and you want to find
the right region before reading; you need a deterministic declaration map (e.g. to pick the `file:line`
for an `intent-trace` proof); you are token-constrained and a full `Read` of an 800-line file is wasteful.

Skip it when: you have NOT yet run graphify + checked the wiki (do that first — non-negotiable); the file
is small (just `Read` it — outline overhead isn't worth it); the question is cross-file or relational (use
graphify); ast-grep is absent (then fall back to `Read`, recorded as a LOUD skip, never silent — and
**never** spin up an index to compensate).

---

## 3. PROVE IT BEFORE YOU MANDATE IT (benchmark gate)

This extension is **OPT-IN and UNPROVEN until benchmarked.** "Cheaper than Read" is a *hypothesis*, not a
measured fact. Per the HONESTY law, do not bake `sg outline` into the standing nav order as a *mandate*
until an A/B benchmark shows it actually pays off.

The benchmark mechanism is the **prove-pillar / A/B harness** specified in `walteur-kit/eval/prove-pillar.md` (run it with `eval/ab-bench.sh`)
(`walteur-kit/eval/`, the `claude -p` with-arm/without-arm token·time telemetry harness). **Honesty note:
that harness is SPECIFIED, NOT YET BUILT** — so the benchmark below is a contract to run *when the harness
ships*, not a result to cite today. Absence of the harness = NOT-FOUND, never proven-absent.

The A/B to run, once the harness exists:

| Arm | Procedure | Measure |
|---|---|---|
| **A — Read** | graphify query → wiki → blind full-file `Read` → answer | tokens, wall-time, answer correctness |
| **B — outline** | graphify query → wiki → `sg outline` → targeted `Read` of the named region → answer | tokens, wall-time, answer correctness |

Promote `sg outline` from "opt-in aid" to "mandated step 3" ONLY if arm B shows a material token/time win
**at equal answer correctness** across a representative file-size spread. If B wins on tokens but loses
correctness (skimmed past the relevant code), it stays opt-in — a token saving that drops accuracy is a
regression, not a win. Record the verdict; never sell the hypothesis as the result.

**Bottom line:** `sg outline` is a position-3 navigation aid that extends — never replaces or precedes —
the graphify-first nav order. It is HARD on declaration existence, silent on correctness, and stays
opt-in until the prove-pillar harness measures the win.
