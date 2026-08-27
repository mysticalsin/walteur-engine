# SBOM Analysis for Supply Chain Vulnerabilities

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `analyzing-sbom-for-supply-chain-vulnerabilities`
**NIST CSF:** GV.SC-01, GV.SC-03, GV.SC-06 | **MITRE ATT&CK:** T1195.001, T1195.002

## Purpose

Parse Software Bill of Materials (SBOM) in CycloneDX or SPDX format, correlate components against NVD CVE database, and identify transitive vulnerability paths. Extends WALTEUR's existing `osv-gate.sh` with structured SBOM triage depth. Required by EO 14028 and EU Cyber Resilience Act for software deliveries.

## SBOM Formats

| Format | Standard | Tools |
|--------|----------|-------|
| CycloneDX JSON (v1.4+) | OWASP | syft, cdxgen, trivy |
| SPDX JSON (v2.3+) | Linux Foundation | syft, spdx-tools |

## Workflow

### Step 1: Generate SBOM (if not provided)

```bash
# CycloneDX from container image
syft alpine:latest -o cyclonedx-json > sbom-cyclonedx.json

# SPDX from project directory
syft dir:/path/to/project -o spdx-json > sbom-spdx.json

# CycloneDX from npm project
cdxgen -t nodejs -o sbom.json .
```

### Step 2: Vulnerability correlation

```bash
# Cross-validate SBOM against Grype (OSS vulnerability scanner)
grype sbom:sbom-cyclonedx.json --output json > vuln-report.json

# Check against OSV database (also used by WALTEUR osv-gate)
osv-scanner --sbom sbom-cyclonedx.json --format json > osv-report.json
```

### Step 3: Analyze transitive dependencies

Direct dependencies are visible in `package.json` / `requirements.txt`.
Transitive dependencies (dependencies of dependencies) are the real supply chain risk — they are typically 5–10x more numerous and less audited.

Key questions:
- Which direct dependency introduces the most transitive CVEs?
- Are any transitive dependencies known to be malicious (OSV MAL-* advisories)?
- Are there duplicated packages at different versions (version conflict = patching difficulty)?

### Step 4: Triage findings

Prioritize CVEs in SBOM by:
1. **CVSS score ≥ 9.0** (Critical) — fix immediately
2. **Exploitability in the wild** (CISA KEV list) — fix within 24-72h
3. **Transitive only, no exploit PoC** — fix in next sprint
4. **Low CVSS, no exploit path** — accept with documented risk

```bash
# Filter Critical CVEs from Grype output
cat vuln-report.json | jq '[.matches[] | select(.vulnerability.severity == "Critical")]'

# Cross-reference with CISA KEV
curl -s https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json \
  | jq '.vulnerabilities[].cveID' | sort > cisa-kev.txt
```

### Step 5: Remediation

```bash
# npm: upgrade all direct dependencies to latest non-breaking
npm audit fix

# npm: force upgrade transitive dep (use with care — may break compatibility)
npm install vuln-package@latest

# Python: regenerate lock file after upgrading
pip install --upgrade vuln-package && pip freeze > requirements.txt
```

## WALTEUR Integration

- WALTEUR's `osv-gate.sh` already detects MAL-* (malicious package) advisories
- This playbook adds SBOM generation + transitive CVE triage on top of that gate
- High-severity SBOM findings → cited in `/security` report as supply chain attack path:

> **Attack path [T1195.001]:** Malicious transitive dependency `event-stream@3.3.6` → injected crypto-stealer code → executes at `npm install` time → developer credentials compromised. Absent mitigation: no SBOM audit gate in CI pipeline.

## Tools Reference

| Tool | Purpose | License |
|------|---------|---------|
| syft | SBOM generation | Apache 2.0 |
| grype | SBOM vulnerability scan | Apache 2.0 |
| osv-scanner | OSV CVE correlation | Apache 2.0 |
| cdxgen | CycloneDX SBOM generation | Apache 2.0 |
| trivy | Container + SBOM scanning | Apache 2.0 |
