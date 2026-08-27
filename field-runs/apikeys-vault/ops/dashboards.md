# apikeys-vault — operability dashboards & runbook

Operability surface for the deny-by-default multi-tenant API-key vault. The dashboards read the structured
JSON logs emitted by `server.mjs` (one line per request; the `Authorization` header, any token, and any raw
`key` field are redacted to `***`). No secret values appear here or in any log line.

## Panels (overview.json)

- **Request rate / status mix** — count by `status`. A healthy 401/403/404/409 rate is EXPECTED
  (deny-by-default); only a rising **5xx** rate burns the availability error budget.
- **Latency p50/p99** — from the per-request `ms` field, split by `path` (`/keys`, `/keys/:id`,
  `/keys/:id/rotate`, `/audit`, `/admin/erase`).
- **Key lifecycle events** — issue / rotate / revoke counts per `tenant` (derived from `POST/DELETE` log
  lines). Useful for spotting a noisy tenant; never exposes raw key material.
- **Rotation cadence** — `POST /keys/:id/rotate` 200s over time, tracked against the 90-day
  `issued_key_rotation_policy` in `ops/secrets-policy.json`.
- **Erase events** — count of `POST /admin/erase` 200s (DSAR right-to-erasure executions).

## On-call runbook (per alert)

### `api-availability` (page) — 5xx error rate > 0.1% for 5m
1. Check the latest `level:"error"` log lines for `event:"persist_failed"` or stack-trace context.
2. If persistence is failing, the in-memory store is still authoritative for live responses — disk is
   best-effort. Free disk / fix the volume; data.json rewrites on the next successful mutation. Note: the
   on-disk snapshot is hashes only, so a corrupt data.json never exposes key material.
3. If 5xx is broad, roll back: `bash ops/rollback.sh --check` then `ROLLBACK_CONFIRM=1 bash ops/rollback.sh --execute`.

### `key-verify-latency-p99` (page) — p99 > 150ms for 10m
1. Confirm the host is not CPU-saturated; the store is in-memory so metadata reads should be sub-ms.
2. Check for an oversized tenant bucket; if a tenant exceeds `max_active_keys_per_tenant`, coordinate
   revocation with the owner.

### `key-issue-latency-p99` (warn) — p99 > 300ms for 10m
1. Issue/rotate include a `crypto.randomBytes(32)` mint + sha256 + the atomic `data.json` tmp+rename. Slow
   disk I/O is the usual cause — check volume latency.

## Key-rotation operations

- **Rotate** a tenant key: `POST /keys/:id/rotate` mints fresh material, replaces the stored sha256 hash
  (invalidating the prior credential), and writes a `rotate` audit row. Proven by `test/rotation.test.mjs`.
- **Revoke** a tenant key: `DELETE /keys/:id` flips status to `revoked`; the credential is permanently dead
  and cannot be rotated back to life (returns 409).
- The raw key is shown exactly once (issue/rotate response) and is never re-fetchable or logged.

## Chaos / game-day

`bash ops/chaos.sh` injects a real process-kill, confirms steady state on `GET /health`, hard-kills the
listener, restarts a fresh instance, and re-probes health. It writes the OBSERVED `recovery_seconds` to
`ops/chaos-report.json` (mirrored into `walteur-kit/`). Recovery is measured, not asserted.
