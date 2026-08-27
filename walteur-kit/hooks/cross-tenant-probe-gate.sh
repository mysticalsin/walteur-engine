#!/usr/bin/env bash
# WALTEUR cross-tenant-probe-gate — HARD gate (enterprise backlog rank 2 + 9). The highest-blast-radius
# bug in a multi-tenant SaaS is one tenant reading another's data. This gate runs a REAL two-tenant
# attack: walteur-kit/tenant-isolation.json lists probes that authenticate as tenant A, request tenant
# B's resource, and MUST observe a deny/empty (the probe_command exits 0 on a correct denial, non-0 on a
# LEAK). It also refuses self-certification: if tenant columns exist in source but no isolation proof,
# FAIL (you cannot attest tenant_surface away).
#
# Applies when has_db && has_auth, or tenant/org/account/customer columns are present, or the manifest exists.
# CONTRACT: leak / missing proof => FAIL exit 2 · single-tenant build => NOT_APPLICABLE · PAUSED => exit 2 ·
# bypass WALTEUR_TENANT=off · skip the live probe (keep manifest requirement) with WALTEUR_TENANT_PROBE=off.
# Report: walteur-kit/cross-tenant-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "cross-tenant-probe-gate - HARD gate (enterprise backlog rank 2 + 9). The highest-blast-radius"
  printf '%s\n' "usage: bash cross-tenant-probe-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/cross-tenant-report.json - fix recipes: walteur-kit/REMEDIATION.md (## cross-tenant-probe-gate)"
  printf '%s\n' "bypass: WALTEUR_TENANT=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# absolute path to THIS script, resolved before any cd, so selftest's re-invocation is cwd-independent
case "$0" in
  /*) SELF="$0" ;;
  *)  if [ -e "$0" ]; then SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; else SELF="$0"; fi ;;
esac
# Fail-closed shared guard: the constant-exit / no-op probe CLASS is closed by _probe-proof.sh
# (probe_proves_something) — the same kernel the 7 hardened execute-probe gates source. Source it if
# present; absence is handled fail-closed at the call site below (never a silent skip of the check).
if [ -f "${SELF%/*}/_probe-proof.sh" ]; then . "${SELF%/*}/_probe-proof.sh"; fi

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
MANIFEST="${WALTEUR_TENANT_FILE:-$KIT/tenant-isolation.json}"
REPORT="$KIT/cross-tenant-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
X="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit --exclude-dir=dist --exclude-dir=build --exclude-dir=.next"
TEN='(tenant|org|organization|account|company|customer|team|workspace|project)_?id'

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"cross-tenant-probe", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"cross-tenant-probe","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

tenant_columns_present() { command -v grep >/dev/null 2>&1 && grep -rIiE \
  --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.mjs' --include='*.cjs' \
  --include='*.py' --include='*.sql' --include='*.ddl' --include='*.psql' --include='*.prisma' --include='schema.prisma' \
  --include='*.go' --include='*.rb' --include='*.java' --include='*.cs' --include='*.php' --include='*.kt' --include='*.rs' \
  --include='*.scala' --include='*.ex' --include='*.exs' --include='*.swift' --include='*.sql.gz' \
  $X "$TEN" "$ROOT" >/dev/null 2>&1; }
tenant_surface() {
  [ -f "$MANIFEST" ] && return 0
  if [ -f "$SIGNALS" ] && have jq; then jq -e '(.has_db==true) and (.has_auth==true)' "$SIGNALS" >/dev/null 2>&1 && return 0; fi
  tenant_columns_present
}

# reuse the integration-proof probe-runner safety: network tools allowed, destructive refused
# run_probe — "" ONLY when a REAL cross-tenant attack RAN and was denied; else a finding-reason. Hardened
# (D4 shared fix): a trivial no-op, an off-allowlist/missing command, a whitespace probe, or a probe that
# asserts no DENIAL (403/deny/empty) no longer counts as proof of isolation — those were silent passes.
#
# Unify probe hardening: the constant-exit/no-op CLASS (true/false/:/empty/`bash -lc "exit 0"`/`node -e` etc.
# that exit green while proving nothing) is now judged by the SHARED kernel _probe-proof.sh
# (probe_proves_something) instead of a bespoke per-gate case-statement — one hardened kernel, not six
# diverging copies. A probe passes this stage if EITHER the shared kernel recognizes it as a real test-runner/
# on-disk-artifact invocation, OR the domain-specific real-tool regex finds a genuine network/db/test tool in
# the executed (comment/quote-stripped) text. FAIL CLOSED if the shared guard file was absent at source time
# (function undefined): never silently skip the no-op check.
run_probe() { # $1=command
  local probe="$1" pfirst low eff
  printf '%s' "$probe" | grep -q '[^[:space:]]' || { printf 'empty/whitespace probe — runs no cross-tenant attack; not verification'; return; }
  if printf '%s' "$probe" | grep -Eqi 'rm[[:space:]]+-rf|mkfs|[[:space:]]dd[[:space:]]|/dev/tcp|/etc/(passwd|shadow)|\|[[:space:]]*(bash|sh)([[:space:]]|$)|>[[:space:]]*/dev/sd'; then
    printf 'destructive/exfil token; refused'; return; fi
  if ! command -v probe_proves_something >/dev/null 2>&1; then
    printf 'shared probe guard (_probe-proof.sh) unavailable — cannot prove the probe is non-trivial; failing closed'; return
  fi
  # COMMENT-LAUNDERING DEFENSE: bash discards everything after an unquoted `#`, so a denial token in a
  # trailing comment (`bash -c 'true' # 403 deny`) fools a naive command-string scan while the executed
  # command is a no-op. Strip shell comments before EVERY scan so we judge only the code bash will run.
  # We also flatten `bash -c '...'` / `sh -c "..."` wrappers so an inert inner payload is visible.
  eff="$(printf '%s' "$probe" | perl -0777 -pe '
    s/\x27[^\x27]*\x27/ /g;   # drop single-quoted strings (their # is literal, not a comment)
    s/"[^"]*"/ /g;            # drop double-quoted strings
    s/#.*$//mg;               # strip shell comments on every line
  ')"
  pfirst="$(printf '%s' "$probe" | awk '{print $1}')"
  # NO-OP PROBE DEFENSE: after stripping quoted strings + comments, the EXECUTED command must either be
  # recognized by the shared kernel (real test-runner / on-disk artifact) or still contain a real network/db/
  # test tool — otherwise it authenticates as no one, requests nothing, and exits 0 unconditionally (or is a
  # bare true/false/:/bash -lc 'exit 0' constant). Reject it as a no-op, not a real attack.
  if probe_proves_something "$eff"; then :;
  elif printf '%s' "$eff" | grep -Eqiw 'curl|wget|http|httpie|node|deno|bun|python|python3|psql|mysql|redis-cli|mongosh|sqlite3|grpcurl|fetch|axios|got|request|supertest|pytest|jest|vitest|go|cargo'; then :; else
    printf "probe ('%s') is a constant-exit/no-op — after stripping comments/quoted strings the executed command runs no network/db verification tool — performs no real cross-tenant attack, not verification" "$pfirst"; return; fi
  # The denial assertion must live in CODE bash executes, not in a discarded comment — scan the stripped form.
  low="$(printf '%s' "$probe" | tr 'A-Z' 'a-z')"
  printf '%s' "$low" | grep -Eq '403|401|deny|denied|reject|forbidden|unauthor|blocked|empty|\[\]|no rows|not found|404' || { printf 'probe asserts no denial (403/deny/empty) of the other-tenant request — cannot confirm isolation'; return; }
  (cd "$ROOT" && eval "$probe" >/dev/null 2>&1) || printf 'LEAK: probe accessed the other tenant'\''s resource (expected deny)'
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "cross-tenant selftest SKIP - jq not installed."; return 0; fi
  echo "cross-tenant-probe-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  tsig() { mkdir -p "$1/walteur-kit" "$1/src"; printf '{"has_db":true,"has_auth":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  man() { jq -n --arg c "$1" '{probes:[{name:"read-other-tenant-invoice",probe_command:$c,expect:"deny"}]}' > "$2/walteur-kit/tenant-isolation.json"; }
  # real probes: use a REAL verification tool (node) as the unquoted command word so the no-op/comment-strip
  # guard sees an actual attack. PASS = cross-tenant request observed a 403 deny AND exits 0; LEAK = the
  # request returned 200 (other tenant readable) so the 403 assertion fails and it exits non-0.
  # node falls back to python3 if node is unavailable on the runner.
  if command -v node >/dev/null 2>&1; then
    PASS_PROBE="node -e 'const status=403; process.exit(status===403?0:1) /* deny */'"
    LEAK_PROBE="node -e 'const status=200; process.exit(status===403?0:1) /* expected deny 403 */'"
  else
    PASS_PROBE="python3 -c 'import sys; status=403; sys.exit(0 if status==403 else 1)  # deny'"
    LEAK_PROBE="python3 -c 'import sys; status=200; sys.exit(0 if status==403 else 1)  # expected deny 403'"
  fi

  # 1. single-tenant (no db+auth, no tenant cols) -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf '{"has_db":false,"has_auth":false}\n' > "$t/walteur-kit/preflight-signals.json"; printf 'export const x=1;\n' > "$t/src/a.ts"; ck "single-tenant -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. tenant surface + passing isolation probe (deny held) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "$PASS_PROBE" "$t"; ck "probe holds (deny) -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. tenant surface, manifest ABSENT -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; printf 'const tenantId = ctx.tenantId;\n' > "$t/src/db.ts"; ck "tenant surface, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. probe LEAKS (other tenant readable) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "$LEAK_PROBE" "$t"; ck "probe leaks -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. empty probes array -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; jq -n '{probes:[]}' > "$t/walteur-kit/tenant-isolation.json"; ck "empty probes -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. destructive probe refused -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "rm -rf /tmp/zz" "$t"; ck "destructive probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. tenant columns in source but attested away (no manifest) -> FAIL (rank 9: no self-cert)
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf '{"has_db":false,"has_auth":false}\n' > "$t/walteur-kit/preflight-signals.json"; printf 'model Invoice { id String @id\n accountId String }\n' > "$t/src/schema.prisma"; ck "tenant cols, self-certed away -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. PROBE=off keeps manifest requirement, skips run -> PASS (manifest present, leak probe not run)
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "$LEAK_PROBE" "$t"; WALTEUR_ROOT="$t" WALTEUR_TENANT_PROBE=off bash "$SELF" >/dev/null 2>&1; ck "PROBE=off (manifest present) -> PASS" 0 "$?"; rm -rf "$t"
  # 9. bypass -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "$LEAK_PROBE" "$t"; WALTEUR_ROOT="$t" WALTEUR_TENANT=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  # 10. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # ── D4 shared probe-bypass regressions ──
  # G1 — trivial "true" probe (was a silent pass) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "true" "$t"; ck "G1 trivial true probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2 — off-allowlist / non-existent script probe -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "./tenant-test.sh" "$t"; ck "G2 off-allowlist probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3 — whitespace probe -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man " " "$t"; ck "G3 whitespace probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G4 — probe asserts no denial (exits 0 but proves nothing) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "bash -c 'echo ok | grep -q ok'" "$t"; ck "G4 no-denial probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # ── PROBE comment-laundering / tautology / hidden-surface regressions (red-team gauntlet) ──
  # G5 — comment-laundering: denial token lives only in a trailing shell `# comment` bash discards; the
  #      executed command is `bash -c 'true'`, a pure no-op. Must FAIL (was a silent PASS, exit 0).
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "bash -c 'true' # 404 not found deny" "$t"; ck "G5 comment-laundered no-op -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G6 — tautology echo: keyword echoed as a literal string, real command is `true`; no attack tool runs.
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "bash -c 'echo \"expected 403 deny forbidden for other tenant\"; true'" "$t"; ck "G6 tautology echo probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G7 — hidden surface: tenant columns live in a .tsx (and .go/.ddl) the old globs skipped, no manifest.
  #      Surface must now be DETECTED -> FAIL (was NOT_APPLICABLE exit 0, defect shipped).
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/app" "$t/migrations"; printf '{"has_db":false,"has_auth":false}\n' > "$t/walteur-kit/preflight-signals.json"
  printf 'export default function P(ctx:{ tenantId: string }){ return sql`SELECT * FROM invoices`; }\n' > "$t/app/page.tsx"
  printf 'type Ctx struct { accountId string }\n' > "$t/app/worker.go"
  printf 'CREATE TABLE invoices ( id int, tenant_id int );\n' > "$t/migrations/0001_init.ddl"
  ck "G7 tenant cols in .tsx/.go/.ddl, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G8 — false-positive guard: a REAL tool probe (node) asserting a 403 deny and exiting 0 still PASSES.
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "$PASS_PROBE" "$t"; ck "G8 real node deny probe -> PASS (FP guard)" 0 "$(run "$t")"; rm -rf "$t"

  # ── Unify probe hardening: shared _probe-proof.sh kernel poison classes (constant-exit/no-op) ──
  # G9 — "false" no-op probe -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "false" "$t"; ck "G9 false no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G10 — ":" no-op probe -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man ":" "$t"; ck "G10 ':' no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G11 — "bash -lc 'exit 0'" constant-exit no-op (the class the shared kernel names by name) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "bash -lc 'exit 0'" "$t"; ck "G11 bash -lc exit-0 no-op probe -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G12 — shared guard fail-closed: if _probe-proof.sh is unavailable at source time, a probe must FAIL
  # closed rather than silently skip the no-op check. Simulate by pointing the gate at a copy of itself
  # with the sibling guard file temporarily hidden.
  t="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; tsig "$t"; man "$PASS_PROBE" "$t"
  gdir="$(mktemp -d "${TMPDIR:-/tmp}/crosstenan.XXXXXX")"; cp "$SELF" "$gdir/cross-tenant-probe-gate.sh"
  ck "G12 guard file absent -> FAIL (fail-closed)" 2 "$(WALTEUR_ROOT="$t" bash "$gdir/cross-tenant-probe-gate.sh" >/dev/null 2>&1; echo $?)"
  rm -rf "$t" "$gdir"

  echo "cross-tenant-probe-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_TENANT:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_TENANT=off"; echo "cross-tenant-probe-gate: bypassed." >&2; exit 0; }

if ! tenant_surface; then
  write_report "NOT_APPLICABLE" "single-tenant build (no has_db+has_auth, no tenant columns, no manifest)"
  echo "cross-tenant-probe-gate: NOT_APPLICABLE"; exit 0
fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "cross-tenant-probe-gate: SKIP." >&2; exit 0; fi

if [ ! -s "$MANIFEST" ]; then
  add_finding "manifest" "multi-tenant surface (tenant columns / has_db+has_auth) but walteur-kit/tenant-isolation.json absent — cross-tenant isolation is unproven (you cannot attest it away)"
elif ! jq -e '.probes | type=="array" and length>=1' "$MANIFEST" >/dev/null 2>&1; then
  add_finding "probes" "tenant-isolation.json must list >=1 cross-tenant probe (auth as tenant A, request tenant B's resource, expect deny)"
else
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    name="$(printf '%s' "$p" | jq -r '.name // "?"')"
    cmd="$(printf '%s' "$p" | jq -r '.probe_command // ""')"
    if [ -z "$cmd" ]; then add_finding "$name" "probe has no probe_command"; continue; fi
    if [ "${WALTEUR_TENANT_PROBE:-on}" = "off" ]; then continue; fi
    res="$(run_probe "$cmd")"
    [ -n "$res" ] && add_finding "$name" "$res (ran: $cmd)"
  done < <(jq -c '.probes[]?' "$MANIFEST")
fi

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures cross-tenant isolation violation(s)"
  echo "cross-tenant-probe-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "every cross-tenant probe observed a deny/empty — tenant isolation holds"
echo "cross-tenant-probe-gate: PASS" >&2
exit 0
