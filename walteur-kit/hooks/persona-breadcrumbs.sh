#!/usr/bin/env bash
# WALTEUR persona-breadcrumbs — EMITTER (not a gate). Maps WALTEUR's real governance phases onto the named
# persona roster (personas.json) and writes an engagement breadcrumb walteur-kit/personas/<id>.json for every
# persona whose (a) spawn_when matches the build signals AND (b) phase's evidence artifact actually exists.
# This makes persona-coverage-gate.sh LIVE + HONEST: a persona is "engaged" only when its phase genuinely ran
# (PLAN.md for plan/coordination, SUMMARY.jsonl for build, qa-report.json for review, audit.json for audit,
# red-flag-register.json for the Senior PM). A skipped phase => no breadcrumb => coverage FAILs. Run near the
# end of a build (the orchestrator calls it after the terminal audit). bypass WALTEUR_PERSONA=off.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "persona-breadcrumbs - EMITTER (not a gate). Maps WALTEURs real governance phases onto the named"
  printf '%s\n' "usage: bash persona-breadcrumbs.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/qa-report.json - fix recipes: walteur-kit/REMEDIATION.md (## persona-breadcrumbs)"
  printf '%s\n' "bypass: WALTEUR_PERSONA=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
ROSTER="$KIT/personas.json"
SIGNALS="$KIT/preflight-signals.json"
OUT="$KIT/personas"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
have() { command -v "$1" >/dev/null 2>&1; }

sig_true() { jq -e --arg s "$1" '(.[$s] // false)==true' "$SIGNALS" >/dev/null 2>&1; }
expr_true() {
  local e="$1" orterm andsig ok
  [ "$e" = "always" ] && return 0
  while IFS= read -r orterm; do
    [ -n "$orterm" ] || continue
    ok=1
    for andsig in $(printf '%s' "$orterm" | sed 's/ *&& */ /g'); do
      andsig="$(printf '%s' "$andsig" | tr -d '[:space:]')"; [ -n "$andsig" ] || continue
      sig_true "$andsig" || ok=0
    done
    [ "$ok" = 1 ] && return 0
  done < <(printf '%s\n' "$e" | sed 's/ *|| */\n/g')
  return 1
}

# evidence artifact for a persona's phase (the proof that phase ran). Returns the path or "" if no evidence.
evidence_for() {
  local id="$1" phase="$2"
  case "$id" in senior-pm) [ -f "$KIT/red-flag-register.json" ] && { echo "walteur-kit/red-flag-register.json"; return; } ;; esac
  case "$phase" in
    all|plan|intake) [ -f "$ROOT/PLAN.md" ] && echo "PLAN.md" ;;
    build) { [ -f "$KIT/SUMMARY.jsonl" ] && echo "walteur-kit/SUMMARY.jsonl"; } || { [ -f "$ROOT/PLAN.md" ] && [ -n "$(find "$ROOT" -type d \( -name node_modules -o -name .git -o -name walteur-kit \) -prune -o -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.py' -o -name '*.go' -o -name '*.css' -o -name '*.html' \) -print 2>/dev/null | head -1)" ] && echo "src"; } ;;
    review) [ -f "$KIT/qa-report.json" ] && echo "walteur-kit/qa-report.json" ;;
    audit) [ -f "$KIT/audit.json" ] && echo "walteur-kit/audit.json" ;;
  esac
}

main() {
  [ "${WALTEUR_PERSONA:-}" = "off" ] && { echo "persona-breadcrumbs: bypassed"; exit 0; }
  if ! have jq; then echo "persona-breadcrumbs: SKIP (no jq)"; exit 0; fi
  [ -f "$ROSTER" ] && [ -f "$SIGNALS" ] || { echo "persona-breadcrumbs: NOT_APPLICABLE (no roster+signals)"; exit 0; }
  mkdir -p "$OUT"
  local id title phase sw n=0 ev
  while IFS=$'\t' read -r id title phase sw; do
    [ -n "$id" ] || continue
    expr_true "$sw" || continue
    ev="$(evidence_for "$id" "$phase")"
    [ -n "$ev" ] || continue
    jq -n --arg id "$id" --arg t "$title" --arg ph "$phase" --arg ev "$ev" --arg ts "$TS" \
      '{verdict:"PASS", persona:$id, title:$t, phase:$ph, evidence:$ev, ts:$ts}' > "$OUT/$id.json" 2>/dev/null && n=$((n+1))
  done < <(jq -r '.personas[] | [.id, .title, (.phase // "all"), .spawn_when] | @tsv' "$ROSTER" 2>/dev/null)
  echo "persona-breadcrumbs: wrote $n engagement breadcrumb(s) (evidence-backed)"
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "persona-breadcrumbs selftest SKIP - no jq."; return 0; fi
  echo "persona-breadcrumbs selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  fullkit() {
    local d="$1"; mkdir -p "$d/walteur-kit"
    printf '{"personas":[{"id":"chief-of-staff","title":"CoS","phase":"all","spawn_when":"always"},{"id":"senior-pm","title":"PM","phase":"plan","spawn_when":"always"},{"id":"senior-qa-analyst","title":"QA","phase":"review","spawn_when":"always"},{"id":"audit-lead","title":"Audit","phase":"audit","spawn_when":"always"},{"id":"pro-designer","title":"Design","phase":"build","spawn_when":"has_ui"}]}\n' > "$d/walteur-kit/personas.json"
    printf '{"has_ui":true}\n' > "$d/walteur-kit/preflight-signals.json"
    printf '# Plan\n' > "$d/PLAN.md"; printf '{}\n' > "$d/walteur-kit/SUMMARY.jsonl"
    printf '{}\n' > "$d/walteur-kit/qa-report.json"; printf '{}\n' > "$d/walteur-kit/audit.json"
    printf '{}\n' > "$d/walteur-kit/red-flag-register.json"
  }
  # 1. full kit -> writes 5 breadcrumbs (all evidenced)
  t="$(mktemp -d "${TMPDIR:-/tmp}/personabre.XXXXXX")"; fullkit "$t"; WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "full kit writes all 5" 5 "$(ls "$t/walteur-kit/personas" 2>/dev/null | wc -l | tr -d ' ')"; rm -rf "$t"
  # 2. no audit.json -> audit-lead breadcrumb NOT written (skipped phase = honest miss)
  t="$(mktemp -d "${TMPDIR:-/tmp}/personabre.XXXXXX")"; fullkit "$t"; rm -f "$t/walteur-kit/audit.json"; WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "audit-lead absent when no audit.json" 0 "$([ -f "$t/walteur-kit/personas/audit-lead.json" ] && echo 1 || echo 0)"; rm -rf "$t"
  # 3. signal off (no has_ui) -> pro-designer NOT written
  t="$(mktemp -d "${TMPDIR:-/tmp}/personabre.XXXXXX")"; fullkit "$t"; printf '{}\n' > "$t/walteur-kit/preflight-signals.json"; WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; ck "no has_ui -> no pro-designer crumb" 0 "$([ -f "$t/walteur-kit/personas/pro-designer.json" ] && echo 1 || echo 0)"; rm -rf "$t"
  # 4. bypass
  t="$(mktemp -d "${TMPDIR:-/tmp}/personabre.XXXXXX")"; fullkit "$t"; WALTEUR_ROOT="$t" WALTEUR_PERSONA=off bash "$SELF" >/dev/null 2>&1; ck "bypass writes nothing" 0 "$(ls "$t/walteur-kit/personas" 2>/dev/null | wc -l | tr -d ' ')"; rm -rf "$t"
  echo "persona-breadcrumbs selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
