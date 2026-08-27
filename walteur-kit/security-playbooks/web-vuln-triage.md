# Web Application Vulnerability Triage

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `performing-web-application-vulnerability-triage`
**NIST CSF:** DE.AE-06, RS.AN-03 | **Subdomain:** vulnerability-management

## Purpose

Triage web application vulnerability findings from DAST/SAST scanners — classify, prioritize, confirm exploitability, and reduce false positives before assigning remediation work. Without triage, raw scanner output overwhelms developers and erodes trust.

## Triage Decision Flow

```
Finding from scanner
├── Is it a false positive?
│   ├── Test manually → if benign → mark FP + tune rule
│   └── Confirmed real → proceed
├── Is it exploitable in production context?
│   ├── YES → confirm severity tier
│   └── NO (e.g., XSS in admin-only page) → downgrade severity
├── Is it already mitigated by a compensating control?
│   ├── YES (WAF blocks it, auth required) → document + accept risk
│   └── NO → assign for remediation
└── Assign severity (Critical / High / Medium / Low / Info)
```

## Severity Classification (CVSS-aligned)

| Severity | CVSS | Examples | SLA |
|----------|------|---------|-----|
| Critical | 9.0-10.0 | RCE, SQLi on public endpoint, auth bypass | Fix in 24h |
| High | 7.0-8.9 | Stored XSS, IDOR on sensitive data, SSRF | Fix in 72h |
| Medium | 4.0-6.9 | Reflected XSS, missing security headers, info disclosure | Fix in 2 weeks |
| Low | 0.1-3.9 | Missing Secure cookie flag, verbose errors | Fix in next sprint |
| Info | 0.0 | Best practice recommendations | Backlog |

## Confirming Exploitability (manual verification steps)

### Reflected XSS
```bash
# Test if payload executes
curl -s "https://target/search?q=<script>alert(1)</script>" | grep -o '<script>alert(1)</script>'
# Also test with: "><img src=x onerror=alert(1)>
# Browser test: does alert fire? Is output encoded?
```

### SQL Injection
```bash
# Error-based SQLi test
curl "https://target/api/user?id=1'"
# Look for: SQL error messages, 500 with DB details
# Time-based: id=1 AND SLEEP(5)
```

### SSRF
```bash
# Use webhook.site or Burp Collaborator as the callback
curl -X POST https://target/api/webhook \
  -d '{"url": "https://your-collaborator-id.burpcollaborator.net"}'
# Check if callback received → SSRF confirmed
```

### IDOR
```bash
# Change user ID in request to another user's ID
curl -H "Authorization: Bearer <your-token>" \
  "https://target/api/users/ANOTHER-USER-ID/profile"
# 200 with their data = confirmed IDOR
```

## False Positive Patterns (common scanner noise)

| Finding | Why it's often FP | Verification |
|---------|------------------|-------------|
| XSS in `text/plain` response | Browser won't execute in non-HTML context | Check Content-Type header |
| SQLi in integer parameter | `id=1 OR 1=1` is blocked by type validation | Check if input is typed |
| CSRF on logout | CSRF on GET/logout is acceptable risk (no state change) | Check if sensitive action |
| Missing HSTS | Internal/staging domain doesn't need HSTS | Check if production |
| Directory listing | Intentional for public static assets | Check if data is sensitive |

## Prioritization Framework (beyond CVSS)

CVSS doesn't capture context. Adjust with:
- **Authentication required?** Reduces exploitability if endpoint requires auth
- **Affected data sensitivity** — PII/financial > operational > public
- **Internet-facing?** Public endpoints > internal only
- **Exploit in the wild?** CISA KEV or Metasploit module = fast-track fix
- **Business impact** — checkout flow > admin panel > analytics endpoint

## Remediation Tracking Format

```markdown
## VULN-2026-042: Reflected XSS in /search endpoint

**Status:** In Remediation
**Severity:** High (confirmed exploitable, no auth required)
**Scanner:** OWASP ZAP (rule 40012) — confirmed manually
**Attack path:** GET `/search?q=<payload>` → unencoded output in `<div class="results">` → XSS
**Absent mitigation:** No output encoding in `src/views/search.ejs:12`
**Fix:** `<%- query %>` → `<%= query %>` (EJS HTML-encode) or `escapeHtml(query)`
**Owner:** @dev-team
**Due:** 2026-06-24
**Verification:** Re-run ZAP scan after fix; confirm 404 for `40012` rule
```
