#!/usr/bin/env bash
# WALTEUR config-validation — ZERO-DEP HARD gate on configuration hygiene.
# Tools: bash + grep + find + awk + sed only (always present) => this is a real exit-2 gate,
#        not a detect-or-skip gate. The only honest SKIP is "no app source code to scan".
#
# Two checks:
#   C1  RAW-ENV ACCESS WITHOUT A VALIDATED CONFIG MODULE.
#       Flags app code that reads config DIRECTLY from the process environment
#       (process.env.X / os.environ / os.getenv / Deno.env.get / ENV[...]) when the repo has
#       NO typed/validated config layer. Validation heuristic — repo is OK if ANY of:
#         JS/TS : envalid | zod (env schema) | t3-oss/env | @t3-env | znv | convict | dotenv-safe
#         Python: pydantic-settings | BaseSettings | environs | dynaconf | django-environ
#         Go    : spf13/viper | kelseyhightower/envconfig | caarlos0/env
#       Raw access is allowed *inside* the validated config module file itself (that file is
#       the one legitimate place env vars are read). Raw access ELSEWHERE with no module => FAIL.
#       If raw access exists AND no validated module exists anywhere => FAIL (exit 2).
#
#   C2  COMMITTED .env WITH REAL-LOOKING SECRETS.
#       A tracked (git-committed, or present-and-not-gitignored) .env / .env.* file (excluding
#       .env.example / .env.sample / .env.template / .env.dist) that contains a value resembling
#       a real secret (high-entropy token, known key prefix, or KEY/SECRET/TOKEN/PASSWORD=<value>)
#       => FAIL (exit 2). Placeholder values (changeme, xxx, <...>, your-..., empty) are ignored.
#
# Report: walteur-kit/config-report.json {verdict, ts, gate, checks, violations, details}.
# Bypass: WALTEUR_CONFIG=off.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "config-validation - ZERO-DEP HARD gate on configuration hygiene."
  printf '%s\n' "usage: bash config-validation.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/config-report.json - fix recipes: walteur-kit/REMEDIATION.md (## config-validation)"
  printf '%s\n' "bypass: WALTEUR_CONFIG=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/config-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

selftest() {
  local pass=0 fail=0 tmp rc
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  ck() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  echo "config-validation selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/config-validation-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no source and no env -> SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/config-validation-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  printf 'console.log(process.env.API_KEY);\n' > "$tmp/src/app.js"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "raw env without validated config -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/config-validation-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  printf '{"dependencies":{"zod":"latest"}}\n' > "$tmp/package.json"
  printf 'console.log(process.env.API_KEY);\n' > "$tmp/src/app.js"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "raw env with validated config dependency -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/config-validation-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'API_KEY=sk-1234567890ABCDEFGHIJKLMNOP\n' > "$tmp/.env"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "real-looking committed .env secret -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/config-validation-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'API_KEY=changeme\n' > "$tmp/.env.example"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "example env placeholder -> PASS" 0 "$?"
  rm -rf "$tmp"

  echo "config-validation selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_CONFIG:-on}" = "off" ] && { echo "config-validation: bypassed (WALTEUR_CONFIG=off)." >&2; exit 0; }

# Zero-dep tool guard: even our baseline tools — if one is missing, SKIP loudly (honest, recorded).
for t in grep find awk sed; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR config-validation SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg ts "$TS" --arg t "$t" '{verdict:"SKIP", ts:$ts, gate:"config", reason:($t+" not installed")}' > "$REPORT"
    else
      printf '{"verdict":"SKIP","ts":"%s","gate":"config","reason":"%s not installed"}\n' "$TS" "$t" > "$REPORT"
    fi
    exit 0
  fi
done
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

PRUNE=( -path "$ROOT/.git" -o -path "$ROOT/node_modules" -o -path "$ROOT/.git/*" \
        -o -path "$ROOT/dist" -o -path "$ROOT/build" -o -path "$ROOT/vendor" \
        -o -path "$ROOT/.venv" -o -path "$ROOT/venv" -o -path "$ROOT/walteur-kit" )

# ── gather app source files (JS/TS/Python/Go) ─────────────────────────────────
SRC_LIST="$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \
  \( -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' -o -name '*.mjs' -o -name '*.cjs' \
     -o -name '*.py' -o -name '*.go' \) -type f -print 2>/dev/null)"

# applicability: no source to scan => SKIP (honest "nothing to validate"). But still run C2
# (committed-secret check) because a leaked .env is a problem even in a docs-only repo.
HAS_SRC=0; [ -n "$SRC_LIST" ] && HAS_SRC=1

is_gitignored() { git -C "$ROOT" check-ignore -q "$1" 2>/dev/null; }

violations=0
findings='[]'
add_finding() { # $1=check $2=file $3=line(int or 0) $4=message
  if [ "$HAVE_JQ" -eq 1 ]; then
    findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg f "$2" --argjson ln "$3" --arg m "$4" \
      '. + [{check:$c, file:$f, line:$ln, message:$m}]')"
  fi
}
rel() { printf '%s' "${1#"$ROOT"/}"; }

echo "WALTEUR config-validation @ $ROOT (sources=${HAS_SRC})" >&2

# ── C1: raw env access without a validated config module ──────────────────────
C1_VERDICT="SKIP"
if [ "$HAS_SRC" -eq 1 ]; then
  C1_VERDICT="PASS"
  # Detect a validated config layer. Search dependency manifests AND source for the libraries,
  # and source for the framework idioms (BaseSettings/viper.New/envconfig.Process).
  MANIFESTS="$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \
    \( -name 'package.json' -o -name 'requirements*.txt' -o -name 'pyproject.toml' -o -name 'Pipfile' \
       -o -name 'go.mod' -o -name 'go.sum' \) -type f -print 2>/dev/null)"

  VALIDATED=0
  # JS/TS libs
  JS_LIB_RE='envalid|"zod"|@t3-oss/env|@t3-env|t3-env|\bznv\b|\bconvict\b|dotenv-safe|zod-config'
  # Python libs / idioms
  PY_LIB_RE='pydantic-settings|pydantic_settings|BaseSettings|\benvirons\b|\bdynaconf\b|django-environ|\benviron\(\)'
  # Go libs / idioms
  GO_LIB_RE='spf13/viper|kelseyhightower/envconfig|caarlos0/env|envconfig\.Process|viper\.(New|GetString|BindEnv)'

  # Search manifests first (cheap), then source.
  if [ -n "$MANIFESTS" ] && printf '%s\n' "$MANIFESTS" | tr '\n' '\0' | xargs -0 grep -lEi "$JS_LIB_RE|$PY_LIB_RE|$GO_LIB_RE" >/dev/null 2>&1; then
    VALIDATED=1
  fi
  # The file(s) that constitute the validated module (so we don't flag legit env reads inside them).
  MODULE_FILES=""
  if [ "$VALIDATED" -eq 0 ] || true; then
    MODULE_FILES="$(printf '%s\n' "$SRC_LIST" | tr '\n' '\0' \
      | xargs -0 grep -lEi "$JS_LIB_RE|$PY_LIB_RE|$GO_LIB_RE" 2>/dev/null || true)"
    [ -n "$MODULE_FILES" ] && VALIDATED=1
  fi

  # Raw env-access idioms across the four languages.
  RAW_RE='process\.env\.[A-Za-z_]|process\.env\[|os\.environ\[|os\.environ\.get|os\.getenv|Deno\.env\.get|ENV\[|getenv\('

  # Find files with raw access, excluding the validated module files.
  RAW_HITS=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # skip the module file itself — that is the one place env reads belong
    skip=0
    if [ -n "$MODULE_FILES" ]; then
      while IFS= read -r mf; do [ "$f" = "$mf" ] && { skip=1; break; }; done <<EOF
$MODULE_FILES
EOF
    fi
    [ "$skip" -eq 1 ] && continue
    # also skip config-ish module filenames by convention (config/env loaders) — they may define schema
    case "$(basename "$f")" in
      env.ts|env.js|env.mjs|config.ts|config.js|settings.py|config.py|env.go|config.go) cfgish=1 ;;
      *) cfgish=0 ;;
    esac
    line="$(grep -nE "$RAW_RE" "$f" 2>/dev/null | head -1 || true)"
    [ -z "$line" ] && continue
    # if there's a validated module anywhere, a config-ish file reading env is acceptable
    if [ "$VALIDATED" -eq 1 ] && [ "$cfgish" -eq 1 ]; then continue; fi
    RAW_HITS="$RAW_HITS$f"$'\n'
    ln="${line%%:*}"
    add_finding C1 "$(rel "$f")" "$ln" "raw env access ($(printf '%s' "${line#*:}" | sed -E 's/^[[:space:]]+//' | cut -c1-80))"
  done <<EOF
$SRC_LIST
EOF

  if [ -n "${RAW_HITS//[[:space:]]/}" ] && [ "$VALIDATED" -eq 0 ]; then
    n="$(printf '%s' "$RAW_HITS" | grep -c . || echo 0)"
    echo "  FAIL — C1: $n file(s) read config directly from the environment and NO validated config module (envalid/zod-env/pydantic-settings/viper) exists." >&2
    printf '%s' "$RAW_HITS" | grep . | while IFS= read -r f; do echo "         · $(rel "$f")" >&2; done
    violations=$((violations+1))
    C1_VERDICT="FAIL"
  elif [ -n "${RAW_HITS//[[:space:]]/}" ] && [ "$VALIDATED" -eq 1 ]; then
    echo "  ok   — C1: raw env access present but a validated config module exists (env reads should route through it; advisory)." >&2
    C1_VERDICT="PASS"
  else
    echo "  ok   — C1: no unguarded raw env access (validated module=${VALIDATED})." >&2
    C1_VERDICT="PASS"
  fi
else
  echo "  SKIP — C1: no JS/TS/Python/Go source files to scan." >&2
fi

# ── C2: committed .env with real-looking secrets ──────────────────────────────
C2_VERDICT="PASS"
ENV_FILES="$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \
  \( -name '.env' -o -name '.env.*' \) -type f -print 2>/dev/null)"

c2_flagged=0
while IFS= read -r ef; do
  [ -z "$ef" ] && continue
  base="$(basename "$ef")"
  # exclude example/template files — those SHOULD be committed.
  case "$base" in
    .env.example|.env.sample|.env.template|.env.dist|.env.local.example|*.example|*.sample|*.template) continue ;;
  esac
  # only care about files that are committed OR present-and-not-gitignored (i.e. would be committed).
  if is_gitignored "$ef"; then continue; fi
  # scan KEY=VALUE lines for a real-looking secret value.
  # Strategy: take lines that look secret-bearing by key name OR by value shape; reject placeholders.
  while IFS= read -r kvline; do
    [ -z "$kvline" ] && continue
    key="$(printf '%s' "$kvline" | sed -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/')"
    val="$(printf '%s' "$kvline" | sed -E 's/^[^=]*=[[:space:]]*//; s/^["'"'"']//; s/["'"'"'][[:space:]]*$//')"
    [ -z "$val" ] && continue
    # placeholder rejection (case-insensitive)
    if printf '%s' "$val" | grep -qiE '^(changeme|change-me|placeholder|example|test|dummy|xxx+|todo|none|null|true|false|0|1|<.*>|\$\{.*\}|your[-_].*|my[-_].*|replace[-_].*)$'; then
      continue
    fi
    secretish_key=0
    printf '%s' "$key" | grep -qiE '(SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE_KEY|API[_-]?KEY|ACCESS[_-]?KEY|CLIENT_SECRET|AUTH|CREDENTIAL|DSN|CONNECTION_STRING)' && secretish_key=1
    realish_val=0
    # known provider prefixes
    if printf '%s' "$val" | grep -qE '(sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.)'; then
      realish_val=1
    fi
    # high-entropy-ish token: long, mixed case+digits, no spaces
    if printf '%s' "$val" | grep -qE '^[A-Za-z0-9+/_=-]{24,}$' && printf '%s' "$val" | grep -q '[0-9]' && printf '%s' "$val" | grep -q '[A-Za-z]'; then
      realish_val=1
    fi
    if [ "$realish_val" -eq 1 ] || { [ "$secretish_key" -eq 1 ] && [ "${#val}" -ge 8 ] && printf '%s' "$val" | grep -qE '[^[:space:]]'; }; then
      [ "$c2_flagged" -eq 0 ] && echo "  FAIL — C2: committed .env file(s) contain real-looking secret value(s)." >&2
      echo "         · $(rel "$ef"): ${key}=<redacted>" >&2
      add_finding C2 "$(rel "$ef")" 0 "committed secret-bearing key: ${key} (value redacted)"
      c2_flagged=1
    fi
  done < <(grep -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "$ef" 2>/dev/null)
done <<EOF
$ENV_FILES
EOF

if [ "$c2_flagged" -eq 1 ]; then
  violations=$((violations+1))
  C2_VERDICT="FAIL"
else
  echo "  ok   — C2: no committed .env with real-looking secrets." >&2
fi

# ── overall verdict ───────────────────────────────────────────────────────────
if [ "$violations" -gt 0 ]; then
  OVERALL=FAIL
elif [ "$HAS_SRC" -eq 0 ] && [ -z "$ENV_FILES" ]; then
  OVERALL=SKIP   # nothing to validate at all
else
  OVERALL=PASS
fi

if [ "$HAVE_JQ" -eq 1 ]; then
  jq -n --arg v "$OVERALL" --arg ts "$TS" --arg c1 "$C1_VERDICT" --arg c2 "$C2_VERDICT" \
        --argjson viol "$violations" --argjson det "$findings" \
    '{verdict:$v, ts:$ts, gate:"config",
      checks:{C1_raw_env_no_validation:$c1, C2_committed_env_secrets:$c2},
      violations:$viol, details:$det}' > "$REPORT"
else
  printf '{"verdict":"%s","ts":"%s","gate":"config","checks":{"C1":"%s","C2":"%s"},"violations":%s}\n' \
    "$OVERALL" "$TS" "$C1_VERDICT" "$C2_VERDICT" "$violations" > "$REPORT"
fi

echo "config-validation verdict: $OVERALL (C1=$C1_VERDICT, C2=$C2_VERDICT, violations=$violations) -> $REPORT" >&2
[ "$OVERALL" = "FAIL" ] && exit 2
exit 0
