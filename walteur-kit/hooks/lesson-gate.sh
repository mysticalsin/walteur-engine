#!/usr/bin/env bash
# WALTEUR lesson-gate -- the lessons.jsonl capture pipeline (B04). PROTOCOL gate, not HARD: it never blocks a
# build. Two jobs: (1) --capture is the append-only helper that turns a lesson candidate (JSON on stdin) into
# a durable row in the live store; (2) the default (no-arg) run is a freshness check -- it WARNS if the store
# is missing or hasn't been written to in a while, because a stale lessons.jsonl means the self-improvement
# loop (CLAUDE.md S3, memory-discipline.md) has silently stopped running. It never invents enforcement the
# docs don't promise: no contradiction-resolution -- walteur-kit/canonical-kit-staging/lesson-gate.sh.patch
# describes a diff against a base lesson-gate.sh that does not exist anywhere in this repo (grep confirms),
# so it is stale/inapplicable here. This is the honest minimal fallback the task allows.
#
# SUPERSESSION IS NOW IMPLEMENTED (panel #12): --invalidate <id> [ref] closes a lesson's validity window by
# stamping invalidated_at (+ optional superseded_by), exactly as canonical-kit-staging/SCHEMA.lessons.md
# specifies. Before it, invalidated_at was inert on 48/48 rows -- a bi-temporal field with no writer, so a
# lesson proven wrong could never be retired and recall kept serving it. Recall skips invalidated rows
# (.claude/workflows/walteur.js recall STEP 3).
#
# Store: WALTEUR_MEM env (default HOME/.walteur/memory)/lessons.jsonl (append-only, one JSON object per line).
# Per-row fields (SCHEMA.lessons.md): id, lesson, ts, helpful, harmful, applied, invalidated_at, source_build.
# Capture:  echo LESSON_JSON | bash lesson-gate.sh --capture   (requires non-empty .lesson field)
# Report: walteur-kit/lesson-gate-report.json (freshness-check runs only; --capture does not write a report).
# Bypass: WALTEUR_LESSON=off (recorded, not free). Staleness window: WALTEUR_LESSON_STALE_DAYS (default 14).
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "lesson-gate - PROTOCOL gate (not HARD). Append-only lessons.jsonl capture + freshness WARN."
  printf '%s\n' "usage: bash lesson-gate.sh [--capture|--apply <id>|--invalidate <id> [ref]|--selftest|--help|<default freshness-check run>]"
  printf '%s\n' "apply: bash lesson-gate.sh --apply <lesson-id>   (bumps applied counter — the recall half)"
  printf '%s\n' "invalidate: bash lesson-gate.sh --invalidate <lesson-id> [superseding-ref]   (closes the lesson's"
  printf '%s\n' "  validity window: stamps invalidated_at (+ superseded_by) so recall stops serving it — the PRUNE half)"
  printf '%s\n' "capture: pipe a JSON lesson object on stdin with --capture (requires non-empty .lesson)"
  printf '%s\n' "store: \${WALTEUR_MEM:-\$HOME/.walteur/memory}/lessons.jsonl"
  printf '%s\n' "report: walteur-kit/lesson-gate-report.json - fix recipes: walteur-kit/REMEDIATION.md (## lesson-gate)"
  printf '%s\n' "bypass: WALTEUR_LESSON=off (recorded, not free)"
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
REPORT="$KIT/lesson-gate-report.json"
MEM_DIR="${WALTEUR_MEM:-}"
if [ -z "$MEM_DIR" ]; then
  # No explicit WALTEUR_MEM. Prefer a co-located campaign store (walteur-kit/memory) when it already holds
  # lessons, so a DEFAULT freshness run reports the REAL store instead of WARNing "no store" while the repo's
  # own lessons sit in walteur-kit/memory (panel #3 memory gap). Else fall back to the per-user default.
  if [ -f "$KIT/memory/lessons.jsonl" ]; then MEM_DIR="$KIT/memory"; else MEM_DIR="$HOME/.walteur/memory"; fi
fi
STORE="$MEM_DIR/lessons.jsonl"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STALE_DAYS="${WALTEUR_LESSON_STALE_DAYS:-14}"
have() { command -v "$1" >/dev/null 2>&1; }

ROWS=0; NEWEST_TS=""; AGE_SOURCE="none"; PREV_ROWS=-1
write_report() {
  v="$1"; r="$2"; mkdir -p "$KIT"
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --arg store "$STORE" \
      --argjson rows "${ROWS:-0}" --arg newest "$NEWEST_TS" --arg src "$AGE_SOURCE" \
      '{verdict:$v, ts:$ts, gate:"lesson-gate", store:$store, reason:$r, rows:$rows, newest_lesson_ts:$newest, age_source:$src}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"lesson-gate","store":"%s","reason":"%s","rows":%s,"newest_lesson_ts":"%s","age_source":"%s"}\n' \
    "$v" "$TS" "$STORE" "$r" "${ROWS:-0}" "$NEWEST_TS" "$AGE_SOURCE" > "$REPORT" 2>/dev/null || true
}

# ---- capture: append-only helper. Reads one JSON lesson object from stdin, adds the standard fields
# (SCHEMA.lessons.md), appends it as one line. Never rewrites existing rows. Exits 1 on invalid input --
# this is explicit-CLI misuse feedback to the caller, not a gate verdict, so it does not touch REPORT.
capture() {
  if ! have jq; then echo "lesson-gate --capture: jq required, none found -- lesson NOT captured." >&2; return 1; fi
  candidate="$(cat)"
  if ! printf '%s' "$candidate" | jq -e '(.lesson // "") | length > 0' >/dev/null 2>&1; then
    echo "lesson-gate --capture: invalid input -- need JSON with non-empty .lesson field. Lesson NOT captured." >&2
    return 1
  fi
  mkdir -p "$MEM_DIR" || { echo "lesson-gate --capture: cannot create $MEM_DIR -- lesson NOT captured." >&2; return 1; }
  lid="lesson-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  # PROVENANCE (panel #12: source_build was null on 41/48 rows — a lesson nobody can trace back to the build
  # that produced it cannot be re-examined when it turns out to be wrong). If the candidate omits source_build,
  # inherit WALTEUR_BUILD_ID when the harness exported one; only if BOTH are absent does it stay null, and then
  # say so out loud instead of silently storing an untraceable lesson. Not made fatal on purpose: dropping a
  # real lesson because a build id was missing would lose more than it protects.
  row="$(printf '%s' "$candidate" | jq -c --arg ts "$TS" --arg lid "$lid" --arg bid "${WALTEUR_BUILD_ID:-}" \
    '. + {id:(.id // $lid), ts:(.ts // $ts), helpful:(.helpful // 0), harmful:(.harmful // 0), applied:(.applied // 0), invalidated_at:(.invalidated_at // null), source_build:(.source_build // (if ($bid|length)>0 then $bid else null end))}' 2>/dev/null)"
  if [ -z "$row" ]; then echo "lesson-gate --capture: jq transform failed -- lesson NOT captured." >&2; return 1; fi
  if [ "$(printf '%s' "$row" | jq -r '.source_build // "null"' 2>/dev/null)" = "null" ]; then
    echo "lesson-gate --capture: WARNING -- no source_build (candidate omitted it and WALTEUR_BUILD_ID is unset); this lesson will not be traceable to the build that produced it." >&2
  fi
  printf '%s\n' "$row" >> "$STORE" || { echo "lesson-gate --capture: append to $STORE failed -- lesson NOT captured." >&2; return 1; }
  # Project the canonical corpus into the global read-replica walteur.js:439 recall reads
  # (~/.walteur/memory/lessons.jsonl). Best-effort: a sandbox-denied global write must NEVER
  # fail a successful capture. One-directional, non-fragmenting (see memory-sync.sh header).
  if [ -x "$KIT/memory/memory-sync.sh" ]; then WALTEUR_MEM="$MEM_DIR" bash "$KIT/memory/memory-sync.sh" >/dev/null 2>&1 || true; fi
  echo "lesson-gate: captured $lid -> $STORE" >&2
  return 0
}

# ---- apply: mark a lesson as RECALLED-AND-USED by bumping its applied counter. Distinct from capture:
# this is the recall half of the self-improvement loop (memory-discipline.md §1). Rewrites ONLY the matching
# row's applied count via an atomic temp+mv; every other row passes through byte-for-byte. Idempotent per
# call (each call = one real application the caller can cite). No jq / no store / unknown id => exit 1, store
# untouched. Proves the loop does not just CAPTURE lessons, it APPLIES them (closes panel-3 B37).
apply() {
  if ! have jq; then echo "lesson-gate --apply: jq required, none found." >&2; return 1; fi
  target="${1:-}"
  [ -n "$target" ] || { echo "lesson-gate --apply: need a lesson id argument." >&2; return 1; }
  [ -f "$STORE" ] || { echo "lesson-gate --apply: no store at $STORE." >&2; return 1; }
  if ! jq -e --arg id "$target" 'select(.id==$id)' "$STORE" >/dev/null 2>&1; then
    echo "lesson-gate --apply: no lesson with id '$target' in $STORE -- nothing applied." >&2; return 1
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/lesson-apply.XXXXXX")" || { echo "lesson-gate --apply: mktemp failed." >&2; return 1; }
  if jq -c --arg id "$target" 'if .id==$id then .applied=((.applied // 0)+1) else . end' "$STORE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$STORE"
    newcount="$(jq -r --arg id "$target" 'select(.id==$id) | .applied' "$STORE" 2>/dev/null | head -1)"
    echo "lesson-gate: applied '$target' (applied now ${newcount:-?}) -> $STORE" >&2
    return 0
  fi
  rm -f "$tmp"
  echo "lesson-gate --apply: rewrite failed -- store unchanged." >&2; return 1
}

# ---- invalidate: the PRUNE half. Closes a lesson's validity window by stamping invalidated_at (and, when a
# superseding reference is given, superseded_by) per canonical-kit-staging/SCHEMA.lessons.md. This is the
# writer that field was shipped WITHOUT: invalidated_at was null on every row, so a lesson later proven wrong
# stayed in the corpus forever and recall kept serving it. NEVER deletes a row -- the lesson and its counters
# remain auditable, only its window closes (append-only spirit, atomic temp+mv). Already-closed row => report
# the existing timestamp and exit 0 (idempotent). No jq / no store / unknown id => exit 1, store untouched.
invalidate() {
  if ! have jq; then echo "lesson-gate --invalidate: jq required, none found." >&2; return 1; fi
  target="${1:-}"; by="${2:-}"
  [ -n "$target" ] || { echo "lesson-gate --invalidate: need a lesson id argument." >&2; return 1; }
  [ -f "$STORE" ] || { echo "lesson-gate --invalidate: no store at $STORE." >&2; return 1; }
  if ! jq -e --arg id "$target" 'select(.id==$id)' "$STORE" >/dev/null 2>&1; then
    echo "lesson-gate --invalidate: no lesson with id '$target' in $STORE -- nothing invalidated." >&2; return 1
  fi
  existing="$(jq -r --arg id "$target" 'select(.id==$id) | (.invalidated_at // "")' "$STORE" 2>/dev/null | head -1)"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    echo "lesson-gate: '$target' was already invalidated at $existing -- no change (idempotent)." >&2; return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/lesson-invalidate.XXXXXX")" || { echo "lesson-gate --invalidate: mktemp failed." >&2; return 1; }
  if jq -c --arg id "$target" --arg ts "$TS" --arg by "$by" \
       'if .id==$id then .invalidated_at=$ts | (if ($by|length)>0 then .superseded_by=$by else . end) else . end' \
       "$STORE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$STORE"
    # keep the global read-replica honest so a fallback reader cannot resurrect a retired lesson
    if [ -x "$KIT/memory/memory-sync.sh" ]; then WALTEUR_MEM="$MEM_DIR" bash "$KIT/memory/memory-sync.sh" >/dev/null 2>&1 || true; fi
    echo "lesson-gate: invalidated '$target' at $TS${by:+ (superseded_by $by)} -> $STORE" >&2
    return 0
  fi
  rm -f "$tmp"
  echo "lesson-gate --invalidate: rewrite failed -- store unchanged." >&2; return 1
}

# ---- default run: freshness check only. Never HARD-fails (hardness: protocol) -- a stale/missing store
# is a loud WARN so the self-improvement loop's silence is visible, never a build blocker.
main() {
  [ -f "$KIT/PAUSED" ] && { write_report WARN "PAUSED (recorded, not blocking -- protocol gate)"; echo "lesson-gate: PAUSED (WARN only, protocol gate)" >&2; exit 0; }
  [ "${WALTEUR_LESSON:-on}" = "off" ] && { write_report SKIP "bypassed (WALTEUR_LESSON=off)"; echo "lesson-gate: bypassed" >&2; exit 0; }

  if [ ! -f "$STORE" ]; then
    write_report WARN "no lessons.jsonl at $STORE -- the self-improvement capture loop has never written a lesson"
    echo "lesson-gate: WARN -- no store yet at $STORE" >&2
    exit 0
  fi

  # CONTENT-BASED freshness (panel #12). The old check was mtime-only, so a bare `touch lessons.jsonl`
  # bought a PASS without a single new lesson -- the exact "gate that cannot fail" shape. Age is now
  # measured from the NEWEST .ts INSIDE the store (falling back to mtime, and labeling that fallback in
  # the report), and a store that SHRANK since the last report is called out: rows only ever go up in an
  # append-only corpus, so a drop means rows were deleted or a smaller replica was swapped in.
  now="$(date -u +%s)"
  ROWS="$(grep -c '' "$STORE" 2>/dev/null | tr -d ' ')"; case "${ROWS:-}" in ''|*[!0-9]*) ROWS=0 ;; esac
  PREV_ROWS=-1
  if have jq && [ -f "$REPORT" ]; then
    PREV_ROWS="$(jq -r '.rows // -1' "$REPORT" 2>/dev/null)"; case "${PREV_ROWS:-}" in ''|*[!0-9-]*) PREV_ROWS=-1 ;; esac
  fi
  newest_epoch=""
  if have jq; then
    NEWEST_TS="$(jq -rs '[.[] | (.ts // empty) | select(type=="string")] | max // ""' "$STORE" 2>/dev/null)"
    [ "$NEWEST_TS" = "null" ] && NEWEST_TS=""
    if [ -n "$NEWEST_TS" ]; then
      # Portable ISO-8601 (UTC, ...Z) -> epoch: GNU date -d first, then BSD date -j -f.
      newest_epoch="$(date -u -d "$NEWEST_TS" +%s 2>/dev/null)"
      case "$newest_epoch" in ''|*[!0-9]*) newest_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$NEWEST_TS" +%s 2>/dev/null)";; esac
      case "$newest_epoch" in ''|*[!0-9]*) newest_epoch="";; esac
    fi
  fi
  if [ -n "$newest_epoch" ]; then
    AGE_SOURCE="newest_lesson_ts"
    age_days=$(( (now - newest_epoch) / 86400 ))
  else
    AGE_SOURCE="mtime-fallback (no parseable .ts in any row)"
    mtime="$(date -r "$STORE" +%s 2>/dev/null || echo "$now")"
    age_days=$(( (now - mtime) / 86400 ))
  fi
  [ "$age_days" -lt 0 ] && age_days=0   # a future-dated ts is not "fresh credit"; treat as today

  if [ "$PREV_ROWS" -ge 0 ] && [ "$ROWS" -lt "$PREV_ROWS" ]; then
    write_report WARN "lessons.jsonl SHRANK: $ROWS row(s) now vs $PREV_ROWS at the last check -- an append-only corpus must never lose rows (deleted lessons or a smaller replica swapped in)"
    echo "lesson-gate: WARN -- store shrank ($ROWS < $PREV_ROWS rows)" >&2
    exit 0
  fi

  if [ "$age_days" -gt "$STALE_DAYS" ]; then
    write_report WARN "newest lesson is ${age_days}d old (> ${STALE_DAYS}d threshold, measured from ${AGE_SOURCE}) -- capture loop looks stalled"
    echo "lesson-gate: WARN -- store stale (newest lesson ${age_days}d > ${STALE_DAYS}d, via ${AGE_SOURCE})" >&2
    exit 0
  fi

  write_report PASS "$ROWS lesson(s) present, newest ${age_days}d old (<= ${STALE_DAYS}d, measured from ${AGE_SOURCE})"
  echo "lesson-gate: PASS ($ROWS rows, newest lesson ${age_days}d old via ${AGE_SOURCE})" >&2
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "lesson-gate selftest SKIP - no jq."; return 0; fi
  echo "lesson-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }

  # 1. missing store -> WARN, exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/lesson-gate.XXXXXX")" || return 1
  mkdir -p "$t/walteur-kit"
  rc="$(WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" >/dev/null 2>&1; echo $?)"
  ck "no store -> exit 0 (WARN)" 0 "$rc"
  v="$(jq -r '.verdict' "$t/walteur-kit/lesson-gate-report.json" 2>/dev/null)"
  ck "no store -> report verdict WARN" WARN "$v"
  rm -rf "$t"

  # 2. capture: valid lesson -> row appended, exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/lesson-gate.XXXXXX")" || return 1
  mkdir -p "$t/walteur-kit"
  rc="$(printf '{"lesson":"test lesson","why":"selftest"}' | WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" --capture >/dev/null 2>&1; echo $?)"
  ck "capture valid -> exit 0" 0 "$rc"
  n="$(wc -l < "$t/mem/lessons.jsonl" 2>/dev/null | tr -d ' ')"
  ck "capture valid -> 1 row written" 1 "${n:-0}"
  hasfields="$(jq -e '(.id? and .ts? and (.helpful? != null) and (.harmful? != null) and (.applied? != null))' "$t/mem/lessons.jsonl" >/dev/null 2>&1; echo $?)"
  ck "capture valid -> standard fields present" 0 "$hasfields"
  # provenance: no candidate source_build and no WALTEUR_BUILD_ID -> null + a loud warning (panel #12)
  ck "capture without provenance -> source_build null" null "$(jq -r '.source_build' "$t/mem/lessons.jsonl")"
  warned="$(printf '{"lesson":"prov warn","why":"selftest"}' | env -u WALTEUR_BUILD_ID WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem2" bash "$SELF" --capture 2>&1 >/dev/null | grep -c 'no source_build')"
  ck "capture without provenance -> WARNS out loud" 1 "$warned"
  # provenance: WALTEUR_BUILD_ID is inherited when the candidate omits source_build
  printf '{"lesson":"prov inherit","why":"selftest"}' | WALTEUR_BUILD_ID="audit-2026-07-25-zz" WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem3" bash "$SELF" --capture >/dev/null 2>&1
  ck "capture inherits WALTEUR_BUILD_ID as source_build" audit-2026-07-25-zz "$(jq -r '.source_build' "$t/mem3/lessons.jsonl")"
  # an explicit candidate source_build always wins over the env
  printf '{"lesson":"prov explicit","source_build":"explicit-1"}' | WALTEUR_BUILD_ID="env-2" WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem4" bash "$SELF" --capture >/dev/null 2>&1
  ck "explicit source_build wins over WALTEUR_BUILD_ID" explicit-1 "$(jq -r '.source_build' "$t/mem4/lessons.jsonl")"

  # 2b. fresh store -> PASS
  rc="$(WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" >/dev/null 2>&1; echo $?)"
  ck "fresh store -> exit 0 (PASS)" 0 "$rc"
  v="$(jq -r '.verdict' "$t/walteur-kit/lesson-gate-report.json" 2>/dev/null)"
  ck "fresh store -> report verdict PASS" PASS "$v"
  rm -rf "$t"

  # 3. capture: invalid input (no .lesson) -> exit 1, nothing written
  t="$(mktemp -d "${TMPDIR:-/tmp}/lesson-gate.XXXXXX")" || return 1
  mkdir -p "$t/walteur-kit"
  rc="$(printf '{"why":"missing lesson field"}' | WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" --capture >/dev/null 2>&1; echo $?)"
  ck "capture invalid -> exit 1" 1 "$rc"
  ck "capture invalid -> no store created" "" "$( [ -f "$t/mem/lessons.jsonl" ] && echo exists )"
  rm -rf "$t"

  # 4. stale store -> WARN, exit 0 (backdate mtime past threshold via touch -t)
  t="$(mktemp -d "${TMPDIR:-/tmp}/lesson-gate.XXXXXX")" || return 1
  mkdir -p "$t/walteur-kit" "$t/mem"
  printf '{"id":"x","lesson":"old","ts":"2020-01-01T00:00:00Z","helpful":0,"harmful":0,"applied":0,"invalidated_at":null,"source_build":null}\n' > "$t/mem/lessons.jsonl"
  touch -t 202001010000 "$t/mem/lessons.jsonl" 2>/dev/null || touch -d "2020-01-01" "$t/mem/lessons.jsonl" 2>/dev/null
  rc="$(WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" WALTEUR_LESSON_STALE_DAYS=14 bash "$SELF" >/dev/null 2>&1; echo $?)"
  ck "stale store -> exit 0 (WARN)" 0 "$rc"
  v="$(jq -r '.verdict' "$t/walteur-kit/lesson-gate-report.json" 2>/dev/null)"
  ck "stale store -> report verdict WARN" WARN "$v"
  rm -rf "$t"

  # 5. bypass + PAUSED never HARD-fail (protocol gate)
  t="$(mktemp -d "${TMPDIR:-/tmp}/lesson-gate.XXXXXX")" || return 1
  mkdir -p "$t/walteur-kit"
  rc="$(WALTEUR_ROOT="$t" WALTEUR_LESSON=off bash "$SELF" >/dev/null 2>&1; echo $?)"
  ck "bypass -> exit 0" 0 "$rc"
  touch "$t/walteur-kit/PAUSED"
  rc="$(WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; echo $?)"
  ck "PAUSED -> exit 0 (protocol gate never HARD-blocks)" 0 "$rc"
  rm -rf "$t"

  # 6. apply: bump applied counter on an existing lesson; unknown id -> exit 1 (B37 recall half)
  t="$(mktemp -d "${TMPDIR:-/tmp}/lesson-gate.XXXXXX")" || return 1
  mkdir -p "$t/walteur-kit" "$t/mem"
  printf '{"id":"L1","lesson":"a","ts":"2026-01-01T00:00:00Z","helpful":0,"harmful":0,"applied":0,"invalidated_at":null,"source_build":null}\n' > "$t/mem/lessons.jsonl"
  printf '{"id":"L2","lesson":"b","ts":"2026-01-01T00:00:00Z","helpful":0,"harmful":0,"applied":0,"invalidated_at":null,"source_build":null}\n' >> "$t/mem/lessons.jsonl"
  rc="$(WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" --apply L1 >/dev/null 2>&1; echo $?)"
  ck "apply valid id -> exit 0" 0 "$rc"
  ck "apply -> L1.applied incremented to 1" 1 "$(jq -r 'select(.id=="L1").applied' "$t/mem/lessons.jsonl" 2>/dev/null)"
  ck "apply -> L2 untouched (still 0)" 0 "$(jq -r 'select(.id=="L2").applied' "$t/mem/lessons.jsonl" 2>/dev/null)"
  ck "apply -> row count unchanged (2)" 2 "$(wc -l < "$t/mem/lessons.jsonl" | tr -d ' ')"
  WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" --apply L1 >/dev/null 2>&1
  ck "apply again -> L1.applied now 2 (idempotent per call)" 2 "$(jq -r 'select(.id=="L1").applied' "$t/mem/lessons.jsonl" 2>/dev/null)"
  rc="$(WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" --apply NOPE >/dev/null 2>&1; echo $?)"
  ck "apply unknown id -> exit 1" 1 "$rc"
  rm -rf "$t"

  # 7. co-located campaign store: no WALTEUR_MEM + $KIT/memory/lessons.jsonl present -> freshness FINDS it
  #    (panel #3 memory gap: a default run must not WARN "no store" while the repo's own lessons exist).
  t="$(mktemp -d "${TMPDIR:-/tmp}/lesson-gate.XXXXXX")" || return 1
  mkdir -p "$t/walteur-kit/memory"
  # ts must be TODAY, not a hardcoded date: freshness is now content-based, so a fixture with a fixed
  # past ts would decay into a WARN and stop testing what this case is about (store DISCOVERY).
  printf '{"id":"c1","lesson":"colocated","ts":"%s","helpful":0,"harmful":0,"applied":0,"invalidated_at":null,"source_build":null}\n' "$TS" > "$t/walteur-kit/memory/lessons.jsonl"
  env -u WALTEUR_MEM WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  v="$(jq -r '.verdict' "$t/walteur-kit/lesson-gate-report.json" 2>/dev/null)"
  ck "no WALTEUR_MEM + co-located campaign store -> found (PASS)" PASS "$v"
  st="$(jq -r '.store' "$t/walteur-kit/lesson-gate-report.json" 2>/dev/null)"
  case "$st" in */walteur-kit/memory/lessons.jsonl) ck "co-located store resolved to walteur-kit/memory" 0 0 ;; *) ck "co-located store resolved to walteur-kit/memory" 0 1 ;; esac
  rm -rf "$t"

  # 8. no WALTEUR_MEM + NO co-located store -> falls back to per-user default (unchanged behavior)
  t="$(mktemp -d "${TMPDIR:-/tmp}/lesson-gate.XXXXXX")" || return 1
  mkdir -p "$t/walteur-kit"
  st="$(env -u WALTEUR_MEM WALTEUR_ROOT="$t" WALTEUR_LESSON=off bash "$SELF" >/dev/null 2>&1; echo $?)"
  ck "no WALTEUR_MEM + no co-located store -> still runs (bypass path exit 0)" 0 "$st"
  rm -rf "$t"

  # 8b. invalidate: the SUPERSESSION writer (panel #12) — closes a window, never deletes a row.
  t="$(mktemp -d "${TMPDIR:-/tmp}/lesson-gate.XXXXXX")" || return 1
  mkdir -p "$t/walteur-kit" "$t/mem"
  printf '{"id":"L1","lesson":"a","ts":"%s","helpful":0,"harmful":3,"applied":2,"invalidated_at":null,"source_build":null}\n' "$TS" > "$t/mem/lessons.jsonl"
  printf '{"id":"L2","lesson":"b","ts":"%s","helpful":1,"harmful":0,"applied":1,"invalidated_at":null,"source_build":null}\n' "$TS" >> "$t/mem/lessons.jsonl"
  rc="$(WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" --invalidate L1 audit-2026-07-25-x >/dev/null 2>&1; echo $?)"
  ck "invalidate valid id -> exit 0" 0 "$rc"
  ck "invalidate -> L1.invalidated_at is a timestamp, not null" 0 "$(jq -e 'select(.id=="L1") | (.invalidated_at|type)=="string"' "$t/mem/lessons.jsonl" >/dev/null 2>&1; echo $?)"
  ck "invalidate -> superseded_by recorded" audit-2026-07-25-x "$(jq -r 'select(.id=="L1").superseded_by' "$t/mem/lessons.jsonl")"
  ck "invalidate -> row NOT deleted (2 rows remain)" 2 "$(wc -l < "$t/mem/lessons.jsonl" | tr -d ' ')"
  ck "invalidate -> counters preserved (harmful still 3)" 3 "$(jq -r 'select(.id=="L1").harmful' "$t/mem/lessons.jsonl")"
  ck "invalidate -> L2 window still OPEN (null)" null "$(jq -r 'select(.id=="L2").invalidated_at' "$t/mem/lessons.jsonl")"
  first="$(jq -r 'select(.id=="L1").invalidated_at' "$t/mem/lessons.jsonl")"
  rc="$(WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" --invalidate L1 >/dev/null 2>&1; echo $?)"
  ck "re-invalidate -> exit 0 (idempotent)" 0 "$rc"
  ck "re-invalidate -> original timestamp untouched" "$first" "$(jq -r 'select(.id=="L1").invalidated_at' "$t/mem/lessons.jsonl")"
  rc="$(WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" --invalidate NOPE >/dev/null 2>&1; echo $?)"
  ck "invalidate unknown id -> exit 1" 1 "$rc"
  rc="$(WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" --invalidate >/dev/null 2>&1; echo $?)"
  ck "invalidate with no id -> exit 1" 1 "$rc"
  rm -rf "$t"

  # 9. POISON [panel #12]: `touch` must NOT buy a PASS. Old rows (ts far in the past) + a brand-new mtime
  #    was the whole hole: mtime-only age said "fresh" while the corpus had not gained a lesson in years.
  t="$(mktemp -d "${TMPDIR:-/tmp}/lesson-gate.XXXXXX")" || return 1
  mkdir -p "$t/walteur-kit" "$t/mem"
  printf '{"id":"x","lesson":"old","ts":"2020-01-01T00:00:00Z","helpful":0,"harmful":0,"applied":0,"invalidated_at":null,"source_build":null}\n' > "$t/mem/lessons.jsonl"
  touch "$t/mem/lessons.jsonl"   # fresh mtime, ZERO new content
  WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" WALTEUR_LESSON_STALE_DAYS=14 bash "$SELF" >/dev/null 2>&1
  v="$(jq -r '.verdict' "$t/walteur-kit/lesson-gate-report.json" 2>/dev/null)"
  ck "touch-only (fresh mtime, ancient rows) -> WARN not PASS" WARN "$v"
  src="$(jq -r '.age_source' "$t/walteur-kit/lesson-gate-report.json" 2>/dev/null)"
  ck "age measured from newest_lesson_ts, not mtime" newest_lesson_ts "$src"
  rm -rf "$t"

  # 10. SHRINK detection: an append-only corpus that loses rows between checks -> WARN (deleted evidence
  #     or a smaller replica swapped over the canonical store).
  t="$(mktemp -d "${TMPDIR:-/tmp}/lesson-gate.XXXXXX")" || return 1
  mkdir -p "$t/walteur-kit" "$t/mem"
  { printf '{"id":"a","lesson":"1","ts":"%s"}\n' "$TS"; printf '{"id":"b","lesson":"2","ts":"%s"}\n' "$TS"; printf '{"id":"c","lesson":"3","ts":"%s"}\n' "$TS"; } > "$t/mem/lessons.jsonl"
  WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" >/dev/null 2>&1
  ck "3 fresh rows -> PASS" PASS "$(jq -r '.verdict' "$t/walteur-kit/lesson-gate-report.json" 2>/dev/null)"
  ck "report records the real row count" 3 "$(jq -r '.rows' "$t/walteur-kit/lesson-gate-report.json" 2>/dev/null)"
  { printf '{"id":"a","lesson":"1","ts":"%s"}\n' "$TS"; } > "$t/mem/lessons.jsonl"   # 2 rows deleted
  WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" >/dev/null 2>&1
  ck "row count dropped 3->1 -> WARN" WARN "$(jq -r '.verdict' "$t/walteur-kit/lesson-gate-report.json" 2>/dev/null)"
  # growth is NOT a shrink [FALSE-POSITIVE GUARD]
  { printf '{"id":"a","lesson":"1","ts":"%s"}\n' "$TS"; printf '{"id":"d","lesson":"4","ts":"%s"}\n' "$TS"; } > "$t/mem/lessons.jsonl"
  WALTEUR_ROOT="$t" WALTEUR_MEM="$t/mem" bash "$SELF" >/dev/null 2>&1
  ck "1->2 rows (growth) -> PASS" PASS "$(jq -r '.verdict' "$t/walteur-kit/lesson-gate-report.json" 2>/dev/null)"
  rm -rf "$t"

  echo "lesson-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --capture) capture; exit $? ;;
  --apply) apply "${2:-}"; exit $? ;;
  --invalidate) invalidate "${2:-}" "${3:-}"; exit $? ;;
  *) main "$@" ;;
esac
