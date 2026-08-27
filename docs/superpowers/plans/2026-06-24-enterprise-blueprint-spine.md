# Enterprise Blueprint Spine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an enterprise-blueprint spine that makes WALTEUR's initial build target richer and more concrete.

**Architecture:** Add one typed artifact, one gate, one schema, two examples, and narrow docs/scaffold/registry updates. The gate follows existing shell-hook conventions and writes `walteur-kit/enterprise-blueprint-report.json`.

**Tech Stack:** Bash, jq, JSON Schema, Markdown docs, existing WALTEUR selftest harness.

## Global Constraints

- No new package dependency.
- Keep the gate shell-only plus jq, matching existing hooks.
- Missing proof is not green proof.
- No field-mile claim.
- Update aggregate selftest and release truth after verification.

---

### Task 1: Red test for missing gate coverage

**Files:**
- Modify: `walteur-kit/selftest.sh`

**Interfaces:**
- Consumes: existing `ck` helper and hook selftest pattern.
- Produces: an aggregate assertion for `enterprise-blueprint-gate.sh --selftest`.

- [ ] Add an aggregate selftest line for `enterprise-blueprint-gate.sh --selftest` next to the plan/product gates.
- [ ] Run `bash walteur-kit/selftest.sh` and confirm it fails because the hook is missing.

### Task 2: Add schema, examples, and gate

**Files:**
- Create: `walteur-kit/schemas/enterprise-blueprint.schema.json`
- Create: `walteur-kit/examples/enterprise-blueprint.good.json`
- Create: `walteur-kit/examples/enterprise-blueprint.vague.json`
- Create: `walteur-kit/hooks/enterprise-blueprint-gate.sh`

**Interfaces:**
- Consumes: `walteur-kit/enterprise-blueprint.json`.
- Produces: `walteur-kit/enterprise-blueprint-report.json`.

- [ ] Write schema with required non-empty top-level sections.
- [ ] Write good and vague example fixtures.
- [ ] Implement hook with `--selftest` covering not-applicable, missing, good pass, vague fail, restated goal fail, missing explicit cuts fail, fake evidence fail, and placeholder fail.
- [ ] Run `bash walteur-kit/hooks/enterprise-blueprint-gate.sh --selftest` and confirm pass.

### Task 3: Register and scaffold the blueprint

**Files:**
- Modify: `walteur-kit/gate-registry.json`
- Modify: `walteur-kit/scaffold/harness-init.sh`

**Interfaces:**
- Consumes: registry selection logic already used by `harness-init.sh`.
- Produces: selected verification command coverage and generated `enterprise-blueprint.json`.

- [ ] Add gate registry entry and add the gate to selected requirements.
- [ ] Update scaffold comments and generated file list.
- [ ] Generate first-pass `enterprise-blueprint.json` after build contract creation.
- [ ] Add the gate to bootstrap-safe run list.
- [ ] Run scaffold selftest if available and validate generated JSON with jq.

### Task 4: Documentation and release truth

**Files:**
- Modify: `walteur-kit/HARNESS-LOOP.md`
- Modify: `walteur-kit/README.md`
- Modify: `README.md`
- Modify: `walteur/SKILL.md`
- Modify: `walteur-kit/release-ledger.json`

**Interfaces:**
- Consumes: new gate, schema, report, and aggregate proof count.
- Produces: documented v9.78 release truth.

- [ ] Document the Enterprise Blueprint Contract.
- [ ] Add new file descriptions to README tables.
- [ ] Add v9.78 changelog line without overstating field proof.
- [ ] Update release ledger expected aggregate count after verification.

### Task 5: Verify and review

**Files:**
- Read: `walteur-kit/selftest-report.json`
- Read: `git diff`

**Interfaces:**
- Consumes: all modified files.
- Produces: proof for final report.

- [ ] Run `bash walteur-kit/hooks/enterprise-blueprint-gate.sh --selftest`.
- [ ] Run `jq empty` on new JSON files.
- [ ] Run `bash walteur-kit/selftest.sh`.
- [ ] Read selftest report and confirm expected pass/fail/skip counts.
- [ ] Review `git diff` for accidental broad changes.
