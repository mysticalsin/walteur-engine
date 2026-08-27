# DAST Integration with OWASP ZAP in CI/CD

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `integrating-dast-with-owasp-zap-in-pipeline`
**NIST CSF:** DE.CM-04, PR.PS-01 | **MITRE ATT&CK:** T1190 (exploit public-facing app)

## Purpose

Integrate Dynamic Application Security Testing (DAST) via OWASP ZAP into CI/CD pipelines. DAST tests the running application, finding vulnerabilities that SAST misses (real HTTP behavior, session management, authentication bypasses). Complements WALTEUR's SAST gate.

## SAST vs DAST Comparison

| | SAST | DAST |
|---|------|------|
| When | At code commit | Against running app |
| What it finds | Code patterns, taint flows | HTTP behavior, auth issues |
| False positive rate | Higher | Lower (real HTTP response) |
| Speed | Fast (seconds) | Slower (minutes) |
| Misses | Runtime behavior | Code paths not triggered |
| WALTEUR gate | opengrep-taint | This playbook |

## GitHub Actions Integration (ZAP Baseline Scan)

```yaml
# .github/workflows/dast.yml
name: DAST Security Scan

on:
  push:
    branches: [main]
  schedule:
    - cron: '0 2 * * 1'  # Weekly Monday 02:00 UTC

jobs:
  dast:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29  # v4.1.6

      - name: Start application
        run: |
          docker compose up -d
          sleep 15  # Wait for app to be ready
          curl --retry 10 --retry-delay 3 http://localhost:3000/health

      - name: ZAP Baseline Scan
        uses: zaproxy/action-baseline@7550aa33e4dc1f2c6c1df05c62f07df1ea4fc4cb  # v0.12.0
        with:
          target: 'http://localhost:3000'
          rules_file_name: '.zap/rules.tsv'   # Custom rule configuration
          cmd_options: '-a -j'                 # Scan Ajax, generate JSON report
          fail_action: true                    # Fail CI on new HIGH findings

      - name: Upload ZAP Report
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: zap-report
          path: report_json.json
```

## ZAP Rule Configuration

Create `.zap/rules.tsv` to customize which rules block CI vs. warn:

```tsv
# Rule ID  Threshold  (IGNORE/WARN/FAIL)
10016      WARN       # Web Browser XSS Protection Not Enabled
10017      WARN       # Cross-Domain JavaScript Source File Inclusion
10020      FAIL       # Anti-clickjacking Header not found
10021      WARN       # X-Content-Type-Options Header Missing
10038      FAIL       # Content Security Policy Header Not Set
10045      FAIL       # Source Code Disclosure - /WEB-INF folder
10054      WARN       # Cookie Without SameSite Attribute
40012      FAIL       # Cross Site Scripting (Reflected)
40014      FAIL       # Cross Site Scripting (Persistent)
40018      FAIL       # SQL Injection
90022      WARN       # Application Error Disclosure
```

## Authenticated Scanning

For testing authenticated endpoints:

```yaml
      - name: ZAP Full Scan (authenticated)
        uses: zaproxy/action-full-scan@7550aa33e4dc1f2c6c1df05c62f07df1ea4fc4cb
        with:
          target: 'http://localhost:3000'
          cmd_options: >
            -z "-config scanner.attackStrength=MEDIUM
                -config scanner.alertThreshold=MEDIUM"
        env:
          ZAP_AUTH_HEADER: "Authorization"
          ZAP_AUTH_HEADER_VALUE: "Bearer ${{ secrets.TEST_JWT_TOKEN }}"
```

## Key Vulnerabilities DAST Finds

1. **Reflected XSS** — user input echoed in response without encoding
2. **SQL injection** — error-based or time-based blind SQLi in form fields
3. **Missing security headers** — CSP, HSTS, X-Frame-Options, X-Content-Type-Options
4. **CORS misconfiguration** — `Access-Control-Allow-Origin: *` on authenticated endpoints
5. **Authentication bypass** — unauthenticated access to protected routes
6. **Session fixation** — session ID not rotated post-login
7. **Directory traversal** — `../` in URL path parameters

## WALTEUR Integration

DAST results feed `walteur-kit/dast-report.json` (parallel to `sast-report.json`).
HIGH/CRITICAL DAST findings → cite in `/security` report:

> **Attack path [T1190]:** Unauthenticated HTTP GET `/api/users?id=1 OR 1=1--` returns full user table [ZAP: 40018 SQL Injection]. Absent mitigation: no parameterized query in `src/routes/users.js:23`. Exploitability: confirmed exploitable via ZAP active scan.
