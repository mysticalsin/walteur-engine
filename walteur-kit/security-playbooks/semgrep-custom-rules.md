# Semgrep Custom SAST Rules

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `implementing-semgrep-for-custom-sast-rules`
**NIST CSF:** PR.PS-01, DE.CM-04 | **Scope:** WALTEUR opengrep-taint extension

## Purpose

Write custom Semgrep rules in YAML to detect application-specific security anti-patterns that generic rulesets miss. Complements WALTEUR's existing `opengrep-taint` gate (which runs `p/owasp-top-ten` and `p/secrets`).

## Rule Structure

```yaml
rules:
  - id: rule-id-lowercase-dashes
    message: >
      Human-readable description of the vulnerability.
      Include: what the pattern does, why it's dangerous, how to fix.
    languages: [javascript, typescript]
    severity: ERROR        # ERROR / WARNING / INFO
    metadata:
      cwe: CWE-89          # CWE identifier
      owasp: A03:2021      # OWASP category
      confidence: HIGH     # HIGH / MEDIUM / LOW
    pattern: |
      # The code pattern to detect
      db.query($QUERY + ...)
    fix: |
      # Optional auto-fix suggestion
      db.query($QUERY, [...])
```

## Useful Pattern Constructs

| Construct | Meaning |
|-----------|---------|
| `$X` | Metavariable (matches any expression) |
| `...` | Ellipsis (matches any code in between) |
| `pattern-either` | OR — match any of several patterns |
| `pattern-inside` | Context constraint — only match inside a block |
| `pattern-not` | Exclude a sub-pattern |
| `taint` | Data flow from source to sink |

## High-Value Custom Rule Examples

### 1. SQL injection via string concatenation (Node/Express)

```yaml
rules:
  - id: sqli-string-concat
    message: SQL query built with string concatenation — use parameterized queries
    languages: [javascript, typescript]
    severity: ERROR
    metadata:
      cwe: CWE-89
      owasp: A03:2021
    pattern-either:
      - pattern: db.query("..." + $INPUT)
      - pattern: db.query(`...${$INPUT}...`)
      - pattern: pool.query("..." + $INPUT)
```

### 2. Hardcoded secrets

```yaml
rules:
  - id: hardcoded-api-key
    message: Potential hardcoded API key — use environment variables
    languages: [javascript, typescript, python]
    severity: ERROR
    metadata:
      cwe: CWE-798
      owasp: A02:2021
    pattern-either:
      - pattern: |
          $KEY = "sk-..."
      - pattern: |
          apiKey: "..."
      - pattern: |
          secret = "..."
```

### 3. Taint rule (user input → dangerous sink)

```yaml
rules:
  - id: user-input-to-exec
    message: User input flows to exec() / child_process — command injection risk
    languages: [javascript]
    severity: ERROR
    mode: taint
    metadata:
      cwe: CWE-78
      owasp: A03:2021
    pattern-sources:
      - pattern: req.body.$X
      - pattern: req.query.$X
      - pattern: req.params.$X
    pattern-sinks:
      - pattern: exec($INPUT)
      - pattern: execSync($INPUT)
      - pattern: spawn($INPUT, ...)
    pattern-sanitizers:
      - pattern: shellEscape($INPUT)
```

### 4. JWT algorithm confusion (none-algorithm attack)

```yaml
rules:
  - id: jwt-algorithm-none
    message: JWT verification without algorithm check — vulnerable to alg:none attack
    languages: [javascript, typescript]
    severity: ERROR
    metadata:
      cwe: CWE-327
    pattern: jwt.verify($TOKEN, $SECRET)
    pattern-not: jwt.verify($TOKEN, $SECRET, {algorithms: [...]})
```

## WALTEUR Rule Storage

Custom rules live in `walteur-kit/ast-grep-rules/` and are picked up by the existing `sgconfig.yml`.
To add a Semgrep rule:
1. Create `walteur-kit/ast-grep-rules/security/<rule-name>.yml`
2. Run: `semgrep scan --config walteur-kit/ast-grep-rules/ --test`
3. Add test cases to `walteur-kit/ast-grep-tests/`

## Noise Control

Too many findings → analysts stop reading. Tuning protocol:
- Start with `severity: ERROR` only for CI fail-gate
- `severity: WARNING` for informational tracking
- Use `// nosemgrep: rule-id` (with comment explaining why) for legitimate exceptions
- Review rule precision quarterly: if FP rate >20%, tighten the pattern
