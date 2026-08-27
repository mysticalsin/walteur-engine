# WALTEUR Project-Context Generator Spec
> CURATED-GENERATED — derived from the real PLAN/PRD/stack/DESIGN, then human-reviewable.
> Research finding: generic auto-generated context HURTS (lower success, higher cost). Every rule must pass: "would removing this cause a mistake on THIS project specifically?" If generic, omit it.

---

## What gets generated (per project, once, at scaffold time)

| File | Reader | Hard cap | Purpose |
|------|--------|----------|---------|
| `AGENTS.md` | Every AI tool (Linux Foundation agents.md standard; read natively by 30+ tools) | 32 KiB | Project ground truth — build/test/run commands, code style, testing, security, commit/PR |
| `CLAUDE.md` | Claude Code | 200 lines | Imports `@AGENTS.md` + Claude-specific advisory bits only |
| `.claude/rules/*.md` | Claude Code (per-rule, per-session) | — | Stack-specific rules; each ≥1 real code snippet |

---

## AGENTS.md — 6 required sections

```markdown
# AGENTS.md — <project name>
> Cross-tool AI context (Linux Foundation / agents.md standard). Specific to this project.

## 1. Project overview
<2–3 sentences: what it does, the one success metric, the primary user.>

## 2. Build / test / run commands
<!-- THE REAL COMMANDS for this specific project — not generic placeholders. -->
```bash walteur:skip
# Install
<exact install command>

# Run (dev)
<exact dev command>

# Test (all)
<exact test command>

# Test (single file/function — the fast inner loop)
<exact fast-test command>

# Lint / format
<exact lint command>
```

## 3. Code style
<!-- Stack-specific. Include ≥1 real snippet showing the pattern. -->
- <convention 1 specific to this stack>
- <convention 2>

```<lang>
// Real snippet showing the idiom — one pattern worth more than a paragraph.
<concrete example from THIS project's stack>
```

## 4. Testing
<!-- What the test strategy IS on this project: framework, file naming, fixture location. -->
- Framework: <name>
- File naming: <pattern>
- Golden rule: <the one test discipline that matters most here>

## 5. Security
<!-- Hard rules for THIS stack: secrets handling, auth pattern, input validation. -->
- <security rule 1 specific to stack>
- <security rule 2>

## 6. Commit / PR
- Commit format: `<type>(<scope>): <subject>` (conventional commits)
- PR: one concern per PR; tests green; AGENTS.md updated if conventions change
```

**Anti-slop checklist (run before finalizing):**
- [ ] Every command is the REAL command (not `npm test` if the project uses `pnpm run test:ci`)
- [ ] Code snippet is from THIS project's stack (not a Hello World)
- [ ] No section says "follow best practices" without naming the specific practice
- [ ] No rule that would apply equally to any project (if yes → delete it)
- [ ] Commands verified to exist in package.json / Makefile / pyproject.toml
- [ ] Current: no deprecated APIs, no stale version pins

---

## CLAUDE.md — structure

```markdown
# CLAUDE.md — <project name>
<!-- ≤200 lines. Imports AGENTS.md. Adds ONLY Claude-specific bits. -->

@AGENTS.md

## Claude-specific notes
<!-- Only things Claude needs that other tools don't: -->
- <e.g., "Use the Playwright MCP for any browser interaction — never describe, always verify">
- <e.g., "The types/ dir is generated — never edit directly">
- <e.g., "Run `make lint` before proposing any change — it auto-fixes style">

<!-- Hard invariants (things that should never happen) belong in hooks/settings, NOT here. -->
<!-- If you're writing "always do X" or "never do Y" → ask: is this a hook? If yes, put it there. -->
```

**Size discipline:** CLAUDE.md that is just AGENTS.md re-stated = noise. If a line in CLAUDE.md already appears in AGENTS.md, delete it.

---

## .claude/rules/*.md — rule file structure

Each rule file covers ONE concern. Required sections:

```markdown
# Rule — <name> (<stack>-specific)

## The rule
<1 sentence: what must always / never happen>

## Why (specific to this project)
<1–2 sentences: what breaks if you violate this on THIS project specifically>

## Example (real snippet)
```<lang>
// GOOD — the pattern to follow
<real code snippet from this project's stack>

// BAD — what to avoid
<real anti-pattern>
```

## Verification
<how to check compliance: a command, a grep, a test name>
```

**Standard rule files to generate per archetype:**

| Archetype | Rule files |
|-----------|-----------|
| ai-app | `code-style.md` (async/typing), `testing.md` (evals-first, golden dataset), `prompts.md` (registry, versioning) |
| web-app | `code-style.md` (TypeScript strict, no `any`), `testing.md` (story coverage), `design.md` (design-gate contract) |
| cli | `code-style.md` (exit codes, stderr/stdout discipline), `testing.md` (fixture-based) |
| cloud-iac | `code-style.md` (no hardcoded secrets, tag every resource), `testing.md` (terratest), `compliance.md` (tfsec/checkov) |

**Per-project additions:** if the PLAN mentions a specific constraint (rate limits, PII, external API contract), generate a rule for it. A rule about `never use X pattern` that appeared in the PLAN's risk section is worth more than 5 generic style rules.

---

## Generation algorithm (the scaffold's inner loop)

```
inputs: PLAN.md + PRD.md (if exists) + scope.stack + DESIGN.md (if exists)

1. Read PLAN.md → extract: stack, key files, test framework, build commands
2. Read PRD.md → extract: success metric, primary user, out-of-scope constraints
3. Detect archetype via archetypes.md stack-detection table
4. Generate AGENTS.md:
   - §2 commands: grep package.json/Makefile/pyproject.toml for REAL commands
   - §3 style: pick the 2–3 idioms the PLAN uses most (TypeScript? async def? struct tags?)
   - §4 testing: name the framework + file naming convention actually in PLAN.md
   - §5 security: name the security constraints that appear in PRD.md / scope
   - Apply anti-slop checklist before finalizing
5. Generate CLAUDE.md: @AGENTS.md + Claude-specific notes only (≤200 lines)
6. Generate .claude/rules/: one per archetype standard + one per PLAN risk/constraint
7. Ensure _relay/ wired: BATON.md exists + mentions AGENTS.md path
```

---

## Honest contract

- Generated context is a STARTING POINT, not a finished product. A human reviews before committing.
- The generator must never fabricate commands — if a command can't be read from the project files, it writes `# TODO: fill in — could not detect from PLAN.md`.
- Rule files that don't pass the "would removing this cause a mistake on THIS project specifically?" test are NOT generated.
- Hard invariants (things enforced mechanically) go to hooks/settings.json, not CLAUDE.md prose.

*Provenance: research finding on generic LLM context degrading agent success rate, synthesized from dotclaude/everything-claude-code + agents.md Linux Foundation standard + WALTEUR §1 honesty law.*
