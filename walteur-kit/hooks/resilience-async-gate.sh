#!/usr/bin/env bash
# WALTEUR resilience-async-gate — HARD gate (enterprise backlog rank 15). resilience-lint covers timeouts/
# jitter but three failure modes that take a $50-100M SaaS fully down are unguarded: (1) an outbound
# dependency with no circuit-breaker/bulkhead — one slow downstream saturates every worker (cascading
# failure); (2) an async job with no dead-letter queue or idempotency key — a poison message is lost or
# double-processed (a duplicate charge); (3) connection-pool exhaustion — sum(instances * pool_size) exceeds
# db_max_connections, so a traffic spike opens more connections than the DB allows and everything 500s.
# This gate requires walteur-kit/resilience.json (+ async-jobs.json) and FAILs on any of the three.
#
# Applies when an async/outbound surface is present (signal has_async/has_outbound, code, or the manifests).
# CONTRACT: any of the three => FAIL exit 2 · no surface => NOT_APPLICABLE · jq absent => SKIP · PAUSED =>
# exit 2 · bypass WALTEUR_RESILIENCE=off.
# Report: walteur-kit/resilience-async-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "resilience-async-gate - HARD gate (enterprise backlog rank 15). resilience-lint covers timeouts/"
  printf '%s\n' "usage: bash resilience-async-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/resilience-async-report.json - fix recipes: walteur-kit/REMEDIATION.md (## resilience-async-gate)"
  printf '%s\n' "bypass: WALTEUR_RESILIENCE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
MANIFEST="${WALTEUR_RESILIENCE_FILE:-$KIT/resilience.json}"
JOBS="$KIT/async-jobs.json"
REPORT="$KIT/resilience-async-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
X="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit --exclude-dir=dist --exclude-dir=build"

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"resilience-async", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"resilience-async","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }
has_sig() { [ -f "$SIGNALS" ] && have jq && jq -e "$1" "$SIGNALS" >/dev/null 2>&1; }
surface() {
  [ -f "$MANIFEST" ] || [ -f "$JOBS" ] && return 0
  has_sig '(.has_async==true) or (.has_outbound==true) or (.has_queue==true)' && return 0
  command -v grep >/dev/null 2>&1 && grep -rIiqE --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.mjs' --include='*.cjs' --include='*.py' --include='*.go' --include='*.rb' --include='*.java' --include='*.cs' --include='*.kt' --include='*.php' $X 'kafka|sqs|rabbitmq|amqp|bullmq|bull\b|sidekiq|celery|pub[_/-]?sub|eventbridge|kinesis|nats\b|servicebus|axios|node-fetch|got\(|httpx|requests\.(get|post)|http\.Client|RestTemplate|\.enqueue|\.publish\(|\.sendMessage' "$ROOT" 2>/dev/null
}
defer_ok() { printf '%s' "$1" | jq -e '.deferral.owner and .deferral.ticket and .deferral.review_trigger' >/dev/null 2>&1; }

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "resilience-async selftest SKIP - jq not installed."; return 0; fi
  echo "resilience-async-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  sfc() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${2:-high}" > "$1/walteur-kit/build-contract.json"; printf '{"has_async":true,"has_outbound":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  goodres() { jq -n '{db_max_connections:100,services:[{name:"api",instances:4,db_pool_size:10},{name:"worker",instances:2,db_pool_size:20}],outbound_dependencies:[{name:"stripe",circuit_breaker:true,timeout_ms:3000,bulkhead:true}]}' > "$1/walteur-kit/resilience.json"; }
  goodjobs() { jq -n '{jobs:[{name:"send-email",dlq:"email-dlq",idempotency_key:true},{name:"charge",dlq:"charge-dlq",idempotency_key:true}]}' > "$1/walteur-kit/async-jobs.json"; }

  # 1. no surface -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"has_async":false,"has_outbound":false}\n' > "$t/walteur-kit/preflight-signals.json"; printf 'export const x=1;\n' > "$t/a.ts"; ck "no surface -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. good resilience + good jobs -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; goodjobs "$t"; ck "full resilience -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. high-risk + no resilience.json -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t" high; ck "high-risk, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. outbound dep missing circuit-breaker -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; goodjobs "$t"; jq '.outbound_dependencies[0].circuit_breaker=false' "$t/walteur-kit/resilience.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/resilience.json"; ck "no circuit-breaker -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. pool ceiling exceeded -> FAIL (4*10 + 2*60 = 160 > 100)
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; goodjobs "$t"; jq '.services[1].db_pool_size=60' "$t/walteur-kit/resilience.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/resilience.json"; ck "pool ceiling exceeded -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. async job missing DLQ -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; goodjobs "$t"; jq '.jobs[0].dlq=""' "$t/walteur-kit/async-jobs.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/async-jobs.json"; ck "job missing DLQ -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. async job missing idempotency_key -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; goodjobs "$t"; jq '.jobs[1].idempotency_key=false' "$t/walteur-kit/async-jobs.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/async-jobs.json"; ck "job missing idempotency -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. has_async + no async-jobs.json at high risk -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t" high; goodres "$t"; ck "has_async, no jobs manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. missing breaker signed-deferred at low risk -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t" low; goodres "$t"; goodjobs "$t"; jq '.outbound_dependencies[0]={name:"stripe",circuit_breaker:false,deferral:{owner:"Tony",ticket:"REL-1",review_trigger:"GA"}}' "$t/walteur-kit/resilience.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/resilience.json"; ck "breaker deferred at low risk -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 10. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; WALTEUR_ROOT="$t" WALTEUR_RESILIENCE=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ── D4 gauntlet regressions (type-coercion / fail-open) ──
  pm() { jq "$1" "$2/walteur-kit/resilience.json" > "$2/m" && mv "$2/m" "$2/walteur-kit/resilience.json"; }
  jm() { jq "$1" "$2/walteur-kit/async-jobs.json" > "$2/mj" && mv "$2/mj" "$2/walteur-kit/async-jobs.json"; }
  # G1 — string-typed pool numbers that over-subscribe (4*60=240>100) -> FAIL (was fail-open)
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; goodjobs "$t"; pm '.services[0].instances="4" | .services[0].db_pool_size="60"' "$t"; ck "G1 string-typed pool over -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2 — db_max_connections "100 " (trailing space) + real over -> FAIL (was skip)
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; goodjobs "$t"; pm '.db_max_connections="100 " | .services[1].db_pool_size=60' "$t"; ck "G2 string ceiling + over -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3 — fractional pool causing over (2*30.5=61 -> 101>100) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; goodjobs "$t"; pm '.services[1].db_pool_size=30.5' "$t"; ck "G3 fractional pool over -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G4 — dlq as boolean true (not a queue name) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; goodjobs "$t"; jm '.jobs[0].dlq=true' "$t"; ck "G4 dlq boolean -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G5 — dlq sentinel string "yes" -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; goodjobs "$t"; jm '.jobs[0].dlq="yes"' "$t"; ck "G5 dlq sentinel -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G6 — idempotency_key as a truthy non-boolean "yes" -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; goodjobs "$t"; jm '.jobs[1].idempotency_key="yes"' "$t"; ck "G6 idempotency non-bool -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G7 — FALSE-POSITIVE GUARD: string-typed numbers WITHIN the ceiling -> PASS (coercion works both ways)
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; goodjobs "$t"; pm '.services[0].instances="4" | .services[0].db_pool_size="10" | .services[1].instances="2" | .services[1].db_pool_size="20"' "$t"; ck "G7 string nums within ceiling -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # G8 — jobs as an OBJECT not array -> FAIL (fail-closed)
  t="$(mktemp -d "${TMPDIR:-/tmp}/resilience.XXXXXX")"; sfc "$t"; goodres "$t"; jq -n '{jobs:{charge:{dlq:"charge-dlq",idempotency_key:true}}}' > "$t/walteur-kit/async-jobs.json"; ck "G8 jobs object shape -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  echo "resilience-async-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_RESILIENCE:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_RESILIENCE=off"; echo "resilience-async-gate: bypassed." >&2; exit 0; }

if ! surface; then write_report "NOT_APPLICABLE" "no async/outbound surface"; echo "resilience-async-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "resilience-async-gate: SKIP." >&2; exit 0; fi

RISK="$(risk)"
if [ ! -s "$MANIFEST" ]; then
  case "$RISK" in
    high|regulated) add_finding "manifest" "async/outbound surface at $RISK risk but no walteur-kit/resilience.json — declare circuit-breakers, the connection-pool ceiling, and per-service instances/pool_size"
      write_report "FAIL" "resilience manifest absent at $RISK risk"; echo "resilience-async-gate: FAIL - manifest absent" >&2; exit 2 ;;
    *) write_report "NOT_APPLICABLE" "no resilience.json and risk_tier=$RISK below the required floor"; echo "resilience-async-gate: NOT_APPLICABLE ($RISK risk)"; exit 0 ;;
  esac
fi

# (1) outbound dependencies — circuit-breaker + timeout
while IFS= read -r dep; do
  [ -n "$dep" ] || continue
  nm="$(printf '%s' "$dep" | jq -r '.name // "dep"')"
  cb="$(printf '%s' "$dep" | jq -r '.circuit_breaker // false')"
  to="$(printf '%s' "$dep" | jq -r '.timeout_ms // 0')"
  if [ "$cb" != "true" ] || ! printf '%s' "$to" | grep -qE '^[1-9][0-9]*$'; then
    if defer_ok "$dep"; then
      case "$RISK" in high|regulated) add_finding "$nm" "outbound dependency lacks circuit-breaker/timeout and cannot be signed-deferred at risk_tier=$RISK";; esac
    else
      add_finding "$nm" "outbound dependency '$nm' has no circuit-breaker (cb=$cb) or timeout_ms ($to) — one slow downstream cascades to a full outage"
    fi
  fi
done < <(jq -c '.outbound_dependencies[]?' "$MANIFEST" 2>/dev/null)

# (3) connection-pool ceiling — FAIL-CLOSED + numeric coercion (D4 gauntlet: string-typed "4"/"100 "/fractional
# values made the old jq arithmetic error → swallowed → check silently skipped). Everything is computed inside
# jq with tonumber; if the ceiling is present but the total cannot be computed, that is a FINDING, not a skip.
if jq -e 'has("db_max_connections")' "$MANIFEST" >/dev/null 2>&1; then
  if jq -e '(.services? // null) and ((.services|type) != "array")' "$MANIFEST" >/dev/null 2>&1; then
    add_finding "pool_ceiling" "services must be an array — cannot compute the connection-pool total (fail-closed)"
  else
    pv="$(jq -r '
      def num: (. // null) | (if type=="number" then . elif (type=="string" and test("^[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*$")) then (gsub("[[:space:]]";"")|tonumber) else null end);
      (.db_max_connections | num) as $mx
      | ([ .services[]? | ((.instances|num) as $i | (.db_pool_size|num) as $p | if ($i==null or $p==null) then null else ($i*$p) end) ]) as $prod
      | if ($mx==null) or ($prod | any(.==null)) then "BAD"
        else (($prod|add) // 0) as $t | (if $t > $mx then "OVER \($t) \($mx)" else "OK" end) end' "$MANIFEST" 2>/dev/null)"
    case "$pv" in
      OVER*) t="$(printf '%s' "$pv" | awk '{print $2}')"; mx="$(printf '%s' "$pv" | awk '{print $3}')"; add_finding "pool_ceiling" "sum(instances * db_pool_size) = $t exceeds db_max_connections = $mx — a traffic spike will exhaust the DB connection pool and 500 everything" ;;
      OK) : ;;
      *) add_finding "pool_ceiling" "db_max_connections / instances / db_pool_size are not all valid numbers — cannot prove the pool stays within the DB ceiling (fail-closed)" ;;
    esac
  fi
fi

# (2) async jobs — DLQ must be a real queue NAME (not a boolean/sentinel) and idempotency_key must be boolean true
# (D4 gauntlet: dlq:true / "yes" and idempotency_key:"yes"/1 sailed past the non-empty / string-equals checks).
if [ -s "$JOBS" ]; then
  if jq -e '(.jobs? // null) and ((.jobs|type) != "array")' "$JOBS" >/dev/null 2>&1; then
    add_finding "jobs" "async-jobs.json .jobs must be an array — cannot evaluate DLQ/idempotency per job (fail-closed)"
  fi
  while IFS=$'\t' read -r jn dlqtype dlqval idem; do
    [ -n "$jn" ] || continue
    if [ "$dlqtype" != "string" ]; then add_finding "$jn" "async job '$jn' dlq must be a queue NAME (string), got $dlqtype — a poison message has nowhere to go"
    else
      low="$(printf '%s' "$dlqval" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
      case "$low" in ''|null|true|false|yes|no|on|off|enabled|disabled|1|0|tbd|todo|none) add_finding "$jn" "async job '$jn' dlq '$dlqval' is a sentinel, not a real dead-letter-queue name — a poison message is silently lost";; esac
    fi
    [ "$idem" = "true" ] || add_finding "$jn" "async job '$jn' idempotency_key must be boolean true (got non-true) — a redelivery double-processes (e.g. a duplicate charge)"
  done < <(jq -r '.jobs[]? | [(.name // "job"), (.dlq|type), (.dlq|tostring), ((.idempotency_key==true)|tostring)] | @tsv' "$JOBS" 2>/dev/null)
elif has_sig '.has_async==true'; then
  case "$RISK" in high|regulated) add_finding "jobs" "has_async at $RISK risk but no walteur-kit/async-jobs.json — every job must declare a DLQ + idempotency_key";; esac
fi

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures resilience violation(s)"
  echo "resilience-async-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "outbound deps circuit-broken, async jobs have DLQ+idempotency, connection-pool within the DB ceiling"
echo "resilience-async-gate: PASS" >&2
exit 0
