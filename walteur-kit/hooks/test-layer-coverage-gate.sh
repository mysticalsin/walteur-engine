#!/usr/bin/env bash
# WALTEUR test-layer-coverage-gate — HARD gate (fix #7 completeness). Closes "only pure-logic
# tests + manual clicks": a UI build must carry a re-runnable test command at EVERY required
# layer (logic + component + e2e), each exit 0. A claimed-PASS layer with no recorded command
# is treated as not-executed and FAILS.
#
# Reads walteur-kit/test-coverage.json:
#   { "layers": { "logic":{"recorded_command":"...","exit_code":0},
#                 "component":{...}, "e2e":{...} } }
#
# Required layers by build type:
#   UI build (has_ui)                 => logic + component + e2e
#   software + API boundary (no UI)   => logic + e2e
#   software CLI/library (no UI/API)  => logic
#   data-ai / cloud-iac / workflow    => logic
#   document                          => NOT_APPLICABLE
#
# CONTRACT: required-but-missing manifest/layer => FAIL exit 2; jq absent => SKIP; PAUSED => exit 2.
# Report: walteur-kit/test-layer-coverage-report.json   Bypass: WALTEUR_TEST_LAYERS=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "test-layer-coverage-gate - HARD gate (fix #7 completeness). Closes only pure-logic"
  printf '%s\n' "usage: bash test-layer-coverage-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/test-layer-coverage-report.json - fix recipes: walteur-kit/REMEDIATION.md (## test-layer-coverage-gate)"
  printf '%s\n' "bypass: WALTEUR_TEST_LAYERS=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
CONTRACT="$KIT/build-contract.json"
SIGNALS="$KIT/preflight-signals.json"
COVERAGE="${WALTEUR_TEST_COVERAGE_FILE:-$KIT/test-coverage.json}"
REPORT="$KIT/test-layer-coverage-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
# EXEC mode default: build-class-aware. When walteur-kit/build-contract.json exists and its build_class
# is a code class (software|data-ai|cloud-iac|mixed), EXEC defaults to ARMED (1) — a code build gets the
# genuine live re-run by default. No contract, or a non-code class (e.g. document), keeps the legacy
# default of 0 (shape-read only). An explicit WALTEUR_TEST_LAYERS_EXEC env value always wins over this
# default, so WALTEUR_TEST_LAYERS_EXEC=0 still opts out even on a code-class contract.
default_exec_armed() {
  [ -f "$CONTRACT" ] || return 1
  have jq || return 1
  bc="$(jq -r '.build_class // ""' "$CONTRACT" 2>/dev/null)"
  case "$bc" in software|data-ai|cloud-iac|mixed) return 0;; *) return 1;; esac
}
if [ -n "${WALTEUR_TEST_LAYERS_EXEC:-}" ]; then
  EXEC="$WALTEUR_TEST_LAYERS_EXEC"
elif default_exec_armed; then
  EXEC=1
else
  EXEC=0
fi
# EXEC mode (opt-in): when WALTEUR_TEST_LAYERS_EXEC=1, each present layer's recorded_command is
# ACTUALLY re-run from $ROOT and its LIVE exit code is compared to expect_exit (default 0). This is
# genuine execution against project artifacts, not a shape-read of the recorded exit_code. Counters
# below are the honest evidence of real re-runs; they gate the execution marker on the report.
layers_reran=0          # commands actually launched + observed in this run
layers_reran_pass=0     # of those, how many observed the expected exit code
add_finding() { findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() {
  verdict="$1"; reason="$2"
  # Only stamp the execution marker when at least one recorded_command was GENUINELY re-run this
  # invocation (layers_reran>0). The shape-read path leaves the marker false — it did not execute.
  executed="false"; [ "$EXEC" = "1" ] && [ "$layers_reran" -gt 0 ] && executed="true"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" --argjson f "$findings" \
      --argjson ex "$executed" --argjson rr "$layers_reran" --argjson rp "$layers_reran_pass" \
      '{verdict:$v, ts:$ts, gate:"test-layer-coverage", reason:$r,
        test_layers_executed:$ex, layers_reran:$rr, layers_reran_pass:$rp, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"test-layer-coverage","reason":"%s","test_layers_executed":%s,"layers_reran":%s}\n' "$verdict" "$TS" "$reason" "$executed" "$layers_reran" > "$REPORT" 2>/dev/null || true
}

sig() { [ -f "$SIGNALS" ] && jq -e "$1" "$SIGNALS" >/dev/null 2>&1; }
build_class() { [ -f "$CONTRACT" ] && jq -r '.build_class // "software"' "$CONTRACT" 2>/dev/null || echo "software"; }
has_ui() { sig '.has_ui==true' && return 0; [ -f "$CONTRACT" ] && jq -e '[.interfaces[]?|select(.type=="ui")]|length>0' "$CONTRACT" >/dev/null 2>&1; }
has_api() { sig '.has_api_boundary==true'; }

classifiable() { [ -f "$CONTRACT" ] || [ -f "$SIGNALS" ]; }

required_layers() {
  classifiable || { echo ""; return; }   # no build-contract AND no signals => can't classify => NOT_APPLICABLE
  bc="$(build_class)"
  case "$bc" in
    document) echo ""; return;;
  esac
  if has_ui; then echo "logic component e2e"; return; fi
  case "$bc" in
    software|mixed) if has_api; then echo "logic e2e"; else echo "logic"; fi;;
    *) echo "logic";;
  esac
}

validate() {
  req="$(required_layers)"
  if [ -z "$req" ]; then return 0; fi   # NOT_APPLICABLE handled by caller via empty req
  if [ ! -s "$COVERAGE" ]; then
    add_finding "coverage_manifest" "code build requires test-coverage.json with re-runnable test layers ($req); manifest absent"
    return 0
  fi
  if ! jq -e '.layers | type=="object"' "$COVERAGE" >/dev/null 2>&1; then
    add_finding "coverage_shape" "test-coverage.json has no .layers object"
    return 0
  fi
  # Build the set to inspect: every required layer, PLUS (in EXEC mode) any extra declared layer
  # that carries a recorded_command — so genuinely-runnable layers beyond the minimum are re-run too.
  inspect="$req"
  if [ "$EXEC" = "1" ]; then
    extra="$(jq -r '.layers | to_entries[] | select((.value.recorded_command // "") != "") | .key' "$COVERAGE" 2>/dev/null)"
    for e in $extra; do case " $req " in *" $e "*) :;; *) inspect="$inspect $e";; esac; done
  fi

  for layer in $inspect; do
    is_required=0; case " $req " in *" $layer "*) is_required=1;; esac
    if ! jq -e --arg l "$layer" '.layers[$l]' "$COVERAGE" >/dev/null 2>&1; then
      [ "$is_required" = 1 ] && add_finding "${layer}_not_executed" "required test layer '$layer' missing from test-coverage.json (claimed but not executed)"
      continue
    fi
    cmd="$(jq -r --arg l "$layer" '.layers[$l].recorded_command // ""' "$COVERAGE")"
    code="$(jq -r --arg l "$layer" '.layers[$l].exit_code // "missing"' "$COVERAGE")"
    want="$(jq -r --arg l "$layer" '.layers[$l].expect_exit // 0' "$COVERAGE")"
    if [ -z "$cmd" ]; then
      [ "$is_required" = 1 ] && add_finding "${layer}_no_command" "test layer '$layer' has no recorded_command (not re-runnable = not real)"
      continue
    fi

    if [ "$EXEC" = "1" ]; then
      # GENUINE EXECUTION: re-run the recorded_command from $ROOT, observe the LIVE exit code.
      ( cd "$ROOT" && eval "$cmd" ) >/dev/null 2>&1
      live=$?
      layers_reran=$((layers_reran+1))
      if [ "$live" = "$want" ]; then
        layers_reran_pass=$((layers_reran_pass+1))
      else
        add_finding "${layer}_exec_mismatch" "test layer '$layer' RE-RAN '$cmd' -> OBSERVED exit $live (expected $want)"
      fi
    else
      # SHAPE-READ fallback: trust the recorded exit_code only (no re-run).
      if [ "$code" = "missing" ]; then add_finding "${layer}_no_exit" "test layer '$layer' has no exit_code"
      elif [ "$code" != "0" ]; then add_finding "${layer}_failed" "test layer '$layer' recorded exit_code $code (not passing)"; fi
    fi
  done
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "test-layer-coverage selftest SKIP - jq not installed."; return 0; fi
  echo "test-layer-coverage-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  # NOTE: base fixtures below set build_class:"software", which (post S033) auto-arms EXEC by default —
  # so recorded_command values must be REAL re-runnable commands, not fictional ones like "npm test", or
  # the genuine re-run will observe exit 127 and false-FAIL a fixture meant to prove shape-only semantics.
  # Seed real on-disk stub scripts (same idiom as zero-downtime-cutover-gate.sh's write_good_plan) so the
  # live re-run genuinely executes and observes the intended exit code.
  ui() { mkdir -p "$1/walteur-kit"; printf '{"build_class":"software"}\n' > "$1/walteur-kit/build-contract.json"; printf '{"has_ui":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  seed_pass() { printf 'process.exit(0)\n' > "$1/walteur-kit/probe.$2.mjs"; }
  seed_fail() { printf 'process.exit(1)\n' > "$1/walteur-kit/probe.$2.mjs"; }
  cov3ok() { seed_pass "$1" logic; seed_pass "$1" component; seed_pass "$1" e2e; jq -n '{layers:{logic:{recorded_command:"node walteur-kit/probe.logic.mjs",exit_code:0},component:{recorded_command:"node walteur-kit/probe.component.mjs",exit_code:0},e2e:{recorded_command:"node walteur-kit/probe.e2e.mjs",exit_code:0}}}' > "$1/walteur-kit/test-coverage.json"; }

  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "bare dir (no contract/signals) -> NOT_APPLICABLE" 0 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"build_class":"document"}\n' > "$t/walteur-kit/build-contract.json"; ck "document -> NOT_APPLICABLE" 0 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; ui "$t"; cov3ok "$t"; ck "UI + logic+component+e2e exit0 -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; ui "$t"; ck "UI + no test-coverage.json -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; ui "$t"; seed_pass "$t" logic; jq -n '{layers:{logic:{recorded_command:"node walteur-kit/probe.logic.mjs",exit_code:0},component:{recorded_command:"x",exit_code:0}}}' > "$t/walteur-kit/test-coverage.json"; ck "UI + e2e missing -> FAIL (e2e_not_executed)" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; ui "$t"; seed_pass "$t" logic; seed_fail "$t" e2e; jq -n '{layers:{logic:{recorded_command:"node walteur-kit/probe.logic.mjs",exit_code:0},component:{recorded_command:"x",exit_code:0},e2e:{recorded_command:"node walteur-kit/probe.e2e.mjs",exit_code:1}}}' > "$t/walteur-kit/test-coverage.json"; ck "UI + e2e exit_code 1 -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; ui "$t"; seed_pass "$t" logic; jq -n '{layers:{logic:{recorded_command:"node walteur-kit/probe.logic.mjs",exit_code:0},component:{recorded_command:"x",exit_code:0},e2e:{recorded_command:"",exit_code:0}}}' > "$t/walteur-kit/test-coverage.json"; ck "UI + e2e empty command -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"build_class":"software"}\n' > "$t/walteur-kit/build-contract.json"; printf '{"has_ui":false,"has_api_boundary":true}\n' > "$t/walteur-kit/preflight-signals.json"; seed_pass "$t" logic; seed_pass "$t" e2e; jq -n '{layers:{logic:{recorded_command:"node walteur-kit/probe.logic.mjs",exit_code:0},e2e:{recorded_command:"node walteur-kit/probe.e2e.mjs",exit_code:0}}}' > "$t/walteur-kit/test-coverage.json"; ck "API service + logic+e2e -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"build_class":"software"}\n' > "$t/walteur-kit/build-contract.json"; printf '{"has_ui":false,"has_api_boundary":false}\n' > "$t/walteur-kit/preflight-signals.json"; seed_pass "$t" logic; jq -n '{layers:{logic:{recorded_command:"node walteur-kit/probe.logic.mjs",exit_code:0}}}' > "$t/walteur-kit/test-coverage.json"; ck "CLI/library + logic only -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; ui "$t"; cov3ok "$t"; rm "$t/walteur-kit/test-coverage.json"; WALTEUR_ROOT="$t" WALTEUR_TEST_LAYERS=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; ui "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ── EXEC-default build-class-awareness (S033 enforcement) ──────────────────────────────────────
  # (a) code-class contract + no env override -> EXEC path ARMED (report shows genuine re-run markers)
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; ui "$t"; cov3ok "$t"
  WALTEUR_ROOT="$t" bash "$0" >/dev/null 2>&1
  ck "software build-contract + no env -> EXEC armed by default (exit)" 0 "$?"
  jq -e '.test_layers_executed == true and .layers_reran == 3' "$t/walteur-kit/test-layer-coverage-report.json" >/dev/null 2>&1
  ck "software build-contract + no env -> report shows genuine re-run (layers_reran=3)" 0 "$?"
  rm -rf "$t"

  # (b) explicit WALTEUR_TEST_LAYERS_EXEC=0 override respected even on a code-class contract
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; ui "$t"; cov3ok "$t"
  WALTEUR_TEST_LAYERS_EXEC=0 WALTEUR_ROOT="$t" bash "$0" >/dev/null 2>&1
  ck "software build-contract + explicit EXEC=0 -> override respected (exit)" 0 "$?"
  jq -e '(.test_layers_executed // false) == false' "$t/walteur-kit/test-layer-coverage-report.json" >/dev/null 2>&1
  ck "explicit EXEC=0 override -> report shows shape-read only (no genuine re-run)" 0 "$?"
  rm -rf "$t"

  # (c) no build-contract.json at all -> legacy default (EXEC stays 0, shape-read)
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"has_ui":true}\n' > "$t/walteur-kit/preflight-signals.json"; cov3ok "$t"
  WALTEUR_ROOT="$t" bash "$0" >/dev/null 2>&1
  ck "no build-contract.json -> legacy default (exit)" 0 "$?"
  jq -e '(.test_layers_executed // false) == false' "$t/walteur-kit/test-layer-coverage-report.json" >/dev/null 2>&1
  ck "no build-contract.json -> report shows shape-read only (legacy default)" 0 "$?"
  rm -rf "$t"

  # (d) document build_class contract -> legacy default (EXEC stays 0) even though contract exists
  t="$(mktemp -d "${TMPDIR:-/tmp}/testlayerc.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"build_class":"document"}\n' > "$t/walteur-kit/build-contract.json"
  ck "document build_class -> NOT_APPLICABLE (unaffected by EXEC-default change)" 0 "$(run "$t")"
  rm -rf "$t"

  echo "test-layer-coverage-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_TEST_LAYERS:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_TEST_LAYERS=off"; echo "test-layer-coverage-gate: bypassed." >&2; exit 0; }
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "test-layer-coverage-gate: SKIP - jq unavailable." >&2; exit 0; fi

if [ -z "$(required_layers)" ]; then
  write_report "NOT_APPLICABLE" "build type requires no automated test layers"
  echo "test-layer-coverage-gate: NOT_APPLICABLE"
  exit 0
fi

validate

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures test-layer coverage violation(s)"
  echo "test-layer-coverage-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null || true
  exit 2
fi
if [ "$EXEC" = "1" ] && [ "$layers_reran" -gt 0 ]; then
  write_report "PASS" "RE-RAN $layers_reran test layer(s); OBSERVED expected exit on $layers_reran_pass/$layers_reran"
  echo "test-layer-coverage-gate: PASS - RE-RAN $layers_reran layer(s), OBSERVED exit ok on $layers_reran_pass/$layers_reran" >&2
else
  write_report "PASS" "all required test layers present with recorded exit 0 (shape-read; set WALTEUR_TEST_LAYERS_EXEC=1 to execute layers live)"
  echo "test-layer-coverage-gate: PASS" >&2
fi
exit 0
