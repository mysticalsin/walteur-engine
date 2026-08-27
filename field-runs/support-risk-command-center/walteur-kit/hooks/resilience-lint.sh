#!/usr/bin/env bash
# WALTEUR resilience-lint — ZERO-DEP HARD gate over source for resilience anti-patterns.
# Tools used: bash + grep + awk + sed + find only. These are ALWAYS present, so this is a HARD
# gate with a REAL exit 2 on violation. The only honest SKIP is "required base tool missing"
# (grep/awk/sed/find) — recorded loudly, exit 0 — never silent-green.
#
# Rules (each a real violation -> exit 2):
#   R1  EMPTY CATCH / except-pass — a swallowed error:
#         - python : `except[...]:` whose body is only `pass` (next non-blank, deeper-indented line)
#         - js/ts  : `catch (e) {}` empty block, or a catch block whose only statement is `;`
#         - go     : `if err != nil { }` empty error-handling block
#   R2  NETWORK CALL WITH NO TIMEOUT — fetch()/requests/http client call with no timeout/signal
#       configured within a small window around the call:
#         - js/ts  : `fetch(` with no `signal:`/`AbortSignal`/`timeout` within +/- a few lines
#         - python : `requests.get|post|...(` or `httpx`/`urlopen(` with no `timeout=` nearby
#         - go     : `http.Get(`/`http.Post(`/`http.DefaultClient` with no Timeout/Context nearby
#   R3  FIXED-SLEEP RETRY WITH NO JITTER — a sleep inside an obvious retry loop, with a constant
#       (literal) delay and no randomness (no random/jitter/rand) anywhere near the loop:
#         - sleep(N) / time.sleep(N) / time.Sleep(<const>) sitting in a for/while/retry context.
#   R4  `throw new Error("string-literal")` in LIBRARY code (files under lib/ src/ packages/) —
#       opaque string-only errors with no typed error / cause. Heuristic, library paths only.
#   R5  BRITTLE E2E SELECTORS — in E2E/test specs (*.spec.ts, *.e2e.*, tests/e2e/**, or files that
#       import @playwright/test) flag selectors that break on any layout change:
#         - pixel/coordinate clicks: mouse.click(x,y) / click_at(...) / page.mouse.* with numeric coords
#         - deep nth-child chains: a CSS selector with >=3 '>' combinators, or repeated ':nth-child'
#         - absolute XPath: //div[1]/div[2]-style positional paths
#       Recommend getByRole / getByTestId / data-testid. Additive to R3; spec files only.
#
# Silent-failure rules (v9.2 #13 — WARNING-FIRST: a real finding -> a LOUD WARN, but exit 0 by default;
#   they do NOT block. They are HARD (exit 2) ONLY when WALTEUR_RESILIENCE_SILENT=hard is set. The
#   structural ones (R6 js/py, R8) are ALSO backed by ast-grep severity:warning rules — when ast-grep is
#   on PATH the AST pass emits the same finding more precisely; ast-grep exits 0 on a warning, so the
#   preamble never blocks. The grep/awk arms below are the zero-dep floor for when ast-grep is ABSENT.):
#   R6  INDISTINGUISHABLE FALLBACK — a catch/except whose body just `return`s an empty value
#       (null/undefined/0/[]/{} in js; None/0/[]/{} in py) with NO log call and NO re-throw/re-raise.
#       The caller can't tell a real empty result from a swallowed failure. (AST: return-in-catch-*.yml)
#   R7  `|| true` / MISSING `set -e` — shell scripts (*.sh / #! .../sh|bash) that mask command failure:
#         - a `<cmd> || true` (or `|| :`) that throws away a non-zero exit
#         - a script with NO `set -e` / `set -euo pipefail` and >=10 command lines (errors flow past)
#       Shell-text heuristic (no AST — .sh files are not in the source-language set). Low false-positive.
#   R8  FLOATING EMPTY .catch() — a js/ts `.catch(() => {})` / `.catch(e => {})` / `.catch(function(){})`
#       whose handler body is empty: the promise rejection is swallowed (handled in name only).
#       (AST: floating-catch-js.yml. The grep/awk arm is the zero-dep floor.)
#
# Scope: scans tracked/source files under ROOT, skipping vendor/build/test/min dirs. Test files
#        are excluded from R1/R4/R6/R8 (test code legitimately swallows / throws string errors).
#        R7 scans shell scripts (separate enumeration).
# Report: walteur-kit/resilience-report.json  {verdict, ts, gate, violations, details[], warnings, warn_details[]}.
# Bypass: WALTEUR_RESILIENCE=off.   Promote R6-R8 to HARD: WALTEUR_RESILIENCE_SILENT=hard.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
# ROOT honors WALTEUR_ROOT (used by --selftest for a hermetic temp tree); default is git-root/pwd —
# behavior-preserving: with WALTEUR_ROOT unset the path is identical to before.
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/resilience-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

# ── selftest: hermetic good/poisoned-twin verification of R6/R7/R8 (WARNING-FIRST) ───────────────
#   bash walteur-kit/hooks/resilience-lint.sh --selftest
# Runs the gate against a temp tree containing GOOD twins (must NOT warn) and POISONED twins (MUST warn),
# in the zero-dep grep/awk floor (WALTEUR_ASTGREP-independent — uses the floor by setting the AST backend
# aside via PATH is not needed; the floor always runs for warnings). Asserts: exit 0 by default (WARNING-
# FIRST never blocks), the report records the expected warnings, and WALTEUR_RESILIENCE_SILENT=hard
# promotes a poisoned tree to exit 2. Also asserts the GOOD twin produces ZERO R6/R7/R8 warnings.
selftest() {
  local fails=0 total=0 tmp rc warns
  ck() { # $1=label $2=want $3=got
    total=$((total+1))
    if [ "$3" = "$2" ]; then echo "  ok   — $1"
    else echo "  FAIL — $1 (want=$2, got=$3)"; fails=$((fails+1)); fi
  }
  # count warn_details with a given rule id in the report
  count_rule() { # $1=report $2=rule
    if command -v jq >/dev/null 2>&1; then
      jq --arg r "$2" '[.warn_details[]? | select(.rule==$r)] | length' "$1" 2>/dev/null || echo 0
    else
      grep -o "\"rule\":\"$2\"" "$1" 2>/dev/null | grep -c . 2>/dev/null || echo 0
    fi
  }
  echo "resilience-lint selftest (R6/R7/R8 silent-failure, WARNING-FIRST):"

  # ── POISONED tree: one R6-js, one R6-py, one R7, one R8 — all must WARN, exit 0 by default ──────
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/reslint-selftest.XXXXXX")"
  mkdir -p "$tmp/src"
  cat > "$tmp/src/bad.js" << 'JS'
function load() { try { return work(); } catch (e) { return null; } }
function ping() { doThing().catch(() => {}); }
function pong() { doOther().catch(function() {}); }
JS
  cat > "$tmp/src/bad.py" << 'PY'
def load():
    try:
        return work()
    except Exception:
        return []
PY
  cat > "$tmp/deploy.sh" << 'SH'
#!/usr/bin/env bash
echo one
echo two
risky_command || true
echo three
echo four
echo five
echo six
echo seven
echo eight
echo nine
echo ten
SH
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_RESILIENCE=on bash "$SELF" >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  ck "poisoned: WARNING-FIRST default -> exit 0 (non-blocking)" 0 "$rc"
  local rep="$tmp/walteur-kit/resilience-report.json"
  ck "poisoned: >=1 R6 warning recorded" 1 "$([ "$(count_rule "$rep" R6)" -ge 1 ] && echo 1 || echo 0)"
  ck "poisoned: >=1 R7 warning recorded" 1 "$([ "$(count_rule "$rep" R7)" -ge 1 ] && echo 1 || echo 0)"
  ck "poisoned: >=1 R8 warning recorded" 1 "$([ "$(count_rule "$rep" R8)" -ge 1 ] && echo 1 || echo 0)"

  # ── same POISONED tree with WALTEUR_RESILIENCE_SILENT=hard -> exit 2 ────────────────────────────
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_RESILIENCE=on WALTEUR_RESILIENCE_SILENT=hard bash "$SELF" >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  ck "poisoned + SILENT=hard -> exit 2 (armed HARD)" 2 "$rc"
  rm -rf "$tmp"

  # ── GOOD tree: handlers that log/re-raise/return real fallbacks — must produce ZERO R6/R7/R8 ────
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/reslint-selftest.XXXXXX")"
  mkdir -p "$tmp/src"
  cat > "$tmp/src/good.js" << 'JS'
function load() { try { return work(); } catch (e) { console.error(e); return cachedValue; } }
function ping() { doThing().catch((e) => { report(e); }); }
JS
  cat > "$tmp/src/good.py" << 'PY'
def load():
    try:
        return work()
    except Exception as e:
        log.error("failed", exc_info=e)
        raise
PY
  cat > "$tmp/deploy.sh" << 'SH'
#!/usr/bin/env bash
set -euo pipefail
echo one
echo two
echo three
SH
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_RESILIENCE=on bash "$SELF" >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  ck "good: exit 0" 0 "$rc"
  rep="$tmp/walteur-kit/resilience-report.json"
  warns="$( (command -v jq >/dev/null 2>&1 && jq '.warnings // 0' "$rep" 2>/dev/null) || echo 0)"
  ck "good: zero R6 warnings" 0 "$(count_rule "$rep" R6)"
  ck "good: zero R7 warnings" 0 "$(count_rule "$rep" R7)"
  ck "good: zero R8 warnings" 0 "$(count_rule "$rep" R8)"
  rm -rf "$tmp"

  # ── BYPASS / PAUSED behavior-preserving sanity ─────────────────────────────────────────────────
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/reslint-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_RESILIENCE=off bash "$SELF" >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  ck "bypass: WALTEUR_RESILIENCE=off -> exit 0" 0 "$rc"
  touch "$tmp/walteur-kit/PAUSED"
  set +e
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  ck "PAUSED -> exit 2" 2 "$rc"
  rm -rf "$tmp"

  echo "resilience-lint selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_RESILIENCE:-on}" = "off" ] && { echo "resilience-lint: bypassed (WALTEUR_RESILIENCE=off)." >&2; exit 0; }

# write_report <verdict> <reason> <findings-json-array> [<warn-findings-json-array>]
write_report() {
  local arr="$3"; local warr="${4:-[]}"
  [ -z "$arr" ]  && arr='[]'
  [ -z "$warr" ] && warr='[]'
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg v "$1" --arg ts "$TS" --arg reason "$2" --argjson f "$arr" --argjson w "$warr" \
      '{verdict:$v, ts:$ts, gate:"resilience", reason:$reason, violations:($f|length), details:$f,
        warnings:($w|length), warn_details:$w}' > "$REPORT"
  else
    # jq is not in the mandated zero-dep set; emit valid minimal JSON without it.
    local n; n="$(printf '%s' "$arr"  | grep -o '"rule"' | grep -c . 2>/dev/null || echo 0)"
    local m; m="$(printf '%s' "$warr" | grep -o '"rule"' | grep -c . 2>/dev/null || echo 0)"
    printf '{"verdict":"%s","ts":"%s","gate":"resilience","reason":"%s","violations":%s,"details":%s,"warnings":%s,"warn_details":%s}\n' \
      "$1" "$TS" "$2" "$n" "$arr" "$m" "$warr" > "$REPORT"
  fi
}

# ── base-tool guard: the only honest SKIP path ───────────────────────────────
for t in grep awk sed find; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR resilience-lint SKIP — required base tool '$t' not installed (recorded, not silent-green)." >&2
    write_report "SKIP" "$t not installed" "[]"
    exit 0
  fi
done

# ── OPT-IN AST backend (ADDITIVE: AST finding => FAIL exit 2; AST-clean OR ast-grep absent => fall
#    through to the zero-dep grep/awk floor below, so R1..R5 coverage is never lost). ──────────────
if [ -f "$(dirname "$0")/_ast-grep-preamble.sh" ]; then
  . "$(dirname "$0")/_ast-grep-preamble.sh"
  walteur_astgrep_pass "$KIT/sgconfig.yml" "$ROOT" "resilience-lint"
  _ag_rc=$?
  if [ "$_ag_rc" -eq 2 ]; then
    write_report "FAIL" "ast-grep AST backend: resilience anti-pattern(s) found (see stderr)" "[]"
    exit 2
  fi
  # _ag_rc 0 (AST clean) or 100 (AST absent/errored) -> continue to the grep/awk floor (no coverage lost).
fi

echo "WALTEUR resilience-lint @ $ROOT (zero-dep HARD gate)" >&2

# ── source file enumeration ──────────────────────────────────────────────────
# Skip vendor/build/cache/minified dirs and minified bundles.
list_src() { # $1 = -iname expr alternation already built into find call below
  find "$ROOT" \
    \( -path '*/.git'           -o -path '*/node_modules'   -o -path '*/vendor' \
       -o -path '*/dist'        -o -path '*/build'          -o -path '*/.next' \
       -o -path '*/target'      -o -path '*/__pycache__'    -o -path '*/.venv' \
       -o -path '*/venv'        -o -path '*/.mypy_cache'    -o -path '*/coverage' \
       -o -path '*/walteur-kit' \) -prune -o \
    -type f \( -name '*.py' -o -name '*.js' -o -name '*.jsx' -o -name '*.ts' \
       -o -name '*.tsx' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.go' \) \
    ! -name '*.min.js' ! -name '*.bundle.js' \
    -print 2>/dev/null
}

# Is a file a test file? (excluded from R1/R4)
is_test() { case "$1" in
  */test/*|*/tests/*|*/__tests__/*|*_test.py|*_test.go|*.test.js|*.test.ts|*.test.jsx|*.test.tsx|*.spec.js|*.spec.ts|*.spec.jsx|*.spec.tsx|*/conftest.py) return 0;;
  *) return 1;; esac; }

# Is a file library code? (R4 applies only here)
is_lib() { case "$1" in
  */lib/*|*/src/*|*/packages/*) return 0;;
  *) return 1;; esac; }

# Is a file an E2E/test spec? (R5 applies only here). Path-based signals OR a @playwright/test import.
is_spec() {
  case "$1" in
    *.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx|*.spec.mjs|*.spec.cjs) return 0;;
    *.e2e.ts|*.e2e.tsx|*.e2e.js|*.e2e.jsx|*.e2e.mjs|*.e2e.cjs) return 0;;
    *.e2e.spec.ts|*.e2e.spec.js) return 0;;
    */tests/e2e/*|*/test/e2e/*|*/e2e/*) return 0;;
  esac
  grep -qE "from[[:space:]]+['\"]@playwright/test['\"]|require\(['\"]@playwright/test['\"]\)" "$1" 2>/dev/null && return 0
  return 1
}

# JSON escaping for arbitrary text (snippets can contain quotes/backslashes/tabs).
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r//g'
}

FINDINGS=()                # HARD findings (R1..R5) -> exit 2
add_finding() {            # $1=rule $2=file(rel) $3=line $4=message $5=snippet
  local rf; rf="${2#"$ROOT"/}"
  FINDINGS+=("$(printf '{"rule":"%s","file":"%s","line":%s,"message":"%s","snippet":"%s"}' \
    "$1" "$(json_escape "$rf")" "$3" "$(json_escape "$4")" "$(json_escape "$5")")")
}

WARN_FINDINGS=()           # WARNING-FIRST findings (R6..R8) -> LOUD WARN, exit 0 (unless _SILENT=hard)
add_warn() {               # $1=rule $2=file(rel) $3=line $4=message $5=snippet
  local rf; rf="${2#"$ROOT"/}"
  WARN_FINDINGS+=("$(printf '{"rule":"%s","file":"%s","line":%s,"message":"%s","snippet":"%s"}' \
    "$1" "$(json_escape "$rf")" "$3" "$(json_escape "$4")" "$(json_escape "$5")")")
}

# ── per-file analysis driven by awk (one pass per rule family) ───────────────
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in *.py) lang=py;; *.go) lang=go;; *) lang=js;; esac
  testf=0; is_test "$f" && testf=1
  libf=0;  is_lib  "$f" && libf=1
  specf=0; is_spec "$f" && specf=1

  # R1 — EMPTY CATCH / except-pass ------------------------------------------------
  if [ "$testf" -eq 0 ]; then
    while IFS=$'\t' read -r ln msg snip; do
      [ -z "$ln" ] && continue
      add_finding "R1" "$f" "$ln" "$msg" "$snip"
    done < <(awk -v lang="$lang" '
      function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
      function indent(s,  i){ i=match(s,/[^ \t]/); return (i? i-1 : 0) }
      {
        line[NR]=$0
      }
      END {
        for (i=1;i<=NR;i++){
          s=line[i]; t=trim(s)
          if (lang=="py") {
            # except ...: with body that is only pass
            if (t ~ /^except([ (].*)?:[ \t]*(#.*)?$/) {
              ind=indent(s)
              # find next non-blank, non-comment line
              j=i+1
              while (j<=NR){
                nt=trim(line[j])
                if (nt=="" || nt ~ /^#/) { j++; continue }
                break
              }
              if (j<=NR){
                nind=indent(line[j]); nt=trim(line[j])
                # body deeper-indented and the FIRST body stmt is bare pass
                if (nind>ind && nt=="pass") {
                  # ensure it is the ONLY body statement (next sibling dedents)
                  k=j+1; only=1
                  while (k<=NR){
                    kt=trim(line[k])
                    if (kt=="" || kt ~ /^#/){ k++; continue }
                    if (indent(line[k])>=nind) only=0
                    break
                  }
                  if (only) printf "%d\t%s\t%s\n", i, "empty except: body is only pass (swallowed error)", trim(s)
                }
              }
            }
          } else if (lang=="js") {
            # catch (...) {}   or   catch {}   empty block on one line
            # Anchor: must NOT be preceded by `.` (member-access .catch belongs to R8, not R1)
            if (t ~ /(^|[^.A-Za-z0-9_$])catch[ \t]*(\([^)]*\))?[ \t]*\{[ \t]*\}/) {
              printf "%d\t%s\t%s\n", i, "empty catch block (swallowed error)", trim(s)
            }
            else if (t ~ /(^|[^.A-Za-z0-9_$])catch[ \t]*(\([^)]*\))?[ \t]*\{[ \t]*$/) {
              # multi-line: next non-blank line closes the block (only "}" or ";")
              j=i+1
              while (j<=NR){ nt=trim(line[j]); if (nt==""){ j++; continue } break }
              if (j<=NR){
                nt=trim(line[j])
                if (nt=="}" || nt==";" || nt=="};") printf "%d\t%s\t%s\n", i, "empty catch block (swallowed error)", trim(s)
              }
            }
          } else if (lang=="go") {
            # if err != nil {}  empty error handling
            if (t ~ /if[ \t]+[A-Za-z0-9_]*err[A-Za-z0-9_]*[ \t]*!=[ \t]*nil[ \t]*\{[ \t]*\}/) {
              printf "%d\t%s\t%s\n", i, "empty error-handling block (if err != nil {})", trim(s)
            }
            else if (t ~ /if[ \t]+[A-Za-z0-9_]*err[A-Za-z0-9_]*[ \t]*!=[ \t]*nil[ \t]*\{[ \t]*$/) {
              j=i+1
              while (j<=NR){ nt=trim(line[j]); if (nt==""){ j++; continue } break }
              if (j<=NR){ nt=trim(line[j]); if (nt=="}") printf "%d\t%s\t%s\n", i, "empty error-handling block (if err != nil {})", trim(s) }
            }
          }
        }
      }
    ' "$f")
  fi

  # R2 — NETWORK CALL WITH NO TIMEOUT --------------------------------------------
  while IFS=$'\t' read -r ln msg snip; do
    [ -z "$ln" ] && continue
    add_finding "R2" "$f" "$ln" "$msg" "$snip"
  done < <(awk -v lang="$lang" '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    { line[NR]=$0 }
    END {
      WIN=4  # lines on each side to look for a timeout/signal config
      for (i=1;i<=NR;i++){
        s=line[i]; t=trim(s)
        iscall=0; what=""
        if (lang=="js") {
          if (t ~ /(^|[^A-Za-z0-9_.])fetch[ \t]*\(/ && t !~ /\/\// ) { iscall=1; what="fetch()" }
        } else if (lang=="py") {
          if (t ~ /requests\.(get|post|put|patch|delete|head|request)[ \t]*\(/) { iscall=1; what="requests call" }
          else if (t ~ /(httpx\.(get|post|put|patch|delete|request|Client|AsyncClient)|urlopen|urllib\.request\.urlopen)[ \t]*\(/) { iscall=1; what="http call" }
        } else if (lang=="go") {
          if (t ~ /http\.(Get|Post|PostForm|Head)[ \t]*\(/) { iscall=1; what="http call" }
          else if (t ~ /http\.DefaultClient/) { iscall=1; what="http.DefaultClient (no Timeout)" }
        }
        if (!iscall) continue
        # search the window for a timeout/signal/context-deadline marker
        lo=i-WIN; if(lo<1)lo=1; hi=i+WIN; if(hi>NR)hi=NR
        ok=0
        for (j=lo;j<=hi;j++){
          w=line[j]
          if (lang=="js" && w ~ /(signal[ \t]*:|AbortSignal|AbortController|timeout[ \t]*:|axios\.create|\.timeout\()/) { ok=1; break }
          if (lang=="py" && w ~ /timeout[ \t]*=/) { ok=1; break }
          if (lang=="go" && w ~ /(Timeout[ \t]*:|context\.WithTimeout|context\.WithDeadline|\.WithTimeout|http\.Client\{)/) { ok=1; break }
        }
        if (!ok) printf "%d\t%s\t%s\n", i, ("network " what " has no timeout/signal configured nearby"), t
      }
    }
  ' "$f")

  # R3 — FIXED-SLEEP RETRY WITH NO JITTER ----------------------------------------
  while IFS=$'\t' read -r ln msg snip; do
    [ -z "$ln" ] && continue
    add_finding "R3" "$f" "$ln" "$msg" "$snip"
  done < <(awk -v lang="$lang" '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    { line[NR]=$0 }
    END {
      WIN=8  # how far above the sleep to look for a loop/retry context, and around for jitter
      for (i=1;i<=NR;i++){
        s=line[i]; t=trim(s)
        # a sleep with a CONSTANT literal delay (no variable, no expression with rand)
        issleep=0; delay=""
        if (lang=="py") {
          if (match(t,/time\.sleep[ \t]*\([ \t]*[0-9]+(\.[0-9]+)?[ \t]*\)/)) { issleep=1 }
        } else if (lang=="go") {
          if (t ~ /time\.Sleep[ \t]*\([ \t]*[0-9]+[ \t]*\*[ \t]*time\.(Second|Millisecond|Minute)/ ) { issleep=1 }
          else if (t ~ /time\.Sleep[ \t]*\([ \t]*[0-9]+(\.[0-9]+)?[ \t]*\*/ ) { issleep=1 }
        } else { # js/ts
          if (t ~ /(setTimeout|sleep|delay)[ \t]*\([^,]*,[ \t]*[0-9]+[ \t]*\)/) { issleep=1 }
          else if (t ~ /(await[ \t]+)?(sleep|delay)[ \t]*\([ \t]*[0-9]+[ \t]*\)/) { issleep=1 }
        }
        if (!issleep) continue
        # require a retry/loop context within WIN lines ABOVE
        lo=i-WIN; if(lo<1)lo=1
        inloop=0
        for (j=lo;j<=i;j++){
          w=line[j]
          if (w ~ /(for[ \t(]|while[ \t(]|retr(y|ies)|attempt|backoff|reconnect|max_?retries|maxRetries)/) { inloop=1; break }
        }
        if (!inloop) continue
        # jitter/randomness anywhere in a wider window => OK (not a violation)
        lo2=i-WIN-4; if(lo2<1)lo2=1; hi2=i+4; if(hi2>NR)hi2=NR
        hasjitter=0
        for (j=lo2;j<=hi2;j++){
          w=line[j]
          if (w ~ /(jitter|random|rand\.|Random|Math\.random|secrets\.|np\.random|crypto\.getRandomValues|rand\()/) { hasjitter=1; break }
        }
        if (!hasjitter) printf "%d\t%s\t%s\n", i, "fixed-delay sleep in a retry loop with no jitter (thundering-herd risk)", t
      }
    }
  ' "$f")

  # R4 — throw new Error("string") in LIBRARY code (lib/ src/ packages/) ----------
  if [ "$libf" -eq 1 ] && [ "$testf" -eq 0 ] && [ "$lang" = "js" ]; then
    while IFS=$'\t' read -r ln msg snip; do
      [ -z "$ln" ] && continue
      add_finding "R4" "$f" "$ln" "$msg" "$snip"
    done < <(awk '
      function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
      {
        s=$0; t=trim(s)
        # throw new Error("...")  or  throw new Error(`...`)  — pure string literal, no template var, no cause
        if (t ~ /throw[ \t]+new[ \t]+Error[ \t]*\([ \t]*(["'"'"'`])/) {
          # exclude template literals that interpolate a variable (${...}) — those carry context
          if (t ~ /\$\{/) next
          # exclude when a cause/options object is passed: Error("x", { cause })
          if (t ~ /Error[ \t]*\([^)]*,[ \t]*\{/) next
          # comment line guard
          if (t ~ /^\/\//) next
          printf "%d\t%s\t%s\n", NR, "throw new Error(\"string\") in library code (use a typed error / include cause)", t
        }
      }
    ' "$f")
  fi

  # R5 — BRITTLE E2E SELECTORS (spec files only) ---------------------------------
  if [ "$specf" -eq 1 ]; then
    while IFS=$'\t' read -r ln msg snip; do
      [ -z "$ln" ] && continue
      add_finding "R5" "$f" "$ln" "$msg" "$snip"
    done < <(awk '
      function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
      {
        s=$0; t=trim(s)
        if (t ~ /^\/\//) next   # comment line guard

        # (a) pixel / coordinate clicks — numeric x,y passed to a click/mouse API
        if (t ~ /mouse\.click[ \t]*\([ \t]*[0-9]+(\.[0-9]+)?[ \t]*,[ \t]*[0-9]+/ \
            || t ~ /click_at[ \t]*\([ \t]*[0-9]+/ \
            || t ~ /\.mouse\.(move|down|up)[ \t]*\([ \t]*[0-9]+(\.[0-9]+)?[ \t]*,[ \t]*[0-9]+/) {
          printf "%d\t%s\t%s\n", NR, "pixel/coordinate click is brittle (use getByRole/getByTestId)", t
          next
        }

        # (b) deep nth-child chains — only inside an actual selector string (quoted), to avoid
        #     matching JS arrow funcs / comparisons. Count child combinators ">" and ":nth-child".
        if (match(t, /["'"'"'`][^"'"'"'`]*(>|:nth-child)[^"'"'"'`]*["'"'"'`]/)) {
          sel=substr(t, RSTART, RLENGTH)
          gt=gsub(/>/,">",sel)                 # identity replace; gsub returns the count
          nchild=gsub(/:nth-child/,":nth-child",sel)
          if (gt>=3 || nchild>=2) {
            printf "%d\t%s\t%s\n", NR, "deep nth-child/child-combinator chain is brittle (use data-testid)", t
            next
          }
        }

        # (c) absolute / positional XPath — //div[1]/div[2]-style paths
        if (t ~ /\/\/[A-Za-z*]+\[[0-9]+\]\/[A-Za-z*]+\[[0-9]+\]/) {
          printf "%d\t%s\t%s\n", NR, "absolute positional XPath is brittle (use getByRole/getByTestId)", t
          next
        }
      }
    ' "$f")
  fi

  # ── WARNING-FIRST silent-failure arms (R6, R8) — grep/awk FLOOR for when ast-grep is absent. ──
  # When ast-grep is on PATH the AST rules (severity:warning) already emitted these more precisely; this
  # floor exists so coverage is not lost in the zero-dep path. Findings -> add_warn (LOUD WARN, exit 0).

  # R6 — INDISTINGUISHABLE FALLBACK: a catch/except body whose first real statement just returns an
  #      empty value, with no log-call and no throw/raise inside the handler block. Excludes test files.
  if [ "$testf" -eq 0 ] && { [ "$lang" = "js" ] || [ "$lang" = "py" ]; }; then
    while IFS=$'\t' read -r ln msg snip; do
      [ -z "$ln" ] && continue
      add_warn "R6" "$f" "$ln" "$msg" "$snip"
    done < <(awk -v lang="$lang" '
      function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
      function indent(s,  i){ i=match(s,/[^ \t]/); return (i? i-1 : 0) }
      # is t a bare return of an EMPTY value? (null/undefined/0/[]/{} js ; None/0/[]/{} py)
      function empty_ret(t,  re){
        if (lang=="js") re="^return[ \t]+(null|undefined|0|\\[[ \t]*\\]|\\{[ \t]*\\})[ \t]*;?$"
        else            re="^return[ \t]+(None|0|\\[[ \t]*\\]|\\{[ \t]*\\})[ \t]*$"
        return (t ~ re)
      }
      { line[NR]=$0 }
      END {
        for (i=1;i<=NR;i++){
          s=line[i]; t=trim(s)
          if (lang=="js") {
            # single-line:  catch (e) { return null; }  — inline body with an empty-fallback return and
            # no other call/throw between the braces. Handles terse one-liners the multi-line gather misses.
            if (match(t, /catch[ \t]*(\([^)]*\))?[ \t]*\{[^{}]*\}/)) {
              body=substr(t, RSTART, RLENGTH)
              sub(/^catch[ \t]*(\([^)]*\))?[ \t]*\{/, "", body); sub(/\}[ \t]*$/, "", body)
              bt2=trim(body)
              if (empty_ret(bt2) \
                  && bt2 !~ /(console\.|logger?\.|log\.|\.error\(|\.warn\(|report\(|captureException|Sentry\.)/ \
                  && bt2 !~ /(^|[^A-Za-z_])throw([ \t]|$)/) {
                printf "%d\t%s\t%s\n", i, "catch returns an empty fallback with no log or re-throw (indistinguishable from a swallowed error)", t
                continue
              }
            }
            # catch (e) { ... }  — gather the multi-line handler block by brace depth (window 25 lines).
            if (t ~ /catch[ \t]*(\([^)]*\))?[ \t]*\{[ \t]*$/) {
              # collect lines until matching close brace (cap window at 25 lines)
              depth=0; started=0; hit=0; haslog=0; hasthrow=0; endi=i
              for (j=i; j<=NR && j<=i+25; j++){
                w=line[j]
                for (c=1;c<=length(w);c++){ ch=substr(w,c,1); if(ch=="{"){depth++;started=1} else if(ch=="}"){depth--} }
                bt=trim(w)
                if (j>i){
                  if (bt ~ /(console\.|logger?\.|log\.|\.error\(|\.warn\(|report\(|captureException|Sentry\.)/) haslog=1
                  if (bt ~ /(^|[^A-Za-z_])throw([ \t]|$)/) hasthrow=1
                  if (!hit && empty_ret(bt)) { hit=j }
                }
                if (started && depth<=0){ endi=j; break }
              }
              if (hit && !haslog && !hasthrow)
                printf "%d\t%s\t%s\n", hit, "catch returns an empty fallback with no log or re-throw (indistinguishable from a swallowed error)", trim(line[hit])
            }
          } else { # py
            # except[...]:  — gather the deeper-indented block beneath it.
            if (t ~ /^except([ (].*)?:[ \t]*(#.*)?$/) {
              ind=indent(s); hit=0; haslog=0; hasraise=0
              for (j=i+1; j<=NR; j++){
                bt=trim(line[j])
                if (bt=="" || bt ~ /^#/) continue
                if (indent(line[j])<=ind) break          # dedent -> handler ends
                if (bt ~ /\.(error|warning|warn|exception|critical|info|debug)\(|log(ger)?\.|print\(|report\(|capture/) haslog=1
                if (bt ~ /^raise(\b|$)/) hasraise=1
                if (!hit && empty_ret(bt)) hit=j
              }
              if (hit && !haslog && !hasraise)
                printf "%d\t%s\t%s\n", hit, "except returns an empty fallback with no log or re-raise (indistinguishable from a swallowed error)", trim(line[hit])
            }
          }
        }
      }
    ' "$f")
  fi

  # R8 — FLOATING EMPTY .catch(): `.catch(() => {})` / `.catch(e => {})` / `.catch(function(){})` whose
  #      handler body is empty. js/ts only; test files excluded.
  if [ "$testf" -eq 0 ] && [ "$lang" = "js" ]; then
    while IFS=$'\t' read -r ln msg snip; do
      [ -z "$ln" ] && continue
      add_warn "R8" "$f" "$ln" "$msg" "$snip"
    done < <(awk '
      function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
      {
        s=$0; t=trim(s)
        if (t ~ /^\/\//) next
        # .catch( <empty-arrow-or-fn> {} )  — empty body block (only whitespace or a lone ;)
        if (t ~ /\.catch[ \t]*\([ \t]*(\([^)]*\)|[A-Za-z_$][A-Za-z0-9_$]*)?[ \t]*=>[ \t]*\{[ \t]*;?[ \t]*\}[ \t]*\)/ \
            || t ~ /\.catch[ \t]*\([ \t]*function[ \t]*\([^)]*\)[ \t]*\{[ \t]*;?[ \t]*\}[ \t]*\)/) {
          printf "%d\t%s\t%s\n", NR, "empty .catch() handler — the promise rejection is swallowed (handled in name only)", t
        }
      }
    ' "$f")
  fi

done < <(list_src)

# ── R7 — `|| true` / MISSING `set -e` (shell scripts; WARNING-FIRST grep/awk floor, no AST) ──────────
# Separate enumeration: shell scripts are not in the js/py/go source set. A finding -> add_warn.
list_sh() {
  find "$ROOT" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/vendor' -o -path '*/dist' \
       -o -path '*/build' -o -path '*/.next' -o -path '*/target' -o -path '*/__pycache__' \
       -o -path '*/.venv' -o -path '*/venv' -o -path '*/coverage' -o -path '*/walteur-kit' \) -prune -o \
    -type f \( -name '*.sh' -o -name '*.bash' \) -print 2>/dev/null
}
while IFS= read -r f; do
  [ -z "$f" ] && continue
  # (a) `cmd || true` / `cmd || :` — masks a non-zero exit. Skip commented lines.
  while IFS=$'\t' read -r ln msg snip; do
    [ -z "$ln" ] && continue
    add_warn "R7" "$f" "$ln" "$msg" "$snip"
  done < <(awk '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    {
      t=trim($0)
      if (t ~ /^#/) next
      if (t ~ /\|\|[ \t]*(true|:)[ \t]*(#.*)?$/)
        printf "%d\t%s\t%s\n", NR, "`|| true` / `|| :` masks command failure (the non-zero exit is discarded)", t
    }
  ' "$f")
  # (b) script with NO `set -e` and >=10 command lines — errors flow past silently. One finding/file.
  if ! grep -qE '^[[:space:]]*set[[:space:]]+(-[a-z]*e[a-z]*|-o[[:space:]]+errexit)' "$f" 2>/dev/null; then
    cmdlines="$(grep -cvE '^[[:space:]]*(#|$)' "$f" 2>/dev/null || echo 0)"
    if [ "${cmdlines:-0}" -ge 10 ]; then
      add_warn "R7" "$f" 1 "shell script has no \`set -e\`/\`set -euo pipefail\` and ${cmdlines} command lines — a failing command does not stop the script" "$(head -1 "$f" 2>/dev/null)"
    fi
  fi
done < <(list_sh)

# ── assemble verdict ─────────────────────────────────────────────────────────
# Build a JSON array string from an already-JSON list passed on stdin (one element per line).
# Zero-dep, bash-3.2 safe (no namerefs — macOS /usr/bin/env bash is 3.2).
join_json() { # reads JSON-object lines on stdin -> one JSON array on stdout
  local out="[" first=1 fj
  while IFS= read -r fj; do
    [ -z "$fj" ] && continue
    if [ "$first" -eq 1 ]; then out="$out$fj"; first=0; else out="$out,$fj"; fi
  done
  echo "$out]"
}
print_lines() { # reads JSON-object lines on stdin -> pretty stderr lines; $1 = label prefix
  local fj r fl l m
  while IFS= read -r fj; do
    [ -z "$fj" ] && continue
    r="$(printf '%s' "$fj"  | sed -E 's/.*"rule":"([^"]*)".*/\1/')"
    fl="$(printf '%s' "$fj" | sed -E 's/.*"file":"([^"]*)".*/\1/')"
    l="$(printf '%s' "$fj"  | sed -E 's/.*"line":([0-9]+).*/\1/')"
    m="$(printf '%s' "$fj"  | sed -E 's/.*"message":"([^"]*)".*/\1/')"
    echo "  $1  $r  $fl:$l  $m" >&2
  done
}

N="${#FINDINGS[@]}"
W="${#WARN_FINDINGS[@]}"
ARR="[]";  [ "$N" -gt 0 ] && ARR="$(printf '%s\n' "${FINDINGS[@]}" | join_json)"
WARR="[]"; [ "$W" -gt 0 ] && WARR="$(printf '%s\n' "${WARN_FINDINGS[@]}" | join_json)"
SILENT_HARD=0; [ "${WALTEUR_RESILIENCE_SILENT:-warn}" = "hard" ] && SILENT_HARD=1

# WARNING-FIRST surface: R6..R8 always print LOUDLY but do NOT block by default.
if [ "$W" -gt 0 ]; then
  echo "resilience-lint: $W silent-failure WARNING(s) (R6/R7/R8 — WARNING-FIRST, non-blocking by default):" >&2
  printf '%s\n' "${WARN_FINDINGS[@]}" | print_lines "WARN"
  [ "$SILENT_HARD" -eq 0 ] && echo "  [WARNING-FIRST] Set WALTEUR_RESILIENCE_SILENT=hard to make R6-R8 block (exit 2)." >&2
fi

# HARD path: R1..R5 always block (exit 2). Behavior-preserving — unchanged for the existing rules.
if [ "$N" -gt 0 ]; then
  write_report "FAIL" "$N resilience anti-pattern(s) found" "$ARR" "$WARR"
  echo "resilience-lint verdict: FAIL — $N anti-pattern(s):" >&2
  printf '%s\n' "${FINDINGS[@]}" | print_lines " "
  exit 2
fi

# No HARD findings. If silent-failure rules are explicitly armed HARD and fired, block now.
if [ "$SILENT_HARD" -eq 1 ] && [ "$W" -gt 0 ]; then
  write_report "FAIL" "$W silent-failure warning(s) promoted to HARD (WALTEUR_RESILIENCE_SILENT=hard)" "$ARR" "$WARR"
  echo "resilience-lint verdict: FAIL — $W silent-failure finding(s) (R6-R8 armed HARD)." >&2
  exit 2
fi

# PASS (HARD-clean). Warnings, if any, are recorded in the report but do not block.
if [ "$W" -gt 0 ]; then
  write_report "PASS" "R1..R5 clean; $W silent-failure warning(s) recorded (non-blocking)" "$ARR" "$WARR"
  echo "resilience-lint verdict: PASS (R1..R5 clean) — $W non-blocking WARN(s) recorded -> $REPORT" >&2
else
  write_report "PASS" "no resilience anti-patterns found" "[]" "[]"
  echo "resilience-lint verdict: PASS — no anti-patterns (R1..R5 clean) -> $REPORT" >&2
fi
exit 0
