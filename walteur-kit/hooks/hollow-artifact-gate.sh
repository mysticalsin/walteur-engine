#!/usr/bin/env bash
# WALTEUR hollow-artifact-gate — HARD gate (intake: gsd-build/get-shit-done gsd-verifier L4 data-flow check).
# WALTEUR's original retro: builds "under-ship" — the UI looks wired but the data source is a stub, so a green
# build ships a hollow shell. L1-L3 verification proves the artifact RENDERS; this L4 gate proves it's FED by a
# REAL source. For a build that declares a database/API, it scans the server/route/action surface and FAILs any
# handler that returns a STATIC empty collection ([]/{}) or a hard-coded mock with NO data-access call behind it.
#
# Applies when has_db OR has_api_boundary AND a server/route surface exists. Pure static heuristic (labeled).
# CONTRACT: a hollow handler (static-empty/mock response + no DB/query/fetch in the file) => FAIL exit 2 ·
# no data-backed surface => NOT_APPLICABLE · PAUSED => exit 2 · bypass WALTEUR_HOLLOW=off ·
# per-file override line:  // hollow-ok  (or  <!-- hollow-ok -->). Tunable WALTEUR_HOLLOW_MAX (default 0).
# Report: walteur-kit/hollow-artifact-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "hollow-artifact-gate - HARD gate (intake: gsd-build/get-shit-done gsd-verifier L4 data-flow check)."
  printf '%s\n' "usage: bash hollow-artifact-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/hollow-artifact-report.json - fix recipes: walteur-kit/REMEDIATION.md (## hollow-artifact-gate)"
  printf '%s\n' "bypass: WALTEUR_HOLLOW=off (recorded, not free)"
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
REPORT="$KIT/hollow-artifact-report.json"
MAXHITS="${WALTEUR_HOLLOW_MAX:-0}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"hollow-artifact", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

data_backed() {
  [ -f "$SIGNALS" ] && have jq || return 1
  jq -e '(.has_db==true) or (.has_api_boundary==true) or (.external_surface==true)' "$SIGNALS" >/dev/null 2>&1
}

# server/route/action/loader/resolver surface (where a hollow data source ships)
surface_files() {
  command -v find >/dev/null 2>&1 || return 0
  find "$ROOT" -type d \( -name node_modules -o -name .git -o -name walteur-kit -o -name .claude -o -name dist -o -name build -o -name .next -o -name tests -o -name __tests__ \) -prune -o \
    -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.mjs' -o -name '*.py' -o -name '*.go' \) -print 2>/dev/null | \
    grep -iE '/(api|routes?|controllers?|actions?|loaders?|resolvers?|server|handlers?|services?)/|\.(controller|route|resolver|handler|service)\.' 2>/dev/null
}

applies() { data_backed && [ -n "$(surface_files | head -1)" ]; }

# A real data-access token anywhere in the file means it is NOT a hollow stub.
DATA_RE='prisma|drizzle|\bknex\b|sequelize|mongoose|supabase|createClient|mongo|redis|\.query\s*\(|findMany|findUnique|findFirst|\.aggregate\s*\(|\bSELECT\b\s|\bFROM\b\s|\.find(One)?\s*\(|fetch\s*\(|axios|got\s*\(|\$fetch|httpx|requests\.|urllib|sql`|getServerSession|process\.env\.(DATABASE|DB_|SUPABASE|MONGO|REDIS|API_)'

scan_file() {
  local f="$1" rel; rel="$(printf '%s' "$f" | sed "s#$ROOT/##")"
  have perl || return 0
  local res
  res="$(DATA_RE="$DATA_RE" perl -0777 -ne '
    my $b = $_;
    # whole-file override
    exit 0 if $b =~ m{(//|\#|<!--)\s*hollow-ok}i;
    my $hasdata = ($b =~ /$ENV{DATA_RE}/si) ? 1 : 0;
    # explicit mock marker feeding output
    my $mock = ($b =~ /\b(mockData|fakeData|sampleData|dummyData|placeholderData|MOCK_[A-Z]|hardcoded)\b/s) ? 1 : 0;
    # static-empty response returned to a client
    my $empty = 0;
    $empty = 1 if $b =~ /(NextResponse|Response|res|reply|ctx|c)\s*\.\s*(json|send)\s*\(\s*(\[\s*\]|\{\s*\})\s*\)/s;
    $empty = 1 if $b =~ /\breturn\s+(\[\s*\]|\{\s*\})\s*;?\s*\n/s;
    $empty = 1 if $b =~ /\breturn\s+(json|jsonify|JsonResponse)\s*\(\s*(\[\s*\]|\{\s*\}|\[\s*\])\s*\)/s;
    if ((($empty || $mock) && !$hasdata)) {
      print $mock ? "mock-data" : "static-empty";
    }
  ' "$f" 2>/dev/null)"
  [ -n "$res" ] && add_finding "$rel" "hollow handler ($res): returns a stub/empty/mock response with NO data-access call (db/query/fetch) in the file — wire the real source or mark // hollow-ok if intentionally static"
}

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused; echo "hollow-artifact-gate: PAUSED -> exit 2"; exit 2; }
  [ "${WALTEUR_HOLLOW:-}" = "off" ] && { write_report SKIP bypassed; echo "hollow-artifact-gate: bypassed"; exit 0; }
  if ! applies; then write_report NOT_APPLICABLE "no data-backed server surface (need has_db/has_api_boundary + api/route/action files)"; echo "hollow-artifact-gate: NOT_APPLICABLE"; exit 0; fi
  local f
  while IFS= read -r f; do [ -n "$f" ] && scan_file "$f"; done < <(surface_files | sort -u)
  if [ "$failures" -gt "$MAXHITS" ]; then
    write_report FAIL "$failures hollow handler(s) over threshold $MAXHITS"
    echo "hollow-artifact-gate: FAIL ($failures hollow) -> exit 2"
    printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null | head -15 || true
    exit 2
  fi
  write_report PASS "data-backed surface is real ($failures hollow <= $MAXHITS)"
  echo "hollow-artifact-gate: PASS"
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq || ! have perl; then echo "hollow-artifact selftest SKIP - need jq+perl."; return 0; fi
  echo "hollow-artifact-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  seed() { mkdir -p "$1/walteur-kit" "$1/src/api/users"; printf '{"has_db":true,"has_api_boundary":true}\n' > "$1/walteur-kit/preflight-signals.json"; }

  # 1. not data-backed -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/hollowarti.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src/api"; printf '{"has_db":false,"has_api_boundary":false}\n' > "$t/walteur-kit/preflight-signals.json"; printf 'export async function GET(){return Response.json([]);}\n' > "$t/src/api/x.ts"; ck "not data-backed -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. real route with prisma -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/hollowarti.XXXXXX")"; seed "$t"; printf 'import {prisma} from "../db";\nexport async function GET(){ const u = await prisma.user.findMany(); return Response.json(u); }\n' > "$t/src/api/users/route.ts"; ck "real prisma route -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. G1 hollow: route returns [] with no data access -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/hollowarti.XXXXXX")"; seed "$t"; printf 'export async function GET(){ return Response.json([]); }\n' > "$t/src/api/users/route.ts"; ck "G1 static-empty route -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. G2 mock data marker, no data access -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/hollowarti.XXXXXX")"; seed "$t"; printf 'const mockData=[{id:1,name:"Ada"}];\nexport async function GET(){ return Response.json(mockData); }\n' > "$t/src/api/users/route.ts"; ck "G2 mock-data route -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. G3 python flask hollow -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/hollowarti.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/server/handlers"; printf '{"has_db":true}\n' > "$t/walteur-kit/preflight-signals.json"; printf 'def list_users():\n    return jsonify([])\n' > "$t/server/handlers/users.py"; ck "G3 flask static-empty -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. FP guard: route fetching an external API (fetch) -> PASS (real source, just not a DB)
  t="$(mktemp -d "${TMPDIR:-/tmp}/hollowarti.XXXXXX")"; seed "$t"; printf 'export async function GET(){ const r = await fetch("https://api.example.com/u"); return Response.json(await r.json()); }\n' > "$t/src/api/users/route.ts"; ck "G4 external fetch route -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 7. FP guard: hollow-ok override -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/hollowarti.XXXXXX")"; seed "$t"; printf '// hollow-ok intentional empty stub\nexport async function GET(){ return Response.json([]); }\n' > "$t/src/api/users/route.ts"; ck "G5 hollow-ok override -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 8. FP guard: a real route returning [] only as an early-return guard but with a query later -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/hollowarti.XXXXXX")"; seed "$t"; printf 'export async function GET(req){ if(!req.user) return Response.json([]); const u = await prisma.user.findMany(); return Response.json(u); }\n' > "$t/src/api/users/route.ts"; ck "G6 early-return + real query -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 9. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/hollowarti.XXXXXX")"; seed "$t"; printf 'export async function GET(){ return Response.json([]); }\n' > "$t/src/api/users/route.ts"; WALTEUR_ROOT="$t" WALTEUR_HOLLOW=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/hollowarti.XXXXXX")"; seed "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  echo "hollow-artifact-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
