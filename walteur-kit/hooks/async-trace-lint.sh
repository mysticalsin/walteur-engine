#!/usr/bin/env bash
# WALTEUR async-trace-lint — HARD gate (enterprise backlog rank 14). observe-lint checks that synchronous
# request handlers are traced, but trace context is silently DROPPED across async boundaries (queue / event /
# job): the producer enqueues without injecting traceparent, the consumer starts a fresh root span, and a
# production incident that crosses that hop is undebuggable — no correlation from API call to the worker that
# failed. This gate requires walteur-kit/async-trace.json to enumerate every producer→consumer hop and prove
# trace-context is INJECTED on the producer and EXTRACTED on the consumer (optionally verified by a probe).
#
# Applies when an async-messaging surface is present (signal has_async, queue/event code, or async-trace.json).
# CONTRACT: a hop with broken propagation => FAIL exit 2 · no async surface => NOT_APPLICABLE · jq absent =>
# SKIP · PAUSED => exit 2 · bypass WALTEUR_ASYNCTRACE=off · skip live probes with WALTEUR_ASYNCTRACE_PROBE=off.
# Report: walteur-kit/async-trace-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "async-trace-lint - HARD gate (enterprise backlog rank 14). observe-lint checks that synchronous"
  printf '%s\n' "usage: bash async-trace-lint.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/async-trace-report.json - fix recipes: walteur-kit/REMEDIATION.md (## async-trace-lint)"
  printf '%s\n' "bypass: WALTEUR_ASYNCTRACE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# Self-root: resolve this gate's own path so we can source the shared probe guard.
case "$0" in
  /*) SELF="$0" ;;
  *)  if [ -e "$0" ]; then SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; else SELF="$0"; fi ;;
esac
# Fail-closed shared guard: the constant-exit / no-op probe CLASS is closed by _probe-proof.sh
# (probe_proves_something) — the same kernel the 7 hardened execute-probe gates source. Source it if
# present; absence is handled fail-closed at the call site below (never a silent skip of the check).
if [ -f "${SELF%/*}/_probe-proof.sh" ]; then . "${SELF%/*}/_probe-proof.sh"; fi

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
MANIFEST="${WALTEUR_ASYNCTRACE_FILE:-$KIT/async-trace.json}"
REPORT="$KIT/async-trace-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
X="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit --exclude-dir=dist --exclude-dir=build"

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"async-trace", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"async-trace","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

# risk — read risk_tier fail-CLOSED. jq object parsing is LAST-WINS for a repeated key, so a contract
# {"risk_tier":"high",...,"risk_tier":"low"} (high to any head/grep/human reading the first key) silently
# evaluates as "low" and downgrades the gate. Defenses: (1) contract that is not a single valid JSON object
# (malformed / multi-doc / array / scalar) => HIGH floor; (2) a top-level risk_tier declared more than once
# (ambiguous) => HIGH floor; (3) otherwise the (single) declared value, defaulting to medium.
risk() {
  [ -f "$CONTRACT" ] && have jq || { echo medium; return; }
  # must be exactly one JSON value AND a single object; else ambiguous => fail closed to high
  jq -e -s 'length==1 and (.[0]|type=="object")' "$CONTRACT" >/dev/null 2>&1 || { echo high; return; }
  local dup
  dup="$(jq --stream -c 'select(length==2 and (.[0]|length)==1 and .[0][0]=="risk_tier") | 1' "$CONTRACT" 2>/dev/null | grep -c 1)"
  [ "${dup:-0}" -gt 1 ] && { echo high; return; }   # duplicate top-level risk_tier — ambiguous, fail closed
  jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo high
}
async_surface() {
  [ -f "$MANIFEST" ] && return 0
  if [ -f "$SIGNALS" ] && have jq; then jq -e '(.has_async==true) or (.has_queue==true)' "$SIGNALS" >/dev/null 2>&1 && return 0; fi
  command -v grep >/dev/null 2>&1 && grep -rIiqE --include='*.ts' --include='*.js' --include='*.py' --include='*.go' --include='*.java' $X 'kafka|sqs|rabbitmq|amqp|bullmq|bull\b|sidekiq|celery|pub[_/-]?sub|eventbridge|kinesis|nats\b|@google-cloud/pubsub|servicebus|\.enqueue|\.publish\(|\.sendMessage' "$ROOT" 2>/dev/null
}

# probe_effective — the command that ACTUALLY executes, exposed for inspection: (1) strip shell comments
# (#... to end-of-segment on each line — an attacker hides a no-op as the real command and launders the
# keyword into a `# traceparent` comment that bash discards); (2) unwrap `bash -c '<script>'` /
# `sh -c "<script>"` / `node -e '<src>'` / `python -c '<src>'` so the inner work — not the wrapper token —
# is what the no-op/tool/self-match checks see. Best-effort, fail-closed: the unwrap reveals MORE command
# text, never less, so a probe that looks inert after unwrap genuinely is.
probe_effective() {
  perl -0777 -e '
    my $p = do { local $/; <STDIN> };
    # strip shell comments: a # that starts a token (preceded by start/space/;/|/&/( ) to end-of-line
    $p =~ s/(^|[\s;|&(])#[^\n]*/$1/mg;
    # iteratively unwrap -c / -e quoted inner scripts so their contents are inspected as live command text
    for (1..4) {
      if ($p =~ /(?:^|\s)(?:bash|sh|zsh|node|deno|bun|python3?|ruby|perl|php)\s+(?:-[A-Za-z]*[ce])\s+(?:'"'"'([^'"'"']*)'"'"'|"([^"]*)"|(\S+))/) {
        my $inner = defined($1)?$1:(defined($2)?$2:$3);
        $p = $p . " ; " . $inner;   # append so we never lose the outer text either
        # remove the matched wrapper so the loop can find a nested one
        $p =~ s/(?:^|\s)(?:bash|sh|zsh|node|deno|bun|python3?|ruby|perl|php)\s+(?:-[A-Za-z]*[ce])\s+(?:'"'"'[^'"'"']*'"'"'|"[^"]*"|\S+)//;
      } else { last }
    }
    $p =~ s/\s+/ /g; $p =~ s/^\s+|\s+$//g;
    print $p;
  '
}

# run_probe — "" ONLY when a REAL propagation probe RAN and observed the trace id cross the hop; else a
# finding-reason. Hardened (D4 shared fix + comment-launder/no-op/self-match): a trivial no-op, off-allowlist
# /missing command, whitespace probe, a probe that references no trace context, a probe whose EFFECTIVE
# (comment-stripped, -c/-e-unwrapped) command runs only inert builtins with NO real network/db/test tool, or
# a self-fulfilling tautology that echoes the trace keyword and greps its own output — none observe a trace
# crossing the hop; all FAIL closed.
#
# Unify probe hardening: the constant-exit/no-op CLASS (true/false/:/empty/`bash -lc "exit 0"`/`node -e` etc.
# that exit green while proving no propagation) is now judged by the SHARED kernel _probe-proof.sh
# (probe_proves_something) instead of a bespoke per-gate case-statement — one hardened kernel, not six
# diverging copies. A probe passes this stage if EITHER the shared kernel recognizes it as a real test-runner/
# on-disk-artifact invocation, OR the domain-specific real-tool regex finds a genuine network/db/test tool in
# the EFFECTIVE (unwrapped) command. FAIL CLOSED if the shared guard file was absent at source time (function
# undefined): never silently skip the no-op check.
run_probe() { # $1
  local probe="$1" pfirst low eff efflow
  printf '%s' "$probe" | grep -q '[^[:space:]]' || { printf 'empty/whitespace probe — observes no trace; not verification'; return; }
  printf '%s' "$probe" | grep -Eqi 'rm[[:space:]]+-rf|mkfs|[[:space:]]dd[[:space:]]|/dev/tcp|/etc/(passwd|shadow)|\|[[:space:]]*(bash|sh)([[:space:]]|$)' && { printf 'destructive token; refused'; return; }
  if ! command -v probe_proves_something >/dev/null 2>&1; then
    printf 'shared probe guard (_probe-proof.sh) unavailable — cannot prove the probe is non-trivial; failing closed'; return
  fi
  # EFFECTIVE command: comments stripped, -c/-e inner scripts unwrapped (see probe_effective)
  eff="$(printf '%s' "$probe" | probe_effective)"
  [ -n "$eff" ] || eff="$probe"
  printf '%s' "$eff" | grep -q '[^[:space:]]' || { printf 'probe is only comments / whitespace after stripping — observes no trace; not verification'; return; }
  efflow="$(printf '%s' "$eff" | tr 'A-Z' 'a-z')"
  pfirst="$(printf '%s' "$probe" | awk '{print $1}')"
  # REQUIRE either the shared kernel to recognize the probe (real test-runner / on-disk artifact) or a real
  # verification tool in the EFFECTIVE (unwrapped) command. A wrapper like `bash -lc 'exit 0'` or
  # `bash -c 'echo deny; true'` exposes only inert builtins after unwrap and has NO real network/db/test tool
  # actually sourcing data across the hop — it is a no-op masquerade, not verification.
  if probe_proves_something "$eff"; then :;
  elif printf '%s' "$efflow" | grep -Eqw 'curl|wget|http|httpie|node|deno|bun|python|python3|npx|psql|mysql|redis-cli|mongo|mongosh|grpcurl|amqp|kafkacat|kcat|nats|aws|gcloud|go|cargo|jq|nc|ncat|socat'; then :; else
    printf "probe ('%s') is a constant-exit/no-op — effective command runs only shell builtins (echo/printf/:/true/test) with no real network/db/test tool to source the trace across the hop — not verification" "$pfirst"; return; fi
  # SELF-MATCH tautology: the trace keyword is PRODUCED by a literal echo/printf inside the probe and then
  # grepped from that same echo — the probe observes its own output, never a trace crossing the hop. Reject
  # unless a real verification tool (not echo/printf/grep/jq) actually sources the data.
  if printf '%s' "$efflow" | grep -Eq '(echo|printf)[^|]*(traceparent|trace[_-]?id|trace[_-]?context|x-b3|span[_-]?id|correlation)[^|]*\|[^|]*grep'; then
    printf '%s' "$efflow" | grep -Eqw 'curl|wget|http|httpie|node|deno|bun|python|python3|npx|psql|mysql|redis-cli|mongo|mongosh|grpcurl|amqp|kafkacat|kcat|nats|aws|gcloud|nc|ncat|socat' \
      || { printf 'self-fulfilling probe: echoes the trace keyword and greps its own output — observes no trace crossing the hop; source the trace id from the real producer/consumer (queue, collector, header)'; return; }
  fi
  low="$(printf '%s' "$probe" | tr 'A-Z' 'a-z')"
  printf '%s' "$low" | grep -Eq 'traceparent|trace[_-]?id|trace[_-]?context|propagat|x-b3|span[_-]?id|correlation' || { printf 'probe references no trace context (traceparent/trace-id/propagation) — cannot confirm the trace crossed the hop'; return; }
  (cd "$ROOT" && eval "$probe" >/dev/null 2>&1) || printf 'trace context was LOST across the hop (probe did not observe the propagated trace id)'
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "async-trace selftest SKIP - jq not installed."; return 0; fi
  echo "async-trace-lint selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  asy() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${2:-high}" > "$1/walteur-kit/build-contract.json"; printf '{"has_async":true}\n' > "$1/walteur-kit/preflight-signals.json";
          # captured-trace fixtures: stand in for a message the probe reads back across the hop with a REAL tool
          printf '{"headers":{"traceparent":"00-abc-def-01"}}\n' > "$1/walteur-kit/captured-trace.json";
          printf '{"headers":{}}\n' > "$1/walteur-kit/captured-none.json"; }
  goodman() { jq -n --arg p "$1" '{hops:[{name:"api->worker",queue:"jobs",producer_injects:true,consumer_extracts:true,probe_command:$p},{name:"worker->email",queue:"email",producer_injects:true,consumer_extracts:true}]}' > "$2/walteur-kit/async-trace.json"; }
  # HONEST probes use a REAL tool (jq) to read a captured message back across the hop; the trace id is sourced
  # from a fixture FILE, not echoed inside the probe (no self-match). PASS: traceparent present -> exit 0.
  # FAIL: probe references traceparent but the captured message lacks it -> non-zero (context was LOST).
  PASS_PROBE='jq -e ".headers.traceparent | test(\"^00-\")" walteur-kit/captured-trace.json'
  FAIL_PROBE='jq -e ".headers.traceparent | test(\"^00-\")" walteur-kit/captured-none.json'

  # 1. no async surface -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"has_async":false}\n' > "$t/walteur-kit/preflight-signals.json"; printf 'export const x=1;\n' > "$t/a.ts"; ck "no async surface -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. async + all hops propagate -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "$PASS_PROBE" "$t"; ck "all hops propagate -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. async + high-risk + no manifest -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t" high; ck "high-risk, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. producer does not inject -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "$PASS_PROBE" "$t"; jq '.hops[0].producer_injects=false' "$t/walteur-kit/async-trace.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/async-trace.json"; ck "producer no-inject -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. consumer does not extract -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "$PASS_PROBE" "$t"; jq '.hops[1].consumer_extracts=false' "$t/walteur-kit/async-trace.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/async-trace.json"; ck "consumer no-extract -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. probe shows trace lost -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "$FAIL_PROBE" "$t"; ck "probe trace-lost -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. broken hop signed-deferred at low risk -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t" low; jq -n '{hops:[{name:"api->worker",producer_injects:false,consumer_extracts:true,deferral:{owner:"Tony",ticket:"OBS-1",review_trigger:"GA"}}]}' > "$t/walteur-kit/async-trace.json"; ck "broken hop deferred at low risk -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 8. broken hop signed-deferred at high risk -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t" high; jq -n '{hops:[{name:"api->worker",producer_injects:false,consumer_extracts:true,deferral:{owner:"Tony",ticket:"OBS-1",review_trigger:"GA"}}]}' > "$t/walteur-kit/async-trace.json"; ck "broken hop deferred at high risk -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "$FAIL_PROBE" "$t"; WALTEUR_ROOT="$t" WALTEUR_ASYNCTRACE=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # ── D4 shared probe-bypass regressions (propagation semantics) ──
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "true" "$t"; ck "G1 trivial true probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "./trace-test.sh" "$t"; ck "G2 off-allowlist probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman " " "$t"; ck "G3 whitespace probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "bash -c 'echo ok | grep -q ok'" "$t"; ck "G4 no-trace-reference probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # ── gauntlet misses (comment-launder / self-match / duplicate-key) ──
  # G5 (Miss 1): `bash -c ': traceparent; exit 0'` — inert ':' hidden inside -c, keyword laundered as arg, exits 0. FAIL closed.
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman 'bash -c ": traceparent; exit 0"' "$t"; ck "G5 comment/no-op-launder probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G5b: keyword laundered into a discarded shell comment over an inert command. FAIL closed.
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman 'bash -c "true # traceparent deny 403"' "$t"; ck "G5b comment-laundered keyword probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G6 (Miss 3): self-fulfilling tautology — echoes the trace keyword then greps its own output, no real tool. FAIL closed.
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "bash -c 'echo traceparent=00-abc-def-01 | grep -q traceparent'" "$t"; ck "G6 self-match tautology probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G7 (Miss 2): duplicate top-level risk_tier (high...low) must NOT downgrade — manifest absent at high floor => FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '%s\n' '{"risk_tier":"high","service":"x","risk_tier":"low"}' > "$t/walteur-kit/build-contract.json"; printf '{"has_async":true}\n' > "$t/walteur-kit/preflight-signals.json"; ck "G7 duplicate-key risk downgrade -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G7b: malformed / multi-doc contract is ambiguous => HIGH floor; manifest absent => FAIL (fail-closed).
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '%s\n' '{"risk_tier":"low"}{"risk_tier":"low"}' > "$t/walteur-kit/build-contract.json"; printf '{"has_async":true}\n' > "$t/walteur-kit/preflight-signals.json"; ck "G7b multi-doc contract -> FAIL (high floor)" 2 "$(run "$t")"; rm -rf "$t"
  # G7c FALSE-POSITIVE GUARD: a legitimately-nested risk_tier (top-level low, nested unrelated) is NOT a dup => stays low => NA exit 0.
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '%s\n' '{"risk_tier":"low","meta":{"risk_tier":"high"}}' > "$t/walteur-kit/build-contract.json"; printf '{"has_async":true}\n' > "$t/walteur-kit/preflight-signals.json"; ck "G7c nested risk_tier not a dup -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # G8 FALSE-POSITIVE GUARD: an HONEST real-tool probe carrying a harmless trailing comment still PASSES (no over-block).
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "$PASS_PROBE # verifies traceparent crossed api->worker" "$t"; ck "G8 real probe + harmless comment -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # ── Unify probe hardening: shared _probe-proof.sh kernel poison classes (constant-exit/no-op) ──
  # G9 — "false" no-op probe -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "false" "$t"; ck "G9 false no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G10 — ":" no-op probe -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman ":" "$t"; ck "G10 ':' no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G11 — "bash -lc 'exit 0'" constant-exit no-op (the class the shared kernel names by name) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "bash -lc 'exit 0'" "$t"; ck "G11 bash -lc exit-0 no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G12 — shared guard fail-closed: if _probe-proof.sh is unavailable at source time, a probe must FAIL
  # closed rather than silently skip the no-op check. Simulate by pointing the gate at a copy of itself
  # with the sibling guard file temporarily hidden.
  t="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; asy "$t"; goodman "$PASS_PROBE" "$t"
  gdir="$(mktemp -d "${TMPDIR:-/tmp}/asynctrace.XXXXXX")"; cp "$SELF" "$gdir/async-trace-lint.sh"
  ck "G12 guard file absent -> FAIL (fail-closed)" 2 "$(WALTEUR_ROOT="$t" bash "$gdir/async-trace-lint.sh" >/dev/null 2>&1; echo $?)"
  rm -rf "$t" "$gdir"

  echo "async-trace-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_ASYNCTRACE:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_ASYNCTRACE=off"; echo "async-trace-lint: bypassed." >&2; exit 0; }

if ! async_surface; then write_report "NOT_APPLICABLE" "no async-messaging surface"; echo "async-trace-lint: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "async-trace-lint: SKIP." >&2; exit 0; fi

RISK="$(risk)"
if [ ! -s "$MANIFEST" ]; then
  case "$RISK" in
    high|regulated) add_finding "manifest" "async-messaging surface at $RISK risk but no walteur-kit/async-trace.json — enumerate each producer→consumer hop and prove trace-context propagation"
      write_report "FAIL" "async-trace manifest absent at $RISK risk"; echo "async-trace-lint: FAIL - manifest absent" >&2; exit 2 ;;
    *) write_report "NOT_APPLICABLE" "no async-trace.json and risk_tier=$RISK below the required floor"; echo "async-trace-lint: NOT_APPLICABLE ($RISK risk)"; exit 0 ;;
  esac
fi
jq -e '.hops | type=="array" and length>=1' "$MANIFEST" >/dev/null 2>&1 || add_finding "hops" "async-trace.json must enumerate >=1 producer->consumer hop"

while IFS= read -r hop; do
  [ -n "$hop" ] || continue
  nm="$(printf '%s' "$hop" | jq -r '.name // "hop"')"
  inj="$(printf '%s' "$hop" | jq -r '.producer_injects // false')"
  ext="$(printf '%s' "$hop" | jq -r '.consumer_extracts // false')"
  deferred="$(printf '%s' "$hop" | jq -e '.deferral.owner and .deferral.ticket and .deferral.review_trigger' >/dev/null 2>&1 && echo yes || echo no)"
  broken=no
  [ "$inj" = "true" ] || broken=yes
  [ "$ext" = "true" ] || broken=yes
  if [ "$broken" = "yes" ]; then
    if [ "$deferred" = "yes" ]; then
      case "$RISK" in high|regulated) add_finding "$nm" "trace propagation broken (producer_injects=$inj, consumer_extracts=$ext) and cannot be signed-deferred at risk_tier=$RISK";; esac
    else
      add_finding "$nm" "broken trace propagation: producer_injects=$inj, consumer_extracts=$ext — inject W3C traceparent on enqueue and extract it in the consumer (or sign a deferral)"
    fi
  else
    probe="$(printf '%s' "$hop" | jq -r '.probe_command // ""')"
    if [ -n "$probe" ] && [ "${WALTEUR_ASYNCTRACE_PROBE:-on}" != "off" ]; then res="$(run_probe "$probe")"; [ -n "$res" ] && add_finding "$nm" "$res (ran: $probe)"; fi
  fi
done < <(jq -c '.hops[]?' "$MANIFEST" 2>/dev/null)

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures async-trace violation(s)"
  echo "async-trace-lint: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "trace context injected by every producer and extracted by every consumer across all async hops"
echo "async-trace-lint: PASS" >&2
exit 0
