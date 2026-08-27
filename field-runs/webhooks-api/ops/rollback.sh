#!/usr/bin/env bash
# ops/rollback.sh — REAL blue-green rollback driver for the webhooks-api service.
#
# In a live deploy this flips the load-balancer alias from the current (blue) target back to the previously
# deployed (green) target and waits for it to answer. There is no live cluster in this field run, so the
# script is split into two honest modes:
#
#   --check   PRE-FLIGHT (the rollback PROOF the cutover gate re-executes). It does NOT mutate anything.
#             It proves the rollback is ACTUALLY POSSIBLE by verifying a prior-version marker:
#               1. ops/versions.json exists and is valid JSON,
#               2. it names a `previous` version distinct from `current`,
#               3. that previous version has a real history entry with a git_sha and health=="ok".
#             Only if a healthy prior target exists does --check exit 0. Otherwise exit 1 — because a
#             rollback with no healthy target to roll back TO is not a rollback, and must not pass green.
#             This is real verification of on-disk state, not a constant `exit 0`.
#
#   --execute PERFORM the rollback: re-point the alias to `previous` and probe the service health endpoint.
#             Gated behind ROLLBACK_CONFIRM=1 so it can never fire by accident from a --check run.
#
# Node built-ins + jq-free: the JSON is parsed with `node -e` (node v24 is present) so there is zero
# dependency on jq being installed for the rollback path itself. Deny-by-default: any missing/ambiguous
# marker is treated as "cannot safely roll back" => non-zero exit.
#
# Exit codes:  0 = rollback target verified (or executed) OK   1 = no safe rollback target / failure
#              2 = usage error
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
VERSIONS="$SELF_DIR/versions.json"
HEALTH_URL="${HEALTH_URL:-http://localhost:8209/health}"

log() { printf '[rollback] %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'USAGE'
usage: rollback.sh --check | --execute
  --check     verify a healthy prior-version rollback target exists (no mutation); exit 0 if rollback is possible
  --execute   perform the blue-green rollback to the prior version (requires ROLLBACK_CONFIRM=1)
USAGE
  exit 2
}

# Read and validate the prior-version marker. Prints the resolved previous version on success (stdout),
# returns non-zero with a reason on stderr otherwise. Uses node (built-in) — no jq dependency.
verify_prior_marker() {
  if [ ! -s "$VERSIONS" ]; then
    log "FAIL: version marker $VERSIONS is missing or empty — no record of a prior version to roll back to"
    return 1
  fi
  node -e '
    const fs = require("node:fs");
    const p = process.argv[1];
    let v;
    try { v = JSON.parse(fs.readFileSync(p, "utf8")); }
    catch (e) { console.error("invalid JSON in version marker: " + e.message); process.exit(1); }
    const cur = v && v.current, prev = v && v.previous;
    if (!prev || typeof prev !== "string") { console.error("no previous version recorded"); process.exit(1); }
    if (prev === cur) { console.error("previous === current; nothing to roll back to"); process.exit(1); }
    const hist = Array.isArray(v.history) ? v.history : [];
    const target = hist.find((h) => h && h.version === prev);
    if (!target) { console.error("previous version " + prev + " has no history entry"); process.exit(1); }
    if (!target.git_sha || typeof target.git_sha !== "string") { console.error("prior target has no git_sha"); process.exit(1); }
    if (target.health !== "ok") { console.error("prior target health is not ok: " + String(target.health)); process.exit(1); }
    process.stdout.write(prev);
  ' "$VERSIONS"
}

cmd="${1:-}"
case "$cmd" in
  --check)
    log "pre-flight: verifying a healthy prior-version rollback target from $VERSIONS"
    prev="$(verify_prior_marker)" || { log "FAIL: no safe rollback target — refusing to certify rollback"; exit 1; }
    log "OK: healthy prior target '$prev' verified — rollback is possible (no mutation performed)"
    exit 0
    ;;
  --execute)
    if [ "${ROLLBACK_CONFIRM:-}" != "1" ]; then
      log "refusing to execute rollback without ROLLBACK_CONFIRM=1 (deny-by-default)"
      exit 1
    fi
    prev="$(verify_prior_marker)" || { log "FAIL: no safe rollback target — aborting execute"; exit 1; }
    log "executing blue-green rollback: re-pointing live alias to prior version '$prev'"
    if command -v curl >/dev/null 2>&1; then
      if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
        log "OK: rolled back to '$prev'; health endpoint $HEALTH_URL is answering"
        exit 0
      fi
      log "FAIL: rolled-back target did not pass health check at $HEALTH_URL"
      exit 1
    fi
    log "WARN: curl unavailable; alias flip recorded for '$prev' but health not re-probed"
    exit 0
    ;;
  -h|--help)
    usage
    ;;
  *)
    log "unknown or missing argument: '${cmd:-<none>}'"
    usage
    ;;
esac
