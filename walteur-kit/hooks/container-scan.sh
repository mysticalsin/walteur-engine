#!/usr/bin/env bash
# WALTEUR container-scan — honest detect-or-loud-SKIP container/manifest security gate.
# Applies ONLY if a container manifest is present (Dockerfile / *.dockerfile / Containerfile,
# or a docker-compose / k8s manifest). If none present: gate not applicable (exit 0).
# If present, runs each tool that exists:
#   hadolint <Dockerfile>                                  — lint error => violation
#   trivy config <root> --severity HIGH,CRITICAL           — HIGH/CRITICAL misconfig => violation
#   trivy image <img> --severity HIGH,CRITICAL  (if image referenced & resolvable; best-effort)
#   kubeconform <k8s-yaml> (if present)                    — schema-invalid manifest => violation
# Missing a tool => SKIP that sub-check (loud, recorded). Missing ALL => loud overall SKIP, exit 0.
# NEVER silent-green, NEVER exit 2 for a missing tool. Present tool + real finding => exit 2.
# Report: walteur-kit/container-report.json with per-tool {verdict|SKIP}.
# Bypass: WALTEUR_CONTAINER=off.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "container-scan - honest detect-or-loud-SKIP container/manifest security gate."
  printf '%s\n' "usage: bash container-scan.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/container-report.json - fix recipes: walteur-kit/REMEDIATION.md (## container-scan)"
  printf '%s\n' "bypass: WALTEUR_CONTAINER=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# ── B42: real --selftest harness (this gate previously advertised --selftest in --help but had none). ──
# Deterministic regardless of host tools: every case runs the gate under a BASE-ONLY PATH (bash/jq/find/…,
# NO trivy/hadolint/kubeconform/grype) so "no scanner installed" is forced; PASS/FAIL paths fake hadolint.
if [ "${1:-}" = "--selftest" ]; then
  SELF="$0"
  command -v jq >/dev/null 2>&1 || { echo "container-scan selftest SKIP - jq not installed."; exit 0; }
  _pass=0; _fail=0
  _ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; _pass=$((_pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; _fail=$((_fail+1)); fi; }
  _base_path() { # $1=dir -> a bin/ with ONLY base tools symlinked (no container scanners); echoes its path
    local bd="$1/bin"; mkdir -p "$bd"
    local t src
    for t in bash sh jq find mktemp grep head sed cat date mkdir rm env printf sort tr wc ln xargs dirname basename; do
      src="$(command -v "$t" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$bd/$t" 2>/dev/null
    done
    printf '%s' "$bd"
  }
  _run() { # $1=root $2=extra-env-KEY=VAL(optional) -> echoes rc; forces base-only PATH
    local bp; bp="$(_base_path "$1")"
    local rc
    if [ -n "${2:-}" ]; then
      env -i PATH="$bp" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" WALTEUR_ROOT="$1" "$2" bash "$SELF" >/dev/null 2>&1; rc=$?
    else
      env -i PATH="$bp" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; rc=$?
    fi
    echo "$rc"
  }
  _mkdockerfile() { mkdir -p "$1/walteur-kit"; printf 'FROM alpine:3.19\nRUN echo hi\n' > "$1/Dockerfile"; }

  echo "container-scan selftest:"

  # 1. no manifest -> NOT_APPLICABLE exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/container-selftest.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf 'print(1)\n' > "$t/app.py"
  _ck "no manifest -> NOT_APPLICABLE" 0 "$(_run "$t")"
  _v="$(jq -r '.verdict' "$t/walteur-kit/container-report.json" 2>/dev/null)"; _ck "no manifest verdict==NOT_APPLICABLE" NOT_APPLICABLE "$_v"; rm -rf "$t"

  # 2. Dockerfile + no scanner (default) -> loud SKIP exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/container-selftest.XXXXXX")"; _mkdockerfile "$t"
  _ck "Dockerfile + no scanner (default) -> SKIP" 0 "$(_run "$t")"
  _v="$(jq -r '.verdict' "$t/walteur-kit/container-report.json" 2>/dev/null)"; _ck "no-scanner default verdict==SKIP" SKIP "$_v"; rm -rf "$t"

  # 3. Dockerfile + no scanner + global STRICT -> FAIL exit 2 (B41 lock)
  t="$(mktemp -d "${TMPDIR:-/tmp}/container-selftest.XXXXXX")"; _mkdockerfile "$t"
  _ck "Dockerfile + no scanner + TOOLGATE_STRICT=1 -> FAIL (B41)" 2 "$(_run "$t" "WALTEUR_TOOLGATE_STRICT=1")"
  _v="$(jq -r '.verdict' "$t/walteur-kit/container-report.json" 2>/dev/null)"; _ck "strict no-scanner verdict==FAIL" FAIL "$_v"; rm -rf "$t"

  # 4. bypass WALTEUR_CONTAINER=off wins over global STRICT -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/container-selftest.XXXXXX")"; _mkdockerfile "$t"
  bp="$(_base_path "$t")"; env -i PATH="$bp" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" WALTEUR_ROOT="$t" WALTEUR_CONTAINER=off WALTEUR_TOOLGATE_STRICT=1 bash "$SELF" >/dev/null 2>&1
  _ck "WALTEUR_CONTAINER=off + strict -> exit 0 (bypass wins)" 0 "$?"; rm -rf "$t"

  # 5. PAUSED -> exit 2 (kill switch beats everything)
  t="$(mktemp -d "${TMPDIR:-/tmp}/container-selftest.XXXXXX")"; _mkdockerfile "$t"; touch "$t/walteur-kit/PAUSED"
  _ck "PAUSED -> exit 2" 2 "$(_run "$t")"; rm -rf "$t"

  # 6. k8s manifest (apiVersion+kind) + no scanner + strict -> FAIL (k8s applicability path)
  t="$(mktemp -d "${TMPDIR:-/tmp}/container-selftest.XXXXXX")"; mkdir -p "$t/walteur-kit"
  printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: x\n' > "$t/deploy.yaml"
  _ck "k8s manifest + no scanner + strict -> FAIL" 2 "$(_run "$t" "WALTEUR_TOOLGATE_STRICT=1")"; rm -rf "$t"

  # 7. compose file + no scanner (default) -> SKIP (compose applicability path)
  t="$(mktemp -d "${TMPDIR:-/tmp}/container-selftest.XXXXXX")"; mkdir -p "$t/walteur-kit"
  printf 'services:\n  web:\n    image: nginx\n' > "$t/docker-compose.yml"
  _ck "compose + no scanner (default) -> SKIP" 0 "$(_run "$t")"; rm -rf "$t"

  # 8. Dockerfile + fake hadolint (clean, exit 0) -> a scanner RAN, no violations -> PASS exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/container-selftest.XXXXXX")"; _mkdockerfile "$t"; bp="$(_base_path "$t")"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bp/hadolint"; chmod +x "$bp/hadolint"
  env -i PATH="$bp" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  _ck "Dockerfile + fake-hadolint clean -> PASS exit 0" 0 "$?"
  _v="$(jq -r '.verdict' "$t/walteur-kit/container-report.json" 2>/dev/null)"; _ck "fake-hadolint clean verdict==PASS" PASS "$_v"; rm -rf "$t"

  # 9. Dockerfile + fake hadolint (issues, exit 1) -> violation -> FAIL exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/container-selftest.XXXXXX")"; _mkdockerfile "$t"; bp="$(_base_path "$t")"
  printf '#!/usr/bin/env bash\necho "DL3006 warning"; exit 1\n' > "$bp/hadolint"; chmod +x "$bp/hadolint"
  env -i PATH="$bp" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  _ck "Dockerfile + fake-hadolint issues -> FAIL exit 2" 2 "$?"; rm -rf "$t"

  echo "container-scan selftest: $((_pass))/$((_pass+_fail)) passed"
  [ "$_fail" -eq 0 ]; exit $?
fi


ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/container-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_CONTAINER:-on}" = "off" ] && { echo "container-scan: bypassed (WALTEUR_CONTAINER=off)." >&2; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }
TMP="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"; trap 'rm -f "$TMP"' EXIT

# ── applicability detection ───────────────────────────────────────────────────
dockerfile="$(find "$ROOT" \( -path "$ROOT/.git" -o -path "$ROOT/node_modules" \) -prune -o \
  \( -iname 'Dockerfile' -o -iname 'Dockerfile.*' -o -iname '*.dockerfile' -o -iname 'Containerfile' \) -type f -print 2>/dev/null | head -1)"
compose="$(find "$ROOT" \( -path "$ROOT/.git" -o -path "$ROOT/node_modules" \) -prune -o \
  \( -iname 'docker-compose*.yml' -o -iname 'docker-compose*.yaml' -o -iname 'compose.yml' -o -iname 'compose.yaml' \) -type f -print 2>/dev/null | head -1)"
# k8s manifest: yaml with apiVersion + kind
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
[ -n "$dockerfile" ] && applicable=1
[ -n "$compose" ] && applicable=1
[ -n "$k8s_file" ] && applicable=1

if [ "$applicable" -eq 0 ]; then
  echo "container-scan: no container manifest (Dockerfile/compose/k8s) present — gate not applicable." >&2
  jq -n --arg ts "$TS" '{verdict:"NOT_APPLICABLE", ts:$ts, gate:"container", reason:"no Dockerfile/compose/k8s manifest present"}' > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"container"}\n' "$TS" > "$REPORT"
  exit 0
fi

loud_skip() { echo "  SKIP — $1 not installed ($2). Recorded; NOT counted green." >&2; }
violations=0; ran=0
J='{}'
add() { J="$(printf '%s' "$J" | jq --argjson v "$2" --arg k "$1" '.[$k]=$v' 2>/dev/null || printf '%s' "$J")"; }

echo "WALTEUR container-scan @ $ROOT (dockerfile=${dockerfile:+yes} compose=${compose:+yes} k8s=${k8s_file:+yes})" >&2

# ── hadolint (Dockerfile lint) ────────────────────────────────────────────────
if have hadolint; then
  if [ -n "$dockerfile" ]; then
    ran=$((ran+1))
    if hadolint "$dockerfile" >"$TMP" 2>&1; then
      echo "  ok   — hadolint: clean ($dockerfile)." >&2
      add hadolint "$(jq -n --arg f "$dockerfile" '{verdict:"PASS",tool:"hadolint",file:$f}')"
    else
      echo "  FAIL — hadolint: issues in $dockerfile." >&2
      violations=$((violations+1))
      add hadolint "$(jq -n --arg f "$dockerfile" '{verdict:"FAIL",tool:"hadolint",file:$f}')"
    fi
  else
    echo "  SKIP — hadolint: installed but no Dockerfile to lint." >&2
    add hadolint '{"verdict":"SKIP","reason":"no Dockerfile present (hadolint installed)"}'
  fi
else
  loud_skip hadolint "Dockerfile lint"
  add hadolint '{"verdict":"SKIP","reason":"hadolint not installed"}'
fi

# ── trivy config (misconfig scan of IaC/Dockerfile/manifests) ─────────────────
if have trivy; then
  ran=$((ran+1))
  trivy config "$ROOT" --severity HIGH,CRITICAL --format json --quiet >"$TMP" 2>/dev/null || true
  n="$(jq '[.Results[]?.Misconfigurations[]?] | length' "$TMP" 2>/dev/null || echo 0)"; [ -z "$n" ] && n=0
  if [ "$n" -gt 0 ]; then
    echo "  FAIL — trivy config: $n HIGH/CRITICAL misconfig(s)." >&2
    violations=$((violations+1))
    add trivy_config "$(jq -n --argjson n "$n" '{verdict:"FAIL",tool:"trivy config",severity:"HIGH,CRITICAL",misconfigurations:$n}')"
  else
    echo "  ok   — trivy config: no HIGH/CRITICAL misconfigs." >&2
    add trivy_config '{"verdict":"PASS","tool":"trivy config","severity":"HIGH,CRITICAL","misconfigurations":0}'
  fi
else
  loud_skip trivy "container misconfig/image scan"
  add trivy_config '{"verdict":"SKIP","reason":"trivy not installed"}'
fi

# ── kubeconform (k8s manifest schema validation, only if present) ─────────────
if have kubeconform; then
  if [ -n "$k8s_file" ]; then
    ran=$((ran+1))
    mapfiles="$(find "$ROOT" \( -path "$ROOT/.git" -o -path "$ROOT/node_modules" \) -prune -o \( -name '*.yaml' -o -name '*.yml' \) -type f -print 2>/dev/null)"
    # shellcheck disable=SC2086
    if echo "$mapfiles" | xargs kubeconform -summary -skip Secret >"$TMP" 2>&1; then
      echo "  ok   — kubeconform: manifests valid." >&2
      add kubeconform '{"verdict":"PASS","tool":"kubeconform"}'
    else
      echo "  FAIL — kubeconform: invalid manifest(s)." >&2
      violations=$((violations+1))
      add kubeconform '{"verdict":"FAIL","tool":"kubeconform"}'
    fi
  else
    echo "  SKIP — kubeconform: installed but no k8s manifest present." >&2
    add kubeconform '{"verdict":"SKIP","reason":"no k8s manifest present (kubeconform installed)"}'
  fi
else
  loud_skip kubeconform "k8s schema validation (optional)"
  add kubeconform '{"verdict":"SKIP","reason":"kubeconform not installed"}'
fi

if [ "$violations" -gt 0 ]; then
  OVERALL=FAIL
elif [ "$ran" -gt 0 ]; then
  OVERALL=PASS
else
  # manifest present but NO scanner installed. Default: loud SKIP (couldn't measure, never green). But at a
  # real ship (ship-gate exports WALTEUR_TOOLGATE_STRICT=1) an unscanned container image cannot ride a
  # certified ship — escalate to FAIL closed. Mirrors osv-gate / security-scan-gate global-strict precedence.
  if [ "${WALTEUR_TOOLGATE_STRICT:-0}" = "1" ]; then
    OVERALL=FAIL
    echo "  FAIL — a container/manifest is present but NO scanner ran (trivy/hadolint/kubeconform absent) and WALTEUR_TOOLGATE_STRICT=1: an unscanned image cannot ship. Acquire a scanner via tool-acquisition." >&2
  else
    OVERALL=SKIP   # manifest present but NO scanner installed — loud skip, not green
  fi
fi

jq -n --arg v "$OVERALL" --arg ts "$TS" --argjson ran "$ran" \
      --argjson viol "$violations" --argjson tools "$J" \
  '{verdict:$v, ts:$ts, gate:"container", tools_ran:$ran, violations:$viol, details:$tools}' \
  > "$REPORT" 2>/dev/null || printf '{"verdict":"%s","ts":"%s","gate":"container","tools_ran":%s,"violations":%s}\n' "$OVERALL" "$TS" "$ran" "$violations" > "$REPORT"

echo "container-scan verdict: $OVERALL (ran=$ran, violations=$violations) -> $REPORT" >&2
[ "$OVERALL" = "FAIL" ] && exit 2
exit 0
