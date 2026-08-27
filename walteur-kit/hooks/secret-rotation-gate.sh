#!/usr/bin/env bash
# WALTEUR secret-rotation-gate — prove secrets are KMS/vault-managed, ROTATED, and NEVER committed.
#
# PURPOSE: a deployable that declares secrets/env must prove three things the council cannot eyeball:
#   (1) NO secret VALUES are committed to tracked source/config (active high-signal scan — the teeth),
#   (2) every declared secret is sourced from a managed store (kms/vault/secret-manager/env-injected),
#       NEVER hardcoded, and was rotated within its declared rotation_max_age_days (freshness math),
#   (3) the static secret scan itself ran recently (static_secret_scan.ran_ts fresh).
#   None of the existing gates does this:
#     · review-egress-redaction-gate = secrets in a payload SENT TO A REVIEWER MODEL (egress surface)
#     · agent-security-gate          = a secret interpolated into a PROMPT literal
#     · ai-tool-governance-gate      = a PAPER manifest ("no confidential data to a general model"), no scan
#   This gate scans the BUILD'S OWN tracked source for committed secret literals AND proves rotation hygiene.
#
# APPLICABILITY (detect-or-NOT_APPLICABLE — never stalls a build with no secrets):
#   ARMS only when the build DECLARES secrets/env: walteur-kit/secrets-policy.json present.
#   No secrets-policy.json => NOT_APPLICABLE exit 0.
#
# CONTRACT (armed):
#   PAUSED => exit 2 · bypass WALTEUR_SECRETROT=off => loud SKIP exit 0.
#   perl OR jq ABSENT => loud SKIP exit 0 (cannot_measure — NEVER silent green).
#   FAIL exit 2 if ANY of:
#     (a) HARD — a tracked source/config file contains a committed secret LITERAL (active perl scan).
#     (b) HARD — a declared secret has source NOT in {kms,vault,secret-manager,env-injected}
#               (i.e. hardcoded/inline), OR last_rotated is over rotation_max_age_days old, OR missing.
#     (c) HARD — static_secret_scan.ran_ts is absent / unparseable / stale.
#   PASS only on OBSERVED evidence: the scan EXECUTED (scan_executed marker) and found zero literals,
#   and every secret is managed + fresh.
#
# HONESTY LABELS:
#   HARD  — (a) committed-literal scan (a file either contains a secret token or it does not),
#           (b) source-not-hardcoded + rotation-freshness math (decidable from the policy + a clock),
#           (c) scan ran_ts freshness. All exit-2 on a checkable fact.
#   PROTOCOL — provider_attestation: an LLM/operator-authored claim that the provider rotates keys; the
#           gate checks it EXISTS and is fresh, NOT that it is true. Existence-only, never correctness-blocking.
#
# Report: walteur-kit/secret-rotation-report.json
# Zero-dep + OFFLINE: bash + jq + perl + find. Never hits the network.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "secret-rotation-gate - prove secrets are KMS/vault-managed, ROTATED, and NEVER committed."
  printf '%s\n' "usage: bash secret-rotation-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/secret-rotation-report.json - fix recipes: walteur-kit/REMEDIATION.md (## secret-rotation-gate)"
  printf '%s\n' "bypass: WALTEUR_SECRETROT=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd || echo "$ROOT")"
KIT="$ROOT/walteur-kit"
POLICY="$KIT/secrets-policy.json"
REPORT="$KIT/secret-rotation-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TODAY="$(date -u +%F)"
MAX_SCAN_AGE_DAYS="${WALTEUR_SECRETROT_SCAN_MAX_AGE_DAYS:-7}"
MAX_ATTEST_AGE_DAYS="${WALTEUR_SECRETROT_ATTEST_MAX_AGE_DAYS:-90}"
mkdir -p "$KIT"
# have — tool presence. WALTEUR_SECRETROT_FORCE_NO_<TOOL>=1 simulates absence (selftest-only hook,
# so the perl/jq-absent SKIP path is provable offline without breaking the msys bash DLL loader).
have() {
  case "$1" in
    perl) [ "${WALTEUR_SECRETROT_FORCE_NO_PERL:-}" = "1" ] && return 1 ;;
    jq)   [ "${WALTEUR_SECRETROT_FORCE_NO_JQ:-}" = "1" ] && return 1 ;;
  esac
  command -v "$1" >/dev/null 2>&1
}

findings='[]'; failures=0
add_finding() {
  findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"
  failures=$((failures+1))
}
# write_report — strip CRLF off any captured marker before jq; fail-closed text fallback if jq absent.
write_report() {
  local verdict="$1" reason="$2" extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  if have jq && printf '%s\n' "$extra" | jq -e . >/dev/null 2>&1; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg reason "$reason" --arg policy "${POLICY#"$ROOT"/}" \
       --argjson findings "$findings" --argjson extra "$extra" \
       '{verdict:$v, ts:$ts, gate:"secret-rotation-gate", policy_file:$policy, reason:$reason, findings:$findings} + $extra' \
       > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"secret-rotation-gate","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

# date_to_epoch — GNU (-d) then BSD (-j -f) arms, both UTC. Echoes nothing on a bad date.
# BSD bare-date arm PINS midnight ("$1 00:00:00"): `date -j -f "%Y-%m-%d"` fills unspecified H:M:S with
# the CURRENT time, so two bare-date parses seconds apart race across a second boundary and a same-day
# last_rotated intermittently reads "in the future" (~15% flake). Midnight-pinning makes it deterministic.
date_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%d %H:%M:%S" "$1 00:00:00" +%s 2>/dev/null
}

# ── the teeth: active committed-secret-literal scan of a tracked source/config file ─────────────
# prints a non-empty marker line if a raw committed secret is present; silent if clean.
# Mirrors review-egress-redaction-gate's high-signal perl idiom. Excuses redaction placeholders.
scan_committed_secret() { # $1=file
  have perl || return 0
  perl -0777 -ne '
    my $t = $_;
    my @pat = (
      qr/-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----/,   # any private-key block
      qr/\bAKIA[0-9A-Z]{16}\b/,                                          # AWS access key id
      qr/\bASIA[0-9A-Z]{16}\b/,                                          # AWS temp access key id
      qr/\bsk-(?:ant-)?[A-Za-z0-9_\-]{20,}/,                             # OpenAI/Anthropic-style key
      qr/\bgh[posru]_[A-Za-z0-9]{30,}/,                                  # GitHub token
      qr/\bxox[baprs]-[A-Za-z0-9-]{10,}/,                                # Slack token
      qr/\bAIza[0-9A-Za-z_\-]{35}\b/,                                    # Google API key
      qr/\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{6,}/, # JWT
      qr{\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqps?):\/\/[^:\@\/\s]+:[^\@\/\s]{3,}\@}i, # conn-string user:pass@
    );
    for my $p (@pat){ if ($t =~ $p){ print "secret-token\n"; exit 0 } }
    # NAME containing secret|token|password|apikey|api_key = <high-entropy value>, excluding placeholders.
    while ($t =~ /(\w*(?:secret|token|password|passwd|apikey|api[_-]?key)\w*)\b\s*[:=]\s*[\x22\x27]?([A-Za-z0-9+\/_\-\.]{16,})[\x22\x27]?/gi) {
      my ($k,$v) = ($1,$2);
      next if $v =~ /^(?:x{3,}|your[_-]|example|changeme|dummy|placeholder|redacted|sample|null|none|true|false|undefined|process\.|os\.environ|getenv|env\.)/i;
      next if $v =~ /[<>{}\$\*]/;                          # template / *** redaction syntax
      next if $v =~ /^[A-Z][a-z]+(?:[A-Z][a-z]+){1,}$/;    # CamelCase identifier, not a secret value
      # entropy floor: a real secret value mixes case/digits; a plain lowercase English-ish word is not one.
      my $digits = ($v =~ tr/0-9//);
      my $upper  = ($v =~ tr/A-Z//);
      my $lower  = ($v =~ tr/a-z//);
      my $classes = (($digits>0)+($upper>0)+($lower>0));
      next if $classes < 2;                                # require >=2 char classes (case+digit mix)
      print "secret-assignment\n"; exit 0;
    }
    exit 0;
  ' "$1" 2>/dev/null
}

PRUNE=( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' \
        -o -path '*/out/*' -o -path '*/.next/*' -o -path '*/.output/*' -o -path '*/.svelte-kit/*' \
        -o -path '*/coverage/*' -o -path '*/walteur-kit/*' -o -path '*/.venv/*' -o -path '*/vendor/*' )

# scan_tree — walk tracked source/config text, run scan_committed_secret on each, echo first hit "file|marker".
scan_tree() {
  local hit=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local m; m="$(scan_committed_secret "$f")"
    if [ -n "$m" ]; then hit="${f#"$ROOT"/}|$m"; break; fi
  done < <(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \
      -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.mts' -o -name '*.cts' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.py' \
        -o -name '*.go' -o -name '*.rb' -o -name '*.java' -o -name '*.cs' -o -name '*.php' \
        -o -name '*.env' -o -name '.env' -o -name '.env.*' -o -name '*.yml' -o -name '*.yaml' \
        -o -name '*.json' -o -name '*.toml' -o -name '*.ini' -o -name '*.cfg' -o -name '*.conf' \
        -o -name '*.properties' -o -name '*.tf' -o -name '*.sh' -o -name '*.txt' -o -name '*.md' \) -print 2>/dev/null)
  printf '%s' "$hit"
}

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused; echo "secret-rotation-gate: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_SECRETROT:-}" = "off" ] && { write_report SKIP "bypassed via WALTEUR_SECRETROT=off"; echo "secret-rotation-gate: SKIP — WALTEUR_SECRETROT=off (loud skip)" >&2; exit 0; }

  if [ ! -f "$POLICY" ]; then
    write_report NOT_APPLICABLE "no secrets-policy.json — build declares no secrets/env"
    echo "secret-rotation-gate: NOT_APPLICABLE (no walteur-kit/secrets-policy.json)" >&2
    exit 0
  fi

  if ! have jq || ! have perl; then
    local miss; have jq || miss="jq"; have perl || miss="${miss:+$miss,}perl"
    # B71 (panel-11 security expert - a real B62-class fail-OPEN): at ship (WALTEUR_TOOLGATE_STRICT=1, which
    # ship-gate.sh exports) an absent jq/perl means the committed-secret scan is UNVERIFIABLE - a HARD "secrets
    # never committed" gate must FAIL-CLOSED there, not SKIP (a committed AKIA in a .mjs was slipping as exit 0).
    # Off-ship it stays a LOUD recorded SKIP (never silent-green). Matches osv/container/anti-slop (B40/41/62).
    if [ "${WALTEUR_TOOLGATE_STRICT:-0}" = "1" ]; then
      add_finding tool_absent_strict "required tool(s) absent at ship ($miss); committed-secret scan UNVERIFIABLE - STRICT fail-closed"
      write_report FAIL "required tool(s) absent at ship: $miss (STRICT fail-closed)"
      echo "secret-rotation-gate: FAIL-CLOSED - required tool(s) absent ($miss) at ship (WALTEUR_TOOLGATE_STRICT=1); committed-secret scan unverifiable" >&2
      exit 2
    fi
    write_report SKIP "required tool(s) absent: $miss"
    echo "secret-rotation-gate: SKIP — required tool(s) absent ($miss); cannot_measure (loud skip, not silent-green)" >&2
    exit 0
  fi

  if ! jq -e . "$POLICY" >/dev/null 2>&1; then
    add_finding policy "secrets-policy.json is not valid JSON"
    write_report FAIL "secrets-policy.json invalid JSON"
    echo "secret-rotation-gate: FAIL (invalid policy JSON) -> exit 2" >&2
    exit 2
  fi

  # shape floor: secrets[] non-empty and static_secret_scan object present.
  if ! jq -e '(.secrets | type=="array" and length>=1) and (.static_secret_scan | type=="object")' "$POLICY" >/dev/null 2>&1; then
    add_finding shape "secrets-policy.json must have a non-empty secrets[] array and a static_secret_scan object"
    write_report FAIL "secrets-policy.json fails required shape"
    echo "secret-rotation-gate: FAIL (bad shape) -> exit 2" >&2
    exit 2
  fi

  # ── (c) HARD — static_secret_scan.ran_ts fresh ───────────────────────────────
  local ran_ts ran_epoch today_epoch scan_age
  ran_ts="$(jq -r '.static_secret_scan.ran_ts // ""' "$POLICY" 2>/dev/null | tr -d '\r')"
  today_epoch="$(date_to_epoch "$TODAY")"
  ran_epoch="$(date_to_epoch "$ran_ts")"
  if [ -z "$ran_ts" ] || [ -z "$ran_epoch" ]; then
    add_finding scan_ran_ts "static_secret_scan.ran_ts is absent or unparseable: '${ran_ts:-<empty>}'"
  elif [ "$ran_epoch" -gt "$today_epoch" ]; then
    add_finding scan_ran_ts "static_secret_scan.ran_ts is in the future: $ran_ts"
  else
    scan_age=$(( (today_epoch - ran_epoch) / 86400 ))
    [ "$scan_age" -gt "$MAX_SCAN_AGE_DAYS" ] && add_finding scan_stale "static secret scan is stale (${scan_age}d old, max ${MAX_SCAN_AGE_DAYS}d)"
  fi

  # ── (b) HARD — every declared secret managed (not hardcoded) + rotated within max age ─────────
  local n i
  n="$(jq '.secrets | length' "$POLICY" 2>/dev/null || echo 0)"
  i=0
  while [ "$i" -lt "$n" ]; do
    local name src maxage last owner last_epoch age
    name="$(jq -r ".secrets[$i].name // \"(unnamed#$i)\"" "$POLICY" 2>/dev/null | tr -d '\r')"
    src="$(jq -r ".secrets[$i].source // \"\"" "$POLICY" 2>/dev/null | tr -d '\r')"
    maxage="$(jq -r ".secrets[$i].rotation_max_age_days // \"\"" "$POLICY" 2>/dev/null | tr -d '\r')"
    last="$(jq -r ".secrets[$i].last_rotated // \"\"" "$POLICY" 2>/dev/null | tr -d '\r')"
    owner="$(jq -r ".secrets[$i].owner // \"\"" "$POLICY" 2>/dev/null | tr -d '\r')"

    case "$src" in
      kms|vault|secret-manager|env-injected) : ;;
      "") add_finding "source[$name]" "secret '$name' has no source — must be one of kms|vault|secret-manager|env-injected" ;;
      *)  add_finding "source[$name]" "secret '$name' source '$src' is not a managed store (hardcoded/inline values are forbidden)" ;;
    esac

    [ -z "$owner" ] && add_finding "owner[$name]" "secret '$name' has no owner"

    if ! printf '%s' "$maxage" | grep -Eq '^[0-9]+$' || [ "${maxage:-0}" -lt 1 ]; then
      add_finding "rotation_max_age[$name]" "secret '$name' rotation_max_age_days must be a positive integer (got '${maxage:-<empty>}')"
    elif [ -z "$last" ]; then
      add_finding "last_rotated[$name]" "secret '$name' has no last_rotated date"
    else
      last_epoch="$(date_to_epoch "$last")"
      if [ -z "$last_epoch" ]; then
        add_finding "last_rotated[$name]" "secret '$name' last_rotated is unparseable: '$last'"
      elif [ "$last_epoch" -gt "$today_epoch" ]; then
        add_finding "last_rotated[$name]" "secret '$name' last_rotated is in the future: $last"
      else
        age=$(( (today_epoch - last_epoch) / 86400 ))
        [ "$age" -gt "$maxage" ] && add_finding "rotation[$name]" "secret '$name' is over-age: rotated ${age}d ago, max ${maxage}d"
      fi
    fi

    # PROTOCOL — provider_attestation: existence/freshness only, never correctness.
    local att_ts att_epoch att_age
    att_ts="$(jq -r ".secrets[$i].provider_attestation.attested_ts // \"\"" "$POLICY" 2>/dev/null | tr -d '\r')"
    if [ -n "$att_ts" ]; then
      att_epoch="$(date_to_epoch "$att_ts")"
      if [ -n "$att_epoch" ] && [ "$att_epoch" -le "$today_epoch" ]; then
        att_age=$(( (today_epoch - att_epoch) / 86400 ))
        [ "$att_age" -gt "$MAX_ATTEST_AGE_DAYS" ] && add_finding "attestation[$name]" "PROTOCOL: provider_attestation for '$name' is stale (${att_age}d, max ${MAX_ATTEST_AGE_DAYS}d) — refresh the attestation (existence/freshness check, not correctness)"
      fi
    fi
    i=$((i+1))
  done

  # ── (a) HARD — the teeth: active committed-secret-literal scan of the tracked tree ───────────
  local scan_hit scan_file scan_marker
  scan_hit="$(scan_tree)"
  local scan_executed=true
  if [ -n "$scan_hit" ]; then
    scan_file="${scan_hit%%|*}"; scan_marker="${scan_hit##*|}"
    add_finding "committed_secret" "tracked file '$scan_file' contains a committed secret literal ($scan_marker) — move it to a managed store and purge from history"
  fi

  if [ "$failures" -gt 0 ]; then
    local extra; extra="$(jq -n --argjson n "$n" --argjson exec "$scan_executed" '{secrets_count:$n, scan_executed:$exec}')"
    write_report FAIL "$failures secret-rotation/scan violation(s)" "$extra"
    echo "secret-rotation-gate: FAIL ($failures) -> exit 2" >&2
    printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null | head -20 >&2 || true
    exit 2
  fi

  local extra; extra="$(jq -n --argjson n "$n" --argjson exec "$scan_executed" --arg scan_ts "$ran_ts" \
    '{secrets_count:$n, scan_executed:$exec, scan_ran_ts:$scan_ts}')"
  write_report PASS "$n secret(s) managed + rotation-fresh; static scan EXECUTED and found zero committed literals" "$extra"
  echo "secret-rotation-gate: PASS ($n secret(s) managed + fresh; scan executed, zero literals)" >&2
  exit 0
}

selftest() {
  local pass=0 fail=0 today t
  today="$(date -u +%F)"
  if ! have jq || ! have perl; then echo "secret-rotation-gate selftest SKIP — need jq+perl."; return 0; fi
  echo "secret-rotation-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }

  # builds a clean source tree (no committed literals)
  seed_src() { mkdir -p "$1/src"; printf 'const apiKey = process.env.API_KEY;\nexport function go(){ return fetch("/x"); }\n' > "$1/src/app.ts"; }
  # writes a policy. $2=source $3=last_rotated $4=scan_ran_ts (all default fresh/managed)
  policy() { # $1=root $2=source $3=last_rotated $4=scan_ran_ts
    local src="${2:-kms}" last="${3:-$today}" scan="${4:-${today}T00:00:00Z}"
    mkdir -p "$1/walteur-kit"
    jq -n --arg src "$src" --arg last "$last" --arg scan "$scan" '{
      schema_version: 1,
      secrets: [
        { name:"STRIPE_API_KEY", source:$src, rotation_max_age_days:90, last_rotated:$last, owner:"payments-team",
          provider_attestation:{ attested_ts:$scan, by:"sec-owner" } }
      ],
      static_secret_scan: { ran_ts:$scan, tool:"gitleaks" }
    }' > "$1/walteur-kit/secrets-policy.json"
  }

  # 1. no policy -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; ck "no secrets-policy.json -> NOT_APPLICABLE" 0 "$(run "$t")"; rm -rf "$t"

  # 2. GOOD: clean tree + managed + fresh + scan fresh -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t"; ck "clean + managed + fresh -> PASS" 0 "$(run "$t")"
  jq -e '.scan_executed == true' "$t/walteur-kit/secret-rotation-report.json" >/dev/null 2>&1; ck "report records scan_executed marker" 0 "$?"; rm -rf "$t"

  # 3. POISONED: committed AKIA-style literal in a seeded file -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t"; printf 'AWS_KEY = AKIAIOSFODNN7EXAMPLE\n' > "$t/src/leak.txt"; ck "committed AKIA literal -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 3a. POISONED (B69 regression guard): secret in a .mjs/.cjs ES-module file must be caught (the find-filter
  #      omitted .mjs/.cjs before B69 - a real blind spot, since apikeys-vault/webhooks-api ship .mjs source).
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t"; printf 'const k = "AKIAIOSFODNN7EXAMPLE";\n' > "$t/src/leak.mjs"; ck "committed secret in .mjs -> FAIL (B69 blind-spot guard)" 2 "$(run "$t")"; rm -rf "$t"

  # 3b. POISONED: committed private-key block -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t"; printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----\n' > "$t/src/key.pem.txt"; ck "committed private-key block -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 3c. POISONED: NAME=high-entropy secret assignment -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t"; printf 'db_password = Ab12Cd34Ef56Gh78Ij90\n' > "$t/src/conf.ini"; ck "committed password=value literal -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 4. POISONED: over-age last_rotated -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t" kms "2000-01-01"; ck "over-age last_rotated -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 5. POISONED: source:hardcoded -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t" hardcoded; ck "source:hardcoded -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 5b. POISONED: stale static_secret_scan.ran_ts -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t" kms "$today" "2000-01-01T00:00:00Z"; ck "stale scan ran_ts -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 5c. POISONED: missing last_rotated -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t"; jq 'del(.secrets[0].last_rotated)' "$t/walteur-kit/secrets-policy.json" > "$t/walteur-kit/p.tmp" && mv "$t/walteur-kit/p.tmp" "$t/walteur-kit/secrets-policy.json"; ck "missing last_rotated -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 6. FP guard: env-injected source + env-var reference (no literal) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t" env-injected; printf 'API_KEY=${API_KEY}\nTOKEN=your-token-here\npassword=changeme\n' > "$t/src/.env.example"; ck "env-ref + placeholders -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # 7. invalid policy JSON -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; mkdir -p "$t/walteur-kit"; printf '{bad json\n' > "$t/walteur-kit/secrets-policy.json"; ck "invalid policy JSON -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # 8. perl-absent -> SKIP. Simulated via WALTEUR_SECRETROT_FORCE_NO_PERL=1 (the have() test hook):
  # symlinking bash into an isolated PATH breaks the msys DLL loader, so the override is the clean,
  # deterministic way to prove the cannot_measure SKIP path offline. A real perl-less host hits the
  # identical `! have perl` branch. The committed literal is present to prove SKIP wins over the scan.
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t"; printf 'AWS_KEY = AKIAIOSFODNN7EXAMPLE\n' > "$t/src/leak.txt"
  rc="$(WALTEUR_SECRETROT_FORCE_NO_PERL=1 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; echo $?)"
  ck "perl absent -> SKIP exit 0" 0 "$rc"
  if [ -f "$t/walteur-kit/secret-rotation-report.json" ]; then
    jq -e '.verdict == "SKIP"' "$t/walteur-kit/secret-rotation-report.json" >/dev/null 2>&1; ck "perl-absent verdict==SKIP" 0 "$?"
  else
    ck "perl-absent verdict==SKIP" 0 1
  fi
  # 8b. B71 (panel-11 security): perl-absent AT SHIP (WALTEUR_TOOLGATE_STRICT=1) -> FAIL-CLOSED, not SKIP -
  #      a committed AKIA was slipping a HARD "secrets never committed" gate as exit 0 (a B62-class fail-open).
  rc="$(WALTEUR_SECRETROT_FORCE_NO_PERL=1 WALTEUR_TOOLGATE_STRICT=1 WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; echo $?)"
  ck "perl absent + STRICT (ship) -> FAIL-CLOSED exit 2 (B71)" 2 "$rc"
  rm -rf "$t"

  # 9. bypass WALTEUR_SECRETROT=off -> SKIP exit 0 (even with a committed literal present)
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t"; printf 'AWS_KEY = AKIAIOSFODNN7EXAMPLE\n' > "$t/src/leak.txt"
  rc="$(WALTEUR_SECRETROT=off WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1; echo $?)"; ck "bypass WALTEUR_SECRETROT=off -> exit 0" 0 "$rc"; rm -rf "$t"

  # 10. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/secretrota.XXXXXX")"; seed_src "$t"; policy "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "secret-rotation-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
