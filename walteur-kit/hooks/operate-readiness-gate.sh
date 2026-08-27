#!/usr/bin/env bash
# WALTEUR operate-readiness-gate - operate-stage proof for enterprise runtime systems.
#
# APPLICABILITY:
#   Runtime/deployable surface exists when the repo has Docker/Containerfile, Procfile,
#   fly.toml, serverless.yml, k8s YAML, GitHub deploy/release workflow, Terraform/Pulumi,
#   package.json start script, or common app-server source.
#   No runtime surface -> NOT_APPLICABLE, exit 0.
#
# HARD CHECK:
#   Runtime work requires walteur-kit/operate-readiness.json.
#   The proof must be fresh and include service ownership, SLOs, DORA targets,
#   incident runbooks, on-call/escalation, observability/alert evidence, rollback
#   rehearsal with RTO/RPO, support handoff, and post-incident review procedure.
#   Every local proof ref must exist, stay inside the repo, and be non-empty.
#
# Report: walteur-kit/operate-readiness-report.json.
# Bypass: WALTEUR_OPERATE_READINESS=off. Pause: walteur-kit/PAUSED present.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "operate-readiness-gate - operate-stage proof for enterprise runtime systems."
  printf '%s\n' "usage: bash operate-readiness-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/operate-readiness-report.json - fix recipes: walteur-kit/REMEDIATION.md (## operate-readiness-gate)"
  printf '%s\n' "bypass: WALTEUR_OPERATE_READINESS=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
PROOF="$KIT/operate-readiness.json"
REPORT="$KIT/operate-readiness-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MAX_AGE_DAYS="${WALTEUR_OPERATE_READINESS_MAX_AGE_DAYS:-14}"
mkdir -p "$KIT"

write_report() {
  local verdict="$1" reason="$2" extra="${3-}"
  [ -n "$extra" ] || extra='{}'
  if command -v jq >/dev/null 2>&1 && printf '%s\n' "$extra" | jq -e . >/dev/null 2>&1; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg reason "$reason" --argjson extra "$extra" \
      '{verdict:$v, ts:$ts, gate:"operate-readiness-gate", reason:$reason} + $extra' > "$REPORT" 2>/dev/null \
      && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"operate-readiness-gate","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT"
}

relpath() {
  case "$1" in
    "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

selftest() {
  local pass=0 fail=0 tmp today
  local SELF_PATH
  SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  today="$(date -u +%F)"

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

  make_runtime() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit/operate" "$dst/src"
    printf 'FROM node:20-alpine\nCMD ["node","src/server.js"]\n' > "$dst/Dockerfile"
    printf 'import express from "express"; const app = express(); app.get("/health", (_,res)=>res.send("ok")); app.listen(3000);\n' > "$dst/src/server.js"
  }

  make_evidence() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit/operate"
    for f in runtime slo error-budget lead-time deploy-frequency change-fail-rate mttr runbook severity comms dashboard alerts smoke logs rollback handoff post-incident; do
      printf '%s evidence\n' "$f" > "$dst/walteur-kit/operate/$f.txt"
    done
  }

  make_proof() {
    local dst="$1" run_date="${2:-$today}"
    cat > "$dst/walteur-kit/operate-readiness.json" <<JSON
{
  "schema_version": 1,
  "run_date": "$run_date",
  "owner": "release-owner",
  "service": {
    "name": "ops-dashboard",
    "tier": "customer-facing",
    "runtime_ref": "walteur-kit/operate/runtime.txt"
  },
  "slo": {
    "objectives": [
      { "name": "availability", "target": ">= 99.9%", "window": "30d", "measurement_ref": "walteur-kit/operate/slo.txt" }
    ],
    "error_budget_policy_ref": "walteur-kit/operate/error-budget.txt"
  },
  "dora": {
    "lead_time": { "target": "<= 1 day", "measurement_ref": "walteur-kit/operate/lead-time.txt" },
    "deployment_frequency": { "target": ">= weekly", "measurement_ref": "walteur-kit/operate/deploy-frequency.txt" },
    "change_fail_rate": { "target": "<= 15%", "measurement_ref": "walteur-kit/operate/change-fail-rate.txt" },
    "mttr": { "target": "<= 1 hour", "measurement_ref": "walteur-kit/operate/mttr.txt" }
  },
  "incident_response": {
    "runbook_refs": ["walteur-kit/operate/runbook.txt"],
    "severity_matrix_ref": "walteur-kit/operate/severity.txt",
    "on_call_owner": "SRE primary",
    "escalation_path": ["SRE primary", "Tech lead", "EM"],
    "comms_template_ref": "walteur-kit/operate/comms.txt"
  },
  "observability": {
    "dashboard_refs": ["walteur-kit/operate/dashboard.txt"],
    "alert_refs": ["walteur-kit/operate/alerts.txt"],
    "smoke_check_ref": "walteur-kit/operate/smoke.txt",
    "trace_or_log_ref": "walteur-kit/operate/logs.txt"
  },
  "rollback": {
    "rollback_command": "kubectl rollout undo deploy/ops-dashboard",
    "rehearsal_ref": "walteur-kit/operate/rollback.txt",
    "rto_minutes": 30,
    "rpo_minutes": 15
  },
  "support": {
    "support_model": "Business-hours support with P1 on-call escalation.",
    "handoff_ref": "walteur-kit/operate/handoff.txt",
    "post_incident_review_ref": "walteur-kit/operate/post-incident.txt"
  }
}
JSON
  }

  echo "operate-readiness-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operate-readiness-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no runtime surface -> NOT_APPLICABLE" 0 "$?"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/operate-readiness-report.json" >/dev/null 2>&1
  ck "no runtime report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operate-readiness-selftest.XXXXXX")" || return 1
  make_runtime "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "runtime without operate-readiness.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operate-readiness-selftest.XXXXXX")" || return 1
  make_runtime "$tmp"
  printf '{ bad json\n' > "$tmp/walteur-kit/operate-readiness.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "invalid operate-readiness.json -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operate-readiness-selftest.XXXXXX")" || return 1
  make_runtime "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "valid operate readiness -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operate-readiness-selftest.XXXXXX")" || return 1
  make_runtime "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  jq 'del(.slo.objectives)' "$tmp/walteur-kit/operate-readiness.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/operate-readiness.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "missing SLO objectives -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operate-readiness-selftest.XXXXXX")" || return 1
  make_runtime "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  jq 'del(.dora.mttr)' "$tmp/walteur-kit/operate-readiness.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/operate-readiness.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "missing DORA MTTR -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operate-readiness-selftest.XXXXXX")" || return 1
  make_runtime "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  jq '.incident_response.runbook_refs = []' "$tmp/walteur-kit/operate-readiness.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/operate-readiness.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "missing incident runbook -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operate-readiness-selftest.XXXXXX")" || return 1
  make_runtime "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  rm -f "$tmp/walteur-kit/operate/alerts.txt"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "missing alert evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operate-readiness-selftest.XXXXXX")" || return 1
  make_runtime "$tmp"; make_evidence "$tmp"; make_proof "$tmp"
  jq '.rollback.rehearsal_ref = "../outside.txt"' "$tmp/walteur-kit/operate-readiness.json" > "$tmp/walteur-kit/proof.tmp" && mv "$tmp/walteur-kit/proof.tmp" "$tmp/walteur-kit/operate-readiness.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "unsafe evidence ref -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operate-readiness-selftest.XXXXXX")" || return 1
  make_runtime "$tmp"; make_evidence "$tmp"; make_proof "$tmp" "2000-01-01"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "stale operate readiness -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operate-readiness-selftest.XXXXXX")" || return 1
  make_runtime "$tmp"
  WALTEUR_ROOT="$tmp" WALTEUR_OPERATE_READINESS=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/operate-readiness-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operate-readiness-selftest.XXXXXX")" || return 1
  make_runtime "$tmp"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "operate-readiness-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

if [ -f "$KIT/PAUSED" ]; then
  write_report "FAIL" "walteur-kit/PAUSED present" '{"paused":true}'
  echo "operate-readiness-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
fi

if [ "${WALTEUR_OPERATE_READINESS:-on}" = "off" ]; then
  write_report "SKIP" "bypassed via WALTEUR_OPERATE_READINESS=off" '{"bypassed":true}'
  echo "operate-readiness-gate verdict: SKIP - bypassed -> $REPORT" >&2
  exit 0
fi

for t in find grep jq date; do
  if ! command -v "$t" >/dev/null 2>&1; then
    write_report "SKIP" "$t not installed" "$(printf '{"missing_tool":"%s"}' "$t")"
    echo "operate-readiness-gate SKIP - required tool '$t' not installed." >&2
    exit 0
  fi
done

PRUNE=( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' \
        -o -path '*/out/*' -o -path '*/.next/*' -o -path '*/.output/*' -o -path '*/.svelte-kit/*' \
        -o -path '*/coverage/*' -o -path '*/vendor/*' -o -path '*/.venv/*' )

runtime_hit="$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \
  -type f \( -iname 'Dockerfile' -o -iname 'Dockerfile.*' -o -iname '*.dockerfile' -o -iname 'Containerfile' \
            -o -iname 'Procfile' -o -iname 'fly.toml' -o -iname 'serverless.yml' -o -iname 'serverless.yaml' \
            -o -iname 'pulumi.yaml' -o -iname '*.tf' \) -print 2>/dev/null | head -1)"

if [ -z "$runtime_hit" ]; then
  while IFS= read -r y; do
    [ -z "$y" ] && continue
    if grep -lqE '^[[:space:]]*apiVersion:' "$y" 2>/dev/null && grep -lqE '^[[:space:]]*kind:' "$y" 2>/dev/null; then
      runtime_hit="$y"
      break
    fi
  done < <(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \( -name '*.yaml' -o -name '*.yml' \) -type f -print 2>/dev/null)
fi

if [ -z "$runtime_hit" ] && [ -d "$ROOT/.github/workflows" ]; then
  while IFS= read -r wf; do
    [ -z "$wf" ] && continue
    if case "$wf" in *deploy*|*release*) true ;; *) false ;; esac || grep -liqE 'deploy|deployment|environment:' "$wf" 2>/dev/null; then
      runtime_hit="$wf"
      break
    fi
  done < <(find "$ROOT/.github/workflows" \( -name '*.yml' -o -name '*.yaml' \) -type f 2>/dev/null)
fi

if [ -z "$runtime_hit" ]; then
  while IFS= read -r pj; do
    [ -z "$pj" ] && continue
    if jq -e '(.scripts.start // "") | type == "string" and length > 0' "$pj" >/dev/null 2>&1; then
      runtime_hit="$pj"
      break
    fi
  done < <(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -name package.json -type f -print 2>/dev/null)
fi

if [ -z "$runtime_hit" ]; then
  runtime_hit="$(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \
    -type f \( -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.go' \) -print 2>/dev/null \
    | xargs grep -lE 'FastAPI\\(|Flask\\(|express\\(|app\\.listen\\(|http\\.ListenAndServe|uvicorn|Hono\\(' 2>/dev/null \
    | head -1)"
fi

if [ -z "$runtime_hit" ]; then
  write_report "NOT_APPLICABLE" "no runtime or deployable surface found" '{"runtime_signal":null}'
  echo "operate-readiness-gate verdict: NOT_APPLICABLE - no runtime surface -> $REPORT" >&2
  exit 0
fi

runtime_rel="$(relpath "$runtime_hit")"

if [ ! -f "$PROOF" ]; then
  details="$(jq -n --arg signal "$runtime_rel" '{runtime_signal:$signal}')"
  write_report "FAIL" "operate-readiness.json missing for runtime surface" "$details"
  echo "operate-readiness-gate verdict: FAIL - missing operate-readiness.json -> $REPORT" >&2
  exit 2
fi

if ! jq -e . "$PROOF" >/dev/null 2>&1; then
  details="$(jq -n --arg signal "$runtime_rel" '{runtime_signal:$signal}')"
  write_report "FAIL" "operate-readiness.json is not valid JSON" "$details"
  echo "operate-readiness-gate verdict: FAIL - invalid JSON -> $REPORT" >&2
  exit 2
fi

shape_err="$(jq -r '
  def err(c;m): if c then m else empty end;
  . as $doc
  | [
      err(($doc.schema_version != 1); "schema_version must be 1"),
      err(($doc.run_date|type)!="string" or ($doc.run_date|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")|not); "run_date must be YYYY-MM-DD"),
      err(($doc.owner|type)!="string" or ($doc.owner|length)<1; "owner must be non-empty"),
      err(($doc.service|type)!="object"; "service must be an object"),
      err(($doc.service.name|type)!="string" or ($doc.service.name|length)<1; "service.name must be non-empty"),
      err(($doc.service.tier as $v | ["internal","customer-facing","regulated","mission-critical"] | index($v) | not); "service.tier must be a supported tier"),
      err(($doc.service.runtime_ref|type)!="string" or ($doc.service.runtime_ref|length)<1; "service.runtime_ref must be non-empty"),
      err(($doc.slo.objectives|type)!="array" or ($doc.slo.objectives|length)<1; "slo.objectives must contain at least one objective"),
      err([ $doc.slo.objectives[]? | select((.name|type)!="string" or (.name|length)<1 or (.target|type)!="string" or (.target|test("^(>=|<=|>|<|=)\\s*\\S")|not) or (.window|type)!="string" or (.window|length)<1 or (.measurement_ref|type)!="string" or (.measurement_ref|length)<1) ] | length>0; "every SLO objective needs name, comparator target, window, and measurement_ref"),
      err(($doc.slo.error_budget_policy_ref|type)!="string" or ($doc.slo.error_budget_policy_ref|length)<1; "slo.error_budget_policy_ref must be non-empty"),
      err((($doc.dora.lead_time.target // "")|length)<1 or (($doc.dora.lead_time.measurement_ref // "")|length)<1; "dora.lead_time target and measurement_ref are required"),
      err((($doc.dora.deployment_frequency.target // "")|length)<1 or (($doc.dora.deployment_frequency.measurement_ref // "")|length)<1; "dora.deployment_frequency target and measurement_ref are required"),
      err((($doc.dora.change_fail_rate.target // "")|length)<1 or (($doc.dora.change_fail_rate.measurement_ref // "")|length)<1; "dora.change_fail_rate target and measurement_ref are required"),
      err((($doc.dora.mttr.target // "")|length)<1 or (($doc.dora.mttr.measurement_ref // "")|length)<1; "dora.mttr target and measurement_ref are required"),
      err(($doc.incident_response.runbook_refs|type)!="array" or ($doc.incident_response.runbook_refs|length)<1; "incident_response.runbook_refs must contain at least one ref"),
      err(($doc.incident_response.severity_matrix_ref|type)!="string" or ($doc.incident_response.severity_matrix_ref|length)<1; "incident_response.severity_matrix_ref must be non-empty"),
      err(($doc.incident_response.on_call_owner|type)!="string" or ($doc.incident_response.on_call_owner|length)<1; "incident_response.on_call_owner must be non-empty"),
      err(($doc.incident_response.escalation_path|type)!="array" or ($doc.incident_response.escalation_path|length)<1; "incident_response.escalation_path must contain at least one owner"),
      err(($doc.incident_response.comms_template_ref|type)!="string" or ($doc.incident_response.comms_template_ref|length)<1; "incident_response.comms_template_ref must be non-empty"),
      err(($doc.observability.dashboard_refs|type)!="array" or ($doc.observability.dashboard_refs|length)<1; "observability.dashboard_refs must contain at least one ref"),
      err(($doc.observability.alert_refs|type)!="array" or ($doc.observability.alert_refs|length)<1; "observability.alert_refs must contain at least one ref"),
      err(($doc.observability.smoke_check_ref|type)!="string" or ($doc.observability.smoke_check_ref|length)<1; "observability.smoke_check_ref must be non-empty"),
      err(($doc.observability.trace_or_log_ref|type)!="string" or ($doc.observability.trace_or_log_ref|length)<1; "observability.trace_or_log_ref must be non-empty"),
      err(($doc.rollback.rollback_command|type)!="string" or ($doc.rollback.rollback_command|length)<1; "rollback.rollback_command must be non-empty"),
      err(($doc.rollback.rehearsal_ref|type)!="string" or ($doc.rollback.rehearsal_ref|length)<1; "rollback.rehearsal_ref must be non-empty"),
      err(($doc.rollback.rto_minutes|type)!="number" or ($doc.rollback.rto_minutes < 0); "rollback.rto_minutes must be >= 0"),
      err(($doc.rollback.rpo_minutes|type)!="number" or ($doc.rollback.rpo_minutes < 0); "rollback.rpo_minutes must be >= 0"),
      err(($doc.support.support_model|type)!="string" or ($doc.support.support_model|length)<1; "support.support_model must be non-empty"),
      err(($doc.support.handoff_ref|type)!="string" or ($doc.support.handoff_ref|length)<1; "support.handoff_ref must be non-empty"),
      err(($doc.support.post_incident_review_ref|type)!="string" or ($doc.support.post_incident_review_ref|length)<1; "support.post_incident_review_ref must be non-empty")
    ] | map(select(. != null)) | .[]
' "$PROOF" 2>/dev/null)"

if [ -n "$shape_err" ]; then
  findings="$(printf '%s\n' "$shape_err" | jq -R -s 'split("\n") | map(select(length > 0)) | map({check:"shape", message:.})')"
  details="$(jq -n --arg signal "$runtime_rel" --argjson findings "$findings" '{runtime_signal:$signal, findings:$findings}')"
  write_report "FAIL" "operate-readiness.json missing required operate proof" "$details"
  echo "operate-readiness-gate verdict: FAIL - missing required operate proof -> $REPORT" >&2
  exit 2
fi

run_date="$(jq -r '.run_date' "$PROOF")"
if ! proof_epoch="$(date -u -j -f %F "$run_date" +%s 2>/dev/null)"; then
  if ! proof_epoch="$(date -u -d "$run_date" +%s 2>/dev/null)"; then
    proof_epoch=0
  fi
fi
now_epoch="$(date -u +%s)"
max_age_seconds=$((MAX_AGE_DAYS * 86400))
if [ "$proof_epoch" -le 0 ] || [ $((now_epoch - proof_epoch)) -gt "$max_age_seconds" ]; then
  details="$(jq -n --arg signal "$runtime_rel" --arg run_date "$run_date" --argjson max_age_days "$MAX_AGE_DAYS" '{runtime_signal:$signal, run_date:$run_date, max_age_days:$max_age_days}')"
  write_report "FAIL" "operate-readiness.json is stale" "$details"
  echo "operate-readiness-gate verdict: FAIL - stale proof -> $REPORT" >&2
  exit 2
fi

refs="$(jq -r '
  [
    .service.runtime_ref,
    .slo.error_budget_policy_ref,
    (.slo.objectives[]?.measurement_ref),
    .dora.lead_time.measurement_ref,
    .dora.deployment_frequency.measurement_ref,
    .dora.change_fail_rate.measurement_ref,
    .dora.mttr.measurement_ref,
    (.incident_response.runbook_refs[]?),
    .incident_response.severity_matrix_ref,
    .incident_response.comms_template_ref,
    (.observability.dashboard_refs[]?),
    (.observability.alert_refs[]?),
    .observability.smoke_check_ref,
    .observability.trace_or_log_ref,
    .rollback.rehearsal_ref,
    .support.handoff_ref,
    .support.post_incident_review_ref
  ] | .[] | select(type == "string" and length > 0)
' "$PROOF")"

bad_refs=""
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    /*|*../*|../*) bad_refs="${bad_refs}${ref}: unsafe path"$'\n'; continue ;;
  esac
  path="$ROOT/$ref"
  if [ ! -f "$path" ]; then
    bad_refs="${bad_refs}${ref}: missing"$'\n'
  elif [ ! -s "$path" ]; then
    bad_refs="${bad_refs}${ref}: empty"$'\n'
  fi
done <<EOF
$refs
EOF

if [ -n "$bad_refs" ]; then
  findings="$(printf '%s' "$bad_refs" | jq -R -s 'split("\n") | map(select(length > 0)) | map({check:"evidence_ref", message:.})')"
  details="$(jq -n --arg signal "$runtime_rel" --argjson findings "$findings" '{runtime_signal:$signal, findings:$findings}')"
  write_report "FAIL" "operate readiness evidence refs are missing, empty, or unsafe" "$details"
  echo "operate-readiness-gate verdict: FAIL - evidence refs invalid -> $REPORT" >&2
  exit 2
fi

details="$(jq -n --arg signal "$runtime_rel" --arg run_date "$run_date" '{runtime_signal:$signal, run_date:$run_date}')"
write_report "PASS" "operate readiness proof passes" "$details"
echo "operate-readiness-gate verdict: PASS - operate readiness proof passes -> $REPORT" >&2
exit 0
