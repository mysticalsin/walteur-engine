#!/usr/bin/env bash
# walteur-apex refresh-fixture-dates — defuses the calendar time-bomb in the fixture suite.
#
# THE PROBLEM: two gates assert scan freshness RELATIVE TO NOW and also reject future-dated
# timestamps as a cheat — cve-gate (14-day window, `scanned_at`) and secret-rotation-gate (7-day
# window, `static_secret_scan.ran_ts`). So their fixtures cannot be pinned to a far-future date the
# way `playbook-fresh` is. Left alone, 4 of 29 fixtures (14% of the suite) go red on calendar drift
# alone, producing a FALSE regression signal — the alarm-fatigue harm this project argues against.
#
# WHY REGENERATING IS HONEST, NOT CHEATING: in these fixtures the timestamp is SCAFFOLDING, not the
# property under test. What is under test is "does cve-gate catch an open unexcepted CRITICAL CVE"
# and "does secret-rotation-gate catch a hardcoded credential" — never "was this scan run recently".
# The poisoned twin must still FAIL for its planted defect and the clean twin must still PASS after
# refreshing; if a refresh ever flipped a verdict, that would itself be the regression. `--verify`
# asserts exactly that.
#
# It rewrites ONLY these fields, only inside eval-harness-additions/fixtures/, and only when the
# existing value is a date-shaped string. It never touches gates, manifests, or anything else.
#
# CONTRACT: refreshed => exit 0 · nothing to do => exit 0 · jq absent => exit 2 (cannot edit safely)
#           PAUSED => exit 2 · bypass WALTEUR_FIXDATE=off => exit 0
#
# --help: self-documentation BEFORE any side effect
case "${1:-}" in
  -h|--help)
    printf '%s\n' "refresh-fixture-dates - re-dates the freshness-windowed fixture timestamps to now."
    printf '%s\n' "usage: bash refresh-fixture-dates.sh [--check|--verify|--selftest|--help|<default: rewrite>]"
    printf '%s\n' "  --check   report which fixtures are stale; exit 2 if any are (writes nothing)"
    printf '%s\n' "  --verify  refresh, then assert every twin still behaves (needs WALTEUR_FRAMEWORK)"
    printf '%s\n' "fields: scanned_at · static_secret_scan.ran_ts · secrets[].last_rotated · secrets[].provider_attestation.attested_ts"
    exit 0 ;;
esac

set -uo pipefail
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
have() { command -v "$1" >/dev/null 2>&1; }

# ROOT must be the REPOSITORY root. `dirname/..` gave ROOT=walteur-kit once this file was installed at
# walteur-kit/eval-harness/, so the PAUSED check looked for walteur-kit/walteur-kit/PAUSED and could
# never fire — a paused harness would have kept rewriting fixtures. Same defect, same fix, as
# fixture-integrity.sh: walk up to the first git top-level or walteur-kit parent.
if [ -n "${WALTEUR_APEX_ROOT:-}" ]; then
  ROOT="$WALTEUR_APEX_ROOT"
else
  ROOT="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)"
  _up="$ROOT"
  while [ -n "$_up" ] && [ "$_up" != "/" ]; do
    if [ -d "$_up/.git" ] || [ -f "$_up/.git" ] || [ -d "$_up/walteur-kit" ]; then ROOT="$_up"; break; fi
    _up="$(dirname "$_up")"
  done
  [ "$_up" = "/" ] && ROOT="$(cd "$(dirname "$SELF")/.." 2>/dev/null && pwd)"
fi
# Layout-aware: fixtures live at eval-harness-additions/fixtures inside walteur-apex, and at
# walteur-kit/eval-harness/fixtures once adopted into a WALTEUR tree. Hardcoding the apex path made
# this SILENTLY SKIP after adoption, which would have turned its CI step into a no-op — the exact
# quiet-skip failure mode this repo keeps finding in other people's tooling.
FX=""
for cand in \
  "$ROOT/eval-harness-additions/fixtures" \
  "$ROOT/walteur-kit/eval-harness/fixtures" \
  "$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)/fixtures" ; do
  [ -d "$cand" ] && { FX="$cand"; break; }
done
[ -n "$FX" ] || FX="$ROOT/eval-harness-additions/fixtures"
TODAY="$(date -u +%Y-%m-%d)"
# MIDNIGHT-PINNED, deliberately. secret-rotation-gate computes `today_epoch` from UTC-midnight and
# rejects `ran_ts -gt today_epoch` as a fabricated future timestamp — so ANY same-day time-of-day reads
# as "in the future" and fails the clean twin. Writing 00:00:00Z makes ran_epoch == today_epoch: today,
# not the future. It also makes the value trivially day-idempotent.
NOW_TS="$(date -u +%Y-%m-%d)T00:00:00Z"

# BOUNDARY FIXTURES. A fixture may carry `walteur-kit/.refresh-offset-days` holding an integer N; its
# recency fields are then re-dated to N days AGO instead of today. That exists because the only two
# surviving `boundary` mutants in the whole suite (cve-gate, memory-staleness-gate) sit on thresholds
# that are CALENDAR-RELATIVE — `age_days -gt 14`, `valid_until -lt today`. Killing a boundary mutant
# needs a fixture sitting exactly ON the threshold, and a fixture sitting exactly on a calendar
# threshold is a time-bomb by construction: it is correct for one day and wrong forever after. The
# offset marker is what makes such a fixture maintainable rather than a scheduled false alarm.
# N=14 means "exactly at the 14-day edge"; N=0 means "expires today".
offset_days() {
  # `local d="$1" m="$d/..."` does NOT work under set -u: bash creates every name in one `local`
  # statement as an unset local BEFORE running the assignments, so `$d` there resolves to the new
  # unset local and aborts the function with "d: unbound variable". The function then returned the
  # empty string, which sailed straight past `[ "$1" = "0" ]` into `date -d " days ago"` — a string
  # GNU date happily accepts. Two silent failures composing into a plausible wrong date.
  local d="$1"
  local m="$d/walteur-kit/.refresh-offset-days" v
  [ -f "$m" ] || { printf '0'; return 0; }
  v="$(tr -d '[:space:]\r' < "$m" 2>/dev/null)"
  case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}
# Both helpers treat anything that is not a positive integer as "today". Never hand a malformed
# offset to `date -d`: it accepts far more than it should and answers with a confident wrong date.
date_minus_days() { # $1 = whole days ago -> YYYY-MM-DD (UTC)
  case "${1:-}" in ''|0|*[!0-9]*) printf '%s' "$TODAY"; return 0 ;; esac
  date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null || printf '%s' "$TODAY"
}
ts_minus_days() { # $1 = whole days ago -> midnight UTC on that day
  case "${1:-}" in ''|0|*[!0-9]*) printf '%s' "$NOW_TS"; return 0 ;; esac
  # Midnight ON the target day — same reason as NOW_TS above, and it makes the value idempotent.
  # "N days ago minus 12 hours" landed on the PREVIOUS day whenever the run happened before noon, so
  # its date part never matched the day-idempotence check and the fixture was rewritten every run.
  printf '%sT00:00:00Z' "$(date_minus_days "$1")"
}

# Fields that carry a recency assertion. Date-only vs full-timestamp is decided per field so we never
# widen a date into a timestamp (or vice versa) and break a gate's own parser.
refresh_file() {
  local f="$1" mode="$2" changed=0 tmp
  # Per-fixture offset: everything before `/walteur-kit/` is the fixture root.
  # NOTE the names: `local TODAY` here would SHADOW the global that date_minus_days falls back to,
  # and since the local is still unset when the helper runs, every fixture would be re-dated to the
  # empty string. Cost a green selftest to find; keep these locals distinct from the globals.
  # `%` (shortest suffix), NOT `%%`. In an ADOPTED tree the path contains TWO `/walteur-kit/`
  # segments — the repo's own and the fixture's — and `%%` strips from the FIRST, yielding the repo
  # root instead of the fixture directory. The offset marker was then never found, every boundary
  # fixture silently got offset 0, and `cve-at-window-edge` was re-dated to TODAY: a fixture built to
  # sit on the 14-day threshold, quietly moved off it. Invisible in the apex layout, which has only
  # one `/walteur-kit/`, so the selftest passed while the real tree was wrong.
  local fxroot="${f%/walteur-kit/*}" off D T
  off="$(offset_days "$fxroot")"
  D="$(date_minus_days "$off")"; T="$(ts_minus_days "$off")"
  tmp="$(mktemp)"
  # NOTE: use has() rather than `.k? // empty`. In jq, `(.k? // empty) != null` yields EMPTY when the
  # key is absent, which makes the enclosing `if` produce no output at all — the whole document
  # silently becomes empty and the fixture gets truncated. Cost me a green selftest to find.
  jq --arg d "$D" --arg t "$T" '
    def isdate: type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}");
    # Idempotent on the EXACT target value, not merely on the date prefix. Both targets are now
    # deterministic (a date, or that date at 00:00:00Z), so exact equality is the correct test — and
    # unlike a prefix test it SELF-HEALS: a wrong time-of-day on the right date used to be treated as
    # already-current and could never be repaired, which is how a bad same-day `ran_ts` survived a
    # refresh and kept failing its clean twin.
    def setdate($v): if (isdate and . == $v) then . elif isdate then $v else . end;
    (if has("scanned_at") then .scanned_at |= setdate($d) else . end)
    | (if (has("static_secret_scan") and (.static_secret_scan|type)=="object" and (.static_secret_scan|has("ran_ts")))
       then .static_secret_scan.ran_ts |= setdate($t) else . end)
    | (if (has("secrets") and (.secrets|type)=="array")
       then .secrets |= map(
              (if (type=="object" and has("last_rotated")) then .last_rotated |= setdate($d) else . end)
            | (if (type=="object" and has("provider_attestation") and (.provider_attestation|type)=="object" and (.provider_attestation|has("attested_ts")))
               then .provider_attestation.attested_ts |= setdate($t) else . end))
       else . end)
  ' "$f" > "$tmp" 2>/dev/null
  # Fail closed on an empty/invalid result rather than writing a truncated fixture.
  if [ ! -s "$tmp" ] || ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; echo "  ERROR: jq produced no valid output for $f (refusing to write)" >&2; return 2
  fi
  # Compare CANONICALLY (jq -S), not byte-wise: jq always re-indents, so a byte compare would report
  # every compact-JSON file as changed and rewrite files whose dates were already current.
  if ! diff -q <(jq -S . "$f" 2>/dev/null) <(jq -S . "$tmp" 2>/dev/null) >/dev/null 2>&1; then
    changed=1
    [ "$mode" = "write" ] && cat "$tmp" > "$f"
  fi
  rm -f "$tmp"
  return $changed
}

# The playbook is JSONL, so it needs line-wise rewriting rather than a single jq document pass.
# ONLY fixtures that declare an offset marker are touched: `playbook-fresh` pins valid_until far in the
# future on purpose and must stay byte-identical.
refresh_jsonl() {
  local f="$1" mode="$2" changed=0 tmp
  local fxroot="${f%/walteur-kit/*}"   # shortest suffix — see refresh_file
  [ -f "$fxroot/walteur-kit/.refresh-offset-days" ] || return 0
  local off target; off="$(offset_days "$fxroot")"; target="$(date_minus_days "$off")"
  tmp="$(mktemp)"
  while IFS= read -r line; do
    if [ -z "$(printf '%s' "$line" | tr -d '[:space:]\r')" ]; then printf '%s\n' "$line" >> "$tmp"; continue; fi
    printf '%s' "$line" | jq -ce --arg d "$target" \
      'if (has("valid_until") and (.valid_until|type)=="string" and (.valid_until|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))
       then .valid_until = $d else . end' >> "$tmp" 2>/dev/null \
      || { rm -f "$tmp"; echo "  ERROR: unparseable JSONL line in $f (refusing to write)" >&2; return 2; }
  done < "$f"
  [ -s "$tmp" ] || { rm -f "$tmp"; echo "  ERROR: empty result for $f (refusing to write)" >&2; return 2; }
  if ! diff -q --strip-trailing-cr "$f" "$tmp" >/dev/null 2>&1; then
    changed=1
    [ "$mode" = "write" ] && cat "$tmp" > "$f"
  fi
  rm -f "$tmp"
  return $changed
}

collect() { find "$FX" -type f -name '*.json' -path '*walteur-kit*' 2>/dev/null | sort; }
collect_jsonl() { find "$FX" -type f -name '*.jsonl' -path '*walteur-kit*' 2>/dev/null | sort; }

main() {
  local mode="${1:-write}" stale=0 total=0
  [ -f "$ROOT/walteur-kit/PAUSED" ] && { echo "refresh-fixture-dates: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_FIXDATE:-on}" = "off" ] && { echo "refresh-fixture-dates: bypassed" >&2; exit 0; }
  have jq || { echo "refresh-fixture-dates: FAIL - jq absent; refusing to edit fixtures unsafely" >&2; exit 2; }
  [ -d "$FX" ] || { echo "refresh-fixture-dates: SKIP (no fixtures dir)"; exit 0; }

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    total=$((total+1))
    refresh_file "$f" "$mode"; local rc=$?
    [ "$rc" = "2" ] && exit 2
    if [ "$rc" = "1" ]; then
      stale=$((stale+1))
      echo "  $([ "$mode" = "write" ] && echo REFRESHED || echo STALE): ${f#$ROOT/}"
    fi
  done < <(collect)

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    total=$((total+1))
    refresh_jsonl "$f" "$mode"; local rc=$?
    [ "$rc" = "2" ] && exit 2
    if [ "$rc" = "1" ]; then
      stale=$((stale+1))
      echo "  $([ "$mode" = "write" ] && echo REFRESHED || echo STALE): ${f#$ROOT/}"
    fi
  done < <(collect_jsonl)

  if [ "$mode" = "check" ]; then
    [ "$stale" -gt 0 ] && { echo "refresh-fixture-dates: $stale of $total fixture manifest(s) carry stale dates -> exit 2" >&2; exit 2; }
    echo "refresh-fixture-dates: PASS - all $total fixture manifests carry current dates"; exit 0
  fi
  echo "refresh-fixture-dates: refreshed $stale of $total fixture manifest(s) to $TODAY"
  exit 0
}

# --verify: refresh, then prove the refresh did not change any twin's verdict. This is the check that
# makes regenerating dates defensible rather than a fudge.
verify() {
  local FW="${WALTEUR_FRAMEWORK:-D:/Walteur/walteur-framework}"
  local H="$FW/walteur-kit/hooks"
  [ -d "$H" ] || { echo "refresh-fixture-dates --verify: SKIP (set WALTEUR_FRAMEWORK to a tree with walteur-kit/hooks)"; exit 0; }
    # SUBSHELL, not a bare call. `main` ends in `exit 0`, and a redirection on a function call does not
  # create a subshell — so `main write >/dev/null` terminated the whole script right here, silently,
  # with status 0. `--verify` therefore printed nothing, ran ZERO twins, and reported success. It was
  # wired into CI in that state: a verification step that verified nothing and could never fail.
  # The fail-closed twin-count guard below existed the whole time and never got the chance to run.
  ( main write ) >/dev/null 2>&1 || true
  local pass=0 fail=0
  check_twin() { # fixture, gate, want
    local t; t="$(mktemp -d)"; cp -R "$FX/$1/." "$t"/ 2>/dev/null
    WALTEUR_ROOT="$t" bash "$H/$2" >/dev/null 2>&1; local rc=$?
    rm -rf "$t"
    if [ "$rc" = "$3" ]; then echo "  ok   - $1 via $2 (rc=$rc)"; pass=$((pass+1));
    else echo "  FAIL - $1 via $2 (want $3 got $rc)"; fail=$((fail+1)); fi
  }
  echo "refresh-fixture-dates --verify (post-refresh twin behaviour):"
  check_twin cve-clean        cve-gate.sh             0
  check_twin cve-poisoned     cve-gate.sh             2
  check_twin secrot-clean     secret-rotation-gate.sh 0
  check_twin secrot-poisoned  secret-rotation-gate.sh 2
  # BOUNDARY twins. These are the reason offset markers exist, and they are the strictest possible
  # check on the refresh: they sit EXACTLY on a calendar threshold, so a refresh that is off by one
  # day in either direction flips them. If the refresher ever mis-dates, these fail first.
  check_twin cve-at-window-edge cve-gate.sh              0
  check_twin mem-expires-today  memory-staleness-gate.sh 0
  echo "refresh-fixture-dates --verify: $pass/$((pass+fail)) twins behave after refresh"
  # FAIL CLOSED if the twins could not actually be run. Observed for real: under fork exhaustion on
  # Windows/Git-Bash every check_twin died before producing a verdict, and this returned 0 — a
  # "verification passed" that verified nothing. A count that does not reach the expected total is a
  # failure to verify, which is not the same as a verification that passed.
  local expected=6
  if [ $((pass+fail)) -ne "$expected" ]; then
    echo "refresh-fixture-dates --verify: FAIL - only $((pass+fail))/$expected twins could be run (environment problem, not a pass)" >&2
    exit 2
  fi
  [ "$fail" -eq 0 ] || exit 2
  exit 0
}

selftest() {
  local pass=0 fail=0
  have jq || { echo "refresh-fixture-dates selftest SKIP - no jq."; return 0; }
  echo "refresh-fixture-dates selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  mkworld() {
    local d="$1" when="$2"
    mkdir -p "$d/eval-harness-additions/fixtures/a/walteur-kit"
    jq -n --arg w "$when" '{scanned_at:$w, vulnerabilities:[]}' > "$d/eval-harness-additions/fixtures/a/walteur-kit/cve-report.json"
    jq -n --arg w "${when}T00:00:00Z" --arg d2 "$when" '{static_secret_scan:{ran_ts:$w,tool:"gitleaks"},secrets:[{name:"X",last_rotated:$d2,provider_attestation:{attested_ts:$w}}]}' \
      > "$d/eval-harness-additions/fixtures/a/walteur-kit/secrets-policy.json"
    cp "$SELF" "$d/eval-harness-additions/refresh-fixture-dates.sh"
  }
  run() { WALTEUR_APEX_ROOT="$1" bash "$1/eval-harness-additions/refresh-fixture-dates.sh" "${2:-}" >/dev/null 2>&1; echo $?; }

  # 1. stale dates -> --check FAILs
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/fixdate.XXXXXX")"; mkworld "$t" "2001-01-01"
  ck "stale dates -> --check FAIL" 2 "$(run "$t" --check)"; rm -rf "$t"

  # 2. rewrite then --check passes (the actual fix)
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixdate.XXXXXX")"; mkworld "$t" "2001-01-01"
  run "$t" >/dev/null
  ck "after refresh -> --check PASS" 0 "$(run "$t" --check)"; rm -rf "$t"

  # 3. the rewrite actually wrote today's date
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixdate.XXXXXX")"; mkworld "$t" "2001-01-01"
  run "$t" >/dev/null
  jq -e --arg d "$TODAY" '.scanned_at==$d' "$t/eval-harness-additions/fixtures/a/walteur-kit/cve-report.json" >/dev/null 2>&1
  ck "scanned_at rewritten to today" 0 "$?"
  jq -e --arg d "$TODAY" '(.secrets[0].last_rotated==$d) and (.static_secret_scan.ran_ts|startswith($d))' \
    "$t/eval-harness-additions/fixtures/a/walteur-kit/secrets-policy.json" >/dev/null 2>&1
  ck "ran_ts + last_rotated rewritten to today" 0 "$?"; rm -rf "$t"

  # 4. idempotent — a second run changes nothing
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixdate.XXXXXX")"; mkworld "$t" "2001-01-01"
  run "$t" >/dev/null
  local before after
  before="$(cat "$t/eval-harness-additions/fixtures/a/walteur-kit/cve-report.json")"
  run "$t" >/dev/null
  after="$(cat "$t/eval-harness-additions/fixtures/a/walteur-kit/cve-report.json")"
  [ "$before" = "$after" ]; ck "idempotent on a second run" 0 "$?"; rm -rf "$t"

  # 5. NON-date fields are never touched (no collateral edits)
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixdate.XXXXXX")"; mkworld "$t" "2001-01-01"
  run "$t" >/dev/null
  jq -e '.static_secret_scan.tool=="gitleaks" and (.secrets[0].name=="X")' \
    "$t/eval-harness-additions/fixtures/a/walteur-kit/secrets-policy.json" >/dev/null 2>&1
  ck "non-date fields untouched" 0 "$?"; rm -rf "$t"

  # 6. a manifest with no recency fields is left byte-identical
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixdate.XXXXXX")"; mkworld "$t" "2001-01-01"
  printf '{"risk_tier":"high"}' > "$t/eval-harness-additions/fixtures/a/walteur-kit/build-contract.json"
  run "$t" >/dev/null
  [ "$(cat "$t/eval-harness-additions/fixtures/a/walteur-kit/build-contract.json")" = '{"risk_tier":"high"}' ]
  ck "unrelated manifest byte-identical" 0 "$?"; rm -rf "$t"

  # 7. bypass
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixdate.XXXXXX")"; mkworld "$t" "2001-01-01"
  WALTEUR_APEX_ROOT="$t" WALTEUR_FIXDATE=off bash "$t/eval-harness-additions/refresh-fixture-dates.sh" --check >/dev/null 2>&1
  ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"

  # 8. OFFSET MARKER — a boundary fixture is re-dated to exactly N days ago, not to today.
  #    The first version of this returned an EMPTY offset (a `local d="$1" m="$d/…"` unbound-variable
  #    abort under set -u) and `date -d " days ago"` accepted it, producing a plausible wrong date with
  #    no error. Assert the exact date, not merely "it changed".
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixdate.XXXXXX")"; mkworld "$t" "2001-01-01"
  printf '14\n' > "$t/eval-harness-additions/fixtures/a/walteur-kit/.refresh-offset-days"
  run "$t" >/dev/null
  jq -e --arg d "$(date -u -d '14 days ago' +%Y-%m-%d)" '.scanned_at==$d' \
    "$t/eval-harness-additions/fixtures/a/walteur-kit/cve-report.json" >/dev/null 2>&1
  ck "offset marker re-dates to exactly N days ago" 0 "$?"
  ck "offset fixture is idempotent -> --check PASS" 0 "$(run "$t" --check)"; rm -rf "$t"

  # 8b. THE ADOPTED LAYOUT, where the path carries TWO `/walteur-kit/` segments. `${f%%/walteur-kit/*}`
  #     strips from the FIRST and returns the repo root, so no offset marker is ever found and every
  #     boundary fixture is silently re-dated to today — the fixture built to sit on the 14-day
  #     threshold quietly moved off it. Passed the apex-layout selftest above; failed on the real tree.
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixdate.XXXXXX")"
  mkdir -p "$t/walteur-kit/eval-harness/fixtures/edge/walteur-kit"
  jq -n '{scanned_at:"2001-01-01",vulnerabilities:[]}' > "$t/walteur-kit/eval-harness/fixtures/edge/walteur-kit/cve-report.json"
  printf '14\n' > "$t/walteur-kit/eval-harness/fixtures/edge/walteur-kit/.refresh-offset-days"
  cp "$SELF" "$t/walteur-kit/eval-harness/refresh-fixture-dates.sh"
  WALTEUR_APEX_ROOT="$t" bash "$t/walteur-kit/eval-harness/refresh-fixture-dates.sh" >/dev/null 2>&1
  jq -e --arg d "$(date -u -d '14 days ago' +%Y-%m-%d)" '.scanned_at==$d' \
    "$t/walteur-kit/eval-harness/fixtures/edge/walteur-kit/cve-report.json" >/dev/null 2>&1
  ck "offset marker resolves in the ADOPTED (nested walteur-kit) layout" 0 "$?"; rm -rf "$t"

  # 9. A MALFORMED marker must fall back to today, never to whatever `date -d` makes of the garbage.
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixdate.XXXXXX")"; mkworld "$t" "2001-01-01"
  printf 'banana\n' > "$t/eval-harness-additions/fixtures/a/walteur-kit/.refresh-offset-days"
  run "$t" >/dev/null
  jq -e --arg d "$TODAY" '.scanned_at==$d' \
    "$t/eval-harness-additions/fixtures/a/walteur-kit/cve-report.json" >/dev/null 2>&1
  ck "malformed offset marker falls back to today" 0 "$?"; rm -rf "$t"

  # 10. JSONL valid_until is re-dated ONLY where a marker exists — playbook-fresh must stay pinned.
  t="$(mktemp -d "${TMPDIR:-/tmp}/fixdate.XXXXXX")"; mkworld "$t" "2001-01-01"
  mkdir -p "$t/eval-harness-additions/fixtures/pinned/walteur-kit"
  printf '{"id":"p1","fact":"pinned","valid_until":"2099-12-31"}\n' > "$t/eval-harness-additions/fixtures/pinned/walteur-kit/playbook.jsonl"
  printf '{"id":"e1","fact":"edge","valid_until":"2001-01-01"}\n' > "$t/eval-harness-additions/fixtures/a/walteur-kit/playbook.jsonl"
  printf '0\n' > "$t/eval-harness-additions/fixtures/a/walteur-kit/.refresh-offset-days"
  run "$t" >/dev/null
  jq -e --arg d "$TODAY" '.valid_until==$d' "$t/eval-harness-additions/fixtures/a/walteur-kit/playbook.jsonl" >/dev/null 2>&1
  ck "marked playbook valid_until re-dated to today" 0 "$?"
  [ "$(cat "$t/eval-harness-additions/fixtures/pinned/walteur-kit/playbook.jsonl")" = '{"id":"p1","fact":"pinned","valid_until":"2099-12-31"}' ]
  ck "unmarked playbook left byte-identical" 0 "$?"; rm -rf "$t"

  echo "refresh-fixture-dates selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --check)    main check ;;
  --verify)   verify ;;
  *)          main write ;;
esac
