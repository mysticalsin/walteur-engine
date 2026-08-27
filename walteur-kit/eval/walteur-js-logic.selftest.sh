#!/usr/bin/env bash
# walteur-js-logic.selftest.sh — zero-drift proof for the v9.2 BUCKET-JS pure-logic blocks in walteur.js.
# Mirrors the existing WAVE-LOGIC/TRIAGE-LOGIC extraction idiom in walteur-kit/selftest.sh: the pure
# decision functions live BETWEEN named markers in the orchestrator, are extracted verbatim by awk (so the
# test can NEVER drift from production), exported as an ESM module, and asserted against a truth table.
# Proves: #1 triageRoute · #6 reconcileVerdict · #10 spawnJustify · #12 classifyScopeTrack · blast-radius sortByBlastRadius.
# Usage: walteur-js-logic.selftest.sh [--selftest]   (the flag is accepted for registrar uniformity)
set -u
PASS=0; FAIL=0
ck () { # ck "label" expected actual
  if [ "$2" = "$3" ]; then echo "  ok   — $1"; PASS=$((PASS+1)); else echo "  FAIL — $1 (want '$2' got '$3')"; FAIL=$((FAIL+1)); fi
}

# Resolve walteur.js: prefer the canonical git mirror, fall back to a sibling .claude tree, then $WALTEUR_JS.
CANDIDATES="${WALTEUR_JS:-} \
$HOME/walteur/starter/.claude/workflows/walteur.js \
$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)/.claude/workflows/walteur.js"
WJS=""
for c in $CANDIDATES; do [ -f "$c" ] && { WJS="$c"; break; }; done
if [ -z "$WJS" ]; then echo "FAIL — cannot locate walteur.js (set WALTEUR_JS)"; exit 2; fi
echo "walteur.js pure-logic extraction assertions (zero-drift from: $WJS):"

T="$(mktemp -d "${TMPDIR:-/tmp}/walteur-logic.XXXXXX")"; trap 'rm -rf "$T"' EXIT

extract () { # extract BLOCKNAME -> $T/BLOCK.mjs ; returns nonzero if empty
  awk "/>>> $1-LOGIC START/{f=1;next} /<<< $1-LOGIC END/{f=0} f" "$WJS" > "$T/$1.mjs"
  [ -s "$T/$1.mjs" ]
}

# ── #6 RECON-LOGIC: reconcileVerdict truth table ────────────────────────────────
if extract RECON; then
  printf '\nexport { reconcileVerdict };\n' >> "$T/RECON.mjs"
  cat > "$T/RECON.test.mjs" <<'EOF'
import { reconcileVerdict } from './RECON.mjs';
const cases = [
  [{ status:'DONE', tests_pass:true,  planned_files:['a.js'], actual_files:['a.js'] }, 'PASS'],
  [{ status:'DONE', tests_pass:false, planned_files:['a.js'], actual_files:['a.js'] }, 'GAP'],
  [{ status:'DONE', tests_pass:true,  planned_files:['a.js'], actual_files:['a.js','b.js'] }, 'DRIFT'],     // wrote unowned
  [{ status:'DONE', tests_pass:true,  planned_files:['a.js','b.js'], actual_files:['a.js'] }, 'DRIFT'],     // skipped owned
  [{ status:'DONE', tests_pass:true,  planned_files:['a.js'], actual_files:['a.js'], concern:true }, 'DONE_WITH_CONCERNS'],
  [{ status:'BLOCKED', tests_pass:false, planned_files:['a.js'], actual_files:[] }, 'BLOCKED'],
  [{ status:'FAILED',  tests_pass:false, planned_files:[], actual_files:[] }, 'BLOCKED'],
];
let out = [];
for (const [inp, want] of cases) { const got = reconcileVerdict(inp); out.push(got === want ? 'ok' : `BAD:${got}!=${want}`); }
console.log(out.join('|'));
EOF
  GOT=$(cd "$T" && node RECON.test.mjs 2>&1)
  ck "#6 reconcileVerdict PASS/GAP/DRIFT(x2)/DONE_WITH_CONCERNS/BLOCKED(x2)" "ok|ok|ok|ok|ok|ok|ok" "$GOT"

  # ── S1 WIRING: resolveBuildResult join → reconcileVerdict (integration, not just the pure fn) ──────
  # The pure reconcileVerdict cases above pass in isolation, but the live call site joins a build result by
  # id. A failed implementer is a sentinel {__failed,status:'FAILED',id}; before S1 the join produced r={}
  # (no id match) → reconcileVerdict({status:undefined}) → GAP, mis-classifying the WORST task. This proves
  # the WIRING: sentinel-by-id and sentinel-by-failures-label both resolve to BLOCKED, and a fallback-tier
  # success resolves to DONE_WITH_CONCERNS.
  printf '\nexport { resolveBuildResult };\n' >> "$T/RECON.mjs"
  cat > "$T/RECON.wiring.test.mjs" <<'EOF'
import { reconcileVerdict, resolveBuildResult } from './RECON.mjs';
const out = [];
const task = { id: 7, files: ['a.js'] };
// (1) failed sentinel carrying id (safeOne parsed it from `build:T7`) → resolves → BLOCKED
const buildA = [{ id: 7, __failed: true, status: 'FAILED' }];
const rA = resolveBuildResult(buildA, [], task.id);
const vA = reconcileVerdict({ status: rA.status, tests_pass: rA.tests_pass, planned_files: task.files, actual_files: rA.files_written || [], concern: !!rA.__failed });
out.push(vA === 'BLOCKED' ? 'ok' : `BAD-sentinel-by-id:${vA}`);
// (2) sentinel NOT in build but present in failures[] by label → label fallback → BLOCKED (never r={})
const rB = resolveBuildResult([], [{ label: 'build:T7' }], task.id);
const vB = reconcileVerdict({ status: rB.status, tests_pass: rB.tests_pass, planned_files: task.files, actual_files: rB.files_written || [], concern: !!rB.__failed });
out.push(vB === 'BLOCKED' ? 'ok' : `BAD-sentinel-by-label:${vB}`);
// (3) fallback-tier success (safeOne tagged __usedFallback) → DONE_WITH_CONCERNS
const buildC = [{ id: 7, status: 'DONE', tests_pass: true, files_written: ['a.js'], __usedFallback: true }];
const rC = resolveBuildResult(buildC, [], task.id);
const concernC = !!(rC && rC.__failed) || (rC.status === 'DONE' && rC.tests_pass === false) || !!(rC && rC.__usedFallback);
const vC = reconcileVerdict({ status: rC.status, tests_pass: rC.tests_pass, planned_files: task.files, actual_files: rC.files_written || [], concern: concernC });
out.push(vC === 'DONE_WITH_CONCERNS' ? 'ok' : `BAD-fallback-concern:${vC}`);
// (4) clean success still resolves to PASS (no regression)
const buildD = [{ id: 7, status: 'DONE', tests_pass: true, files_written: ['a.js'] }];
const rD = resolveBuildResult(buildD, [], task.id);
const vD = reconcileVerdict({ status: rD.status, tests_pass: rD.tests_pass, planned_files: task.files, actual_files: rD.files_written || [], concern: false });
out.push(vD === 'PASS' ? 'ok' : `BAD-clean:${vD}`);
console.log(out.join('|'));
EOF
  GOT=$(cd "$T" && node RECON.wiring.test.mjs 2>&1)
  ck "S1 wiring: failed sentinel (by-id|by-label)→BLOCKED · fallback→DONE_WITH_CONCERNS · clean→PASS" "ok|ok|ok|ok" "$GOT"
else echo "  FAIL — RECON-LOGIC marker extraction empty (drift)"; FAIL=$((FAIL+1)); fi

# ── #10 SPAWN-LOGIC: spawnJustify recommendation + hard exclusion ────────────────
if extract SPAWN; then
  printf '\nexport { spawnJustify };\n' >> "$T/SPAWN.mjs"
  cat > "$T/SPAWN.test.mjs" <<'EOF'
import { spawnJustify } from './SPAWN.mjs';
const out = [];
// excluded (governance/auditor/security-floor/Logic-Correctness/intent-auditor) ALWAYS spawns + isolation_required
const ex = spawnJustify({ files:[], deps:[], detail:'', isExcluded:true });
out.push(ex.recommend === 'spawn' && ex.isolation_required === true ? 'ok' : `BAD-excluded:${ex.recommend}/${ex.isolation_required}`);
// tiny task, weak criteria -> prefer in-session
const tiny = spawnJustify({ files:['x.js'], deps:['1'], detail:'tweak', acceptance:'', model:'sonnet', sameWaveCount:1 });
out.push(tiny.recommend === 'in-session' ? 'ok' : `BAD-tiny:${tiny.recommend}`);
// substantial parallel task -> spawn
const big = spawnJustify({ files:['a.js','b.js','c.js'], deps:[], detail:'x'.repeat(250), acceptance:'y'.repeat(80), model:'opus', sameWaveCount:3 });
out.push(big.recommend === 'spawn' ? 'ok' : `BAD-big:${big.recommend}`);
console.log(out.join('|'));
EOF
  GOT=$(cd "$T" && node SPAWN.test.mjs 2>&1)
  ck "#10 spawnJustify excluded=spawn+isolated · tiny=in-session · big=spawn" "ok|ok|ok" "$GOT"
else echo "  FAIL — SPAWN-LOGIC marker extraction empty (drift)"; FAIL=$((FAIL+1)); fi

# ── #12 CEREMONY-LOGIC: classifyScopeTrack tracks + forced override ──────────────
if extract CEREMONY; then
  printf '\nexport { classifyScopeTrack };\n' >> "$T/CEREMONY.mjs"
  cat > "$T/CEREMONY.test.mjs" <<'EOF'
import { classifyScopeTrack } from './CEREMONY.mjs';
const out = [];
out.push(classifyScopeTrack({ file_count:1, in_scope_count:1 }) === 'quick-fix' ? 'ok' : 'BAD-qf');
out.push(classifyScopeTrack({ file_count:5, in_scope_count:5 }) === 'standard' ? 'ok' : 'BAD-std');
out.push(classifyScopeTrack({ file_count:10, in_scope_count:10 }) === 'complex' ? 'ok' : 'BAD-cx');
out.push(classifyScopeTrack({ forced:'complex', file_count:1, in_scope_count:1 }) === 'complex' ? 'ok' : 'BAD-forced'); // override wins
out.push(classifyScopeTrack({ file_count:NaN }) === 'standard' ? 'ok' : 'BAD-default'); // ambiguity -> standard
console.log(out.join('|'));
EOF
  GOT=$(cd "$T" && node CEREMONY.test.mjs 2>&1)
  ck "#12 classifyScopeTrack quick-fix/standard/complex/forced/default" "ok|ok|ok|ok|ok" "$GOT"
else echo "  FAIL — CEREMONY-LOGIC marker extraction empty (drift)"; FAIL=$((FAIL+1)); fi

# ── blast-radius: sortByBlastRadius ordering (worst-consequence first) ───────────
if extract RADIUS; then
  printf '\nexport { blastRadius, sortByBlastRadius };\n' >> "$T/RADIUS.mjs"
  cat > "$T/RADIUS.test.mjs" <<'EOF'
import { blastRadius, sortByBlastRadius } from './RADIUS.mjs';
const out = [];
out.push(blastRadius('possible data corruption in writer') === 'data-corruption' ? 'ok' : 'BAD-dc');
out.push(blastRadius('SQL injection at the query sink') === 'security-exposure' ? 'ok' : 'BAD-sec');
out.push(blastRadius('minor whitespace nit') === 'cosmetic' ? 'ok' : 'BAD-cos');
out.push(blastRadius('something unclassifiable here') === 'degraded-ux' ? 'ok' : 'BAD-unknown'); // unknown -> middle
// ordering: a cosmetic + a corruption + a security finding sort worst-first
const sorted = sortByBlastRadius([
  { text:'typo in label' }, { text:'data corruption on concurrent write' }, { text:'auth bypass via header' },
]).map(x => x.blast_radius).join(',');
out.push(sorted === 'data-corruption,security-exposure,cosmetic' ? 'ok' : `BAD-order:${sorted}`);
console.log(out.join('|'));
EOF
  GOT=$(cd "$T" && node RADIUS.test.mjs 2>&1)
  ck "blast-radius classify(4) + sort worst-first" "ok|ok|ok|ok|ok" "$GOT"
else echo "  FAIL — RADIUS-LOGIC marker extraction empty (drift)"; FAIL=$((FAIL+1)); fi

# ── #1 TRIAGE-LOGIC: triageRoute default-Code safety table ───────────────────────
# NOTE: the TRIAGE markers carry a "// v9.2 #1 —" prefix instead of the >>>/<<< arrows the other blocks
# use, so this anchors on the "TRIAGE-LOGIC START/END" substring (present regardless of the prefix). The
# extracted block also pulls in the top-level `const _consecutiveRedByGate = new Map()` — a harmless
# module-level const that the pure fn does not read. Locks the default-Code routing the orchestrator relies
# on: a regression to any threshold (consecutive_n<2, confidence<0.7, classification gating) is caught here.
awk '/TRIAGE-LOGIC START/{f=1;next} /TRIAGE-LOGIC END/{f=0} f' "$WJS" > "$T/TRIAGE.mjs"
if [ -s "$T/TRIAGE.mjs" ]; then
  printf '\nexport { triageRoute };\n' >> "$T/TRIAGE.mjs"
  cat > "$T/TRIAGE.test.mjs" <<'EOF'
import { triageRoute } from './TRIAGE.mjs';
const out = [];
// consecutive_n<2 -> Code (triage fires only on 2nd+ consecutive same-gate RED) even with a high-conf Intent
out.push(triageRoute({ gate:'g', consecutive_n:1, classification:'Intent', confidence:0.99 }) === 'Code' ? 'ok' : 'BAD-n1');
// null / 'Code' classification -> Code regardless of confidence
out.push(triageRoute({ gate:'g', consecutive_n:3, classification:null, confidence:0.99 }) === 'Code' ? 'ok' : 'BAD-null');
out.push(triageRoute({ gate:'g', consecutive_n:3, classification:'Code', confidence:0.99 }) === 'Code' ? 'ok' : 'BAD-code');
// confidence below threshold (default 0.7) -> Code even for a valid Intent/Spec classification
out.push(triageRoute({ gate:'g', consecutive_n:3, classification:'Intent', confidence:0.69 }) === 'Code' ? 'ok' : 'BAD-lowconf');
// armed + high confidence -> route to the classified track
out.push(triageRoute({ gate:'g', consecutive_n:2, classification:'Intent', confidence:0.7 }) === 'Intent' ? 'ok' : 'BAD-intent');
out.push(triageRoute({ gate:'g', consecutive_n:2, classification:'Spec', confidence:0.8 }) === 'Spec' ? 'ok' : 'BAD-spec');
// unknown classification at high conf -> safe default Code
out.push(triageRoute({ gate:'g', consecutive_n:3, classification:'Mystery', confidence:0.99 }) === 'Code' ? 'ok' : 'BAD-unknown');
console.log(out.join('|'));
EOF
  GOT=$(cd "$T" && node TRIAGE.test.mjs 2>&1)
  ck "#1 triageRoute n<2/null/Code/low-conf -> Code · Intent/Spec @hi-conf · unknown -> Code" "ok|ok|ok|ok|ok|ok|ok" "$GOT"
else echo "  FAIL — TRIAGE-LOGIC marker extraction empty (drift)"; FAIL=$((FAIL+1)); fi

# ── CLAIM-LOGIC: claimFiles / clearClaims per-wave file-claim registry ───────────
if extract CLAIM; then
  printf '\nexport { claimFiles, clearClaims };\n' >> "$T/CLAIM.mjs"
  cat > "$T/CLAIM.test.mjs" <<'EOF'
import { claimFiles, clearClaims } from './CLAIM.mjs';
const out = [];
const claims = new Map();
// two tasks claiming non-overlapping files -> both ok
const r1 = claimFiles(claims, 1, ['a.js', 'b.js']);
out.push(r1.ok === true ? 'ok' : `BAD-first:${JSON.stringify(r1)}`);
const r2 = claimFiles(claims, 2, ['c.js', 'd.js']);
out.push(r2.ok === true ? 'ok' : `BAD-nonoverlap:${JSON.stringify(r2)}`);
// third task claims a file already owned by task 1 -> blocked
const r3 = claimFiles(claims, 3, ['b.js', 'e.js']);
out.push(r3.ok === false && r3.blocked_by === 1 && r3.conflicting_files.includes('b.js') ? 'ok' : `BAD-blocked:${JSON.stringify(r3)}`);
// clearClaims -> map is empty
clearClaims(claims);
out.push(claims.size === 0 ? 'ok' : `BAD-clear:size=${claims.size}`);
// after clear, same file is claimable again
const r4 = claimFiles(claims, 4, ['a.js']);
out.push(r4.ok === true ? 'ok' : `BAD-post-clear:${JSON.stringify(r4)}`);
console.log(out.join('|'));
EOF
  GOT=$(cd "$T" && node CLAIM.test.mjs 2>&1)
  ck "CLAIM claimFiles(non-overlap x2) + blocked + clearClaims + post-clear reclaim" "ok|ok|ok|ok|ok" "$GOT"
else echo "  FAIL — CLAIM-LOGIC marker extraction empty (drift)"; FAIL=$((FAIL+1)); fi

echo ""
echo "walteur-js-logic selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
