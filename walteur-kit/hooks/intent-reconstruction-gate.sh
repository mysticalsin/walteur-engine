#!/usr/bin/env bash
# WALTEUR intent-reconstruction-gate — HARD gate on the INTENT.md artifact (the COMPREHEND-phase contract,
# §2.6 BROWNFIELD UPGRADE). The symmetric twin of prd-gate: a PRD validates the intent of a NEW build; this
# validates the REVERSE-ENGINEERED intent of an EXISTING one. You cannot safely upgrade an app whose purpose
# you have not recovered — so a missing/stub INTENT.md on a brownfield signal = FAIL (exit 2).
#
# Applicability (detect-or-LOUD-SKIP). A "brownfield signal" is EITHER preflight-signals.json .is_brownfield
#   ==true OR a walteur-kit/INTENT.md present. NEITHER => NOT_APPLICABLE (exit 0): a greenfield build has no
#   prior intent to reconstruct — its intent lives in PRD.md, governed by prd-gate.
# SHORT-CIRCUIT: a brownfield app that ALREADY documents intent in a non-stub PRD.md (a WALTEUR-built app)
#   needs no reconstruction. PRD present + non-stub + no INTENT.md => PASS.
#
# Quality floor (anti-hallucination) — when applicable, INTENT.md must carry ALL of:
#   (1) >=12 non-empty lines,                 (2) a what-it-IS signal,
#   (3) an ORIGINAL-GOAL signal,              (4) a used-for / users signal,
#   (5) >=1 confidence label (confirmed|inferred|unknown) — proves fact was separated from guess,
#   (6) >=1 evidence reference (a file:line, or an `evidence`/`evidence_refs` key) — grounds the claims.
#   (5)+(6) are the load-bearing pair: an INTENT with no labels or no evidence is a guess, not a recovery.
#
# Bypass: WALTEUR_INTENT=off => SKIP, exit 0. Kill switch: walteur-kit/PAUSED => exit 2.
# Zero-dep: bash + grep + awk + sed (+ jq for the report only; falls back to printf). HARD: exit 2 on a real violation.
# Report: walteur-kit/intent-reconstruction-report.json {verdict, ts, gate, mode, reason, findings}.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "intent-reconstruction-gate - HARD gate on the INTENT.md artifact (the COMPREHEND-phase contract,"
  printf '%s\n' "usage: bash intent-reconstruction-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/intent-reconstruction-report.json - fix recipes: walteur-kit/REMEDIATION.md (## intent-reconstruction-gate)"
  printf '%s\n' "bypass: WALTEUR_INTENT=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
REPORT="$KIT/intent-reconstruction-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; }
write_report() { # $1=verdict $2=mode $3=reason
  if have jq; then
    jq -n --arg v "$1" --arg ts "$TS" --arg mode "$2" --arg r "$3" --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"intent-reconstruction", mode:$mode, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"intent-reconstruction","mode":"%s","reason":"%s"}\n' "$1" "$TS" "$2" "$3" > "$REPORT" 2>/dev/null || true
}

brownfield_signal() { [ -f "$SIGNALS" ] && have jq && jq -e '.is_brownfield==true' "$SIGNALS" >/dev/null 2>&1; }

prd_nonstub() { # $1 = path — true if the file is a non-stub PRD (the short-circuit floor)
  local f="$1" n
  n="$(grep -cv '^[[:space:]]*$' "$f" 2>/dev/null)"; n="${n:-0}"
  [ "$n" -ge 12 ] || return 1
  grep -Eqi 'problem|background|why[ -]?now|objective|outcome' "$f" || return 1
  return 0
}

run_gate() {
  DIR="${1:-}"

  [ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }

  if [ "${WALTEUR_INTENT:-on}" = "off" ]; then
    echo "WALTEUR intent-reconstruction-gate SKIP — bypass WALTEUR_INTENT=off (recorded, not silent-green)." >&2
    write_report "SKIP" "bypass" "bypass WALTEUR_INTENT=off"; exit 0
  fi
  for t in grep awk sed; do
    command -v "$t" >/dev/null 2>&1 || { echo "WALTEUR intent-reconstruction-gate SKIP — '$t' not installed (recorded)." >&2; write_report "SKIP" "tool-missing" "$t not installed"; exit 0; }
  done

  # locate the contract files (kit first, then root, then the scanned dir)
  INTENT=""; for c in "$KIT/INTENT.md" "$ROOT/INTENT.md" "${DIR:+$DIR/INTENT.md}"; do [ -n "$c" ] && [ -f "$c" ] && { INTENT="$c"; break; }; done
  PRD="";    for c in "$KIT/PRD.md"    "$ROOT/PRD.md"    "${DIR:+$DIR/PRD.md}";    do [ -n "$c" ] && [ -f "$c" ] && { PRD="$c"; break; }; done

  # ── applicability ─────────────────────────────────────────────────────────────
  if ! brownfield_signal && [ -z "$INTENT" ]; then
    echo "WALTEUR intent-reconstruction-gate NOT_APPLICABLE — no brownfield signal (greenfield: intent lives in PRD.md)." >&2
    write_report "NOT_APPLICABLE" "not-applicable" \
      "no brownfield signal (no preflight-signals.is_brownfield, no INTENT.md): greenfield build, intent governed by prd-gate"
    exit 0
  fi

  # ── short-circuit: WALTEUR-built app already documents intent in a non-stub PRD ─
  if [ -z "$INTENT" ] && [ -n "$PRD" ] && prd_nonstub "$PRD"; then
    write_report "PASS" "prd-short-circuit" "brownfield app already documents intent in ${PRD#"$ROOT"/} (non-stub PRD); no reconstruction needed"
    echo "WALTEUR intent-reconstruction-gate: PASS — intent already documented in PRD (${PRD#"$ROOT"/})." >&2
    exit 0
  fi

  # ── brownfield but no INTENT.md and no usable PRD ──────────────────────────────
  if [ -z "$INTENT" ]; then
    add_finding "missing-intent" "brownfield signal present but no INTENT.md (and no non-stub PRD.md). Run COMPREHEND (§2.6): reverse-engineer intent into walteur-kit/INTENT.md from INTENT.template.md."
    write_report "FAIL" "applicable" "brownfield signal but no INTENT.md and no non-stub PRD.md — cannot upgrade an app whose intent is not recovered"
    echo "WALTEUR intent-reconstruction-gate: FAIL — brownfield but no INTENT.md." >&2
    echo "  Fix: author walteur-kit/INTENT.md (copy walteur-kit/INTENT.template.md; run COMPREHEND, §2.6)." >&2
    exit 2
  fi

  # ── anti-hallucination quality floor (zero-dep, grep) ─────────────────────────
  INTENT_REL="${INTENT#"$ROOT"/}"
  NONEMPTY="$(grep -cv '^[[:space:]]*$' "$INTENT" 2>/dev/null)"; NONEMPTY="${NONEMPTY:-0}"
  MISSING=()
  [ "$NONEMPTY" -lt 12 ] && MISSING+=("min-lines(>=12, got $NONEMPTY)")
  grep -Eqi 'what_it_is|what it is' "$INTENT" || MISSING+=("what-it-is")
  grep -Eqi 'original_goal|original goal|built to|why it was built|the original' "$INTENT" || MISSING+=("original-goal")
  grep -Eqi 'used_for|used for|users:|who uses|the jobs' "$INTENT" || MISSING+=("used-for/users")
  grep -Eqi '\b(confirmed|inferred|unknown)\b' "$INTENT" || MISSING+=("confidence-labels(confirmed/inferred/unknown)")
  if ! grep -Eqi 'evidence|evidence_refs' "$INTENT" \
     && ! grep -Eq '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:[0-9]+' "$INTENT"; then
    MISSING+=("evidence(file:line or evidence_refs)")
  fi

  if [ "${#MISSING[@]}" -gt 0 ]; then
    for m in "${MISSING[@]}"; do add_finding "stub-intent" "INTENT '$INTENT_REL' missing: $m"; done
    write_report "FAIL" "applicable" "INTENT '$INTENT_REL' is a stub — missing: $(printf '%s; ' "${MISSING[@]}")"
    echo "WALTEUR intent-reconstruction-gate: FAIL — INTENT '$INTENT_REL' is a stub. Missing: ${MISSING[*]}" >&2
    exit 2
  fi

  write_report "PASS" "applicable" "INTENT present + non-stub: $INTENT_REL ($NONEMPTY non-empty lines, labeled + evidenced)"
  echo "WALTEUR intent-reconstruction-gate: PASS — brownfield intent recovered in '$INTENT_REL'." >&2
  exit 0
}

# ── embedded self-test (good + poisoned twins; hermetic temp project) ────────────
selftest() {
  local fails=0 total=0 tmp rc
  local SELF; SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  run_one() { # $1=label $2=want-rc $3=setup-fn
    total=$((total+1))
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/intent-gate-selftest.XXXXXX")" || { echo "  FAIL — $1 (mktemp)"; fails=$((fails+1)); return; }
    mkdir -p "$tmp/walteur-kit" "$tmp/src"
    "$3" "$tmp"
    WALTEUR_ROOT="$tmp" WALTEUR_INTENT=on bash "$SELF" "$tmp/src" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq "$2" ]; then echo "  ok   — $1 (rc=$rc)"; else echo "  FAIL — $1 (rc=$rc, want $2)"; fails=$((fails+1)); fi
    rm -rf "$tmp"
  }

  brown() { printf '{"is_brownfield":true}\n'  > "$1/walteur-kit/preflight-signals.json"; }
  green() { printf '{"is_brownfield":false}\n' > "$1/walteur-kit/preflight-signals.json"; }

  good_setup() { # brownfield + complete INTENT -> PASS
    brown "$1"
    cat > "$1/walteur-kit/INTENT.md" <<'EOF'
---
intent_version: 1
product: legacy-app
reconstructed: true
what_it_is: A Flask API serving invoice PDFs.
original_goal: Built to let finance self-serve invoice exports.
used_for: Finance staff pull monthly invoice bundles.
users:
  - finance staff exporting invoices
claims:
  - { statement: "exposes /invoices", label: confirmed, evidence: "app/routes.py:42" }
  - { statement: "intended for internal use", label: inferred }
evidence_refs:
  - README.md:1
---
# INTENT — legacy-app (reconstructed)
## 1. What it is
A Flask API. Evidence: app/main.py:10
## 2. The original goal
Built to let finance self-serve. Confirmed via README.md:3
## 3. What it is used for
Finance staff pull invoice bundles; the jobs it does are exports.
## 4. Reconstruction ledger
Claims labeled confirmed / inferred / unknown, grounded at app/routes.py:42.
EOF
  }

  shortcircuit_setup() { # brownfield + non-stub PRD, no INTENT -> PASS (short-circuit)
    brown "$1"
    cat > "$1/walteur-kit/PRD.md" <<'EOF'
# PRD — legacy-app
## 1. Summary
A tool to export invoices.
## 2. Background — the problem
Finance could not self-serve.
## 3. Objective
North-star: export adoption, target 50%.
## 4. Target user
When closing the month, finance wants exports, so they can reconcile.
## 6. Prioritized scope
v1 = the exporter. NOT-doing: no GTM.
## 7. Assumptions
Adoption is the constraint.
EOF
  }

  stub_setup() { brown "$1"; printf '# INTENT\nTODO\n' > "$1/walteur-kit/INTENT.md"; }

  noevidence_setup() { # has what/goal/used/labels but NO evidence and NO file:line -> FAIL
    brown "$1"
    cat > "$1/walteur-kit/INTENT.md" <<'EOF'
---
intent_version: 1
product: app
what_it_is: a tool
original_goal: built to do the thing
used_for: people use it for the thing
users:
  - some users
---
# INTENT — app
## What it is
It is a tool. The original goal was the thing. It is used for the thing.
Claims are labeled confirmed and inferred but cite no source.
Padding line one to clear the twelve-line floor.
Padding line two to clear the twelve-line floor.
EOF
  }

  nolabels_setup() { # has evidence file:line but NO confidence labels -> FAIL
    brown "$1"
    cat > "$1/walteur-kit/INTENT.md" <<'EOF'
---
intent_version: 1
product: app
what_it_is: a tool
original_goal: built to do the thing
used_for: people use it for the thing
evidence_refs:
  - app/main.py:10
---
# INTENT — app
## What it is
It is a tool, see app/main.py:10. The original goal is at README.md:2.
It is used for the thing by who uses it.
Padding line one to clear the twelve-line floor of the gate.
Padding line two to clear the twelve-line floor of the gate.
Padding line three to clear the twelve-line floor of the gate.
EOF
  }

  greenfield_setup() { green "$1"; printf '<div>app</div>\n' > "$1/src/App.tsx"; }   # no INTENT, no brownfield -> NA
  missing_setup()    { brown "$1"; }                                                  # brownfield, no INTENT, no PRD -> FAIL

  echo "intent-reconstruction-gate selftest:"
  run_one "good twin: brownfield + complete INTENT -> PASS"        0 good_setup
  run_one "good twin: brownfield + non-stub PRD (short-circuit) -> PASS" 0 shortcircuit_setup
  run_one "poisoned: stub INTENT -> FAIL"                          2 stub_setup
  run_one "poisoned: INTENT with no evidence -> FAIL"             2 noevidence_setup
  run_one "poisoned: INTENT with no confidence labels -> FAIL"    2 nolabels_setup
  run_one "greenfield (no signal, no INTENT) -> NOT_APPLICABLE"    0 greenfield_setup
  run_one "brownfield, no INTENT, no PRD -> FAIL"                  2 missing_setup

  # bypass + kill-switch
  total=$((total+1)); tmp="$(mktemp -d "${TMPDIR:-/tmp}/intentreco.XXXXXX")"; mkdir -p "$tmp/walteur-kit"; brown "$tmp"
  WALTEUR_ROOT="$tmp" WALTEUR_INTENT=off bash "$SELF" "$tmp" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then echo "  ok   — bypass WALTEUR_INTENT=off -> exit 0 (rc=$rc)"; else echo "  FAIL — bypass (rc=$rc, want 0)"; fails=$((fails+1)); fi; rm -rf "$tmp"
  total=$((total+1)); tmp="$(mktemp -d "${TMPDIR:-/tmp}/intentreco.XXXXXX")"; mkdir -p "$tmp/walteur-kit"; brown "$tmp"; touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" WALTEUR_INTENT=on bash "$SELF" "$tmp" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then echo "  ok   — PAUSED -> exit 2 (rc=$rc)"; else echo "  FAIL — PAUSED (rc=$rc, want 2)"; fails=$((fails+1)); fi; rm -rf "$tmp"

  echo "intent-reconstruction-gate selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi
run_gate "${1:-}"
