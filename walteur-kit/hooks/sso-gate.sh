#!/usr/bin/env bash
# WALTEUR sso-gate — HARD gate (enterprise backlog rank 8). SSO is unmodeled today: authz-tenant accepts
# ANY string for authn_provider; nothing verifies SAML assertion signature, audience/Recipient restriction,
# NotBefore/NotOnOrAfter window, replay/nonce, OIDC state+PKCE. A Golden-SAML / signature-stripping /
# audience-confusion bug is a cross-tenant account takeover with unlimited blast radius, and enterprise
# procurement gates entirely on working, hardened SSO. This gate requires walteur-kit/sso.json with each
# load-bearing control verified by a probe that RUNS a malicious assertion and asserts it is rejected (403).
#
# Applies when an SSO surface is present (signal has_sso, SAML/OIDC code, or sso.json).
# CONTRACT: missing/weak/forgeable control => FAIL exit 2 · no SSO => NOT_APPLICABLE · jq absent => SKIP ·
# PAUSED => exit 2 · bypass WALTEUR_SSO=off · skip live probes with WALTEUR_SSO_PROBE=off.
# Report: walteur-kit/sso-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "sso-gate - HARD gate (enterprise backlog rank 8). SSO is unmodeled today: authz-tenant accepts"
  printf '%s\n' "usage: bash sso-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/sso-report.json - fix recipes: walteur-kit/REMEDIATION.md (## sso-gate)"
  printf '%s\n' "bypass: WALTEUR_SSO=off (recorded, not free)"
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
MANIFEST="${WALTEUR_SSO_FILE:-$KIT/sso.json}"
REPORT="$KIT/sso-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
X="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit --exclude-dir=dist --exclude-dir=build"
# the load-bearing controls a $50-100M SaaS SSO must enforce
REQUIRED_CONTROLS="assertion_signature_validation audience_restriction time_window_enforcement replay_protection"

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"sso", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"sso","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

sso_surface() {
  [ -f "$MANIFEST" ] && return 0
  if [ -f "$SIGNALS" ] && have jq; then jq -e '.has_sso==true' "$SIGNALS" >/dev/null 2>&1 && return 0; fi
  command -v grep >/dev/null 2>&1 && grep -rIiE --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.py' --include='*.go' --include='*.java' --include='*.cs' --include='*.rb' --include='*.php' --include='*.scala' --include='*.kt' --include='*.ex' --include='*.cshtml' $X 'saml|passport-saml|openid-client|saml2|@boxyhq|workos|jackson|samlify|oidc.*client|acs.*url|assertionconsumer|sustainsys|spring-security-saml|omniauth-saml|python3?-saml' "$ROOT" >/dev/null 2>&1
}
risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }

# strip_comments — emit a probe's EXECUTED text: drop every shell '#' comment that bash itself would discard
# (a '#' at start-of-string or preceded by whitespace and NOT inside a single/double-quoted string). Quote-aware
# so a '#' inside a URL fragment or a quoted literal is preserved. This defeats comment-laundering: an attacker
# who buries the rejection keyword (403/deny) in a trailing '# ...' comment while the REAL command is a no-op.
strip_comments() {
  printf '%s' "$1" | awk '
  { out=""; n=length($0); inS=0; inD=0
    for (i=1;i<=n;i++){ c=substr($0,i,1)
      if (inS){ out=out c; if(c=="\x27") inS=0; continue }
      if (inD){ out=out c; if(c=="\"") inD=0; continue }
      if (c=="\x27"){ inS=1; out=out c; continue }
      if (c=="\""){ inD=1; out=out c; continue }
      if (c=="#"){ if (i==1) break; p=substr($0,i-1,1); if (p==" "||p=="\t") break; out=out c; continue }
      out=out c }
    print out }'
}

# A real network/db/test tool whose PRESENCE (in the executed, comment-stripped probe text) is required: a probe
# that only echo/printf/:/true/test/grep-tautologies sends no malicious assertion and verifies nothing.
REAL_PROBE_TOOL='curl|wget|http|httpie|node|deno|bun|python3?|npx|psql|mysql|mariadb|redis-cli|mongosh?|pytest|jest|vitest|playwright|grpcurl|nc|ncat|openssl[[:space:]]+s_client'

# run_probe — returns "" ONLY when a real malicious-assertion probe RAN and observed a rejection; otherwise a
# finding-reason. Hardened after the D4 gauntlet proved 7 probe-bypasses (trivial no-op, off-allowlist script,
# whitespace, no-rejection health-check) AND after a later gauntlet proved 3 more: (1) comment-laundering — the
# rejection keyword lives in a trailing '# ...' comment bash discards while the real command is `echo 200|grep 200`
# (forged assertion ACCEPTED); (3) a vacuous probe that contains a real tool but discards its output and forces
# exit 0 with a trailing `; true`. FAIL-CLOSED: scan only the EXECUTED text (comments stripped), require a real
# verification tool in it, reject trailing unconditional-success tokens, require the keyword in executed code.
#
# Unify probe hardening: the constant-exit/no-op CLASS (true/false/:/empty/`bash -lc "exit 0"`/`node -e` etc.
# that exit green while proving nothing) is now judged by the SHARED kernel _probe-proof.sh
# (probe_proves_something) instead of a bespoke per-gate case-statement — one hardened kernel, not six
# diverging copies. A probe passes this stage if EITHER the shared kernel recognizes it as a real test-runner/
# on-disk-artifact invocation, OR the domain-specific REAL_PROBE_TOOL regex finds a genuine network/db/test tool
# in the executed text (curl/node/python one-liners that assert an HTTP status are this gate's normal shape and
# the shared kernel alone does not recognize them — see _probe-proof.sh's own docstring). FAIL CLOSED if the
# shared guard file was absent at source time (function undefined): never silently skip the no-op check.
run_probe() { # $1=command
  local probe="$1" pfirst low eff
  printf '%s' "$probe" | grep -q '[^[:space:]]' || { printf 'empty/whitespace probe — sends no assertion; not verification'; return; }
  # EXECUTED text only — a laundering comment is not part of the verification.
  eff="$(strip_comments "$probe")"
  printf '%s' "$eff" | grep -q '[^[:space:]]' || { printf 'probe is only a shell comment (comment-laundering) — sends no assertion; not verification'; return; }
  printf '%s' "$probe" | grep -Eqi 'rm[[:space:]]+-rf|mkfs|[[:space:]]dd[[:space:]]|/dev/tcp|/etc/(passwd|shadow)|\|[[:space:]]*(bash|sh)([[:space:]]|$)' && { printf 'destructive token; refused'; return; }
  if ! command -v probe_proves_something >/dev/null 2>&1; then
    printf 'shared probe guard (_probe-proof.sh) unavailable — cannot prove the probe is non-trivial; failing closed'; return
  fi
  pfirst="$(printf '%s' "$eff" | awk '{print $1}')"
  if ! probe_proves_something "$eff" && ! printf '%s' "$eff" | grep -Eqi "(^|[^[:alnum:]_])(${REAL_PROBE_TOOL})([^[:alnum:]_]|\$)"; then
    printf "probe ('%s') is a constant-exit/no-op or contains no real network/db/test tool (curl/python/node/psql/...) — sends no malicious assertion, verifies nothing" "$pfirst"; return
  fi
  # A trailing unconditional-success token (`; true`, `|| true`, `&& :`, `; :`) hardcodes exit 0 and decouples it
  # from whether the forged assertion was rejected — the probe's verdict is then attacker-controlled, not observed.
  printf '%s' "$eff" | grep -Eq '(;|\|\||&&|&)[[:space:]]*(true|:)[[:space:]]*$' && { printf 'probe ends in an unconditional-success token (; true / || true / ; :) — exit status is forced to 0, decoupled from the SSO outcome; not verification'; return; }
  low="$(printf '%s' "$eff" | tr 'A-Z' 'a-z')"
  printf '%s' "$low" | grep -Eq '401|403|deny|denied|reject|unauthor|forbidden|blocked|invalid' || { printf 'probe asserts no rejection (401/403/deny) of the forged assertion — cannot confirm the control is enforced'; return; }
  (cd "$ROOT" && eval "$probe" >/dev/null 2>&1) || printf 'a malicious assertion was ACCEPTED (expected 401/403)'
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "sso selftest SKIP - jq not installed."; return 0; fi
  echo "sso-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  sso() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${2:-medium}" > "$1/walteur-kit/build-contract.json"; printf '{"has_sso":true,"has_auth":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  # real probes: must carry a real verification tool, assert a 403 rejection in EXECUTED code, and the exit status
  # must reflect the captured code. PASS: forged assertion got 403 (rejected) -> exit 0. LEAK: forged assertion got
  # 200 (ACCEPTED) yet still claims 403 -> assertion fails -> exit non-0 (caught). No trailing unconditional-success
  # token; the keyword '403' lives in executed code, never in a discarded echo or comment. Pick whatever real tool
  # this host has so the selftest stays portable (offline, deterministic).
  if have python3; then PASS_PROBE="python3 -c 'import sys; code=403; sys.exit(0 if code==403 else 1)'"; LEAK_PROBE="python3 -c 'import sys; code=200; sys.exit(0 if code==403 else 1)'"
  elif have python; then PASS_PROBE="python -c 'import sys; code=403; sys.exit(0 if code==403 else 1)'"; LEAK_PROBE="python -c 'import sys; code=200; sys.exit(0 if code==403 else 1)'"
  elif have node;   then PASS_PROBE="node -e 'var code=403; process.exit(code===403?0:1) /* reject 403 */'"; LEAK_PROBE="node -e 'var code=200; process.exit(code===403?0:1) /* reject 403 */'"
  else echo "  note - no python/node for a tool-bearing PASS probe; skipping PASS-asserting cases"; PASS_PROBE=""; LEAK_PROBE=""; fi
  if [ -z "$PASS_PROBE" ]; then echo "sso-gate selftest: SKIP (no real-tool runtime for probe fixtures)"; return 0; fi
  goodman() { jq -n --arg p "$1" '{protocol:"saml",controls:[
    {name:"assertion_signature_validation",status:"verified",probe_command:$p},
    {name:"audience_restriction",status:"verified",probe_command:$p},
    {name:"time_window_enforcement",status:"verified",probe_command:$p},
    {name:"replay_protection",status:"verified",probe_command:$p}]}' > "$2/walteur-kit/sso.json"; }

  # 1. no SSO surface -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"has_auth":true}\n' > "$t/walteur-kit/preflight-signals.json"; printf 'export const x=1;\n' > "$t/a.ts"; ck "no SSO surface -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. all required controls verified + REAL rejecting probes -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "$PASS_PROBE" "$t"; ck "real rejecting probes -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. manifest absent -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; ck "SSO surface, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. a control probe ACCEPTS a forged assertion -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "$PASS_PROBE" "$t"; jq --arg L "$LEAK_PROBE" '(.controls[]|select(.name=="assertion_signature_validation")).probe_command=$L' "$t/walteur-kit/sso.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/sso.json"; ck "signature probe accepts forged -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. a required control missing -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "$PASS_PROBE" "$t"; jq '.controls |= map(select(.name!="audience_restriction"))' "$t/walteur-kit/sso.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/sso.json"; ck "missing audience_restriction -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. verified control with NO probe -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "$PASS_PROBE" "$t"; jq '(.controls[]|select(.name=="replay_protection")).probe_command=""' "$t/walteur-kit/sso.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/sso.json"; ck "verified control no probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. signed-deferred at risk=high -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t" high; goodman "$PASS_PROBE" "$t"; jq '(.controls[]|select(.name=="replay_protection"))|={name:"replay_protection",status:"signed-deferred",deferral:{owner:"Tony",ticket:"W-1",review_trigger:"beta"}}' "$t/walteur-kit/sso.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/sso.json"; ck "deferred at high risk -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. signed-deferred at risk=low -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t" low; goodman "$PASS_PROBE" "$t"; jq '(.controls[]|select(.name=="replay_protection"))|={name:"replay_protection",status:"signed-deferred",deferral:{owner:"Tony",ticket:"W-1",review_trigger:"beta"}}' "$t/walteur-kit/sso.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/sso.json"; ck "deferred at low risk -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 9. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "$LEAK_PROBE" "$t"; WALTEUR_ROOT="$t" WALTEUR_SSO=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ── D4 gauntlet regressions (probe-bypass class — every one was a PROVEN false-negative) ──
  # G1 — trivial no-op "true" probe
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "true" "$t"; ck "G1 trivial true probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2 — non-allowlisted / non-existent script probe (silently skipped before)
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "./run-sso-test.sh --signature-strip" "$t"; ck "G2 off-allowlist script -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3 — whitespace-only probe
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman " " "$t"; ck "G3 whitespace probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G4 — probe asserts NO rejection (a health check that exits 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "bash -c 'echo healthy | grep -q healthy'" "$t"; ck "G4 no-rejection probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G5 — duplicate control: real first, fake "true" appended -> trivial-probe rejection still FAILs
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "$PASS_PROBE" "$t"; jq '.controls += [{name:"assertion_signature_validation",status:"verified",probe_command:"true"}]' "$t/walteur-kit/sso.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/sso.json"; ck "G5 duplicate fake control -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G6 — SSO impl in a .cs file, no sso.json, has_sso absent -> surface now detected -> FAIL (manifest absent)
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf '{"has_auth":true}\n' > "$t/walteur-kit/preflight-signals.json"; printf 'using Sustainsys.Saml2; // AssertionConsumer acs url handler\n' > "$t/src/Auth.cs"; ck "G6 SSO in .cs, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # ── later gauntlet regressions (probe/shape laundering — every one was a PROVEN false-negative) ──
  # G7 — comment-laundering: the '403' rejection keyword lives only in a trailing '# ...' comment bash discards,
  #      while the real command `echo 200|grep -q 200` exits 0 (forged assertion ACCEPTED). Must FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t" high; goodman "bash -c 'echo 200 | grep -q 200' # asserts 403 rejection of forged SAML assertion" "$t"; ck "G7 comment-laundered 403 keyword -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G8 — multi-document JSON stream: two concatenated objects smuggle a duplicate signature control past the
  #      per-name duplicate guard (non-slurped jq -> head -1 reads only doc 1). Must FAIL on the malformed manifest.
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t" high
  printf '%s\n' '{"controls":[{"name":"assertion_signature_validation","status":"verified","probe_command":"X"},{"name":"audience_restriction","status":"verified","probe_command":"X"},{"name":"time_window_enforcement","status":"verified","probe_command":"X"},{"name":"replay_protection","status":"verified","probe_command":"X"}]}' > "$t/walteur-kit/sso.json"
  printf '%s\n' '{"controls":[{"name":"assertion_signature_validation","status":"verified","probe_command":"Y"}]}' >> "$t/walteur-kit/sso.json"
  ck "G8 multi-doc JSON stream -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G9 — vacuous probe: a real tool (curl) is present but its output is discarded and a trailing `; true` hardcodes
  #      exit 0; the '403' keyword sits only in a >/dev/null echo. Verifies nothing. Must FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t" high; goodman 'curl -s http://127.0.0.1:1/x >/dev/null 2>&1; echo "expecting 403 rejection" >/dev/null; true' "$t"; ck "G9 vacuous probe (trailing true) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G10 — false-positive guard: a genuine bash-wrapped curl probe that asserts a real 403 on a forged assertion and
  #       whose exit reflects the match must still PASS (the real-tool/keyword checks must not over-reject).
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "bash -c 'printf 403 | grep -q 403 && curl --version >/dev/null 2>&1'" "$t"; ck "G10 genuine bash+curl 403 probe -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # ── Unify probe hardening: shared _probe-proof.sh kernel poison classes (constant-exit/no-op) ──
  # G11 — "false" no-op probe (exits non-0 unconditionally, proves nothing) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "false" "$t"; ck "G11 false no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G12 — ":" no-op probe -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman ":" "$t"; ck "G12 ':' no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G13 — "bash -lc 'exit 0'" constant-exit no-op (the class the shared kernel names by name) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "bash -lc 'exit 0'" "$t"; ck "G13 bash -lc exit-0 no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G14 — shared guard fail-closed: if _probe-proof.sh is unavailable at source time, a probe must FAIL
  # closed rather than silently skip the no-op check. Simulate by pointing the gate at a copy of itself
  # with the sibling guard file temporarily hidden.
  t="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; sso "$t"; goodman "$PASS_PROBE" "$t"
  gdir="$(mktemp -d "${TMPDIR:-/tmp}/ssogate.XXXXXX")"; cp "$SELF" "$gdir/sso-gate.sh"
  ck "G14 guard file absent -> FAIL (fail-closed)" 2 "$(WALTEUR_ROOT="$t" bash "$gdir/sso-gate.sh" >/dev/null 2>&1; echo $?)"
  rm -rf "$t" "$gdir"

  echo "sso-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_SSO:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_SSO=off"; echo "sso-gate: bypassed." >&2; exit 0; }

if ! sso_surface; then write_report "NOT_APPLICABLE" "no SSO surface (no has_sso, no SAML/OIDC code, no sso.json)"; echo "sso-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "sso-gate: SKIP." >&2; exit 0; fi

if [ ! -s "$MANIFEST" ]; then
  add_finding "manifest" "SSO surface (SAML/OIDC) but walteur-kit/sso.json absent — assertion signature, audience, time-window and replay controls are unverified (Golden-SAML / audience-confusion = account takeover)"
  write_report "FAIL" "sso manifest absent"; echo "sso-gate: FAIL - manifest absent" >&2; exit 2
fi
# The manifest MUST be exactly ONE JSON document with a top-level controls array. A multi-document JSON stream
# (two concatenated objects) is each individually valid to a streaming `jq .`, but it smuggles a duplicate/forged
# control past the per-name duplicate guard below: a non-slurped `jq` emits one length per doc (cnt="1\n1"), the
# integer test errors out (2>/dev/null swallows it), and `head -1` only ever reads document #1. Reject up front.
if ! jq -se 'length==1 and (.[0]|type=="object") and ((.[0].controls|type)=="array")' "$MANIFEST" >/dev/null 2>&1; then
  add_finding "manifest" "walteur-kit/sso.json is not a single well-formed JSON object with a controls array (malformed, or a multi-document JSON stream used to smuggle a duplicate/forged control past the duplicate guard)"
  write_report "FAIL" "sso manifest not a single JSON document"; echo "sso-gate: FAIL - manifest not a single JSON document" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
RISK="$(risk)"
for c in $REQUIRED_CONTROLS; do
  # duplicate entries for one control name are ambiguous — the gauntlet hid a fake "true"-probe entry next to a
  # real one to defeat head -1. Require exactly one declaration per required control (order can't matter now).
  cnt="$(jq -s --arg n "$c" '[.[0].controls[]? | select(.name==$n)] | length' "$MANIFEST" 2>/dev/null)"
  [ "${cnt:-0}" -gt 1 ] 2>/dev/null && add_finding "$c" "duplicate '$c' control entries ($cnt) — declare exactly one verified control per name"
  entry="$(jq -c --arg n "$c" '.controls[]? | select(.name==$n)' "$MANIFEST" 2>/dev/null | head -1)"
  if [ -z "$entry" ]; then add_finding "$c" "required SSO control '$c' not declared in sso.json"; continue; fi
  st="$(printf '%s' "$entry" | jq -r '.status // ""')"
  case "$st" in
    verified)
      probe="$(printf '%s' "$entry" | jq -r '.probe_command // ""')"
      if [ -z "$probe" ]; then add_finding "$c" "control '$c' is 'verified' but cites no probe_command (must POST a tampered/unsigned/expired/wrong-audience assertion and assert 401/403)"
      elif [ "${WALTEUR_SSO_PROBE:-on}" != "off" ]; then res="$(run_probe "$probe")"; [ -n "$res" ] && add_finding "$c" "$res (ran: $probe)"; fi
      ;;
    signed-deferred)
      case "$RISK" in high|regulated) add_finding "$c" "SSO control '$c' cannot be signed-deferred at risk_tier=$RISK — an SSO bypass is account takeover";; esac
      printf '%s' "$entry" | jq -e '.deferral.owner and .deferral.ticket and .deferral.review_trigger' >/dev/null 2>&1 || add_finding "$c" "signed-deferred '$c' needs deferral owner+ticket+review_trigger"
      ;;
    not-applicable)
      printf '%s' "$entry" | jq -e '.reason // empty' >/dev/null 2>&1 || add_finding "$c" "'$c' marked not-applicable without a reason"
      ;;
    *) add_finding "$c" "control '$c' status must be verified|signed-deferred|not-applicable (got '${st:-empty}')";;
  esac
done

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures SSO control violation(s)"
  echo "sso-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "SSO assertion signature + audience + time-window + replay controls verified by malicious-assertion probes"
echo "sso-gate: PASS" >&2
exit 0
