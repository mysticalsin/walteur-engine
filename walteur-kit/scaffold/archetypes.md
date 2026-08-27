# WALTEUR Scaffold Archetypes
> STARTING POINTS — customized to the actual project. Never shipped verbatim.
> Pick: detect stack → match archetype → lay out tree → generate UNIQUE context (AGENTS.md + CLAUDE.md + .claude/rules).

---

## ai-app (Python / FastAPI — the reference archetype)

Best-practice production tree. 20/10 differentiators are **first-class**: versioned prompt registry, 3-layer security, evals-first golden dataset, per-stage observability.

```
your-ai-app/
├── app/
│   ├── main.py              # FastAPI entry — lifespan, router mounts, middleware
│   ├── config.py            # pydantic-settings: env-sourced, no hardcoded literals
│   └── models.py            # Pydantic request/response schemas
├── components/
│   ├── hybrid_retriever.py  # dense + sparse retrieval fusion
│   └── reranker.py          # cross-encoder reranker (Cohere / local)
├── services/
│   ├── rag_pipeline.py      # orchestrator: retrieve → rerank → generate
│   ├── semantic_cache.py    # exact + approximate cache (Redis / in-mem)
│   ├── conversation.py      # session history manager
│   ├── query_rewriter.py    # HyDE / step-back / query expansion
│   └── query_router.py      # intent classifier → route (RAG / direct / tool)
├── prompts/
│   ├── templates/           # versioned .jinja2 / .txt templates (hot-swappable)
│   └── registry.py          # loads by name+version; never hardcoded strings in code
├── agents/
│   ├── document_grader.py   # relevance scorer (LLM-as-judge)
│   ├── query_decomposer.py  # sub-question decomposition
│   ├── adaptive_router.py   # dynamic strategy selector
│   └── tools/
│       ├── vector_search.py
│       ├── web_search.py
│       └── code_search.py
├── security/
│   ├── input_guard.py       # Layer 1: prompt-injection + PII scrub on input
│   ├── content_filter.py    # Layer 2: topic scope + toxicity filter mid-pipeline
│   └── output_filter.py     # Layer 3: PII redaction + policy check on output
├── evaluation/
│   ├── golden_dataset.json  # curated Q/A pairs — the evals-first contract
│   ├── offline_eval.py      # batch runner: correctness + faithfulness + relevance
│   ├── online_monitor.py    # live traffic shadow eval (sample-based)
│   └── eval_results/        # timestamped JSONL output — never overwrite
├── observability/
│   ├── tracer.py            # OpenTelemetry spans: retrieve/rerank/generate latency
│   ├── feedback.py          # thumbs up/down collector → eval loop
│   └── cost_tracker.py      # token usage per request → budget dashboard
├── data/
│   ├── raw/                 # source documents (immutable)
│   ├── processed/           # chunked + cleaned
│   └── index_config.json    # embedding model, chunk size, overlap — versioned
├── scripts/
│   ├── seed.py              # ingest raw/ → processed/ → vector store
│   ├── migrate.py           # index schema migrations
│   └── healthcheck.py       # end-to-end smoke (retrieval + generation)
├── frontend/                # optional: lightweight chat UI (Next.js or Streamlit)
├── tests/
│   ├── unit/                # component-level (retriever, reranker, router)
│   ├── integration/         # pipeline end-to-end against golden_dataset
│   └── eval/                # offline_eval CI runner (exits 0 only on threshold pass)
├── docs/
│   ├── architecture.md      # decision log: model choice, retrieval strategy, guards
│   ├── api-reference.md     # OpenAPI supplement (the /docs endpoint is live, this is prose)
│   └── deployment.md        # infra, env vars, scaling notes
├── .claude/
│   ├── rules/
│   │   ├── code-style.md    # stack-specific: typing, import order, async patterns
│   │   └── testing.md       # eval-first: golden dataset is the ground truth
│   └── settings.json        # permissions + hooks
├── CLAUDE.md                # project-specific — @AGENTS.md + Claude-only notes
├── AGENTS.md                # cross-tool standard (Linux Foundation / agents.md)
├── docker-compose.yml       # app + redis + vector store (local dev)
├── pyproject.toml           # deps + ruff + pytest config
└── README.md
```

**20/10 differentiators (baked in, not optional):**
- `prompts/registry.py` — every prompt is named + versioned; hot-swappable without code deploys
- `security/` — 3 layers: input (injection/PII), mid-pipeline (scope/toxicity), output (redaction/policy)
- `evaluation/golden_dataset.json` — evals-first: golden set exists before first production request
- `observability/` — per-stage latency + live shadow eval + token cost; no blind spots

---

## web-app (Next.js full-stack)

```
your-web-app/
├── app/                     # Next.js 14+ App Router
│   ├── (auth)/              # route group: login, register, callback
│   ├── (dashboard)/         # route group: main product surfaces
│   ├── api/                 # Route Handlers: REST endpoints + webhooks
│   └── layout.tsx           # root layout: fonts, providers, error boundary
├── components/
│   ├── ui/                  # shadcn/ui primitives (Button, Input, Dialog…)
│   ├── features/            # domain components (each owns its stories)
│   └── layouts/             # page-level shells (Sidebar, TopNav, Shell)
├── lib/
│   ├── db/                  # Drizzle ORM schema + migrations
│   ├── auth/                # next-auth config + session helpers
│   ├── api/                 # typed fetch wrappers (tRPC or plain)
│   └── utils/               # pure helpers (no side effects)
├── hooks/                   # React custom hooks
├── stores/                  # Zustand / Jotai state slices
├── design-system/
│   └── MASTER.md            # token system: colors, typography, spacing (the design contract)
├── public/                  # static assets
├── tests/
│   ├── unit/                # Vitest: utils, hooks, store reducers
│   ├── integration/         # Playwright: critical user flows
│   └── a11y/                # axe-core accessibility audit
├── .claude/
│   ├── rules/
│   │   ├── code-style.md    # TypeScript strict, import conventions, no `any`
│   │   └── testing.md       # every component has Default + Loading + Error story
│   └── settings.json
├── CLAUDE.md
├── AGENTS.md
├── DESIGN.md                # design contract (design-gate.sh reads this)
├── next.config.ts
├── drizzle.config.ts
├── package.json
└── tsconfig.json
```

---

## cli (command-line tool)

```
your-cli/
├── src/
│   ├── main.ts              # entry: arg parse → command dispatch
│   ├── commands/            # one file per subcommand (init, run, ls, rm…)
│   ├── core/                # business logic (pure, testable, no I/O)
│   ├── io/                  # all I/O (fs, network, stdin/stdout) isolated here
│   └── config/              # schema + loader (zod-validated, env + file)
├── tests/
│   ├── unit/                # core/ logic — no I/O, fast
│   ├── integration/         # commands with real FS in tmp dirs
│   └── fixtures/            # sample inputs + expected outputs
├── .claude/
│   ├── rules/
│   │   ├── code-style.md    # exit codes, stderr for errors, stdout for data
│   │   └── testing.md       # fixtures-based: add fixture before implementing edge case
│   └── settings.json
├── CLAUDE.md
├── AGENTS.md
├── package.json             # or pyproject.toml / go.mod / Cargo.toml
├── tsconfig.json
└── README.md
```

---

## cloud-iac (Terraform / Pulumi service)

```
your-infra/
├── modules/
│   ├── networking/          # VPC, subnets, security groups
│   ├── compute/             # ECS / Lambda / GKE workloads
│   ├── data/                # RDS, DynamoDB, S3 buckets
│   └── observability/       # CloudWatch / Grafana / PagerDuty wiring
├── environments/
│   ├── dev/                 # per-env tfvars + backend config
│   ├── staging/
│   └── prod/
├── scripts/
│   ├── plan.sh              # terraform plan + cost estimate (Infracost)
│   ├── apply.sh             # guarded apply (requires APPROVED marker)
│   └── destroy.sh           # requires explicit DESTROY_CONFIRMED env var
├── tests/
│   ├── unit/                # terratest module tests (go test)
│   └── compliance/          # tfsec + checkov policy assertions
├── .claude/
│   ├── rules/
│   │   ├── code-style.md    # no hardcoded secrets, tag every resource, module-per-concern
│   │   └── testing.md       # every module has a terratest; apply only after plan passes CI
│   └── settings.json
├── CLAUDE.md
├── AGENTS.md
├── layers.json              # edge / rate-limit / cache attestation (WALTEUR §14)
├── .terraform.lock.hcl      # committed: provider version pins
└── README.md
```

---

## Stack detection → archetype mapping

| Signal | Archetype |
|---|---|
| `requirements.txt` / `pyproject.toml` + `openai`/`anthropic`/`langchain`/`llama` | **ai-app** |
| `package.json` + `next` / `react` + `app/` dir | **web-app** |
| `package.json` / `pyproject.toml` + CLI entry (`bin`, `console_scripts`, `main.go`, `main.rs`) | **cli** |
| `*.tf` / `Pulumi.yaml` / `cdk.json` | **cloud-iac** |
| (none / ambiguous) | ask + default **web-app** |

---

*Provenance: synthesized from production patterns in vercel/next.js, tiangolo/fastapi, grpc-ecosystem, hashicorp/terraform. Each tree is a STARTING POINT — the scaffold generator customizes it to the actual PLAN/PRD/stack.*
