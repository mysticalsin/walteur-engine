# THE WALTEUR MASTER BUILD PLAN — Zero to 1M Users on Boring Tech, Executed by the Framework

> The canonical "start from zero, scale to industry standard" playbook WALTEUR applies to **any** app it's asked to build. Grounded in real scaling data (OpenAI, Shopify, Basecamp, Segment, Notion, Prime Video, Vercel, Levels.io). Brutally concrete — no generic filler, no premature distribution. Read this before scoping any product build.

## The thesis (read this first)

You do **not** "scale to 1M users" by building for 1M on day one — that's the modal failure (a real founder burned 14 months on K8s+microservices+GraphQL and launched to **zero** customers; **92% of micro-SaaS die within 18 months**, dominant cause = building before validating). You scale by shipping **ONE boring modular monolith on a single Postgres**, then climbing a known, **evidence-triggered ladder** where the **DATA tier breaks first every single time** and the app tier is cheap.

The proof:
- **OpenAI** runs ~800M ChatGPT users on **ONE primary Postgres + ~50 read replicas + PgBouncer, no sharding**.
- **Shopify** runs 2.8M LOC as a **modular monolith** (Packwerk-enforced boundaries; pods shard on `shop_id`).
- **Basecamp** serves millions on a 9-year **Rails+Hotwire** codebase with ~12 programmers (saved $7M leaving cloud).
- **Segment, Prime Video, and InVision all REVERSED microservices back to monoliths.**

**The strategy in one line:** validate demand before code → ship a modular-monolith on Postgres with **tenant-shaped IDs from the first migration** → climb the data-layer ladder (indexes → PgBouncer → read replicas → cache → partition → **shard-last**) **only when a named alert fires** → buy enterprise-readiness (auth/SOC2/audit-log) as a **revenue gate**, not a checkbox.

**WALTEUR makes this executable:** `/goal` scopes it · `estimate.json` sizes it · the Socratic auto-debate resolves the genuine forks into ADRs · the parallel swarm builds in the ACT→TEST→REFINE loop · the **multi-agent QA corps (incl. a Logic agent)** + the 8-dimension score certify it · the **31-gate dispatch** enforces the floors · a terminal Opus audit + **ship-gate (selftest 19/19)** signs every tier. **Build for the tier you're at; pre-wire only the cheap things (tenant_id, pooler, audit log) that are brutal to retrofit.**

---

## Iron principles (non-negotiable, concrete)

1. **The DATABASE breaks before the web tier — ALWAYS.** Put your best engineer + capacity budget on the data path (indexes → pooler → replicas → cache), never on microservices/K8s. The app tier stays 3–4 boxes behind a load balancer all the way to 100k.
2. **Validate demand with a landing page + manual recruiting BEFORE app logic.** Week 1 deliverable is a Next.js+Tailwind+shadcn landing page with a waitlist + Stripe payment link — *not* a repo with auth scaffolding. The core loop starts ~Day 15, after customer interviews. Hand-recruit the first 10 users yourself.
3. **Pre-wire the four things brutal to retrofit, cheap on day one:** (1) a tenant-shaped shard key (`org_id`/`workspace_id`) on **every** table from the first migration, (2) PgBouncer/Supavisor transaction-mode pooling, (3) an append-only **audit log** baked into the schema, (4) **CI-enforced module boundaries** (import-linter/Packwerk/ArchUnit/Nx). Everything else you add on evidence.
4. **Sharding is the LAST resort; its trigger is OPERATIONAL** (write-throughput ceiling on the primary, or VACUUM stalling toward TXID-wraparound — Notion's actual trigger), **not** a user-count milestone. OpenAI runs 800M users unsharded. Shard at 50k users and you've bought hundreds of endpoint rewrites + lost joins/global analytics for nothing.
5. **Modularity is a CI-LINTER boundary, not a network boundary.** Buy it with Packwerk/import-linter/ArchUnit/Nx that fails CI when a module reaches into another's internals — not with Kubernetes/a service mesh. Segment's 140+ services made a shared-lib change take ~1 week; they merged back to a monolith.
6. **Add the cache BEFORE the read replica.** AWS benchmark: 1 cache node + replica delivers the same 30k QPS as 4 read replicas for ~55% less ($780 vs $1740/mo) and cuts read QPS 60–86%.
7. **Every async job is at-least-once — design EVERY job idempotent** (a worker can crash after doing the work, before the ack). Separate priority queues so a 2FA code never waits behind a promo-email blast.
8. **Set spend alerts day one + have a Vercel exit plan.** Vercel meters 8 axes with no hard cap on Pro — documented $20→$700 bills exactly as you scale. At ~$100–200/mo, move bandwidth-heavy/static paths to Cloudflare ($0 egress) or self-host on Fly/Railway. **Egress is the silent killer.**
9. **Cost-per-request + cost-per-customer instrumented from launch for ANY AI/LLM feature:** log token-count + model + customer on every call, set a margin floor, add a per-customer token budget/kill-switch so one whale can't invert blended margin. **Flat-rate pricing on an LLM product is a margin time-bomb.**
10. **Pick ONE boring fused stack you already know and NEVER re-litigate it.** Framework wars are a token/time sink — Levels runs ~$250k/mo on vanilla PHP+jQuery+SQLite in one `index.php`. The only correct stack answer is "the one that lets you ship today."

---

## The default fused stack (boring-but-scalable)

**Recommended:** TypeScript + **Next.js 15 (App Router)** on Vercel (start) → Cloudflare/Fly (scale) · **Postgres via Neon or Supabase** · **Drizzle ORM** · **Clerk** auth (50k-MRU free) · **Stripe Billing+Tax** (or Lemon Squeezy/Paddle MoR if solo+international) · **Resend** email · **Cloudflare R2** storage ($0 egress) · **Upstash Redis + QStash** for cache/rate-limit/async.
**The universal spine:** single Postgres primary → PgBouncer/Supavisor (transaction mode) → read replicas → Redis cache → partition → **shard-LAST**.

**Why:** it dominates LLM training data, so AI codegen (and WALTEUR's own swarm) is **most reliable** on it — a decisive advantage for an AI-assisted builder — plus the largest hiring pool. The spine (Postgres + pooler + replicas) is the OpenAI/Basecamp/Go-monolith common denominator proven to hundreds of millions of users. Week-1 net-new code = only your one core loop (clone Makerkit/ShipFast for the rest).

**Alternatives (pick on team, not hype):**
- **Rails 8 + Hotwire + Postgres + Solid Queue/Cache** (DHH "No Build, No Redis") — focused product, sub-20-eng Ruby team, fewest moving parts, server-rendered (no separate frontend tier).
- **Go + Postgres single static binary + PgBouncer** — performance/infra-DNA team (Go-Fiber ~20× baseline vs Node ~4.7× vs Django ~1.9×). More CRUD boilerplate.
- **Django + HTMX + Postgres** — Python-native / AI-ML-adjacent team; batteries-included; lowest raw throughput (fine for typical web, not hot paths).
- **Astro** — ONLY for the marketing/content surface, paired with an app stack above.
- **Local-first sync engine** (ElectricSQL/Zero/Replicache/PowerSync; Y.js/Automerge CRDT) **on top of the monolith** — only if instant/offline UX is your wow-factor (Linear's moat was a client-side sync engine, NOT microservices). A monolith + great sync beats microservices + a slow round-trip.

---

## The phases (0 → 1M, each a `/goal` re-entry)

### Phase 0 — Foundation & Validation (pre-code) · 0–100 users · weeks 1–4 · ~$0–50/mo
**Goal:** prove demand and ship the ONE core loop. The bottleneck is **demand, not infra** — nothing technical breaks. The only failure mode is building machinery (auth+payments+AI+reports) instead of recruiting users.
**Build order:** Day 1 landing page + waitlist + Stripe payment link (not a repo) → Days 1–14 hand-recruit 10 users + interviews → Day 15+ clone a boilerplate (Makerkit/ShipFast) so net-new code = only the core loop. Plumbing order: landing → DB schema with `org_id` on every table → Clerk auth → **CORE LOOP** → billing → Resend → R2 → Upstash queue. Wire the **four day-one non-negotiables**. Run 30–50 manual onboardings by hand — that friction data IS your month-2 automation spec.
**Scaling moves:** none — resist all premature distribution. Ship `pg_stat_statements` + N+1 query-count assertions in tests *before* 10k. Index every FK manually (Postgres does not auto-index FKs).
**WALTEUR:** `/goal` → `estimate.json` → `/adhd` widens the core-loop/UX options → auto-debate resolves the Phase-0 forks (billing, auth) into ADRs → a **LIGHT swarm pass** (don't spin 25 agents for an MVP). Gates: Security floor, Data-Arch (tenant_id present), DevEx. QA corps: Unit/Integration + **Logic** on the core loop. Terminal Opus audit + ship-gate before the first real user.
**Exit:** ≥10 hand-recruited users on the core loop · first paying customer (or strong paid intent) · 30–50 onboardings logged · tenant_id + pooler + audit-log + CI-boundary-linter in place.

### Phase 1 — Product-Market Pull (the 2nd-engineer milestone) · ~1k–10k users · 1–3 months · ~$50–500/mo
**Goal:** turn the validated loop into a real product and survive the **second engineer**. At ~10k the thing that breaks is **process, not infra** — 2× t3.large + a load balancer serves 10k fine, but manual SSH `git pull` deploys collide the moment two engineers push.
**Build order:** automate ONLY the friction the manual onboardings revealed → `EXPLAIN ANALYZE` the hot queries (the right index turns 10s → 10ms); fix N+1 with eager loading → stand up CI/CD (GitHub Actions) + Secrets Manager + centralized logging + IaC (Terraform) → make sessions stateless (JWT) or Redis-backed; uploads → S3/R2 + CDN → adopt **feature flags** (decouple deploy from release — cheapest, biggest change-failure-rate reduction).
**Scaling moves:** stop hand-deploying (this milestone arrives by **headcount**, not QPS) · add the connection pooler if not already · cardinality budget at the OTel Collector from the start (never put `user_id`/`request_id` on metrics — 70–90% of the obs bill).
**WALTEUR:** full 7-phase lifecycle now (THINK→PLAN→BUILD→REVIEW→TEST→SHIP→REFLECT). Debate resolves CI/CD + flags + session forks into ADRs. Parallel swarm (Frontend + Backend + DB). QA corps: Unit/Integration + E2E + **Logic** + Security. Gates: DevEx (CI/CD), Infra (IaC), Security. 8-dim score must move every change. Opus audit per release; ship-gate 19/19.
**Exit:** CI/CD + IaC + Secrets live (no human SSHes to deploy) · feature flags · hot queries indexed (EXPLAIN-driven) · OTel Collector with cardinality limits + tail sampling.

### Phase 2 — Scale the Reads (cache-then-replica) · ~10k–100k users · 3–6 months · ~$500–3k/mo
**Goal:** the DB primary saturates — reads are 80–90% of queries, primary CPU > 70%, connections creep past ~200, API p95 drifts 100ms→300ms, sync work in the request path blows up p99.
**Build order:** **cache-aside on hot identical queries FIRST** (Redis/ElastiCache/Upstash — cuts read QPS 60–86%, ~55% cheaper than replicas; cache-lock/jitter for stampede) → **then** 2–5 read replicas routing cache-miss reads + reports off the primary → move ALL sync side-work (email, PDF, thumbnails, webhooks) to an idempotent **priority job queue** → move search off the primary (Postgres FTS/pg_trgm → Meilisearch <10M docs → ES/OpenSearch only for fuzzy ranking) → partition the biggest tables (pg_partman) at ~100M rows or 50GB.
**Scaling moves:** **sequence is law: CACHE before REPLICA** · wire alerts as triggers (conn > 200, replica CPU > 80%, cache-hit < 95%, dead-tuples > 5%/wk, p95 +20%/mo) · add APM (Datadog/Honeycomb/Grafana via OTel) + blue-green/rolling deploys.
**WALTEUR:** `/goal` per scaling epic → `estimate.json` → **`/grill-me-codex` hardens the cache-invalidation + idempotency plans** (data correctness is high-stakes). Debate resolves cache-vs-replica order, search engine, partition key into ADRs. Full swarm (Backend + DB + Performance-QA) in isolated worktrees. QA corps: **Performance** (load-test replica/cache) + **Logic** (idempotency/queue correctness) + Security + E2E. Gates enforce Performance + Data-Arch floors; Security non-negotiable. Opus audit; ship-gate 19/19.
**Exit:** cache-aside cutting read QPS ≥60% (cache-hit > 95%) · 2–5 replicas off the primary · all sync side-work on idempotent priority queues · biggest tables partitioned; search offloaded; rate-limiting in place.

### Phase 3 — Enterprise-Ready & Write-Pressure (the revenue-gate tier) · ~100k–1M users · 6–18 months · ~$3k–30k+/mo + ~$30–50k SOC2 yr1
**Goal:** two pressures hit together. **Commercially:** the first enterprise prospect sends a security questionnaire (SSO+SOC2+audit-logs+RBAC) — auth/compliance gaps block **75–80% of the enterprise pipeline**. **Technically:** write throughput pressures the single primary; analytics queries spike OLTP p95; table bloat/VACUUM rises.
**Build order:** **start SOC2 Type II NOW** (3–4mo observation window → start 4–6 months before the deal; ~$30–50k yr1 via Vanta/Drata/Secureframe + auditor + mandatory pentest; closes enterprise ~35% faster) → build enterprise-readiness in the **correct order: RBAC → audit logs → SSO → SCIM** (skipping audit logs FAILS SOC2; the audit log was already in the schema from Phase 0) → buy SSO/SCIM via **WorkOS/Auth0/Ory** (never hand-roll SAML per-IdP) → offload write-heavy NEW tables to a separate store (OpenAI→CosmosDB pattern) → move analytics to **columnar OLAP (ClickHouse, or Doris for real-time UPDATE/DELETE) via CDC (Debezium)** only once analytical tables > 1TB or dashboards > 5s; fan replicas out (~50 like OpenAI) → mature CI/CD to **canary + auto-rollback** + SLO burn-rate alerting.
**Scaling moves:** carve out ONLY a genuinely independent, differently-scaling concern (search→OpenSearch, one CPU-bound pipeline) — never by default (Prime Video cut cost 90% by NOT splitting steps that always run together) · vertical-scale the primary first (handles most < 500GB/< 200 conns) · error-budget-driven alerting; consider self-hosted Grafana/Tempo/Loki/Mimir to escape per-GB pricing · FinOps cost-per-customer as a standing ritual.
**WALTEUR:** **`/grill-with-docs-codex` hardens the RBAC/audit/SSO plan against the domain model** (auth + compliance = highest stakes). Debate resolves extract-a-service-or-not, OLAP engine, MoR-vs-Stripe-at-scale into ADRs. Full swarm across all tiers in worktrees. QA corps at full strength: **Security** (SOC2 controls + pentest scoping) + **Logic** (RBAC correctness, audit-log completeness, idempotency) + Performance (write + OLAP load) + E2E + Accessibility. The **31-gate dispatch** enforces every floor; **Security < floor → CRISIS MODE** (halt non-security work, full audit, resume only on all-clear). Opus audit; ship-gate 19/19 before enterprise GA.
**Exit:** SOC2 Type II in hand; SSO+SCIM+RBAC+audit-log shipped (correct order) · write-heavy tables offloaded; OLTP primary back under headroom · analytics on columnar OLAP via CDC; replicas fanned out · canary deploys + SLO burn-rate alerting; AI margin floor enforced with per-customer token budgets.

### Phase 4 — Shard-Last (only if the write ceiling is genuinely hit) · ~1M+ users · weeks–months of DB work · highest-risk migration
**Goal:** the single primary can no longer absorb **write** throughput, OR VACUUM consistently stalls toward TXID-wraparound (Notion's actual trigger — NOT user count). This is the ONLY thing that genuinely forces sharding. **Most teams never reach this line.**
**Build order:** re-confirm the trigger is real (writes/VACUUM — if it's reads/analytics, DO NOT shard; go back to replicas/cache/OLAP) → shard by a **tenant-aligned key** (`workspace_id`/`org_id`) so ~99% of queries stay single-shard (the Phase-0 tenant_id makes this possible) → choose a logical-shard count with **many divisors** (Notion: 480) **decoupled from physical host count** → migrate via **double-write + audit-log backfill, then cut over reads** (never a flag-day; Notion did this zero-downtime, 3-day backfill on a 96-CPU box) → **or BUY it** (Citus/PgDog/Vitess/PlanetScale) so you don't rewrite the app. Accept the permanent cost: loss of cross-shard joins + global analytics → those live in OLAP.
**Scaling moves:** keep the app a **monolith** (Shopify "pods" — isolation lives in the data tier) · monitor dead-tuple ratio + txid age as first-class alerts · split out a few genuinely-independent services (media, notifications, payments) onto ECS/EKS only on **measured** boundaries.
**WALTEUR:** `/goal` scopes the shard migration as its own high-stakes epic → `estimate.json` sizes double-write + backfill + cutover (multi-week) → **`/grill-me-codex` MANDATORY** (highest-stakes migration there is). Debate resolves shard-key, logical-shard-count, build-vs-buy into ADRs. Full swarm with DB/Data as lead tier in an isolated worktree; WIP-commits every ~8 min. QA corps: **Logic** (shard-routing correctness, zero data loss on double-write) + Performance + Security + E2E with shard-aware fixtures. **Confusion Protocol on any ambiguity (no guessing on a shard migration).** Opus audit signs the migration; ship-gate 19/19 + verified zero-downtime cutover before flipping reads.
**Exit:** write-throughput trigger confirmed real · tenant-keyed logical shards (many-divisor count) decoupled from physical hosts · zero-downtime double-write + backfill + verified cutover; no data loss · cross-shard analytics on OLAP; app remains a single deployable.

---

## The data-layer ladder (climb in order, on evidence)

0. **Day-one:** single managed Postgres (Neon scale-to-zero / Supabase) + PgBouncer/Supavisor **transaction mode** from line 1 + `org_id`/`tenant_id` on every table + index every FK + `pg_stat_statements` + N+1 assertions in tests.
1. **Indexes + query tuning** — `EXPLAIN ANALYZE` the hot paths; the right index turns 10s → 10ms; fix N+1. (Breaks first at ~1k users / 250k rows: 20ms→400ms.)
2. **Connection pooling** — PgBouncer (monoliths) / Supavisor or PgDog (serverless). Compresses 500 app conns → ~20 real PG conns; OpenAI saw 50ms→5ms connect. Disable prepared statements in transaction mode (Prisma: `?pgbouncer=true`).
3. **Cache-aside** (Redis/ElastiCache/Upstash) on hot identical queries — **before replicas**. Cuts read QPS 60–86%, ~55% cheaper. Cache-lock/jitter for stampede. Hot-key + sessions + rate-limit + idempotency, NOT "everything."
4. **Read replicas** (2–5, scale to ~50 like OpenAI) — route cache-miss reads + reports off the primary. Linear for reads, nothing for writes. (Mandatory ~20k–50k users.)
5. **Async job queue** (Sidekiq/Celery/BullMQ/pg-boss/River/SQS+workers) — email/PDF/image/webhooks off the request path. Every job idempotent; priority queues. (Mandatory ~50k–100k.)
6. **Search offload** — Postgres FTS/pg_trgm first (free) → Meilisearch (<10M docs) → ES/OpenSearch only for fuzzy ranking/faceting at scale.
7. **Table partitioning** (pg_partman, range/time) — partition the biggest tables at ~100M rows or 50GB; keeps VACUUM tractable, drops cold partitions instantly.
8. **Write-offload** — move write-heavy NEW feature tables to a separate store (OpenAI→CosmosDB pattern; KV/queue) to keep the OLTP primary headroom.
9. **Columnar OLAP offload** (ClickHouse, or Doris for real-time UPDATE/DELETE) via logical replication/CDC (Debezium) — ONLY when analytical tables > 1TB or dashboards > 5s. Keep OFF the OLTP primary.
10. **Shard LAST** — tenant-keyed (`workspace_id`), logical-shard count with many divisors (480) decoupled from physical hosts, double-write + audit-log backfill, zero-downtime cutover. Or buy: Citus/PgDog/Vitess. Trigger is write-ceiling or VACUUM/TXID-wraparound, NOT user count. Cross-shard joins → OLAP.

---

## Anti-patterns — REFUSE these (the token/effort/money wasters)

- **Microservices / K8s / service mesh / Kafka on day one "to be scalable"** — the #1 startup-killer. Segment, Prime Video, AND InVision all reversed it. You EARN microservices at a measured bottleneck.
- **Building the full SaaS before ONE paying customer** — 92% of micro-SaaS die in 18 months, dominant cause. Week 1 is a landing page.
- **One service per integration/connector/tenant-type** — Segment's exact mistake; a shared-lib change took ~1 week each. Keep them as **modules** in one deployable.
- **A network hop + object storage between two steps that ALWAYS run together** — Prime Video's Step-Functions+S3-between-stages cost ~10×; in-process cut it 90%.
- **Sharding the write primary early "to be safe"** — splits app logic, forces distributed transactions, kills joins/global analytics. OpenAI: 800M users, one primary. PgBouncer + replicas + cache FIRST.
- **Reaching for K8s/service mesh to get "modularity"** — modularity is a CI-linter boundary, not a network boundary.
- **Serverless + Postgres WITHOUT a transaction-mode pooler** — guarantees a "too many connections" outage on the first spike. Wire Supavisor/PgDog/Neon-driver from commit one.
- **Read replicas WITHOUT a cache first** — paying $1740/mo for 4 replicas to get throughput one cache node + replica delivers for $780/mo.
- **`user_id`/`request_id`/full-URL as METRIC labels** — cardinality explosion eats 70–90% of the obs bill. Put them on traces/exemplars. Export via the OTel Collector, never SDK→vendor direct.
- **SSO before RBAC + audit logs** — skipping audit logs FAILS SOC2. Correct order: RBAC → audit logs → SSO → SCIM. Bake the audit log in day one.
- **Hand-rolling auth or SAML/SCIM per-IdP** — a bottomless edge-case sink and a security risk. Never roll your own auth.
- **Flat-rate pricing on an LLM product with no per-customer token budget** — one whale inverts blended margin. Instrument cost-per-request from launch + a kill-switch on the fat tail.
- **Re-litigating the stack / chasing satisfaction-hype** (e.g. a beta framework for a 1M-user bet) — pure waste. Levels runs $250k/mo on PHP+jQuery+SQLite.
- **Premature Redis / a dedicated vector DB (Pinecone) / "exabyte-scale" DB / polyglot persistence / a Kafka backbone for a CRUD app** — Postgres alone (JSONB+FTS+queue+pgvector) covers 0→1M; add each only when a metric forces it.
- **Staying on Vercel Pro through the $100–500 band with no spend alerts/exit plan** — surprise $700 bills. Cloudflare's $0 egress is the structural fix.
- **Bare `ALTER TABLE` / non-concurrent `CREATE INDEX` / validated-FK-add on a hot table in business hours** — ACCESS EXCLUSIVE behind one long query queues ALL traffic (self-inflicted outage). Use `lock_timeout` + `CREATE INDEX CONCURRENTLY` + `NOT VALID`/`VALIDATE`.
- **Alerting on every cause instead of SLO burn-rate** — the noise that caused 44% of orgs to have outages from IGNORED alerts. Fewer, symptom-based alerts.

---

## How WALTEUR RUNS this plan (one continuous `/goal`-driven lifecycle, re-entered per tier)

1. **`/goal <product or scaling epic>`** — sets the objective; instantiates `.swarm_state/` (the live **8-dimension score** — Design · Infra · Security · UX/UI · Performance · Features · Data-Arch · DevEx — is the truth; every change must move the composite or it's waste; the builder cannot score its own work).
2. **`estimate.json`** — sizes the increment (time/tokens/cost) so the swarm scales agent count to the job. Phase 0 = LIGHT pass (don't spin 25 agents for an MVP); Phases 2–4 = FULL swarm across tiers in isolated git worktrees, WIP-commit every ~8 min.
3. **`/adhd`** widens the option space before locking a plan (core-loop/UX, shard-key, OLAP engine). The **Socratic auto-debate** resolves each genuine fork into an immutable numbered **ADR**. High-stakes forks (auth, schema, concurrency, migrations, payments, sharding) escalate to **`/grill-me-codex` / `/grill-with-docs-codex`** — a second model (Codex, read-only) stress-tests the plan until APPROVED.
4. **Parallel build** in the loop: ACT→TEST→ANALYZE→REFINE→RETEST→COMMIT, max 5 iters/change, never commit broken code. **Confusion Protocol = no guessing** (mandatory on a shard migration). Each issue → `_relay/ISSUES.md`; each fix → graduates to `Preferences/Lessons.md`.
5. **Multi-agent QA corps** certifies every tier — Gatekeeper + E2E + Unit/Integration + Performance + Accessibility + Security + a **Logic agent** (idempotency, RBAC, audit-log completeness, shard-routing, zero data loss). The builder never scores its own work.
6. **The 31-gate dispatch** enforces the per-tier floors (Data-Arch: tenant_id; DevEx: CI/CD; Performance: load-tested; **Security: NON-NEGOTIABLE floor → CRISIS MODE if breached**).
7. **Terminal Opus audit** signs each tier, then the **ship-gate (selftest 19/19)** must pass before that tier goes live — first user (P0), each release (P1–2), enterprise GA (P3, SOC2-gated), the verified zero-downtime cutover (P4). REFLECT appends the tier's learnings; the baton (`_relay/BATON.md`) hands the thread to the next shift/model.

**Model routing throughout:** Opus PLANS, Sonnet EXECUTES (Rule 0). The **exit_criteria of each phase ARE the gate conditions that unlock the next `/goal` entry.**

---

## The genuine decision forks (WALTEUR's auto-debate resolves these per project; defaults given)

- **Billing:** Stripe Billing+Tax (own tax, lower fees) vs Merchant-of-Record (Lemon Squeezy/Paddle handle global VAT). **Default:** solo + international + no finance ops → MoR; US-centric or has finance → Stripe. Decide in **week 1**.
- **Auth:** Clerk (50k-MRU free, 30-min integration) vs Supabase Auth (only if already on Supabase, for RLS) vs WorkOS/Auth0 (when enterprise SSO is a literal sales blocker). **Default:** Clerk for greenfield. Never NextAuth-by-default in 2026; never hand-roll.
- **Cache vs replica order:** **Default cache-aside FIRST** (60–86% read-QPS cut, ~55% cheaper), replicas second. Invert only if freshness must be < 5s with millions of unique filter combos.
- **Hosting at the cost cliff:** Vercel vs Cloudflare ($0 egress) vs self-host Fly/Railway. **Default:** Vercel free→MVP; at ~$100–200/mo, move egress-heavy paths to Cloudflare or self-host. Spend alerts day one regardless.
- **Search engine:** Postgres FTS/pg_trgm → Meilisearch (<10M docs) → ES/OpenSearch (fuzzy ranking/faceting at scale). **Default:** Postgres FTS first.
- **Extract-a-service-or-not (100k–1M):** **Default keep the monolith;** carve out only a genuinely independent, differently-scaling concern. Prime Video cut cost 90% by NOT splitting steps that always run together.
- **OLAP engine:** ClickHouse (fastest single-table scans) vs Doris (real-time UPDATE/DELETE). **Default:** ClickHouse; Doris if mutable real-time rows. Feed via CDC; keep off the primary.
- **Shard build-vs-buy (Phase 4 only):** **Default BUY** (Citus/Vitess) so you don't rewrite the app; hand-roll only with deep DB-ops DNA. Shard key = tenant; logical count = many divisors.
- **Local-first sync yes/no:** **Default no** — add ElectricSQL/Zero/Replicache/PowerSync on top of the monolith ONLY if instant/offline UX is your wow-factor (Linear's moat).

---

*This plan is the strategic spine WALTEUR applies to every build. Tiers are evidence-triggered, not calendar-driven: build for the tier you're at, pre-wire only what's brutal to retrofit, and let the named alerts — not folklore — trigger each climb up the ladder. Sources: OpenAI/Shopify/Basecamp/Segment/Notion/Prime Video/Vercel engineering accounts, AWS scaling benchmarks, State-of-JS/DB surveys, r/SaaS · r/webdev · r/devops, and YC/indie-hacker post-mortems (2024–2026).*
