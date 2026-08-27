#!/usr/bin/env bash
# WALTEUR doc-quality-gate — class-specific quality proof for the `document` build class.
#
# WHY: the document class (memo, deck, PRD, proposal, policy) used to lean on software-shaped
# baseline gates and had NO document-quality check. This gate proves the document extra-proof that
# HARNESS-LOOP requires: structure (not a wall of text), source-citation/audit, readability, and a
# humanizer pass for external docs.
#
# APPLICABILITY (checked FIRST). APPLICABLE iff ANY of:
#   - walteur-kit/build-contract.json classification.build_class is "document" or "mixed", OR
#   - walteur-kit/doc-quality.json is present.
# Else => {"verdict":"NOT_APPLICABLE"} + exit 0 (a code/cloud build does not owe document quality here).
#
# WHEN APPLICABLE, walteur-kit/doc-quality.json MUST exist and satisfy (shape: schemas/doc-quality.schema.json):
#   D1  deliverables[] non-empty and every .path is an existing, non-empty file inside the project root.
#   D2  structure.has_sections == true (the doc is sectioned, not an unbroken wall).
#   D3  sourcing.claims_cited == sourcing.claims_total AND source_audit_ref is non-empty (every claim cited).
#   D4  readability.has_headings == true AND readability.max_paragraph_words <= cap (WALTEUR_DOCQ_MAXPARA, default 220).
#   D5  audience=="external" REQUIRES humanizer.passed == true AND a non-empty humanizer.evidence_ref.
#   D6  verdict PASS requires an empty blockers[].
# ANY violation => exit 2. Clean => exit 0.
#
# Engine: jq (zero-dep baseline) => HARD gate. jq absent => LOUD SKIP. Report: walteur-kit/doc-quality-report.json.
# Bypass: WALTEUR_DOC_QUALITY=off. Honors walteur-kit/PAUSED.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/doc-quality-report.json"
SCHEMA="$KIT/schemas/doc-quality.schema.json"
MANIFEST="$KIT/doc-quality.json"
CONTRACT="$KIT/build-contract.json"
MAXPARA="${WALTEUR_DOCQ_MAXPARA:-220}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  local v="$1" reason="$2" details="${3:-}"
  [ -n "$details" ] || details="{}"
  if have jq; then
    local df; df="$(mktemp "${TMPDIR:-/tmp}/doc-quality-report.XXXXXX")" || df=""
    if [ -n "$df" ]; then
      printf '%s\n' "$details" > "$df"
      if jq -e . "$df" >/dev/null 2>&1; then
        jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --slurpfile d "$df" \
          '{verdict:$v, ts:$ts, gate:"doc-quality", reason:$reason, details:$d[0]}' > "$REPORT" 2>/dev/null
        local rc=$?; rm -f "$df"; [ "$rc" -eq 0 ] && return 0
      else rm -f "$df"; fi
    fi
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"doc-quality","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
}

VIOL_JSON='[]'; N_VIOL=0
add_violation() { # <rule> <message>
  VIOL_JSON="$(jq -c --arg r "$1" --arg m "$2" '. + [{rule:$r, message:$m}]' <<<"$VIOL_JSON")"
  N_VIOL=$((N_VIOL+1))
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  for t in jq grep find awk; do have "$t" || { echo "doc-quality-gate selftest SKIP - '$t' missing."; return 0; }; done

  mk() { tmp="$(mktemp -d "${TMPDIR:-/tmp}/docq-selftest.XXXXXX")" || return 1; mkdir -p "$tmp/walteur-kit/schemas" "$tmp/docs"; cp "$SCHEMA" "$tmp/walteur-kit/schemas/doc-quality.schema.json"; printf '# Memo\n\n## Context\n\ntext\n\n## Decision\n\ntext\n' > "$tmp/docs/memo.md"; printf 'source audit\n' > "$tmp/docs/sources.md"; printf 'humanizer pass\n' > "$tmp/docs/humanizer.txt"; }
  doc_contract() { printf '%s\n' '{"classification":{"build_class":"document"}}' > "$tmp/walteur-kit/build-contract.json"; }
  valid_manifest() { cat > "$tmp/walteur-kit/doc-quality.json" <<'JSON'
{ "schema_version":"1.0.0","ts":"2026-06-23T00:00:00Z","verdict":"PASS","audience":"external",
  "deliverables":[{"path":"docs/memo.md","type":"memo"}],
  "structure":{"has_sections":true,"sections":["Context","Decision"]},
  "sourcing":{"claims_total":2,"claims_cited":2,"source_audit_ref":"docs/sources.md"},
  "readability":{"max_paragraph_words":40,"has_headings":true},
  "humanizer":{"passed":true,"evidence_ref":"docs/humanizer.txt"},
  "blockers":[] }
JSON
  }

  echo "doc-quality-gate selftest:"

  # 1. non-document project, no manifest -> NOT_APPLICABLE
  mk || return 1; printf '{"classification":{"build_class":"software"}}' > "$tmp/walteur-kit/build-contract.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "non-document build -> NOT_APPLICABLE" 0 "$?"
  jq -e '.verdict=="NOT_APPLICABLE"' "$tmp/walteur-kit/doc-quality-report.json" >/dev/null 2>&1; ck "report NOT_APPLICABLE" 0 "$?"; rm -rf "$tmp"

  # 2. document build, NO manifest -> FAIL
  mk || return 1; doc_contract
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "document build without doc-quality.json -> FAIL" 2 "$?"
  jq -e '.verdict=="FAIL"' "$tmp/walteur-kit/doc-quality-report.json" >/dev/null 2>&1; ck "missing-manifest report FAIL" 0 "$?"; rm -rf "$tmp"

  # 3. valid -> PASS
  mk || return 1; doc_contract; valid_manifest
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "valid doc-quality -> PASS" 0 "$?"
  jq -e '.verdict=="PASS"' "$tmp/walteur-kit/doc-quality-report.json" >/dev/null 2>&1; ck "valid report PASS" 0 "$?"; rm -rf "$tmp"

  # 4. uncited claims -> FAIL (D3)
  mk || return 1; doc_contract; valid_manifest
  jq '.sourcing.claims_cited=1' "$tmp/walteur-kit/doc-quality.json" > "$tmp/x" && mv "$tmp/x" "$tmp/walteur-kit/doc-quality.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "uncited claims -> FAIL" 2 "$?"
  jq -e '[.details.items[]?.rule]|index("D3")' "$tmp/walteur-kit/doc-quality-report.json" >/dev/null 2>&1; ck "records D3" 0 "$?"; rm -rf "$tmp"

  # 5. no sections -> FAIL (D2)
  mk || return 1; doc_contract; valid_manifest
  jq '.structure.has_sections=false' "$tmp/walteur-kit/doc-quality.json" > "$tmp/x" && mv "$tmp/x" "$tmp/walteur-kit/doc-quality.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "no sections -> FAIL" 2 "$?"
  jq -e '[.details.items[]?.rule]|index("D2")' "$tmp/walteur-kit/doc-quality-report.json" >/dev/null 2>&1; ck "records D2" 0 "$?"; rm -rf "$tmp"

  # 6. external without humanizer -> FAIL (D5)
  mk || return 1; doc_contract; valid_manifest
  jq '.humanizer.passed=false' "$tmp/walteur-kit/doc-quality.json" > "$tmp/x" && mv "$tmp/x" "$tmp/walteur-kit/doc-quality.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "external w/o humanizer -> FAIL" 2 "$?"
  jq -e '[.details.items[]?.rule]|index("D5")' "$tmp/walteur-kit/doc-quality-report.json" >/dev/null 2>&1; ck "records D5" 0 "$?"; rm -rf "$tmp"

  # 7. deliverable path missing -> FAIL (D1)
  mk || return 1; doc_contract; valid_manifest; rm -f "$tmp/docs/memo.md"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "missing deliverable file -> FAIL" 2 "$?"
  jq -e '[.details.items[]?.rule]|index("D1")' "$tmp/walteur-kit/doc-quality-report.json" >/dev/null 2>&1; ck "records D1" 0 "$?"; rm -rf "$tmp"

  # 8. wall of text -> FAIL (D4)
  mk || return 1; doc_contract; valid_manifest
  jq '.readability.max_paragraph_words=999' "$tmp/walteur-kit/doc-quality.json" > "$tmp/x" && mv "$tmp/x" "$tmp/walteur-kit/doc-quality.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "wall of text -> FAIL" 2 "$?"
  jq -e '[.details.items[]?.rule]|index("D4")' "$tmp/walteur-kit/doc-quality-report.json" >/dev/null 2>&1; ck "records D4" 0 "$?"; rm -rf "$tmp"

  # 8b. fabricated evidence ref (file does not exist) -> FAIL (D7)
  mk || return 1; doc_contract; valid_manifest
  jq '.sourcing.source_audit_ref="docs/NOPE-does-not-exist.md"' "$tmp/walteur-kit/doc-quality.json" > "$tmp/x" && mv "$tmp/x" "$tmp/walteur-kit/doc-quality.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "fabricated evidence_ref -> FAIL" 2 "$?"
  jq -e '[.details.items[]?.rule]|index("D7")' "$tmp/walteur-kit/doc-quality-report.json" >/dev/null 2>&1; ck "records D7" 0 "$?"; rm -rf "$tmp"

  # 9. bypass -> SKIP
  mk || return 1; doc_contract
  WALTEUR_ROOT="$tmp" WALTEUR_DOC_QUALITY=off bash "$0" >/dev/null 2>&1; ck "bypass -> SKIP" 0 "$?"
  jq -e '.verdict=="SKIP"' "$tmp/walteur-kit/doc-quality-report.json" >/dev/null 2>&1; ck "bypass report SKIP" 0 "$?"; rm -rf "$tmp"

  # 10. PAUSED -> hard block
  mk || return 1; touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1; ck "PAUSED -> hard block" 2 "$?"; rm -rf "$tmp"

  echo "doc-quality-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED." >&2; exit 2; }
if [ "${WALTEUR_DOC_QUALITY:-on}" = "off" ]; then
  echo "doc-quality-gate: bypassed (WALTEUR_DOC_QUALITY=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_DOC_QUALITY=off" '{"bypassed":true}'; exit 0
fi

# ── applicability ──
APPLICABLE="no"; REASON=""
if [ -f "$MANIFEST" ]; then APPLICABLE="yes"; REASON="doc-quality.json present"; fi
if [ "$APPLICABLE" = "no" ] && have jq && [ -f "$CONTRACT" ]; then
  bc="$(jq -r '.classification.build_class // ""' "$CONTRACT" 2>/dev/null)"
  case "$bc" in document|mixed) APPLICABLE="yes"; REASON="build_class=$bc";; esac
fi
if [ "$APPLICABLE" = "no" ]; then
  echo "doc-quality-gate: not a document/mixed build — not applicable." >&2
  if have jq; then write_report "NOT_APPLICABLE" "not a document build" "$(jq -n '{applicable:false}')"; else write_report "NOT_APPLICABLE" "not a document build" '{}'; fi
  exit 0
fi

echo "WALTEUR doc-quality-gate @ $ROOT — applicable ($REASON)." >&2

if ! have jq; then
  echo "WALTEUR doc-quality-gate SKIP — jq not installed (recorded, NOT silent-green)." >&2
  write_report "SKIP" "jq not installed" '{}'; exit 0
fi

if [ ! -f "$MANIFEST" ]; then
  echo "WALTEUR doc-quality-gate: FAIL — document build but walteur-kit/doc-quality.json is absent." >&2
  write_report "FAIL" "document build with no doc-quality proof" "$(jq -n --arg r "$REASON" '{applicable:true, reason:$r, rule:"document-build-requires-doc-quality"}')"
  exit 2
fi
if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
  echo "WALTEUR doc-quality-gate: FAIL — doc-quality.json is not valid JSON." >&2
  write_report "FAIL" "doc-quality.json not valid JSON" '{"applicable":true,"rule":"parse"}'; exit 2
fi

# ── D1: deliverables present + path-backed ──
dcount="$(jq -r '(.deliverables // []) | length' "$MANIFEST" 2>/dev/null)"; [ -n "$dcount" ] || dcount=0
if [ "$dcount" -eq 0 ]; then add_violation "D1" "deliverables[] is empty — a document build must name its deliverable(s)"; fi
while IFS= read -r p; do
  [ -z "$p" ] && continue
  case "$p" in /*|*..*) add_violation "D1" "deliverable path '$p' must be project-relative without parent traversal"; continue;; esac
  if [ ! -s "$ROOT/$p" ]; then add_violation "D1" "deliverable '$p' does not exist or is empty"; fi
done < <(jq -r '.deliverables[]?.path // empty' "$MANIFEST" 2>/dev/null)

# ── D2..D6 via jq ──
ENVELOPE="$(jq -r --argjson cap "$MAXPARA" '
  [ (if (.structure.has_sections == true) then empty else "D2::structure.has_sections must be true (doc must be sectioned, not a wall)" end),
    (if ((.sourcing.claims_total|type)=="number" and (.sourcing.claims_cited|type)=="number"
          and (.sourcing.claims_cited == .sourcing.claims_total)) then empty
       else "D3::every claim must be cited (sourcing.claims_cited must equal claims_total)" end),
    (if ((.sourcing.source_audit_ref|type)=="string" and (.sourcing.source_audit_ref|length)>0) then empty
       else "D3::sourcing.source_audit_ref must be a non-empty reference" end),
    (if (.readability.has_headings == true) then empty else "D4::readability.has_headings must be true" end),
    (if ((.readability.max_paragraph_words|type)=="number" and (.readability.max_paragraph_words <= $cap)) then empty
       else "D4::readability.max_paragraph_words exceeds cap \($cap) (wall of text)" end),
    (if (.audience == "external")
       then (if (.humanizer.passed == true and (.humanizer.evidence_ref|type)=="string" and (.humanizer.evidence_ref|length)>0) then empty
               else "D5::external doc REQUIRES humanizer.passed==true with a non-empty evidence_ref" end)
       else empty end),
    (if ((.blockers // []) | length) > 0 then "D6::doc-quality has \((.blockers|length)) blocker(s)" else empty end)
  ] | .[]' "$MANIFEST" 2>/dev/null)"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  add_violation "${line%%::*}" "${line#*::}"
done <<EOF
$ENVELOPE
EOF

# ── D7: evidence refs must point at REAL files (declaration must be WIRED, not a fabricated string) ──
# A local ref (no URL scheme) must exist on disk after stripping any #anchor; URL refs (contain "://")
# are accepted as external. Closes the "agent can type any string to a clean PASS" hole.
while IFS=$'\t' read -r field ref; do
  [ -z "$ref" ] && continue
  case "$ref" in *://*) continue ;; esac
  pp="${ref%%#*}"
  case "$pp" in /*|*..*) add_violation "D7" "$field '$ref' must be a project-relative path without parent traversal"; continue ;; esac
  [ -s "$ROOT/$pp" ] || add_violation "D7" "$field points at '$ref' but that evidence file does not exist or is empty"
done < <(
  jq -r '(.sourcing.source_audit_ref // empty) | select(length>0) | "source_audit_ref\t\(.)"' "$MANIFEST" 2>/dev/null
  jq -r 'select(.audience=="external") | (.humanizer.evidence_ref // empty) | select(length>0) | "humanizer.evidence_ref\t\(.)"' "$MANIFEST" 2>/dev/null
)

DETAILS="$(jq -n --argjson dc "$dcount" --argjson nv "$N_VIOL" --argjson v "$VIOL_JSON" '{applicable:true, deliverables:$dc, violations:$nv, items:$v}')"
if [ "$N_VIOL" -gt 0 ]; then
  echo "WALTEUR doc-quality-gate: FAIL — $N_VIOL violation(s)." >&2
  jq -r '.[] | "  - [\(.rule)] \(.message)"' <<<"$VIOL_JSON" >&2 2>/dev/null || true
  write_report "FAIL" "$N_VIOL doc-quality violation(s)" "$DETAILS"; exit 2
fi
echo "doc-quality-gate: ok — $dcount deliverable(s); structure, sourcing, readability, humanizer all pass." >&2
write_report "PASS" "document quality proven" "$DETAILS"; exit 0
