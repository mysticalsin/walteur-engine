#!/usr/bin/env bash
# WALTEUR perf-gate — performance discipline gate. Tail latency is a first-class budget, not slop.
#
# APPLICABILITY FIRST. The gate applies only if a perf/load context exists:
#   (a) walteur-kit/perf-budget.json is present, OR
#   (b) a SERVICE entrypoint exists — a server/app/main file that wires an HTTP listener
#       (listen( / http.Serve / app.run / FastAPI() / express() / Flask( ... ), OR
#   (c) a load script for k6 / wrk / locust exists (k6 *.js with import 'k6', wrk *.lua, locustfile).
#   If NONE of these exist (a bare/minimal project) => {"verdict":"NOT_APPLICABLE"} + exit 0.
#   exit 2 is ONLY for a real violation in an APPLICABLE project.
#
# Layer 1 — ZERO-DEP HARD RULES (bash/grep/jq/awk/find/sed — always run, real exit 2):
#   1a. If walteur-kit/perf-budget.json exists, EVERY critical_path MUST declare a non-null
#       p99 AND p999. A budget without tail latency is the slop we forbid => exit 2 if any missing.
#       (Also: the file must be valid JSON with a non-empty critical_paths array.)
#   1b. If a SERVICE entrypoint exists but NO perf-budget.json is present => perf is UNBUDGETED
#       => exit 2. (A service that ships traffic with no latency budget is forbidden.)
#       A pure load-script context (no service, no budget) is APPLICABLE but does not trip 1b —
#       the load script IS the perf artefact; absent a budget there is nothing to validate, so it
#       PASSES the zero-dep layer and falls through to the detect-or-skip layer.
#
# Layer 2 — DETECT-OR-LOUD-SKIP UPGRADES (heavy tools; tool absent => loud SKIP + exit 0):
#   2a. k6 OR wrk2 present + a load script present => run it, parse the achieved p99, diff against a
#       committed baseline (walteur-kit/perf-baseline.json or .hdr). >10% p99 regression => exit 2.
#   2b. `go test -race` present (go on PATH) + shared-state Go code => run the race detector;
#       a detected data race => exit 2.
#   Any heavy tool absent => print a LOUD SKIP to stderr + record it. NEVER silent-green,
#   NEVER exit 2 for a missing tool.
#
# Report: walteur-kit/perf-report.json {verdict, ts, gate, reason, details}.
# Bypass: WALTEUR_PERF=off.  Pause: walteur-kit/PAUSED.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "perf-gate - performance discipline gate. Tail latency is a first-class budget, not slop."
  printf '%s\n' "usage: bash perf-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/perf-report.json - fix recipes: walteur-kit/REMEDIATION.md (## perf-gate)"
  printf '%s\n' "bypass: WALTEUR_PERF=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/perf-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_PERF:-on}" = "off" ] && { echo "perf-gate: bypassed (WALTEUR_PERF=off)." >&2; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }
loud_skip() { echo "  SKIP — $1 not installed ($2). Recorded; NOT counted green." >&2; }

# write_report <verdict> <reason> <details-json-object>
# Falls back to printf if jq is unavailable so a report ALWAYS lands.
write_report() {
  local v="$1" reason="$2" details="${3:-{\}}"
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --argjson d "$details" \
      '{verdict:$v, ts:$ts, gate:"perf", reason:$reason, details:$d}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"perf","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
}

selftest() {
  local pass=0 fail=0 tmp rc
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  ck() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  echo "perf-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/perf-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no perf context -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/perf-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'const app = require("express")(); app.listen(3000);\n' > "$tmp/server.js"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "service without perf budget -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/perf-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{"critical_paths":[{"name":"home","p99":200}]}\n' > "$tmp/walteur-kit/perf-budget.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "budget missing p999 -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/perf-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{"critical_paths":[{"name":"home","p99":200,"p999":500}]}\n' > "$tmp/walteur-kit/perf-budget.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "tail budget with p99 and p999 -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/perf-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'const app = require("express")(); app.listen(3000);\n' > "$tmp/server.js"
  WALTEUR_ROOT="$tmp" WALTEUR_PERF=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/perf-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "perf-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

# Standard prune set so we never trip on VCS / deps / build / the kit itself.
PRUNE=( -path "$ROOT/.git" -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/venv' \
        -o -path '*/dist' -o -path '*/build' -o -path '*/target' -o -path '*/vendor' -o -path "$KIT" )

# ── budget ────────────────────────────────────────────────────────────────────
BUDGET="$KIT/perf-budget.json"
HAS_BUDGET="no"; [ -f "$BUDGET" ] && HAS_BUDGET="yes"

# ── detect a SERVICE entrypoint (server/app/main wiring an HTTP listener) ──────
# We look for files whose basename hints at an entrypoint AND whose content wires HTTP serving.
SERVICE_FILE=""
detect_service() {
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$(basename "$f" | tr 'A-Z' 'a-z')" in
      server.*|app.*|main.*|index.*|wsgi.*|asgi.*|cmd.go|httpd.*|api.*)
        # Content must look like it stands up an HTTP listener / web app.
        if grep -qiE '\.listen\(|http\.(ListenAndServe|Serve)|ListenAndServe|app\.run\(|uvicorn|gunicorn|FastAPI\(|Flask\(|express\(|http\.createServer|net/http|actix_web|axum::|fiber\.New|gin\.(Default|New)\(' "$f" 2>/dev/null; then
          SERVICE_FILE="$f"; return 0
        fi
        ;;
    esac
  done <<EOF
$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \
    \( -name '*.go' -o -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.mjs' \
       -o -name '*.rs' -o -name '*.java' -o -name '*.rb' \) -type f -print 2>/dev/null)
EOF
  return 1
}
detect_service || true
HAS_SERVICE="no"; [ -n "$SERVICE_FILE" ] && HAS_SERVICE="yes"

# ── detect a LOAD script (k6 / wrk / locust) ──────────────────────────────────
LOAD_SCRIPT=""; LOAD_KIND=""
detect_load_script() {
  local f
  # k6: a JS file importing the k6 module (bare 'k6' or a submodule like 'k6/http', 'k6/metrics').
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if grep -qE "(from[[:space:]]+['\"]k6(/[a-zA-Z0-9_-]+)?['\"]|require\(['\"]k6(/[a-zA-Z0-9_-]+)?['\"]\))" "$f" 2>/dev/null; then
      LOAD_SCRIPT="$f"; LOAD_KIND="k6"; return 0
    fi
  done <<EOF
$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -name '*.js' -type f -print 2>/dev/null)
EOF
  # locust: a locustfile.py or any *.py defining an HttpUser / TaskSet.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    base="$(basename "$f" | tr 'A-Z' 'a-z')"
    if [ "$base" = "locustfile.py" ] || grep -qE 'from[[:space:]]+locust[[:space:]]+import|HttpUser|locust\.' "$f" 2>/dev/null; then
      LOAD_SCRIPT="$f"; LOAD_KIND="locust"; return 0
    fi
  done <<EOF
$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -name '*.py' -type f -print 2>/dev/null)
EOF
  # wrk: a *.lua script that defines wrk hooks (request/response/setup).
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if grep -qE 'wrk\.(format|method|headers|body)|function[[:space:]]+(request|response|setup)\(' "$f" 2>/dev/null; then
      LOAD_SCRIPT="$f"; LOAD_KIND="wrk"; return 0
    fi
  done <<EOF
$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -name '*.lua' -type f -print 2>/dev/null)
EOF
  return 1
}
detect_load_script || true
HAS_LOAD="no"; [ -n "$LOAD_SCRIPT" ] && HAS_LOAD="yes"

# ── APPLICABILITY GATE ────────────────────────────────────────────────────────
if [ "$HAS_BUDGET" = "no" ] && [ "$HAS_SERVICE" = "no" ] && [ "$HAS_LOAD" = "no" ]; then
  echo "perf-gate: no perf/load context (no perf-budget.json, no HTTP service entrypoint, no k6/wrk/locust script) — gate not applicable." >&2
  if have jq; then
    write_report "NOT_APPLICABLE" "no perf/load context" \
      "$(jq -n '{has_budget:false, has_service:false, has_load_script:false}')"
  else
    write_report "NOT_APPLICABLE" "no perf/load context" '{}'
  fi
  exit 0
fi

echo "WALTEUR perf-gate @ $ROOT — budget=$HAS_BUDGET service=${SERVICE_FILE:-none} load=${LOAD_SCRIPT:-none}" >&2

# ── LAYER 1a: budget present => every critical_path needs non-null p99 AND p999 ─
if [ "$HAS_BUDGET" = "yes" ]; then
  if ! have jq; then
    # jq is a hard prerequisite for the zero-dep budget validation. Without it we cannot
    # honestly validate tail latency — refuse to silent-green. (jq is a zero-dep tool here.)
    echo "WALTEUR perf-gate: FAIL — perf-budget.json present but jq unavailable to validate it." >&2
    write_report "FAIL" "perf-budget.json present but jq unavailable to validate tail-latency rule" '{}'
    exit 2
  fi
  if ! jq -e . "$BUDGET" >/dev/null 2>&1; then
    echo "WALTEUR perf-gate: FAIL — perf-budget.json is not valid JSON." >&2
    write_report "FAIL" "perf-budget.json is not valid JSON" \
      "$(jq -n --arg b "$BUDGET" '{budget_file:$b, valid_json:false}')"
    exit 2
  fi
  # Must have a non-empty critical_paths array.
  CP_COUNT="$(jq -r '(.critical_paths // []) | length' "$BUDGET" 2>/dev/null || echo 0)"
  if [ "${CP_COUNT:-0}" -lt 1 ]; then
    echo "WALTEUR perf-gate: FAIL — perf-budget.json has no critical_paths." >&2
    write_report "FAIL" "perf-budget.json has no critical_paths" \
      "$(jq -n --arg b "$BUDGET" '{budget_file:$b, critical_paths:0}')"
    exit 2
  fi
  # The slop check: any critical_path whose p99 OR p999 is null/absent.
  MISSING="$(jq -r '
    [ .critical_paths[]
      | select((.p99 == null) or (.p999 == null) or (has("p99")|not) or (has("p999")|not))
      | (.name // "<unnamed>") ] | join(", ")' "$BUDGET" 2>/dev/null || echo "")"
  if [ -n "$MISSING" ]; then
    echo "WALTEUR perf-gate: FAIL — critical path(s) missing tail-latency budget (p99/p999): $MISSING" >&2
    echo "  A perf budget without p99 AND p999 is the slop WALTEUR forbids. Add both." >&2
    write_report "FAIL" "critical path(s) missing non-null p99/p999: $MISSING" \
      "$(jq -n --arg b "$BUDGET" --arg m "$MISSING" --argjson c "$CP_COUNT" \
        '{budget_file:$b, critical_paths:$c, missing_tail_latency:($m|split(", ")), rule:"p99+p999-required"}')"
    exit 2
  fi
  echo "  ok   — budget: all $CP_COUNT critical path(s) declare non-null p99 AND p999." >&2
fi

# ── LAYER 1b: service present but NO budget => perf unbudgeted => FAIL ─────────
if [ "$HAS_SERVICE" = "yes" ] && [ "$HAS_BUDGET" = "no" ]; then
  echo "WALTEUR perf-gate: FAIL — HTTP service entrypoint ($SERVICE_FILE) but NO walteur-kit/perf-budget.json." >&2
  echo "  A service that ships traffic with no latency budget is forbidden. Add walteur-kit/perf-budget.json." >&2
  write_report "FAIL" "service present but perf unbudgeted (no perf-budget.json)" \
    "$(have jq && jq -n --arg s "$SERVICE_FILE" '{service_entrypoint:$s, has_budget:false, rule:"service-requires-budget"}' || echo '{}')"
  exit 2
fi

# ── LAYER 2a: k6 / wrk2 load run + baseline p99 regression diff (>10% => FAIL) ─
PERF_RUN_VERDICT="SKIP"; PERF_RUN_REASON=""
ACHIEVED_P99=""; BASELINE_P99=""; REGRESSION_PCT=""
BASELINE_JSON="$KIT/perf-baseline.json"
BASELINE_HDR="$KIT/perf-baseline.hdr"

# Extract a baseline p99 (ms) from a committed baseline file, if any.
read_baseline_p99() {
  if [ -f "$BASELINE_JSON" ] && have jq; then
    # Accept either {p99: N} or {metrics:{http_req_duration:{p99:N}}} (k6-summary shape).
    local v
    v="$(jq -r '
      (.p99 // .metrics."http_req_duration"."p99" // .metrics."http_req_duration".values."p(99)" // empty)' \
      "$BASELINE_JSON" 2>/dev/null || true)"
    if printf '%s' "$v" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then BASELINE_P99="$v"; return 0; fi
  fi
  if [ -f "$BASELINE_HDR" ]; then
    # HdrHistogram .hdr text export: a line like  "99.000   <value>" — take the 99.0pct row's value.
    local v
    v="$(grep -E '^[[:space:]]*99\.0+([[:space:]]|0)' "$BASELINE_HDR" 2>/dev/null | awk '{print $1}' | head -1)"
    # That heuristic is fragile across .hdr dialects; only accept a clean number.
    if printf '%s' "$v" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then BASELINE_P99="$v"; return 0; fi
  fi
  return 1
}

if [ "$HAS_LOAD" = "yes" ]; then
  RUNNER=""; RUNNER_BIN=""
  if [ "$LOAD_KIND" = "k6" ] && have k6; then RUNNER="k6"; RUNNER_BIN="k6"; fi
  if [ -z "$RUNNER" ] && [ "$LOAD_KIND" = "wrk" ]; then
    if have wrk2; then RUNNER="wrk2"; RUNNER_BIN="wrk2"; elif have wrk; then RUNNER="wrk"; RUNNER_BIN="wrk"; fi
  fi

  if [ -z "$RUNNER" ]; then
    case "$LOAD_KIND" in
      k6)     loud_skip "k6"       "load script $LOAD_SCRIPT present but k6 absent" ;;
      wrk)    loud_skip "wrk/wrk2" "load script $LOAD_SCRIPT present but wrk/wrk2 absent" ;;
      locust) loud_skip "locust"   "load script $LOAD_SCRIPT present but locust absent (no in-gate run)" ;;
    esac
    PERF_RUN_VERDICT="SKIP"; PERF_RUN_REASON="$LOAD_KIND runner not installed"
  else
    # A target URL is required to drive load. Without one we cannot run honestly => loud SKIP.
    TARGET="${WALTEUR_PERF_TARGET:-}"
    if [ -z "$TARGET" ] && [ "$RUNNER" != "k6" ]; then
      echo "  SKIP — $RUNNER present but no target URL (set WALTEUR_PERF_TARGET=http://host:port). Recorded; NOT green." >&2
      PERF_RUN_VERDICT="SKIP"; PERF_RUN_REASON="$RUNNER present but no WALTEUR_PERF_TARGET"
    else
      OUT="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"
      echo "  run  — $RUNNER on $LOAD_SCRIPT ${TARGET:+(target $TARGET)} ..." >&2
      if [ "$RUNNER" = "k6" ]; then
        # k6 carries its own targets inside the script; emit JSON summary for parsing.
        SUMMARY="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"
        k6 run --summary-export "$SUMMARY" "$LOAD_SCRIPT" >"$OUT" 2>&1 || true
        if have jq && [ -s "$SUMMARY" ]; then
          v="$(jq -r '(.metrics."http_req_duration".values."p(99)" // .metrics."http_req_duration"."p(99)" // empty)' "$SUMMARY" 2>/dev/null || true)"
          printf '%s' "$v" | grep -qE '^[0-9]+(\.[0-9]+)?$' && ACHIEVED_P99="$v"
        fi
        rm -f "$SUMMARY"
      else
        # wrk2 latency dist: parse the "99.000%   <value>(ms|us|s)" row from --latency output.
        "$RUNNER_BIN" -t2 -c10 -d10s -R1000 --latency "$TARGET" >"$OUT" 2>&1 || \
          "$RUNNER_BIN" -t2 -c10 -d10s --latency "$TARGET" >"$OUT" 2>&1 || true
        line="$(grep -E '^[[:space:]]*99\.000%' "$OUT" 2>/dev/null | head -1)"
        if [ -n "$line" ]; then
          raw="$(printf '%s' "$line" | awk '{print $2}')"        # e.g. 12.34ms / 980.00us / 1.20s
          num="$(printf '%s' "$raw" | sed -E 's/[a-z]+$//I')"
          unit="$(printf '%s' "$raw" | sed -E 's/^[0-9.]+//')"
          case "$unit" in
            us|µs) ACHIEVED_P99="$(awk -v n="$num" 'BEGIN{printf "%.3f", n/1000}')" ;;
            s)     ACHIEVED_P99="$(awk -v n="$num" 'BEGIN{printf "%.3f", n*1000}')" ;;
            *)     ACHIEVED_P99="$num" ;;   # ms (default)
          esac
        fi
      fi
      rm -f "$OUT"

      if ! printf '%s' "$ACHIEVED_P99" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
        echo "  SKIP — $RUNNER ran but no parseable p99 was produced. Recorded; NOT green." >&2
        PERF_RUN_VERDICT="SKIP"; PERF_RUN_REASON="$RUNNER produced no parseable p99"
      elif ! read_baseline_p99; then
        echo "  SKIP — achieved p99=${ACHIEVED_P99}ms but no committed baseline (perf-baseline.json/.hdr). Recorded; NOT green." >&2
        PERF_RUN_VERDICT="SKIP"; PERF_RUN_REASON="no committed perf baseline to diff against"
      else
        # >10% p99 regression => FAIL.  pct = (achieved - baseline) / baseline * 100
        REGRESSION_PCT="$(awk -v a="$ACHIEVED_P99" -v b="$BASELINE_P99" 'BEGIN{ if (b<=0){print "NaN"} else {printf "%.2f", (a-b)/b*100} }')"
        OVER="$(awk -v a="$ACHIEVED_P99" -v b="$BASELINE_P99" 'BEGIN{ print (b>0 && (a-b)/b > 0.10) ? "yes":"no" }')"
        if [ "$OVER" = "yes" ]; then
          echo "WALTEUR perf-gate: FAIL — p99 regression ${REGRESSION_PCT}% (achieved ${ACHIEVED_P99}ms vs baseline ${BASELINE_P99}ms, >10%)." >&2
          write_report "FAIL" "p99 regression ${REGRESSION_PCT}% > 10%% (achieved ${ACHIEVED_P99}ms vs baseline ${BASELINE_P99}ms)" \
            "$(have jq && jq -n --arg r "$RUNNER" --arg ls "$LOAD_SCRIPT" --argjson a "$ACHIEVED_P99" --argjson b "$BASELINE_P99" --argjson p "$REGRESSION_PCT" \
              '{runner:$r, load_script:$ls, achieved_p99_ms:$a, baseline_p99_ms:$b, regression_pct:$p, threshold_pct:10}' || echo '{}')"
          exit 2
        fi
        echo "  ok   — p99 ${ACHIEVED_P99}ms vs baseline ${BASELINE_P99}ms (${REGRESSION_PCT}%, within 10%)." >&2
        PERF_RUN_VERDICT="PASS"; PERF_RUN_REASON="p99 within 10% of baseline (${REGRESSION_PCT}%)"
      fi
    fi
  fi
else
  PERF_RUN_VERDICT="SKIP"; PERF_RUN_REASON="no load script to run"
fi

# ── LAYER 2b: go test -race on shared-state Go code ────────────────────────────
RACE_VERDICT="SKIP"; RACE_REASON=""
# "shared-state Go code" = a *.go file using goroutines/channels/sync primitives.
SHARED_GO=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if grep -qE '\bgo[[:space:]]+[A-Za-z_]|\bgo[[:space:]]+func\b|\bchan\b|sync\.(Mutex|RWMutex|WaitGroup|Once|Map)|atomic\.' "$f" 2>/dev/null; then
    SHARED_GO="$f"; break
  fi
done <<EOF
$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -name '*.go' -type f -print 2>/dev/null)
EOF

if [ -n "$SHARED_GO" ]; then
  if have go; then
    echo "  run  — go test -race (shared-state Go detected: $SHARED_GO) ..." >&2
    ROUT="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"
    ( cd "$ROOT" && go test -race ./... ) >"$ROUT" 2>&1
    rc=$?
    if grep -q 'WARNING: DATA RACE' "$ROUT" 2>/dev/null; then
      echo "WALTEUR perf-gate: FAIL — go test -race detected a DATA RACE." >&2
      grep -n 'DATA RACE' "$ROUT" | head -3 >&2 || true
      write_report "FAIL" "go test -race detected a data race" \
        "$(have jq && jq -n --arg f "$SHARED_GO" '{race_detector:true, data_race:true, first_offender_hint:$f}' || echo '{}')"
      rm -f "$ROUT"
      exit 2
    fi
    if [ "$rc" -ne 0 ]; then
      # Non-race test failure (compile error, failing assertion). Not THIS gate's violation —
      # other gates own test pass/fail. Record as SKIP so we don't double-penalise / false-green.
      echo "  SKIP — go test -race exited $rc with no DATA RACE (test/compile failure owned elsewhere). Recorded." >&2
      RACE_VERDICT="SKIP"; RACE_REASON="go test -race exited $rc without a data race (non-race failure)"
    else
      echo "  ok   — go test -race: no data race." >&2
      RACE_VERDICT="PASS"; RACE_REASON="no data race detected"
    fi
    rm -f "$ROUT"
  else
    loud_skip "go" "shared-state Go ($SHARED_GO) present but go toolchain absent — race detector not run"
    RACE_VERDICT="SKIP"; RACE_REASON="go toolchain not installed"
  fi
else
  RACE_VERDICT="SKIP"; RACE_REASON="no shared-state Go code"
fi

# ── overall verdict ───────────────────────────────────────────────────────────
# We reached here => no hard violation tripped. PASS the gate (zero-dep rules satisfied);
# detect-or-skip sub-checks are recorded honestly (PASS or loud SKIP), never silent-green.
OVERALL="PASS"
REASON="zero-dep perf rules satisfied"
[ "$HAS_BUDGET" = "yes" ] && REASON="tail-latency budget valid; $REASON"

if have jq; then
  write_report "$OVERALL" "$REASON" \
    "$(jq -n \
        --arg hb "$HAS_BUDGET" --arg hs "$HAS_SERVICE" --arg hl "$HAS_LOAD" \
        --arg svc "${SERVICE_FILE:-}" --arg ls "${LOAD_SCRIPT:-}" --arg lk "${LOAD_KIND:-}" \
        --arg prv "$PERF_RUN_VERDICT" --arg prr "$PERF_RUN_REASON" \
        --arg rv "$RACE_VERDICT" --arg rr "$RACE_REASON" \
        --arg ap "${ACHIEVED_P99:-}" --arg bp "${BASELINE_P99:-}" --arg rp "${REGRESSION_PCT:-}" \
      '{
        applicability:{has_budget:($hb=="yes"), has_service:($hs=="yes"), has_load_script:($hl=="yes")},
        service_entrypoint:(if ($svc|length)>0 then $svc else null end),
        load_script:(if ($ls|length)>0 then {file:$ls, kind:$lk} else null end),
        load_run:{verdict:$prv, reason:$prr,
                  achieved_p99_ms:(if ($ap|length)>0 then ($ap|tonumber) else null end),
                  baseline_p99_ms:(if ($bp|length)>0 then ($bp|tonumber) else null end),
                  regression_pct:(if ($rp|length)>0 and ($rp!="NaN") then ($rp|tonumber) else null end)},
        race_detector:{verdict:$rv, reason:$rr}
      }')"
else
  write_report "$OVERALL" "$REASON" '{}'
fi

echo "perf-gate verdict: $OVERALL (budget=$HAS_BUDGET, load_run=$PERF_RUN_VERDICT, race=$RACE_VERDICT) -> $REPORT" >&2
exit 0
