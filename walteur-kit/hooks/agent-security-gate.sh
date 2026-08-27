#!/usr/bin/env bash
# WALTEUR agent-security-gate — HARD gate. An LLM / tool-calling-agent surface that mixes UNTRUSTED data
# with TOOL or CREDENTIAL authority, or that pastes a secret into a prompt, is a prompt-injection blast
# radius: a poisoned web page / email / document can drive your tools and exfiltrate your keys. This gate
# fires when an agent surface is present and requires walteur-kit/agent-security.json to declare a
# trust-split (untrusted-data LLM path has ZERO tool/credential authority), no_secret_in_prompt, and a
# named prompt-injection control. It also ACTIVE-scans source: FAIL if a secret/env var is interpolated
# into a prompt/messages/system literal in code.
#
# Applies when an agent surface is present: src imports/uses openai|anthropic|langchain|llama_index|
#   @modelcontextprotocol|mcp|tool_call|function_call across *.ts/*.js/*.py (or agent-security.json exists).
# CONTRACT: surface present + missing/weak agent-security.json => FAIL exit 2 · secret-in-prompt in code
#   => FAIL exit 2 · no agent surface => NOT_APPLICABLE exit 0 · jq absent => SKIP · PAUSED => exit 2 ·
#   bypass WALTEUR_AGENTSEC=off.
# Report: walteur-kit/agent-security-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "agent-security-gate - HARD gate. An LLM / tool-calling-agent surface that mixes UNTRUSTED data"
  printf '%s\n' "usage: bash agent-security-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/agent-security-report.json - fix recipes: walteur-kit/REMEDIATION.md (## agent-security-gate)"
  printf '%s\n' "bypass: WALTEUR_AGENTSEC=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
MANIFEST="${WALTEUR_AGENTSEC_FILE:-$KIT/agent-security.json}"
REPORT="$KIT/agent-security-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"agent-security", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"agent-security","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

# ── source pruning (skip vendored / build / kit trees) ────────────────────────
PRUNE=( -path "$ROOT/.git" -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/venv' \
        -o -path '*/dist' -o -path '*/build' -o -path '*/vendor' -o -path "$KIT" )

# All scannable source files (ts/tsx/mts/cts/js/jsx/mjs/cjs/py) outside pruned trees.
# .mts/.cts are first-class tsc-native TypeScript ES-module / CommonJS extensions in routine production
# use — omitting them lets an agent surface hide from BOTH applies() and the active secret scan.
src_files() {
  find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -type f \
    \( -name '*.ts' -o -name '*.tsx' -o -name '*.mts' -o -name '*.cts' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.py' \) \
    -print 2>/dev/null
}

# Agent surface present? Any src file imports/uses an agent/LLM signal.
AGENT_RE='openai|anthropic|langchain|llama_index|llamaindex|@modelcontextprotocol|modelcontextprotocol|\bmcp\b|tool_call|tool_calls|function_call|functioncall'
applies() {
  [ -f "$MANIFEST" ] && return 0
  local files hit
  files="$(src_files)"
  [ -n "$files" ] || return 1
  # capture-first then test — never `func | grep -q` under pipefail.
  hit="$(printf '%s\n' "$files" | xargs grep -lEi "$AGENT_RE" 2>/dev/null | head -1)"
  [ -n "$hit" ]
}

# ── ACTIVE scan: secret/env var interpolated into a prompt/messages/system literal ──
# Returns 0 (and prints the offending file) if a violation is found; 1 if clean.
# Windows Git Bash: grep -P is locale-broken, so multiline matching is done in perl -0777.
scan_secret_in_prompt() {
  local files f hit=""
  files="$(src_files)"
  [ -n "$files" ] || { return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # perl slurps the whole file (-0777). A secret only trips this gate when it is interpolated INSIDE a
    # prompt string literal (NOT merely near one — a secret passed to an SDK as a credential must pass).
    # Secret = process.env.*<KEY|SECRET|TOKEN|PASSWORD|CRED|CREDENTIAL>
    #        | os.environ[...<same>...] | os.environ.get(...<same>...) | os.getenv(...<same>...)
    # Literal-scoped shapes:
    #   (A) JS/TS back-tick template literal that interpolates a secret in ${...} AND reads like a prompt;
    #   (B) Python f-string assigned/keyed to a prompt-ish name (prompt/system/content/...), secret in {...};
    #   (C) Python triple-quoted prompt block fed a secret via a trailing .format()/%/+ (or inside the body);
    #   (D) secret read into a local var, then that VAR string-concatenated (+) into a prompt-ish literal
    #       (JS/TS  "...prompt..." + secretVar / secretVar + "...prompt..."; the most common real spelling).
    if perl -0777 -ne '
      my $sec = qr/process\.env(?:\.[A-Za-z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|CRED|CREDENTIAL)[A-Za-z0-9_]*|\[\s*["'"'"'][^"'"'"']*(?:KEY|SECRET|TOKEN|PASSWORD|CRED|CREDENTIAL)[^"'"'"']*["'"'"']\s*\])|os\.environ(?:\.get)?\s*[\[(]\s*["'"'"'][^"'"'"']*(?:KEY|SECRET|TOKEN|PASSWORD|CRED|CREDENTIAL)[^"'"'"']*["'"'"']|os\.getenv\s*\(\s*["'"'"'][^"'"'"']*(?:KEY|SECRET|TOKEN|PASSWORD|CRED|CREDENTIAL)[^"'"'"']*["'"'"']/;
      my $prompty = qr/\b(?:you are|assistant|an agent|system prompt|instruction|role\s*[:=]|"role"|"content")\b/i;
      my $prompty_lit = qr/\b(?:you are|assistant|an agent|system prompt|instruction|use (?:it|the|these) tool|call (?:the )?tool|on the user|admin token|privileged tool)\b/i;
      # (A) back-tick template literal: secret in ${...} and the literal reads like a system/agent prompt
      while (/`([^`]*)`/sg){ my $b=$1; if ($b=~/\$\{[^}]*(?:$sec)/ && ($b=~/$prompty/ || $b=~/\b(use (it|the|these) tool|call (the )?tool|database|password|token)\b/i)){ exit 1 } }
      # (B) python f-string valued to a prompt-ish key/var, secret inside the {...}
      while (/((?:^|[\s\[{(,])(?:prompt|messages|system_prompt|systemPrompt|user_prompt|userPrompt|instructions|system|content|template)\s*[:=]\s*|"(?:content|text)"\s*:\s*)f(["'"'"'])(.*?)\2/sgmi){ my $b=$3; if ($b=~/\{[^}]*(?:$sec)/){ exit 1 } }
      # (C) python triple-quoted prompt block fed a secret via .format()/%/+ trailer (or in the body)
      while (/("""|'"'"''"'"''"'"')(.*?)\1(\s*(?:\.\s*format\s*\([^)]*|%[^\n;]*|\+[^\n;]*))?/sg){
         my $body=$2; my $trail=defined($3)?$3:"";
         if (($body=~/$prompty/ || $body=~/\b(password|token|secret|api[_ ]?key|credential)\b/i)
             && ($body=~/(?:$sec)/ || $trail=~/(?:$sec)/)){ exit 1 }
      }
      # (D) pre-bound-variable concat: (1) collect names bound directly to a secret, then
      #     (2) FAIL if any such name is +-concatenated next to a prompt-ish string literal.
      my %secvar;
      while (/(?:const|let|var)?\s*([A-Za-z_\$][A-Za-z0-9_\$]*)\s*=\s*(?:await\s+)?(?:$sec)\s*[;\n]/sg){ $secvar{$1}=1; }            # JS/TS:  const adminToken = process.env.ADMIN_API_TOKEN;
      while (/^[ \t]*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:$sec)\s*$/mg){ $secvar{$1}=1; }                                              # Python: admin_token = os.getenv("...")
      if (%secvar){
        my $names = join("|", map { quotemeta } keys %secvar);
        my $nre = qr/(?<![A-Za-z0-9_\$])(?:$names)(?![A-Za-z0-9_\$])/;
        # a string literal (single or double quoted) that READS like a system/agent prompt
        while (/(["'"'"'])((?:\\.|(?!\1).)*?)\1/sg){
          # capture offsets BEFORE any other regex runs (inner matches clobber @-/@+)
          my $s=$-[0]; my $e=$+[0]; my $body=$2;
          next unless $body=~/$prompty_lit/;
          # window: the concat expression around this literal (look a little before and after)
          my $lo = $s>240 ? $s-240 : 0; my $pre = substr($_,$lo,$s-$lo);
          my $post = substr($_,$e,240);
          # secretVar concatenated immediately before  (...+ secretVar +"prompt") or after ("prompt"+ secretVar)
          if ($pre=~/\+\s*$nre\s*\+?\s*$/s || $post=~/^\s*\+\s*$nre/s){ exit 1 }
        }
      }
      exit 0
    ' "$f" 2>/dev/null; then
      : # exit 0 from perl => clean for this file
    else
      hit="$f"; break
    fi
  done <<EOF
$files
EOF
  if [ -n "$hit" ]; then printf '%s\n' "$hit"; return 0; fi
  return 1
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "agent-security selftest SKIP - jq not installed."; return 0; fi
  if ! have perl; then echo "agent-security selftest SKIP - perl not installed."; return 0; fi
  echo "agent-security-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }

  # good manifest: trust_split + no_secret_in_prompt + named control
  goodman() {
    mkdir -p "$1/walteur-kit"
    jq -n '{trust_split:true, no_secret_in_prompt:true, prompt_injection_control:"dual-llm-quarantine"}' > "$1/walteur-kit/agent-security.json"
  }
  # an agent surface in src (clean — no secret in any prompt)
  surface() {
    mkdir -p "$1/src"
    cat > "$1/src/agent.ts" <<'TS'
import OpenAI from "openai";
const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
const system = `You are a helpful agent. Use the provided tools carefully.`;
export async function run(userMsg: string) {
  return client.chat.completions.create({ model: "gpt-4o", messages: [
    { role: "system", content: system },
    { role: "user", content: userMsg },
  ]});
}
TS
  }

  # 1. no agent surface, no manifest -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; mkdir -p "$t/src"; printf 'export const x = 1;\n' > "$t/src/util.ts"; ck "no agent surface -> NA" 0 "$(run "$t")"; rm -rf "$t"

  # 2. agent surface (clean) + good manifest -> PASS   [FALSE-POSITIVE GUARD]
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; goodman "$t"; ck "clean surface + good manifest -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 3. agent surface present, manifest absent -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; ck "surface, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 4. trust_split=false -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; goodman "$t"; jq '.trust_split=false' "$t/walteur-kit/agent-security.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/agent-security.json"; ck "trust_split=false -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 5. no_secret_in_prompt=false -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; goodman "$t"; jq '.no_secret_in_prompt=false' "$t/walteur-kit/agent-security.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/agent-security.json"; ck "no_secret_in_prompt=false -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 6. prompt_injection_control missing/empty -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; goodman "$t"; jq '.prompt_injection_control=""' "$t/walteur-kit/agent-security.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/agent-security.json"; ck "empty prompt_injection_control -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 7. ACTIVE scan: TS secret interpolated into a prompt template literal -> FAIL (poisoned twin of #2)
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; goodman "$t"
  cat > "$t/src/leak.ts" <<'TS'
const system = `You are an agent. Internal admin token: ${process.env.ADMIN_API_TOKEN}. Use it to call tools.`;
TS
  ck "secret in TS prompt literal -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 8. ACTIVE scan: Python secret in a triple-quoted system prompt -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; goodman "$t"
  cat > "$t/agent.py" <<'PY'
import os
system_prompt = """
You are an agent. The database password is {pw}.
""".format(pw=os.environ["DB_PASSWORD"])
PY
  # the format() ref is on the same construct window — still a secret feeding the prompt
  ck "secret in py system prompt -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 9. ACTIVE scan: Python f-string messages with os.getenv secret -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; goodman "$t"
  cat > "$t/chat.py" <<'PY'
import os
messages = [{"role": "system", "content": f"key={os.getenv('OPENAI_API_KEY')}"}]
PY
  ck "secret in py f-string messages -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 10. FALSE-POSITIVE GUARD: env secret used ONLY as SDK credential, never in a prompt -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; goodman "$t"
  mkdir -p "$t/src"
  cat > "$t/src/client.ts" <<'TS'
import OpenAI from "openai";
// secret used as a credential, NOT pasted into any prompt
const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY, organization: process.env.OPENAI_ORG });
const system = `You are a helpful, careful agent.`;
export const c = client;
export const s = system;
TS
  ck "env secret as credential only -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 11. FALSE-POSITIVE GUARD: prompt mentions a NON-secret env var (no KEY/SECRET/TOKEN) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; goodman "$t"
  cat > "$t/src/region.ts" <<'TS'
const prompt = `Operate in region ${process.env.AWS_REGION} for the user.`;
export const p = prompt;
TS
  ck "non-secret env var in prompt -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 12. bypass -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; WALTEUR_ROOT="$t" WALTEUR_AGENTSEC=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"

  # 13. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; mkdir -p "$t/walteur-kit"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ── G# regression cases for the 3 proven red-team false-negatives ────────────────────────────────────
  # G1 — TYPE/ENCODING evasion: manifest fields are well-typed look-alikes (string "true", number 0) that
  #      the old jq -r string compare waved through. Strict jq -e now rejects all of them -> FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; mkdir -p "$t/walteur-kit"
  cat > "$t/walteur-kit/agent-security.json" <<'JSON'
{ "trust_split": "true", "no_secret_in_prompt": "true", "prompt_injection_control": 0 }
JSON
  ck "G1 type-trick manifest (\"true\"/0) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G1b — the \"none\" / [] sentinel spellings of prompt_injection_control are also rejected -> FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; mkdir -p "$t/walteur-kit"
  cat > "$t/walteur-kit/agent-security.json" <<'JSON'
{ "trust_split": true, "no_secret_in_prompt": true, "prompt_injection_control": "none" }
JSON
  ck "G1b prompt_injection_control=\"none\" -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G2 — SHAPE evasion: agent surface + secret-in-prompt hidden in a .mts file (now scanned) -> FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; goodman "$t"; mkdir -p "$t/src"
  cat > "$t/src/app.mts" <<'TS'
import OpenAI from "openai";
const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
const system = `You are an autonomous agent with database and shell tools. Internal admin token: ${process.env.ADMIN_API_TOKEN}. Use it to call the tools.`;
export async function run(m: string) {
  return client.chat.completions.create({ model: "gpt-4o", messages: [
    { role: "system", content: system }, { role: "user", content: m } ] });
}
TS
  ck "G2 secret-in-prompt in .mts (now scanned) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G2b — a bare agent surface in a .cts file (no manifest) is now visible to applies() -> FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; mkdir -p "$t/src"
  cat > "$t/src/svc.cts" <<'TS'
import OpenAI from "openai";
export const c = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
TS
  ck "G2b agent surface in .cts, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G3 — SEMANTIC evasion: secret read into a local var then +-concatenated into a system-prompt literal
  #      (the most common real spelling) is now caught even with an all-true manifest -> FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; goodman "$t"; mkdir -p "$t/src"
  cat > "$t/src/concat.ts" <<'TS'
import OpenAI from "openai";
const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
const adminToken = process.env.ADMIN_API_TOKEN;
const system =
  "You are an autonomous agent. Your internal admin token is " +
  adminToken +
  ". Use it to call privileged tools on the user's behalf.";
export async function run(userMsg: string) {
  return client.chat.completions.create({ model: "gpt-4o", messages: [
    { role: "system", content: system }, { role: "user", content: userMsg } ] });
}
TS
  ck "G3 secret var +-concatenated into prompt -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G4 — FALSE-POSITIVE GUARD for shape (D): a NON-secret var concatenated into a prompt literal -> PASS.
  #      (proves the concat scanner keys on the secret BINDING, not on '+' near a prompt string).
  t="$(mktemp -d "${TMPDIR:-/tmp}/agentsecur.XXXXXX")"; surface "$t"; goodman "$t"
  cat > "$t/src/safe-concat.ts" <<'TS'
const userName = "Ada";
const system =
  "You are a helpful assistant for " +
  userName +
  ". Use the provided tools carefully.";
export const s = system;
TS
  ck "G4 non-secret var concat in prompt -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "agent-security-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_AGENTSEC:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_AGENTSEC=off"; echo "agent-security-gate: bypassed." >&2; exit 0; }

if ! applies; then write_report "NOT_APPLICABLE" "no LLM/tool-calling-agent surface (no agent SDK/MCP/tool_call signal in src, no agent-security.json)"; echo "agent-security-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "agent-security-gate: SKIP." >&2; exit 0; fi

# ── ACTIVE scan first: a secret in a prompt is a code-level breach, fail-closed even if manifest is clean ──
if have perl; then
  leak="$(scan_secret_in_prompt)" || leak=""
  if [ -n "$leak" ]; then
    add_finding "secret_in_prompt" "a secret/env var is interpolated into a prompt/messages/system literal in '${leak#"$ROOT"/}' — a prompt-injection or log leak exfiltrates this credential"
    write_report "FAIL" "secret interpolated into a prompt literal in source"
    echo "agent-security-gate: FAIL - secret in prompt ($leak)" >&2
    exit 2
  fi
else
  # perl is the multiline engine; without it we cannot run the ACTIVE scan — fail-closed.
  add_finding "scanner" "perl unavailable — cannot run the secret-in-prompt source scan; fail-closed"
  write_report "FAIL" "perl unavailable for ACTIVE secret-in-prompt scan"
  echo "agent-security-gate: FAIL - perl unavailable" >&2
  exit 2
fi

# ── manifest must exist and declare the three controls ────────────────────────
if [ ! -s "$MANIFEST" ]; then
  add_finding "manifest" "agent surface present but walteur-kit/agent-security.json absent — declare {trust_split:true, no_secret_in_prompt:true, prompt_injection_control:\"<name>\"}"
  write_report "FAIL" "agent-security.json absent"; echo "agent-security-gate: FAIL - manifest absent" >&2; exit 2
fi
# Force EXACTLY one JSON document (reject multi-doc streams / concatenated docs) and a single object.
# jq -s slurps every doc into an array: length==1 rejects streams; (.[0]|type=="object") rejects arrays/scalars.
if ! jq -e -s 'length==1 and (.[0]|type=="object")' "$MANIFEST" >/dev/null 2>&1; then
  add_finding "manifest" "agent-security.json is not a single valid JSON object (malformed, multi-document, or not an object)"
  write_report "FAIL" "agent-security.json not a single valid JSON object"; echo "agent-security-gate: FAIL - bad json" >&2; exit 2
fi

# ── STRICT, type-safe validation (jq -e on the parsed value, NOT jq -r string compare) ────────────────
# trust_split / no_secret_in_prompt must be the JSON boolean true — reject string "true", number 1, etc.
jq -e '.trust_split == true' "$MANIFEST" >/dev/null 2>&1 \
  || add_finding "trust_split" "trust_split is not JSON boolean true (string/number/null look-alikes rejected) — the untrusted-data LLM path must have ZERO tool/credential authority"
jq -e '.no_secret_in_prompt == true' "$MANIFEST" >/dev/null 2>&1 \
  || add_finding "no_secret_in_prompt" "no_secret_in_prompt is not JSON boolean true (string/number/null look-alikes rejected) — declare that no secret is ever interpolated into a prompt"
# prompt_injection_control must be a JSON STRING naming a REAL control — reject number 0, "none"/"null"/"0"/
# "false"/""/whitespace, empty array, etc. (all falsy/meaningless sentinels that jq -r used to wave through).
jq -e '(.prompt_injection_control | type) == "string"
       and ((.prompt_injection_control | ascii_downcase | gsub("^\\s+|\\s+$";"")) | IN("","none","null","0","false","n/a","na","todo","tbd") | not)' \
   "$MANIFEST" >/dev/null 2>&1 \
  || add_finding "prompt_injection_control" "prompt_injection_control must be a non-falsy named STRING (number 0 / \"none\" / [] etc. rejected) — name the control (e.g. dual-llm-quarantine, allow-list, spotlighting)"

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures agent-security violation(s)"
  echo "agent-security-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "agent surface declares trust-split + no-secret-in-prompt + a named prompt-injection control, and no secret is interpolated into a prompt in source"
echo "agent-security-gate: PASS" >&2
exit 0
