#!/usr/bin/env bash
# WALTEUR persona-coverage-gate — HARD gate (Tony's standing org model). The orchestrator spawns a named
# senior org on demand: a Chief of Staff coordinating, a Senior PM front-loading red-flag detection at PLAN,
# specialists by signal (Pro Designer, CMO, Senior Cybersecurity Analyst, Senior QA, Full-Stack, DevOps,
# Data, a11y, perf, compliance…), and a terminal Audit Squad reviewing everything. This gate makes "the right
# roles engaged" MECHANICAL: it reads personas.json + preflight signals, computes which personas are REQUIRED
# for this build, and FAILs if any required role left no engagement breadcrumb (walteur-kit/personas/<id>.json).
#
# Applies when walteur-kit/personas.json + preflight-signals.json are present. CONTRACT: a required persona
# with no (or FAIL/SKIP) breadcrumb => FAIL exit 2 · not a roster build => NOT_APPLICABLE · PAUSED => exit 2 ·
# bypass WALTEUR_PERSONA=off. Report: walteur-kit/persona-coverage-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "persona-coverage-gate - HARD gate (Tonys standing org model). The orchestrator spawns a named"
  printf '%s\n' "usage: bash persona-coverage-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/persona-coverage-report.json - fix recipes: walteur-kit/REMEDIATION.md (## persona-coverage-gate)"
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
CRUMBS="$KIT/personas"
REPORT="$KIT/persona-coverage-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"persona-coverage", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","reason":"%s"}\n' "$v" "$r" > "$REPORT" 2>/dev/null || true; }

sig_true() { jq -e --arg s "$1" '(.[$s] // false)==true' "$SIGNALS" >/dev/null 2>&1; }

# evaluate a spawn_when expression ("always" | OR of (AND of signal names)) against the signals.
expr_true() {
  local e="$1" orterm andsig ok
  [ "$e" = "always" ] && return 0
  while IFS= read -r orterm; do
    [ -n "$orterm" ] || continue
    ok=1
    for andsig in $(printf '%s' "$orterm" | sed 's/ *&& */ /g'); do
      andsig="$(printf '%s' "$andsig" | tr -d '[:space:]')"
      [ -n "$andsig" ] || continue
      sig_true "$andsig" || ok=0
    done
    [ "$ok" = 1 ] && return 0
  done < <(printf '%s\n' "$e" | sed 's/ *|| */\n/g')   # %s\n: guarantee a trailing newline so `read` keeps the last orterm
  return 1
}

# a persona "engaged" if its breadcrumb exists and verdict is not FAIL/SKIP/empty.
engaged() {
  local f="$CRUMBS/$1.json"
  [ -f "$f" ] || return 1
  local v; v="$(jq -r '.verdict // "PASS"' "$f" 2>/dev/null || echo PASS)"
  case "$v" in FAIL|SKIP|"") return 1 ;; *) return 0 ;; esac
}

applies() { [ -f "$ROSTER" ] && [ -f "$SIGNALS" ]; }

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused; echo "persona-coverage-gate: PAUSED -> exit 2"; exit 2; }
  [ "${WALTEUR_PERSONA:-}" = "off" ] && { write_report SKIP bypassed; echo "persona-coverage-gate: bypassed"; exit 0; }
  if ! have jq; then write_report SKIP "no jq"; echo "persona-coverage-gate: SKIP"; exit 0; fi
  if ! applies; then write_report NOT_APPLICABLE "no personas.json + preflight-signals.json"; echo "persona-coverage-gate: NOT_APPLICABLE"; exit 0; fi

  # enforcement: 'required' personas matching their signal MUST engage (hard-fail if missing); 'advisory'
  # personas are recommended + reported but never block. Default (missing field) = required.
  local n_req=0 n_ok=0 n_adv=0 n_adv_missing=0 id title sw enf
  local adv_missing=""
  while IFS=$'\t' read -r id title sw enf; do
    [ -n "$id" ] || continue
    expr_true "$sw" || continue
    if [ "$enf" = "advisory" ]; then
      n_adv=$((n_adv+1)); engaged "$id" || { n_adv_missing=$((n_adv_missing+1)); adv_missing="$adv_missing $id"; }
    else
      n_req=$((n_req+1))
      if engaged "$id"; then n_ok=$((n_ok+1)); else add_finding "$id" "REQUIRED persona '$title' (spawn_when: $sw) did not engage — no walteur-kit/personas/$id.json breadcrumb"; fi
    fi
  done < <(jq -r '.personas[] | [.id, .title, .spawn_when, (.enforcement // "required")] | @tsv' "$ROSTER" 2>/dev/null)

  [ "$n_adv_missing" -gt 0 ] && echo "persona-coverage-gate: ADVISORY — $n_adv_missing recommended role(s) not engaged:$adv_missing (non-blocking)" >&2 || true
  if [ "$failures" -gt 0 ]; then
    write_report FAIL "$failures required persona(s) missing of $n_req required ($n_ok engaged); $n_adv_missing/$n_adv advisory not engaged"
    echo "persona-coverage-gate: FAIL ($n_ok/$n_req required personas engaged; $n_adv_missing advisory recommended) -> exit 2"
    printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null | head -12 || true
    exit 2
  fi
  write_report PASS "all $n_req required personas engaged ($n_adv_missing/$n_adv advisory recommended, non-blocking)"
  echo "persona-coverage-gate: PASS ($n_ok/$n_req required senior personas engaged · $n_adv_missing/$n_adv advisory recommended)"
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq; then echo "persona-coverage selftest SKIP - no jq."; return 0; fi
  echo "persona-coverage-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  # minimal roster covering an always-persona + two signal-gated ones
  roster() { cat > "$1/walteur-kit/personas.json" <<'EOF'
{"personas":[
 {"id":"chief-of-staff","title":"Chief of Staff","spawn_when":"always"},
 {"id":"senior-pm","title":"Senior PM","spawn_when":"always"},
 {"id":"senior-qa-analyst","title":"Senior QA","spawn_when":"always"},
 {"id":"audit-lead","title":"Audit Lead","spawn_when":"always"},
 {"id":"pro-designer","title":"Pro Designer","spawn_when":"has_ui || is_user_facing"},
 {"id":"senior-cybersecurity-analyst","title":"Sec Analyst","spawn_when":"has_auth || has_payments || regulated"},
 {"id":"fullstack-developer","title":"Full-Stack","spawn_when":"has_ui && has_api_boundary"},
 {"id":"growth-marketer","title":"Growth","spawn_when":"go_to_market","enforcement":"advisory"}
]}
EOF
  }
  crumb() { mkdir -p "$1/walteur-kit/personas"; printf '{"verdict":"PASS","persona":"%s"}\n' "$2" > "$1/walteur-kit/personas/$2.json"; }
  always4() { for p in chief-of-staff senior-pm senior-qa-analyst audit-lead; do crumb "$1" "$p"; done; }

  # 1. no roster -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/personacov.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"has_ui":true}\n' > "$t/walteur-kit/preflight-signals.json"; ck "no roster -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. minimal build (no signals) + all always-personas engaged -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/personacov.XXXXXX")"; mkdir -p "$t/walteur-kit"; roster "$t"; printf '{}\n' > "$t/walteur-kit/preflight-signals.json"; always4 "$t"; ck "always-personas engaged -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. G1 a required always-persona (senior-pm) missing -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/personacov.XXXXXX")"; mkdir -p "$t/walteur-kit"; roster "$t"; printf '{}\n' > "$t/walteur-kit/preflight-signals.json"; for p in chief-of-staff senior-qa-analyst audit-lead; do crumb "$t" "$p"; done; ck "G1 missing Senior PM -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. G2 has_ui build but Pro Designer missing -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/personacov.XXXXXX")"; mkdir -p "$t/walteur-kit"; roster "$t"; printf '{"has_ui":true}\n' > "$t/walteur-kit/preflight-signals.json"; always4 "$t"; ck "G2 has_ui, no Pro Designer -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. G3 has_ui build WITH Pro Designer (and not needing fullstack since no api) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/personacov.XXXXXX")"; mkdir -p "$t/walteur-kit"; roster "$t"; printf '{"has_ui":true}\n' > "$t/walteur-kit/preflight-signals.json"; always4 "$t"; crumb "$t" pro-designer; ck "G3 has_ui + Pro Designer -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 6. G4 AND-signal: has_ui && has_api_boundary requires fullstack -> FAIL when missing
  t="$(mktemp -d "${TMPDIR:-/tmp}/personacov.XXXXXX")"; mkdir -p "$t/walteur-kit"; roster "$t"; printf '{"has_ui":true,"has_api_boundary":true}\n' > "$t/walteur-kit/preflight-signals.json"; always4 "$t"; crumb "$t" pro-designer; ck "G4 ui&&api, no Full-Stack -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. G5 security signal: has_payments requires Sec Analyst -> PASS when present
  t="$(mktemp -d "${TMPDIR:-/tmp}/personacov.XXXXXX")"; mkdir -p "$t/walteur-kit"; roster "$t"; printf '{"has_payments":true}\n' > "$t/walteur-kit/preflight-signals.json"; always4 "$t"; crumb "$t" senior-cybersecurity-analyst; ck "G5 has_payments + Sec Analyst -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 8. FP guard: a FAIL breadcrumb does not count as engaged -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/personacov.XXXXXX")"; mkdir -p "$t/walteur-kit/personas"; roster "$t"; printf '{}\n' > "$t/walteur-kit/preflight-signals.json"; for p in chief-of-staff senior-qa-analyst audit-lead; do crumb "$t" "$p"; done; printf '{"verdict":"FAIL"}\n' > "$t/walteur-kit/personas/senior-pm.json"; ck "G6 FAIL breadcrumb != engaged -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8b. advisory role missing does NOT block: go_to_market signal, growth-marketer (advisory) absent -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/personacov.XXXXXX")"; mkdir -p "$t/walteur-kit"; roster "$t"; printf '{"go_to_market":true}\n' > "$t/walteur-kit/preflight-signals.json"; always4 "$t"; ck "G7 advisory role missing -> PASS (non-blocking)" 0 "$(run "$t")"; rm -rf "$t"
  # 9. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/personacov.XXXXXX")"; mkdir -p "$t/walteur-kit"; roster "$t"; printf '{}\n' > "$t/walteur-kit/preflight-signals.json"; WALTEUR_ROOT="$t" WALTEUR_PERSONA=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/personacov.XXXXXX")"; mkdir -p "$t/walteur-kit"; roster "$t"; printf '{}\n' > "$t/walteur-kit/preflight-signals.json"; always4 "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "persona-coverage-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
