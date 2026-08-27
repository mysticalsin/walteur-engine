# Dependency SCA Scanning with Snyk

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `performing-sca-dependency-scanning-with-snyk`
**NIST CSF:** GV.SC-06, PR.PS-01 | **MITRE ATT&CK:** T1195.001

## Purpose

Software Composition Analysis (SCA) scans open-source dependencies for known CVEs, license violations, and malicious packages. Complements WALTEUR's `osv-gate.sh` (OSV database) by adding Snyk's proprietary vuln database (often faster on newly disclosed CVEs), fix PRs, and license compliance.

## Snyk vs OSV Gate (WALTEUR existing)

| | osv-gate.sh (existing) | Snyk (this playbook) |
|---|----------------------|---------------------|
| Database | OSV (Google, open) | Snyk DB (proprietary + OSV) |
| Malicious packages (MAL-*) | Yes | Limited |
| Fix PRs | No | Yes (Snyk Fix) |
| License compliance | No | Yes |
| IDE integration | No | Yes (VS Code, JetBrains) |
| Cost | Free | Free tier (limited), paid |

Use both: osv-gate for the HARD gate (MAL-* blocks), Snyk for deeper CVE triage + fix suggestions.

## Snyk CLI Usage

```bash
# Install
npm install -g snyk

# Authenticate (required)
snyk auth

# Scan npm/yarn project
snyk test --json > walteur-kit/snyk-report.json

# Scan Python project
snyk test --command=python3 --json > snyk-report.json

# Scan container image
snyk container test nginx:latest --json > snyk-container-report.json

# Monitor (continuous tracking in Snyk web dashboard)
snyk monitor

# Auto-fix (creates package.json upgrades)
snyk fix
```

## CI/CD Integration

```yaml
# .github/workflows/sca.yml
- name: Run Snyk SCA
  uses: snyk/actions/node@master
  env:
    SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
  with:
    args: >
      --severity-threshold=high
      --json-file-output=walteur-kit/snyk-report.json
  continue-on-error: false  # Block PR on HIGH+ CVEs
```

## Triage Snyk Findings

```bash
# Parse report for critical/high
cat walteur-kit/snyk-report.json | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
vulns = data.get('vulnerabilities', [])
high_plus = [v for v in vulns if v.get('severity') in ('critical','high')]
for v in high_plus:
    print(f\"{v['severity'].upper()} | {v['id']} | {v['packageName']}@{v['version']} | {v['title']}\")
"
```

## Fix Priority Logic

1. **Critical CVE + exploit in wild (CISA KEV):** Fix immediately, do not ship
2. **Critical CVE, no known exploit:** Fix within 24h
3. **High CVE:** Fix within 72h
4. **Snyk offers auto-fix:** Accept the fix PR after testing
5. **Transitive dep, no upgrade path:** Open issue in upstream; use `npm audit fix --force` as last resort
6. **Dev-only dep:** Confirm the dep is not reachable in prod before downgrading severity

## License Compliance

Snyk flags license violations automatically. For WALTEUR projects:

| License | Policy |
|---------|--------|
| MIT, Apache 2.0, BSD | Allowed |
| ISC, Unlicense | Allowed |
| LGPL v2/v3 | Review required (dynamic linking OK) |
| GPL v2/v3 | Blocked in commercial projects |
| AGPL | Blocked |
| Unknown / No license | Blocked |

```bash
# Snyk license check
snyk test --print-deps --json | jq '.dependencies[] | select(.license | test("GPL|AGPL")) | {name:.name, version:.version, license:.license}'
```

## WALTEUR Integration

`snyk-report.json` feeds the security audit alongside `osv-report.json`.
When the re-prosecutor finds a vulnerable dependency:
> **Attack path [T1195.001]:** `lodash@4.17.20` (direct dependency via `express@4.18.2`) has CVE-2021-23337 (HIGH, CVSS 7.2) — prototype pollution via `_.set()`. If user-controlled data flows through `_.set()`, attacker can corrupt Object.prototype and bypass authorization checks. Absent mitigation: no version pin or `noprotect` sandbox for untrusted data.
