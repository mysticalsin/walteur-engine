#!/usr/bin/env bash
# WALTEUR workflow-quality-gate — class-specific quality proof for the `workflow` build class.
#
# WHY: the workflow class (SOP, automation, operating cadence, handoff) leaned on generic gates and
# had no workflow-quality check. This gate proves the workflow extra-proof HARNESS-LOOP requires:
# a single accountable owner (RACI), a dry-run, an exception path, and a recovery path.
#
# APPLICABILITY (checked FIRST). APPLICABLE iff ANY of:
#   - walteur-kit/build-contract.json classification.build_class is "workflow" or "mixed", OR
#   - walteur-kit/workflow-quality.json is present.
# Else => {"verdict":"NOT_APPLICABLE"} + exit 0.
#
# WHEN APPLICABLE, walteur-kit/workflow-quality.json MUST exist and satisfy (schema: schemas/workflow-quality.schema.json):
#   W1  deliverables[] non-empty and every .path is an existing, non-empty file inside the project root.
#   W2  ownership.owner non-empty AND ownership.raci.accountable non-empty (one accountable party).
#   W3  dry_run.performed == true AND a non-empty dry_run.evidence_ref.
#   W4  exception_path.defined == true AND a non-empty exception_path.ref.
#   W5  recovery_path.defined == true AND a non-empty recovery_path.ref.
#   W6  verdict PASS requires an empty blockers[].
# ANY violation => exit 2. Clean => exit 0.
#
# Engine: jq (zero-dep) => HARD gate. jq absent => LOUD SKIP. Report: walteur-kit/workflow-quality-report.json.
# Bypass: WALTEUR_WORKFLOW_QUALITY=off. Honors walteur-kit/PAUSED.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/workflow-quality-report.json"
SCHEMA="$KIT/schemas/workflow-quality.schema.json"
MANIFEST="$KIT/workflow-quality.json"
CONTRACT="$KIT/build-contract.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  local v="$1" reason="$2" details="${3:-}"
  [ -n "$details" ] || details="{}"
  if have jq; then
    local df; df="$(mktemp "${TMPDIR:-/tmp}/workflow-quality-report.XXXXXX")" || df=""
    if [ -n "$df" ]; then
      printf '%s\n' "$details" > "$df"
      if jq -e . "$df" >/dev/null 2>&1; then
        jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --slurpfile d "$df" \
          '{verdict:$v, ts:$ts, gate:"workflow-quality", reason:$reason, details:$d[0]}' > "$REPORT" 2>/dev/null
        local rc=$?; rm -f "$df"; [ "$rc" -eq 0 ] && return 0
      else rm -f "$df"; fi
    fi
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"workflow-quality","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
}

VIOL_JSON='[]'; N_VIOL=0
add_violation() { VIOL_JSON="$(jq -c --arg r "$1" --arg m "$2" '. + [{rule:$r, message:$m}]' <<<"$VIOL_JSON")"; N_VIOL=$((N_VIOL+1)); }

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  for t in jq grep find awk; do have "$t" || { echo "workflow-quality-gate selftest SKIP - '$t' missing."; return 0; }; done

  mk() { tmp="$(mktemp -d "${TMPDIR:-/tmp}/wfq-selftest.XXXXXX")" || return 1; mkdir -p "$tmp/walteur-kit/schemas" "$tmp/ops"; cp "$SCHEMA" "$tmp/walteur-kit/schemas/workflow-quality.schema.json"; printf '# Runbook\n\n## exceptions\n## recovery\n1. step\n' > "$tmp/ops/runbook.md"; printf 'dry run log\n' > "$tmp/ops/dryrun.log"; }
  wf_contract() { printf '%s\n' '{"classification":{"build_class":"workflow"}}' > "$tmp/walteur-kit/build-contract.json"; }
  valid_manifest() { cat > "$tmp/walteur-kit/workflow-quality.json" <<'JSON'
{ "schema_version":"1.0.0","ts":"2026-06-23T00:00:00Z","verdict":"PASS",
  "deliverables":[{"path":"ops/runbook.md","type":"runbook"}],
  "ownership":{"owner":"Ops Lead","raci":{"responsible":"Ops Eng","accountable":"Ops Lead","consulted":"SRE","informed":"Eng"}},
  "dry_run":{"performed":true,"evidence_ref":"ops/dryrun.log"},
  "exception_path":{"defined":true,"ref":"ops/runbook.md#exceptions"},
  "recovery_path":{"defined":true,"ref":"ops/runbook.md#recovery"},
  "blockers":[] }
JSON
  }

  echo "workflow-quality-gate selftest:"

  # 1. non-workflow build, no manifest -> NOT_APPLICABLE
  mk || return 1; printf '{"classification":{"build_class":"software"}}' > "$tmp/walteur-kit/build-contract.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "non-workflow build -> NOT_APPLICABLE" 0 "$?"
  jq -e '.verdict=="NOT_APPLICABLE"' "$tmp/walteur-kit/workflow-quality-report.json" >/dev/null 2>&1; ck "report NOT_APPLICABLE" 0 "$?"; rm -rf "$tmp"

  # 2. workflow build, NO manifest -> FAIL
  mk || return 1; wf_contract
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "workflow build without manifest -> FAIL" 2 "$?"
  jq -e '.verdict=="FAIL"' "$tmp/walteur-kit/workflow-quality-report.json" >/dev/null 2>&1; ck "missing-manifest report FAIL" 0 "$?"; rm -rf "$tmp"

  # 3. valid -> PASS
  mk || return 1; wf_contract; valid_manifest
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "valid workflow-quality -> PASS" 0 "$?"
  jq -e '.verdict=="PASS"' "$tmp/walteur-kit/workflow-quality-report.json" >/dev/null 2>&1; ck "valid report PASS" 0 "$?"; rm -rf "$tmp"

  # 4. no accountable owner -> FAIL (W2)
  mk || return 1; wf_contract; valid_manifest
  jq '.ownership.raci.accountable=""' "$tmp/walteur-kit/workflow-quality.json" > "$tmp/x" && mv "$tmp/x" "$tmp/walteur-kit/workflow-quality.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "no accountable owner -> FAIL" 2 "$?"
  jq -e '[.details.items[]?.rule]|index("W2")' "$tmp/walteur-kit/workflow-quality-report.json" >/dev/null 2>&1; ck "records W2" 0 "$?"; rm -rf "$tmp"

  # 5. no dry-run -> FAIL (W3)
  mk || return 1; wf_contract; valid_manifest
  jq '.dry_run.performed=false' "$tmp/walteur-kit/workflow-quality.json" > "$tmp/x" && mv "$tmp/x" "$tmp/walteur-kit/workflow-quality.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "no dry-run -> FAIL" 2 "$?"
  jq -e '[.details.items[]?.rule]|index("W3")' "$tmp/walteur-kit/workflow-quality-report.json" >/dev/null 2>&1; ck "records W3" 0 "$?"; rm -rf "$tmp"

  # 6. no exception path -> FAIL (W4)
  mk || return 1; wf_contract; valid_manifest
  jq '.exception_path.defined=false' "$tmp/walteur-kit/workflow-quality.json" > "$tmp/x" && mv "$tmp/x" "$tmp/walteur-kit/workflow-quality.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "no exception path -> FAIL" 2 "$?"
  jq -e '[.details.items[]?.rule]|index("W4")' "$tmp/walteur-kit/workflow-quality-report.json" >/dev/null 2>&1; ck "records W4" 0 "$?"; rm -rf "$tmp"

  # 7. no recovery path -> FAIL (W5)
  mk || return 1; wf_contract; valid_manifest
  jq '.recovery_path.defined=false' "$tmp/walteur-kit/workflow-quality.json" > "$tmp/x" && mv "$tmp/x" "$tmp/walteur-kit/workflow-quality.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "no recovery path -> FAIL" 2 "$?"
  jq -e '[.details.items[]?.rule]|index("W5")' "$tmp/walteur-kit/workflow-quality-report.json" >/dev/null 2>&1; ck "records W5" 0 "$?"; rm -rf "$tmp"

  # 7b. fabricated dry-run evidence ref (file does not exist) -> FAIL (W7)
  mk || return 1; wf_contract; valid_manifest
  jq '.dry_run.evidence_ref="ops/NOPE-missing.log"' "$tmp/walteur-kit/workflow-quality.json" > "$tmp/x" && mv "$tmp/x" "$tmp/walteur-kit/workflow-quality.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "fabricated evidence_ref -> FAIL" 2 "$?"
  jq -e '[.details.items[]?.rule]|index("W7")' "$tmp/walteur-kit/workflow-quality-report.json" >/dev/null 2>&1; ck "records W7" 0 "$?"; rm -rf "$tmp"

  # 8. deliverable path missing -> FAIL (W1)
  mk || return 1; wf_contract; valid_manifest; rm -f "$tmp/ops/runbook.md"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "missing deliverable file -> FAIL" 2 "$?"
  jq -e '[.details.items[]?.rule]|index("W1")' "$tmp/walteur-kit/workflow-quality-report.json" >/dev/null 2>&1; ck "records W1" 0 "$?"; rm -rf "$tmp"

  # 9. bypass -> SKIP
  mk || return 1; wf_contract
  WALTEUR_ROOT="$tmp" WALTEUR_WORKFLOW_QUALITY=off bash "$0" >/dev/null 2>&1; ck "bypass -> SKIP" 0 "$?"
  jq -e '.verdict=="SKIP"' "$tmp/walteur-kit/workflow-quality-report.json" >/dev/null 2>&1; ck "bypass report SKIP" 0 "$?"; rm -rf "$tmp"

  # 10. PAUSED -> hard block
  mk || return 1; touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "PAUSED -> hard block" 2 "$?"; rm -rf "$tmp"

  echo "workflow-quality-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED." >&2; exit 2; }
if [ "${WALTEUR_WORKFLOW_QUALITY:-on}" = "off" ]; then
  echo "workflow-quality-gate: bypassed (WALTEUR_WORKFLOW_QUALITY=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_WORKFLOW_QUALITY=off" '{"bypassed":true}'; exit 0
fi

# ── applicability ──
APPLICABLE="no"; REASON=""
if [ -f "$MANIFEST" ]; then APPLICABLE="yes"; REASON="workflow-quality.json present"; fi
if [ "$APPLICABLE" = "no" ] && have jq && [ -f "$CONTRACT" ]; then
  bc="$(jq -r '.classification.build_class // ""' "$CONTRACT" 2>/dev/null)"
  case "$bc" in workflow|mixed) APPLICABLE="yes"; REASON="build_class=$bc";; esac
fi
if [ "$APPLICABLE" = "no" ]; then
  echo "workflow-quality-gate: not a workflow/mixed build — not applicable." >&2
  if have jq; then write_report "NOT_APPLICABLE" "not a workflow build" "$(jq -n '{applicable:false}')"; else write_report "NOT_APPLICABLE" "not a workflow build" '{}'; fi
  exit 0
fi

echo "WALTEUR workflow-quality-gate @ $ROOT — applicable ($REASON)." >&2

if ! have jq; then
  echo "WALTEUR workflow-quality-gate SKIP — jq not installed (recorded, NOT silent-green)." >&2
  write_report "SKIP" "jq not installed" '{}'; exit 0
fi

if [ ! -f "$MANIFEST" ]; then
  echo "WALTEUR workflow-quality-gate: FAIL — workflow build but walteur-kit/workflow-quality.json is absent." >&2
  write_report "FAIL" "workflow build with no workflow-quality proof" "$(jq -n --arg r "$REASON" '{applicable:true, reason:$r, rule:"workflow-build-requires-workflow-quality"}')"
  exit 2
fi
if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
  echo "WALTEUR workflow-quality-gate: FAIL — workflow-quality.json is not valid JSON." >&2
  write_report "FAIL" "workflow-quality.json not valid JSON" '{"applicable":true,"rule":"parse"}'; exit 2
fi

# ── W1: deliverables present + path-backed ──
dcount="$(jq -r '(.deliverables // []) | length' "$MANIFEST" 2>/dev/null)"; [ -n "$dcount" ] || dcount=0
if [ "$dcount" -eq 0 ]; then add_violation "W1" "deliverables[] is empty — a workflow build must name its SOP/runbook(s)"; fi
while IFS= read -r p; do
  [ -z "$p" ] && continue
  case "$p" in /*|*..*) add_violation "W1" "deliverable path '$p' must be project-relative without parent traversal"; continue;; esac
  if [ ! -s "$ROOT/$p" ]; then add_violation "W1" "deliverable '$p' does not exist or is empty"; fi
done < <(jq -r '.deliverables[]?.path // empty' "$MANIFEST" 2>/dev/null)

# ── W2..W6 via jq ──
ENVELOPE="$(jq -r '
  [ (if ((.ownership.owner|type)=="string" and (.ownership.owner|length)>0
          and (.ownership.raci.accountable|type)=="string" and (.ownership.raci.accountable|length)>0) then empty
       else "W2::ownership.owner and ownership.raci.accountable must both be named" end),
    (if (.dry_run.performed == true and (.dry_run.evidence_ref|type)=="string" and (.dry_run.evidence_ref|length)>0) then empty
       else "W3::dry_run.performed must be true with a non-empty evidence_ref" end),
    (if (.exception_path.defined == true and (.exception_path.ref|type)=="string" and (.exception_path.ref|length)>0) then empty
       else "W4::exception_path.defined must be true with a non-empty ref" end),
    (if (.recovery_path.defined == true and (.recovery_path.ref|type)=="string" and (.recovery_path.ref|length)>0) then empty
       else "W5::recovery_path.defined must be true with a non-empty ref" end),
    (if ((.blockers // []) | length) > 0 then "W6::workflow-quality has \((.blockers|length)) blocker(s)" else empty end)
  ] | .[]' "$MANIFEST" 2>/dev/null)"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  add_violation "${line%%::*}" "${line#*::}"
done <<EOF
$ENVELOPE
EOF

# ── W7: evidence refs must point at REAL files (declaration must be WIRED, not a fabricated string) ──
# Local refs (no URL scheme) must exist after stripping any #anchor; URL refs (contain "://") accepted.
while IFS=$'\t' read -r field ref; do
  [ -z "$ref" ] && continue
  case "$ref" in *://*) continue ;; esac
  pp="${ref%%#*}"
  case "$pp" in /*|*..*) add_violation "W7" "$field '$ref' must be a project-relative path without parent traversal"; continue ;; esac
  [ -s "$ROOT/$pp" ] || add_violation "W7" "$field points at '$ref' but that evidence file does not exist or is empty"
done < <(
  jq -r '(.dry_run.evidence_ref // empty) | select(length>0) | "dry_run.evidence_ref\t\(.)"' "$MANIFEST" 2>/dev/null
  jq -r '(.exception_path.ref // empty) | select(length>0) | "exception_path.ref\t\(.)"' "$MANIFEST" 2>/dev/null
  jq -r '(.recovery_path.ref // empty) | select(length>0) | "recovery_path.ref\t\(.)"' "$MANIFEST" 2>/dev/null
)

DETAILS="$(jq -n --argjson dc "$dcount" --argjson nv "$N_VIOL" --argjson v "$VIOL_JSON" '{applicable:true, deliverables:$dc, violations:$nv, items:$v}')"
if [ "$N_VIOL" -gt 0 ]; then
  echo "WALTEUR workflow-quality-gate: FAIL — $N_VIOL violation(s)." >&2
  jq -r '.[] | "  - [\(.rule)] \(.message)"' <<<"$VIOL_JSON" >&2 2>/dev/null || true
  write_report "FAIL" "$N_VIOL workflow-quality violation(s)" "$DETAILS"; exit 2
fi
echo "workflow-quality-gate: ok — $dcount deliverable(s); owner/RACI, dry-run, exception + recovery paths all proven." >&2
write_report "PASS" "workflow quality proven" "$DETAILS"; exit 0
