#!/usr/bin/env bash
# WALTEUR ai-safety-gate — HARD gate (exit 2) on TWO VETO rules from the senior-ai rubric.
#
# WHY: AI/agent builds with no prompt-injection test corpus and/or unbounded agent loops are
# structurally unsafe at ship time. This gate makes both properties machine-checkable at every
# ship attempt, not just at manual review.
#
# RULES ENFORCED (exactly the VETO conditions in walteur-kit/rubrics/senior-ai.md):
#   R2 = rubric B3 — a prompt-injection TEST CORPUS must exist.
#        VETO if an AI-build has no corpus (tests/injection/*, **/*.injection.json,
#        **/injection/*.json, or a fixtures/injection/ directory).
#   R1 = rubric C2 — every agent loop must have a hard, model-INDEPENDENT termination cap.
#        VETO if an agent-loop source file exists with none of the cap signals.
#        (NA if no agent-loop file is found — the rule only fires when a loop is detected.)
#   R3 = model-pin freshness — a Claude/Anthropic model ID must NOT be hardcoded as a source
#        literal; it must be env-sourced or config-sourced.
#        VETO if an AI-build source file contains a hardcoded claude-* model literal that is
#        not inside an env/config read expression — UNLESS a dated attestation exists in
#        walteur-kit/layers.json key "ai-safety-R3".
#        (Only fires on builds already detected as AI/Anthropic SDK builds — §16 safety.
#         R3 itself contains NO hardcoded model ID — it polices the PATTERN, not a specific
#         version, so the gate does not rot like the thing it polices.)
#
# NOT ENFORCED here: C1 (abstention) — it is NOT a rubric VETO and is false-positive-prone;
# it stays in the Opus audit (PROTOCOL), not in this hard gate.
#
# APPLICABILITY: same AI/agent signals as tool-contract-lint.sh — fires on exactly the same
# builds, and exits 0 as NOT_APPLICABLE on every non-AI build.
#
# Bypass: WALTEUR_AISAFE=off => write SKIP report, exit 0.
# Kill switch: walteur-kit/PAUSED present => exit 2.
# Per-rule signed deferral: walteur-kit/layers.json key "ai-safety-R1", "ai-safety-R2",
#   or "ai-safety-R3" with value "deferred:<reason>" or "pass" waives that rule for this project.
#
# Report: walteur-kit/ai-safety-report.json {verdict, ts, gate, rules:[{rule, result, evidence}]}.
# Zero-dep: bash + grep + find + (jq optional for report). HARD: real exit 2 on any VETO.
# HONESTY: corpus check is PRESENCE-based (a found corpus file passes; its content quality
#          stays in PROTOCOL). Loop-cap check is a GENEROUS heuristic (any cap signal passes;
#          correctness of the cap value stays in PROTOCOL).
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "ai-safety-gate - HARD gate (exit 2) on TWO VETO rules from the senior-ai rubric."
  printf '%s\n' "usage: bash ai-safety-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/ai-safety-report.json - fix recipes: walteur-kit/REMEDIATION.md (## ai-safety-gate)"
  printf '%s\n' "bypass: WALTEUR_AISAFE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/ai-safety-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# ── report writer (jq preferred; printf fallback) ─────────────────────────────
write_report() {  # $1=verdict $2=rules-json-array
  local v="$1" rules="${2:-[]}"
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --argjson rules "$rules" \
      '{verdict:$v, ts:$ts, gate:"ai-safety", rules:$rules}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"ai-safety","rules":%s}\n' "$v" "$TS" "$rules" > "$REPORT"
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

  for t in bash jq find grep head xargs mktemp date mkdir rm ln cat touch; do
    if ! have "$t"; then
      echo "ai-safety-gate selftest SKIP - required tool '$t' not installed."
      return 0
    fi
  done

  make_core_path() {
    dst="$1"
    mkdir -p "$dst"
    for t in bash jq find grep head xargs mktemp date mkdir rm; do
      ln -sf "$(command -v "$t")" "$dst/$t"
    done
  }
  make_corpus() {
    root="$1"
    mkdir -p "$root/tests/injection"
    printf '{"name":"basic injection","prompt":"ignore previous instructions"}\n' > "$root/tests/injection/basic.injection.json"
  }
  write_good_agent() {
    root="$1"
    mkdir -p "$root/src"
    cat > "$root/src/agent.py" <<'PY'
import os
import anthropic

client = anthropic.Anthropic()
MODEL = os.environ["ANTHROPIC_MODEL"]
max_iterations = 3
for i in range(max_iterations):
    client.messages.create(model=MODEL, messages=[])
PY
  }
  write_uncapped_agent() {
    root="$1"
    mkdir -p "$root/src"
    cat > "$root/src/agent.py" <<'PY'
import os
import anthropic

client = anthropic.Anthropic()
while True:
    client.messages.create(model=os.environ["ANTHROPIC_MODEL"], messages=[])
PY
  }
  write_hardcoded_model_agent() {
    root="$1"
    mkdir -p "$root/src"
    cat > "$root/src/agent.py" <<'PY'
import anthropic

client = anthropic.Anthropic()
max_iterations = 3
for i in range(max_iterations):
    client.messages.create(model="claude-sonnet-4-6", messages=[])
PY
  }

  echo "ai-safety-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aisafeself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  PATH="$tmp/bin:$PATH" WALTEUR_ROOT="$tmp" bash "$0" "$tmp/missing" >/dev/null 2>&1
  ck "invalid directory -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/ai-safety-report.json" >/dev/null 2>&1
  ck "invalid directory report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aisafeself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin" "$tmp/src"
  make_core_path "$tmp/bin"
  printf 'print("plain app")\n' > "$tmp/src/app.py"
  PATH="$tmp/bin:$PATH" WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "non-AI project -> NOT_APPLICABLE exit" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/ai-safety-report.json" >/dev/null 2>&1
  ck "non-AI report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aisafeself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  write_good_agent "$tmp"
  PATH="$tmp/bin:$PATH" WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "AI missing injection corpus -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.rules[] | select(.rule == "R2-injection-corpus" and .result == "VETO"))' "$tmp/walteur-kit/ai-safety-report.json" >/dev/null 2>&1
  ck "missing corpus report records R2 VETO" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aisafeself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  write_good_agent "$tmp"
  make_corpus "$tmp"
  PATH="$tmp/bin:$PATH" WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "AI corpus + capped loop + env model -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and (.rules[] | select(.rule == "R2-injection-corpus" and .result == "PASS")) and (.rules[] | select(.rule == "R1-loop-cap" and .result == "PASS")) and (.rules[] | select(.rule == "R3-model-pin" and .result == "PASS"))' "$tmp/walteur-kit/ai-safety-report.json" >/dev/null 2>&1
  ck "good AI report records R1/R2/R3 PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aisafeself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  write_uncapped_agent "$tmp"
  make_corpus "$tmp"
  PATH="$tmp/bin:$PATH" WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "AI uncapped loop -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.rules[] | select(.rule == "R1-loop-cap" and .result == "VETO"))' "$tmp/walteur-kit/ai-safety-report.json" >/dev/null 2>&1
  ck "uncapped loop report records R1 VETO" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aisafeself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  write_hardcoded_model_agent "$tmp"
  make_corpus "$tmp"
  PATH="$tmp/bin:$PATH" WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "AI hardcoded Claude model -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.rules[] | select(.rule == "R3-model-pin" and .result == "VETO"))' "$tmp/walteur-kit/ai-safety-report.json" >/dev/null 2>&1
  ck "hardcoded model report records R3 VETO" 0 "$?"
  rm -rf "$tmp"

  # Regression lock: a plain English word that merely CONTAINS "rag" (coverage, storage, average,
  # garage, ...) must NOT trip the AI/agent name-signal — the keyword needs a real word boundary.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aisafeself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  printf 'export const coverage = 1;\n' > "$tmp/src/persona-coverage-gate.sh"
  printf 'export const storage = 1;\n' > "$tmp/src/storage.ts"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "'rag' substring inside 'coverage'/'storage' -> NOT_APPLICABLE (no false name-signal)" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/ai-safety-report.json" >/dev/null 2>&1
  ck "'rag' substring false-positive report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  # Regression lock: the harness's own installed .claude/hooks/*.sh scripts (which legitimately
  # mention agent/rag/tool-contract in their own dispatch comments/filenames) must never count as
  # the PROJECT'S AI/agent build signal — only project source outside .claude/hooks/ counts.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aisafeself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/.claude/hooks"
  printf 'export const ok = 1;\n' > "$tmp/app.js"
  printf '#!/usr/bin/env bash\n# dispatches an AI agent tool-contract check\n' > "$tmp/.claude/hooks/agent-runner.sh"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck ".claude/hooks/ harness scripts excluded from AI/agent name-signal scan -> NOT_APPLICABLE" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/ai-safety-report.json" >/dev/null 2>&1
  ck ".claude/hooks/ exclusion report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aisafeself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" WALTEUR_AISAFE=off bash "$0" "$tmp" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/ai-safety-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aisafeself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "ai-safety-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

# ── kill switch ───────────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && {
  echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2
  exit 2
}

# ── env bypass ───────────────────────────────────────────────────────────────
if [ "${WALTEUR_AISAFE:-on}" = "off" ]; then
  echo "WALTEUR ai-safety-gate SKIP — bypass WALTEUR_AISAFE=off (recorded, not silent-green)." >&2
  write_report "SKIP" '[]'
  exit 0
fi

# ── directory argument ────────────────────────────────────────────────────────
DIR="${1:-}"
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  echo "WALTEUR ai-safety-gate SKIP — no/invalid directory argument." >&2
  write_report "SKIP" '[]'
  exit 0
fi

# ── signed-deferral lookup (same policy store as edge-protection) ─────────────
# walteur-kit/layers.json key "ai-safety-R1" or "ai-safety-R2"
# value "pass" or "deferred:<reason>" => that named rule is waived.
rule_deferred() {  # $1 = rule key e.g. "ai-safety-R1" → 0 if waived
  [ -f "$KIT/layers.json" ] || return 1
  local val
  val="$(jq -r --arg k "$1" '.[$k] // ""' "$KIT/layers.json" 2>/dev/null)"
  case "$val" in pass|deferred:*) return 0 ;; esac
  return 1
}

# ── pruning spec (same as tool-contract-lint) ─────────────────────────────────
PRUNE=( -path "$ROOT/.git" -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/venv' \
        -o -path '*/dist' -o -path '*/build' -o -path '*/vendor' -o -path '*/.claude/hooks' )

# ── APPLICABILITY — mirror tool-contract-lint.sh exactly ──────────────────────
# An AI/agent build if ANY of:
#   (a) walteur-kit/tool-contracts/ exists
#   (b) any *.tool.json file in the project
#   (c) file/dir name matches agent|llm|prompt|mcp|rag|embedding|tool.?contract (case-insensitive)
#   (d) source files import an LLM SDK (openai / anthropic / langchain / huggingface / cohere / mistral)
#   (e) walteur-kit/tool-contract.schema.json exists
#   (f) a tools.* file exists at the project root

APPLICABLE="no"
APP_REASON=""

if [ -d "$DIR/walteur-kit/tool-contracts" ]; then
  APPLICABLE="yes"; APP_REASON="walteur-kit/tool-contracts/ present"
fi

if [ "$APPLICABLE" = "no" ]; then
  TOOLJ="$(find "$DIR" \( "${PRUNE[@]}" \) -prune -o -type f -name '*.tool.json' -print 2>/dev/null | head -1)"
  if [ -n "$TOOLJ" ]; then APPLICABLE="yes"; APP_REASON="*.tool.json: $TOOLJ"; fi
fi

if [ "$APPLICABLE" = "no" ]; then
  NAME_HIT="$(find "$DIR" \( "${PRUNE[@]}" \) -prune -o \( -type f -o -type d \) -print 2>/dev/null \
    | grep -viE '(^|/)walteur-kit/' \
    | grep -iE '(^|/)[^/]*(agent|llm|prompt|mcp|\brag\b|embedding|tool.?contract)[^/]*$' \
    | head -1)"
  if [ -n "$NAME_HIT" ]; then APPLICABLE="yes"; APP_REASON="AI/agent name: $NAME_HIT"; fi
fi

if [ "$APPLICABLE" = "no" ]; then
  SRC="$(find "$DIR" \( "${PRUNE[@]}" \) -prune -o -type f \
    \( -name '*.py' -o -name '*.ts' -o -name '*.js' -o -name '*.mjs' -o -name '*.rb' -o -name '*.go' \) \
    -print 2>/dev/null)"
  if [ -n "$SRC" ]; then
    SDK_HIT="$(printf '%s\n' "$SRC" | xargs grep -lEi \
      'import openai|from openai|import anthropic|from anthropic|langchain|huggingface|cohere|mistral|openai\.ChatCompletion|client\.messages\.create|ChatOpenAI|AzureOpenAI|BedrockRuntime' \
      2>/dev/null | head -1)"
    if [ -n "$SDK_HIT" ]; then APPLICABLE="yes"; APP_REASON="LLM SDK import: $SDK_HIT"; fi
  fi
fi

if [ "$APPLICABLE" = "no" ]; then
  if [ -f "$DIR/walteur-kit/schemas/tool-contract.schema.json" ]; then
    APPLICABLE="yes"; APP_REASON="tool-contract.schema.json present"
  fi
fi

if [ "$APPLICABLE" = "no" ]; then
  TOOLS_HIT="$(find "$DIR" -maxdepth 2 -name 'tools.*' -type f 2>/dev/null | head -1)"
  if [ -n "$TOOLS_HIT" ]; then APPLICABLE="yes"; APP_REASON="tools.* file: $TOOLS_HIT"; fi
fi

if [ "$APPLICABLE" = "no" ]; then
  echo "WALTEUR ai-safety-gate: NOT_APPLICABLE — no AI/agent build signals under '$DIR'." >&2
  write_report "NOT_APPLICABLE" '[{"rule":"R2-injection-corpus","result":"NA","evidence":"not an AI build"},{"rule":"R1-loop-cap","result":"NA","evidence":"not an AI build"},{"rule":"R3-model-pin","result":"NA","evidence":"not an AI build"}]'
  exit 0
fi

echo "WALTEUR ai-safety-gate @ $DIR — applicable ($APP_REASON)." >&2

# ── rule results accumulator ──────────────────────────────────────────────────
VETO=0
RULES_JSON='[]'

add_rule() {  # $1=rule $2=result $3=evidence
  local rule="$1" result="$2" evidence="$3"
  if have jq; then
    RULES_JSON="$(jq -c --arg r "$rule" --arg res "$result" --arg ev "$evidence" \
      '. + [{"rule":$r,"result":$res,"evidence":$ev}]' <<<"$RULES_JSON")"
  else
    RULES_JSON="${RULES_JSON%]},{\"rule\":\"$rule\",\"result\":\"$result\",\"evidence\":\"$evidence\"}]"
  fi
}

# ── R2: injection corpus must exist ───────────────────────────────────────────
# Corpus paths: tests/injection/*, **/*.injection.json, **/injection/*.json, fixtures/injection/
R2_RESULT="VETO"
R2_EVIDENCE=""

# tests/injection/ directory
if [ -d "$DIR/tests/injection" ]; then
  R2_RESULT="PASS"; R2_EVIDENCE="tests/injection/ directory found"
fi

# **/*.injection.json
if [ "$R2_RESULT" != "PASS" ]; then
  HIT="$(find "$DIR" \( "${PRUNE[@]}" \) -prune -o -type f -name '*.injection.json' -print 2>/dev/null | head -1)"
  if [ -n "$HIT" ]; then R2_RESULT="PASS"; R2_EVIDENCE="*.injection.json: $HIT"; fi
fi

# **/injection/*.json (any directory named "injection" with json files)
if [ "$R2_RESULT" != "PASS" ]; then
  HIT="$(find "$DIR" \( "${PRUNE[@]}" \) -prune -o -type d -name 'injection' -print 2>/dev/null \
    | while IFS= read -r d; do find "$d" -maxdepth 1 -type f -name '*.json' 2>/dev/null | head -1; done \
    | head -1)"
  if [ -n "$HIT" ]; then R2_RESULT="PASS"; R2_EVIDENCE="injection dir JSON: $HIT"; fi
fi

# fixtures/injection directory
if [ "$R2_RESULT" != "PASS" ]; then
  if [ -d "$DIR/fixtures/injection" ]; then
    R2_RESULT="PASS"; R2_EVIDENCE="fixtures/injection/ directory found"
  fi
fi

if [ "$R2_RESULT" = "VETO" ]; then
  if rule_deferred "ai-safety-R2"; then
    R2_RESULT="DEFERRED"
    R2_EVIDENCE="signed deferral in walteur-kit/layers.json[ai-safety-R2]"
    echo "WALTEUR ai-safety-gate: R2 DEFERRED — signed deferral accepted for injection corpus." >&2
  else
    echo "WALTEUR ai-safety-gate: VETO R2 (rubric B3) — AI build detected ($APP_REASON) but NO injection test corpus found." >&2
    echo "  Required: tests/injection/*, *.injection.json, or fixtures/injection/ containing test cases." >&2
    echo "  Fix: add an injection corpus, or sign a deferral: walteur-kit/layers.json {\"ai-safety-R2\": \"deferred:<reason>\"}." >&2
    R2_EVIDENCE="no corpus found; no signed deferral"
    VETO=$((VETO+1))
  fi
fi

add_rule "R2-injection-corpus" "$R2_RESULT" "$R2_EVIDENCE"

# ── R1: agent loop must have a hard termination cap ───────────────────────────
# Step 1: find agent-loop source files — files that contain an actual loop construct.
#   Loop signals: while|for  (case-insensitive, checking all source files).
#   We look for files that seem to be running an agent loop by looking for BOTH
#   an LLM/agent call AND a loop construct in the same file (or just the loop in
#   a file already flagged as an agent file by applicability).

LOOP_FILE=""
AGENT_FILES="$(find "$DIR" \( "${PRUNE[@]}" \) -prune -o -type f \
  \( -name '*.py' -o -name '*.ts' -o -name '*.js' -o -name '*.mjs' -o -name '*.rb' -o -name '*.go' -o -name '*.java' \) \
  -print 2>/dev/null)"

if [ -n "$AGENT_FILES" ]; then
  # A file is an "agent loop file" if it contains BOTH a loop keyword AND an LLM/dispatch/tool call signal.
  LOOP_FILE="$(printf '%s\n' "$AGENT_FILES" | while IFS= read -r f; do
    # Has a loop?
    grep -qiE '\b(while|for)\b' "$f" 2>/dev/null || continue
    # Has an LLM/agent call or tool dispatch signal?
    grep -qiE '(openai|anthropic|langchain|dispatch|llm|invoke|run_agent|agent\.run|client\.messages|chat\.completions|tool_call|call_tool|step\()' "$f" 2>/dev/null || continue
    echo "$f"
    break
  done | head -1)"

  # Fallback: if applicability was triggered by an agent-named file, check that file for a loop
  if [ -z "$LOOP_FILE" ] && [ -n "$APP_REASON" ]; then
    # Check the file/dir that triggered applicability for a loop
    APP_FILE="$(printf '%s\n' "$AGENT_FILES" | grep -iE '(agent|llm|prompt|mcp|rag)' | head -1)"
    if [ -n "$APP_FILE" ]; then
      grep -qiE '\b(while|for)\b' "$APP_FILE" 2>/dev/null && LOOP_FILE="$APP_FILE"
    fi
  fi
fi

R1_RESULT="NA"
R1_EVIDENCE="no agent-loop file detected"

if [ -n "$LOOP_FILE" ]; then
  # GENEROUS cap signal regex — any of these in the loop file means a cap exists.
  # Covers Python (range(), MAX_ITERS), TS/JS (maxTurns, maxIterations, for i<N),
  # wall-clock timeouts, recursion limits, etc.
  CAP_REGEX='max_iterations|maxIterations|MAX_ITER|max_turns|maxTurns|MAX_TURNS|max_steps|maxSteps|step_budget|stepBudget|range\(|for .* in range|while .*<[[:space:]]*[A-Za-z0-9_]*[Mm]ax|wall.?clock|deadline|timeout|n_?iter|iteration[_[:space:]]?cap|recursion_limit'

  if grep -qiE "$CAP_REGEX" "$LOOP_FILE" 2>/dev/null; then
    CAP_LINE="$(grep -inE "$CAP_REGEX" "$LOOP_FILE" 2>/dev/null | head -1)"
    R1_RESULT="PASS"
    R1_EVIDENCE="cap signal in $LOOP_FILE: $CAP_LINE"
  else
    if rule_deferred "ai-safety-R1"; then
      R1_RESULT="DEFERRED"
      R1_EVIDENCE="signed deferral in walteur-kit/layers.json[ai-safety-R1]; loop in $LOOP_FILE"
      echo "WALTEUR ai-safety-gate: R1 DEFERRED — signed deferral accepted for loop cap." >&2
    else
      echo "WALTEUR ai-safety-gate: VETO R1 (rubric C2) — agent loop in '$LOOP_FILE' has no hard termination cap." >&2
      echo "  Required: at least one of: max_iterations, maxIterations, max_turns, maxTurns, max_steps," >&2
      echo "    step_budget, range(N), for i<MAX, wall_clock deadline, timeout, recursion_limit, etc." >&2
      echo "  Fix: add a model-independent cap, or sign a deferral: walteur-kit/layers.json {\"ai-safety-R1\": \"deferred:<reason>\"}." >&2
      R1_RESULT="VETO"
      R1_EVIDENCE="no cap signal in $LOOP_FILE; no signed deferral"
      VETO=$((VETO+1))
    fi
  fi
fi

add_rule "R1-loop-cap" "$R1_RESULT" "$R1_EVIDENCE"

# ── R3: Claude/Anthropic model ID must not be a hardcoded source literal ──────
# Pattern: string literal matching claude-(opus|sonnet|haiku)-[0-9] or claude-<word>-YYYYMMDD.
# PASS condition: the match only appears inside an env/config-read expression — i.e.
#   os.environ[...], process.env, os.getenv(, config[ — which means the value is injected
#   at runtime, not frozen in source.
# VETO condition: a bare hardcoded literal is found with no env-read wrapping AND no
#   signed attestation in layers.json["ai-safety-R3"].
# NOTE: This regex detects the PATTERN of a versioned model literal.
#   It contains NO specific "current" model ID — so the gate does not rot like the thing it polices.

R3_RESULT="NA"
R3_EVIDENCE="no AI source files or no Claude SDK detected"

# R3 only fires when the applicability path was triggered by an Anthropic/LLM SDK import
# (i.e. APP_REASON contains "LLM SDK import") OR when source files import anthropic.
# This prevents false positives on non-AI builds that happen to have agent-like names.
AI_SRC_FILES=""
if [ -n "$AGENT_FILES" ]; then
  AI_SRC_FILES="$(printf '%s\n' "$AGENT_FILES" | xargs grep -lEi \
    'import anthropic|from anthropic|anthropic\.Anthropic|client\.messages\.create' \
    2>/dev/null)"
fi

if [ -n "$AI_SRC_FILES" ]; then
  # MODEL_LITERAL_REGEX: matches a versioned claude-* model name in source.
  # Catches: "claude-opus-4-5", "claude-sonnet-4-6", "claude-haiku-3-5", "claude-opus-20240229", etc.
  # Does NOT match: os.environ["ANTHROPIC_MODEL"] (the env var name, not a versioned model ID).
  # Intentionally no quote anchoring — macOS BSD grep does not interpret \x27 in character classes,
  # and the versioned model name pattern itself is sufficient to distinguish a hardcoded literal
  # from a dynamic env-var reference (which would contain no versioned model name string).
  MODEL_LITERAL_REGEX='claude-(opus|sonnet|haiku)-[0-9]|claude-[a-z]+-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'

  # ENV_SOURCED_REGEX: lines where the model literal appears inside an env/config read.
  # If ALL matches are env-sourced, R3 passes. If ANY match is a bare literal, R3 vetoes.
  ENV_SOURCE_REGEX='os\.environ\[|process\.env\.|os\.getenv\(|config\[|getenv\(|ENV\['

  R3_VETO_FILE=""
  R3_VETO_LINE=""
  R3_PASS_EVIDENCE=""

  while IFS= read -r f; do
    [ -f "$f" ] || continue
    # Find all lines with a hardcoded claude-* literal
    LITERAL_LINES="$(grep -nE "$MODEL_LITERAL_REGEX" "$f" 2>/dev/null)"
    [ -z "$LITERAL_LINES" ] && continue

    # Check each matching line: if it also contains an env/config source pattern → pass for this line
    BARE_LINE=""
    while IFS= read -r lline; do
      if printf '%s\n' "$lline" | grep -qE "$ENV_SOURCE_REGEX"; then
        # env-sourced reference — fine
        R3_PASS_EVIDENCE="env-sourced model in $f: $lline"
      else
        # bare literal
        BARE_LINE="$lline"
        break
      fi
    done < <(printf '%s\n' "$LITERAL_LINES")

    if [ -n "$BARE_LINE" ]; then
      R3_VETO_FILE="$f"
      R3_VETO_LINE="$BARE_LINE"
      break
    fi
  done < <(printf '%s\n' "$AI_SRC_FILES")

  if [ -n "$R3_VETO_FILE" ]; then
    # A bare hardcoded literal was found — check for signed attestation
    if rule_deferred "ai-safety-R3"; then
      R3_RESULT="DEFERRED"
      R3_EVIDENCE="signed attestation in walteur-kit/layers.json[ai-safety-R3]; literal in $R3_VETO_FILE: $R3_VETO_LINE"
      echo "WALTEUR ai-safety-gate: R3 DEFERRED — dated attestation accepted for model-pin." >&2
    else
      echo "WALTEUR ai-safety-gate: VETO R3 — AI build has a hardcoded Claude model literal in '$R3_VETO_FILE'." >&2
      echo "  Hardcoded model IDs rot silently as model versions are superseded." >&2
      echo "  Fix: source the model from env (os.environ[\"ANTHROPIC_MODEL\"] / process.env.ANTHROPIC_MODEL)" >&2
      echo "       or sign a dated attestation: walteur-kit/layers.json {\"ai-safety-R3\": \"deferred:verified:YYYY-MM-DD:claude-api\"}." >&2
      R3_RESULT="VETO"
      R3_EVIDENCE="bare hardcoded literal in $R3_VETO_FILE: $R3_VETO_LINE; no attestation"
      VETO=$((VETO+1))
    fi
  else
    if [ -n "$R3_PASS_EVIDENCE" ]; then
      R3_RESULT="PASS"
      R3_EVIDENCE="$R3_PASS_EVIDENCE"
    else
      # No literal at all in any AI SDK source file — model is not hardcoded
      R3_RESULT="PASS"
      R3_EVIDENCE="no hardcoded Claude model literal found in AI SDK source files"
    fi
  fi
fi

add_rule "R3-model-pin" "$R3_RESULT" "$R3_EVIDENCE"

# ── verdict ───────────────────────────────────────────────────────────────────
if [ "$VETO" -gt 0 ]; then
  write_report "FAIL" "$RULES_JSON"
  echo "WALTEUR ai-safety-gate: FAIL — $VETO VETO(s). See walteur-kit/ai-safety-report.json." >&2
  exit 2
fi

write_report "PASS" "$RULES_JSON"
echo "WALTEUR ai-safety-gate: PASS — R2=$(printf '%s' "$RULES_JSON" | grep -o '"R2[^"]*","result":"[^"]*"' | grep -o '"result":"[^"]*"' | head -1) R1=$(printf '%s' "$RULES_JSON" | grep -o '"R1[^"]*","result":"[^"]*"' | grep -o '"result":"[^"]*"' | head -1) R3=$(printf '%s' "$RULES_JSON" | grep -o '"R3[^"]*","result":"[^"]*"' | grep -o '"result":"[^"]*"' | head -1)." >&2
exit 0
