#!/usr/bin/env bash
# WALTEUR team-coordination-gate — proves a TEAM MODE run was REAL, fail-closed.
# TEAM MODE = 5-7 named Claude Code terminals coordinating over the peerbus
# (walteur-kit/team/peerbus-mcp.mjs). The bus leaves JSONL receipts; this gate verifies
# they cohere, because "seven terminals worked as a team" is exactly the kind of claim
# that must not pass on vibes:
#   T1 every registry peer + board actor + correspondent is in team-manifest.json (no phantoms)
#   T2 heartbeats are plausible (>=2 peers, ALL byte-identical timestamps = hand-forged registry)
#   T3 every done task was claimed first, claim ts <= done ts (board-log transitions)
#   T4 build-lane tasks were NOT self-done: done actor != owner unless reviewer/qa/lead role
#   T5 message envelopes well-formed (id/ts/from/to/body), correspondents in roster
# CONTRACT: no _team/ dir or empty bus => NOT_APPLICABLE exit 0 (not a team build) ·
# bus present but manifest missing => FAIL exit 2 (unverifiable roster, fail-closed) ·
# violations => FAIL exit 2 · clean => PASS exit 0 · no jq => FAIL exit 2 (fail-closed) ·
# bypass WALTEUR_TEAM_GATE=off (recorded) · report walteur-kit/team-coordination-report.json
set -uo pipefail

usage() {
  cat <<'EOF'
team-coordination-gate — verifies a WALTEUR TEAM MODE run left coherent, non-forged receipts
usage: team-coordination-gate.sh [--selftest|--help] [root]
checks: phantom peers, forged heartbeats, done-without-claim, self-done build tasks, malformed envelopes
report: walteur-kit/team-coordination-report.json · bypass: WALTEUR_TEAM_GATE=off (recorded)
not-applicable: no _team/ bus dir at the root (exit 0, recorded)
EOF
}

run_gate() {
  local ROOT="$1"
  local KIT="$ROOT/walteur-kit"
  local REPORT="$KIT/team-coordination-report.json"
  local TS; TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local TEAM="$ROOT/_team"
  local MANIFEST="$KIT/team/team-manifest.json"

  write_report() { # verdict reason findings_json
    mkdir -p "$KIT" 2>/dev/null
    jq -n --arg v "$1" --arg r "$2" --arg ts "$TS" --argjson f "${3:-[]}" \
      '{verdict:$v, reason:$r, ts:$ts, gate:"team-coordination", findings:$f}' > "$REPORT" 2>/dev/null
  }

  if [ "${WALTEUR_TEAM_GATE:-on}" = "off" ]; then
    write_report "SKIP" "bypassed via WALTEUR_TEAM_GATE=off (recorded, not free)" "[]"
    echo "team-coordination-gate: SKIP (bypassed — recorded)"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || { echo "team-coordination-gate: FAIL — need jq (cannot verify => fail-closed)"; return 2; }

  if [ ! -d "$TEAM" ] || [ ! -s "$TEAM/registry.json" ]; then
    write_report "NOT_APPLICABLE" "no _team bus at $TEAM — not a team build" "[]"
    echo "team-coordination-gate: NOT_APPLICABLE (no team bus)"
    return 0
  fi
  if [ ! -s "$MANIFEST" ]; then
    write_report "FAIL" "team bus exists but team-manifest.json missing — unverifiable roster" "[]"
    echo "team-coordination-gate: FAIL — bus present but no manifest to verify against"
    return 2
  fi

  local FINDINGS="[]"
  add_finding() { FINDINGS="$(jq -c --arg t "$1" --arg d "$2" '. + [{check:$t, detail:$d}]' <<<"$FINDINGS")"; }

  local ROSTER
  ROSTER="$(jq -r '.peers[].name' "$MANIFEST" 2>/dev/null)"
  if [ -z "$ROSTER" ]; then
    write_report "FAIL" "manifest unparseable or empty roster" "[]"
    echo "team-coordination-gate: FAIL — bad manifest"
    return 2
  fi
  in_roster() { grep -qx "$1" <<<"$ROSTER"; }

  # T1 phantom peers in registry
  local peer
  while IFS= read -r peer; do
    [ -z "$peer" ] && continue
    in_roster "$peer" || add_finding "T1-phantom-peer" "registry peer '$peer' not in team-manifest roster"
  done <<<"$(jq -r '.peers | keys[]' "$TEAM/registry.json" 2>/dev/null)"

  # T2 forged heartbeats
  local HB_TOTAL HB_UNIQ
  HB_TOTAL="$(jq -r '[.peers[].last_heartbeat] | length' "$TEAM/registry.json" 2>/dev/null || echo 0)"
  HB_UNIQ="$(jq -r '[.peers[].last_heartbeat] | unique | length' "$TEAM/registry.json" 2>/dev/null || echo 0)"
  if [ "${HB_TOTAL:-0}" -ge 2 ] && [ "${HB_UNIQ:-0}" -le 1 ]; then
    add_finding "T2-forged-heartbeats" "all $HB_TOTAL peer heartbeats byte-identical — real peers heartbeat independently"
  fi

  # T3/T4 board-log coherence
  local BLOG="$TEAM/board-log.jsonl"
  if [ -s "$TEAM/board.json" ] && [ "$(jq -r '.tasks | length' "$TEAM/board.json" 2>/dev/null || echo 0)" -gt 0 ]; then
    if [ ! -s "$BLOG" ]; then
      add_finding "T3-no-log" "board.json has tasks but board-log.jsonl is missing/empty — state without transitions is unverifiable"
    else
      local task actor dts claim_row cts owner role
      while IFS=$'\t' read -r task actor dts; do
        [ -z "$task" ] && continue
        claim_row="$(jq -c --arg t "$task" 'select(.action=="claim" and .task==$t)' "$BLOG" 2>/dev/null | head -1)"
        if [ -z "$claim_row" ]; then
          add_finding "T3-done-without-claim" "task $task marked done (by $actor) with no claim transition in board-log"
        else
          cts="$(jq -r '.ts' <<<"$claim_row")"
          [ "$(printf '%s\n%s\n' "$cts" "$dts" | sort | head -1)" != "$cts" ] && add_finding "T3-time-travel" "task $task done at $dts before its claim at $cts"
        fi
        owner="$(jq -r --arg t "$task" '.tasks[] | select(.id==$t) | .owner // empty' "$TEAM/board.json" 2>/dev/null)"
        if [ -n "$owner" ] && [ "$actor" = "$owner" ]; then
          role="$(jq -r --arg n "$actor" '.peers[] | select(.name==$n) | .role // ""' "$MANIFEST" 2>/dev/null)"
          case "$role" in
            *review*|*qa*|*verifier*|*lead*) : ;;
            *) add_finding "T4-self-done" "task $task: builder '$actor' ($role) marked own work done — review is mandatory (TEAM-PROTOCOL §3)";;
          esac
        fi
        in_roster "$actor" || add_finding "T1-phantom-actor" "board-log actor '$actor' not in roster (task $task)"
      done <<<"$(jq -r 'select(.action=="done") | [.task, .peer, .ts] | @tsv' "$BLOG" 2>/dev/null)"
    fi
  fi

  # T5 message envelope shape + roster membership
  local MLOG="$TEAM/messages-log.jsonl" BAD_ENV who
  if [ -s "$MLOG" ]; then
    BAD_ENV="$(jq -c 'select((.id and .ts and .from and .to and .body) | not)' "$MLOG" 2>/dev/null | head -3)"
    [ -n "$BAD_ENV" ] && add_finding "T5-malformed-envelope" "messages-log has envelope(s) missing id/ts/from/to/body: $(head -c 200 <<<"$BAD_ENV")"
    while IFS= read -r who; do
      [ -z "$who" ] && continue
      in_roster "$who" || add_finding "T5-phantom-correspondent" "message from/to '$who' not in roster"
    done <<<"$(jq -r 'select(.from and .to) | .from, .to' "$MLOG" 2>/dev/null | sort -u)"
  fi

  local N_FIND
  N_FIND="$(jq 'length' <<<"$FINDINGS")"
  if [ "$N_FIND" -gt 0 ]; then
    write_report "FAIL" "$N_FIND coordination violation(s) — see findings" "$FINDINGS"
    echo "team-coordination-gate: FAIL — $N_FIND violation(s):"
    jq -r '.[] | "  [\(.check)] \(.detail)"' <<<"$FINDINGS"
    echo "how to fix: walteur-kit/REMEDIATION.md (## team-coordination-gate)"
    return 2
  fi
  local N_PEERS N_DONE
  N_PEERS="$(jq -r '.peers | length' "$TEAM/registry.json")"
  N_DONE="$(jq -r '[.tasks[]? | select(.status=="done")] | length' "$TEAM/board.json" 2>/dev/null || echo 0)"
  write_report "PASS" "team bus coherent: $N_PEERS peers, $N_DONE done task(s), transitions + envelopes verified" "[]"
  echo "team-coordination-gate: PASS — $N_PEERS peers, $N_DONE done task(s), receipts coherent"
  return 0
}

# ── selftest: hermetic fixtures in a temp root ────────────────────────────────
selftest() {
  command -v jq >/dev/null 2>&1 || { echo "team-coordination-gate selftest SKIP: need jq"; exit 0; }
  local pass=0 fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1"; pass=$((pass+1)); else echo "  FAIL - $1 (got $2 want $3)"; fail=$((fail+1)); fi; }

  local T; T="$(mktemp -d "${TMPDIR:-/tmp}/teamcoordi.XXXXXX")"
  # shellcheck disable=SC2064 — expand NOW so the trap survives the local going out of scope under set -u
  trap "rm -rf '$T'" EXIT

  mk_root() { # $1=name -> echoes root; seeds manifest with ALPHA(builder) BETA(security-reviewer) LEAD(lead-orchestrator)
    local r="$T/$1"
    mkdir -p "$r/walteur-kit/team" "$r/_team/inbox"
    cat > "$r/walteur-kit/team/team-manifest.json" <<'EOF'
{"peers":[{"name":"ALPHA","role":"builder-backend"},{"name":"BETA","role":"security-reviewer"},{"name":"LEAD","role":"lead-orchestrator"}]}
EOF
    echo "$r"
  }
  seed_good() { # $1=root — coherent 2-peer run: post->claim(ALPHA)->done(BETA reviewer)
    cat > "$1/_team/registry.json" <<'EOF'
{"peers":{"ALPHA":{"role":"builder-backend","status":"active","summary":"api","last_heartbeat":"2026-07-02T01:00:05Z"},"BETA":{"role":"security-reviewer","status":"active","summary":"review","last_heartbeat":"2026-07-02T01:02:11Z"}}}
EOF
    cat > "$1/_team/board.json" <<'EOF'
{"tasks":[{"id":"t001","title":"build /health","status":"done","owner":"ALPHA","notes":[]}]}
EOF
    cat > "$1/_team/board-log.jsonl" <<'EOF'
{"ts":"2026-07-02T00:50:00Z","peer":"LEAD","action":"post","task":"t001","title":"build /health"}
{"ts":"2026-07-02T00:55:00Z","peer":"ALPHA","action":"claim","task":"t001"}
{"ts":"2026-07-02T01:10:00Z","peer":"BETA","action":"done","task":"t001","note":"re-ran tests, observed exit 0"}
EOF
    cat > "$1/_team/messages-log.jsonl" <<'EOF'
{"id":"m_1","ts":"2026-07-02T00:56:00Z","from":"ALPHA","to":"BETA","subject":"review","body":"t001 ready"}
EOF
  }

  local r rc

  # 1. NOT_APPLICABLE when no _team
  r="$(mk_root na)"; rm -rf "$r/_team"
  (run_gate "$r" >/dev/null 2>&1); rc=$?
  ck "no _team bus => NOT_APPLICABLE exit 0" "$rc" "0"
  ck "  ...verdict recorded NOT_APPLICABLE" "$(jq -r .verdict "$r/walteur-kit/team-coordination-report.json")" "NOT_APPLICABLE"

  # 2. good coherent run => PASS
  r="$(mk_root good)"; seed_good "$r"
  (run_gate "$r" >/dev/null 2>&1); rc=$?
  ck "coherent team run => PASS exit 0" "$rc" "0"
  ck "  ...verdict PASS" "$(jq -r .verdict "$r/walteur-kit/team-coordination-report.json")" "PASS"

  # 3. NEGATIVE: phantom peer in registry
  r="$(mk_root phantom)"; seed_good "$r"
  jq '.peers.GHOST = {"role":"x","last_heartbeat":"2026-07-02T01:03:00Z"}' "$r/_team/registry.json" > "$r/_team/registry.json.n" && mv "$r/_team/registry.json.n" "$r/_team/registry.json"
  (run_gate "$r" >/dev/null 2>&1); rc=$?
  ck "NEGATIVE phantom registry peer => FAIL exit 2" "$rc" "2"

  # 4. NEGATIVE: hand-forged registry (identical heartbeats)
  r="$(mk_root forged)"; seed_good "$r"
  jq '.peers.ALPHA.last_heartbeat="2026-07-02T01:00:00Z" | .peers.BETA.last_heartbeat="2026-07-02T01:00:00Z"' "$r/_team/registry.json" > "$r/_team/registry.json.n" && mv "$r/_team/registry.json.n" "$r/_team/registry.json"
  (run_gate "$r" >/dev/null 2>&1); rc=$?
  ck "NEGATIVE all-identical heartbeats => FAIL exit 2" "$rc" "2"

  # 5. NEGATIVE: done without claim
  r="$(mk_root noclaim)"; seed_good "$r"
  grep -v '"action":"claim"' "$r/_team/board-log.jsonl" > "$r/_team/board-log.jsonl.n" && mv "$r/_team/board-log.jsonl.n" "$r/_team/board-log.jsonl"
  (run_gate "$r" >/dev/null 2>&1); rc=$?
  ck "NEGATIVE done-without-claim => FAIL exit 2" "$rc" "2"

  # 6. NEGATIVE: builder self-done
  r="$(mk_root selfdone)"; seed_good "$r"
  jq -c 'if .action=="done" then .peer="ALPHA" else . end' "$r/_team/board-log.jsonl" > "$r/_team/board-log.jsonl.n" && mv "$r/_team/board-log.jsonl.n" "$r/_team/board-log.jsonl"
  (run_gate "$r" >/dev/null 2>&1); rc=$?
  ck "NEGATIVE builder marks own task done => FAIL exit 2" "$rc" "2"
  ck "  ...T4 named in findings" "$(jq -r '[.findings[].check] | index("T4-self-done") != null' "$r/walteur-kit/team-coordination-report.json")" "true"

  # 7. reviewer closing own review-lane task is ALLOWED (no false positive)
  r="$(mk_root revok)"; seed_good "$r"
  jq '.tasks[0].owner="BETA"' "$r/_team/board.json" > "$r/_team/board.json.n" && mv "$r/_team/board.json.n" "$r/_team/board.json"
  jq -c 'if .action=="claim" then .peer="BETA" else . end' "$r/_team/board-log.jsonl" > "$r/_team/board-log.jsonl.n" && mv "$r/_team/board-log.jsonl.n" "$r/_team/board-log.jsonl"
  (run_gate "$r" >/dev/null 2>&1); rc=$?
  ck "reviewer self-done on own review task => PASS (no false positive)" "$rc" "0"

  # 8. NEGATIVE: malformed message envelope
  r="$(mk_root badenv)"; seed_good "$r"
  echo '{"ts":"2026-07-02T01:00:00Z","body":"no from/to"}' >> "$r/_team/messages-log.jsonl"
  (run_gate "$r" >/dev/null 2>&1); rc=$?
  ck "NEGATIVE malformed envelope => FAIL exit 2" "$rc" "2"

  # 9. NEGATIVE: bus present, manifest missing => fail-closed
  r="$(mk_root nomanifest)"; seed_good "$r"; rm -f "$r/walteur-kit/team/team-manifest.json"
  (run_gate "$r" >/dev/null 2>&1); rc=$?
  ck "NEGATIVE bus without manifest => FAIL exit 2 (fail-closed)" "$rc" "2"

  # 10. bypass recorded
  r="$(mk_root bypass)"; seed_good "$r"
  jq '.peers.GHOST = {"role":"x","last_heartbeat":"2026-07-02T01:03:00Z"}' "$r/_team/registry.json" > "$r/_team/registry.json.n" && mv "$r/_team/registry.json.n" "$r/_team/registry.json"
  (WALTEUR_TEAM_GATE=off run_gate "$r" >/dev/null 2>&1); rc=$?
  ck "bypass => exit 0 with SKIP verdict recorded" "$rc:$(jq -r .verdict "$r/walteur-kit/team-coordination-report.json")" "0:SKIP"

  echo "team-coordination-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --selftest) selftest; exit $? ;;
  *)
    ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    [ -n "${1:-}" ] && ROOT="$1"
    run_gate "$ROOT"
    exit $?
    ;;
esac
