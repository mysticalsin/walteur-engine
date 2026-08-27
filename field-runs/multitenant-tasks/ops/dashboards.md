# Operations Dashboards — multitenant-tasks

Operator-facing dashboard catalogue for the multi-tenant task service. Every panel below maps to a
declared SLI in `ops/slo.json` (mirrored into `walteur-kit/slo.json`, the artifact the
`slo-error-budget-gate` validates). Dashboards visualise the same signals the alerts fire on, so the
on-call view at 3am and the alert condition agree by construction.

Provider-neutral PromQL/LogQL expressions are given so this doc is portable across Grafana / managed
Prometheus / Loki backends. No secret values appear here; data-source URLs and tokens are env-injected at
the dashboard provider, never committed.

---

## Dashboard: Service Overview (`ops/dashboards/overview.json`)

The single pane on-call opens first. Top row is the SLO health line; lower rows are the contributing
signals.

| Panel | SLI | Bound SLO | Query (Prometheus) | Healthy when |
|-------|-----|-----------|--------------------|--------------|
| Request error rate | errors | `api-availability` | `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))` | < 0.1% (30d budget 0.1%) |
| Request latency p99 | latency | `api-latency-p99` | `histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` | p99 < 300ms |
| Tenant authz denials | errors | `api-availability` | `sum(rate(http_requests_total{status=~"40[13]"}[5m]))` | deny-by-default baseline; spikes = probing |
| Ingest queue saturation | saturation | `ingest-saturation` | `max(task_ingest_queue_depth) / max(task_ingest_queue_capacity)` | < 80% |

### How to read it

- **Error rate** is the primary availability SLI. A sustained breach burns the `api-availability`
  error budget (0.1% over 30d ≈ 43m/month). The `error_rate > 0.1% for 5m` alert fires before the
  budget is meaningfully spent.
- **Latency p99** is the user-perceived-speed SLI. The p99 line crossing 300ms for 10m fires
  `api-latency-p99`. Watch alongside error rate — a latency cliff often precedes 5xx as timeouts trip.
- **Tenant authz denials** is an isolation signal, not just an error signal. The store is
  deny-by-default (`owned()` chokepoint in `core.mjs`); a normal baseline of 401/403 is expected.
  A *step change* means either a deploy broke a tenant token or someone is enumerating across tenants —
  correlate with the audit log (`ops/seed-audit.mjs` output) before paging security.
- **Ingest saturation** is the leading indicator. Queue depth climbing toward capacity predicts a
  latency-then-errors cascade; the `queue_depth > 80% for 15m` alert gives lead time to scale or shed.

---

## Logging panel (structured)

All application logs are structured JSON (`logging.structured: true` in the SLO contract). The dashboard
embeds a Loki/LogQL table so an SLI breach can be pivoted straight to the offending requests:

```
{app="multitenant-tasks"} | json | status >= 500 | line_format "{{.ts}} tenant={{.tenant_id}} route={{.route}} status={{.status}} latency_ms={{.latency_ms}}"
```

Because logs are structured, every panel above can be re-derived from logs when the metrics pipeline is
itself degraded — the failure mode where unstructured logs leave you blind at 3am is designed out.

## Tracing

Distributed tracing is enabled (`tracing.enabled: true`). Each latency-breach data point links to its
exemplar trace via the `trace_id` recorded on the structured log line, so a slow p99 sample is one click
from the span that caused it.

---

## On-call runbook (per alert)

- **`api-availability` fires** → open Service Overview, confirm error-rate panel, check the structured
  log table for the dominant `status`/`route`. If a single tenant dominates, suspect a bad tenant token
  (see audit log) before declaring a global incident.
- **`api-latency-p99` fires** → check ingest-saturation panel first (saturation usually leads latency).
  If queue is healthy, suspect a downstream dependency; pull the exemplar trace.
- **`ingest-saturation` fires** → scale ingest workers or enable shed-load; this is the early-warning
  alert and should be actioned before the other two fire.

Budget policy: when an SLO's 30-day error budget is exhausted, feature rollouts for that surface freeze
until the budget recovers (error-budget policy, enforced by release review, not by this gate).
