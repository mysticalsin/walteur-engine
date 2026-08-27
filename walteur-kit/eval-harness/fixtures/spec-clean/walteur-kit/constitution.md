# Constitution — Tenant-Scoped API Rate Limiter

## Security & Isolation
- Every quota counter is keyed by tenant id at the row level; tenants SHALL never read or
  increment another tenant's usage counter. Row-level security is enforced in the datastore,
  not only in application logic.
- Rate-limit configuration changes require an authz check; least-privilege applies to every
  admin endpoint that can raise or lower a tenant's quota.
