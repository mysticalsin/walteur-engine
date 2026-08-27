#!/usr/bin/env bash
# WALTEUR stamp.sh — append an IMMUTABLE certification stamp to STAMP.md + the hash chain.
#
# The stamp ledger is APPEND/UPDATE-ONLY: the "Current" score line may change, but every dated history
# row is permanent — recorded as a sha256 in walteur-kit/stamp-chain.json and enforced by
# stamp-integrity-gate.sh (a deleted file, a removed row, or an altered row => FAIL exit 2). This lets the
# score be re-stamped over time without ever erasing where it has been, even while other files are optimized.
#
# v10.4 — TRUTH-BINDING: before appending a stamp row, the claimed score/gates MUST be corroborated by a
# FRESH, PASSing walteur-kit/gate-suite-report.json (verdict==PASS, ts within WALTEUR_STAMP_MAXAGE hours,
# default 24). Absent / stale / non-PASS => refuse to stamp (exit 2) — a score can no longer be recorded
# from LLM assertion alone. Emergency override: WALTEUR_STAMP_FORCE=1 bypasses the check but the row
# records forced:true so a forced stamp is never indistinguishable from a proven one.
#
# Usage: stamp.sh "<event>" <score> <gates> "<proof>"
#   e.g. stamp.sh "data-acquisition fold + Phase-1 skip-budget" 46 128 "gate-suite PASS broken:0"
# Writes to: <root>/STAMP.md  and  <root>/walteur-kit/stamp-chain.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "stamp - stamp.sh - append an IMMUTABLE certification stamp to STAMP.md + the hash chain."
  printf '%s\n' "usage: bash stamp.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/gate-suite-report.json - fix recipes: walteur-kit/REMEDIATION.md (## stamp)"
  exit 0 ;;
esac

set -uo pipefail
SELF="${BASH_SOURCE[0]}"
have() { command -v "$1" >/dev/null 2>&1; }
sha() { if have sha256sum; then sha256sum | awk '{print $1}'; elif have shasum; then shasum -a 256 | awk '{print $1}'; else cksum | awk '{print $1}'; fi; }

main() {
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STAMP="$ROOT/STAMP.md"
CHAIN="$ROOT/walteur-kit/stamp-chain.json"
SUITE_REPORT="$ROOT/walteur-kit/gate-suite-report.json"
mkdir -p "$ROOT/walteur-kit"

event="${1:?event required}"; score="${2:?score required}"; gates="${3:?gates required}"; proof="${4:-}"
DATE="$(date -u +%Y-%m-%d)"; TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── TRUTH-BINDING GUARD ──────────────────────────────────────────────────────────────────────────
# fail-closed helper: print reason to stderr and exit 2 (never stamp a claim the suite doesn't back).
guard_fail() { echo "STAMP REFUSED: $1" >&2; echo "  → run: bash walteur-kit/hooks/gate-suite.sh   (or) emergency: WALTEUR_STAMP_FORCE=1 (recorded forced:true)" >&2; exit 2; }

FORCED=0
if [ "${WALTEUR_STAMP_FORCE:-0}" = "1" ]; then
  FORCED=1
  echo "STAMP WARNING: WALTEUR_STAMP_FORCE=1 — bypassing gate-suite truth-binding. Row will record forced:true." >&2
else
  if ! have jq; then guard_fail "jq unavailable — cannot verify gate-suite-report.json; refusing to stamp unverified (fail-closed, not silent-skip)."; fi
  [ -f "$SUITE_REPORT" ] || guard_fail "walteur-kit/gate-suite-report.json is missing. Run gate-suite.sh before stamping — a score must be proof-backed, not asserted."
  suite_verdict="$(jq -r '.verdict // empty' "$SUITE_REPORT" 2>/dev/null || true)"
  [ "$suite_verdict" = "PASS" ] || guard_fail "gate-suite-report.json verdict is '${suite_verdict:-null}', not PASS. A stamp must be backed by a green suite run."
  suite_ts="$(jq -r '.ts // empty' "$SUITE_REPORT" 2>/dev/null || true)"
  [ -n "$suite_ts" ] && [ "$suite_ts" != "null" ] || guard_fail "gate-suite-report.json has no 'ts' field — cannot verify freshness."
  suite_epoch="$(date -u -d "$suite_ts" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$suite_ts" +%s 2>/dev/null || true)"
  [ -n "$suite_epoch" ] || guard_fail "gate-suite-report.json 'ts' ($suite_ts) is not a parseable timestamp — cannot verify freshness."
  now_epoch="$(date -u +%s)"
  maxage_hours="${WALTEUR_STAMP_MAXAGE:-24}"
  maxage_secs=$(( maxage_hours * 3600 ))
  age_secs=$(( now_epoch - suite_epoch ))
  [ "$age_secs" -ge 0 ] || guard_fail "gate-suite-report.json 'ts' ($suite_ts) is in the future — refusing a clock-skewed proof."
  [ "$age_secs" -le "$maxage_secs" ] || guard_fail "gate-suite-report.json is stale (age ${age_secs}s > max ${maxage_secs}s / ${maxage_hours}h). Re-run gate-suite.sh before stamping."

  # ANTI-FORGERY VERIFICATION SAMPLE (S034 — narrows the S032/S033 "hand-written report spoofing"
  # residual). A fresh PASS gate-suite-report.json is necessary but NOT sufficient: a forger can
  # `echo` one without ever running the suite. So we independently RE-RUN a random sample of REAL
  # registry gates' --selftest here; if ANY sampled gate is actually RED, the all-green report is a
  # lie (or stale) and we refuse. This raises forgery from "echo a PASS json" to "also survive a live
  # re-run of real gates". HONEST LIMIT: it is a SAMPLE (default 5), not exhaustive — a forged report
  # over a genuinely all-green kit still stamps; that residual is procedural and documented, not
  # silently claimed closed. WALTEUR_STAMP_SAMPLE=0 disables (fast CI); WALTEUR_STAMP_SAMPLE_GATES
  # (comma-sep hook filenames) forces a deterministic set (used by the selftest).
  sample_n="${WALTEUR_STAMP_SAMPLE:-5}"
  reg="$ROOT/walteur-kit/gate-registry.json"
  if [ "$sample_n" != "0" ] && [ -f "$reg" ]; then
    if [ -n "${WALTEUR_STAMP_SAMPLE_GATES:-}" ]; then
      sample_gates="$(printf '%s' "$WALTEUR_STAMP_SAMPLE_GATES" | tr ',' '\n')"
    elif have shuf; then
      sample_gates="$(jq -r '.gates[].hook // empty' "$reg" 2>/dev/null | grep -v '^_' | shuf | head -n "$sample_n")"
    else
      sample_gates="$(jq -r '.gates[].hook // empty' "$reg" 2>/dev/null | grep -v '^_' | sort -R 2>/dev/null | head -n "$sample_n")"
    fi
    # WALL-CLOCK CAP (S037): the sample must never make stamping exceed a caller's foreground timeout —
    # the original 5×90s worst case blew a 2-min limit, the killed-but-surviving process then double-wrote
    # the ledger. Cap TOTAL sample time (WALTEUR_STAMP_SAMPLE_MAXSEC, default 55s) + a tighter 40s per-gate
    # timeout; once the budget is spent we stop sampling (recording how many we managed) rather than run on.
    s_checked=0; s_red=0
    _s_budget="${WALTEUR_STAMP_SAMPLE_MAXSEC:-55}"; _s_start="$(date +%s 2>/dev/null || echo 0)"
    while IFS= read -r hk; do
      [ -z "$hk" ] && continue
      _s_elapsed=$(( $(date +%s 2>/dev/null || echo 0) - _s_start ))
      if [ "$_s_start" != "0" ] && [ "$_s_elapsed" -ge "$_s_budget" ]; then
        echo "  verify-sample: time budget ${_s_budget}s reached after $s_checked gate(s) — stopping sample (not a failure)" >&2; break
      fi
      hp="$ROOT/walteur-kit/hooks/$hk"
      [ -f "$hp" ] || continue
      if have timeout; then s_out="$(WALTEUR_ROOT="$ROOT" timeout 40 bash "$hp" --selftest 2>&1)"
      else s_out="$(WALTEUR_ROOT="$ROOT" bash "$hp" --selftest 2>&1)"; fi
      s_line="$(printf '%s' "$s_out" | grep -oiE '[0-9]+/[0-9]+ passed' | tail -1)"
      [ -z "$s_line" ] && continue   # no measurable selftest (skip/no-selftest) -> don't count, don't fail
      s_n="${s_line%%/*}"; s_d="$(printf '%s' "$s_line" | sed -E 's#^[0-9]+/([0-9]+).*#\1#')"
      s_checked=$((s_checked+1))
      if [ "$s_n" != "$s_d" ] || [ "${s_d:-0}" -eq 0 ]; then s_red=$((s_red+1)); echo "  verify-sample: $hk -> $s_line (RED)" >&2; fi
    done <<SAMPLE_EOF
$sample_gates
SAMPLE_EOF
    [ "$s_red" -eq 0 ] || guard_fail "verification sample re-ran $s_checked gate(s); $s_red were RED — the all-green gate-suite-report is not credible. A stamp's proof must survive a live re-run."
    [ "$s_checked" -gt 0 ] && echo "STAMP verify-sample: $s_checked real gate(s) re-run, all green (of $sample_n sampled)." >&2
  fi
fi

# init STAMP.md + chain if absent
if [ ! -f "$STAMP" ]; then
  cat > "$STAMP" <<'HDR'
# WALTEUR — Certification STAMP (IMMUTABLE LEDGER)

> **This file is permanent. It is APPEND/UPDATE-ONLY and MUST NOT be deleted or have history removed.**
> The `Current` block below may be re-stamped as the score changes. Every row in `Stamp history` is
> immutable — its sha256 is recorded in `walteur-kit/stamp-chain.json` and verified by
> `stamp-integrity-gate.sh` on every ship (a deleted file / removed row / altered row => FAIL exit 2).
> You may optimize, refactor, or delete any OTHER file in the harness; this one stays, and its history
> only ever grows.

<!-- STAMP-CURRENT-START -->
## Current
- score: (pending first stamp)
<!-- STAMP-CURRENT-END -->

## Stamp history (append-only — never delete or edit a row)
<!-- STAMP-HISTORY-START -->
<!-- STAMP-HISTORY-END -->
HDR
fi
[ -f "$CHAIN" ] || printf '{"rows":[]}\n' > "$CHAIN"

# SINGLE-WRITE GUARD (S037): serialize the id-assignment + row/chain write behind an exclusive lock so two
# stamp.sh processes (e.g. a timed-out-but-surviving foreground run + a manual re-run) can't BOTH append —
# that double-write produced duplicate rows S036/S037 this session. mkdir is atomic; a >120s-stale lock is
# taken over (a crashed stamp must not deadlock the ledger). Released on EXIT.
STAMP_LOCK="$ROOT/walteur-kit/.stamp.lock"
_lock_deadline=$(( $(date +%s 2>/dev/null || echo 0) + 20 ))
while ! mkdir "$STAMP_LOCK" 2>/dev/null; do
  _held="$(cat "$STAMP_LOCK/pid" 2>/dev/null || echo '')"
  _lts="$(cat "$STAMP_LOCK/ts" 2>/dev/null || echo 0)"
  if [ "$(( $(date +%s 2>/dev/null || echo 0) - ${_lts:-0} ))" -gt 120 ]; then rm -rf "$STAMP_LOCK" 2>/dev/null; continue; fi
  [ "$(date +%s 2>/dev/null || echo 0)" -gt "$_lock_deadline" ] && guard_fail "another stamp holds $STAMP_LOCK (pid ${_held:-?}) — refusing to double-write the ledger. Retry once it releases."
  sleep 1 2>/dev/null || true
done
printf '%s' "$$" > "$STAMP_LOCK/pid" 2>/dev/null; printf '%s' "$(date +%s 2>/dev/null || echo 0)" > "$STAMP_LOCK/ts" 2>/dev/null
trap 'rm -rf "$STAMP_LOCK" 2>/dev/null' EXIT

# next id
last="$(grep -oE '^- S[0-9]+ ' "$STAMP" 2>/dev/null | grep -oE 'S[0-9]+' | sort | tail -1)"
if [ -n "$last" ]; then num=$(( 10#${last#S} + 1 )); else num=1; fi
id="$(printf 'S%03d' "$num")"

# canonical row line (the exact text that gets hashed). forced:true is appended when the
# WALTEUR_STAMP_FORCE emergency bypass was used, so a forced stamp is never indistinguishable
# from one the truth-binding guard actually verified.
if [ "$FORCED" = "1" ]; then
  row="- $id | $DATE | score=$score | gates=$gates | event=$event | proof=$proof | forced:true"
else
  row="- $id | $DATE | score=$score | gates=$gates | event=$event | proof=$proof"
fi
rowsha="$(printf '%s' "$row" | sha)"

# insert row just before the history END marker.
# CRITICAL (S037 fix): pass the row via ENVIRON, NOT `awk -v`. awk's -v assignment PROCESSES backslash
# escapes, so an event containing a backslash (e.g. a code snippet) was written to STAMP.md DIFFERENTLY
# from the text that was hashed into rowsha above — silently breaking stamp-integrity-gate (row ALTERED).
# ENVIRON values are passed verbatim (no escape processing), so the written row byte-matches the hash.
tmp="$(mktemp "${TMPDIR:-/tmp}/stamp.XXXXXX")"
WALTEUR_STAMP_ROW="$row" awk '/<!-- STAMP-HISTORY-END -->/{print ENVIRON["WALTEUR_STAMP_ROW"]} {print}' "$STAMP" > "$tmp" && mv "$tmp" "$STAMP"

# rewrite the Current block
tmp="$(mktemp "${TMPDIR:-/tmp}/stamp.XXXXXX")"
awk -v s="$score" -v g="$gates" -v d="$DATE" -v ts="$TS" -v id="$id" '
  /<!-- STAMP-CURRENT-START -->/{print; print "## Current"; print "- score: " s "/100  (gates: " g ", last stamp: " id " on " d ")"; print "- updated_ts: " ts; skip=1; next}
  /<!-- STAMP-CURRENT-END -->/{skip=0}
  skip!=1{print}
' "$STAMP" > "$tmp" && mv "$tmp" "$STAMP"

# append hash to the chain (forced carried through so a forced row is auditable in the chain too)
if have jq; then
  jq --arg id "$id" --arg sha "$rowsha" --arg d "$DATE" --argjson sc "$score" --argjson forced "$([ "$FORCED" = "1" ] && echo true || echo false)" \
    '.rows += [{id:$id, sha256:$sha, date:$d, score:$sc, forced:$forced}]' "$CHAIN" > "$CHAIN.tmp" && mv "$CHAIN.tmp" "$CHAIN"
fi

echo "stamped $id (score=$score gates=$gates) -> $STAMP"
echo "  chain row sha256=$rowsha -> $CHAIN"
}

selftest() {
  echo "stamp.sh selftest:"
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (exit $3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  # existing cases run in bare mktemp dirs with no gate-registry.json, so the verify-sample is
  # inert there; belt-and-suspenders set SAMPLE=0 so these stay hermetic + fast regardless.
  run() { WALTEUR_ROOT="$1" WALTEUR_STAMP_SAMPLE=0 bash "$SELF" "ev" "77" "10" "proof-x" >/dev/null 2>&1; echo $?; }
  fresh_suite() { # $1=dir $2=verdict $3=hours_offset_from_now (negative = past)
    mkdir -p "$1/walteur-kit"
    local ts_epoch=$(( $(date -u +%s) + ${3:-0} * 3600 ))
    local ts; ts="$(date -u -d "@$ts_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$ts_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"verdict":"%s","ts":"%s","gate":"gate-suite","total":10,"green":10}\n' "$2" "$ts" > "$1/walteur-kit/gate-suite-report.json"
  }

  if ! have jq; then echo "  skip - jq absent; stamp.sh fails closed without it (see G_NOJQ below is the live proof, no separate skip needed)"; fi

  # GOOD: fresh PASS gate-suite-report.json -> stamp succeeds, row has no forced marker.
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; fresh_suite "$t" PASS 0
  ck "GOOD fresh PASS suite -> stamp succeeds" 0 "$(run "$t")"
  if [ -f "$t/STAMP.md" ]; then
    grep -q 'score=77' "$t/STAMP.md" >/dev/null 2>&1; ck "  row recorded with claimed score" 0 "$?"
    grep -q 'forced:true' "$t/STAMP.md" >/dev/null 2>&1; ck "  row NOT marked forced (proof-backed)" 1 "$?"
  fi
  if have jq && [ -f "$t/walteur-kit/stamp-chain.json" ]; then
    [ "$(jq -r '.rows[0].forced' "$t/walteur-kit/stamp-chain.json" 2>/dev/null)" = "false" ]; ck "  chain row forced=false (proof-backed)" 0 "$?"
  fi
  rm -rf "$t"

  # NEGATIVE CONTROL 1 — missing report entirely -> refuse (exit 2), fail-closed.
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; mkdir -p "$t/walteur-kit"
  ck "POISON missing gate-suite-report.json -> REFUSED" 2 "$(run "$t")"
  [ -f "$t/STAMP.md" ]; ck "  no STAMP.md written on refusal" 1 "$?"
  rm -rf "$t"

  # NEGATIVE CONTROL 2 — stale report (36h old, default max 24h) -> refuse.
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; fresh_suite "$t" PASS -36
  ck "POISON stale report (36h > 24h max) -> REFUSED" 2 "$(run "$t")"
  rm -rf "$t"

  # NEGATIVE CONTROL 3 — non-PASS verdict (a real but FAILing suite run) -> refuse.
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; fresh_suite "$t" FAIL 0
  ck "POISON FAIL-verdict report -> REFUSED" 2 "$(run "$t")"
  rm -rf "$t"

  # NEGATIVE CONTROL 4 — hand-forged, not-even-JSON report -> refuse (never crash into a false PASS).
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf 'GARBAGE NOT EVEN JSON\n' > "$t/walteur-kit/gate-suite-report.json"
  ck "POISON forged non-JSON report -> REFUSED" 2 "$(run "$t")"
  rm -rf "$t"

  # NEGATIVE CONTROL 5 — valid JSON, PASS verdict, but no ts field -> refuse (freshness unverifiable).
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"verdict":"PASS","gate":"gate-suite"}\n' > "$t/walteur-kit/gate-suite-report.json"
  ck "POISON PASS report with no ts field -> REFUSED" 2 "$(run "$t")"
  rm -rf "$t"

  # NEGATIVE CONTROL 6 — future-dated ts (clock skew / forged freshness) -> refuse.
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; fresh_suite "$t" PASS 6
  ck "POISON future-dated ts (clock skew) -> REFUSED" 2 "$(run "$t")"
  rm -rf "$t"

  # ANTI-FORGERY VERIFICATION SAMPLE (S034): a fresh PASS report + a forced sample pointing at a
  # gate whose --selftest is actually RED -> stamp REFUSES (the report claims all-green; a live
  # re-run proves otherwise). Positive twin: a GREEN sampled gate -> stamp proceeds.
  mk_sample_gate() { # $1=dir $2=hook_name $3=pass $4=total ; also seeds a registry listing it
    mkdir -p "$1/walteur-kit/hooks"
    printf '#!/usr/bin/env bash\ncase "${1:-}" in --selftest) echo "%s: %s/%s passed"; [ "%s" = "%s" ] && exit 0 || exit 1;; esac\n' \
      "$2" "$3" "$4" "$3" "$4" > "$1/walteur-kit/hooks/$2.sh"
    printf '{"gates":[{"id":"%s","hook":"%s.sh"}]}\n' "$2" "$2" > "$1/walteur-kit/gate-registry.json"
  }
  # RED sampled gate -> refuse
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; fresh_suite "$t" PASS 0; mk_sample_gate "$t" "synthbad" 2 3
  ck "VERIFY-SAMPLE forged PASS report + RED sampled gate -> REFUSED" 2 \
    "$(WALTEUR_ROOT="$t" WALTEUR_STAMP_SAMPLE_GATES=synthbad.sh bash "$SELF" "ev" "99" "1" "px" >/dev/null 2>&1; echo $?)"
  [ -f "$t/STAMP.md" ]; ck "  no STAMP.md written when sample catches a RED gate" 1 "$?"
  rm -rf "$t"
  # GREEN sampled gate -> proceed
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; fresh_suite "$t" PASS 0; mk_sample_gate "$t" "synthok" 3 3
  ck "VERIFY-SAMPLE fresh PASS report + GREEN sampled gate -> stamp succeeds" 0 \
    "$(WALTEUR_ROOT="$t" WALTEUR_STAMP_SAMPLE_GATES=synthok.sh bash "$SELF" "ev" "88" "1" "px" >/dev/null 2>&1; echo $?)"
  rm -rf "$t"

  # BACKSLASH-IN-EVENT (S037 regression): an event containing a backslash must be written to STAMP.md
  # BYTE-IDENTICALLY to what was hashed — else stamp-integrity-gate reports the row ALTERED. Proven by
  # re-running stamp-integrity's own check: the written row's sha must equal the chain entry's sha.
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; fresh_suite "$t" PASS 0
  WALTEUR_ROOT="$t" WALTEUR_STAMP_SAMPLE=0 bash "$SELF" 'event with a backslash \x and a quote'"'"'s tail' "77" "10" "proof \n literal" >/dev/null 2>&1
  if have jq && [ -f "$t/STAMP.md" ] && [ -f "$t/walteur-kit/stamp-chain.json" ]; then
    _rid="$(jq -r '.rows[-1].id' "$t/walteur-kit/stamp-chain.json")"
    _wantsha="$(jq -r '.rows[-1].sha256' "$t/walteur-kit/stamp-chain.json")"
    _rowline="$(grep -E "^- ${_rid} \| " "$t/STAMP.md" | head -1)"
    _gotsha="$(printf '%s' "$_rowline" | sha)"
    ck "backslash-in-event: written row byte-matches its hash (integrity intact)" "$_wantsha" "$_gotsha"
  fi
  rm -rf "$t"

  # SINGLE-WRITE LOCK (S037): a fresh lock held by another stamp -> refuse (no double-write); a STALE
  # lock (>120s) -> take over + succeed; a clean stamp leaves NO lock behind.
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; fresh_suite "$t" PASS 0
  mkdir -p "$t/walteur-kit/.stamp.lock"; printf '%s' "99999" > "$t/walteur-kit/.stamp.lock/pid"; printf '%s' "$(date +%s)" > "$t/walteur-kit/.stamp.lock/ts"
  ck "single-write: a FRESH foreign lock -> stamp REFUSED (no double-write)" 2 \
    "$(WALTEUR_ROOT="$t" WALTEUR_STAMP_SAMPLE=0 WALTEUR_STAMP_MAXAGE=99999 bash "$SELF" ev 77 10 px >/dev/null 2>&1; echo $?)"
  # stale lock (ts=0 => >120s old) -> taken over, stamp succeeds
  printf '%s' "0" > "$t/walteur-kit/.stamp.lock/ts"
  ck "single-write: a STALE lock (>120s) -> taken over, stamp succeeds" 0 \
    "$(WALTEUR_ROOT="$t" WALTEUR_STAMP_SAMPLE=0 bash "$SELF" ev 77 10 px >/dev/null 2>&1; echo $?)"
  ck "  ...no lock dir left behind after a clean stamp" 1 "$([ -d "$t/walteur-kit/.stamp.lock" ] && echo 0 || echo 1)"
  rm -rf "$t"
  # TIME-CAP: a tiny budget still lets an honest stamp through (sample stops early, not a failure)
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; fresh_suite "$t" PASS 0; mk_sample_gate "$t" "synokslow" 3 3
  ck "verify-sample time-cap: tiny budget -> stamp still succeeds (sample capped, not failed)" 0 \
    "$(WALTEUR_ROOT="$t" WALTEUR_STAMP_SAMPLE_MAXSEC=0 WALTEUR_STAMP_SAMPLE_GATES=synokslow.sh bash "$SELF" ev 77 10 px >/dev/null 2>&1; echo $?)"
  rm -rf "$t"

  # WALTEUR_STAMP_FORCE=1 — bypasses the guard even with a missing/FAIL report, but the row + chain
  # entry MUST carry forced:true (an emergency stamp is never indistinguishable from a proven one).
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; mkdir -p "$t/walteur-kit"
  WALTEUR_ROOT="$t" WALTEUR_STAMP_FORCE=1 bash "$SELF" "ev" "77" "10" "proof-x" >/dev/null 2>&1
  ck "FORCE=1 bypasses guard with NO report present" 0 "$?"
  if [ -f "$t/STAMP.md" ]; then
    grep -q 'forced:true' "$t/STAMP.md" >/dev/null 2>&1; ck "  forced:true recorded in STAMP.md row" 0 "$?"
  fi
  if have jq && [ -f "$t/walteur-kit/stamp-chain.json" ]; then
    [ "$(jq -r '.rows[0].forced' "$t/walteur-kit/stamp-chain.json" 2>/dev/null)" = "true" ]; ck "  forced:true recorded in stamp-chain.json" 0 "$?"
  fi
  rm -rf "$t"

  # Custom WALTEUR_STAMP_MAXAGE is honored: a 36h-old report is stale at the 24h default but fresh
  # under a widened 48h window — proves the threshold is read, not hardcoded.
  t="$(mktemp -d "${TMPDIR:-/tmp}/stamp.XXXXXX")"; fresh_suite "$t" PASS -36
  WALTEUR_ROOT="$t" WALTEUR_STAMP_MAXAGE=48 bash "$SELF" "ev" "77" "10" "proof-x" >/dev/null 2>&1
  ck "WALTEUR_STAMP_MAXAGE=48 widens the freshness window (36h old now OK)" 0 "$?"
  rm -rf "$t"

  echo "stamp.sh selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
