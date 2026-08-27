#!/usr/bin/env bash
# WALTEUR browser-proof-gate - replayable real-browser evidence for UI builds.
#
# APPLICABILITY:
#   A UI surface exists when the project has .html/.tsx/.jsx/.vue/.svelte source files.
#   No UI source -> NOT_APPLICABLE, exit 0.
#
# HARD CHECK:
#   UI source requires walteur-kit/browser-proof.json.
#   The proof must include a fresh run date, command output, at least one route,
#   browser + viewport, PASS status, screenshot evidence, accessibility evidence,
#   and interaction evidence. Every referenced local proof file must exist and be non-empty.
#
# Report: walteur-kit/browser-proof-report.json.
# Bypass: WALTEUR_BROWSER_PROOF=off. Pause: walteur-kit/PAUSED present.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "browser-proof-gate - replayable real-browser evidence for UI builds."
  printf '%s\n' "usage: bash browser-proof-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/browser-proof-report.json - fix recipes: walteur-kit/REMEDIATION.md (## browser-proof-gate)"
  printf '%s\n' "bypass: WALTEUR_BROWSER_PROOF=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
PROOF="$KIT/browser-proof.json"
REPORT="$KIT/browser-proof-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TODAY="$(date -u +%F)"
MAX_AGE_DAYS="${WALTEUR_BROWSER_PROOF_MAX_AGE_DAYS:-14}"
mkdir -p "$KIT"

write_report() {
  local verdict="$1" reason="$2" extra="${3-}"
  [ -n "$extra" ] || extra='{}'
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg reason "$reason" --argjson extra "$extra" \
      '{verdict:$v, ts:$ts, gate:"browser-proof-gate", reason:$reason} + $extra' > "$REPORT" 2>/dev/null \
      || printf '{"verdict":"%s","ts":"%s","gate":"browser-proof-gate","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT"
  else
    printf '{"verdict":"%s","ts":"%s","gate":"browser-proof-gate","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT"
  fi
}

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_BROWSER_PROOF:-on}" = "off" ] && { write_report "SKIP" "WALTEUR_BROWSER_PROOF=off"; echo "browser-proof-gate: bypassed (WALTEUR_BROWSER_PROOF=off)." >&2; exit 0; }

selftest() {
  local pass=0 fail=0 tmp today
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  today="$(date -u +%F)"

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

  make_ui() {
    local dst="$1"
    mkdir -p "$dst/src" "$dst/walteur-kit"
    printf '<button>Ship</button>\n' > "$dst/src/index.html"
  }

  make_evidence() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit/browser/screenshots" "$dst/walteur-kit/browser/a11y" "$dst/walteur-kit/browser/interactions"
    printf 'playwright test passed\n' > "$dst/walteur-kit/browser/command.txt"
    printf 'png bytes placeholder\n' > "$dst/walteur-kit/browser/screenshots/home.png"
    printf 'accessibility tree has button name Ship\n' > "$dst/walteur-kit/browser/a11y/home.txt"
    printf 'clicked primary action and observed dashboard\n' > "$dst/walteur-kit/browser/interactions/home.txt"
  }

  make_proof() {
    local dst="$1" run_date="${2:-$today}" status="${3:-PASS}"
    cat > "$dst/walteur-kit/browser-proof.json" <<JSON
{
  "schema_version": 1,
  "run_date": "$run_date",
  "tool": "playwright",
  "command": "npx playwright test",
  "command_output_ref": "walteur-kit/browser/command.txt",
  "target_url": "http://127.0.0.1:4173",
  "routes": [
    {
      "id": "home",
      "path": "/",
      "browser": "chromium",
      "viewport": { "width": 1440, "height": 900 },
      "status": "$status",
      "screenshot_ref": "walteur-kit/browser/screenshots/home.png",
      "accessibility_ref": "walteur-kit/browser/a11y/home.txt",
      "interaction_ref": "walteur-kit/browser/interactions/home.txt"
    }
  ]
}
JSON
  }

  echo "browser-proof-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no UI source -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "UI without browser-proof.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"
  printf '{ bad json\n' > "$tmp/walteur-kit/browser-proof.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "invalid browser-proof.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  jq 'del(.routes)' "$tmp/walteur-kit/browser-proof.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/browser-proof.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "proof missing routes -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "valid browser proof -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  rm -f "$tmp/walteur-kit/browser/screenshots/home.png"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "missing screenshot evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"; make_evidence "$tmp"; make_proof "$tmp" "2000-01-01"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "stale proof -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"; make_evidence "$tmp"; make_proof "$tmp" "$today" "FAIL"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "non-PASS route -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"
  WALTEUR_ROOT="$tmp" WALTEUR_BROWSER_PROOF=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # ── REPLAY MODE (C7) — WALTEUR_BROWSER_EXEC ────────────────────────────────────
  # replay: command that touches something real (an existing file) and exits 0 -> PASS, markers set
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  jq --arg c "test -f walteur-kit/browser/command.txt" '.command = $c' "$tmp/walteur-kit/browser-proof.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/browser-proof.json"
  out="$(WALTEUR_ROOT="$tmp" WALTEUR_BROWSER_EXEC=1 bash "$SELF_PATH" 2>&1)"; rc=$?
  ck "replay: real command exit 0 -> PASS" 0 "$rc"
  executed="$(jq -r '.browser_probe_executed' "$tmp/walteur-kit/browser-proof-report.json" 2>/dev/null)"
  ck "replay: browser_probe_executed marker true" "true" "$executed"
  oe="$(jq -r '.observed_exit' "$tmp/walteur-kit/browser-proof-report.json" 2>/dev/null)"
  ck "replay: observed_exit marker 0" "0" "$oe"
  rm -rf "$tmp"

  # NEGATIVE CONTROL: replay of a no-op constant command (touches nothing real) -> FAIL, not silently green
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  jq --arg c 'bash -c "exit 0"' '.command = $c' "$tmp/walteur-kit/browser-proof.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/browser-proof.json"
  WALTEUR_ROOT="$tmp" WALTEUR_BROWSER_EXEC=1 bash "$SELF_PATH" >/dev/null 2>&1
  ck "replay: no-op constant command -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # NEGATIVE CONTROL: replay of a real, resolvable command that actually exits non-zero -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  jq '.command = "test -f walteur-kit/browser/does-not-exist.txt"' "$tmp/walteur-kit/browser-proof.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/browser-proof.json"
  WALTEUR_ROOT="$tmp" WALTEUR_BROWSER_EXEC=1 bash "$SELF_PATH" >/dev/null 2>&1
  ck "replay: real command exits non-zero -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # default (WALTEUR_BROWSER_EXEC unset) -> replay skipped, still PASS on a valid proof
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "replay default off -> PASS (no execution)" 0 "$?"
  rm -rf "$tmp"

  # evidence-content match: a route marker present in the a11y snapshot -> PASS (panel #5 defense)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  jq '.routes[0].evidence_must_contain = ["Ship"]' "$tmp/walteur-kit/browser-proof.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/browser-proof.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "evidence marker present in a11y -> PASS" 0 "$?"
  rm -rf "$tmp"

  # evidence-content match: a route marker ABSENT from the a11y snapshot -> FAIL (the stale-artifact crack)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/browser-proof-selftest.XXXXXX")" || return 1
  make_ui "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  jq '.routes[0].evidence_must_contain = ["Cadence-marker-absent-from-this-a11y"]' "$tmp/walteur-kit/browser-proof.json" > "$tmp/walteur-kit/p.tmp" && mv "$tmp/walteur-kit/p.tmp" "$tmp/walteur-kit/browser-proof.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "evidence marker absent from a11y -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "browser-proof-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

for t in find jq date tr; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "browser-proof-gate SKIP - required tool '$t' not installed." >&2
    write_report "SKIP" "$t not installed"
    exit 0
  fi
done

# Prune the harness's OWN walteur-kit/ (holds eval fixtures like slop-ui/*.tsx that are NOT the project's UI)
# and any field-runs/ SUB-PROJECT directly under the scan root (self-contained WALTEUR projects with their own
# walteur-kit/ + proofs — the parent repo must not be classified as a UI build because it contains UI field-runs).
# The field-runs prune is anchored to "$ROOT/field-runs" so a field-run scanned DIRECTLY (ROOT=the field-run) is
# unaffected (its own src/ is still scanned). Fixes a latent repo-root false-FAIL surfaced by the design field-run.
PRUNE=( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' \
        -o -path '*/out/*' -o -path '*/.next/*' -o -path '*/.output/*' -o -path '*/.svelte-kit/*' \
        -o -path '*/coverage/*' -o -path '*/graphify-out/*' -o -path '*/walteur-kit/*' -o -path "$ROOT/field-runs/*" )

# -print -quit (not "| head -1"): under `set -o pipefail` a producer killed by SIGPIPE can lose its
# first line, which would classify a real UI build as NOT_APPLICABLE - a fail-open. -quit stops find
# after the first hit with no pipe at all.
ui_src="$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \
  -type f \( -name '*.html' -o -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' \) -print -quit 2>/dev/null)"

if [ -z "$ui_src" ]; then
  echo "browser-proof-gate: no UI source (.html/.tsx/.jsx/.vue/.svelte) - gate not applicable." >&2
  write_report "NOT_APPLICABLE" "no UI source present"
  exit 0
fi

if [ ! -f "$PROOF" ]; then
  echo "browser-proof-gate: FAIL - UI source exists but walteur-kit/browser-proof.json is missing." >&2
  write_report "FAIL" "browser-proof.json missing for UI build"
  exit 2
fi

if ! jq -e . "$PROOF" >/dev/null 2>&1; then
  echo "browser-proof-gate: FAIL - browser-proof.json is not valid JSON." >&2
  write_report "FAIL" "browser-proof.json is not valid JSON"
  exit 2
fi

shape_err="$(jq -r '
  def err(c;m): if c then m else empty end;
  [ err((.run_date|type)!="string" or (.run_date|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")|not); "run_date must be YYYY-MM-DD")
  , err((.tool|type)!="string" or (.tool|length)<1; "tool must be a non-empty string")
  , err((.command|type)!="string" or (.command|length)<1; "command must be a non-empty string")
  , err((.command_output_ref|type)!="string" or (.command_output_ref|length)<1; "command_output_ref must be a non-empty string")
  , err((.routes|type)!="array"; "routes must be an array")
  , err(((.routes|type)=="array") and ((.routes|length)<1); "routes must contain at least one route")
  , err([ .routes[]? | select((.id|type)!="string" or (.id|length)<1) ] | length>0; "each route needs a non-empty id")
  , err([ .routes[]? | select((.path|type)!="string" or (.path|length)<1) ] | length>0; "each route needs a non-empty path")
  , err([ .routes[]? | select((.browser|type)!="string" or (.browser|length)<1) ] | length>0; "each route needs a browser")
  , err([ .routes[]? | select((.viewport.width|type)!="number" or (.viewport.width<1) or ((.viewport.width|floor) != .viewport.width)) ] | length>0; "each route needs viewport.width integer >= 1")
  , err([ .routes[]? | select((.viewport.height|type)!="number" or (.viewport.height<1) or ((.viewport.height|floor) != .viewport.height)) ] | length>0; "each route needs viewport.height integer >= 1")
  , err([ .routes[]? | select(.status != "PASS") ] | length>0; "each route status must be PASS")
  , err([ .routes[]? | select((.screenshot_ref|type)!="string" or (.screenshot_ref|length)<1) ] | length>0; "each route needs screenshot_ref")
  , err([ .routes[]? | select((.accessibility_ref|type)!="string" or (.accessibility_ref|length)<1) ] | length>0; "each route needs accessibility_ref")
  , err([ .routes[]? | select((.interaction_ref|type)!="string" or (.interaction_ref|length)<1) ] | length>0; "each route needs interaction_ref")
  ] | map(select(. != null)) | .[]' "$PROOF" 2>/dev/null)"

if [ -n "$shape_err" ]; then
  echo "browser-proof-gate: FAIL - browser-proof.json violates the required shape:" >&2
  printf '%s\n' "$shape_err" | sed 's/^/  - /' >&2
  err_json="$(printf '%s\n' "$shape_err" | jq -R . | jq -s '{findings:.}')"
  write_report "FAIL" "browser-proof.json fails required shape" "$err_json"
  exit 2
fi

date_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d %H:%M:%S" "$1 00:00:00" +%s 2>/dev/null
}

run_date="$(jq -r '.run_date' "$PROOF")"
today_epoch="$(date_to_epoch "$TODAY")"
run_epoch="$(date_to_epoch "$run_date")"
if [ -z "$run_epoch" ] || [ -z "$today_epoch" ]; then
  echo "browser-proof-gate: FAIL - run_date is not parseable: $run_date" >&2
  write_report "FAIL" "run_date is not parseable"
  exit 2
fi
if [ "$run_epoch" -gt "$today_epoch" ]; then
  echo "browser-proof-gate: FAIL - browser proof run_date is in the future: $run_date" >&2
  write_report "FAIL" "browser proof run_date is in the future"
  exit 2
fi
age_days=$(( (today_epoch - run_epoch) / 86400 ))
if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
  echo "browser-proof-gate: FAIL - browser proof is stale (${age_days}d old, max ${MAX_AGE_DAYS}d)." >&2
  write_report "FAIL" "browser proof is stale"
  exit 2
fi

safe_ref() {
  local ref="$1"
  [ -n "$ref" ] || return 1
  case "$ref" in
    /*|*../*|../*|*'/..'|*'//'*) return 1 ;;
  esac
  [ -f "$ROOT/$ref" ] && [ -s "$ROOT/$ref" ]
}

missing_refs=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  if ! safe_ref "$ref"; then
    echo "browser-proof-gate: FAIL - missing/unsafe/empty proof ref: $ref" >&2
    missing_refs=$((missing_refs+1))
  fi
done < <(jq -r '
  .command_output_ref,
  (.routes[] | .screenshot_ref, .accessibility_ref, .interaction_ref, (.console_ref // empty), (.network_ref // empty))
' "$PROOF" | tr -d '\r')

if [ "$missing_refs" -gt 0 ]; then
  write_report "FAIL" "$missing_refs browser proof reference(s) missing, unsafe, or empty"
  exit 2
fi

# EVIDENCE-CONTENT MATCH (stale-artifact defense, panel #5): if a route declares
# "evidence_must_contain": [...], every listed string MUST appear in that route's cited accessibility
# snapshot. Closes the class a blind panel caught in the design field-run - a browser-proof bundle that
# reuses a stale a11y tree from a DIFFERENT app (whose app-specific markers are absent) is now a FAIL,
# not a silent PASS. Opt-in per route; a route without the field is unchecked (backward compatible).
content_err=0
while IFS="$(printf '\t')" read -r a11y_ref need; do
  [ -n "${need:-}" ] || continue
  a11y_file="$ROOT/$a11y_ref"
  if [ -f "$a11y_file" ] && ! grep -Fq -- "$need" "$a11y_file"; then
    echo "browser-proof-gate: FAIL - accessibility evidence ($a11y_ref) missing required marker: $need" >&2
    content_err=$((content_err+1))
  fi
done < <(jq -r '.routes[]? | .accessibility_ref as $a | (.evidence_must_contain // [])[]? | [$a, (. | tostring)] | @tsv' "$PROOF" | tr -d '\r')

if [ "$content_err" -gt 0 ]; then
  echo "browser-proof-gate: FAIL - cited accessibility snapshot does not match the app (stale/mismatched artifact)." >&2
  write_report "FAIL" "$content_err evidence marker(s) absent from the cited accessibility snapshot"
  exit 2
fi

# ── REPLAY MODE (opt-in, default off): WALTEUR_BROWSER_EXEC=1 re-runs the recorded .command through
# the shared _probe-proof.sh authenticity guard (same kernel authz/privacy/sdlc/audit/cutover use), then
# actually EXECUTES it and observes its real exit code. This closes the "recorded command that was never
# run" gap: a proof can declare command:"npx playwright test" truthfully while nobody ever ran it. When
# armed, a command that fails the probe_proves_something check (a no-op constant like `bash -c 'exit 0'`)
# or that executes and returns non-zero is a FAIL — the replay disagrees with the recorded PASS verdict.
# Markers browser_probe_executed:true and observed_exit:<n> are written into the report either way so the
# receipt is auditable. Default OFF: replaying a real browser command in a commit-time hook is expensive
# and environment-dependent (needs a dev server, browsers installed); CI/opt-in is the intended surface.
BROWSER_EXEC="${WALTEUR_BROWSER_EXEC:-0}"
probe_executed="false"; observed_exit=""
if [ "$BROWSER_EXEC" = "1" ] || [ "$BROWSER_EXEC" = "on" ]; then
  SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck disable=SC1091
  if [ -f "$SELF_DIR/_probe-proof.sh" ]; then
    . "$SELF_DIR/_probe-proof.sh"
    cmd="$(jq -r '.command // empty' "$PROOF")"
    if [ -z "$cmd" ] || ! probe_proves_something "$cmd"; then
      echo "browser-proof-gate: FAIL - replay: recorded command touches nothing real (no-op / unresolvable): $cmd" >&2
      write_report "FAIL" "browser proof replay: command proves nothing (no-op or unresolvable)" \
        "$(jq -n '{browser_probe_executed:false, observed_exit:null}')"
      exit 2
    fi
    ( cd "$ROOT" && eval "$cmd" ) >/dev/null 2>&1
    observed_exit=$?
    probe_executed="true"
    if [ "$observed_exit" -ne 0 ]; then
      echo "browser-proof-gate: FAIL - replay: command exited $observed_exit (recorded proof claims PASS): $cmd" >&2
      write_report "FAIL" "browser proof replay: recorded command exited non-zero" \
        "$(jq -n --argjson oe "$observed_exit" '{browser_probe_executed:true, observed_exit:$oe}')"
      exit 2
    fi
  else
    echo "browser-proof-gate: FAIL - replay requested (WALTEUR_BROWSER_EXEC=1) but _probe-proof.sh is missing." >&2
    write_report "FAIL" "browser proof replay requested but _probe-proof.sh guard is missing" \
      "$(jq -n '{browser_probe_executed:false, observed_exit:null}')"
    exit 2
  fi
fi

routes_count="$(jq '.routes | length' "$PROOF")"
extra="$(jq -n --argjson routes "$routes_count" --arg run_date "$run_date" --argjson executed "$probe_executed" \
  --arg oe "$observed_exit" '{routes:$routes, run_date:$run_date, browser_probe_executed:$executed} + (if $oe != "" then {observed_exit:($oe|tonumber)} else {} end)')"
write_report "PASS" "browser proof is fresh and replayable" "$extra"
echo "browser-proof-gate verdict: PASS (${routes_count} route(s), run_date $run_date, replay=${probe_executed}) -> $REPORT" >&2
exit 0
