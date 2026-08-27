#!/usr/bin/env bash
# WALTEUR slo-error-budget-gate — HARD gate. A service with no SLO is a service no one promised to keep
# up; a service with SLOs but no alerts is a promise no one is watching; an error budget that is not a
# real number is a budget no one can spend. otel-gate proves the service can be SEEN (traces/metrics/logs);
# THIS gate proves someone declared WHAT "healthy" means, set a measurable objective, bound an alert to it,
# and reserved a spendable error budget — the operate-readiness companion to instrumentation.
#
# APPLICABILITY (any service/deployable, else NOT_APPLICABLE exit 0):
#   A service/deployable is in scope when preflight-signals.json says has_api_boundary | external_surface |
#   is_cloud_iac is true, OR build-contract.json build_class is software|data-ai|cloud-iac|mixed. No such
#   signal => NOT_APPLICABLE (a pure library / one-shot script has no SLO to keep).
#
# REQUIRED ARTIFACT: walteur-kit/slo.json
#   {
#     "slos": [ { "name", "sli" in {latency,errors,traffic,saturation}, "objective", "window", "error_budget" } ],
#     "alerts": [ { "slo" (matches an slos[].name), "condition", "channel" } ],
#     "dashboards": [ "<ref to a non-empty file under ROOT>" ],
#     "logging":  { "structured": true },
#     "tracing":  { "enabled": <bool> }
#   }
#
# HARD CHECKS (exit-2 on checkable facts):
#   - slo.json exists and is valid JSON (a service that is in scope but has no slo.json => FAIL).
#   - at least one SLO with sli=="errors" AND at least one with sli=="latency".
#   - EVERY slo has a bound alert: each slos[].name appears in some alerts[].slo (an unwatched SLO => FAIL).
#   - every alerts[].slo names a declared slos[].name (a dangling alert => FAIL).
#   - each declared error_budget is a number with 0 < eb <= 100.
#   - every dashboards[] ref resolves to a safe, NON-EMPTY file under ROOT.
#   - logging.structured == true (boolean true; missing/false => FAIL).
#
# PROTOCOL CHECK (existence/freshness, NOT correctness):
#   - dashboard quality. Each dashboards[] ref is checked for EXISTENCE + NON-EMPTINESS only. Whether the
#     dashboard actually charts the SLIs well is an LLM/human judgement this gate does not and cannot
#     adjudicate — it is a PROTOCOL marker, never a correctness claim.
#
# CONTRACT:
#   walteur-kit/PAUSED present            => exit 2.
#   WALTEUR_SLO=off                       => loud SKIP exit 0.
#   not a service/deployable              => NOT_APPLICABLE exit 0.
#   jq absent                             => loud SKIP exit 0 (cannot_measure, never silent-green).
#   slo.json absent for a service         => FAIL exit 2.
#   any HARD violation                    => FAIL exit 2.
#   all HARD checks observed-good         => PASS exit 0.
#
# Report: walteur-kit/slo-error-budget-report.json {verdict, ts, gate, reason, findings, ...markers}
#   On a real check pass the report carries slo_checks_executed (execution marker) so the execution-ratio
#   meta-gate counts this gate as one that OBSERVES, not merely reads a verdict.
#
# HONESTY LABELS: the SLO/alert/error-budget/dashboard-existence/structured-logging checks are HARD
#   (exit-2 on decidable facts). "dashboard quality" is PROTOCOL (existence/freshness only). This gate
#   weakens no security control and reads no secret values.
#
# Bypass: WALTEUR_SLO=off. Pause: walteur-kit/PAUSED present.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "slo-error-budget-gate - HARD gate. A service with no SLO is a service no one promised to keep"
  printf '%s\n' "usage: bash slo-error-budget-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/slo-error-budget-report.json - fix recipes: walteur-kit/REMEDIATION.md (## slo-error-budget-gate)"
  printf '%s\n' "bypass: WALTEUR_SLO=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# Resolve $0 to an absolute SELF (Windows-drive arm first) before any cd, so --selftest can re-invoke us.
case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd || echo "$ROOT")"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
SLO="${WALTEUR_SLO_FILE:-$KIT/slo.json}"
REPORT="$KIT/slo-error-budget-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() {
  findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"
  failures=$((failures+1))
}
# write_report: jq-first, fail-closed plain-JSON fallback. extra is a JSON object merged into the report
# (used for execution markers like slo_checks_executed). Always emits a parseable report.
write_report() {
  local v="$1" r="$2" extra="${3:-}"
  [ -n "$extra" ] || extra='{}'   # NOTE: not ${3:-{}} — nested braces mis-parse and append a stray '}'.
  if have jq && printf '%s' "$extra" | jq -e . >/dev/null 2>&1; then
    jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" --argjson x "$extra" \
      '{verdict:$v, ts:$ts, gate:"slo-error-budget", reason:$r, findings:$f} + $x' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"slo-error-budget","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true
}

# applies: any service/deployable signal. preflight-signals (has_api_boundary|external_surface|is_cloud_iac)
# OR build-contract build_class in software|data-ai|cloud-iac|mixed. A pure library/script => no signal.
applies() {
  if [ -f "$SIGNALS" ] && have jq \
     && jq -e '(.has_api_boundary==true) or (.external_surface==true) or (.is_cloud_iac==true)' "$SIGNALS" >/dev/null 2>&1; then
    APPLIES_REASON="preflight-signals service/deployable signal"
    return 0
  fi
  if [ -f "$CONTRACT" ] && have jq; then
    local cls; cls="$(jq -r '.build_class // empty' "$CONTRACT" 2>/dev/null || true)"
    case "$cls" in
      software|data-ai|cloud-iac|mixed) APPLIES_REASON="build-contract build_class '$cls'"; return 0 ;;
    esac
  fi
  return 1
}

# safe_ref: a dashboard ref must be a relative path under ROOT, no traversal/absolute, resolving to a
# NON-EMPTY file. Mirrors the browser-proof-gate safe_ref idiom. Returns 0 if the ref is safe + non-empty.
safe_ref() {
  local ref="$1"
  [ -n "$ref" ] || return 1
  case "$ref" in
    /*|*../*|../*|*'/..'|*'//'*|?:[\\/]*) return 1 ;;
  esac
  [ -f "$ROOT/$ref" ] && [ -s "$ROOT/$ref" ]
}

selftest() {
  local pass=0 fail=0 tmp
  ck() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "  ok   - $name (rc=$got)"; pass=$((pass+1))
    else echo "  FAIL - $name (want $want got $got)"; fail=$((fail+1)); fi
  }
  if ! have jq; then echo "slo-error-budget-gate selftest SKIP - jq not installed."; return 0; fi

  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }

  # fixture: declare this build a service so the gate applies.
  svc() { mkdir -p "$1/walteur-kit"; printf '{"has_api_boundary":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  # fixture: a non-empty dashboard file so dashboard refs resolve.
  dash() { mkdir -p "$1/ops/dashboards"; printf '{"title":"service overview","panels":["latency_p99","error_rate"]}\n' > "$1/ops/dashboards/overview.json"; }

  # GOOD slo.json: errors+latency SLOs, every SLO has a bound alert, budgets in (0,100], dashboard ref
  # non-empty, structured logging true.
  goodslo() {
    dash "$1"
    jq -n '{
      slos: [
        { name:"api-availability", sli:"errors",  objective:99.9, window:"30d", error_budget:0.1 },
        { name:"api-latency-p99",  sli:"latency",  objective:99.0, window:"30d", error_budget:1.0 },
        { name:"ingest-saturation", sli:"saturation", objective:95.0, window:"30d", error_budget:5.0 }
      ],
      alerts: [
        { slo:"api-availability", condition:"error_rate > 0.1% for 5m",      channel:"pagerduty:oncall" },
        { slo:"api-latency-p99",  condition:"p99_latency > 300ms for 10m",   channel:"slack:#alerts" },
        { slo:"ingest-saturation", condition:"queue_depth > 80% for 15m",    channel:"slack:#alerts" }
      ],
      dashboards: [ "ops/dashboards/overview.json" ],
      logging: { structured: true },
      tracing: { enabled: true }
    }' > "$1/walteur-kit/slo.json"
  }

  echo "slo-error-budget-gate selftest:"

  # 1. not a service/deployable -> NOT_APPLICABLE (exit 0). Bare lib, no signals, no slo.json.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; mkdir -p "$tmp/walteur-kit"
  ck "no service signal -> NOT_APPLICABLE" 0 "$(run "$tmp")"; rm -rf "$tmp"

  # 2. service in scope but slo.json absent -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"
  ck "service without slo.json -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 3. invalid JSON slo.json -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; printf '{ bad json\n' > "$tmp/walteur-kit/slo.json"
  ck "invalid slo.json -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 4. GOOD: full valid slo.json -> PASS.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"
  ck "full valid slo.json -> PASS" 0 "$(run "$tmp")"
  jq -e '.slo_checks_executed != null' "$tmp/walteur-kit/slo-error-budget-report.json" >/dev/null 2>&1
  ck "PASS report records execution marker" 0 "$?"; rm -rf "$tmp"

  # 5. POISONED: no errors-SLO (drop the errors one) -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"
  jq '.slos |= map(select(.sli != "errors")) | .alerts |= map(select(.slo != "api-availability"))' \
     "$tmp/walteur-kit/slo.json" > "$tmp/s" && mv "$tmp/s" "$tmp/walteur-kit/slo.json"
  ck "missing errors-SLO -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 5b. POISONED twin: no latency-SLO -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"
  jq '.slos |= map(select(.sli != "latency")) | .alerts |= map(select(.slo != "api-latency-p99"))' \
     "$tmp/walteur-kit/slo.json" > "$tmp/s" && mv "$tmp/s" "$tmp/walteur-kit/slo.json"
  ck "missing latency-SLO -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 6. POISONED: an SLO with no bound alert (drop its alert, keep the SLO) -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"
  jq '.alerts |= map(select(.slo != "ingest-saturation"))' \
     "$tmp/walteur-kit/slo.json" > "$tmp/s" && mv "$tmp/s" "$tmp/walteur-kit/slo.json"
  ck "SLO with no bound alert -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 6b. POISONED: a dangling alert naming a non-existent SLO -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"
  jq '.alerts += [{ slo:"ghost-slo", condition:"x>1", channel:"slack:#x" }]' \
     "$tmp/walteur-kit/slo.json" > "$tmp/s" && mv "$tmp/s" "$tmp/walteur-kit/slo.json"
  ck "dangling alert (unknown SLO) -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 7. POISONED: dashboard ref empty file -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"; : > "$tmp/ops/dashboards/overview.json"
  ck "dashboard ref empty file -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 7b. POISONED: dashboard ref missing file -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"; rm -f "$tmp/ops/dashboards/overview.json"
  ck "dashboard ref missing file -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 7c. POISONED: dashboard ref traversal/unsafe -> FAIL (never escapes ROOT).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"
  jq '.dashboards = ["../../etc/passwd"]' "$tmp/walteur-kit/slo.json" > "$tmp/s" && mv "$tmp/s" "$tmp/walteur-kit/slo.json"
  ck "dashboard ref traversal -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 8. POISONED: structured:false -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"
  jq '.logging.structured = false' "$tmp/walteur-kit/slo.json" > "$tmp/s" && mv "$tmp/s" "$tmp/walteur-kit/slo.json"
  ck "structured:false -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 8b. POISONED: structured missing -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"
  jq 'del(.logging.structured)' "$tmp/walteur-kit/slo.json" > "$tmp/s" && mv "$tmp/s" "$tmp/walteur-kit/slo.json"
  ck "structured missing -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 9. POISONED: error_budget out of range (eb > 100) -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"
  jq '.slos[0].error_budget = 150' "$tmp/walteur-kit/slo.json" > "$tmp/s" && mv "$tmp/s" "$tmp/walteur-kit/slo.json"
  ck "error_budget > 100 -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 9b. POISONED: error_budget == 0 (not > 0) -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"
  jq '.slos[1].error_budget = 0' "$tmp/walteur-kit/slo.json" > "$tmp/s" && mv "$tmp/s" "$tmp/walteur-kit/slo.json"
  ck "error_budget == 0 -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 9c. POISONED: error_budget non-numeric -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"
  jq '.slos[2].error_budget = "lots"' "$tmp/walteur-kit/slo.json" > "$tmp/s" && mv "$tmp/s" "$tmp/walteur-kit/slo.json"
  ck "error_budget non-numeric -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 10. POISONED: an sli value outside the allowed enum -> FAIL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"
  jq '.slos[2].sli = "vibes"' "$tmp/walteur-kit/slo.json" > "$tmp/s" && mv "$tmp/s" "$tmp/walteur-kit/slo.json"
  ck "sli outside enum -> FAIL" 2 "$(run "$tmp")"; rm -rf "$tmp"

  # 11. applicability via build-contract build_class=software (no preflight signals) + good slo -> PASS.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; mkdir -p "$tmp/walteur-kit"
  printf '{"build_class":"software"}\n' > "$tmp/walteur-kit/build-contract.json"
  goodslo "$tmp"
  ck "build_class=software + good slo -> PASS" 0 "$(run "$tmp")"; rm -rf "$tmp"

  # 12. bypass -> exit 0 even on a would-fail fixture (service, no slo.json).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"
  WALTEUR_SLO=off WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1
  ck "bypass WALTEUR_SLO=off -> exit 0" 0 "$?"; rm -rf "$tmp"

  # 13. PAUSED -> exit 2.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sloerrorbu.XXXXXX")"; svc "$tmp"; goodslo "$tmp"; : > "$tmp/walteur-kit/PAUSED"
  ck "PAUSED -> exit 2" 2 "$(run "$tmp")"; rm -rf "$tmp"

  echo "slo-error-budget-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

# ── CONTRACT ENTRY ──────────────────────────────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_SLO:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_SLO=off"; echo "slo-error-budget-gate: bypassed (WALTEUR_SLO=off)." >&2; exit 0; }

if ! have jq; then
  write_report "SKIP" "jq unavailable (cannot_measure — not silent-green)"
  echo "slo-error-budget-gate: SKIP - jq not installed (cannot measure)." >&2
  exit 0
fi

APPLIES_REASON=""
if ! applies; then
  write_report "NOT_APPLICABLE" "no service/deployable signal (preflight has_api_boundary|external_surface|is_cloud_iac and build-contract build_class all absent)"
  echo "slo-error-budget-gate: NOT_APPLICABLE - no service/deployable signal." >&2
  exit 0
fi

# Service is in scope from here on: slo.json is REQUIRED.
if [ ! -s "$SLO" ]; then
  write_report "FAIL" "service/deployable in scope ($APPLIES_REASON) but walteur-kit/slo.json is missing/empty"
  echo "slo-error-budget-gate: FAIL - service in scope ($APPLIES_REASON) but slo.json absent." >&2
  exit 2
fi

if ! jq empty "$SLO" >/dev/null 2>&1; then
  write_report "FAIL" "walteur-kit/slo.json is not valid JSON"
  echo "slo-error-budget-gate: FAIL - slo.json is not valid JSON." >&2
  exit 2
fi

# ── SHAPE FLOOR ─────────────────────────────────────────────────────────────────────────────────────
if ! jq -e '(.slos | type=="array" and length>=1) and (.alerts | type=="array")' "$SLO" >/dev/null 2>&1; then
  add_finding "shape" "slo.json must have a non-empty slos[] array and an alerts[] array"
fi

# Per-SLO entry validity: name non-empty string; sli in the allowed enum; objective a number; window a
# non-empty string; error_budget a number with 0 < eb <= 100.
bad_slos="$(jq -r '
  (.slos // [])[]
  | select(
      ((.name|type)!="string" or (.name|length)==0)
      or ((.sli as $s | ["latency","errors","traffic","saturation"] | index($s)) | not)
      or ((.objective|type)!="number")
      or ((.window|type)!="string" or (.window|length)==0)
      or ((.error_budget|type)!="number") or (.error_budget<=0) or (.error_budget>100)
    )
  | (.name // "<unnamed>")
' "$SLO" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_slos" ] && add_finding "slos.entries" "invalid SLO entries (name/sli-enum/objective/window/error_budget 0<eb<=100): $bad_slos"

# At least one errors SLO AND at least one latency SLO.
jq -e 'any(.slos[]?; .sli=="errors")'  "$SLO" >/dev/null 2>&1 || add_finding "slos.errors"  "no SLO with sli==\"errors\" — declare what failure rate counts as unhealthy"
jq -e 'any(.slos[]?; .sli=="latency")' "$SLO" >/dev/null 2>&1 || add_finding "slos.latency" "no SLO with sli==\"latency\" — declare what slowness counts as unhealthy"

# EVERY slo has a bound alert: every slos[].name must appear in some alerts[].slo.
unwatched="$(jq -r '
  (.slos // []) as $s | (.alerts // []) as $a
  | ($a | map(.slo)) as $watched
  | $s[] | select((.name|type)=="string" and (.name|length)>0) | .name
  | select(. as $n | ($watched | index($n)) | not)
' "$SLO" 2>/dev/null | paste -sd ', ' -)"
[ -n "$unwatched" ] && add_finding "alerts.coverage" "SLO(s) with no bound alert: $unwatched — an SLO no one is alerted on is a promise no one is watching"

# Every alert must name a declared SLO (no dangling alerts).
dangling="$(jq -r '
  (.slos // []) as $s | ($s | map(.name)) as $names
  | (.alerts // [])[]
  | .slo as $aslo
  | select(($aslo|type)!="string" or ($aslo|length)==0 or (($names | index($aslo)) | not))
  | ($aslo // "<empty>")
' "$SLO" 2>/dev/null | paste -sd ', ' -)"
[ -n "$dangling" ] && add_finding "alerts.dangling" "alert(s) bound to an undeclared SLO name: $dangling"

# Alert entry validity: condition + channel must be non-empty strings.
bad_alerts="$(jq -r '
  (.alerts // [])[]
  | select(((.condition|type)!="string" or (.condition|length)==0) or ((.channel|type)!="string" or (.channel|length)==0))
  | (.slo // "<unnamed>")
' "$SLO" 2>/dev/null | paste -sd ', ' -)"
[ -n "$bad_alerts" ] && add_finding "alerts.entries" "alert(s) missing a non-empty condition or channel: $bad_alerts"

# logging.structured must be boolean true.
jq -e '.logging.structured == true' "$SLO" >/dev/null 2>&1 || add_finding "logging.structured" "logging.structured must be true — unstructured logs cannot be queried by SLI at 3am"

# dashboards[] must be a non-empty array of refs (PROTOCOL: existence + non-emptiness, not chart quality).
if ! jq -e '.dashboards | type=="array" and length>=1' "$SLO" >/dev/null 2>&1; then
  add_finding "dashboards.shape" "dashboards[] must be a non-empty array of refs to dashboard files"
else
  dash_checked=0
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    dash_checked=$((dash_checked+1))
    if ! safe_ref "$ref"; then
      add_finding "dashboards.ref" "dashboard ref missing, empty, or unsafe (must be a non-empty file under ROOT): $ref"
    fi
  done < <(jq -r '(.dashboards // [])[] | select(type=="string")' "$SLO" 2>/dev/null)
fi

# ── VERDICT ─────────────────────────────────────────────────────────────────────────────────────────
if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "$failures SLO/error-budget violation(s)"
  echo "slo-error-budget-gate: FAIL - $failures violation(s) -> $REPORT" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi

# All HARD checks observed-good. Record an execution marker so the execution-ratio meta-gate counts this.
slo_count="$(jq '.slos | length' "$SLO" 2>/dev/null || echo 0)"
alert_count="$(jq '.alerts | length' "$SLO" 2>/dev/null || echo 0)"
dash_count="$(jq '.dashboards | length' "$SLO" 2>/dev/null || echo 0)"
extra="$(jq -n --argjson slos "${slo_count:-0}" --argjson alerts "${alert_count:-0}" --argjson dashboards "${dash_count:-0}" \
  '{slo_checks_executed:true, slos:$slos, alerts:$alerts, dashboards:$dashboards}' 2>/dev/null || printf '{"slo_checks_executed":true}')"
write_report "PASS" "SLOs (errors+latency) declared, every SLO alert-bound, error budgets in (0,100], dashboards present, structured logging on ($APPLIES_REASON)" "$extra"
echo "slo-error-budget-gate: PASS - ${slo_count} SLO(s), ${alert_count} alert(s), ${dash_count} dashboard(s) -> $REPORT" >&2
exit 0
