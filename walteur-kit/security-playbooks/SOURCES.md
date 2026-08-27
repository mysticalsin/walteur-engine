# Security Playbooks — Source Attribution

**Source repository:** `mukul975/Anthropic-Cybersecurity-Skills`
**URL:** https://github.com/mukul975/Anthropic-Cybersecurity-Skills
**Commit SHA:** `7eebca88aa7e5bf723cabbb7c441f3d83b4779cd`
**License:** Apache License 2.0 (permissive — subset vendoring with attribution is permitted)
**Copyright:** 2026 mukul975

## Curation Ratio

**Kept 20 of 762 skills (2.6%) — anti-bloat proof.**

Every file here is a tight reference doc synthesized from the upstream SKILL.md.
Original full skill files (scripts, references/) are NOT vendored — only the distilled playbook content.

## Curated Skills — Selected + Rationale

| # | Playbook File | Upstream Skill | Why Selected |
|---|---------------|----------------|--------------|
| 1 | threat-modeling-mitre-attack.md | `implementing-threat-modeling-with-mitre-attack` | Core WALTEUR gap: maps adversary TTPs to detection coverage; feeds the re-prosecutor's attack paths |
| 2 | threat-modeling-owasp.md | `performing-threat-modeling-with-owasp-threat-dragon` | STRIDE/DFD-based complement to ATT&CK; needed for pre-build threat analysis |
| 3 | cyber-risk-assessment-nist-800-30.md | `conducting-cyber-risk-assessment-with-nist-800-30` | Authoritative risk methodology for project risk registers and ATO prep |
| 4 | incident-response-playbook.md | `building-incident-response-playbook` | NIST 800-61r3 / SANS PICERL IR structure; directly extends the /security lane |
| 5 | cloud-incident-response.md | `conducting-cloud-incident-response` | AWS/Azure/GCP-specific IR; cloud is WALTEUR's primary deploy surface |
| 6 | sbom-supply-chain.md | `analyzing-sbom-for-supply-chain-vulnerabilities` | Extends WALTEUR's existing osv-gate with CycloneDX/SPDX triage depth |
| 7 | cicd-supply-chain-detection.md | `detecting-supply-chain-attacks-in-ci-cd` | GitHub Actions / CI pipeline attack detection — direct WALTEUR pipeline relevance |
| 8 | sast-pipeline-integration.md | `integrating-sast-into-github-actions-pipeline` | Adds SAST depth beyond opengrep-taint; cites GitHub Actions integration patterns |
| 9 | semgrep-custom-rules.md | `implementing-semgrep-for-custom-sast-rules` | Custom Semgrep rules complement existing opengrep-taint gate |
| 10 | dast-owasp-zap-pipeline.md | `integrating-dast-with-owasp-zap-in-pipeline` | Dynamic testing layer absent from current WALTEUR gates |
| 11 | owasp-api-security-top10.md | `testing-api-security-with-owasp-top-10` | Citable OWASP API Top-10 attack paths for the re-prosecutor |
| 12 | web-vuln-triage.md | `performing-web-application-vulnerability-triage` | DAST/SAST finding triage methodology to reduce false positives |
| 13 | detection-rules-sigma.md | `building-detection-rules-with-sigma` | Vendor-agnostic Sigma rules for detection engineering; feeds SIEM tuning |
| 14 | mitre-attack-coverage-mapping.md | `implementing-mitre-attack-coverage-mapping` | Coverage gap analysis between detected TTPs and ATT&CK matrix |
| 15 | anomalous-auth-detection.md | `detecting-anomalous-authentication-patterns` | UEBA-based auth anomaly detection; high-signal authz attack path |
| 16 | container-security-scanning.md | `performing-container-security-scanning-with-trivy` | Trivy scanning complements existing guarddog; container attack surface |
| 17 | container-escape-detection.md | `detecting-container-escape-attempts` | ATT&CK-mapped container escape detection; runtime security gap |
| 18 | dependency-sca-snyk.md | `performing-sca-dependency-scanning-with-snyk` | SCA depth for WALTEUR's supply-chain lane; OSV gate companion |
| 19 | typosquatting-package-detection.md | `detecting-typosquatting-packages-in-npm-pypi` | npm/PyPI typosquatting detection — extends osv-gate + guarddog |
| 20 | cis-cloud-audit.md | `auditing-cloud-with-cis-benchmarks` | CIS Benchmark cloud audit; baseline hardening reference for cloud posture |

## Deliberately Excluded

- **Offensive/red-team-only:** penetration testing, exploit dev, Cobalt Strike analysis, malware sandbox, rootkit/shellcode analysis — WALTEUR is defensive
- **Forensics/DFIR (tool-specific):** Volatility, Autopsy, Cellebrite, disk imaging — valuable but out of scope for a build-engine security lane (better suited to a dedicated DFIR skill set)
- **Vendor-locked SIEM skills:** Splunk SPL, Elastic SIEM, Azure Sentinel (612+ skills) — too specific to deploy environment
- **ICS/OT/SCADA:** Out of WALTEUR's web/API/cloud scope
- **Compliance-only walkthroughs:** CMMC, NERC CIP, PCI DSS (lengthy checklists duplicating existing gate outputs)
- **Duplicate coverage:** Skills that replicate what gitleaks, osv-gate, guarddog, or opengrep-taint already provide mechanically

## Usage in WALTEUR

These files are a **graphify-indexed REFERENCE LIBRARY** — graphify remains the one brain.
The `/security` command cites playbooks by name when raising findings.
No new plugin engine. No second index. Reference only.

See: `walteur-starter/.claude/commands/security.md` for integration wiring.
