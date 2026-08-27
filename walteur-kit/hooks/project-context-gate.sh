#!/usr/bin/env bash
# WALTEUR project-context-gate - hard proof for project-specific AI context and subagent handoffs.
#
# Contract:
#   - No project-context.json before plan                  => NOT_APPLICABLE, exit 0.
#   - Plan/build/verify/review/ship/reflect without proof  => FAIL, exit 2.
#   - PASS proof with generic context, missing rule files,
#     stale sources, budget drift, or broken handoffs       => FAIL, exit 2.
#
# Report:
#   walteur-kit/project-context-report.json
#
# Bypass:
#   WALTEUR_PROJECT_CONTEXT=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "project-context-gate - hard proof for project-specific AI context and subagent handoffs."
  printf '%s\n' "usage: bash project-context-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/project-context-report.json - fix recipes: walteur-kit/REMEDIATION.md (## project-context-gate)"
  printf '%s\n' "bypass: WALTEUR_PROJECT_CONTEXT=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

input_dir="${1:-}"
if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "$WALTEUR_ROOT" ]; then
  ROOT="$(cd "$WALTEUR_ROOT" && pwd)"
elif [ -n "$input_dir" ] && [ -d "$input_dir" ]; then
  ROOT="$(cd "$input_dir" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
KIT="$ROOT/walteur-kit"
STATE="$KIT/autopilot/STATE.json"
CTX="$KIT/project-context.json"
REPORT="$KIT/project-context-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_report() {
  verdict="$1"
  mode="$2"
  reason="$3"
  findings_json="${4:-[]}"
  if have jq; then
    jq -n \
      --arg v "$verdict" --arg ts "$TS" --arg mode "$mode" --arg reason "$reason" \
      --arg context_file "${CTX#"$ROOT"/}" --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"project-context-gate", mode:$mode, project_context_file:$context_file, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"project-context-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0\n'
}

file_bytes() {
  wc -c < "$1" 2>/dev/null | tr -d '[:space:]'
}

file_lines() {
  wc -l < "$1" 2>/dev/null | tr -d '[:space:]'
}

detect_required() {
  CONTEXT_REQUIRED=0
  CONTEXT_REQUIRED_REASON=""

  if [ "${WALTEUR_PROJECT_CONTEXT_REQUIRED:-}" = "1" ]; then
    CONTEXT_REQUIRED=1
    CONTEXT_REQUIRED_REASON="WALTEUR_PROJECT_CONTEXT_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      plan|build|verify|review|ship|reflect)
        CONTEXT_REQUIRED=1
        CONTEXT_REQUIRED_REASON="STATE.phase=$phase"
        return 0 ;;
    esac
  fi
}

resolve_ref() {
  ref="$1"
  ref_file="${ref%%#*}"
  [ -n "$ref_file" ] || return 1
  case "$ref_file" in
    /*)
      case "$ref_file" in "$ROOT"/*) printf '%s\n' "$ref_file"; return 0 ;; *) return 1 ;; esac ;;
    *..*) return 1 ;;
    *) printf '%s\n' "$ROOT/$ref_file"; return 0 ;;
  esac
}

check_ref() {
  label="$1"
  ref="$2"
  path="$(resolve_ref "$ref" 2>/dev/null || true)"
  if [ -z "$path" ]; then
    add_finding "$label" "$label must be a relative path inside the project"
    return 0
  fi
  [ -f "$path" ] || add_finding "$label" "$label points to missing file: $ref"
}

scan_placeholders() {
  label="$1"
  file="$2"
  hits="$(grep -Eio 'TODO|TBD|FIXME|placeholder|lorem ipsum|follow best practices|best practices|<[^>]+>' "$file" 2>/dev/null | head -5 | paste -sd ' | ' -)"
  [ -n "$hits" ] && add_finding "$label" "$label contains generic placeholder text: $hits"
}

latest_context_source_mtime() {
  latest=0
  update_latest() {
    f="$1"
    [ -f "$f" ] || return 0
    case "$f" in "$REPORT"|"$CTX") return 0 ;; esac
    mt="$(mtime "$f")"
    [ "${mt:-0}" -gt "$latest" ] && latest="$mt"
  }

  update_latest "$ROOT/PLAN.md"
  update_latest "$KIT/PRD.md"
  update_latest "$KIT/current-stack.json"
  update_latest "$KIT/delivery-orchestration.json"
  update_latest "$KIT/build-contract.json"
  update_latest "$STATE"
  printf '%s\n' "$latest"
}

selftest() {
  pass=0
  fail=0

  ck() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  if ! have jq; then
    echo "project-context-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    root="$1"
    phase="$2"
    mkdir -p "$root/walteur-kit/autopilot"
    jq -n --arg phase "$phase" '{phase:$phase}' > "$root/walteur-kit/autopilot/STATE.json"
  }

  write_good_context() {
    root="$1"
    mkdir -p "$root/.claude/rules" "$root/_relay" "$root/walteur-kit/evidence" "$root/walteur-kit/handoffs" "$root/src"
    printf '# Plan\nBuild the support dashboard.\n' > "$root/PLAN.md"
    printf 'export function formatTicket(id: string) { return id.trim(); }\n' > "$root/src/tickets.ts"
    cat > "$root/AGENTS.md" <<'EOF'
# AGENTS.md - Support Dashboard

## 1. Project overview
Support agents triage tickets with a p95 search target under 120 ms.

## 2. Build / test / run commands
```bash
pnpm install
pnpm dev
pnpm test
pnpm test src/tickets.test.ts
pnpm lint
```

## 3. Code style
Use typed helpers for ticket identifiers.

```ts
export function formatTicket(id: string) { return id.trim(); }
```

## 4. Testing
- Framework: Vitest
- File naming: `*.test.ts`
- Golden rule: ticket parsing gets a fixture test.

## 5. Security
- Never log ticket descriptions.
- Validate ticket identifiers before API calls.

## 6. Commit / PR
- Commit format: `feat(scope): subject`
- PR: one concern with tests green.
EOF
    cat > "$root/CLAUDE.md" <<'EOF'
# CLAUDE.md - Support Dashboard

@AGENTS.md

## Claude-specific notes
- Use Playwright only after the dev server is running.
EOF
    cat > "$root/.claude/rules/testing.md" <<'EOF'
# Rule - ticket parsing

## The rule
Every ticket parser change includes a fixture test.

## Why
The support dashboard routes work from parsed ticket identifiers.

## Example
```ts
formatTicket(" T-123 ")
```

## Verification
pnpm test src/tickets.test.ts
EOF
    printf 'rule evidence\n' > "$root/walteur-kit/evidence/rule.md"
    printf 'handoff artifact\n' > "$root/walteur-kit/handoffs/frontend.md"
    printf 'handoff validation\n' > "$root/walteur-kit/evidence/handoff-check.txt"
    printf 'baton ready\n' > "$root/_relay/BATON.md"
    agents_bytes="$(file_bytes "$root/AGENTS.md")"
    claude_lines="$(file_lines "$root/CLAUDE.md")"
    jq -n \
      --argjson agents_bytes "$agents_bytes" \
      --argjson claude_lines "$claude_lines" \
      '{
        schema_version: 1,
        verdict: "PASS",
        generated_context: {
          agents_ref: "AGENTS.md",
          claude_ref: "CLAUDE.md",
          relay_ref: "_relay/BATON.md",
          source_refs: ["PLAN.md"],
          rules: [
            {
              path: ".claude/rules/testing.md",
              why_specific: "Ticket parsing is the dashboard routing boundary.",
              evidence_ref: "walteur-kit/evidence/rule.md",
              verification: "pnpm test src/tickets.test.ts"
            }
          ]
        },
        subagent_handoffs: [
          {
            from: "frontend",
            to: "qa",
            artifact_ref: "walteur-kit/handoffs/frontend.md",
            validation_ref: "walteur-kit/evidence/handoff-check.txt",
            baton_ref: "_relay/BATON.md",
            status: "planned"
          }
        ],
        context_budget: {
          max_agents_bytes: 32768,
          max_claude_lines: 200,
          actual_agents_bytes: $agents_bytes,
          actual_claude_lines: $claude_lines
        },
        specificity: {
          commands_verified: true,
          snippets_from_project: true,
          generic_rules_removed: true,
          no_placeholders: true
        },
        freshness: {
          source_refs: ["PLAN.md"],
          generated_at: "2026-06-22T00:00:00Z"
        },
        ts: "2026-06-22T00:00:00Z"
      }' > "$root/walteur-kit/project-context.json"
  }

  echo "project-context-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/project-context-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "no context before plan -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/project-context-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "plan phase missing project-context -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/project-context-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{ bad json\n' > "$tmp/walteur-kit/project-context.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "malformed context -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/project-context-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_good_context "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "complete project context -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/project-context-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_good_context "$tmp"
  rm -f "$tmp/AGENTS.md"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "missing AGENTS.md -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/project-context-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_good_context "$tmp"
  printf '\nFollow best practices.\n' >> "$tmp/AGENTS.md"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "generic AGENTS.md text -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/project-context-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_good_context "$tmp"
  rm -f "$tmp/walteur-kit/handoffs/frontend.md"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "missing subagent handoff artifact -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/project-context-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_good_context "$tmp"
  jq '.context_budget.actual_agents_bytes = 1' "$tmp/walteur-kit/project-context.json" > "$tmp/ctx.json" && mv "$tmp/ctx.json" "$tmp/walteur-kit/project-context.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "context budget mismatch -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/project-context-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  write_good_context "$tmp"
  jq '.subagent_handoffs = []' "$tmp/walteur-kit/project-context.json" > "$tmp/ctx.json" && mv "$tmp/ctx.json" "$tmp/walteur-kit/project-context.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "zero subagent handoffs -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "project-context-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && {
  write_report "FAIL" "paused" "walteur-kit/PAUSED present" '[{"check":"paused","message":"WALTEUR is paused"}]'
  echo "project-context-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
}

if [ "${WALTEUR_PROJECT_CONTEXT:-on}" = "off" ]; then
  write_report "SKIP" "bypass" "WALTEUR_PROJECT_CONTEXT=off" "[]"
  echo "project-context-gate verdict: SKIP - bypassed via WALTEUR_PROJECT_CONTEXT=off -> $REPORT" >&2
  exit 0
fi

if ! have jq; then
  write_report "SKIP" "tool-missing" "jq not installed" "[]"
  echo "project-context-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  exit 0
fi

detect_required

if [ ! -f "$CTX" ]; then
  if [ "$CONTEXT_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "missing" "project context proof required ($CONTEXT_REQUIRED_REASON) but walteur-kit/project-context.json is absent" \
      '[{"check":"project_context.present","message":"plan and later phases require walteur-kit/project-context.json shaped by walteur-kit/schemas/project-context.schema.json"}]'
    echo "project-context-gate verdict: FAIL - proof missing while required ($CONTEXT_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "not-applicable" "no project context proof and current phase does not require one" "[]"
  echo "project-context-gate verdict: NOT_APPLICABLE - no proof before plan -> $REPORT" >&2
  exit 0
fi

if [ ! -s "$CTX" ]; then
  if [ "$CONTEXT_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "empty" "project context proof required ($CONTEXT_REQUIRED_REASON) but walteur-kit/project-context.json is empty" \
      '[{"check":"project_context.nonempty","message":"zero-byte project-context stubs cannot satisfy plan or later phases"}]'
    echo "project-context-gate verdict: FAIL - empty proof while required ($CONTEXT_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "runtime-stub" "zero-byte runtime project-context stub before plan" "[]"
  echo "project-context-gate verdict: NOT_APPLICABLE - zero-byte runtime stub before plan -> $REPORT" >&2
  exit 0
fi

if ! jq empty "$CTX" >/dev/null 2>&1; then
  write_report "FAIL" "invalid-json" "walteur-kit/project-context.json is invalid JSON" \
    '[{"check":"project_context.json","message":"walteur-kit/project-context.json must be valid JSON"}]'
  echo "project-context-gate verdict: FAIL - project-context JSON invalid -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

if ! jq -e '.schema_version == 1' "$CTX" >/dev/null 2>&1; then
  add_finding "schema_version" "schema_version must be 1"
fi
if ! jq -e '.verdict == "PASS"' "$CTX" >/dev/null 2>&1; then
  add_finding "verdict" "project context verdict must be PASS"
fi

agents_ref="$(jq -r '.generated_context.agents_ref // empty' "$CTX")"
claude_ref="$(jq -r '.generated_context.claude_ref // empty' "$CTX")"
relay_ref="$(jq -r '.generated_context.relay_ref // empty' "$CTX")"

check_ref "generated_context.agents_ref" "$agents_ref"
check_ref "generated_context.claude_ref" "$claude_ref"
check_ref "generated_context.relay_ref" "$relay_ref"

agents_path="$(resolve_ref "$agents_ref" 2>/dev/null || true)"
claude_path="$(resolve_ref "$claude_ref" 2>/dev/null || true)"

if [ -n "$agents_path" ] && [ -f "$agents_path" ]; then
  agents_bytes="$(file_bytes "$agents_path")"
  [ "${agents_bytes:-0}" -le 32768 ] || add_finding "AGENTS.md.size" "AGENTS.md must stay <= 32768 bytes"
  for heading in "## 1. Project overview" "## 2. Build / test / run commands" "## 3. Code style" "## 4. Testing" "## 5. Security" "## 6. Commit / PR"; do
    grep -qF "$heading" "$agents_path" || add_finding "AGENTS.md.sections" "AGENTS.md missing required section: $heading"
  done
  scan_placeholders "AGENTS.md" "$agents_path"
  actual_agents="$(jq -r '.context_budget.actual_agents_bytes // -1' "$CTX")"
  [ "$actual_agents" = "$agents_bytes" ] || add_finding "context_budget.actual_agents_bytes" "actual_agents_bytes must equal AGENTS.md byte count ($agents_bytes)"
fi

if [ -n "$claude_path" ] && [ -f "$claude_path" ]; then
  claude_lines="$(file_lines "$claude_path")"
  [ "${claude_lines:-9999}" -le 200 ] || add_finding "CLAUDE.md.lines" "CLAUDE.md must stay <= 200 lines"
  grep -q '@AGENTS.md' "$claude_path" || add_finding "CLAUDE.md.import" "CLAUDE.md must import @AGENTS.md instead of duplicating context"
  scan_placeholders "CLAUDE.md" "$claude_path"
  actual_claude="$(jq -r '.context_budget.actual_claude_lines // -1' "$CTX")"
  [ "$actual_claude" = "$claude_lines" ] || add_finding "context_budget.actual_claude_lines" "actual_claude_lines must equal CLAUDE.md line count ($claude_lines)"
fi

if ! jq -e '.generated_context.rules | type == "array" and length > 0' "$CTX" >/dev/null 2>&1; then
  add_finding "generated_context.rules" "at least one project-specific .claude/rules file is required"
fi
while IFS=$'\t' read -r rule_path why evidence verification; do
  [ -n "$rule_path" ] || continue
  case "$rule_path" in
    .claude/rules/*.md) : ;;
    *) add_finding "generated_context.rules.path" "rule path must live under .claude/rules/*.md: $rule_path" ;;
  esac
  [ -n "$why" ] || add_finding "generated_context.rules.why_specific" "rule $rule_path needs a why_specific explanation"
  [ -n "$verification" ] || add_finding "generated_context.rules.verification" "rule $rule_path needs a verification command or check"
  check_ref "generated_context.rules.$rule_path.path" "$rule_path"
  check_ref "generated_context.rules.$rule_path.evidence_ref" "$evidence"
  rule_abs="$(resolve_ref "$rule_path" 2>/dev/null || true)"
  [ -n "$rule_abs" ] && [ -f "$rule_abs" ] && scan_placeholders "rule.$rule_path" "$rule_abs"
done <<EOF
$(jq -r '.generated_context.rules[]? | [(.path // ""), (.why_specific // ""), (.evidence_ref // ""), (.verification // "")] | @tsv' "$CTX")
EOF

for selector in '.generated_context.source_refs[]?' '.freshness.source_refs[]?'; do
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    check_ref "source_ref" "$ref"
  done < <(jq -r "$selector" "$CTX")
done

if ! jq -e '.subagent_handoffs | type == "array" and length > 0' "$CTX" >/dev/null 2>&1; then
  add_finding "subagent_handoffs" "at least one subagent or specialist handoff proof is required"
fi
while IFS=$'\t' read -r from_id to_id artifact validation baton status; do
  [ -n "$from_id" ] || continue
  [ -n "$to_id" ] || add_finding "subagent_handoffs.to" "handoff from $from_id needs a destination"
  case "$status" in planned|completed|blocked) : ;; *) add_finding "subagent_handoffs.status" "handoff $from_id->$to_id has invalid status: $status" ;; esac
  check_ref "subagent_handoffs.artifact_ref" "$artifact"
  check_ref "subagent_handoffs.validation_ref" "$validation"
  check_ref "subagent_handoffs.baton_ref" "$baton"
done <<EOF
$(jq -r '.subagent_handoffs[]? | [(.from // ""), (.to // ""), (.artifact_ref // ""), (.validation_ref // ""), (.baton_ref // ""), (.status // "")] | @tsv' "$CTX")
EOF

if ! jq -e '.context_budget.max_agents_bytes <= 32768 and .context_budget.max_claude_lines <= 200 and .context_budget.actual_agents_bytes <= .context_budget.max_agents_bytes and .context_budget.actual_claude_lines <= .context_budget.max_claude_lines' "$CTX" >/dev/null 2>&1; then
  add_finding "context_budget" "context budget must keep AGENTS.md <=32 KiB and CLAUDE.md <=200 lines"
fi

if ! jq -e '.specificity.commands_verified == true and .specificity.snippets_from_project == true and .specificity.generic_rules_removed == true and .specificity.no_placeholders == true' "$CTX" >/dev/null 2>&1; then
  add_finding "specificity" "specificity checks must all be true"
fi

json_placeholder_hits="$(jq -r '
  .. | strings
  | select(test("(^|\\b)(TODO|TBD|FIXME|placeholder|lorem ipsum|follow best practices|best practices)(\\b|$)|<[^>]+>"; "i"))
' "$CTX" 2>/dev/null | head -5 | paste -sd ' | ' -)"
[ -n "$json_placeholder_hits" ] && add_finding "project_context.placeholder" "project-context.json contains placeholder or generic text: $json_placeholder_hits"

ctx_mtime="$(mtime "$CTX")"
latest_mtime="$(latest_context_source_mtime)"
if [ "${latest_mtime:-0}" -gt "${ctx_mtime:-0}" ]; then
  add_finding "freshness" "project-context.json is older than PLAN/PRD/current-stack/delivery/state source artifacts"
fi

if ! jq -e '.ts | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$CTX" >/dev/null 2>&1; then
  add_finding "ts" "ts must be UTC ISO format YYYY-MM-DDTHH:MM:SSZ"
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "strict project-context contract failed with $failures finding(s)" "$findings"
  echo "project-context-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "pass" "project context, context budget, baton, rules, and subagent handoffs are proven" "$findings"
echo "project-context-gate verdict: PASS - project context proof complete -> $REPORT" >&2
exit 0
