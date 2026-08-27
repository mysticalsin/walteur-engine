#!/usr/bin/env bash
# WALTEUR observe-probe — DETECT-OR-SKIP live-service observability probe.
# This gate proves a RUNNING service satisfies the observability contract at runtime. It needs:
#   (a) a base URL of a running service  — env WALTEUR_PROBE_URL (or arg $1), e.g. http://localhost:8080
#   (b) curl                            — to make the HTTP calls
# If EITHER is absent => print a LOUD recorded SKIP to stderr + write verdict:SKIP + exit 0.
# NEVER silent-green, NEVER exit 2 for a missing prerequisite. A reachable service that FAILS a
# check => exit 2.
#
# Checks it RUNS when a service URL + curl are present (each maps to the observability contract):
#   C1  GET <base>/healthz            -> expect HTTP 200            (liveness: process is up)
#   C2  GET <base>/readyz             -> expect 200 when deps OK; this gate additionally asserts
#                                        readiness returns 503 WHEN A DEPENDENCY IS DOWN — driven by
#                                        WALTEUR_PROBE_DEP_DOWN=1 (the harness stops a dep, then
#                                        re-probes; 200-while-dep-down is a readiness LIE => fail).
#                                        (contract: health.liveness_distinct_from_readiness +
#                                         health.readiness_checks_deps)
#   C3  GET <base>/metrics            -> expect a Prometheus latency HISTOGRAM: a line matching
#                                        `<name>_bucket{...le="..."} <n>` for a *_seconds / *_duration
#                                        / *_latency family. A bare gauge/summary-without-buckets for
#                                        latency => fail. (contract: metrics.latency_is_histogram)
#   C4  GET <base>/healthz (or any traced route) with a W3C `traceparent` request header
#                                     -> expect the response to carry a trace id back (traceparent /
#                                        x-trace-id / trace-id response header), proving context
#                                        propagation is wired. (contract: tracing.context_propagation)
#
# Tunables (all optional):
#   WALTEUR_PROBE_URL / $1     base URL (REQUIRED to run; absent => SKIP)
#   WALTEUR_PROBE_HEALTH_PATH  default /healthz
#   WALTEUR_PROBE_READY_PATH   default /readyz
#   WALTEUR_PROBE_METRICS_PATH default /metrics
#   WALTEUR_PROBE_DEP_DOWN     set to 1 when a dependency is intentionally down (asserts readyz==503)
#   WALTEUR_PROBE_TIMEOUT      per-request curl timeout seconds, default 5
# Bypass: WALTEUR_OBSERVE_PROBE=off.
# Report: walteur-kit/observe-probe-report.json  {verdict, ts, gate, base_url, checks, details}.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/observe-probe-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

BASE="${1:-${WALTEUR_PROBE_URL:-}}"
J='{}'
add() { J="$(printf '%s' "$J" | jq --argjson v "$2" --arg k "$1" '.[$k]=$v' 2>/dev/null || printf '%s' "$J")"; }

write_report() { # $1=verdict  $2=reason
  jq -n --arg v "$1" --arg ts "$TS" --arg reason "$2" --arg base "${BASE:-}" --argjson checks "$J" \
    '{verdict:$v, ts:$ts, gate:"observe-probe", base_url:$base, reason:$reason, details:$checks}' > "$REPORT" 2>/dev/null \
  || printf '{"verdict":"%s","ts":"%s","gate":"observe-probe","reason":"%s"}\n' "$1" "$TS" "$2" > "$REPORT"
}

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_OBSERVE_PROBE:-on}" = "off" ] && { echo "observe-probe: bypassed (WALTEUR_OBSERVE_PROBE=off)." >&2; write_report "SKIP" "bypassed (WALTEUR_OBSERVE_PROBE=off)"; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }

# jq is needed to write a structured report; if even jq is absent, stay honest.
if ! have jq; then
  echo "WALTEUR observe-probe SKIP — required tool 'jq' not installed (recorded, not silent-green)." >&2
  printf '{"verdict":"SKIP","ts":"%s","gate":"observe-probe","reason":"jq not installed"}\n' "$TS" > "$REPORT"
  exit 0
fi

# ── DETECT-OR-SKIP gate 1: a running service URL must be provided ──────────────
if [ -z "$BASE" ]; then
  cat >&2 <<'SKIPMSG'
============================================================================
WALTEUR observe-probe  ::  LOUD SKIP — NO RUNNING SERVICE PROVIDED
----------------------------------------------------------------------------
This gate verifies a LIVE service at runtime; it cannot run against source.
Provide a base URL to enable it:   WALTEUR_PROBE_URL=http://localhost:8080
                              or:   bash observe-probe.sh http://localhost:8080

It WOULD run these checks against the contract:
  C1 GET /healthz   -> 200                       (liveness: process up)
  C2 GET /readyz    -> 200 when deps OK;
                       503 when a dependency is down (set WALTEUR_PROBE_DEP_DOWN=1)
  C3 GET /metrics   -> latency exposed as a Prometheus HISTOGRAM
                       (..._bucket{le="..."}) — not a gauge/average
  C4 GET /healthz with W3C `traceparent` header
                    -> response echoes a trace id (context propagation wired)
Recorded as SKIP; NOT counted green.
============================================================================
SKIPMSG
  write_report "SKIP" "no running service URL (set WALTEUR_PROBE_URL or pass it as \$1)"
  exit 0
fi

# ── DETECT-OR-SKIP gate 2: curl must be installed ─────────────────────────────
if ! have curl; then
  echo "WALTEUR observe-probe SKIP — 'curl' not installed; cannot probe $BASE. Recorded; NOT counted green." >&2
  write_report "SKIP" "curl not installed"
  exit 0
fi

BASE="${BASE%/}"
HEALTH_PATH="${WALTEUR_PROBE_HEALTH_PATH:-/healthz}"
READY_PATH="${WALTEUR_PROBE_READY_PATH:-/readyz}"
METRICS_PATH="${WALTEUR_PROBE_METRICS_PATH:-/metrics}"
TO="${WALTEUR_PROBE_TIMEOUT:-5}"
TMP="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"; HDR="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"; trap 'rm -f "$TMP" "$HDR"' EXIT

echo "WALTEUR observe-probe @ $BASE (health=$HEALTH_PATH ready=$READY_PATH metrics=$METRICS_PATH dep_down=${WALTEUR_PROBE_DEP_DOWN:-0})" >&2

# ── reachability pre-check: if the service is unreachable, that is a SKIP, not a fail ──
if ! curl -s -o /dev/null --max-time "$TO" "$BASE$HEALTH_PATH" 2>/dev/null \
   && ! curl -s -o /dev/null --max-time "$TO" "$BASE/" 2>/dev/null; then
  echo "WALTEUR observe-probe SKIP — service at $BASE is unreachable (no liveness/root response within ${TO}s). Recorded; NOT counted green." >&2
  write_report "SKIP" "service unreachable at $BASE"
  exit 0
fi

violations=0
# code_of <path> [extra-curl-args...] -> prints the HTTP status code (000 on transport error)
code_of() { local p="$1"; shift; curl -s -o "$TMP" -w '%{http_code}' --max-time "$TO" "$@" "$BASE$p" 2>/dev/null || echo 000; }

# ── C1: /healthz == 200 ────────────────────────────────────────────────────────
c1="$(code_of "$HEALTH_PATH")"
if [ "$c1" = "200" ]; then
  echo "  ok   — C1 liveness: GET $HEALTH_PATH -> 200" >&2
  add c1_liveness "$(jq -n --arg p "$HEALTH_PATH" '{verdict:"PASS",check:"liveness 200",path:$p,code:200}')"
else
  echo "  FAIL — C1 liveness: GET $HEALTH_PATH -> $c1 (want 200)" >&2
  violations=$((violations+1))
  add c1_liveness "$(jq -n --arg p "$HEALTH_PATH" --arg c "$c1" '{verdict:"FAIL",check:"liveness 200",path:$p,code:($c|tonumber? // 0),expected:200}')"
fi

# ── C2: /readyz — 200 normally; 503 when a dependency is down ──────────────────
c2="$(code_of "$READY_PATH")"
if [ "${WALTEUR_PROBE_DEP_DOWN:-0}" = "1" ]; then
  # A dependency is intentionally down: readiness MUST fail (503). 200 = readiness lies about deps.
  if [ "$c2" = "503" ]; then
    echo "  ok   — C2 readiness(dep-down): GET $READY_PATH -> 503 (correctly NOT ready)" >&2
    add c2_readiness "$(jq -n --arg p "$READY_PATH" '{verdict:"PASS",check:"readiness 503 when dep down",path:$p,code:503,dep_down:true}')"
  else
    echo "  FAIL — C2 readiness(dep-down): GET $READY_PATH -> $c2 (want 503; 200 = readiness lies about a downed dependency)" >&2
    violations=$((violations+1))
    add c2_readiness "$(jq -n --arg p "$READY_PATH" --arg c "$c2" '{verdict:"FAIL",check:"readiness 503 when dep down",path:$p,code:($c|tonumber? // 0),expected:503,dep_down:true}')"
  fi
else
  # Deps assumed healthy: readiness should be 200.
  if [ "$c2" = "200" ]; then
    echo "  ok   — C2 readiness(deps-up): GET $READY_PATH -> 200" >&2
    add c2_readiness "$(jq -n --arg p "$READY_PATH" '{verdict:"PASS",check:"readiness 200 when deps up",path:$p,code:200,dep_down:false}')"
  else
    echo "  FAIL — C2 readiness(deps-up): GET $READY_PATH -> $c2 (want 200)" >&2
    violations=$((violations+1))
    add c2_readiness "$(jq -n --arg p "$READY_PATH" --arg c "$c2" '{verdict:"FAIL",check:"readiness 200 when deps up",path:$p,code:($c|tonumber? // 0),expected:200,dep_down:false}')"
  fi
fi

# ── C3: /metrics exposes a latency HISTOGRAM (..._bucket{le="..."}) ────────────
cm="$(code_of "$METRICS_PATH")"
if [ "$cm" = "200" ]; then
  # A latency histogram bucket line: <name>_bucket{ ... le="..." } <value>
  # for a latency-ish family (seconds/duration/latency/request). Gauges/summaries lack _bucket.
  if grep -qE '(_seconds|_duration|latency|request[A-Za-z_]*)[A-Za-z0-9_]*_bucket\{[^}]*le=' "$TMP" 2>/dev/null \
     || grep -qE '_bucket\{[^}]*le=' "$TMP" 2>/dev/null && grep -qiE 'latency|duration|_seconds' "$TMP" 2>/dev/null; then
    echo "  ok   — C3 metrics: latency histogram buckets present at $METRICS_PATH" >&2
    add c3_histogram "$(jq -n --arg p "$METRICS_PATH" '{verdict:"PASS",check:"latency exposed as histogram (_bucket{le=})",path:$p}')"
  else
    echo "  FAIL — C3 metrics: no latency histogram buckets (_bucket{le=...}) at $METRICS_PATH — latency must be a histogram, not a gauge/average" >&2
    violations=$((violations+1))
    add c3_histogram "$(jq -n --arg p "$METRICS_PATH" '{verdict:"FAIL",check:"latency exposed as histogram (_bucket{le=})",path:$p,reason:"no _bucket{le=...} latency series found"}')"
  fi
else
  echo "  FAIL — C3 metrics: GET $METRICS_PATH -> $cm (want 200 with Prometheus exposition)" >&2
  violations=$((violations+1))
  add c3_histogram "$(jq -n --arg p "$METRICS_PATH" --arg c "$cm" '{verdict:"FAIL",check:"metrics endpoint reachable",path:$p,code:($c|tonumber? // 0),expected:200}')"
fi

# ── C4: trace-context propagation — send traceparent, expect a trace id back ───
TRACEPARENT='00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'
ccode="$(curl -s -D "$HDR" -o /dev/null -w '%{http_code}' --max-time "$TO" \
          -H "traceparent: $TRACEPARENT" "$BASE$HEALTH_PATH" 2>/dev/null || echo 000)"
if [ "$ccode" = "200" ] || [ "$ccode" = "204" ]; then
  if grep -qiE '^(traceparent|x-trace-id|trace-id|x-b3-traceid|x-amzn-trace-id):' "$HDR" 2>/dev/null; then
    echo "  ok   — C4 tracing: response echoes a trace id (context propagation wired)" >&2
    add c4_trace_propagation "$(jq -n '{verdict:"PASS",check:"trace context propagated (trace id in response headers)"}')"
  else
    echo "  FAIL — C4 tracing: sent traceparent but response carries no trace id header (context propagation not wired)" >&2
    violations=$((violations+1))
    add c4_trace_propagation "$(jq -n '{verdict:"FAIL",check:"trace context propagated",reason:"no traceparent/x-trace-id in response headers"}')"
  fi
else
  echo "  FAIL — C4 tracing: GET $HEALTH_PATH (with traceparent) -> $ccode (want 200/204)" >&2
  violations=$((violations+1))
  add c4_trace_propagation "$(jq -n --arg c "$ccode" '{verdict:"FAIL",check:"trace context propagated",code:($c|tonumber? // 0)}')"
fi

if [ "$violations" -gt 0 ]; then OVERALL=FAIL; else OVERALL=PASS; fi
write_report "$OVERALL" "$([ "$OVERALL" = PASS ] && echo 'all live observability checks passed' || echo "$violations live observability check(s) failed")"
echo "observe-probe verdict: $OVERALL (violations=$violations) -> $REPORT" >&2
[ "$OVERALL" = "FAIL" ] && exit 2
exit 0
