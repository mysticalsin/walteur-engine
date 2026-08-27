#!/usr/bin/env bash
# WALTEUR osv-gate — supply-chain malicious-package gate (pillar P-OSV).
# BEFORE a new dependency or a candidate MCP server is enabled, query the OSV.dev free public REST
# API (querybatch) for the candidate set and FAIL CLOSED (exit 2) on a MAL-* malicious-package advisory.
# Closes the gap P04/gitleaks (secrets) does not cover: gitleaks catches secrets you LEAK; this catches
# a poisoned dep you PULL IN.
#
# HONESTY BOUNDARY (load-bearing — do not erode):
#   * HARD: a MAL-* (or otherwise-malicious-flagged) advisory in the OSV response => exit 2. Mechanical:
#     the advisory id either starts with "MAL-" or carries database_specific.malicious=true. No judgment.
#   * NOT a clean bill of health: a PASS means "no MALICIOUS advisory for the candidates we queried at
#     this version pin" — it does NOT prove the deps are safe, current, or free of ordinary CVEs (those
#     are GHSA-/CVE- ids, deliberately NOT hard-blocked here — vuln-triage is PROTOCOL, a separate gate).
#   * Absence of an advisory = NOT-FOUND, never PROVEN-SAFE. A LOUD SKIP (no network/curl) is honest:
#     "we could not check", never silent-green.
#
# Candidate collection (whatever is present under ROOT, union of):
#   - package.json            -> .dependencies + .devDependencies            (ecosystem npm)
#   - requirements.txt        -> name[==version] lines                        (ecosystem PyPI)
#   - pyproject.toml          -> [project].dependencies / [tool.poetry...]    (ecosystem PyPI)
#   - Cargo.toml              -> [dependencies] / [dev-dependencies]          (ecosystem crates.io)
#   - go.mod                  -> require (...) module paths                   (ecosystem Go)
#   - walteur-kit/osv-candidates.txt -> newline list "ecosystem name [version]" (explicit override; for
#                                MCP servers published as packages, or any dep not in a manifest)
#
# Network contract (SANDBOX-SAFE — the curl path is REAL but guarded):
#   * OSV_FIXTURE=/path/to/response.json  -> use that file AS the OSV response (NO network). selftest path.
#   * OSV_ENDPOINT=https://host/v1/querybatch -> override the endpoint (still real curl).
#   * Neither override + curl present + network reachable -> real POST to OSV_DEFAULT_ENDPOINT.
#   * curl ABSENT, or endpoint unreachable -> LOUD SKIP exit 0 (recorded) UNLESS WALTEUR_OSV=strict
#     (then a can't-check on a candidate set is itself a fail-closed posture => exit 2).
# Bypass: WALTEUR_OSV=off => recorded SKIP, exit 0.   Kill switch: walteur-kit/PAUSED present => exit 2.
# Self-test: bash walteur-kit/hooks/osv-gate.sh --selftest   (HERMETIC, OFFLINE — driven by OSV_FIXTURE).
# Zero-dep floor: bash + grep + awk + sed + curl. jq used for the report WHEN PRESENT (printf fallback).
# Report: walteur-kit/osv-report.json {verdict, ts, gate, mode, source, ecosystems, queried, malicious[], reason}.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "osv-gate - supply-chain malicious-package gate (pillar P-OSV)."
  printf '%s\n' "usage: bash osv-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/osv-report.json - fix recipes: walteur-kit/REMEDIATION.md (## osv-gate)"
  printf '%s\n' "bypass: WALTEUR_OSV=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/osv-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MODE="${WALTEUR_OSV:-on}"
# Honor the global ship-time strict toggle: ship-gate exports WALTEUR_TOOLGATE_STRICT=1 on a real ship, and a
# "cannot verify OSV" (curl absent / endpoint unreachable, no fixture) must then FAIL closed, not loud-skip to
# exit 0 — an unscanned dependency set cannot ride a certified ship. Only the DEFAULT "on" escalates; an explicit
# WALTEUR_OSV=off (bypass) or WALTEUR_OSV=strict is left as-is. Mirrors security-scan-gate.sh precedence.
if [ "$MODE" = "on" ] && [ "${WALTEUR_TOOLGATE_STRICT:-0}" = "1" ]; then MODE="strict"; fi
OSV_DEFAULT_ENDPOINT="https://api.osv.dev/v1/querybatch"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# write_report <verdict> <reason> <source> <ecosystems-csv> <queried-int> <malicious-json-array>
write_report() {
  local v="$1" reason="$2" source="$3" ecos="$4" queried="$5" mal="${6:-[]}"
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --arg mode "$MODE" --arg reason "$reason" \
          --arg source "$source" --arg ecos "$ecos" --argjson queried "${queried:-0}" --argjson mal "$mal" \
      '{verdict:$v, ts:$ts, gate:"osv", mode:$mode, source:$source,
        ecosystems:($ecos|split(",")|map(select(length>0))), queried:$queried,
        malicious:$mal, reason:$reason}' > "$REPORT"
  else
    # jq is NOT in the mandated zero-dep set; emit valid minimal JSON without it.
    local ecos_json="[]"
    [ -n "$ecos" ] && ecos_json="$(printf '%s' "$ecos" | awk -F, '{out="["; for(i=1;i<=NF;i++){if($i!=""){out=out (i>1?",":"") "\"" $i "\""}} out=out "]"; print out}')"
    printf '{"verdict":"%s","ts":"%s","gate":"osv","mode":"%s","source":"%s","ecosystems":%s,"queried":%s,"malicious":%s,"reason":"%s"}\n' \
      "$v" "$TS" "$MODE" "$source" "$ecos_json" "${queried:-0}" "$mal" "$reason" > "$REPORT"
  fi
}

run_gate() {
  # ── kill switch ────────────────────────────────────────────────────────────
  [ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }

  # ── bypass ─────────────────────────────────────────────────────────────────
  if [ "$MODE" = "off" ]; then
    echo "WALTEUR osv-gate SKIP — bypass WALTEUR_OSV=off (recorded, not silent-green)." >&2
    write_report "SKIP" "bypass WALTEUR_OSV=off" "bypass" "" 0 '[]'; exit 0
  fi

  # ── base-tool guard (zero-dep floor for candidate parsing) ───────────────────
  for t in grep awk sed; do
    if ! have "$t"; then
      echo "WALTEUR osv-gate SKIP — required base tool '$t' not installed (recorded, not silent-green)." >&2
      write_report "SKIP" "$t not installed" "tool-missing" "" 0 '[]'; exit 0
    fi
  done

  # ── 1. collect candidates -> $CANDS file, one "ecosystem<TAB>name<TAB>version" per line ──
  CANDS="$(mktemp "${TMPDIR:-/tmp}/osv-cands.XXXXXX")"
  trap 'rm -f "$CANDS"' EXIT
  collect_candidates > "$CANDS"
  local n; n="$(grep -cve '^[[:space:]]*$' "$CANDS" 2>/dev/null)"; n="${n:-0}"
  local ecos; ecos="$(awk -F'\t' 'NF>=1 && $1!=""{print $1}' "$CANDS" | sort -u | paste -sd, - 2>/dev/null)"
  ecos="${ecos:-}"

  if [ "$n" -eq 0 ]; then
    echo "WALTEUR osv-gate NOT_APPLICABLE — no candidate deps found (no manifest, no walteur-kit/osv-candidates.txt)." >&2
    write_report "NOT_APPLICABLE" "no candidate dependencies to query" "none" "" 0 '[]'
    exit 0
  fi

  # ── 2. obtain an OSV response (fixture | real curl | LOUD SKIP) ──────────────
  local RESP source
  if [ -n "${OSV_FIXTURE:-}" ]; then
    if [ ! -f "$OSV_FIXTURE" ]; then
      echo "WALTEUR osv-gate SKIP — OSV_FIXTURE='$OSV_FIXTURE' not a file (recorded, not silent-green)." >&2
      write_report "SKIP" "OSV_FIXTURE not found: $OSV_FIXTURE" "fixture-missing" "$ecos" "$n" '[]'; exit 0
    fi
    RESP="$(cat "$OSV_FIXTURE")"
    source="fixture:$OSV_FIXTURE"
    echo "WALTEUR osv-gate — using OSV_FIXTURE (offline): $OSV_FIXTURE" >&2
  else
    # real network path — guarded. curl absent OR endpoint unreachable => LOUD SKIP (unless strict).
    if ! have curl; then
      _net_unavailable "curl not installed" "$ecos" "$n"; return
    fi
    local endpoint="${OSV_ENDPOINT:-$OSV_DEFAULT_ENDPOINT}"
    local body; body="$(build_querybatch "$CANDS")"
    # -sS quiet but show errors; --max-time bounds the call; -f makes HTTP>=400 a curl error.
    RESP="$(printf '%s' "$body" | curl -sS -f --max-time 20 \
            -H 'Content-Type: application/json' -X POST --data @- "$endpoint" 2>/dev/null)"
    if [ -z "$RESP" ]; then
      _net_unavailable "OSV endpoint unreachable or empty response ($endpoint)" "$ecos" "$n"; return
    fi
    source="osv:$endpoint"
    echo "WALTEUR osv-gate — queried $endpoint ($n candidate(s))." >&2
  fi

  # ── 2b. malware detection + verifiability (parser-aware; closes the fail-open on EVERY path) ─
  # The hole this is hardened against: a body we CANNOT parse — jq absent (zero-dep floor) OR jq
  # present but the response is corrupt/unparseable — must NEVER be read as "no malware found / clean".
  # A raw byte scan (parser-independent) always backstops for MAL-* ids AND a malicious:true flag;
  # if found => FAIL. If NOT found but we could not VERIFY a clean parse, the verdict is can't-verify
  # (strict => fail-closed, else LOUD SKIP) — never a silent PASS.
  local PARSEABLE="no"
  if have jq && printf '%s' "$RESP" | jq -e . >/dev/null 2>&1; then PARSEABLE="yes"; fi

  local raw_ids raw_flag
  raw_ids="$(printf '%s' "$RESP" | grep -oE '"id"[[:space:]]*:[[:space:]]*"MAL-[^"]*"' \
            | sed -E 's/.*"(MAL-[^"]*)".*/\1/' | sort -u)"
  raw_flag="$(printf '%s' "$RESP" | grep -oE '"malicious"[[:space:]]*:[[:space:]]*true' | head -1 || true)"

  local MAL_JSON mc
  if [ "$PARSEABLE" = "yes" ]; then
    MAL_JSON="$(extract_malicious "$RESP")"
    mc="$(printf '%s' "$MAL_JSON" | jq 'length' 2>/dev/null || echo 0)"
  else
    # no parser / unparseable: rely on the raw backstop (MAL-* ids and/or a malicious:true flag).
    mc=0
    [ -n "$raw_ids" ] && mc="$(printf '%s\n' "$raw_ids" | grep -c .)"
    [ -n "$raw_flag" ] && mc=$((mc + 1))
    MAL_JSON="$(printf '%s\n' "$raw_ids" | awk 'BEGIN{printf"["} NF{if(c++)printf",";printf"{\"id\":\"%s\",\"ecosystem\":\"\",\"package\":\"\",\"summary\":\"malicious package (OSV; raw backstop)\"}",$0} END{printf"]"}')"
    { [ "$MAL_JSON" = "[]" ] && [ -n "$raw_flag" ]; } && MAL_JSON='[{"id":"(malicious:true)","ecosystem":"","package":"","summary":"package flagged malicious=true (OSV; raw backstop)"}]'
  fi
  mc="${mc:-0}"

  if [ "$mc" -gt 0 ]; then
    write_report "FAIL" "$mc malicious-package advisory(ies) found in candidate set" "$source" "$ecos" "$n" "$MAL_JSON"
    echo "WALTEUR osv-gate: FAIL — $mc MALICIOUS advisory(ies) in candidate deps. DO NOT enable these." >&2
    printf '%s' "$MAL_JSON" | { jq -r '.[] | "  MALICIOUS  \(.id)  \(.ecosystem)/\(.package)  -> \(.summary // "malicious package")"' 2>/dev/null \
      || grep -o '"id":"[^"]*"' | sed 's/^/  MALICIOUS  /'; } >&2 2>/dev/null || true
    exit 2
  fi

  # No malware found. If we could NOT verify a clean parse, this is can't-verify — NOT clean.
  if [ "$PARSEABLE" != "yes" ]; then
    local why
    if have jq; then why="OSV response is unparseable (corrupt)"
    else why="jq not installed — cannot parse/verify the OSV response (the zero-dep grep floor catches MAL-* / malicious:true only)"; fi
    if [ "$MODE" = "strict" ]; then
      write_report "FAIL" "strict: $why; cannot verify candidate set (fail-closed)" "$source:unverified" "$ecos" "$n" '[]'
      echo "WALTEUR osv-gate: FAIL (strict) — $why; cannot verify (fail-closed)." >&2
      exit 2
    fi
    write_report "SKIP" "$why; no MAL-* found but cannot confirm clean — recorded, NOT silent-green" "$source:unverified" "$ecos" "$n" '[]'
    echo "WALTEUR osv-gate SKIP — $why; no MAL-* found but cannot confirm clean (recorded, not silent-green; set WALTEUR_OSV=strict to fail-closed)." >&2
    exit 0
  fi

  write_report "PASS" "no malicious (MAL-*) advisory for $n candidate(s); ordinary CVE triage is a separate gate (PROTOCOL)" "$source" "$ecos" "$n" '[]'
  echo "WALTEUR osv-gate: PASS — no MALICIOUS advisory for $n candidate(s) [$ecos]. (Not a clean bill of health: ordinary CVEs are NOT hard-blocked here.)" >&2
  exit 0
}

# LOUD SKIP for the no-network path; strict mode turns can't-check into fail-closed.
_net_unavailable() { # $1=reason $2=ecos $3=n
  if [ "$MODE" = "strict" ]; then
    echo "WALTEUR osv-gate FAIL (strict) — $1; cannot verify candidate set against OSV (fail-closed posture)." >&2
    write_report "FAIL" "strict: cannot verify ($1)" "unreachable-strict" "$2" "$3" '[]'
    exit 2
  fi
  echo "WALTEUR osv-gate SKIP — $1 (recorded, not silent-green; set WALTEUR_OSV=strict to fail-closed, or OSV_FIXTURE to verify offline)." >&2
  write_report "SKIP" "network/tool unavailable: $1" "unreachable" "$2" "$3" '[]'
  exit 0
}

# ── candidate collectors. Emit "ecosystem<TAB>name<TAB>version" (version may be empty). ──
collect_candidates() {
  # explicit override list always wins-by-union: "ecosystem name [version]" (space/comma tolerant, # comments)
  local cfile="$KIT/osv-candidates.txt"
  if [ -f "$cfile" ]; then
    awk '
      { sub(/#.*$/,""); gsub(/^[ \t]+|[ \t]+$/,"") }
      $0=="" { next }
      { e=$1; nm=$2; v=($3==""?"":$3); if(e!="" && nm!="") printf "%s\t%s\t%s\n", e, nm, v }
    ' "$cfile"
  fi

  # package.json (npm) — .dependencies + .devDependencies. jq when present; awk fallback.
  while IFS= read -r pj; do
    [ -z "$pj" ] && continue
    if have jq; then
      jq -r '
        (.dependencies // {}) * (.devDependencies // {}) | to_entries[]
        | "npm\t\(.key)\t\(.value|tostring|gsub("[\\^~>=<* ]";""))"
      ' "$pj" 2>/dev/null
    else
      # zero-dep floor: extract "name":"range" pairs that sit inside a dependencies/devDependencies
      # object. Handles the block opening on the same line as the deps (compact one-line objects) and
      # multi-line blocks. Best-effort — jq is the authoritative path; this keeps coverage when jq absent.
      awk '
        function harvest(s,   m,nm,vr){
          while (match(s, /"[^"]+"[ \t]*:[ \t]*"[^"]*"/)) {
            m=substr(s,RSTART,RLENGTH); s=substr(s,RSTART+RLENGTH)
            nm=m; sub(/"[ \t]*:.*$/,"",nm); gsub(/"/,"",nm)
            vr=m; sub(/^[^:]*:[ \t]*"/,"",vr); sub(/".*$/,"",vr); gsub(/[\^~>=<* ]/,"",vr)
            if(nm!="") printf "npm\t%s\t%s\n", nm, vr
          }
        }
        {
          line=$0
          if (!indep && match(line, /"(dependencies|devDependencies)"[ \t]*:[ \t]*\{/)) {
            indep=1; depth=1
            rest=substr(line, RSTART+RLENGTH)          # text AFTER the opening brace, same line
            # account for braces already on this remainder
            t=rest; while(match(t,/\{/)){depth++; t=substr(t,RSTART+1)}
            t=rest; while(match(t,/\}/)){depth--; t=substr(t,RSTART+1)}
            harvest(rest)
            if(depth<=0) indep=0
            next
          }
          if (indep) {
            harvest(line)
            t=line; while(match(t,/\{/)){depth++; t=substr(t,RSTART+1)}
            t=line; while(match(t,/\}/)){depth--; t=substr(t,RSTART+1)}
            if(depth<=0) indep=0
          }
        }
      ' "$pj"
    fi
  done < <(_find_manifests 'package.json')

  # requirements.txt (PyPI)
  while IFS= read -r rq; do
    [ -z "$rq" ] && continue
    awk '
      { sub(/#.*$/,""); gsub(/[ \t]/,""); }
      $0=="" { next }
      /^-/ { next }                       # -r/-e/--hash flags
      {
        line=$0; sub(/;.*/,"",line);      # drop env markers
        name=line; ver="";
        if (match(line, /[=<>!~]=?/)) { name=substr(line,1,RSTART-1); rest=substr(line,RSTART);
          if (match(rest,/[0-9][0-9A-Za-z.\-]*/)) ver=substr(rest,RSTART,RLENGTH) }
        gsub(/\[.*\]/,"",name);           # drop extras: pkg[extra]
        if(name!="") printf "PyPI\t%s\t%s\n", name, ver
      }
    ' "$rq"
  done < <(_find_manifests 'requirements*.txt')

  # pyproject.toml (PyPI) — [project].dependencies array + poetry [tool.poetry.dependencies] table
  while IFS= read -r pp; do
    [ -z "$pp" ] && continue
    awk '
      function emit(nm,  v){ gsub(/^[ \t]+|[ \t]+$/,"",nm); if(nm!="" && tolower(nm)!="python") printf "PyPI\t%s\t%s\n", nm, "" }
      /^\[project\]/                   { sec="project"; next }
      /^\[tool\.poetry\.dependencies\]/{ sec="poetry"; next }
      /^\[/                            { if($0 !~ /^\[project\]/ && $0 !~ /^\[tool\.poetry\.dependencies\]/){ if(sec!="projdeps") sec="" } }
      # PEP 621: dependencies = [ "pkg>=1", "other" ]  (array, may span lines)
      sec=="project" && /dependencies[ \t]*=[ \t]*\[/ { arr=1 }
      sec=="project" && arr {
        line=$0
        while (match(line, /"[^"]+"/)) {
          tok=substr(line,RSTART+1,RLENGTH-2); line=substr(line,RSTART+RLENGTH)
          nm=tok; sub(/[ \t]*[=<>!~;[].*$/,"",nm); emit(nm)
        }
        if (line ~ /\]/) arr=0
        next
      }
      # poetry: pkg = "^1.2"   (key = value table)
      sec=="poetry" && match($0, /^[A-Za-z0-9_.\-]+[ \t]*=/) {
        nm=substr($0,RSTART,RLENGTH); sub(/[ \t]*=$/,"",nm); emit(nm)
      }
    ' "$pp"
  done < <(_find_manifests 'pyproject.toml')

  # Cargo.toml (crates.io) — [dependencies] / [dev-dependencies] / [build-dependencies] tables
  while IFS= read -r cg; do
    [ -z "$cg" ] && continue
    awk '
      /^\[dependencies\]/             { sec=1; next }
      /^\[dev-dependencies\]/         { sec=1; next }
      /^\[build-dependencies\]/       { sec=1; next }
      /^\[/                           { sec=0 }
      sec && match($0, /^[A-Za-z0-9_\-]+[ \t]*=/) {
        nm=substr($0,RSTART,RLENGTH); sub(/[ \t]*=$/,"",nm); gsub(/[ \t]/,"",nm);
        if(nm!="") printf "crates.io\t%s\t%s\n", nm, ""
      }
    ' "$cg"
  done < <(_find_manifests 'Cargo.toml')

  # go.mod (Go) — require (...) block and single-line require directives
  while IFS= read -r gm; do
    [ -z "$gm" ] && continue
    awk '
      /^require[ \t]*\(/ { blk=1; next }
      blk && /^\)/       { blk=0; next }
      blk {
        line=$0; sub(/\/\/.*/,"",line); gsub(/^[ \t]+|[ \t]+$/,"",line);
        if(line=="") next
        n=split(line,a," "); if(n>=1 && a[1]!="") printf "Go\t%s\t%s\n", a[1], (n>=2?a[2]:"")
        next
      }
      /^require[ \t]+[^ (]/ {
        line=$0; sub(/^require[ \t]+/,"",line); sub(/\/\/.*/,"",line); gsub(/^[ \t]+|[ \t]+$/,"",line);
        n=split(line,a," "); if(n>=1 && a[1]!="") printf "Go\t%s\t%s\n", a[1], (n>=2?a[2]:"")
      }
    ' "$gm"
  done < <(_find_manifests 'go.mod')
}

# find manifests under ROOT, pruning the usual non-source dirs (and walteur-kit itself).
_find_manifests() { # $1 = -name glob
  find "$ROOT" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/vendor' -o -path '*/dist' \
       -o -path '*/build' -o -path '*/.next' -o -path '*/target' -o -path '*/__pycache__' \
       -o -path '*/.venv' -o -path '*/venv' -o -path '*/walteur-kit' \) -prune -o \
    -type f -name "$1" -print 2>/dev/null
}

# build the OSV querybatch request body from $CANDS (one query per candidate; version pin when known).
build_querybatch() { # $1 = candidates file
  local f="$1"
  if have jq; then
    awk -F'\t' 'NF>=2 && $2!="" {print $1"\t"$2"\t"$3}' "$f" \
      | jq -R 'split("\t") | {ecosystem:.[0], name:.[1], version:(.[2]//"")}' \
      | jq -s '{queries: [ .[] | if .version=="" then {package:{ecosystem:.ecosystem,name:.name}}
                                else {package:{ecosystem:.ecosystem,name:.name}, version:.version} end ]}'
  else
    # zero-dep floor: hand-roll the JSON. Names/versions from manifests are package identifiers (safe charset).
    awk -F'\t' '
      BEGIN { printf "{\"queries\":[" }
      NF>=2 && $2!="" {
        if(c++) printf ","
        if($3=="") printf "{\"package\":{\"ecosystem\":\"%s\",\"name\":\"%s\"}}", $1, $2
        else       printf "{\"package\":{\"ecosystem\":\"%s\",\"name\":\"%s\"},\"version\":\"%s\"}", $1, $2, $3
      }
      END { printf "]}" }
    ' "$f"
  fi
}

# extract malicious advisories from an OSV querybatch response.
# Malicious := advisory id starts with "MAL-"  OR  database_specific.malicious == true.
# Emits a JSON array of {id, ecosystem, package, summary} (best-effort; package/ecosystem may be "").
extract_malicious() { # $1 = response JSON
  local resp="$1"
  if have jq; then
    printf '%s' "$resp" | jq -c '
      [ (.results // [])[]? | (.vulns // [])[]?
        | select((.id // "" | startswith("MAL-")) or (.database_specific.malicious == true))
        | { id: (.id // ""),
            ecosystem: ((.affected // [])[0]?.package.ecosystem // ""),
            package:   ((.affected // [])[0]?.package.name // ""),
            summary:   (.summary // "malicious package (OSV)") } ]
    ' 2>/dev/null || echo '[]'
  else
    # zero-dep floor: scan for MAL- ids. Coarser (no per-vuln ecosystem/package mapping) but HONEST —
    # it still mechanically catches the MAL-* advisory and fails closed.
    local ids
    ids="$(printf '%s' "$resp" | grep -oE '"id"[ \t]*:[ \t]*"MAL-[^"]*"' | sed -E 's/.*"(MAL-[^"]*)".*/\1/' | sort -u)"
    if [ -z "$ids" ]; then echo '[]'; return; fi
    local out="[" first=1 id
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      [ "$first" -eq 1 ] && first=0 || out="$out,"
      out="$out{\"id\":\"$id\",\"ecosystem\":\"\",\"package\":\"\",\"summary\":\"malicious package (OSV)\"}"
    done <<EOF
$ids
EOF
    echo "$out]"
  fi
}

# ── embedded self-test (GOOD + POISON twins; hermetic, OFFLINE via OSV_FIXTURE) ──────────
selftest() {
  local fails=0 total=0 tmp rc
  local SELF; SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  # Build a bin/ holding the tools osv-gate needs but DELIBERATELY excluding jq, so we can exercise
  # the zero-dep (jq-absent) floor — the path the corrupt fail-open hid on.
  _nojq_path() { # $1=tmp -> echoes a PATH dir with no jq
    # Exec wrappers, NOT `ln -sf`: on Git Bash/MSYS `ln -s` deep-COPIES the binary, and a copy invoked with
    # PATH restricted to $bd cannot resolve msys-2.0.dll -> rc=127, the gate never starts and the twin is VOID.
    # A #!/bin/sh wrapper resolves its interpreter by absolute path, so it holds on every platform.
    # Only absolute resolutions are wrapped: `command -v printf` yields the shell BUILTIN name, and wrapping
    # that would produce a wrapper that execs itself. jq is deliberately absent; paste is needed (ecos line).
    local bd="$1/nojq-bin" t src; mkdir -p "$bd"
    for t in bash sh env grep egrep sed awk gawk sort head tail cat tr cut wc paste date mkdir rm rmdir chmod find dirname basename cp mv touch mktemp true false test; do
      src="$(command -v "$t" 2>/dev/null)"; case "$src" in /*) ;; *) continue ;; esac
      printf '#!/bin/sh\nexec "%s" "$@"\n' "$src" > "$bd/$t" 2>/dev/null && chmod +x "$bd/$t" 2>/dev/null
    done
    printf '%s' "$bd"
  }

  run_one() { # $1=label $2=want-rc $3=setup-fn (sets up $tmp, may export OSV_FIXTURE/WALTEUR_OSV)
    total=$((total+1))
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/osv-gate-selftest.XXXXXX")" || {
      echo "  FAIL — $1 (mktemp could not create a temp dir)"; fails=$((fails+1)); return; }
    mkdir -p "$tmp/walteur-kit" "$tmp/src"
    SELF_FIXTURE=""; SELF_MODE="on"; SELF_ENDPOINT=""; SELF_NOJQ=""; SELF_VERDICT=""; SELF_TOOLGATE_STRICT=""
    "$3" "$tmp"   # setup writes manifests/fixtures into $tmp and may set SELF_FIXTURE/SELF_MODE/SELF_ENDPOINT
    set +e
    # Clean env so a stray OSV_* from the caller cannot leak into a twin. When no fixture is set, point
    # OSV_ENDPOINT at an unresolvable host so the no-network path is DETERMINISTIC offline (curl fails fast).
    local osv_env=()
    if [ -n "$SELF_FIXTURE" ]; then
      osv_env=( "OSV_FIXTURE=$SELF_FIXTURE" )
    else
      osv_env=( "OSV_ENDPOINT=${SELF_ENDPOINT:-http://osv-gate.invalid./v1/querybatch}" )
    fi
    local run_path="$PATH"
    if [ -n "$SELF_NOJQ" ]; then
      run_path="$(_nojq_path "$tmp")"
      # The jq-free PATH must be able to RUN the gate. A shim dir that cannot exec voids the twin — say so
      # as a FAIL against the HARNESS, never let it read as a verdict from the gate.
      if ! env -i PATH="$run_path" HOME="${HOME:-/tmp}" bash -c 'command -v grep >/dev/null && command -v awk >/dev/null' 2>/dev/null; then
        echo "  FAIL — $1 (harness could not build a working jq-free PATH: $run_path)"; fails=$((fails+1)); rm -rf "$tmp"; return
      fi
    fi
    env -i PATH="$run_path" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
        WALTEUR_ROOT="$tmp" WALTEUR_OSV="$SELF_MODE" ${SELF_TOOLGATE_STRICT:+WALTEUR_TOOLGATE_STRICT=1} "${osv_env[@]}" \
        bash "$SELF" >/dev/null 2>&1
    rc=$?
    set -e
    local okv=1; [ "$rc" -eq "$2" ] || okv=0
    if [ -n "$SELF_VERDICT" ]; then
      # Read the verdict on the SAME zero-dep floor the gate claims (no jq), and never let a missing or
      # unreadable report abort the run: `set -e` is in force here, so a bare failing command substitution
      # would kill the selftest mid-case and swallow every twin after it. Empty gv != want => loud FAIL.
      local gv; gv="$(grep -oE '"verdict"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp/walteur-kit/osv-report.json" 2>/dev/null \
                      | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true)"
      [ "$gv" = "$SELF_VERDICT" ] || okv=0
    fi
    if [ "$okv" -eq 1 ]; then echo "  ok   — $1 (rc=$rc${SELF_VERDICT:+,verdict=$SELF_VERDICT})"; else echo "  FAIL — $1 (rc=$rc want $2${SELF_VERDICT:+, verdict want $SELF_VERDICT})"; fails=$((fails+1)); fi
    rm -rf "$tmp"
  }

  # a candidate manifest common to the network-shaped twins.
  _write_pkg() { printf '{\n "name":"demo",\n "dependencies":{ "left-pad":"1.3.0", "express":"^4.18.0" }\n}\n' > "$1/package.json"; }

  # GOOD twin — fixture has advisories but NONE malicious (an ordinary GHSA) => PASS (exit 0).
  good_setup() {
    _write_pkg "$1"
    cat > "$1/walteur-kit/osv-good.json" <<'JSON'
{ "results": [
  { "vulns": [ { "id": "GHSA-xxxx-yyyy-zzzz", "summary": "ReDoS in left-pad",
                 "affected": [ { "package": { "ecosystem": "npm", "name": "left-pad" } } ] } ] },
  {}
] }
JSON
    SELF_FIXTURE="$1/walteur-kit/osv-good.json"
  }

  # POISON twin — fixture contains a MAL-* malicious-package advisory => CAUGHT (exit 2).
  poison_setup() {
    _write_pkg "$1"
    cat > "$1/walteur-kit/osv-poison.json" <<'JSON'
{ "results": [
  { "vulns": [ { "id": "MAL-2024-1337", "summary": "malicious code in left-pad clone",
                 "database_specific": { "malicious": true },
                 "affected": [ { "package": { "ecosystem": "npm", "name": "left-pad" } } ] } ] },
  {}
] }
JSON
    SELF_FIXTURE="$1/walteur-kit/osv-poison.json"
  }

  # POISON twin #2 — malicious flagged via database_specific.malicious=true with a NON-MAL id => CAUGHT (exit 2).
  poison_flag_setup() {
    _write_pkg "$1"
    cat > "$1/walteur-kit/osv-poison2.json" <<'JSON'
{ "results": [
  { "vulns": [ { "id": "OSV-2024-9999", "summary": "package flagged malicious",
                 "database_specific": { "malicious": true },
                 "affected": [ { "package": { "ecosystem": "npm", "name": "express" } } ] } ] }
] }
JSON
    SELF_FIXTURE="$1/walteur-kit/osv-poison2.json"
  }

  # explicit candidate list (MCP-server-as-package) + MAL fixture => CAUGHT (exit 2).
  mcp_candidate_setup() {
    printf 'npm @evil/mcp-server 0.0.1\nPyPI requests\n' > "$1/walteur-kit/osv-candidates.txt"
    cat > "$1/walteur-kit/osv-mcp.json" <<'JSON'
{ "results": [
  { "vulns": [ { "id": "MAL-2025-0001", "summary": "typosquat MCP server",
                 "affected": [ { "package": { "ecosystem": "npm", "name": "@evil/mcp-server" } } ] } ] },
  {}
] }
JSON
    SELF_FIXTURE="$1/walteur-kit/osv-mcp.json"
  }

  # NO candidates at all => NOT_APPLICABLE (exit 0).
  none_setup() { printf 'print("cli")\n' > "$1/src/main.py"; }   # .py source != a manifest; nothing to query

  # NO fixture + NO network reachable in this sandbox + candidates present => LOUD SKIP (exit 0).
  # We force the no-fixture path; the run_one harness points OSV_ENDPOINT at an unresolvable host.
  noskip_setup() { _write_pkg "$1"; }   # SELF_FIXTURE intentionally left unset

  # STRICT + no fixture + unreachable => fail-closed (exit 2).
  strict_setup() { _write_pkg "$1"; SELF_MODE="strict"; }   # no fixture, strict mode
  # global ship-time toggle (panel #3 security fix): WALTEUR_OSV unset/on + WALTEUR_TOOLGATE_STRICT=1 (which
  # ship-gate exports on a real ship) must escalate a can't-verify to fail-closed exactly like WALTEUR_OSV=strict.
  global_strict_setup() { _write_pkg "$1"; SELF_TOOLGATE_STRICT="1"; }   # SELF_MODE stays "on"
  # negative control: an explicit WALTEUR_OSV=off bypass still wins over the global strict escalation.
  bypass_over_global_setup() { _write_pkg "$1"; SELF_MODE="off"; SELF_TOOLGATE_STRICT="1"; }

  # CORRUPT + MALICIOUS — an UNPARSEABLE (truncated) OSV body that still carries a MAL-* id.
  # This is the exact fail-open the gate is hardened against: must be CAUGHT (exit 2), never read clean.
  corrupt_mal_setup() {
    _write_pkg "$1"
    printf '%s' '{ "results": [ { "vulns": [ { "id": "MAL-2025-6666", "summary": "evil", "affected": [ { "package": { "ecosystem": "npm", "name": "left-pad"' > "$1/walteur-kit/osv-corrupt-mal.json"
    SELF_FIXTURE="$1/walteur-kit/osv-corrupt-mal.json"
  }

  # CORRUPT + NO MAL marker — unparseable body, no MAL-* id => cannot verify (never a silent PASS).
  corrupt_clean_setup() {
    _write_pkg "$1"
    printf '%s' '{ "results": [ { "vulns": [ { "id": "GHSA-aaaa-bbbb' > "$1/walteur-kit/osv-corrupt.json"
    SELF_FIXTURE="$1/walteur-kit/osv-corrupt.json"; SELF_VERDICT="SKIP"
  }
  corrupt_clean_strict_setup() { corrupt_clean_setup "$1"; SELF_MODE="strict"; SELF_VERDICT=""; }

  # jq-ABSENT (zero-dep floor) twins — the path the corrupt fail-open hid on (caught by verification).
  nojq_garbage_setup() { _write_pkg "$1"; printf '%s' 'this is not json at all %%%' > "$1/walteur-kit/osv-nojq.json"; SELF_FIXTURE="$1/walteur-kit/osv-nojq.json"; SELF_NOJQ=1; SELF_VERDICT="SKIP"; }
  nojq_mal_setup()     { _write_pkg "$1"; printf '%s' '{"results":[{"vulns":[{"id":"MAL-2025-7777"}]}]}' > "$1/walteur-kit/osv-nojq.json"; SELF_FIXTURE="$1/walteur-kit/osv-nojq.json"; SELF_NOJQ=1; }
  nojq_flag_setup()    { _write_pkg "$1"; printf '%s' '{"results":[{"vulns":[{"id":"OSV-1","database_specific":{"malicious":true}}]}]}' > "$1/walteur-kit/osv-nojq.json"; SELF_FIXTURE="$1/walteur-kit/osv-nojq.json"; SELF_NOJQ=1; }
  nojq_strict_setup()  { nojq_garbage_setup "$1"; SELF_MODE="strict"; SELF_VERDICT=""; }

  echo "osv-gate selftest:"
  run_one "GOOD twin: ordinary GHSA, no MAL -> PASS"                  0 good_setup
  run_one "POISON twin: MAL-* advisory -> CAUGHT"                     2 poison_setup
  run_one "POISON twin: database_specific.malicious=true -> CAUGHT"   2 poison_flag_setup
  run_one "explicit MCP candidate + MAL fixture -> CAUGHT"            2 mcp_candidate_setup
  run_one "no candidates (CLI .py only) -> NOT_APPLICABLE"            0 none_setup
  run_one "no fixture + no network -> LOUD SKIP"                      0 noskip_setup
  run_one "strict + no fixture + no network -> fail-closed"           2 strict_setup
  run_one "global WALTEUR_TOOLGATE_STRICT=1 escalates can't-verify -> fail-closed" 2 global_strict_setup
  run_one "WALTEUR_OSV=off + global strict -> still SKIP (bypass wins)"            0 bypass_over_global_setup
  run_one "CORRUPT response w/ MAL-* id -> CAUGHT (no fail-open)"      2 corrupt_mal_setup
  run_one "CORRUPT response, no MAL -> LOUD SKIP (never PASS)"         0 corrupt_clean_setup
  run_one "CORRUPT response, no MAL, strict -> fail-closed"           2 corrupt_clean_strict_setup
  run_one "jq-ABSENT + garbage -> can't-verify SKIP (NOT silent PASS)" 0 nojq_garbage_setup
  run_one "jq-ABSENT + MAL-* id -> CAUGHT (grep floor)"               2 nojq_mal_setup
  run_one "jq-ABSENT + malicious:true flag -> CAUGHT (grep floor)"    2 nojq_flag_setup
  run_one "jq-ABSENT + garbage + strict -> fail-closed"               2 nojq_strict_setup
  echo "osv-gate selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi
run_gate
