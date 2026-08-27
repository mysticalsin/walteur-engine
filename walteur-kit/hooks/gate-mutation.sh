#!/usr/bin/env bash
# walteur-apex gate-mutation — mutation testing applied to the CHECKER, not the code under test.
#
# THE TECHNIQUE, AND WHY IT IS THE RIGHT ONE. Published work on evaluating static analysers converges
# on mutating the ANALYSER and asking whether its own test corpus notices:
#   - StaAgent (mutate the rule, compare seed vs mutant verdicts) surfaced 64 genuine rule defects in
#     the LATEST versions of five heavily-used analysers, 28 of them in SpotBugs.
#   - muSE found 25 design flaws across major security static analysers, 13 in FlowDroid alone.
#   - SecMutBench showed a naive mutation score OVERSTATES security-detection quality unless kills are
#     classified by reason.
# A fixture COUNT says nothing about fixture QUALITY. This measures quality directly: if a gate can be
# broken without any fixture noticing, that fixture set is decorative for that failure mode.
#
# It is also the manual experiment in experiment/RESULTS.md turned into a repeatable tool. That
# experiment hand-injected one regression into one gate and reported the result; adversarial review
# correctly noted the outcome was determined by which gate was chosen. This removes the choosing.
#
# MUTATION OPERATORS (deterministic, source-level, always reverted):
#   M1 blind      every `exit 2` -> `exit 0`            — the canonical "gate went blind"
#   M2 cmp-flip   -lt<->-ge, -gt<->-le                  — inverted threshold logic
#   M3 boundary   -gt->-ge, -lt->-le                    — off-by-one at the threshold
#   M4 denegate   `[ ! ` -> `[ `                        — dropped negation in a guard
#   M5 unexclude  drop `--exclude-dir=<x>` from greps    — widened/narrowed scan scope
#
# THE NULL-MUTANT CONTROL (runs first, never scored). Before any operator's verdict is believed, a
# semantically-null mutant — the gate plus one trailing comment — must reproduce the gate's own
# baseline exactly. If it does not, the verdicts are about the harness, not the mutation: the gate is
# excluded from the score and the run exits 2. This is not defensive decoration. Both defects that
# forced a public retraction of this tool's first numbers (mutants staged outside the hooks dir, so
# sibling sourcing broke; a CR-sensitive no-op guard that skipped nothing) would have been caught on
# the first run by this single control. A mutation figure published without it is not trustworthy.
#
# HOW TO READ THE SCORE — three published counterweights, stated up front rather than buried:
#   1. Mutation score is a RANKING SIGNAL, NOT A KPI. ICSE 2018 (Defects4J + CoreBench) found the
#      correlation between mutation score and real-fault detection falls to 0.05-0.20 once test-suite
#      SIZE is controlled for. Use this to compare fixture sets and to find SURVIVORS; do not chase
#      the percentage, and do not add fixtures purely to move it.
#   2. Synthetic fixtures OVERSTATE a checker's power — the realism gap. ISSTA 2022 found
#      state-of-the-art static analysers miss 47-80% of vulnerabilities in benchmarks built from real
#      programs, despite performing well on synthetic corpora. A high kill rate here is evidence about
#      these fixtures, not proof the gates work on real repositories.
#   3. Kills should be classified by REASON (SecMutBench): a naive score overstates detection quality.
#      This tool reports which operator survived per gate, which is the classification that matters
#      operationally; it does not yet classify why a kill happened.
# The actionable output is therefore the SURVIVOR LIST, not the number.
#
# KILLED = at least one of the gate's fixtures changed verdict (a poisoned twin stopped failing, or a
# clean twin started failing). SURVIVED = every fixture behaved identically => the fixtures cannot see
# that class of breakage. Mutants that break the script outright (syntax or fail-to-run) are reported separately
# as INVALID and excluded from the score, so a broken mutant never inflates the kill rate.
#
# CONTRACT: score computed => exit 0 · below --min => exit 2 · jq/bash absent => exit 2
#           no manifest => NOT_APPLICABLE exit 0 · PAUSED => exit 2 · bypass WALTEUR_GATEMUT=off
# Report: walteur-kit/eval-harness/gate-mutation-report.json
#
# --help: self-documentation BEFORE any side effect
case "${1:-}" in
  -h|--help)
    printf '%s\n' "gate-mutation - mutation testing of the GATES; measures whether fixtures kill a broken gate."
    printf '%s\n' "usage: bash gate-mutation.sh [--gate <hook.sh>] [--min N] [--selftest|--help]"
    printf '%s\n' "  --gate  restrict to one gate (default: every gate with a poisoned fixture)"
    printf '%s\n' "  --min N fail (exit 2) if the mutation kill rate is below N percent"
    printf '%s\n' "report: walteur-kit/eval-harness/gate-mutation-report.json"
    printf '%s\n' "bypass: WALTEUR_GATEMUT=off (recorded, not free)"
    exit 0 ;;
esac

set -uo pipefail
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
have() { command -v "$1" >/dev/null 2>&1; }
jqr() { jq -r "$@" 2>/dev/null | tr -d '\r'; }

# Emit a mutated copy of $1 into $2 under operator $3. Returns 1 if the operator did not apply
# (nothing to mutate) so the caller can skip it rather than scoring a no-op mutant.
mutate() {
  local src="$1" dst="$2" op="$3"
  case "$op" in
    blind)     sed -E 's/\bexit 2\b/exit 0/g' "$src" > "$dst" ;;
    cmp-flip)  sed -E 's/ -lt / -XTMPX /g; s/ -ge / -lt /g; s/ -XTMPX / -ge /g; s/ -gt / -YTMPY /g; s/ -le / -gt /g; s/ -YTMPY / -le /g' "$src" > "$dst" ;;
    boundary)  sed -E 's/ -gt / -ge /g; s/ -lt / -le /g' "$src" > "$dst" ;;
    denegate)  sed -E 's/\[ ! /[ /g' "$src" > "$dst" ;;
    unexclude) sed -E 's/--exclude-dir=[A-Za-z0-9_.-]+//g' "$src" > "$dst" ;;
    # NULL — the control operator. Appends a comment line: syntactically different, semantically
    # identical. It is never scored. Its only job is to prove the HARNESS is sound before any real
    # operator's verdict is believed. Two prior defects (mutants staged in mktemp -d so sibling
    # sourcing broke; a dead CR-sensitive no-op guard) both produced verdicts that had nothing to do
    # with the mutation, and both would have been caught on the first run by this one control.
    null)      cat "$src" > "$dst"; printf '\n# gatemut-null-control\n' >> "$dst" ;;
    *) return 1 ;;
  esac
  # No-op mutants are not evidence of anything — skip them.
  # MUST compare CR-INSENSITIVELY. GNU sed strips CR from CRLF input, and every gate in this framework
  # is CRLF, so a plain `cmp -s` found EVERY mutant "different" even when the operator matched nothing.
  # Nothing was ever skipped: all 15 gates scored exactly 5 mutants, ~39 of which were the unmodified
  # gate with LF endings, counted as SURVIVORS. That single defect manufactured the "systematic blind
  # spot" this tool reported — 10 of 12 unexclude survivors were gates with no --exclude-dir at all.
  # Fourth time CRLF has corrupted a measurement in this repo; see playbook win-jq-defender-crlf.
  diff -q --strip-trailing-cr "$src" "$dst" >/dev/null 2>&1 && return 1
  # A mutant that will not even parse tells us nothing about the fixtures.
  bash -n "$dst" 2>/dev/null || return 2
  return 0
}

main() {
  local ONLY="" MIN=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --gate) ONLY="${2:-}"; shift 2 ;;
      --min)  MIN="${2:-0}"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$MIN" in ''|*[!0-9]*) MIN=0 ;; esac

  local ROOT KIT EH MAN HOOKS REPORT TS
  ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  KIT="$ROOT/walteur-kit"; EH="$KIT/eval-harness"; HOOKS="$KIT/hooks"
  MAN="$EH/manifest.json"; REPORT="$EH/gate-mutation-report.json"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  [ -f "$KIT/PAUSED" ] && { echo "gate-mutation: PAUSED -> exit 2" >&2; exit 2; }
  [ "${WALTEUR_GATEMUT:-on}" = "off" ] && { echo "gate-mutation: bypassed" >&2; exit 0; }
  [ -f "$MAN" ] || { echo "gate-mutation: NOT_APPLICABLE (no eval-harness manifest)"; exit 0; }
  have jq || { echo "gate-mutation: FAIL - jq absent; cannot measure (fail-closed)" >&2; exit 2; }
  # A corrupt manifest previously yielded "0% kill rate (0 killed, 0 survived) across 0 gates" and
  # exit 0 — unmeasured reported as a clean run, the same fail-open this tool exists to detect in
  # other checkers. Cannot-measure and measured-clean must never share an exit code.
  jq -e . "$MAN" >/dev/null 2>&1 || { echo "gate-mutation: FAIL - manifest is not valid JSON; cannot measure (fail-closed)" >&2; exit 2; }

  # Mutants are written INTO the hooks dir (so sibling sourcing works) and must never outlive the run.
  # A killed run left four .gatemut-* files behind, and a stray executable in a hooks directory is a
  # hazard: the gate suite enumerates that directory. Clean on ANY exit, including interrupt.
  cleanup_mutants() { rm -f "$HOOKS"/.gatemut-* 2>/dev/null || true; }
  trap cleanup_mutants EXIT INT TERM
  cleanup_mutants   # also clear anything a previous killed run orphaned

  local OPS="blind cmp-flip boundary denegate unexclude"
  local rows='[]' killed=0 survived=0 invalid=0 controls_failed=0 control_names=""

  # Run every fixture for a gate against a given gate script; echo "fx:rc" lines.
  observe() {
    local gscript="$1" gate="$2"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      local fx="${line%%|*}" want="${line##*|}"
      local d="$EH/fixtures/$fx"; [ -d "$d" ] || continue
      local t; t="$(mktemp -d)"; cp -R "$d/." "$t"/ 2>/dev/null
      WALTEUR_ROOT="$t" timeout 120 bash "$gscript" >/dev/null 2>&1
      echo "$fx:$?"
      rm -rf "$t"
    done < <(jqr --arg g "$gate" '.[] | select(.gate==$g) | .fixture + "|" + .expect' "$MAN")
  }

  while IFS= read -r gate; do
    [ -n "$gate" ] || continue
    [ -n "$ONLY" ] && [ "$gate" != "$ONLY" ] && continue
    local gpath="$HOOKS/$gate"; [ -f "$gpath" ] || continue

    # Baseline behaviour of the REAL gate across its fixtures.
    local base; base="$(observe "$gpath" "$gate")"
    [ -z "$base" ] && continue

    local gk=0 gs=0 survivors=""
    # Mutants MUST live in the hooks dir, not a temp dir. Gates source sibling helpers via
    # "${SELF%/*}/_probe-proof.sh"; running a mutant from mktemp -d broke that sourcing, so those gates
    # failed closed on EVERY mutant regardless of the mutation. That made cross-tenant-probe and
    # test-claim-verifier look like the strongest fixtures at 100% when in fact they change verdict on
    # NO mutation at all — the tool was measuring its own staging bug. Proven with a null operator.
    local tmpdir="$HOOKS"

    # ---- NULL-MUTANT CONTROL, before any scored operator ----
    # A semantically-null mutant MUST reproduce the baseline exactly. If it does not, every verdict
    # for this gate is about the harness rather than the mutation, so the gate is NOT SCORED and the
    # run fails closed. Two failure causes are distinguished, because they need different fixes:
    #   staging        — the mutant runs differently from the original for a reason unrelated to its
    #                    content (broken sibling sourcing, path assumptions, self-inspection).
    #   nondeterministic — the UNMUTATED gate does not even reproduce its own baseline, so no mutation
    #                    verdict from it means anything.
    local nullmut="$tmpdir/.gatemut-null-$gate" nullrc=0 nullafter="" ctl_reason=""
    mutate "$gpath" "$nullmut" "null"; nullrc=$?
    if [ "$nullrc" != "0" ]; then
      ctl_reason="null-mutant-unusable"
    else
      nullafter="$(observe "$nullmut" "$gate")"
      if [ "$nullafter" != "$base" ]; then
        local rerun; rerun="$(observe "$gpath" "$gate")"
        if [ "$rerun" != "$base" ]; then ctl_reason="nondeterministic"; else ctl_reason="staging"; fi
      fi
    fi
    rm -f "$nullmut"
    if [ -n "$ctl_reason" ]; then
      controls_failed=$((controls_failed+1))
      control_names="$(printf '%s %s(%s)' "$control_names" "$gate" "$ctl_reason")"
      rows="$(printf '%s' "$rows" | jq --arg g "$gate" --arg r "$ctl_reason" \
        '. + [{gate:$g, killed:0, survived:0, kill_pct:null, survivors:[], control:"FAILED", control_reason:$r}]' \
        2>/dev/null || printf '%s' "$rows")"
      printf '  %-32s CONTROL FAILED (%s) - NOT SCORED\n' "$gate" "$ctl_reason"
      continue
    fi

    for op in $OPS; do
      local mut="$tmpdir/.gatemut-$op-$gate"
      mutate "$gpath" "$mut" "$op"; local mrc=$?
      [ "$mrc" = "1" ] && continue                     # operator did not apply
      if [ "$mrc" = "2" ]; then invalid=$((invalid+1)); continue; fi
      local after; after="$(observe "$mut" "$gate")"
      if [ "$after" = "$base" ]; then
        gs=$((gs+1)); survived=$((survived+1))
        survivors="$(printf '%s\n%s' "$survivors" "$op" | grep . || true)"
      else
        gk=$((gk+1)); killed=$((killed+1))
      fi
    done
    # Delete ONLY the mutant files. tmpdir is now the real hooks directory — an `rm -rf "$tmpdir"`
    # here would destroy every gate in the framework.
    rm -f "$tmpdir"/.gatemut-*-"$gate"

    local tot=$((gk+gs)) gpct=0
    [ "$tot" -gt 0 ] && gpct=$(( gk * 100 / tot ))
    local sv='[]'
    [ -n "$survivors" ] && sv="$(printf '%s\n' "$survivors" | grep . | jq -R . | jq -cs . 2>/dev/null || echo '[]')"
    rows="$(printf '%s' "$rows" | jq --arg g "$gate" --argjson k "$gk" --argjson s "$gs" --argjson p "$gpct" --argjson sv "$sv" \
      '. + [{gate:$g, killed:$k, survived:$s, kill_pct:$p, survivors:$sv, control:"PASS"}]' 2>/dev/null || printf '%s' "$rows")"
    printf '  %-32s killed %s/%s (%s%%)%s\n' "$gate" "$gk" "$tot" "$gpct" \
      "$([ -n "$survivors" ] && printf '  survived: %s' "$(printf '%s' "$survivors" | tr '\n' ' ')")"
  done < <(jqr '[.[].gate] | unique | .[]' "$MAN")

  local total=$((killed+survived)) pct=0
  [ "$total" -gt 0 ] && pct=$(( killed * 100 / total ))

  local scored; scored="$(printf '%s' "$rows" | jq '[.[]|select(.control=="PASS")]|length' 2>/dev/null || echo 0)"

  jq -n --arg ts "$TS" --argjson p "$pct" --argjson k "$killed" --argjson s "$survived" \
    --argjson inv "$invalid" --argjson r "$rows" --argjson m "$MIN" --argjson cf "$controls_failed" \
    '{verdict:(if $cf > 0 then "FAIL" elif $p >= $m then "PASS" else "FAIL" end), ts:$ts, gate:"gate-mutation",
      kill_pct:$p, killed:$k, survived:$s, invalid_mutants:$inv, controls_failed:$cf,
      min_required:$m, gates:$r}' \
    > "$REPORT" 2>/dev/null || true

  echo "gate-mutation: ${pct}% mutation kill rate (${killed} killed, ${survived} survived, ${invalid} invalid) across ${scored} gates"
  [ "$survived" -gt 0 ] && echo "  a SURVIVED mutant means the fixtures cannot see that class of breakage — that is the actionable output."
  # A failed control means the harness, not the fixtures, decided those verdicts. Publishing a
  # percentage next to that is exactly the retraction this tool already had to issue once.
  if [ "$controls_failed" -gt 0 ]; then
    echo "gate-mutation: FAIL - ${controls_failed} gate(s) failed the null-mutant control:${control_names}" >&2
    echo "  Those gates are excluded from the score above; the percentage covers only the ${scored} controlled gates." >&2
    exit 2
  fi
  if [ "$pct" -lt "$MIN" ]; then
    echo "gate-mutation: FAIL - ${pct}% below required ${MIN}% -> exit 2" >&2; exit 2
  fi
  exit 0
}

selftest() {
  local pass=0 fail=0
  have jq || { echo "gate-mutation selftest SKIP - no jq."; return 0; }
  echo "gate-mutation selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }

  mkworld() { # $1 dir
    local d="$1"; mkdir -p "$d/walteur-kit/hooks" "$d/walteur-kit/eval-harness/fixtures/poison" "$d/walteur-kit/eval-harness/fixtures/clean"
    cat > "$d/walteur-kit/hooks/g.sh" <<'GATE'
#!/usr/bin/env bash
R="${WALTEUR_ROOT:-$1}"
n=0
[ -f "$R/POISON" ] && n=1
if [ "$n" -gt 0 ]; then exit 2; fi
exit 0
GATE
    : > "$d/walteur-kit/eval-harness/fixtures/poison/POISON"
    : > "$d/walteur-kit/eval-harness/fixtures/clean/OK"
    printf '%s' '[{"fixture":"poison","gate":"g.sh","expect":"FAIL"},{"fixture":"clean","gate":"g.sh","expect":"PASS"}]' \
      > "$d/walteur-kit/eval-harness/manifest.json"
  }

  # 1. a real fixture pair KILLS the blind mutant -> high kill rate, exit 0
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/gatemut.XXXXXX")"; mkworld "$t"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  ck "fixtures present -> exit 0" 0 "$?"
  jq -e '.killed >= 1' "$t/walteur-kit/eval-harness/gate-mutation-report.json" >/dev/null 2>&1
  ck "blind mutant is KILLED by the fixtures" 0 "$?"

  # 2. the report names survivors when the fixtures are weak
  #    Remove the poisoned fixture: now nothing can notice the gate going blind.
  rm -rf "$t/walteur-kit/eval-harness/fixtures/poison"
  printf '%s' '[{"fixture":"clean","gate":"g.sh","expect":"PASS"}]' > "$t/walteur-kit/eval-harness/manifest.json"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  jq -e '.survived >= 1 and ((.gates[0].survivors|length) >= 1)' "$t/walteur-kit/eval-harness/gate-mutation-report.json" >/dev/null 2>&1
  ck "clean-only fixtures -> blind mutant SURVIVES and is named" 0 "$?"; rm -rf "$t"

  # 3. --min enforcement
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatemut.XXXXXX")"; mkworld "$t"
  rm -rf "$t/walteur-kit/eval-harness/fixtures/poison"
  printf '%s' '[{"fixture":"clean","gate":"g.sh","expect":"PASS"}]' > "$t/walteur-kit/eval-harness/manifest.json"
  WALTEUR_ROOT="$t" bash "$SELF" --min 99 >/dev/null 2>&1
  ck "--min 99 with survivors -> FAIL" 2 "$?"; rm -rf "$t"

  # 4. a no-op operator must not be scored (script with no exit 2 / no comparisons).
  #    The assertion here USED TO BE `(.killed + .survived) == 0 or (.gates|length) >= 0`, whose
  #    right-hand side is true for every possible report — a tautology that passed unconditionally and
  #    tested nothing. Flagged by adversarial review. It now asserts the exact numbers.
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatemut.XXXXXX")"; mkworld "$t"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$t/walteur-kit/hooks/g.sh"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  jq -e '.killed == 0 and .survived == 0 and (.gates|length) == 1
         and .gates[0].control == "PASS" and (.gates[0].killed + .gates[0].survived) == 0' \
    "$t/walteur-kit/eval-harness/gate-mutation-report.json" >/dev/null 2>&1
  ck "non-mutable gate scores exactly zero mutants (was a tautology)" 0 "$?"; rm -rf "$t"

  # 4b. THE OPERATOR-APPLICABILITY ASSERTION. A gate containing no `--exclude-dir=` must score ZERO
  #     unexclude mutants — neither killed nor survived. Its absence is what let the retracted headline
  #     ("unexclude survived on 12 gates") stand: 10 of those 12 gates had no --exclude-dir at all, so
  #     the "mutant" was the unmodified gate, counted as a survivor.
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatemut.XXXXXX")"; mkworld "$t"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  grep -q -- '--exclude-dir=' "$t/walteur-kit/hooks/g.sh" \
    && { echo "  FAIL - fixture gate unexpectedly contains --exclude-dir"; fail=$((fail+1)); } \
    || { jq -e '[.gates[]|select(.gate=="g.sh")|.survivors[]]|index("unexclude") == null' \
           "$t/walteur-kit/eval-harness/gate-mutation-report.json" >/dev/null 2>&1
         ck "gate without --exclude-dir scores no unexclude mutant" 0 "$?"; }
  rm -rf "$t"

  # 4c. THE NULL-MUTANT CONTROL ITSELF. A gate whose verdict depends on its own source text makes every
  #     mutation verdict meaningless. The control must catch it, refuse to score the gate, and exit 2 —
  #     the check that would have caught both retracted defects on their first run.
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatemut.XXXXXX")"; mkworld "$t"
  # The marker is assembled at runtime so the ORIGINAL gate does not contain the literal it greps for
  # — otherwise the baseline trips its own check and matches the mutant, and the control looks fine.
  printf '#!/usr/bin/env bash\nP=gatemut-null\ngrep -q "${P}-control" "$0" && exit 2\nexit 0\n' > "$t/walteur-kit/hooks/g.sh"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  ck "null-control failure -> exit 2" 2 "$?"
  jq -e '.controls_failed == 1 and .verdict == "FAIL"
         and (.gates[]|select(.gate=="g.sh")|.control) == "FAILED"
         and (.gates[]|select(.gate=="g.sh")|.control_reason) == "staging"' \
    "$t/walteur-kit/eval-harness/gate-mutation-report.json" >/dev/null 2>&1
  ck "null-control failure named as 'staging' and gate not scored" 0 "$?"; rm -rf "$t"

  # 5. no manifest -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatemut.XXXXXX")"; mkdir -p "$t/walteur-kit"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  ck "no manifest -> NOT_APPLICABLE" 0 "$?"; rm -rf "$t"

  # 5b. REGRESSION: a corrupt manifest must FAIL closed. It previously reported
  #     "0% kill rate (0 killed, 0 survived) across 0 gates" and exit 0 — unmeasured presented as a
  #     clean run, the exact fail-open this tool exists to find in other checkers.
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatemut.XXXXXX")"; mkdir -p "$t/walteur-kit/eval-harness"
  printf 'X' > "$t/walteur-kit/eval-harness/manifest.json"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  ck "G5b corrupt manifest -> FAIL (was exit 0)" 2 "$?"; rm -rf "$t"

  # 6. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/gatemut.XXXXXX")"; mkworld "$t"
  WALTEUR_ROOT="$t" WALTEUR_GATEMUT=off bash "$SELF" --min 99 >/dev/null 2>&1
  ck "bypass -> exit 0" 0 "$?"
  touch "$t/walteur-kit/PAUSED"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  ck "PAUSED -> exit 2" 2 "$?"; rm -rf "$t"

  echo "gate-mutation selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
