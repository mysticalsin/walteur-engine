# feature-flags-api — operations dashboards & runbooks

Observability spine for the deny-by-default multi-tenant feature-flags service. All request logs are
structured JSON to stdout (`server.mjs` `logLine`), with the `Authorization` header and any token field
**redacted to `***`** — a credential can never reach a log sink.

## Dashboards

### Overview (`ops/dashboards/overview.json`)
- **Request rate** by `path` and `status` (info / warn / error tiers).
- **Deny rate**: count of `401` (unauthenticated) and `403` (cross-tenant) — these are *correct* behavior,
  tracked separately from `5xx` so a healthy deny spike never burns the availability error budget.
- **Latency** `ms` field, p50 / p99 split by `GET /flags` (read hot path) vs `POST /flags` (write+persist).
- **Per-tenant activity**: mutations (`set` / `delete`) from the audit trail, scoped per `tenant`.

## SLOs (see `ops/slo.json`)
| SLO | SLI | Objective | Budget |
|-----|-----|-----------|--------|
| api-availability | errors (non-5xx) | 99.9% / 30d | 0.1% |
| flag-read-latency-p99 | latency < 150ms | 99.0% / 30d | 1.0% |
| flag-write-latency-p99 | latency < 300ms | 99.0% / 30d | 1.0% |

## On-call runbook (per alert)

### `api-availability` — error_rate > 0.1% for 5m (PAGE)
1. Check the overview dashboard: is the spike `5xx` (real) or `401/403` (deny — not an outage)?
2. If `5xx`: tail structured logs for `level:"error"` + `event` (e.g. `persist_failed`). A persistence
   failure does **not** fail the request (in-memory store answered) but signals disk trouble.
3. If sustained, execute the blue-green rollback: `ROLLBACK_CONFIRM=1 bash ops/rollback.sh --execute`.

### `flag-read-latency-p99` / `flag-write-latency-p99` — p99 over target (PAGE / WARN)
1. Inspect the latency panel; correlate with request rate (load) and `persist_failed` events (write path).
2. Reads are in-memory and should stay sub-ms; sustained read-latency points at the host/runtime, not the
   store — check CPU saturation and GC.

### Recovery drill
- `bash ops/chaos.sh` injects a real process-kill fault and measures observed recovery seconds, writing
  `ops/chaos-report.json`. Run it as a periodic game-day to keep the recovery number honest.

## Liveness
- `GET /health` (and alias `GET /healthz`) → `200 {"status":"ok"}`, no auth, leaks no tenant data. This is
  the cutover plan's `health_check` target and the chaos drill's probe.
