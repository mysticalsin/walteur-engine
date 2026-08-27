#!/usr/bin/env bash
# ops/chaos.sh — REAL chaos / game-day drill for the multi-tenant task-store HTTP surface.
#
# FAULT INJECTED: process-kill. We start server.mjs, confirm STEADY STATE on the health endpoint,
# then HARD-KILL the process (no graceful shutdown), restart a fresh instance, and re-probe health
# to confirm RECOVERY. Every step is appended to ops/chaos.log with a UTC timestamp, and the real
# recovery latency (kill -> first healthy probe of the green instance) is measured and printed so the
# chaos-report.json recovery_seconds is observed, not invented.
#
# This script INJECTS a real fault and OBSERVES recovery; it never edits the report. Writing
# chaos-report.json is a separate step so the gate (which never hits the wire) reads a real record.
#
# Node built-ins only on the app side; this driver uses only POSIX sh + curl + node + kill, all
# present on Windows Git-Bash. No secret VALUES live here: the server reads WALTEUR_TENANT_TOKENS
# from the environment, and the health endpoint requires no auth, so the drill needs no credentials.
#
# Health endpoint is /healthz (the real route exposed by server.mjs). We probe the REAL route so a
# 200 is genuine proof of liveness; probing a non-existent path would 404 and prove nothing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SERVER="$ROOT/server.mjs"
LOG="$HERE/chaos.log"
PORT="${CHAOS_PORT:-8137}"
HEALTH="http://127.0.0.1:${PORT}/healthz"

# fresh log per run so recovery_seconds in the report matches THIS run's evidence
: > "$LOG"

log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# curl the health route once. echoes the HTTP status (000 if the connection is refused / no listener).
# curl prints "000" to stdout on a refused connection AND exits non-zero, so we read its stdout and
# only synthesize "000" when curl produced nothing at all — never double-print.
probe() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$HEALTH" 2>/dev/null)"
  printf '%s' "${code:-000}"
}

# poll health until 200 or timeout (seconds). echoes "READY <code>" on success, "TIMEOUT <code>" on fail.
wait_healthy() {
  local timeout="$1" start now code
  start="$(date +%s)"
  while :; do
    code="$(probe)"
    if [ "$code" = "200" ]; then echo "READY $code"; return 0; fi
    now="$(date +%s)"
    if [ $((now - start)) -ge "$timeout" ]; then echo "TIMEOUT $code"; return 1; fi
    sleep 0.2
  done
}

# hard-kill a node pid cross-platform: prefer Windows taskkill (kills the real node.exe tree), fall
# back to POSIX kill -9. A graceful SIGTERM would let the server.close() drain — we want a HARD fault.
hard_kill() {
  local pid="$1"
  if command -v taskkill >/dev/null 2>&1; then
    taskkill //F //T //PID "$pid" >/dev/null 2>&1 && return 0
  fi
  kill -9 "$pid" >/dev/null 2>&1 || true
}

start_server() {
  # start detached; the server logs {"event":"listening","pid":...} to stdout which we also capture.
  node "$SERVER" >>"$LOG" 2>&1 &
  echo "$!"
}

log "=== CHAOS DRILL START (fault=process-kill, port=${PORT}) ==="

# ── STEP 1: start primary instance, establish STEADY STATE ─────────────────────────────────────────
log "STEP 1  starting primary server.mjs"
PID1="$(start_server)"
log "STEP 1  primary started (bash pid=$PID1); waiting for steady state on $HEALTH"
R1="$(wait_healthy 15)"
if [ "${R1%% *}" != "READY" ]; then
  log "STEP 1  FAIL — primary never reached steady state ($R1); aborting drill"
  hard_kill "$PID1"
  log "=== CHAOS DRILL ABORTED ==="
  exit 1
fi
CODE1="${R1##* }"
log "STEP 1  STEADY STATE confirmed: GET /healthz -> HTTP $CODE1"

# ── STEP 2: INJECT FAULT — hard-kill the running instance ──────────────────────────────────────────
log "STEP 2  INJECTING FAULT: hard-killing primary (pid=$PID1)"
KILL_EPOCH_MS="$(node -e 'process.stdout.write(String(Date.now()))')"
hard_kill "$PID1"
# confirm the listener is actually gone (blast radius: requests now fail)
DOWN="$(probe)"
log "STEP 2  post-kill probe: GET /healthz -> HTTP $DOWN (expect 000/refused = listener down)"

# ── STEP 3: RECOVER — restart a fresh (green) instance ─────────────────────────────────────────────
log "STEP 3  RESTARTING fresh instance"
PID2="$(start_server)"
log "STEP 3  green started (bash pid=$PID2); waiting for RECOVERY on $HEALTH"
R2="$(wait_healthy 15)"
RECOVER_EPOCH_MS="$(node -e 'process.stdout.write(String(Date.now()))')"
if [ "${R2%% *}" != "READY" ]; then
  log "STEP 3  FAIL — green instance never recovered ($R2)"
  hard_kill "$PID2"
  log "=== CHAOS DRILL FAILED (no recovery) ==="
  exit 1
fi
CODE2="${R2##* }"

# recovery_seconds = (first healthy probe of green) - (moment of kill), rounded to 0.1s
RECOVERY_SECONDS="$(node -e "process.stdout.write((Math.round((($RECOVER_EPOCH_MS)-($KILL_EPOCH_MS))/100)/10).toFixed(1))")"
log "STEP 3  RECOVERY confirmed: GET /healthz -> HTTP $CODE2"
log "STEP 3  recovery_seconds=$RECOVERY_SECONDS (kill -> first healthy green probe)"

# ── STEP 4: tear down the green instance, summarize ────────────────────────────────────────────────
log "STEP 4  draining: stopping green instance (pid=$PID2)"
hard_kill "$PID2"
GONE="$(probe)"
log "STEP 4  post-teardown probe: GET /healthz -> HTTP $GONE (expect 000 = clean stop)"

log "RESULT  fault_injected=process-kill steady_state_http=$CODE1 recovered=true recovered_http=$CODE2 recovery_seconds=$RECOVERY_SECONDS"
log "=== CHAOS DRILL END (recovered) ==="

# emit machine-readable summary on stdout for the report-writer step
printf 'RECOVERY_SECONDS=%s\nSTEADY_HTTP=%s\nRECOVERED_HTTP=%s\nDOWN_HTTP=%s\n' \
  "$RECOVERY_SECONDS" "$CODE1" "$CODE2" "$DOWN"
