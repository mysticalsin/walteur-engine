# Spec — Tenant-Scoped API Rate Limiter

Multi-tenant SaaS API gateway needs per-tenant request throttling so one noisy tenant cannot
starve shared capacity from the others. This spec covers the throttling service only; billing
for overage is out of scope.

## FR-101 Enforce per-tenant request quota
Each tenant is assigned a configurable requests-per-minute quota. The gateway must reject
requests once a tenant's quota is exhausted for the current window.
Acceptance: WHEN a tenant's request rate exceeds its configured quota THEN the system SHALL reject the request with HTTP 429.

## FR-102 Track quota usage per tenant
Usage counters are scoped per tenant so tenants can never observe or influence another
tenant's counter, in line with the standing isolation principle in constitution.md.
Acceptance: WHILE a tenant session is active THEN the system SHALL increment only that tenant's usage counter.

## FR-103 Reset counters on window rollover
Counters reset at the start of each rate-limit window so quota is a rolling allowance, not a
lifetime cap.
Acceptance: WHEN a rate-limit window elapses THEN the system SHALL reset the tenant's counter to zero.

## FR-104 Handle burst traffic above quota
Real client traffic is bursty; a hard cutoff at exactly 100% of quota causes visible errors for
legitimate short bursts. Product decided on a bounded grace window rather than an immediate cutoff.
Acceptance: WHEN a tenant briefly exceeds its quota by a small margin THEN the system SHALL allow a single 5-second grace-burst window before rejecting the request with HTTP 429.
