#!/usr/bin/env bash
# WALTEUR self-improvement-gate - compounding harness and project improvement gate.
#
# Contract:
#   - No self-improvement report before plan             => NOT_APPLICABLE, exit 0.
#   - Plan/build/verify/review/ship/reflect without it   => FAIL, exit 2.
#   - Report without trace mining, current GitHub scout,
#     bounded proposals, regression proof, or learning   => FAIL, exit 2.
#   - Complete measured improvement loop                 => PASS, exit 0.
#
# Report:
#   walteur-kit/self-improvement-report.json
#
# Bypass:
#   WALTEUR_SELF_IMPROVEMENT=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "self-improvement-gate - compounding harness and project improvement gate."
  printf '%s\n' "usage: bash self-improvement-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/self-improvement-report.json - fix recipes: walteur-kit/REMEDIATION.md (## self-improvement-gate)"
  printf '%s\n' "bypass: WALTEUR_SELF_IMPROVEMENT=off (recorded, not free)"
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
LOOP="$KIT/self-improvement.json"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/self-improvement-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CURRENT_YEAR="$(date -u +%Y)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_report() {
  verdict="$1"
  mode="$2"
  reason="$3"
  findings_json="${4:-[]}"
  if have jq; then
    jq -n \
      --arg v "$verdict" --arg ts "$TS" --arg mode "$mode" --arg reason "$reason" \
      --arg loop_file "${LOOP#"$ROOT"/}" --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"self-improvement-gate", mode:$mode, self_improvement_file:$loop_file, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"self-improvement-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0\n'
}

detect_required() {
  IMPROVEMENT_REQUIRED=0
  IMPROVEMENT_REQUIRED_REASON=""

  if [ "${WALTEUR_SELF_IMPROVEMENT_REQUIRED:-}" = "1" ]; then
    IMPROVEMENT_REQUIRED=1
    IMPROVEMENT_REQUIRED_REASON="WALTEUR_SELF_IMPROVEMENT_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      plan|build|verify|review|ship|reflect)
        IMPROVEMENT_REQUIRED=1
        IMPROVEMENT_REQUIRED_REASON="STATE.phase=$phase"
        return 0 ;;
    esac
  fi
}

resolve_ref() {
  ref="$1"
  ref_file="${ref%%#*}"
  [ -n "$ref_file" ] || return 1
  case "$ref_file" in
    /*)
      case "$ref_file" in "$ROOT"/*) printf '%s\n' "$ref_file"; return 0 ;; *) return 1 ;; esac ;;
    *..*) return 1 ;;
    *) printf '%s\n' "$ROOT/$ref_file"; return 0 ;;
  esac
}

check_ref() {
  label="$1"
  ref="$2"
  path="$(resolve_ref "$ref" 2>/dev/null || true)"
  if [ -z "$path" ]; then
    add_finding "$label" "$label must be a relative path inside the project"
    return 0
  fi
  [ -f "$path" ] || add_finding "$label" "$label points to missing file: $ref"
}

latest_source_mtime() {
  latest=0
  update_latest() {
    f="$1"
    [ -f "$f" ] || return 0
    case "$f" in
      "$REPORT"|"$LOOP") return 0 ;;
    esac
    mt="$(mtime "$f")"
    [ "${mt:-0}" -gt "$latest" ] && latest="$mt"
  }

  if [ -d "$ROOT" ]; then
    while IFS= read -r -d '' f; do
      update_latest "$f"
    done < <(find "$ROOT" \
      \( -path '*/.git/*' -o -path '*/node_modules/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path "$KIT/*" \) -prune -o \
      -type f -print0 2>/dev/null)
  fi

  for f in \
    "$ROOT/PLAN.md" \
    "$ROOT/DESIGN.md" \
    "$KIT/PRD.md" \
    "$KIT/build-contract.json" \
    "$KIT/autopilot/STATE.json" \
    "$KIT/run-trace.json" \
    "$KIT/outcome-eval.json" \
    "$KIT/qa-report.json" \
    "$KIT/scoreboard.json" \
    "$KIT/audit.json" \
    "$KIT/DEFINITION-OF-DONE.md"
  do
    update_latest "$f"
  done

  printf '%s\n' "$latest"
}

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

  if ! have jq; then
    echo "self-improvement-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    root="$1"
    phase="$2"
    mkdir -p "$root/walteur-kit/autopilot"
    jq -n --arg phase "$phase" '{phase:$phase}' > "$root/walteur-kit/autopilot/STATE.json"
  }

  write_sources() {
    root="$1"
    mkdir -p "$root/src" "$root/walteur-kit/evidence"
    printf 'export const App = () => "done";\n' > "$root/src/App.tsx"
    printf '# Plan\nBuild an enterprise app.\n' > "$root/PLAN.md"
    printf 'trace evidence\n' > "$root/walteur-kit/evidence/trace.json"
    printf 'scout evidence\n' > "$root/walteur-kit/evidence/scout.md"
    printf 'baseline green\n' > "$root/walteur-kit/evidence/baseline.txt"
    printf 'current green\n' > "$root/walteur-kit/evidence/current.txt"
    printf 'regression green\n' > "$root/walteur-kit/evidence/regression.txt"
    printf 'rollback documented\n' > "$root/walteur-kit/evidence/rollback.md"
    printf 'lesson captured\n' > "$root/walteur-kit/evidence/memory-capture.json"
    # skill-mint fixtures (authored skill + recurrence provenance + quality verdicts)
    mkdir -p "$root/walteur-kit/evidence/minted-skill"
    printf -- '---\nname: minted-workflow\ndescription: A reusable workflow minted from a recurring build gap.\n---\n# Minted Workflow\n' > "$root/walteur-kit/evidence/minted-skill/SKILL.md"
    printf '{"cluster":"repeated-deploy-steps","support":3,"evidence":"trace"}\n' > "$root/walteur-kit/evidence/skill-provenance.json"
    printf '{"verdict":"PASS","gate":"skill-quality"}\n' > "$root/walteur-kit/evidence/skill-quality-pass.json"
    printf '{"verdict":"FAIL","gate":"skill-quality"}\n' > "$root/walteur-kit/evidence/skill-quality-fail.json"
  }

  write_good_loop() {
    root="$1"
    mode="${2:-good}"
    year="$CURRENT_YEAR"
    mkdir -p "$root/walteur-kit"
    jq -n --arg mode "$mode" --arg year "$year" '
      {
        schema_version: 1,
        verdict: "PASS",
        trace_mining: {
          trace_refs: ["walteur-kit/evidence/trace.json"],
          failure_clusters: [
            {
              id: "missing-evidence-loop",
              support: 3,
              mechanism: "Agent claimed done before reading gate reports.",
              evidence_ref: "walteur-kit/evidence/trace.json",
              proposed_response: "Add a stricter done-proof gate."
            }
          ]
        },
        scout: {
          performed: true,
          date: ($year + "-06-22"),
          sources: [
            {
              kind: "github_repo",
              name: "langchain-ai/langgraph",
              url: "https://github.com/langchain-ai/langgraph",
              captured_ref: "walteur-kit/evidence/scout.md"
            }
          ],
          candidates: [
            {
              name: "LangGraph durability pattern",
              url: "https://github.com/langchain-ai/langgraph",
              license: "MIT",
              last_checked: ($year + "-06-22"),
              fit: "Durable state and human review pattern for long-running agents.",
              maintenance: "Active release stream reviewed.",
              security: "No adoption without local dependency and license review.",
              decision: "defer",
              evidence_ref: "walteur-kit/evidence/scout.md"
            }
          ]
        },
        proposals: [
          {
            id: "p1",
            source: "weakness-mining",
            change: "Require independent outcome evaluation before ship.",
            bounded: true,
            status: "promoted",
            validation_ref: "walteur-kit/evidence/regression.txt",
            rollback_ref: "walteur-kit/evidence/rollback.md",
            delta: {
              quality_delta: 0.1,
              regressions: 0,
              cost_delta_usd: 0
            }
          }
        ],
        regression: {
          baseline_ref: "walteur-kit/evidence/baseline.txt",
          current_ref: "walteur-kit/evidence/current.txt",
          regressions: 0,
          commands: [
            {
              command: "bash walteur-kit/selftest.sh",
              exit_code: 0,
              evidence_ref: "walteur-kit/evidence/regression.txt"
            }
          ]
        },
        compounding: {
          memory_updates: [
            {
              lesson: "Promote harness changes only after regression proof.",
              target_ref: "walteur-kit/evidence/scout.md",
              result_ref: "walteur-kit/evidence/memory-capture.json",
              captured: true
            }
          ],
          next_watch: "Mine next run traces for repeated failure clusters."
        },
        ts: "2026-06-22T00:00:00Z"
      }
      | if $mode == "no-github" then .scout.sources[0].kind = "docs" | .scout.sources[0].url = "https://example.com/docs" | .scout.candidates[0].url = "https://example.com/docs" else . end
      | if $mode == "old-scout" then .scout.date = "2025-01-01" | .scout.candidates[0].last_checked = "2025-01-01" else . end
      | if $mode == "unchecked-security" then .scout.candidates[0].security = "unknown" else . end
      | if $mode == "unbounded" then .proposals[0].bounded = false else . end
      | if $mode == "missing-rollback" then del(.proposals[0].rollback_ref) else . end
      | if $mode == "regression-fail" then .regression.regressions = 1 | .regression.commands[0].exit_code = 2 | .proposals[0].delta.regressions = 1 else . end
      | if $mode == "missing-memory-result" then del(.compounding.memory_updates[0].result_ref) else . end
      | if $mode == "no-change" then .proposals[0].status = "no_change" | del(.proposals[0].rollback_ref) | .proposals[0].change = "No safe change promoted after scout and regression review." else . end
      | if $mode == "skill-mint-good" then .proposals += [{id:"sm1", source:"skill-mint", change:"Mint the recurring deploy workflow into a reusable skill.", bounded:true, status:"promoted", validation_ref:"walteur-kit/evidence/regression.txt", rollback_ref:"walteur-kit/evidence/rollback.md", minted_skill_path:"walteur-kit/evidence/minted-skill/SKILL.md", provenance_ref:"walteur-kit/evidence/skill-provenance.json", quality_gate_ref:"walteur-kit/evidence/skill-quality-pass.json", delta:{quality_delta:0.1,regressions:0,cost_delta_usd:0}}] else . end
      | if $mode == "skill-mint-no-quality" then .proposals += [{id:"sm1", source:"skill-mint", change:"Mint the recurring deploy workflow into a reusable skill.", bounded:true, status:"deferred", validation_ref:"walteur-kit/evidence/regression.txt", minted_skill_path:"walteur-kit/evidence/minted-skill/SKILL.md", provenance_ref:"walteur-kit/evidence/skill-provenance.json"}] else . end
      | if $mode == "skill-mint-quality-fail" then .proposals += [{id:"sm1", source:"skill-mint", change:"Mint the recurring deploy workflow into a reusable skill.", bounded:true, status:"deferred", validation_ref:"walteur-kit/evidence/regression.txt", minted_skill_path:"walteur-kit/evidence/minted-skill/SKILL.md", provenance_ref:"walteur-kit/evidence/skill-provenance.json", quality_gate_ref:"walteur-kit/evidence/skill-quality-fail.json"}] else . end
    ' > "$root/walteur-kit/self-improvement.json"
  }

  echo "self-improvement-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/self-improvement-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "no report before plan -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/self-improvement-selftest.XXXXXX")" || return 1
  write_state "$tmp" "plan"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "plan phase missing report -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/self-improvement-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{ bad json\n' > "$tmp/walteur-kit/self-improvement.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "malformed report -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/self-improvement-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{"schema_version":1,"verdict":"PASS"}\n' > "$tmp/walteur-kit/self-improvement.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "shallow report -> FAIL" 2 "$?"
  rm -rf "$tmp"

  for mode in no-github old-scout unchecked-security unbounded missing-rollback regression-fail missing-memory-result skill-mint-no-quality skill-mint-quality-fail; do
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/self-improvement-selftest.XXXXXX")" || return 1
    write_sources "$tmp"
    write_state "$tmp" "plan"
    write_good_loop "$tmp" "$mode"
    WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
    ck "$mode report -> FAIL" 2 "$?"
    rm -rf "$tmp"
  done

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/self-improvement-selftest.XXXXXX")" || return 1
  write_sources "$tmp"
  write_state "$tmp" "plan"
  write_good_loop "$tmp" "good"
  touch -t 202001010000 "$tmp/walteur-kit/self-improvement.json" 2>/dev/null || true
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "stale improvement report after source edit -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/self-improvement-selftest.XXXXXX")" || return 1
  write_sources "$tmp"
  write_state "$tmp" "plan"
  write_good_loop "$tmp" "no-change"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "complete no-change loop -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/self-improvement-selftest.XXXXXX")" || return 1
  write_sources "$tmp"
  write_state "$tmp" "plan"
  write_good_loop "$tmp" "good"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "complete promoted improvement loop -> PASS" 0 "$?"
  rm -rf "$tmp"

  # skill-mint: a fully-provenanced minted skill with a PASSING quality verdict -> PASS
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/self-improvement-selftest.XXXXXX")" || return 1
  write_sources "$tmp"
  write_state "$tmp" "plan"
  write_good_loop "$tmp" "skill-mint-good"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "skill-mint with provenance + authored SKILL.md + PASS quality -> PASS" 0 "$?"
  rm -rf "$tmp"

  echo "self-improvement-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && {
  write_report "FAIL" "paused" "walteur-kit/PAUSED present" '[{"check":"paused","message":"WALTEUR is paused"}]'
  echo "self-improvement-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
}

if [ "${WALTEUR_SELF_IMPROVEMENT:-on}" = "off" ]; then
  write_report "SKIP" "bypass" "WALTEUR_SELF_IMPROVEMENT=off" "[]"
  echo "self-improvement-gate verdict: SKIP - bypassed via WALTEUR_SELF_IMPROVEMENT=off -> $REPORT" >&2
  exit 0
fi

if ! have jq; then
  write_report "SKIP" "tool-missing" "jq not installed" "[]"
  echo "self-improvement-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  exit 0
fi

detect_required

if [ ! -f "$LOOP" ]; then
  if [ "$IMPROVEMENT_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "missing" "self-improvement report required ($IMPROVEMENT_REQUIRED_REASON) but walteur-kit/self-improvement.json is absent" \
      '[{"check":"self_improvement.present","message":"plan and later phases require walteur-kit/self-improvement.json shaped by walteur-kit/schemas/self-improvement.schema.json"}]'
    echo "self-improvement-gate verdict: FAIL - report missing while required ($IMPROVEMENT_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "not-applicable" "no self-improvement report and current phase does not require one" "[]"
  echo "self-improvement-gate verdict: NOT_APPLICABLE - no report before plan -> $REPORT" >&2
  exit 0
fi

if [ ! -s "$LOOP" ]; then
  if [ "$IMPROVEMENT_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "empty" "self-improvement report required ($IMPROVEMENT_REQUIRED_REASON) but walteur-kit/self-improvement.json is empty" \
      '[{"check":"self_improvement.nonempty","message":"zero-byte self-improvement stubs cannot satisfy plan or later phases"}]'
    echo "self-improvement-gate verdict: FAIL - empty report while required ($IMPROVEMENT_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "runtime-stub" "zero-byte runtime self-improvement stub before plan" "[]"
  echo "self-improvement-gate verdict: NOT_APPLICABLE - zero-byte runtime stub before plan -> $REPORT" >&2
  exit 0
fi

if ! jq empty "$LOOP" >/dev/null 2>&1; then
  write_report "FAIL" "invalid-json" "walteur-kit/self-improvement.json is invalid JSON" \
    '[{"check":"self_improvement.json","message":"walteur-kit/self-improvement.json must be valid JSON"}]'
  echo "self-improvement-gate verdict: FAIL - self-improvement JSON invalid -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

if ! jq -e '.schema_version == 1' "$LOOP" >/dev/null 2>&1; then
  add_finding "schema_version" "schema_version must be 1"
fi
if ! jq -e '.verdict == "PASS"' "$LOOP" >/dev/null 2>&1; then
  add_finding "verdict" "self-improvement verdict must be PASS"
fi

if ! jq -e '.trace_mining.trace_refs | type == "array" and length > 0' "$LOOP" >/dev/null 2>&1; then
  add_finding "trace_mining.trace_refs" "trace mining requires at least one trace_ref"
else
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    check_ref "trace_mining.trace_refs" "$ref"
  done < <(jq -r '.trace_mining.trace_refs[]?' "$LOOP")
fi
while IFS=$'\t' read -r id ref; do
  [ -n "$id" ] || continue
  [ -n "$ref" ] && check_ref "trace_mining.failure_clusters.$id.evidence_ref" "$ref"
done <<EOF
$(jq -r '.trace_mining.failure_clusters[]? | [(.id // "cluster"), (.evidence_ref // "")] | @tsv' "$LOOP")
EOF

if ! jq -e '.scout.performed == true' "$LOOP" >/dev/null 2>&1; then
  add_finding "scout.performed" "scout.performed must be true"
fi
if ! jq -e --arg y "$CURRENT_YEAR" '.scout.date | type == "string" and startswith($y + "-")' "$LOOP" >/dev/null 2>&1; then
  add_finding "scout.date" "scout.date must be in the current UTC year"
fi
if ! jq -e '.scout.sources | type == "array" and length > 0' "$LOOP" >/dev/null 2>&1; then
  add_finding "scout.sources" "scout.sources requires at least one source"
elif ! jq -e '.scout.sources | map(select(.kind == "github_repo" and (.url | startswith("https://github.com/")))) | length > 0' "$LOOP" >/dev/null 2>&1; then
  add_finding "scout.sources.github" "scout must include at least one current GitHub repository source"
fi
while IFS=$'\t' read -r name ref; do
  [ -n "$name" ] || continue
  check_ref "scout.sources.$name.captured_ref" "$ref"
done <<EOF
$(jq -r '.scout.sources[]? | [(.name // "source"), (.captured_ref // "")] | @tsv' "$LOOP")
EOF

if ! jq -e '.scout.candidates | type == "array" and length > 0' "$LOOP" >/dev/null 2>&1; then
  add_finding "scout.candidates" "scout.candidates requires at least one reviewed candidate"
elif ! jq -e '.scout.candidates | map(select(.url | startswith("https://github.com/"))) | length > 0' "$LOOP" >/dev/null 2>&1; then
  add_finding "scout.candidates.github" "at least one scout candidate must be a GitHub repository"
fi
bad_candidates="$(jq -r --arg y "$CURRENT_YEAR" '
  [.scout.candidates[]? | select(
    ((.name // "") | length == 0) or
    ((.url // "") | length == 0) or
    ((.license // "") | length == 0) or
    ((.fit // "") | length == 0) or
    ((.maintenance // "") | length == 0) or
    ((.security // "") | length == 0) or
    ((.security // "" | ascii_downcase) | test("unknown|unchecked|todo|tbd")) or
    ((.last_checked // "") | startswith($y + "-") | not) or
    (.decision as $d | ["adopt","defer","reject"] | index($d) | not) or
    ((.evidence_ref // "") | length == 0)
  )] | length
' "$LOOP")"
if [ "${bad_candidates:-0}" -gt 0 ]; then
  add_finding "scout.candidates.shape" "$bad_candidates scout candidate(s) are missing license, current check, fit, maintenance, security review, decision, or evidence"
fi
while IFS=$'\t' read -r name ref; do
  [ -n "$name" ] || continue
  check_ref "scout.candidates.$name.evidence_ref" "$ref"
done <<EOF
$(jq -r '.scout.candidates[]? | [(.name // "candidate"), (.evidence_ref // "")] | @tsv' "$LOOP")
EOF

if ! jq -e '.proposals | type == "array" and length > 0' "$LOOP" >/dev/null 2>&1; then
  add_finding "proposals" "self-improvement loop requires at least one proposal or no_change decision"
fi
if ! jq -e 'all(.proposals[]?; ((.id // "") | length > 0) and ((.change // "") | length > 0) and (.bounded == true) and (.status as $s | ["promoted","rejected","deferred","no_change"] | index($s)) and ((.validation_ref // "") | length > 0))' "$LOOP" >/dev/null 2>&1; then
  add_finding "proposals.shape" "each proposal needs id, change, bounded:true, valid status, and validation_ref"
fi
# skill-mint proposals (Hermes "it also creates its own skills"): a recurring reusable-workflow gap turned
# into a NEW skill must carry recurrence PROVENANCE + the authored SKILL.md + a PASSING quality verdict.
# This closes the self-improvement loop from CONSUME-only to MINT — without letting a skill be claimed unproven.
while IFS=$'\t' read -r id msp prov qg; do
  [ -n "$id" ] || continue
  if [ -z "$msp" ]; then add_finding "proposals.$id.minted_skill_path" "skill-mint proposal must cite the authored SKILL.md (minted_skill_path)"; else check_ref "proposals.$id.minted_skill_path" "$msp"; fi
  if [ -z "$prov" ]; then add_finding "proposals.$id.provenance_ref" "skill-mint proposal must cite recurrence provenance (provenance_ref: a trace/cluster with support>=2 proving the workflow recurred)"; else check_ref "proposals.$id.provenance_ref" "$prov"; fi
  if [ -z "$qg" ]; then
    add_finding "proposals.$id.quality_gate_ref" "skill-mint proposal must cite a PASSING quality-gate verdict (quality_gate_ref -> skill-quality / skill-frontmatter report)"
  else
    check_ref "proposals.$id.quality_gate_ref" "$qg"
    qgp="$(resolve_ref "$qg" 2>/dev/null || true)"
    if [ -n "$qgp" ] && [ -f "$qgp" ] && ! jq -e '.verdict == "PASS"' "$qgp" >/dev/null 2>&1; then
      add_finding "proposals.$id.quality_gate_ref" "minted skill quality_gate_ref verdict is not PASS — a minted skill must pass skill-quality + skill-frontmatter before promotion"
    fi
  fi
done <<EOF
$(jq -r '.proposals[]? | select(.source == "skill-mint") | [(.id // "proposal"), (.minted_skill_path // ""), (.provenance_ref // ""), (.quality_gate_ref // "")] | @tsv' "$LOOP")
EOF
while IFS=$'\t' read -r id ref; do
  [ -n "$id" ] || continue
  check_ref "proposals.$id.validation_ref" "$ref"
done <<EOF
$(jq -r '.proposals[]? | [(.id // "proposal"), (.validation_ref // "")] | @tsv' "$LOOP")
EOF
promoted_bad="$(jq -r '
  [.proposals[]? | select(
    .status == "promoted" and (
      ((.rollback_ref // "") | length == 0) or
      ((.delta.quality_delta // 0) < 0) or
      ((.delta.regressions // 0) != 0)
    )
  )] | length
' "$LOOP")"
if [ "${promoted_bad:-0}" -gt 0 ]; then
  add_finding "proposals.promoted" "promoted proposals require rollback_ref, non-negative quality_delta, and zero regressions"
fi
while IFS=$'\t' read -r id ref; do
  [ -n "$id" ] || continue
  [ -n "$ref" ] && check_ref "proposals.$id.rollback_ref" "$ref"
done <<EOF
$(jq -r '.proposals[]? | select(.status == "promoted") | [(.id // "proposal"), (.rollback_ref // "")] | @tsv' "$LOOP")
EOF

if ! jq -e '.regression.regressions == 0' "$LOOP" >/dev/null 2>&1; then
  add_finding "regression.regressions" "regression.regressions must be 0"
fi
for ref_field in baseline_ref current_ref; do
  if ! jq -e --arg f "$ref_field" '.regression[$f] | type == "string" and length > 0' "$LOOP" >/dev/null 2>&1; then
    add_finding "regression.$ref_field" "regression.$ref_field is required"
  else
    check_ref "regression.$ref_field" "$(jq -r --arg f "$ref_field" '.regression[$f]' "$LOOP")"
  fi
done
if ! jq -e '.regression.commands | type == "array" and length > 0 and all(.[]; ((.command // "") | length > 0) and (.exit_code == 0) and ((.evidence_ref // "") | length > 0))' "$LOOP" >/dev/null 2>&1; then
  add_finding "regression.commands" "regression commands require command, exit_code 0, and evidence_ref"
fi
while IFS=$'\t' read -r cmd ref; do
  [ -n "$cmd" ] || continue
  check_ref "regression.commands.evidence_ref" "$ref"
done <<EOF
$(jq -r '.regression.commands[]? | [(.command // "command"), (.evidence_ref // "")] | @tsv' "$LOOP")
EOF

if ! jq -e '.compounding.memory_updates | type == "array" and length > 0' "$LOOP" >/dev/null 2>&1; then
  add_finding "compounding.memory_updates" "compounding.memory_updates requires at least one lesson or no-change learning"
elif ! jq -e 'all(.compounding.memory_updates[]?; ((.lesson // "") | length > 0) and ((.target_ref // "") | length > 0) and ((.result_ref // "") | length > 0) and (.captured == true))' "$LOOP" >/dev/null 2>&1; then
  add_finding "compounding.memory_updates.shape" "memory updates require lesson, target_ref, result_ref, and captured:true"
fi
while IFS=$'\t' read -r lesson ref result_ref captured; do
  [ -n "$lesson" ] || continue
  lesson_words="$(printf '%s' "$lesson" | awk '{print NF}')"
  [ "${lesson_words:-0}" -le 25 ] || add_finding "compounding.memory_updates.lesson" "memory lesson exceeds 25 words"
  [ "$captured" = "true" ] || add_finding "compounding.memory_updates.captured" "memory update must set captured:true"
  check_ref "compounding.memory_updates.target_ref" "$ref"
  check_ref "compounding.memory_updates.result_ref" "$result_ref"
done <<EOF
$(jq -r '.compounding.memory_updates[]? | [(.lesson // ""), (.target_ref // ""), (.result_ref // ""), (.captured // false)] | @tsv' "$LOOP")
EOF
if ! jq -e '.compounding.next_watch | type == "string" and length > 0' "$LOOP" >/dev/null 2>&1; then
  add_finding "compounding.next_watch" "compounding.next_watch is required"
fi
if ! jq -e '.ts | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$LOOP" >/dev/null 2>&1; then
  add_finding "ts" "ts must be UTC ISO format YYYY-MM-DDTHH:MM:SSZ"
fi

placeholder_hits="$(jq -r '
  .. | strings
  | select(test("(^|\\b)(TODO|TBD|FIXME|placeholder|lorem ipsum)(\\b|$)|<[^>]+>"; "i"))
' "$LOOP" 2>/dev/null | head -5 | paste -sd ' | ' -)"
[ -n "$placeholder_hits" ] && add_finding "placeholder" "self-improvement report contains placeholder text: $placeholder_hits"

loop_mtime="$(mtime "$LOOP")"
latest_mtime="$(latest_source_mtime)"
if [ "${latest_mtime:-0}" -gt "${loop_mtime:-0}" ]; then
  add_finding "freshness" "self-improvement report is older than at least one source, trace, eval, QA, score, audit, or state artifact"
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "strict self-improvement contract failed with $failures finding(s)" "$findings"
  echo "self-improvement-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "pass" "self-improvement loop includes trace mining, current GitHub scout, bounded proposals, regression proof, and learning capture" "$findings"
echo "self-improvement-gate verdict: PASS - compounding improvement loop complete -> $REPORT" >&2
exit 0
