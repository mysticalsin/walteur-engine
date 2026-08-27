# Loop safety & guardrails — minimum bar for an unattended (L3) WALTEUR loop

> Adapted from loop-engineering `docs/safety.md` (MIT). These are the controls `loop-readiness-gate.sh`
> requires before a loop may run unattended. See [[walteur-gauntlet-self-improve]].

## Path denylist (never auto-edit without a human gate)
```
.env  .env.*  **/secrets/**  **/credentials/**  **/*_key*  **/*_secret*
.terraform/**  k8s/production/**  **/migrations/**  auth/**  payments/**  billing/**
```
WALTEUR enforces these surfaces fail-closed via `security-baseline`, `authz-tenant`, `supply-chain`,
`ci-hardening`, `agent-security`. The loop must escalate, not edit, when a change lands here.

## Auto-merge policy — **default: off**
Allowed only with an explicit allowlist (typo in comment/doc, lint-fix in test files, import ordering).
Never auto-merge: behavior changes, dependency/lockfile bumps, anything on the denylist.

## Human gates (required — interrupt by exception)
Security/authn/authz · payments/billing/PII · infra/Terraform/K8s-prod · dependency upgrades (supply chain) ·
changes touching >~10 files · the 3rd failed attempt on one item. Everything else: autonomous.

## MCP least-privilege
Read-broad, write-narrow; separate bot tokens with minimal scopes; no production DB write from a loop;
≤3–5 MCPs enabled (see [[context-economics]]). Prefer CLI+Skill over a write-everything MCP.

## Secrets in prompts & logs
Never paste keys into a scheduler/agent prompt. Redact CI logs before writing to state. State files are
committed — no credentials in `loop-state.json` / `STATE.md`. (`agent-security-gate` scans for secret-in-prompt.)

## Kill switch & incident response
**Kill switch:** drop `walteur-kit/PAUSED` → every gate exits 2; remove the next ScheduleWakeup → loop stops.
**If a loop ships bad output:** pause all → revert → record in `loop-state` + a story → tighten the verifier
or shrink scope before restart.

## Pre-flight L3 check (enforced by loop-readiness-gate)
- [ ] state file · [ ] maker/checker verifier · [ ] path denylist · [ ] token budget + run log · [ ] kill switch
- [ ] human gates documented · [ ] proven prior run (not just files on disk)

---
*Provenance: loop-engineering safety guardrails (MIT, Cobus Greyling / Addy Osmani).*
