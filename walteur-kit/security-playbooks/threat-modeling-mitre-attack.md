# Threat Modeling with MITRE ATT&CK

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `implementing-threat-modeling-with-mitre-attack`
**NIST CSF:** DE.CM-01, DE.AE-02, RS.MA-01 | **MITRE ATT&CK:** T1078, T1566

## Purpose

Map adversary TTPs against organizational assets, expose detection coverage gaps, and prioritize defensive investments. Use when: onboarding a new environment, justifying security tool spend, or feeding the WALTEUR re-prosecutor with citable attack paths.

## Workflow (5 steps)

### 1. Identify sector-relevant threat actors
- Query ATT&CK Groups at https://attack.mitre.org/groups/
- Filter by sector (Financial, Technology, Healthcare) to get the actor shortlist
- Pull TTP list per actor — focus on Initial Access, Persistence, Lateral Movement, Exfiltration

### 2. Build TTP profile per actor
- Export actor techniques as ATT&CK Navigator layer (JSON)
- Annotate each technique with: observed frequency, data source needed, detection feasibility (High/Medium/Low)
- Key data sources: Windows Event Logs, Sysmon, Zeek/Suricata, CloudTrail, Endpoint EDR telemetry

### 3. Map current detection coverage
- For each ATT&CK technique in the actor profile, tag status: `DETECTED` / `PARTIAL` / `BLIND`
- Export coverage as a second Navigator layer; overlay with actor profile → gaps are red
- Tools: Splunk ES (annotated correlation searches), Sigma rule inventory, SIEM coverage matrix

### 4. Prioritize gaps
Rank uncovered techniques by:
1. Technique prevalence across actor profiles (used by 3+ actors = top priority)
2. Blast radius of the technique (data exfiltration > persistence > recon)
3. Detection feasibility given current telemetry

### 5. Build detection roadmap
- For each P1 gap: define the required data source, write a Sigma rule skeleton (see `detection-rules-sigma.md`), assign owner
- Review quarterly as ATT&CK matrix is updated (currently v15)

## Key ATT&CK Techniques for Web/API/Cloud (WALTEUR scope)

| Technique | ID | Re-prosecutor citation |
|-----------|-----|----------------------|
| Valid Accounts | T1078 | Stolen credential misuse → authz boundary bypass |
| Phishing / Spearphishing Attachment | T1566 | Initial access via email → code execution |
| Exploit Public-Facing Application | T1190 | Injection / unpatched CVE → RCE on web tier |
| Supply Chain Compromise | T1195 | Malicious dependency → arbitrary code at build time |
| Exfiltration Over Web Service | T1567 | Data leak via S3/HTTPS to external domain |
| Abuse Elevation Control Mechanism | T1548 | Privilege escalation via misconfigured IAM/RBAC |

## Re-prosecutor Citation Format

When a security finding maps to a technique above, cite it as:

> **Attack path [ATT&CK T1190]:** External attacker → HTTP POST to `/api/eval` with unsanitized input → eval() sink at `src/api/handler.js:42` → Remote Code Execution. Absent mitigation: no input validation at sink. Exploitability: curl-exploitable in <60 seconds on default config.

## Tools

- ATT&CK Navigator (web): https://mitre-attack.github.io/attack-navigator/
- MITRE ATT&CK STIX data: https://github.com/mitre/cti
- Atomic Red Team (simulation): https://github.com/redcanaryco/atomic-red-team
