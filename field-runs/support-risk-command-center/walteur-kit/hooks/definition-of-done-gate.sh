#!/usr/bin/env bash
# WALTEUR definition-of-done-gate - ship-stage checklist evidence gate.
#
# Contract:
#   - No DoD and not in ship/reflect phase          => NOT_APPLICABLE, exit 0.
#   - Present DoD before ship                       => NOT_APPLICABLE, exit 0.
#   - Ship/reflect without a complete DoD           => FAIL, exit 2.
#   - Any unchecked item, missing/weak Evidence,
#     missing evidence file, weak N/A reason,
#     placeholder, or stale DoD                     => FAIL, exit 2.
#   - Closed DoD with fresh proof references        => PASS, exit 0.
#
# Report:
#   walteur-kit/definition-of-done-report.json
#
# Bypass:
#   WALTEUR_DOD=off
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
DOD="$KIT/DEFINITION-OF-DONE.md"
STATE="$KIT/autopilot/STATE.json"
REPORT="$KIT/definition-of-done-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

checked_count=0
unchecked_count=0
na_count=0

write_report() {
  verdict="$1"
  mode="$2"
  reason="$3"
  findings_json="${4:-[]}"
  if have jq; then
    jq -n \
      --arg v "$verdict" --arg ts "$TS" --arg mode "$mode" --arg reason "$reason" \
      --arg dod "${DOD#"$ROOT"/}" --arg required "${DOD_REQUIRED:-0}" \
      --argjson checked "${checked_count:-0}" --argjson unchecked "${unchecked_count:-0}" \
      --argjson na "${na_count:-0}" --argjson findings "$findings_json" \
      '{
        verdict: $v,
        ts: $ts,
        gate: "definition-of-done-gate",
        mode: $mode,
        required: ($required == "1"),
        dod_file: $dod,
        reason: $reason,
        counts: {
          checked: $checked,
          unchecked: $unchecked,
          not_applicable: $na
        },
        findings: $findings
      }' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"definition-of-done-gate","mode":"%s","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$mode")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0\n'
}

detect_dod_required() {
  DOD_REQUIRED=0
  DOD_REQUIRED_REASON=""

  if [ "${WALTEUR_DOD_REQUIRED:-}" = "1" ]; then
    DOD_REQUIRED=1
    DOD_REQUIRED_REASON="WALTEUR_DOD_REQUIRED=1"
    return 0
  fi

  if [ -s "$STATE" ] && jq empty "$STATE" >/dev/null 2>&1; then
    phase="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
    case "$phase" in
      ship|reflect)
        DOD_REQUIRED=1
        DOD_REQUIRED_REASON="STATE.phase=$phase"
        return 0 ;;
    esac
  fi
}

latest_source_mtime() {
  latest=0
  update_latest() {
    f="$1"
    [ -f "$f" ] || return 0
    case "$f" in
      "$REPORT"|"$DOD") return 0 ;;
    esac
    mt="$(mtime "$f")"
    [ "${mt:-0}" -gt "$latest" ] && latest="$mt"
  }

  if [ -d "$ROOT" ]; then
    while IFS= read -r -d '' f; do
      update_latest "$f"
    done < <(find "$ROOT" \
      \( -path '*/.git/*' -o -path '*/node_modules/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' \) -prune -o \
      -type f -print0 2>/dev/null)
  fi

  printf '%s\n' "$latest"
}

count_lines() {
  checked_count="$(grep -Ec '^[[:space:]]*-[[:space:]]+\[[xX]\]' "$DOD" 2>/dev/null || true)"
  unchecked_count="$(grep -Ec '^[[:space:]]*-[[:space:]]+\[[[:space:]]\]' "$DOD" 2>/dev/null || true)"
  na_count="$(grep -Ec '^[[:space:]]*-[[:space:]]+N/A\b' "$DOD" 2>/dev/null || true)"
}

validate_evidence_refs() {
  line_no="$1"
  evidence="$2"
  valid_ref=0
  invalid_refs=""

  if printf '%s' "$evidence" | grep -Eq '(^|[[:space:];,])(command|report|screenshot|review|signed-decision|log):[^[:space:]]'; then
    valid_ref=1
  fi
  if printf '%s' "$evidence" | grep -Eq '(^|[[:space:];,])url:https?://[^[:space:]]'; then
    valid_ref=1
  fi

  path_scan="$(printf '%s' "$evidence" | sed -E 's#https?://[^[:space:],;)]+##g')"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    ref="$(printf '%s' "$ref" | sed 's/^[[:space:]]*//; s/^[`"(]*//; s/[`".,;:)]*$//')"
    [ -n "$ref" ] || continue

    case "$ref" in
      ../*|*/../*)
        invalid_refs="${invalid_refs}${invalid_refs:+, }$ref"
        continue ;;
      "$ROOT"/*)
        candidate="$ref" ;;
      /*)
        invalid_refs="${invalid_refs}${invalid_refs:+, }$ref"
        continue ;;
      ./*)
        candidate="$ROOT/${ref#./}" ;;
      *)
        candidate="$ROOT/$ref" ;;
    esac

    if [ -s "$candidate" ]; then
      valid_ref=1
    else
      invalid_refs="${invalid_refs}${invalid_refs:+, }$ref"
    fi
  done < <(printf '%s\n' "$path_scan" | grep -Eo '([.]?/?[A-Za-z0-9._-]+/[^[:space:],;)]+|[A-Za-z0-9._-]+\.(json|md|txt|log|xml|ya?ml|html|png|jpe?g|webp|pdf|csv|ts|tsx|js|jsx|py|sh|go|rs|java|cs|rb|php|sql))' 2>/dev/null || true)

  if [ -n "$invalid_refs" ]; then
    add_finding "line.$line_no.evidence_ref" "Evidence references missing, empty, outside-root, or unsafe local file(s): $invalid_refs"
  fi

  if [ "$valid_ref" -eq 0 ]; then
    add_finding "line.$line_no.evidence_ref" "checked Evidence must cite a typed proof (command:, report:, screenshot:, review:, signed-decision:, url:https://, log:) or an existing local file"
  fi
}

check_closed_dod() {
  findings="[]"
  failures=0
  count_lines

  if [ "$checked_count" -eq 0 ] && [ "$na_count" -eq 0 ]; then
    add_finding "closed_items" "DoD must contain at least one checked item or reasoned N/A item"
  fi

  if [ "$unchecked_count" -gt 0 ]; then
    add_finding "unchecked_items" "DoD contains $unchecked_count unchecked item(s); close or convert each to N/A - reason"
  fi

  while IFS= read -r entry; do
    line_no="${entry%%:*}"
    line="${entry#*:}"
    case "$line" in
      *Evidence:*)
        evidence="${line#*Evidence:}"
        if ! printf '%s' "$evidence" | grep -Eq '[^[:space:]]'; then
          add_finding "line.$line_no.evidence" "checked item has an empty Evidence marker"
        else
          validate_evidence_refs "$line_no" "$evidence"
        fi ;;
      *)
        add_finding "line.$line_no.evidence" "checked item must include Evidence: with a command, report path, screenshot, review note, or signed decision" ;;
    esac
  done < <(grep -nE '^[[:space:]]*-[[:space:]]+\[[xX]\]' "$DOD" 2>/dev/null || true)

  while IFS= read -r entry; do
    line_no="${entry%%:*}"
    line="${entry#*:}"
    case "$line" in
      *"N/A - "*)
        reason="${line#*N/A - }"
        if ! printf '%s' "$reason" | grep -Eq '[[:alnum:]]'; then
          add_finding "line.$line_no.na_reason" "N/A item has no concrete reason"
        fi ;;
      *)
        add_finding "line.$line_no.na_reason" "N/A item must use: N/A - reason" ;;
    esac
  done < <(grep -nE '^[[:space:]]*-[[:space:]]+N/A\b' "$DOD" 2>/dev/null || true)

  while IFS= read -r entry; do
    line_no="${entry%%:*}"
    add_finding "line.$line_no.placeholder" "DoD contains placeholder or TODO text"
  done < <(grep -nEi '\b(TODO|TBD)\b|lorem ipsum|placeholder|<[^>]+>' "$DOD" 2>/dev/null || true)

  dod_mtime="$(mtime "$DOD")"
  latest_mtime="$(latest_source_mtime)"
  if [ "${latest_mtime:-0}" -gt "${dod_mtime:-0}" ]; then
    add_finding "freshness" "DoD is older than one or more source/evidence files; re-read outputs and update the DoD last"
  fi

  if [ "$failures" -gt 0 ]; then
    write_report "FAIL" "required" "Definition of Done is incomplete for ship/reflect." "$findings"
    return 2
  fi

  write_report "PASS" "required" "Definition of Done is closed with fresh evidence markers." "$findings"
  return 0
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
    echo "definition-of-done-gate selftest SKIP - jq not installed."
    return 0
  fi

  write_state() {
    root="$1"
    phase="$2"
    mkdir -p "$root/walteur-kit/autopilot"
    jq -n --arg phase "$phase" '{phase:$phase}' > "$root/walteur-kit/autopilot/STATE.json"
  }

  write_complete_dod() {
    root="$1"
    mkdir -p "$root/walteur-kit"
    printf '{"schema_version":1}\n' > "$root/walteur-kit/build-contract.json"
    printf '{"verdict":"PASS"}\n' > "$root/walteur-kit/qa-report.json"
    printf '{"certified":true}\n' > "$root/walteur-kit/audit.json"
    cat > "$root/walteur-kit/DEFINITION-OF-DONE.md" <<'DODEOF'
# Definition of Done

- [x] Build class recorded. Evidence: walteur-kit/build-contract.json
- [x] Verification output read. Evidence: walteur-kit/qa-report.json
- [x] Terminal audit reviewed. Evidence: walteur-kit/audit.json
- N/A - No external action in this selftest run.
DODEOF
  }

  echo "definition-of-done-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dod-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "no DoD before ship -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dod-selftest.XXXXXX")" || return 1
  write_state "$tmp" "intake"
  mkdir -p "$tmp/walteur-kit"
  printf '# DoD\n- [ ] Open item\n' > "$tmp/walteur-kit/DEFINITION-OF-DONE.md"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "unchecked template before ship -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dod-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ship missing DoD -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dod-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  mkdir -p "$tmp/walteur-kit"
  printf '# DoD\n- [ ] Open item\n' > "$tmp/walteur-kit/DEFINITION-OF-DONE.md"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ship unchecked item -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dod-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  mkdir -p "$tmp/walteur-kit"
  printf '# DoD\n- [x] Checked with no evidence\n' > "$tmp/walteur-kit/DEFINITION-OF-DONE.md"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ship checked item without Evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dod-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  mkdir -p "$tmp/walteur-kit"
  printf '# DoD\n- [x] Checked with fake proof. Evidence: all good\n' > "$tmp/walteur-kit/DEFINITION-OF-DONE.md"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ship checked item with unverifiable Evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dod-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  mkdir -p "$tmp/walteur-kit"
  printf '# DoD\n- [x] Missing report proof. Evidence: walteur-kit/missing-report.json\n' > "$tmp/walteur-kit/DEFINITION-OF-DONE.md"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ship missing evidence file -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dod-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  mkdir -p "$tmp/walteur-kit"
  printf '# DoD\n- N/A\n' > "$tmp/walteur-kit/DEFINITION-OF-DONE.md"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ship N/A without reason -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dod-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  mkdir -p "$tmp/walteur-kit"
  printf '# DoD\n- [x] Placeholder check. Evidence: <report>\n' > "$tmp/walteur-kit/DEFINITION-OF-DONE.md"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ship placeholder evidence -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dod-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  write_complete_dod "$tmp"
  touch -t 202001010000 "$tmp/walteur-kit/DEFINITION-OF-DONE.md" 2>/dev/null || true
  printf 'newer\n' > "$tmp/src-newer.txt"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ship stale DoD -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dod-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  write_complete_dod "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "ship complete DoD -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dod-selftest.XXXXXX")" || return 1
  write_state "$tmp" "ship"
  WALTEUR_DOD=off WALTEUR_ROOT="$tmp" bash "$0" "$tmp" >/dev/null 2>&1
  ck "WALTEUR_DOD=off -> SKIP" 0 "$?"
  rm -rf "$tmp"

  echo "definition-of-done-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest)
    selftest
    exit $? ;;
esac

if [ "${WALTEUR_DOD:-}" = "off" ]; then
  write_report "SKIP" "bypass" "WALTEUR_DOD=off"
  exit 0
fi

if [ -f "$KIT/PAUSED" ]; then
  write_report "FAIL" "paused" "walteur-kit/PAUSED is present; harness is paused."
  exit 2
fi

if ! have jq; then
  write_report "SKIP" "tool-missing" "jq is not installed."
  exit 0
fi

detect_dod_required

if [ ! -s "$DOD" ]; then
  if [ "$DOD_REQUIRED" -eq 1 ]; then
    write_report "FAIL" "required" "Definition of Done is required at ship/reflect but missing or empty."
    exit 2
  fi
  write_report "NOT_APPLICABLE" "not-required" "Definition of Done is not required before ship/reflect."
  exit 0
fi

if [ "$DOD_REQUIRED" -ne 1 ]; then
  count_lines
  write_report "NOT_APPLICABLE" "not-required" "Definition of Done exists but ship/reflect has not been reached."
  exit 0
fi

check_closed_dod
exit $?
