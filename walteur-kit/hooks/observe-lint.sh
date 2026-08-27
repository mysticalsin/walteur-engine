#!/usr/bin/env bash
# WALTEUR observe-lint — ZERO-DEP HARD gate on source files for observability anti-patterns.
# One finding = fail (exit 2). Clean = exit 0. No-op SKIP (exit 0) when no source files exist.
# Usage: bash walteur-kit/hooks/observe-lint.sh [dir]   (default: $ROOT)
#
# Scans .py .js .jsx .ts .tsx .go .rb .java for three observability sins:
#   R1  print() / console.log() / System.out used AS LOGGING outside a CLI/bin path.
#       Heuristic: a print/console.log/puts call in a file whose path is NOT under
#       cli/ bin/ scripts/ examples/ tools/ AND whose basename is not cli/main/__main__
#       (entrypoints legitimately print). These belong in a structured logger in app code.
#   R2  gauge-for-latency naming: a metric named like a gauge ("...latency..._gauge",
#       "gauge(...latency/duration/response_time...)", "Gauge(name='..._latency_...')").
#       Latency MUST be a histogram (percentiles), never a gauge/average. (Mirrors the
#       observability-contract.schema.json `metrics.latency_is_histogram` requirement.)
#   R3  PII-looking key interpolated INTO a log call: a log/print line that interpolates a
#       variable/field whose name matches email|ssn|password|passwd|secret|token|api_key|
#       credit_card|card_number — e.g.  logger.info(f"login {email}")  ·  console.log(`tok ${token}`)
#       ·  log.Printf("pw=%s", password)  ·  logger.info("user " + ssn).  PII must be redacted
#       BEFORE it reaches a log sink. (Mirrors `structured_logging.pii_redaction`.)
#   R4  Sentry DETECT-OR-SKIP: IF a Sentry dependency is declared (@sentry / sentry-sdk in
#       package.json/requirements.txt/go.mod/Gemfile), THEN source must contain a Sentry.init /
#       sentry_sdk.init call AND traces_sample_rate set to a value >= 0.1 AND at least one span/
#       transaction marker (Sentry.startSpan|startTransaction|start_span|@sentry tracing). Missing
#       any -> finding -> exit 2. No Sentry dep -> rule is N/A (skipped). (Mirrors `tracing`.)
#
# Zero-dep: bash + grep + awk + sed + jq + find only. HARD: real exit 2 on any finding.
# HONESTY: the tools used are always present, so a missing-tool SKIP only triggers if one is
#          genuinely absent. The applicability SKIP = "no source files" — honest, not silent-green.
# Bypass: WALTEUR_OBSERVE=off.
# Report: walteur-kit/observe-report.json  {verdict, ts, gate, dir, reason, files_scanned, details}.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "observe-lint - ZERO-DEP HARD gate on source files for observability anti-patterns."
  printf '%s\n' "usage: bash observe-lint.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/observe-report.json - fix recipes: walteur-kit/REMEDIATION.md (## observe-lint)"
  printf '%s\n' "bypass: WALTEUR_OBSERVE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/observe-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_report() { # $1=verdict  $2=reason  $3=findings-json-array  $4=scanned-count
  jq -n \
    --arg v "$1" --arg ts "$TS" --arg reason "$2" --arg dir "${DIR:-}" \
    --argjson findings "${3:-[]}" --argjson scanned "${4:-0}" \
    '{verdict:$v, ts:$ts, gate:"observe-lint", dir:$dir, reason:$reason,
      files_scanned:$scanned, details:$findings}' > "$REPORT"
}

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

  echo "observe-lint selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/observe-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no source -> SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/observe-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/cli"
  printf 'console.log(\"hello\");\n' > "$tmp/cli/main.js"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "CLI print allowed -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/observe-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  printf 'console.log(\"debug\");\n' > "$tmp/src/app.js"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "app console logging -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/observe-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  printf 'logger.info(`token ${token}`);\n' > "$tmp/src/app.js"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PII-looking token in log -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/observe-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/src"
  printf 'console.log(\"debug\");\n' > "$tmp/src/app.js"
  WALTEUR_ROOT="$tmp" WALTEUR_OBSERVE=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/observe-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "observe-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_OBSERVE:-on}" = "off" ] && { echo "observe-lint: bypassed (WALTEUR_OBSERVE=off)." >&2; write_report "SKIP" "bypassed (WALTEUR_OBSERVE=off)" '[]' 0; exit 0; }

# ── tool guard (zero-dep, but stay honest if a base tool is missing) ──────────
for t in grep awk sed jq find; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR observe-lint SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
    write_report "SKIP" "$t not installed" '[]' 0
    exit 0
  fi
done

DIR="${1:-$ROOT}"
if [ ! -d "$DIR" ]; then
  echo "WALTEUR observe-lint SKIP — '$DIR' is not a directory (nothing to scan)." >&2
  write_report "SKIP" "not a directory: $DIR" '[]' 0
  exit 0
fi

# ── collect source files (prune vendor/build/VCS dirs) ───────────────────────
FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$f")
done < <(find "$DIR" \
  \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' \
     -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/vendor/*' -o -path '*/.venv/*' \
     -o -path '*/venv/*' -o -path '*/target/*' -o -path '*/__pycache__/*' \) -prune -o \
  -type f \( -name '*.py' -o -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' \
             -o -name '*.go' -o -name '*.rb' -o -name '*.java' \) -print 2>/dev/null)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "WALTEUR observe-lint SKIP — no source files (.py/.js/.ts/.go/.rb/.java) under '$DIR'." >&2
  write_report "SKIP" "no source files found" '[]' 0
  exit 0
fi

declare -a FINDINGS_JSON=()
add() { # $1=file(rel)  $2=line  $3=rule  $4=message
  FINDINGS_JSON+=("$(jq -n --arg f "$1" --argjson ln "$2" --arg r "$3" --arg m "$4" \
    '{file:$f, line:$ln, rule:$r, message:$m}')")
}

# is_cli_path <relpath> -> 0 (true) if the file lives on a legitimate CLI/entrypoint path,
# where print()/console.log are an acceptable interface (not logging).
is_cli_path() {
  case "/$1" in
    */cli/*|*/bin/*|*/scripts/*|*/examples/*|*/tools/*|*/cmd/*) return 0 ;;
  esac
  case "$(basename "$1")" in
    cli.*|main.*|__main__.py|manage.py) return 0 ;;
  esac
  return 1
}

# trim leading line-number + colon from grep -n output and leading whitespace
clean_txt() { printf '%s' "$1" | sed -E 's/^[0-9]+://; s/^[[:space:]]+//'; }

PII_RE='email|e_mail|ssn|social_security|password|passwd|pwd|secret|api_key|apikey|access_token|auth_token|token|credit_card|card_number|cardnum|cvv'
# a logging/print call sink, language-agnostic
LOG_CALL_RE='(console\.(log|info|warn|error|debug)|print[[:space:]]*\(|println|printStackTrace|System\.(out|err)\.print|puts|p[[:space:]]*\(|log(ger)?\.[A-Za-z]+|logging\.[A-Za-z]+|fmt\.Print|log\.Print|Console\.Write|p?printf)'

for file in "${FILES[@]}"; do
  rel="${file#"$ROOT"/}"

  # ── R1: print()/console.log()/puts/System.out used as logging outside a CLI/bin path ──
  if ! is_cli_path "$rel"; then
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      ln="${hit%%:*}"; txt="$(clean_txt "$hit")"
      # skip obvious comment-only lines (best-effort: leading // # *)
      case "$txt" in \#*|//*|\**) continue ;; esac
      add "$rel" "$ln" "print-as-logging" "print/console.log used as logging in app code (use a structured logger): $txt"
    done < <(grep -niE '(^|[^A-Za-z0-9_.])(console\.(log|info|warn|error|debug)[[:space:]]*\(|print[[:space:]]*\(|println[[:space:]]*\(|System\.(out|err)\.print|puts[[:space:]])' "$file" 2>/dev/null || true)
  fi

  # ── R2: gauge-for-latency naming ──
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(clean_txt "$hit")"
    add "$rel" "$ln" "gauge-for-latency" "latency/duration recorded as a gauge (must be a histogram for percentiles): $txt"
  done < <(grep -niE '((latency|duration|response_time|resp_time|elapsed)[A-Za-z0-9_]*_gauge|gauge[A-Za-z0-9_]*_(latency|duration|response_time)|[Gg]auge[^A-Za-z0-9_]{0,4}.{0,40}(latency|duration|response_time|resp_time|request_seconds)|(latency|duration|response_time|resp_time).{0,40}[Gg]auge[(<])' "$file" 2>/dev/null || true)

  # ── R3: PII-looking key interpolated into a log/print call ──
  # f-strings / template literals: a log call line that contains {pii} or ${pii} or %(pii)s.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(clean_txt "$hit")"
    add "$rel" "$ln" "pii-in-log" "PII-looking value interpolated into a log call (redact before logging): $txt"
  done < <(grep -niE "$LOG_CALL_RE" "$file" 2>/dev/null \
            | grep -iE "(\{|\\\$\{|%\()[[:space:]]*[A-Za-z0-9_.]*($PII_RE)" || true)

  # printf-style + concatenation: a log call line naming a pii identifier as an argument,
  #   log.Printf("pw=%s", password)  ·  logger.info("user " + ssn)  ·  console.log("t", token)
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    ln="${hit%%:*}"; txt="$(clean_txt "$hit")"
    add "$rel" "$ln" "pii-in-log" "PII-looking value passed to a log call (redact before logging): $txt"
  done < <(grep -niE "$LOG_CALL_RE" "$file" 2>/dev/null \
            | grep -iE "(,|\+|%[sdv])[[:space:]]*[\"'\`]?[[:space:]]*[A-Za-z0-9_.]*($PII_RE)([^A-Za-z0-9_]|\$)" || true)
done

# ── R4: Sentry DETECT-OR-SKIP (repo-level) ───────────────────────────────────
# IF a Sentry dependency is declared (package.json/requirements.txt/go.mod/Gemfile),
# THEN require, somewhere in the scanned source, ALL of:
#   (a) an init call            Sentry.init( | sentry_sdk.init(
#   (b) tracing turned on       traces_sample_rate set to a value >= 0.1
#   (c) >=1 span/txn marker     Sentry.startSpan|startTransaction|start_span|@sentry tracing
# Missing any => finding(s) => exit 2.  No Sentry dep => N/A (rule skipped silently;
# R1/R2/R3 above already ran). This mirrors the observability-contract `tracing` block.
SENTRY_MANIFEST=""
for mf in package.json requirements.txt go.mod Gemfile; do
  for base in "$DIR" "$ROOT"; do
    cand="$base/$mf"
    [ -f "$cand" ] || continue
    if grep -qiE '@sentry|sentry-sdk|sentry-go|sentry-ruby|getsentry/sentry' "$cand" 2>/dev/null; then
      SENTRY_MANIFEST="$cand"; break
    fi
  done
  [ -n "$SENTRY_MANIFEST" ] && break
done

if [ -n "$SENTRY_MANIFEST" ]; then
  mrel="${SENTRY_MANIFEST#"$ROOT"/}"
  HAS_INIT=n; HAS_TRACING=n; HAS_SPAN=n
  for file in "${FILES[@]}"; do
    if [ "$HAS_INIT" = n ] && grep -qE '(Sentry\.init|sentry_sdk\.init|sentry\.Init)[[:space:]]*\(' "$file" 2>/dev/null; then HAS_INIT=y; fi
    # traces_sample_rate set to a numeric value >= 0.1 (covers 0.1..1.0 and whole 1+).
    if [ "$HAS_TRACING" = n ] && grep -niE 'traces[_-]?[Ss]ample[_-]?[Rr]ate[[:space:]]*[:=][[:space:]]*[0-9]' "$file" 2>/dev/null \
         | awk -F'[:=]' '{ for(i=NF;i>=1;i--){ if(match($i,/[0-9]+(\.[0-9]+)?/)){ v=substr($i,RSTART,RLENGTH); if(v+0>=0.1){print; exit} break } } }' \
         | grep -q . ; then HAS_TRACING=y; fi
    if [ "$HAS_SPAN" = n ] && grep -qiE 'Sentry\.startSpan|startTransaction|start_span|start_transaction|@sentry/tracing|sentry-tracing|sentry\.StartSpan' "$file" 2>/dev/null; then HAS_SPAN=y; fi
    [ "$HAS_INIT" = y ] && [ "$HAS_TRACING" = y ] && [ "$HAS_SPAN" = y ] && break
  done
  [ "$HAS_INIT" = y ]    || add "$mrel" 0 "sentry-no-init" "Sentry dependency declared but no Sentry.init/sentry_sdk.init call found in source."
  [ "$HAS_TRACING" = y ] || add "$mrel" 0 "sentry-no-tracing" "Sentry dependency declared but traces_sample_rate is not set to a value >= 0.1 (tracing effectively off)."
  [ "$HAS_SPAN" = y ]    || add "$mrel" 0 "sentry-no-span" "Sentry dependency declared but no span/transaction marker (startSpan/startTransaction/start_span/@sentry tracing) found in source."
fi

# de-duplicate findings (a line can match a regex twice across the two R3 passes)
SCANNED="${#FILES[@]}"
if [ "${#FINDINGS_JSON[@]}" -eq 0 ]; then
  write_report "PASS" "no observability anti-patterns found" '[]' "$SCANNED"
  echo "WALTEUR observe-lint: PASS — $SCANNED source file(s) scanned, zero anti-patterns." >&2
  exit 0
fi

FIND_JSON="$(printf '%s\n' "${FINDINGS_JSON[@]}" | jq -s 'unique_by({file,line,rule})')"
NFIND="$(printf '%s' "$FIND_JSON" | jq 'length')"
write_report "FAIL" "$NFIND observability finding(s)" "$FIND_JSON" "$SCANNED"
echo "WALTEUR observe-lint: FAIL — $NFIND finding(s) across $SCANNED file(s):" >&2
printf '%s' "$FIND_JSON" | jq -r '.[] | "  [\(.rule)] \(.file):\(.line)  \(.message)"' >&2
exit 2
