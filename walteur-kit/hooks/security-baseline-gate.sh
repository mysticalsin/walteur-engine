#!/usr/bin/env bash
# WALTEUR security-baseline-gate — HARD gate. "Protect yourself, not just your app."
# Encodes an 11-point production-security baseline (privacy/GDPR-CCPA, RLS, auth failure-path
# tests, security headers, OWASP review, server-side validation, data-leak check, no frontend
# secrets, rate limits, CAPTCHA+CORS, safe error messages). Each is mapped to a §14 production
# layer and is REQUIRED when the build asserts the relevant signal. A security-relevant build
# may not ship with a required baseline check unaddressed.
#
# Reads walteur-kit/security-baseline.json:
#   { "checks": [ { "id":"rls", "status":"verified|signed-deferred|not-applicable",
#                   "evidence":"...", "deferral":{reason,owner,ticket,review_trigger} } ] }
#
# HONESTY: HARD on existence/addressed (the check is present + verified|signed|N-A with proof);
#          PROTOCOL on whether the security is actually CORRECT (that is the security QA pass,
#          org-secure-coding-checklist, and an external pentest agent e.g. CyberStrike/OWASP).
#
# CONTRACT: security-relevant build + missing manifest/check => FAIL exit 2; non-security build
#           => NOT_APPLICABLE; jq absent => SKIP; PAUSED => exit 2.
# Report: walteur-kit/security-baseline-report.json   Bypass: WALTEUR_SECURITY_BASELINE=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "security-baseline-gate - HARD gate. Protect yourself, not just your app."
  printf '%s\n' "usage: bash security-baseline-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/security-baseline-report.json - fix recipes: walteur-kit/REMEDIATION.md (## security-baseline-gate)"
  printf '%s\n' "bypass: WALTEUR_SECURITY_BASELINE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
MANIFEST="${WALTEUR_SECURITY_BASELINE_FILE:-$KIT/security-baseline.json}"
CONTRACT="$KIT/build-contract.json"
SIGNALS="$KIT/preflight-signals.json"
REPORT="$KIT/security-baseline-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() {
  verdict="$1"; reason="$2"; req="${3:-[]}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" --argjson f "$findings" --argjson req "$req" \
      '{verdict:$v, ts:$ts, gate:"security-baseline", reason:$r, required_checks:$req, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"security-baseline","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

# id|jq-required-condition|label (§14 layer)
CHECKS="privacy_legal|(.has_db==true) or (.has_auth==true) or (.has_pii==true) or (.external_surface==true)|GDPR/CCPA privacy policy + know where user data lives (L8 governance)
rls|(.has_db==true)|Row-Level Security policies enabled — DB not readable from DevTools (L8)
auth_failure_tests|(.has_auth==true)|Auth failure paths tested: wrong-pw x5, reset unknown email, double verify, signup existing (L4)
security_headers|(.has_ui==true) or (.external_surface==true)|Strong security headers + baseline posture (L1/L5)
owasp_review|(.external_surface==true) or (.has_api_boundary==true)|OWASP review — SQLi, XSS, auth bugs (L8)
server_side_validation|(.has_api_boundary==true)|Server-side validation (client validation is UX, not security) (L2)
no_data_leaks|(.has_ui==true) or (.has_api_boundary==true) or (.external_surface==true)|No .env in frontend, no over-returning APIs, no secrets in logs (L8)
no_frontend_secrets|(.has_ui==true)|API keys server-side / proxied — not in the browser (L2/L4)
rate_limits|(.has_api_boundary==true) or (.has_payments==true)|Rate limits on every endpoint hitting a paid API (L9)
captcha_cors|(.has_ui==true) and (.external_surface==true)|CAPTCHA on public forms + CORS locked to your domain (L1/L8)
safe_error_messages|(.external_surface==true) or (.has_api_boundary==true)|Generic user errors; full errors logged server-side only (L12)"

load_signals() {
  if [ -f "$SIGNALS" ]; then cat "$SIGNALS"; return; fi
  if [ -f "$CONTRACT" ]; then
    jq '{
      has_ui: ([.interfaces[]?|select(.type=="ui")]|length>0),
      external_surface: ([.interfaces[]?|select(.type=="external-service" or .type=="api" or .type=="public")]|length>0),
      has_api_boundary: ([.interfaces[]?|select(.type=="api" or .type=="external-service")]|length>0),
      has_db: false, has_auth: false, has_payments: false,
      has_pii: ((.data_classification=="pii") or (.data_classification=="regulated") or (.data_classification=="restricted"))
    }' "$CONTRACT" 2>/dev/null || echo '{}'
    return
  fi
  echo '{}'
}

SIGNALS_JSON=""
sig() { printf '%s' "$SIGNALS_JSON" | jq -e "$1" >/dev/null 2>&1; }

# ACTIVE machine check — actually grep client-served source for high-signal exposed secrets.
# A hit FAILS no_frontend_secrets regardless of attested status ("you said no secrets — here's one").
# High-signal provider patterns only (low false-positive); gitleaks (security-gate) is the deeper scan.
scan_secrets() {
  command -v grep >/dev/null 2>&1 || return 0
  # NB excludes only node_modules/.git/walteur-kit — NOT dist/build/.next: the built bundle is
  # exactly where NEXT_PUBLIC_/VITE_ vars are inlined and where sourcemaps embed source (gauntlet hole 10).
  local X='--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit'
  # code + CONFIG/DATA extensions (gauntlet holes 1: .json/.env/.pem/.yaml/.map were never opened)
  local INCSET='--include=*.ts --include=*.tsx --include=*.js --include=*.jsx --include=*.mjs --include=*.cjs --include=*.vue --include=*.svelte --include=*.html --include=*.astro --include=*.json --include=*.json5 --include=*.env --include=*.env.* --include=*.pem --include=*.key --include=*.yaml --include=*.yml --include=*.toml --include=*.txt --include=*.map --include=*.webmanifest'
  # provider prefixes + generic high-value (JWT, SendGrid, Twilio, Stripe webhook) + service-account shape
  # (gauntlet holes 3 + 12: only 6 prefixes before; JWT service-role tokens / firebase .json sailed through)
  local PAT='sk_live_[0-9A-Za-z]{16}|rk_live_[0-9A-Za-z]{16}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[0-9A-Za-z]{36}|xox[baprs]-[0-9A-Za-z-]{10}|-----BEGIN [A-Z ]*PRIVATE KEY-----|SG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{30,}|SK[0-9a-f]{32}|whsec_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{5,}|"type"[[:space:]]*:[[:space:]]*"service_account"|"private_key"[[:space:]]*:[[:space:]]*"-----BEGIN'
  local out
  out="$(grep -rIEl $INCSET $X "$PAT" "$ROOT" 2>/dev/null | head -3)"
  # browser-served roots: ANY extension ships byte-for-byte to visitors (gauntlet hole 2)
  local d h
  for d in public static assets out dist .next; do
    [ -d "$ROOT/$d" ] || continue
    h="$(grep -rIEl "$PAT" "$ROOT/$d" 2>/dev/null | head -2)"
    [ -n "$h" ] && out="$out
$h"
  done
  # exposure VECTOR: a client-public env var NAMED like a secret is inlined into the bundle (gauntlet hole 4)
  if [ -n "$(grep -rIiEl '(NEXT_PUBLIC_|VITE_|REACT_APP_|PUBLIC_|EXPO_PUBLIC_|NUXT_PUBLIC_|GATSBY_)[A-Z0-9_]*(SECRET|PRIVATE|SERVICE_ROLE|SERVICE_KEY|SIGNING|PASSWORD|CLIENT_SECRET|ACCESS_KEY|API_?KEY|TOKEN)' $INCSET $X "$ROOT" 2>/dev/null | head -n1)" ]; then
    out="$out
client-public-env-var-named-like-a-secret"
  fi
  printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | sed "s#$ROOT/##g" | head -4 | tr '\n' ';'
}

# ACTIVE machine check — verify Row-Level Security is actually defined. If SQL/migrations define
# tables but NO `ENABLE ROW LEVEL SECURITY` / `CREATE POLICY` exists, the DB is readable without
# RLS — a naked multi-tenant DB. Echoes "rls_missing" in that case (else nothing). Static scan
# (no live DB needed); when there are no SQL files on disk it stays silent and attestation stands.
scan_rls() {
  command -v grep >/dev/null 2>&1 || return 0
  local X='--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit'
  local TEN='(tenant|org|organization|account|company|customer|team|workspace|project)_?id'   # hole 6: broadened B2B discriminators
  local DDL='enable row level security|create policy'
  local CMT='^[^:]*:[[:space:]]*(//|#|\*|--)'   # exclude comment lines so dead/commented tokens do not count (hole 5)
  # raw SQL: tables defined but no RLS at all
  if grep -rIiE --include='*.sql' $X 'create table' "$ROOT" >/dev/null 2>&1; then
    grep -rIiE --include='*.sql' $X "$DDL" "$ROOT" >/dev/null 2>&1 || { printf 'rls_missing'; return 0; }
  fi
  # non-isolating policy: USING(true) / USING(1=1)
  grep -rIiE --include='*.sql' $X 'using[[:space:]]*\([[:space:]]*(true|1[[:space:]]*=[[:space:]]*1)[[:space:]]*\)' "$ROOT" >/dev/null 2>&1 && { printf 'rls_noop'; return 0; }
  # ORM/code tenant column present: require a REAL RLS DDL (not a dead/comment token — hole 5), scanning
  # SQL *and* migration code (hole 7: Prisma/Drizzle/TypeORM push emit no .sql).
  if grep -rIiE --include='schema.prisma' --include='*.ts' --include='*.js' --include='*.mjs' --include='*.py' --include='*.rb' $X "$TEN" "$ROOT" 2>/dev/null | grep -vqE "$CMT"; then
    grep -rIiE --include='*.sql' --include='*.ts' --include='*.js' --include='*.mjs' --include='*.py' --include='*.rb' $X "$DDL" "$ROOT" 2>/dev/null | grep -vqE "$CMT" || { printf 'rls_orm_missing'; return 0; }
  fi
  # app-layer isolation trusting client input (hole 11): tenant predicate from req.* with no DB-side enforcement
  if grep -rIiE --include='*.ts' --include='*.js' --include='*.mjs' --include='*.py' $X "(req|request)\.(query|params|body|headers|args)[^=;]{0,40}$TEN|$TEN[^=;]{0,40}(req|request)\.(query|params|body|headers|args)" "$ROOT" >/dev/null 2>&1; then
    grep -rIiE --include='*.sql' --include='*.ts' --include='*.js' --include='*.py' $X "$DDL|set_config\(|current_setting\(" "$ROOT" >/dev/null 2>&1 || { printf 'rls_app_layer_trusts_client'; return 0; }
  fi
}

# header/CORS/rate-limit active scans (rank 1) — each fires only when the surface clearly exists
# AND the control is clearly absent; a hit OVERRIDES an attested "verified".
scan_headers() {
  command -v grep >/dev/null 2>&1 || return 0
  local X='--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit'
  # is there a server/edge/config surface that could set headers?
  grep -rIilE --include='*.ts' --include='*.js' --include='*.mjs' --include='*.json' --include='*.conf' --include='*.toml' $X 'middleware|next\.config|vercel\.json|nginx|express\(|fastify\(|createServer|helmet|setHeader|"headers"|headers:' "$ROOT" >/dev/null 2>&1 || return 0
  grep -rIiE $X 'content-security-policy|strict-transport-security|helmet\(|x-content-type-options' "$ROOT" >/dev/null 2>&1 || printf 'header_missing'
}
scan_cors() {
  command -v grep >/dev/null 2>&1 || return 0
  local X='--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit'
  grep -rIiE $X "access-control-allow-origin['\"]?[[:space:]]*[,:=][[:space:]]*['\"]?\*" "$ROOT" >/dev/null 2>&1 && { printf 'ACAO:*'; return 0; }
  grep -rIiE --include='*.ts' --include='*.js' --include='*.mjs' $X 'origin:[[:space:]]*true' "$ROOT" >/dev/null 2>&1 && printf 'origin:true'
}
scan_ratelimit() {
  command -v grep >/dev/null 2>&1 || return 0
  local X='--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit'
  # is there an API/route surface?
  grep -rIilE --include='*.ts' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' $X 'app\.(get|post|put|delete)|router\.|@app\.route|HandleFunc|export (async )?function (GET|POST|PUT|DELETE)|fastify' "$ROOT" >/dev/null 2>&1 || return 0
  grep -rIiE $X 'rate-?limit|ratelimit|express-rate-limit|@upstash/ratelimit|throttle|limiter|[^0-9]429[^0-9]|too many requests' "$ROOT" >/dev/null 2>&1 || printf 'ratelimit_missing'
}

required_check_ids() {
  while IFS='|' read -r id cond label; do
    [ -n "$id" ] || continue
    sig "$cond" && printf '%s\n' "$id"
  done <<< "$CHECKS"
}

validate() {
  risk="medium"; [ -f "$CONTRACT" ] && risk="$(jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium)"
  if [ ! -s "$MANIFEST" ]; then
    add_finding "manifest" "security-relevant build but walteur-kit/security-baseline.json is absent (the 11-point baseline must be addressed)"
    return 0
  fi
  if ! jq -e '.checks | type=="array"' "$MANIFEST" >/dev/null 2>&1; then
    add_finding "manifest_shape" "security-baseline.json has no .checks array"
    return 0
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    entry="$(jq -c --arg i "$id" '.checks[]? | select(.id==$i)' "$MANIFEST" 2>/dev/null | head -1)"
    if [ -z "$entry" ]; then
      add_finding "$id" "required security check '$id' is missing from security-baseline.json"
      continue
    fi
    status="$(printf '%s' "$entry" | jq -r '.status // ""')"
    case "$status" in
      verified)
        ev="$(printf '%s' "$entry" | jq -r '.evidence // ""')"
        [ -n "$ev" ] || add_finding "$id" "status=verified but no evidence cited"
        ;;
      signed-deferred)
        if [ "$risk" = "high" ] || [ "$risk" = "regulated" ]; then
          add_finding "$id" "security check '$id' cannot be deferred at risk_tier=$risk — verify it"
        else
          for f in reason owner ticket review_trigger; do
            v="$(printf '%s' "$entry" | jq -r --arg k "$f" '.deferral[$k] // ""')"
            [ -n "$v" ] || add_finding "$id" "status=signed-deferred but deferral.$f is empty"
          done
        fi
        ;;
      not-applicable)
        rs="$(printf '%s' "$entry" | jq -r '.reason // (.evidence // "")')"
        [ -n "$rs" ] || add_finding "$id" "status=not-applicable but no reason given"
        ;;
      *)
        add_finding "$id" "status must be verified|signed-deferred|not-applicable (got '$status')"
        ;;
    esac
  done < <(required_check_ids)

  # ACTIVE verification — if the build needs the leak checks, actually scan the source. A real
  # exposed secret overrides any attested "verified" status (we looked, not just trusted).
  # NB: capture first + match with `case` — `required_check_ids | grep -q` short-circuits the
  # left side with SIGPIPE which, under `set -o pipefail`, falsely fails the guard.
  reqscan="$(required_check_ids)"
  case "$reqscan" in
    *no_frontend_secrets*|*no_data_leaks*)
      hits="$(scan_secrets)"
      if [ -n "$hits" ]; then
        add_finding "no_frontend_secrets" "ACTIVE scan found exposed secret(s) in client-served source (overrides attested status): $(printf '%s' "$hits" | tr '\n' ';')"
      fi
      ;;
  esac
  case "$reqscan" in
    *rls*)
      case "$(scan_rls)" in
        rls_missing) add_finding "rls" "ACTIVE scan: SQL defines tables but no ENABLE ROW LEVEL SECURITY/CREATE POLICY — DB readable without RLS (overrides attested status)" ;;
        rls_noop) add_finding "rls" "ACTIVE scan: an RLS policy uses USING(true)/USING(1=1) — non-isolating, every tenant sees every row (overrides attested status)" ;;
        rls_orm_missing) add_finding "rls" "ACTIVE scan: ORM/code has a tenant/org/account/customer/team column but no real RLS policy (ENABLE RLS + CREATE POLICY) in SQL or migrations — tenant data not isolated (overrides attested status)" ;;
        rls_app_layer_trusts_client) add_finding "rls" "ACTIVE scan: the tenant predicate is derived from CLIENT request input (req.query/params/headers/body) with no DB-side RLS/session binding — a cross-tenant IDOR (overrides attested status)" ;;
      esac
      ;;
  esac
  case "$reqscan" in
    *security_headers*) [ "$(scan_headers)" = "header_missing" ] && add_finding "security_headers" "ACTIVE scan: a server/config surface exists but no Content-Security-Policy / Strict-Transport-Security / X-Content-Type-Options (nor helmet) — headers attested but absent (overrides attested status)" ;;
  esac
  case "$reqscan" in
    *owasp_review*|*captcha_cors*) corshit="$(scan_cors)"; [ -n "$corshit" ] && add_finding "owasp_review" "ACTIVE scan: permissive CORS found ($corshit) — Access-Control-Allow-Origin:* / origin:true exposes an authed surface cross-site (overrides attested status)" ;;
  esac
  case "$reqscan" in
    *rate_limits*) [ "$(scan_ratelimit)" = "ratelimit_missing" ] && add_finding "rate_limits" "ACTIVE scan: API/route surface exists but no rate-limit / 429 / limiter signal in source — rate limiting attested but absent (overrides attested status)" ;;
  esac
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "security-baseline selftest SKIP - jq not installed."; return 0; fi
  echo "security-baseline-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }
  secsig() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${2:-medium}" > "$1/walteur-kit/build-contract.json"; printf '{"has_ui":true,"external_surface":true,"has_api_boundary":true,"has_db":true,"has_auth":true,"has_payments":true,"has_pii":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  # full baseline (every check verified)
  fullbaseline() {
    jq -n '{checks: ([
      "privacy_legal","rls","auth_failure_tests","security_headers","owasp_review",
      "server_side_validation","no_data_leaks","no_frontend_secrets","rate_limits","captcha_cors","safe_error_messages"
    ] | map({id:., status:"verified", evidence:("addressed: "+.)}))}' > "$1/walteur-kit/security-baseline.json"
  }

  # 1. non-security build -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"has_ui":false,"external_surface":false,"has_api_boundary":false,"has_db":false,"has_auth":false,"has_payments":false}\n' > "$t/walteur-kit/preflight-signals.json"; ck "non-security build -> NOT_APPLICABLE" 0 "$(run "$t")"; rm -rf "$t"
  # 2. security build + full verified baseline -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; ck "security build + full baseline -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. security build + baseline absent -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; ck "security build + baseline ABSENT -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. one required check missing (drop rls) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; jq '.checks |= map(select(.id!="rls"))' "$t/walteur-kit/security-baseline.json" > "$t/b" && mv "$t/b" "$t/walteur-kit/security-baseline.json"; ck "missing required check (rls) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. verified but no evidence -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; jq '(.checks[] | select(.id=="owasp_review")).evidence=""' "$t/walteur-kit/security-baseline.json" > "$t/b" && mv "$t/b" "$t/walteur-kit/security-baseline.json"; ck "verified w/o evidence -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. signed-deferred complete (medium risk) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t" medium; fullbaseline "$t"; jq '(.checks[] | select(.id=="captcha_cors")) |= {id:"captcha_cors",status:"signed-deferred",deferral:{reason:"private beta only",owner:"Tony",ticket:"WALT-9",review_trigger:"before public launch"}}' "$t/walteur-kit/security-baseline.json" > "$t/b" && mv "$t/b" "$t/walteur-kit/security-baseline.json"; ck "signed-deferred complete (medium) -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 7. signed-deferred missing ticket -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t" medium; fullbaseline "$t"; jq '(.checks[] | select(.id=="captcha_cors")) |= {id:"captcha_cors",status:"signed-deferred",deferral:{reason:"x",owner:"Tony",ticket:"",review_trigger:"launch"}}' "$t/walteur-kit/security-baseline.json" > "$t/b" && mv "$t/b" "$t/walteur-kit/security-baseline.json"; ck "signed-deferred missing ticket -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. signed-deferred but risk=high -> FAIL (no deferring security on high risk)
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t" high; fullbaseline "$t"; jq '(.checks[] | select(.id=="rls")) |= {id:"rls",status:"signed-deferred",deferral:{reason:"x",owner:"Tony",ticket:"W-1",review_trigger:"soon"}}' "$t/walteur-kit/security-baseline.json" > "$t/b" && mv "$t/b" "$t/walteur-kit/security-baseline.json"; ck "signed-deferred + risk=high -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. not-applicable with reason -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; jq '(.checks[] | select(.id=="rate_limits")) |= {id:"rate_limits",status:"not-applicable",reason:"no paid-API endpoints in this slice"}' "$t/walteur-kit/security-baseline.json" > "$t/b" && mv "$t/b" "$t/walteur-kit/security-baseline.json"; ck "not-applicable + reason -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 10. invalid status -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; jq '(.checks[] | select(.id=="rls")).status="mock"' "$t/walteur-kit/security-baseline.json" > "$t/b" && mv "$t/b" "$t/walteur-kit/security-baseline.json"; ck "invalid status -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10b. ACTIVE secret scan: a real exposed key in client source -> FAIL even though attested verified
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/src"; printf 'export const k = "sk_live_0123456789abcdef";\n' > "$t/src/config.ts"; ck "exposed secret in src (scan overrides attestation) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10c. ACTIVE RLS scan: SQL defines tables but no RLS policy -> FAIL even though attested verified
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/db"; printf 'CREATE TABLE tenants (id uuid primary key, name text);\n' > "$t/db/schema.sql"; ck "naked DB (tables, no RLS) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10d. real ISOLATING RLS policy -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/db"; printf "CREATE TABLE tenants (id uuid primary key, tenant_id uuid);\nALTER TABLE tenants ENABLE ROW LEVEL SECURITY;\nCREATE POLICY t ON tenants USING (tenant_id = current_setting('app.tenant')::uuid);\n" > "$t/db/schema.sql"; ck "isolating RLS policy -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 10e. no SQL on disk -> RLS scan N/A, attestation stands -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; ck "no SQL files -> RLS scan N/A -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 10f. USING(true) non-isolating policy -> FAIL (rank 12)
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/db"; printf 'CREATE TABLE t (id uuid);\nALTER TABLE t ENABLE ROW LEVEL SECURITY;\nCREATE POLICY p ON t USING (true);\n' > "$t/db/schema.sql"; ck "USING(true) no-op RLS -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10g. ORM (Prisma) tenant column but no RLS enforcement -> FAIL (rank 12)
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/prisma"; printf 'model User {\n  id String @id\n  tenantId String\n}\n' > "$t/prisma/schema.prisma"; ck "ORM tenant col, no RLS -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # --- gauntlet regression: 12 adversarially-PROVEN false-negatives, now locked out ---
  # G6. broadened discriminator: accountId (not just tenantId) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/prisma"; printf 'model Invoice {\n  id String @id\n  accountId String\n}\n' > "$t/prisma/schema.prisma"; ck "G6: ORM accountId, no RLS -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G5. dead/commented current_setting must NOT suppress -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/src"; printf 'model Org { id String @id\n organizationId String }\n' > "$t/src/schema.prisma"; printf '// const x = current_setting("app.tenant"); // decoy, never used\n' > "$t/src/ctx.ts"; ck "G5: dead-comment current_setting -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G11. app-layer tenant predicate from client input, no DB RLS -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/src"; printf 'export const list = (req) => db.invoices.findMany({ where: { tenantId: req.query.tenantId } });\n' > "$t/src/api.ts"; ck "G11: client-trusted tenant predicate -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G1. secret in a .json config file (not just code) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/src"; printf '{"stripe":"sk_live_0123456789abcdef"}\n' > "$t/src/runtime-config.json"; ck "G1: secret in .json -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2. secret under a browser-served root (public/) any extension -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/public"; printf 'window.KEY="sk_live_0123456789abcdef";\n' > "$t/public/config.js"; ck "G2: secret in public/ -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3. generic JWT (e.g. Supabase service-role) in client code -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/src"; printf 'const k = "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.abcdef";\n' > "$t/src/sb.ts"; ck "G3: JWT service-role token -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G4. NEXT_PUBLIC_ env var named like a secret (client-inlined) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; printf 'NEXT_PUBLIC_SERVICE_ROLE_KEY=whatever\n' > "$t/.env.local"; ck "G4: NEXT_PUBLIC secret-named env -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G12. firebase-style service-account JSON -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/src"; printf '{"type":"service_account","private_key":"-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----"}\n' > "$t/src/sa.json"; ck "G12: service-account JSON -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10h. security_headers: server surface but no CSP/HSTS/helmet -> FAIL (rank 1)
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/src"; printf 'import express from "express";\nconst app = express();\napp.get("/", (req,res)=>res.send("hi"));\n' > "$t/src/server.ts"; ck "server, no security headers -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10i. headers + rate-limit present -> PASS (rank 1)
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/src"; printf 'import express from "express";\nimport helmet from "helmet";\nimport rateLimit from "express-rate-limit";\nconst app=express();\napp.use(helmet());\napp.use(rateLimit());\napp.get("/",(req,res)=>res.send("ok"));\n' > "$t/src/server.ts"; ck "helmet + rate-limit present -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 10j. wildcard CORS on an authed surface -> FAIL (rank 1)
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/src"; printf 'import helmet from "helmet";\nres.setHeader("Content-Security-Policy","default-src self");\nres.setHeader("Strict-Transport-Security","max-age=1");\nres.setHeader("Access-Control-Allow-Origin","*");\n' > "$t/src/api.ts"; ck "wildcard CORS -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10k. API/route surface but no rate limit -> FAIL (rank 1)
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; fullbaseline "$t"; mkdir -p "$t/src"; printf 'import express from "express";\nimport helmet from "helmet";\nconst app=express();\napp.use(helmet());\nres.setHeader("Strict-Transport-Security","x");\napp.post("/charge",(req,res)=>res.json({}));\n' > "$t/src/api.ts"; ck "API surface, no rate-limit -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 11. bypass -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; WALTEUR_ROOT="$t" WALTEUR_SECURITY_BASELINE=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  # 12. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/securityba.XXXXXX")"; secsig "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "security-baseline-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_SECURITY_BASELINE:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_SECURITY_BASELINE=off"; echo "security-baseline-gate: bypassed." >&2; exit 0; }
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "security-baseline-gate: SKIP - jq unavailable." >&2; exit 0; fi

SIGNALS_JSON="$(load_signals)"
if ! sig '(.has_db==true) or (.has_auth==true) or (.has_pii==true) or (.external_surface==true) or (.has_api_boundary==true) or (.has_ui==true) or (.has_payments==true)'; then
  write_report "NOT_APPLICABLE" "no security-relevant signal (no UI/auth/db/api/payments/external surface)"
  echo "security-baseline-gate: NOT_APPLICABLE"
  exit 0
fi

req_json="$(required_check_ids | jq -R . | jq -s . 2>/dev/null || echo '[]')"
validate

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures security-baseline violation(s)" "$req_json"
  echo "security-baseline-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null || true
  exit 2
fi
write_report "PASS" "all required security-baseline checks verified, signed-deferred, or N/A" "$req_json"
echo "security-baseline-gate: PASS" >&2
exit 0
