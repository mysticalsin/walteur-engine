# Plan — Tenant-Scoped API Rate Limiter

## Tasks
- T1 implements FR-101 — reject over-quota requests with HTTP 429
- T2 implements FR-102 — per-tenant usage counter, row-level scoped
- T3 implements FR-103 — reset counter on window rollover

## Notes
Burst-handling behavior will ship in a follow-up milestone once analytics confirms a short
grace window doesn't mask real abuse; tracked separately in the backlog for now.
