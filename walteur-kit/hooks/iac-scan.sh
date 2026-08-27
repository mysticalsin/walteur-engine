#!/usr/bin/env bash
# WALTEUR iac-scan — honest detect-or-loud-SKIP infrastructure-as-code security gate.
# Applies ONLY if IaC files are present (*.tf / *.bicep / Kubernetes YAML). If none present:
# the gate does not apply (verdict NOT_APPLICABLE, exit 0).
# If IaC IS present, runs each tool that exists:
#   tfsec   --minimum-severity HIGH  (Terraform)  — HIGH+ finding => violation
#   checkov -d <root>                              — failed check => violation
#   conftest test <files> (if present)             — failure => violation
# Missing a tool => SKIP that sub-check (loud, recorded). Missing ALL tools => loud overall SKIP,
# exit 0 — NEVER silent-green, NEVER exit 2 for a missing tool.
# A present tool with a real finding => exit 2.
# Report: walteur-kit/iac-report.json with per-tool {verdict|SKIP}.
# Bypass: WALTEUR_IAC=off.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "iac-scan - honest detect-or-loud-SKIP infrastructure-as-code security gate."
  printf '%s\n' "usage: bash iac-scan.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/iac-report.json - fix recipes: walteur-kit/REMEDIATION.md (## iac-scan)"
  printf '%s\n' "bypass: WALTEUR_IAC=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/iac-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  local v="$1" reason="$2" details="${3:-}"
  [ -n "$details" ] || details="{}"
  if have jq; then
    local details_file
    details_file="$(mktemp "${TMPDIR:-/tmp}/iac-report-details.XXXXXX")" || details_file=""
    if [ -n "$details_file" ]; then
      printf '%s\n' "$details" > "$details_file"
      if jq -e . "$details_file" >/dev/null 2>&1; then
        jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --slurpfile d "$details_file" \
          '{verdict:$v, ts:$ts, gate:"iac", reason:$reason, details:$d[0]}' > "$REPORT" 2>/dev/null
        rc=$?
        rm -f "$details_file"
        [ "$rc" -eq 0 ] && return 0
      else
        rm -f "$details_file"
      fi
    fi
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"iac","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
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

  for t in bash jq grep find sed head mktemp date mkdir rm ln chmod; do
    if ! have "$t"; then
      echo "iac-scan selftest SKIP - required tool '$t' not installed."
      return 0
    fi
  done

  make_core_path() {
    dst="$1"
    mkdir -p "$dst"
    for t in bash jq grep find sed head mktemp date mkdir rm; do
      ln -sf "$(command -v "$t")" "$dst/$t"
    done
  }

  make_tf() {
    mkdir -p "$1/infra"
    cat > "$1/infra/main.tf" <<'TF'
resource "aws_s3_bucket" "logs" {
  bucket = "walteur-selftest-logs"
}
TF
  }

  echo "iac-scan selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/iacself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'hello\n' > "$tmp/README.txt"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no IaC -> NOT_APPLICABLE exit" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/iac-report.json" >/dev/null 2>&1
  ck "no IaC report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/iacself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  make_tf "$tmp"
  make_core_path "$tmp/bin"
  PATH="$tmp/bin:$PATH" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "IaC with no scanners -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP" and .tools_ran == 0' "$tmp/walteur-kit/iac-report.json" >/dev/null 2>&1
  ck "no scanner report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/iacself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  make_tf "$tmp"
  make_core_path "$tmp/bin"
  cat > "$tmp/bin/tfsec" <<'SH'
#!/usr/bin/env bash
printf '{"results":[]}\n'
SH
  chmod +x "$tmp/bin/tfsec"
  PATH="$tmp/bin:$PATH" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "fake tfsec clean -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .tools_ran == 1 and .details.tfsec.verdict == "PASS"' "$tmp/walteur-kit/iac-report.json" >/dev/null 2>&1
  ck "fake tfsec clean report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/iacself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  make_tf "$tmp"
  make_core_path "$tmp/bin"
  cat > "$tmp/bin/tfsec" <<'SH'
#!/usr/bin/env bash
printf '{"results":[{"rule_id":"selftest"}]}\n'
SH
  chmod +x "$tmp/bin/tfsec"
  PATH="$tmp/bin:$PATH" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "fake tfsec finding -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .violations == 1 and .details.tfsec.findings == 1' "$tmp/walteur-kit/iac-report.json" >/dev/null 2>&1
  ck "fake tfsec finding report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/iacself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  make_tf "$tmp"
  WALTEUR_ROOT="$tmp" WALTEUR_IAC=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/iac-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/iacself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "iac-scan selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
if [ "${WALTEUR_IAC:-on}" = "off" ]; then
  echo "iac-scan: bypassed (WALTEUR_IAC=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_IAC=off" '{"bypassed":true}'
  exit 0
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"; trap 'rm -f "$TMP"' EXIT

# ── applicability detection ───────────────────────────────────────────────────
# Terraform / Bicep by extension; k8s YAML by content (apiVersion + kind).
tf_files="$(find "$ROOT" -path "$ROOT/.git" -prune -o -name '*.tf' -type f -print 2>/dev/null | head -1)"
bicep_files="$(find "$ROOT" -path "$ROOT/.git" -prune -o -name '*.bicep' -type f -print 2>/dev/null | head -1)"
k8s_file=""
while IFS= read -r y; do
  [ -z "$y" ] && continue
  if grep -lqE '^[[:space:]]*apiVersion:' "$y" 2>/dev/null && grep -lqE '^[[:space:]]*kind:' "$y" 2>/dev/null; then
    k8s_file="$y"; break
  fi
done <<EOF
$(find "$ROOT" \( -path "$ROOT/.git" -o -path "$ROOT/node_modules" \) -prune -o \( -name '*.yaml' -o -name '*.yml' \) -type f -print 2>/dev/null)
EOF

applicable=0
[ -n "$tf_files" ] && applicable=1
[ -n "$bicep_files" ] && applicable=1
[ -n "$k8s_file" ] && applicable=1

if [ "$applicable" -eq 0 ]; then
  echo "iac-scan: no IaC files (*.tf / *.bicep / k8s YAML) present — gate not applicable." >&2
  jq -n --arg ts "$TS" '{verdict:"NOT_APPLICABLE", ts:$ts, gate:"iac", reason:"no *.tf/*.bicep/k8s YAML present"}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"iac"}\n' "$TS" > "$REPORT"
  exit 0
fi

loud_skip() { echo "  SKIP — $1 not installed ($2). Recorded; NOT counted green." >&2; }
violations=0; ran=0
J='{}'
add() { J="$(printf '%s' "$J" | jq --argjson v "$2" --arg k "$1" '.[$k]=$v' 2>/dev/null || printf '%s' "$J")"; }

echo "WALTEUR iac-scan @ $ROOT (tf=${tf_files:+yes} bicep=${bicep_files:+yes} k8s=${k8s_file:+yes})" >&2

# ── tfsec (Terraform, HIGH+) ──────────────────────────────────────────────────
if have tfsec; then
  ran=$((ran+1))
  tfsec "$ROOT" --minimum-severity HIGH --format json --no-color >"$TMP" 2>/dev/null || true
  n="$(jq '[.results[]?] | length' "$TMP" 2>/dev/null || echo 0)"; [ -z "$n" ] && n=0
  if [ "$n" -gt 0 ]; then
    echo "  FAIL — tfsec: $n HIGH+ finding(s)." >&2
    violations=$((violations+1))
    add tfsec "$(jq -n --argjson n "$n" '{verdict:"FAIL",tool:"tfsec",min_severity:"HIGH",findings:$n}')"
  else
    echo "  ok   — tfsec: no HIGH+ findings." >&2
    add tfsec '{"verdict":"PASS","tool":"tfsec","min_severity":"HIGH","findings":0}'
  fi
else
  loud_skip tfsec "Terraform HIGH+ scan"
  add tfsec '{"verdict":"SKIP","reason":"tfsec not installed"}'
fi

# ── checkov ───────────────────────────────────────────────────────────────────
if have checkov; then
  ran=$((ran+1))
  checkov -d "$ROOT" --compact --quiet -o json >"$TMP" 2>/dev/null || true
  # checkov json may be an object or an array of frameworks; sum failed_checks across both shapes.
  failed="$(jq '[.. | objects | .results?.failed_checks? // empty | length] | add // 0' "$TMP" 2>/dev/null || echo 0)"
  [ -z "$failed" ] && failed=0
  if [ "$failed" -gt 0 ]; then
    echo "  FAIL — checkov: $failed failed check(s)." >&2
    violations=$((violations+1))
    add checkov "$(jq -n --argjson n "$failed" '{verdict:"FAIL",tool:"checkov",failed_checks:$n}')"
  else
    echo "  ok   — checkov: no failed checks." >&2
    add checkov '{"verdict":"PASS","tool":"checkov","failed_checks":0}'
  fi
else
  loud_skip checkov "policy-as-code IaC scan"
  add checkov '{"verdict":"SKIP","reason":"checkov not installed"}'
fi

# ── conftest (only if present) ────────────────────────────────────────────────
if have conftest; then
  ran=$((ran+1))
  targets=""
  [ -n "$tf_files" ] && targets="$targets $(find "$ROOT" -path "$ROOT/.git" -prune -o -name '*.tf' -type f -print 2>/dev/null)"
  [ -n "$k8s_file" ] && targets="$targets $k8s_file"
  # shellcheck disable=SC2086
  if conftest test $targets >"$TMP" 2>&1; then
    echo "  ok   — conftest: all policies passed." >&2
    add conftest '{"verdict":"PASS","tool":"conftest"}'
  else
    echo "  FAIL — conftest: policy failure(s)." >&2
    violations=$((violations+1))
    add conftest '{"verdict":"FAIL","tool":"conftest"}'
  fi
else
  loud_skip conftest "OPA policy test (optional)"
  add conftest '{"verdict":"SKIP","reason":"conftest not installed"}'
fi

if [ "$violations" -gt 0 ]; then
  OVERALL=FAIL
elif [ "$ran" -gt 0 ]; then
  OVERALL=PASS
else
  OVERALL=SKIP   # IaC present but NO scanner installed — loud skip, not green
fi

jq -n --arg v "$OVERALL" --arg ts "$TS" --argjson ran "$ran" \
      --argjson viol "$violations" --argjson tools "$J" \
  '{verdict:$v, ts:$ts, gate:"iac", tools_ran:$ran, violations:$viol, details:$tools}' \
  > "$REPORT" 2>/dev/null || printf '{"verdict":"%s","ts":"%s","gate":"iac","tools_ran":%s,"violations":%s}\n' "$OVERALL" "$TS" "$ran" "$violations" > "$REPORT"

echo "iac-scan verdict: $OVERALL (ran=$ran, violations=$violations) -> $REPORT" >&2
[ "$OVERALL" = "FAIL" ] && exit 2
exit 0
