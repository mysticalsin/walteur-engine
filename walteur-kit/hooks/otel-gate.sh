#!/usr/bin/env bash
# WALTEUR otel-gate — HARD gate. An API boundary you cannot SEE is an outage you cannot diagnose.
# A service that takes external traffic but emits no traces, no metrics, no structured logs, and no
# trace-context propagation is a black box: when it degrades at 3am nobody can answer "where is the
# latency" or "which request failed". This gate makes observability a ship requirement at the edge.
#
# Applies when preflight-signals.json .has_api_boundary==true.
# Observability is SATISFIED by EITHER of:
#   (a) walteur-kit/observability.json declaring {traces:true, metrics:true, logs:true, traceparent:true}
#       (each pillar an explicit boolean true — a missing/false pillar is NOT satisfied), OR
#   (b) an OpenTelemetry setup in code: grep @opentelemetry | OTLP | trace.getTracer | opentelemetry |
#       otel.Tracer across source files.
#
# CONTRACT:
#   no api boundary                                   => NOT_APPLICABLE exit 0.
#   api boundary + (full manifest OR OTel code)       => PASS exit 0.
#   api boundary + neither, risk_tier high/regulated  => FAIL exit 2.
#   api boundary + neither, risk_tier low/medium      => PASS exit 0 (loud WARN — not blocking below high).
#   jq absent                                         => SKIP exit 0 (loud).
#   walteur-kit/PAUSED                                => exit 2.
# Bypass: WALTEUR_OTEL=off.
# Report: walteur-kit/otel-report.json   {verdict, ts, gate, reason, findings}
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "otel-gate - HARD gate. An API boundary you cannot SEE is an outage you cannot diagnose."
  printf '%s\n' "usage: bash otel-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/otel-report.json - fix recipes: walteur-kit/REMEDIATION.md (## otel-gate)"
  printf '%s\n' "bypass: WALTEUR_OTEL=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
MANIFEST="${WALTEUR_OTEL_FILE:-$KIT/observability.json}"
REPORT="$KIT/otel-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"otel", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"otel","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

# applies: has_api_boundary==true in preflight-signals.json (the surface this gate guards).
applies() { [ -f "$SIGNALS" ] && have jq && jq -e '.has_api_boundary==true' "$SIGNALS" >/dev/null 2>&1; }

# manifest_full: observability.json exists AND is EXACTLY ONE json document that declares all four
# pillars explicitly true. Fail-CLOSED: a non-JSON / unreadable manifest yields rc!=0 here (treated as
# NOT satisfied), never a silent pass. We SLURP (-s) and require length==1 so a multi-document JSON
# stream (NDJSON / concatenated objects) or a top-level array cannot smuggle an all-true decoy past a
# leading operative all-false config: `jq -e '<filter>'` over a stream returns only the LAST value's
# status, so a trailing decoy would override the real config. length==1 forces single-doc semantics and
# .[0]|<predicate> asserts that the one real document satisfies every pillar.
manifest_full() {
  [ -s "$MANIFEST" ] || return 1
  jq -e -s 'length==1 and (.[0]|(.traces==true) and (.metrics==true) and (.logs==true) and (.traceparent==true))' "$MANIFEST" >/dev/null 2>&1
}

# otel_in_code: any source file under ROOT contains REAL OpenTelemetry instrumentation. perl -0777
# multiline scan (grep -P is locale-broken on Git Bash). Skips vendored/dep dirs and the kit's own gate
# sources so the gate self-description here does not count as evidence. Returns 0 if found, 1 otherwise.
#
# SEMANTIC fail-closed: a bare token is NOT evidence. We FIRST strip comments (// line, # line, /* */
# block) from each file, so a `// TODO: wire up @opentelemetry/sdk-node` future-promise comment cannot
# satisfy a present-tense observability requirement. THEN, in the comment-stripped code, we require a
# real instrumentation site — EITHER an actual import/require of an opentelemetry module, OR a real call
# site (trace.getTracer(...), otel.Tracer(...), an OTLP exporter constructor) — not a free-floating word.
otel_in_code() {
  local f hit=1
  while IFS= read -r f; do
    perl -0777 -ne '
      # 1. strip comments so a token inside a comment is not evidence.
      s{/\*.*?\*/}{ }gs;        # /* block */ comments
      s{(^|\s)//[^\n]*}{$1}g;   # // line comments (TS/JS/Go/Java/C#/Rust/Kotlin/PHP)
      s{(^|\s)\#[^\n]*}{$1}g;   # # line comments (Python/Ruby/YAML/PHP)
      # 2. require REAL instrumentation in the surviving code, not a bare keyword.
      #    (a) an import/require that pulls in an opentelemetry/otel/OTLP module, OR
      #    (b) a real call site: trace.getTracer(...) / otel.Tracer(...) / *OTLP*Exporter(...).
      if (
        /(?:import|require|from|use|using)\b[^\n;]*\b(?:\@?opentelemetry|otel[._-]|OTLP)/i
        || /\btrace\.getTracer\s*\(/
        || /\botel\.Tracer\s*\(/
        || /\bOTLP\w*Exporter\s*\(/i
      ) { exit(0); }
      exit(1);
    ' "$f" 2>/dev/null && { hit=0; break; }
  done < <(
    find "$ROOT" -type f \
      \( -name '*.py' -o -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' \
         -o -name '*.mts' -o -name '*.cts' -o -name '*.mjs' -o -name '*.cjs' \
         -o -name '*.go' -o -name '*.rb' -o -name '*.java' -o -name '*.cs' -o -name '*.rs' \
         -o -name '*.kt' -o -name '*.php' -o -name '*.yaml' -o -name '*.yml' \) \
      -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/vendor/*' \
      -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/walteur-kit/hooks/*' \
      2>/dev/null
  )
  return $hit
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "otel selftest SKIP - jq not installed."; return 0; fi
  if ! have perl; then echo "otel selftest SKIP - perl not installed."; return 0; fi
  echo "otel-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }

  # fixture builders (twins): api() = api boundary present; risk() = set risk_tier
  api()  { mkdir -p "$1/walteur-kit"; printf '{"has_api_boundary":true}\n'  > "$1/walteur-kit/preflight-signals.json"; }
  noapi(){ mkdir -p "$1/walteur-kit"; printf '{"has_api_boundary":false}\n' > "$1/walteur-kit/preflight-signals.json"; }
  risk() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "$2" > "$1/walteur-kit/build-contract.json"; }
  goodman() { jq -n '{traces:true,metrics:true,logs:true,traceparent:true}' > "$1/walteur-kit/observability.json"; }
  otelcode() { mkdir -p "$1/src"; printf 'import { trace } from "@opentelemetry/api";\nconst t = trace.getTracer("svc");\n' > "$1/src/tel.ts"; }

  # 1. no api boundary -> NOT_APPLICABLE (PASS) — even at regulated tier
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; noapi "$t"; risk "$t" regulated; ck "no api boundary -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. GOOD: api + full observability manifest -> PASS (regulated)
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" regulated; goodman "$t"; ck "full manifest @regulated -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. GOOD: api + OTel in code (no manifest) -> PASS (regulated)
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" regulated; otelcode "$t"; ck "OTel code @regulated -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 4. POISONED: api + NEITHER, regulated -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" regulated; ck "api, no obs @regulated -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. POISONED twin: api + NEITHER, high -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" high; ck "api, no obs @high -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. POISONED: manifest present but a pillar is FALSE, regulated -> FAIL (partial != satisfied)
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" regulated; goodman "$t"; jq '.traceparent=false' "$t/walteur-kit/observability.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/observability.json"; ck "partial manifest @regulated -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. POISONED: manifest present but a pillar MISSING, regulated -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" regulated; jq -n '{traces:true,metrics:true,logs:true}' > "$t/walteur-kit/observability.json"; ck "missing-pillar manifest @regulated -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. FALSE-POSITIVE GUARD: api + NEITHER but risk=medium -> PASS (only high/regulated blocks)
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" medium; ck "api, no obs @medium -> PASS (warn only)" 0 "$(run "$t")"; rm -rf "$t"
  # 9. FALSE-POSITIVE GUARD: api + NEITHER, no build-contract (default medium) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; ck "api, no obs, default tier -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 10. FALSE-POSITIVE GUARD: clean regulated build WITH full manifest AND OTel code -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" regulated; goodman "$t"; otelcode "$t"; ck "manifest+code @regulated -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 11. self-description must NOT count: api + regulated + a file under walteur-kit/hooks mentioning otel -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" regulated; mkdir -p "$t/walteur-kit/hooks"; printf 'grep @opentelemetry OTLP trace.getTracer\n' > "$t/walteur-kit/hooks/some-gate.sh"; ck "hooks/ self-mention not evidence -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 12. bypass -> exit 0 even on a would-fail fixture
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" regulated; WALTEUR_ROOT="$t" WALTEUR_OTEL=off bash "$0" >/dev/null 2>&1; ck "bypass WALTEUR_OTEL=off -> exit 0" 0 "$?"; rm -rf "$t"
  # 13. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" regulated; goodman "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ---- regression cases for the 3 proven red-team false-negatives ----
  blackbox() { mkdir -p "$1/src"; printf 'import express from "express";\nconst app = express();\napp.post("/api/v1/charge", (req, res) => { res.json({ ok: true }); });\napp.listen(8080);\n' > "$1/src/server.ts"; }

  # G14 (MISS-1, TYPE/ENCODING): risk_tier casing/whitespace must NOT evade the blocking case match.
  #   api + NO obs + risk_tier="High" -> must FAIL (was exit 0 because `case` was case-sensitive).
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" High; blackbox "$t"; ck "G14 risk_tier=High (casing) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" Regulated; blackbox "$t"; ck "G14b risk_tier=Regulated (casing) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # trailing-space variant (printf the raw value, no helper): "high " must normalize to high -> FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; mkdir -p "$t/walteur-kit"; printf '{"risk_tier":"high "}\n' > "$t/walteur-kit/build-contract.json"; blackbox "$t"; ck "G14c risk_tier='high ' (trailing ws) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G15 (MISS-2, SHAPE): multi-document JSON manifest stream must NOT smuggle an all-true decoy past a
  #   leading operative all-false config. Operative (first) disables all pillars; trailing decoy all-true.
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" high; mkdir -p "$t/walteur-kit"
  { printf '{"traces":false,"metrics":false,"logs":false,"traceparent":false}\n'; printf '{"traces":true,"metrics":true,"logs":true,"traceparent":true}\n'; } > "$t/walteur-kit/observability.json"
  ck "G15 multi-doc stream manifest (decoy) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G15b: top-level array wrapping an all-true object must also be rejected (length!=1 after slurp).
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" high; mkdir -p "$t/walteur-kit"; printf '[{"traces":true,"metrics":true,"logs":true,"traceparent":true}]\n' > "$t/walteur-kit/observability.json"; ck "G15b array-wrapped manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G16 (MISS-3, SEMANTIC): a bare OTel token inside a COMMENT (future-promise TODO) is NOT evidence.
  #   The only OTel mention is in a // TODO comment; no real import or call site exists -> must FAIL.
  todocode() { mkdir -p "$1/src"; printf 'import http from "http";\n\n// TODO(observability): wire up @opentelemetry/sdk-node before GA. Ticket OBS-1421.\n// For now we ship blind: no tracer, no metrics, no traceparent propagation.\nconst server = http.createServer((req, res) => { res.end(); });\nserver.listen(8080);\n' > "$1/src/server.ts"; }
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" high; todocode "$t"; ck "G16 comment-only OTel token -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G16b: block-comment /* ... @opentelemetry ... trace.getTracer(...) */ also stripped -> FAIL.
  blockcode() { mkdir -p "$1/src"; printf 'import http from "http";\n/* TODO: wire up @opentelemetry/sdk-node and trace.getTracer("svc") before GA */\nconst server = http.createServer((req, res) => { res.end(); });\nserver.listen(8080);\n' > "$1/src/server.ts"; }
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" high; blockcode "$t"; ck "G16b block-comment OTel token -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # ---- false-positive guards for the new fixes (real instrumentation must still PASS) ----
  # G17: a REAL OTel import + call site in code (not a comment) still satisfies -> PASS.
  realcode() { mkdir -p "$1/src"; printf 'import { trace } from "@opentelemetry/api";\nconst tracer = trace.getTracer("svc"); // real call site\n' > "$1/src/tel.ts"; }
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" high; realcode "$t"; ck "G17 real OTel import+call @high -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # G18: real OTel in a .mts file (widened glob) still found -> PASS.
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" high; mkdir -p "$t/src"; printf 'import { NodeSDK } from "@opentelemetry/sdk-node";\nconst sdk = new NodeSDK();\nsdk.start();\n' > "$t/src/otel.mts"; ck "G18 real OTel in .mts glob -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # G19: an honest SINGLE all-true manifest (the normal happy path) still satisfies -> PASS.
  t="$(mktemp -d "${TMPDIR:-/tmp}/otelgate.XXXXXX")"; api "$t"; risk "$t" high; goodman "$t"; ck "G19 honest single manifest @high -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "otel-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_OTEL:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_OTEL=off"; echo "otel-gate: bypassed." >&2; exit 0; }

if ! have jq; then write_report "SKIP" "jq unavailable"; echo "otel-gate: SKIP (jq unavailable)." >&2; exit 0; fi
if ! applies; then write_report "NOT_APPLICABLE" "no api boundary (has_api_boundary!=true)"; echo "otel-gate: NOT_APPLICABLE"; exit 0; fi

# risk tier (default medium). Only high/regulated block; lower tiers warn.
# NORMALIZE before matching: a human-authored contract is free text — "High"/"HIGH"/"Regulated"/"high "
# (trailing space) all denote a blocking tier. Lowercase + strip ALL whitespace so a casing/whitespace
# variant cannot fall through the case-sensitive match into the non-blocking WARN branch. Fail-closed.
risk="medium"; [ -f "$CONTRACT" ] && risk="$(jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium)"
risk="$(printf '%s' "$risk" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
[ -z "$risk" ] && risk="medium"

man_ok=no; manifest_full && man_ok=yes
code_ok=no; otel_in_code && code_ok=yes

if [ "$man_ok" = "yes" ] || [ "$code_ok" = "yes" ]; then
  src="manifest"; [ "$man_ok" = "yes" ] || src="OTel code"
  write_report "PASS" "observability satisfied via $src"
  echo "otel-gate: PASS ($src)" >&2
  exit 0
fi

# Neither: api boundary with no observability. Block at high/regulated; warn below.
add_finding "observability" "has_api_boundary build with NO observability: observability.json missing/partial (need traces+metrics+logs+traceparent all true) AND no OpenTelemetry setup in code (@opentelemetry|OTLP|trace.getTracer|opentelemetry|otel.Tracer)"
case "$risk" in
  high|regulated)
    write_report "FAIL" "api boundary at risk_tier=$risk with no traces/metrics/logs/trace-context — the edge is unobservable"
    echo "otel-gate: FAIL - unobservable api boundary at risk_tier=$risk" >&2
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
    exit 2
    ;;
  *)
    write_report "WARN" "api boundary with no observability at risk_tier=$risk — add OpenTelemetry before promoting to high/regulated"
    echo "otel-gate: WARN - no observability (risk_tier=$risk, non-blocking below high)" >&2
    exit 0
    ;;
esac
