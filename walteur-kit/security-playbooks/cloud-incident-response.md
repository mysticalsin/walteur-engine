# Cloud Incident Response (AWS / Azure / GCP)

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `conducting-cloud-incident-response`
**NIST CSF:** RS.MA-01, DE.AE-02 | **Subdomain:** incident-response, cloud-security

## Purpose

Respond to security incidents in cloud environments using identity-based containment (not network-based). Cloud IR differs from on-premises: VMs are ephemeral, network isolation is less reliable, and the primary attack surface is IAM credentials + API calls.

## Cloud IR Principles

1. **Identity is the perimeter** — contain by revoking credentials, not by blocking IPs
2. **Preserve evidence before containment** — snapshot EBS/disk, export CloudTrail logs to isolated S3
3. **Assume credential compromise first** — API keys and IAM roles are more common initial access than exploits
4. **Log everything** — CloudTrail (AWS) / Activity Log (Azure) / Cloud Audit (GCP) must be enabled before an incident; retroactive logging is impossible

## Workflow

### Step 1: Detect and Triage

Indicators of cloud compromise:
- Unusual IAM API calls: `CreateUser`, `AttachUserPolicy`, `CreateAccessKey` outside business hours
- Crypto-mining: high compute spend spike, unknown EC2/GCP instance types
- Exfiltration: `GetObject` on sensitive S3 buckets from unknown IP, large data transfer
- Lateral movement: access to multiple accounts/regions from a single credential
- Impossible travel: same credential used from 2 geographic regions within minutes

Triage query (AWS CloudTrail via Athena):
```sql
SELECT userIdentity.arn, sourceIPAddress, eventName, eventTime
FROM cloudtrail_logs
WHERE eventTime > '2026-01-01'
  AND eventName IN ('CreateUser','AttachUserPolicy','CreateAccessKey','PutBucketPolicy')
ORDER BY eventTime DESC
LIMIT 100;
```

### Step 2: Contain (identity-first)

**AWS:**
```bash
# Immediately revoke compromised access key
aws iam update-access-key --access-key-id AKIA... --status Inactive --user-name compromised-user

# Attach deny-all policy to compromised IAM user/role
aws iam put-user-policy --user-name compromised-user --policy-name EMERGENCY_DENY \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"*","Resource":"*"}]}'

# Snapshot EC2 instance for forensics BEFORE termination
aws ec2 create-snapshot --volume-id vol-xxxx --description "IR-snapshot-$(date +%Y%m%d)"
```

**Azure:**
```bash
# Disable compromised service principal
az ad sp update --id <app-id> --set accountEnabled=false

# Revoke all active sessions for compromised user
az ad user revoke-sign-in-sessions --id user@domain.com
```

### Step 3: Investigate

**Establish timeline:**
1. When was the credential created / last used legitimately?
2. First anomalous API call (timestamp from CloudTrail/Activity Log)
3. What resources were accessed/modified/created?
4. Was data exfiltrated? (S3 GetObject, storage blob reads, DB snapshots)

**Blast radius:**
- List all resources created by the compromised identity
- Check for new IAM users/roles/policies (attacker persistence)
- Check for new S3 buckets, EC2 instances, Lambda functions (crypto-mining, exfil staging)
- Review VPC flow logs for unusual outbound traffic

### Step 4: Eradicate

- Remove all attacker-created resources (IAM users, EC2 instances, buckets)
- Audit and remediate IAM policies that enabled the compromise (over-permissive policies)
- Rotate all credentials associated with the compromised service
- Enable CloudTrail / GuardDuty if not already active

### Step 5: Recover

- Restore from pre-incident snapshot or infrastructure-as-code (Terraform/CDK) for clean rebuild
- Apply principle of least privilege to all IAM policies post-incident
- Enable CloudTrail integrity validation and log archival to locked S3 bucket

## AWS-Specific Detection Queries

```bash
# List recent high-risk IAM events in the last 24h
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateAccessKey \
  --start-time $(date -d '24 hours ago' -u +%Y-%m-%dT%H:%M:%SZ)

# Find unusual cross-account role assumptions
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole
```

## WALTEUR Integration

Cloud incidents follow the same PICERL structure in `incident-response-playbook.md`.
Key difference: containment = IAM revocation, not network block. Document in `walteur-kit/audit.json`.
