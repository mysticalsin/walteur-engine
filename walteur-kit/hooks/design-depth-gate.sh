#!/usr/bin/env bash
# WALTEUR design-depth-gate — HARD gate (build-depth pivot D2). A thin design becomes a thin build. The
# preflight signals already know which §14 layers this build touches (has_auth, has_db, has_payments,
# has_async, has_api_boundary, external_surface/has_ui, is_cloud_iac); this gate checks the PLAN.md /
# design-of-record actually decomposes EACH flagged layer to real depth (a "Layer depth: <x>" section or the
# layer's concrete non-negotiables) BEFORE Build. If the build needs payments but the design never mentions
# idempotency/webhook-signature, the build will not have them.
#
# S033 candidate C4: fail-closed for user-facing builds (is_user_facing/has_ui) as well as high/regulated
# risk_tier — the frontend layer's evidence bar cannot be advisory on the common (medium-risk) path.
#
# S033 candidate C4 (keyword-stuffing resistance): "covered" is no longer a bare regex hit. A magic-word
# match only counts if it sits inside a real prose section — >=200 non-whitespace characters of
# surrounding text (same paragraph/section window) — not a bare list of keywords with no decomposition.
# A file that is just "idempotent webhook signature reconcile ledger" (keyword-only, no sentences) FAILS.
#
# Applies when PLAN.md + preflight-signals.json exist.
# CONTRACT: a flagged layer with no design depth => FAIL exit 2 (high/regulated OR user-facing) · no
# plan/signals => NOT_APPLICABLE · jq absent => SKIP · PAUSED => exit 2 · bypass WALTEUR_DESIGNDEPTH=off.
# Report: walteur-kit/design-depth-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "design-depth-gate - HARD gate (build-depth pivot D2). A thin design becomes a thin build. The"
  printf '%s\n' "usage: bash design-depth-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/design-depth-report.json - fix recipes: walteur-kit/REMEDIATION.md (## design-depth-gate)"
  printf '%s\n' "bypass: WALTEUR_DESIGNDEPTH=off (recorded, not free)"
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
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
PLAN="$ROOT/PLAN.md"
REPORT="$KIT/design-depth-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"design-depth", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"design-depth","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }
sig() { [ -f "$SIGNALS" ] && have jq && jq -e "$1" "$SIGNALS" >/dev/null 2>&1; }

# S033: explicit user-facing signal (distinct from the coarser has_ui/external_surface layer trigger below)
# — escalates the WHOLE gate to fail-closed regardless of risk_tier, same idiom as apple-grade-design-gate.
is_user_facing() {
  { [ -f "$SIGNALS" ] && have jq && jq -e '.is_user_facing==true' "$SIGNALS" >/dev/null 2>&1; } && return 0
  { [ -f "$CONTRACT" ] && have jq && jq -e '(.is_user_facing==true) or ([.interfaces[]? | select(.type=="ui")] | length > 0)' "$CONTRACT" >/dev/null 2>&1; } && return 0
  return 1
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "design-depth selftest SKIP - jq not installed."; return 0; fi
  echo "design-depth-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  setup() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${2:-high}" > "$1/walteur-kit/build-contract.json"; printf '%s\n' "$3" > "$1/walteur-kit/preflight-signals.json"; }
  # real decomposition prose per section — each section is >=200 non-whitespace chars so the S033
  # prose-density floor is met (this is what genuine depth looks like, not a keyword list).
  deepplan() { cat > "$1/PLAN.md" <<'EOF'
# PLAN
### Layer depth: auth
Deny-by-default authorization on every route; explicit allow-list per role. Sessions use short-lived
access tokens with a refresh/revoke flow — revoking a session invalidates all its refresh tokens
immediately. Passwords are hashed with argon2id (memory-hard, tuned for this box). MFA is a required
hook on any privileged-role login, backed by TOTP with recovery codes issued once and stored hashed.
### Layer depth: data
Real forward-only migrations checked into version control, never hand-edited in production. Every
tenant-scoped table carries a row-level security (RLS) policy so a leaked query cannot cross tenants.
Foreign keys and CHECK constraints enforce referential and value integrity at the database layer, not
just in application code. Indexes are added for every foreign key and every filter/sort column used
by a real query path. Monetary values are stored as integer minor units, never floating point.
### Layer depth: payments
Every charge carries a client-generated idempotency key so a network retry cannot double-charge.
Webhook handlers verify the provider's signature before processing and de-duplicate by event id so a
redelivered webhook is a no-op. A reconciliation job compares our ledger against the provider's report
daily and pages on drift. Refunds and partial captures follow the same idempotent, signed-event path.
### Layer depth: api
Every endpoint has a typed request/response contract (zod) that rejects malformed input at the edge.
Errors follow one taxonomy — a stable error code, a human message, and a correlation id — never a bare
500. Creates are idempotent via a client-supplied key. List endpoints are cursor-paginated, never
offset-based, to stay correct under concurrent writes.
EOF
  }
  # frontend section with real prose depth (used by the has_ui PASS case and the user-facing escalation cases)
  frontendplan() { cat > "$1/PLAN.md" <<'EOF'
# PLAN
### Layer depth: frontend
Every screen ships loading, empty, and error states before the happy path is considered done — an
empty state always carries a next action, an error state always carries a specific, recoverable
message, never a bare "something went wrong". Accessibility floor is WCAG 2.1 AA: contrast ratios of
at least 4.5:1 for body text, full keyboard operability with a visible focus ring, and touch targets
of at least 44 points. Forms validate inline as the user types, not only on submit, and announce
errors to assistive tech via aria-live regions.
EOF
  }
  # S033 keyword-stuffing negative control: the exact magic words the auth-layer regex matches on, but
  # with ZERO surrounding prose — a bare list, not a decomposition. Under the pre-S033 grep-only covered()
  # this would have PASSED (grep -Eq hits every one of these words); it must FAIL under the density floor.
  keywordstuffplan() { cat > "$1/PLAN.md" <<'EOF'
# PLAN
### Layer depth: auth
authz deny-by-default session refresh revoke rbac argon2 mfa
EOF
  }

  # 1. no plan/signals -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no plan/signals -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. flagged layers all covered with real prose (high) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" high '{"has_auth":true,"has_db":true,"has_payments":true,"has_api_boundary":true}'; deepplan "$t"; ck "all flagged layers covered -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. has_db flagged but design omits data/RLS (high) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" high '{"has_db":true}'; printf '# PLAN\n### Layer depth: auth\nsessions.\n' > "$t/PLAN.md"; ck "missing data depth (high) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. same omission but low risk, non-user-facing -> PASS (advisory)
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" low '{"has_db":true,"is_user_facing":false}'; printf '# PLAN\nbuild a thing.\n' > "$t/PLAN.md"; ck "missing data depth (low, non-user-facing) -> advisory PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 5. has_payments flagged, no billing depth (high) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" high '{"has_payments":true}'; printf '# PLAN\n### Layer depth: api\nroutes.\n' > "$t/PLAN.md"; ck "missing payments depth (high) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. has_ui flagged + real frontend prose depth present (high) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" high '{"has_ui":true}'; frontendplan "$t"; ck "frontend depth present -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 7. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" high '{"has_db":true}'; printf '# PLAN\nthin.\n' > "$t/PLAN.md"; WALTEUR_ROOT="$t" WALTEUR_DESIGNDEPTH=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" high '{"has_db":true}'; printf '# PLAN\nthin.\n' > "$t/PLAN.md"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ── S033 candidate C4: escalate to fail-closed for user-facing builds (not just high/regulated risk) ──
  # 8. medium-risk + is_user_facing:true + missing frontend depth -> FAIL (was advisory PASS pre-S033)
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" medium '{"has_ui":true,"is_user_facing":true}'; printf '# PLAN\nbuild a UI.\n' > "$t/PLAN.md"; ck "medium-risk + is_user_facing:true + thin frontend -> FAIL (fail-closed flip)" 2 "$(run "$t")"; rm -rf "$t"
  # 9. FP guard: same thin plan, medium-risk, NON-user-facing -> PASS (advisory)
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" medium '{"has_ui":true,"is_user_facing":false}'; printf '# PLAN\nbuild a UI.\n' > "$t/PLAN.md"; ck "medium-risk + non-user-facing + thin frontend -> PASS (advisory, FP guard)" 0 "$(run "$t")"; rm -rf "$t"
  # 10. medium-risk + is_user_facing:true + real frontend depth -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" medium '{"has_ui":true,"is_user_facing":true}'; frontendplan "$t"; ck "medium-risk + is_user_facing:true + real frontend depth -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # ── S033 candidate C4: keyword-stuffing resistance (negative control) ──
  # 11. NEGATIVE CONTROL: bare keyword list (zero decomposition prose) -> FAIL even though every magic
  #     word the regex looks for is literally present — grep -Eq alone would have said PASS.
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" high '{"has_auth":true}'; keywordstuffplan "$t"
  ck "NEGATIVE CONTROL: keyword-only file (no prose) -> FAIL (density floor)" 2 "$(run "$t")"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  jq -e '.findings[] | select(.check=="auth")' "$t/walteur-kit/design-depth-report.json" >/dev/null 2>&1
  ck "report names the 'auth' finding for the keyword-stuffed file" 0 "$?"
  rm -rf "$t"
  # ── Panel #12: PADDED-FILLER negative control. The S033 floor was a LENGTH test, and length is the one
  # thing filler is good at: this fixture reaches 204 non-whitespace characters in the auth section and was
  # reported PASS / "every flagged §14 layer is decomposed to real depth". It names nothing buildable past
  # the keyword list itself, so the mechanism-density floor fails it while the two prose fixtures above pass.
  padfillerplan() { cat > "$1/PLAN.md" <<'EOF'
# PLAN
### Layer depth: auth
authz deny-by-default session refresh revoke rbac argon2 mfa
we will do the thing and then the other thing and then we will do more of the thing
and after that we will do the thing again because the thing needs doing repeatedly
EOF
  }
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" high '{"has_auth":true}'; padfillerplan "$t"
  ck "NEGATIVE CONTROL: 200+ chars of content-free filler -> FAIL (was PASS on the length floor alone)" 2 "$(run "$t")"
  ck "the padded-filler section really does clear the 200-char length floor" 0 \
     "$(perl -0777 -ne 'my @s=split /(?=^\#{1,6}[ \t])/m,$_; for (@s){ next unless /layer depth: *auth/i; s/\s+//g; exit 0 if length>=200 } exit 1' < "$t/PLAN.md"; echo $?)"
  rm -rf "$t"
  # 12. same keywords, but embedded in a real >=200-char decomposition paragraph -> PASS (contrast case)
  t="$(mktemp -d "${TMPDIR:-/tmp}/designdept.XXXXXX")"; setup "$t" high '{"has_auth":true}'; deepplan "$t"; ck "same keywords embedded in real prose -> PASS (contrast case)" 0 "$(run "$t")"; rm -rf "$t"

  echo "design-depth-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_DESIGNDEPTH:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_DESIGNDEPTH=off"; echo "design-depth-gate: bypassed." >&2; exit 0; }

if [ ! -s "$PLAN" ] || [ ! -f "$SIGNALS" ]; then write_report "NOT_APPLICABLE" "no PLAN.md and/or preflight-signals.json"; echo "design-depth-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "design-depth-gate: SKIP." >&2; exit 0; fi

RISK="$(risk)"
UF="no"; is_user_facing && UF="yes"
# concatenated design-of-record text (PLAN.md + any design docs), ORIGINAL case preserved for the prose
# density check (perl does its own case-insensitive matching); a separate lowercased copy is kept for
# nothing else now, but DOC_RAW is what covered() actually scans.
DOC_RAW="$( { cat "$PLAN" 2>/dev/null; for f in "$KIT"/design*.md "$KIT"/DESIGN*.md "$ROOT"/DESIGN.md; do [ -f "$f" ] && cat "$f"; done; } 2>/dev/null )"

# S033 candidate C4 (keyword-stuffing resistance): a magic-word hit only counts as "covered" if the
# SECTION it lives in (split on markdown headers `#`..`######`, or the whole doc when there are no
# headers) carries >=200 non-whitespace characters of prose — not a bare list of magic words with zero
# decomposition. A file that is just "idempotent webhook signature reconcile ledger" (keyword-only, no
# sentences, no header) fails this even though the plain-grep regex would match. Falls back to a plain
# grep hit when perl is unavailable (degrades to the pre-S033 behavior rather than SKIPping the whole
# gate over a missing optional tool).
covered() {
  local pattern="$1"
  if ! have perl; then
    printf '%s' "$DOC_RAW" | tr 'A-Z' 'a-z' | grep -Eq "$pattern"
    return $?
  fi
  # PANEL #12 REFUTATION FIX — the 200-char floor alone is a LENGTH test, not a decomposition test, and
  # length is the one thing filler is good at. Measured: a section containing the bare magic-word list
  # "authz deny-by-default session refresh revoke rbac argon2 mfa" plus two lines of "we will do the thing
  # and then the other thing…" reaches 204 dense characters and was reported as "decomposed to real depth".
  # A section must now ALSO name SPECIFIC MECHANISMS in more than one place (both floors AND-ed — the
  # length floor is kept, not replaced): >=4 DISTINCT mechanism tokens, spread over >=2 sentences of >=6
  # words that each name at least one. A mechanism token is something you could build or test against —
  # an identifier carrying a digit (argon2id, sha256), a measured quantity with a unit or ratio (44 points,
  # 4.5:1, 200ms), a hyphenated compound (deny-by-default, row-level, aria-live), an acronym (RLS, MFA,
  # TOTP), or a quoted/backticked name. "Depth" means naming what you will actually do; filler by
  # construction names nothing, which is exactly what a length test cannot see and this test can.
  WDD_PATTERN="$pattern" perl -0777 -ne '
    my $pat = $ENV{WDD_PATTERN};
    my $MECH = qr/(?:\b[a-z]{2,}[0-9]+[a-z0-9]*\b          # argon2id, sha256, http2
                   |\b[0-9]+(?:\.[0-9]+)?\s*(?:ms|px|pt|rem|kb|mb|gb|%|days?|points?|hours?|minutes?|seconds?)\b
                   |\b[0-9]+(?:\.[0-9]+)?\s*:\s*[0-9]+     # 4.5:1
                   |\b[0-9]{2,}\b                          # a measured quantity
                   |\b[a-zA-Z]{3,}-[a-z]{2,}(?:-[a-z]{2,})*\b   # deny-by-default, row-level, aria-live
                   |\b[A-Z]{2,6}\b                         # RLS, MFA, TOTP, WCAG
                   |"[^"]{3,}"|`[^`]{3,}`
                  )/x;
    # split into sections at markdown headers, keeping the header with the section that follows it
    my @sections = split /(?=^#{1,6}[ \t])/m, $_;
    @sections = ($_) unless @sections;
    for my $s (@sections) {
      next unless $s =~ /$pat/mi;
      (my $dense = $s) =~ s/\s+//g;
      next unless length($dense) >= 200;                   # floor 1: not a one-liner (kept from S033)
      # floor 2: structural decomposition. The sentence split avoids breaking decimals ("WCAG 2.1") and
      # keeps markdown bullets as separate units, so a bullet-per-decision plan is not merged into a blob.
      my (%mech, $sents);
      $sents = 0;
      for my $sent (split m{(?:(?<![0-9])[.;]\s+)|\n(?=\s*(?:[-*+]\s|[0-9]+[.)]\s|\#))}, $s) {
        next if $sent =~ /^\s*\#/;                         # the header line itself is not a decision
        my @w = ($sent =~ /[A-Za-z0-9][A-Za-z0-9\x27-]*/g);
        next if scalar(@w) < 6;
        my @m = ($sent =~ /($MECH)/g);
        next unless @m;
        $sents++;
        for my $x (@m) { $x =~ s/\s+/ /g; $mech{lc $x} = 1 }
      }
      exit 0 if $sents >= 2 && scalar(keys %mech) >= 4;
    }
    exit 1;
  ' <<<"$DOC_RAW" 2>/dev/null
}

# each flagged signal -> the layer evidence its design must show
check_layer() { # $1=label $2=evidence-regex
  covered "$2" || add_finding "$1" "build flagged '$1' but the design-of-record shows no depth for it — add a 'Layer depth: $1' section ($3)"
}
sig '.has_auth==true'                                   && { covered 'layer depth: *auth|authz|deny-by-default|session (lifecycle|refresh|revoke)|rbac|argon2|mfa' || add_finding "auth" "has_auth but no auth depth in design (sessions/authz/MFA/password hashing)"; }
sig '.has_db==true'                                     && { covered 'layer depth: *data|migration|\brls\b|row-level|tenant.*(policy|scope)|index|constraint|schema' || add_finding "data" "has_db but no data/persistence depth (migrations, RLS/row-scope, indexes, constraints)"; }
sig '.has_payments==true'                               && { covered 'layer depth: *payment|billing|idempoten|webhook signature|reconcil|ledger' || add_finding "payments" "has_payments but no billing depth (idempotency, webhook signature, reconciliation)"; }
{ sig '.has_async==true' || sig '.has_queue==true'; }   && { covered 'layer depth: *async|dead-letter|\bdlq\b|\bqueue\b|\bjob\b|idempoten|trace context' || add_finding "async" "has_async but no async/jobs depth (DLQ, idempotency, trace propagation)"; }
sig '.has_api_boundary==true'                           && { covered 'layer depth: *api|endpoint|openapi|error (taxonomy|envelope)|typed (request|response|contract)|pagination' || add_finding "api" "has_api_boundary but no API-contract depth (typed contracts, error taxonomy, versioning, idempotency)"; }
{ sig '.has_ui==true' || sig '.external_surface==true'; } && { covered 'layer depth: *frontend|wcag|accessib|loading.*(empty|error)|empty.*error|optimistic|a11y' || add_finding "frontend" "has_ui/external_surface but no frontend/UX depth (loading/empty/error states, WCAG AA, accessibility)"; }
sig '.is_cloud_iac==true'                               && { covered 'layer depth: *infra|\biac\b|terraform|pulumi|least-privilege|autoscal|health check' || add_finding "infra" "is_cloud_iac but no infra/IaC depth (declarative IaC, least-privilege IAM, autoscaling, health checks)"; }

if [ "$failures" -ne 0 ]; then
  if [ "$RISK" = "high" ] || [ "$RISK" = "regulated" ] || [ "$UF" = "yes" ]; then
    write_report "FAIL" "$failures flagged layer(s) with no design depth (risk=$RISK, user_facing=$UF)"
    echo "design-depth-gate: FAIL - $failures flagged layer(s) thin in the design (risk=$RISK, user_facing=$UF)" >&2
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
    exit 2
  fi
  write_report "ADVISORY" "$failures flagged layer(s) thin in the design (advisory: risk=$RISK, non-user-facing)"
  echo "design-depth-gate: ADVISORY - $failures thin layer(s) (risk=$RISK, non-user-facing, not blocking)" >&2
  exit 0
fi
write_report "PASS" "every flagged §14 layer is decomposed to real depth in the design-of-record"
echo "design-depth-gate: PASS" >&2
exit 0
