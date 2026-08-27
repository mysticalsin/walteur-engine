# Loop Scout - 2026-06-22

## Source Scan

- [OpenAI Agents SDK](https://github.com/openai/openai-agents-python): multi-agent workflows built around agents, tools, handoffs, guardrails, human-in-the-loop, sessions, and tracing.
- [LangGraph](https://github.com/langchain-ai/langgraph): durable execution, human-in-the-loop state inspection, persistent memory, and tracing for long-running stateful agents.
- [Microsoft Agent Framework](https://github.com/microsoft/agent-framework): production-grade multi-agent workflows with graph patterns, checkpointing, streaming, human-in-the-loop, observability, declarative agents, skills, and benchmarking labs.
- [CrewAI](https://github.com/crewAIInc/crewAI): role/task driven agent crews and sequential workflows that make delegation explicit.
- [Self-Harness](https://arxiv.org/abs/2606.09498): evidence-driven harness improvement loop: weakness mining from traces, bounded proposals, and regression validation before promotion.
- [AgentSPEX](https://arxiv.org/abs/2604.13346): explicit workflow specification, typed steps, branching, loops, parallel execution, checkpointing, verification, and logging.

## Adopt Now

- Add `outcome-eval-gate.sh`: the builder cannot be the only judge of whether the user outcome was met.
- Add `self-improvement-gate.sh`: every serious run must mine traces, scout current GitHub/source patterns, propose bounded upgrades, validate regressions, and capture reusable lessons.
- Keep scouts quarantined: a GitHub repo can inspire a pattern or candidate, but adoption requires license, maintenance, security, fit, regression, and rollback evidence.

## Next Candidates

- Replay/time-travel proof for failed traces, inspired by durable agent frameworks.
- Tool-call guardrail coverage table: every external tool gets pre-call, post-call, and error-path checks.
- Production-shadow eval pack for LLM-backed builds: fixed test set plus rolling real-traffic samples.
- Subagent roster registry: product, architecture, security, QA, UX, SRE, data, compliance, and outcome-evaluator roles selected by build class and risk tier.

## Decision

WALTEUR should stay stack-neutral and file-first. Do not embed a framework runtime by default. Instead, borrow the best control surfaces: explicit state, typed gates, trace evidence, subagent boundaries, human authority boundaries, independent evaluation, and measured self-improvement.

## Progress (loop)

- 2026-06-23 — Adopt Now items SHIPPED earlier in this wave: `outcome-eval-gate.sh`, `self-improvement-gate.sh`.
- 2026-06-23 — **Next Candidate #2 DONE**: tool-call guardrail coverage → `tool-guardrail-gate.sh` + `schemas/tool-guardrails.schema.json` (rules G1–G6: pre-call/post-call non-empty, error-path arrays + non-silent on_fatal, dangerous/external invariant, full tool-contract coverage). Wired into `gate-registry.json` (data-ai, spec) + HARNESS-LOOP "Tool Guardrail Coverage Contract" + aggregate selftest. Proof: hook `--selftest` 15/15, full `selftest.sh` **146 passed / 0 failed / 0 skipped** (run sandbox-disabled — see mktemp note). Uncommitted.
- 2026-06-23 — **#2 HARDENED** after a 4-lens adversarial self-review (rated 7/10). Closed confirmed false-PASS holes: G0 envelope validation (rejects quoted `"external":"true"` + missing top-level keys), G7 no-silent-empty-table (`no_external_tools` ack), G5 now requires `evidence_ref` on every band for dangerous/external tools, mktemp idiom fixed, G1/G2/G3 fixtures added (caught + fixed a `jq -e` stream-last-value assertion bug — see memory), HARNESS-LOOP wording de-overclaimed. Proof: hook `--selftest` 27/27, full `selftest.sh` **149/0/0 ALL GREEN**. Honest residual scope: externality is author-asserted (gate can't infer from code); `checks`/`evidence_ref` prove declared-and-wired, runtime execution is QA/outcome-eval's job.
- Remaining Next Candidates for future loop iterations: #1 replay/time-travel proof for failed traces · #3 production-shadow eval pack · #4 subagent roster registry by build-class/risk-tier. NOTE: wave is large + uncommitted (≈140 paths) — consider committing before adding more gates.
