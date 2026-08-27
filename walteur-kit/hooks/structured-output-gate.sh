#!/usr/bin/env bash
# WALTEUR structured-output-gate — HARD gate. An LLM returns a STRING; trusting it raw is the #1
# production LLM bug. A file that makes a model call AND consumes the model output (.choices[0] /
# .content / response.text) MUST validate that output against a schema before use — a zod .parse/
# .safeParse, a pydantic model_validate/BaseModel, a JSON-schema validate(), OR a structured-output
# param on the call itself (response_format / schema / output_schema). Consuming raw model text with
# no validation in the file is a contract-breaching defect (silent garbage, prompt-injection, crashes).
#
# Applies when an LLM API call is present in src:
#   (chat.completions.create|messages.create|responses.create|generateText|generateObject|client.chat)
# CONTRACT: model output consumed with NO schema/validation in that file => FAIL exit 2 ·
#   no LLM call => NOT_APPLICABLE (exit 0) · PAUSED => exit 2 · bypass WALTEUR_STRUCTOUT=off.
# Report: walteur-kit/structured-output-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "structured-output-gate - HARD gate. An LLM returns a STRING; trusting it raw is the #1"
  printf '%s\n' "usage: bash structured-output-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/structured-output-report.json - fix recipes: walteur-kit/REMEDIATION.md (## structured-output-gate)"
  printf '%s\n' "bypass: WALTEUR_STRUCTOUT=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/structured-output-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"structured-output", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"structured-output","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

PRUNE=( -path "$ROOT/.git" -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/venv' \
        -o -path '*/dist' -o -path '*/build' -o -path '*/vendor' -o -path '*/walteur-kit' )

# Regex menus (perl, multiline-safe via -0777). Kept as single-line alternations.
CALL_RE='chat\.completions\.create|messages\.create|responses\.create|generateText|generateObject|client\.chat'
# A file "consumes" model output if it reaches into the response shape.
CONSUME_RE='\.choices\s*\[\s*0\s*\]|\.choices\b|\.content\b|response\.text|resp\.text|completion\.text|\.output_text\b'
# Validation/schema present anywhere in the file. NB: bare `.parse` is gated by a negative lookbehind so
# that JSON.parse / Date.parse (NOT schema validation) do not masquerade as validation — that would be a
# false-NEGATIVE (the #1 way a poisoned file sneaks past). `.safeParse` is zod-specific and always counts.
VALIDATE_RE='\.safeParse\b|(?<!JSON)(?<!Date)\.parse\b|z\.object|z\.string|z\.array|model_validate\b|model_validate_json\b|BaseModel\b|parse_obj\b|parse_raw\b|TypeAdapter\b|jsonschema\.validate\b|ajv\b|\.validate\s*\(|validateSchema\b|Schema\.parse\b'
# Structured-output param ON the call (model is constrained server-side). HARDENED: a bare param NAME is
# NOT proof — the param's VALUE must actually constrain the model. response_format must be type
# json_object|json_schema (NOT "text", which is plain prose); response_mime_type must be application/json;
# tool_choice/function_call must FORCE a call (required/an object), not "auto"/"none"; a bare `schema`
# key only counts when its value is a JSON-schema-like object ({...type|properties...}). Matched against a
# COMMENT-STRIPPED slurp so a token sitting in a comment/docstring cannot satisfy the gate.
PARAM_RE='response_format\s*[:=][^;]*?\btype\b["'"'"']?\s*[:=]\s*["'"'"']?(json_object|json_schema)\b|zodResponseFormat\b|\boutput_schema\b|\bresponse_schema\b|\bresponse_model\b|\bwith_structured_output\b|\bresponse_mime_type\b["'"'"']?\s*[:=]\s*["'"'"']?application/json|tool_choice\s*[:=]\s*(\{|["'"'"']required|["'"'"']function|\[|required\b)|function_call\s*[:=]\s*\{|\bschema\s*[:=]\s*\{[^}]*\b(type|properties)\b'

# files_with_call: list source files containing an LLM call (NUL-safe-ish; paths have no newlines here).
list_src() {
  find "$1" \( "${PRUNE[@]}" \) -prune -o -type f \
    \( -name '*.py' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
       -o -name '*.mjs' -o -name '*.cjs' -o -name '*.rb' -o -name '*.go' \) -print 2>/dev/null
}

# perl -0777 (whole-file slurp) dodges grep -P locale breakage on Git Bash. Regex passed via env (RE)
# to avoid quoting hell; rc 0 = match. Used inline at every call/consume/validate test below.

# match_re FILE: rc 0 if $RE matches the RAW file slurp.
match_re() { RE="$1" perl -0777 -ne 'exit(($_ =~ /$ENV{RE}/) ? 0 : 1)' "$2" 2>/dev/null; }
# match_re_nc FILE: rc 0 if $RE matches the COMMENT-STRIPPED slurp. Strips /* */ and // and #-line
# comments so a validation/structured-output token that lives ONLY in a comment/docstring (a vacuous,
# no-op mention) cannot earn the file a PASS. Credit-granting checks (VALIDATE/PARAM) use this; the
# blame-assigning CONSUME check stays on raw (fail-closed: a real consume is never hidden by stripping).
match_re_nc() {
  RE="$1" perl -0777 -ne '
    s{/\*.*?\*/}{}gs;        # /* ... */ block comments (JS/TS/Go/C)
    s{//[^\n]*}{}g;          # // line comments (JS/TS/Go)
    s{(^|\s)\#[^\n]*}{$1}g;  # # line comments (Python/Ruby), at line-start or after whitespace
    exit(($_ =~ /$ENV{RE}/) ? 0 : 1);
  ' "$2" 2>/dev/null
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  echo "structured-output-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  mk() { mkdir -p "$1/src"; }

  # --- fixtures -------------------------------------------------------------
  # poisoned PY: openai call, consumes .choices[0]...content, NO validation
  poison_py() { cat > "$1/src/agent.py" <<'EOF'
import openai
client = openai.OpenAI()
def run(prompt):
    resp = client.chat.completions.create(model="gpt-4o", messages=[{"role":"user","content":prompt}])
    text = resp.choices[0].message.content
    return json.loads(text)["answer"]
EOF
  }
  # good PY: same call, but validates with pydantic model_validate_json
  good_py() { cat > "$1/src/agent.py" <<'EOF'
import openai
from pydantic import BaseModel
class Answer(BaseModel):
    answer: str
client = openai.OpenAI()
def run(prompt):
    resp = client.chat.completions.create(model="gpt-4o", messages=[{"role":"user","content":prompt}])
    text = resp.choices[0].message.content
    return Answer.model_validate_json(text)
EOF
  }
  # good TS via response_format param ON the call (structured output server-side)
  good_ts_param() { cat > "$1/src/llm.ts" <<'EOF'
import OpenAI from "openai";
const client = new OpenAI();
export async function ask(q: string) {
  const r = await client.chat.completions.create({
    model: "gpt-4o",
    messages: [{ role: "user", content: q }],
    response_format: { type: "json_object" },
  });
  return r.choices[0].message.content;
}
EOF
  }
  # good TS via zod safeParse on response.text (generateText path)
  good_ts_zod() { cat > "$1/src/ai.ts" <<'EOF'
import { generateText } from "ai";
import { z } from "zod";
const Schema = z.object({ answer: z.string() });
export async function ask(q: string) {
  const { text } = await generateText({ model: openai("gpt-4o"), prompt: q });
  const parsed = Schema.safeParse(JSON.parse(text));
  return parsed.success ? parsed.data : null;
}
EOF
  }
  # poisoned TS: generateText, consumes response.text raw, NO schema
  poison_ts() { cat > "$1/src/ai.ts" <<'EOF'
import { generateText } from "ai";
export async function ask(q: string) {
  const response = await generateText({ model: openai("gpt-4o"), prompt: q });
  return JSON.parse(response.text).answer;
}
EOF
  }
  # FALSE-POSITIVE GUARD A: has an LLM call but never consumes the output shape
  # (fire-and-forget / streams to client). Must PASS — nothing to validate here.
  noconsume_py() { cat > "$1/src/notify.py" <<'EOF'
import openai
client = openai.OpenAI()
def log_prompt(prompt):
    # fire the call for side effects / streaming; output not parsed in this file
    client.chat.completions.create(model="gpt-4o", messages=[{"role":"user","content":prompt}], stream=True)
    return "queued"
EOF
  }
  # FALSE-POSITIVE GUARD B: a non-LLM file that happens to use .content / .parse on unrelated objects.
  # No LLM call at all -> whole project must still be APPLICABLE via other file, and THIS file must
  # not be flagged.
  unrelated_py() { cat > "$1/src/util.py" <<'EOF'
def read(node):
    body = node.content
    return Date.parse(body)
EOF
  }

  # ── REGRESSION fixtures (3 proven red-team false-negatives) ──────────────────
  # G12 — inert sibling-key sentinel: a telemetry literal `schema: "v2"` (a string-typed log/version tag,
  # NOT a model constraint) used to satisfy the bare `\bschema\s*[:=]` substring. Consumes raw output,
  # JSON.parse()s it, moves money — MUST FAIL.
  poison_ts_schema_sentinel() { cat > "$1/src/payments-agent.ts" <<'EOF'
import OpenAI from "openai";
const client = new OpenAI();
// telemetry config — NOT a model constraint. `schema` here is just a log/version tag.
const telemetry = { schema: "v2", source: "payments-agent" };
export async function decideTransfer(userMessage: string) {
  const r = await client.chat.completions.create({
    model: "gpt-4o",
    messages: [
      { role: "system", content: "You are a payments assistant. Reply with JSON {amount, toAccount}." },
      { role: "user", content: userMessage },
    ],
  });
  const raw = r.choices[0].message.content as string;
  const decision = JSON.parse(raw);
  await fetch("https://bank.internal/transfer", {
    method: "POST",
    body: JSON.stringify({ amount: decision.amount, toAccount: decision.toAccount, tag: telemetry.schema }),
  });
  return decision;
}
EOF
  }
  # G13 — response_format with type "text": a VALID OpenAI param whose VALUE constrains the model to PLAIN
  # PROSE (the antithesis of structured output). Bare `response_format\b` used to certify it. Consumes raw
  # output and JSON.parses it with no validation — MUST FAIL.
  poison_ts_rf_text() { cat > "$1/src/agent.ts" <<'EOF'
import OpenAI from "openai";
const client = new OpenAI();
export async function decideRefund(ticket: string): Promise<number> {
  const r = await client.chat.completions.create({
    model: "gpt-4o",
    messages: [{ role: "user", content: `Return JSON {"amount": <number>} for: ${ticket}` }],
    response_format: { type: "text" },
  });
  const raw = r.choices[0].message.content;
  return JSON.parse(raw!).amount;
}
EOF
  }
  # G14 — vacuous schema token living ONLY in a comment (author chose NOT to pass it). The call is
  # unconstrained and the output is consumed raw via json.loads — MUST FAIL (comment-stripping kills it).
  poison_py_schema_comment() { cat > "$1/src/agent.py" <<'EOF'
import json
import openai

client = openai.OpenAI()

# NOTE: we considered passing a response schema like:
#   schema = {"type": "object", "properties": {"answer": {"type": "string"}}}
# but the model "usually" returns valid JSON, so we skip it for latency.

def run(prompt: str) -> str:
    resp = client.chat.completions.create(
        model="gpt-4o",
        messages=[{"role": "user", "content": prompt}],
    )
    text = resp.choices[0].message.content
    return json.loads(text)["answer"]
EOF
  }
  # FALSE-POSITIVE GUARD C: a REAL structured-output via response_format json_schema (multiline, the
  # legit twin of G13's "text"). Consumes raw output but the call is genuinely constrained — MUST PASS.
  good_ts_rf_jsonschema() { cat > "$1/src/agent.ts" <<'EOF'
import OpenAI from "openai";
const client = new OpenAI();
export async function decide(ticket: string): Promise<number> {
  const r = await client.chat.completions.create({
    model: "gpt-4o",
    messages: [{ role: "user", content: ticket }],
    response_format: {
      type: "json_schema",
      json_schema: { name: "refund", schema: { type: "object", properties: { amount: { type: "number" } } } },
    },
  });
  const raw = r.choices[0].message.content;
  return JSON.parse(raw!).amount;
}
EOF
  }

  # 1. no LLM call anywhere -> NOT_APPLICABLE (exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; printf 'def add(a,b):\n    return a+b\n' > "$t/src/m.py"; ck "no LLM call -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. poisoned py: consumes raw model output, no validation -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; poison_py "$t"; ck "py consumes raw output, no schema -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 3. good py: pydantic model_validate_json -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; good_py "$t"; ck "py pydantic-validated -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 4. poisoned ts: generateText + raw response.text -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; poison_ts "$t"; ck "ts consumes raw response.text -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. good ts via zod safeParse -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; good_ts_zod "$t"; ck "ts zod safeParse -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 6. good ts via response_format param on call -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; good_ts_param "$t"; ck "ts response_format param -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 7. FALSE-POSITIVE GUARD: LLM call but output never consumed -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; noconsume_py "$t"; ck "FP-guard: call but no consume -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 8. FALSE-POSITIVE GUARD: good file + unrelated .content/.parse file -> PASS (unrelated not flagged)
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; good_py "$t"; unrelated_py "$t"; ck "FP-guard: unrelated .content not flagged -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 9. mixed: one good + one poisoned -> FAIL (the poisoned one)
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; good_py "$t"; poison_ts "$t"; ck "mixed good+poisoned -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10. bypass WALTEUR_STRUCTOUT=off -> exit 0 even when poisoned
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; poison_py "$t"; WALTEUR_ROOT="$t" WALTEUR_STRUCTOUT=off bash "$0" >/dev/null 2>&1; ck "bypass STRUCTOUT=off -> exit 0" 0 "$?"; rm -rf "$t"
  # 11. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; poison_py "$t"; mkdir -p "$t/walteur-kit"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # G12. REGRESSION: inert `schema:"v2"` telemetry sentinel must NOT satisfy the gate -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; poison_ts_schema_sentinel "$t"; ck "G12 inert schema sentinel -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G13. REGRESSION: response_format:{type:"text"} is plain prose, not structure -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; poison_ts_rf_text "$t"; ck "G13 response_format type:text -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G14. REGRESSION: a schema token living only in a comment must be stripped -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; poison_py_schema_comment "$t"; ck "G14 schema-in-comment only -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G15. FP-GUARD: a REAL response_format json_schema (G13's legit twin) must still -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/structured.XXXXXX")"; mk "$t"; good_ts_rf_jsonschema "$t"; ck "G15 FP-guard response_format json_schema -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "structured-output-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_STRUCTOUT:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_STRUCTOUT=off"; echo "structured-output-gate: bypassed." >&2; exit 0; }
have perl || { write_report "SKIP" "perl unavailable"; echo "structured-output-gate: SKIP (no perl)." >&2; exit 0; }

# ── APPLICABILITY: any source file containing an LLM API call ────────────────
SRC="$(list_src "$ROOT")"
[ -n "$SRC" ] || { write_report "NOT_APPLICABLE" "no source files"; echo "structured-output-gate: NOT_APPLICABLE (no source)."; exit 0; }

CALL_FILES=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if match_re_nc "$CALL_RE" "$f"; then   # comment-stripped: a commented-out call is not a real call
    CALL_FILES="$CALL_FILES$f"$'\n'
  fi
done <<< "$SRC"

if [ -z "$CALL_FILES" ]; then
  write_report "NOT_APPLICABLE" "no LLM API call present (chat.completions.create|messages.create|responses.create|generateText|generateObject|client.chat)"
  echo "structured-output-gate: NOT_APPLICABLE (no LLM call)."
  exit 0
fi

# ── CHECK each call-file: if it CONSUMES output, it MUST validate ───────────
while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="${f#"$ROOT"/}"

  # Does this file consume the model output shape? Raw slurp (fail-closed: a real consume is never hidden).
  if match_re "$CONSUME_RE" "$f"; then
    consumes="yes"
  else
    consumes="no"
  fi
  [ "$consumes" = "yes" ] || continue   # call but no consumption in this file -> nothing to validate

  # Is there a schema/validation OR a structured-output param somewhere in this file? Matched against the
  # COMMENT-STRIPPED slurp so a token in a comment/docstring (vacuous, never reaches the call) earns no PASS.
  validated="no"
  if match_re_nc "$VALIDATE_RE" "$f"; then
    validated="yes"
  elif match_re_nc "$PARAM_RE" "$f"; then
    validated="yes"
  fi

  if [ "$validated" = "no" ]; then
    add_finding "$rel" "consumes raw model output (.choices/.content/response.text) with NO schema/validation in the file — add a zod .parse/.safeParse, pydantic model_validate/BaseModel, a JSON-schema validate(), or a response_format/output_schema param on the call"
  fi
done <<< "$CALL_FILES"

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures file(s) consume model output with no validation"
  echo "structured-output-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi

write_report "PASS" "every file that consumes model output validates it against a schema (or constrains it via a structured-output param)"
echo "structured-output-gate: PASS" >&2
exit 0
