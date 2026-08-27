#!/usr/bin/env bash
# WALTEUR opengrep-gate — inter-procedural source->sink TAINT analysis (pillar P-OPENGREP, beside ast-grep P12).
# Runs opengrep (the OSS opengrep/opengrep engine, ~12 langs) over ROOT and surfaces data-flow findings that
# ast-grep / grep CANNOT see: a tainted SOURCE (req.query, argv, env, network body) reaching a dangerous SINK
# (exec/eval/SQL string/path open) THROUGH function calls. This raises the silent-failure + security surfaces
# from SYNTACTIC (a pattern on one line) to DATA-FLOW (a value tracked across the call graph).
#
# WHY a NEW hook (not folded into ast-grep): ast-grep matches AST *shapes* on a single tree; it has no taint
# engine — it structurally cannot follow a value from source to sink across procedures. opengrep's `mode: taint`
# rules do exactly that. The two are complementary: ast-grep proves structure, opengrep proves flow.
#
# HONESTY BOUNDARY (load-bearing — do not erode):
#   * WARNING-FIRST: by default a real taint finding => a LOUD WARN and exit 0 (it does NOT block). It becomes
#     HARD (exit 2) ONLY when WALTEUR_OPENGREP=hard. New gates ship warn-first; HARD is opt-in. This hook is
#     NOT wired into the live ship-gate.sh.
#   * A finding is mechanical: a SARIF result whose `level` is "error" (an opengrep taint/security rule firing).
#     "warning"/"note" results are recorded as informational, never block. No judgment in the verdict.
#   * A PASS means "opengrep ran and reported no error-level taint result for the rules we ran" — it is NOT a
#     clean bill of health: it does not prove the code is safe, only that THIS ruleset found no source->sink path.
#   * Absence of a finding = NOT-FOUND, never PROVEN-SAFE. opengrep ABSENT => a LOUD SKIP (exit 0): "we could
#     not run the taint engine", never silent-green. detect-or-LOUD-SKIP — the binary is likely NOT installed.
#
# Tool contract (DETECT-OR-LOUD-SKIP — opengrep is likely absent; this MUST be graceful):
#   * opengrep ABSENT on PATH      -> LOUD SKIP exit 0 (recorded), UNLESS WALTEUR_OPENGREP=hard (then a
#                                     can't-run on a taint surface is itself fail-closed => exit 2).
#   * opengrep PRESENT             -> real run: `opengrep scan --sarif` (semgrep-compatible CLI) over ROOT
#                                     with the ruleset, parse the SARIF, count error-level results.
#   * OPENGREP_SARIF=/path.json    -> use that file AS the SARIF output (NO run). The selftest path — lets the
#                                     PARSE + verdict logic be proven hermetically whether or not the binary
#                                     is installed. (Also handy to re-grade a CI artifact offline.)
#   * OPENGREP_BIN=/path           -> override the binary name/path (default: opengrep).
#   * OPENGREP_CONFIG=<ruleset>    -> override the ruleset (default: walteur-kit/opengrep-rules/ if present,
#                                     else the engine's bundled "auto"/"p/default" registry config).
# Bypass: WALTEUR_OPENGREP=off => recorded SKIP, exit 0.   Kill switch: walteur-kit/PAUSED present => exit 2.
# Self-test: bash walteur-kit/hooks/opengrep-gate.sh --selftest   (HERMETIC, OFFLINE — driven by OPENGREP_SARIF;
#            PASSES with the binary ABSENT — it proves the LOUD-SKIP path AND the SARIF parse/verdict logic).
# Zero-dep floor: bash + grep + awk + sed. jq used for SARIF parse + report WHEN PRESENT (grep/awk fallback).
# Report: walteur-kit/opengrep-report.json {verdict, ts, gate, mode, source, config, findings, errors,
#         warnings, details[], reason}.
#
# LGPL note: opengrep/opengrep is LGPL. That governs REDISTRIBUTION of the BINARY; calling it as an external
# tool (as this gate does — never bundling or linking it) is plain use, not a redistribution trigger.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "opengrep-gate - inter-procedural source->sink TAINT analysis (pillar P-OPENGREP, beside ast-grep P12)."
  printf '%s\n' "usage: bash opengrep-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/opengrep-report.json - fix recipes: walteur-kit/REMEDIATION.md (## opengrep-gate)"
  printf '%s\n' "bypass: WALTEUR_OPENGREP=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/opengrep-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MODE="${WALTEUR_OPENGREP:-on}"
OPENGREP_BIN="${OPENGREP_BIN:-opengrep}"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# write_report <verdict> <reason> <source> <config> <errors-int> <warnings-int> <details-json-array>
write_report() {
  local v="$1" reason="$2" source="$3" config="$4" errs="${5:-0}" warns="${6:-0}" det="${7:-[]}"
  local total=$(( errs + warns ))
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --arg mode "$MODE" --arg reason "$reason" \
          --arg source "$source" --arg config "$config" \
          --argjson errs "$errs" --argjson warns "$warns" --argjson total "$total" --argjson det "$det" \
      '{verdict:$v, ts:$ts, gate:"opengrep", mode:$mode, source:$source, config:$config,
        findings:$total, errors:$errs, warnings:$warns, details:$det, reason:$reason}' > "$REPORT"
  else
    # jq is NOT in the mandated zero-dep set; emit valid minimal JSON without it.
    printf '{"verdict":"%s","ts":"%s","gate":"opengrep","mode":"%s","source":"%s","config":"%s","findings":%s,"errors":%s,"warnings":%s,"details":%s,"reason":"%s"}\n' \
      "$v" "$TS" "$MODE" "$source" "$config" "$total" "$errs" "$warns" "$det" "$reason" > "$REPORT"
  fi
}

# extract error-level taint results from an opengrep/semgrep SARIF 2.1.0 document.
# Error := a result whose level == "error" (a taint/security rule firing). warning/note are informational.
# Emits a JSON array of {ruleId, level, file, line, message} (best-effort; fields may be "").
extract_sarif() { # $1 = SARIF JSON
  local sarif="$1"
  if have jq; then
    printf '%s' "$sarif" | jq -c '
      [ (.runs // [])[]? | (.results // [])[]?
        | { ruleId:  (.ruleId // ""),
            level:   (.level // "warning"),
            file:    ((.locations // [])[0]?.physicalLocation.artifactLocation.uri // ""),
            line:    ((.locations // [])[0]?.physicalLocation.region.startLine // 0),
            message: (.message.text // "taint finding") } ]
    ' 2>/dev/null || echo '[]'
  else
    # zero-dep floor: SARIF is line-structured enough that a coarse scan still mechanically catches the
    # error-level results. Coarser (no per-result file/line mapping) but HONEST — it still fails closed in
    # hard mode when an error-level result is present. One {ruleId,level} object per error result.
    local ids
    # pair up "ruleId":"X" with the nearest following "level":"error" within the same result object.
    # NOTE: count with `awk END{print NR}` (always exactly one integer, exit 0) — NOT `grep -c ... || echo 0`,
    # whose `||` arm DOUBLES the output to "0\n0" on zero matches and breaks the integer test downstream.
    ids="$(printf '%s' "$sarif" \
      | tr ',' '\n' \
      | grep -E '"(ruleId|level)"' \
      | awk '
          /"ruleId"/ { rid=$0; sub(/.*"ruleId"[ \t]*:[ \t]*"/,"",rid); sub(/".*/,"",rid); pend=rid; next }
          /"level"[ \t]*:[ \t]*"error"/ { if(pend!=""){ print pend; pend="" } }
        ' \
      | awk 'END{print NR+0}')"
    ids="${ids:-0}"
    if [ "$ids" -eq 0 ]; then echo '[]'; return; fi
    # emit ids placeholders (count-accurate; field-coarse). The jq path above is authoritative.
    local out="[" first=1 k=0
    while [ "$k" -lt "$ids" ]; do
      [ "$first" -eq 1 ] && first=0 || out="$out,"
      out="$out{\"ruleId\":\"\",\"level\":\"error\",\"file\":\"\",\"line\":0,\"message\":\"taint finding (opengrep)\"}"
      k=$((k+1))
    done
    echo "$out]"
  fi
}

# count results at a given level in the details array. $1=details-json $2=level
count_level() {
  local det="$1" lvl="$2"
  if have jq; then
    printf '%s' "$det" | jq --arg l "$lvl" '[.[] | select(.level==$l)] | length' 2>/dev/null || echo 0
  else
    # awk END{print NR+0} prints exactly one integer and exits 0 — `grep -c ... || echo 0` would emit
    # "0\n0" on zero matches (grep -c prints 0 AND exits 1, so the || arm fires too), breaking [ -gt ].
    printf '%s' "$det" | grep -o "\"level\":\"$lvl\"" 2>/dev/null | awk 'END{print NR+0}'
  fi
}

# LOUD SKIP for the can't-run path; hard mode turns can't-run into fail-closed.
_cannot_run() { # $1=reason $2=config
  if [ "$MODE" = "hard" ]; then
    echo "WALTEUR opengrep-gate FAIL (hard) — $1; cannot run taint analysis (fail-closed posture)." >&2
    write_report "FAIL" "hard: cannot run ($1)" "unavailable-hard" "$2" 0 0 '[]'
    exit 2
  fi
  echo "WALTEUR opengrep-gate SKIP — $1 (recorded, not silent-green; set WALTEUR_OPENGREP=hard to fail-closed, or OPENGREP_SARIF=<file> to verify the parse offline)." >&2
  write_report "SKIP" "tool unavailable: $1" "unavailable" "$2" 0 0 '[]'
  exit 0
}

run_gate() {
  # ── kill switch ────────────────────────────────────────────────────────────
  [ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }

  # ── bypass ─────────────────────────────────────────────────────────────────
  if [ "$MODE" = "off" ]; then
    echo "WALTEUR opengrep-gate SKIP — bypass WALTEUR_OPENGREP=off (recorded, not silent-green)." >&2
    write_report "SKIP" "bypass WALTEUR_OPENGREP=off" "bypass" "" 0 0 '[]'; exit 0
  fi

  # ── base-tool guard (zero-dep floor for SARIF parse) ─────────────────────────
  for t in grep awk sed; do
    if ! have "$t"; then
      echo "WALTEUR opengrep-gate SKIP — required base tool '$t' not installed (recorded, not silent-green)." >&2
      write_report "SKIP" "$t not installed" "tool-missing" "" 0 0 '[]'; exit 0
    fi
  done

  # ── resolve the ruleset/config ───────────────────────────────────────────────
  local config
  if [ -n "${OPENGREP_CONFIG:-}" ]; then
    config="$OPENGREP_CONFIG"
  elif [ -d "$KIT/opengrep-rules" ]; then
    config="$KIT/opengrep-rules"
  else
    config="auto"   # the engine's bundled registry default (taint + security)
  fi

  # ── obtain a SARIF document (fixture | real run | LOUD SKIP) ──────────────────
  local SARIF source
  if [ -n "${OPENGREP_SARIF:-}" ]; then
    if [ ! -f "$OPENGREP_SARIF" ]; then
      echo "WALTEUR opengrep-gate SKIP — OPENGREP_SARIF='$OPENGREP_SARIF' not a file (recorded, not silent-green)." >&2
      write_report "SKIP" "OPENGREP_SARIF not found: $OPENGREP_SARIF" "fixture-missing" "$config" 0 0 '[]'; exit 0
    fi
    SARIF="$(cat "$OPENGREP_SARIF")"
    source="fixture:$OPENGREP_SARIF"
    echo "WALTEUR opengrep-gate — using OPENGREP_SARIF (offline parse): $OPENGREP_SARIF" >&2
  else
    # real run path — DETECT-OR-LOUD-SKIP. The binary is likely absent.
    if ! have "$OPENGREP_BIN"; then
      _cannot_run "opengrep binary '$OPENGREP_BIN' not installed (install: https://github.com/opengrep/opengrep)" "$config"
    fi
    local out; out="$(mktemp "${TMPDIR:-/tmp}/opengrep-sarif.XXXXXX")"
    # opengrep is semgrep-compatible: `scan --sarif --config <c> <root>`. Quiet; tolerate non-zero exit
    # (opengrep exits non-zero WHEN findings exist — we read the SARIF, not the exit code).
    "$OPENGREP_BIN" scan --sarif --config "$config" --output "$out" "$ROOT" >/dev/null 2>&1 || true
    if [ ! -s "$out" ]; then
      rm -f "$out"
      _cannot_run "opengrep produced no SARIF output (run failed for config '$config')" "$config"
    fi
    SARIF="$(cat "$out")"; rm -f "$out"
    source="opengrep:$OPENGREP_BIN"
    echo "WALTEUR opengrep-gate — ran $OPENGREP_BIN (config: $config) over $ROOT." >&2
  fi

  # ── parse SARIF -> details, count error/warning levels ───────────────────────
  local DET; DET="$(extract_sarif "$SARIF")"
  local errs warns
  errs="$(count_level "$DET" error)";   errs="${errs:-0}"
  warns="$(count_level "$DET" warning)"; warns="${warns:-0}"
  # SARIF "note" rolls into the informational warning bucket for the report total.
  local notes; notes="$(count_level "$DET" note)"; notes="${notes:-0}"
  warns=$(( warns + notes ))

  # ── verdict (WARNING-FIRST: error-level findings WARN by default, HARD only via WALTEUR_OPENGREP=hard) ─
  if [ "$errs" -gt 0 ]; then
    if [ "$MODE" = "hard" ]; then
      write_report "FAIL" "$errs error-level taint finding(s) (armed HARD: WALTEUR_OPENGREP=hard)" "$source" "$config" "$errs" "$warns" "$DET"
      echo "WALTEUR opengrep-gate: FAIL — $errs error-level taint finding(s) [armed HARD]." >&2
      print_findings "$DET"
      exit 2
    fi
    write_report "WARN" "$errs error-level taint finding(s) (WARNING-FIRST, non-blocking; set WALTEUR_OPENGREP=hard to block)" "$source" "$config" "$errs" "$warns" "$DET"
    echo "WALTEUR opengrep-gate: WARN — $errs error-level taint finding(s) (WARNING-FIRST, non-blocking). Set WALTEUR_OPENGREP=hard to make this block (exit 2)." >&2
    print_findings "$DET"
    exit 0
  fi

  if [ "$warns" -gt 0 ]; then
    write_report "PASS" "no error-level taint finding; $warns informational warning/note(s) recorded (non-blocking)" "$source" "$config" 0 "$warns" "$DET"
    echo "WALTEUR opengrep-gate: PASS (no error-level taint) — $warns informational finding(s) recorded -> $REPORT" >&2
    exit 0
  fi

  write_report "PASS" "no taint/security finding for the ruleset we ran (NOT a clean bill of health)" "$source" "$config" 0 0 '[]'
  echo "WALTEUR opengrep-gate: PASS — no taint/security finding (config: $config). (Not a clean bill of health: only proves THIS ruleset found no source->sink path.)" >&2
  exit 0
}

# pretty-print details to stderr. $1 = details-json-array
print_findings() {
  local det="$1"
  if have jq; then
    printf '%s' "$det" | jq -r '.[] | select(.level=="error") | "  TAINT  \(.ruleId)  \(.file):\(.line)  -> \(.message)"' >&2 2>/dev/null || true
  else
    printf '%s' "$det" | grep -o '"ruleId":"[^"]*"' | sed 's/^/  TAINT  /' >&2 2>/dev/null || true
  fi
}

# ── embedded self-test (GOOD + POISON twins; hermetic, OFFLINE via OPENGREP_SARIF) ──────────
# Proves BOTH paths the build laws require: (1) the LOUD-SKIP path when the binary is absent, and (2) the
# SARIF parse/verdict logic — without ever needing opengrep installed.
selftest() {
  local fails=0 total=0 tmp rc

  run_one() { # $1=label $2=want-rc $3=setup-fn (writes into $tmp; sets SELF_SARIF/SELF_MODE)
    total=$((total+1))
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/opengrep-gate-selftest.XXXXXX")" || {
      echo "  FAIL — $1 (mktemp could not create a temp dir)"; fails=$((fails+1)); return; }
    mkdir -p "$tmp/walteur-kit" "$tmp/src"
    SELF_SARIF=""; SELF_MODE="on"
    "$3" "$tmp"   # setup writes fixtures into $tmp and may set SELF_SARIF/SELF_MODE
    set +e
    # Clean env so a stray OPENGREP_*/WALTEUR_OPENGREP from the caller cannot leak into a twin. When no
    # fixture is set, point OPENGREP_BIN at a name that does NOT exist so the no-binary LOUD-SKIP path is
    # DETERMINISTIC regardless of whether a real opengrep is installed on this machine.
    local og_env=()
    if [ -n "$SELF_SARIF" ]; then
      og_env=( "OPENGREP_SARIF=$SELF_SARIF" )
    else
      og_env=( "OPENGREP_BIN=opengrep-does-not-exist-$$" )
    fi
    env -i PATH="$PATH" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
        WALTEUR_ROOT="$tmp" WALTEUR_OPENGREP="$SELF_MODE" "${og_env[@]}" \
        bash "$SELF" >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq "$2" ]; then echo "  ok   — $1 (rc=$rc)"; else echo "  FAIL — $1 (rc=$rc, want $2)"; fails=$((fails+1)); fi
    rm -rf "$tmp"
  }

  # also assert the REPORT verdict for a couple of twins (parse correctness, not just exit code).
  report_verdict() { # $1=tmp -> echoes verdict field
    local rep="$1/walteur-kit/opengrep-report.json"
    if command -v jq >/dev/null 2>&1; then jq -r '.verdict // ""' "$rep" 2>/dev/null
    else grep -o '"verdict":"[^"]*"' "$rep" 2>/dev/null | head -1 | sed -E 's/.*:"([^"]*)".*/\1/'; fi
  }

  # GOOD twin — SARIF has results but ALL are warning/note (no error-level taint) => PASS (exit 0).
  good_setup() {
    cat > "$1/walteur-kit/og-good.json" <<'JSON'
{ "version": "2.1.0",
  "runs": [ { "tool": { "driver": { "name": "opengrep" } },
    "results": [
      { "ruleId": "style.naming", "level": "warning", "message": { "text": "naming nit" },
        "locations": [ { "physicalLocation": { "artifactLocation": { "uri": "src/app.js" }, "region": { "startLine": 12 } } } ] },
      { "ruleId": "info.note", "level": "note", "message": { "text": "fyi" },
        "locations": [ { "physicalLocation": { "artifactLocation": { "uri": "src/app.js" }, "region": { "startLine": 20 } } } ] }
    ] } ] }
JSON
    SELF_SARIF="$1/walteur-kit/og-good.json"
  }

  # POISON twin — SARIF contains an error-level TAINT result (source->sink) => WARN, exit 0 by default.
  poison_setup() {
    cat > "$1/walteur-kit/og-poison.json" <<'JSON'
{ "version": "2.1.0",
  "runs": [ { "tool": { "driver": { "name": "opengrep" } },
    "results": [
      { "ruleId": "taint.command-injection", "level": "error",
        "message": { "text": "user input from req.query.cmd reaches child_process.exec (command injection)" },
        "locations": [ { "physicalLocation": { "artifactLocation": { "uri": "src/handler.js" }, "region": { "startLine": 42 } } } ] }
    ] } ] }
JSON
    SELF_SARIF="$1/walteur-kit/og-poison.json"
  }

  # SAME POISON twin armed HARD via WALTEUR_OPENGREP=hard => CAUGHT (exit 2).
  poison_hard_setup() { poison_setup "$1"; SELF_MODE="hard"; }

  # CLEAN twin — empty results array => PASS (exit 0).
  clean_setup() {
    cat > "$1/walteur-kit/og-clean.json" <<'JSON'
{ "version": "2.1.0", "runs": [ { "tool": { "driver": { "name": "opengrep" } }, "results": [] } ] }
JSON
    SELF_SARIF="$1/walteur-kit/og-clean.json"
  }

  # NO fixture + binary ABSENT (forced) => LOUD SKIP (exit 0). This is the real-world default path.
  noskip_setup() { printf 'console.log("x")\n' > "$1/src/app.js"; }   # SELF_SARIF intentionally unset

  # NO fixture + binary ABSENT + WALTEUR_OPENGREP=hard => fail-closed (exit 2).
  hardskip_setup() { printf 'console.log("x")\n' > "$1/src/app.js"; SELF_MODE="hard"; }

  echo "opengrep-gate selftest (taint, WARNING-FIRST; hermetic, binary-absent-safe):"
  run_one "GOOD twin: only warning/note levels -> PASS"                 0 good_setup
  run_one "POISON twin: error-level taint -> WARN (non-blocking)"       0 poison_setup
  run_one "POISON twin + WALTEUR_OPENGREP=hard -> CAUGHT (exit 2)"      2 poison_hard_setup
  run_one "CLEAN twin: empty results -> PASS"                           0 clean_setup
  run_one "no fixture + opengrep ABSENT -> LOUD SKIP"                   0 noskip_setup
  run_one "no fixture + ABSENT + hard -> fail-closed"                   2 hardskip_setup

  # ── explicit verdict-string assertions (proves the PARSE, not just the exit code) ──
  echo "opengrep-gate selftest (verdict-string assertions):"
  _verdict_check() { # $1=label $2=want-verdict $3=setup-fn
    total=$((total+1))
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/opengrep-gate-vchk.XXXXXX")"
    mkdir -p "$tmp/walteur-kit" "$tmp/src"
    SELF_SARIF=""; SELF_MODE="on"; "$3" "$tmp"
    set +e
    env -i PATH="$PATH" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
        WALTEUR_ROOT="$tmp" WALTEUR_OPENGREP="$SELF_MODE" "OPENGREP_SARIF=$SELF_SARIF" \
        bash "$SELF" >/dev/null 2>&1
    set -e
    local got; got="$(report_verdict "$tmp")"
    if [ "$got" = "$2" ]; then echo "  ok   — $1 (verdict=$got)"; else echo "  FAIL — $1 (verdict=$got, want $2)"; fails=$((fails+1)); fi
    rm -rf "$tmp"
  }
  _verdict_check "POISON (warn-first) -> verdict WARN" "WARN" poison_setup
  _verdict_check "GOOD                -> verdict PASS" "PASS" good_setup

  echo "opengrep-gate selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi
run_gate
