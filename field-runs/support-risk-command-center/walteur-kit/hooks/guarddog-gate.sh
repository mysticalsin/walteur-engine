#!/usr/bin/env bash
# WALTEUR guarddog-gate — novel / unindexed-malware supply-chain gate (pillar P13, EGRESS companion to osv-gate).
# BEFORE a new dependency (or a candidate MCP server published as a package) is enabled, run DataDog/guarddog
# (Semgrep source-code rules + package-metadata heuristics) over the candidate manifests / source and WARN on
# any heuristic hit — a fresh typosquat / install-time code-exec / data-exfil package that OSV has NOT indexed.
# Closes the gap osv-gate cannot: osv-gate fires ONLY on a MAL-* / database_specific.malicious advisory that
# the OSV database already KNOWS about; guarddog catches the brand-new malicious package BEFORE any advisory
# exists (left-of-CVE / left-of-advisory detection).
#
# HONESTY BOUNDARY (load-bearing — do not erode):
#   * WARNING-FIRST: a guarddog heuristic hit (issues>0) is reported as a LOUD WARN and the gate exits 0 by
#     DEFAULT — it does NOT block. HARD (exit 2) ONLY when WALTEUR_GUARDDOG=hard is set. New gate, opt-in teeth.
#   * A heuristic hit is a SIGNAL, not a proven verdict: guarddog's rules are high-signal but can false-positive
#     (a legit install-script, a legit network call). Hence warning-first — a human / a hard-mode opt-in decides.
#   * A PASS means "guarddog ran and flagged nothing for the candidates we scanned" — it does NOT prove the deps
#     are safe (a sufficiently novel payload evades the heuristics). Absence of a hit = NOT-FOUND, never PROVEN-SAFE.
#   * guarddog ABSENT => LOUD SKIP exit 0 (recorded, never silent-green, never exit 2 for a missing tool).
#     A LOUD SKIP is honest: "we could not check", never a false green. (Even hard-mode loud-skips on absence —
#     a missing TOOL is not a malicious-package finding; only a real heuristic hit is hard-blockable.)
#
# Candidate detection (whatever is present under ROOT — guarddog VERIFIES the manifest's declared deps):
#   - package.json      -> guarddog npm verify <package.json>        (ecosystem npm)
#   - requirements.txt  -> guarddog pypi verify <requirements.txt>   (ecosystem pypi)
#   No manifest under ROOT (and no explicit candidate list) => NOT_APPLICABLE (exit 0).
#   guarddog also supports `scan <dir>` over source, but VERIFY over the declared dependency set is the
#   dependency-surface contract here (mirrors osv-gate: we gate the deps you PULL IN, version-pinned).
#
# Tool contract (SANDBOX-SAFE — the guarddog path is REAL but guarded):
#   GUARDDOG_FIXTURE=/path/to/output.json  -> use that file AS guarddog's JSON output (NO subprocess). selftest path.
#   GUARDDOG_BIN=/path/to/guarddog         -> override the binary path (still a real exec).
#   Neither override + guarddog present     -> real `guarddog <eco> verify --output-format=json <manifest>`.
#   guarddog ABSENT (and no fixture)        -> LOUD SKIP exit 0 (recorded).
# guarddog's JSON output carries an integer "issues" count (and a per-rule "results" map); issues>0 == a hit.
# The `verify` form emits a JSON ARRAY (one object per scanned dependency); we sum "issues" across the array.
# Bypass: WALTEUR_GUARDDOG=off => recorded SKIP, exit 0.   Kill switch: walteur-kit/PAUSED present => exit 2.
# Self-test: bash walteur-kit/hooks/guarddog-gate.sh --selftest  (HERMETIC, OFFLINE — driven by GUARDDOG_FIXTURE;
#   PASSES whether or not guarddog is installed — it tests the LOUD-SKIP path AND the issues-parse logic).
# Zero-dep floor: bash + grep + awk + sed + find. jq used for the report/parse WHEN PRESENT (grep fallback).
# Pin: guarddog >= 3.0 (the v3 line; `verify --output-format=json` contract). Output is treated as DATA, not code.
# Report: walteur-kit/guarddog-report.json {verdict, ts, gate, mode, source, ecosystems, scanned, issues, hits[], reason}.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/guarddog-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MODE="${WALTEUR_GUARDDOG:-on}"
GUARDDOG_BIN="${GUARDDOG_BIN:-guarddog}"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# write_report <verdict> <reason> <source> <ecosystems-csv> <scanned-int> <issues-int> <hits-json-array>
write_report() {
  local v="$1" reason="$2" source="$3" ecos="$4" scanned="$5" issues="${6:-0}" hits="${7:-[]}"
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --arg mode "$MODE" --arg reason "$reason" \
          --arg source "$source" --arg ecos "$ecos" --argjson scanned "${scanned:-0}" \
          --argjson issues "${issues:-0}" --argjson hits "$hits" \
      '{verdict:$v, ts:$ts, gate:"guarddog", mode:$mode, source:$source,
        ecosystems:($ecos|split(",")|map(select(length>0))), scanned:$scanned,
        issues:$issues, hits:$hits, reason:$reason}' > "$REPORT"
  else
    # jq is NOT in the mandated zero-dep set; emit valid minimal JSON without it.
    local ecos_json="[]"
    [ -n "$ecos" ] && ecos_json="$(printf '%s' "$ecos" | awk -F, '{out="["; for(i=1;i<=NF;i++){if($i!=""){out=out (i>1?",":"") "\"" $i "\""}} out=out "]"; print out}')"
    printf '{"verdict":"%s","ts":"%s","gate":"guarddog","mode":"%s","source":"%s","ecosystems":%s,"scanned":%s,"issues":%s,"hits":%s,"reason":"%s"}\n' \
      "$v" "$TS" "$MODE" "$source" "$ecos_json" "${scanned:-0}" "${issues:-0}" "$hits" "$reason" > "$REPORT"
  fi
}

run_gate() {
  # ── kill switch ────────────────────────────────────────────────────────────
  [ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }

  # ── bypass ─────────────────────────────────────────────────────────────────
  if [ "$MODE" = "off" ]; then
    echo "WALTEUR guarddog-gate SKIP — bypass WALTEUR_GUARDDOG=off (recorded, not silent-green)." >&2
    write_report "SKIP" "bypass WALTEUR_GUARDDOG=off" "bypass" "" 0 0 '[]'; exit 0
  fi

  # ── base-tool guard (zero-dep floor for manifest detection / parse) ──────────
  for t in grep awk sed find; do
    if ! have "$t"; then
      echo "WALTEUR guarddog-gate SKIP — required base tool '$t' not installed (recorded, not silent-green)." >&2
      write_report "SKIP" "$t not installed" "tool-missing" "" 0 0 '[]'; exit 0
    fi
  done

  # ── 1. detect candidate manifests -> "$ecosystem<TAB>manifest-path" per line ──
  local MANS; MANS="$(detect_manifests)"
  local n; n="$(printf '%s\n' "$MANS" | grep -cve '^[[:space:]]*$' 2>/dev/null)"; n="${n:-0}"
  local ecos; ecos="$(printf '%s\n' "$MANS" | awk -F'\t' 'NF>=1 && $1!=""{print $1}' | sort -u | paste -sd, - 2>/dev/null)"
  ecos="${ecos:-}"

  if [ "$n" -eq 0 ]; then
    echo "WALTEUR guarddog-gate NOT_APPLICABLE — no candidate manifest (package.json / requirements.txt) under ROOT." >&2
    write_report "NOT_APPLICABLE" "no candidate manifest to scan" "none" "" 0 0 '[]'
    exit 0
  fi

  # ── 2. obtain guarddog JSON (fixture | real guarddog | LOUD SKIP on absence) ──
  local RESP source
  if [ -n "${GUARDDOG_FIXTURE:-}" ]; then
    if [ ! -f "$GUARDDOG_FIXTURE" ]; then
      echo "WALTEUR guarddog-gate SKIP — GUARDDOG_FIXTURE='$GUARDDOG_FIXTURE' not a file (recorded, not silent-green)." >&2
      write_report "SKIP" "GUARDDOG_FIXTURE not found: $GUARDDOG_FIXTURE" "fixture-missing" "$ecos" "$n" 0 '[]'; exit 0
    fi
    RESP="$(cat "$GUARDDOG_FIXTURE")"
    source="fixture:$GUARDDOG_FIXTURE"
    echo "WALTEUR guarddog-gate — using GUARDDOG_FIXTURE (offline): $GUARDDOG_FIXTURE" >&2
  else
    if ! have "$GUARDDOG_BIN"; then
      # detect-or-LOUD-SKIP: a missing TOOL is never a finding and never a hard fail — loud-skip even in hard mode.
      echo "WALTEUR guarddog-gate SKIP — '$GUARDDOG_BIN' not installed (recorded, not silent-green; pip install 'guarddog>=3.0', or set GUARDDOG_FIXTURE to verify offline)." >&2
      write_report "SKIP" "guarddog not installed" "tool-missing" "$ecos" "$n" 0 '[]'; exit 0
    fi
    # real exec — one `guarddog <eco> verify --output-format=json <manifest>` per manifest, JSON concatenated.
    RESP="$(run_guarddog "$MANS")"
    if [ -z "$RESP" ]; then
      echo "WALTEUR guarddog-gate SKIP — guarddog produced no output (recorded, not silent-green)." >&2
      write_report "SKIP" "guarddog produced empty output" "guarddog-empty" "$ecos" "$n" 0 '[]'; exit 0
    fi
    source="guarddog:$GUARDDOG_BIN"
    echo "WALTEUR guarddog-gate — ran guarddog over $n manifest(s) [$ecos]." >&2
  fi

  # ── 3. parse: total issues + per-rule hits ───────────────────────────────────
  local issues hits
  issues="$(extract_issue_count "$RESP")"; issues="${issues:-0}"
  hits="$(extract_hits "$RESP")"

  if [ "$issues" -gt 0 ]; then
    if [ "$MODE" = "hard" ]; then
      write_report "FAIL" "$issues guarddog heuristic hit(s) on candidate deps [HARD mode]" "$source" "$ecos" "$n" "$issues" "$hits"
      echo "WALTEUR guarddog-gate: FAIL — $issues guarddog heuristic hit(s) on candidate deps [HARD: WALTEUR_GUARDDOG=hard]. DO NOT enable these." >&2
      emit_hits "$hits"
      exit 2
    else
      write_report "WARN" "$issues guarddog heuristic hit(s) on candidate deps (warning-first; set WALTEUR_GUARDDOG=hard to block)" "$source" "$ecos" "$n" "$issues" "$hits"
      echo "WALTEUR guarddog-gate: WARN — $issues guarddog heuristic hit(s) on candidate deps (typosquat / install-exec / exfil signal). Warning-first: NOT blocking. Set WALTEUR_GUARDDOG=hard to block." >&2
      emit_hits "$hits"
      exit 0
    fi
  fi

  write_report "PASS" "guarddog flagged no heuristic hits for $n manifest(s); not a clean bill of health (a novel payload can evade heuristics)" "$source" "$ecos" "$n" 0 '[]'
  echo "WALTEUR guarddog-gate: PASS — guarddog flagged nothing for $n manifest(s) [$ecos]. (Not proof of safety: a sufficiently novel payload can evade the heuristics.)" >&2
  exit 0
}

# print the per-rule hits (jq when present; grep fallback) to stderr.
emit_hits() { # $1 = hits json array
  local hits="$1"
  if have jq; then
    printf '%s' "$hits" | jq -r '.[] | "  HEURISTIC  \(.ecosystem)/\(.package)  rule=\(.rule)  -> \(.detail)"' >&2 2>/dev/null || true
  else
    printf '%s' "$hits" | grep -o '"rule":"[^"]*"' | sed 's/^/  HEURISTIC  /' >&2 2>/dev/null || true
  fi
}

# ── manifest detection. Emit "ecosystem<TAB>path" (npm|pypi). Explicit override list wins by union. ──
detect_manifests() {
  # explicit override: "ecosystem<space>path" lines (for an MCP server's manifest at a non-standard path).
  local cfile="$KIT/guarddog-candidates.txt"
  if [ -f "$cfile" ]; then
    awk '
      { sub(/#.*$/,""); gsub(/^[ \t]+|[ \t]+$/,"") }
      $0=="" { next }
      { e=$1; p=$2; if(e!="" && p!="") printf "%s\t%s\n", e, p }
    ' "$cfile"
  fi
  # package.json -> npm
  while IFS= read -r m; do [ -n "$m" ] && printf 'npm\t%s\n' "$m"; done < <(_find_manifests 'package.json')
  # requirements*.txt -> pypi
  while IFS= read -r m; do [ -n "$m" ] && printf 'pypi\t%s\n' "$m"; done < <(_find_manifests 'requirements*.txt')
}

# find manifests under ROOT, pruning the usual non-source dirs (and walteur-kit itself).
_find_manifests() { # $1 = -name glob
  find "$ROOT" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/vendor' -o -path '*/dist' \
       -o -path '*/build' -o -path '*/.next' -o -path '*/target' -o -path '*/__pycache__' \
       -o -path '*/.venv' -o -path '*/venv' -o -path '*/walteur-kit' \) -prune -o \
    -type f -name "$1" -print 2>/dev/null
}

# run guarddog verify over each manifest; concatenate the JSON outputs (one doc per manifest).
run_guarddog() { # $1 = manifests ("eco<TAB>path" lines)
  local mans="$1" eco path
  while IFS=$'\t' read -r eco path; do
    [ -z "$eco" ] && continue
    [ -f "$path" ] || continue
    # guarddog <ecosystem> verify --output-format=json <manifest>. Output is DATA. Errors -> empty, skipped.
    "$GUARDDOG_BIN" "$eco" verify --output-format=json "$path" 2>/dev/null || true
  done <<EOF
$mans
EOF
}

# extract the TOTAL "issues" integer across guarddog's output.
# guarddog `verify` emits a JSON array (one object per dep), each with an integer "issues"; `scan` emits a
# single object with "issues". We concatenate per-manifest docs, so flatten arrays + objects and SUM "issues".
extract_issue_count() { # $1 = response (concatenated guarddog JSON docs)
  local resp="$1"
  if have jq; then
    # -s slurps every concatenated doc into one stream; flatten array docs; sum each doc's .issues.
    printf '%s' "$resp" | jq -s '[ .[] | if type=="array" then .[] else . end | (.issues // 0) ] | add // 0' 2>/dev/null || echo 0
  else
    # zero-dep floor: sum every  "issues": <int>  occurrence. HONEST and mechanical — catches issues>0.
    printf '%s' "$resp" | grep -oE '"issues"[ \t]*:[ \t]*[0-9]+' | grep -oE '[0-9]+' \
      | awk '{s+=$1} END{print s+0}'
  fi
}

# extract per-rule hits as a JSON array of {ecosystem, package, rule, detail} (best-effort; fields may be "").
extract_hits() { # $1 = response
  local resp="$1"
  if have jq; then
    printf '%s' "$resp" | jq -c '
      [ ( . as $root | (if type=="array" then .[] else . end) )
        | select((.issues // 0) > 0)
        | .package as $pkg
        | (.results // {}) | to_entries[]
        | select(.value != null and (.value | length) > 0)
        | { ecosystem: "",
            package: ($pkg // ""),
            rule: (.key // ""),
            detail: ( .value
                      | if type=="array" then (.[0] | (.message? // .description? // (tostring)))
                        elif type=="string" then .
                        else tostring end ) } ]
    ' 2>/dev/null || echo '[]'
  else
    # zero-dep floor: list the matched rule names from the "results" object keys is non-trivial without a
    # parser; instead surface the package identifiers and a generic detail. Coarser but HONEST — the WARN/FAIL
    # decision is driven by the issues count above; this only enriches the report.
    local pkgs out first=1 p
    pkgs="$(printf '%s' "$resp" | grep -oE '"package"[ \t]*:[ \t]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/' | sort -u)"
    out="["
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      [ "$first" -eq 1 ] && first=0 || out="$out,"
      out="$out{\"ecosystem\":\"\",\"package\":\"$p\",\"rule\":\"(see guarddog output)\",\"detail\":\"heuristic hit\"}"
    done <<EOF
$pkgs
EOF
    echo "$out]"
  fi
}

# ── embedded self-test (GOOD + POISON twins; hermetic, OFFLINE via GUARDDOG_FIXTURE) ──────────
selftest() {
  local fails=0 total=0 tmp rc
  local SELF; SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  run_one() { # $1=label $2=want-rc $3=setup-fn (sets up $tmp, may set SELF_FIXTURE/SELF_MODE)
    total=$((total+1))
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/guarddog-gate-selftest.XXXXXX")" || {
      echo "  FAIL — $1 (mktemp could not create a temp dir)"; fails=$((fails+1)); return; }
    mkdir -p "$tmp/walteur-kit" "$tmp/src"
    SELF_FIXTURE=""; SELF_MODE="on"
    "$3" "$tmp"   # setup writes manifests/fixtures into $tmp and may set SELF_FIXTURE/SELF_MODE
    set +e
    # Clean env so a stray GUARDDOG_* from the caller cannot leak into a twin. When no fixture is set, point
    # GUARDDOG_BIN at a definitely-absent binary so the LOUD-SKIP path is DETERMINISTIC offline.
    local gd_env=()
    if [ -n "$SELF_FIXTURE" ]; then
      gd_env=( "GUARDDOG_FIXTURE=$SELF_FIXTURE" )
    else
      gd_env=( "GUARDDOG_BIN=guarddog-gate-absent-$$.invalid" )
    fi
    env -i PATH="$PATH" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
        WALTEUR_ROOT="$tmp" WALTEUR_GUARDDOG="$SELF_MODE" "${gd_env[@]}" \
        bash "$SELF" >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq "$2" ]; then echo "  ok   — $1 (rc=$rc)"; else echo "  FAIL — $1 (rc=$rc, want $2)"; fails=$((fails+1)); fi
    rm -rf "$tmp"
  }

  # a candidate manifest common to the scan-shaped twins.
  _write_pkg() { printf '{\n "name":"demo",\n "dependencies":{ "left-pad":"1.3.0", "express":"^4.18.0" }\n}\n' > "$1/package.json"; }
  _write_req() { printf 'requests==2.31.0\nflask>=2.0\n' > "$1/requirements.txt"; }

  # GOOD twin — guarddog ran and flagged nothing (issues:0) => PASS (exit 0). (clean fixture)
  good_setup() {
    _write_pkg "$1"
    cat > "$1/walteur-kit/gd-good.json" <<'JSON'
[ { "package": "left-pad", "issues": 0, "results": {} },
  { "package": "express",  "issues": 0, "results": {} } ]
JSON
    SELF_FIXTURE="$1/walteur-kit/gd-good.json"
  }

  # POISON twin — install-exec + exfil heuristic hit (issues>0), DEFAULT mode => WARN, exit 0 (warning-first).
  poison_warn_setup() {
    _write_pkg "$1"
    cat > "$1/walteur-kit/gd-poison.json" <<'JSON'
[ { "package": "left-pad", "issues": 0, "results": {} },
  { "package": "evil-dep", "issues": 2,
    "results": { "code-execution": ["executes shell during install"],
                 "exfiltrate-sensitive-data": ["posts env vars to remote host"] } } ]
JSON
    SELF_FIXTURE="$1/walteur-kit/gd-poison.json"
  }

  # POISON twin (SAME fixture) but WALTEUR_GUARDDOG=hard => CAUGHT, exit 2 (the opt-in teeth).
  poison_hard_setup() {
    _write_pkg "$1"
    cat > "$1/walteur-kit/gd-poison.json" <<'JSON'
[ { "package": "evil-dep", "issues": 2,
    "results": { "code-execution": ["executes shell during install"],
                 "exfiltrate-sensitive-data": ["posts env vars to remote host"] } } ]
JSON
    SELF_FIXTURE="$1/walteur-kit/gd-poison.json"
    SELF_MODE="hard"
  }

  # POISON twin: a single-object `scan`-shaped doc (not an array) with issues>0, hard => CAUGHT (exit 2).
  poison_scanshape_setup() {
    _write_req "$1"
    cat > "$1/walteur-kit/gd-scan.json" <<'JSON'
{ "package": "typosquat-pkg", "issues": 1,
  "results": { "typosquatting": ["similar to popular package 'requests'"] } }
JSON
    SELF_FIXTURE="$1/walteur-kit/gd-scan.json"
    SELF_MODE="hard"
  }

  # explicit candidate list (MCP-server-as-package manifest at a non-standard path) + hit fixture, hard => CAUGHT.
  mcp_candidate_setup() {
    mkdir -p "$1/mcp"
    printf '{\n "name":"@evil/mcp-server",\n "dependencies":{ "left-pad":"1.3.0" }\n}\n' > "$1/mcp/package.json"
    printf 'npm %s/mcp/package.json\n' "$1" > "$1/walteur-kit/guarddog-candidates.txt"
    cat > "$1/walteur-kit/gd-mcp.json" <<'JSON'
[ { "package": "@evil/mcp-server", "issues": 1,
    "results": { "download-executable": ["downloads and runs a remote binary on install"] } } ]
JSON
    SELF_FIXTURE="$1/walteur-kit/gd-mcp.json"
    SELF_MODE="hard"
  }

  # NO manifest at all => NOT_APPLICABLE (exit 0).
  none_setup() { printf 'print("cli")\n' > "$1/src/main.py"; }   # .py source != a manifest; nothing to verify

  # guarddog ABSENT (no fixture) + manifest present + DEFAULT => LOUD SKIP (exit 0).
  skip_setup() { _write_pkg "$1"; }   # SELF_FIXTURE unset => harness points GUARDDOG_BIN at an absent binary

  # guarddog ABSENT + manifest present + HARD => STILL a LOUD SKIP (a missing tool is not a finding) exit 0.
  skip_hard_setup() { _write_pkg "$1"; SELF_MODE="hard"; }   # no fixture, hard mode -> must NOT exit 2 on absence

  # bypass: WALTEUR_GUARDDOG=off => recorded SKIP, exit 0 (even with a poison fixture present).
  off_setup() {
    _write_pkg "$1"
    cat > "$1/walteur-kit/gd-poison.json" <<'JSON'
[ { "package": "evil-dep", "issues": 9, "results": { "code-execution": ["x"] } } ]
JSON
    SELF_FIXTURE="$1/walteur-kit/gd-poison.json"
    SELF_MODE="off"
  }

  echo "guarddog-gate selftest:"
  run_one "GOOD twin: clean (issues:0) -> PASS"                          0 good_setup
  run_one "POISON twin: install-exec+exfil, default -> WARN (exit 0)"    0 poison_warn_setup
  run_one "POISON twin: SAME hit + WALTEUR_GUARDDOG=hard -> CAUGHT"      2 poison_hard_setup
  run_one "POISON twin: scan-shaped doc + hard -> CAUGHT"               2 poison_scanshape_setup
  run_one "explicit MCP candidate + hit fixture + hard -> CAUGHT"       2 mcp_candidate_setup
  run_one "no manifest (CLI .py only) -> NOT_APPLICABLE"                0 none_setup
  run_one "guarddog absent + manifest, default -> LOUD SKIP"            0 skip_setup
  run_one "guarddog absent + manifest, HARD -> LOUD SKIP (not exit 2)"  0 skip_hard_setup
  run_one "bypass WALTEUR_GUARDDOG=off -> SKIP"                          0 off_setup
  echo "guarddog-gate selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi
run_gate
