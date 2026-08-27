# CI/CD Supply Chain Attack Detection

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `detecting-supply-chain-attacks-in-ci-cd`
**NIST CSF:** DE.CM-01, PR.PS-02 | **MITRE ATT&CK:** T1195.002, T1554, T1053

## Purpose

Scan GitHub Actions workflows and CI/CD pipeline configurations for indicators of supply chain attacks, including malicious action pinning, secret exfiltration patterns, and pipeline tampering. Directly relevant to WALTEUR's build pipeline.

## Attack Patterns to Detect

### 1. Unpinned GitHub Actions (SHA drift)

Risk: `actions/checkout@v3` resolves to whatever the tag points to today — an attacker who compromises the `actions` org can change the tag.

**Mitigation:** Pin ALL external actions to a full commit SHA:
```yaml
# VULNERABLE (mutable tag)
- uses: actions/checkout@v3

# SAFE (pinned SHA)
- uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29  # v4.1.6
```

**Detection:** grep for `uses: .*@v[0-9]` in `.github/workflows/` — any mutable tag is a finding.

### 2. Secret exfiltration via workflow step

Pattern: A step `curl`s or `wget`s data including `${{ secrets.* }}` to an external host.

```bash
# Scan workflows for potential secret exfiltration
grep -rE 'curl.*secrets\.|wget.*secrets\.' .github/workflows/
grep -rE '\$\{\{[[:space:]]*secrets\.' .github/workflows/ | grep -E 'curl|wget|nc |python|node'
```

### 3. Workflow injection via untrusted input

Risk: `${{ github.event.pull_request.title }}` is attacker-controlled — if used in a `run:` step, it's RCE.

```yaml
# VULNERABLE — PR title injected into shell
- run: echo "PR: ${{ github.event.pull_request.title }}"

# SAFE — use env variable to break injection
- env:
    PR_TITLE: ${{ github.event.pull_request.title }}
  run: echo "PR: $PR_TITLE"
```

**Detection:** `grep -rE '\$\{\{.*github\.event\.' .github/workflows/ | grep 'run:'`

### 4. Overly permissive workflow tokens

```yaml
# VULNERABLE — write-all allows pushing to main, creating releases
permissions:
  contents: write-all

# SAFE — minimal permissions
permissions:
  contents: read
  pull-requests: write
```

**Detection:** `grep -rE 'write-all|permissions: write' .github/workflows/`

### 5. Self-hosted runner poisoning

Risk: PRs from forks can trigger workflows on self-hosted runners → arbitrary code on your infra.

Check: `runs-on: self-hosted` + trigger `pull_request` (from forks) = high risk.

```bash
# Find workflows using self-hosted runners triggered by PRs
grep -l 'self-hosted' .github/workflows/ | xargs grep -l 'pull_request'
```

## WALTEUR Pipeline Audit Checklist

```bash
# Run all checks in one pass
echo "=== Unpinned actions ===" && grep -rE 'uses: .*@v[0-9]' .github/workflows/ | head -20
echo "=== Possible secret exfil ===" && grep -rE 'curl|wget' .github/workflows/ | grep 'secrets\.' | head -10
echo "=== Injection risks ===" && grep -rE '\$\{\{.*github\.event\.' .github/workflows/ | grep 'run:' | head -10
echo "=== Overpermissioned ===" && grep -rE 'write-all' .github/workflows/ | head -10
echo "=== Self-hosted + PR trigger ===" && for f in $(grep -l 'self-hosted' .github/workflows/); do grep -l 'pull_request' "$f" && echo "  ^ RISK: $f"; done
```

## WALTEUR Integration

- The `cicd-supply-chain-detection.md` patterns extend WALTEUR's `osv-gate.sh` to the pipeline config layer
- Any finding from the checklist above → cite as supply chain attack path in `/security` report:

> **Attack path [T1195.002]:** External contributor submits PR → workflow `build.yml` uses unpinned `actions/setup-node@v3` → if `actions` org compromised, arbitrary code executes in CI → secrets exfiltrated. Absent mitigation: no SHA pinning on external actions.
