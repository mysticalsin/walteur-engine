#!/usr/bin/env bash
# WALTEUR measured-quality-gate — HARD gate (fix #7 completeness, S033 candidate C2 fabrication-resistance).
# Closes the "a11y/perf CLAIMED but never measured" hole: a UI build cannot ship without real Lighthouse +
# axe artifacts that meet thresholds. "We couldn't measure" must NOT read as "done" — for a UI build a
# missing measurement is a FAIL, not a skip. S033: hardened against a hand-fabricated {performance:95}
# shape — real tool-emission provenance + freshness are now required, and an EXEC mode can re-run the
# tools itself and observe (never trust a bare artifact when the tool is available to re-check it).
#
# Reads (default paths; override via walteur-kit/quality-budget.json):
#   walteur-kit/quality/lighthouse.json  — Lighthouse result with .categories.{performance,
#                                           accessibility,best-practices}.score (0..1)
#   walteur-kit/quality/axe.json         — axe-core result with .violations[]
#
# Thresholds (walteur-kit/quality-budget.json .lighthouse / .axe, else defaults):
#   perf_min 0.9 · a11y_min 0.9 · best_practices_min 0.9 · axe.max_violations 0
#
# PROVENANCE (S033): a real Lighthouse result carries .lighthouseVersion + .fetchTime + a .audits tree;
# a bare {categories:{performance:{score:0.95}}} fabrication has neither. A real axe-core result carries
# .testEngine + .timestamp. Missing provenance fields => FAIL (fabrication-shaped artifact), same as a
# missing artifact — a hand-written stub must not pass.
#
# FRESHNESS (S033): lighthouse .fetchTime / axe .timestamp must be within WALTEUR_MEASURED_MAXAGE seconds
# of now (default 259200 = 72h). A stale artifact from an old run is not evidence for THIS build.
#
# EXEC mode (S033, WALTEUR_MEASURED_EXEC, default 0): when armed and a target URL/file is recorded at
# walteur-kit/quality/target.json ({"url":"..."} or {"file":"..."}), and the lighthouse/axe CLI is present,
# re-run the tool and observe its exit + freshly written artifact instead of trusting whatever is on disk.
# If EXEC is armed but the CLI is absent, this is a LOUD cannot_measure verdict — never a silent green —
# and exits 2 (fail-closed; EXEC is an explicit opt-in, so "I asked you to measure and you can't" is a FAIL).
#
# CONTRACT:
#   has_ui (preflight-signals.has_ui, build-contract ui interface, quality-budget.json, or
#           frontend source files) => REQUIRED (validate); else NOT_APPLICABLE exit 0.
#   jq absent => SKIP exit 0.  walteur-kit/PAUSED => exit 2.
# Report: walteur-kit/measured-quality-report.json   Bypass: WALTEUR_MEASURED_QUALITY=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "measured-quality-gate - HARD gate (fix #7 completeness, S033 candidate C2 fabrication-resistance)."
  printf '%s\n' "usage: bash measured-quality-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/measured-quality-report.json - fix recipes: walteur-kit/REMEDIATION.md (## measured-quality-gate)"
  printf '%s\n' "bypass: WALTEUR_MEASURED_QUALITY=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
CONTRACT="$KIT/build-contract.json"
SIGNALS="$KIT/preflight-signals.json"
BUDGET="$KIT/quality-budget.json"
REPORT="$KIT/measured-quality-report.json"
MAXAGE="${WALTEUR_MEASURED_MAXAGE:-259200}"   # 72h in seconds
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW="$(date -u +%s)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() {
  verdict="$1"; reason="$2"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"measured-quality", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"measured-quality","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

has_ui() {
  [ -f "$SIGNALS" ] && jq -e '.has_ui==true' "$SIGNALS" >/dev/null 2>&1 && return 0
  [ -f "$CONTRACT" ] && jq -e '[.interfaces[]? | select(.type=="ui")] | length > 0' "$CONTRACT" >/dev/null 2>&1 && return 0
  [ -f "$BUDGET" ] && return 0
  # capture-first (NOT `find | grep -q` — that SIGPIPEs find and, under `set -o pipefail`,
  # falsely fails the test when frontend files DO exist).
  local uif; uif="$(find "$ROOT" -type d -name node_modules -prune -o -type f \( -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' -o -name '*.html' \) -print 2>/dev/null | head -1)"
  [ -n "$uif" ] && return 0
  return 1
}

num() { # numeric default helper: $1=value $2=default
  case "$1" in ''|null) echo "$2";; *) echo "$1";; esac
}

# epoch seconds from an ISO8601 timestamp or a unix-ms/unix-s numeric fetchTime. Empty on parse failure.
to_epoch() {
  local v="$1"
  [ -z "$v" ] || [ "$v" = "null" ] && { echo ""; return; }
  case "$v" in
    ''|*[!0-9]*) : ;;   # not purely digits -> fall through to date parsing below
    *)
      # purely numeric: lighthouse .fetchTime is ISO8601 normally, but some emitters use unix ms.
      if [ "${#v}" -ge 12 ]; then echo "$((v/1000))"; else echo "$v"; fi
      return ;;
  esac
  date -u -d "$v" +%s 2>/dev/null && return
  date -u -jf "%Y-%m-%dT%H:%M:%S" "${v%%.*}" +%s 2>/dev/null && return
  echo ""
}

# EXEC-mode tool detection: run when a live re-measure is requested and a target is recorded.
TARGET="$KIT/quality/target.json"
exec_target_url() { [ -f "$TARGET" ] && jq -r '.url // empty' "$TARGET" 2>/dev/null; }
exec_target_file() { [ -f "$TARGET" ] && jq -r '.file // empty' "$TARGET" 2>/dev/null; }

# run lighthouse/axe live when EXEC is armed. Writes fresh artifacts on success. Sets EXEC_RAN=1 if a
# tool actually executed. cannot_measure findings are added directly (LOUD, never silent).
run_exec() {
  local url file
  url="$(exec_target_url)"; file="$(exec_target_file)"
  if [ -z "$url" ] && [ -z "$file" ]; then
    add_finding "cannot_measure" "WALTEUR_MEASURED_EXEC=1 but no target recorded at $TARGET ({\"url\":...} or {\"file\":...}) — cannot re-run Lighthouse/axe without a target."
    return
  fi
  local target="${url:-$file}"

  # Lighthouse
  if have npx && npx --no-install lighthouse --version >/dev/null 2>&1; then
    npx --no-install lighthouse "$target" --output=json --output-path="$KIT/quality/lighthouse.json" --quiet --chrome-flags="--headless" >/dev/null 2>&1
    EXEC_RAN=1
  elif have lighthouse; then
    lighthouse "$target" --output=json --output-path="$KIT/quality/lighthouse.json" --quiet --chrome-flags="--headless" >/dev/null 2>&1
    EXEC_RAN=1
  else
    add_finding "cannot_measure" "WALTEUR_MEASURED_EXEC=1 but no lighthouse CLI found (npx lighthouse / lighthouse) — cannot execute a live measurement (LOUD, not silent-green)."
  fi

  # axe-core CLI
  if have npx && npx --no-install axe --version >/dev/null 2>&1; then
    npx --no-install axe "$target" --save "$KIT/quality/axe.json" >/dev/null 2>&1
    EXEC_RAN=1
  elif have axe; then
    axe "$target" --save "$KIT/quality/axe.json" >/dev/null 2>&1
    EXEC_RAN=1
  else
    add_finding "cannot_measure" "WALTEUR_MEASURED_EXEC=1 but no axe CLI found (npx @axe-core/cli / axe) — cannot execute a live measurement (LOUD, not silent-green)."
  fi
}

validate() {
  LH="$KIT/quality/lighthouse.json"; AXE="$KIT/quality/axe.json"
  perf_min="0.9"; a11y_min="0.9"; bp_min="0.9"; axe_max="0"
  if [ -f "$BUDGET" ]; then
    perf_min="$(num "$(jq -r '.lighthouse.perf_min // empty' "$BUDGET" 2>/dev/null)" 0.9)"
    a11y_min="$(num "$(jq -r '.lighthouse.a11y_min // empty' "$BUDGET" 2>/dev/null)" 0.9)"
    bp_min="$(num "$(jq -r '.lighthouse.best_practices_min // empty' "$BUDGET" 2>/dev/null)" 0.9)"
    axe_max="$(num "$(jq -r '.axe.max_violations // empty' "$BUDGET" 2>/dev/null)" 0)"
  fi
  [ -f "$KIT/quality/lighthouse.json.path" ] && LH="$ROOT/$(cat "$KIT/quality/lighthouse.json.path")"

  # Lighthouse
  if [ ! -s "$LH" ]; then
    add_finding "unmeasured_perf" "UI build but Lighthouse artifact missing ($LH). a11y/perf must be MEASURED, not claimed."
  elif ! jq -e '.categories' "$LH" >/dev/null 2>&1; then
    add_finding "lighthouse_shape" "lighthouse.json has no .categories (not a real Lighthouse result)"
  elif ! jq -e '(.lighthouseVersion // empty) != "" and (.fetchTime // empty) != "" and (.audits // empty) != {}' "$LH" >/dev/null 2>&1; then
    add_finding "lighthouse_provenance" "lighthouse.json has no .lighthouseVersion/.fetchTime/.audits — a real Lighthouse run always emits these; this looks fabricated ({categories:{...}} alone is not sufficient)."
  else
    local fetch_epoch age
    fetch_epoch="$(to_epoch "$(jq -r '.fetchTime // empty' "$LH" 2>/dev/null)")"
    if [ -z "$fetch_epoch" ]; then
      add_finding "lighthouse_provenance" "lighthouse.json .fetchTime could not be parsed as a timestamp — cannot verify freshness."
    else
      age=$((NOW - fetch_epoch))
      if [ "$age" -gt "$MAXAGE" ] || [ "$age" -lt 0 ]; then
        add_finding "lighthouse_stale" "lighthouse.json .fetchTime is $((age/3600))h old, exceeds freshness window ${MAXAGE}s ($((MAXAGE/3600))h) — re-run Lighthouse for this build."
      fi
    fi
    for pair in "performance:$perf_min" "accessibility:$a11y_min" "best-practices:$bp_min"; do
      catkey="${pair%%:*}"; minv="${pair##*:}"
      score="$(jq -r --arg c "$catkey" '.categories[$c].score // "null"' "$LH" 2>/dev/null)"
      if [ "$score" = "null" ]; then add_finding "lighthouse_missing_$catkey" "Lighthouse missing category '$catkey'"
      elif awk -v s="$score" -v m="$minv" 'BEGIN{exit !(s+0 < m+0)}'; then
        add_finding "lighthouse_below_$catkey" "Lighthouse $catkey score $score below threshold $minv"
      fi
    done
  fi

  # axe
  if [ ! -s "$AXE" ]; then
    add_finding "unmeasured_a11y" "UI build but axe artifact missing ($AXE). Run axe-core and commit the JSON."
  elif ! jq -e '.violations | type=="array"' "$AXE" >/dev/null 2>&1; then
    add_finding "axe_shape" "axe.json has no .violations array (not a real axe-core result)"
  elif ! jq -e '(.testEngine // empty) != {} and (.testEngine.name // empty) != "" and (.timestamp // empty) != ""' "$AXE" >/dev/null 2>&1; then
    add_finding "axe_provenance" "axe.json has no .testEngine.name/.timestamp — a real axe-core run always emits these; this looks fabricated ({violations:[]} alone is not sufficient)."
  else
    local axe_epoch age
    axe_epoch="$(to_epoch "$(jq -r '.timestamp // empty' "$AXE" 2>/dev/null)")"
    if [ -z "$axe_epoch" ]; then
      add_finding "axe_provenance" "axe.json .timestamp could not be parsed as a timestamp — cannot verify freshness."
    else
      age=$((NOW - axe_epoch))
      if [ "$age" -gt "$MAXAGE" ] || [ "$age" -lt 0 ]; then
        add_finding "axe_stale" "axe.json .timestamp is $((age/3600))h old, exceeds freshness window ${MAXAGE}s ($((MAXAGE/3600))h) — re-run axe-core for this build."
      fi
    fi
    vcount="$(jq -r '.violations | length' "$AXE" 2>/dev/null || echo 0)"
    if [ "$vcount" -gt "$axe_max" ]; then add_finding "axe_violations" "axe reports $vcount violation(s) (max allowed $axe_max)"; fi
  fi
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "measured-quality selftest SKIP - jq not installed."; return 0; fi
  echo "measured-quality-gate selftest:"
  mk() { mkdir -p "$1/walteur-kit/quality"; printf '{"has_ui":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  now_iso() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
  old_iso() { date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -v-10d +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || echo "2000-01-01T00:00:00.000Z"; }
  goodlh() { jq -n --arg ft "$(now_iso)" '{lighthouseVersion:"11.4.0", fetchTime:$ft, requestedUrl:"http://localhost:3000/", categories:{performance:{score:0.95},accessibility:{score:1.0},"best-practices":{score:0.95}}, audits:{"first-contentful-paint":{score:1}}}' > "$1/walteur-kit/quality/lighthouse.json"; }
  goodaxe() { jq -n --arg ts "$(now_iso)" '{testEngine:{name:"axe-core",version:"4.9.0"}, timestamp:$ts, violations:[]}' > "$1/walteur-kit/quality/axe.json"; }
  # fabricated: bare shape, no provenance fields at all
  fabricatedlh() { jq -n '{categories:{performance:{score:0.95},accessibility:{score:1.0},"best-practices":{score:0.95}}}' > "$1/walteur-kit/quality/lighthouse.json"; }
  fabricatedaxe() { jq -n '{violations:[]}' > "$1/walteur-kit/quality/axe.json"; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }

  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no UI -> NOT_APPLICABLE" 0 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; goodlh "$t"; goodaxe "$t"; ck "UI + good lighthouse + axe 0 -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # find-fallback: UI detected via a frontend FILE only (no signals) -> gate applies (regression for the pipefail bug)
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mkdir -p "$t/walteur-kit/quality" "$t/src"; printf 'export const A=()=>null;\n' > "$t/src/App.tsx"; goodlh "$t"; goodaxe "$t"; ck "UI via frontend file (no signals) -> applies + PASS" 0 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; goodaxe "$t"; ck "UI + lighthouse ABSENT -> FAIL (unmeasured_perf)" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; jq -n --arg ft "$(now_iso)" '{lighthouseVersion:"11.4.0", fetchTime:$ft, audits:{a:{score:1}}, categories:{performance:{score:0.4},accessibility:{score:1.0},"best-practices":{score:0.95}}}' > "$t/walteur-kit/quality/lighthouse.json"; goodaxe "$t"; ck "UI + perf 0.4 < 0.9 -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; goodlh "$t"; ck "UI + axe ABSENT -> FAIL (unmeasured_a11y)" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; goodlh "$t"; jq -n --arg ts "$(now_iso)" '{testEngine:{name:"axe-core",version:"4.9.0"}, timestamp:$ts, violations:[{id:"color-contrast",impact:"serious"}]}' > "$t/walteur-kit/quality/axe.json"; ck "UI + 1 axe violation -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; jq -n --arg ft "$(now_iso)" '{lighthouseVersion:"11.4.0", fetchTime:$ft, audits:{a:{score:1}}, categories:{performance:{score:0.4},accessibility:{score:1.0},"best-practices":{score:0.95}}}' > "$t/walteur-kit/quality/lighthouse.json"; goodaxe "$t"; jq -n '{lighthouse:{perf_min:0.3}}' > "$t/walteur-kit/quality-budget.json"; ck "custom budget perf_min 0.3 + perf 0.4 -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; jq -n '{violations:[{}]}' > "$t/walteur-kit/quality/axe.json"; WALTEUR_ROOT="$t" WALTEUR_MEASURED_QUALITY=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ── S033 NEGATIVE CONTROLS: fabricated artifacts (no provenance) must FAIL, not pass ──
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; fabricatedlh "$t"; fabricatedaxe "$t"; ck "NEGATIVE CONTROL: bare {performance:95} fabrication (no lighthouseVersion/fetchTime/audits, no testEngine/timestamp) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; fabricatedlh "$t"; goodaxe "$t"; ck "NEGATIVE CONTROL: fabricated lighthouse (real axe) -> FAIL (lighthouse_provenance)" 2 "$(run "$t")"
  jq -e '.findings[] | select(.check=="lighthouse_provenance")' "$t/walteur-kit/measured-quality-report.json" >/dev/null 2>&1; ck "report names lighthouse_provenance finding" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; goodlh "$t"; fabricatedaxe "$t"; ck "NEGATIVE CONTROL: fabricated axe (real lighthouse) -> FAIL (axe_provenance)" 2 "$(run "$t")"; rm -rf "$t"

  # ── S033: freshness ──
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; jq -n --arg ft "$(old_iso)" '{lighthouseVersion:"11.4.0", fetchTime:$ft, audits:{a:{score:1}}, categories:{performance:{score:0.95},accessibility:{score:1.0},"best-practices":{score:0.95}}}' > "$t/walteur-kit/quality/lighthouse.json"; goodaxe "$t"; ck "lighthouse fetchTime 10 days old (>72h default) -> FAIL (stale)" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; jq -n --arg ft "$(old_iso)" '{lighthouseVersion:"11.4.0", fetchTime:$ft, audits:{a:{score:1}}, categories:{performance:{score:0.95},accessibility:{score:1.0},"best-practices":{score:0.95}}}' > "$t/walteur-kit/quality/lighthouse.json"; goodaxe "$t"; WALTEUR_ROOT="$t" WALTEUR_MEASURED_MAXAGE=999999999 bash "$SELF" >/dev/null 2>&1; ck "same 10-day-old artifact but WALTEUR_MEASURED_MAXAGE widened -> PASS" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; goodlh "$t"; jq -n --arg ts "$(old_iso)" '{testEngine:{name:"axe-core",version:"4.9.0"}, timestamp:$ts, violations:[]}' > "$t/walteur-kit/quality/axe.json"; ck "axe timestamp 10 days old -> FAIL (stale)" 2 "$(run "$t")"; rm -rf "$t"

  # ── S033: EXEC mode ──
  # EXEC armed, no target recorded, tools irrelevant -> cannot_measure FAIL (loud, never silent green)
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; goodlh "$t"; goodaxe "$t"; WALTEUR_ROOT="$t" WALTEUR_MEASURED_EXEC=1 bash "$SELF" >/dev/null 2>&1; ec=$?; ck "EXEC armed + no target.json -> FAIL (cannot_measure, no silent green even with good artifacts on disk)" 2 "$ec"
  jq -e '.findings[] | select(.check=="cannot_measure")' "$t/walteur-kit/measured-quality-report.json" >/dev/null 2>&1; ck "report names cannot_measure finding" 0 "$?"; rm -rf "$t"
  # EXEC armed, target recorded, tool CLIs not actually installed in this sandbox (npx --no-install
  # fails fast without network install) -> cannot_measure FAIL, not the stale good artifacts on disk
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; goodlh "$t"; goodaxe "$t"; jq -n '{url:"http://localhost:3000/"}' > "$t/walteur-kit/quality/target.json"
  WALTEUR_ROOT="$t" WALTEUR_MEASURED_EXEC=1 bash "$SELF" >/dev/null 2>&1; ec=$?
  ck "EXEC armed + target set + lighthouse/axe CLI not installed -> FAIL (cannot_measure), not the stale good artifacts on disk" 2 "$ec"; rm -rf "$t"
  # EXEC not armed (default) -> old behavior unaffected, validates whatever is on disk
  t="$(mktemp -d "${TMPDIR:-/tmp}/measuredqu.XXXXXX")"; mk "$t"; goodlh "$t"; goodaxe "$t"; ck "EXEC default (0) -> validates on-disk artifacts as before -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "measured-quality-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_MEASURED_QUALITY:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_MEASURED_QUALITY=off"; echo "measured-quality-gate: bypassed." >&2; exit 0; }
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "measured-quality-gate: SKIP - jq unavailable." >&2; exit 0; fi

if ! has_ui; then
  write_report "NOT_APPLICABLE" "no UI surface detected"
  echo "measured-quality-gate: NOT_APPLICABLE (no UI)"
  exit 0
fi

EXEC_RAN=0
if [ "${WALTEUR_MEASURED_EXEC:-0}" = "1" ]; then
  run_exec
  if [ "$failures" -gt 0 ]; then
    # cannot_measure is always fail-closed: EXEC is an explicit opt-in request to measure live;
    # a tool/target that can't deliver that must never read as a quiet pass on stale disk artifacts.
    write_report "FAIL" "cannot_measure: EXEC armed but live measurement could not run"
    echo "measured-quality-gate: FAIL - cannot_measure (EXEC armed, live measurement unavailable)" >&2
    printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null || true
    exit 2
  fi
fi

validate

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures measured-quality violation(s)"
  echo "measured-quality-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null || true
  exit 2
fi
write_report "PASS" "Lighthouse + axe measured and within thresholds (provenance + freshness verified$([ "$EXEC_RAN" = 1 ] && echo '; EXEC live-measured'))"
echo "measured-quality-gate: PASS" >&2
exit 0
