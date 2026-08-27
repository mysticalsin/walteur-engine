# Cyber Risk Assessment — NIST SP 800-30

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `conducting-cyber-risk-assessment-with-nist-800-30`
**NIST CSF:** GV.RM-01, ID.RA-01 through ID.RA-05 | **Standard:** NIST SP 800-30 Rev 1

## Purpose

Produce a defensible, prioritized risk register for a project or system. Required as input for ISO 27001 (§6.1.2), NIST RMF (ATO prep), SOC 2 (CC3), and PCI DSS. Use when leadership asks "what are our top risks?" or when a major system change needs pre-authorization risk analysis.

## Four-Step Methodology (NIST SP 800-30 Rev 1)

### Step 1: Prepare — define scope and risk model

Lock these BEFORE scoring so results are comparable:
- **Scope:** system boundary, tier (Org / Mission-Process / System), time horizon
- **Threat sources:** Adversarial (nation-state, cybercriminal, insider) | Accidental (user error) | Structural (HW/SW failure) | Environmental
- **Risk scales:** Qualitative (Very Low / Low / Moderate / High / Very High) or semi-quantitative (0–10). Commit once; never change mid-assessment.
- **Information sources:** threat intel (ISAC feeds, ATT&CK Groups), vuln data (scan results, pen test), business impact data (asset criticality, data classification)

### Step 2: Conduct — the analytic core

**2a. Identify threat sources** (NIST App D)
Classify each source by capability + intent + targeting. For adversarial: use ATT&CK Groups relevant to your sector.

**2b. Identify threat events** (NIST App E)
Map to ATT&CK techniques for traceability:
- "Adversary exfiltrates credentials via phishing" → T1566 → T1078
- "Insider copies PII to personal storage" → T1048 → T1530

**2c. Identify vulnerabilities** (NIST App F)
Sources: SAST/DAST findings, dependency CVEs (osv-gate), config drift (CIS benchmarks), architecture gaps (STRIDE model), patch lag.

**2d. Determine likelihood** (NIST App G)
For each threat-event + vulnerability pair:
- Initiation likelihood (how likely is the threat source to attempt?)
- Exploitation success likelihood (given the vulnerability, how likely to succeed?)
- Overall likelihood = min(initiation, success) or expert judgment

**2e. Determine impact** (NIST App H)
Impact on Confidentiality / Integrity / Availability:
- Very High: mission failure, loss of life, major regulatory penalty
- High: significant operational degradation, significant data breach
- Moderate: limited operational impact, limited PII exposure
- Low: minor degradation, no PII

**2f. Determine risk level**
Risk = f(Likelihood, Impact). Use NIST App I risk matrix or equivalent:
```
           |  Low   | Moderate |  High  | Very High |
Very High  |  Mod   |   High   |  Very  |   Very    |
High       |  Low   |   Mod    |  High  |   Very    |
Moderate   |  Low   |   Low    |  Mod   |   High    |
Low        |  Low   |   Low    |  Low   |   Mod     |
```

### Step 3: Communicate — produce the risk register

Each row in the risk register:

| Field | Content |
|-------|---------|
| Risk ID | R-001 |
| Threat source | APT-FIN7 (adversarial, high capability) |
| Threat event | Credential harvesting via spearphishing |
| ATT&CK | T1566.001, T1078 |
| Vulnerability | No MFA on admin console |
| Likelihood | High |
| Impact | Very High |
| Risk level | Very High |
| Current controls | Email gateway (partial) |
| Recommended treatment | Enforce MFA (Priority 1), deploy FIDO2 |
| Residual risk | Moderate (post-treatment estimate) |
| Owner | Security Engineering |

### Step 4: Maintain — residual risk and treatment tracking

- Document treatment decisions: Accept / Mitigate / Transfer / Avoid
- Re-score residual risk after controls deployed
- Schedule annual reassessment; trigger ad hoc on major architecture changes

## WALTEUR Integration

- Run this assessment before `/scaffold` for any project with external-facing components or PII
- Top-3 Very High / High risks feed directly into the security floor check in `/security`
- Risk register output → `walteur-kit/audit.json:risk_register`
