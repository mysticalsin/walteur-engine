#!/usr/bin/env bash
# WALTEUR security-gate — honest detect-or-loud-SKIP secret/dependency/SAST gate.
# Each sub-tool is INDEPENDENTLY detect-or-skip:
#   - gitleaks detect        — ANY finding  => violation (exit 2)
#   - osv-scanner | npm audit | pip-audit — HIGH+ vuln => violation (exit 2)
#   - semgrep --config p/owasp-top-ten     — ERROR-level finding => violation (exit 2)
# If a tool is ABSENT: print a LOUD recorded SKIP to stderr and record verdict:SKIP for that
# sub-tool in the report — NEVER silent-green, NEVER exit 2 for a missing tool.
# Overall exit: 2 if ANY present tool found a real violation; else 0 (clean or all-SKIP).
# Report: walteur-kit/security-report.json with per-tool {verdict|SKIP}.
# Bypass: WALTEUR_SECURITY=off.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/security-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }
loud_skip() { echo "  SKIP — $1 not installed ($2). Recorded; NOT counted green." >&2; }

write_report() {
  local v="$1" reason="$2" details="${3:-}"
  [ -n "$details" ] || details="{}"
  if have jq; then
    local details_file
    details_file="$(mktemp "${TMPDIR:-/tmp}/security-report-details.XXXXXX")" || details_file=""
    if [ -n "$details_file" ]; then
      printf '%s\n' "$details" > "$details_file"
      if jq -e . "$details_file" >/dev/null 2>&1; then
        jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --slurpfile d "$details_file" \
          '{verdict:$v, ts:$ts, gate:"security", reason:$reason, details:$d[0]}' > "$REPORT" 2>/dev/null
        rc=$?
        rm -f "$details_file"
        [ "$rc" -eq 0 ] && return 0
      else
        rm -f "$details_file"
      fi
    fi
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"security","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
}

selftest() {
  pass=0
  fail=0
  ck() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  for t in bash jq mktemp date mkdir rm ln chmod cat; do
    if ! have "$t"; then
      echo "security-gate selftest SKIP - required tool '$t' not installed."
      return 0
    fi
  done

  make_core_path() {
    dst="$1"
    mkdir -p "$dst"
    for t in bash jq mktemp date mkdir rm; do
      ln -sf "$(command -v "$t")" "$dst/$t"
    done
  }
  make_fake_gitleaks() {
    dst="$1"
    cat > "$dst/gitleaks" <<'SH'
#!/usr/bin/env bash
src=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) shift; src="${1:-}";;
  esac
  shift || true
done
[ -n "$src" ] || src="."
[ -f "$src/leak.env" ] && exit 1
exit 0
SH
    chmod +x "$dst/gitleaks"
  }

  echo "security-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/secself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no scanners -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP" and .tools_ran == 0' "$tmp/walteur-kit/security-report.json" >/dev/null 2>&1
  ck "no scanners report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/secself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  make_fake_gitleaks "$tmp/bin"
  printf 'safe configuration\n' > "$tmp/app.txt"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "fake gitleaks clean -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .tools_ran == 1 and .details.gitleaks.verdict == "PASS"' "$tmp/walteur-kit/security-report.json" >/dev/null 2>&1
  ck "fake gitleaks clean report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/secself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  make_fake_gitleaks "$tmp/bin"
  printf 'SECRET_TOKEN=not-real\n' > "$tmp/leak.env"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "fake gitleaks leak -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .violations == 1 and .details.gitleaks.verdict == "FAIL"' "$tmp/walteur-kit/security-report.json" >/dev/null 2>&1
  ck "fake gitleaks leak report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/secself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" WALTEUR_SECURITY=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/security-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/secself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "security-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
if [ "${WALTEUR_SECURITY:-on}" = "off" ]; then
  echo "security-gate: bypassed (WALTEUR_SECURITY=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_SECURITY=off" '{"bypassed":true}'
  exit 0
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"; trap 'rm -f "$TMP"' EXIT

violations=0   # number of present tools that found a real violation
ran=0          # number of present tools that actually ran

# tool_json accumulators (jq-built object)
J='{}'
add() { # add <key> <json-value>
  J="$(printf '%s' "$J" | jq --argjson v "$2" --arg k "$1" '.[$k]=$v' 2>/dev/null || printf '%s' "$J")"
}

echo "WALTEUR security-gate @ $ROOT" >&2

# ── 1. gitleaks (secret scan) — ANY finding fails ─────────────────────────────
if have gitleaks; then
  ran=$((ran+1))
  if gitleaks detect --source "$ROOT" --no-banner --redact >/dev/null 2>"$TMP"; then
    echo "  ok   — gitleaks: no secrets found." >&2
    add gitleaks '{"verdict":"PASS","tool":"gitleaks","rule":"any-finding=fail"}'
  else
    echo "  FAIL — gitleaks: secret(s) detected." >&2
    violations=$((violations+1))
    add gitleaks '{"verdict":"FAIL","tool":"gitleaks","rule":"any-finding=fail"}'
  fi
else
  loud_skip gitleaks "secret scanning"
  add gitleaks '{"verdict":"SKIP","reason":"gitleaks not installed"}'
fi

# ── 2. dependency vuln scan — first available of osv-scanner | npm audit | pip-audit ──
# HIGH+ severity => violation. Independent detect-or-skip; if NONE present => SKIP.
dep_done=0
if have osv-scanner; then
  ran=$((ran+1)); dep_done=1
  # osv-scanner: non-zero exit means vulnerabilities were found; filter to HIGH/CRITICAL.
  osv-scanner --format json -r "$ROOT" >"$TMP" 2>/dev/null || true
  high="$(jq '[.results[]?.packages[]?.vulnerabilities[]? | select((.database_specific.severity // .severity // "" | ascii_upcase) | test("HIGH|CRITICAL"))] | length' "$TMP" 2>/dev/null || echo 0)"
  [ -z "$high" ] && high=0
  if [ "$high" -gt 0 ]; then
    echo "  FAIL — osv-scanner: $high HIGH/CRITICAL vuln(s)." >&2
    violations=$((violations+1))
    add dependency "$(jq -n --arg t osv-scanner --argjson n "$high" '{verdict:"FAIL",tool:$t,high_or_critical:$n,rule:"HIGH+=fail"}')"
  else
    echo "  ok   — osv-scanner: no HIGH/CRITICAL vulns." >&2
    add dependency '{"verdict":"PASS","tool":"osv-scanner","high_or_critical":0,"rule":"HIGH+=fail"}'
  fi
elif have npm && [ -f "$ROOT/package.json" ]; then
  ran=$((ran+1)); dep_done=1
  ( cd "$ROOT" && npm audit --audit-level=high --json ) >"$TMP" 2>/dev/null || true
  high="$(jq '((.metadata.vulnerabilities.high // 0) + (.metadata.vulnerabilities.critical // 0))' "$TMP" 2>/dev/null || echo 0)"
  [ -z "$high" ] && high=0
  if [ "$high" -gt 0 ]; then
    echo "  FAIL — npm audit: $high high/critical advisory(ies)." >&2
    violations=$((violations+1))
    add dependency "$(jq -n --argjson n "$high" '{verdict:"FAIL",tool:"npm audit",high_or_critical:$n,rule:"HIGH+=fail"}')"
  else
    echo "  ok   — npm audit: no high/critical advisories." >&2
    add dependency '{"verdict":"PASS","tool":"npm audit","high_or_critical":0,"rule":"HIGH+=fail"}'
  fi
elif have pip-audit; then
  ran=$((ran+1)); dep_done=1
  ( cd "$ROOT" && pip-audit --format json ) >"$TMP" 2>/dev/null || true
  # pip-audit lists vulns per dependency; treat any vuln as fail (it does not always carry severity).
  vc="$(jq '[.dependencies[]?.vulns[]?] | length' "$TMP" 2>/dev/null || echo 0)"
  [ -z "$vc" ] && vc=0
  if [ "$vc" -gt 0 ]; then
    echo "  FAIL — pip-audit: $vc known vuln(s)." >&2
    violations=$((violations+1))
    add dependency "$(jq -n --argjson n "$vc" '{verdict:"FAIL",tool:"pip-audit",vulns:$n,rule:"known-vuln=fail"}')"
  else
    echo "  ok   — pip-audit: no known vulns." >&2
    add dependency '{"verdict":"PASS","tool":"pip-audit","vulns":0,"rule":"known-vuln=fail"}'
  fi
fi
if [ "$dep_done" -eq 0 ]; then
  loud_skip "osv-scanner/npm-audit/pip-audit" "dependency vulnerability scanning"
  add dependency '{"verdict":"SKIP","reason":"no dependency scanner installed (osv-scanner|npm audit|pip-audit)"}'
fi

# ── 3. semgrep SAST (OWASP Top Ten) — ERROR-level finding fails ───────────────
if have semgrep; then
  ran=$((ran+1))
  semgrep --config p/owasp-top-ten --error --json "$ROOT" >"$TMP" 2>/dev/null || true
  errs="$(jq '[.results[]? | select((.extra.severity // "" | ascii_upcase)=="ERROR")] | length' "$TMP" 2>/dev/null || echo 0)"
  [ -z "$errs" ] && errs=0
  if [ "$errs" -gt 0 ]; then
    echo "  FAIL — semgrep: $errs ERROR-level OWASP finding(s)." >&2
    violations=$((violations+1))
    add semgrep "$(jq -n --argjson n "$errs" '{verdict:"FAIL",tool:"semgrep",config:"p/owasp-top-ten",errors:$n,rule:"ERROR=fail"}')"
  else
    echo "  ok   — semgrep: no ERROR-level findings." >&2
    add semgrep '{"verdict":"PASS","tool":"semgrep","config":"p/owasp-top-ten","errors":0,"rule":"ERROR=fail"}'
  fi
else
  loud_skip semgrep "OWASP Top Ten SAST"
  add semgrep '{"verdict":"SKIP","reason":"semgrep not installed"}'
fi

# ── overall verdict ───────────────────────────────────────────────────────────
if [ "$violations" -gt 0 ]; then
  OVERALL=FAIL
elif [ "$ran" -gt 0 ]; then
  OVERALL=PASS
else
  OVERALL=SKIP
fi

jq -n --arg v "$OVERALL" --arg ts "$TS" --argjson ran "$ran" \
      --argjson viol "$violations" --argjson tools "$J" \
  '{verdict:$v, ts:$ts, gate:"security", tools_ran:$ran, violations:$viol, details:$tools}' \
  > "$REPORT" 2>/dev/null || printf '{"verdict":"%s","ts":"%s","gate":"security","tools_ran":%s,"violations":%s}\n' "$OVERALL" "$TS" "$ran" "$violations" > "$REPORT"

echo "security-gate verdict: $OVERALL (ran=$ran, violations=$violations) -> $REPORT" >&2
[ "$OVERALL" = "FAIL" ] && exit 2
exit 0
