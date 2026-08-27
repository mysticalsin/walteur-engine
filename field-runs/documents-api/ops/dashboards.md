# documents-api — operability dashboards & runbook

Operability surface for the deny-by-default multi-tenant documents service. The dashboards read the
structured JSON logs emitted by `server.mjs` (one line per request; the `Authorization` header and any
token are redacted to `***`). No secret values appear here or in any log line.

## Panels (overview.json)

- **Request rate / status mix** — count by `status`. A healthy 401/403 rate is EXPECTED (deny-by-default);
  only a rising **5xx** rate burns the availability error budget.
- **Latency p50/p99** — from the per-request `ms` field, split by `path` (`/docs`, `/docs/:id`,
  `/audit`, `/admin/erase`).
- **Tenant activity** — mutations per `tenant` (derived from `POST/PUT/DELETE` log lines). Useful for spotting
  a noisy tenant; never exposes another tenant's document contents.
- **Erase events** — count of `POST /admin/erase` 200s (DSAR right-to-erasure executions).

## On-call runbook (per alert)

### `api-availability` (page) — 5xx error rate > 0.1% for 5m
1. Check the latest `level:"error"` log lines for `event:"persist_failed"` or stack-trace context.
2. If persistence is failing, the in-memory store is still authoritative for live responses — disk is
   best-effort. Free disk / fix the volume; data.json rewrites on the next successful mutation.
3. If 5xx is broad, roll back: `bash ops/rollback.sh --check` then `ROLLBACK_CONFIRM=1 bash ops/rollback.sh --execute`.

### `doc-read-latency-p99` (page) — p99 > 150ms for 10m
1. Confirm the host is not CPU-saturated; the store is in-memory so reads should be sub-ms.
2. Check for an oversized tenant bucket; if a tenant is abusively large, coordinate retention with the owner.

### `doc-write-latency-p99` (warn) — p99 > 300ms for 10m
1. Writes include the atomic `data.json` tmp+rename. Slow disk I/O is the usual cause — check volume latency.

## Chaos / game-day

`bash ops/chaos.sh` injects a real process-kill, confirms steady state on `GET /health`, hard-kills the
listener, restarts a fresh instance, and re-probes health. It writes the OBSERVED `recovery_seconds` to
`ops/chaos-report.json` (mirrored into `walteur-kit/`). Recovery is measured, not asserted.
