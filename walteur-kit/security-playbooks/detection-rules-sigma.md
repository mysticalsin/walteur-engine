# Vendor-Agnostic Detection Rules with Sigma

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `building-detection-rules-with-sigma`
**NIST CSF:** DE.CM-01, DE.AE-02 | **MITRE ATT&CK:** Multiple techniques

## Purpose

Build Sigma rules — vendor-agnostic detection logic that compiles to Splunk SPL, Elastic KQL, Microsoft Sentinel KQL, Sumo Logic, and more. Write once, deploy anywhere. Use when writing detection rules for the WALTEUR security lane or for client SIEM deployments.

## Sigma Rule Structure

```yaml
title: Suspicious PowerShell Encoded Command Execution
id: c539b6b3-5d2e-4e93-a4c4-5dd8ba51d7b1  # UUID v4
status: test  # test / experimental / stable
description: Detects PowerShell execution with base64-encoded commands — common in malware delivery
references:
  - https://attack.mitre.org/techniques/T1027/010/
author: walteur-security-lane
date: 2026-06-21
tags:
  - attack.execution
  - attack.t1059.001
  - attack.defense_evasion
  - attack.t1027.010
logsource:
  category: process_creation
  product: windows
detection:
  selection:
    CommandLine|contains|all:
      - 'powershell'
      - '-EncodedCommand'
  condition: selection
falsepositives:
  - Legitimate administrative scripts using encoded commands
  - Some software installers
level: high    # informational / low / medium / high / critical
```

## Key Detection Categories for WALTEUR

### Credential Dumping (T1003)

```yaml
title: LSASS Memory Access by Non-System Process
logsource:
  category: process_access
  product: windows
detection:
  selection:
    TargetImage|endswith: '\lsass.exe'
    GrantedAccess|contains:
      - '0x1010'
      - '0x1410'
      - '0x147a'
      - '0x1fffff'
  filter_legitimate:
    SourceImage|startswith:
      - 'C:\Windows\System32\'
      - 'C:\Windows\SysWOW64\'
  condition: selection and not filter_legitimate
level: high
tags:
  - attack.credential_access
  - attack.t1003.001
```

### Supply Chain — Malicious npm/pip Package Post-Install

```yaml
title: Package Manager Post-Install Network Connection
logsource:
  category: network_connection
  product: linux
detection:
  selection:
    Initiated: 'true'
    ParentImage|contains:
      - 'npm'
      - 'pip'
      - 'node'
    DestinationPort|not|contains:
      - '80'
      - '443'
      - '8080'
  condition: selection
level: medium
tags:
  - attack.execution
  - attack.t1195.002
```

### Secrets in Environment Variables (CI/CD exfil)

```yaml
title: CI/CD Secret Exfiltration via curl
logsource:
  category: process_creation
  product: linux
detection:
  selection:
    CommandLine|contains|all:
      - 'curl'
      - 'SECRET'
  condition: selection
level: high
tags:
  - attack.exfiltration
  - attack.t1552.001
```

## Sigma Compilation

```bash
# Install sigma CLI
pip install sigma-cli

# Convert to Splunk SPL
sigma convert -t splunk -p splunk_windows sigma/rules/

# Convert to Elastic KQL
sigma convert -t elasticsearch -p ecs_windows sigma/rules/

# Convert to Microsoft Sentinel
sigma convert -t microsoft365defender sigma/rules/

# Validate rule syntax
sigma check sigma/rules/my-rule.yml
```

## Rule Quality Standards

Every production Sigma rule must have:
- `id` field (UUID v4) — for tracking and SIEM deduplication
- `tags` with ATT&CK technique (e.g., `attack.t1059.001`)
- `falsepositives` list — even if "None known"
- `level` set correctly (test rules on actual log data before promoting to `high`)
- `references` to ATT&CK or vendor advisory

## WALTEUR Integration

Store custom Sigma rules in `walteur-kit/rules/sigma/`.
Cross-reference with `mitre-attack-coverage-mapping.md` — each rule covers specific ATT&CK sub-techniques.
When the re-prosecutor identifies a detection gap, this playbook is the entry point to close it.
