#!/usr/bin/env bash
# WALTEUR ship-gate — HARD-enforced terminal gate; exit 2 on any red.
# Wired PreToolUse on the Bash TOOL (matcher "Bash"); an internal command-guard makes it a
# NO-OP unless the command is `git commit` / `git tag` (the real ship transition).
# Runs against the IN-PROJECT walteur-kit/ (git toplevel || pwd) — never a synced/cloud copy
# (OneDrive/TCC can surface a stale or empty mirror; always gate the working tree).
# Checks (deterministic file reads — NEVER a quality judgment):
#   1 command-guard  2 kill-switch  3 PLAN.md  4 refine-gate (DoD complete + composite>=target)
#   5 qa-report (top+5 lines PASS + RE-RUN recorded unit/int cmd + fresh)  6 debate/OPEN empty
#   7 audit.json (model==opus + certified==true + fresh)
# Bypass: WALTEUR_SHIP=off.
# HONESTY: HARD = this script exit 2 (existence/freshness/green/Opus-authored/re-run = checkable facts).
#          PROTOCOL = correctness of the verdicts inside the files (LLM judgment; labeled, not claimed enforced).
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "ship-gate - HARD-enforced terminal gate; exit 2 on any red."
  printf '%s\n' "usage: bash ship-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/audit.json (its registered verdict report; walteur-kit/qa-report.json is an INPUT it reads) - fix recipes: walteur-kit/REMEDIATION.md (## ship-gate)"
  printf '%s\n' "bypass: WALTEUR_SHIP=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# 1. command-guard — only act on a real ship transition; no-op on every other Bash call.
# Fail-SAFE detection: fire on any command mentioning git AND commit/tag — this catches indirection
# like `g=git; $g commit` that a literal "git commit" substring match would silently skip. Over-
# triggering only ADDS a gate to an unrelated command; it can never let a real ship transition through.
INPUT="$(cat 2>/dev/null || true)"
CMD=""
if command -v jq >/dev/null 2>&1; then
  CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
fi
# jq-free path: MATCH THE RAW PAYLOAD, do not try to parse it.
# A first attempt here used a sed regex to re-extract the command without jq. It extracted nothing, so
# every payload hit the fail-closed branch and the hook blocked `ls -la` — trading a silent fail-open
# for a total lockout, which is worse operationally. Detection does not need parsing: this guard only has
# to notice that a payload mentions git AND a commit-creating verb. Grepping the raw JSON does that with
# no regex fragility, stays ARMED without jq, and cannot brick the harness. Over-matching an escaped
# string inside an unrelated payload only adds a gate — the documented safe direction.
HAYSTACK="${CMD:-$INPUT}"
if printf '%s' "$HAYSTACK" | grep -Eq '(^|[^a-zA-Z0-9_])git([^a-zA-Z0-9_]|$)' \
   && printf '%s' "$HAYSTACK" | grep -Eq 'commit|tag|cherry-pick|cherry_pick|merge|revert|[[:space:]]am([[:space:]]|$)|rebase|push'; then
  :
else
  exit 0
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
KIT="$ROOT/walteur-kit"

# 2. Kill switch
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }
# Bypass
[ "${WALTEUR_SHIP:-on}" = "off" ] && exit 0

fail() { echo "SHIP-GATE FAIL: $1" >&2; exit 2; }

# 3. PLAN.md exists
[ -s "$ROOT/PLAN.md" ] || fail "PLAN.md missing or empty. Plan before build; sign off before ship."

# 4. REFINE-GATE clause — the §3.x all-green conjunction via its proxies (DoD checklist + the score).
# A6 — FAIL-CLOSED: PLAN.md exists (checked above), so this IS a walteur build; a certified build MUST
# emit DoD + scoreboard. Their absence = incomplete build, not a pass. (Old code skipped if absent.)
DOD="$KIT/DEFINITION-OF-DONE.md"
[ -f "$DOD" ] || fail "DEFINITION-OF-DONE.md missing. A certified build emits it; absence = incomplete build (fail-closed)."
grep -q -- '- \[ \]' "$DOD" && fail "DEFINITION-OF-DONE.md has unchecked items. Refine until every box is checked with evidence (never lower the bar)."
SB="$KIT/scoreboard.json"
[ -f "$SB" ] || fail "scoreboard.json missing. The composite score must be recorded before ship (fail-closed)."
target="$(jq -r '.target // empty' "$SB" 2>/dev/null || true)"
composite="$(jq -r '.composite // empty' "$SB" 2>/dev/null || true)"
{ [ -n "$composite" ] && [ "$composite" != "null" ]; } || fail "scoreboard.json composite is not set. The composite score (computed from evidence, not the builder) must be recorded before ship."
if [ -n "$target" ] && [ "$target" != "null" ]; then
  awk "BEGIN{ exit !($composite >= $target) }" 2>/dev/null || fail "composite $composite < target $target. Refine to the bar; the target is immutable mid-run (Iron Law 12)."
fi
# A6 — enforce the SECURITY FLOOR (the computed security dimension must clear floors.security).
secf="$(jq -r '.floors.security // empty' "$SB" 2>/dev/null || true)"
seca="$(jq -r '.floors.security_actual // .dims.security // empty' "$SB" 2>/dev/null || true)"
if [ -n "$secf" ] && [ "$secf" != "null" ] && [ -n "$seca" ] && [ "$seca" != "null" ]; then
  awk "BEGIN{ exit !($seca >= $secf) }" 2>/dev/null || fail "security dimension $seca < floor $secf. Security is a non-negotiable floor (crisis mode), never waived to ship."
fi

# 5. QA gate
QA="$KIT/qa-report.json"
[ -f "$QA" ] || fail "walteur-kit/qa-report.json missing. Run /qa first."
qa_verdict="$(jq -r '.verdict // empty' "$QA" 2>/dev/null || true)"
[ "$qa_verdict" = "PASS" ] || fail "qa-report.json top verdict is not PASS (got: ${qa_verdict:-null}). Run /qa; resolve all failing types."
for k in unit_integration e2e performance accessibility resilience; do
  tv="$(jq -r --arg k "$k" '.[$k].verdict // empty' "$QA" 2>/dev/null || true)"
  [ "$tv" = "PASS" ] || [ "$tv" = "WAIVED" ] || fail "qa-report.json type '$k' verdict is not PASS or WAIVED (got: ${tv:-null})."
done
# Multi-agent QA-corps dimensions (logic/security/data-integrity/integration). Enforced WHEN PRESENT — a
# VETO from any (esp. LOGIC: the build is logically wrong even if tests pass) HARD-blocks the ship. Absent
# keys are skipped so minimal/legacy reports still pass.
for k in logic security data_integrity integration; do
  tv="$(jq -r --arg k "$k" '.[$k].verdict // "ABSENT"' "$QA" 2>/dev/null || echo ABSENT)"
  [ "$tv" = "ABSENT" ] || [ "$tv" = "PASS" ] || [ "$tv" = "WAIVED" ] || fail "qa-report.json dimension '$k' is not PASS or WAIVED (got: $tv). The QA corps VETOed this dimension."
done
ui_cmd="$(jq -r '.unit_integration.recorded_command // empty' "$QA" 2>/dev/null || true)"
if [ -n "$ui_cmd" ]; then
  # A6 — INJECTION GUARD. The recorded command is re-RUN, so it could be a prompt-injection / exfil
  # payload smuggled through agent-written JSON. Defense-in-depth before eval: (a) the runner (first
  # token) must be an allowlisted test runner; (b) reject clear exfil/destructive tokens. A failed
  # check FAILS THE GATE (never runs). Not a full sandbox — see SKILL §enforcement for the honest scope.
  first="$(printf '%s' "$ui_cmd" | awk '{print $1}')"
  case "$first" in
    npm|pnpm|yarn|npx|node|deno|bun|python|python3|pytest|tox|uv|go|cargo|make|just|task|bash|sh|jest|vitest|mocha|rspec|rake|phpunit|composer|dotnet|mvn|gradle|./gradlew|ctest|cmake) : ;;
    *) fail "qa-report recorded_command runner '$first' is not an allowlisted test runner (injection guard). Use a standard runner (npm/node/pytest/go/cargo/...)." ;;
  esac
  if printf '%s' "$ui_cmd" | grep -Eqi 'curl|wget|/dev/tcp|base64|netcat|ncat|rm[[:space:]]+-rf|sudo|mkfs|[[:space:]]dd[[:space:]]|ssh[[:space:]]|scp[[:space:]]|\$\(|`|/etc/(passwd|shadow)'; then
    fail "qa-report recorded_command contains a dangerous token (exfil/destructive). Refusing to re-run."
  fi
  # v10.4 — VACUOUS-RUNNER CLOSE: an allowlisted runner token is necessary but not sufficient (e.g. a
  # recorded_command of literally "true" or "npm run noop-that-does-nothing" would still exit 0 and
  # falsely corroborate the qa-report's PASS claim). Route through the shared _probe-proof.sh kernel —
  # the same "touches something real" guard the execute-probe gates use — before eval'ing. Fail-closed
  # if the guard file is missing (never silently skip the check).
  if [ -f "$KIT/hooks/_probe-proof.sh" ]; then . "$KIT/hooks/_probe-proof.sh"; fi
  if ! command -v probe_proves_something >/dev/null 2>&1; then
    fail "shared probe guard (_probe-proof.sh) unavailable — cannot prove qa-report recorded_command is non-trivial; failing closed."
  fi
  probe_proves_something "$ui_cmd" || fail "qa-report recorded_command '$ui_cmd' is a no-op probe (proves nothing real — see _probe-proof.sh). Refusing to accept as a reproduced test claim."
  (cd "$ROOT" && eval "$ui_cmd" >/dev/null 2>&1) || fail "unit/integration re-run FAILED (command: $ui_cmd). qa-report claims PASS; live run disagrees."
fi
newest_src="$(find "$ROOT" \( -path "$KIT" -o -path "$ROOT/node_modules" -o -path "$ROOT/.git" \) -prune -o -type f -newer "$QA" -print 2>/dev/null | head -1)"
[ -z "$newest_src" ] || fail "Source file '$newest_src' is newer than qa-report.json. Re-run /qa after the last code change."

# 6. ADR gate — no open forks
OPEN="$KIT/debate/OPEN.json"
[ -f "$OPEN" ] || fail "walteur-kit/debate/OPEN.json missing. Initialize as []."
open_count="$(jq 'length' "$OPEN" 2>/dev/null || echo error)"
[ "$open_count" = "0" ] || fail "debate/OPEN.json has ${open_count} unresolved fork(s). Resolve each via /debate -> ADR first."

# 7. Terminal Opus audit gate
AUDIT="$KIT/audit.json"
[ -f "$AUDIT" ] || fail "walteur-kit/audit.json missing. Run /audit (terminal Opus certification) first."
certified="$(jq -r '.certified // empty' "$AUDIT" 2>/dev/null || true)"
[ "$certified" = "true" ] || fail "audit.json certified != true (got: ${certified:-null}). Fix the shortfalls it lists."
amodel="$(jq -r '.model // empty' "$AUDIT" 2>/dev/null || true)"
[ "$amodel" = "opus" ] || fail "audit.json model != opus (got: ${amodel:-null}). The terminal audit MUST be Opus (non-negotiable)."
newest_after_audit="$(find "$ROOT" \( -path "$KIT" -o -path "$ROOT/node_modules" -o -path "$ROOT/.git" \) -prune -o -type f -newer "$AUDIT" -print 2>/dev/null | head -1)"
[ -z "$newest_after_audit" ] || fail "Source file '$newest_after_audit' is newer than audit.json. Re-run /audit after the last code change."

# 8. CRAFT-GATE DISPATCH — run the per-discipline Track-B gates if present. Each is self-contained:
#    exit 2 = a real violation (blocks ship); exit 0 = PASS / SKIP / NOT_APPLICABLE (loud SKIP when its
#    tool is absent — never silent-green). One exit-2 from any gate blocks. Absent gate files => skipped,
#    so a minimal project (or the selftest baseline) is unaffected.
run_gate() {
  local name="$1"; local s="$KIT/hooks/$name"; shift
  [ -f "$s" ] || return 0
  (cd "$ROOT" && bash "$s" "$@" >/dev/null 2>&1); local rc=$?
  # v9.2/T1 — per-gate run-trace span at the gate seam (real exit code; append-only, no daemon).
  # Verdict vocabulary matches the run_gate() exit semantics below: 2=VETO (blocks ship), 0=USED
  # (ran + passed), anything else=SKIP (inapplicable / internal tool error — never blocks; see return 0).
  # TRUE no-op under WALTEUR_TRACE=off (guarded here AND inside run-trace.sh); `|| true` guarantees the
  # span append can NEVER alter the gate's real exit code.
  if [ -f "$KIT/hooks/run-trace.sh" ] && [ "${WALTEUR_TRACE:-on}" != "off" ]; then
    local _gv; case "$rc" in 2) _gv=VETO ;; 0) _gv=USED ;; *) _gv=SKIP ;; esac
    WALTEUR_ROOT="$ROOT" bash "$KIT/hooks/run-trace.sh" emit \
      --phase "ShipGate" --model "n/a" --tool "$name" --exit_code "$rc" --gate_verdict "$_gv" --tokens 5 \
      >/dev/null 2>&1 || true
  fi
  [ "$rc" = 2 ] && fail "craft-gate '$name' reported a violation (exit 2). See walteur-kit/*-report.json."
  return 0   # non-2 (e.g. an internal tool error / inapplicable) records a SKIP and never blocks the ship
}

# ARM THE TEETH (ship/release phase ONLY). This block runs solely on a real ship transition — the
# command-guard above already made this whole script a NO-OP unless the Bash command is `git commit`/
# `git tag`. So exporting here NEVER touches any gate's hermetic --selftest (those run via gate-suite.sh
# with their own env); it only flips the execute-probes ON for the gates dispatched below during an
# actual ship. Effect: a real ship now REQUIRES execution+observation (probes re-run recorded commands
# and observe the exit) and a >=60% execution ratio — not shape-reads of self-written JSON.
#   AUTHZ/PRIVACY/SDLC/AUDIT_EXEC=1 -> the ship-stage proof gates must OBSERVE, not attest.
#   CUTOVER_EXEC=1                  -> zero-downtime-cutover re-runs rollback_proof.command + observes exit.
#   TOOLGATE_STRICT=1              -> tool gates fail-closed on a missing/broken backing tool (no silent green).
#   EXECRATIO_MIN=60              -> execution-ratio-gate FAILs the ship below a 60% executed/applicable ratio.
export WALTEUR_AUTHZ_TENANT_EXEC=1 WALTEUR_PRIVACY_EXEC=1 WALTEUR_SDLC_EXEC=1 WALTEUR_AUDIT_EXEC=1 \
       WALTEUR_CUTOVER_EXEC=1 WALTEUR_TOOLGATE_STRICT=1 WALTEUR_EXECRATIO_MIN=60

run_gate tool-readiness.sh   # GAP 1 — fail-closed: a declared-required missing tool blocks EARLY, before the expensive gates
run_gate spec-lint.sh "$ROOT/PLAN.md"
run_gate anti-slop-ui.sh "$ROOT"
run_gate anti-slop-prose-gate.sh    # user-facing copy free of AI-slop prose tells (stop-slop)
run_gate apple-grade-design-gate.sh   # build it like Apple built it: type scale·4pt grid·tokens·motion·design system
run_gate security-gate.sh
run_gate craft-gate.sh
run_gate iac-scan.sh
run_gate container-scan.sh
# v8.1 — the full discipline coverage (each self-roots + detects applicability; NA/SKIP/PASS => exit 0):
run_gate resilience-lint.sh
run_gate observe-lint.sh
run_gate config-validation.sh
run_gate migration-lint.sh
run_gate contract-gate.sh "$ROOT/PLAN.md"
run_gate compliance-gate.sh
run_gate mutation-gate.sh
run_gate fitness-gate.sh
run_gate maintainability-gate.sh
run_gate loop-readiness-gate.sh       # autonomous loop earned its L0-L3 readiness (state·verifier·denylist·budget·run-log·kill-switch)
run_gate context-compaction-gate.sh   # auto-compact context at 150k/200k absolute (Tony rule)
run_gate harness-self-audit-gate.sh   # WALTEUR scaffold scored + no silent regression (ECC/ruflo)
run_gate integrator-audit-gate.sh     # cross-model Codex SHIP verdict, fresh + adversarial (rocket-fuel §5.5b)
run_gate excellence-loop-gate.sh      # plateau law: green is the floor — plateau or cap+residuals (rocket-fuel §3.x)
run_gate hollow-artifact-gate.sh       # L4 data-flow: no hollow/mock data sources ship (GSD verifier)
run_gate test-claim-verifier-gate.sh  # a "tests pass" claim is REPRODUCED (re-run the cmd), not trusted (lacp)
run_gate data-correctness-gate.sh     # analytics/SQL correctness pitfalls (ECC validate-data)
run_gate release-gate.sh
run_gate frontend-budget.sh
run_gate docrun.sh
run_gate spec-trace.sh "$ROOT/PLAN.md"
run_gate quickstart-check.sh "$ROOT/README.md"
# v8.2 — final discipline coverage (each NA-on-bare; activates only when its context exists):
run_gate perf-gate.sh
run_gate schema-lint.sh
run_gate restore-proof.sh
run_gate tool-contract-lint.sh
run_gate nfr-lint.sh
run_gate devenv-gate.sh
run_gate cost-budget.sh
run_gate i18n-lint.sh
run_gate a11y-content-lint.sh
run_gate story-coverage.sh "$ROOT"
# v8.5 — design contract: UI source requires a non-stub DESIGN.md / design-system/MASTER.md:
run_gate design-gate.sh "$ROOT"
# v9.0 — §2.0b benchmark coverage: user-facing products require walteur-kit/benchmark.md with >=3 leaders,
#         a date, and every table_stakes item dispositioned (planned+taskref OR out_of_scope+reason+signer):
run_gate benchmark-gate.sh "$ROOT"
# v8.5 — §14 L9/L10: HTTP server requires rate-limiting + caching signals or a signed layers.json deferral:
run_gate edge-protection.sh "$ROOT"
# v8.6 — AI safety: AI/agent builds require injection corpus (R2/B3) + bounded agent loop (R1/C2):
run_gate ai-safety-gate.sh "$ROOT"

# v9.0/v9.1 — PRD contract (front-funnel) + intended-vs-implemented (deterministic AST existence arm) +
#             supply-chain (OSV malicious-package gate). detect-or-LOUD-SKIP; exit 2 blocks.
run_gate prd-gate.sh
run_gate intent-trace.sh
run_gate osv-gate.sh

# v9.8 — COMPLETENESS (fix #7): no silent mocks · measured a11y/perf · tests at every layer.
# Each self-roots + detects applicability (NA/SKIP => exit 0); a real violation exits 2 and blocks ship.
run_gate skill-readiness.sh           # fix #2 — routed-required skill missing/unstamped => fail-closed
run_gate skill-quality-gate.sh        # every SKILL.md routable (name+trigger, not bloated) — agent-skills/ECC
run_gate tool-liveness-probe.sh       # required tools actually EXEC (missing|BROKEN-shim|ok) — Agent-Reach
run_gate skill-frontmatter-gate.sh    # SKILL.md upload contract (kebab name, desc <=1024 no <>, known keys)
run_gate persona-coverage-gate.sh      # required senior personas engaged (Chief of Staff/PM/specialists/Audit Squad)
run_gate skill-index-lint.sh          # fix #2 — skill-index.json shape drift guard
run_gate integration-proof-gate.sh    # fix #7 — no integration may silently mock
run_gate measured-quality-gate.sh     # fix #7 — Lighthouse + axe MEASURED, not claimed
run_gate test-layer-coverage-gate.sh  # fix #7 — logic + component + e2e all executed (exit 0)
run_gate security-baseline-gate.sh    # the 11-point production-security baseline (RLS, OWASP, headers, rate limits, CAPTCHA/CORS, safe errors, no leaks) — "don't ship naked"
# v9.9 — ENTERPRISE ($50-100M ARR): revenue integrity + audit trail.
run_gate billing-integrity-gate.sh    # webhook signature + event-id idempotency; money-moving calls carry idempotency keys
run_gate audit-trail-gate.sh          # tamper-evident, retained audit of privileged actions (SOC2 CC7.2/7.3)
# v10.0 — ENTERPRISE: tenant isolation · residency · backups/DR · access recertification.
run_gate cross-tenant-probe-gate.sh   # runs a real two-tenant attack; a cross-tenant LEAK blocks ship
run_gate residency-gate.sh            # data/backups/subprocessors + IaC regions within required_regions
run_gate backup-policy-gate.sh        # cadence/retention/PITR/offsite/encryption consistent with RPO
run_gate access-review-gate.sh        # periodic prod-access recertification within cadence (SOC2 CC6)
run_gate lifecycle-access-gate.sh     # SCIM deprovisioning actually revokes sessions/tokens (disable→401 probe)
run_gate sso-gate.sh                  # SAML/OIDC: signature + audience + time-window + replay, probed with malicious assertions
run_gate load-proof-gate.sh           # fresh load run met p99 budget at a declared RPS/VUs (no shipping unmeasured under load)
run_gate anti-slop-code-gate.sh       # no TODO/placeholder/stub/`as any`/empty-catch in production source — pure production code
run_gate cve-gate.sh                  # no unexpired CRITICAL/HIGH CVE in the dependency tree (fail-closed, signed exceptions)
run_gate dast-gate.sh                 # dynamic scan of the deployed surface: no unexpired High/Critical OWASP alert
run_gate async-trace-lint.sh          # trace-context propagated across every async hop (producer injects, consumer extracts)
run_gate resilience-async-gate.sh     # circuit-breakers on outbound deps + DLQ/idempotency on async jobs + connection-pool ceiling
run_gate redundancy-topology-gate.sh  # no customer-facing single-point-of-failure tier (single region+AZ+<2 replicas)
run_gate design-depth-gate.sh         # the design-of-record decomposes every flagged §14 layer to real depth (no thin design → thin build)
run_gate anti-slop-ui.sh              # frontend output is sleek-by-default: no AI-slop tells (gradients/gradient-text/raw-hex/sluggish-motion/lorem/fake-data/…)
run_gate supply-chain-gate.sh         # no malicious install scripts (Shai-Hulud worm class) + reproducible hash-pinned lockfile
run_gate ci-hardening-gate.sh         # CI is default-secure: SHA-pinned actions, OIDC not static keys, scoped permissions (tj-actions/Megalodon class)
# v10.1 ULTIMATE — research-fleet gates (best-of-breed folded in).
run_gate spec-gate.sh                 # EARS spec.md + constitution.md + FR-ID→task traceability (kills "drift")
run_gate context-budget-gate.sh       # handoff artifacts within the token ceiling; plan pinned (compress + keep quality)
run_gate agent-security-gate.sh       # LLM-agent builds: trust-split + no secret in any prompt/trace (OWASP LLM)
run_gate review-egress-redaction-gate.sh # reviewer-model egress: payload RE-SCANNED secret-clean + consent recorded before any council/external-model review handoff (LOOPER)
run_gate data-acquisition-gate.sh # governed external data sourcing: vetted tool + provenance + robots/PII + high-risk legal signoff (Firecrawl/Crawl4AI/browser-use/curl_cffi)
run_gate stamp-integrity-gate.sh # immutable certification ledger STAMP.md never deleted / rows never removed or altered (sha256 chain)
run_gate dead-code-gate.sh # EXECUTING: runs Knip, observes real exit (unused files/exports/deps); fail-closed on findings or tool error (Knip absent=loud skip)
run_gate db-health-gate.sh # EXECUTING: runs orm-doctor, observes real score+exit (N+1/unsafe-SQL/table-wipe); fail-closed (absent=loud skip)
run_gate security-scan-gate.sh # EXECUTING: runs MEDUSA (AGPL ext-CLI), observes real findings/exit (CVE/secrets/injection/MCP-poison); fail-closed (absent=loud skip)
# v10.3 — ship-phase resilience + deploy + secret hygiene + SLO (run BEFORE execution-ratio so their reports count).
run_gate chaos-resilience-gate.sh      # ACTIVE chaos/game-day drill RECORD: fresh, >=1 recovered drill, no un-accepted failure (resilience surface only)
run_gate secret-rotation-gate.sh       # deployable secrets: no committed VALUES (active scan) + managed-store + rotated within max-age (secrets-policy.json only)
run_gate zero-downtime-cutover-gate.sh # zero-downtime deploy strategy + PROVEN rollback; armed (WALTEUR_CUTOVER_EXEC=1) re-runs rollback_proof.command + observes exit
run_gate slo-error-budget-gate.sh      # service SLOs: errors+latency SLO, every SLO alert-bound, spendable error budget, structured logging (operate-readiness companion to otel)
run_gate execution-ratio-gate.sh # META: % of applicable gates that actually EXECUTED+observed vs shape-read (all-green-but-nothing-ran catch)
run_gate report-integrity-gate.sh # META: freshness+coherence floor across *-report.json (PASS+nonzero observed_exit / *_executed w/o observed_exit => finding; advisory unless WALTEUR_REPORT_INTEGRITY=hard)
run_gate anti-reward-hack-gate.sh     # no tautological/always-pass/skipped tests gaming coverage
run_gate structured-output-gate.sh    # model output is schema-validated before use (no unparsed consumption)
run_gate pbt-gate.sh                  # property-based tests on pure-logic/money/auth modules (tests with teeth)
run_gate mutation-gate.sh             # mutation score ≥ threshold — assertions actually bite
run_gate blast-radius-gate.sh         # brownfield: callers checked before a cross-cutting edit (80%-miss gap)
# §2.6 BROWNFIELD UPGRADE — comprehend-before-change + prove-no-regression (all NA on greenfield).
run_gate intent-reconstruction-gate.sh # brownfield: the existing app's intent is reverse-engineered (INTENT.md) or already in PRD.md
run_gate baseline-capture-gate.sh      # brownfield: a before-snapshot + golden-master net was captured before any edit
run_gate non-regression-gate.sh        # brownfield TERMINAL: after>=before on every dimension, golden-master green, behavior changes signed
run_gate memory-staleness-gate.sh     # no stale-past-TTL fact used without re-verification
run_gate otel-gate.sh                 # API builds emit the OTel traces/metrics/logs observability spine

echo "SHIP-GATE: all gates green. Cleared to ship." >&2
exit 0
