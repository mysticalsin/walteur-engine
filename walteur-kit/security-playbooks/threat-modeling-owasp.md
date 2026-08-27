# Threat Modeling with OWASP Threat Dragon (STRIDE)

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `performing-threat-modeling-with-owasp-threat-dragon`
**NIST CSF:** ID.RA-01, ID.AM-03 | **Framework:** OWASP, STRIDE

## Purpose

Create Data Flow Diagrams (DFDs), apply STRIDE threat enumeration, and produce a prioritized threat list with mitigations. Use at architecture/design phase — before code is written. Complements ATT&CK-based threat modeling (which is retrospective) by catching design flaws early.

## STRIDE Threat Categories

| Letter | Threat | Violates | Example |
|--------|--------|----------|---------|
| S | Spoofing | Authentication | JWT forged, session hijacked |
| T | Tampering | Integrity | HTTP body modified in transit |
| R | Repudiation | Non-repudiation | Log deleted, action denied |
| I | Information Disclosure | Confidentiality | Secrets in env vars, verbose errors |
| D | Denial of Service | Availability | Rate-limitless endpoint flooded |
| E | Elevation of Privilege | Authorization | IDOR, RBAC bypass |

## Workflow (4 steps)

### 1. Draw the DFD (Level 0 → Level 1)
Define system boundaries using these elements:
- **Process** (circle): code that transforms data (API handler, auth service)
- **Data Store** (parallel lines): DB, S3 bucket, cache
- **External Entity** (rectangle): browser, mobile client, third-party API
- **Data Flow** (arrow): every arrow crossing a trust boundary is a threat candidate
- **Trust Boundary** (dashed line): network perimeter, auth checkpoint, privilege level change

Every arrow crossing a trust boundary gets STRIDE applied.

### 2. Apply STRIDE per element

For each DFD element, enumerate relevant STRIDE threats:

```
Process (Auth Service):
- S: Can another process impersonate this service? → mutual TLS / service identity
- T: Can inputs be tampered before reaching the process? → signed JWTs, HMAC
- I: Does error output leak internal state? → sanitize error messages
- E: Can a low-privilege user call admin endpoints? → RBAC enforcement
```

### 3. Score and prioritize threats (DREAD or CVSS-lite)

For each threat, score:
- **Damage** (1-3): data loss, service outage, credential exposure
- **Reproducibility** (1-3): always/sometimes/rarely
- **Exploitability** (1-3): unauthenticated/authenticated/insider
- **Affected users** (1-3): all/some/one
- **Discoverability** (1-3): public/need account/insider

Total 5-15. Priority: 12+ = Critical, 9-11 = High, 6-8 = Medium.

### 4. Define mitigations per threat

Map each threat to a concrete mitigation and track status (Open/In Progress/Mitigated):

| Threat | Component | STRIDE | Score | Mitigation | Status |
|--------|-----------|--------|-------|------------|--------|
| JWT forged | Auth Service | S | 13 | RS256 signed JWT + JWKS endpoint | Open |
| IDOR on /api/orders | Order API | E | 11 | Ownership check `order.userId === req.user.id` | Open |
| Secrets in logs | Logger | I | 10 | Redact PII/secrets in log serializer | Done |

## WALTEUR Integration

Before opening a new project scaffold:
1. Draw a 5-minute Level-0 DFD (components + trust boundaries)
2. Run STRIDE on each trust boundary crossing
3. P1 threats (score ≥12) become **launch-blocking security findings** in the WALTEUR audit

## Tools

- OWASP Threat Dragon (free, open-source): https://www.threatdragon.com/
- OWASP Threat Dragon GitHub: https://github.com/OWASP/threat-dragon
- Microsoft Threat Modeling Tool (alternative): https://learn.microsoft.com/en-us/azure/security/develop/threat-modeling-tool
