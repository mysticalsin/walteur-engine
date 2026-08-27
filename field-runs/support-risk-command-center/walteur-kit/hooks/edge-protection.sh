#!/usr/bin/env bash
# WALTEUR edge-protection — HARD gate on §14 Layer 9 (Rate Limiting) + Layer 10 (Caching & CDN).
# One unaddressed layer = fail (exit 2). Clean / signed-deferred / not-applicable = exit 0.
# Usage: bash walteur-kit/hooks/edge-protection.sh <dir>
#
# Intent: §14's law is "every layer is addressed OR an explicit, signed decision to defer it".
# Layers 9 and 10 were the only two with no mechanical check — this gate closes that, enforcing
# the §14 law itself: when the project ships an HTTP SERVER, each layer needs EITHER
#   (a) a real signal in the source/config that the concern is handled, OR
#   (b) a signed deferral recorded in walteur-kit/layers.json ("9": "deferred:<reason>" / "pass").
#
# Layer 9 — rate-limiting signals (any): rate-limit / ratelimit / throttle / limiter / 429 /
#   express-rate-limit / rack-attack / slowapi / @upstash/ratelimit / token-bucket / leaky-bucket,
#   or gateway/IaC throttling config.
# Layer 10 — caching/CDN signals (any): Cache-Control / ETag / s-maxage / stale-while-revalidate /
#   redis / memcached / varnish / cloudfront / cloudflare / fastly / CDN / lru_cache / @cache.
#
# Applicability SKIP (recorded, never silent-green):
#   - no HTTP-server code detected (CLI / library / static site / pure frontend => not in scope).
# Bypass: WALTEUR_EDGE=off => write SKIP report, exit 0.
# Kill switch: walteur-kit/PAUSED present => exit 2.
#
# Zero-dep: bash + grep + find + jq only. HARD: real exit 2 on an unaddressed layer.
# HONESTY: signal checks are heuristic PRESENCE checks (lenient direction — a found signal passes;
#          correctness of the rate-limit/cache config stays PROTOCOL via Senior Security/Full-Stack).
# Report: walteur-kit/edge-report.json  {verdict, ts, gate, reason, layers:{9,10}}.
set -uo pipefail

ARG_DIR="${1:-}"
if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "$WALTEUR_ROOT" ]; then
  ROOT="$(cd "$WALTEUR_ROOT" && pwd)"
elif [ -n "$ARG_DIR" ] && [ -d "$ARG_DIR" ]; then
  ROOT="$(cd "$ARG_DIR" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/edge-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_report() { # $1=verdict $2=reason $3=l9 $4=l10
  jq -n --arg v "$1" --arg ts "$TS" --arg reason "$2" --arg l9 "${3:-n/a}" --arg l10 "${4:-n/a}" \
    '{verdict:$v, ts:$ts, gate:"edge-protection", reason:$reason, layers:{"9_rate_limiting":$l9,"10_caching_cdn":$l10}}' > "$REPORT"
}

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }

for t in grep find jq; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WALTEUR edge-protection SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
    write_report "SKIP" "$t not installed"; exit 0
  fi
done

if [ "${WALTEUR_EDGE:-on}" = "off" ]; then
  echo "WALTEUR edge-protection SKIP — bypass WALTEUR_EDGE=off (recorded, not silent-green)." >&2
  write_report "SKIP" "bypass WALTEUR_EDGE=off"; exit 0
fi

DIR="${ARG_DIR:-$ROOT}"
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  echo "WALTEUR edge-protection SKIP — no/invalid directory argument." >&2
  write_report "SKIP" "no/invalid directory argument"; exit 0
fi

PRUNE=( \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.next/*' -o -path '*/coverage/*' -o -path '*/walteur-kit/*' -o -path '*/vendor/*' \) -prune -o )

# ── applicability: does this project ship an HTTP server? ───────────────────
SRC_FILES="$(find "$DIR" "${PRUNE[@]}" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.ts' -o -name '*.py' -o -name '*.go' -o -name '*.rb' -o -name '*.rs' -o -name '*.java' -o -name '*.php' \) -print 2>/dev/null)"
SERVER_HIT=""
if [ -n "$SRC_FILES" ]; then
  SERVER_HIT="$(printf '%s\n' "$SRC_FILES" | xargs grep -lEi \
    'require\(["'"'"']express["'"'"']\)|from ["'"'"']express["'"'"']|fastify\(|new Koa\(|Hono\(|createServer\(|listen\([0-9]|FastAPI\(|Flask\(__name__|django|http\.ListenAndServe|gin\.Default\(|actix_web|axum::|Rails\.application|@RestController|->get\(["'"'"']/' \
    2>/dev/null | head -1)"
fi
if [ -z "$SERVER_HIT" ]; then
  echo "WALTEUR edge-protection SKIP — no HTTP-server code detected under '$DIR' (layers 9/10 not in scope)." >&2
  write_report "SKIP" "no HTTP-server code detected"; exit 0
fi

# ── signed deferral lookup (the §14 escape hatch — a WRITTEN, owned decision) ─
layer_status() { # $1 = layer number → echoes layers.json value or ""
  [ -f "$KIT/layers.json" ] || { echo ""; return; }
  jq -r --arg k "$1" '
    .[$k] //
    (
      first(
        (.production_layers // [])[]
        | select((.id | tostring) == $k)
        | if (.status | IN("verified","built")) then "pass"
          elif (.status | IN("deferred","out_of_scope")) then
            "deferred:" + ((.rationale // .reason // "production-layer contract") | tostring)
          else "" end
      ) // ""
    )
  ' "$KIT/layers.json" 2>/dev/null
}

# ── signal scans (presence checks across source + common config/IaC files) ───
ALL_FILES="$(find "$DIR" "${PRUNE[@]}" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.ts' -o -name '*.py' -o -name '*.go' -o -name '*.rb' -o -name '*.rs' -o -name '*.java' -o -name '*.php' -o -name '*.tf' -o -name '*.yml' -o -name '*.yaml' -o -name '*.toml' -o -name '*.conf' -o -name '*.json' \) -print 2>/dev/null)"

has_signal() { # $1 = extended regex → 0 if any file matches
  [ -n "$ALL_FILES" ] && printf '%s\n' "$ALL_FILES" | xargs grep -lEi "$1" 2>/dev/null | head -1 | grep -q .
}

L9="MISSING"; L10="MISSING"
if has_signal 'rate.?limit|throttl|limiter|"429"|status\(429\)|rack.attack|slowapi|token.bucket|leaky.bucket'; then
  L9="signal-found"
else
  st="$(layer_status 9)"
  case "$st" in pass|deferred:*) L9="layers.json:$st" ;; esac
fi
if has_signal 'cache-control|etag|s-maxage|stale-while-revalidate|redis|memcached|varnish|cloudfront|cloudflare|fastly|[^a-z]cdn[^a-z]|lru_cache|@cache|surrogate-key'; then
  L10="signal-found"
else
  st="$(layer_status 10)"
  case "$st" in pass|deferred:*) L10="layers.json:$st" ;; esac
fi

if [ "$L9" = "MISSING" ] || [ "$L10" = "MISSING" ]; then
  write_report "FAIL" "HTTP server detected but §14 layer(s) unaddressed and not signed-deferred" "$L9" "$L10"
  echo "WALTEUR edge-protection: FAIL — HTTP server detected ($SERVER_HIT) but:" >&2
  [ "$L9"  = "MISSING" ] && echo "  L9 RATE LIMITING — no rate-limit/throttle/429 signal in source/config, and no signed deferral in walteur-kit/layers.json (\"9\": \"deferred:<reason>\")." >&2
  [ "$L10" = "MISSING" ] && echo "  L10 CACHING & CDN — no cache-control/etag/redis/CDN signal, and no signed deferral in walteur-kit/layers.json (\"10\": \"deferred:<reason>\")." >&2
  echo "  Fix: implement the layer, or record the owned deferral (§14: every layer is ✅ or deferred in writing)." >&2
  exit 2
fi

write_report "PASS" "L9=$L9 L10=$L10" "$L9" "$L10"
echo "WALTEUR edge-protection: PASS — L9=$L9 · L10=$L10." >&2
exit 0
