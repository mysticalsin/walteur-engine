#!/usr/bin/env bash
# WALTEUR outcome-eval-gate - independent outcome evaluator contract.
#
# Contract:
#   - No outcome eval and not in review/ship/reflect phase => NOT_APPLICABLE, exit 0.
#   - Empty runtime eval stub before review                 => NOT_APPLICABLE, exit 0.
#   - Review/ship/reflect without valid outcome eval        => FAIL, exit 2.
#   - PASS eval without independent evaluator, rubric,
#     evidence refs, confidence, bias checks, or freshness  => FAIL, exit 2.
#   - Complete independent outcome evaluation               => PASS, exit 0.
#
# Report:
#   walteur-kit/outcome-eval-report.json
#
# Bypass:
#   WALTEUR_OUTCOME_EVAL=off
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
EVAL="$KIT/outcome-eval.json"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/outcome-eval-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
      --arg eval_file "${EVAL#"$ROOT"/}" --argjson findings "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"outcome-eval-gate", mode:$mode, eval_file:$eval_file, reason:$reason, findings:$findings}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"outcome-eval-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0\n'
}

detect_required() {
  OUTCOME_REQUIRED=0
  OUTCOME_REQUIRED_REASON=""

  if [ "${WALTEUR_OUTCOME_EVAL_REQUIRED:-}" = "1" ]; then
    OUTCOME_REQUIRED=1
    OUTCOME_REQUIRED_REASON="WALTEUR_OUTCOME_EVAL_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      review|ship|reflect)
        OUTCOME_REQUIRED=1
        OUTCOME_REQUIRED_REASON="STATE.phase=$phase"
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
      "$REPORT"|"$EVAL") return 0 ;;
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
    "$KIT/layers.json" \
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
    echo "outcome-eval-gate selftest SKIP - jq not installed."
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
    mkdir -p "$root/src" "$root/walteur-kit"
    printf 'export const App = () => "done";\n' > "$root/src/App.tsx"
    printf '# Goal\nBuild the requested outcome.\n' > "$root/PLAN.md"
    printf 'unit test output\n' > "$root/walteur-kit/test-output.txt"
    printf 'accessibility output\n' > "$root/walteur-kit/a11y-output.txt"
    printf 'security output\n' > "$root/walteur-kit/security-output.txt"
  }

  write_good_eval() {
    root="$1"
    mode="${2:-good}"
    mkdir -p "$root/walteur-kit"
    jq -n --arg mode "$mode" '
      {
        schema_version: 1,
        verdict: "PASS",
        subject: {
          artifact_ref: "src/App.tsx",
          task_context_ref: "PLAN.md"
        },
        evaluator: {
          kind: "llm",
          name: "Independent outcome evaluator",
          model: "gpt-5",
          independent_from_builder: true,
          bias_checks: {
            leniency: "Reviewer checked for soft-pass bias.",
            verbosity: "Reviewer ignored length as quality unless tied to user value.",
            self_preference: "Reviewer did not score own build."
          }
        },
        rubric: {
          scale: { min: 0, max: 10 },
          pass_threshold: 8.5,
          criteria: [
            { id: "outcome", name: "Outcome fit", weight: 0.4, score: 9.0, confidence: 0.86, critical: true, evidence_ref: "walteur-kit/test-output.txt", feedback: "Core outcome is present." },
            { id: "quality", name: "Engineering quality", weight: 0.3, score: 9.0, confidence: 0.84, critical: true, evidence_ref: "walteur-kit/security-output.txt", feedback: "No blocking issue found." },
            { id: "experience", name: "User experience", weight: 0.3, score: 9.0, confidence: 0.82, evidence_ref: "walteur-kit/a11y-output.txt", feedback: "Experience checks pass." }
          ]
        },
        overall: {
          score: 9.0,
          confidence: 0.84,
          summary: "The artifact meets the requested outcome with evidence."
        },
        blockers: [],
        ts: "2026-06-22T00:00:00Z"
      }
      | if $mode == "self-review" then .evaluator.independent_from_builder = false else . end
      | if $mode == "bad-weights" then .rubric.criteria[2].weight = 0.1 else . end
      | if $mode == "low-score" then .overall.score = 7.5 else . end
      | if $mode == "low-confidence" then .overall.confidence = 0.4 else . end
      | if $mode == "critical-low" then .rubric.criteria[0].score = 7.0 else . end
      | if $mode == "missing-evidence" then .rubric.criteria[1].evidence_ref = "walteur-kit/missing.txt" else . end
      | if $mode == "no-bias" then del(.evaluator.bias_checks) else . end
    ' > "$root/walteur-kit/outcome-eval.json"
  }

  echo "outcome-eval-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/outcome-eval-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "no eval before review -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/outcome-eval-selftest.XXXXXX")" || return 1
  write_state "$tmp" "review"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "review phase missing eval -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/outcome-eval-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  : > "$tmp/walteur-kit/outcome-eval.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "zero-byte eval before review -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/outcome-eval-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{ bad json\n' > "$tmp/walteur-kit/outcome-eval.json"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "malformed eval -> FAIL" 2 "$?"
  rm -rf "$tmp"

  for mode in self-review bad-weights low-score low-confidence critical-low missing-evidence no-bias; do
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/outcome-eval-selftest.XXXXXX")" || return 1
    write_sources "$tmp"
    write_state "$tmp" "review"
    write_good_eval "$tmp" "$mode"
    WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
    ck "$mode eval -> FAIL" 2 "$?"
    rm -rf "$tmp"
  done

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/outcome-eval-selftest.XXXXXX")" || return 1
  write_sources "$tmp"
  write_state "$tmp" "review"
  write_good_eval "$tmp" "good"
  touch -t 202001010000 "$tmp/walteur-kit/outcome-eval.json" 2>/dev/null || true
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "stale eval after source edit -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/outcome-eval-selftest.XXXXXX")" || return 1
  write_sources "$tmp"
  write_state "$tmp" "review"
  write_good_eval "$tmp" "good"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "complete independent eval -> PASS" 0 "$?"
  rm -rf "$tmp"

  echo "outcome-eval-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && {
  write_report "FAIL" "paused" "walteur-kit/PAUSED present" '[{"check":"paused","message":"WALTEUR is paused"}]'
  echo "outcome-eval-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
}

if [ "${WALTEUR_OUTCOME_EVAL:-on}" = "off" ]; then
  write_report "SKIP" "bypass" "WALTEUR_OUTCOME_EVAL=off" "[]"
  echo "outcome-eval-gate verdict: SKIP - bypassed via WALTEUR_OUTCOME_EVAL=off -> $REPORT" >&2
  exit 0
fi

if ! have jq; then
  write_report "SKIP" "tool-missing" "jq not installed" "[]"
  echo "outcome-eval-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  exit 0
fi

detect_required

if [ ! -f "$EVAL" ]; then
  if [ "$OUTCOME_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "missing" "outcome eval required ($OUTCOME_REQUIRED_REASON) but walteur-kit/outcome-eval.json is absent" \
      '[{"check":"outcome_eval.present","message":"review/ship/reflect requires walteur-kit/outcome-eval.json shaped by walteur-kit/schemas/outcome-eval.schema.json"}]'
    echo "outcome-eval-gate verdict: FAIL - eval missing while required ($OUTCOME_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "not-applicable" "no outcome eval and current phase does not require one" "[]"
  echo "outcome-eval-gate verdict: NOT_APPLICABLE - no outcome eval before review -> $REPORT" >&2
  exit 0
fi

if [ ! -s "$EVAL" ]; then
  if [ "$OUTCOME_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "empty" "outcome eval required ($OUTCOME_REQUIRED_REASON) but walteur-kit/outcome-eval.json is empty" \
      '[{"check":"outcome_eval.nonempty","message":"zero-byte outcome eval stubs cannot satisfy review/ship/reflect"}]'
    echo "outcome-eval-gate verdict: FAIL - empty eval while required ($OUTCOME_REQUIRED_REASON) -> $REPORT" >&2
    exit 2
  fi
  write_report "NOT_APPLICABLE" "runtime-stub" "zero-byte runtime outcome eval stub before review" "[]"
  echo "outcome-eval-gate verdict: NOT_APPLICABLE - zero-byte runtime outcome eval stub before review -> $REPORT" >&2
  exit 0
fi

if ! jq empty "$EVAL" >/dev/null 2>&1; then
  write_report "FAIL" "invalid-json" "walteur-kit/outcome-eval.json is invalid JSON" \
    '[{"check":"outcome_eval.json","message":"walteur-kit/outcome-eval.json must be valid JSON"}]'
  echo "outcome-eval-gate verdict: FAIL - outcome eval JSON invalid -> $REPORT" >&2
  exit 2
fi

findings='[]'
failures=0

if ! jq -e '.schema_version == 1' "$EVAL" >/dev/null 2>&1; then
  add_finding "schema_version" "schema_version must be 1"
fi
if ! jq -e '.verdict == "PASS"' "$EVAL" >/dev/null 2>&1; then
  add_finding "verdict" "outcome evaluation verdict must be PASS"
fi
if ! jq -e '.subject.artifact_ref | type == "string" and length > 0' "$EVAL" >/dev/null 2>&1; then
  add_finding "subject.artifact_ref" "subject.artifact_ref is required"
else
  check_ref "subject.artifact_ref" "$(jq -r '.subject.artifact_ref' "$EVAL")"
fi
if ! jq -e '.subject.task_context_ref | type == "string" and length > 0' "$EVAL" >/dev/null 2>&1; then
  add_finding "subject.task_context_ref" "subject.task_context_ref is required"
else
  check_ref "subject.task_context_ref" "$(jq -r '.subject.task_context_ref' "$EVAL")"
fi
if ! jq -e '.evaluator.kind as $k | ["human","llm","hybrid"] | index($k)' "$EVAL" >/dev/null 2>&1; then
  add_finding "evaluator.kind" "evaluator.kind must be human, llm, or hybrid"
fi
if ! jq -e '.evaluator.name | type == "string" and length > 0' "$EVAL" >/dev/null 2>&1; then
  add_finding "evaluator.name" "evaluator.name is required"
fi
if ! jq -e '.evaluator.independent_from_builder == true' "$EVAL" >/dev/null 2>&1; then
  add_finding "evaluator.independence" "evaluator must be independent from builder"
fi

kind="$(jq -r '.evaluator.kind // empty' "$EVAL")"
case "$kind" in
  llm|hybrid)
    if ! jq -e '.evaluator.model | type == "string" and length > 0' "$EVAL" >/dev/null 2>&1; then
      add_finding "evaluator.model" "llm or hybrid evaluator requires model"
    fi
    for bias in leniency verbosity self_preference; do
      if ! jq -e --arg b "$bias" '.evaluator.bias_checks[$b] | type == "string" and length > 0' "$EVAL" >/dev/null 2>&1; then
        add_finding "evaluator.bias_checks.$bias" "llm or hybrid evaluator requires bias check: $bias"
      fi
    done ;;
esac

if ! jq -e '.rubric.scale.min | type == "number"' "$EVAL" >/dev/null 2>&1 \
  || ! jq -e '.rubric.scale.max | type == "number"' "$EVAL" >/dev/null 2>&1 \
  || ! jq -e '.rubric.scale.max > .rubric.scale.min' "$EVAL" >/dev/null 2>&1; then
  add_finding "rubric.scale" "rubric scale requires numeric min and max with max > min"
fi
if ! jq -e '.rubric.pass_threshold | type == "number"' "$EVAL" >/dev/null 2>&1; then
  add_finding "rubric.pass_threshold" "rubric.pass_threshold must be numeric"
fi
if ! jq -e '.rubric.criteria | type == "array" and length >= 3 and length <= 7' "$EVAL" >/dev/null 2>&1; then
  add_finding "rubric.criteria" "rubric requires 3 to 7 criteria"
else
  if ! jq -e '.rubric as $r | all($r.criteria[]; ((.id // "") | length > 0) and ((.name // "") | length > 0) and (.weight | type == "number" and . > 0) and (.score | type == "number" and . >= $r.scale.min and . <= $r.scale.max) and (.confidence | type == "number" and . >= 0.7 and . <= 1) and ((.evidence_ref // "") | length > 0) and ((.feedback // "") | length > 0))' "$EVAL" >/dev/null 2>&1; then
    add_finding "rubric.criteria.shape" "each criterion needs id, name, positive weight, in-scale score, confidence >= 0.7, evidence_ref, and feedback"
  fi
  if ! jq -e '([.rubric.criteria[]?.weight] | add) as $s | ($s >= 0.99 and $s <= 1.01)' "$EVAL" >/dev/null 2>&1; then
    add_finding "rubric.criteria.weights" "criterion weights must sum to 1.0 within 0.01"
  fi
  if ! jq -e '.rubric as $r | all($r.criteria[]; ((.critical // false) != true) or (.score >= $r.pass_threshold))' "$EVAL" >/dev/null 2>&1; then
    add_finding "rubric.criteria.critical" "critical criteria must meet the pass threshold"
  fi
  while IFS=$'\t' read -r id ref; do
    [ -n "$id" ] || continue
    check_ref "rubric.criteria.$id.evidence_ref" "$ref"
  done <<EOF
$(jq -r '.rubric.criteria[]? | [(.id // "criterion"), (.evidence_ref // "")] | @tsv' "$EVAL")
EOF
fi

if ! jq -e '(.overall.score | type == "number") and (.overall.score >= .rubric.scale.min) and (.overall.score <= .rubric.scale.max)' "$EVAL" >/dev/null 2>&1; then
  add_finding "overall.score" "overall.score must be numeric and within scale"
elif ! jq -e '.overall.score >= .rubric.pass_threshold' "$EVAL" >/dev/null 2>&1; then
  add_finding "overall.pass_threshold" "overall.score is below pass threshold"
fi
if ! jq -e '(.overall.confidence | type == "number") and (.overall.confidence >= 0.7) and (.overall.confidence <= 1)' "$EVAL" >/dev/null 2>&1; then
  add_finding "overall.confidence" "overall.confidence must be >= 0.7"
fi
if ! jq -e '.overall.summary | type == "string" and length > 0' "$EVAL" >/dev/null 2>&1; then
  add_finding "overall.summary" "overall.summary is required"
fi
if ! jq -e '.blockers | type == "array" and length == 0' "$EVAL" >/dev/null 2>&1; then
  add_finding "blockers" "PASS outcome eval cannot contain blockers"
fi
if ! jq -e '.ts | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$EVAL" >/dev/null 2>&1; then
  add_finding "ts" "ts must be UTC ISO format YYYY-MM-DDTHH:MM:SSZ"
fi

placeholder_hits="$(jq -r '
  .. | strings
  | select(test("(^|\\b)(TODO|TBD|FIXME|placeholder|lorem ipsum)(\\b|$)|<[^>]+>"; "i"))
' "$EVAL" 2>/dev/null | head -5 | paste -sd ' | ' -)"
[ -n "$placeholder_hits" ] && add_finding "placeholder" "outcome eval contains placeholder text: $placeholder_hits"

eval_mtime="$(mtime "$EVAL")"
latest_mtime="$(latest_source_mtime)"
if [ "${latest_mtime:-0}" -gt "${eval_mtime:-0}" ]; then
  add_finding "freshness" "outcome eval is older than at least one source, spec, QA, score, audit, or DoD artifact"
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "strict outcome evaluation contract failed with $failures finding(s)" "$findings"
  echo "outcome-eval-gate verdict: FAIL - $failures finding(s) -> $REPORT" >&2
  exit 2
fi

write_report "PASS" "pass" "independent outcome evaluation passes rubric, evidence, confidence, bias, and freshness checks" "$findings"
echo "outcome-eval-gate verdict: PASS - independent outcome evaluation passes -> $REPORT" >&2
exit 0
