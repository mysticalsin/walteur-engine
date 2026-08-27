# OWASP API Security Top 10

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `testing-api-security-with-owasp-top-10`
**NIST CSF:** DE.CM-04, ID.RA-01 | **MITRE ATT&CK:** T1190, T1078, T1530

## Purpose

Citable OWASP API Top-10 attack paths for WALTEUR's re-prosecutor. For each category: the attack pattern, the HTTP exploit, and the absent mitigation that confirms the finding.

## OWASP API Security Top 10 (2023)

### API1:2023 — Broken Object Level Authorization (BOLA / IDOR)

**Attack path:** Authenticated user changes resource ID in request URL/body to access another user's data.

```http
# Attacker: authenticated as user 42, accesses user 43's orders
GET /api/v1/users/43/orders HTTP/1.1
Authorization: Bearer <user-42-token>
# VULNERABLE if server returns user 43's data
```

**Absent mitigation:** No ownership check: `if (order.userId !== req.user.id) return 403`
**ATT&CK:** T1078 (Valid Accounts)

---

### API2:2023 — Broken Authentication

**Attack path:** Weak JWT, no rate limiting on `/login`, token not invalidated on logout.

```bash
# JWT with weak secret brute-forced offline
# or: no rate limiting on login endpoint
for i in $(seq 1 1000); do
  curl -X POST /api/auth/login -d '{"user":"admin","pass":"'$i'"}'
done
```

**Absent mitigation:** No account lockout, no rate limiting, JWT signed with `HS256 + weak secret`
**ATT&CK:** T1110 (Brute Force)

---

### API3:2023 — Broken Object Property Level Authorization (BOPLA)

**Attack path:** `PUT /api/users/42` with extra properties like `{"role":"admin","isAdmin":true}` — server updates all properties including privileged ones.

**Absent mitigation:** No allowlist of writable properties (mass assignment protection)
**ATT&CK:** T1548 (Abuse Elevation Control Mechanism)

---

### API4:2023 — Unrestricted Resource Consumption

**Attack path:** No rate limiting → attacker floods endpoint → DoS or compute cost explosion.

```http
# Batch endpoint with no limit
POST /api/search
{"query": "a", "limit": 1000000}
```

**Absent mitigation:** No rate limiting (`express-rate-limit`), no pagination cap, no timeout
**ATT&CK:** T1499 (Endpoint Denial of Service)

---

### API5:2023 — Broken Function Level Authorization (BFLA)

**Attack path:** Low-privilege user calls admin-only endpoint by guessing URL.

```http
# Regular user calls admin endpoint
DELETE /api/admin/users/99 HTTP/1.1
Authorization: Bearer <regular-user-token>
# VULNERABLE if 200 OK
```

**Absent mitigation:** No role check middleware on admin routes
**ATT&CK:** T1078, T1548

---

### API6:2023 — Unrestricted Access to Sensitive Business Flows

**Attack path:** No bot protection on high-value flows (checkout, password reset, OTP verification).

**Absent mitigation:** No CAPTCHA, no device fingerprinting, no anomaly detection on business flows

---

### API7:2023 — Server Side Request Forgery (SSRF)

**Attack path:** User-supplied URL in `webhookUrl` parameter → server fetches attacker-controlled URL → reads AWS metadata service.

```http
POST /api/webhooks
{"url": "http://169.254.169.254/latest/meta-data/iam/security-credentials/"}
```

**Absent mitigation:** No URL allowlist, no SSRF filter, no block of RFC 1918 / metadata IP ranges
**ATT&CK:** T1552.005 (Cloud Instance Metadata API)

---

### API8:2023 — Security Misconfiguration

**Patterns:** CORS `*`, verbose error stack traces, default credentials, open admin UI, unnecessary HTTP methods enabled.

```bash
# Check CORS
curl -H "Origin: https://evil.com" -I /api/data
# VULNERABLE if: Access-Control-Allow-Origin: https://evil.com (reflected)

# Check verbose errors
GET /api/nonexistent → stack trace with file paths, DB connection string
```

---

### API9:2023 — Improper Inventory Management

**Attack path:** Old API version (`/api/v1/`) still accessible after `v2` launch — old version lacks security fixes.

**Check:** `GET /api/v1/users` returns 200 even though docs say v1 is deprecated.

---

### API10:2023 — Unsafe Consumption of APIs

**Attack path:** Backend trusts third-party API response without validation → third-party compromised → malicious data injected into your system.

**Absent mitigation:** No schema validation on third-party API responses, no output encoding before storage

---

## Re-prosecutor Citation Template

> **Attack path [OWASP API1:2023 / T1078]:** Authenticated user modifies `userId` path parameter in `GET /api/orders/{userId}` → server returns another user's order history without ownership check at `src/routes/orders.js:34`. Absent mitigation: no `if (req.params.userId !== req.user.id)` guard. Exploitability: any authenticated user can enumerate all orders by incrementing the ID.
