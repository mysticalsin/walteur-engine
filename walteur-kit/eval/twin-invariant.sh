#!/usr/bin/env bash
# WALTEUR twin-invariant — a DETERMINISTIC guard (NOT an LLM judge) that asserts the load-bearing twin
# invariants WALTEUR's two-distribution + twinned-doc posture depends on. A regression-catcher: it proves
# the identities that are CLAIMED today still hold, and reports drift the instant a copy diverges.
#
# It REPLACES the temporary inline md5 twin checks the v9.2 build put in walteur-kit/selftest.sh
# (run-trace.sh / confidentiality-gate.sh / skill-readiness.sh, marked "temporary until #7 twin-invariant.sh
# is built"). The registrar wires `twin-invariant.sh --selftest` into selftest.sh and removes those 3 lines.
#
# THREE invariants (check the load-bearing fact, NOT wording that legitimately varies):
#   A. DOC-TWIN byte-identity  — walteur/SKILL.md ≡ WALTEUR-builder-CLAUDE.md (cmp exit 0) where that
#      identity is CLAIMED. Both live in the SPEC repo; the claim is verified there. (md5 today: 120914 B.)
#   B. DISTRIBUTION-TWIN identity — for the declared [both] twin set, the file is byte-identical across the
#      two canonical trees. The set is DISCOVERED dynamically: every hook present in BOTH canonical
#      walteur-kit/hooks/ dirs, plus required-skills.json, every rubrics/*.md present in both, AND every
#      .claude/hooks/*.sh present in both (the CROSS-TREE runtime-hook surface — the harness contract that
#      ".claude/hooks stays byte-identical for hooks" applies here too, not just the walteur-kit distribution).
#      A file present in one tree but missing in the other is reported as MISSING drift (not a crash).
#   C. RUBRIC house-contract present — every rubrics/*.md carries its cite-or-VETO + file:line evidence
#      contract. Grepped as an INVARIANT (the contract PHRASE "VETO" + "file:line"), never exact wording —
#      rubric prose legitimately varies; the contract must not.
#
# HONEST CONTRACT (kit idiom):
#   * detect-or-LOUD-SKIP: if a tree/file the invariant needs is ABSENT, print a LOUD skip line to stderr
#     and continue scanning what IS present (recorded, NOT silent-green). A wholly-absent surface SKIPs.
#   * PROTOCOL by default in normal mode: real DRIFT prints a loud WARN and exits 0 (a report to READ;
#     warning-first, per the WALTEUR build law — a new guard ships exit-0 + loud WARN). Arm HARD blocking
#     with WALTEUR_TWIN=hard, in which case any drift/missing/contract-gap => exit 2.
#   * --selftest is ALWAYS hard: good twin (identical) => PASS; poisoned twin (a deliberately mutated copy
#     in a mktemp dir) MUST be CAUGHT => exit 2. A selftest that did not catch the poison is a FAIL.
#   * Kill switch: walteur-kit/PAUSED present => exit 2 (paused means not green).
#     Bypass: WALTEUR_TWIN=off => LOUD skip, exit 0.
#
# Zero-dep: bash + cmp + grep (md5 only for the report fingerprint, with md5sum fallback). No daemon, no
# index — graphify stays the one brain. Read-only over the trees; writes ONLY its report JSON.
#
# REPORT: walteur-kit/twin-invariant-report.json  (overwrite; the kit write_report idiom)
set -uo pipefail

# ── self-root ───────────────────────────────────────────────────────────────────
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/twin-invariant-report.json"
MODE="${WALTEUR_TWIN:-on}"
# SCOPE selects which twins count toward the HARD-mode blocking total.
#   all   (default) — every invariant (doc-twin + distribution/hook twins + rubric contracts) blocks.
#   hooks           — the DISTRIBUTION/HOOK twins block; the doc-twin (SKILL.md vs WALTEUR-builder-CLAUDE.md)
#                     is a KNOWN, intentionally-allowed drift, so its drift is still CHECKED + REPORTED (loud,
#                     in the report) but EXCLUDED from the blocking total. Used by gate-suite so live HOOK
#                     drift reds a ship while the allowed doc-twin drift does not permanently red the suite.
SCOPE="${WALTEUR_TWIN_SCOPE:-all}"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# md5 of a file (BSD `md5 -q` or GNU `md5sum`); empty string if absent/unreadable.
md5of() {
  [ -f "$1" ] || { printf ''; return; }
  if have md5; then md5 -q "$1" 2>/dev/null
  elif have md5sum; then md5sum "$1" 2>/dev/null | awk '{print $1}'
  else printf ''; fi
}

# ── kill switch + bypass (before any work) ───────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). twin-invariant exiting 2." >&2; exit 2; }
if [ "$MODE" = "off" ]; then
  echo "WALTEUR twin-invariant SKIP — bypass WALTEUR_TWIN=off (recorded, not silent-green)." >&2
  exit 0
fi

# ── the two canonical distribution roots (overridable; PORTABLE discovery, not macOS-hardcoded) ──
# S008 fix: the old defaults hardcoded absolute macOS home paths, so on Windows both trees were absent
# and the whole distribution-twin invariant silently note_skipped — unenforced. Now TREE_A defaults to this
# repo (the canonical Pro Coding tree) and TREE_B is DISCOVERED relative to it (the walteur-starter scaffold,
# a sibling or nested), so the canonical<->scaffold mirror is actually CHECKED on any OS. The original macOS
# dual-location path remains the last-resort fallback so existing macOS runs are unaffected. The hermetic
# selftest still overrides both via WALTEUR_TWIN_TREE_A/B. If no scaffold is found it honestly LOUD-SKIPs.
_twin_b_default=""
for _c in "$ROOT/../walteur-starter" "$ROOT/walteur-starter" "$ROOT/../../walteur-starter"; do
  [ -d "$_c" ] && { _twin_b_default="$(cd "$_c" 2>/dev/null && pwd)"; break; }
done
# 2026-07-25: the hardcoded macOS last-resort fallback was REMOVED. Two reasons, both load-bearing.
# (1) It leaked an absolute home path into a PUBLIC repo — one of 28 tracked files that did so.
# (2) Worse, it DEFEATED the honest LOUD-SKIP this block's own comment promises: on any checkout with
#     no sibling walteur-starter (e.g. a clone under ~/), discovery fails and the fallback silently
#     pointed the distribution-twin comparison at ONE SPECIFIC MACHINE's tree — so the invariant
#     looked like it ran while comparing against a tree outside the repo under test.
# Discovery above still covers sibling / nested / grandparent-sibling, i.e. the canonical layouts.
# If none is found, _twin_b_default stays empty and the existing detect-or-LOUD-SKIP path reports
# honestly instead of guessing. Override explicitly with WALTEUR_TWIN_TREE_B.
TREE_A="${WALTEUR_TWIN_TREE_A:-$ROOT}"
TREE_B="${WALTEUR_TWIN_TREE_B:-$_twin_b_default}"
# The SPEC repo is where the doc-twin (SKILL.md + WALTEUR-builder-CLAUDE.md) lives & is claimed identical.
SPEC_ROOT="${WALTEUR_TWIN_SPEC:-$ROOT}"

# ── accumulators (a finding == a load-bearing invariant that does NOT hold) ───────
DRIFT=0       # byte-identity claimed but broken (counts toward the blocking total)
MISSING=0     # a [both] member present in one tree, absent in the other
GAP=0         # a rubric missing its cite-or-VETO house-contract
DOC_DRIFT=0   # doc-twin drift recorded but EXCLUDED from the blocking total when SCOPE=hooks (allowed drift)
CHECKED=0     # invariants actually evaluated (a present surface)
SKIPPED=0     # surfaces absent => detect-or-LOUD-SKIP (recorded, not green)
declare -a FINDINGS=()

note_drift()   { DRIFT=$((DRIFT+1));     FINDINGS+=("DRIFT: $1"); echo "  DRIFT   — $1" >&2; }
note_missing() { MISSING=$((MISSING+1)); FINDINGS+=("MISSING: $1"); echo "  MISSING — $1" >&2; }
note_gap()     { GAP=$((GAP+1));         FINDINGS+=("CONTRACT-GAP: $1"); echo "  GAP     — $1" >&2; }
note_skip()    { SKIPPED=$((SKIPPED+1)); echo "  skip    — $1 (recorded, not silent-green)" >&2; }
note_ok()      { CHECKED=$((CHECKED+1)); echo "  ok      — $1" >&2; }
# doc-twin drift router: in SCOPE=hooks it's an ALLOWED-drift WARN (reported, not blocking); else a real DRIFT.
note_doc_drift() {
  if [ "$SCOPE" = "hooks" ]; then
    DOC_DRIFT=$((DOC_DRIFT+1)); FINDINGS+=("ALLOWED-DOC-DRIFT: $1")
    echo "  ALLOWED — $1 (doc-twin is a KNOWN allowed drift under SCOPE=hooks: reported, NOT blocking)" >&2
  else
    note_drift "$1"
  fi
}

# ── INVARIANT A — doc-twin byte-identity where CLAIMED ───────────────────────────
# SKILL.md ≡ WALTEUR-builder-CLAUDE.md. cmp is the load-bearing check; identity must be exact (it is the
# whole point of the twin). Only evaluated where BOTH files exist (the claim's surface = the SPEC repo).
check_doc_twin() {
  local a="$SPEC_ROOT/walteur/SKILL.md"
  local b="$SPEC_ROOT/WALTEUR-builder-CLAUDE.md"
  if [ ! -f "$a" ] || [ ! -f "$b" ]; then
    note_skip "doc-twin (SKILL.md / WALTEUR-builder-CLAUDE.md not both present under $SPEC_ROOT)"
    return
  fi
  if cmp -s "$a" "$b"; then
    note_ok "doc-twin byte-identical: walteur/SKILL.md ≡ WALTEUR-builder-CLAUDE.md ($(md5of "$a"))"
  else
    note_doc_drift "doc-twin BROKEN: walteur/SKILL.md != WALTEUR-builder-CLAUDE.md (cmp non-zero) — re-sync the twin"
  fi
}

# ── INVARIANT B — distribution-twin identity across the two canonical trees ───────
# Discover the [both] set dynamically: union of (hooks in BOTH hooks/ dirs) + required-skills.json + every
# rubrics/*.md in both + every .claude/hooks/*.sh in both. For each, cmp A vs B. Present-in-one-only =>
# MISSING drift, never a crash.
check_distribution_twins() {
  if [ ! -d "$TREE_A" ] || [ ! -d "$TREE_B" ]; then
    note_skip "distribution-twins (a canonical tree is absent: A=$([ -d "$TREE_A" ] && echo y || echo n) B=$([ -d "$TREE_B" ] && echo y || echo n))"
    return
  fi
  local KA="$TREE_A/walteur-kit" KB="$TREE_B/walteur-kit"

  # --- hooks: every basename that appears in EITHER hooks/ dir is a twin obligation ---
  if [ -d "$KA/hooks" ] && [ -d "$KB/hooks" ]; then
    local names
    names="$( { ls "$KA/hooks" 2>/dev/null; ls "$KB/hooks" 2>/dev/null; } | sort -u )"
    local h
    while IFS= read -r h; do
      [ -z "$h" ] && continue
      case "$h" in *.sh) : ;; *) continue ;; esac   # twin obligation is the shell hooks
      local fa="$KA/hooks/$h" fb="$KB/hooks/$h"
      if [ -f "$fa" ] && [ -f "$fb" ]; then
        if cmp -s "$fa" "$fb"; then note_ok "hook twin identical: $h"
        else note_drift "hook twin DRIFT across distributions: hooks/$h (A != B)"; fi
      elif [ -f "$fa" ]; then note_missing "hooks/$h present in A, ABSENT in B"
      else note_missing "hooks/$h present in B, ABSENT in A"; fi
    done <<EOF
$names
EOF
  else
    note_skip "hook twins (a hooks/ dir is absent under one tree)"
  fi

  # --- required-skills.json ---
  local rsa="$KA/required-skills.json" rsb="$KB/required-skills.json"
  if [ -f "$rsa" ] && [ -f "$rsb" ]; then
    if cmp -s "$rsa" "$rsb"; then note_ok "required-skills.json twin identical"
    else note_drift "required-skills.json DRIFT across distributions (A != B)"; fi
  elif [ -f "$rsa" ] || [ -f "$rsb" ]; then
    note_missing "required-skills.json present in one tree only (A:$([ -f "$rsa" ] && echo y || echo n) B:$([ -f "$rsb" ] && echo y || echo n))"
  else
    note_skip "required-skills.json (absent in both trees)"
  fi

  # --- rubrics/*.md byte-identity across distributions ---
  if [ -d "$KA/rubrics" ] && [ -d "$KB/rubrics" ]; then
    local rnames
    rnames="$( { ls "$KA/rubrics" 2>/dev/null; ls "$KB/rubrics" 2>/dev/null; } | grep -E '\.md$' | sort -u )"
    local r
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      local ra="$KA/rubrics/$r" rb="$KB/rubrics/$r"
      if [ -f "$ra" ] && [ -f "$rb" ]; then
        if cmp -s "$ra" "$rb"; then note_ok "rubric twin identical: rubrics/$r"
        else note_drift "rubric twin DRIFT across distributions: rubrics/$r (A != B)"; fi
      elif [ -f "$ra" ]; then note_missing "rubrics/$r present in A, ABSENT in B"
      else note_missing "rubrics/$r present in B, ABSENT in A"; fi
    done <<EOF
$rnames
EOF
  fi

  # --- .claude/hooks/*.sh byte-identity across distributions (the CROSS-TREE surface: the harness
  #     contract is that the runtime .claude/hooks copies must stay byte-identical for hooks too, not just
  #     the walteur-kit/hooks distribution set). Root-level .claude/hooks, NOT under walteur-kit/. Same
  #     cmp/note_drift/note_missing pattern as the kit-hooks loop above. ---
  local CA="$TREE_A/.claude/hooks" CB="$TREE_B/.claude/hooks"
  if [ -d "$CA" ] && [ -d "$CB" ]; then
    local cnames
    cnames="$( { ls "$CA" 2>/dev/null; ls "$CB" 2>/dev/null; } | sort -u )"
    local c
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      case "$c" in *.sh) : ;; *) continue ;; esac   # twin obligation is the shell hooks
      local fca="$CA/$c" fcb="$CB/$c"
      if [ -f "$fca" ] && [ -f "$fcb" ]; then
        if cmp -s "$fca" "$fcb"; then note_ok ".claude/hooks twin identical: $c"
        else note_drift ".claude/hooks twin DRIFT across distributions: .claude/hooks/$c (A != B)"; fi
      elif [ -f "$fca" ]; then note_missing ".claude/hooks/$c present in A, ABSENT in B"
      else note_missing ".claude/hooks/$c present in B, ABSENT in A"; fi
    done <<EOF
$cnames
EOF
  else
    note_skip ".claude/hooks twins (a .claude/hooks dir is absent under one tree)"
  fi
}

# ── INVARIANT C — every rubric carries its cite-or-VETO + file:line house-contract ─
# Check the INVARIANT (the contract is present), not the exact prose. A rubric without its evidence law is a
# rubber-stampable rubric — the load-bearing failure this catches. Scanned in TREE_A (the rubrics' home).
check_rubric_contracts() {
  local RB="$TREE_A/walteur-kit/rubrics"
  [ -d "$RB" ] || RB="$SPEC_ROOT/walteur-kit/rubrics"
  if [ ! -d "$RB" ]; then
    note_skip "rubric house-contracts (no rubrics/ dir found in TREE_A or SPEC_ROOT)"
    return
  fi
  local found=0 f
  for f in "$RB"/*.md; do
    [ -f "$f" ] || continue
    found=$((found+1))
    # contract = the cite-or-VETO evidence law: a VETO posture AND a file:line evidence requirement.
    if grep -qiE 'VETO' "$f" && grep -q 'file:line' "$f"; then
      note_ok "rubric house-contract present: $(basename "$f") (cite-or-VETO + file:line)"
    else
      note_gap "rubric MISSING cite-or-VETO house-contract: $(basename "$f") (no VETO+file:line evidence law)"
    fi
  done
  [ "$found" -eq 0 ] && note_skip "rubric house-contracts (rubrics/ dir present but holds no .md)"
}

# ── write_report (kit idiom) ─────────────────────────────────────────────────────
write_report() {
  local verdict="$1"
  local findings_json="["
  local first=1 x
  for x in "${FINDINGS[@]:-}"; do
    [ -z "$x" ] && continue
    # JSON-escape backslash and double-quote.
    local e="${x//\\/\\\\}"; e="${e//\"/\\\"}"
    if [ "$first" -eq 1 ]; then findings_json="$findings_json\"$e\""; first=0
    else findings_json="$findings_json,\"$e\""; fi
  done
  findings_json="$findings_json]"
  if have jq; then
    jq -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg verdict "$verdict" \
      --arg mode "$MODE" \
      --arg scope "$SCOPE" \
      --argjson checked "$CHECKED" --argjson skipped "$SKIPPED" \
      --argjson drift "$DRIFT" --argjson missing "$MISSING" --argjson gap "$GAP" \
      --argjson docdrift "$DOC_DRIFT" \
      --argjson findings "$findings_json" \
      '{tool:"twin-invariant", ts:$ts, verdict:$verdict, mode:$mode, scope:$scope,
        checked:$checked, skipped:$skipped,
        drift:$drift, missing:$missing, contract_gap:$gap, doc_drift_allowed:$docdrift, findings:$findings}' > "$REPORT"
  else
    printf '{"tool":"twin-invariant","ts":"%s","verdict":"%s","mode":"%s","scope":"%s","checked":%s,"skipped":%s,"drift":%s,"missing":%s,"contract_gap":%s,"doc_drift_allowed":%s,"findings":%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$verdict" "$MODE" "$SCOPE" "$CHECKED" "$SKIPPED" "$DRIFT" "$MISSING" "$GAP" "$DOC_DRIFT" "$findings_json" > "$REPORT"
  fi
}

# ── normal run ───────────────────────────────────────────────────────────────────
run_normal() {
  echo "WALTEUR twin-invariant — asserting twin invariants (mode=$MODE)" >&2
  echo "  doc-twin SPEC:  $SPEC_ROOT" >&2
  echo "  dist tree A:    $TREE_A" >&2
  echo "  dist tree B:    $TREE_B" >&2
  check_doc_twin
  check_distribution_twins
  check_rubric_contracts

  # The BLOCKING total excludes DOC_DRIFT: when SCOPE=hooks the doc-twin is a KNOWN allowed drift, so it is
  # reported (DOC_DRIFT>0, findings carry an ALLOWED-DOC-DRIFT line) but never reds the run.
  local total_findings=$((DRIFT+MISSING+GAP))
  echo "" >&2
  echo "twin-invariant: checked=$CHECKED skipped=$SKIPPED | drift=$DRIFT missing=$MISSING contract_gap=$GAP doc_drift_allowed=$DOC_DRIFT (scope=$SCOPE)" >&2

  if [ "$total_findings" -eq 0 ]; then
    write_report "PASS"
    if [ "$DOC_DRIFT" -gt 0 ]; then
      echo "twin-invariant: PASS — HOOK/distribution twins hold; doc-twin drift ($DOC_DRIFT) is the KNOWN allowed exception (reported, not blocking) ($CHECKED checked, $SKIPPED skipped)." >&2
    else
      echo "twin-invariant: PASS — all evaluated twin invariants hold ($CHECKED checked, $SKIPPED skipped)." >&2
    fi
    return 0
  fi

  # Findings exist. Warning-first by default (exit 0 + loud WARN); HARD only when explicitly armed.
  write_report "DRIFT"
  if [ "$MODE" = "hard" ]; then
    echo "twin-invariant: FAIL (WALTEUR_TWIN=hard) — $total_findings twin-invariant violation(s). exit 2." >&2
    return 2
  fi
  echo "WALTEUR twin-invariant WARN — $total_findings twin-invariant violation(s) found (report: $REPORT)." >&2
  echo "  warning-first: exit 0 by default. Arm HARD blocking with WALTEUR_TWIN=hard." >&2
  return 0
}

# ── HERMETIC self-test — good twin PASSES, poisoned twin is CAUGHT (exit 2) ───────
# Builds throwaway twin trees in mktemp, runs the SAME invariants against them via a recursive `bash $SELF`
# with the tree roots redirected. Good twins are byte-identical => PASS; the poisoned twin mutates ONE file
# so the identity breaks => the recursive run under WALTEUR_TWIN=hard MUST exit 2 (the poison is caught).
selftest() {
  local fails=0 total=0
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/twin-inv-selftest.XXXXXX")" || { echo "  FAIL — mktemp"; exit 1; }
  trap 'rm -rf "$tmp"' RETURN

  ck() { # $1=label $2=cond(0=pass)
    total=$((total+1))
    if [ "$2" -eq 0 ]; then echo "  ok   — $1"; else echo "  FAIL — $1"; fails=$((fails+1)); fi
  }

  echo "twin-invariant selftest:"

  # --- build a GOOD twin world: spec + two identical canonical trees ---
  local spec="$tmp/spec" ta="$tmp/treeA" tb="$tmp/treeB"
  mkdir -p "$spec/walteur" "$spec/walteur-kit/rubrics"
  mkdir -p "$ta/walteur-kit/hooks" "$ta/walteur-kit/rubrics" "$ta/.claude/hooks"
  mkdir -p "$tb/walteur-kit/hooks" "$tb/walteur-kit/rubrics" "$tb/.claude/hooks"

  # doc-twin: SKILL.md ≡ WALTEUR-builder-CLAUDE.md (byte-identical)
  printf 'WALTEUR builder skill body — line one\nline two\n' > "$spec/walteur/SKILL.md"
  cp -p "$spec/walteur/SKILL.md" "$spec/WALTEUR-builder-CLAUDE.md"

  # distribution-twins: a hook + required-skills.json + a rubric, identical across A and B
  printf '#!/usr/bin/env bash\necho compliance\n' > "$ta/walteur-kit/hooks/compliance-gate.sh"
  cp -p "$ta/walteur-kit/hooks/compliance-gate.sh" "$tb/walteur-kit/hooks/compliance-gate.sh"
  printf '{"required":["org-confidentiality-guard"]}\n' > "$ta/walteur-kit/required-skills.json"
  cp -p "$ta/walteur-kit/required-skills.json" "$tb/walteur-kit/required-skills.json"
  # a rubric WITH the cite-or-VETO + file:line house-contract
  printf 'Evidence law: no file:line cited => automatic VETO. Rubber-stamping impossible.\n' \
    > "$ta/walteur-kit/rubrics/senior-api.md"
  cp -p "$ta/walteur-kit/rubrics/senior-api.md" "$tb/walteur-kit/rubrics/senior-api.md"
  # a .claude/hooks runtime hook, identical across A and B (the CROSS-TREE surface under test)
  printf '#!/usr/bin/env bash\necho ship-gate\n' > "$ta/.claude/hooks/ship-gate.sh"
  cp -p "$ta/.claude/hooks/ship-gate.sh" "$tb/.claude/hooks/ship-gate.sh"

  # (1) GOOD twin world => PASS, exit 0 (even under hard mode — nothing is broken).
  WALTEUR_ROOT="$tmp" WALTEUR_TWIN=hard \
    WALTEUR_TWIN_SPEC="$spec" WALTEUR_TWIN_TREE_A="$ta" WALTEUR_TWIN_TREE_B="$tb" \
    bash "$SELF" >/dev/null 2>&1
  ck "GOOD twin world passes (exit 0 under hard mode)" "$?"

  # the good-world report must record PASS with zero findings
  if have jq; then
    local gv; gv="$(jq -r '.verdict' "$tmp/walteur-kit/twin-invariant-report.json" 2>/dev/null)"
    ck "GOOD world report verdict=PASS" "$([ "$gv" = "PASS" ] && echo 0 || echo 1)"
    local gd; gd="$(jq -r '(.drift+.missing+.contract_gap)' "$tmp/walteur-kit/twin-invariant-report.json" 2>/dev/null)"
    ck "GOOD world report has zero findings" "$([ "$gd" = "0" ] && echo 0 || echo 1)"
  fi

  # --- POISON 1: break the doc-twin (mutate WALTEUR-builder-CLAUDE.md so it != SKILL.md) ---
  local pa="$tmp/poisonA"; cp -R "$spec" "$pa-spec"; cp -R "$ta" "$pa-A"; cp -R "$tb" "$pa-B"
  printf 'POISONED — doc-twin no longer matches SKILL.md\n' >> "$pa-spec/WALTEUR-builder-CLAUDE.md"
  WALTEUR_ROOT="$tmp" WALTEUR_TWIN=hard \
    WALTEUR_TWIN_SPEC="$pa-spec" WALTEUR_TWIN_TREE_A="$pa-A" WALTEUR_TWIN_TREE_B="$pa-B" \
    bash "$SELF" >/dev/null 2>&1
  ck "POISON (doc-twin broken) is CAUGHT — exit 2 under hard mode" "$([ "$?" -eq 2 ] && echo 0 || echo 1)"

  # --- POISON 2: break a distribution-twin (mutate the hook in tree B only) ---
  local pb="$tmp/poisonB"; cp -R "$spec" "$pb-spec"; cp -R "$ta" "$pb-A"; cp -R "$tb" "$pb-B"
  printf '\n# drift injected into B only\n' >> "$pb-B/walteur-kit/hooks/compliance-gate.sh"
  WALTEUR_ROOT="$tmp" WALTEUR_TWIN=hard \
    WALTEUR_TWIN_SPEC="$pb-spec" WALTEUR_TWIN_TREE_A="$pb-A" WALTEUR_TWIN_TREE_B="$pb-B" \
    bash "$SELF" >/dev/null 2>&1
  ck "POISON (hook drift A!=B) is CAUGHT — exit 2 under hard mode" "$([ "$?" -eq 2 ] && echo 0 || echo 1)"

  # --- POISON 3: a [both] member present in A but MISSING in B ---
  local pc="$tmp/poisonC"; cp -R "$spec" "$pc-spec"; cp -R "$ta" "$pc-A"; cp -R "$tb" "$pc-B"
  rm -f "$pc-B/walteur-kit/hooks/compliance-gate.sh"
  WALTEUR_ROOT="$tmp" WALTEUR_TWIN=hard \
    WALTEUR_TWIN_SPEC="$pc-spec" WALTEUR_TWIN_TREE_A="$pc-A" WALTEUR_TWIN_TREE_B="$pc-B" \
    bash "$SELF" >/dev/null 2>&1
  ck "POISON (twin member missing in B) is CAUGHT — exit 2 under hard mode" "$([ "$?" -eq 2 ] && echo 0 || echo 1)"

  # --- POISON 4: a rubric STRIPPED of its cite-or-VETO house-contract ---
  local pd="$tmp/poisonD"; cp -R "$spec" "$pd-spec"; cp -R "$ta" "$pd-A"; cp -R "$tb" "$pd-B"
  printf 'A rubric with no evidence law and no veto posture at all.\n' \
    > "$pd-A/walteur-kit/rubrics/senior-api.md"
  cp -p "$pd-A/walteur-kit/rubrics/senior-api.md" "$pd-B/walteur-kit/rubrics/senior-api.md"
  WALTEUR_ROOT="$tmp" WALTEUR_TWIN=hard \
    WALTEUR_TWIN_SPEC="$pd-spec" WALTEUR_TWIN_TREE_A="$pd-A" WALTEUR_TWIN_TREE_B="$pd-B" \
    bash "$SELF" >/dev/null 2>&1
  ck "POISON (rubric stripped of cite-or-VETO contract) is CAUGHT — exit 2 under hard mode" "$([ "$?" -eq 2 ] && echo 0 || echo 1)"

  # --- POISON 5: break the CROSS-TREE .claude/hooks surface (mutate the runtime hook in tree B only) ---
  local pe="$tmp/poisonE"; cp -R "$spec" "$pe-spec"; cp -R "$ta" "$pe-A"; cp -R "$tb" "$pe-B"
  printf '\n# drift injected into .claude/hooks B only\n' >> "$pe-B/.claude/hooks/ship-gate.sh"
  WALTEUR_ROOT="$tmp" WALTEUR_TWIN=hard \
    WALTEUR_TWIN_SPEC="$pe-spec" WALTEUR_TWIN_TREE_A="$pe-A" WALTEUR_TWIN_TREE_B="$pe-B" \
    bash "$SELF" >/dev/null 2>&1
  ck "POISON (.claude/hooks twin drift A!=B) is CAUGHT — exit 2 under hard mode" "$([ "$?" -eq 2 ] && echo 0 || echo 1)"

  # --- SCOPE=hooks ALLOWED-DOC-DRIFT: doc-twin-only drift under hard+scope=hooks must PASS (exit 0) and the
  #     report must record it as an allowed drift (doc_drift_allowed>0, verdict PASS, blocking drift==0). The
  #     doc-twin is a KNOWN intentionally-allowed drift, so it must NOT red a scope=hooks run. (pa-* = doc poison)
  WALTEUR_ROOT="$tmp" WALTEUR_TWIN=hard WALTEUR_TWIN_SCOPE=hooks \
    WALTEUR_TWIN_SPEC="$pa-spec" WALTEUR_TWIN_TREE_A="$pa-A" WALTEUR_TWIN_TREE_B="$pa-B" \
    bash "$SELF" >/dev/null 2>&1
  ck "SCOPE=hooks: doc-twin-only drift PASSES (exit 0; allowed exception, not blocking)" "$([ "$?" -eq 0 ] && echo 0 || echo 1)"
  if have jq; then
    local sv; sv="$(jq -r '.verdict' "$tmp/walteur-kit/twin-invariant-report.json" 2>/dev/null)"
    ck "SCOPE=hooks doc-drift report verdict=PASS" "$([ "$sv" = "PASS" ] && echo 0 || echo 1)"
    local sd; sd="$(jq -r '(.drift+.missing+.contract_gap)' "$tmp/walteur-kit/twin-invariant-report.json" 2>/dev/null)"
    ck "SCOPE=hooks doc-drift report has zero BLOCKING findings" "$([ "$sd" = "0" ] && echo 0 || echo 1)"
    local sa; sa="$(jq -r '.doc_drift_allowed' "$tmp/walteur-kit/twin-invariant-report.json" 2>/dev/null)"
    ck "SCOPE=hooks doc-drift report records doc_drift_allowed=1 (reported, not silent)" "$([ "$sa" = "1" ] && echo 0 || echo 1)"
  fi

  # --- SCOPE=hooks HOOK drift STILL BLOCKS: a real hook drift under hard+scope=hooks must FAIL (exit 2).
  #     Scoping out the doc-twin must NOT weaken the hook-twin guard — live HOOK drift still reds the run. (pb-* = hook poison)
  WALTEUR_ROOT="$tmp" WALTEUR_TWIN=hard WALTEUR_TWIN_SCOPE=hooks \
    WALTEUR_TWIN_SPEC="$pb-spec" WALTEUR_TWIN_TREE_A="$pb-A" WALTEUR_TWIN_TREE_B="$pb-B" \
    bash "$SELF" >/dev/null 2>&1
  ck "SCOPE=hooks: HOOK drift is STILL CAUGHT (exit 2; scoping doc-twin out does not weaken hook guard)" "$([ "$?" -eq 2 ] && echo 0 || echo 1)"

  # --- SCOPE=hooks .claude/hooks drift STILL BLOCKS: the CROSS-TREE surface is not carved out either. (pe-* = .claude/hooks poison)
  WALTEUR_ROOT="$tmp" WALTEUR_TWIN=hard WALTEUR_TWIN_SCOPE=hooks \
    WALTEUR_TWIN_SPEC="$pe-spec" WALTEUR_TWIN_TREE_A="$pe-A" WALTEUR_TWIN_TREE_B="$pe-B" \
    bash "$SELF" >/dev/null 2>&1
  ck "SCOPE=hooks: .claude/hooks drift is STILL CAUGHT (exit 2; cross-tree surface not carved out)" "$([ "$?" -eq 2 ] && echo 0 || echo 1)"

  # (6) WARNING-FIRST default: the SAME doc-twin poison in DEFAULT mode WARNs but exits 0 (build law).
  WALTEUR_ROOT="$tmp" WALTEUR_TWIN=on \
    WALTEUR_TWIN_SPEC="$pa-spec" WALTEUR_TWIN_TREE_A="$pa-A" WALTEUR_TWIN_TREE_B="$pa-B" \
    bash "$SELF" >/dev/null 2>&1
  ck "warning-first: drift in DEFAULT mode WARNs but exits 0 (not blocking by default)" "$([ "$?" -eq 0 ] && echo 0 || echo 1)"

  # (7) PAUSED kill switch => exit 2
  mkdir -p "$tmp/walteur-kit"; : > "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" WALTEUR_TWIN=on \
    WALTEUR_TWIN_SPEC="$spec" WALTEUR_TWIN_TREE_A="$ta" WALTEUR_TWIN_TREE_B="$tb" \
    bash "$SELF" >/dev/null 2>&1
  ck "PAUSED kill switch => exit 2" "$([ "$?" -eq 2 ] && echo 0 || echo 1)"
  rm -f "$tmp/walteur-kit/PAUSED"

  # (8) gate-suite SHIM selftest is green — twin-invariant is the cross-tree/twin guard family, and the
  #     shim (.claude/hooks/gate-suite.sh) is its closest sibling contract (fail-closed-if-canonical-absent).
  #     Wire the assertion here so a shim regression is caught by the SAME suite that guards twin drift.
  #     Located relative to $SELF (walteur-kit/eval/twin-invariant.sh -> repo root is two levels up), never
  #     via ROOT/cwd, so this stays hermetic regardless of invocation directory.
  local self_repo="$(cd "$(dirname "$SELF")/../.." 2>/dev/null && pwd)"
  local shim="$self_repo/.claude/hooks/gate-suite.sh"
  if [ -f "$shim" ]; then
    local shim_out shim_rc
    shim_out="$(bash "$shim" --selftest 2>&1)"; shim_rc=$?
    local shim_line; shim_line="$(printf '%s' "$shim_out" | grep -oiE 'shim selftest: [0-9]+/[0-9]+ passed' | tail -1)"
    if [ -n "$shim_line" ]; then
      local shim_num shim_den; shim_num="$(printf '%s' "$shim_line" | grep -oE '[0-9]+' | sed -n 1p)"; shim_den="$(printf '%s' "$shim_line" | grep -oE '[0-9]+' | sed -n 2p)"
      ck "gate-suite shim selftest is green ($shim_line)" "$([ "$shim_num" = "$shim_den" ] && [ -n "$shim_num" ] && echo 0 || echo 1)"
    else
      ck "gate-suite shim selftest is green (shim selftest: N/N passed line found)" 1
    fi
  else
    note_skip "gate-suite shim selftest (shim absent at $shim)"
  fi

  echo "twin-invariant selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

# ── dispatch ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --selftest) selftest; exit $? ;;
  -h|--help)  sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")         run_normal; exit $? ;;
  *)          echo "twin-invariant: unknown arg '$1' (try --selftest or no-arg normal run)." >&2; exit 1 ;;
esac
