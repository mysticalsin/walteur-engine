#!/usr/bin/env bash
# WALTEUR memory-staleness-gate — HARD gate. Kills the "confidently wrong stale fact" failure mode:
# a memory/playbook fact carried past its re-verification date and used without re-checking. Every
# playbook entry must declare valid_until (YYYY-MM-DD). FAIL on any entry whose valid_until is in the
# PAST, missing, or unparseable (fail-closed — an undated or garbage-dated fact is treated as stale).
#
# Applies when walteur-kit/playbook.json OR walteur-kit/playbook.jsonl exists, OR when a lessons store
# (walteur-kit/memory/lessons.jsonl — the corpus recall actually reads) exists.
#
# TWO SURFACES (the second added by panel #12). Before it, this gate — the ONLY hardness=hard memory gate —
# reported NOT_APPLICABLE on every run of this repo, because no playbook.json has ever existed here. A HARD
# gate that cannot fire is theater, and the failure it exists to stop (a stale fact reused without
# re-checking) was happening on the OTHER memory surface: the lessons corpus went 19 days without a capture
# while its global read-replica drifted 6 lessons behind canonical, and nothing surfaced either. So the gate
# now also enforces the LESSONS STORE:
#   · unparseable row(s)                         => FAIL (a corpus recall cannot read cannot be vouched for)
#   · no parseable .ts anywhere                  => FAIL (freshness unprovable — fail-closed)
#   · newest lesson older than the HARD window   => FAIL (WALTEUR_MEMSTALE_DAYS, default 30 — lesson-gate
#                                                   WARNs at 14, so this is the escalation for a WARN that
#                                                   was ignored for another 16 days)
#   · global read-replica DRIFTED from canonical => FAIL (repair: bash walteur-kit/memory/memory-sync.sh)
# An ABSENT store is not a failure here (a fresh clone has no lessons yet) — that is lesson-gate's WARN.
# CONTRACT: any past/missing/unparseable valid_until => FAIL exit 2 · any lessons-store violation => FAIL
# exit 2 · no playbook AND no lessons store => NOT_APPLICABLE · jq absent => SKIP · PAUSED => exit 2 ·
# bypass WALTEUR_MEMSTALE=off.
# Report: walteur-kit/memory-staleness-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "memory-staleness-gate - HARD gate. Kills the confidently wrong stale fact failure mode:"
  printf '%s\n' "usage: bash memory-staleness-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "surfaces: walteur-kit/playbook.json|.jsonl (valid_until per entry) AND the lessons store"
  printf '%s\n' "  (\${WALTEUR_MEM:-walteur-kit/memory}/lessons.jsonl): parseable rows, newest .ts within"
  printf '%s\n' "  \${WALTEUR_MEMSTALE_DAYS:-30}d, and no drift between canonical and the global read-replica."
  printf '%s\n' "report: walteur-kit/memory-staleness-report.json - fix recipes: walteur-kit/REMEDIATION.md (## memory-staleness-gate)"
  printf '%s\n' "bypass: WALTEUR_MEMSTALE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
PB_JSON="$KIT/playbook.json"
PB_JSONL="$KIT/playbook.jsonl"
REPORT="$KIT/memory-staleness-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TODAY="$(date -u +%Y-%m-%d)"
# Portable YYYY-MM-DD -> epoch: try GNU date -d first, then BSD date -j -f (macOS/*BSD has no -d).
parse_ymd_epoch() {
  d="$1"
  out="$(date -u -d "$d" +%s 2>/dev/null)"
  case "$out" in ''|*[!0-9]*) out="$(date -j -u -f "%Y-%m-%d" "$d" +%s 2>/dev/null)";; esac
  printf '%s' "$out"
}
# Compare calendar days: an entry's valid_until is parsed to that day's UTC midnight, so we must
# compare against TODAY's UTC midnight (not the wall-clock instant). valid_until==today is still valid.
TODAY_EPOCH="$(parse_ymd_epoch "$TODAY")"
case "$TODAY_EPOCH" in ''|*[!0-9]*) TODAY_EPOCH="$(date -u +%s)";; esac
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"memory-staleness", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"memory-staleness","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

# ---- LESSONS-STORE surface. Same store resolution as hooks/lesson-gate.sh so both gates judge the same
# file: explicit WALTEUR_MEM wins, else the co-located campaign store when it exists, else the per-user default.
MEM_DIR="${WALTEUR_MEM:-}"
if [ -z "$MEM_DIR" ]; then
  if [ -f "$KIT/memory/lessons.jsonl" ]; then MEM_DIR="$KIT/memory"; else MEM_DIR="$HOME/.walteur/memory"; fi
fi
STORE="$MEM_DIR/lessons.jsonl"
REPLICA_DIR="${WALTEUR_GLOBAL_MEM:-$HOME/.walteur/memory}"
REPLICA="$REPLICA_DIR/lessons.jsonl"
MEM_STALE_DAYS="${WALTEUR_MEMSTALE_DAYS:-30}"

applies() { [ -s "$PB_JSON" ] || [ -s "$PB_JSONL" ] || [ -s "$STORE" ]; }
playbook_present() { [ -s "$PB_JSON" ] || [ -s "$PB_JSONL" ]; }

abspath() { d="$(dirname "$1")"; b="$(basename "$1")"; if [ -d "$d" ]; then printf '%s/%s' "$(cd "$d" && pwd)" "$b"; else printf '%s' "$1"; fi; }

# Portable ISO-8601 UTC (YYYY-MM-DDTHH:MM:SSZ) -> epoch. Also accepts a bare YYYY-MM-DD.
parse_iso_epoch() {
  o="$(date -u -d "$1" +%s 2>/dev/null)"
  case "$o" in ''|*[!0-9]*) o="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null)";; esac
  case "$o" in ''|*[!0-9]*) o="$(date -j -u -f '%Y-%m-%d' "$1" +%s 2>/dev/null)";; esac
  case "$o" in ''|*[!0-9]*) o="";; esac
  printf '%s' "$o"
}

# Returns 0 always; every violation is recorded via add_finding (which increments $failures).
check_lessons_store() {
  [ -s "$STORE" ] || return 0            # absent/empty store: lesson-gate's WARN, not this gate's FAIL
  have jq || return 0                    # jq-absent is already reported as SKIP by the caller
  # 1. every row must parse — recall does a whole-file read, so one broken row poisons the surface
  bad=0; rows=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || continue
    rows=$((rows+1))
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || bad=$((bad+1))
  done < "$STORE"
  if [ "$bad" -gt 0 ]; then
    add_finding "lessons.parse" "$bad of $rows row(s) in $STORE are not valid JSON — recall reads the whole file, so freshness/content cannot be vouched for (fail-closed)"
  fi
  # 2. freshness measured from CONTENT (newest .ts), never from mtime — a bare `touch` must buy nothing
  newest="$(jq -rs '[.[] | (.ts // empty) | select(type=="string")] | max // ""' "$STORE" 2>/dev/null)"
  [ "$newest" = "null" ] && newest=""
  if [ -z "$newest" ]; then
    add_finding "lessons.ts" "no row in $STORE carries a parseable string .ts — the corpus cannot prove when it was last updated (fail-closed)"
  else
    ne="$(parse_iso_epoch "$newest")"
    if [ -z "$ne" ]; then
      add_finding "lessons.ts" "newest .ts '$newest' in $STORE is not a parseable timestamp — freshness unprovable (fail-closed)"
    else
      age=$(( ( $(date -u +%s) - ne ) / 86400 ))
      [ "$age" -lt 0 ] && age=0
      if [ "$age" -gt "$MEM_STALE_DAYS" ]; then
        add_finding "lessons.stale" "newest lesson in $STORE is ${age}d old (> ${MEM_STALE_DAYS}d HARD window) — the capture loop has stopped; every recall is serving facts nothing has re-verified since"
      fi
    fi
  fi
  # 3. the global read-replica must not have DRIFTED from canonical: recall falls back to it, and a
  #    silently-behind replica is exactly how a build gets served a corpus the harness already outgrew.
  if [ -f "$REPLICA" ] && [ "$(abspath "$REPLICA")" != "$(abspath "$STORE")" ]; then
    if ! cmp -s "$STORE" "$REPLICA"; then
      cn="$(grep -c '' "$STORE" 2>/dev/null | tr -d ' ')"; rn="$(grep -c '' "$REPLICA" 2>/dev/null | tr -d ' ')"
      add_finding "lessons.replica_drift" "global read-replica $REPLICA (${rn:-?} row(s)) has DRIFTED from canonical $STORE (${cn:-?} row(s)) — a reader falling back to the replica gets a stale corpus. Repair: bash walteur-kit/memory/memory-sync.sh"
    fi
  fi
  return 0
}

# Emit one compact JSON object per entry to stdout, from whichever surface exists.
# playbook.json may be a bare array, a {entries:[...]} envelope, or a single object.
# playbook.jsonl is one JSON object per non-blank line.
#
# Fail-closed on SHAPE evasion: a vendor/nested object whose entry list hides under a
# non-array `.entries` (or under .items/.facts/.data/.records/.report) must NOT collapse
# into one synthetic top-level entry (which would let stale nested facts ride beneath a
# fresh top-level decoy valid_until). We emit a {"__shape_error__":true} sentinel instead,
# which the caller fails closed. We also reject multi-doc / non-single-document streams.
entries() {
  if [ -s "$PB_JSON" ]; then
    # Force a SINGLE JSON document (reject concatenated/multi-doc streams fail-closed).
    jq -cs '
      if length != 1 then [{"__shape_error__":true}]
      else
        .[0] as $d |
        if ($d|type)=="array" then $d
        elif ($d|type)=="object" then
          # A recognized envelope MUST carry an array under .entries; anything else
          # (object/number/string/missing-but-nested-elsewhere) fails closed.
          if ($d|has("entries")) then
            if ($d.entries|type)=="array" then $d.entries
            else [{"__shape_error__":true}] end
          else
            # No .entries key. If this single object hides a nested array of
            # entry-shaped objects under ANY common container key, fail closed
            # rather than treat the whole doc as one fresh-looking entry.
            ( [ $d[] | select(type=="array") | .[]? | select(type=="object") |
                select(has("valid_until") or has("id") or has("name") or has("fact")) ]
              | length ) as $nested |
            if $nested > 0 then [{"__shape_error__":true}]
            else [$d] end
          end
        else [{"__shape_error__":true}] end
      end | .[]
    ' "$PB_JSON" 2>/dev/null || printf '{"__shape_error__":true}\n'
  fi
  if [ -s "$PB_JSONL" ]; then
    # -c per line; tolerate blank lines, fail-closed on a malformed line via a sentinel.
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || continue
      printf '%s' "$line" | jq -c '.' 2>/dev/null || printf '{"__parse_error__":true}\n'
    done < "$PB_JSONL"
  fi
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "memory-staleness selftest SKIP - jq not installed."; return 0; fi
  echo "memory-staleness-gate selftest:"
  # HERMETIC: every run pins BOTH memory dirs into the temp root, so a playbook case can never be
  # influenced by (or clear) the developer's real ~/.walteur/memory store.
  run() { WALTEUR_ROOT="$1" WALTEUR_MEM="$1/mem" WALTEUR_GLOBAL_MEM="$1/global" bash "$0" >/dev/null 2>&1; echo $?; }
  kit() { mkdir -p "$1/walteur-kit"; }
  # portable "N days ago" ISO-8601 UTC timestamp
  ago() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ; }
  FUT="$(date -u -d '2999-12-31' +%Y-%m-%d 2>/dev/null || echo 2999-12-31)"
  PAST="$(date -u -d '2000-01-01' +%Y-%m-%d 2>/dev/null || echo 2000-01-01)"
  # CLEAN json: two entries, both valid_until in the far future -> must PASS (false-positive guard).
  goodjson() { jq -n --arg f "$FUT" '{entries:[{id:"stack-2026",fact:"Next 15 is current",valid_until:$f},{id:"jq-ver",fact:"jq 1.8",valid_until:$f}]}' > "$1/walteur-kit/playbook.json"; }
  # CLEAN jsonl: bare-array-free, one obj per line, all future.
  goodjsonl() { { jq -nc --arg f "$FUT" '{id:"a",fact:"x",valid_until:$f}'; jq -nc --arg f "$FUT" '{id:"b",fact:"y",valid_until:$f}'; } > "$1/walteur-kit/playbook.jsonl"; }

  # 1. no playbook -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; ck "no playbook -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. clean json (all future) -> PASS  [FALSE-POSITIVE GUARD]
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; goodjson "$t"; ck "clean json all-future -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. clean jsonl (all future) -> PASS  [FALSE-POSITIVE GUARD]
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; goodjsonl "$t"; ck "clean jsonl all-future -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 4. POISONED: one entry valid_until in the past -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; goodjson "$t"; jq --arg p "$PAST" '.entries[1].valid_until=$p' "$t/walteur-kit/playbook.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/playbook.json"; ck "one past valid_until -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. POISONED jsonl: one line past -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; { jq -nc --arg f "$FUT" '{id:"a",valid_until:$f}'; jq -nc --arg p "$PAST" '{id:"b",valid_until:$p}'; } > "$t/walteur-kit/playbook.jsonl"; ck "jsonl past line -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. missing valid_until -> FAIL (fail-closed: undated fact is stale)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n '{entries:[{id:"a",fact:"no date here"}]}' > "$t/walteur-kit/playbook.json"; ck "missing valid_until -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. unparseable valid_until -> FAIL (fail-closed)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n '{entries:[{id:"a",valid_until:"someday"}]}' > "$t/walteur-kit/playbook.json"; ck "unparseable valid_until -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. today's date is NOT past -> PASS (boundary: valid_until==today still valid)  [FALSE-POSITIVE GUARD]
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n --arg d "$TODAY" '{entries:[{id:"a",valid_until:$d}]}' > "$t/walteur-kit/playbook.json"; ck "valid_until==today -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 9. malformed jsonl line (not JSON) -> FAIL (fail-closed parse)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; { jq -nc --arg f "$FUT" '{id:"a",valid_until:$f}'; printf 'this is not json\n'; } > "$t/walteur-kit/playbook.jsonl"; ck "malformed jsonl line -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10. bare-array json, all future -> PASS  [FALSE-POSITIVE GUARD on shape]
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n --arg f "$FUT" '[{id:"a",valid_until:$f},{id:"b",valid_until:$f}]' > "$t/walteur-kit/playbook.json"; ck "bare-array json all-future -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 11. empty entries array -> PASS (nothing stale)  [FALSE-POSITIVE GUARD]
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n '{entries:[]}' > "$t/walteur-kit/playbook.json"; ck "empty entries -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 12. bypass -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; goodjson "$t"; jq --arg p "$PAST" '.entries[0].valid_until=$p' "$t/walteur-kit/playbook.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/playbook.json"; WALTEUR_ROOT="$t" WALTEUR_MEMSTALE=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  # 13. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; goodjson "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ---- REGRESSION cases for the 3 red-team false-negatives (relative dates + shape evasion) ----
  # G14 [MISS#1]: relative/arithmetic valid_until "now + 100 years" (perpetual-future sentinel) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n --arg f "$FUT" '{entries:[{id:"fresh",valid_until:$f},{id:"stale-auth-pin",fact:"Stripe API 2022-08-01 + bearer in src/pay.js current",valid_until:"now + 100 years"}]}' > "$t/walteur-kit/playbook.json"; ck "G14 relative 'now + 100 years' -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G16 [MISS#3]: relative valid_until "+1 year" -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n --arg f "$FUT" '{entries:[{id:"stack",valid_until:$f},{id:"rds-master-cred",fact:"prod RDS master password reuse",valid_until:"+1 year"}]}' > "$t/walteur-kit/playbook.json"; ck "G16 relative '+1 year' -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G17 [MISS#1/3 variant]: relative valid_until "tomorrow" -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n '{entries:[{id:"a",valid_until:"tomorrow"}]}' > "$t/walteur-kit/playbook.json"; ck "G17 relative 'tomorrow' -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G17b: epoch-arithmetic valid_until "@99999999999" (matches no calendar shape) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n '{entries:[{id:"a",valid_until:"@99999999999"}]}' > "$t/walteur-kit/playbook.json"; ck "G17b epoch '@99999999999' -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G17c: fixed-date-with-trailing-arith "2020-01-01 +50 years" (reads future, must NOT parse) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n '{entries:[{id:"a",valid_until:"2020-01-01 +50 years"}]}' > "$t/walteur-kit/playbook.json"; ck "G17c '2020-01-01 +50 years' -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G15 [MISS#2]: nested-object .entries (items[] under an object) w/ fresh top-level decoy -> FAIL (shape)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n --arg f "$FUT" '{schema:"vendor",valid_until:$f,entries:{count:2,items:[{id:"auth-token-ttl",valid_until:"2001-03-14"},{id:"stack",valid_until:$f}]}}' > "$t/walteur-kit/playbook.json"; ck "G15 nested-object .entries -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G18 [MISS#2 variant]: entry array hidden under an alternate key (.facts) w/ fresh top-level decoy -> FAIL (shape)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n --arg f "$FUT" '{valid_until:$f,facts:[{id:"stale",valid_until:"2001-03-14"}]}' > "$t/walteur-kit/playbook.json"; ck "G18 nested array under .facts -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G18b [MISS#2 variant]: .entries present but a non-array object scalar -> FAIL (shape, no fallthrough)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n --arg f "$FUT" '{valid_until:$f,entries:{id:"x",valid_until:"2001-03-14"}}' > "$t/walteur-kit/playbook.json"; ck "G18b .entries non-array object -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G18c: multi-document JSON stream (two concatenated objects) -> FAIL (single-doc enforcement)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; { jq -nc --arg f "$FUT" '{entries:[{id:"a",valid_until:$f}]}'; jq -nc '{entries:[{id:"b",valid_until:"2001-03-14"}]}'; } > "$t/walteur-kit/playbook.json"; ck "G18c multi-doc stream -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G19 [FALSE-POSITIVE GUARD]: legitimate SINGLE entry object (the real single-object shape) all-future -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; jq -n --arg f "$FUT" '{id:"solo",fact:"jq 1.8",valid_until:$f}' > "$t/walteur-kit/playbook.json"; ck "G19 single entry object all-future -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # ───────── LESSONS-STORE surface (panel #12): the reason this HARD gate can fire on a repo with no playbook ─────────
  mem() { mkdir -p "$1/mem" "$1/global"; }
  # L1 [FALSE-POSITIVE GUARD]: no playbook, fresh lessons store, no replica -> PASS (gate APPLIES now, and passes honestly)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; mem "$t"
  printf '{"id":"a","lesson":"x","ts":"%s"}\n' "$(ago 1)" > "$t/mem/lessons.jsonl"
  ck "L1 no playbook + fresh store -> PASS (applies)" 0 "$(run "$t")"
  ck "L1 verdict is PASS, not NOT_APPLICABLE" PASS "$(jq -r '.verdict' "$t/walteur-kit/memory-staleness-report.json")"; rm -rf "$t"
  # L2 POISON: newest lesson 60d old (> 30d HARD window) -> FAIL exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; mem "$t"
  { printf '{"id":"a","lesson":"x","ts":"%s"}\n' "$(ago 90)"; printf '{"id":"b","lesson":"y","ts":"%s"}\n' "$(ago 60)"; } > "$t/mem/lessons.jsonl"
  ck "L2 newest lesson 60d old -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # L2b BOUNDARY [FALSE-POSITIVE GUARD]: 29d old is inside the 30d window -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; mem "$t"
  printf '{"id":"a","lesson":"x","ts":"%s"}\n' "$(ago 29)" > "$t/mem/lessons.jsonl"
  ck "L2b newest lesson 29d old -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # L3 POISON: `touch` cannot rescue an ancient corpus (freshness is content-based, never mtime)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; mem "$t"
  printf '{"id":"a","lesson":"x","ts":"%s"}\n' "$(ago 400)" > "$t/mem/lessons.jsonl"; touch "$t/mem/lessons.jsonl"
  ck "L3 touch-only on a 400d corpus -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # L4 POISON: one unparseable row -> FAIL (recall reads the whole file)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; mem "$t"
  { printf '{"id":"a","lesson":"x","ts":"%s"}\n' "$(ago 1)"; printf 'not json at all\n'; } > "$t/mem/lessons.jsonl"
  ck "L4 unparseable row -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # L5 POISON: no .ts anywhere -> FAIL (freshness unprovable, fail-closed)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; mem "$t"
  printf '{"id":"a","lesson":"x"}\n' > "$t/mem/lessons.jsonl"
  ck "L5 no .ts on any row -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # L6 POISON: global read-replica DRIFTED behind canonical -> FAIL; and the documented repair -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; mem "$t"
  { printf '{"id":"a","lesson":"x","ts":"%s"}\n' "$(ago 1)"; printf '{"id":"b","lesson":"y","ts":"%s"}\n' "$(ago 1)"; } > "$t/mem/lessons.jsonl"
  printf '{"id":"a","lesson":"x","ts":"%s"}\n' "$(ago 1)" > "$t/global/lessons.jsonl"   # replica missing row b
  ck "L6 replica drifted behind canonical -> FAIL" 2 "$(run "$t")"
  ck "L6 finding names replica_drift" lessons.replica_drift "$(jq -r '.findings[] | select(.check=="lessons.replica_drift") | .check' "$t/walteur-kit/memory-staleness-report.json")"
  cp "$t/mem/lessons.jsonl" "$t/global/lessons.jsonl"                                   # the repair memory-sync.sh performs
  ck "L6 after re-projection -> PASS [FALSE-POSITIVE GUARD]" 0 "$(run "$t")"; rm -rf "$t"
  # L7 SURFACES ARE INDEPENDENT: a perfectly fresh playbook must NOT vouch for a stale lessons store
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; mem "$t"; goodjson "$t"
  printf '{"id":"a","lesson":"x","ts":"%s"}\n' "$(ago 120)" > "$t/mem/lessons.jsonl"
  ck "L7 fresh playbook + 120d-stale store -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # L8 [FALSE-POSITIVE GUARD]: absent store + no playbook -> NOT_APPLICABLE (a fresh clone is not a failure)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; mem "$t"
  ck "L8 no playbook + no store -> exit 0" 0 "$(run "$t")"
  ck "L8 verdict NOT_APPLICABLE" NOT_APPLICABLE "$(jq -r '.verdict' "$t/walteur-kit/memory-staleness-report.json")"; rm -rf "$t"
  # L9: bypass still works on the new surface (recorded, not free)
  t="$(mktemp -d "${TMPDIR:-/tmp}/memorystal.XXXXXX")"; kit "$t"; mem "$t"
  printf '{"id":"a","lesson":"x","ts":"%s"}\n' "$(ago 400)" > "$t/mem/lessons.jsonl"
  WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" WALTEUR_GLOBAL_MEM="$t/global" WALTEUR_MEMSTALE=off bash "$0" >/dev/null 2>&1; ck "L9 stale store + bypass -> exit 0" 0 "$?"; rm -rf "$t"

  echo "memory-staleness-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_MEMSTALE:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_MEMSTALE=off"; echo "memory-staleness-gate: bypassed." >&2; exit 0; }

if ! applies; then write_report "NOT_APPLICABLE" "no walteur-kit/playbook.json, no playbook.jsonl, and no lessons store at $STORE"; echo "memory-staleness-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "memory-staleness-gate: SKIP." >&2; exit 0; fi

n=0
while IFS= read -r e; do
  [ -n "$e" ] || continue
  n=$((n+1))
  # (entries() emits nothing when no playbook exists, so this loop is a no-op on the lessons-only surface.)
  # Fail-closed on a line that could not be parsed into JSON.
  if [ "$(printf '%s' "$e" | jq -r '.__parse_error__ // false' 2>/dev/null)" = "true" ]; then
    add_finding "entry#$n.parse" "playbook entry is not valid JSON — cannot verify freshness (fail-closed)"
    continue
  fi
  # Fail-closed on a playbook whose SHAPE hides entries (non-array .entries, nested
  # entry arrays under an alternate key, or a multi-document stream). Refusing to
  # enumerate => refuse to vouch for freshness.
  if [ "$(printf '%s' "$e" | jq -r '.__shape_error__ // false' 2>/dev/null)" = "true" ]; then
    add_finding "playbook.shape" "playbook is not a bare array, a {entries:[...]} envelope, or a single entry object — its entries cannot be enumerated, so freshness cannot be proven (fail-closed)"
    continue
  fi
  id="$(printf '%s' "$e" | jq -r '.id // .name // ("entry#'"$n"'")' 2>/dev/null)"
  vu="$(printf '%s' "$e" | jq -r 'if (.valid_until|type)=="string" then .valid_until else "" end' 2>/dev/null)"
  if [ -z "$vu" ]; then
    add_finding "$id.valid_until" "entry has no string valid_until (YYYY-MM-DD) — an undated fact is treated as stale (fail-closed)"
    continue
  fi
  # Require a FIXED calendar date (strict ^YYYY-MM-DD$). A relative/arithmetic expression
  # ("now + 100 years", "+1 year", "next year", "tomorrow", "@99999999999", "2020-01-01 +50 years")
  # is a self-renewing sentinel: date -d re-resolves it to a future epoch on every run, so the
  # re-verification clock can never fire. Reject anything that is not a literal calendar date
  # BEFORE handing it to date -d (fail-closed).
  case "$vu" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *)
      add_finding "$id.valid_until" "valid_until '$vu' is not a fixed YYYY-MM-DD calendar date (relative/arithmetic dates auto-renew and can never expire) — fail-closed"
      continue
      ;;
  esac
  # Parse with the portable YYYY-MM-DD epoch helper; unparseable => FAIL (fail-closed).
  vu_epoch="$(parse_ymd_epoch "$vu")"
  case "$vu_epoch" in
    ''|*[!0-9]*)
      add_finding "$id.valid_until" "valid_until '$vu' is not a parseable date — cannot prove freshness (fail-closed)"
      continue
      ;;
  esac
  if [ "$vu_epoch" -lt "$TODAY_EPOCH" ]; then
    add_finding "$id.stale" "valid_until '$vu' is in the PAST (today is $TODAY) — fact is stale and must be re-verified before reuse"
  fi
done < <(entries)

# SECOND SURFACE — the lessons corpus recall actually reads (see header). Always evaluated, so this HARD
# gate has a live surface on a repo that has never had a playbook.json.
check_lessons_store
store_rows=0
[ -s "$STORE" ] && { store_rows="$(grep -c '' "$STORE" 2>/dev/null | tr -d ' ')"; case "${store_rows:-}" in ''|*[!0-9]*) store_rows=0 ;; esac; }

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures memory violation(s) across $n playbook entr(ies) and a $store_rows-row lessons store"
  echo "memory-staleness-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi

if [ "$n" -eq 0 ] && [ "$store_rows" -eq 0 ]; then
  write_report "PASS" "playbook present with zero entries and no lessons store — nothing to verify"
  echo "memory-staleness-gate: PASS (empty playbook, no lessons store)" >&2
  exit 0
fi
if [ "$n" -eq 0 ]; then
  write_report "PASS" "lessons store OK: $store_rows row(s), all parseable, newest within ${MEM_STALE_DAYS}d, replica in sync (no playbook entries to verify)"
  echo "memory-staleness-gate: PASS (lessons store: $store_rows rows fresh + replica in sync)" >&2
  exit 0
fi
write_report "PASS" "all $n playbook entr(ies) carry a valid_until on or after $TODAY; lessons store ($store_rows row(s)) parseable, fresh (<= ${MEM_STALE_DAYS}d) and in sync"
echo "memory-staleness-gate: PASS" >&2
exit 0
