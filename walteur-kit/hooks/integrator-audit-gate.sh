#!/usr/bin/env bash
# WALTEUR integrator-audit-gate - cross-model Integrator SHIP verdict (rocket-fuel port, HARD at ship).
#
# A different model must fail to break the build before it ships. This gate requires a FRESH
# adversarial verdict receipt from the OpenAI Codex CLI ("the Integrator", per the rocket-fuel
# co-founder OS), produced via the hardened driver rf-codex.sh in a READ-ONLY sandbox against the
# build diff. The receipt's last line must be exactly `VERDICT: SHIP`, parsed deterministically by
# `rf-codex.sh verdict` — never by this gate's own regex. Claude's own reviews never satisfy this
# gate: the whole point is a second model with no stake in the build.
#
# Contract:
#   - Not required (no ship/reflect phase, no WALTEUR_INTEGRATOR_REQUIRED=1) => NOT_APPLICABLE, exit 0.
#   - Required + missing/REVISE/wrong-phase/malformed/crash-marker receipt   => FAIL, exit 2.
#   - Required + receipt older than the newest source file (scope moved)     => FAIL, exit 2.
#   - Required + archived brief missing the adversarial anchors (softball)   => FAIL, exit 2.
#   - Codex down (usage-limit/model/auth): PASS only as DEGRADED_ACCEPTED —
#     walteur-kit/integrator/DEGRADED.json {rc:2|3|4, reason, ts} AND an approved
#     accepted_risk signoff covering "integrator-audit-gate" in autopilot/STATE.json.
#     Either half missing => FAIL, exit 2. Loud, recorded, never silent.
#   - Fresh SHIP receipt + honest brief                                      => PASS, exit 0.
#
# Driver: WALTEUR_RF_CODEX (default ~/.claude/skills/rocket-fuel/scripts/rf-codex.sh) — reused
# verbatim, never reimplemented here. Statedir: walteur-kit/integrator/, labels ship-audit[-rN]
# (highest round wins). Report: walteur-kit/integrator-audit-report.json
# Bypass: WALTEUR_INTEGRATOR=off (recorded, not free). PAUSED => exit 2.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "integrator-audit-gate - cross-model Integrator SHIP verdict (rocket-fuel port, HARD at ship)."
  printf '%s\n' "usage: bash integrator-audit-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/integrator-audit-report.json - fix recipes: walteur-kit/REMEDIATION.md (## integrator-audit-gate)"
  printf '%s\n' "driver: \$WALTEUR_RF_CODEX (default ~/.claude/skills/rocket-fuel/scripts/rf-codex.sh)"
  printf '%s\n' "bypass: WALTEUR_INTEGRATOR=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

input_dir="${1:-}"
if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "$WALTEUR_ROOT" ]; then
  ROOT="$(cd "$WALTEUR_ROOT" && pwd)"
elif [ -n "$input_dir" ] && [ -d "$input_dir" ]; then
  ROOT="$(cd "$input_dir" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
KIT="$ROOT/walteur-kit"
SD="$KIT/integrator"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/integrator-audit-report.json"
RFC="${WALTEUR_RF_CODEX:-$HOME/.claude/skills/rocket-fuel/scripts/rf-codex.sh}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

have() { command -v "$1" >/dev/null 2>&1; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0\n'; }

findings='[]'; failures=0
add_finding() {
  findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"
  failures=$((failures+1))
}

write_report() { # verdict mode reason [receipt] [verdict_line]
  v="$1"; mode="$2"; reason="$3"; receipt="${4:-}"; vline="${5:-}"
  mkdir -p "$KIT" 2>/dev/null
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --arg mode "$mode" --arg reason "$reason" \
      --arg receipt "$receipt" --arg vline "$vline" --argjson findings "$findings" \
      '{verdict:$v, ts:$ts, gate:"integrator-audit", mode:$mode, receipt:$receipt, verdict_line:$vline, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"integrator-audit","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$v")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

detect_required() {
  REQUIRED=0; REQUIRED_REASON=""
  if [ "${WALTEUR_INTEGRATOR_REQUIRED:-}" = "1" ]; then
    REQUIRED=1; REQUIRED_REASON="WALTEUR_INTEGRATOR_REQUIRED=1"; return 0
  fi
  if [ -s "$STATE" ] && have jq && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      ship|reflect) REQUIRED=1; REQUIRED_REASON="STATE.phase=$phase"; return 0 ;;
    esac
  fi
}

latest_source_mtime() {
  # B4 fix: prune ONLY the receipts this gate writes (integrator/ + *-report.json), NOT the whole kit —
  # so edits to hooks / gate-registry.json / release-ledger.json AFTER the verdict correctly stale it.
  latest=0
  if [ -d "$ROOT" ]; then
    while IFS= read -r -d '' f; do
      case "$f" in *-report.json) continue ;; esac
      mt="$(mtime "$f")"
      [ "${mt:-0}" -gt "$latest" ] && latest="$mt"
    done < <(find "$ROOT" \
      \( -path '*/.git/*' -o -path '*/node_modules/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path "$SD/*" \) -prune -o \
      -type f -print0 2>/dev/null)
  fi
  printf '%s\n' "$latest"
}

check_provenance() { # $1=label — SHAPE-LEVEL provenance (PROTOCOL, not cryptographic).
  # A shell gate cannot cryptographically prove a subprocess ran; what it CAN do is require the full rf-codex
  # output SHAPE — the --json event stream (thread.started + turn/item events + a uuid thread_id) AND a
  # sibling thread_id file that matches — so a lone hand-written last.txt, a thin forgery, or a stale/forged
  # high round cannot pass. A determined forger with repo-write access who reproduces the exact stream shape
  # is out of scope for a shell gate; this defeats casual/accidental forgery and binds to the driver's output.
  local label="$1"; local ev="$SD/$label.events.jsonl" tid_in_events tid_file
  if [ ! -s "$ev" ]; then
    add_finding provenance.noevents "receipt $label has no sibling events.jsonl — rf-codex writes the --json stream beside the verdict; a lone last.txt is not a proven cross-model run"
    return 1
  fi
  if [ "$(wc -c < "$ev" 2>/dev/null || echo 0)" -lt 200 ]; then
    add_finding provenance.thinevents "events.jsonl for $label is implausibly small (<200B) — not a real Codex turn stream"
    return 1
  fi
  # B2 (r2) strengthen: require rf-codex event SHAPE — a thread-start signature AND >=2 turn/item events —
  # not merely size + a uuid substring.
  grep -qa '"thread_id"' "$ev" 2>/dev/null || { add_finding provenance.noshape "events.jsonl for $label has no thread_id event — not an rf-codex --json stream"; return 1; }
  local nshape
  nshape="$(grep -acE '"type"[[:space:]]*:|"(item|turn|agent_message|assistant|response)' "$ev" 2>/dev/null)"
  case "$nshape" in ''|*[!0-9]*) nshape=0 ;; esac
  if [ "$nshape" -lt 2 ]; then
    add_finding provenance.noshape "events.jsonl for $label lacks the rf-codex turn/item event shape (<2 typed events, got $nshape) — a real read-only session emits many"
    return 1
  fi
  tid_in_events="$(grep -ao '"thread_id":"[0-9a-f][0-9a-f-]\{35\}"' "$ev" 2>/dev/null | head -1 | cut -d'"' -f4)"
  if ! printf '%s' "$tid_in_events" | grep -qE '^[0-9a-f-]{36}$'; then
    add_finding provenance.notid "events.jsonl for $label carries no uuid thread_id — cannot bind the verdict to a real rf-codex session"
    return 1
  fi
  # B1 (r2) fix: the thread_id file is MANDATORY and must match — no more "compare only when present" bypass.
  # rf-codex start/resume always writes $SD/thread_id; its absence means the receipt was not driver-produced.
  if [ ! -s "$SD/thread_id" ]; then
    add_finding provenance.nothreadfile "no $SD/thread_id — rf-codex writes it on every start/resume; its absence means the receipt is not a driver product"
    return 1
  fi
  tid_file="$(cat "$SD/thread_id" 2>/dev/null | tr -d '[:space:]')"
  if [ "$tid_file" != "$tid_in_events" ]; then
    add_finding provenance.tidmismatch "receipt $label thread_id ($tid_in_events) != last session thread_id ($tid_file) — a stale/forged round cannot override the live session"
    return 1
  fi
  return 0
}

pick_receipt() { # newest = highest ROUND NUMBER (ship-audit-rN), never mtime — same law as rf-codex protocol_gate
  LABEL=""; best=-1
  for f in "$SD"/ship-audit*.last.txt; do
    [ -e "$f" ] || continue
    base="${f##*/}"; base="${base%.last.txt}"
    n="$(printf '%s' "$base" | sed -n 's/^ship-audit-r\([0-9][0-9]*\)$/\1/p')"
    [ -n "$n" ] || { [ "$base" = "ship-audit" ] && n=0 || continue; }
    if [ "$n" -gt "$best" ]; then best="$n"; LABEL="$base"; fi
  done
}

check_brief_anchors() { # $1=brief file — gate-side clone of rf-codex attack_gate, SHIP-phase anchors
  bf="$1"; miss=""
  [ -f "$bf" ] || { add_finding brief.missing "archived brief $bf not found — every integrator attack archives its brief for audit"; return 1; }
  grep -qi "adversarial" "$bf" || miss="$miss adversarial-framing"
  { grep -qi "default" "$bf" && grep -q "REVISE" "$bf"; } || miss="$miss default-verdict-is-REVISE"
  grep -qF "VERDICT: SHIP" "$bf" || miss="$miss exact-SHIP/REVISE-ending-instruction"
  if [ -n "$miss" ]; then
    add_finding brief.softball "brief missing anchors:$miss — a softball brief voids the round (rocket-fuel Rule 2: no end runs)"
    return 1
  fi
  return 0
}

check_degraded() { # PASS path when codex is down: DEGRADED.json + a REAL failed-run log + approved signoff
  dg="$SD/DEGRADED.json"
  [ -s "$dg" ] || return 1
  jq -e '(.rc == 2 or .rc == 3 or .rc == 4) and ((.reason // "") | length > 0) and ((.ts // "") | length > 0) and ((.driver_log // "") | length > 0)' "$dg" >/dev/null 2>&1 || {
    add_finding degraded.shape "DEGRADED.json present but invalid (needs rc 2|3|4, reason, ts, driver_log pointing at the failed rf-codex log)"; return 1; }
  # B5/B4 (r2): the outage must be EVIDENCED by a real rf-codex failure log UNDER THE STATEDIR whose content
  # matches the rc. SHAPE-LEVEL provenance (PROTOCOL): a shell gate cannot prove a subprocess exited N, but it
  # can require the driver's own output file (rf-codex names failed runs <label>.err.log / .events.jsonl in the
  # statedir) carrying the classify_failure signature — not an arbitrary external file.
  local rc dl dlp sig
  rc="$(jq -r '.rc' "$dg")"; dl="$(jq -r '.driver_log' "$dg")"
  # B3 (r2) fix: reject absolute paths and any parent-escape — driver_log must be a plain name under the statedir.
  case "$dl" in
    /*|*/../*|*/..|../*|..) add_finding degraded.escape "driver_log ($dl) must be a relative rf-codex output filename UNDER the statedir — no absolute or ../-escaping paths"; return 1 ;;
    *.err.log|*.events.jsonl) ;;
    *) add_finding degraded.shape "driver_log ($dl) is not an rf-codex output file (expected <label>.err.log or <label>.events.jsonl)"; return 1 ;;
  esac
  dlp="$SD/$dl"
  if [ ! -s "$dlp" ]; then
    add_finding degraded.nolog "DEGRADED.driver_log ($dl) not found under the statedir — the outage is asserted, not evidenced"; return 1
  fi
  case "$rc" in
    2) sig="usage limit" ;;
    3) sig="requires a newer version" ;;
    4) sig="not logged in\|401" ;;
  esac
  if ! grep -qaiE "$sig" "$dlp" 2>/dev/null; then
    add_finding degraded.mismatch "driver_log does not contain the rc=$rc outage signature ('$sig') — the DEGRADED claim is not backed by the actual failure (rf-codex classify_failure model)"; return 1
  fi
  [ -s "$STATE" ] || { add_finding degraded.signoff "DEGRADED.json present but no STATE.json to carry the accepted_risk signoff"; return 1; }
  # signoff must be present, approved, cover this gate, AND be fresh vs the sources (a stale signoff
  # from a prior scope cannot bless a new degraded ship).
  local smt="$(latest_source_mtime)" gmt="$(mtime "$dg")"
  if [ "${smt:-0}" -gt "${gmt:-0}" ]; then
    add_finding degraded.stale "sources changed after the DEGRADED marker (source $smt > marker $gmt) — re-attempt the Integrator or re-sign for the new scope"; return 1
  fi
  jq -e '(.signoffs // []) | any(
      .kind == "accepted_risk" and .status == "approved"
      and ((.owner // "") | length > 0) and ((.reason // "") | length > 0) and ((.timestamp // "") | length > 0)
      and ((((.covers // []) | index("integrator-audit-gate")) != null) or (((.covers // []) | index("all")) != null)))' "$STATE" >/dev/null 2>&1 || {
    add_finding degraded.signoff "codex outage claimed but no approved accepted_risk signoff covering integrator-audit-gate in STATE.json (risk-acceptance-gate model)"; return 1; }
  return 0
}

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused "kill switch"; echo "integrator-audit-gate: PAUSED -> exit 2"; exit 2; }
  [ "${WALTEUR_INTEGRATOR:-}" = "off" ] && { write_report SKIP bypassed "WALTEUR_INTEGRATOR=off"; echo "integrator-audit-gate: bypassed (recorded)"; exit 0; }
  if ! have jq; then write_report FAIL degraded "missing dependency: jq (a ship gate cannot run degraded)"; echo "integrator-audit-gate: FAIL - missing dependency: jq (fail-closed)" >&2; exit 2; fi

  detect_required
  if [ "$REQUIRED" -ne 1 ]; then
    write_report NOT_APPLICABLE pre-ship "integrator verdict due at ship/reflect (or WALTEUR_INTEGRATOR_REQUIRED=1)"
    echo "integrator-audit-gate: NOT_APPLICABLE (not required yet)"; exit 0
  fi

  if [ ! -r "$RFC" ]; then
    add_finding driver.missing "rf-codex.sh driver not readable at $RFC (set WALTEUR_RF_CODEX; rocket-fuel skill provides it)"
    write_report FAIL required "driver missing"; echo "integrator-audit-gate: FAIL (driver missing: $RFC) -> exit 2" >&2; exit 2
  fi

  pick_receipt
  if [ -z "$LABEL" ]; then
    if check_degraded; then
      write_report DEGRADED_ACCEPTED required "codex unavailable ($(jq -r '.reason' "$SD/DEGRADED.json" 2>/dev/null)); ships on an approved accepted_risk signoff — loud, recorded"
      echo "integrator-audit-gate: DEGRADED_ACCEPTED (codex down + signed risk acceptance) -> PASS"; exit 0
    fi
    add_finding receipt.missing "no ship-audit*.last.txt receipt in $SD — run the §5.5b cross-model attack via rf-codex.sh (read-only) before ship"
    write_report FAIL required "no integrator receipt"; echo "integrator-audit-gate: FAIL (no receipt in $SD) -> exit 2" >&2; exit 2
  fi

  receipt="$SD/$LABEL.last.txt"
  vout="$(bash "$RFC" verdict "$SD" "$LABEL" SHIP 2>&1)"; vrc=$?
  if [ "$vrc" -ne 0 ]; then
    add_finding verdict.rc"$vrc" "rf-codex verdict refused ($LABEL): $vout"
    write_report FAIL required "verdict not SHIP (driver rc=$vrc)" "$receipt" "$vout"
    echo "integrator-audit-gate: FAIL ($vout) -> exit 2" >&2; exit 2
  fi

  check_provenance "$LABEL" || {
    write_report FAIL required "receipt failed provenance (not a real rf-codex product)" "$receipt" "$vout"
    echo "integrator-audit-gate: FAIL (provenance — forged/hand-written receipt) -> exit 2" >&2; exit 2; }

  check_brief_anchors "$SD/$LABEL.brief.txt" || {
    write_report FAIL required "brief failed adversarial-anchor check" "$receipt" "$vout"
    echo "integrator-audit-gate: FAIL (brief anchors) -> exit 2" >&2; exit 2; }

  src_mt="$(latest_source_mtime)"; rcp_mt="$(mtime "$receipt")"
  if [ "${src_mt:-0}" -gt "${rcp_mt:-0}" ]; then
    add_finding receipt.stale "sources changed after the verdict (source mtime $src_mt > receipt mtime $rcp_mt) — scope moved, re-attack (rocket-fuel: approval of gate N-1 never satisfies gate N)"
    write_report FAIL required "stale receipt" "$receipt" "$vout"
    echo "integrator-audit-gate: FAIL (stale receipt — re-run the attack) -> exit 2" >&2; exit 2
  fi

  write_report PASS required "fresh cross-model SHIP verdict ($LABEL)" "$receipt" "$vout"
  echo "integrator-audit-gate: PASS ($LABEL: $vout)"; exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "integrator-audit-gate selftest FAIL - no jq (fail-closed)."; return 1; fi
  echo "integrator-audit-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }

  # hermetic fake driver: replicates rf-codex.sh verdict exit semantics without codex
  FAKE="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")/rf-fake.sh"
  cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "verdict" ] || exit 5
sd="$2"; label="$3"; expect="$4"
[ -f "$sd/$label.running" ] && { echo "VERDICT: UNTRUSTED (crash marker)"; exit 12; }
f="$sd/$label.last.txt"; [ -s "$f" ] || { echo "VERDICT: MISSING"; exit 1; }
last=$(tail -1 "$f")
case "$last" in
  "VERDICT: APPROVED"|"VERDICT: SHIP") ;;
  "VERDICT: REVISE") echo "$last"; exit 10 ;;
  *) echo "VERDICT: MALFORMED (last line: $last)"; exit 1 ;;
esac
[ "$last" != "VERDICT: $expect" ] && { echo "VERDICT: WRONG-PHASE (got '$last')"; exit 11; }
echo "$last"; exit 0
EOF
  chmod +x "$FAKE"

  SELF_PATH="$0"
  run() { WALTEUR_ROOT="$1" WALTEUR_RF_CODEX="${2:-$FAKE}" bash "$SELF_PATH" >/dev/null 2>&1; echo $?; }
  mkfix() { # $1=dir $2=phase — kit + STATE + one backdated source file
    local d="$1" phase="$2"
    mkdir -p "$d/src" "$d/walteur-kit/autopilot" "$d/walteur-kit/integrator"
    printf 'x\n' > "$d/src/app.txt"; touch -t 202001010000 "$d/src/app.txt"
    printf '{"phase":"%s"}\n' "$phase" > "$d/walteur-kit/autopilot/STATE.json"
  }
  UUID="019f4cb1-d9bd-7801-9b73-fe7c488eab3d"
  good_receipt() { # $1=dir $2=label — fresh SHIP receipt + honest brief + a plausible rf-codex events stream
    local g="$1/walteur-kit/integrator"
    printf 'findings: none\nVERDICT: SHIP\n' > "$g/$2.last.txt"
    # capital "Default" on purpose — the anchor check must be case-insensitive (a real brief phrases it either way)
    printf 'You are the Integrator, adversarial reviewer of this build diff. Default verdict is REVISE; SHIP must be earned by evidence.\nEnd with EXACTLY one line, nothing after it: VERDICT: SHIP or VERDICT: REVISE\n' > "$g/$2.brief.txt"
    # a real rf-codex --json stream: >200B, carries a uuid thread_id; sibling thread_id file matches.
    { printf '{"type":"thread.started","thread_id":"%s"}\n' "$UUID"
      for i in 1 2 3 4 5 6 7 8; do printf '{"type":"item.completed","item":{"turn":%s,"text":"adversarial review step %s over the build diff — checking gate evasion and honesty"}}\n' "$i" "$i"; done
    } > "$g/$2.events.jsonl"
    printf '%s\n' "$UUID" > "$1/walteur-kit/integrator/thread_id"
  }

  # 1. not required (phase=build) -> NA 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" build; ck "pre-ship phase -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. no kit/STATE at all -> NA 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkdir -p "$t/src"; ck "no kit -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 3. ship + missing receipt -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; ck "ship + no receipt -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. ship + fresh SHIP receipt + honest brief -> 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r1; ck "fresh SHIP receipt -> PASS" 0 "$(run "$t")"
  # 4b. parity: the REAL rf-codex.sh parses the same receipt identically (pure-local, no codex needed)
  REAL="$HOME/.claude/skills/rocket-fuel/scripts/rf-codex.sh"
  if [ -r "$REAL" ]; then
    rrc=0; bash "$REAL" verdict "$t/walteur-kit/integrator" ship-audit-r1 SHIP >/dev/null 2>&1 || rrc=$?
    ck "real rf-codex.sh verdict parity" 0 "$rrc"
  else
    echo "  ok   - real rf-codex.sh absent; parity case skipped (fake driver covers semantics)"; pass=$((pass+1))
  fi
  rm -rf "$t"
  # 5. REVISE receipt -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r1
  printf 'blocker: x\nVERDICT: REVISE\n' > "$t/walteur-kit/integrator/ship-audit-r1.last.txt"
  ck "REVISE receipt -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. wrong-phase APPROVED -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r1
  printf 'VERDICT: APPROVED\n' > "$t/walteur-kit/integrator/ship-audit-r1.last.txt"
  ck "wrong-phase APPROVED -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. stale receipt (source newer) -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r1
  touch -t 202001010000 "$t/walteur-kit/integrator/ship-audit-r1.last.txt"; touch "$t/src/app.txt"
  ck "stale receipt -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. crash marker -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r1
  touch "$t/walteur-kit/integrator/ship-audit-r1.running"
  ck "crash marker -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. softball brief -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r1
  printf 'Please review this nice build.\n' > "$t/walteur-kit/integrator/ship-audit-r1.brief.txt"
  ck "softball brief -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10. highest round wins: r1=REVISE, r2=SHIP -> 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r1; good_receipt "$t" ship-audit-r2
  printf 'blocker: x\nVERDICT: REVISE\n' > "$t/walteur-kit/integrator/ship-audit-r1.last.txt"
  ck "highest round wins (r2 SHIP over r1 REVISE)" 0 "$(run "$t")"; rm -rf "$t"
  dg_signoff() { printf '{"phase":"ship","signoffs":[{"id":"so-1","kind":"accepted_risk","status":"approved","owner":"Tony","reason":"codex usage limit; ship accepted on Opus audit alone","timestamp":"2026-07-10T00:00:00Z","covers":["integrator-audit-gate"]}]}\n' > "$1/walteur-kit/autopilot/STATE.json"; }
  # 11. DEGRADED + real driver_log (usage-limit sig) + approved signoff -> 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship
  printf 'rf-codex: USAGE LIMIT — try again at 18:00. Prescription: wait.\n' > "$t/walteur-kit/integrator/ship-audit-r1.err.log"
  printf '{"rc":2,"reason":"usage limit until 18:00","ts":"2026-07-10T00:00:00Z","driver_log":"ship-audit-r1.err.log"}\n' > "$t/walteur-kit/integrator/DEGRADED.json"
  dg_signoff "$t"
  ck "DEGRADED + real log + signoff -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 11b. DEGRADED with driver_log MISSING -> 2 (outage asserted, not evidenced)
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship
  printf '{"rc":2,"reason":"usage limit","ts":"2026-07-10T00:00:00Z","driver_log":"ship-audit-r1.err.log"}\n' > "$t/walteur-kit/integrator/DEGRADED.json"; dg_signoff "$t"
  ck "DEGRADED no driver log -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 11c. DEGRADED driver_log present but WRONG signature (rc=4 auth, log says usage limit) -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship
  printf 'rf-codex: USAGE LIMIT — try again later\n' > "$t/walteur-kit/integrator/ship-audit-r1.err.log"
  printf '{"rc":4,"reason":"auth","ts":"2026-07-10T00:00:00Z","driver_log":"ship-audit-r1.err.log"}\n' > "$t/walteur-kit/integrator/DEGRADED.json"; dg_signoff "$t"
  ck "DEGRADED log/rc signature mismatch -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 12. DEGRADED with real log but NO signoff -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship
  printf 'rf-codex: USAGE LIMIT — try again later\n' > "$t/walteur-kit/integrator/ship-audit-r1.err.log"
  printf '{"rc":2,"reason":"usage limit","ts":"2026-07-10T00:00:00Z","driver_log":"ship-audit-r1.err.log"}\n' > "$t/walteur-kit/integrator/DEGRADED.json"
  ck "DEGRADED without signoff -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 12b. FORGED receipt: SHIP last.txt but NO events.jsonl (hand-written) -> 2 (provenance)
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r1
  rm -f "$t/walteur-kit/integrator/ship-audit-r1.events.jsonl"
  ck "forged receipt (no events) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 12c. thread_id MISMATCH: receipt events uuid != $SD/thread_id (forged high round) -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r99
  printf '0a0a0a0a-b1b1-7c7c-9d9d-e0e0e0e0e0e0\n' > "$t/walteur-kit/integrator/thread_id"
  ck "thread_id mismatch (forged r99) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 12d. B1(r2): thread_id FILE ABSENT (forged: events with a uuid but no driver-written thread_id) -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r1
  rm -f "$t/walteur-kit/integrator/thread_id"
  ck "no thread_id file -> FAIL (B1 r2)" 2 "$(run "$t")"; rm -rf "$t"
  # 12e. B2(r2): events present + uuid but NO typed-event shape (thin forgery padded to >200B) -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r1
  { printf 'thread_id 019f4cb1-d9bd-7801-9b73-fe7c488eab3d '; head -c 300 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$t/walteur-kit/integrator/ship-audit-r1.events.jsonl"
  ck "no rf-codex event shape -> FAIL (B2 r2)" 2 "$(run "$t")"; rm -rf "$t"
  # 12f. B3(r2): DEGRADED driver_log ABSOLUTE path (outside statedir) -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship
  printf 'rf-codex: USAGE LIMIT — later\n' > "$t/outside.err.log"
  printf '{"rc":2,"reason":"usage limit","ts":"2026-07-10T00:00:00Z","driver_log":"%s/outside.err.log"}\n' "$t" > "$t/walteur-kit/integrator/DEGRADED.json"; dg_signoff "$t"
  ck "DEGRADED absolute driver_log -> FAIL (B3 r2)" 2 "$(run "$t")"; rm -rf "$t"
  # 12g. B4(r2): DEGRADED driver_log wrong shape (not .err.log/.events.jsonl) -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship
  printf 'rf-codex: USAGE LIMIT — later\n' > "$t/walteur-kit/integrator/outage.txt"
  printf '{"rc":2,"reason":"usage limit","ts":"2026-07-10T00:00:00Z","driver_log":"outage.txt"}\n' > "$t/walteur-kit/integrator/DEGRADED.json"; dg_signoff "$t"
  ck "DEGRADED wrong-shape driver_log -> FAIL (B4 r2)" 2 "$(run "$t")"; rm -rf "$t"
  # 13. driver missing -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r1
  ck "driver missing -> FAIL" 2 "$(run "$t" "/nonexistent/rf-codex.sh")"; rm -rf "$t"
  # 14. PAUSED -> 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship; good_receipt "$t" ship-audit-r1; touch "$t/walteur-kit/PAUSED"
  ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # 15. bypass -> 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/iag.XXXXXX")"; mkfix "$t" ship
  rc=0; WALTEUR_ROOT="$t" WALTEUR_RF_CODEX="$FAKE" WALTEUR_INTEGRATOR=off bash "$SELF_PATH" >/dev/null 2>&1 || rc=$?
  ck "bypass -> exit 0" 0 "$rc"; rm -rf "$t"
  rm -rf "$(dirname "$FAKE")"

  echo "integrator-audit-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
