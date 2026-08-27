#!/usr/bin/env bash
# WALTEUR contract-gate — ZERO-DEP hard gate on API contracts, with a spectral-lint upgrade.
#
# Two layers:
#   1. ZERO-DEP HARD RULE (bash/grep/find/jq only — always runs, real exit 2):
#      If the build DECLARES an API surface, a machine-readable spec MUST exist.
#      "Declares an API surface" =
#         - PLAN.md (or any *.md) contains a line matching  surface:\s*api   (case-insensitive), OR
#         - a machine-readable API artefact is present:
#             openapi*.{yaml,yml,json} | swagger*.{yaml,yml,json} | *.proto | schema.graphql
#           OR any yaml/json whose CONTENT declares openapi:/swagger: at top level.
#      If an API is declared by PLAN but NO machine-readable spec file is found anywhere => exit 2.
#      (You said "surface: api" — then there is no spec. That is the contract-less API we forbid.)
#
#   2. DETECT-OR-SKIP UPGRADE (needs `spectral`):
#      If `spectral` is on PATH AND a spec file exists, run `spectral lint -r .spectral.yaml <spec>`.
#      Any ERROR-severity result => violation (exit 2). `spectral` ABSENT => LOUD recorded SKIP of
#      that sub-check (exit 0 unless the zero-dep layer already failed) — never silent-green.
#
# Exit: 2 on any real violation; 0 on clean / not-applicable / spectral-absent-but-zero-dep-clean.
# Report: walteur-kit/contract-report.json {verdict, ts, gate, details}.
# Bypass: WALTEUR_CONTRACT=off.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/contract-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# write_report <verdict> <reason> <details-json-object>
# Falls back to printf if jq is unavailable so a report ALWAYS lands.
write_report() {
  local v="$1" reason="$2" details="${3:-}"
  [ -n "$details" ] || details="{}"
  if have jq; then
    local details_file
    details_file="$(mktemp "${TMPDIR:-/tmp}/contract-report-details.XXXXXX")" || details_file=""
    if [ -n "$details_file" ]; then
      printf '%s\n' "$details" > "$details_file"
      if jq -e . "$details_file" >/dev/null 2>&1; then
        jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --slurpfile d "$details_file" \
          '{verdict:$v, ts:$ts, gate:"contract", reason:$reason, details:$d[0]}' > "$REPORT" 2>/dev/null
        rc=$?
        rm -f "$details_file"
        [ "$rc" -eq 0 ] && return 0
      else
        rm -f "$details_file"
      fi
    fi
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"contract","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
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

  for t in jq grep find sed; do
    if ! have "$t"; then
      echo "contract-gate selftest SKIP - required tool '$t' not installed."
      return 0
    fi
  done

  echo "contract-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cgate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '# Plan\nsurface: cli\n' > "$tmp/PLAN.md"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no API surface -> NOT_APPLICABLE exit" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/contract-report.json" >/dev/null 2>&1
  ck "no API report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cgate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '# Plan\nsurface: api\n' > "$tmp/PLAN.md"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "declared API without spec -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .details.spec_found == false' "$tmp/walteur-kit/contract-report.json" >/dev/null 2>&1
  ck "missing spec report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cgate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '# Plan\nsurface: api\n' > "$tmp/PLAN.md"
  cat > "$tmp/schema.graphql" <<'GRAPHQL'
type Query {
  health: String!
}
GRAPHQL
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "machine-readable graphql spec -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .details.spec_found == true and .details.spectral.verdict == "SKIP"' "$tmp/walteur-kit/contract-report.json" >/dev/null 2>&1
  ck "graphql spec report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cgate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  printf '# Plan\nsurface: api\n' > "$tmp/PLAN.md"
  cat > "$tmp/openapi.yaml" <<'YAML'
openapi: 3.1.0
info:
  title: Demo
  version: "1.0.0"
paths: {}
YAML
  cat > "$tmp/bin/spectral" <<'SH'
#!/usr/bin/env bash
printf '[{"severity":0,"code":"selftest-error"}]\n'
SH
  chmod +x "$tmp/bin/spectral"
  PATH="$tmp/bin:$PATH" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "spectral error -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .details.spectral.verdict == "FAIL" and .details.spectral.error_severity_count == 1' "$tmp/walteur-kit/contract-report.json" >/dev/null 2>&1
  ck "spectral error report verdict FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cgate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '# Plan\nsurface: api\n' > "$tmp/PLAN.md"
  WALTEUR_ROOT="$tmp" WALTEUR_CONTRACT=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/contract-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cgate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "contract-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
if [ "${WALTEUR_CONTRACT:-on}" = "off" ]; then
  echo "contract-gate: bypassed (WALTEUR_CONTRACT=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_CONTRACT=off" '{"bypassed":true}'
  exit 0
fi

# ── find machine-readable API spec(s) ─────────────────────────────────────────
# Prune VCS / dependency / build dirs so we don't trip on fixtures or vendored specs.
SPEC_FILE=""
find_spec() {
  # 1) Filename-based: openapi*/swagger*/.proto/schema.graphql.
  local f
  f="$(find "$ROOT" \
        \( -path "$ROOT/.git" -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/venv' \
           -o -path '*/dist' -o -path '*/build' -o -path "$KIT" \) -prune -o \
        \( -iname 'openapi*.yaml' -o -iname 'openapi*.yml' -o -iname 'openapi*.json' \
           -o -iname 'swagger*.yaml' -o -iname 'swagger*.yml' -o -iname 'swagger*.json' \
           -o -iname '*.proto' -o -iname 'schema.graphql' -o -iname '*.graphql' \) \
        -type f -print 2>/dev/null | head -1)"
  if [ -n "$f" ]; then SPEC_FILE="$f"; return 0; fi
  # 2) Content-based: any yaml/json declaring openapi:/swagger: at (near) top level.
  while IFS= read -r y; do
    [ -z "$y" ] && continue
    if grep -lqiE '^[[:space:]]*"?(openapi|swagger)"?[[:space:]]*:' "$y" 2>/dev/null; then
      SPEC_FILE="$y"; return 0
    fi
  done <<EOF
$(find "$ROOT" \
    \( -path "$ROOT/.git" -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/venv' \
       -o -path '*/dist' -o -path '*/build' -o -path "$KIT" \) -prune -o \
    \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) -type f -print 2>/dev/null)
EOF
  return 1
}
find_spec || true

# ── detect an explicitly DECLARED API surface ─────────────────────────────────
# PLAN-declared: a markdown line "surface: api" (the user's literal trigger). The .git, kit, and
# dependency dirs are excluded so we read the project's own plan, not a vendored one.
PLAN_DECLARES_API="no"
DECL_FILE=""
while IFS= read -r md; do
  [ -z "$md" ] && continue
  if grep -liE '^[[:space:]]*[-*]?[[:space:]]*surface[[:space:]]*:[[:space:]]*api\b' "$md" >/dev/null 2>&1; then
    PLAN_DECLARES_API="yes"; DECL_FILE="$md"; break
  fi
done <<EOF
$(find "$ROOT" \
    \( -path "$ROOT/.git" -o -path '*/node_modules' -o -path '*/.venv' -o -path "$KIT" \) -prune -o \
    -name '*.md' -type f -print 2>/dev/null)
EOF

# The build also "declares" an API simply by SHIPPING a spec artefact (proto/graphql/openapi).
API_DECLARED="no"
[ "$PLAN_DECLARES_API" = "yes" ] && API_DECLARED="yes"
[ -n "$SPEC_FILE" ] && API_DECLARED="yes"

# ── not applicable: no API anywhere ───────────────────────────────────────────
if [ "$API_DECLARED" = "no" ]; then
  echo "contract-gate: no API surface declared (no 'surface: api' in *.md, no openapi/swagger/proto/graphql) — gate not applicable." >&2
  if have jq; then
    write_report "NOT_APPLICABLE" "no API surface declared" \
      "$(jq -n '{api_declared:false, spec_found:false}')"
  else
    write_report "NOT_APPLICABLE" "no API surface declared" '{}'
  fi
  exit 0
fi

# ── ZERO-DEP HARD RULE: API declared but NO machine-readable spec => violation ─
if [ "$API_DECLARED" = "yes" ] && [ -z "$SPEC_FILE" ]; then
  echo "WALTEUR contract-gate: FAIL — an API surface is declared (${DECL_FILE:-spec artefact}) but NO machine-readable spec was found." >&2
  echo "  Required: an OpenAPI/Swagger (openapi*.{yaml,yml,json}), a *.proto, or schema.graphql." >&2
  echo "  An API without a machine-readable contract is forbidden by WALTEUR." >&2
  if have jq; then
    write_report "FAIL" "API declared but no machine-readable spec present" \
      "$(jq -n --arg df "${DECL_FILE:-}" \
        '{api_declared:true, spec_found:false, declared_by:(if ($df|length)>0 then $df else null end), rule:"declared-api-requires-spec"}')"
  else
    write_report "FAIL" "API declared but no machine-readable spec present" '{}'
  fi
  exit 2
fi

echo "WALTEUR contract-gate @ $ROOT — API declared, spec: $SPEC_FILE" >&2

# ── DETECT-OR-SKIP UPGRADE: spectral lint the spec ────────────────────────────
RULESET="$KIT/.spectral.yaml"
SPECTRAL_VERDICT="SKIP"
SPECTRAL_ERRORS=0
SPECTRAL_REASON=""

# Spectral only lints OpenAPI/Swagger/AsyncAPI — not raw .proto / .graphql. If the only spec found
# is a proto/graphql, the zero-dep rule is already satisfied; spectral lint does not apply.
is_lintable_spec() {
  case "$1" in
    *.proto|*.graphql) return 1 ;;
  esac
  # Must look like OpenAPI/Swagger by content OR by openapi*/swagger* filename.
  case "$(basename "$1" | tr 'A-Z' 'a-z')" in
    openapi*|swagger*) return 0 ;;
  esac
  grep -lqiE '^[[:space:]]*"?(openapi|swagger)"?[[:space:]]*:' "$1" 2>/dev/null && return 0
  return 1
}

if have spectral; then
  if is_lintable_spec "$SPEC_FILE"; then
    TMP="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"; trap 'rm -f "$TMP"' EXIT
    # Use our ruleset if present; else fall back to spectral's default resolution.
    if [ -f "$RULESET" ]; then
      spectral lint --ruleset "$RULESET" --format json "$SPEC_FILE" >"$TMP" 2>/dev/null || true
    else
      spectral lint --format json "$SPEC_FILE" >"$TMP" 2>/dev/null || true
    fi
    # Spectral severity: 0=error,1=warn,2=info,3=hint. Count ERROR (severity 0).
    if have jq; then
      SPECTRAL_ERRORS="$(jq '[.[] | select(.severity==0)] | length' "$TMP" 2>/dev/null || echo 0)"
    else
      # jq-less fallback: count "severity":0 occurrences.
      SPECTRAL_ERRORS="$(grep -o '"severity"[[:space:]]*:[[:space:]]*0' "$TMP" 2>/dev/null | wc -l | tr -d ' ')"
    fi
    [ -z "$SPECTRAL_ERRORS" ] && SPECTRAL_ERRORS=0
    if [ "$SPECTRAL_ERRORS" -gt 0 ]; then
      SPECTRAL_VERDICT="FAIL"
      SPECTRAL_REASON="$SPECTRAL_ERRORS spectral error-severity violation(s)"
      echo "  FAIL — spectral: $SPECTRAL_ERRORS error-severity violation(s) in $SPEC_FILE." >&2
    else
      SPECTRAL_VERDICT="PASS"
      SPECTRAL_REASON="no error-severity spectral violations"
      echo "  ok   — spectral: no error-severity violations in $SPEC_FILE." >&2
    fi
  else
    SPECTRAL_VERDICT="SKIP"
    SPECTRAL_REASON="spec is not OpenAPI/Swagger (proto/graphql) — spectral lint not applicable"
    echo "  SKIP — spectral lint not applicable to $SPEC_FILE (proto/graphql). Zero-dep spec rule already satisfied." >&2
  fi
else
  SPECTRAL_VERDICT="SKIP"
  SPECTRAL_REASON="spectral not installed"
  echo "  SKIP — spectral not installed. Zero-dep spec-presence rule PASSED; deep lint not run (recorded, NOT silent-green)." >&2
fi

# ── overall verdict ───────────────────────────────────────────────────────────
if [ "$SPECTRAL_VERDICT" = "FAIL" ]; then
  OVERALL="FAIL"
else
  OVERALL="PASS"   # zero-dep spec-presence rule satisfied; spectral PASS or SKIP
fi

if have jq; then
  write_report "$OVERALL" "$SPECTRAL_REASON" \
    "$(jq -n --arg sf "$SPEC_FILE" --arg sv "$SPECTRAL_VERDICT" --argjson se "$SPECTRAL_ERRORS" \
            --arg sr "$SPECTRAL_REASON" --arg df "${DECL_FILE:-}" \
      '{api_declared:true, spec_found:true, spec_file:$sf, declared_by:(if ($df|length)>0 then $df else null end),
        zero_dep_rule:"PASS",
        spectral:{verdict:$sv, error_severity_count:$se, reason:$sr}}')"
else
  write_report "$OVERALL" "$SPECTRAL_REASON" '{}'
fi

echo "contract-gate verdict: $OVERALL (spec=$SPEC_FILE, spectral=$SPECTRAL_VERDICT) -> $REPORT" >&2
[ "$OVERALL" = "FAIL" ] && exit 2
exit 0
