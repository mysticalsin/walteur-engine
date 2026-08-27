#!/usr/bin/env bash
# WALTEUR review-egress-redaction-gate — HARD egress gate (v10.1).
#
# PURPOSE: when project content is handed to an external / "council" / reviewer MODEL (a second model that
#   grades the build — LOOPER's "Council", WALTEUR's own cross-model review/audit), that payload must be
#   (a) PROVEN free of raw secrets, and (b) sent WITH RECORDED CONSENT. This is the REVIEWER-MODEL EGRESS
#   surface — distinct from every existing gate:
#     · confidentiality-gate.sh  = named-client/NDA codenames in PUBLISHED artifacts (release-notes/press)
#     · agent-security-gate.sh   = a secret interpolated into a prompt LITERAL in the BUILD'S OWN source
#     · ai-tool-governance-gate  = a PAPER manifest asserting "no confidential data to a general model" (no scan)
#     · privacy-data-gate.sh     = at-rest PII lifecycle
#   None of them scans what gets SENT TO A REVIEWER MODEL, and none requires consent. This gate does both.
#
# THE TEETH (honesty law): the gate does NOT trust the manifest's "redaction:PASS" claim — it ACTIVELY
#   re-scans each declared payload file for raw secrets (private-key blocks, AKIA/sk-/ghp_/xox/AIza tokens,
#   JWTs, user:pass@ connection strings, and KEY=<secret-value> assignments). A claimed-clean payload that
#   still contains a live secret FAILS. Redaction placeholders (<REDACTED>, xxxx, your-key, ***) are excused.
#
# ARMS ONLY when a reviewer-model egress surface is DECLARED by the build (detect-or-SKIP — never stalls a
#   build with no external review):
#     (a) walteur-kit/council-egress.json present, OR
#     (b) walteur-kit/delivery-orchestration.json has .egress.external_model == true.
#   Armed by (b) with no council-egress.json => FAIL (egress declared, redaction/consent manifest absent).
#   Neither signal => NOT_APPLICABLE exit 0.
#
# CONTRACT (armed): per handoff in council-egress.json[].handoffs, FAIL exit 2 if ANY of:
#   · payload_ref missing / file absent / empty
#   · consent.granted != true
#   · the payload file contains a raw secret (active perl scan — the teeth)
#   · redaction block absent
#   PAUSED => exit 2 · bypass WALTEUR_EGRESS=off => loud SKIP exit 0.
# Zero-dep: bash + jq + perl + find. Report: walteur-kit/review-egress-redaction-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "review-egress-redaction-gate - HARD egress gate (v10.1)."
  printf '%s\n' "usage: bash review-egress-redaction-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/review-egress-redaction-report.json - fix recipes: walteur-kit/REMEDIATION.md (## review-egress-redaction-gate)"
  printf '%s\n' "bypass: WALTEUR_EGRESS=off (recorded, not free)"
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
MANIFEST="$KIT/council-egress.json"
ORCH="$KIT/delivery-orchestration.json"
REPORT="$KIT/review-egress-redaction-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"review-egress-redaction", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","reason":"%s"}\n' "$v" "$r" > "$REPORT" 2>/dev/null || true; }

# ── the teeth: active raw-secret scan of an actual payload file ─────────────────
# prints a non-empty marker line if a raw (unredacted) secret is present; silent if clean.
scan_payload_secret() { # $1=file
  have perl || return 0
  perl -0777 -ne '
    my $t = $_;
    my @pat = (
      qr/-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----/,
      qr/\bAKIA[0-9A-Z]{16}\b/,
      qr/\bsk-(?:ant-)?[A-Za-z0-9_\-]{20,}/,
      qr/\bgh[posru]_[A-Za-z0-9]{30,}/,
      qr/\bxox[baprs]-[A-Za-z0-9-]{10,}/,
      qr/\bAIza[0-9A-Za-z_\-]{35}\b/,
      qr/\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{6,}/,
      qr{\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqps?):\/\/[^:\@\/\s]+:[^\@\/\s]{3,}\@}i,
    );
    for my $p (@pat){ if ($t =~ $p){ print "secret-token\n"; exit 0 } }
    # KEY = <secret-looking value>, excluding obvious placeholders/redactions
    while ($t =~ /(?:API[_-]?KEY|SECRET[_-]?KEY|CLIENT[_-]?SECRET|ACCESS[_-]?TOKEN|AUTH[_-]?TOKEN|PRIVATE[_-]?KEY|[_-]SECRET|PASSWORD)\b\s*[:=]\s*[\x22\x27]?([A-Za-z0-9+\/_\-\.]{12,})[\x22\x27]?/gi) {
      my $v = $1;
      next if $v =~ /^(?:x{3,}|your[_-]|example|changeme|dummy|placeholder|redacted|sample|null|none|true|false|undefined)/i;
      next if $v =~ /[<>{}\$\*]/;          # template / *** redaction syntax
      next if $v =~ /^[A-Z][a-z]+(?:[A-Z][a-z]+){1,}$/;  # CamelCase identifier, not a secret value
      print "secret-assignment\n"; exit 0;
    }
    exit 0;
  ' "$1" 2>/dev/null
}

applies() {
  [ -f "$MANIFEST" ] && return 0
  if [ -f "$ORCH" ] && have jq; then
    [ "$(jq -r '.egress.external_model // false' "$ORCH" 2>/dev/null)" = "true" ] && return 0
  fi
  return 1
}

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused; echo "review-egress-redaction-gate: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_EGRESS:-}" = "off" ] && { write_report SKIP "bypassed via WALTEUR_EGRESS=off"; echo "review-egress-redaction-gate: SKIP — WALTEUR_EGRESS=off (loud skip)" >&2; exit 0; }
  if ! applies; then write_report NOT_APPLICABLE "no reviewer-model egress declared (no council-egress.json, no delivery-orchestration egress.external_model)"; echo "review-egress-redaction-gate: NOT_APPLICABLE" >&2; exit 0; fi
  if ! have jq; then write_report SKIP "jq not installed"; echo "review-egress-redaction-gate: SKIP (no jq)" >&2; exit 0; fi

  # armed by orchestration egress flag but no manifest => fail-closed
  if [ ! -f "$MANIFEST" ]; then
    add_finding manifest "delivery-orchestration declares egress.external_model:true but walteur-kit/council-egress.json is absent — redaction/consent unproven"
    write_report FAIL "egress declared, council-egress.json absent"
    echo "review-egress-redaction-gate: FAIL (egress declared, manifest absent) -> exit 2" >&2
    exit 2
  fi

  if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
    add_finding manifest "council-egress.json is not valid JSON"
    write_report FAIL "council-egress.json invalid JSON"
    echo "review-egress-redaction-gate: FAIL (invalid manifest) -> exit 2" >&2
    exit 2
  fi

  local n; n="$(jq '.handoffs | length' "$MANIFEST" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -eq 0 ]; then
    add_finding handoffs "council-egress.json has no handoffs[] — an armed egress surface must declare at least one handoff"
    write_report FAIL "no handoffs declared"
    echo "review-egress-redaction-gate: FAIL (no handoffs) -> exit 2" >&2
    exit 2
  fi

  local i=0
  while [ "$i" -lt "$n" ]; do
    local to pref consent has_redact full
    to="$(jq -r ".handoffs[$i].to // \"(unnamed)\"" "$MANIFEST" 2>/dev/null)"
    pref="$(jq -r ".handoffs[$i].payload_ref // \"\"" "$MANIFEST" 2>/dev/null)"
    consent="$(jq -r ".handoffs[$i].consent.granted // false" "$MANIFEST" 2>/dev/null)"
    has_redact="$(jq -e ".handoffs[$i].redaction" "$MANIFEST" >/dev/null 2>&1 && echo 1 || echo 0)"

    if [ "$has_redact" != "1" ]; then add_finding "redaction[$to]" "handoff to '$to' has no redaction block"; fi
    if [ "$consent" != "true" ]; then add_finding "consent[$to]" "handoff to '$to' has consent.granted != true — egress without recorded consent"; fi

    if [ -z "$pref" ]; then
      add_finding "payload[$to]" "handoff to '$to' has no payload_ref — cannot prove the egressed content was clean"
    else
      full="$ROOT/$pref"; [ -f "$pref" ] && full="$pref"
      if [ ! -f "$full" ]; then
        add_finding "payload[$to]" "payload_ref '$pref' does not exist"
      elif [ ! -s "$full" ]; then
        add_finding "payload[$to]" "payload_ref '$pref' is empty"
      else
        local hit; hit="$(scan_payload_secret "$full")"
        if [ -n "$hit" ]; then
          add_finding "secret[$to]" "payload '$pref' contains a RAW secret ($hit) — redact before egress to reviewer model '$to'"
        fi
      fi
    fi
    i=$((i+1))
  done

  if [ "$failures" -gt 0 ]; then
    write_report FAIL "$failures egress-redaction/consent violation(s)"
    echo "review-egress-redaction-gate: FAIL ($failures) -> exit 2" >&2
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null | head -15 >&2 || true
    exit 2
  fi
  write_report PASS "$n handoff(s): payloads secret-clean, consent recorded"
  echo "review-egress-redaction-gate: PASS ($n handoff(s) clean + consented)" >&2
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq || ! have perl; then echo "review-egress-redaction selftest SKIP — need jq+perl."; return 0; fi
  echo "review-egress-redaction-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  seed() { mkdir -p "$1/walteur-kit/egress"; }
  # writes a valid manifest pointing at payload file $2 (relative to root), consent $3 (true/false)
  manifest() { # $1=root $2=payload_rel $3=consent
    jq -n --arg p "$2" --argjson c "$3" '{handoffs:[{to:"council-reviewer", model_family:"anthropic-claude", payload_ref:$p, redaction:{verdict:"PASS"}, consent:{granted:$c, by:"Tony", ts:"2026-06-28T00:00:00Z"}}]}' > "$1/walteur-kit/council-egress.json"
  }

  # 1. no egress signal -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/reviewegre.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf 'const x=1;\n' > "$t/src/a.ts"; ck "no egress signal -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. GOOD: clean payload + consent -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/reviewegre.XXXXXX")"; seed "$t"; printf '# Review payload\nThe handler reads from the orders table and returns JSON.\nConfig via API_KEY=<REDACTED>.\n' > "$t/walteur-kit/egress/p1.md"; manifest "$t" "walteur-kit/egress/p1.md" true; ck "clean payload + consent -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. G1 POISONED: private key in payload -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/reviewegre.XXXXXX")"; seed "$t"; printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----\n' > "$t/walteur-kit/egress/p1.md"; manifest "$t" "walteur-kit/egress/p1.md" true; ck "G1 private key in payload -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. G2 POISONED: AWS AKIA key -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/reviewegre.XXXXXX")"; seed "$t"; printf 'aws creds: AKIAIOSFODNN7EXAMPLE in the config dump\n' > "$t/walteur-kit/egress/p1.md"; manifest "$t" "walteur-kit/egress/p1.md" true; ck "G2 AKIA key -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. G3 POISONED: consent not granted -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/reviewegre.XXXXXX")"; seed "$t"; printf 'clean content\n' > "$t/walteur-kit/egress/p1.md"; manifest "$t" "walteur-kit/egress/p1.md" false; ck "G3 consent=false -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. G4 POISONED: payload_ref missing on disk -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/reviewegre.XXXXXX")"; seed "$t"; manifest "$t" "walteur-kit/egress/nope.md" true; ck "G4 payload_ref absent -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. FP guard: payload names API_KEY as a word + redacted value -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/reviewegre.XXXXXX")"; seed "$t"; printf 'We read the API_KEY env var. In prod set API_KEY=your-key-here. Password rotation policy applies.\n' > "$t/walteur-kit/egress/p1.md"; manifest "$t" "walteur-kit/egress/p1.md" true; ck "FP redacted/placeholder -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 8. G5 POISONED: connection string with inline password -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/reviewegre.XXXXXX")"; seed "$t"; printf 'DB at postgres://admin:s3cr3tP4ss@db.internal:5432/app\n' > "$t/walteur-kit/egress/p1.md"; manifest "$t" "walteur-kit/egress/p1.md" true; ck "G5 conn-string user:pass@ -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. G6 POISONED: armed by orchestration egress flag, no manifest -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/reviewegre.XXXXXX")"; mkdir -p "$t/walteur-kit"; jq -n '{egress:{external_model:true}}' > "$t/walteur-kit/delivery-orchestration.json"; ck "G6 orch egress flag, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10. G7 POISONED: generic sk- token -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/reviewegre.XXXXXX")"; seed "$t"; printf 'leaked: sk-ant-api03-AbCdEf012345GhIjKlMnOpQrStUvWx in the trace\n' > "$t/walteur-kit/egress/p1.md"; manifest "$t" "walteur-kit/egress/p1.md" true; ck "G7 sk- token -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 11. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/reviewegre.XXXXXX")"; seed "$t"; printf -- '-----BEGIN RSA PRIVATE KEY-----\nx\n-----END RSA PRIVATE KEY-----\n' > "$t/walteur-kit/egress/p1.md"; manifest "$t" "walteur-kit/egress/p1.md" true; WALTEUR_ROOT="$t" WALTEUR_EGRESS=off bash "$SELF" >/dev/null 2>&1; ck "bypass WALTEUR_EGRESS=off -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/reviewegre.XXXXXX")"; seed "$t"; manifest "$t" "walteur-kit/egress/p1.md" true; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "review-egress-redaction-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
