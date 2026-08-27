#!/usr/bin/env bash
# WALTEUR trace-mine — the SELF-IMPROVING offline trace miner (HALO's one net-new, done WALTEUR's flat-file way).
#
# NOT HALO's RLM engine, NOT a daemon, NOT a second brain. It is an OFFLINE, on-demand reader (run by /optimize
# or by hand) that scans the structured artifacts WALTEUR ALREADY writes ACROSS runs and finds SYSTEMIC recurring
# patterns — never one-offs. It feeds the EXISTING flywheel: it emits 0–3 CANDIDATE lessons into the SAME
# lesson-gate.sh pipeline (graphify stays the one brain — no new store) AND appends a propose-never-apply patch
# proposal to _relay/ISSUES.md (mirrors self-heal.sh's escalation). It NEVER auto-applies anything.
#
# WHAT IT SCANS (the artifacts the engine already writes — read-only):
#   walteur-kit/run-trace.jsonl   per-phase/tool/gate spans  {ts,phase,model,tool,exit_code,gate_verdict,tokens}
#                                optional {tool_signature} for redundant-call mining; run-trace can derive
#                                conservative signatures from known-equivalent command forms.
#   walteur-kit/refine-log.json   triage verdicts            [{iter,gate,consecutive_n,root_cause,confidence,route}]
#   walteur-kit/SUMMARY.jsonl     reconciliation ledger      {task-id,wave,planned,actual,ac_verdict,deviation}
#   walteur-kit/receipt.json      cost receipt               {est_usd,ceiling_usd,shippable,issues}
#   _relay/ISSUES.md              prior codified issues (read for context; this script APPENDS its proposal here)
#
# THE SYSTEMIC-vs-ONE-OFF LAW (the whole point — honest by construction):
#   A finding is SYSTEMIC iff it RECURS at or above a threshold (default 3) across the append-only ledger.
#   A thing that happened ONCE is a one-off and is NEVER flagged, NEVER emitted as a lesson, NEVER proposed.
#   HONESTY BOUNDARY: run-trace.jsonl spans carry NO per-build id (by design — emitSpan writes none). So this
#   miner counts OCCURRENCES ACROSS THE WHOLE LEDGER; it cannot and does not claim "N distinct builds". It says
#   "recurred N times in the ledger" — a recurrence count, not a build count. That is the honest, defensible signal.
#
# THE PATTERNS IT MINES (each only fires when recurrence >= threshold):
#   1. same-gate RED         a gate/senior whose RED|FAIL|VETO recurs (run-trace gate_verdict + refine-log gate)
#   2. malformed/hallucinated tool calls   spans with a non-zero exit_code for the same tool, recurring
#   3. redundant tool calls repeated explicit or normalized tool_signature spans, recurring
#   4. refusal / stall loop  refine triage routes (refine-log) or SUMMARY BLOCKED verdicts recurring
#   5. dead gate             a gate that appears in the run-trace but NEVER once goes green/PASS (never fires useful) [advisory]
#   6. cost-spike phase      a phase whose token estimate dominates, recurring across the ledger [advisory]
#
# WHAT IT EMITS (never auto-applies — proposes only):
#   - up to 3 CANDIDATE lessons piped to lesson-gate.sh (the SAME shape it consumes: {lesson,why,domain,stack,
#     confidence,source}). lesson-gate.sh then dedupes/contradiction-holds/bounds them — we do NOT bypass it.
#   - ONE proposal block appended to _relay/ISSUES.md (systemic finding + a 1-line fix hypothesis), in the exact
#     propose-never-apply idiom of self-heal.sh ("PROTOCOL: proposal, NOT auto-applied" + an "Action:" line).
#
# CONTRACT (kit idiom):
#   clean corpus (nothing systemic)   => emits NOTHING (no lesson, no ISSUES line). The common path.
#   systemic pattern(s) found         => emit <=3 candidate lessons + ONE ISSUES proposal block.
#   no artifacts at all               => loud skip, exit 0 (nothing to mine; bare/fresh project).
#
# Universal controls (match every WALTEUR surface):
#   kill switch  walteur-kit/PAUSED present   => exit 2 (the ONLY non-selftest exit-2 path; paused != green).
#   bypass       WALTEUR_TRACEMINE=off        => LOUD skip, exit 0, nothing written.
#   ALWAYS exit 0 otherwise — it is a REPORT, not a gate. It NEVER blocks a build.
#
# Tunables (env): WALTEUR_TRACEMINE_MIN (recurrence threshold, default 3) · WALTEUR_TRACEMINE_MAXLESSONS (default 3).
# Zero-dep: bash + jq, with grep/sed fallback when jq is absent. Flat files only; never indexed (graphify is the
# one brain). Append-only consumers; this script never truncates any artifact.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
RUN_TRACE="$(cd "$(dirname "$0")" && pwd)/run-trace.sh"
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
RELAY="$ROOT/_relay"
TRACE="$KIT/run-trace.jsonl"
REFINE="$KIT/refine-log.json"
SUMMARY="$KIT/SUMMARY.jsonl"
RECEIPT="$KIT/receipt.json"
REPORT="$KIT/trace-mine-report.json"
ISSUES="$RELAY/ISSUES.md"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# lesson-gate.sh lives in walteur-kit/memory/ (the flywheel). Find it relative to this hook; degrade gracefully.
LESSON_GATE="$KIT/memory/lesson-gate.sh"

MIN="${WALTEUR_TRACEMINE_MIN:-3}"          # recurrence threshold — below this is a one-off, never flagged
MAXLESSONS="${WALTEUR_TRACEMINE_MAXLESSONS:-3}"

have() { command -v "$1" >/dev/null 2>&1; }

bool_json() {
  if [ -s "$1" ]; then printf 'true'; else printf 'false'; fi
}

PROPOSAL_WRITTEN=0
SYSTEMIC_COUNT=0

write_report() { # $1=verdict $2=reason
  local verdict="$1" reason="$2"
  mkdir -p "$KIT"
  if have jq; then
    jq -n \
      --arg verdict "$verdict" \
      --arg ts "$TS" \
      --arg reason "$reason" \
      --arg gate "trace-mine" \
      --argjson min "$MIN" \
      --argjson max_lessons "$MAXLESSONS" \
      --argjson systemic_count "${SYSTEMIC_COUNT:-0}" \
      --argjson lessons_emitted "${LESSON_EMITTED:-0}" \
      --argjson proposal_appended "$([ "${PROPOSAL_WRITTEN:-0}" -eq 1 ] && echo true || echo false)" \
      --argjson artifacts "$(jq -n \
        --argjson run_trace "$(bool_json "$TRACE")" \
        --argjson refine_log "$(bool_json "$REFINE")" \
        --argjson summary "$(bool_json "$SUMMARY")" \
        --argjson receipt "$(bool_json "$RECEIPT")" \
        '{run_trace:$run_trace, refine_log:$refine_log, summary:$summary, receipt:$receipt}')" \
      '{
        verdict: $verdict,
        ts: $ts,
        gate: $gate,
        reason: $reason,
        recurrence_threshold: $min,
        max_lessons: $max_lessons,
        systemic_count: $systemic_count,
        lessons_emitted: $lessons_emitted,
        proposal_appended: $proposal_appended,
        artifacts: $artifacts
      }' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"trace-mine","reason":"%s","systemic_count":%s,"lessons_emitted":%s,"proposal_appended":%s}\n' \
    "$verdict" "$TS" "$reason" "${SYSTEMIC_COUNT:-0}" "${LESSON_EMITTED:-0}" "$([ "${PROPOSAL_WRITTEN:-0}" -eq 1 ] && echo true || echo false)" > "$REPORT" 2>/dev/null || true
}

# ── universal controls ────────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { write_report "BLOCKED" "walteur-kit/PAUSED present"; echo "WALTEUR PAUSED (walteur-kit/PAUSED). trace-mine exiting 2." >&2; exit 2; }
if [ "${WALTEUR_TRACEMINE:-on}" = "off" ]; then
  write_report "SKIP" "WALTEUR_TRACEMINE=off"
  echo "trace-mine: SKIP — WALTEUR_TRACEMINE=off (loud skip, nothing written)." >&2
  exit 0
fi

# ── emit one candidate lesson into the EXISTING lesson-gate pipeline ────────────────
# We pipe the candidate to lesson-gate.sh (the one brain's gate) — we do NOT write the store ourselves, so its
# dedupe / contradiction-hold / bound rules govern. If lesson-gate.sh is missing, we degrade to a loud note
# (still exit 0) — never silently invent a parallel store.
LESSON_EMITTED=0
LESSONS_OUT=""      # accumulates emitted candidate JSON (one per line) — printed to stdout once, at the end.
                   # NOTE: miners must NOT be called inside $( ) — they mutate these globals; a subshell loses them.
emit_lesson() { # $1=lesson  $2=why  $3=domain  $4=stack  $5=confidence
  [ "$LESSON_EMITTED" -ge "$MAXLESSONS" ] && return 0
  local lesson="$1" why="$2" domain="${3:-build-process}" stack="${4:-walteur-engine}" conf="${5:-0.6}"
  local cand
  if have jq; then
    cand="$(jq -cn --arg l "$lesson" --arg w "$why" --arg d "$domain" --arg s "$stack" --argjson c "$conf" \
      '{lesson:$l, why:$w, domain:$d, stack:$s, confidence:$c, source:"trace-mine"}')"
  else
    cand="{\"lesson\":\"$lesson\",\"why\":\"$why\",\"domain\":\"$domain\",\"stack\":\"$stack\",\"confidence\":$conf,\"source\":\"trace-mine\"}"
  fi
  if [ -x "$LESSON_GATE" ] || [ -f "$LESSON_GATE" ]; then
    printf '%s' "$cand" | bash "$LESSON_GATE" >&2 2>&1 || true
  else
    echo "trace-mine: lesson-gate.sh not found at $LESSON_GATE — candidate NOT stored (no parallel store): $cand" >&2
  fi
  LESSON_EMITTED=$((LESSON_EMITTED+1))
  LESSONS_OUT="${LESSONS_OUT}${cand}"$'\n'   # captured for the end-of-run stdout flush (selftest/visibility)
}

# ── append ONE propose-never-apply proposal block to _relay/ISSUES.md ───────────────
# Exact idiom of self-heal.sh: a "## ... (PROTOCOL: proposal, NOT auto-applied)" header, the systemic findings,
# and an "Action:" line. We APPEND once per run only when at least one systemic finding exists. Never auto-edits.
PROPOSAL_BODY=""    # accumulates "- <finding> — FIX HYPOTHESIS: <one line>\n"
add_proposal_line() { PROPOSAL_BODY="${PROPOSAL_BODY}- $1\n"; }

flush_proposal() {
  [ -n "$PROPOSAL_BODY" ] || return 0
  mkdir -p "$RELAY"
  {
    echo ""
    echo "## TRACE-MINE systemic findings — $TS (PROTOCOL: proposal, NOT auto-applied)"
    echo "> Offline trace-mine over the artifacts WALTEUR already writes (run-trace.jsonl / refine-log.json / SUMMARY.jsonl / receipt.json). Each item below RECURRED >= ${MIN}x in the ledger (recurrence count, NOT a build count — spans carry no build id). One-offs were ignored by design."
    printf '%b' "$PROPOSAL_BODY"
    echo "Action: triage the highest-recurrence finding first; the FIX HYPOTHESIS is a starting point, not a verdict. Candidate lesson(s) for these were proposed to lesson-gate.sh (which dedupes/holds/bounds them). Apply nothing automatically — human review, then a scoped patch."
  } >> "$ISSUES"
  PROPOSAL_WRITTEN=1
  echo "trace-mine: appended ONE systemic-findings proposal block to $ISSUES (propose-never-apply)." >&2
}

# ════════════════════════════════════════════════════════════════════════════════════
#  MINERS — each mutates GLOBALS in place (never echoed / never $( )-captured, or a subshell
#  would lose the PROPOSAL_BODY / LESSON_EMITTED / SYSTEMIC_COUNT accumulators). Each miner
#  bumps SYSTEMIC_COUNT by 1 when it finds a systemic (>= MIN) pattern, else leaves it.
# ════════════════════════════════════════════════════════════════════════════════════
# Are there ANY artifacts to mine? If not, loud skip.
any_artifact() {
  [ -s "$TRACE" ] || [ -s "$REFINE" ] || [ -s "$SUMMARY" ] || [ -s "$RECEIPT" ]
}

# gate label = the LEADING token before the first ':' (verdicts are "<gate>:RED:iter<n>", "<gate>:PASS", "PASS").
# split(":")[0] gives the gate ("senior_security"), never "senior_security:RED" — so RED/iter never leak into the key.

# ── PATTERN 1: same-gate RED recurring ──────────────────────────────────────────────
# Source A: run-trace.jsonl spans whose gate_verdict matches RED|FAIL|VETO (case-insensitive) OR exit_code != 0
#           with a non-empty gate_verdict — grouped by the LEADING gate label in gate_verdict.
# Source B: refine-log.json triage rows — the gate field, weighted by consecutive_n (a gate RED for 4 consecutive
#           iters is itself systemic even in ONE refine-log; we fold consecutive_n into the recurrence count).
mine_same_gate_red() {
  local top_gate="" top_count=0
  if have jq && [ -s "$TRACE" ]; then
    local agg
    agg="$(jq -rs '
      map(select(
            ((.gate_verdict // "") | test("RED|FAIL|VETO"; "i"))
         or (((.exit_code // "0") != "0") and ((.gate_verdict // "") != ""))
      ))
      | map((.gate_verdict // "unknown") | split(":")[0])   # GATE = leading token, never the RED/iter suffix
      | group_by(.) | map({gate:.[0], n:length})
      | sort_by(-.n) | .[0] // empty | "\(.gate)\t\(.n)"
    ' "$TRACE" 2>/dev/null || true)"
    if [ -n "$agg" ]; then
      top_gate="$(printf '%s' "$agg" | cut -f1)"
      top_count="$(printf '%s' "$agg" | cut -f2)"
    fi
  fi
  # fold in refine-log consecutive_n for the same/any gate (a gate RED N consecutive iters counts N)
  if have jq && [ -s "$REFINE" ]; then
    local rl
    rl="$(jq -rs 'add // [] | map(select(type=="object"))
                  | group_by(.gate) | map({gate:.[0].gate, n:(map(.consecutive_n // 1) | add)})
                  | sort_by(-.n) | .[0] // empty | "\(.gate)\t\(.n)"' "$REFINE" 2>/dev/null || true)"
    if [ -n "$rl" ]; then
      local rg rn; rg="$(printf '%s' "$rl" | cut -f1)"; rn="$(printf '%s' "$rl" | cut -f2)"
      if [ "${rn:-0}" -gt "${top_count:-0}" ] 2>/dev/null; then top_gate="$rg"; top_count="$rn"; fi
    fi
  fi
  # grep/sed fallback when jq is absent — count RED-ish lines in run-trace (gate label not extractable cheaply)
  if ! have jq && [ -s "$TRACE" ]; then
    top_count="$(grep -ciE '"gate_verdict":"[^"]*(RED|FAIL|VETO)' "$TRACE" 2>/dev/null || echo 0)"
    top_gate="(gate — jq absent, label not extracted)"
  fi
  [ "${top_count:-0}" -ge "$MIN" ] 2>/dev/null || return 0
  emit_lesson \
    "A governance/QA gate ('$top_gate') goes RED repeatedly across builds — front-load its check into the PLAN/spec phase, not the refine loop." \
    "trace-mine: gate '$top_gate' recurred RED ${top_count}x in the ledger (>= ${MIN}x threshold); repeated late RED on the same gate means the failure is predictable and should be designed out upfront." \
    "build-process" "walteur-engine" "0.7"
  add_proposal_line "SAME-GATE RED: gate '$top_gate' went RED ${top_count}x — FIX HYPOTHESIS: move its acceptance criteria into PLAN/spec-lint so the build can't reach refine with this gap."
  SYSTEMIC_COUNT=$((SYSTEMIC_COUNT+1))
}

# ── PATTERN 2: malformed / hallucinated / failing tool calls recurring ──────────────
# Spans with exit_code != 0 grouped by tool. A tool that fails once is noise; a tool that fails >= MIN times is a
# systemic call problem (bad invocation pattern, missing dep, hallucinated flags).
mine_tool_failures() {
  local top_tool="" top_count=0
  if have jq && [ -s "$TRACE" ]; then
    local agg
    agg="$(jq -rs '
      map(select(((.exit_code // "0") != "0") and ((.tool // "") != "")))
      | map(.tool) | group_by(.) | map({tool:.[0], n:length})
      | sort_by(-.n) | .[0] // empty | "\(.tool)\t\(.n)"' "$TRACE" 2>/dev/null || true)"
    if [ -n "$agg" ]; then top_tool="$(printf '%s' "$agg" | cut -f1)"; top_count="$(printf '%s' "$agg" | cut -f2)"; fi
  elif [ -s "$TRACE" ]; then
    top_count="$(grep -cE '"exit_code":"[^0"][^"]*"' "$TRACE" 2>/dev/null || echo 0)"
    top_tool="(tool — jq absent)"
  fi
  [ "${top_count:-0}" -ge "$MIN" ] 2>/dev/null || return 0
  emit_lesson \
    "Tool '$top_tool' fails repeatedly (non-zero exit) across builds — verify its invocation contract / availability before relying on it in a wave." \
    "trace-mine: tool '$top_tool' returned non-zero ${top_count}x in the ledger (>= ${MIN}x); a recurring tool failure is a contract/dep problem, not bad luck." \
    "tooling" "walteur-engine" "0.6"
  add_proposal_line "RECURRING TOOL FAILURE: '$top_tool' exited non-zero ${top_count}x — FIX HYPOTHESIS: add a tool-readiness precheck (or fix the invocation pattern) before the build wave that uses it."
  SYSTEMIC_COUNT=$((SYSTEMIC_COUNT+1))
}

# ── PATTERN 3: redundant tool calls recurring ─────────────────────────────────────
# Requires richer trace spans with tool_signature (explicit --signature or derived by run-trace.sh --command
# for known-safe equivalent command forms). This deliberately does NOT infer redundancy from tool name alone
# because repeated use of Bash/Read/Edit can be legitimate. The key is phase + tool + normalized signature,
# and only successful spans count; failing repeats are handled by mine_tool_failures instead.
mine_redundant_tool_calls() {
  have jq && [ -s "$TRACE" ] || return 0
  local redundant
  redundant="$(jq -rs '
    def sig: (.tool_signature // .normalized_tool_signature // .command_signature // .normalized_input // "");
    map(select(
      (sig | type == "string" and length > 0)
      and (((.exit_code // "0") | tostring) == "0")
    ))
    | group_by([(.phase // ""), (.tool // ""), sig])
    | map({phase:(.[0].phase // ""), tool:(.[0].tool // ""), signature:(.[0] | sig), n:length})
    | map(select(.n >= '"$MIN"'))
    | sort_by(-.n)
    | .[0] // empty
    | if type == "object" then [.phase, .tool, .signature, (.n|tostring)] | @tsv else empty end
  ' "$TRACE" 2>/dev/null || true)"
  [ -n "$redundant" ] || return 0
  local phase tool signature count
  phase="$(printf '%s' "$redundant" | cut -f1)"
  tool="$(printf '%s' "$redundant" | cut -f2)"
  signature="$(printf '%s' "$redundant" | cut -f3)"
  count="$(printf '%s' "$redundant" | cut -f4)"
  emit_lesson \
    "Tool '$tool' repeats the same normalized signature in phase '$phase' — cache, batch, or reuse the prior result before calling it again." \
    "trace-mine: signature '$signature' recurred ${count}x for tool '$tool' in phase '$phase' (>= ${MIN}x); repeated identical successful calls are likely wasted context, time, or money unless the plan explains why freshness is required." \
    "tooling" "walteur-engine" "0.65"
  add_proposal_line "REDUNDANT TOOL CALL: '$tool' repeated signature '$signature' ${count}x in phase '$phase' — FIX HYPOTHESIS: cache/reuse the result, batch the call, or record why each repeat needs fresh state."
  SYSTEMIC_COUNT=$((SYSTEMIC_COUNT+1))
}

# ── PATTERN 4: refusal / stall loop recurring ───────────────────────────────────────
# Source A: SUMMARY.jsonl ac_verdict == BLOCKED (the build stalled on a task). Source B: refine-log routes that
# escalate (Intent/Spec re-derive) — a route that recurs means the engine keeps stalling the same way.
mine_stall_loop() {
  local blocked=0 routed=0
  if have jq && [ -s "$SUMMARY" ]; then
    blocked="$(jq -rs 'map(select((.ac_verdict // "") == "BLOCKED")) | length' "$SUMMARY" 2>/dev/null || echo 0)"
  elif [ -s "$SUMMARY" ]; then
    blocked="$(grep -c '"ac_verdict":"BLOCKED"' "$SUMMARY" 2>/dev/null || echo 0)"
  fi
  if have jq && [ -s "$REFINE" ]; then
    routed="$(jq -rs 'add // [] | map(select(type=="object" and ((.route // "Code") != "Code"))) | length' "$REFINE" 2>/dev/null || echo 0)"
  fi
  local total=$(( ${blocked:-0} + ${routed:-0} ))
  [ "$total" -ge "$MIN" ] 2>/dev/null || return 0
  emit_lesson \
    "Builds stall/re-route repeatedly (BLOCKED tasks or Intent/Spec re-derives) — sharpen DISCOVER/PRD so the bet and spec are validated before the build wave." \
    "trace-mine: ${blocked} BLOCKED task(s) + ${routed} non-Code re-route(s) = ${total} stall signals (>= ${MIN}x); repeated stalls trace to a weak upstream spec/bet, not the code." \
    "build-process" "walteur-engine" "0.65"
  add_proposal_line "RECURRING STALL/RE-ROUTE: ${total} stall signals (BLOCKED=${blocked}, re-route=${routed}) — FIX HYPOTHESIS: strengthen the DISCOVER red-team + PRD gate so the spec is load-bearing before Build."
  SYSTEMIC_COUNT=$((SYSTEMIC_COUNT+1))
}

# ── PATTERN 5: dead gate (advisory) — appears but NEVER goes green ───────────────────
# A gate label present in run-trace gate_verdict whose spans are ALL non-PASS/non-green AND it appears >= MIN
# times. A gate that fires often but never passes useful work is suspect (mis-scoped or always-skipped).
# Advisory: proposal line only, NO lesson (it is a config smell, not a generalizable failure-mode).
mine_dead_gate() {
  have jq && [ -s "$TRACE" ] || return 0
  local dead
  dead="$(jq -rs '
    map(select((.gate_verdict // "") != ""))
    | group_by((.gate_verdict | split(":")[0]))
    | map({gate:(.[0].gate_verdict | split(":")[0]),
           n:length,
           green:(map(select((.gate_verdict//"")|test("PASS|GREEN|OK"; "i"))) | length)})
    | map(select(.n >= '"$MIN"' and .green == 0))
    | sort_by(-.n) | .[0] // empty | "\(.gate)\t\(.n)"' "$TRACE" 2>/dev/null || true)"
  [ -n "$dead" ] || return 0
  local dg dn; dg="$(printf '%s' "$dead" | cut -f1)"; dn="$(printf '%s' "$dead" | cut -f2)"
  add_proposal_line "DEAD/STUCK GATE (advisory): '$dg' appeared ${dn}x but NEVER recorded a PASS — FIX HYPOTHESIS: it is mis-scoped or always-skipped; confirm it can ever go green, else retire or fix its trigger."
  SYSTEMIC_COUNT=$((SYSTEMIC_COUNT+1))
}

# ── PATTERN 6: cost-spike phase (advisory) — one phase dominates tokens, recurring ───
# Sum token estimates per phase; if one phase's estimate is >= 60% of total AND there are >= MIN spans, flag it.
# Advisory: proposal line only, NO lesson (cost shape is project-dependent, not a generalizable failure-mode).
mine_cost_spike() {
  have jq && [ -s "$TRACE" ] || return 0
  local spike
  spike="$(jq -rs '
    (map(.tokens.estimate // 0) | add) as $tot
    | (length) as $cnt
    | (group_by(.phase) | map({phase:.[0].phase, t:(map(.tokens.estimate // 0) | add)}) | sort_by(-.t)) as $byphase
    | if ($tot > 0 and $cnt >= '"$MIN"' and ($byphase[0].t * 100 / $tot) >= 60)
      then "\($byphase[0].phase)\t\(($byphase[0].t * 100 / $tot) | floor)" else empty end' "$TRACE" 2>/dev/null || true)"
  [ -n "$spike" ] || return 0
  local sp pct; sp="$(printf '%s' "$spike" | cut -f1)"; pct="$(printf '%s' "$spike" | cut -f2)"
  add_proposal_line "COST-SPIKE PHASE (advisory): phase '$sp' is ~${pct}% of estimated tokens — FIX HYPOTHESIS: route that phase to a cheaper model or split its work; check cost-budget.sh ceiling headroom."
  SYSTEMIC_COUNT=$((SYSTEMIC_COUNT+1))
}

# ════════════════════════════════════════════════════════════════════════════════════
#  MAIN — miners run in THIS shell (no subshell) so they can mutate the accumulators.
# ════════════════════════════════════════════════════════════════════════════════════
run_mine() {
  if ! any_artifact; then
    write_report "SKIP" "no artifacts to mine"
    echo "trace-mine: SKIP — no artifacts to mine (run-trace.jsonl / refine-log.json / SUMMARY.jsonl / receipt.json all absent or empty)." >&2
    return 0
  fi

  mine_same_gate_red
  mine_tool_failures
  mine_redundant_tool_calls
  mine_stall_loop
  mine_dead_gate
  mine_cost_spike

  flush_proposal

  # Flush the captured candidate lessons to stdout (one JSON per line) for selftest/visibility.
  [ -n "$LESSONS_OUT" ] && printf '%s' "$LESSONS_OUT"

  if [ "$SYSTEMIC_COUNT" -eq 0 ]; then
    write_report "PASS" "no systemic pattern met the recurrence threshold"
    echo "trace-mine: clean — no SYSTEMIC pattern (>= ${MIN}x) found. Nothing emitted (one-offs ignored by design)." >&2
  else
    write_report "PASS" "$SYSTEMIC_COUNT systemic pattern(s) proposed for review"
    echo "trace-mine: $SYSTEMIC_COUNT systemic pattern(s) found; $LESSON_EMITTED candidate lesson(s) proposed to lesson-gate; ISSUES proposal written." >&2
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════════════════════
#  SELFTEST — hermetic. Synthetic multi-run corpus with a SYSTEMIC pattern + a one-off.
#  Asserts: flags the systemic pattern (NOT the one-off) · emits a well-formed candidate
#  lesson + an ISSUES.md proposal line · clean corpus emits nothing · WALTEUR_TRACEMINE=off skips.
# ════════════════════════════════════════════════════════════════════════════════════
selftest() {
  local fails=0 total=0 tmp rc
  ck() { # $1=label $2=want $3=got
    total=$((total+1))
    if [ "$3" = "$2" ]; then echo "  ok   — $1"
    else echo "  FAIL — $1 (want=$2, got=$3)"; fails=$((fails+1)); fi
  }

  echo "trace-mine selftest:"

  # The SPEC distribution may not ship lesson-gate.sh. The selftest proves trace-mine degrades loudly and
  # never creates a parallel memory store when the canonical lesson gate is absent.
  local SELFTEST_MEM
  # ── CASE 1: systemic SAME-GATE RED (recurs 4x) + a one-off RED (1x). Expect: flag systemic, IGNORE one-off ──
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/trace-mine-st.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/memory" "$tmp/_relay"
  SELFTEST_MEM="$tmp/.lessons.jsonl"
  # synthetic run-trace.jsonl: gate 'senior_security' RED 4 distinct times (SYSTEMIC) + gate 'senior_pm' RED once (ONE-OFF)
  cat > "$tmp/walteur-kit/run-trace.jsonl" <<'JSONL'
{"ts":"2026-06-20T10:00:00Z","phase":"Review","model":"opus","tool":"agent","exit_code":"0","gate_verdict":"senior_security:RED:iter1","tokens":{"estimate":100}}
{"ts":"2026-06-20T10:01:00Z","phase":"Refine","model":"opus","tool":"agent","exit_code":"0","gate_verdict":"senior_security:RED:iter2","tokens":{"estimate":120}}
{"ts":"2026-06-20T11:00:00Z","phase":"Review","model":"opus","tool":"agent","exit_code":"0","gate_verdict":"senior_security:RED:iter1","tokens":{"estimate":110}}
{"ts":"2026-06-20T11:01:00Z","phase":"Refine","model":"opus","tool":"agent","exit_code":"0","gate_verdict":"senior_security:RED:iter2","tokens":{"estimate":115}}
{"ts":"2026-06-20T12:00:00Z","phase":"Review","model":"opus","tool":"agent","exit_code":"0","gate_verdict":"senior_pm:RED:iter1","tokens":{"estimate":90}}
{"ts":"2026-06-20T12:30:00Z","phase":"Build","model":"sonnet","tool":"Bash","exit_code":"0","gate_verdict":"","tokens":{"estimate":80}}
JSONL
  : > "$tmp/_relay/ISSUES.md"
  local out
  out="$(WALTEUR_ROOT="$tmp" WALTEUR_MEM="$SELFTEST_MEM" WALTEUR_TRACEMINE_MIN=3 bash "$SELF" 2>/dev/null)"; rc=$?
  ck "systemic case: exit 0 (report, not a gate)" 0 "$rc"
  # flagged the SYSTEMIC gate (senior_security), recurrence 4
  ck "systemic case: emits a candidate lesson naming senior_security" 0 "$(printf '%s' "$out" | grep -q 'senior_security' && echo 0 || echo 1)"
  # did NOT flag the one-off gate (senior_pm appears once < MIN)
  ck "systemic case: does NOT flag the one-off (senior_pm)" 0 "$(printf '%s' "$out" | grep -q 'senior_pm' && echo 1 || echo 0)"
  # candidate lesson is well-formed JSON with a non-empty .lesson (the shape lesson-gate.sh requires)
  local cand_ok=1
  if have jq; then
    cand_ok="$(printf '%s\n' "$out" | grep '"source":"trace-mine"' | head -n1 | jq -e '.lesson | type=="string" and (length>0)' >/dev/null 2>&1 && echo 0 || echo 1)"
  else
    cand_ok="$(printf '%s' "$out" | grep -q '"source":"trace-mine"' && echo 0 || echo 1)"
  fi
  ck "systemic case: candidate lesson is well-formed (non-empty .lesson)" 0 "$cand_ok"
  # ISSUES.md got exactly ONE proposal block, propose-never-apply, naming the systemic gate
  ck "systemic case: ISSUES.md gained a propose-never-apply block" 0 "$(grep -q 'PROTOCOL: proposal, NOT auto-applied' "$tmp/_relay/ISSUES.md" && echo 0 || echo 1)"
  ck "systemic case: ISSUES proposal names senior_security" 0 "$(grep -q 'senior_security' "$tmp/_relay/ISSUES.md" && echo 0 || echo 1)"
  ck "systemic case: ISSUES proposal does NOT name the one-off senior_pm" 0 "$(grep -q 'senior_pm' "$tmp/_relay/ISSUES.md" && echo 1 || echo 0)"
  local block_count; block_count="$(grep -c 'TRACE-MINE systemic findings' "$tmp/_relay/ISSUES.md" 2>/dev/null | tr -d ' \n' || echo 0)"
  ck "systemic case: exactly ONE proposal block appended" 1 "$block_count"
  ck "systemic case: report records PASS with proposal evidence" 0 "$(jq -e '.verdict=="PASS" and .systemic_count >= 1 and .proposal_appended == true and .lessons_emitted >= 1 and .artifacts.run_trace == true' "$tmp/walteur-kit/trace-mine-report.json" >/dev/null 2>&1 && echo 0 || echo 1)"
  ck "systemic case: missing lesson-gate creates no parallel memory store" 0 "$([ ! -s "$SELFTEST_MEM" ] && echo 0 || echo 1)"
  rm -rf "$tmp"

  # ── CASE 2: CLEAN corpus (every pattern below threshold) — expect NOTHING emitted ──
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/trace-mine-clean.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/memory" "$tmp/_relay"
  cat > "$tmp/walteur-kit/run-trace.jsonl" <<'JSONL'
{"ts":"2026-06-20T10:00:00Z","phase":"Build","model":"sonnet","tool":"Bash","exit_code":"0","gate_verdict":"","tokens":{"estimate":100}}
{"ts":"2026-06-20T10:01:00Z","phase":"Review","model":"opus","tool":"agent","exit_code":"0","gate_verdict":"senior_security:PASS","tokens":{"estimate":120}}
{"ts":"2026-06-20T10:02:00Z","phase":"Audit","model":"opus","tool":"agent","exit_code":"0","gate_verdict":"PASS","tokens":{"estimate":90}}
JSONL
  : > "$tmp/_relay/ISSUES.md"
  out="$(WALTEUR_ROOT="$tmp" WALTEUR_TRACEMINE_MIN=3 bash "$SELF" 2>/dev/null)"; rc=$?
  ck "clean case: exit 0" 0 "$rc"
  ck "clean case: emits NO candidate lesson" 0 "$(printf '%s' "$out" | grep -q '"source":"trace-mine"' && echo 1 || echo 0)"
  ck "clean case: ISSUES.md untouched (no proposal block)" 0 "$([ ! -s "$tmp/_relay/ISSUES.md" ] && echo 0 || echo 1)"
  ck "clean case: report records PASS with zero systemic patterns" 0 "$(jq -e '.verdict=="PASS" and .systemic_count == 0 and .proposal_appended == false and .artifacts.run_trace == true' "$tmp/walteur-kit/trace-mine-report.json" >/dev/null 2>&1 && echo 0 || echo 1)"
  rm -rf "$tmp"

  # ── CASE 3: WALTEUR_TRACEMINE=off — loud skip, nothing written ──
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/trace-mine-off.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/memory" "$tmp/_relay"
  cat > "$tmp/walteur-kit/run-trace.jsonl" <<'JSONL'
{"ts":"2026-06-20T10:00:00Z","phase":"Review","model":"opus","tool":"agent","exit_code":"0","gate_verdict":"senior_security:RED:iter1","tokens":{"estimate":100}}
{"ts":"2026-06-20T10:01:00Z","phase":"Review","model":"opus","tool":"agent","exit_code":"0","gate_verdict":"senior_security:RED:iter1","tokens":{"estimate":100}}
{"ts":"2026-06-20T10:02:00Z","phase":"Review","model":"opus","tool":"agent","exit_code":"0","gate_verdict":"senior_security:RED:iter1","tokens":{"estimate":100}}
{"ts":"2026-06-20T10:03:00Z","phase":"Review","model":"opus","tool":"agent","exit_code":"0","gate_verdict":"senior_security:RED:iter1","tokens":{"estimate":100}}
JSONL
  : > "$tmp/_relay/ISSUES.md"
  out="$(WALTEUR_ROOT="$tmp" WALTEUR_TRACEMINE=off bash "$SELF" 2>&1)"; rc=$?
  ck "TRACEMINE=off: exit 0" 0 "$rc"
  ck "TRACEMINE=off: loud skip message" 0 "$(printf '%s' "$out" | grep -q 'WALTEUR_TRACEMINE=off' && echo 0 || echo 1)"
  ck "TRACEMINE=off: ISSUES.md untouched" 0 "$([ ! -s "$tmp/_relay/ISSUES.md" ] && echo 0 || echo 1)"
  ck "TRACEMINE=off: report records SKIP" 0 "$(jq -e '.verdict=="SKIP" and (.reason | test("WALTEUR_TRACEMINE=off"))' "$tmp/walteur-kit/trace-mine-report.json" >/dev/null 2>&1 && echo 0 || echo 1)"
  rm -rf "$tmp"

  # ── CASE 4: PAUSED — exit 2 (the only non-selftest exit-2 path) ──
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/trace-mine-paused.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF" >/dev/null 2>&1; rc=$?
  ck "PAUSED: exit 2" 2 "$rc"
  ck "PAUSED: report records BLOCKED" 0 "$(jq -e '.verdict=="BLOCKED" and (.reason | test("PAUSED"))' "$tmp/walteur-kit/trace-mine-report.json" >/dev/null 2>&1 && echo 0 || echo 1)"
  rm -rf "$tmp"

  # ── CASE 5: no artifacts at all — loud skip, exit 0, nothing written ──
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/trace-mine-none.XXXXXX")"
  mkdir -p "$tmp/walteur-kit" "$tmp/_relay"
  : > "$tmp/_relay/ISSUES.md"
  out="$(WALTEUR_ROOT="$tmp" bash "$SELF" 2>&1)"; rc=$?
  ck "no-artifacts: exit 0" 0 "$rc"
  ck "no-artifacts: loud skip message" 0 "$(printf '%s' "$out" | grep -q 'no artifacts to mine' && echo 0 || echo 1)"
  ck "no-artifacts: ISSUES.md untouched" 0 "$([ ! -s "$tmp/_relay/ISSUES.md" ] && echo 0 || echo 1)"
  ck "no-artifacts: report records SKIP with empty artifact flags" 0 "$(jq -e '.verdict=="SKIP" and .artifacts.run_trace == false and .artifacts.summary == false' "$tmp/walteur-kit/trace-mine-report.json" >/dev/null 2>&1 && echo 0 || echo 1)"
  rm -rf "$tmp"

  # ── CASE 6: systemic STALL via SUMMARY.jsonl BLOCKED (>=MIN) — proves SUMMARY miner + multi-source ──
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/trace-mine-stall.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/memory" "$tmp/_relay"
  cat > "$tmp/walteur-kit/SUMMARY.jsonl" <<'JSONL'
{"task-id":1,"wave":1,"planned":"a.ts","actual":"","ac_verdict":"BLOCKED","deviation":"implementer reported BLOCKED"}
{"task-id":2,"wave":1,"planned":"b.ts","actual":"","ac_verdict":"BLOCKED","deviation":"implementer reported BLOCKED"}
{"task-id":3,"wave":2,"planned":"c.ts","actual":"","ac_verdict":"BLOCKED","deviation":"implementer reported BLOCKED"}
{"task-id":4,"wave":2,"planned":"d.ts","actual":"d.ts","ac_verdict":"DONE","deviation":""}
JSONL
  : > "$tmp/_relay/ISSUES.md"
  out="$(WALTEUR_ROOT="$tmp" WALTEUR_MEM="$tmp/.lessons.jsonl" WALTEUR_TRACEMINE_MIN=3 bash "$SELF" 2>/dev/null)"; rc=$?
  ck "stall case: exit 0" 0 "$rc"
  ck "stall case: flags recurring stall/re-route" 0 "$(grep -q 'RECURRING STALL' "$tmp/_relay/ISSUES.md" && echo 0 || echo 1)"
  ck "stall case: emits a stall candidate lesson" 0 "$(printf '%s' "$out" | grep -q 'stall' && echo 0 || echo 1)"
  ck "stall case: report records SUMMARY artifact and systemic pattern" 0 "$(jq -e '.verdict=="PASS" and .systemic_count >= 1 and .artifacts.summary == true' "$tmp/walteur-kit/trace-mine-report.json" >/dev/null 2>&1 && echo 0 || echo 1)"
  rm -rf "$tmp"

  # ── CASE 7: redundant tool signature (>=MIN) + one-off signature — proves semantic trace mining when spans carry signatures ──
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/trace-mine-redundant.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/memory" "$tmp/_relay"
  cat > "$tmp/walteur-kit/run-trace.jsonl" <<'JSONL'
{"ts":"2026-06-20T10:00:00Z","phase":"Build","model":"sonnet","tool":"Bash","exit_code":"0","gate_verdict":"","tool_signature":"bash -lc npm test -- --watch=false","tokens":{"estimate":120}}
{"ts":"2026-06-20T10:01:00Z","phase":"Build","model":"sonnet","tool":"Bash","exit_code":"0","gate_verdict":"","tool_signature":"bash -lc npm test -- --watch=false","tokens":{"estimate":120}}
{"ts":"2026-06-20T10:02:00Z","phase":"Build","model":"sonnet","tool":"Bash","exit_code":"0","gate_verdict":"","tool_signature":"bash -lc npm test -- --watch=false","tokens":{"estimate":120}}
{"ts":"2026-06-20T10:03:00Z","phase":"Build","model":"sonnet","tool":"Bash","exit_code":"0","gate_verdict":"","tool_signature":"bash -lc npm run lint","tokens":{"estimate":40}}
JSONL
  : > "$tmp/_relay/ISSUES.md"
  out="$(WALTEUR_ROOT="$tmp" WALTEUR_MEM="$tmp/.lessons.jsonl" WALTEUR_TRACEMINE_MIN=3 bash "$SELF" 2>/dev/null)"; rc=$?
  ck "redundant signature case: exit 0" 0 "$rc"
  ck "redundant signature case: flags repeated tool signature" 0 "$(grep -q 'REDUNDANT TOOL CALL' "$tmp/_relay/ISSUES.md" && echo 0 || echo 1)"
  ck "redundant signature case: ignores one-off signature" 0 "$(grep -q 'npm run lint' "$tmp/_relay/ISSUES.md" && echo 1 || echo 0)"
  ck "redundant signature case: emits a candidate lesson" 0 "$(printf '%s' "$out" | grep -q 'repeats the same normalized signature' && echo 0 || echo 1)"
  ck "redundant signature case: report records run-trace artifact and systemic pattern" 0 "$(jq -e '.verdict=="PASS" and .systemic_count >= 1 and .artifacts.run_trace == true' "$tmp/walteur-kit/trace-mine-report.json" >/dev/null 2>&1 && echo 0 || echo 1)"
  rm -rf "$tmp"

  # ── CASE 8: equivalent command forms normalize through run-trace, then trace-mine groups the shared signature ──
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/trace-mine-normalized.XXXXXX")"
  mkdir -p "$tmp/walteur-kit/memory" "$tmp/_relay"
  WALTEUR_ROOT="$tmp" bash "$RUN_TRACE" emit --phase Build --model sonnet --tool Bash --exit_code 0 --gate_verdict "" --tokens 30 --command "bash -lc 'npm test -- --watch=false'"
  WALTEUR_ROOT="$tmp" bash "$RUN_TRACE" emit --phase Build --model sonnet --tool Bash --exit_code 0 --gate_verdict "" --tokens 30 --command "npm run test -- --watch=false"
  WALTEUR_ROOT="$tmp" bash "$RUN_TRACE" emit --phase Build --model sonnet --tool Bash --exit_code 0 --gate_verdict "" --tokens 30 --command "zsh -c \"npm test -- --watch=false\""
  WALTEUR_ROOT="$tmp" bash "$RUN_TRACE" emit --phase Build --model sonnet --tool Bash --exit_code 0 --gate_verdict "" --tokens 30 --command "npm run lint"
  : > "$tmp/_relay/ISSUES.md"
  ck "normalized command case: run-trace emitted 3 shared npm test signatures" 3 "$(jq -r 'select(.tool_signature=="cmd:npm:test -- --watch=false") | "ok"' "$tmp/walteur-kit/run-trace.jsonl" | wc -l | tr -d ' ')"
  out="$(WALTEUR_ROOT="$tmp" WALTEUR_MEM="$tmp/.lessons.jsonl" WALTEUR_TRACEMINE_MIN=3 bash "$SELF" 2>/dev/null)"; rc=$?
  ck "normalized command case: exit 0" 0 "$rc"
  ck "normalized command case: flags equivalent command repeats" 0 "$(grep -q 'REDUNDANT TOOL CALL' "$tmp/_relay/ISSUES.md" && echo 0 || echo 1)"
  ck "normalized command case: proposal names normalized npm test signature" 0 "$(grep -q 'cmd:npm:test -- --watch=false' "$tmp/_relay/ISSUES.md" && echo 0 || echo 1)"
  ck "normalized command case: unknown npm lint command remains ungrouped" 0 "$(grep -q 'npm run lint' "$tmp/_relay/ISSUES.md" && echo 1 || echo 0)"
  ck "normalized command case: report records systemic run-trace finding" 0 "$(jq -e '.verdict=="PASS" and .systemic_count >= 1 and .artifacts.run_trace == true' "$tmp/walteur-kit/trace-mine-report.json" >/dev/null 2>&1 && echo 0 || echo 1)"
  rm -rf "$tmp"

  echo "trace-mine selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

# ── dispatch ────────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --selftest) selftest; exit $? ;;
  ""|--mine)  run_mine; exit 0 ;;
  *)
    echo "trace-mine usage:" >&2
    echo "  trace-mine.sh            # mine the artifacts; emit <=3 candidate lessons + ONE ISSUES proposal if systemic" >&2
    echo "  trace-mine.sh --mine     # same as no-arg" >&2
    echo "  trace-mine.sh --selftest # hermetic self-test" >&2
    echo "  env: WALTEUR_TRACEMINE=off (skip) · WALTEUR_TRACEMINE_MIN=<n> (recurrence threshold, default 3)" >&2
    exit 1
    ;;
esac
