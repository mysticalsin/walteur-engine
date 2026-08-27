# Container Escape Detection

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `detecting-container-escape-attempts`
**NIST CSF:** DE.CM-01, DE.AE-02 | **MITRE ATT&CK:** T1611, T1068, T1610
**Subdomain:** container-security

## Purpose

Detect container escape attempts — when an adversary breaks out of the container boundary to access the host OS or other containers. Container escape is a critical runtime attack that static scanning cannot prevent.

## Container Escape Techniques (ATT&CK T1611)

| Technique | How it works | Indicator |
|-----------|-------------|-----------|
| Privileged container + mount | `--privileged` container mounts host `/` | Container has `CAP_SYS_ADMIN`, mounts host devices |
| Docker socket mount | `/var/run/docker.sock` inside container → control host Docker daemon | Container accesses `/var/run/docker.sock` |
| Kernel exploit (CVE-2022-0847 DirtyPipe, etc.) | Exploit kernel vulnerability from within container | Unexpected privilege escalation, kernel error logs |
| Namespace escape | `unshare --pid` or `nsenter` from privileged container | `nsenter` / `unshare` execution from container PID |
| Writable host filesystem | Container with host path bind mount (`-v /:/hostfs`) | File writes to paths like `/etc/cron.d/` from container |
| runc vulnerability (CVE-2019-5736) | Overwrite runc binary from within container | Modification of container runtime binary |

## Detection Rules

### Falco (Runtime Security — preferred for production)

```yaml
# Install Falco: https://falco.org/docs/getting-started/
# Add to /etc/falco/falco_rules.local.yaml

- rule: Container Escape via Docker Socket Access
  desc: Container attempting to access Docker socket (can control host)
  condition: >
    container and
    evt.type=open and
    fd.name=/var/run/docker.sock
  output: >
    Container accessing Docker socket
    (user=%user.name container=%container.name image=%container.image.repository
     file=%fd.name pid=%proc.pid cmdline=%proc.cmdline)
  priority: CRITICAL
  tags: [container, privilege_escalation, T1611]

- rule: Privileged Container Execution
  desc: Container running in privileged mode
  condition: >
    container.privileged=true and
    evt.type=execve
  output: >
    Privileged container executing command
    (container=%container.name image=%container.image.repository
     cmdline=%proc.cmdline user=%user.name)
  priority: WARNING
  tags: [container, T1610]

- rule: nsenter or unshare from Container
  desc: Namespace escape attempt using nsenter or unshare
  condition: >
    container and
    evt.type=execve and
    (proc.name=nsenter or proc.name=unshare)
  output: >
    Namespace escape tool executed from container
    (container=%container.name cmdline=%proc.cmdline)
  priority: CRITICAL
  tags: [container, T1611]

- rule: Write to Host Sensitive Path from Container
  desc: Container writing to host paths that shouldn't be writable
  condition: >
    container and
    evt.type in (open, creat) and
    evt.is_open_write=true and
    fd.name pmatch (/etc/cron.d, /etc/cron.daily, /etc/sudoers.d, /etc/init.d)
  output: >
    Container writing to sensitive host path
    (container=%container.name image=%container.image.repository path=%fd.name)
  priority: CRITICAL
  tags: [container, persistence, T1611]
```

### Kubernetes Audit Log Rules (Sigma)

```yaml
title: Privileged Pod Creation in Kubernetes
logsource:
  product: kubernetes
  service: kube-apiserver
detection:
  selection:
    verb: create
    objectRef.resource: pods
    requestObject.spec.containers[].securityContext.privileged: 'true'
  condition: selection
level: high
tags:
  - attack.privilege_escalation
  - attack.t1610
```

## Prevention (Configuration)

```yaml
# Kubernetes Pod Security Standards (enforce restricted policy)
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.28

---
# Deny privileged containers via OPA/Gatekeeper
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sBlockPrivilegedContainers
metadata:
  name: block-privileged-containers
```

## Triage: Confirmed Container Escape Indicators

An escape is likely confirmed if you observe ALL THREE:
1. Container process accessing host namespace (`/proc/1/ns/` from container PID namespace)
2. New process on host with container's PID ancestry
3. Host file modification (new user in `/etc/passwd`, cron job, SSH key)

## WALTEUR Integration

Container escape findings from Falco or K8s audit → cite in `/security` report:
> **Attack path [T1611]:** Application container mounts `/var/run/docker.sock` at `containers[0].volumeMounts` in `k8s/deployment.yaml:34` → any process in the container can issue Docker API calls → create privileged container → access host filesystem → full host compromise. Absent mitigation: no PSP/PodSecurity blocking `docker.sock` mounts.
