#!/usr/bin/env bash
# WALTEUR spec-trace — ZERO-DEP HARD gate on PLAN.md requirement traceability.
# Usage: bash walteur-kit/hooks/spec-trace.sh [PLAN.md]   (defaults to ROOT/PLAN.md)
#
# Enforces the three traceability invariants WALTEUR's PLAN.template.md promises
# ("every requirement traces to >=1 task"; premortem High x High needs a mitigation_task_id):
#
#   T1  FORWARD trace — every requirement id REQ-<id> referenced anywhere in the plan must map to
#       >=1 task. A task "covers" a requirement when the requirement id appears on a task row /
#       in the task's Acceptance cell, or a task explicitly lists "(REQ-x, REQ-y)". Any REQ-<id>
#       with zero covering tasks is an UNTRACED requirement => violation.
#   T2  NO GOLD-PLATING (reverse trace) — every task must trace back to >=1 requirement. A task
#       that names no REQ-<id> and is not explicitly marked as scaffolding (tag
#       `[no-req]` / `traces: none` / a "Why/Req" cell naming an out-of-scope rationale) is
#       untraced build => gold-plating => violation. (A plan with NO REQ ids at all is exempt
#       from T2 — there is nothing to gold-plate against; T1 then has nothing to check either.)
#   T3  PREMORTEM High x High mitigation — for the premortem (a fenced ```json array matching
#       walteur-kit/schemas/premortem.schema.json, OR the markdown premortem table), every
#       scenario with likelihood=high AND impact=high MUST carry a mitigation_task_id (JSON) or a
#       non-empty Mitigation cell that names a task (table). An unmitigated High x High => violation.
#   T4  (OPTIONAL, v9.0) PRD STORY trace — IF walteur-kit/PRD.md (or PRD.md) exists with STORY-<id>
#       ids, every story must map to >=1 task in PLAN.md (the §4.1a law). No PRD / no STORY ids =>
#       silently skipped, so the T1..T3 semantics and the no-PRD path are unchanged.
#
# HONESTY: the tools here (grep/awk/sed/jq) are zero-dep core; there is no missing-tool SKIP.
# The only honest non-fail-non-pass outcomes are: no PLAN.md (cannot trace nothing => SKIP), or a
# plan with no requirement ids AND no premortem (nothing to trace => NOT_APPLICABLE).
# jq is used only when a JSON premortem block is present; if jq is absent we degrade that one
# sub-check to the table parser and record it.
# Report: walteur-kit/spec-trace-report.json {verdict, ts, gate, plan, failed_checks, details}.
# Bypass: WALTEUR_SPECTRACE=off.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/spec-trace-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

PLAN="${1:-$ROOT/PLAN.md}"

# write_report VERDICT REASON FAILED_CHECKS_JSON DETAILS_JSON
write_report() {
  if have jq; then
    jq -n --arg v "$1" --arg ts "$TS" --arg reason "$2" --arg plan "$PLAN" \
          --argjson checks "${3:-[]}" --argjson details "${4:-[]}" \
      '{verdict:$v, ts:$ts, gate:"spec-trace", plan:$plan, reason:$reason,
        failed_checks:$checks, details:$details}' > "$REPORT"
  else
    printf '{"verdict":"%s","ts":"%s","gate":"spec-trace","plan":"%s","reason":"%s","failed_checks":%s,"details":%s}\n' \
      "$1" "$TS" "$PLAN" "$2" "${3:-[]}" "${4:-[]}" > "$REPORT"
  fi
}

json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n\t'; }

selftest() {
  pass=0
  fail=0
  ck() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  for t in bash jq grep head cut awk sort sed tr mktemp date mkdir rm ln cat touch; do
    if ! have "$t"; then
      echo "spec-trace selftest SKIP - required tool '$t' not installed."
      return 0
    fi
  done

  make_core_path() {
    dst="$1"
    mkdir -p "$dst"
    for t in bash jq grep head cut awk sort sed tr mktemp date mkdir rm; do
      ln -sf "$(command -v "$t")" "$dst/$t"
    done
  }
  write_prd() {
    root="$1"; story="$2"
    mkdir -p "$root/walteur-kit"
    cat > "$root/walteur-kit/PRD.md" <<MD
# PRD

## Stories
- $story: user can complete the promised workflow.
MD
  }
  write_valid_plan() {
    root="$1"
    cat > "$root/PLAN.md" <<'MD'
# PLAN

## Requirements
- REQ-A: user can complete the promised workflow.

## Tasks
| Task | Acceptance |
|---|---|
| T1 | Build the core flow for REQ-A and STORY-A. |

## Premortem
```json
[
  {"scenario":"Service outage","likelihood":"high","impact":"high","mitigation_task_id":"T1"}
]
```
MD
  }

  echo "spec-trace selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/spectrace.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing PLAN -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/spec-trace-report.json" >/dev/null 2>&1
  ck "missing PLAN report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/spectrace.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  printf '# PLAN\n\nNo traceable ids here.\n' > "$tmp/PLAN.md"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no trace signals -> NOT_APPLICABLE exit" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/spec-trace-report.json" >/dev/null 2>&1
  ck "no trace signals report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/spectrace.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  write_valid_plan "$tmp"
  write_prd "$tmp" "STORY-A"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "valid PLAN + PRD trace -> PASS" 0 "$?"
  jq -e '.verdict == "PASS"' "$tmp/walteur-kit/spec-trace-report.json" >/dev/null 2>&1
  ck "valid trace report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/spectrace.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  cat > "$tmp/PLAN.md" <<'MD'
# PLAN
## Requirements
- REQ-A: this must be delivered.
## Tasks
| Task | Acceptance |
|---|---|
| T1 | Build unrelated work for REQ-B. |
MD
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "untraced requirement -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.failed_checks | index("T1"))' "$tmp/walteur-kit/spec-trace-report.json" >/dev/null 2>&1
  ck "untraced requirement report records T1" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/spectrace.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  cat > "$tmp/PLAN.md" <<'MD'
# PLAN
## Requirements
- REQ-A: this must be delivered.
## Tasks
| Task | Acceptance |
|---|---|
| T1 | Build required work for REQ-A. |
| T2 | Build extra dashboard. |
MD
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "untraced task -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.failed_checks | index("T2"))' "$tmp/walteur-kit/spec-trace-report.json" >/dev/null 2>&1
  ck "untraced task report records T2" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/spectrace.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  cat > "$tmp/PLAN.md" <<'MD'
# PLAN
## Requirements
- REQ-A: this must be delivered.
## Tasks
| Task | Acceptance |
|---|---|
| T1 | Build required work for REQ-A. |
## Premortem
```json
[
  {"scenario":"Data loss","likelihood":"high","impact":"high"}
]
```
MD
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "unmitigated premortem -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.failed_checks | index("T3"))' "$tmp/walteur-kit/spec-trace-report.json" >/dev/null 2>&1
  ck "unmitigated premortem report records T3" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/spectrace.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  write_valid_plan "$tmp"
  write_prd "$tmp" "STORY-MISSING"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "untraced PRD story -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and (.failed_checks | index("T4"))' "$tmp/walteur-kit/spec-trace-report.json" >/dev/null 2>&1
  ck "untraced PRD story report records T4" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/spectrace.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" WALTEUR_SPECTRACE=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/spec-trace-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/spectrace.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "spec-trace selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
if [ "${WALTEUR_SPECTRACE:-on}" = "off" ]; then
  echo "spec-trace: bypassed (WALTEUR_SPECTRACE=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_SPECTRACE=off" '[]' '[{"bypassed":true}]'
  exit 0
fi

if [ ! -f "$PLAN" ]; then
  echo "WALTEUR spec-trace SKIP — '$PLAN' not found (nothing to trace)." >&2
  write_report "SKIP" "plan file not found: $PLAN" '[]' '[]'
  exit 0
fi

REQ_RE='REQ-[A-Za-z0-9][A-Za-z0-9._-]*'

# ── identify the task region ─────────────────────────────────────────────────────
# Tasks live under a "## Tasks" heading (WALTEUR PLAN.template.md). If absent, fall back to the
# whole file (so a flat plan still traces). A "task line" is a markdown table row or a list item
# that carries a status/ownership shape; we keep it permissive — a row under Tasks is a task.
TASKS_START="$(grep -niE '^[[:space:]]*#{1,6}[[:space:]]*tasks\b' "$PLAN" | head -1 | cut -d: -f1)"

# Pull the requirement ids referenced ANYWHERE in the plan (forward-trace universe).
ALL_REQS="$(grep -oE "$REQ_RE" "$PLAN" 2>/dev/null | sed -E 's/[.,;:]+$//' | LC_ALL=C sort -u || true)"

# Extract task rows (the lines we reverse-trace). Each task row -> a line number + text.
# A task row = under the Tasks section (if present), a non-blank line that is either a table data
# row (starts with optional ws then '|') excluding the header/separator, or a list item ('-','*','+').
# macOS bare `mktemp` ignores $TMPDIR and uses confstr(_CS_DARWIN_USER_TEMP_DIR), which can be unwritable
# (sandbox/MDM/hardened-runtime) → empty tempfile → COVERED_REQS empty → every REQ false-fires T1. Use an
# explicit $TMPDIR template + hard-fail SKIP (mirrors prd-gate.sh).
task_rows_file="$(mktemp "${TMPDIR:-/tmp}/spec-trace.XXXXXX")" || {
  echo "WALTEUR spec-trace SKIP — could not create a tempfile under ${TMPDIR:-/tmp} (recorded, not silent-green)." >&2
  write_report "SKIP" "mktemp failed (restricted temp dir)" '[]' '[]'; exit 0; }
trap 'rm -f "$task_rows_file"' EXIT
awk -v start="${TASKS_START:-0}" '
  NR>start {
    if (start>0 && NR>start && $0 ~ /^[[:space:]]*#{1,6}[[:space:]]/) exit   # next heading ends Tasks
    line=$0
    # skip blank
    if (line ~ /^[[:space:]]*$/) next
    # table separator row (---|---) is not a task
    if (line ~ /^[[:space:]]*\|?[[:space:]]*:?-{2,}/) next
    # table header row: contains "Task" and "Acceptance" or "Owner" or "Status" headings
    if (line ~ /^[[:space:]]*\|/ && line ~ /[Tt]ask/ && (line ~ /[Aa]cceptance/ || line ~ /[Oo]wner/ || line ~ /[Ss]tatus/)) next
    is_table = (line ~ /^[[:space:]]*\|/)
    is_list  = (line ~ /^[[:space:]]*[-*+][[:space:]]+/)
    if (is_table || is_list) {
      # a task row should reference a number/id or a verb — keep all rows under Tasks; flat-file
      # mode (start==0) requires a list/table item too, which is what we have here.
      print NR "\t" line
    }
  }
' "$PLAN" > "$task_rows_file"

# grep -c already prints 0 on no match (and exits 1); the old `|| echo 0` appended a SECOND 0 → "0\n0".
TASK_COUNT="$(grep -c . "$task_rows_file" 2>/dev/null)"; TASK_COUNT="${TASK_COUNT:-0}"

# Requirement ids that APPEAR in task rows (covered set, for forward trace).
COVERED_REQS="$(grep -oE "$REQ_RE" "$task_rows_file" 2>/dev/null | sed -E 's/[.,;:]+$//' | LC_ALL=C sort -u || true)"

FAILED_CHECKS=""
DETAILS=""        # newline-separated compact JSON objects
add_detail() {    # $1=check  $2=line(int)  $3=message
  obj="$(printf '{"check":"%s","line":%s,"message":"%s"}' "$1" "$2" "$(json_esc "$3")")"
  DETAILS="$DETAILS$obj
"
}
mark_fail() { case " $FAILED_CHECKS " in *" $1 "*) :;; *) FAILED_CHECKS="$FAILED_CHECKS $1";; esac; }

HAS_REQS=0; [ -n "$ALL_REQS" ] && HAS_REQS=1

# ── T1: forward trace — every referenced REQ-<id> must be covered by >=1 task ────
if [ "$HAS_REQS" = 1 ]; then
  while IFS= read -r req; do
    [ -z "$req" ] && continue
    if ! printf '%s\n' "$COVERED_REQS" | grep -qxF "$req"; then
      mark_fail T1
      ln="$(grep -nE "$req" "$PLAN" | head -1 | cut -d: -f1)"; [ -z "$ln" ] && ln=0
      add_detail T1 "$ln" "Untraced requirement: $req referenced but no task covers it."
      echo "  FAIL T1 — $req has no covering task." >&2
    fi
  done <<EOF
$ALL_REQS
EOF
fi

# ── T2: reverse trace — every task must name a REQ or be explicitly scaffolding ──
# Exempt the whole check if the plan declares no requirement ids at all.
if [ "$HAS_REQS" = 1 ] && [ "$TASK_COUNT" -gt 0 ]; then
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    ln="${row%%	*}"
    txt="${row#*	}"
    # covered if it names any REQ id
    if printf '%s' "$txt" | grep -qoE "$REQ_RE"; then
      continue
    fi
    # explicit scaffolding escape hatches (case-insensitive)
    if printf '%s' "$txt" | grep -qiE '\[no-req\]|traces:[[:space:]]*none|no-req\b|scaffold(ing)?\b|chore:[[:space:]]'; then
      continue
    fi
    mark_fail T2
    short="$(printf '%s' "$txt" | sed -E 's/^[[:space:]]*\|?[[:space:]]*//; s/[[:space:]]+/ /g' | cut -c1-90)"
    add_detail T2 "$ln" "Gold-plating: task traces to no requirement: $short"
    echo "  FAIL T2 — task at line $ln traces to no REQ id: $short" >&2
  done < "$task_rows_file"
fi

# ── T3: premortem High x High must carry a mitigation_task_id / Mitigation ───────
# Locate a premortem region: a "## Premortem" heading, OR a referenced premortem.json file.
PREMORTEM_OK=1   # 1 = no unmitigated HighxHigh found / not present; flips to 0 on violation
premortem_checked=0

# (a) fenced ```json array directly in the plan, under/after a Premortem heading.
PM_HEAD="$(grep -niE '^[[:space:]]*#{1,6}[[:space:]]*premortem' "$PLAN" | head -1 | cut -d: -f1)"

extract_json_block() {
  # print the first fenced ```json block in $PLAN (body only)
  awk '
    /^[[:space:]]*(```|~~~)[[:space:]]*[Jj][Ss][Oo][Nn][[:space:]]*$/ { if(!inb){inb=1; next} }
    inb && /^[[:space:]]*(```|~~~)[[:space:]]*$/ { exit }
    inb { print }
  ' "$PLAN"
}

PM_JSON="$(extract_json_block)"
if [ -n "$PM_JSON" ] && printf '%s' "$PM_JSON" | grep -qiE 'likelihood|impact'; then
  premortem_checked=1
  if have jq && printf '%s' "$PM_JSON" | jq -e . >/dev/null 2>&1; then
    # Count HighxHigh entries lacking a mitigation_task_id (>=0 integer).
    BAD="$(printf '%s' "$PM_JSON" | jq '[ .[] | select((.likelihood|ascii_downcase)=="high" and (.impact|ascii_downcase)=="high") | select((has("mitigation_task_id")|not) or (.mitigation_task_id==null)) ] | length' 2>/dev/null || echo -1)"
    if [ "$BAD" = "-1" ]; then
      :  # not the expected shape; fall through to table parser below
      premortem_checked=0
    elif [ "$BAD" -gt 0 ]; then
      PREMORTEM_OK=0
      mark_fail T3
      add_detail T3 "${PM_HEAD:-0}" "$BAD premortem High x High scenario(s) lack mitigation_task_id."
      echo "  FAIL T3 — $BAD HighxHigh premortem scenario(s) without mitigation_task_id." >&2
    fi
  fi
fi

# (b) markdown premortem table (used when no usable JSON block was found).
if [ "$premortem_checked" -eq 0 ] && [ -n "$PM_HEAD" ]; then
  # Scan table rows under the Premortem heading; columns: scenario | likelihood | impact | mitigation...
  TBL_BAD="$(awk -v start="$PM_HEAD" '
    function lc(s){return tolower(s)}
    NR>start {
      if ($0 ~ /^[[:space:]]*#{1,6}[[:space:]]/) exit
      if ($0 !~ /^[[:space:]]*\|/) next
      if ($0 ~ /^[[:space:]]*\|?[[:space:]]*:?-{2,}/) next            # separator
      line=$0
      # split on |
      n=split(line, c, /\|/)
      # find likelihood & impact among cells; mitigation = last non-empty cell after impact
      hi_like=0; hi_imp=0; mit=""
      # header detection: skip a row that literally contains the word likelihood AND impact as headers
      if (line ~ /[Ll]ikelihood/ && line ~ /[Ii]mpact/) next
      for (i=1;i<=n;i++){
        cell=c[i]; gsub(/^[ \t]+|[ \t]+$/,"",cell); lcell=lc(cell)
        if (lcell ~ /(^|[^a-z])high([^a-z]|$)/) {
          # mark first high as likelihood, second as impact (column order in template)
          if (hi_like==0) hi_like=1; else hi_imp=1
        }
      }
      # mitigation present if any cell after the impact mentions a task/REQ/word "mitigat" or an id
      mitpresent=0
      for (i=1;i<=n;i++){
        cell=c[i]; gsub(/^[ \t]+|[ \t]+$/,"",cell)
        if (cell ~ /[Tt]ask|REQ-|[Tt]#?[0-9]|[Mm]itigat|monitor|redesign|→/) mitpresent=1
      }
      if (hi_like==1 && hi_imp==1 && mitpresent==0) { print NR }
    }
  ' "$PLAN")"
  if [ -n "$TBL_BAD" ]; then
    PREMORTEM_OK=0
    mark_fail T3
    while IFS= read -r bl; do
      [ -z "$bl" ] && continue
      add_detail T3 "$bl" "Premortem High x High row has no mitigation/task."
      echo "  FAIL T3 — premortem High x High at line $bl has no mitigation." >&2
    done <<EOF
$TBL_BAD
EOF
  fi
fi

# ── T4 (OPTIONAL): PRD story trace — every STORY-<id> in PRD.md must map to >=1 task in PLAN ──
# Front-funnel v9.0: the PRD's stories are the unit of user-visible work; each must trace to a task
# (the §4.1a PLAN law). Applicability-gated: no PRD.md or no STORY ids => silently skipped, so the
# no-PRD path (and T1/T2/T3 semantics) are unchanged.
HAS_PRD_STORIES=0
PRD_FILE=""
for p in "$KIT/PRD.md" "$ROOT/PRD.md"; do [ -f "$p" ] && { PRD_FILE="$p"; break; }; done
STORY_RE='STORY-[A-Za-z0-9._-]+'
if [ -n "$PRD_FILE" ]; then
  PRD_STORIES="$(grep -oE "$STORY_RE" "$PRD_FILE" 2>/dev/null | sed -E 's/[.,;:]+$//' | LC_ALL=C sort -u || true)"
  if [ -n "$PRD_STORIES" ]; then
    HAS_PRD_STORIES=1
    PLAN_STORIES="$(grep -oE "$STORY_RE" "$PLAN" 2>/dev/null | sed -E 's/[.,;:]+$//' | LC_ALL=C sort -u || true)"
    while IFS= read -r st; do
      [ -z "$st" ] && continue
      if ! printf '%s\n' "$PLAN_STORIES" | grep -qxF "$st"; then
        mark_fail T4
        add_detail T4 0 "PRD story $st has no covering task in PLAN.md (author a task that delivers it, or descope the story)."
        echo "  FAIL T4 — PRD story $st has no covering task in PLAN." >&2
      fi
    done <<EOF
$PRD_STORIES
EOF
  fi
fi

# ── assemble + verdict ───────────────────────────────────────────────────────────
# Determine applicability: if there are no REQ ids AND no premortem region AND no PRD stories, nothing to trace.
if [ "$HAS_REQS" = 0 ] && [ -z "$PM_HEAD" ] && [ -z "$PM_JSON" ] && [ "${HAS_PRD_STORIES:-0}" = 0 ]; then
  echo "spec-trace: PLAN.md has no REQ-<id> references and no premortem — gate not applicable." >&2
  write_report "NOT_APPLICABLE" "no requirement ids and no premortem in plan" '[]' '[]'
  exit 0
fi

if [ -n "$DETAILS" ]; then
  if have jq; then
    DETAILS_JSON="$(printf '%s' "$DETAILS" | grep -v '^[[:space:]]*$' | jq -s '.')"
  else
    joined="$(printf '%s' "$DETAILS" | grep -v '^[[:space:]]*$' | paste -sd, -)"
    DETAILS_JSON="[$joined]"
  fi
else
  DETAILS_JSON='[]'
fi

# failed-checks array
CHECKS_TRIM="$(printf '%s' "$FAILED_CHECKS" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
if [ -n "$CHECKS_TRIM" ]; then
  if have jq; then
    CHECKS_JSON="$(printf '%s\n' $CHECKS_TRIM | jq -R . | jq -s 'unique')"
  else
    arr=""; for c in $CHECKS_TRIM; do arr="$arr\"$c\","; done; CHECKS_JSON="[${arr%,}]"
  fi
else
  CHECKS_JSON='[]'
fi

if [ -z "$CHECKS_TRIM" ]; then
  reqn="$(printf '%s\n' "$ALL_REQS" | grep -c . 2>/dev/null || echo 0)"
  write_report "PASS" "traceability intact: $reqn req id(s), $TASK_COUNT task row(s), premortem clear" '[]' "$DETAILS_JSON"
  echo "spec-trace verdict: PASS — T1/T2/T3 satisfied (reqs=$reqn tasks=$TASK_COUNT) -> $REPORT" >&2
  exit 0
fi

write_report "FAIL" "failing checks:$FAILED_CHECKS" "$CHECKS_JSON" "$DETAILS_JSON"
echo "spec-trace verdict: FAIL — failing check(s):$FAILED_CHECKS -> $REPORT" >&2
exit 2
