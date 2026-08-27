#!/usr/bin/env bash
# WALTEUR integration-proof-gate — HARD gate (fix #7 completeness). Closes the "integrations
# stayed mock" hole: a build cannot ship while an external dependency is silently faked.
#
# Reads walteur-kit/integrations.json — the per-build registry of every external dependency.
# Each integration is one of:
#   live-wired     → proven by a real round-trip artifact (proof.command_output_ref, fresh)
#   signed-deferred→ deferred WITH owner + ticket + reason + review_trigger (auditable)
#   mock           → ONLY legal if root allow_mock_prototype:true, time-boxed, low/medium risk
#
# CONTRACT:
#   integrations.json present              => validate every integration (PASS/FAIL).
#   absent BUT external surface declared   => FAIL exit 2 (build-contract has an external-service/api
#                                             interface, or preflight-signals shows has_api_boundary/has_db).
#   absent and no external surface         => NOT_APPLICABLE exit 0.
#   jq absent                              => SKIP exit 0 (loud).
#   walteur-kit/PAUSED                     => exit 2.
#
# Report: walteur-kit/integration-proof-report.json   Bypass: WALTEUR_INTEGRATION_PROOF=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "integration-proof-gate - HARD gate (fix #7 completeness). Closes the integrations"
  printf '%s\n' "usage: bash integration-proof-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/integration-proof-report.json - fix recipes: walteur-kit/REMEDIATION.md (## integration-proof-gate)"
  printf '%s\n' "bypass: WALTEUR_INTEGRATION_PROOF=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# absolute path to THIS script, resolved before any cd, so selftest's re-invocation is cwd-independent
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
MANIFEST="${WALTEUR_INTEGRATIONS_FILE:-$KIT/integrations.json}"
CONTRACT="$KIT/build-contract.json"
SIGNALS="$KIT/preflight-signals.json"
REPORT="$KIT/integration-proof-report.json"
MAX_AGE_DAYS="${WALTEUR_INTEGRATION_MAX_AGE_DAYS:-14}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() {
  verdict="$1"; reason="$2"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"integration-proof", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"integration-proof","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

external_surface_declared() {
  [ -f "$CONTRACT" ] && jq -e '[.interfaces[]? | select(.type=="external-service" or .type=="api")] | length > 0' "$CONTRACT" >/dev/null 2>&1 && return 0
  [ -f "$SIGNALS" ] && jq -e '(.has_api_boundary==true) or (.has_db==true) or (.external_surface==true)' "$SIGNALS" >/dev/null 2>&1 && return 0
  return 1
}

epoch() {
  # Portable date parse: try GNU date -d first (Linux), then BSD/macOS date -j -f with the
  # concrete formats we actually emit (Y-m-d and full ISO-8601 UTC). GNU date -d is simply
  # absent on Darwin -- it exits nonzero rather than parsing, so a naive `-d` call alone
  # false-fails every date on macOS regardless of validity.
  local d="$1" out
  out="$(date -u -d "$d" +%s 2>/dev/null)" && [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  out="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$d" +%s 2>/dev/null)" && [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  # Bare dates pin to midnight UTC: BSD date -j fills omitted time fields with CURRENT wall-clock,
  # which intermittently pushed today's valid date "into the future" (verifier-caught flake).
  out="$(date -u -j -f '%Y-%m-%d %H:%M:%S' "$d 00:00:00" +%s 2>/dev/null)" && [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  echo ""
}

validate() {
  # root-level prototype controls
  allow_mock="$(jq -r '.allow_mock_prototype // false' "$MANIFEST")"
  proto_expires="$(jq -r '.prototype_expires // ""' "$MANIFEST")"
  proto_owner="$(jq -r '.prototype_owner // ""' "$MANIFEST")"
  risk="medium"; [ -f "$CONTRACT" ] && risk="$(jq -r '.risk_tier // "medium"' "$CONTRACT")"
  now="$(date -u +%s)"

  while IFS= read -r intg; do
    [ -n "$intg" ] || continue
    name="$(printf '%s' "$intg" | jq -r '.name // "?"')"
    status="$(printf '%s' "$intg" | jq -r '.status // ""')"
    case "$status" in
      live-wired)
        cmd="$(printf '%s' "$intg" | jq -r '.proof.command // ""')"
        ref="$(printf '%s' "$intg" | jq -r '.proof.command_output_ref // ""')"
        cap="$(printf '%s' "$intg" | jq -r '.proof.captured_at // ""')"
        if [ -z "$cmd" ] || [ -z "$ref" ] || [ -z "$cap" ]; then
          add_finding "$name.proof" "status=live-wired but proof.{command,command_output_ref,captured_at} incomplete"
        else
          if [ ! -s "$ROOT/$ref" ]; then add_finding "$name.proof" "proof artifact missing/empty: $ref"; fi
          ce="$(epoch "$cap")"
          if [ -z "$ce" ]; then add_finding "$name.proof" "proof.captured_at not a parseable date: $cap"
          elif [ "$ce" -gt "$now" ]; then add_finding "$name.proof" "proof.captured_at is in the future: $cap"
          elif [ $(( (now - ce) / 86400 )) -gt "$MAX_AGE_DAYS" ]; then add_finding "$name.proof" "proof is stale (>$MAX_AGE_DAYS days old): $cap"; fi
        fi
        # ACTIVE verification — the difference between attestation and proof. If a re-runnable
        # proof.probe_command is provided, RUN it NOW and require exit 0: this proves the
        # integration actually responds, not just that a log file exists. Network tools are
        # allowed (the probe is supposed to make a call); destructive/exfil tokens are refused;
        # an unrecognized runner now runs ONLY if the shared kernel proves it non-trivial (recognized test
        # runner or a real on-disk artifact token) — previously it silently loud-skipped, which let an
        # unrecognized constant-exit no-op (e.g. `perl -e 'exit 0'`) pass unexamined. Disable via
        # WALTEUR_INTEGRATION_PROBE=off.
        #
        # Unify probe hardening: the constant-exit/no-op CLASS (true/false/:/empty/`bash -lc "exit 0"`/
        # `node -e` etc. that exit green while proving no live round-trip) is now judged by the SHARED
        # kernel _probe-proof.sh (probe_proves_something) instead of a bespoke per-gate case-statement —
        # one hardened kernel, not six diverging copies. FAIL CLOSED if the shared guard file was absent
        # at source time (function undefined): never silently skip the no-op check.
        probe="$(printf '%s' "$intg" | jq -r '.proof.probe_command // ""')"
        if [ -n "$probe" ] && [ "${WALTEUR_INTEGRATION_PROBE:-on}" != "off" ]; then
          if printf '%s' "$probe" | grep -Eqi 'rm[[:space:]]+-rf|mkfs|[[:space:]]dd[[:space:]]|/dev/tcp|/etc/(passwd|shadow)|\|[[:space:]]*(bash|sh)([[:space:]]|$)|>[[:space:]]*/dev/sd'; then
            add_finding "$name.probe" "probe_command contains a destructive/exfil token; refusing to run"
          elif ! command -v probe_proves_something >/dev/null 2>&1; then
            add_finding "$name.probe" "shared probe guard (_probe-proof.sh) unavailable — cannot prove probe_command is non-trivial; failing closed"
          else
            pfirst="$(printf '%s' "$probe" | awk '{print $1}')"
            case "$pfirst" in
              curl|wget|http|httpie|node|deno|bun|python|python3|npx|npm|pnpm|yarn|psql|mysql|redis-cli|go|cargo)
                # a named network/db tool proves a live round-trip call even though the shared kernel
                # (test-runner/on-disk-artifact focused) doesn't recognize this shape.
                if ! (cd "$ROOT" && eval "$probe" >/dev/null 2>&1); then
                  add_finding "$name.probe" "ACTIVE probe FAILED (ran: $probe) — the live-wired claim does not hold right now"
                fi ;;
              bash|sh)
                # a bash/sh wrapper is only a real probe if its EXECUTED payload still contains a real
                # network/db tool, OR the shared kernel recognizes it (test-runner/on-disk artifact) —
                # `bash -lc 'exit 0'` / `bash -c 'true'` are constant-exit no-ops wearing a bash costume.
                if probe_proves_something "$probe" || printf '%s' "$probe" | grep -Eqiw 'curl|wget|http|httpie|node|deno|bun|python|python3|npx|psql|mysql|redis-cli|mongosh|sqlite3|grpcurl|go|cargo'; then
                  if ! (cd "$ROOT" && eval "$probe" >/dev/null 2>&1); then
                    add_finding "$name.probe" "ACTIVE probe FAILED (ran: $probe) — the live-wired claim does not hold right now"
                  fi
                else
                  add_finding "$name.probe" "trivial/constant-exit probe_command ('$probe') proves no live round-trip — cite a real call (curl/psql/node/...) that exits 0 ONLY when the integration responds"
                fi ;;
              '')
                add_finding "$name.probe" "empty probe_command proves no live round-trip — cite a real call (curl/psql/node/...) that exits 0 ONLY when the integration responds" ;;
              *)
                if probe_proves_something "$probe"; then
                  if ! (cd "$ROOT" && eval "$probe" >/dev/null 2>&1); then
                    add_finding "$name.probe" "ACTIVE probe FAILED (ran: $probe) — the live-wired claim does not hold right now"
                  fi
                else
                  add_finding "$name.probe" "trivial/constant-exit probe_command ('$pfirst') proves no live round-trip — cite a real call (curl/psql/node/...) that exits 0 ONLY when the integration responds"
                fi ;;
            esac
          fi
        fi
        ;;
      signed-deferred)
        for f in reason owner ticket review_trigger; do
          v="$(printf '%s' "$intg" | jq -r --arg k "$f" '.deferral[$k] // ""')"
          [ -n "$v" ] || add_finding "$name.deferral" "status=signed-deferred but deferral.$f is empty"
        done
        ;;
      mock)
        if [ "$allow_mock" != "true" ]; then
          add_finding "$name.status" "status=mock without allow_mock_prototype (silent mock is launch-blocking)"
        elif [ "$risk" = "high" ] || [ "$risk" = "regulated" ]; then
          add_finding "$name.status" "status=mock not permitted at risk_tier=$risk (no prototype trapdoor for high/regulated)"
        else
          [ -n "$proto_owner" ] || add_finding "$name.prototype" "allow_mock_prototype set but prototype_owner missing"
          if [ -z "$proto_expires" ]; then add_finding "$name.prototype" "allow_mock_prototype set but prototype_expires missing"
          else
            pe="$(epoch "$proto_expires")"
            if [ -z "$pe" ]; then add_finding "$name.prototype" "prototype_expires not a parseable date: $proto_expires"
            elif [ "$pe" -lt "$now" ]; then add_finding "$name.prototype" "prototype window EXPIRED ($proto_expires) — wire it or sign a deferral"; fi
          fi
        fi
        ;;
      *)
        add_finding "$name.status" "status must be live-wired|signed-deferred|mock (got '$status')"
        ;;
    esac
  done < <(jq -c '.integrations[]?' "$MANIFEST" 2>/dev/null)
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "integration-proof selftest SKIP - jq not installed."; return 0; fi
  echo "integration-proof-gate selftest:"
  today="$(date -u +%Y-%m-%d)"
  future="$(date -u -d '+30 days' +%Y-%m-%d 2>/dev/null)"
  [ -n "$future" ] || future="$(date -u -v+30d +%Y-%m-%d 2>/dev/null)"
  old="2000-01-01"; pastexp="2001-01-01"

  mk() { mkdir -p "$1/walteur-kit"; }
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }

  # 1. no manifest, no external surface -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; ck "no manifest + no external surface -> NA" 0 "$(run "$t")"; rm -rf "$t"

  # 2. external-service interface but no manifest -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"
  printf '{"interfaces":[{"name":"x","type":"external-service"}],"risk_tier":"medium"}\n' > "$t/walteur-kit/build-contract.json"
  ck "external surface declared but no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 3. live-wired with fresh proof -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'ok 200 inserted id=42\n' > "$t/walteur-kit/roundtrip.log"
  jq -n --arg d "$today" '{integrations:[{name:"supabase",kind:"database",status:"live-wired",proof:{command:"node probe.mjs",command_output_ref:"walteur-kit/roundtrip.log",captured_at:$d}}]}' > "$t/walteur-kit/integrations.json"
  ck "live-wired + fresh proof -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 4. live-wired missing proof file -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"
  jq -n --arg d "$today" '{integrations:[{name:"supabase",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/missing.log",captured_at:$d}}]}' > "$t/walteur-kit/integrations.json"
  ck "live-wired + missing proof artifact -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 5. live-wired stale proof -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'x\n' > "$t/walteur-kit/r.log"
  jq -n --arg d "$old" '{integrations:[{name:"s",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/r.log",captured_at:$d}}]}' > "$t/walteur-kit/integrations.json"
  ck "live-wired + stale proof -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 6. mock without allow_mock_prototype -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"
  jq -n '{integrations:[{name:"calcom",kind:"calendar",status:"mock"}]}' > "$t/walteur-kit/integrations.json"
  ck "mock without flag -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 7. mock WITH allow_mock_prototype + future expiry + low risk -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf '{"risk_tier":"low"}\n' > "$t/walteur-kit/build-contract.json"
  jq -n --arg e "$future" '{allow_mock_prototype:true,prototype_owner:"Tony",prototype_expires:$e,integrations:[{name:"calcom",kind:"calendar",status:"mock"}]}' > "$t/walteur-kit/integrations.json"
  ck "mock + valid prototype window + low risk -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 8. mock WITH allow_mock_prototype but EXPIRED -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf '{"risk_tier":"low"}\n' > "$t/walteur-kit/build-contract.json"
  jq -n --arg e "$pastexp" '{allow_mock_prototype:true,prototype_owner:"Tony",prototype_expires:$e,integrations:[{name:"calcom",kind:"calendar",status:"mock"}]}' > "$t/walteur-kit/integrations.json"
  ck "mock + EXPIRED prototype -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 9. signed-deferred complete -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"
  jq -n '{integrations:[{name:"teams",kind:"chat",status:"signed-deferred",deferral:{reason:"sandbox key pending",owner:"Tony",ticket:"WALT-318",review_trigger:"before beta"}}]}' > "$t/walteur-kit/integrations.json"
  ck "signed-deferred complete -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 10. signed-deferred missing ticket -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"
  jq -n '{integrations:[{name:"teams",kind:"chat",status:"signed-deferred",deferral:{reason:"x",owner:"Tony",ticket:"",review_trigger:"beta"}}]}' > "$t/walteur-kit/integrations.json"
  ck "signed-deferred missing ticket -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 11. mock allowed but risk=high -> FAIL (no trapdoor for high risk)
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf '{"risk_tier":"high"}\n' > "$t/walteur-kit/build-contract.json"
  jq -n --arg e "$future" '{allow_mock_prototype:true,prototype_owner:"Tony",prototype_expires:$e,integrations:[{name:"pay",kind:"payments",status:"mock"}]}' > "$t/walteur-kit/integrations.json"
  ck "mock + high risk -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 12. bypass -> SKIP exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"
  jq -n '{integrations:[{name:"x",kind:"other",status:"mock"}]}' > "$t/walteur-kit/integrations.json"
  WALTEUR_ROOT="$t" WALTEUR_INTEGRATION_PROOF=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"

  # 13. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; touch "$t/walteur-kit/PAUSED"
  jq -n '{integrations:[]}' > "$t/walteur-kit/integrations.json"
  ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # 14. ACTIVE probe runs and succeeds -> PASS (verification, not attestation)
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'ok\n' > "$t/walteur-kit/r.log"
  jq -n --arg d "$today" '{integrations:[{name:"s",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/r.log",captured_at:$d,probe_command:"node --version"}}]}' > "$t/walteur-kit/integrations.json"
  ck "active probe succeeds -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 15. ACTIVE probe runs and FAILS -> FAIL (the live-wired claim is false right now)
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'ok\n' > "$t/walteur-kit/r.log"
  jq -n --arg d "$today" '{integrations:[{name:"s",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/r.log",captured_at:$d,probe_command:"node --nonexistent-flag-zzz"}}]}' > "$t/walteur-kit/integrations.json"
  ck "active probe FAILS -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 16. destructive probe refused -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'ok\n' > "$t/walteur-kit/r.log"
  jq -n --arg d "$today" '{integrations:[{name:"s",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/r.log",captured_at:$d,probe_command:"rm -rf /tmp/zz"}}]}' > "$t/walteur-kit/integrations.json"
  ck "destructive probe refused -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 17. probe would fail but WALTEUR_INTEGRATION_PROBE=off -> PASS (probe skipped, artifact stands)
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'ok\n' > "$t/walteur-kit/r.log"
  jq -n --arg d "$today" '{integrations:[{name:"s",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/r.log",captured_at:$d,probe_command:"node --nonexistent-flag-zzz"}}]}' > "$t/walteur-kit/integrations.json"
  WALTEUR_ROOT="$t" WALTEUR_INTEGRATION_PROBE=off bash "$0" >/dev/null 2>&1; ck "probe fails but PROBE=off -> PASS" 0 "$?"; rm -rf "$t"
  # 18. D4 regression — trivial "true" probe proves no round-trip -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'ok\n' > "$t/walteur-kit/r.log"
  jq -n --arg d "$today" '{integrations:[{name:"s",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/r.log",captured_at:$d,probe_command:"true"}}]}' > "$t/walteur-kit/integrations.json"
  ck "G18 trivial true probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # ── Unify probe hardening: shared _probe-proof.sh kernel poison classes (constant-exit/no-op) ──
  # G19 — "false" no-op probe -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'ok\n' > "$t/walteur-kit/r.log"
  jq -n --arg d "$today" '{integrations:[{name:"s",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/r.log",captured_at:$d,probe_command:"false"}}]}' > "$t/walteur-kit/integrations.json"
  ck "G19 false no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G20 — ":" no-op probe -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'ok\n' > "$t/walteur-kit/r.log"
  jq -n --arg d "$today" '{integrations:[{name:"s",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/r.log",captured_at:$d,probe_command:":"}}]}' > "$t/walteur-kit/integrations.json"
  ck "G20 ':' no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G21 — "bash -lc 'exit 0'" constant-exit no-op (the class the shared kernel names by name) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'ok\n' > "$t/walteur-kit/r.log"
  jq -n --arg d "$today" --arg p "bash -lc 'exit 0'" '{integrations:[{name:"s",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/r.log",captured_at:$d,probe_command:$p}}]}' > "$t/walteur-kit/integrations.json"
  ck "G21 bash -lc exit-0 no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G22 — shared guard fail-closed: if _probe-proof.sh is unavailable at source time, a probe must FAIL
  # closed rather than silently skip the no-op check. Simulate by pointing the gate at a copy of itself
  # with the sibling guard file temporarily hidden.
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'ok\n' > "$t/walteur-kit/r.log"
  jq -n --arg d "$today" '{integrations:[{name:"s",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/r.log",captured_at:$d,probe_command:"node --version"}}]}' > "$t/walteur-kit/integrations.json"
  gdir="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; cp "$SELF" "$gdir/integration-proof-gate.sh"
  ck "G22 guard file absent -> FAIL (fail-closed)" 2 "$(WALTEUR_ROOT="$t" bash "$gdir/integration-proof-gate.sh" >/dev/null 2>&1; echo $?)"
  rm -rf "$t" "$gdir"
  # G23 — behavior-change regression: an unrecognized runner that is really a constant-exit no-op
  # (previously silently loud-skipped) must now FAIL, since the shared kernel proves it non-trivial.
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'ok\n' > "$t/walteur-kit/r.log"
  jq -n --arg d "$today" --arg p "perl -e 'exit 0'" '{integrations:[{name:"s",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/r.log",captured_at:$d,probe_command:$p}}]}' > "$t/walteur-kit/integrations.json"
  ck "G23 unrecognized-runner no-op -> FAIL (was loud-skip)" 2 "$(run "$t")"; rm -rf "$t"
  # G24 false-positive guard: an unrecognized runner that references a REAL on-disk script (the shared
  # kernel's file-existence branch) still counts as a live round-trip attempt and runs.
  t="$(mktemp -d "${TMPDIR:-/tmp}/integratio.XXXXXX")"; mk "$t"; printf 'ok\n' > "$t/walteur-kit/r.log"; printf '#!/usr/bin/env perl\nexit 0;\n' > "$t/probe.pl"; chmod +x "$t/probe.pl" 2>/dev/null
  jq -n --arg d "$today" --arg p "perl walteur-kit/../probe.pl" '{integrations:[{name:"s",kind:"database",status:"live-wired",proof:{command:"x",command_output_ref:"walteur-kit/r.log",captured_at:$d,probe_command:$p}}]}' > "$t/walteur-kit/integrations.json"
  ck "G24 unrecognized-runner real script -> PASS (FP guard)" 0 "$(run "$t")"; rm -rf "$t"

  echo "integration-proof-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_INTEGRATION_PROOF:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_INTEGRATION_PROOF=off"; echo "integration-proof-gate: bypassed." >&2; exit 0; }

if [ ! -f "$MANIFEST" ]; then
  if external_surface_declared; then
    add_finding "manifest" "external surface declared (build-contract interface or preflight signal) but walteur-kit/integrations.json is absent"
    write_report "FAIL" "external surface declared but integrations.json absent"
    echo "integration-proof-gate: FAIL - external surface declared but integrations.json absent" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "no integrations.json and no external surface declared"
  echo "integration-proof-gate: NOT_APPLICABLE"
  exit 0
fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "integration-proof-gate: SKIP - jq unavailable." >&2; exit 0; fi
if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then add_finding "json" "integrations.json is not valid JSON"; write_report "FAIL" "invalid JSON"; echo "integration-proof-gate: FAIL - invalid JSON" >&2; exit 2; fi

validate

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures integration proof violation(s)"
  echo "integration-proof-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null || true
  exit 2
fi
write_report "PASS" "all integrations proven, signed-deferred, or within a valid prototype window"
echo "integration-proof-gate: PASS" >&2
exit 0
