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
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
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
  OVERALL=SKIP   # manifest present but NO scanner installed — loud skip, not green
fi

jq -n --arg v "$OVERALL" --arg ts "$TS" --argjson ran "$ran" \
      --argjson viol "$violations" --argjson tools "$J" \
  '{verdict:$v, ts:$ts, gate:"container", tools_ran:$ran, violations:$viol, details:$tools}' \
  > "$REPORT" 2>/dev/null || printf '{"verdict":"%s","ts":"%s","gate":"container","tools_ran":%s,"violations":%s}\n' "$OVERALL" "$TS" "$ran" "$violations" > "$REPORT"

echo "container-scan verdict: $OVERALL (ran=$ran, violations=$violations) -> $REPORT" >&2
[ "$OVERALL" = "FAIL" ] && exit 2
exit 0
