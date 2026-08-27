#!/usr/bin/env bash
# WALTEUR doctor.sh — 'walteur doctor' health self-check for a walteur-starter / walteur-kit tree.
#
# HONESTY LABELS:
#   HARD   = exit 1 on checkable facts: bash+jq absent, gate-registry.json missing or not valid JSON,
#            or a core gate --selftest that actually runs and reports a FAIL (re-run, observed exit).
#   These are real observations, not authored verdicts. There is no PROTOCOL (authored-verdict) check here.
#
# WHAT IT CHECKS:
#   1. bash + jq present (node reported as advisory; not health-fatal).
#   2. <KIT>/gate-registry.json exists and parses (jq .), counts declared gates.
#   3. Counts hook scripts present under .claude/hooks (and notes how many declared hooks are on disk).
#   4. Runs a core gate --selftest and OBSERVES the count. The task names ship-gate.sh, but ship-gate is a
#      stdin Bash-hook with NO --selftest mode (it would report 0/0 and mislead). doctor therefore runs the
#      registry-auditing gate-suite.sh --selftest (or hollow-artifact-gate.sh as a fallback) and reports its
#      real N/N. This substitution is stated openly — never a silent 0/0.
#   5. TRIAGE (not just health): scans every walteur-kit/*-report.json for verdict=="FAIL" (excluding
#      doctor's own prior report — doctor never self-triages) and, for each, prints the gate id, the
#      report's `reason` field, and the walteur-kit/REMEDIATION.md#<gate-id> anchor the remediation
#      table uses. This makes ANY FAIL report loud even when it was written by a run days ago — doctor
#      is a triage entrypoint, not only a tools/registry smoke test.
#   6. Prints a health summary, plus a "what to do next" epilogue naming the top 3 most-recent FAIL
#      reports (by the report's own `ts`) with their direct re-run command.
#
# CONTRACT: PAUSED present => exit 2. Bypass WALTEUR_DOCTOR=off => loud SKIP exit 0.
#           Healthy AND zero FAIL reports => exit 0. Problems (missing tool/registry, failed core
#           selftest) OR any *-report.json with verdict=="FAIL" => exit 1.
# Report: walteur-kit/doctor-report.json with an execution marker (selftest_executed / observed_exit)
#         plus failing_gates (count) and triage (array of {gate, reason, ts, report, remediation}).
# Selftest: bash doctor.sh --selftest  (GOOD + POISONED twins, offline, synthetic fixtures, incl. a
#           seeded-FAIL-report triage twin and a self-report-exclusion negative control).
# --dry-run (alias --stdout): emit the report to STDOUT and write NOTHING. Read-only CI probe.
# Unknown flag => "unknown option" on stderr + exit 64 (EX_USAGE). A one-hyphen typo of --selftest
# must never silently run the default mode: silence on a typo is how an operator concludes a check
# passed when it never ran. (uxdx, panel #12.)
# --help: self-documentation BEFORE any side effect (S033 usability contract)
DRY_RUN=0
case "${1:-}" in
  -h|--help)
  printf '%s\n' "doctor - doctor.sh - walteur doctor health self-check for a walteur-starter / walteur-kit tree."
  printf '%s\n' "usage: bash doctor.sh [--selftest|--dry-run|--stdout|--help|<default run>]"
  printf '%s\n' "  (no arg)    health check + FAIL-report triage; WRITES walteur-kit/doctor-report.json"
  printf '%s\n' "  --dry-run   same checks, report to STDOUT, writes NOTHING (alias: --stdout)"
  printf '%s\n' "  --selftest  prove doctor's own logic (GOOD + POISONED twins, offline)"
  printf '%s\n' "exit: 0 healthy · 1 problem or a FAIL report exists · 2 walteur-kit/PAUSED · 64 bad usage"
  printf '%s\n' "report: walteur-kit/doctor-report.json - fix recipes: walteur-kit/REMEDIATION.md (## doctor)"
  printf '%s\n' "bypass: WALTEUR_DOCTOR=off (recorded, not free)"
  exit 0 ;;
  --dry-run|--stdout) DRY_RUN=1 ;;
  --selftest|'') : ;;
  *)
  printf '%s\n' "doctor: unknown option: ${1}" >&2
  printf '%s\n' "doctor: valid options are --selftest | --dry-run (alias --stdout) | --help | no argument." >&2
  printf '%s\n' "doctor: run 'bash walteur-kit/hooks/doctor.sh --help' for the full contract." >&2
  exit 64 ;;
esac
if [ "$#" -gt 1 ]; then
  printf '%s\n' "doctor: too many arguments (got $#: $*) — doctor takes at most one option." >&2
  printf '%s\n' "doctor: run 'bash walteur-kit/hooks/doctor.sh --help' for the full contract." >&2
  exit 64
fi

set -uo pipefail

# Resolve $0 with a Windows-drive arm.
case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) SELF="$(pwd)/$0" ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
REGISTRY="$KIT/gate-registry.json"
REPORT="$KIT/doctor-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── cwd guard ────────────────────────────────────────────────────────────────
# Run from the wrong directory, doctor used to CREATE walteur-kit/ in that unrelated tree, report
# "gate-registry.json missing", and leave a doctor-report.json behind as litter. That reads as
# "the harness is broken" when the real fault is the cwd. Say so, and touch nothing. (uxdx, panel #12.)
# --selftest is hermetic (it builds its own fixture trees) so it is exempt: it must run from anywhere.
if [ ! -d "$KIT" ] && [ "${1:-}" != "--selftest" ]; then
  printf '%s\n' "doctor: run from the repo root (walteur-kit/ not found here)." >&2
  printf '%s\n' "doctor: looked in: $ROOT" >&2
  printf '%s\n' "doctor: fix -> cd \"\$(git rev-parse --show-toplevel)\"   # or: WALTEUR_ROOT=/path/to/repo bash walteur-kit/hooks/doctor.sh" >&2
  printf '%s\n' "doctor: nothing was written (no report, no directory created)." >&2
  exit 1
fi
[ "$DRY_RUN" -eq 1 ] || mkdir -p "$KIT" 2>/dev/null || true

# --dry-run stream discipline: keep fd 3 as the ORIGINAL stdout for the JSON report, and send every
# human line to stderr. `doctor.sh --dry-run > report.json` therefore yields clean JSON and nothing
# else, while the operator still sees the whole readout on the terminal.
exec 3>&1
REPORT_LABEL="$REPORT"
if [ "$DRY_RUN" -eq 1 ]; then
  exec 1>&2
  REPORT_LABEL="(stdout — --dry-run: nothing was written)"
fi

# Hooks dir: prefer the project scaffold (.claude/hooks); fall back to the kit's own hooks dir.
if [ -d "$ROOT/.claude/hooks" ]; then
  HOOKS="$ROOT/.claude/hooks"
else
  HOOKS="$KIT/hooks"
fi

have() { command -v "$1" >/dev/null 2>&1; }

# REMEDIATION.md anchor aliases (uxdx, panel #12). The triage pointer resolver below tries <id>,
# <id>-gate, <id>-lint, <id>-check; those suffix rules cannot bridge a report id whose WORDS differ
# from the registry slug. Live case: lifecycle-access-gate.sh writes '"gate":"access-lifecycle"' but the
# heading is '## lifecycle-access-gate' — a hyphen-segment SWAP — so #access-lifecycle 404'd. Explicit,
# auditable, and honored ONLY when the target heading really exists. --selftest asserts exactly that.
# Format: whitespace-separated "<report-id>=<REMEDIATION heading>" pairs.
REMEDIATION_ALIASES='access-lifecycle=lifecycle-access-gate'

# "what to do next" epilogue: top-3 failing gates by recency (triage_json is already
# reverse-sorted by ts, newest first). Compact, on-demand, non-interactive.
print_epilogue() {
  local tjson="$1" tcount="$2" n=3
  echo ""
  echo "What to do next (top $n most recent failing gate(s) of $tcount):"
  printf '%s' "$tjson" | jq -r --argjson n "$n" \
    '.[0:$n] | to_entries[] | "  \(.key+1)) bash walteur-kit/hooks/\(.value.gate).sh   # re-run · reason: \(.value.reason) · fix -> \(.value.remediation)"' \
    2>/dev/null
}

write_report() {
  local verdict="$1" reason="$2" extra
  # NOTE: do NOT write `local extra="${3:-{}}"` — with a multi-line $3 bash mis-parses the
  # `{}` default and appends a stray `}`, corrupting the JSON. Assign the arg, then default.
  extra="${3-}"
  [ -n "$extra" ] || extra='{}'
  # Build the payload first, THEN place it. --dry-run sends it to the saved original stdout (fd 3) and
  # touches no file; the default run writes the file exactly as before. NOTE: this must be `>&3` (a dup),
  # not `> /dev/fd/3` — reopening a pipe through /dev/fd/N fails on macOS and would silently emit nothing.
  local payload=""
  if have jq && printf '%s\n' "$extra" | jq -e . >/dev/null 2>&1; then
    payload="$(jq -n --arg v "$verdict" --arg ts "$TS" --arg reason "$reason" --argjson extra "$extra" \
      '{verdict:$v, ts:$ts, gate:"doctor", reason:$reason} + $extra' 2>/dev/null)" || payload=""
  fi
  [ -n "$payload" ] || payload="$(printf '{"verdict":"%s","ts":"%s","gate":"doctor","reason":"%s"}' "$verdict" "$TS" "$reason")"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$payload" >&3
  else
    printf '%s\n' "$payload" > "$REPORT"
  fi
}

# Pick a real self-testing core gate (ship-gate has no --selftest). Order of preference.
pick_core_gate() {
  for g in gate-suite.sh hollow-artifact-gate.sh harness-self-audit-gate.sh; do
    [ -f "$HOOKS/$g" ] && { echo "$g"; return 0; }
  done
  echo ""
}

# ── selftest ────────────────────────────────────────────────────────────────
selftest() {
  local pass=0 fail=0 tmp
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")"

  ck() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "  ok   - $name (rc=$got)"; pass=$((pass+1))
    else echo "  FAIL - $name (want $want got $got)"; fail=$((fail+1)); fi
  }

  # A minimal healthy fixture: a registry + a hooks dir with a tiny gate that self-tests green.
  make_healthy() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit" "$dst/.claude/hooks"
    cat > "$dst/walteur-kit/gate-registry.json" <<'JSON'
{ "schema_version": 1, "registry_id": "doctor-selftest", "gates": [
  { "id": "demo", "hook": "gate-suite.sh", "report": "walteur-kit/x.json" } ] }
JSON
    # A stand-in core gate that emits the canonical selftest summary line and exits 0.
    cat > "$dst/.claude/hooks/gate-suite.sh" <<'JSON'
#!/usr/bin/env bash
if [ "${1:-}" = "--selftest" ]; then echo "gate-suite selftest: 3/3 passed"; exit 0; fi
exit 0
JSON
  }

  echo "doctor selftest:"

  # GOOD twin -> healthy -> exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "healthy tree -> exit 0" 0 "$?"
  jq -e '.selftest_executed != null' "$tmp/walteur-kit/doctor-report.json" >/dev/null 2>&1
  ck "report records selftest execution marker" 0 "$?"
  jq -e '.failing_gates == 0' "$tmp/walteur-kit/doctor-report.json" >/dev/null 2>&1
  ck "healthy tree: failing_gates==0 (no reports to triage)" 0 "$?"
  rm -rf "$tmp"

  # TRIAGE: seeded FAIL report -> doctor names the gate + points at REMEDIATION.md, exit 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  jq -n '{verdict:"FAIL", ts:"2026-01-01T00:00:00Z", gate:"demo-triage-gate", reason:"synthetic seeded failure for selftest"}' \
    > "$tmp/walteur-kit/demo-triage-gate-report.json"
  out="$(WALTEUR_ROOT="$tmp" bash "$SELF_PATH" 2>&1)"; rc="$?"
  ck "seeded FAIL report -> doctor exits 1 (not healthy)" 1 "$rc"
  printf '%s' "$out" | grep -q 'demo-triage-gate' && printf '%s' "$out" | grep -q 'synthetic seeded failure for selftest'
  ck "triage output names the gate + its reason" 0 "$?"
  printf '%s' "$out" | grep -q 'REMEDIATION.md#demo-triage-gate'
  ck "triage output points at the REMEDIATION.md anchor" 0 "$?"
  jq -e '.failing_gates == 1 and (.triage[0].gate=="demo-triage-gate") and (.triage[0].remediation=="walteur-kit/REMEDIATION.md#demo-triage-gate")' \
    "$tmp/walteur-kit/doctor-report.json" >/dev/null 2>&1
  ck "report JSON records the triage entry with remediation anchor" 0 "$?"
  rm -rf "$tmp"

  # DERIVED REASON (B63, panel-7 uxdx): a FAIL report with NO top-level reason but rich structured detail must
  # still explain itself — doctor synthesizes a concise reason from details[]/rules[]/broken[]/violations/detail.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  jq -n '{verdict:"FAIL", ts:"2026-01-02T00:00:00Z", gate:"demo-noreason-gate", details:[{rule:"input-no-label", file:"x.html", message:"an input has no label"}]}' \
    > "$tmp/walteur-kit/demo-noreason-gate-report.json"
  out="$(WALTEUR_ROOT="$tmp" bash "$SELF_PATH" 2>&1)"
  if grep -q 'input-no-label' <<< "$out" && ! grep -q 'no reason field in report' <<< "$out"; then rc=0; else rc=1; fi
  ck "reason-less structured FAIL -> doctor DERIVES a reason (not '(no reason field)')" 0 "$rc"
  rm -rf "$tmp"

  # RESOLVER (panel #3 uxdx fix): a report's short gate id must resolve to a LIVE REMEDIATION.md header —
  # doctor tries <id>, <id>-gate, <id>-lint, <id>-check. 69/91 real pointers dangled before this because a
  # report gate "anti-slop-code" was emitted as #anti-slop-code while the header is "## anti-slop-code-gate".
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  printf '## foo-gate\nEnforces: demo.\n' > "$tmp/walteur-kit/REMEDIATION.md"
  jq -n '{verdict:"FAIL", ts:"2026-01-01T00:00:00Z", gate:"foo", reason:"short id needs -gate resolution"}' \
    > "$tmp/walteur-kit/foo-report.json"
  out="$(WALTEUR_ROOT="$tmp" bash "$SELF_PATH" 2>&1)"
  printf '%s' "$out" | grep -q 'REMEDIATION.md#foo-gate'
  ck "resolver: short id foo -> live anchor #foo-gate" 0 "$?"
  jq -e '(.triage[] | select(.gate=="foo") | .remediation) == "walteur-kit/REMEDIATION.md#foo-gate"' \
    "$tmp/walteur-kit/doctor-report.json" >/dev/null 2>&1
  ck "resolver: report JSON records resolved #foo-gate anchor" 0 "$?"
  rm -rf "$tmp"

  # RESOLVER fallback: an id with NO matching header (any variant) falls back to the bare id -- honest, not invented.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  printf '## something-else\n' > "$tmp/walteur-kit/REMEDIATION.md"
  jq -n '{verdict:"FAIL", ts:"2026-01-01T00:00:00Z", gate:"nomatch", reason:"no header anywhere"}' \
    > "$tmp/walteur-kit/nomatch-report.json"
  out="$(WALTEUR_ROOT="$tmp" bash "$SELF_PATH" 2>&1)"
  printf '%s' "$out" | grep -q 'REMEDIATION.md#nomatch'
  ck "resolver: no matching header -> honest bare-id fallback #nomatch" 0 "$?"
  rm -rf "$tmp"

  # TRIAGE negative control: doctor's OWN prior report (verdict FAIL, gate:"doctor") must never
  # self-triage — a doctor run must not name itself in its own next run's triage list.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  jq -n '{verdict:"FAIL", ts:"2026-01-01T00:00:00Z", gate:"doctor", reason:"stale self-report, must be ignored"}' \
    > "$tmp/walteur-kit/doctor-report.json"
  out="$(WALTEUR_ROOT="$tmp" bash "$SELF_PATH" 2>&1)"; rc="$?"
  ck "stale self-report alone -> healthy exit 0 (self-report excluded)" 0 "$rc"
  printf '%s' "$out" | grep -q 'stale self-report, must be ignored'
  [ "$?" -ne 0 ]
  ck "doctor never triages its own prior report" 0 "$?"
  rm -rf "$tmp"

  # POISONED twin 1 -> registry absent -> exit 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  rm -f "$tmp/walteur-kit/gate-registry.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "missing gate-registry.json -> exit 1" 1 "$?"
  rm -rf "$tmp"

  # POISONED twin 2 -> registry invalid JSON -> exit 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  printf '{ bad json\n' > "$tmp/walteur-kit/gate-registry.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "invalid gate-registry.json -> exit 1" 1 "$?"
  rm -rf "$tmp"

  # POISONED twin 3 -> core gate selftest FAILS (exit 2) -> exit 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  cat > "$tmp/.claude/hooks/gate-suite.sh" <<'JSON'
#!/usr/bin/env bash
if [ "${1:-}" = "--selftest" ]; then echo "gate-suite selftest: 1/3 passed"; exit 2; fi
exit 0
JSON
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "failing core-gate selftest -> exit 1" 1 "$?"
  rm -rf "$tmp"

  # POISONED twin 4 -> core gate prints 'selftest: 0/5 passed' but EXITS 0 (false-green by exit-code) -> exit 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  cat > "$tmp/.claude/hooks/gate-suite.sh" <<'JSON'
#!/usr/bin/env bash
if [ "${1:-}" = "--selftest" ]; then echo "gate-suite selftest: 0/5 passed"; exit 0; fi
exit 0
JSON
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "selftest 0/5 passed but exit 0 -> exit 1 (passed<total)" 1 "$?"
  jq -e '.selftest_executed == true' "$tmp/walteur-kit/doctor-report.json" >/dev/null 2>&1
  ck "0/5 twin: count was parsed so selftest_executed==true" 0 "$?"
  rm -rf "$tmp"

  # POISONED twin 5 -> core gate has NO --selftest branch (exit 0, emits NO count) -> exit 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  cat > "$tmp/.claude/hooks/gate-suite.sh" <<'JSON'
#!/usr/bin/env bash
exit 0
JSON
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "core gate with no selftest branch (no count) -> exit 1" 1 "$?"
  jq -e '.selftest_executed == false' "$tmp/walteur-kit/doctor-report.json" >/dev/null 2>&1
  ck "no-count twin: selftest_executed==false (not on file existence)" 0 "$?"
  rm -rf "$tmp"

  # PAUSED -> exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  : > "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> exit 2" 2 "$?"
  rm -rf "$tmp"

  # Bypass -> loud SKIP exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  WALTEUR_DOCTOR=off WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass WALTEUR_DOCTOR=off -> exit 0" 0 "$?"
  rm -rf "$tmp"

  # ── uxdx (panel #12): argument validation ──────────────────────────────────
  # NEGATIVE CONTROL. A one-hyphen typo of --selftest used to run the DEFAULT health check and exit 1
  # with no signal at all, so the operator read a health-check failure as a selftest failure. An
  # unrecognised flag must say "unknown option" and exit 64 (EX_USAGE) — never run a different mode.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  out="$(WALTEUR_ROOT="$tmp" bash "$SELF_PATH" --self-test 2>&1)"; rc="$?"
  ck "typo --self-test -> exit 64 (EX_USAGE), not the default run" 64 "$rc"
  printf '%s' "$out" | grep -q 'unknown option: --self-test'
  ck "typo names the offending flag ('unknown option: --self-test')" 0 "$?"
  printf '%s' "$out" | grep -q 'selftest:'
  ck "typo did NOT silently run another mode (no selftest output)" 1 "$?"
  out="$(WALTEUR_ROOT="$tmp" bash "$SELF_PATH" --explain-everything 2>&1)"; rc="$?"
  ck "unknown flag --explain-everything -> exit 64" 64 "$rc"
  out="$(WALTEUR_ROOT="$tmp" bash "$SELF_PATH" --dry-run --selftest 2>&1)"; rc="$?"
  ck "too many arguments -> exit 64" 64 "$rc"
  rm -rf "$tmp"

  # ── uxdx (panel #12): --dry-run writes NOTHING ─────────────────────────────
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  make_healthy "$tmp"
  out="$(WALTEUR_ROOT="$tmp" bash "$SELF_PATH" --dry-run 2>/dev/null)"; rc="$?"
  ck "--dry-run on a healthy tree -> exit 0" 0 "$rc"
  [ -f "$tmp/walteur-kit/doctor-report.json" ]
  ck "--dry-run wrote NO doctor-report.json" 1 "$?"
  printf '%s' "$out" | jq -e '.gate=="doctor" and .verdict=="PASS"' >/dev/null 2>&1
  ck "--dry-run stdout is the report JSON alone (parses, gate==doctor)" 0 "$?"
  out="$(WALTEUR_ROOT="$tmp" bash "$SELF_PATH" --stdout 2>/dev/null)"
  printf '%s' "$out" | jq -e '.gate=="doctor"' >/dev/null 2>&1
  ck "--stdout is an alias for --dry-run" 0 "$?"
  # dry-run must still FAIL-CLOSED on a real problem — read-only is not a free pass.
  rm -f "$tmp/walteur-kit/gate-registry.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" --dry-run >/dev/null 2>&1
  ck "--dry-run still exits 1 on a missing registry (read-only != green)" 1 "$?"
  [ -f "$tmp/walteur-kit/doctor-report.json" ]
  ck "--dry-run wrote no report even on the failing path" 1 "$?"
  rm -rf "$tmp"

  # ── uxdx (panel #12): cwd guard — no litter in an unrelated tree ───────────
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-selftest.XXXXXX")" || return 1
  # deliberately NO walteur-kit/ here: this is the "ran from the wrong directory" case.
  out="$(WALTEUR_ROOT="$tmp" bash "$SELF_PATH" 2>&1)"; rc="$?"
  ck "no walteur-kit/ in cwd -> exit 1" 1 "$rc"
  printf '%s' "$out" | grep -q 'run from the repo root'
  ck "wrong cwd says 'run from the repo root', not 'registry missing'" 0 "$?"
  [ -d "$tmp/walteur-kit" ]
  ck "wrong cwd created NO walteur-kit/ directory" 1 "$?"
  [ -f "$tmp/walteur-kit/doctor-report.json" ]
  ck "wrong cwd littered NO doctor-report.json" 1 "$?"
  rm -rf "$tmp"

  # ── uxdx (panel #12): every REMEDIATION alias must target a LIVE heading ───
  # An alias that points at a heading which does not exist would manufacture a live-LOOKING pointer
  # to a void — worse than the honest fallback. Assert each alias target is a real '## ' heading.
  if [ -f "$KIT/REMEDIATION.md" ]; then
    _bad_alias=0
    for _pair in $REMEDIATION_ALIASES; do
      _target="${_pair#*=}"
      grep -Fxq "## $_target" "$KIT/REMEDIATION.md" 2>/dev/null || _bad_alias=$((_bad_alias+1))
    done
    [ "$_bad_alias" -eq 0 ]
    ck "every REMEDIATION_ALIASES target is a live '## ' heading" 0 "$?"
  fi

  echo "doctor selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

# ── CONTRACT preamble ─────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }
[ "${WALTEUR_DOCTOR:-on}" = "off" ] && {
  write_report "SKIP" "WALTEUR_DOCTOR=off"
  echo "doctor: bypassed (WALTEUR_DOCTOR=off)." >&2
  exit 0
}

echo "WALTEUR doctor — health self-check"
echo "=================================="

problems=0

# 1. Tooling --------------------------------------------------------------------
for t in bash jq; do
  if have "$t"; then printf '  ok   - %-4s present (%s)\n' "$t" "$(command -v "$t")"
  else printf '  FAIL - %-4s NOT found on PATH\n' "$t"; problems=$((problems+1)); fi
done
if have node; then printf '  ok   - node present (%s)\n' "$(command -v node)"
else printf '  warn - node not found (advisory; test re-runs need it)\n'; fi

# jq is required for the rest; if it is absent we cannot measure -> loud problem, fail-closed.
if ! have jq; then
  echo "doctor: jq absent — cannot parse the gate registry (cannot_measure)." >&2
  write_report "FAIL" "jq absent: cannot parse gate-registry.json"
  echo ""
  echo "Health: UNHEALTHY (jq missing). Install jq and re-run."
  exit 1
fi

# 2. Gate registry --------------------------------------------------------------
declared_gates=0
if [ ! -f "$REGISTRY" ]; then
  printf '  FAIL - gate-registry.json missing (%s)\n' "${REGISTRY#"$ROOT"/}"
  problems=$((problems+1))
elif ! jq -e . "$REGISTRY" >/dev/null 2>&1; then
  printf '  FAIL - gate-registry.json is not valid JSON (%s)\n' "${REGISTRY#"$ROOT"/}"
  problems=$((problems+1))
else
  declared_gates="$(jq -r '(.gates // []) | length' "$REGISTRY" 2>/dev/null || echo 0)"
  printf '  ok   - gate-registry.json parses (%s declared gate(s))\n' "$declared_gates"
fi

# 3. Hooks present --------------------------------------------------------------
hooks_on_disk=0
if [ -d "$HOOKS" ]; then
  hooks_on_disk="$(find "$HOOKS" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')"
  printf '  ok   - hooks dir present: %s (%s *.sh script(s))\n' "${HOOKS#"$ROOT"/}" "$hooks_on_disk"
else
  printf '  warn - hooks dir not found (looked at .claude/hooks and walteur-kit/hooks)\n'
fi

# 4. Core-gate selftest (OBSERVED) ---------------------------------------------
# False-green hardening: keying PASS on the child's exit code alone lets a core gate that is just
# `#!/bin/bash; exit 0` (NO --selftest branch, emits no count) read HEALTHY. A real selftest MUST emit a
# parseable N/N. We therefore require a NON-EMPTY parsed count AND passed==total AND total>0; otherwise it
# is a PROBLEM. The execution marker is set ONLY when a real count was parsed (never on file existence).
core_gate="$(pick_core_gate)"
selftest_count=""
selftest_exit=""
selftest_parsed=false   # true only when a real N/N count was actually extracted
if [ -z "$core_gate" ]; then
  printf '  warn - no self-testing core gate found to smoke (gate-suite/hollow-artifact/harness-self-audit)\n'
else
  out="$(bash "$HOOKS/$core_gate" --selftest 2>&1)"; selftest_exit=$?
  out="$(printf '%s' "$out" | tr -d '\r')"
  selftest_count="$(printf '%s\n' "$out" | grep -Ei 'selftest:.*passed' | tail -1 | grep -Eo '[0-9]+/[0-9]+' | tail -1)"
  s_pass=""; s_total=""
  if [ -n "$selftest_count" ]; then
    s_pass="${selftest_count%%/*}"; s_total="${selftest_count##*/}"
    selftest_parsed=true
  fi
  # A selftest proves something only when: a count was parsed, total>0, passed==total, AND child exit 0.
  if [ "$selftest_parsed" = true ] && [ "$s_total" -gt 0 ] 2>/dev/null \
     && [ "$s_pass" -eq "$s_total" ] 2>/dev/null && [ "$selftest_exit" -eq 0 ]; then
    printf '  ok   - core selftest %s -> %s (exit 0)\n' "$core_gate" "$selftest_count"
  elif [ "$selftest_parsed" != true ]; then
    printf '  FAIL - core selftest %s emitted NO parseable N/N count (proves nothing) (exit %s)\n' \
      "$core_gate" "$selftest_exit"
    problems=$((problems+1))
  elif [ "$s_total" -eq 0 ] 2>/dev/null; then
    printf '  FAIL - core selftest %s -> %s has zero total (0/0 proves nothing) (exit %s)\n' \
      "$core_gate" "$selftest_count" "$selftest_exit"
    problems=$((problems+1))
  else
    printf '  FAIL - core selftest %s -> %s (passed<total or exit %s)\n' \
      "$core_gate" "$selftest_count" "$selftest_exit"
    problems=$((problems+1))
  fi
fi

# 5. Failure triage (OBSERVED, not authored) ------------------------------------
# Scan every *-report.json in the kit for verdict=="FAIL" (a gate's own staleness/forgery
# checks already fold into FAIL — doctor does not re-derive staleness, it surfaces what the
# gate itself recorded). For each: name the gate, print its reason, and point at the
# REMEDIATION.md anchor '## <gate-id>' the remediation table uses (link only — doctor never
# edits or reads REMEDIATION.md's body, so a missing row is still a valid, honest pointer).
triage_json='[]'
triage_count=0
REMEDIATION_REL="walteur-kit/REMEDIATION.md"
# uxdx fix (panel #3): the "fix -> REMEDIATION.md#<id>" pointer doctor prints on every failing gate must be
# a LIVE anchor, not a void. A report's .gate is a short id ("anti-slop-code") while REMEDIATION headers use
# the registry slug ("## anti-slop-code-gate") — 69/91 pointers dangled. doctor now reads ONLY the "## "
# HEADERS of REMEDIATION.md (never its body — it still never triages from REMEDIATION content) and resolves
# the anchor to a header that actually exists, trying <id>, <id>-gate, <id>-lint, <id>-check; honest <id>
# fallback if none match.
# uxdx fix (panel #12): the suffix rules above cannot bridge a report id whose WORDS differ from the
# registry slug. Live case: lifecycle-access-gate.sh writes '"gate":"access-lifecycle"', but the heading
# is '## lifecycle-access-gate' — a hyphen-segment SWAP, not a suffix — so #access-lifecycle 404'd.
# An explicit, auditable alias list handles exactly those (REMEDIATION_ALIASES, defined near the top so
# --selftest can assert every alias target is a live heading), and an alias is honored ONLY when its
# target heading really exists, so this can never invent a live-looking pointer to a void.
REMEDIATION_HEADERS=""
[ -f "$KIT/REMEDIATION.md" ] && REMEDIATION_HEADERS="$(grep -E '^## ' "$KIT/REMEDIATION.md" 2>/dev/null | sed 's/^## //')"
resolve_anchor() {
  _g="$1"
  for _c in "$_g" "$_g-gate" "$_g-lint" "$_g-check"; do
    if printf '%s\n' "$REMEDIATION_HEADERS" | grep -Fxq "$_c"; then printf '%s' "$_c"; return; fi
  done
  _alias="$(printf '%s\n' "$REMEDIATION_ALIASES" | grep -E "^${_g}=" 2>/dev/null | head -1 | cut -d= -f2-)"
  if [ -n "$_alias" ] && printf '%s\n' "$REMEDIATION_HEADERS" | grep -Fxq "$_alias"; then
    printf '%s' "$_alias"; return
  fi
  printf '%s' "$_g"
}
if [ -d "$KIT" ]; then
  triage_tmp="$(mktemp "${TMPDIR:-/tmp}/doctor-triage.XXXXXX")" 2>/dev/null || triage_tmp=""
  if [ -n "$triage_tmp" ]; then
    : > "$triage_tmp"
    for rep in "$KIT"/*-report.json; do
      [ -f "$rep" ] || continue
      base="$(basename "$rep")"
      # doctor's own report is a health check, not a triage subject.
      [ "$base" = "doctor-report.json" ] && continue
      v="$(jq -r '.verdict // empty' "$rep" 2>/dev/null)"
      [ "$v" = "FAIL" ] || continue
      g="$(jq -r '.gate // empty' "$rep" 2>/dev/null)"
      [ -n "$g" ] || g="${base%-report.json}"
      r="$(jq -r '
        (.reason // empty)
        // (.detail // empty)
        // (.message // empty)
        // (if ((.details|type)=="array" and (.details|length)>0) then
             ((.details|length|tostring) + " finding(s): " + ((.details[0].rule // .details[0].check // "issue")|tostring) + (if .details[0].file then " in " + (.details[0].file|tostring) else "" end) + (if .details[0].message then " - " + (.details[0].message|tostring|.[0:120]) else "" end))
           else empty end)
        // (if ((.rules|type)=="array") then
             ([.rules[]|select((.result//"")|test("VETO|FAIL"))|.rule] as $bad | if ($bad|length)>0 then (($bad|length|tostring) + " rule(s) failed: " + ($bad|join(", "))) else empty end)
           else empty end)
        // (if ((.broken|type)=="array" and (.broken|length)>0) then
             ("broken: " + ([.broken[]|((.gate//"?")|tostring) + " " + ((.result//"")|tostring)]|join("; ")) + (if .twin_result then " - twin:" + (.twin_result|tostring) else "" end))
           else empty end)
        // (if (.violations != null) then ((.violations|tostring) + " violation(s)" + (if ((.details|type)=="object") then " (" + ([.details|to_entries[]|select((.value.verdict//"")=="FAIL")|.key]|join(",")) + ")" else "" end)) else empty end)
        // "FAIL (structured detail in report; no summary field)"
      ' "$rep" 2>/dev/null | head -1)"
      [ -n "$r" ] || r="(no reason field in report)"
      ts="$(jq -r '.ts // empty' "$rep" 2>/dev/null)"
      [ -n "$ts" ] || ts="0000-00-00T00:00:00Z"
      _anchor_slug="$(resolve_anchor "$g")"
      jq -n --arg gate "$g" --arg reason "$r" --arg ts "$ts" --arg report "${rep#"$ROOT"/}" \
        --arg anchor "${REMEDIATION_REL}#${_anchor_slug}" \
        '{gate:$gate, reason:$reason, ts:$ts, report:$report, remediation:$anchor}' >> "$triage_tmp" 2>/dev/null
    done
    if [ -s "$triage_tmp" ]; then
      triage_json="$(jq -s 'sort_by(.ts) | reverse' "$triage_tmp" 2>/dev/null || echo '[]')"
      triage_count="$(printf '%s' "$triage_json" | jq -r 'length' 2>/dev/null || echo 0)"
    fi
    rm -f "$triage_tmp"
  fi
fi

if [ "$triage_count" -gt 0 ] 2>/dev/null; then
  echo ""
  echo "Failing gates ($triage_count) — triage:"
  printf '%s' "$triage_json" | jq -r '.[] | "  ✗ " + .gate + " · " + .reason + " · fix -> " + .remediation' 2>/dev/null
fi

# 6. Summary --------------------------------------------------------------------
echo ""
extra="$(jq -n \
  --argjson declared "${declared_gates:-0}" \
  --argjson ondisk "${hooks_on_disk:-0}" \
  --arg core "${core_gate:-none}" \
  --arg count "${selftest_count:-}" \
  --arg sexit "${selftest_exit:-}" \
  --argjson parsed "${selftest_parsed:-false}" \
  --argjson problems "$problems" \
  --argjson failing "$triage_count" \
  --argjson triage "$triage_json" \
  '{declared_gates:$declared, hooks_on_disk:$ondisk, core_gate:$core,
    selftest_executed:$parsed, selftest_count:$count,
    observed_exit:(if $sexit=="" then null else ($sexit|tonumber) end), problems:$problems,
    failing_gates:$failing, triage:$triage}' 2>/dev/null || echo '{}')"

if [ "$problems" -gt 0 ]; then
  write_report "FAIL" "$problems health problem(s)" "$extra"
  echo "Health: UNHEALTHY ($problems problem(s)). See messages above -> $REPORT_LABEL"
  [ "$triage_count" -gt 0 ] 2>/dev/null && print_epilogue "$triage_json" "$triage_count"
  exit 1
fi

if [ "$triage_count" -gt 0 ] 2>/dev/null; then
  write_report "FAIL" "$triage_count gate report(s) recorded FAIL" "$extra"
  echo "Health: HEALTHY tools, but $triage_count gate report(s) are FAIL -> $REPORT_LABEL"
  print_epilogue "$triage_json" "$triage_count"
  exit 1
fi

write_report "PASS" "healthy: tools + registry + core selftest green" "$extra"
echo "Health: HEALTHY (declared_gates=${declared_gates}, hooks_on_disk=${hooks_on_disk}, core_selftest=${selftest_count:-n/a}) -> $REPORT_LABEL"
exit 0
