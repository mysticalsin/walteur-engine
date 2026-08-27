# WALTEUR v9.1 — AST proof + self-correcting memory + the asset lifts

> **Through-line.** v9.1 moves enforcement from PROTOCOL (LLM judgment) toward HARD (deterministic
> tree-sitter proof) and memory from append-only toward self-correcting — both in service of WALTEUR's
> de-circularized-eval law. Sourced from a 32-agent evaluation of 6 external repos (goose, claude-context,
> context-engineering-intro, ast-grep, graphiti, ai-dev-tasks). graphify stays the ONE retrieval brain;
> no second KG; no standing infra added.

Provenance (all credit-clean to lift): ast-grep (MIT) · graphiti (Apache-2.0) · goose (Apache-2.0) ·
claude-context (MIT) · context-engineering-intro / ai-dev-tasks (MIT/Apache). Adapted into WALTEUR's idiom.

---

## A. SHIPPED HERE (git SPEC tree) — verified with real runs

The first AST awareness in a 36-hook gate set that was 100% grep/awk/sed/find.

| Artifact | What | Honesty |
|---|---|---|
| `sgconfig.yml` | ast-grep project config (ruleDirs + testConfigs) | inert until a hook invokes ast-grep |
| `ast-grep-rules/empty-catch.yml` (py) | `except: pass` swallowed error | **HARD** (severity:error), twin-proven |
| `ast-grep-rules/empty-catch-js.yml` | `catch(e){}` / `catch(e){;}` empty | **HARD**, twin-proven |
| `ast-grep-rules/raw-primitive-inline-style.yml` | raw `<button/input/select/textarea style={{…}}>` (both forms) | **HARD**, twin-proven |
| `ast-grep-rules/swallowed-error.yml` · `todo-placeholder.yml` · `banned-api-call.yml` | NEW-coverage candidates | **`severity: warning` (ADVISORY)** — node-kinds not yet twin-proven; warning ⇒ `scan` exits 0 ⇒ does NOT trip the gate. Promote to `error` only after a green `ast-grep test` fixture. |
| `ast-grep-tests/*-test.yml` + `__snapshots__/` | good/POISON twin fixtures (the kill-criterion) | `ast-grep test` = **3 passed / 0 failed** |
| `required-tools.json` | registers ast-grep `required:false` (opt-in) | **PROTOCOL-by-design**: required:false keeps "machinery is optional" intact; absence ⇒ LOUD SKIP to the grep floor, never a hard dependency |
| `hooks/_ast-grep-preamble.sh` | shared opt-in runner: ast-grep error-match ⇒ exit 1 ⇒ remap **1→2** (host FAIL); absent/errored ⇒ **return 100** (LOUD SKIP → grep floor) | **HARD** remap is the deterministic spine |
| `hooks/resilience-lint.sh` (spliced) | AST backend is **ADDITIVE**: AST finding ⇒ exit 2; AST-clean OR absent ⇒ fall through to the full grep floor (R1–R5 never lost) | **HARD**; coverage strictly increases |
| `hooks/anti-slop-ui.sh` (spliced) | same, gated on `SHADCN==1`; R1–R10 grep floor preserved | **HARD** |
| `hooks/intent-trace.sh` | §5.5 deterministic arm: per PRD `ast_proof`, prove the construct EXISTS at file:line into `audit.json.intent_vs_impl[]`; HARD-fail (exit 2) on a claimed-but-ABSENT construct; `--selftest` = **3/3** | **HARD on EXISTENCE only.** Every proof carries `proves:"existence"` + `not_proven:"correctness…(PROTOCOL §5.4)"`. Absence = NOT-FOUND, never PROVEN-ABSENT. |
| `schemas/prd.schema.json` (bumped) | `stories[].acceptance[]` = `oneOf(string \| {text,construct,ast_proof})` | back-compat (string ACs still valid); prd-gate selftest **5/5** unchanged |

**The load-bearing fence:** an AST match proves a construct **exists at a line** — it never proves the
construct is **correct** or that it runs on the **live path**. Correctness stays PROTOCOL (§5.4
Logic-Correctness + the policy-shadow guard). intent-trace encodes this in every proof object.

### Verification evidence (run 2026-06-15, ast-grep 0.42.3 via pip venv)
```
ast-grep test -c sgconfig.yml         -> 3 passed; 0 failed
resilience-lint (poison except:pass)  -> exit 2  (walteur-empty-catch-py fired)
resilience-lint (clean)               -> exit 0  (AST clean -> grep floor -> PASS)
anti-slop-ui (shadcn + raw <button style>) -> exit 2  (walteur-raw-primitive-inline-style fired)
intent-trace.sh --selftest            -> 3/3   (good PASS / poison CAUGHT / NA)
resilience-lint (ast-grep ABSENT)     -> LOUD SKIP -> grep floor (no crash)
prd-gate.sh --selftest                -> 5/5   (regression clean after schema bump)
bash -n (4 hooks) / jq (2 json) / yaml (10 files) -> all OK
```
The kill-criterion already paid off: the first `ast-grep test` run CAUGHT a bad rule (an undefined
`$TAG` constraint) and three rules whose hand-built node-kinds did not match — all fixed against the
real parser before shipping. `required:false` means even a wrong rule cannot break a build (grep floor).

---

## B. APPLIED to the canonical kit (`~/walteur/starter`; merged to `~/walteur` main `db239a8`)

Done + verified (canonical `selftest.sh` v9.1 block 4/4; lesson-gate supersede twin 6/6; orchestrator-smoke PASS).
ship-gate now dispatches prd-gate + intent-trace + osv-gate; the AST backend, recipe schema, memory
schema/recall, bi-temporal supersede, spec-trace T4, and pause_per_task are all wired. Reference copies +
trail in `canonical-kit-staging/README.md`.
- **Bi-temporal lessons** (graphiti PATTERN, not engine): `invalidated_at` / `superseded_by` / `source_build`
  nullable fields + `lesson-gate.sh` closing the superseded window in the LIVE store (was: park-and-keep-serving).
  Conservative: auto-close only on explicit link or exact-key contradiction; ambiguous = HELD. `recall.sh`
  filters current-only. Zero deps, flat-file (honors §18).
- **`pause_per_task`** (ai-dev-tasks salvage): a third `autonomy_policy`, off by default, reusing the shipped
  APPROVED-file + STATE.json halt-resume seam.
- **spec-trace.sh T4 Arm B**: delegate an AC with an `ast_proof` to intent-trace for a code-PROOF — STAGED
  (it edits a working 15KB hook; apply after reviewing the real :251-267).

---

## C. NEXT scoped builds (the deep-mine lifts — specified, not yet built)

Disciplined order; each is cheap and on-ethos (no infra-in-repo):
1. **OSV supply-chain gate** (goose) — `detect-or-LOUD-SKIP` hook querying OSV.dev (free REST), fail-closed
   on `MAL-*` for new deps + candidate MCP servers. Closes the gap gitleaks doesn't. New pillar **P-OSV**.
2. **`recipe.schema.json`** (goose) — a portable parameterized runnable workflow artifact (typed params +
   `response.json_schema` output + `sub_recipes`), interpreted by walteur.js. No goose runtime.
3. **build-with-agent-team skill** (context-eng) — lead authors integration contracts BEFORE parallel spawn
   + a contract-diff gate. Upgrades claude-squad's worktree-only isolation.
4. **The `claude -p` A/B benchmark harness** (ast-grep) → `walteur-kit/eval/` — machinery to PROVE a pillar
   pays off (with/without arms, token/time telemetry). Directly serves the HONESTY law.
5. **graphify extensions** (claude-context Merkle-DAG incremental sync; ast-grep `sg outline`) — ONE brain.
6. **Prompt micro-lifts**: lettered-option scoping questions; "Relevant Files (+paired tests)" PLAN manifest;
   `.claude/rules/memory-discipline.md` (search-before-act); BATON Dead-Ends + Key-Decisions sections.

**Reconciled tension:** PRP's self-scored 1-10 confidence (context-eng) is adopted ONLY as an *internal*
trigger ("<7 ⇒ run another red-team round"), never a shippable quality claim (HONESTY law).

## D. SKIP (honest declines)
goose runtime/provider-gateway/ACP · graphiti MCP+Neo4j engine · claude-context Milvus pillar (standing infra,
duplicates graphify) · context-eng Cloudflare MCP template · ai-dev-tasks as a framework. All re-platform,
drag infra, or collide with graphify.

## E. v10 bets (gated, not promised)
- **Lessons semantic recall** via a graphify embedding-index EXTENSION over `lessons.jsonl` (the sharpest gap
  none of the 6 fixed; today recall is lexical, which also blinds the bi-temporal supersede to
  differently-worded contradictions). Embeddings RANK/SUGGEST only, never auto-close. Gate: measure the
  recall-miss rate + verify a graphify embedding API exists first.
- Author ONE real recipe and A/B it before generalizing the recipe layer.
- `valid_from` / point-in-time lesson replay — only when a workflow consumes it.

## F. CI wiring
Add to the standing selftest surface:
```
ast-grep test -c walteur-kit/sgconfig.yml        # 3/3 (rules)
bash walteur-kit/hooks/intent-trace.sh --selftest # 3/3 (existence arm)
```
Both require ast-grep + jq on the CI image (the eval/run-all.sh runner installs pillar tools via bootstrap).
