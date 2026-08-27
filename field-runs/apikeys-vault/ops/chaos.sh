#!/usr/bin/env bash
# ops/chaos.sh — REAL chaos / game-day drill for the multi-tenant API-key vault HTTP surface.
#
# FAULT INJECTED: process-kill. We start server.mjs, confirm STEADY STATE on the health endpoint, then
# HARD-KILL the process (no graceful shutdown), restart a fresh instance, and re-probe health to confirm
# RECOVERY. Every step is appended to ops/chaos.log with a UTC timestamp, and the real recovery latency
# (kill -> first healthy probe of the green instance) is measured and printed so the chaos-report.json
# recovery_seconds is observed, not invented.
#
# This script INJECTS a real fault and OBSERVES recovery, then WRITES ops/chaos-report.json from the
# observed values (and mirrors it into walteur-kit/ for the gate). Node built-ins only on the app side;
# this driver uses only POSIX sh + curl + node + kill, all present on Windows Git-Bash. No secret VALUES
# live here: the server reads WALTEUR_TENANT_TOKENS from the environment, and the health endpoint requires
# no auth, so the drill needs no credentials.
#
# Health endpoint is /health (a real route exposed by server.mjs). We probe the REAL route so a 200 is
# genuine proof of liveness; probing a non-existent path would 404 and prove nothing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SERVER="$ROOT/server.mjs"
LOG="$HERE/chaos.log"
REPORT="$HERE/chaos-report.json"
KIT_REPORT="$ROOT/walteur-kit/chaos-report.json"
PORT="${CHAOS_PORT:-8203}"
HEALTH="http://127.0.0.1:${PORT}/health"

# fresh log per run so recovery_seconds in the report matches THIS run's evidence
: > "$LOG"

log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# curl the health route once. echoes the HTTP status (000 if the connection is refused / no listener).
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

# hard-kill a node pid cross-platform: prefer Windows taskkill (kills the real node.exe tree), fall back to
# POSIX kill -9. A graceful SIGTERM would let server.close() drain — we want a HARD fault.
hard_kill() {
  local pid="$1"
  if command -v taskkill >/dev/null 2>&1; then
    taskkill //F //T //PID "$pid" >/dev/null 2>&1 && return 0
  fi
  kill -9 "$pid" >/dev/null 2>&1 || true
}

start_server() {
  # start detached on a throwaway data file so the drill never mutates the real data.json
  VAULT_DATA_FILE="$ROOT/data.chaos.json" PORT="$PORT" node "$SERVER" >>"$LOG" 2>&1 &
  echo "$!"
}

write_report() {
  # args: recovery_seconds steady_http recovered_http down_http recovered(true/false)
  #
  # Emits the chaos-resilience-gate drills[] schema (hypothesis/fault_injected/steady_state_metric/
  # blast_radius_observed/recovered/recovery_seconds/ran_ts/evidence_ref) so the gate reads THIS run's
  # regenerated evidence directly. evidence_ref points at ops/chaos.log — the in-tree, non-empty log this
  # drill rewrites every run — so the gate's fresh-recovery check is satisfied by observed values, not
  # invented ones. The flat per-run telemetry is preserved under .drills[0].observed for humans/dashboards.
  # The gate's chaos_probe.command is carried at the top level so an armed (WALTEUR_CHAOS_EXEC=1) gate run
  # re-runs THIS drill; we re-stamp it on every write so it survives the regeneration.
  node -e '
    const fs = require("node:fs");
    const [rs, steady, recovered, down, ok] = process.argv.slice(1);
    const recoveredBool = ok === "true";
    const report = {
      schema_version: 1,
      report_id: "apikeys-vault-process-kill",
      service: "apikeys-vault",
      chaos_probe: { command: "bash ops/chaos.sh" },
      drills: [
        {
          hypothesis: "If the apikeys-vault server process is hard-killed, a fresh instance restarts and GET /health returns 200 within the SLO budget.",
          fault_injected: "process-kill (taskkill //F //T or kill -9 on the running server.mjs)",
          steady_state_metric: "GET /health returns HTTP 200; post-kill returns 000 (refused); green instance returns 200",
          blast_radius_observed: "listener down during the kill window (GET /health -> " + String(Number(down)) + "); reads restored once the green instance is healthy",
          recovered: recoveredBool,
          recovery_seconds: Number(rs),
          ran_ts: new Date().toISOString(),
          evidence_ref: "ops/chaos.log",
          observed: {
            drill: "process-kill",
            steady_state_http: Number(steady),
            down_http: Number(down),
            recovered_http: Number(recovered),
            health_endpoint: process.env.CHAOS_HEALTH || "/health"
          }
        }
      ],
      notes: "Primary started + steady on GET /health, hard-killed (taskkill/kill -9), fresh instance restarted and re-probed healthy. recovery_seconds = kill -> first healthy green probe (observed). evidence_ref=ops/chaos.log is the per-run drill log."
    };
    const out = JSON.stringify(report, null, 2);
    fs.writeFileSync(process.env.CHAOS_REPORT, out);
    if (process.env.CHAOS_KIT_REPORT) { try { fs.mkdirSync(require("node:path").dirname(process.env.CHAOS_KIT_REPORT), {recursive:true}); fs.writeFileSync(process.env.CHAOS_KIT_REPORT, out); } catch {} }
  ' "$1" "$2" "$3" "$4" "$5"
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
log "STEP 1  STEADY STATE confirmed: GET /health -> HTTP $CODE1"

# ── STEP 2: INJECT FAULT — hard-kill the running instance ──────────────────────────────────────────
log "STEP 2  INJECTING FAULT: hard-killing primary (pid=$PID1)"
KILL_EPOCH_MS="$(node -e 'process.stdout.write(String(Date.now()))')"
hard_kill "$PID1"
DOWN="$(probe)"
log "STEP 2  post-kill probe: GET /health -> HTTP $DOWN (expect 000/refused = listener down)"

# ── STEP 3: RECOVER — restart a fresh (green) instance ─────────────────────────────────────────────
log "STEP 3  RESTARTING fresh instance"
PID2="$(start_server)"
log "STEP 3  green started (bash pid=$PID2); waiting for RECOVERY on $HEALTH"
R2="$(wait_healthy 15)"
RECOVER_EPOCH_MS="$(node -e 'process.stdout.write(String(Date.now()))')"
if [ "${R2%% *}" != "READY" ]; then
  log "STEP 3  FAIL — green instance never recovered ($R2)"
  hard_kill "$PID2"
  CHAOS_REPORT="$REPORT" CHAOS_KIT_REPORT="$KIT_REPORT" write_report "0" "$CODE1" "0" "$DOWN" "false"
  log "=== CHAOS DRILL FAILED (no recovery) ==="
  exit 1
fi
CODE2="${R2##* }"
RECOVERY_SECONDS="$(node -e "process.stdout.write((Math.round((($RECOVER_EPOCH_MS)-($KILL_EPOCH_MS))/100)/10).toFixed(1))")"
log "STEP 3  RECOVERY confirmed: GET /health -> HTTP $CODE2"
log "STEP 3  recovery_seconds=$RECOVERY_SECONDS (kill -> first healthy green probe)"

# ── STEP 4: tear down the green instance, write the report ─────────────────────────────────────────
log "STEP 4  draining: stopping green instance (pid=$PID2)"
hard_kill "$PID2"
GONE="$(probe)"
log "STEP 4  post-teardown probe: GET /health -> HTTP $GONE (expect 000 = clean stop)"
rm -f "$ROOT/data.chaos.json" "$ROOT/data.chaos.json.tmp" 2>/dev/null || true

CHAOS_REPORT="$REPORT" CHAOS_KIT_REPORT="$KIT_REPORT" write_report "$RECOVERY_SECONDS" "$CODE1" "$CODE2" "$DOWN" "true"
log "STEP 4  wrote $REPORT (and mirrored to walteur-kit/)"

log "RESULT  fault_injected=process-kill steady_state_http=$CODE1 recovered=true recovered_http=$CODE2 recovery_seconds=$RECOVERY_SECONDS"
log "=== CHAOS DRILL END (recovered) ==="

printf 'RECOVERY_SECONDS=%s\nSTEADY_HTTP=%s\nRECOVERED_HTTP=%s\nDOWN_HTTP=%s\n' \
  "$RECOVERY_SECONDS" "$CODE1" "$CODE2" "$DOWN"
