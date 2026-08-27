# Incident Response Playbook Structure

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `building-incident-response-playbook`
**NIST CSF:** RS.MA-01, RS.MA-02, RS.AN-03, RC.RP-01 | **Standard:** NIST SP 800-61r3, SANS PICERL

## Purpose

Design and document structured IR playbooks for specific incident types. Use when: building IR program from scratch, adding a new incident type after a novel attack, or automating response in a SOAR platform.

## SANS PICERL Phases

```
Preparation → Identification → Containment → Eradication → Recovery → Lessons Learned
```

## Playbook Template Structure

Every playbook must contain these sections:

### Metadata
```yaml
name: Ransomware Incident Response
version: 1.2
owner: SOC Lead
last_review: 2026-01
trigger: EDR alert "mass file encryption detected" OR helpdesk report of encrypted files
severity_default: P1 (Critical)
```

### RACI Matrix
| Step | Responsible | Accountable | Consulted | Informed |
|------|-------------|-------------|-----------|---------|
| Detection/Triage | SOC Analyst | SOC Lead | IT Admin | CISO |
| Containment | SOC Analyst | IR Lead | Legal | CTO, CEO |
| Eradication | IT Admin | IR Lead | Vendor | CISO |
| Recovery | IT Admin | IT Director | SOC | All-hands |

### Phase Procedures

**P1 — Identification (within 15 min of alert)**
- Verify true positive: check EDR alert + endpoint behavior + affected file list
- Classify severity (P1-P4) using: data sensitivity, blast radius, business impact
- Open incident ticket; assign incident commander

**P2 — Containment (within 30 min for P1)**
- Short-term: Isolate affected host via EDR containment (preserve forensic artifacts)
- Block C2 at DNS/firewall if IOCs known
- Revoke exposed credentials (AD, cloud IAM)
- Long-term: Network segmentation; disable affected service accounts

**P3 — Eradication**
- Identify root cause (initial access vector from ATT&CK)
- Remove malware / reverse persistence mechanisms
- Patch the exploited vulnerability or apply workaround
- Verify eradication via clean scan

**P4 — Recovery**
- Restore from last known-good backup (verify backup integrity first)
- Rebuild compromised systems from clean image where practical
- Validate normal operations before reopening to prod traffic
- Monitor closely for 72h post-recovery

**P5 — Lessons Learned (within 2 weeks)**
- Root cause analysis document
- Detection rule improvement (did we catch it fast enough?)
- Playbook updates
- ATT&CK coverage gap identified → feed `mitre-attack-coverage-mapping.md`

## Decision Tree (Ransomware Example)

```
Alert: Mass file encryption
├── Confirm true positive?
│   ├── YES → P1 → Page incident commander → Begin containment
│   └── NO → False positive → Tune detection rule → Close ticket
├── Is C2 active?
│   ├── YES → Block IOCs at firewall/DNS immediately
│   └── NO → Proceed with isolation
├── Is backup available and unaffected?
│   ├── YES → Proceed to recovery after eradication
│   └── NO → Escalate to leadership for ransom decision (Legal + CISO required)
└── PII/regulated data affected?
    ├── YES → Notify Legal + Privacy Officer within 1h → 72h regulatory clock may start
    └── NO → Internal resolution track
```

## Communication Templates

**P1 internal notification (send within 1h):**
> "SECURITY INCIDENT — P1 active. [Incident type] detected at [timestamp]. Affected systems: [list]. Incident Commander: [name]. Status: Containment in progress. Next update in 1h. Do NOT discuss externally."

**Regulatory notification trigger:**
- GDPR: 72h to supervisory authority if personal data breached
- PCI DSS: Notify card brands within 24h of suspected compromise
- HIPAA: 60-day notification window for breaches >500 individuals

## Metrics to Track

| Metric | Target |
|--------|--------|
| Mean Time to Detect (MTTD) | <4h |
| Mean Time to Contain (MTTC) | <2h for P1 |
| Mean Time to Resolve (MTTR) | <24h for P1 |
| False Positive Rate | <10% |
| Playbook coverage (% incidents with a playbook) | >90% |

## Top Priority Playbook Types

1. Ransomware infection
2. Phishing / credential compromise
3. Business email compromise (BEC)
4. Supply chain compromise (CI/CD)
5. API credential exposure / secret leak
6. Cloud infrastructure compromise
7. Container escape
8. Insider data exfiltration
