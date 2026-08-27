# Container Security Scanning with Trivy

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `performing-container-security-scanning-with-trivy`
**NIST CSF:** PR.PS-01, DE.CM-04 | **Subdomain:** container-security

## Purpose

Scan container images, filesystems, and Kubernetes manifests for vulnerabilities, misconfigurations, secrets, and license issues. Complements WALTEUR's `guarddog` (malicious packages) with image-layer and OS-package CVE scanning.

## What Trivy Scans

| Target | What it finds |
|--------|--------------|
| Container image | OS package CVEs, app dependency CVEs, secrets |
| Filesystem | Code vulnerabilities, config misconfigs |
| Kubernetes manifests | K8s security misconfigs (CIS Benchmark) |
| SBOM | CVE correlation (see `sbom-supply-chain.md`) |
| Dockerfile | Dockerfile best-practice violations |

## Quick Scans

```bash
# Scan a container image (pulls from registry)
trivy image nginx:latest

# Scan a local Dockerfile
trivy config ./Dockerfile

# Scan a filesystem (e.g., post-build artifact)
trivy fs --scanners vuln,secret,misconfig .

# Scan a Kubernetes manifest
trivy k8s --report summary ./k8s/

# Generate SBOM from image (CycloneDX)
trivy image --format cyclonedx --output sbom.json nginx:latest

# JSON output for CI integration
trivy image --format json --output trivy-report.json --exit-code 1 --severity CRITICAL my-app:latest
```

## CI/CD Integration

```yaml
# .github/workflows/container-scan.yml
- name: Scan container image with Trivy
  uses: aquasecurity/trivy-action@6e7b7d1fd3e4fef0c208f94d70b6f2cb37f7bfcd  # v0.24.0
  with:
    image-ref: 'my-app:${{ github.sha }}'
    format: 'sarif'
    output: 'trivy-results.sarif'
    severity: 'CRITICAL,HIGH'
    exit-code: '1'  # Fail CI on CRITICAL/HIGH

- name: Upload Trivy results to GitHub Security tab
  uses: github/codeql-action/upload-sarif@v3
  if: always()
  with:
    sarif_file: 'trivy-results.sarif'
```

## Dockerfile Best Practices Trivy Enforces

| Check | Risk if violated |
|-------|-----------------|
| `USER root` (no non-root user) | Container escape has root access to host |
| No `HEALTHCHECK` | Container orchestrator can't detect unhealthy state |
| `ADD` instead of `COPY` | `ADD` with URL fetches remote content at build time |
| Latest tag | Image content changes unpredictably |
| `--no-install-recommends` missing | Bloated image with unnecessary packages = larger attack surface |

```dockerfile
# Secure Dockerfile pattern
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production --ignore-scripts   # --ignore-scripts prevents malicious postinstall

FROM node:20-alpine AS runner
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY --from=builder --chown=appuser:appgroup /app ./
USER appuser                                    # Non-root user
EXPOSE 3000
HEALTHCHECK --interval=30s CMD curl -f http://localhost:3000/health || exit 1
CMD ["node", "server.js"]
```

## Severity Triage

- **CRITICAL (CVSS ≥9.0):** Block image promotion to prod; fix immediately
- **HIGH (7.0-8.9):** Fix within 72h; document risk if cannot fix immediately
- **MEDIUM:** Fix in next sprint; document in SBOM audit
- **LOW/INFO:** Backlog; accept if no exploit path

## WALTEUR Integration

```bash
# Add to walteur-kit/hooks/security-gate.sh or as standalone gate
trivy image --exit-code 1 --severity CRITICAL,HIGH \
  --format json --output walteur-kit/trivy-report.json \
  "$IMAGE_REF" 2>&1
echo '{"gate":"trivy","exit_code":'$?',"timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' \
  > walteur-kit/container-scan-report.json
```

High findings from Trivy → cite in `/security` report:
> **Attack path [T1190]:** Container image `nginx:1.20` includes OpenSSL 1.1.1t with CVE-2023-0286 (Critical, CVSS 9.8) — remote code execution via crafted X.400 address in certificate. Absent mitigation: image not updated since 2023-03.
