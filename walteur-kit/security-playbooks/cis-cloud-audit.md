# CIS Benchmark Cloud Security Audit

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `auditing-cloud-with-cis-benchmarks`
**NIST CSF:** ID.AM-02, PR.IP-01, DE.CM-07 | **Standard:** CIS Benchmarks

## Purpose

Conduct cloud security audits using CIS Benchmark recommendations for AWS, Azure, and GCP. CIS Benchmarks are the industry baseline for cloud hardening — relevant for WALTEUR projects deploying to cloud infrastructure, and for the security floor check in `/security`.

## CIS Benchmark Levels

| Level | Meaning | Impact |
|-------|---------|--------|
| L1 | Essential security, minimal performance impact | Always apply |
| L2 | Defense-in-depth, may impact usability | Apply based on sensitivity |
| Automated | Machine-enforceable | Integrate into CI/policy |
| Manual | Requires judgment/architecture decision | Review quarterly |

## AWS CIS Benchmark Key Controls (v3.0)

### IAM (CIS AWS 1.x)

```bash
# 1.1 Avoid use of root account
aws iam generate-credential-report && aws iam get-credential-report --query 'Content' --output text | base64 -d | grep root

# 1.4 Ensure MFA is enabled for root
aws iam get-account-summary | jq '.SummaryMap.AccountMFAEnabled'
# Expected: 1

# 1.5 Ensure no access keys exist for root
aws iam list-access-keys --query 'AccessKeyMetadata[?UserName==`root`]'
# Expected: empty

# 1.14 Ensure hardware MFA for root
aws iam get-account-summary | jq '.SummaryMap.AccountMFAEnabled, .SummaryMap.AccountHardwareMFAEnabled'

# 1.15 Ensure IAM password policy
aws iam get-account-password-policy | jq '{MinLength:.PasswordPolicy.MinimumPasswordLength, RequireSymbols:.PasswordPolicy.RequireSymbols, MaxAge:.PasswordPolicy.MaxPasswordAge}'
```

### Logging (CIS AWS 3.x)

```bash
# 3.1 CloudTrail enabled in all regions
aws cloudtrail describe-trails --include-shadow-trails | jq '.trailList[] | {Name:.Name, IsMultiRegion:.IsMultiRegionTrail, LogValidation:.LogFileValidationEnabled}'

trail_name="${TRAIL_NAME:-example-trail}"

# 3.2 CloudTrail log file integrity validation
aws cloudtrail get-trail --name "$trail_name" | jq '.Trail.LogFileValidationEnabled'
# Expected: true

# 3.4 CloudTrail logs encrypted at rest
aws cloudtrail get-trail --name "$trail_name" | jq '.Trail.KMSKeyId'
# Expected: non-null

# 3.9 VPC flow logs enabled
aws ec2 describe-flow-logs --filter Name=resource-type,Values=VPC | jq '.FlowLogs[].FlowLogStatus'
```

### Networking (CIS AWS 5.x)

```bash
# 5.1 No security group allows unrestricted SSH (port 22) from 0.0.0.0/0
aws ec2 describe-security-groups \
  --query 'SecurityGroups[?IpPermissions[?FromPort<=`22` && ToPort>=`22` && IpRanges[?CidrIp==`0.0.0.0/0`]]].[GroupId,GroupName]' \
  --output table

# 5.2 No security group allows unrestricted RDP (port 3389) from 0.0.0.0/0
aws ec2 describe-security-groups \
  --query 'SecurityGroups[?IpPermissions[?FromPort<=`3389` && ToPort>=`3389` && IpRanges[?CidrIp==`0.0.0.0/0`]]].[GroupId,GroupName]' \
  --output table
```

## Automated CIS Audit Tools

```bash
# AWS: Prowler (open-source, covers CIS + other frameworks)
pip install prowler
prowler aws --compliance cis_aws_3.0 --output-formats json --output-directory walteur-kit/

# AWS: CloudSploit (AWS Config Rules)
# Enable in AWS Config: https://console.aws.amazon.com/config

# Azure: Microsoft Defender for Cloud (built-in CIS mapping)
az security assessment list --query "[?contains(name,'cis')]"

# GCP: Security Command Center (built-in CIS mapping)
gcloud scc findings list <organization-id> --filter="category=CIS_GCP*"
```

## Top 10 Cloud Misconfigs (CIS-aligned)

| # | Misconfiguration | Risk | Quick Fix |
|---|-----------------|------|----------|
| 1 | S3 bucket public read/write | Data exposure | `aws s3api put-bucket-acl --acl private` |
| 2 | Root account used / no MFA | Full account compromise | Enable MFA, create admin IAM user |
| 3 | Security group: 0.0.0.0/0 on 22/3389 | SSH/RDP brute force | Restrict to bastion or VPN IP |
| 4 | CloudTrail disabled | No audit trail | Enable multi-region trail with log validation |
| 5 | No VPC flow logs | No network visibility | Enable on all production VPCs |
| 6 | IAM user with console + programmatic access | Credential theft doubles risk | Separate service accounts from human users |
| 7 | EBS/RDS not encrypted at rest | Data exposure if snapshot stolen | Enable default encryption |
| 8 | No versioning on S3 state bucket | Terraform state corruption | Enable versioning + MFA delete |
| 9 | Secrets in Lambda env vars (unencrypted) | Plaintext credential exposure | Use Secrets Manager or Parameter Store |
| 10 | No GuardDuty / Defender enabled | No threat detection | Enable in all regions |

## WALTEUR Integration

Run CIS audit as part of cloud deployment review. Top misconfigs → cite in `/security` report:
> **Attack path [T1552.005]:** Lambda function `api-handler` has `DATABASE_PASSWORD=secret123` in plaintext environment variables (AWS Console visible to any IAM user with `lambda:GetFunction`). Absent mitigation: no Secrets Manager integration, no encryption of env vars at rest. Exploitability: any AWS console user or compromised CI role can read the credential.
