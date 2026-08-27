# SAST Integration in CI/CD Pipeline

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `integrating-sast-into-github-actions-pipeline`
**NIST CSF:** PR.PS-01, DE.CM-04 | **MITRE ATT&CK:** T1190, T1059

## Purpose

Integrate Static Application Security Testing (SAST) into CI pipelines so vulnerabilities are caught at code commit rather than post-deployment. Extends WALTEUR's existing `opengrep-taint` gate with deeper language-native scanning.

## Tool Comparison

| Tool | Best For | License | WALTEUR Fit |
|------|---------|---------|-------------|
| Semgrep (opengrep) | Custom rules, OWASP, taint | LGPL/commercial | Already gated |
| CodeQL | Deep dataflow, GitHub native | Free for OSS | High value add |
| Bandit | Python security | Apache 2.0 | Python projects |
| ESLint security plugin | JavaScript/TypeScript | MIT | Node projects |
| Gosec | Go security | Apache 2.0 | Go projects |
| Trivy (secrets) | Secrets in code | Apache 2.0 | All projects |

## GitHub Actions Integration (CodeQL)

```yaml
# .github/workflows/sast.yml
name: SAST Security Scan

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

permissions:
  security-events: write
  contents: read

jobs:
  codeql:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29  # v4.1.6 — pinned SHA

      - name: Initialize CodeQL
        uses: github/codeql-action/init@b611370bb5703a7efb587f9d136a52ea24c5c38c  # v3.25.11
        with:
          languages: javascript, python  # adjust to your stack
          queries: security-extended     # adds OWASP Top 10 queries

      - name: Build (required for compiled languages)
        run: npm ci  # or: make build, mvn compile, etc.

      - name: Perform CodeQL Analysis
        uses: github/codeql-action/analyze@b611370bb5703a7efb587f9d136a52ea24c5c38c
        with:
          category: /language:javascript
```

## Semgrep (extends existing opengrep-taint gate)

```yaml
  semgrep:
    runs-on: ubuntu-latest
    container:
      image: returntocorp/semgrep
    steps:
      - uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29

      - name: Run Semgrep OWASP + custom rules
        run: |
          semgrep scan \
            --config p/owasp-top-ten \
            --config p/nodejs-security \
            --config walteur-kit/ast-grep-rules/  \  # custom WALTEUR rules
            --json \
            --output walteur-kit/sast-report.json \
            --error  # exit 1 on any finding
```

## Fail Gates Configuration

```yaml
  fail-on-findings:
    needs: [codeql, semgrep]
    runs-on: ubuntu-latest
    steps:
      - name: Check SAST results
        run: |
          CRITICAL=$(cat walteur-kit/sast-report.json | jq '[.results[] | select(.extra.severity == "ERROR")] | length')
          if [ "$CRITICAL" -gt 0 ]; then
            echo "SAST FAIL: $CRITICAL critical findings block merge"
            exit 2
          fi
          echo "SAST PASS: no critical findings"
```

## Baseline and Noise Reduction

New-to-SAST projects will have hundreds of findings. Bootstrap strategy:
1. Run SAST in **audit mode** (no fail-gate) for 2 sprints
2. Tag existing findings as `// nosemgrep: rule-id` with JIRA ticket reference
3. Only NEW findings (introduced in current PR diff) block merge
4. Resolve baselined findings sprint by sprint

```bash
# Semgrep: scan only files changed in PR (diff-aware)
git diff --name-only origin/main...HEAD | xargs semgrep scan --config p/owasp-top-ten
```

## WALTEUR Integration

- SAST results feed `walteur-kit/sast-report.json`
- `/security` audit reads this alongside `security-report.json` (gitleaks) and `osv-report.json`
- Critical SAST findings → attack path citation:

> **Attack path [T1059.007]:** Untrusted user input at `src/api/eval.js:14` flows to `eval()` sink without sanitization [CodeQL: js/code-injection]. Absent mitigation: no input validation or allowlisting. Exploitability: HTTP POST with `{"code":"require('child_process').execSync('whoami')"}` gives RCE.
