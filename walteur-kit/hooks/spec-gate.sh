#!/usr/bin/env bash
# WALTEUR spec-gate — HARD gate (enterprise backlog: spec-before-plan traceability). A PLAN.md that is not
# anchored to a reviewed SPEC drifts: requirements are invented in the plan, acceptance criteria are vague,
# and a standing security/RLS/tenant principle ("tenants never read each other's rows") is never written down
# so nothing enforces it. This gate requires walteur-kit/spec.md to enumerate >=3 requirements — each with an
# FR-### id AND an EARS-shaped acceptance line (WHEN/THEN/SHALL/WHILE) — plus walteur-kit/constitution.md with
# >=1 standing security/RLS/tenant principle. It FAILS on any "[NEEDS CLARIFICATION]" / "TBD" marker in the
# spec, and FAILS (traceability) on any FR-### declared in the spec that is NOT referenced anywhere in PLAN.md.
#
# Applies when PLAN.md exists at ROOT.
# CONTRACT: spec/constitution missing, weak, marker-poisoned, or an FR-### untraced into PLAN.md => violation.
#   Fail-closed (exit 2) at risk_tier high|regulated · ADVISORY (exit 0, report written) below that floor ·
#   no PLAN.md => NOT_APPLICABLE (exit 0) · PAUSED => exit 2 · bypass WALTEUR_SPEC=off.
# Report: walteur-kit/spec-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "spec-gate - HARD gate (enterprise backlog: spec-before-plan traceability). A PLAN.md that is not"
  printf '%s\n' "usage: bash spec-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/spec-report.json - fix recipes: walteur-kit/REMEDIATION.md (## spec-gate)"
  printf '%s\n' "bypass: WALTEUR_SPEC=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
PLAN="$ROOT/PLAN.md"
SPEC="${WALTEUR_SPEC_FILE:-$KIT/spec.md}"
CONSTITUTION="${WALTEUR_CONSTITUTION_FILE:-$KIT/constitution.md}"
CONTRACT="$KIT/build-contract.json"
REPORT="$KIT/spec-report.json"
MIN_REQS="${WALTEUR_SPEC_MIN_REQS:-3}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"spec", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"spec","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

# risk — fail-CLOSED on an unparseable/absent contract: an empty/garbage risk_tier coerces to "high" so a
# broken contract cannot silently demote this gate to advisory. Only the four known low/medium tiers relax it.
risk() {
  local r=""
  if [ -f "$CONTRACT" ] && have jq; then r="$(jq -r '.risk_tier // empty' "$CONTRACT" 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '[:space:]')"; fi
  case "$r" in low|medium|high|regulated) printf '%s' "$r";; *) printf 'high';; esac
}

applies() { [ -f "$PLAN" ]; }

# count_reqs — number of distinct FR-### ids declared in the spec (multiline-safe via perl; grep -P is
# locale-broken on Windows Git Bash). Captured to a var first, never piped under pipefail.
count_reqs() { # $1=file
  local ids
  ids="$(perl -0777 -ne 'while (/\bFR-\d{3,}\b/g) { print "$&\n"; }' "$1" 2>/dev/null | sort -u)"
  printf '%s' "$ids" | grep -c . 2>/dev/null || echo 0
}
# ears_lines — count of EARS-shaped acceptance lines: a line carrying WHEN or WHILE together with THEN or
# SHALL. This is the acceptance-clause shape ("WHEN <trigger> THEN system SHALL <response>").
ears_lines() { # $1=file
  perl -0777 -ne 'my $n=0; for my $l (split /\n/) { $n++ if ($l =~ /\bWHEN\b/ || $l =~ /\bWHILE\b/) && ($l =~ /\bTHEN\b/ || $l =~ /\bSHALL\b/); } print $n;' "$1" 2>/dev/null || echo 0
}
# fr_ids — emit each distinct FR-### declared in the spec, one per line.
fr_ids() { # $1=file
  perl -0777 -ne 'while (/\bFR-\d{3,}\b/g) { print "$&\n"; }' "$1" 2>/dev/null | sort -u
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  echo "spec-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }

  # fixtures ----------------------------------------------------------------
  hi() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"high"}\n' > "$1/walteur-kit/build-contract.json"; }
  lo() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"low"}\n' > "$1/walteur-kit/build-contract.json"; }
  goodplan() {  # PLAN.md referencing FR-001/002/003 (full traceability)
    cat > "$1/PLAN.md" <<'EOF'
# Plan
## Tasks
- T1 implements FR-001 — parse input
- T2 implements FR-002 — persist row (tenant-scoped)
- T3 implements FR-003 — emit audit event
EOF
  }
  goodspec() {  # 3 reqs, each FR-### + EARS acceptance line, no markers
    mkdir -p "$1/walteur-kit"
    cat > "$1/walteur-kit/spec.md" <<'EOF'
# Spec
## FR-001 Parse input
Acceptance: WHEN input is empty THEN the system SHALL exit 0.
## FR-002 Persist row
Acceptance: WHILE a tenant session is active THEN the system SHALL write only that tenant's rows.
## FR-003 Audit event
Acceptance: WHEN a row is written THEN the system SHALL emit an audit event.
EOF
  }
  goodconst() {  # >=1 standing security/RLS/tenant principle
    mkdir -p "$1/walteur-kit"
    cat > "$1/walteur-kit/constitution.md" <<'EOF'
# Constitution
- Security: every table enforces row-level-security; tenants SHALL never read another tenant's rows.
EOF
  }
  goodkit() { goodplan "$1"; goodspec "$1"; goodconst "$1"; }

  # 1. no PLAN.md -> NOT_APPLICABLE (exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no PLAN.md -> NOT_APPLICABLE" 0 "$(run "$t")"; rm -rf "$t"

  # 2. FALSE-POSITIVE GUARD: clean spec+constitution+plan at HIGH risk MUST PASS (exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodkit "$t"; ck "clean kit @high -> PASS (false-positive guard)" 0 "$(run "$t")"; rm -rf "$t"

  # 3. FALSE-POSITIVE GUARD: same clean kit at LOW risk MUST PASS (exit 0)
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; lo "$t"; goodkit "$t"; ck "clean kit @low -> PASS (false-positive guard)" 0 "$(run "$t")"; rm -rf "$t"

  # 4. spec.md absent @high -> FAIL (exit 2)
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodplan "$t"; goodconst "$t"; ck "spec absent @high -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 5. constitution.md absent @high -> FAIL (exit 2)
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodplan "$t"; goodspec "$t"; ck "constitution absent @high -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 6. only 2 requirements (< MIN_REQS) @high -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodplan "$t"; goodconst "$t"; mkdir -p "$t/walteur-kit"
  cat > "$t/walteur-kit/spec.md" <<'EOF'
# Spec
## FR-001 Parse input
Acceptance: WHEN input is empty THEN the system SHALL exit 0.
## FR-002 Persist row
Acceptance: WHILE a tenant session is active THEN the system SHALL write only that tenant's rows.
EOF
  ck "only 2 reqs @high -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 7. a requirement missing its EARS acceptance line @high -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodplan "$t"; goodconst "$t"; mkdir -p "$t/walteur-kit"
  cat > "$t/walteur-kit/spec.md" <<'EOF'
# Spec
## FR-001 Parse input
Acceptance: WHEN input is empty THEN the system SHALL exit 0.
## FR-002 Persist row
Acceptance: WHILE a tenant session is active THEN the system SHALL write only that tenant's rows.
## FR-003 Audit event
Acceptance: the system writes an audit event somewhere eventually.
EOF
  ck "missing EARS line @high -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 8. POISON: [NEEDS CLARIFICATION] marker in spec @high -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodkit "$t"
  printf '\n## FR-004 Unknown\nAcceptance: WHEN x THEN system SHALL [NEEDS CLARIFICATION].\n' >> "$t/walteur-kit/spec.md"
  goodplan "$t"; printf -- '- T4 implements FR-004\n' >> "$t/PLAN.md"
  ck "[NEEDS CLARIFICATION] marker @high -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 9. POISON: TBD marker in spec @high -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodkit "$t"
  perl -0777 -i -pe 's/exit 0\./exit TBD./' "$t/walteur-kit/spec.md"
  ck "TBD marker @high -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 10. TRACEABILITY: FR-003 declared in spec but NOT referenced in PLAN.md @high -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodspec "$t"; goodconst "$t"
  cat > "$t/PLAN.md" <<'EOF'
# Plan
## Tasks
- T1 implements FR-001
- T2 implements FR-002
EOF
  ck "untraced FR-### @high -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 11. constitution present but NO security/RLS/tenant principle @high -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodplan "$t"; goodspec "$t"; mkdir -p "$t/walteur-kit"
  printf '# Constitution\n- Prefer small functions and clear names.\n' > "$t/walteur-kit/constitution.md"
  ck "constitution w/o security principle @high -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 12. ADVISORY: same poisoned spec at LOW risk -> exit 0 (advisory, never blocks)
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; lo "$t"; goodkit "$t"
  perl -0777 -i -pe 's/exit 0\./exit TBD./' "$t/walteur-kit/spec.md"
  ck "TBD marker @low -> ADVISORY exit 0" 0 "$(run "$t")"; rm -rf "$t"

  # 13. unparseable risk_tier -> fail-CLOSED (treated as high): poisoned spec -> FAIL exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{not json' > "$t/walteur-kit/build-contract.json"; goodkit "$t"
  perl -0777 -i -pe 's/exit 0\./exit TBD./' "$t/walteur-kit/spec.md"
  ck "garbage risk_tier -> fail-closed FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 14. bypass WALTEUR_SPEC=off -> exit 0 even with a poisoned kit @high
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodplan "$t"; goodconst "$t"; printf '# Spec\nTBD\n' > "$t/walteur-kit/spec.md"
  WALTEUR_ROOT="$t" WALTEUR_SPEC=off bash "$0" >/dev/null 2>&1; ck "bypass WALTEUR_SPEC=off -> exit 0" 0 "$?"; rm -rf "$t"

  # 15. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodkit "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # G16. REGRESSION (trace id-collision, FR-003 vs FR-0031): FR-003 is genuinely untraced; PLAN.md only
  # contains a longer unrelated id FR-0031 in a backlog note. A bare-substring matcher passes it (false-neg);
  # the anchored matcher must FAIL @high -> exit 2.
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodspec "$t"; goodconst "$t"
  cat > "$t/PLAN.md" <<'EOF'
# Plan
## Tasks
- T1 implements FR-001 — parse input
- T2 implements FR-002 — persist row (tenant-scoped)
## Backlog notes
- Ticket numbering reserved up to FR-0031 for a future epic; do not reuse.
EOF
  ck "G16 trace id-collision FR-0031 masks untraced FR-003 -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G17. REGRESSION (trace id-collision, FR-002 vs FR-0021): FR-002 untraced; PLAN.md only contains FR-0021
  # in a changelog line. Anchored matcher must FAIL @high -> exit 2.
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodspec "$t"; goodconst "$t"
  cat > "$t/PLAN.md" <<'EOF'
# Plan
## Tasks
- T1 implements FR-001 — parse input
- T3 implements FR-003 — emit audit event

## Changelog (historical, not a task list)
- 2025-09: closed legacy ticket FR-0021 (renumbered, do not implement)
EOF
  ck "G17 trace id-collision FR-0021 masks untraced FR-002 -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G18. REGRESSION (negated principle): constitution name-drops security keywords but DISCLAIMS isolation
  # ("tenant isolation is NOT enforced ... any authenticated request may read or write any tenant's rows ...
  # rely on the client"). Keyword-OR match passes it (false-neg); the negation reject must FAIL @high -> exit 2.
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodplan "$t"; goodspec "$t"; mkdir -p "$t/walteur-kit"
  cat > "$t/walteur-kit/constitution.md" <<'EOF'
# Constitution
- Security: tenant isolation is NOT enforced at the database layer; any authenticated
  request may read or write any tenant's rows. We rely on the client to send the right tenant id.
EOF
  ck "G18 negated/disclaimed tenant-isolation principle -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G19. FALSE-POSITIVE GUARD for the new checks: a clean PLAN with the REAL ids (no longer-id collision) and a
  # POSITIVE isolation constitution must still PASS @high -> exit 0. Guards G16/G17 anchoring (real FR-003
  # traces) and G18 negation reject (the positive form uses "never read" but is not a disclaimer).
  t="$(mktemp -d "${TMPDIR:-/tmp}/specgate.XXXXXX")"; hi "$t"; goodkit "$t"; ck "G19 clean anchored-trace + positive principle -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "spec-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_SPEC:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_SPEC=off"; echo "spec-gate: bypassed." >&2; exit 0; }

if ! applies; then write_report "NOT_APPLICABLE" "no PLAN.md at ROOT"; echo "spec-gate: NOT_APPLICABLE (no PLAN.md)"; exit 0; fi
if ! have perl; then write_report "SKIP" "perl unavailable (needed for multiline spec parsing)"; echo "spec-gate: SKIP (no perl)." >&2; exit 0; fi

RISK="$(risk)"

# --- spec.md presence + shape ------------------------------------------------
if [ ! -s "$SPEC" ]; then
  add_finding "spec" "PLAN.md exists but walteur-kit/spec.md is absent — write the spec ($MIN_REQS+ FR-### requirements, each with an EARS WHEN/THEN/SHALL/WHILE acceptance line) before planning"
else
  reqs="$(count_reqs "$SPEC")"; reqs="$(printf '%s' "$reqs" | grep -oE '^[0-9]+' | head -1)"; reqs="${reqs:-0}"
  ears="$(ears_lines "$SPEC")"; ears="$(printf '%s' "$ears" | grep -oE '^[0-9]+' | head -1)"; ears="${ears:-0}"
  [ "$reqs" -ge "$MIN_REQS" ] 2>/dev/null || add_finding "spec.requirements" "spec.md declares $reqs FR-### requirement(s) — at least $MIN_REQS required"
  [ "$ears" -ge "$reqs" ] 2>/dev/null || [ "$ears" -ge "$MIN_REQS" ] 2>/dev/null || add_finding "spec.ears" "spec.md has $ears EARS-shaped acceptance line(s) (WHEN/WHILE + THEN/SHALL) but $reqs requirement(s) — every requirement needs an EARS acceptance line"
  # marker poison
  if perl -0777 -ne 'exit(/\[NEEDS CLARIFICATION\]/i ? 0 : 1)' "$SPEC" 2>/dev/null; then
    add_finding "spec.clarification" "spec.md contains a [NEEDS CLARIFICATION] marker — resolve it before the spec can gate the plan"
  fi
  if perl -0777 -ne 'exit(/\bTBD\b/ ? 0 : 1)' "$SPEC" 2>/dev/null; then
    add_finding "spec.tbd" "spec.md contains a TBD marker — fill it in before the spec can gate the plan"
  fi
fi

# --- constitution.md presence + standing security principle ------------------
if [ ! -s "$CONSTITUTION" ]; then
  add_finding "constitution" "walteur-kit/constitution.md is absent — record at least one standing security/RLS/tenant principle that every build must uphold"
else
  if ! perl -0777 -ne 'exit((/\b(security|rls|row[- ]?level[- ]?security|tenant|multi[- ]?tenan|authz|authoriz|isolat|least[- ]?privilege)\b/i) ? 0 : 1)' "$CONSTITUTION" 2>/dev/null; then
    add_finding "constitution.principle" "constitution.md has no standing security/RLS/tenant principle — declare at least one (e.g. 'tenants never read another tenant's rows')"
  # A keyword-present principle that NEGATES isolation is strictly worse than an absent one: it documents and
  # blesses the cross-tenant hole. Reject affirmative disclaimers fail-closed ("isolation is NOT enforced",
  # "RLS disabled", "rely on the client", "any request may read/write any tenant's rows"). The positive good
  # form ("tenants SHALL never read another tenant's rows") deliberately does NOT match these.
  elif perl -0777 -ne 'exit((
        /\bnot\s+enforced\b/i
        || /\bisolation\s+is\s+not\b/i
        || /\bno\s+(?:tenant\s+)?isolation\b/i
        || /\b(?:rls|row[- ]?level[- ]?security|isolation|authz|authoriz|tenant\s+isolation)\s+(?:is\s+)?(?:disabled|off|not\s+enforced|optional|unenforced)\b/i
        || /\bdisable[ds]?\s+(?:rls|row[- ]?level[- ]?security|isolation|authz)\b/i
        || /\brely(?:ing)?\s+on\s+the\s+client\b/i
        || /\btrust(?:ing)?\s+the\s+client\b/i
        || /\bany\s+(?:authenticated\s+)?request\s+may\s+(?:read|write|access)\b/i
        || /\bmay\s+(?:read|write|access)\s+any\s+tenant/i
      ) ? 0 : 1)' "$CONSTITUTION" 2>/dev/null; then
    add_finding "constitution.principle" "constitution.md's security principle NEGATES tenant isolation (e.g. 'isolation is NOT enforced' / 'rely on the client' / 'any request may read any tenant's rows') — a documented cross-tenant hole is worse than an absent principle; assert positive isolation instead"
  fi
fi

# --- traceability: every FR-### in spec.md must appear in PLAN.md -------------
if [ -s "$SPEC" ]; then
  while IFS= read -r fr; do
    [ -n "$fr" ] || continue
    # Anchored trace match: the FR id must appear bounded by non-alphanumerics so a longer id that merely
    # shares the prefix (FR-0031 contains FR-003; FR-0021 contains FR-002) cannot launder an untraced
    # requirement. A bare \Q$id\E substring match is fail-OPEN against such id-collisions.
    if ! perl -0777 -sne 'exit(/(?<![0-9A-Za-z])\Q$id\E(?![0-9A-Za-z])/ ? 0 : 1)' -- -id="$fr" "$PLAN" 2>/dev/null; then
      add_finding "trace.$fr" "$fr is declared in spec.md but never referenced in PLAN.md — trace the requirement into a plan task (or remove it from the spec)"
    fi
  done < <(fr_ids "$SPEC")
fi

# --- verdict -----------------------------------------------------------------
if [ "$failures" -eq 0 ]; then
  write_report "PASS" "spec.md has >=$MIN_REQS EARS-shaped FR-### requirements, constitution.md states a standing security principle, and every FR-### is traced into PLAN.md"
  echo "spec-gate: PASS" >&2
  exit 0
fi

case "$RISK" in
  high|regulated)
    write_report "FAIL" "$failures spec violation(s) at risk_tier=$RISK"
    echo "spec-gate: FAIL - $failures violation(s) @${RISK}" >&2
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
    exit 2 ;;
  *)
    write_report "ADVISORY" "$failures spec violation(s) at risk_tier=$RISK (below the fail-closed floor — advisory only)"
    echo "spec-gate: ADVISORY - $failures violation(s) @${RISK} (non-blocking)" >&2
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
    exit 0 ;;
esac
