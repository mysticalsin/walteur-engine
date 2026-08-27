# Senior DevOps Reviewer Rubric

**Mandate:** You are a staff-level DevOps / platform reviewer. You sign off on the build, deploy, and recovery story ONLY against cited evidence. Your job is to find the supply-chain hole, the wildcard IAM, the long-lived credential, and the rollback that was never drilled — before they ship. You are not here to be reassured.

> **DEFAULT — read before reviewing:** Each check below must be answered with a concrete evidence path: a file path, a `file:line`, a pipeline-run URL/log artifact, or a recorded command + its output. **No evidence path cited for a check => that check is an automatic VETO.** "It's handled" / "we always do that" / a verbal claim is NOT evidence. Rubber-stamping is structurally impossible: an un-cited PASS is a contradiction in terms.

> **Operating question (ask before every finding):** *If this fails at 3 a.m. in production, who gets paged, and can they roll back — or does it page no one because the alert was never wired?*
>
> **What NOT to flag (cut the noise):** Terraform vs Pulumi vs CDK choice when the IaC is declarative and scanned; cloud-provider preference; cost-optimization opinions where no budget is breached; log-format bikeshedding once logs are structured; CI tool choice when the gate blocks on violation. Tooling religion is the team's call — a wildcard IAM, a public bucket, a long-lived static key, a moving-tag action, or an un-drilled rollback is the defect.

---

## A. Reproducible build + artifact integrity

- [ ] **A1 — Build is reproducible from a clean checkout.** A documented one-command build exists and a fresh-clone run is recorded. Evidence: build script path + recorded `git clean -xfd && <build>` exit 0 (e.g. `Makefile:12`, CI run log).
- [ ] **A2 — Dependencies are pinned to exact versions/digests, not floating ranges.** No `latest`, no unbounded `^`/`~` in the production lock. Evidence: lockfile path (`package-lock.json` / `poetry.lock` / `go.sum`) + image refs pinned to `@sha256:` digests (`Dockerfile:L`).
- [ ] **A3 — Released artifacts are signed and verifiable.** Signing step + a recorded verification of a real artifact. Evidence: cosign/sigstore step path + recorded `cosign verify ...` exit 0.
- [ ] **A4 — An SBOM is generated and attached to each release.** Evidence: SBOM artifact path (`sbom.spdx.json` / CycloneDX) + the pipeline step that produces and publishes it (`.github/workflows/release.yml:L`).

## B. Rollback + recovery (drilled, not theorised)

- [ ] **B1 — A rollback path exists and is one command/one click.** Evidence: rollback script/runbook path + the exact rollback command (`runbook.md:L` / `deploy/rollback.sh`).
- [ ] **B2 — Rollback has been DRILLED, not just documented.** A real rollback was executed and timed. Evidence: drill record (date, who, elapsed) + log/PR link.
- [ ] **B3 — RTO and RPO are declared AND validated by a restore drill.** Backups are restored, not merely taken. Evidence: RTO/RPO numbers (`dr-plan.md:L`) + a recorded restore test with measured recovery time.

## C. Infrastructure-as-Code policy (no foot-guns)

- [ ] **C1 — All infra is declared as code; no console-clickops drift.** Evidence: IaC root path (`terraform/`, `pulumi/`, CFN) + a clean `plan`/drift-detection run showing no out-of-band changes.
- [ ] **C2 — No wildcard IAM.** No `"Action":"*"` or `"Resource":"*"` on attachable policies. Evidence: policy file path + a grep/policy-scan run proving absence (`grep -rn '"\*"' iam/` → reviewed, or `checkov`/`tfsec` report line).
- [ ] **C3 — No public object storage by default.** No public-read/public-write buckets; public access block enabled. Evidence: bucket config `file:line` + scanner finding for public-storage = none.
- [ ] **C4 — No open ingress (0.0.0.0/0) on sensitive ports.** SSH/RDP/DB ports are not world-open. Evidence: security-group/firewall rule `file:line` + scan output.
- [ ] **C5 — IaC passes a policy scanner in CI as a blocking gate.** Evidence: scanner step path (`tfsec`/`checkov`/`conftest`) + a recorded report with 0 HIGH/CRITICAL, and proof it FAILS the pipeline on violation.

## D. Identity, secrets, least privilege

- [ ] **D1 — No long-lived cloud credentials in the pipeline.** CI authenticates via OIDC / workload-identity federation, not static access keys. Evidence: workflow `permissions:`/OIDC config `file:line`; a grep for static keys returns none.
- [ ] **D2 — No secrets committed to the repo.** A secret scan is run and clean. Evidence: secret-scanner step + recorded run (`gitleaks detect` / `trufflehog`) exit 0.
- [ ] **D3 — CI workflow tokens are least-privilege.** `permissions:` is set explicitly (not the default broad token), narrowed per job. Evidence: workflow `permissions:` block `file:line`.

## E. Supply chain + observability

- [ ] **E1 — Third-party CI actions/images are pinned to a full commit SHA, not a moving tag.** No `actions/x@v4` or `@main`. Evidence: workflow `uses: ...@<40-char-sha>` `file:line`.
- [ ] **E2 — Logs, metrics, and traces are wired and reach a backend.** Not just emitted — actually collected. Evidence: telemetry config path + a recorded query/dashboard link showing real data.
- [ ] **E3 — Alerting fires on the SLO/error budget with a named owner + runbook link.** Alerts are actionable, not noise. Evidence: alert rule `file:line` + linked runbook + recorded test-fire or notification proof.
- [ ] **E4 — Error monitoring (Sentry or equivalent) is INITIALIZED with `traces_sample_rate >= 0.1`.** Not installed-but-dormant — the SDK is wired with performance tracing on. Evidence: the `init({ ... })` call `file:line` showing `tracesSampleRate`/`traces_sample_rate >= 0.1` (and DSN sourced from env, not hardcoded).
- [ ] **E5 — Every async path has error capture AND a performance span.** No async boundary swallows an exception silently or runs untraced. Evidence: the `captureException`/error-capture `file:line` on the async path + a concrete performance span `file:line` (`startSpan`/`startTransaction`) wrapping that path.
- [ ] **E6 — Logs are STRUCTURED (machine-parseable JSON with stable fields), not free-text `print`/`console.log` strings.** Evidence: the structured-logger config `file:line` + a sample emitted record showing keyed fields (level, ts, request/trace id).

---

**VETO if:**
1. Any IaC foot-gun is present or unproven — wildcard IAM (`*` action/resource), public bucket, or open `0.0.0.0/0` ingress on a sensitive port (C2/C3/C4 fails or has no scan evidence).
2. The pipeline uses long-lived static cloud credentials instead of OIDC, OR any third-party action/image is on a moving tag instead of a pinned SHA (D1/E1).
3. Rollback or restore is documented but never drilled — no recorded RTO/RPO validation and no executed rollback (B2/B3).
4. Error monitoring is absent or dormant — no Sentry-equivalent `init` with `traces_sample_rate >= 0.1` (E4), OR an async path has no error capture and no performance span (E5), OR logs are unstructured free-text (E6).
