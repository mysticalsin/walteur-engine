#!/usr/bin/env bash
# WALTEUR lifecycle-access-gate — HARD gate (enterprise backlog rank 4). The highest-severity real
# enterprise incident is a terminated employee retaining access. WALTEUR proves a role matrix exists but
# never that disabling a user actually REVOKES live sessions/tokens. This gate requires
# walteur-kit/access-lifecycle.json AND runs a real deprovisioning probe (disable a user via SCIM, then
# assert their existing session/token returns 401). Deprovisioning cannot be signed-deferred at high/regulated.
#
# Applies when an SSO/SCIM/enterprise-tenant surface is present (signals has_sso/has_scim, code, or manifest).
# CONTRACT: leak / missing proof => FAIL exit 2 · no enterprise-auth surface => NOT_APPLICABLE · jq absent =>
# SKIP · PAUSED => exit 2 · bypass WALTEUR_LIFECYCLE=off · skip the live probe with WALTEUR_LIFECYCLE_PROBE=off.
# Report: walteur-kit/access-lifecycle-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "lifecycle-access-gate - HARD gate (enterprise backlog rank 4). The highest-severity real"
  printf '%s\n' "usage: bash lifecycle-access-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/access-lifecycle-report.json - fix recipes: walteur-kit/REMEDIATION.md (## lifecycle-access-gate)"
  printf '%s\n' "bypass: WALTEUR_LIFECYCLE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# Self-root: resolve this gate's own path so we can source the shared probe guard.
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
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
MANIFEST="${WALTEUR_LIFECYCLE_FILE:-$KIT/access-lifecycle.json}"
REPORT="$KIT/access-lifecycle-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
X="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit --exclude-dir=dist --exclude-dir=build"

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"access-lifecycle", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"access-lifecycle","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

ent_surface() {
  [ -f "$MANIFEST" ] && return 0
  if [ -f "$SIGNALS" ] && have jq; then jq -e '(.has_sso==true) or (.has_scim==true)' "$SIGNALS" >/dev/null 2>&1 && return 0; fi
  # M2 fix: the enterprise-auth surface can live in ANY source extension. The previous scan only
  # covered .ts/.js/.py/.go, so a real SCIM/SSO surface hidden in .tsx/.jsx/.mjs/.go/.rb/.java/.cs/...
  # NA-skipped the gate and shipped a high-risk build with unproven leaver deprovisioning. Widen the
  # globs across the common web/back-end ecosystems + migrations, recurse (-r), and keep the same
  # exclude-dirs. grep -r already recurses; the load-bearing change is the include set.
  command -v grep >/dev/null 2>&1 && grep -rIiE \
    --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.mjs' --include='*.cjs' \
    --include='*.py' --include='*.go' --include='*.rb' --include='*.java' --include='*.kt' --include='*.kts' \
    --include='*.cs' --include='*.php' --include='*.rs' --include='*.scala' --include='*.ex' --include='*.exs' \
    --include='*.sql' --include='*.json' --include='*.yaml' --include='*.yml' --include='*.tf' \
    $X 'scim|passport-saml|openid-client|saml2|@okta|okta-sdk|workos|@boxyhq|jackson|enterprise-sso|directory.deleted|user.deleted|directory[-_ ]?sync|saml[-_ ]?assertion|idp[-_ ]?entry' "$ROOT" >/dev/null 2>&1
}
risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }

# strip_probe_comments — remove shell '# comment' runs from the probe so a keyword laundered inside a
# comment (which bash discards at execution) cannot satisfy the revocation-keyword check. bash treats '#'
# as a comment ONLY when it begins a word (preceded by start-of-line/whitespace/a control operator). We
# strip on that rule with perl (-0777 multiline; grep -P is locale-broken on Windows). This deliberately
# also strips a '#' one shell-level deep (inside a `bash -c '… # …'` wrapper) because the comment there is
# likewise discarded at run time — that is exactly the comment-laundering evasion (M1).
strip_probe_comments() { perl -0777 -pe 's/(^|[\s;&|(])#[^\n]*/$1/mg'; }
# REAL_TOOL_RE — tokens that constitute a genuine network/db/test/runtime verification (a real attack).
# A probe whose EXECUTED (comment-stripped) text contains none of these is inert (echo/printf/:/true/test +
# a shell builtin only) and proves nothing, no matter what keyword it prints.
REAL_TOOL_RE='(^|[^A-Za-z0-9_.-])(curl|wget|http|httpie|xh|nc|ncat|socat|openssl|node|deno|bun|ts-node|tsx|python|python3|ruby|php|perl|psql|mysql|mariadb|redis-cli|mongosh|mongo|sqlite3|go|cargo|java|dotnet|pytest|jest|vitest|mocha|playwright|cypress|newman|grpcurl|aws|az|gcloud|kubectl|okta|saml2aws)([^A-Za-z0-9_.-]|$)'

# run_probe — "" ONLY when a REAL revocation probe RAN and observed a 401/deny; else a finding-reason.
# Hardened (D4 shared fix): a trivial no-op, an off-allowlist/missing command, a whitespace probe, or a probe
# that asserts no revocation (401/403/revoked/deny) no longer counts as proof — those were silent passes.
# M1/M3 fix: (1) strip shell comments BEFORE the keyword scan so a laundered '# … 401 revoked' no longer
# satisfies it; (2) require a REAL verification tool in the EXECUTED (non-comment) portion, so an inert
# `bash -c 'echo asserting-401; true'` (keyword present, but echo+true performs no attack) FAILS closed.
#
# Unify probe hardening: the constant-exit/no-op CLASS (true/false/:/empty/`bash -lc "exit 0"`/`node -e` etc.
# that exit green while proving nothing) is now judged by the SHARED kernel _probe-proof.sh
# (probe_proves_something) instead of a bespoke per-gate case-statement — one hardened kernel, not six
# diverging copies. A probe passes this stage if EITHER the shared kernel recognizes it as a real test-runner/
# on-disk-artifact invocation, OR the domain-specific REAL_TOOL_RE regex finds a genuine network/db/test tool
# in the executed text (curl/node/python one-liners asserting an HTTP status are this gate's normal shape and
# the shared kernel alone does not recognize them). FAIL CLOSED if the shared guard file was absent at source
# time (function undefined): never silently skip the no-op check.
run_probe() { # $1=command
  local probe="$1" pfirst exec_text low
  printf '%s' "$probe" | grep -q '[^[:space:]]' || { printf 'empty/whitespace probe — runs no revocation test; not verification'; return; }
  printf '%s' "$probe" | grep -Eqi 'rm[[:space:]]+-rf|mkfs|[[:space:]]dd[[:space:]]|/dev/tcp|/etc/(passwd|shadow)|\|[[:space:]]*(bash|sh)([[:space:]]|$)' && { printf 'destructive token; refused'; return; }
  if ! command -v probe_proves_something >/dev/null 2>&1; then
    printf 'shared probe guard (_probe-proof.sh) unavailable — cannot prove the probe is non-trivial; failing closed'; return
  fi
  pfirst="$(printf '%s' "$probe" | awk '{print $1}')"
  # EXECUTED text = probe with shell comments removed. All semantic checks run on THIS, not the raw string.
  exec_text="$(printf '%s' "$probe" | strip_probe_comments)"
  if ! probe_proves_something "$exec_text" && ! printf '%s' "$exec_text" | grep -Eq "$REAL_TOOL_RE"; then
    printf "probe ('%s') is a constant-exit/no-op or performs no real network/db verification (only echo/printf/true after comment-strip) — not an attack" "$pfirst"; return
  fi
  low="$(printf '%s' "$exec_text" | tr 'A-Z' 'a-z')"
  printf '%s' "$low" | grep -Eq '401|403|revoked|deny|denied|reject|forbidden|unauthor|disabled|invalid' || { printf 'probe asserts no revocation (401/403/revoked/deny) — cannot confirm a disabled user loses access' ; return; }
  (cd "$ROOT" && eval "$probe" >/dev/null 2>&1) || printf 'LEAK: a disabled user still had access (revocation did not return 401)'
}

selftest() {
  pass=0; fail=0
  # $0 absolute BEFORE any cd, so `bash "$SELF"` resolves regardless of cwd (Windows/git-bash safe).
  SELF="$0"; case "$SELF" in /*|?:[\/]*) : ;; *) SELF="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")" ;; esac
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "lifecycle-access selftest SKIP - jq not installed."; return 0; fi
  echo "lifecycle-access-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  ent() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${2:-medium}" > "$1/walteur-kit/build-contract.json"; printf '{"has_scim":true,"has_auth":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  man() { jq -n --arg p "$1" '{scim_provisioning:{status:"verified",evidence:"e2e create flow"},deprovisioning:{status:"verified",max_revocation_latency_seconds:60,probe_command:$p}}' > "$2/walteur-kit/access-lifecycle.json"; }
  # Real probes MUST invoke a real verification tool (post-fix: inert echo/grep no longer counts as proof).
  # Pick a present runtime and build a DETERMINISTIC, network-free PASS/LEAK pair: a true 401 revocation
  # exits 0 (access denied), a still-200 session exits non-0 (LEAK). If no real tool is present we cannot
  # exercise the execution path honestly, so we skip those two cases rather than fake them.
  PASS_PROBE=""; LEAK_PROBE=""
  if have node; then
    PASS_PROBE="node -e 'process.exit(/401/.test(\"status 401 revoked\")?0:1)'"
    LEAK_PROBE="node -e 'process.exit(/401/.test(\"status 200 active\")?0:1)'"
  elif have python3; then
    PASS_PROBE="python3 -c 'import sys;sys.exit(0 if \"401\" in \"status 401 revoked\" else 1)'"
    LEAK_PROBE="python3 -c 'import sys;sys.exit(0 if \"401\" in \"status 200 active\" else 1)'"
  elif have python; then
    PASS_PROBE="python -c 'import sys;sys.exit(0 if \"401\" in \"status 401 revoked\" else 1)'"
    LEAK_PROBE="python -c 'import sys;sys.exit(0 if \"401\" in \"status 200 active\" else 1)'"
  fi

  # 1. no enterprise-auth surface -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"has_auth":true}\n' > "$t/walteur-kit/preflight-signals.json"; printf 'export const x=1;\n' > "$t/a.ts"; ck "no SSO/SCIM surface -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. surface + deprovisioning verified + passing probe -> PASS
  if [ -n "$PASS_PROBE" ]; then t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "$PASS_PROBE" "$t"; ck "deprovision probe holds -> PASS" 0 "$(run "$t")"; rm -rf "$t"; else echo "  skip - deprovision probe holds (no node/python runtime)"; fi
  # 3. manifest absent -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; ck "surface, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. deprovisioning probe LEAKS (disabled user still active) -> FAIL
  if [ -n "$LEAK_PROBE" ]; then t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "$LEAK_PROBE" "$t"; ck "deprovision leak -> FAIL" 2 "$(run "$t")"; rm -rf "$t"; else echo "  skip - deprovision leak (no node/python runtime)"; fi
  # 5. deprovisioning signed-deferred at risk=high -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t" high; jq -n '{scim_provisioning:{status:"verified",evidence:"x"},deprovisioning:{status:"signed-deferred",deferral:{owner:"Tony",ticket:"W-1",reason:"next sprint",review_trigger:"beta"}}}' > "$t/walteur-kit/access-lifecycle.json"; ck "deprovision deferred at high risk -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. deprovisioning signed-deferred at risk=low -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t" low; jq -n '{scim_provisioning:{status:"verified",evidence:"x"},deprovisioning:{status:"signed-deferred",deferral:{owner:"Tony",ticket:"W-1",reason:"next sprint",review_trigger:"beta"}}}' > "$t/walteur-kit/access-lifecycle.json"; ck "deprovision deferred at low risk -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 7. missing max_revocation_latency on a verified deprovision -> FAIL (probe text irrelevant; use a real-tool probe)
  RP="${PASS_PROBE:-node -e 'process.exit(/401/.test(\"401 revoked\")?0:1)'}"
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "$RP" "$t"; jq 'del(.deprovisioning.max_revocation_latency_seconds)' "$t/walteur-kit/access-lifecycle.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/access-lifecycle.json"; ck "verified deprovision, no latency -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. deprovisioning missing entirely -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; jq -n '{scim_provisioning:{status:"verified",evidence:"x"}}' > "$t/walteur-kit/access-lifecycle.json"; ck "no deprovisioning entry -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "$RP" "$t"; WALTEUR_ROOT="$t" WALTEUR_LIFECYCLE=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # ── D4 shared probe-bypass regressions ──
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "true" "$t"; ck "G1 trivial true probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "./revoke-test.sh" "$t"; ck "G2 off-allowlist probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man " " "$t"; ck "G3 whitespace probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "bash -c 'echo ok | grep -q ok'" "$t"; ck "G4 no-revocation-assert probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # ── gauntlet PROVEN false-negative regressions (this hardening pass) ──
  # G5 (M1) — comment-laundering: keyword '401 revoked' hidden in a shell '#' comment bash discards; the
  #           executed command is a bare echo. Must FAIL (no-op probe), not trust the laundered keyword.
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "bash -c 'echo provisioning-ok # assert disabled user session returns 401 revoked'" "$t"; ck "G5 comment-laundered keyword probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G6 (M3) — tautology probe: prints the literal '401' then runs ; true, so it always exits 0 while
  #           verifying nothing (no real network/db tool). Must FAIL as a no-op, not pass on exit-0.
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "bash -c 'echo asserting-401-revocation; true'" "$t"; ck "G6 tautology echo-401 probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G7 (M2) — enterprise SCIM/SSO surface hidden in an unscanned extension (.tsx) with NO manifest: the
  #           gate must STILL detect the surface and FAIL for missing deprovisioning proof, not NA-skip.
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src/app/api/scim"
  printf '{"risk_tier":"high"}\n' > "$t/walteur-kit/build-contract.json"
  printf '{"has_auth":true,"has_sso":false,"has_scim":false}\n' > "$t/walteur-kit/preflight-signals.json"
  printf 'import { WorkOS } from "@workos-inc/node";\nexport async function POST(){ return new Response("ok"); }\n' > "$t/src/app/api/scim/route.tsx"
  printf 'export const ssoConfig = { provider: "okta", scim: true };\n' > "$t/src/sso.mjs"
  ck "G7 SCIM surface in .tsx, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G8 false-positive guard — a CLEAN, valid manifest with a REAL deterministic real-tool probe that
  #     observes a 401 must STILL PASS (the hardening must not break legitimate verified deprovisioning).
  if [ -n "$PASS_PROBE" ]; then
    t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "$PASS_PROBE" "$t"; ck "G8 clean real-tool 401 probe -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  else echo "  skip - G8 clean real-tool probe (no node/python runtime)"; fi

  # ── Unify probe hardening: shared _probe-proof.sh kernel poison classes (constant-exit/no-op) ──
  # G9 — "false" no-op probe -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "false" "$t"; ck "G9 false no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G10 — ":" no-op probe -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man ":" "$t"; ck "G10 ':' no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G11 — "bash -lc 'exit 0'" constant-exit no-op (the class the shared kernel names by name) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "bash -lc 'exit 0'" "$t"; ck "G11 bash -lc exit-0 no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G12 — shared guard fail-closed: if _probe-proof.sh is unavailable at source time, a probe must FAIL
  # closed rather than silently skip the no-op check. Simulate by pointing the gate at a copy of itself
  # with the sibling guard file temporarily hidden.
  if [ -n "$PASS_PROBE" ]; then
    t="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; ent "$t"; man "$PASS_PROBE" "$t"
    gdir="$(mktemp -d "${TMPDIR:-/tmp}/lifecyclea.XXXXXX")"; cp "$SELF" "$gdir/lifecycle-access-gate.sh"
    ck "G12 guard file absent -> FAIL (fail-closed)" 2 "$(WALTEUR_ROOT="$t" bash "$gdir/lifecycle-access-gate.sh" >/dev/null 2>&1; echo $?)"
    rm -rf "$t" "$gdir"
  else echo "  skip - G12 guard file absent (no node/python runtime)"; fi

  echo "lifecycle-access-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_LIFECYCLE:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_LIFECYCLE=off"; echo "lifecycle-access-gate: bypassed." >&2; exit 0; }

if ! ent_surface; then write_report "NOT_APPLICABLE" "no SSO/SCIM/enterprise-auth surface"; echo "lifecycle-access-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "lifecycle-access-gate: SKIP." >&2; exit 0; fi

if [ ! -s "$MANIFEST" ]; then
  add_finding "manifest" "enterprise auth (SSO/SCIM) surface but walteur-kit/access-lifecycle.json absent — joiner/mover/LEAVER deprovisioning must be proven"
  write_report "FAIL" "access-lifecycle manifest absent"; echo "lifecycle-access-gate: FAIL - manifest absent" >&2; exit 2
fi
# Manifest must be exactly ONE well-formed JSON object. Reject malformed JSON and multi-document streams
# ({…}{…}) — a multi-doc file is ambiguous (jq -r reads only the first), letting a hostile second document
# launder the real values. jq -s 'length==1 and (.[0]|type=="object")' fails closed on both.
if ! jq -s -e 'length==1 and (.[0]|type=="object")' "$MANIFEST" >/dev/null 2>&1; then
  add_finding "manifest" "access-lifecycle.json is not a single well-formed JSON object (malformed or multi-document) — cannot trust deprovisioning proof"
  write_report "FAIL" "access-lifecycle manifest malformed/multi-document"; echo "lifecycle-access-gate: FAIL - manifest malformed" >&2; exit 2
fi
RISK="$(risk)"
# provisioning
ps="$(jq -r '.scim_provisioning.status // ""' "$MANIFEST")"
case "$ps" in verified|signed-deferred|not-applicable) : ;; *) add_finding "provisioning" "scim_provisioning.status must be verified|signed-deferred|not-applicable (got '${ps:-empty}')";; esac
# deprovisioning — the load-bearing control
ds="$(jq -r '.deprovisioning.status // ""' "$MANIFEST")"
if [ -z "$ds" ]; then
  add_finding "deprovisioning" "no deprovisioning entry — a disabled/terminated user's access revocation is unproven"
else
  case "$ds" in
    verified)
      # Latency must be a POSITIVE number. Coerce+validate with jq (accept a JSON number OR a numeric
      # string like "60", reject null/0/negative/non-numeric/array). `^[0-9]+$` alone admitted 0 and "00";
      # jq tonumber>0 is the type-safe, value-safe check.
      jq -e '(.deprovisioning.max_revocation_latency_seconds) as $l | ($l != null) and (($l|tostring|test("^[0-9]+(\\.[0-9]+)?$"))) and (($l|tonumber) > 0)' "$MANIFEST" >/dev/null 2>&1 \
        || add_finding "deprovisioning" "verified deprovisioning must declare a measured positive max_revocation_latency_seconds (number, >0)"
      probe="$(jq -r '.deprovisioning.probe_command // ""' "$MANIFEST")"
      if [ -z "$probe" ]; then add_finding "deprovisioning" "verified deprovisioning must cite a probe_command (disable a user, assert their session/token returns 401)"
      elif [ "${WALTEUR_LIFECYCLE_PROBE:-on}" != "off" ]; then
        res="$(run_probe "$probe")"; [ -n "$res" ] && add_finding "deprovisioning" "$res (ran: $probe)"
      fi
      ;;
    signed-deferred)
      case "$RISK" in high|regulated) add_finding "deprovisioning" "deprovisioning cannot be signed-deferred at risk_tier=$RISK — a terminated employee retaining access is unacceptable";; esac
      jq -e '.deprovisioning.deferral.owner and .deprovisioning.deferral.ticket and .deprovisioning.deferral.review_trigger' "$MANIFEST" >/dev/null 2>&1 || add_finding "deprovisioning" "signed-deferred deprovisioning needs deferral owner+ticket+review_trigger"
      ;;
    *) add_finding "deprovisioning" "deprovisioning.status must be verified|signed-deferred (got '$ds')";;
  esac
fi

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures access-lifecycle violation(s)"
  echo "lifecycle-access-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "deprovisioning revokes access (probed) within a measured latency; provisioning accounted for"
echo "lifecycle-access-gate: PASS" >&2
exit 0
