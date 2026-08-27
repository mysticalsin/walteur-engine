#!/usr/bin/env bash
# WALTEUR tool-liveness-probe — HARD gate (intake: Panniantong/Agent-Reach probe three-mode model). WALTEUR's
# 120 gates are bash+jq+perl+coreutils; if a required tool is a DEAD SHIM (present on PATH but cannot exec — a
# stale pipx/npm/uv/winget shim after a runtime upgrade, exit 126/127), `command -v` still says "yes" and the
# gates silently misbehave (this session lost jq once to exactly that). This probe goes beyond `command -v`:
# it EXECS each required tool and classifies missing | BROKEN(exists-but-exec-fails) | timeout | ok, and FAILs
# closed on any missing/broken tool with a precise reinstall hint.
#
# Required set: walteur-kit/required-tools.json .tools[] if present, else the WALTEUR gate toolchain. The
# CANONICAL manifest shape (owned by tool-readiness.sh) is {tools:[{tool,required,discipline,install}, ...]}
# — objects, not bare strings. This probe accepts BOTH: canonical objects (only required==true|absent blocks;
# required==false is probed advisory-only, mirroring tool-readiness.sh's own required-flag semantics) and a
# legacy/hermetic bare-string array (["jq","bash",...], all treated as required — kept for back-compat with
# existing fixtures). A prior version parsed `.tools[]` as if every entry were already a string; against the
# real object-schema manifest this exploded each object's keys/values into 294 junk "tool names" and FAILed
# closed — fixed here (regression case #2b below reproduces and locks the exact canonical-shape defect).
#
# MCP mode (optional): when walteur-kit/mcp-manifest.json is present, additionally probes each server's
# liveness_probe.command via the shared _probe-proof.sh guard (no-side-effect only — the guard requires the
# command to be a recognized test-runner shape or resolve to a real on-disk token; it never executes network
# calls or spawns processes itself, it only classifies the command string). Missing manifest or offline
# targets are a LOUD recorded SKIP per server, never silent-green and never a hard fail on their own —
# MCP servers are advisory unless a future consumer arms strict mode via WALTEUR_MCPPROBE=strict.
#
# Advisory extras (node/rg/gh) reported, never blocking. CONTRACT: any required tool missing/BROKEN/timeout
# => FAIL exit 2 · all ok => PASS · PAUSED => exit 2 · bypass WALTEUR_TOOLPROBE=off.
# Report: walteur-kit/tool-liveness-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
    printf '%s
' "tool-liveness-probe - probes required-tools.json (and optional mcp-manifest liveness probes) with side-effect-free version checks; missing/broken tools become loud findings"
    printf '%s
' "usage: bash tool-liveness-probe.sh [--selftest|--help|<default run>]"
    printf '%s
' "report: walteur-kit/tool-liveness-report.json - fix recipes: walteur-kit/REMEDIATION.md (## tool-liveness-probe)"
    exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -f "$SELF_DIR/_probe-proof.sh" ] && . "$SELF_DIR/_probe-proof.sh"

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
MANIFEST="$KIT/required-tools.json"
MCP_MANIFEST="$KIT/mcp-manifest.json"
REPORT="$KIT/tool-liveness-report.json"
PTO="${WALTEUR_TOOLPROBE_TIMEOUT:-8}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
to() { if command -v timeout >/dev/null 2>&1; then timeout "$PTO" "$@"; else "$@"; fi; }

DEFAULT_REQUIRED="jq bash grep sed awk find"   # perl is probed advisory (some gates degrade-clean without it)
ADVISORY="perl node rg gh git python3"

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }

# classify one tool -> ok|missing|broken|timeout (probe is side-effect-free: --version/--help)
probe() {
  local t="$1" rc
  command -v "$t" >/dev/null 2>&1 || { echo missing; return; }
  to "$t" --version >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then echo ok; return; fi
  case "$rc" in
    126|127) echo broken ;;
    124) echo timeout ;;
    *) # some tools exit non-zero on --version but run fine; confirm with --help, else treat as broken
       to "$t" --help >/dev/null 2>&1; rc=$?
       if [ "$rc" -eq 0 ] || { [ "$rc" -ne 126 ] && [ "$rc" -ne 127 ]; }; then echo ok; else echo broken; fi ;;
  esac
}

# Resolve the required-tools.json manifest into two space-separated lists: $REQ_OUT (required==true or
# absent — blocking) and $ADV_OUT (required==false — probed but advisory-only). Handles BOTH the canonical
# object shape {tools:[{tool,required,...}]} and a legacy bare-string array {tools:["jq","bash"]} (all bare
# strings are treated as required, matching the pre-fix behavior those fixtures were written against).
REQ_OUT=""; ADV_OUT=""
resolve_manifest_tools() {
  REQ_OUT=""; ADV_OUT=""
  [ -f "$MANIFEST" ] || return 0
  have jq || return 0
  # object shape: at least one element is a JSON object
  if jq -e '(.tools // []) | length > 0 and (.[0] | type == "object")' "$MANIFEST" >/dev/null 2>&1; then
    REQ_OUT="$(jq -r '(.tools // [])[] | select(.required != false) | (.tool // empty)' "$MANIFEST" 2>/dev/null | tr '\n' ' ')"
    ADV_OUT="$(jq -r '(.tools // [])[] | select(.required == false) | (.tool // empty)' "$MANIFEST" 2>/dev/null | tr '\n' ' ')"
  else
    # legacy/hermetic bare-string array — every entry required (back-compat)
    REQ_OUT="$(jq -r '(.tools // [])[]' "$MANIFEST" 2>/dev/null | tr '\n' ' ')"
  fi
}

# MCP probe mode: probe each mcp-manifest.json server's liveness_probe.command through _probe-proof.sh
# (no-side-effect classification only — never itself execs a network call). Advisory: recorded, never
# blocks the gate verdict (kept separate from the required-tools FAIL path by design — see header).
mcp_probe_results='[]'
probe_mcp_manifest() {
  [ -f "$MCP_MANIFEST" ] || { mcp_probe_results='[]'; return 0; }
  have jq || { mcp_probe_results='[]'; return 0; }
  if ! command -v probe_proves_something >/dev/null 2>&1 && ! declare -F probe_proves_something >/dev/null 2>&1; then
    mcp_probe_results="$(jq -n '[{status:"skip", reason:"_probe-proof.sh not sourced"}]' 2>/dev/null || echo '[]')"
    return 0
  fi
  local n i id method cmd status out='[]'
  n="$(jq '(.servers // []) | length' "$MCP_MANIFEST" 2>/dev/null || echo 0)"
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    id="$(jq -r ".servers[$i].id // \"?\"" "$MCP_MANIFEST" 2>/dev/null)"
    method="$(jq -r ".servers[$i].liveness_probe.method // \"n-a\"" "$MCP_MANIFEST" 2>/dev/null)"
    cmd="$(jq -r ".servers[$i].liveness_probe.command // \"n-a\"" "$MCP_MANIFEST" 2>/dev/null)"
    if [ "$method" = "n-a" ] || [ "$cmd" = "n-a" ]; then
      status="skip"
    elif probe_proves_something "$cmd"; then
      status="probe-eligible"
    else
      status="skip"
    fi
    out="$(printf '%s' "$out" | jq --arg id "$id" --arg m "$method" --arg s "$status" '. + [{id:$id, method:$m, status:$s}]' 2>/dev/null || printf '%s' "$out")"
    i=$((i+1))
  done
  mcp_probe_results="$out"
}

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; printf '{"verdict":"FAIL","reason":"paused"}\n' > "$REPORT"; echo "tool-liveness-probe: PAUSED -> exit 2"; exit 2; }
  [ "${WALTEUR_TOOLPROBE:-}" = "off" ] && { printf '{"verdict":"SKIP"}\n' > "$REPORT"; echo "tool-liveness-probe: bypassed"; exit 0; }

  local required advisory_manifest; required="$DEFAULT_REQUIRED"; advisory_manifest=""
  resolve_manifest_tools
  [ -n "$REQ_OUT" ] && required="$REQ_OUT"
  advisory_manifest="$ADV_OUT"

  local t st results='[]'
  for t in $required; do
    st="$(probe "$t")"
    have jq && results="$(printf '%s' "$results" | jq --arg t "$t" --arg s "$st" '. + [{tool:$t, status:$s, required:true}]')"
    case "$st" in
      ok) : ;;
      missing) add_finding "$t" "required tool '$t' is MISSING from PATH — install it (Windows: winget; *nix: package manager)." ;;
      broken) add_finding "$t" "required tool '$t' is a BROKEN shim — on PATH but exec fails (exit 126/127, e.g. a stale pipx/npm/winget shim after a runtime upgrade). Reinstall it." ;;
      timeout) add_finding "$t" "required tool '$t' TIMED OUT on a --version probe — likely hung/blocked." ;;
    esac
  done
  for t in $ADVISORY $advisory_manifest; do
    st="$(probe "$t")"
    have jq && results="$(printf '%s' "$results" | jq --arg t "$t" --arg s "$st" '. + [{tool:$t, status:$s, required:false}]')"
  done

  probe_mcp_manifest

  if have jq; then jq -n --arg ts "$TS" --argjson f "$findings" --argjson r "$results" --argjson mcp "$mcp_probe_results" '{verdict:(if ($f|length)>0 then "FAIL" else "PASS" end), ts:$ts, gate:"tool-liveness", findings:$f, tools:$r, mcp_probes:$mcp}' > "$REPORT" 2>/dev/null; fi
  if [ "$failures" -gt 0 ]; then
    echo "tool-liveness-probe: FAIL ($failures required tool issue(s)) -> exit 2"
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null | head -10 || true
    exit 2
  fi
  echo "tool-liveness-probe: PASS (all required tools live: $required)"
  exit 0
}

selftest() {
  pass=0; fail=0
  echo "tool-liveness-probe selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }

  # 1. real env: the default toolchain is live -> PASS (jq/bash/grep/sed/awk/find all present on this host)
  t="$(mktemp -d "${TMPDIR:-/tmp}/toollive.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "default toolchain live -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 2. manifest requires a MISSING tool -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/toollive.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"tools":["jq","definitely-not-a-real-tool-zzz"]}\n' > "$t/walteur-kit/required-tools.json"; ck "missing required tool -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 3. a BROKEN shim (on PATH, exits 127) -> FAIL  (simulate: a fake tool dir prepended to PATH)
  t="$(mktemp -d "${TMPDIR:-/tmp}/toollive.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/bin"; printf '#!/usr/bin/env bash\nexit 127\n' > "$t/bin/brokentool"; chmod +x "$t/bin/brokentool"
  printf '{"tools":["jq","brokentool"]}\n' > "$t/walteur-kit/required-tools.json"
  WALTEUR_ROOT="$t" PATH="$t/bin:$PATH" bash "$SELF" >/dev/null 2>&1; ck "broken shim (exit 127) -> FAIL" 2 "$?"; rm -rf "$t"
  # 4. FP guard: manifest requires only present tools -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/toollive.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"tools":["jq","bash","grep"]}\n' > "$t/walteur-kit/required-tools.json"; ck "all-present manifest -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 5. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/toollive.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"tools":["nope-zzz"]}\n' > "$t/walteur-kit/required-tools.json"; WALTEUR_ROOT="$t" WALTEUR_TOOLPROBE=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/toollive.XXXXXX")"; mkdir -p "$t/walteur-kit"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # 6. REGRESSION (the confirmed live defect): CANONICAL object-schema manifest, exactly the shape
  #    tool-readiness.sh owns ({tools:[{tool,required,discipline,install}]}), with only present/live tools
  #    named -> must PASS. Before the fix this exploded each object's keys/values into junk "tool names"
  #    (e.g. '"tool":', '{', 'false,') and FAILed with 294 bogus findings. This is the exact repro shape.
  t="$(mktemp -d "${TMPDIR:-/tmp}/toollive.XXXXXX")"; mkdir -p "$t/walteur-kit"
  printf '%s\n' '{"$comment":"canonical shape","tools":[{"tool":"jq","required":true,"discipline":"core","install":"brew install jq"},{"tool":"bash","required":true,"discipline":"core","install":"n/a"},{"tool":"ast-grep","required":false,"discipline":"resilience","install":"npm i -g @ast-grep/cli"}]}' > "$t/walteur-kit/required-tools.json"
  ck "canonical OBJECT-schema manifest (real required-tools.json shape) -> PASS, not the 294-junk-finding FAIL" 0 "$(run "$t")"
  jq -e '(.findings | length) == 0 and (.tools | map(.tool) | index("\"tool\":") | not) and (.tools | map(.tool) | index("{") | not)' "$t/walteur-kit/tool-liveness-report.json" >/dev/null 2>&1
  ck "canonical-shape report has zero junk findings/tool-names ({ or \"tool\":)" 0 "$?"
  rm -rf "$t"

  # 7. canonical object-schema manifest with a MISSING required:true tool -> FAIL (required flag still binds)
  t="$(mktemp -d "${TMPDIR:-/tmp}/toollive.XXXXXX")"; mkdir -p "$t/walteur-kit"
  printf '%s\n' '{"tools":[{"tool":"jq","required":true},{"tool":"definitely-not-a-real-tool-zzz","required":true,"discipline":"x","install":"n/a"}]}' > "$t/walteur-kit/required-tools.json"
  ck "canonical object-schema + missing required:true tool -> FAIL" 2 "$(run "$t")"
  rm -rf "$t"

  # 8. canonical object-schema manifest: a MISSING tool marked required:false must NOT block (advisory-only,
  #    mirrors tool-readiness.sh's own required-flag semantics)
  t="$(mktemp -d "${TMPDIR:-/tmp}/toollive.XXXXXX")"; mkdir -p "$t/walteur-kit"
  printf '%s\n' '{"tools":[{"tool":"jq","required":true},{"tool":"walteur_absent_optional_tool_xyz","required":false,"discipline":"x","install":"n/a"}]}' > "$t/walteur-kit/required-tools.json"
  ck "canonical object-schema + missing required:false tool -> PASS (advisory, not blocking)" 0 "$(run "$t")"
  jq -e '.tools[] | select(.tool=="walteur_absent_optional_tool_xyz") | .required == false and .status == "missing"' "$t/walteur-kit/tool-liveness-report.json" >/dev/null 2>&1
  ck "advisory-missing tool recorded (status=missing, required=false) without failing the gate" 0 "$?"
  rm -rf "$t"

  # 9. MCP probe mode: mcp-manifest.json present -> report carries mcp_probes[] entries, advisory-only
  #    (does not block the verdict even though it references servers no one has installed locally)
  t="$(mktemp -d "${TMPDIR:-/tmp}/toollive.XXXXXX")"; mkdir -p "$t/walteur-kit"
  jq -n '{schema_version:1, manifest_id:"selftest-mcp", updated_at:"2026-07-01", policy:"selftest fixture manifest for tool-liveness-probe MCP mode coverage.", servers:[{id:"firecrawl", kind:"mcp", server:{transport:"stdio", command:"npx", args:["-y","firecrawl-mcp"], env_keys:["FIRECRAWL_API_KEY"]}, tools:["scrape"], allowed_build_classes:["research-report"], data_domains:["web-page"], liveness_probe:{method:"exec-version", command:"npx -y firecrawl-mcp --version", timeout_s:15, side_effect_free:true}, governance:{license_risk:"low", usage_risk:"medium", notes:"selftest fixture entry mirroring the real manifest row."}}]}' > "$t/walteur-kit/mcp-manifest.json"
  ck "mcp-manifest present -> gate still PASS (advisory probe, non-blocking)" 0 "$(run "$t")"
  jq -e '(.mcp_probes | type) == "array" and (.mcp_probes | length) >= 1' "$t/walteur-kit/tool-liveness-report.json" >/dev/null 2>&1
  ck "report carries mcp_probes[] for the declared server" 0 "$?"
  rm -rf "$t"

  # 10. NEGATIVE CONTROL: no mcp-manifest.json -> mcp_probes[] is empty, never fabricated/silent-green
  t="$(mktemp -d "${TMPDIR:-/tmp}/toollive.XXXXXX")"; mkdir -p "$t/walteur-kit"
  run "$t" >/dev/null 2>&1
  jq -e '(.mcp_probes | type) == "array" and (.mcp_probes | length) == 0' "$t/walteur-kit/tool-liveness-report.json" >/dev/null 2>&1
  ck "no mcp-manifest.json -> mcp_probes[] empty (no fabricated probe results)" 0 "$?"
  rm -rf "$t"

  echo "tool-liveness-probe selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
