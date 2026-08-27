# prove-the-pillar-pays — A/B benchmark methodology

> **The first WALTEUR machinery that MEASURES instead of asserts.** Every other gate proves a
> thing EXISTS or has a SHAPE. This one asks the harder question the HONESTY law (§1) demands of any
> connection/pillar we bolt on: **does it actually pay?** A pillar (a skill, an MCP server, a graphify
> extension, an `--append-system-prompt` rule, a retrieval step) earns its place only if turning it ON
> beats turning it OFF — on cost, tokens, time, AND quality — by more than the noise. Otherwise it is
> ceremony, and ceremony is slop.
>
> Lifted from ast-grep's `claude -p` paired-arm evaluation methodology (run the same task twice, once
> with the candidate change and once without, on a balanced order, and read the delta). Vendor-neutral
> here; the runner is `claude` because that is the engine WALTEUR drives — see `eval/ab-bench.sh`.

---

## 0. Honest preconditions (read first)

- **This needs the `claude` CLI on PATH.** No CLI => the runner does a LOUD SKIP (exit 0, recorded —
  never silent-green). The methodology below is real; the *measurement* is only as real as the runs you
  can actually execute. Absence of a run = NOT-MEASURED, never "the pillar is proven worthless".
- **This is PROTOCOL, not a HARD gate.** It does not block a build. It produces a *verdict* a human (or
  the §5 review corps) reads. It mechanically computes the deltas; it does NOT mechanically decide the
  pillar's fate — net-value judgment under noise stays human. Label it honestly when you cite it.
- **A win on one task is not a win.** N=1 is an anecdote. The verdict is only trustworthy across a SUITE
  of representative tasks with enough repeats that the delta clears the run-to-run variance. State your N.
- **Cost is real money.** Each arm is a real `claude -p` call that spends tokens. Budget it. The harness
  records spend so you can see what the experiment itself cost — the meta-honesty: a benchmark that costs
  more than the pillar saves is itself slop.

---

## 1. The paired-arm design

For one task `T` and one pillar `X`:

| Arm | Pillar X | Everything else |
|---|---|---|
| **with** (treatment) | ON | identical |
| **without** (control) | OFF | identical |

Both arms run the **same task prompt**, **same model**, **same seed of inputs**, **same isolation**. The
ONLY difference is whether X is wired in. That single-variable discipline is what makes the delta
attributable to X and not to drift. If you change two things, you have measured nothing.

How "X on/off" is expressed depends on what the pillar is — the harness toggles via a task-file field:

- **a skill / system rule** → `--append-system-prompt` (on-arm) vs nothing (off-arm).
- **an MCP server** → present in `--mcp-config` (on-arm) vs absent, both under `--strict-mcp-config`.
- **a graphify retrieval step** → a pre-step that injects retrieved context (on-arm) vs the raw prompt
  (off-arm). (graphify stays the ONE retrieval brain — this measures whether *using* it on this task
  pays; it does not build a second index.)
- **a tool allowlist / a planning preamble / a context-pack** → any flag/preamble pair the task file pins.

---

## 2. Balanced run order (kill the order/cache bias)

Running all `with` arms first then all `without` arms confounds the pillar with **time-order effects**:
prompt-cache warmth, model-side rate-of-day variance, your machine warming up. So the harness
**alternates** the arm order across repeats — `with,without` on even repeats, `without,with` on odd —
and (when N is small) you should additionally **interleave across tasks**, never batch a whole arm.
Record the actual order in each result row so a reader can audit for residual order bias.

Cache caveat (honest): `claude -p` prompt caching can still advantage whichever near-identical arm runs
second within a pair. Balancing the order cancels this *in expectation* across repeats; it does not
cancel it within a single pair. This is why N matters and why the verdict reads the MEAN delta, not one
pair. If you need to defeat caching entirely, vary a no-op nonce per arm — at the cost of realism.

---

## 3. Telemetry — what each arm captures

Run each arm as `claude -p "<task>" --output-format stream-json --verbose` (or `--output-format json`
for just the terminal result object). The harness reads the **final result event**, which carries the
real numbers — not estimates:

| Metric | Source field | Why it matters |
|---|---|---|
| **cost** | `total_cost_usd` | the money the pillar costs or saves — the bottom line |
| **input tokens** | `usage.input_tokens` (+ cache read/creation) | context bloat is the usual hidden tax of a pillar |
| **output tokens** | `usage.output_tokens` | did the pillar make the model write more, or less? |
| **time** | `duration_ms` (+ `duration_api_ms`) | wall-clock the user feels |
| **tool calls** | count of `assistant`→`tool_use` events in the stream | a proxy for wasted motion / extra round-trips |
| **turns** | `num_turns` | did the pillar converge the task faster? |
| **success** | `is_error` / `subtype` | a cheap arm that failed the task is not cheaper |

stream-json gives you the per-event trail (so you can count tool calls and see WHERE the time/tokens
went); plain `json` gives you only the terminal aggregate. The harness prefers stream-json and falls
back to json. If the runner emits neither parseable shape, that arm is recorded as **unparseable**, not
guessed — an unparseable arm cannot win or lose, it is excluded with a loud note.

---

## 4. Quality — deterministic rubric first, LLM-judge optional

Cheaper + faster is **worthless if the answer got worse**. So every arm's output is scored for quality,
two tiers, deterministic first:

**4a. Deterministic rubric (always; no extra model spend).** The task file ships a `rubric`: a list of
checks the output must satisfy — each is a grep/regex/`test`-able assertion (e.g. "output contains a
fenced code block", "exit 0 of an embedded selftest", "mentions the error path", "diff applies clean").
Score = checks passed / total. Deterministic, reproducible, zero-cost, no judge bias. This is the
**primary** quality signal because it is mechanical.

**4b. LLM-judge (optional, opt-in, `--judge`).** For quality dimensions a regex can't capture (is the
explanation actually clear? is the design sound?), a SEPARATE `claude -p` call scores both arms'
outputs **blind to which arm is which** (A/B labels randomized per pair), on a pinned rubric, returning
a 1–5 per dimension as JSON. Honest caveats, all load-bearing:

- The judge is itself an LLM and itself costs tokens — its spend is recorded and counted against the
  experiment's meta-cost.
- Judge it **blind and order-randomized**, or you measure position bias, not quality.
- One judge is one opinion. For a real verdict, run the judge ≥3× and read the median, or use a panel.
- A judge score is PROTOCOL, never HARD. It informs the verdict; it does not certify it.

---

## 5. Run isolation — no leakage between arms

A pillar's measured win is a LIE if the off-arm secretly had the pillar anyway (skill auto-loaded, a
stray MCP server attached, prior context bleeding in). So each arm runs **hermetically**:

- **`--strict-mcp-config`** — ONLY the MCP servers named in the arm's `--mcp-config` load. The off-arm
  passes an EMPTY mcp-config under strict, so no ambient server leaks in. The on-arm passes exactly the
  one server under test. (Without `--strict-mcp-config`, your user/project `.mcp.json` servers attach to
  BOTH arms and the experiment is contaminated.)
- **no skill leakage** — the harness runs each arm in a clean temp CWD with no project `.claude/` and no
  auto-trigger surface, so a skill cannot silently attach to the off-arm. The on-arm's "skill" is
  injected explicitly via `--append-system-prompt` so the toggle is the ONLY difference.
- **fresh session per arm** — never `--resume`; each arm is a cold `-p` invocation. No conversational
  carry-over from the previous arm.
- **pinned model** — both arms pass the SAME `--model`. A model drift between arms invalidates the pair.
- **isolated CWD / no shared write target** — arms do not write to a shared path that the next arm could
  read. Outputs land in per-arm files under the results dir.

If any isolation control cannot be enforced in your environment, the harness records it as a
**contamination caveat** on the row. A contaminated pair is reported, not silently averaged in.

---

## 6. Reading the verdict — a pillar earns its place ONLY if the with-arm wins NET of cost

For each metric, the harness computes the mean delta across repeats:

```
delta_metric = mean(with) - mean(without)        # negative = with-arm is cheaper/faster/leaner
quality_delta = mean(with.quality) - mean(without.quality)   # positive = with-arm is better
```

The verdict rule (PROTOCOL — the harness computes it; a human ratifies it):

- **PILLAR PAYS** — the with-arm is *better or equal* on quality AND wins on the cost basket (cost +
  tokens + time net out in its favor) by a margin that **clears the run-to-run noise** (report the spread,
  not just the mean; a delta inside the variance band is **INCONCLUSIVE**, not a win).
- **PILLAR COSTS** — the with-arm spends more (cost/tokens/time) with **no** quality gain that justifies
  it. This pillar is ceremony. Cut it, or make it opt-in-only so it never taxes the default path.
- **INCONCLUSIVE** — the delta is inside the noise band, or N is too small, or arms were contaminated /
  unparseable. The honest verdict. It means *run more*, not *ship it anyway*.

A net-value call (is a 4% quality gain worth a 30% cost rise?) is a **human judgment** the harness
refuses to fake — it lays out every delta + the noise band + the meta-cost of the experiment, and a
person decides. Never let "the benchmark said so" stand in for that decision. That is the HONESTY law:
the harness measures; it does not pretend the trade-off is mechanical.

---

## 7. Anti-bloat boundary (§ ANTI-BLOAT)

This is **opt-in measurement infra**, not standing infra. It writes one append-only log
(`eval/ab-results.jsonl`) and reads task files you author. It builds **no** second knowledge graph, no
vector index, no daemon — any retrieval pillar it measures is a graphify EXTENSION, never a rival brain.
Don't leave it running; run it when you're deciding whether a pillar is worth its weight, read the
verdict, and stop.

---

## 8. Run it

```bash
# parse + arm-toggle logic, hermetic, NO real claude call — must exit 0
bash walteur-kit/eval/ab-bench.sh --selftest

# a real paired run (needs `claude` on PATH; LOUD-SKIPs exit 0 if absent, or set WALTEUR_ABBENCH=strict to fail-closed)
bash walteur-kit/eval/ab-bench.sh --task walteur-kit/eval/tasks/example.json --repeats 4
# results append to walteur-kit/eval/ab-results.jsonl ; a comparison table prints to stderr
```

The arm runner is overridable: point `WALTEUR_ABBENCH_RUNNER` at a **sourceable file** that defines a
shell function `ab_runner` (a path, NOT a bare function name — a name would not survive the recursive
`bash` boundary, since env vars carry strings, not function bodies). This is exactly how `--selftest`
injects its MOCK runner with no real `claude` call, and how you'd wire a non-`claude` engine.

Task file shape (JSON) the harness reads:

```json
{
  "id": "graphify-context-pays",
  "prompt": "Explain what the resilience-lint R2 rule catches and why.",
  "model": "claude-sonnet-4-6",
  "pillar": {
    "name": "graphify-context",
    "with": { "append_system_prompt": "Use the retrieved repo context below:\n<...>" },
    "without": {},
    "mcp_config_with": null,
    "mcp_config_without": null
  },
  "rubric": [
    { "name": "names-timeout", "contains": "timeout" },
    { "name": "names-the-rule", "regex": "R2|network call" }
  ],
  "judge": { "enabled": false, "dimensions": ["accuracy", "clarity"] }
}
```

HARD vs PROTOCOL, stated once more so no reader confuses them: the harness **mechanically** captures
cost/tokens/time/tool-calls and **mechanically** scores the deterministic rubric. Whether the resulting
delta means the pillar should ship is **PROTOCOL** — judgment, under noise, by a human reading the
spread. Absence of a measurement is NOT-MEASURED, never PROVEN-WORTHLESS.

---

## 9. deepeval — agent/LLM-output evaluation path

### What it measures (and what it doesn't)

There are two distinct eval surfaces in WALTEUR. They are complementary, not competing:

| Surface | What it captures | Who emits it |
|---|---|---|
| **run-trace** (`ab-bench.sh` / `§ 3 Telemetry`) | Engine telemetry — latency, tokens, cost, tool calls, turns | The **orchestrator** (the `claude` CLI / harness) |
| **deepeval** (this section) | Output quality — faithfulness, hallucination, task-completion, G-Eval score | The **agent's answer** (the LLM-produced text) |

`run-trace` tells you whether the engine ran efficiently. `deepeval` tells you whether the answer was
any good. You need both; neither replaces the other. A cheap run that produced a hallucinated answer
is not a win.

### deepeval rides the existing pytest gate — no new runner, no new hook

WALTEUR already has a pytest verification gate. deepeval adds nothing structural: you write pytest test
cases that import deepeval metrics and call `assert_test()`. A metric that scores below its threshold
fails the assertion; pytest fails the test; the gate catches it. The runner is still pytest.

```python
from deepeval import assert_test
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, LLMTestCaseParams

def test_output_quality():
    metric = GEval(
        name="Correctness",
        criteria="Output correctly answers the question without hallucination",
        evaluation_params=[LLMTestCaseParams.ACTUAL_OUTPUT, LLMTestCaseParams.EXPECTED_OUTPUT],
        threshold=0.7,
    )
    test_case = LLMTestCase(
        input="...",
        actual_output="...",  # the agent's answer
        expected_output="...",
    )
    assert_test(test_case, [metric])
```

Available metric classes (import from `deepeval.metrics`): `GEval`, `FaithfulnessMetric`,
`HallucinationMetric`, `TaskCompletionMetric`, and others. Each takes a `threshold` — breach it and the
test fails.

### Key env vars (both mandatory for local-only use)

| Var | Value | Purpose |
|---|---|---|
| `DEEPEVAL_TELEMETRY_OPT_OUT` | `YES` | **Mandatory.** No network call, no deepeval login required. |
| `DEEPEVAL_RESULTS_FOLDER` | `walteur-kit/eval/deepeval-results/` | Where result JSON files land. **This is the evidence path prove-pillar cites.** |

Run via the recipe: `walteur-kit/recipes/deepeval-eval.recipe.yaml` (Task D). The recipe sets both
vars, runs pytest, and validates that result files appeared in `DEEPEVAL_RESULTS_FOLDER`.

### Relationship to prove-pillar (§ A/B benchmark)

prove-pillar (§§ 1–8) measures whether a **pillar** (a skill, an MCP server, a retrieval step) pays
its way across a suite of tasks — the delta in cost/tokens/time/quality between the with-arm and the
without-arm. deepeval measures the **quality score** of a specific agent output against a rubric.

They answer different questions:

- prove-pillar: *"Does adding this pillar improve the outcome enough to justify its cost?"*
- deepeval: *"Is this specific output faithful / hallucination-free / task-complete to a threshold?"*

In practice, deepeval assertions can be the **quality signal** inside a prove-pillar rubric (§ 4a /
4b): wire a deepeval pytest as the quality check for each arm, point the results at
`DEEPEVAL_RESULTS_FOLDER`, and the harness can read the scores. This makes the quality dimension of the
A/B experiment machine-readable rather than grep-only. That integration is opt-in; the two tools
remain independent by default.
