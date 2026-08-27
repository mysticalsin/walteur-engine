#!/usr/bin/env bash
# WALTEUR skill-index-lint - validates walteur-kit/skill-index.json shape (drift guard).
#
# Contract:
#   - skill-index.json absent => NOT_APPLICABLE, exit 0.
#   - jq absent               => SKIP, exit 0, recorded loudly.
#   - malformed / shape-violation / duplicate skill / bad breadcrumb => FAIL, exit 2.
#   - walteur-kit/PAUSED      => exit 2.
#
# Report:
#   walteur-kit/skill-index-report.json
#
# Bypass:
#   WALTEUR_SKILL_INDEX=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "skill-index-lint - validates walteur-kit/skill-index.json shape (drift guard)."
  printf '%s\n' "usage: bash skill-index-lint.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/skill-index-report.json - fix recipes: walteur-kit/REMEDIATION.md (## skill-index-lint)"
  printf '%s\n' "bypass: WALTEUR_SKILL_INDEX=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
INDEX="${WALTEUR_SKILL_INDEX_FILE:-$KIT/skill-index.json}"
REPORT="$KIT/skill-index-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  verdict="$1"; reason="$2"; findings="${3:-[]}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" \
      --arg index "${INDEX#"$ROOT"/}" --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"skill-index", index_file:$index, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"skill-index","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

validate_shape() {
  jq -e '
    def nonempty_string($k): (.[$k] | type == "string" and length > 0);
    type == "object"
    and (.schema_version == 1)
    and (.skill_count | type == "number" and floor == . and . >= 1)
    and (.skills | type == "array" and length >= 1)
    and (.skill_count == (.skills | length))
    and all(.skills[];
        type == "object"
        and nonempty_string("skill")
        and nonempty_string("discipline")
        and (.phase_affinity | type == "array" and length >= 1 and all(.[]; type == "string" and length > 0))
        and (.signal_tags | type == "array" and all(.[]; type == "string"))
        and (.trigger_keywords | type == "array")
        and (.breadcrumb | type == "string" and startswith("walteur-kit/") and endswith(".json"))
        and (.hard_gate | type == "boolean")
        and nonempty_string("source_path")
      )
    and (([.skills[].skill] | length) == ([.skills[].skill] | unique | length))
  ' "$INDEX" >/dev/null 2>&1
}

selftest() {
  pass=0; fail=0
  ck() { name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then echo "  ok   - $name (rc=$got)"; pass=$((pass+1));
    else echo "  FAIL - $name (want $want got $got)"; fail=$((fail+1)); fi; }

  if ! have jq; then echo "skill-index-lint selftest SKIP - jq not installed."; return 0; fi
  echo "skill-index-lint selftest:"

  good() {
    mkdir -p "$1/walteur-kit"
    cat > "$1/walteur-kit/skill-index.json" <<'JSON'
{
  "schema_version": 1,
  "generated_at": "2026-06-27",
  "source_root": "fixture",
  "skill_count": 2,
  "skills": [
    {"skill":"org-a","discipline":"engineering","phase_affinity":["Build"],"signal_tags":[],"trigger_keywords":[],"breadcrumb":"walteur-kit/skills/org-a.json","hard_gate":false,"source_path":"04 Code/org-a/SKILL.md"},
    {"skill":"org-b","discipline":"quality","phase_affinity":["Review","Audit"],"signal_tags":["has_ui","external_surface"],"trigger_keywords":["brand"],"breadcrumb":"walteur-kit/confidentiality-pass.json","hard_gate":true,"source_path":"00 Humanizer/org-b/SKILL.md"}
  ]
}
JSON
  }

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skill-index-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no skill-index.json -> NOT_APPLICABLE" 0 "$?"; rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skill-index-selftest.XXXXXX")" || return 1
  good "$tmp"; WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "valid skill-index -> PASS" 0 "$?"; rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skill-index-selftest.XXXXXX")" || return 1
  good "$tmp"; printf '{ bad json\n' > "$tmp/walteur-kit/skill-index.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "malformed -> FAIL" 2 "$?"; rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skill-index-selftest.XXXXXX")" || return 1
  good "$tmp"; jq '.skill_count = 5' "$tmp/walteur-kit/skill-index.json" > "$tmp/i.json" && mv "$tmp/i.json" "$tmp/walteur-kit/skill-index.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "skill_count mismatch -> FAIL" 2 "$?"; rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skill-index-selftest.XXXXXX")" || return 1
  good "$tmp"; jq 'del(.skills[0].breadcrumb)' "$tmp/walteur-kit/skill-index.json" > "$tmp/i.json" && mv "$tmp/i.json" "$tmp/walteur-kit/skill-index.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing breadcrumb -> FAIL" 2 "$?"; rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skill-index-selftest.XXXXXX")" || return 1
  good "$tmp"; jq '.skills[1].skill = "org-a"' "$tmp/walteur-kit/skill-index.json" > "$tmp/i.json" && mv "$tmp/i.json" "$tmp/walteur-kit/skill-index.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "duplicate skill name -> FAIL" 2 "$?"; rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skill-index-selftest.XXXXXX")" || return 1
  good "$tmp"; WALTEUR_ROOT="$tmp" WALTEUR_SKILL_INDEX=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit 0" 0 "$?"; rm -rf "$tmp"

  echo "skill-index-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_SKILL_INDEX:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_SKILL_INDEX=off" "[]"; echo "skill-index-lint: bypassed." >&2; exit 0; }

if [ ! -f "$INDEX" ]; then
  write_report "NOT_APPLICABLE" "skill-index.json absent" "[]"
  echo "skill-index-lint: NOT_APPLICABLE - skill-index.json absent"
  exit 0
fi
if ! have jq; then
  write_report "SKIP" "jq unavailable" "[]"
  echo "skill-index-lint: SKIP - jq unavailable." >&2
  exit 0
fi

if ! jq -e . "$INDEX" >/dev/null 2>&1; then
  write_report "FAIL" "skill-index.json is not valid JSON" '[{"check":"json","message":"invalid JSON"}]'
  echo "skill-index-lint: FAIL - invalid JSON"
  exit 2
fi
if ! validate_shape; then
  write_report "FAIL" "skill-index.json violates the shape floor" '[{"check":"shape","message":"schema_version/skill_count/skills entries invalid or duplicate skill names"}]'
  echo "skill-index-lint: FAIL - shape violation"
  exit 2
fi

count="$(jq -r '.skill_count' "$INDEX")"
write_report "PASS" "skill-index.json valid ($count skills)" "[]"
echo "skill-index-lint: PASS - $count skills indexed"
exit 0
