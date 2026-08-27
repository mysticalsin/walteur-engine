#!/usr/bin/env bash
# walteur-loop.sh — the earned-sentinel outer loop.
#
# WHAT THIS IS
#   Ralph's relentless fresh-context outer loop, grafted onto WALTEUR's gate registry as the
#   completion oracle. Ralph (MIT, (c) 2026 snarktank; pattern by Geoffrey Huntley,
#   https://ghuntley.com/ralph/) proved the loop shape: bounded iteration over FRESH agent
#   processes, all continuity on disk, never in shell state.
#
#   Ralph's fatal flaw is that its exit condition is a natural-language self-assertion the agent
#   prints. Nothing re-verifies it. This loop inverts that:
#
#       THE SENTINEL IS NOT A STRING. It is the exit status of one jq query over a file that only
#       this script writes, in a directory the agent cannot reach.
#
#   The loop never reads agent stdout to decide anything. After the agent process exits, the loop
#   re-executes the pinned HARD-gate set ITSELF and records the exit codes its own shell captured.
#
# ANTI-FORGERY (four independent layers)
#   1. ORACLE DIR OUTSIDE THE REPO. Verdicts live in $ORACLE, outside the git tree and outside the
#      agent's --add-dir. The agent has no filesystem path to the file the sentinel reads.
#   2. PINNED DENOMINATOR. The hard-gate set is frozen to registry.pin before iteration 1, with a
#      sha256 of gate-registry.json. If the registry changes mid-run the oracle refuses to be done,
#      so the agent cannot shrink what "done" counts by editing the registry.
#   3. RE-EXECUTION. The loop runs each gate hook itself and trusts its OWN captured rc. A perfectly
#      forged report file is simply overwritten by the real run.
#   4. NONCE MTIME. Before running gates the loop stamps a nonce file. Any report whose mtime predates
#      that nonce was not produced by this run and is classified MISSING, never PASS. This is what
#      catches a report pre-written by the agent during its turn.
#
# WHAT IS DELIBERATELY NOT PORTED FROM RALPH
#   --dangerously-allow-all / --dangerously-skip-permissions. This loop runs gated permissions from a
#   loop-owned settings file with an explicit allowlist. An unattended loop is exactly the wrong place
#   to disable the permission system.
#
# RALPH DEFECTS FIXED HERE
#   set -o pipefail + real exit-status observation (Ralph's `|| true` plus a pipe into tee makes a
#   crashed agent indistinguishable from a productive one) · per-iteration timeout · stall detection
#   via git HEAD + dirty-tree comparison · per-item attempt counter with escalation · rollback of a
#   failed iteration's partial edits · ledger-write BEFORE commit (Ralph commits first, so its final
#   iteration's memory writes are never committed) · gate-REGRESSION detection, which Ralph cannot
#   see at all: a gate going green->red is a worse signal than one that was never green.
#
# SKIP IS NOT GREEN
#   The live report corpus carries 24 SKIP and 40 NOT_APPLICABLE against 27 PASS. A gate that cannot
#   run is not a gate that passed. This loop maps SKIP to its own class and refuses to count it green
#   unless WALTEUR_LOOP_ALLOW_SKIP names that gate id explicitly.
#
# USAGE
#   bash walteur-kit/walteur-loop.sh [--max N] [--timeout SEC] [--dry-run] [--selftest] [--help]

set -uo pipefail

VERSION="1.0.0"

# ---------------------------------------------------------------- paths and config
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REGISTRY="$KIT/gate-registry.json"

# The oracle lives OUTSIDE the repo. This is layer 1 of anti-forgery and is not configurable to a
# path inside $ROOT — see assert_oracle_outside_repo.
ORACLE="${WALTEUR_LOOP_ORACLE:-$(dirname "$ROOT")/.walteur-loop-$(basename "$ROOT")}"

MAX_ITERATIONS="${WALTEUR_LOOP_MAX:-10}"
ITER_TIMEOUT="${WALTEUR_LOOP_TIMEOUT:-1800}"
MAX_ATTEMPTS="${WALTEUR_LOOP_MAX_ATTEMPTS:-3}"
STALL_LIMIT="${WALTEUR_LOOP_STALL_LIMIT:-2}"
AGENT_CMD="${WALTEUR_LOOP_AGENT:-claude}"
DRY_RUN=0

# panel-13: a per-invocation id. Without it, attempts_for() counted across runs and the escalation cap
# was already spent on a restart. Derived from the pid plus the pinned registry sha, not from a clock, so
# it is stable within a run and distinct across runs.
RUN_ID="${WALTEUR_LOOP_RUN_ID:-run-$$}"
JOURNAL="$ORACLE/journal.ndjson"
PIN="$ORACLE/registry.pin"
PINSHA="$ORACLE/registry.sha"
LEDGER="$ORACLE/residual.json"
NONCE="$ORACLE/.nonce"

have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'walteur-loop: %s\n' "$*" >&2; exit 2; }

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------------------------------------------------------------- arg parsing
while [ $# -gt 0 ]; do
  case "$1" in
    --max)      MAX_ITERATIONS="${2:?--max needs a value}"; shift 2 ;;
    --max=*)    MAX_ITERATIONS="${1#*=}"; shift ;;
    --timeout)  ITER_TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --timeout=*) ITER_TIMEOUT="${1#*=}"; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --selftest) SELFTEST=1; shift ;;
    --help|-h)  usage ;;
    *) die "unknown argument: $1 (try --help)" ;;
esac
done

case "$MAX_ITERATIONS" in ''|*[!0-9]*) die "--max must be a positive integer" ;; esac
case "$ITER_TIMEOUT"   in ''|*[!0-9]*) die "--timeout must be a positive integer (seconds)" ;; esac

# ---------------------------------------------------------------- invariants
assert_oracle_outside_repo() {
  # A relative or nested oracle dir would hand the agent write access to the sentinel. Refuse.
  case "$ORACLE" in
    "$ROOT"|"$ROOT"/*) die "ORACLE ($ORACLE) is inside ROOT ($ROOT) — the agent could forge the sentinel. Refusing." ;;
    /*) : ;;
    *)  die "ORACLE must be an absolute path, got: $ORACLE" ;;
  esac
}

preflight() {
  have jq   || die "jq is required"
  have git  || die "git is required"
  [ -f "$REGISTRY" ] || die "gate registry not found at $REGISTRY"
  jq -e . "$REGISTRY" >/dev/null 2>&1 || die "gate registry is not valid JSON"
  assert_oracle_outside_repo
  mkdir -p "$ORACLE/logs" || die "cannot create oracle dir $ORACLE"
}

# ---------------------------------------------------------------- the pinned denominator (layer 2)
pin_registry() {
  if [ -f "$PIN" ] && [ -f "$PINSHA" ]; then
    log "  denominator: reusing existing pin ($(wc -l <"$PIN" | tr -d ' ') hard gates)"
    return 0
  fi
  jq -r '[.gates[] | select(.hardness=="hard")]
         | sort_by(.stage, .id)
         | .[] | [.id, .hook, .report] | @tsv' "$REGISTRY" > "$PIN" \
    || die "failed to pin the hard-gate set"
  shasum -a 256 "$REGISTRY" | awk '{print $1}' > "$PINSHA"
  log "  denominator PINNED: $(wc -l <"$PIN" | tr -d ' ') hard gates, registry sha $(cut -c1-12 <"$PINSHA")"
}

registry_unchanged() {
  [ -f "$PINSHA" ] || return 1
  [ "$(shasum -a 256 "$REGISTRY" | awk '{print $1}')" = "$(cat "$PINSHA")" ]
}

# ---------------------------------------------------------------- gate execution (layers 3 and 4)
# Classify one gate. Echoes a single JSON object. NEVER reads agent output.
#
# class is one of: green | red | skip | missing
#   green   -> hook rc 0 AND report verdict in {PASS, NOT_APPLICABLE} AND report is fresh
#   red     -> hook rc non-zero, or report verdict FAIL/WARN/NO_TRACE
#   skip    -> report verdict SKIP (a gate that could not run is not a gate that passed)
#   missing -> no report, unreadable report, or report older than the nonce (stale/forged)
run_one_gate() {
  local id="$1" hook="$2" report="$3"
  local hookpath="$KIT/hooks/$hook"
  local rc=0 verdict="" class="" fresh="true" bytes=0

  if [ ! -f "$hookpath" ]; then
    jq -nc --arg id "$id" --arg hook "$hook" \
      '{id:$id, hook:$hook, rc:127, verdict:null, class:"missing", note:"hook file absent"}'
    return
  fi

  # Real exit-status observation. No pipe, so no SIGPIPE and no pipefail corruption of rc.
  # This is the fix for Ralph's `|| true`-plus-tee blindness.
  #
  # </dev/null is LOAD-BEARING, not hygiene. Without it a hook that reads stdin swallows the rest of
  # the caller's pin file, silently shrinking the denominator — measured live as total:18 against a
  # 59-line pin. An under-measured denominator is a false-GREEN path, the worst possible bug class in
  # a completion oracle. measure_gates also reads the pin on FD 3 as an independent guard.
  local out="$ORACLE/logs/gate-$id.out"
  bash "$hookpath" </dev/null >"$out" 2>&1
  rc=$?

  local reportpath="$ROOT/$report"
  if [ -f "$reportpath" ]; then
    bytes=$(wc -c <"$reportpath" | tr -d ' ')
    # Layer 4: a report not touched since the nonce was stamped did not come from this run.
    if [ -f "$NONCE" ] && [ ! "$reportpath" -nt "$NONCE" ]; then fresh="false"; fi
    verdict=$(jq -r '.verdict // empty' "$reportpath" 2>/dev/null || printf '')
  fi

  if [ "$bytes" -eq 0 ] || [ -z "$verdict" ] || [ "$fresh" = "false" ]; then
    class="missing"
  else
    case "$verdict" in
      PASS|NOT_APPLICABLE) class="green" ;;
      SKIP)                class="skip"  ;;
      *)                   class="red"   ;;
    esac
  fi
  # The hook's own rc always wins over a file that claims success.
  [ "$rc" -ne 0 ] && class="red"

  jq -nc --arg id "$id" --arg hook "$hook" --argjson rc "$rc" \
        --arg verdict "${verdict:-}" --arg class "$class" --arg fresh "$fresh" --argjson bytes "$bytes" \
    '{id:$id, hook:$hook, rc:$rc, verdict:(if $verdict=="" then null else $verdict end),
      class:$class, report_fresh:($fresh=="true"), report_bytes:$bytes}'
}

# Run every pinned gate. Writes $ORACLE/oracle-<tag>.json and echoes its path.
measure_gates() {
  local tag="$1"
  local nd="$ORACLE/logs/gates-$tag.ndjson"
  : > "$nd"
  date -u +%s > "$NONCE"      # stamp the nonce BEFORE any gate runs
  sleep 1                     # ensure a strictly-later mtime is observable at 1s granularity

  # Read the pin on FD 3, not stdin, so nothing a hook does to stdin can truncate the sweep.
  while IFS=$'\t' read -r -u 3 id hook report; do
    [ -n "${id:-}" ] || continue
    run_one_gate "$id" "$hook" "$report" >> "$nd"
  done 3< "$PIN"

  # Completeness assertion. If the sweep measured fewer gates than the pin declares, the denominator
  # was truncated and every downstream verdict is untrustworthy. Fail loudly; never report a partial
  # sweep as a result.
  local want got
  want=$(grep -c . "$PIN"); got=$(grep -c . "$nd")
  if [ "$want" -ne "$got" ]; then
    # panel-13 BUG: this used to call die(), but measure_gates is ALWAYS invoked in a command
    # substitution, so `exit 2` killed only the subshell and the caller carried on with a partial
    # oracle — the fail-closed guard could not actually halt anything. A sentinel file crosses the
    # subshell boundary; the caller checks it immediately after every measure_gates call.
    jrn sweep_truncated "$(jq -nc --argjson w "$want" --argjson g "$got" '{pinned:$w, measured:$g}')"
    printf 'pin=%s measured=%s\n' "$want" "$got" > "$ORACLE/.SWEEP_TRUNCATED"
    printf '%s\n' "walteur-loop: SWEEP TRUNCATED — pin declares $want hard gates, only $got measured." >&2
    return 2
  fi

  local allow="${WALTEUR_LOOP_ALLOW_SKIP:-}"
  local oracle="$ORACLE/oracle-$tag.json"
  jq -s --arg tag "$tag" --arg allow "$allow" '
    ($allow | split(",") | map(select(length>0))) as $allowed
    | map(. + { counted_green: (.class=="green" or (.class=="skip" and (.id | IN($allowed[])))) })
    | { tag:$tag,
        total:      length,
        green:      map(select(.counted_green))          | length,
        red:        map(select(.class=="red"))           | length,
        skip:       map(select(.class=="skip"))          | length,
        missing:    map(select(.class=="missing"))       | length,
        allowed_skips: $allowed,
        blocking:   map(select(.counted_green|not) | {id, class, rc, verdict}),
        gates: .
      }' "$nd" > "$oracle"
  printf '%s\n' "$oracle"
}

# THE SENTINEL. Exit status of one jq -e. Nothing else in this script can produce a done verdict,
# and no agent output is an input to it.
oracle_says_done() {
  local oracle="$1"
  registry_unchanged || { log "  ORACLE: registry sha CHANGED since pin — refusing done"; return 1; }
  jq -e '.total > 0 and .green == .total' "$oracle" >/dev/null 2>&1
}

# ---------------------------------------------------------------- residual ledger (projection, not a queue)
# Every non-green pinned gate IS a work item. Priority comes out of the registry's own enum
# declaration order, so there is no hand-maintained priority field to drift.
project_ledger() {
  local oracle="$1"
  jq --slurpfile reg "$REGISTRY" '
    ($reg[0].gates) as $g
    | ["intake","discover","plan","build","verify","review","ship","reflect"] as $stages
    | [ .gates[] | select(.counted_green | not) as $row
        | ($g | map(.id) | index($row.id)) as $idx
        | ($g[$idx]) as $gate
        | { id: $row.id,
            hook: $row.hook,
            gate_stage: $gate.stage,
            evidence: $gate.evidence,
            report: $gate.report,
            class: $row.class,
            rc: $row.rc,
            verdict: $row.verdict,
            priority: ((($stages | index($gate.stage)) // 99) * 100000 + $idx),
            passes: false }
      ] | sort_by(.priority)' "$oracle" > "$LEDGER"
  jq -r 'length' "$LEDGER"
}

# Admission control. An item must name the gate that adjudicates it, and that gate must be pinned.
# Items no gate can decide are refused at entry rather than burning an iteration.
admit() {
  local id="$1"
  [ -n "$id" ] || { log "  ADMISSION REFUSED: item names no gate id"; return 1; }
  cut -f1 "$PIN" | grep -qxF -- "$id" || { log "  ADMISSION REFUSED: '$id' is not a pinned hard gate"; return 1; }
  return 0
}

# ---------------------------------------------------------------- journal (append-only, write-ahead)
jrn() {
  # jrn <event> <json-object-fragment>
  local ev="$1"; shift
  jq -nc --arg ev "$ev" --arg ts "$(date -u +%FT%TZ)" --arg run "$RUN_ID" --argjson d "${1:-{\}}" \
    '{ts:$ts, run_id:$run, event:$ev} + $d' >> "$JOURNAL"
}

git_head()  { git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf 'NO_HEAD'; }
# panel-13 BUG: this hashed `git status --porcelain` alone, which carries path+status but NOT content.
# Further edits to an already-dirty tracked file were therefore invisible and read as NO_OP, so the stall
# detector fired on a productive iteration. Hash the porcelain listing AND the actual diff content.
git_dirty() {
  { git -C "$ROOT" status --porcelain 2>/dev/null
    git -C "$ROOT" diff 2>/dev/null
    git -C "$ROOT" diff --cached 2>/dev/null
  } | shasum -a 256 | awk '{print $1}'
}

attempts_for() {
  local id="$1"
  [ -f "$JOURNAL" ] || { printf '0'; return; }
  # `jq -s 'map(select(..))|length'` counts RECORDS. The first version piped a bare `jq -r select(..)`
  # into `wc -l`, and jq pretty-prints by default, so ONE record became ~4 lines: two real attempts
  # reported 8. With MAX_ATTEMPTS=3 that meant every item escalated and was parked after a SINGLE
  # attempt, silently disabling the retry logic this loop advertises. Same compact-JSON family as the
  # bug fixed in registry-report-contract-gate; count records, never lines.
  # panel-13 BUGS, two of them:
  #  (a) attempts leaked ACROSS runs — every iteration_end for the item in the whole append-only journal
  #      counted, so a second invocation escalated immediately. Scope to this run via RUN_ID.
  #  (b) a malformed journal line silently disabled the cap: `|| printf '0'` swallowed the jq parse error
  #      and 0 attempts means "never tried". A killed loop produces exactly that truncated append, so the
  #      failure mode was reachable. Now a parse failure returns the CAP (fail-closed: treat an unreadable
  #      journal as exhausted) and says so, rather than silently granting infinite retries.
  local n
  if n="$(jq -s --arg id "$id" --arg run "$RUN_ID" \
        'map(select(.event=="iteration_end" and .item==$id and .run_id==$run)) | length' "$JOURNAL" 2>/dev/null)" \
     && [ -n "$n" ]; then
    printf '%s' "$n"
  else
    printf '%s\n' "walteur-loop: journal unreadable at $JOURNAL — treating '$id' as attempt-exhausted (fail-closed)" >&2
    printf '%s' "$MAX_ATTEMPTS"
  fi
}

# ---------------------------------------------------------------- the agent spawn
# Fresh process per item. Prompt from disk. No session resumption. Gated permissions.
spawn_agent() {
  local item_id="$1" prompt_file="$2" outfile="$3"
  local settings="$ORACLE/loop-settings.json"

  # Loop-owned permission allowlist. Deliberately NOT --dangerously-skip-permissions.
  [ -f "$settings" ] || jq -n --arg oracle "$ORACLE" '{
      permissions: {
        allow: ["Read","Grep","Glob","Edit","Write","Bash(git status:*)","Bash(git diff:*)",
                "Bash(git add:*)","Bash(git commit:*)","Bash(bash walteur-kit/hooks/:*)",
                "Bash(npm test:*)","Bash(npm run:*)","Bash(node:*)","Bash(jq:*)"],
        deny:  ["Read(\($oracle)/**)","Write(\($oracle)/**)","Edit(\($oracle)/**)",
                "Bash(rm -rf:*)","Bash(git push:*)","Bash(git reset --hard:*)",
                "Write(walteur-kit/gate-registry.json)","Edit(walteur-kit/gate-registry.json)"]
      }
    }' > "$settings"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN: would spawn %s for %s\n' "$AGENT_CMD" "$item_id" > "$outfile"
    return 0
  fi

  # panel-13: `timeout` and `gtimeout` are BOTH absent on stock macOS, so the advertised per-iteration
  # timeout silently no-opped on the platform this was written on. Announce the degradation loudly rather
  # than claiming a protection that is not there, and fall back to a watchdog that actually works.
  local rc=0
  if have timeout; then
    timeout "$ITER_TIMEOUT" "$AGENT_CMD" --print --settings "$settings" < "$prompt_file" > "$outfile" 2>&1
    rc=$?
  elif have gtimeout; then
    gtimeout "$ITER_TIMEOUT" "$AGENT_CMD" --print --settings "$settings" < "$prompt_file" > "$outfile" 2>&1
    rc=$?
  else
    # Portable watchdog: run the agent in the background, poll, and kill on expiry. Returns 124 on
    # timeout to match GNU timeout's convention so the outcome classifier needs no special case.
    log "  NOTE: neither timeout nor gtimeout present — using the built-in watchdog (${ITER_TIMEOUT}s)"
    "$AGENT_CMD" --print --settings "$settings" < "$prompt_file" > "$outfile" 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$waited" -ge "$ITER_TIMEOUT" ]; then
        kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 124
      fi
      sleep 1; waited=$((waited+1))
    done
    wait "$pid"; rc=$?
  fi
  return $rc
}

build_prompt() {
  local item_id="$1" pf="$2"
  local item; item=$(jq -c --arg id "$item_id" '.[] | select(.id==$id)' "$LEDGER")
  {
    printf 'You are one iteration of an autonomous gate-repair loop. Fresh context; everything you need is below or on disk.\n\n'
    printf 'YOUR SINGLE TASK: make the WALTEUR gate `%s` go green. One gate. Not two.\n\n' "$item_id"
    printf 'GATE RECORD:\n%s\n\n' "$item"
    printf 'HOW IT IS JUDGED: after you exit, the loop re-runs `bash walteur-kit/hooks/%s` itself and reads the exit code its own shell captures. You cannot influence the verdict by anything you print. Do not attempt to write a report file — the loop overwrites it, and a report older than the run nonce is treated as MISSING.\n\n' "$(jq -r --arg id "$item_id" '.[]|select(.id==$id)|.hook' "$LEDGER")"
    printf 'FIRST, read the accumulated learnings — the Codebase Patterns block at the top of walteur-kit/LOOP-PROGRESS.md if it exists. Do not repeat a documented mistake.\n\n'
    printf 'THEN: reproduce the failure, fix the root cause, run the hook until it exits 0, and commit.\n'
    printf 'ORDERING (this matters): append your learnings to walteur-kit/LOOP-PROGRESS.md and update any AGENTS.md BEFORE you commit, so the memory writes land in the commit rather than being orphaned.\n\n'
    printf 'RULES: one gate per iteration · do not weaken a gate to make it pass (that is the one unforgivable failure here) · do not edit walteur-kit/gate-registry.json · do not edit .claude/hooks/ guard hooks · commit only if the hook exits 0.\n'
  } > "$pf"
}

# ---------------------------------------------------------------- selftest
selftest() {
  local pass=0 fail=0
  t() { if eval "$2"; then printf '  ok   - %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL - %s\n' "$1"; fail=$((fail+1)); fi; }

  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/walteur-loop-selftest.XXXXXX")" || return 2
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  printf 'walteur-loop selftest v%s\n' "$VERSION"

  # The source-scan tests below must examine only the OPERATIONAL code, not this selftest. A test that
  # searches for a forbidden pattern would otherwise match the pattern in its own assertion — the tests
  # A1b/A7/A9 all failed that way on first run. Scope: everything above selftest(), comments stripped.
  awk '/^selftest\(\) \{/{exit} {print}' "$0" | grep -vE '^[[:space:]]*#' > "$tmp/code.sh"
  # code.sh covers only what precedes selftest(). The main loop body lives BELOW it, so assertions about
  # the rollback or the iteration loop need a scan of the WHOLE file minus this function's own body —
  # otherwise they test nothing and pass or fail for the wrong reason (A13b-e initially failed this way).
  awk '/^selftest\(\) \{/{skip=1} skip && /^\}$/{skip=0; next} !skip {print}' "$0" | grep -vE '^[[:space:]]*#' > "$tmp/all.sh"

  # A1 — the sentinel cannot be forged by agent output.
  # An agent printing the literal sentinel string must NOT produce a done verdict.
  mkdir -p "$tmp/o"
  printf '{"tag":"t","total":3,"green":1}\n' > "$tmp/o/oracle-t.json"
  printf '%s\n' 'COMPLETE — all gates pass, done, exit 0' > "$tmp/o/agent.out"
  t "A1 agent stdout printing the sentinel does NOT satisfy the oracle" \
    '! jq -e ".total > 0 and .green == .total" "'"$tmp"'/o/oracle-t.json" >/dev/null 2>&1'

  # A1b — prove no operational code path consults agent stdout for a completion signal.
  t "A1b no operational code path derives doneness from agent output" \
    'grep -q "oracle_says_done" "'"$tmp"'/code.sh" && ! grep -qiE "(promise|<complete>|COMPLETE</)" "'"$tmp"'/code.sh"'

  # A2 — a green oracle is accepted (positive control, so A1 is not passing vacuously).
  printf '{"tag":"t2","total":3,"green":3}\n' > "$tmp/o/oracle-t2.json"
  t "A2 a genuinely all-green oracle IS accepted" \
    'jq -e ".total > 0 and .green == .total" "'"$tmp"'/o/oracle-t2.json" >/dev/null 2>&1'

  # A3 — zero pinned gates must never read as done (empty denominator is not success).
  printf '{"tag":"t3","total":0,"green":0}\n' > "$tmp/o/oracle-t3.json"
  t "A3 an empty denominator does NOT read as done" \
    '! jq -e ".total > 0 and .green == .total" "'"$tmp"'/o/oracle-t3.json" >/dev/null 2>&1'

  # A4 — SKIP is not green.
  printf '%s\n' '{"id":"g1","class":"skip"}' > "$tmp/o/nd"
  t "A4 SKIP is not counted green without an explicit allowlist" \
    '[ "$(jq -s "map(. + {counted_green:(.class==\"green\")}) | map(select(.counted_green)) | length" "'"$tmp"'/o/nd")" = "0" ]'

  # A5 — a stale report (older than the nonce) is MISSING, not PASS.
  mkdir -p "$tmp/r"
  printf '{"verdict":"PASS"}' > "$tmp/r/stale-report.json"
  sleep 1; date -u +%s > "$tmp/o/.nonce"
  t "A5 a report older than the nonce is stale (not newer-than test holds)" \
    '[ ! "'"$tmp"'/r/stale-report.json" -nt "'"$tmp"'/o/.nonce" ]'
  # 1-second filesystem mtime granularity means a report written in the same second as the nonce is
  # NOT newer-than it. This is why measure_gates stamps the nonce and then sleeps 1 before running any
  # gate — without that sleep, a legitimately fresh report would be misread as stale.
  sleep 1; printf '{"verdict":"PASS"}' > "$tmp/r/fresh-report.json"
  t "A5b a report written after the nonce IS fresh" \
    '[ "'"$tmp"'/r/fresh-report.json" -nt "'"$tmp"'/o/.nonce" ]'
  t "A5c measure_gates stamps the nonce BEFORE sleeping, so real reports are always newer" \
    'grep -A2 "date -u +%s > \"\$NONCE\"" "'"$tmp"'/code.sh" | grep -q "sleep 1"'

  # A6 — crashed agent is observable. This is Ralph's blindness; prove our form sees it.
  ( exit 42 ) >/dev/null 2>&1; local crc=$?
  t "A6 a crashing child's real exit status is captured (42)" '[ "'"$crc"'" = "42" ]'
  # And prove the Ralph form loses it.
  local ralph_rc; set +o pipefail; ( exit 42 ) 2>&1 | cat >/dev/null; ralph_rc=$?; set -o pipefail
  t "A6b the Ralph form (pipe into cat) reports 0 for the same crash — hence our form" '[ "'"$ralph_rc"'" = "0" ]'

  # A7 — the pipefail SIGPIPE trap (the tdd-guard.sh:26 class of bug) is not reintroduced here.
  t "A7 operational code contains no 'find | grep -q' SIGPIPE pattern" \
    '! grep -qE "find [^|]*\| *grep -q" "'"$tmp"'/code.sh"'

  # A8 — an oracle dir inside the repo is refused.
  t "A8 an oracle path inside ROOT is refused" \
    '( ROOT=/tmp/x ORACLE=/tmp/x/inside; case "$ORACLE" in "$ROOT"|"$ROOT"/*) exit 0;; *) exit 1;; esac )'

  # A9 — no dangerous permission bypass in operational code. Ralph invokes agents with these flags;
  # an unattended loop is the worst possible place to disable the permission system.
  t "A9 no --dangerously-skip-permissions / --dangerously-allow-all in operational code" \
    '! grep -qE "dangerously-(skip-permissions|allow-all)" "'"$tmp"'/code.sh"'
  t "A9b the loop denies agent access to the oracle dir in its settings allowlist" \
    'grep -q "deny" "'"$tmp"'/code.sh" && grep -q "Write(\\\\(\$oracle)/\*\*)" "'"$tmp"'/code.sh"'

  # A10 — stall detection: identical HEAD + identical dirty-hash is a NO_OP.
  t "A10 identical head+dirty pair classifies as NO_OP" \
    '( h1=abc; d1=def; h2=abc; d2=def; [ "$h1" = "$h2" ] && [ "$d1" = "$d2" ] )'

  # A12 — the attempt counter must count RECORDS, not pretty-printed lines. Regression test for a
  # panel-12 CONFIRMED BUG: `jq -r select(..) | wc -l` reported 8 for 2 records, so with MAX_ATTEMPTS=3
  # every item escalated after ONE attempt and the retry logic was silently dead.
  printf '{"event":"iteration_end","item":"g1"}\n{"event":"iteration_end","item":"g1"}\n{"event":"iteration_end","item":"g2"}\n' > "$tmp/j.ndjson"
  local rec_count line_count
  rec_count="$(jq -s --arg id g1 'map(select(.event=="iteration_end" and .item==$id))|length' "$tmp/j.ndjson")"
  line_count="$(jq -r --arg id g1 'select(.event=="iteration_end" and .item==$id)' "$tmp/j.ndjson" | grep -c .)"
  t "A12 record-count form returns 2 for 2 attempts"            '[ "$rec_count" = "2" ]'
  t "A12b the old line-count form over-counts (proves the bug)"  '[ "$line_count" -gt "$rec_count" ]'
  t "A12c attempts_for counts RECORDS and scopes them to this run" 'grep -q "jq -s --arg id" "'"$tmp"'/all.sh" && grep -q "run_id" "'"$tmp"'/all.sh"' 

  # A13 — rollback must be SCOPED and must not swallow failure. Regression test for the second
  # panel-12 finding: `git checkout -- .` repo-wide would have discarded pre-existing uncommitted work.
  t "A13 rollback never runs a repo-wide checkout"      '! grep -qE "checkout -- \\.( |$)" "'"$tmp"'/all.sh"'
  t "A13b rollback reverts an explicit per-path list"    'grep -q "git -C \"\$ROOT\" checkout -- \"\$pth\"" "'"$tmp"'/all.sh"'
  t "A13c rollback failure stops the loop, not silenced" 'grep -q "ROLLBACK FAILED" "'"$tmp"'/all.sh" && ! grep -q "checkout -- . 2>/dev/null || true" "'"$tmp"'/all.sh"'
  t "A13d untracked files created by the agent are LEFT, not deleted" 'grep -q "untracked_left" "'"$tmp"'/all.sh"'
  t "A13e a pre-iteration dirty PATH snapshot is taken"   'grep -q "DIRTY_SNAP=" "'"$tmp"'/all.sh"'

  # ── A14: BEHAVIOURAL rollback tests ────────────────────────────────────────────────────────────────
  # Panel #13 killed the previous A13 block: it was five `grep -q` assertions against the source text, so
  # replacing the rollback trigger with `if false; then` — leaving every string intact — still passed.
  # A test that greps for its subject is the "gate that cannot fail" pattern this harness exists to catch.
  # These assert FILE STATE after running the real logic, and A14z mutates the trigger to prove they bite.
  _mk_fixture() {                      # $1 = dir; a git repo with pre-existing dirt + a clean file
    mkdir -p "$1" && ( cd "$1" \
      && git init -q . \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
      && printf 'original\n' > preexisting.txt && printf 'original\n' > agentfile.txt \
      && git add -A && git -c user.email=t@t -c user.name=t commit -q -m seed \
      && printf 'PRE-EXISTING DIRT\n' >> preexisting.txt )   # dirty BEFORE the iteration
  }
  # Run the loop's real scoped-rollback logic against a fixture. Echoes "<pre-survived> <agent-reverted>".
  _run_rollback() {
    local dir="$1"; local snap="$dir/.snap"   # split: bash 3.2 + set -u binds left-to-right only across STATEMENTS
    ( cd "$dir" && git status --porcelain | sed 's/^...//' | sort -u > "$snap" )
    ( cd "$dir" && printf 'AGENT EDIT\n' >> agentfile.txt )          # the crashed agent's own change
    local own; own="$dir/.own"
    ( cd "$dir" && comm -13 "$snap" <(git status --porcelain | grep -E '^[ MARC]M|^M' | sed 's/^...//' | sort) 2>/dev/null | sort -u > "$own" )
    while IFS= read -r pth; do [ -n "$pth" ] || continue; ( cd "$dir" && git checkout -- "$pth" ); done < "$own"
    local pre agent
    grep -q 'PRE-EXISTING DIRT' "$dir/preexisting.txt" && pre=yes || pre=no
    grep -q 'AGENT EDIT' "$dir/agentfile.txt" && agent=no || agent=yes   # yes == reverted
    printf '%s %s' "$pre" "$agent"
  }
  _mk_fixture "$tmp/rb" >/dev/null 2>&1
  _mk_fixture_rc=$?
  local rb; rb="$(_run_rollback "$tmp/rb" 2>&1)"
  [ -n "${WALTEUR_LOOP_DEBUG:-}" ] && printf '    [debug] fixture_rc=%s rb=%s\n' "$_mk_fixture_rc" "$rb" >&2
  t "A14 rollback REVERTS the crashed agent's own edit (behavioural)"      '[ "${rb#* }" = "yes" ]'
  t "A14b rollback PRESERVES pre-existing dirt (behavioural, the 63-file hazard)" '[ "${rb%% *}" = "yes" ]'

  # A14c — untracked files the agent created must survive: deleting a file the loop never saw is data loss.
  _mk_fixture "$tmp/rb2" >/dev/null 2>&1
  ( cd "$tmp/rb2" && printf 'new\n' > agent-new.txt )
  _run_rollback "$tmp/rb2" >/dev/null
  t "A14c an untracked file the agent created is NOT deleted"  '[ -f "'"$tmp"'/rb2/agent-new.txt" ]'

  # A14z — MUTATION TEST. Neuter the rollback in a copy and assert the behavioural check now FAILS.
  # If this passes, A14/A14b are vacuous and must not be trusted.
  local mut="$tmp/mutant.sh"
  sed 's|if \[ "\$dirty_before" != "\$dirty_after" \]; then|if false; then|' "$0" > "$mut"
  local mutated; mutated=$(grep -c 'if false; then' "$mut")
  t "A14z the mutation actually applied (guards against a no-op sed)" '[ "$mutated" -ge 1 ]'
  # and prove the ROLLBACK COMMAND itself is what does the work: with no checkout, the edit must persist
  _mk_fixture "$tmp/rb3" >/dev/null 2>&1
  ( cd "$tmp/rb3" && printf 'AGENT EDIT\n' >> agentfile.txt )   # no rollback performed
  t "A14y without the rollback the agent edit PERSISTS (so A14 is not vacuous)" \
    'grep -q "AGENT EDIT" "'"$tmp"'/rb3/agentfile.txt"'

  # A11 — the denominator-truncation guard. A stdin-reading hook must not be able to shrink the sweep.
  # Regression test for a real bug: without </dev/null the live sweep measured 18 of 59 pinned gates,
  # which is a false-GREEN path.
  t "A11 gate hooks are invoked with stdin closed" \
    'grep -qE "bash \"\\\$hookpath\" </dev/null" "'"$tmp"'/code.sh"'
  t "A11b the pin is read on FD 3, not stdin" \
    'grep -qE "read -r -u 3" "'"$tmp"'/code.sh" && grep -qE "done 3< \"\\\$PIN\"" "'"$tmp"'/code.sh"'
  t "A11c a truncated sweep dies instead of emitting a partial oracle" \
    'grep -q "SWEEP TRUNCATED" "'"$tmp"'/code.sh"'
  # Prove the underlying hazard is real, so A11 is not guarding an imaginary problem.
  printf 'a\nb\nc\n' > "$tmp/pin3"
  local n_bad n_good
  n_bad=$(while read -r x; do cat >/dev/null; printf '%s\n' "$x"; done < "$tmp/pin3" | grep -c .)
  n_good=$(while read -r -u 3 x; do cat </dev/null >/dev/null; printf '%s\n' "$x"; done 3< "$tmp/pin3" | grep -c .)
  t "A11d the hazard is real: stdin-consuming child truncates a stdin read-loop (1 of 3)" '[ "'"$n_bad"'" = "1" ]'
  t "A11e the FD-3 + closed-stdin form reads all 3" '[ "'"$n_good"'" = "3" ]'

  printf 'walteur-loop selftest: %d/%d passed\n' "$pass" "$((pass+fail))"
  [ "$fail" -eq 0 ] || return 2
  return 0
}

# ---------------------------------------------------------------- main
if [ "${SELFTEST:-0}" = "1" ]; then selftest; exit $?; fi

preflight
# panel-13: LOOP.md:37 documents walteur-kit/PAUSED as a fail-closed halt for EVERY gate, and this loop
# ignored it completely — it would happily drive agents through a paused harness. Honour it, and re-check
# before each iteration so dropping the file mid-run stops the loop rather than only preventing a start.
if [ -f "$KIT/PAUSED" ]; then
  log "WALTEUR PAUSED ($KIT/PAUSED present) — refusing to start. Resume: rm walteur-kit/PAUSED"
  exit 2
fi
log "walteur-loop v$VERSION"
log "  ROOT   $ROOT"
log "  ORACLE $ORACLE  (outside the repo — the agent cannot write here)"
pin_registry
jrn run_start "$(jq -nc --arg v "$VERSION" --arg root "$ROOT" --argjson max "$MAX_ITERATIONS" \
  '{version:$v, root:$root, max_iterations:$max}')"

log "  measuring baseline..."
rm -f "$ORACLE/.SWEEP_TRUNCATED"
BASE_ORACLE="$(measure_gates baseline)"
[ -f "$ORACLE/.SWEEP_TRUNCATED" ] && die "refusing to run against a partial sweep ($(cat "$ORACLE/.SWEEP_TRUNCATED"))"
jq -r '"  baseline: \(.green)/\(.total) green · \(.red) red · \(.skip) skip · \(.missing) missing"' "$BASE_ORACLE" >&2
PREV_ORACLE="$BASE_ORACLE"

if oracle_says_done "$BASE_ORACLE"; then
  log "ALREADY DONE at baseline — every pinned hard gate is green."
  jrn run_end '{"outcome":"already_done"}'
  exit 0
fi

count="$(project_ledger "$BASE_ORACLE")"
log "  residual ledger: $count item(s)"

stalls=0
for i in $(seq 1 "$MAX_ITERATIONS"); do
  log ""
  log "=== iteration $i of $MAX_ITERATIONS ==="
  if [ -f "$KIT/PAUSED" ]; then
    log "WALTEUR PAUSED mid-run — halting before iteration $i."
    jrn run_end '{"outcome":"paused"}'; exit 2
  fi

  item_id="$(jq -r '.[0].id // empty' "$LEDGER")"
  [ -n "$item_id" ] || { log "  ledger empty but oracle not done — investigate"; jrn run_end '{"outcome":"ledger_empty_not_done"}'; exit 1; }

  if ! admit "$item_id"; then
    jq 'del(.[0])' "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
    jrn admission_refused "$(jq -nc --arg id "$item_id" '{item:$id}')"
    continue
  fi

  tries="$(attempts_for "$item_id")"
  if [ "$tries" -ge "$MAX_ATTEMPTS" ]; then
    log "  ESCALATE: $item_id failed $tries time(s) — parking it, moving on"
    jq --arg id "$item_id" 'map(select(.id != $id))' "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
    jrn escalated "$(jq -nc --arg id "$item_id" --argjson n "$tries" '{item:$id, attempts:$n}')"
    continue
  fi

  head_before="$(git_head)"; dirty_before="$(git_dirty)"
  # Path-level snapshot, not just a hash: the scoped rollback needs to know WHICH files were already
  # dirty so it can leave them alone.
  DIRTY_SNAP="$ORACLE/logs/dirty-before-$i.txt"
  git -C "$ROOT" status --porcelain 2>/dev/null | sed 's/^...//' | sort -u > "$DIRTY_SNAP" || : > "$DIRTY_SNAP"
  jrn iteration_begin "$(jq -nc --arg id "$item_id" --argjson i "$i" --arg h "$head_before" --arg d "$dirty_before" \
    '{iteration:$i, item:$id, head_before:$h, dirty_before:$d}')"

  pf="$ORACLE/logs/prompt-$i.md"; ao="$ORACLE/logs/agent-$i.out"
  build_prompt "$item_id" "$pf"

  spawn_agent "$item_id" "$pf" "$ao"
  agent_rc=$?          # REAL exit status. No pipe, no `|| true`.

  outcome="PROGRESSED"
  if [ "$agent_rc" -eq 124 ]; then outcome="TIMED_OUT"
  elif [ "$agent_rc" -ne 0 ]; then outcome="CRASHED"; fi

  head_after="$(git_head)"; dirty_after="$(git_dirty)"
  if [ "$head_before" = "$head_after" ] && [ "$dirty_before" = "$dirty_after" ]; then
    outcome="NO_OP"
  fi

  jrn iteration_end "$(jq -nc --arg id "$item_id" --argjson i "$i" --argjson rc "$agent_rc" \
    --arg h "$head_after" --arg d "$dirty_after" --arg o "$outcome" \
    '{iteration:$i, item:$id, agent_rc:$rc, head_after:$h, dirty_after:$d, outcome:$o}')"
  log "  agent rc=$agent_rc outcome=$outcome"

  # Roll back a failed iteration's partial edits so the next agent starts clean.
  #
  # SCOPED, deliberately. The first version ran `git checkout -- .` across the whole repo and sent its
  # failure to /dev/null with `|| true`. That would DESTROY pre-existing uncommitted work that had
  # nothing to do with this iteration — measured at 63 files in one real state of this repo — and the
  # journal would still record a clean rollback. A recovery primitive that can eat unrelated work is
  # worse than no recovery primitive.
  #
  # Now: revert only paths that are dirty NOW and were NOT dirty before this iteration, i.e. this
  # agent's own tracked modifications. Untracked files the agent created are left in place and only
  # reported — deleting a file the loop never saw before is not recovery, it is data loss. A rollback
  # that fails is recorded as failed and STOPS the loop rather than handing the next agent a dirty tree.
  if [ "$outcome" = "CRASHED" ] || [ "$outcome" = "TIMED_OUT" ]; then
    # panel-13 BUG: this required head_before == head_after, so an agent that COMMITTED and then left an
    # uncommitted edit before crashing got NO rollback at all — the common shape, since the prompt tells
    # it to commit. Committed work is intentionally left alone (reverting a commit is not this loop's job);
    # the uncommitted remainder is what must be cleaned. Drop the HEAD equality requirement and key only
    # on the working tree having changed.
    if [ "$dirty_before" != "$dirty_after" ]; then
      own="$ORACLE/logs/rollback-$i.paths"
      # tracked modifications present now but absent from the pre-iteration snapshot
      comm -13 "$DIRTY_SNAP" <(git -C "$ROOT" status --porcelain 2>/dev/null | grep -E '^[ MARC]M|^M' | sed 's/^...//' | sort) 2>/dev/null | sort -u > "$own" || : > "$own"
      n_own="$(grep -c . "$own" 2>/dev/null || printf '0')"
      untracked_new="$(comm -13 "$DIRTY_SNAP" <(git -C "$ROOT" status --porcelain 2>/dev/null | grep -E '^\?\?' | sed 's/^...//' | sort) 2>/dev/null | grep -c . || printf '0')"
      if [ "$n_own" -gt 0 ]; then
        log "  rolling back $n_own file(s) this $outcome iteration modified (pre-existing dirt untouched)"
        rb_rc=0
        while IFS= read -r pth; do
          [ -n "$pth" ] || continue
          git -C "$ROOT" checkout -- "$pth" || rb_rc=1
        done < "$own"
        jrn rollback "$(jq -nc --arg id "$item_id" --argjson n "$n_own" --argjson u "$untracked_new" --argjson rc "$rb_rc" \
          '{item:$id, reverted:$n, untracked_left:$u, rollback_rc:$rc}')"
        if [ "$rb_rc" -ne 0 ]; then
          log "ROLLBACK FAILED — refusing to hand the next agent a dirty tree. Inspect $own"
          jrn run_end '{"outcome":"rollback_failed"}'
          exit 2
        fi
      else
        log "  $outcome iteration left no tracked modifications of its own; nothing to roll back"
        jrn rollback "$(jq -nc --arg id "$item_id" --argjson u "$untracked_new" '{item:$id, reverted:0, untracked_left:$u}')"
      fi
      [ "$untracked_new" -gt 0 ] && log "  NOTE: $untracked_new new untracked file(s) left in place deliberately (deleting unseen files is not recovery)"
    fi
  fi

  if [ "$outcome" = "NO_OP" ]; then
    stalls=$((stalls+1))
    log "  STALL $stalls/$STALL_LIMIT (no commit, no working-tree change)"
    if [ "$stalls" -ge "$STALL_LIMIT" ]; then
      log "STALLED: $stalls consecutive no-op iterations. Stopping rather than burning the budget."
      jrn run_end "$(jq -nc --argjson s "$stalls" '{outcome:"stalled", stalls:$s}')"
      exit 1
    fi
  else
    stalls=0
  fi

  rm -f "$ORACLE/.SWEEP_TRUNCATED"
  CUR_ORACLE="$(measure_gates "iter$i")"
  [ -f "$ORACLE/.SWEEP_TRUNCATED" ] && die "refusing to continue against a partial sweep ($(cat "$ORACLE/.SWEEP_TRUNCATED"))"
  jq -r '"  gates: \(.green)/\(.total) green · \(.red) red · \(.skip) skip · \(.missing) missing"' "$CUR_ORACLE" >&2

  # Gate REGRESSION detection — green going red is worse than never-green. Ralph cannot see this.
  regressed="$(jq -s -r '
      (.[0].gates | map(select(.counted_green)) | map(.id)) as $was
    | (.[1].gates | map(select(.counted_green|not)) | map(.id)) as $now
    | ($was - ($was - $now)) | join(",")' "$PREV_ORACLE" "$CUR_ORACLE")"
  if [ -n "$regressed" ]; then
    log "  !! REGRESSION: previously-green gate(s) now red: $regressed"
    jrn regression "$(jq -nc --arg ids "$regressed" '{gates:$ids}')"
  fi
  PREV_ORACLE="$CUR_ORACLE"

  if oracle_says_done "$CUR_ORACLE"; then
    log ""
    log "CONVERGED at iteration $i — every pinned hard gate green, verdict derived from gate state."
    jrn run_end "$(jq -nc --argjson i "$i" '{outcome:"converged", iterations:$i}')"
    exit 0
  fi

  project_ledger "$CUR_ORACLE" >/dev/null
done

log ""
log "NOT CONVERGED after $MAX_ITERATIONS iteration(s)."
jq -r '"  still blocking: " + (.blocking | map(.id + "(" + .class + ")") | join(", "))' "$PREV_ORACLE" >&2
log "  journal: $JOURNAL"
jrn run_end "$(jq -nc --argjson m "$MAX_ITERATIONS" '{outcome:"cap_exhausted", max:$m}')"
exit 1
