# MITRE ATT&CK Coverage Mapping

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `implementing-mitre-attack-coverage-mapping`
**NIST CSF:** DE.CM-01, DE.AE-02 | **Framework:** MITRE ATT&CK Enterprise v15

## Purpose

Identify detection gaps between current SIEM/EDR rules and the ATT&CK technique matrix. Prioritize coverage investments. Feeds the WALTEUR security-adversarial re-prosecutor with a structured gap list to cite when raising findings.

## Coverage States

| Status | Meaning |
|--------|---------|
| DETECTED | Active detection rule exists, tested, low FP rate |
| PARTIAL | Detection exists but incomplete (only some sub-techniques, or high FP) |
| BLIND | No detection — attacker can use this technique undetected |
| NOT-APPLICABLE | Technique not relevant to this environment (e.g., ICS technique on a web-only project) |

## Mapping Process

### Step 1: Inventory current detection rules

Export all detection rules and map each to ATT&CK technique IDs.

```bash
# Sigma rules in walteur-kit/rules/sigma/
grep -r "attack.t[0-9]" walteur-kit/rules/sigma/ | \
  grep -oE 't[0-9]{4}\.[0-9]{3}' | sort | uniq -c | sort -rn
```

### Step 2: Build the coverage matrix

```python
# Simple coverage tracker (extend as needed)
coverage = {
    # Initial Access
    "T1190": "DETECTED",    # Exploit Public-Facing Application — opengrep-taint + DAST
    "T1195.002": "PARTIAL", # Malicious NPM package — osv-gate (MAL-*) but no runtime detection
    "T1566.001": "BLIND",   # Spearphishing Attachment — email gateway needed
    "T1078": "PARTIAL",     # Valid Accounts — anomalous-auth detection (see playbook)

    # Execution
    "T1059.001": "DETECTED", # PowerShell — Sigma rule in place
    "T1059.007": "DETECTED", # JavaScript — opengrep-taint catches eval() sinks

    # Persistence
    "T1053.005": "BLIND",   # Scheduled Task/Job — no scheduled task monitoring
    "T1554": "PARTIAL",     # Compromise Client Software Binary — osv-gate partial coverage

    # Defense Evasion
    "T1027.010": "DETECTED", # Base64 encoded commands — Sigma rule
    "T1070.004": "BLIND",   # File Deletion — no file integrity monitoring

    # Credential Access
    "T1003.001": "BLIND",   # LSASS Memory — no EDR coverage on this environment
    "T1552.001": "DETECTED", # Credentials in Files — gitleaks gate

    # Exfiltration
    "T1567": "PARTIAL",     # Exfil over Web Service — no DLP
    "T1048": "BLIND",       # Exfiltration over alternative protocol

    # Impact
    "T1486": "PARTIAL",     # Data Encrypted for Impact — deploy detection only
}

blind_count = sum(1 for v in coverage.values() if v == "BLIND")
detected_count = sum(1 for v in coverage.values() if v == "DETECTED")
total = len(coverage)
print(f"Coverage: {detected_count}/{total} detected, {blind_count} BLIND gaps")
```

### Step 3: Prioritize BLIND gaps

Rank by:
1. Technique appears in your sector's top threat actor profiles (`threat-modeling-mitre-attack.md`)
2. Exploitation observed in the wild (CISA KEV, threat intel feeds)
3. Detection feasibility given current telemetry

### Step 4: Close gaps

For each top-priority BLIND gap:
1. Identify required data source (process events, network flow, DNS, API logs)
2. Write detection rule (`detection-rules-sigma.md`)
3. Test against simulation (Atomic Red Team test case for that technique)
4. Promote to DETECTED once rule is validated

## ATT&CK Techniques Most Relevant to WALTEUR (Web/API/Cloud)

| Technique | ID | Sub-technique | Detection Source |
|-----------|-----|--------------|-----------------|
| Exploit Public-Facing App | T1190 | — | DAST, WAF logs |
| Supply Chain Compromise | T1195 | .001 .002 | osv-gate, sbom-supply-chain |
| Valid Accounts | T1078 | .004 Cloud | anomalous-auth-detection |
| Server-Side Request Forgery | T1609 | — | SAST taint rule |
| Credentials in Files | T1552 | .001 | gitleaks gate |
| Exfil Over Web Service | T1567 | .002 | Network egress monitoring |
| Container Escape | T1611 | — | container-escape-detection |
| Abuse Elevation Control | T1548 | — | RBAC audit, IAM reviews |

## Navigator Layer Export

Generate ATT&CK Navigator layer from coverage map:

```python
import json

def export_navigator_layer(coverage: dict) -> dict:
    color_map = {"DETECTED": "#00ff00", "PARTIAL": "#ffff00",
                 "BLIND": "#ff0000", "NOT-APPLICABLE": "#888888"}
    return {
        "name": "WALTEUR Coverage",
        "versions": {"attack": "15", "navigator": "5.0", "layer": "4.5"},
        "domain": "enterprise-attack",
        "techniques": [
            {"techniqueID": tid, "color": color_map.get(status, "#888888"),
             "comment": status}
            for tid, status in coverage.items()
        ]
    }

with open("walteur-kit/attack-coverage-layer.json", "w") as f:
    json.dump(export_navigator_layer(coverage), f, indent=2)
```

Upload to https://mitre-attack.github.io/attack-navigator/ to visualize coverage gaps.
