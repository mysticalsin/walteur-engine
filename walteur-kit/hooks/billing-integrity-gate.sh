#!/usr/bin/env bash
# WALTEUR billing-integrity-gate — HARD gate (enterprise backlog rank 3). For any payment-handling
# build: every webhook handler MUST verify signatures (else forged events) AND dedupe by event id
# (else at-least-once retries double-apply), and every money-moving API call MUST carry an idempotency
# key (else a retry double-charges). Active static scan — a violation OVERRIDES any attestation.
#
# Applies when payment code is present (Stripe/Paddle/Braintree/…) or preflight has_payments==true.
# CONTRACT: violation => FAIL exit 2 · no payment surface => NOT_APPLICABLE · jq absent (signals only) =>
# best-effort source scan · walteur-kit/PAUSED => exit 2 · bypass WALTEUR_BILLING=off.
# Report: walteur-kit/billing-integrity-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "billing-integrity-gate - HARD gate (enterprise backlog rank 3). For any payment-handling"
  printf '%s\n' "usage: bash billing-integrity-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/billing-integrity-report.json - fix recipes: walteur-kit/REMEDIATION.md (## billing-integrity-gate)"
  printf '%s\n' "bypass: WALTEUR_BILLING=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
REPORT="$KIT/billing-integrity-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
# Include EVERY genuinely-executable surface that can host a payments handler. Node runs .cjs/.cts/.mts as
# first-class CommonJS/ESM, so omitting them lets a real handler hide from the scan (proven red-team miss).
INC="--include=*.ts --include=*.tsx --include=*.js --include=*.jsx --include=*.mjs --include=*.cjs --include=*.cts --include=*.mts --include=*.py --include=*.go --include=*.rb --include=*.php --include=*.java --include=*.cs --include=*.kt --include=*.rs --include=*.scala"
X="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit --exclude-dir=dist --exclude-dir=build --exclude-dir=.next"
# Money-moving create calls. Case-insensitive + optional trailing 's' so BOTH the JS SDK plural form
# (stripe.charges.create) AND the Python/Ruby singular PascalCase form (stripe.Charge.create) are caught.
CREATE_RE='(charges?|paymentintents?|payment_intents?|refunds?|transfers?|invoiceitems?|invoice_items?|payouts?|subscriptions?)\.create'

# code_only <file>: emit the file with comments stripped so a defect-laundering token buried in a comment
# (e.g. `// TODO: add idempotencyKey`) can NEVER satisfy a suppression grep and clear a real violation.
# Strips C/JS/Go/Rust/Java/C#-style block comments /* ... */ and line comments //...  AND shell/py/rb #...
# Uses perl -0777 (whole-file slurp) — grep -P is locale-broken under Windows Git Bash. Over-stripping
# (e.g. a `//` inside a string) is fail-CLOSED for our token scans, so it is acceptable.
code_only() {
  if have perl; then
    perl -0777 -pe '
      s{/\*.*?\*/}{ }gs;        # block comments (multiline, non-greedy)
      s{//[^\n]*}{}g;           # // line comments to EOL
      s{(^|\s)#[^\n]*}{$1}g;    # # line comments (py/rb/sh) — only when # starts a token, not e.g. C# "x#y"
    ' "$1" 2>/dev/null
  else
    cat "$1" 2>/dev/null
  fi
}

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() {
  verdict="$1"; reason="$2"
  if have jq; then jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"billing-integrity", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi
  printf '{"verdict":"%s","ts":"%s","gate":"billing-integrity","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

payment_surface() {
  [ -f "$SIGNALS" ] && have jq && jq -e '.has_payments==true' "$SIGNALS" >/dev/null 2>&1 && return 0
  command -v grep >/dev/null 2>&1 || return 1
  grep -rIilE $INC $X 'stripe|@stripe|paddle|braintree|lemonsqueezy|chargebee|recurly|paymentintent|payment_intent' "$ROOT" >/dev/null 2>&1
}

rel() { printf '%s' "${1#"$ROOT"/}"; }

scan_webhooks() {
  command -v grep >/dev/null 2>&1 || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # All detection AND suppression greps run against the COMMENT-STRIPPED code, never the raw file, so a
    # token sitting in a comment can neither trigger a false handler-detect nor launder away a real finding.
    code="$(code_only "$f")"
    # a real webhook handler: reads a raw body or checks a provider signature header (in actual code)
    printf '%s' "$code" | grep -qiE 'constructevent|stripe-signature|svix|x-signature|express\.raw|raw_?body|webhook.*secret' 2>/dev/null || continue
    # (a) signature verification present?
    printf '%s' "$code" | grep -qiE 'constructevent|webhooks?\.construct|verify_?header|verify_?signature|verify_?webhook|svix|new[[:space:]]+Webhook\(|hmac|compare_digest' 2>/dev/null \
      || add_finding "webhook_signature" "$(rel "$f"): webhook handler with NO signature verification — forged provider events would be accepted"
    # (b) event-id idempotency guard present?
    printf '%s' "$code" | grep -qiE 'idempot|processed_event|on[[:space:]]+conflict|already[_[:space:]]?process|dedup|event\.id|event\[.id.\]|seen_events' 2>/dev/null \
      || add_finding "webhook_idempotency" "$(rel "$f"): webhook handler with NO event-id idempotency guard — at-least-once retries will double-apply (double credit/activation)"
  done < <(grep -rIilE $INC $X 'webhook|constructevent|stripe-signature|express\.raw|raw_?body' "$ROOT" 2>/dev/null)
}

scan_outbound() {
  command -v grep >/dev/null 2>&1 || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Comment-stripped code view: a commented-out .create can't false-trigger, and an idempotencyKey token
    # parked in a comment can't suppress a real money-moving call with no key (both are proven red-team misses).
    code="$(code_only "$f")"
    printf '%s' "$code" | grep -qiE "$CREATE_RE" 2>/dev/null || continue
    printf '%s' "$code" | grep -qiE 'idempotency_?key|idempotency-key' 2>/dev/null \
      || add_finding "outbound_idempotency" "$(rel "$f"): money-moving .create() call with NO idempotency key — a network retry double-charges"
  done < <(grep -rIilE $INC $X "$CREATE_RE" "$ROOT" 2>/dev/null)
}

selftest() {
  pass=0; fail=0
  # Resolve THIS script to an absolute path NOW — every sub-run invokes "bash $SELF" with a different
  # WALTEUR_ROOT, and a relative $0 would break if the gate were ever launched via a relative path.
  case "$0" in /*|?:[\/]*) SELF="$0" ;; *) SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" ;; esac
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  echo "billing-integrity-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  base() { mkdir -p "$1/walteur-kit" "$1/src"; printf '{"has_payments":true}\n' > "$1/walteur-kit/preflight-signals.json"; }

  # 1. no payment surface -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf 'export const x=1;\n' > "$t/src/a.ts"; ck "no payment surface -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. good webhook (sig + idempotency) + good outbound -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"; printf 'import Stripe from "stripe";\nconst e = stripe.webhooks.constructEvent(req.rawBody, sig, secret);\nif (await db.processed_events.has(e.id)) return;\nawait stripe.paymentIntents.create({amount}, {idempotencyKey: key});\n' > "$t/src/webhook.ts"; ck "sig + idempotency + idempotencyKey -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. webhook with NO signature verification -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"; printf 'app.post("/webhook", (req,res)=>{\n const e = JSON.parse(req.rawBody);\n if (seen_events[e.id]) return;\n handle(e);\n});\n' > "$t/src/webhook.ts"; ck "webhook no signature -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. webhook with signature but NO idempotency -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"; printf 'const e = stripe.webhooks.constructEvent(req.rawBody, sig, secret);\nhandle(e);\n' > "$t/src/webhook.ts"; ck "webhook no idempotency -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. money-create with NO idempotency key -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"; printf 'import Stripe from "stripe";\nawait stripe.charges.create({amount: 5000, currency: "usd"});\n' > "$t/src/pay.ts"; ck "outbound no idempotencyKey -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. money-create WITH idempotency key -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"; printf 'import Stripe from "stripe";\nawait stripe.charges.create({amount: 5000}, {idempotencyKey: req.id});\n' > "$t/src/pay.ts"; ck "outbound with idempotencyKey -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 7. bypass -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"; printf 'stripe.charges.create({amount:1});\n' > "$t/src/pay.ts"; WALTEUR_ROOT="$t" WALTEUR_BILLING=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  # 8. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"; printf 'stripe.charges.create({amount:1});\n' > "$t/src/pay.ts"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ---- RED-TEAM REGRESSIONS (proven gauntlet misses; each fixture used to PASS=exit 0, must now FAIL=exit 2) ----
  # G1. comment-laundering: idempotencyKey appears ONLY in a comment, real charges.create has no key -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"
  printf 'import Stripe from "stripe";\nconst stripe = new Stripe(process.env.SK);\n// TODO(billing): we should add an idempotencyKey here before launch, currently missing\nexport async function chargeCustomer(amountCents) {\n  return await stripe.charges.create({ amount: amountCents, currency: "usd", source: "tok_visa" });\n}\n' > "$t/src/pay.ts"
  ck "G1 comment-laundered idempotencyKey -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G2. .cjs extension evasion: genuine CommonJS Stripe webhook (no sig verify, no idempotency, no key on charge) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"
  printf 'const Stripe = require("stripe");\nconst stripe = Stripe(process.env.STRIPE_KEY);\nconst express = require("express");\nconst app = express();\napp.post("/webhook", express.raw({ type: "application/json" }), async (req, res) => {\n  const event = JSON.parse(req.rawBody.toString());\n  if (event.type === "checkout.session.completed") {\n    await grantSubscription(event.data.object.customer);\n    await stripe.charges.create({ amount: 5000, currency: "usd", source: "tok_x" });\n  }\n  res.json({ received: true });\n});\n' > "$t/src/webhook.cjs"
  ck "G2 .cjs webhook surface scanned -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G3. TODO-next-sprint multi-line comment laundering idempotency_key, real charges.create has no key -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"
  printf 'import Stripe from "stripe";\n\nconst stripe = new Stripe(process.env.STRIPE_KEY!);\n\nexport async function chargeCustomer(amount: number, currency: string) {\n  // TODO(next sprint): pass an idempotency_key so retries do not double-charge.\n  // Tracked in JIRA PAY-1421. Not wired yet.\n  const charge = await stripe.charges.create({\n    amount,\n    currency,\n    source: "tok_visa",\n  });\n  return charge.id;\n}\n' > "$t/src/pay.ts"
  ck "G3 TODO-comment-laundered idempotency_key -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G4. .cts extension evasion (TS CommonJS) — money-create with no key -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"
  printf 'import Stripe from "stripe";\nexport async function pay() {\n  await stripe.charges.create({ amount: 9900, currency: "usd" });\n}\n' > "$t/src/pay.cts"
  ck "G4 .cts surface scanned -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G5. block-comment /* */ laundering of idempotencyKey on a real keyless charge -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"
  printf 'import Stripe from "stripe";\n/* note: idempotencyKey support is on the roadmap, idempotency-key not yet sent */\nawait stripe.paymentIntents.create({ amount: 100, currency: "usd" });\n' > "$t/src/pay.ts"
  ck "G5 block-comment-laundered idempotencyKey -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G6. webhook signature/idempotency tokens laundered into comments only -> FAIL (both findings)
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"
  printf 'app.post("/webhook", express.raw({type:"application/json"}), (req,res)=>{\n // we will verify the signature with constructEvent and dedup by event.id soon (hmac) -- not done yet\n const e = JSON.parse(req.rawBody);\n handle(e);\n res.json({ok:true});\n});\n' > "$t/src/webhook.ts"
  ck "G6 webhook sig+idempotency laundered in comment -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G7. FALSE-POSITIVE GUARD: clean .cjs handler with real sig verify + idempotency + key on charge -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"
  printf 'const Stripe = require("stripe");\nconst stripe = Stripe(process.env.STRIPE_KEY);\nconst app = require("express")();\napp.post("/webhook", require("express").raw({type:"application/json"}), async (req,res)=>{\n  const event = stripe.webhooks.constructEvent(req.rawBody, req.headers["stripe-signature"], process.env.WHSEC);\n  if (await db.processed_events.has(event.id)) return res.json({ok:true});\n  await stripe.charges.create({ amount: 5000, currency: "usd" }, { idempotencyKey: event.id });\n  res.json({received:true});\n});\n' > "$t/src/webhook.cjs"
  ck "G7 clean .cjs handler -> PASS (no false positive)" 0 "$(run "$t")"; rm -rf "$t"

  # G8. FALSE-POSITIVE GUARD: real code line has idempotencyKey (not a comment) alongside a harmless comment -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"
  printf 'import Stripe from "stripe";\n// charge the customer once\nawait stripe.charges.create({ amount: 5000 }, { idempotencyKey: orderId });\n' > "$t/src/pay.ts"
  ck "G8 real idempotencyKey w/ benign comment -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # G9. Python SINGULAR SDK form + #-comment laundering: stripe.Charge.create, idempotency_key only in comment -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"
  printf 'import stripe\n# FIXME: add idempotency_key= to this call before prod\nstripe.Charge.create(amount=5000, currency="usd")\n' > "$t/src/pay.py"
  ck "G9 python Charge.create + #-laundered key -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G10. FALSE-POSITIVE GUARD: clean python handler (real sig verify + dedup + idempotency_key on call) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/billingint.XXXXXX")"; base "$t"
  printf 'import stripe\n# stripe webhook receiver\ndef handle(request):\n    event = stripe.Webhook.construct_event(request.body, request.headers["stripe-signature"], secret)\n    if Processed.objects.filter(event_id=event.id).exists():\n        return\n    stripe.PaymentIntent.create(amount=100, idempotency_key=event.id)\n' > "$t/src/webhook.py"
  ck "G10 clean python handler -> PASS (no false positive)" 0 "$(run "$t")"; rm -rf "$t"

  echo "billing-integrity-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_BILLING:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_BILLING=off"; echo "billing-integrity-gate: bypassed." >&2; exit 0; }

if ! payment_surface; then
  write_report "NOT_APPLICABLE" "no payment surface (no Stripe/Paddle/… code and has_payments!=true)"
  echo "billing-integrity-gate: NOT_APPLICABLE"
  exit 0
fi

scan_webhooks
scan_outbound

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures billing-integrity violation(s)"
  echo "billing-integrity-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "webhooks verify signatures + dedupe; money-moving calls carry idempotency keys"
echo "billing-integrity-gate: PASS" >&2
exit 0
