#!/usr/bin/env bash
# WALTEUR load-proof-gate — HARD gate (enterprise backlog rank 10). perf-gate runs k6/wrk2 only if the tool
# AND a baseline happen to exist, else loud-SKIPs; the asserted p99 is never proven against concurrency. A
# $50-100M SaaS can ship having NEVER measured real p99 under load. This gate requires a FRESH load-run
# artifact whose achieved p99 <= budget at a declared target RPS + VUs.
#
# Applies when has_api_boundary at risk_tier high/regulated, or load-proof.json exists.
# CONTRACT: missing/stale/over-budget run => FAIL exit 2 · not required => NOT_APPLICABLE · jq absent => SKIP
# · PAUSED => exit 2 · bypass WALTEUR_LOAD=off.
#
# EXEC (S033, test-claim pattern): load-proof.json MAY carry recorded_command (the command that produced the
# run). WALTEUR_LOAD_EXEC defaults to 0 (OFF) — load runs are expensive (k6/wrk2 against a live target), so
# re-running on every gate pass is opt-in, unlike the code-class-armed EXEC defaults elsewhere. When
# WALTEUR_LOAD_EXEC=1 and the manifest otherwise proves freshness, the recorded_command is validated via
# _probe-proof.sh (rejects no-op/constant-exit commands) and RE-RUN; the OBSERVED exit is required to be 0
# and is recorded as load_probe_executed+observed_exit (the marker execution-ratio-gate counts). With
# EXEC=1 and NO recorded_command present, the claim is unverifiable and FAILs (a freshness claim with no
# re-runnable proof is not accepted once EXEC is armed).
# Report: walteur-kit/load-proof-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "load-proof-gate - HARD gate (enterprise backlog rank 10). perf-gate runs k6/wrk2 only if the tool"
  printf '%s\n' "usage: bash load-proof-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/load-proof-report.json - fix recipes: walteur-kit/REMEDIATION.md (## load-proof-gate)"
  printf '%s\n' "bypass: WALTEUR_LOAD=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

# Fail-closed shared guard: the constant-exit / no-op command CLASS is closed by _probe-proof.sh
# (probe_proves_something) — same guard test-claim-verifier-gate.sh and qa-contract-gate.sh source.
if [ -f "${SELF%/*}/_probe-proof.sh" ]; then . "${SELF%/*}/_probe-proof.sh"; fi

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
MANIFEST="${WALTEUR_LOAD_FILE:-$KIT/load-proof.json}"
REPORT="$KIT/load-proof-report.json"
MAX_AGE_DAYS="${WALTEUR_LOAD_MAX_AGE_DAYS:-14}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
# write_report V R — when load_probe_executed=1 (set by the EXEC block), the report carries
# load_probe_executed:true + observed_exit, the marker execution-ratio-gate counts.
write_report() {
  v="$1"; r="$2"
  if have jq; then
    if [ "${load_probe_executed:-0}" = "1" ]; then
      jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" --argjson oe "${load_observed_exit:-null}" \
        '{verdict:$v, ts:$ts, gate:"load-proof", reason:$r, findings:$f, load_probe_executed:true, observed_exit:$oe}' > "$REPORT" 2>/dev/null && return 0
    fi
    jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"load-proof", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"load-proof","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true
}

risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }
has_api() { [ -f "$SIGNALS" ] && have jq && jq -e '.has_api_boundary==true' "$SIGNALS" >/dev/null 2>&1; }
applies() { [ -f "$MANIFEST" ] && return 0; if has_api; then case "$(risk)" in high|regulated) return 0;; esac; fi; return 1; }
epoch() {
  # Portable: GNU date (-d) first, then BSD/macOS date (-j -f) with the two run_date shapes we accept
  # (date-only, or date+time with optional trailing Z). Empty output => caller treats as unparseable.
  d="$1"
  out="$(date -u -d "$d" +%s 2>/dev/null)" && [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  norm="${d%Z}"
  case "$norm" in
    *T*) out="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$norm" +%s 2>/dev/null)" ;;
    *' '*) out="$(date -u -j -f '%Y-%m-%d %H:%M:%S' "$norm" +%s 2>/dev/null)" ;;
    *) out="$(date -u -j -f '%Y-%m-%d' "$norm" +%s 2>/dev/null)" ;;
  esac
  [ -n "$out" ] && printf '%s\n' "$out" || echo ""
}

selftest() {
  # Make $0 absolute up front so `bash "$0"` works regardless of caller cwd (no cd happens below, but be robust).
  case "$0" in /*) : ;; *) self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"; set -- "$@"; SELF="$self" ;; esac
  SELF="${SELF:-$0}"
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "load-proof selftest SKIP - jq not installed."; return 0; fi
  echo "load-proof-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  api() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${2:-high}" > "$1/walteur-kit/build-contract.json"; printf '{"has_api_boundary":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  goodman() { jq -n --arg d "$(date -u +%Y-%m-%d)" '{tool:"k6",run_date:$d,target_rps:500,target_vus:200,critical_paths:[{path:"/api/checkout",target_p99_ms:250,achieved_p99_ms:180}]}' > "$1/walteur-kit/load-proof.json"; }

  # 1. low-risk api, no manifest -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" medium; ck "low-risk api, no manifest -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. high-risk api + good load run -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodman "$t"; ck "good load run -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. high-risk api + manifest absent -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; ck "high-risk, no load proof -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. achieved p99 OVER budget -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodman "$t"; jq '.critical_paths[0].achieved_p99_ms=900' "$t/walteur-kit/load-proof.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/load-proof.json"; ck "p99 over budget -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. stale run -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodman "$t"; jq '.run_date="2024-01-01"' "$t/walteur-kit/load-proof.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/load-proof.json"; ck "stale load run -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. missing target_rps/vus -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodman "$t"; jq 'del(.target_rps)' "$t/walteur-kit/load-proof.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/load-proof.json"; ck "no target_rps -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. no critical_paths -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodman "$t"; jq '.critical_paths=[]' "$t/walteur-kit/load-proof.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/load-proof.json"; ck "no critical paths -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; WALTEUR_ROOT="$t" WALTEUR_LOAD=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # --- Red-team regressions (proven false-negatives) ---
  # G1: future-dated run_date must FAIL (one-sided staleness bypass).
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodman "$t"; jq '.run_date="2099-12-31"' "$t/walteur-kit/load-proof.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/load-proof.json"; ck "G1 future run_date -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2: object-typed critical_path.path must FAIL (was crashing @tsv, emptying the budget loop).
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; jq -n --arg d "$(date -u +%Y-%m-%d)" '{tool:"k6",run_date:$d,target_rps:500,target_vus:200,critical_paths:[{path:{"url":"/api/checkout","method":"POST"},target_p99_ms:250,achieved_p99_ms:5000}]}' > "$t/walteur-kit/load-proof.json"; ck "G2 object-typed path -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3: zero-load run (target_rps=0) must FAIL (vacuous no-op probe).
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodman "$t"; jq '.target_rps=0' "$t/walteur-kit/load-proof.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/load-proof.json"; ck "G3 zero target_rps -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3b: zero-concurrency run (target_vus=0) must FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodman "$t"; jq '.target_vus=0' "$t/walteur-kit/load-proof.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/load-proof.json"; ck "G3b zero target_vus -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G4: malformed / multi-document manifest must FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodman "$t"; printf '{"a":1}\n{"b":2}\n' > "$t/walteur-kit/load-proof.json"; ck "G4 multi-doc manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G5: numeric-string p99 (string \"5000\" not number) must FAIL — shape guard requires numeric.
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodman "$t"; jq '.critical_paths[0].achieved_p99_ms="5000"' "$t/walteur-kit/load-proof.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/load-proof.json"; ck "G5 string p99 -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # FP-GUARD: a clean, fresh, positive-load, well-shaped run still PASSES (no over-fail).
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodman "$t"; ck "FP-guard clean run -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # FP-GUARD: today-dated run is fresh (not flagged future by the +1d skew window).
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; jq -n --arg d "$(date -u +%Y-%m-%d)" '{tool:"k6",run_date:$d,target_rps:1,target_vus:1,critical_paths:[{path:"/api/x",target_p99_ms:300,achieved_p99_ms:299}]}' > "$t/walteur-kit/load-proof.json"; ck "FP-guard min positive load -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # ── EXEC-mode selftests (S033, opt-in — WALTEUR_LOAD_EXEC default is 0) ────────────────────────────────
  goodcmd() { jq -n --arg d "$(date -u +%Y-%m-%d)" --arg cmd "$1" '{tool:"k6",run_date:$d,target_rps:500,target_vus:200,recorded_command:$cmd,critical_paths:[{path:"/api/checkout",target_p99_ms:250,achieved_p99_ms:180}]}' > "$2/walteur-kit/load-proof.json"; }

  # default OFF: EXEC-armed manifest with a no-op recorded_command still PASSES when WALTEUR_LOAD_EXEC unset (opt-in, not code-class-armed)
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodcmd "true" "$t"; ck "WALTEUR_LOAD_EXEC unset (default 0) -> PASS (not executed)" 0 "$(run "$t")"; rm -rf "$t"

  # NEGATIVE CONTROL: WALTEUR_LOAD_EXEC=1 + no-op recorded_command (command:true) -> FAIL (refused)
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodcmd "true" "$t"; WALTEUR_LOAD_EXEC=1 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "EXEC=1 no-op recorded_command 'true' -> FAIL (refused)" 2 "$?"; rm -rf "$t"

  # NEGATIVE CONTROL: WALTEUR_LOAD_EXEC=1 + injected FAILING command -> FAIL (observed nonzero exit)
  if have node; then
    t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; mkdir -p "$t/test"; printf 'process.exit(1);\n' > "$t/test/boom.js"; goodcmd "node test/boom.js" "$t"
    WALTEUR_LOAD_EXEC=1 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "EXEC=1 injected failing command -> FAIL (observed nonzero)" 2 "$?"
    jq -e '.load_probe_executed==true and .observed_exit==1' "$t/walteur-kit/load-proof-report.json" >/dev/null 2>&1; ck "FAIL report records load_probe_executed+observed_exit=1" 0 "$?"
    rm -rf "$t"
  fi

  # GENUINE PASS: WALTEUR_LOAD_EXEC=1 + a real passing command -> PASS with exec markers recorded
  if have node; then
    t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; mkdir -p "$t/test"; printf 'process.exit(0);\n' > "$t/test/ok.js"; goodcmd "node test/ok.js" "$t"
    WALTEUR_LOAD_EXEC=1 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "EXEC=1 genuine passing command -> PASS" 0 "$?"
    jq -e '.load_probe_executed==true and .observed_exit==0' "$t/walteur-kit/load-proof-report.json" >/dev/null 2>&1; ck "PASS report records load_probe_executed+observed_exit=0 (exec marker)" 0 "$?"
    rm -rf "$t"
  fi

  # WALTEUR_LOAD_EXEC=1 with NO recorded_command -> FAIL (unverifiable freshness claim, no re-runnable proof)
  t="$(mktemp -d "${TMPDIR:-/tmp}/loadproofg.XXXXXX")"; api "$t" high; goodman "$t"; WALTEUR_LOAD_EXEC=1 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "EXEC=1 no recorded_command -> FAIL (unverifiable)" 2 "$?"; rm -rf "$t"

  echo "load-proof-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_LOAD:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_LOAD=off"; echo "load-proof-gate: bypassed." >&2; exit 0; }

if ! applies; then write_report "NOT_APPLICABLE" "no load-proof required (not a high/regulated API surface, no load-proof.json)"; echo "load-proof-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "load-proof-gate: SKIP." >&2; exit 0; fi

if [ ! -s "$MANIFEST" ]; then
  add_finding "manifest" "traffic-serving surface at $(risk) risk but walteur-kit/load-proof.json absent — p99 was never measured under load"
  write_report "FAIL" "load-proof absent"; echo "load-proof-gate: FAIL - manifest absent" >&2; exit 2
fi
# Reject malformed / multi-document / non-object manifests — they cannot be scored and must not slip.
if ! jq -e -s 'length==1 and (.[0]|type=="object")' "$MANIFEST" >/dev/null 2>&1; then
  add_finding "manifest" "load-proof.json is not a single valid JSON object (malformed, empty, or multi-document) — cannot be scored"
  write_report "FAIL" "malformed load-proof" ; echo "load-proof-gate: FAIL - malformed manifest" >&2; exit 2
fi
rps="$(jq -r '.target_rps // ""' "$MANIFEST")"; vus="$(jq -r '.target_vus // ""' "$MANIFEST")"
if ! printf '%s' "$rps" | grep -qE '^[0-9]+$'; then add_finding "target_rps" "load-proof must declare target_rps (a budget without a load level is meaningless)"
elif [ "$rps" -lt 1 ] 2>/dev/null; then add_finding "target_rps" "target_rps=$rps is a ZERO-load run — p99 was never proven against any traffic"; fi
if ! printf '%s' "$vus" | grep -qE '^[0-9]+$'; then add_finding "target_vus" "load-proof must declare target_vus (concurrency)"
elif [ "$vus" -lt 1 ] 2>/dev/null; then add_finding "target_vus" "target_vus=$vus is a ZERO-concurrency run — p99 was never proven under concurrency"; fi
rd="$(jq -r '.run_date // ""' "$MANIFEST")"
if [ -z "$rd" ]; then add_finding "run_date" "no run_date"
elif ! printf '%s' "$rd" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9:.]+Z?)?$'; then
  add_finding "run_date" "run_date not a valid ISO date: $rd"
else
  re="$(epoch "$rd")"; now="$(date -u +%s)"
  if [ -z "$re" ]; then add_finding "run_date" "run_date not parseable: $rd"
  elif [ "$re" -gt $(( now + 86400 )) ]; then add_finding "run_date" "run_date is in the FUTURE ($rd) — a post-dated load run is not proven against the current build"
  elif [ $(( (now - re) / 86400 )) -gt "$MAX_AGE_DAYS" ]; then add_finding "run_date" "load run is stale (>$MAX_AGE_DAYS days: $rd) — re-run against the current build"; fi
fi
if ! jq -e '.critical_paths | type=="array" and length>=1' "$MANIFEST" >/dev/null 2>&1; then
  add_finding "critical_paths" "load-proof must score >=1 critical_path with target_p99_ms + achieved_p99_ms"
elif ! jq -e '.critical_paths | all((type=="object") and (.path|type=="string") and (.target_p99_ms|type=="number") and (.achieved_p99_ms|type=="number"))' "$MANIFEST" >/dev/null 2>&1; then
  add_finding "critical_paths" "every critical_path must be an object with a string path and numeric target_p99_ms/achieved_p99_ms — malformed shape cannot be scored"
else
  # Each element is shape-validated above; coerce path to a scalar string so a stray non-scalar can never empty the stream.
  while IFS=$'\t' read -r path tgt ach; do
    [ -n "$path" ] || continue
    if ! printf '%s' "$ach" | grep -qE '^[0-9]+$' || ! printf '%s' "$tgt" | grep -qE '^[0-9]+$'; then add_finding "$path" "critical_path '$path' missing numeric target/achieved p99"; continue; fi
    [ "$ach" -le "$tgt" ] 2>/dev/null || add_finding "$path" "measured p99 ${ach}ms EXCEEDS budget ${tgt}ms under load — will breach SLO at scale"
  done < <(jq -r '.critical_paths[]? | [((.path // "path")|tostring), ((.target_p99_ms // "x")|tostring), ((.achieved_p99_ms // "x")|tostring)] | @tsv' "$MANIFEST" 2>/dev/null)
fi

# ── EXEC — re-run the recorded load command and OBSERVE the real exit (S033, test-claim pattern) ────────
# A load-proof.json can CLAIM a fresh, in-budget run with nothing re-running it. WALTEUR_LOAD_EXEC defaults
# to 0 (load runs are expensive) — opt-in only. When WALTEUR_LOAD_EXEC=1, the manifest's recorded_command is
# validated via _probe-proof.sh (rejects no-op/constant-exit — a green no-op proves NOTHING under load) and
# RE-RUN; the observed exit must be 0. No recorded_command while EXEC=1 => unverifiable freshness => FAIL.
load_probe_executed=0; load_observed_exit="null"
if [ "${WALTEUR_LOAD_EXEC:-0}" = "1" ]; then
  load_cmd="$(jq -r '.recorded_command // ""' "$MANIFEST" 2>/dev/null)"
  if [ -z "$load_cmd" ] || [ "$load_cmd" = "null" ]; then
    add_finding "recorded_command" "WALTEUR_LOAD_EXEC=1: load-proof.json claims a fresh run but carries no recorded_command — an unverifiable freshness claim"
  else
    load_first="$(printf '%s' "$load_cmd" | awk '{print $1}')"
    case "$load_first" in
      npm|pnpm|yarn|npx|node|deno|bun|python|python3|k6|wrk|wrk2|artillery|locust|go|bash|sh|make|just|task) : ;;
      *) add_finding "recorded_command.runner" "recorded_command runner '$load_first' is not an allowlisted load-test runner — refusing to execute an unrecognized command"; load_first="__BLOCKED__" ;;
    esac
    if printf '%s' "$load_cmd" | grep -Eqi 'curl|wget|/dev/tcp|base64|netcat|ncat|rm[[:space:]]+-rf|sudo|mkfs|[[:space:]]dd[[:space:]]|ssh[[:space:]]|scp[[:space:]]|\$\(|`|/etc/(passwd|shadow)|>[[:space:]]*/dev/sd'; then
      add_finding "recorded_command.danger" "recorded_command contains a dangerous/exfil token — refusing to run"; load_first="__BLOCKED__"
    fi
    if [ "$load_first" != "__BLOCKED__" ]; then
      if ! command -v probe_proves_something >/dev/null 2>&1; then
        add_finding "recorded_command.guard" "shared probe guard (_probe-proof.sh) unavailable — cannot prove recorded_command is non-trivial; failing closed"
      elif ! probe_proves_something "$load_cmd"; then
        add_finding "recorded_command.noop" "recorded_command '$load_cmd' invokes no recognized load-test runner and references no real artifact — a constant-exit/no-op whose green exit proves NOTHING; refusing to accept the claim"
      else
        load_out="$( (cd "$ROOT" && eval "$load_cmd") 2>&1 )"; load_rc=$?
        load_probe_executed=1; load_observed_exit="$load_rc"
        if [ "$load_rc" -ne 0 ]; then
          load_tail5="$(printf '%s\n' "$load_out" | tail -5 | tr '\n' '|')"
          add_finding "recorded_command.exec" "load-proof.json claimed a valid fresh run but the recorded_command was RE-RUN and exited $load_rc — the claim is FALSE. cmd: $load_cmd · last lines: ${load_tail5:0:300}"
        fi
      fi
    fi
  fi
fi

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures load-proof violation(s)"
  echo "load-proof-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "fresh load run met p99 budget on every critical path at the declared RPS/VUs"
echo "load-proof-gate: PASS" >&2
exit 0
