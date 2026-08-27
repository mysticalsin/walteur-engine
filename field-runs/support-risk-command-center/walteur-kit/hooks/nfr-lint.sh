#!/usr/bin/env bash
# WALTEUR nfr-lint — Planguage gate on non-functional requirements. Every NFR must be quantified:
# a unit, a numeric target, and the load_condition it holds under. A weasel NFR ("should be fast",
# "highly available", "secure") has no number, no unit, no condition — unverifiable, forbidden.
#
# APPLICABILITY (applicability-first — the #1 past bug is a gate that fires on a project that has
# no NFR discipline to check): this gate applies ONLY if EITHER
#   (a) walteur-kit/nfr.json exists, OR
#   (b) PLAN.md (the given file, or $ROOT/PLAN.md) has an "NFR" / "Non-Functional" heading.
# If NEITHER trigger is present (a bare/minimal project) => NOT_APPLICABLE, exit 0. Never exit 2
# on a project that simply lacks NFRs — exit 2 is ONLY a real violation in an applicable project.
#
# ZERO-DEP HARD CHECK (bash + grep + jq + awk + sed only — real exit 2 on a real violation):
#   Path A — walteur-kit/nfr.json present:
#     * must be valid JSON and a non-empty array (shape mirrors schemas/nfr.schema.json)
#     * EVERY entry must have a non-empty string id, a non-empty string unit, a NUMERIC target,
#       and a non-empty string load_condition. A missing/blank unit, a non-numeric/missing target,
#       or a missing/blank load_condition = a weasel NFR => exit 2.
#   Path B — PLAN.md has an NFR/Non-Functional heading but no nfr.json:
#     * the NFR section must carry at least one quantified target: a number adjacent to a unit
#       (e.g. 200ms, 99.9%, 500 rps, 1000 users). A section that only says "fast / scalable /
#       available" with no number+unit = unquantified => exit 2.
#   (If BOTH triggers fire, both checks run; any violation fails.)
#
# Tools used (grep/jq/awk/sed) are zero-dep and effectively always present; if one is genuinely
# absent we emit a LOUD recorded SKIP (never silent-green, never exit 2 for a missing tool).
# Bypass: WALTEUR_NFR=off. Pause: walteur-kit/PAUSED present.
# Report: walteur-kit/nfr-report.json  {verdict, ts, gate, reason, details}.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/nfr-report.json"
NFR_JSON="$KIT/nfr.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_report() { # $1=verdict  $2=reason  $3=details-json-array(default [])
  local v="$1" reason="$2" details="${3:-[]}"
  jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --arg plan "${PLAN:-}" \
    --argjson details "$details" \
    '{verdict:$v, ts:$ts, gate:"nfr-lint", plan:$plan, reason:$reason, details:$details}' \
    > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"%s","ts":"%s","gate":"nfr-lint","reason":"%s","details":[]}\n' \
         "$v" "$TS" "$reason" > "$REPORT"
}

selftest() {
  local pass=0 fail=0 tmp rc
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  ck() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  echo "nfr-lint selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nfr-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no nfr discipline -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nfr-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{ bad json\n' > "$tmp/walteur-kit/nfr.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "invalid nfr.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nfr-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '[{"id":"latency","unit":"ms","load_condition":"p95 under nominal load"}]\n' > "$tmp/walteur-kit/nfr.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "unquantified nfr.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nfr-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '[{"id":"latency","unit":"ms","target":200,"load_condition":"p95 under 500 users"}]\n' > "$tmp/walteur-kit/nfr.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "quantified nfr.json -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nfr-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '# Plan\n\n## Non-Functional Requirements\n\n- The app should be fast and scalable.\n' > "$tmp/PLAN.md"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "unquantified PLAN NFR section -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nfr-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '# Plan\n\n## Non-Functional Requirements\n\n- p95 latency <= 200ms under 500 users.\n' > "$tmp/PLAN.md"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "quantified PLAN NFR section -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nfr-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{ bad json\n' > "$tmp/walteur-kit/nfr.json"
  WALTEUR_ROOT="$tmp" WALTEUR_NFR=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nfr-lint-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "nfr-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_NFR:-on}" = "off" ] && {
  echo "nfr-lint: bypassed (WALTEUR_NFR=off)." >&2
  write_report "SKIP" "bypassed (WALTEUR_NFR=off)" '[]'; exit 0; }

# ── tool guard (zero-dep core; stay honest if a base tool is genuinely missing) ──────────────
for t in grep jq awk sed; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR nfr-lint SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
    write_report "SKIP" "$t not installed" '[]'
    exit 0
  fi
done

# PLAN.md resolution: explicit arg wins, else $ROOT/PLAN.md if present.
PLAN="${1:-}"
if [ -z "$PLAN" ] && [ -f "$ROOT/PLAN.md" ]; then PLAN="$ROOT/PLAN.md"; fi
[ -n "$PLAN" ] && [ ! -f "$PLAN" ] && PLAN=""   # a non-existent arg is not a trigger

# ── applicability: nfr.json OR a PLAN with an NFR/Non-Functional heading ──────────────────────
HAVE_NFR_JSON=0
[ -f "$NFR_JSON" ] && HAVE_NFR_JSON=1

# NFR heading detector: a markdown heading whose text mentions NFR or Non-Functional
# (e.g. "## NFRs", "### Non-Functional Requirements", "## Non functional requirements").
PLAN_NFR_HEAD_LINE=""
if [ -n "$PLAN" ]; then
  PLAN_NFR_HEAD_LINE="$(grep -niE '^[[:space:]]*#{1,6}[[:space:]].*(non[-_ ]?functional|\bNFRs?\b)' "$PLAN" \
    | head -1 | cut -d: -f1 || true)"
fi

if [ "$HAVE_NFR_JSON" -eq 0 ] && [ -z "$PLAN_NFR_HEAD_LINE" ]; then
  echo "nfr-lint: no walteur-kit/nfr.json and no NFR/Non-Functional section in a PLAN — gate not applicable." >&2
  write_report "NOT_APPLICABLE" "no nfr.json and no NFR/Non-Functional heading in PLAN" '[]'
  exit 0
fi

echo "WALTEUR nfr-lint @ $ROOT (nfr.json: $([ "$HAVE_NFR_JSON" -eq 1 ] && echo yes || echo no), plan-nfr-heading: $([ -n "$PLAN_NFR_HEAD_LINE" ] && echo "yes@$PLAN_NFR_HEAD_LINE" || echo no))" >&2

declare -a FINDINGS_JSON=()
add() { # $1=source  $2=ref(string)  $3=rule  $4=message
  FINDINGS_JSON+=("$(jq -n --arg s "$1" --arg ref "$2" --arg r "$3" --arg m "$4" \
    '{source:$s, ref:$ref, rule:$r, message:$m}')")
}

# ── Path A: validate walteur-kit/nfr.json (zero-dep shape via jq, mirrors the schema) ────────
if [ "$HAVE_NFR_JSON" -eq 1 ]; then
  if ! jq -e . "$NFR_JSON" >/dev/null 2>&1; then
    add "nfr.json" "nfr.json" "invalid-json" "walteur-kit/nfr.json is not valid JSON."
  elif ! jq -e 'type=="array" and (length>=1)' "$NFR_JSON" >/dev/null 2>&1; then
    add "nfr.json" "nfr.json" "shape" "walteur-kit/nfr.json must be a non-empty array of NFRs."
  else
    # Per-entry weasel-NFR detection. Emit one finding line per failing field, prefixed with the
    # entry index and its id (or '?'). jq -e returns these as raw lines; we tag each as a finding.
    WEASEL="$(jq -r '
      to_entries[]
      | .key as $i
      | .value as $n
      | ($n.id // "?") as $id
      | [
          ( if (($n.id|type)!="string") or (($n.id|tostring|length)<1)
            then "missing/blank id" else empty end ),
          ( if (($n.unit|type)!="string") or (($n.unit|tostring|gsub("[[:space:]]";"")|length)<1)
            then "missing/blank unit (no scale of measure)" else empty end ),
          ( if ($n.target|type)!="number"
            then "missing/non-numeric target (no quantified goal)" else empty end ),
          ( if (($n.load_condition|type)!="string") or (($n.load_condition|tostring|gsub("[[:space:]]";"")|length)<1)
            then "missing/blank load_condition (no qualifier — fast under what load?)" else empty end )
        ]
      | select(length>0)
      | "[\($i)] \($id): " + (join("; "))
    ' "$NFR_JSON" 2>/dev/null || true)"
    if [ -n "$WEASEL" ]; then
      while IFS= read -r w; do
        [ -z "$w" ] && continue
        ref="${w%%:*}"                       # "[i] id"
        msg="${w#*: }"
        add "nfr.json" "$ref" "weasel-nfr" "Unquantified NFR — $msg"
      done <<< "$WEASEL"
    fi
  fi
fi

# ── Path B: PLAN NFR section must carry at least one number+unit target ───────────────────────
if [ -n "$PLAN_NFR_HEAD_LINE" ]; then
  # Extract the NFR section: from its heading to the next heading of the same-or-higher level
  # (any '#' heading ends it), capped at 200 lines so a runaway file can't be scanned forever.
  SECTION="$(awk -v start="$PLAN_NFR_HEAD_LINE" '
    NR>start {
      if ($0 ~ /^[[:space:]]*#{1,6}[[:space:]]/) exit   # next heading ends the section
      print
      if (NR-start>200) exit
    }' "$PLAN")"

  # number+unit detector: a number immediately/space-adjacent to a recognised NFR unit.
  NUM_UNIT="$(printf '%s' "$SECTION" | grep -ioE \
    '[0-9]+(\.[0-9]+)?[[:space:]]*(ms|s|sec|secs|seconds|m|min|mins|minutes|h|hr|hrs|hours|days?|%|x|rps|qps|req|requests|reqs|tps|users?|sessions?|connections?|conns?|gb|mb|kb|tb|bytes?|errors?_per_million|epm|ppm|nines|fps|p50|p95|p99|p999|usd|eur|€|\$)' \
    | head -1 || true)"

  if [ -z "$NUM_UNIT" ]; then
    add "PLAN" "$PLAN:$PLAN_NFR_HEAD_LINE" "unquantified-section" \
      "NFR/Non-Functional section has no quantified target (no number adjacent to a unit). Add a unit + numeric target + load condition (Planguage), or declare them in walteur-kit/nfr.json."
  fi
fi

# ── verdict ──────────────────────────────────────────────────────────────────────────────────
if [ "${#FINDINGS_JSON[@]}" -eq 0 ]; then
  write_report "PASS" "all NFRs quantified (unit + numeric target + load condition)" '[]'
  echo "WALTEUR nfr-lint: PASS — every NFR is quantified." >&2
  exit 0
fi

FIND_JSON="$(printf '%s\n' "${FINDINGS_JSON[@]}" | jq -s '.')"
NFIND="$(printf '%s' "$FIND_JSON" | jq 'length')"
write_report "FAIL" "$NFIND unquantified NFR(s)" "$FIND_JSON"
echo "WALTEUR nfr-lint: FAIL — $NFIND unquantified NFR finding(s):" >&2
printf '%s' "$FIND_JSON" | jq -r '.[] | "  [\(.rule)] \(.ref)  \(.message)"' >&2
exit 2
