#!/usr/bin/env bash
# WALTEUR remediation-coverage-gate — HARD gate (S033 candidate C1, usability). Closes the
# "REMEDIATION.md rots the instant a gate is added/renamed" hole: nothing previously proved the
# fix-recipe doc actually covers every registered gate, or that every hook honors the documented
# `--help` self-documentation contract (REMEDIATION.md's own intro promises
# `bash walteur-kit/hooks/<gate>.sh --help` works for every gate).
#
# TWO CHECKS (both real exit-2 facts, no judgment):
#   C1  ANCHOR COVERAGE — every gate id in walteur-kit/gate-registry.json must have a matching
#       `## <gate-id>` markdown anchor (exact line, own heading) in walteur-kit/REMEDIATION.md.
#       A registry id with no anchor => FAIL (the fix-recipe table silently fell behind the registry).
#   C2  HELP-ARM COVERAGE — every hook file directly under walteur-kit/hooks/*.sh (excluding
#       underscore-prefixed shared libraries like _probe-proof.sh, which are sourced, never invoked
#       standalone) must carry a `--help`/`-h` arm somewhere in its case/if arg dispatch. A hook with
#       no help arm => FAIL (the documented self-documentation contract is broken for that gate).
#       KNOWN FIRST-RUN STATE: as of this gate's introduction, most hooks do NOT yet have a --help arm
#       (a parallel help-sweep builder is adding them). On first live run this WILL likely FAIL until
#       that sweep lands — that is correct fail-closed behavior: this gate's job is to make the gap
#       visible and keep it from silently regressing once closed, not to pretend the gap is already
#       closed.
#
# CONTRACT:
#   walteur-kit/PAUSED present                          => exit 2.
#   WALTEUR_REMEDIATION_COVERAGE=off                     => loud SKIP, exit 0.
#   gate-registry.json absent OR REMEDIATION.md absent   => NOT_APPLICABLE, exit 0 (nothing to check
#                                                            coverage of yet — never stalls a build
#                                                            before the kit itself is scaffolded).
#   jq absent                                            => SKIP, exit 0 (loud; cannot parse registry).
#   any registry id missing a `## <id>` anchor           => FAIL, exit 2.
#   any non-underscore hooks/*.sh missing a --help arm   => FAIL, exit 2.
#   all covered                                          => PASS, exit 0.
#
# Report: walteur-kit/remediation-coverage-report.json
# Bypass: WALTEUR_REMEDIATION_COVERAGE=off
set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd || echo "$ROOT")"
KIT="$ROOT/walteur-kit"
HOOKS_DIR="$KIT/hooks"
REG="$KIT/gate-registry.json"
REMEDIATION="$KIT/REMEDIATION.md"
REPORT="$KIT/remediation-coverage-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() {
  findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"
  failures=$((failures+1))
}
write_report() {
  v="$1"; r="$2"
  missing_anchors="${3:-[]}"; missing_help="${4:-[]}"
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" \
      --argjson f "$findings" --argjson ma "$missing_anchors" --argjson mh "$missing_help" \
      '{verdict:$v, ts:$ts, gate:"remediation-coverage", reason:$r, missing_anchors:$ma, missing_help_arm:$mh, findings:$f}' \
      > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"remediation-coverage","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true
}

# has_help_arm <hook-file>: does the file's arg dispatch carry a --help / -h case/if arm?
# Matches the two idioms already in use in this kit:
#   case ... in ... -h|--help) ... ;;         (flaky-test-gate.sh style)
#   elif [ "$1" = "--help" ] || [ "$1" = "-h" ]  (tool-acquisition-proof.sh style)
# Deliberately excludes a bare mention of "--help" in a comment or in another tool's invocation
# (e.g. tool-liveness-probe.sh calling `"$t" --help` on a THIRD-PARTY tool it's probing) by requiring
# the token to appear as part of a case-pattern or an argument-comparison, not just anywhere in the file.
has_help_arm() {
  local f="$1"
  grep -qE '(^|\|)[[:space:]]*-h\|--help\)|(^|\|)[[:space:]]*--help\)|=[[:space:]]*"--help"|=[[:space:]]*"-h"' "$f" 2>/dev/null
}

# anchor_present <gate-id> <remediation-file>: an exact `## <gate-id>` heading line exists.
anchor_present() {
  local id="$1" file="$2"
  grep -qxF "## $id" "$file" 2>/dev/null
}

main() {
  if [ -f "$KIT/PAUSED" ]; then
    add_finding paused "walteur-kit/PAUSED present"
    write_report FAIL "PAUSED" '[]' '[]'
    echo "remediation-coverage-gate: PAUSED (walteur-kit/PAUSED) -> exit 2" >&2
    exit 2
  fi
  if [ "${WALTEUR_REMEDIATION_COVERAGE:-on}" = "off" ]; then
    write_report SKIP "bypassed via WALTEUR_REMEDIATION_COVERAGE=off" '[]' '[]'
    echo "remediation-coverage-gate: bypassed (WALTEUR_REMEDIATION_COVERAGE=off)." >&2
    exit 0
  fi
  if [ ! -f "$REG" ] || [ ! -f "$REMEDIATION" ]; then
    write_report NOT_APPLICABLE "no gate-registry.json and/or REMEDIATION.md yet" '[]' '[]'
    echo "remediation-coverage-gate: NOT_APPLICABLE (registry or REMEDIATION.md absent)." >&2
    exit 0
  fi
  if ! have jq; then
    write_report SKIP "jq absent — cannot parse gate-registry.json" '[]' '[]'
    echo "remediation-coverage-gate: SKIP (jq absent, cannot_measure)." >&2
    exit 0
  fi

  # ── C1: anchor coverage ──────────────────────────────────────────────────────────────────────
  local ids missing_anchors_json='[]' id
  ids="$(jq -r '.gates[]?.id // empty' "$REG" 2>/dev/null)"
  if [ -z "$ids" ]; then
    add_finding registry_empty "gate-registry.json has no .gates[] entries"
  else
    local missing_list=()
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      if ! anchor_present "$id" "$REMEDIATION"; then
        missing_list+=("$id")
      fi
    done <<EOF_IDS
$ids
EOF_IDS
    if [ "${#missing_list[@]}" -gt 0 ]; then
      for id in "${missing_list[@]}"; do
        add_finding missing_anchor "REMEDIATION.md has no '## $id' anchor for registered gate '$id'"
      done
      if have jq; then
        missing_anchors_json="$(printf '%s\n' "${missing_list[@]}" | jq -R . | jq -s .)"
      fi
    fi
  fi

  # ── C2: --help arm coverage ──────────────────────────────────────────────────────────────────
  local missing_help_json='[]' hf base
  if [ -d "$HOOKS_DIR" ]; then
    local missing_help_list=()
    for hf in "$HOOKS_DIR"/*.sh; do
      [ -f "$hf" ] || continue
      base="$(basename "$hf")"
      case "$base" in _*) continue ;; esac   # shared/sourced libraries are never invoked standalone
      if ! has_help_arm "$hf"; then
        missing_help_list+=("$base")
      fi
    done
    if [ "${#missing_help_list[@]}" -gt 0 ]; then
      for base in "${missing_help_list[@]}"; do
        add_finding missing_help_arm "$base has no --help/-h arm in its arg dispatch"
      done
      if have jq; then
        missing_help_json="$(printf '%s\n' "${missing_help_list[@]}" | jq -R . | jq -s .)"
      fi
    fi
  fi

  if [ "$failures" -gt 0 ]; then
    write_report FAIL "remediation coverage gap: $failures finding(s)" "$missing_anchors_json" "$missing_help_json"
    echo "remediation-coverage-gate: FAIL ($failures finding(s)) -> exit 2" >&2
    printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null | head -20 >&2 || true
    exit 2
  fi
  write_report PASS "every registry gate has a REMEDIATION.md anchor; every hook has a --help arm" '[]' '[]'
  echo "remediation-coverage-gate: PASS" >&2
  exit 0
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# SELFTEST — hermetic synthetic registry + REMEDIATION.md + hooks/, incl. NEGATIVE CONTROLS
# ─────────────────────────────────────────────────────────────────────────────────────────────────
selftest() {
  local pass=0 fail=0
  if ! have jq; then echo "remediation-coverage-gate selftest SKIP - no jq."; return 0; fi
  echo "remediation-coverage-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }

  # mkfixture <dir> <ids-csv> <hook-help-mode>
  #   hook-help-mode: "all"  = every hook gets a --help arm (GOOD)
  #                   "none" = no hook gets a --help arm     (POISON: help-arm coverage)
  mkfixture() {
    local d="$1" ids_csv="$2" help_mode="$3" id
    mkdir -p "$d/walteur-kit/hooks"
    local gates_json='['
    local first=1
    IFS=',' read -ra idarr <<< "$ids_csv"
    for id in "${idarr[@]}"; do
      [ "$first" -eq 1 ] || gates_json="$gates_json,"
      gates_json="$gates_json{\"id\":\"$id\",\"hook\":\"$id.sh\"}"
      first=0
    done
    gates_json="$gates_json]"
    printf '{"gates":%s}\n' "$gates_json" > "$d/walteur-kit/gate-registry.json"

    : > "$d/walteur-kit/REMEDIATION.md"
    echo "# fixture remediation" >> "$d/walteur-kit/REMEDIATION.md"
    for id in "${idarr[@]}"; do
      {
        echo ""
        echo "## $id"
        echo "Enforces: fixture."
        echo "Common failure: fixture."
        echo "Fix: fixture."
        echo "Bypass: fixture."
      } >> "$d/walteur-kit/REMEDIATION.md"
      if [ "$help_mode" = "all" ]; then
        printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  -h|--help) echo help; exit 0 ;;\n  *) exit 0 ;;\nesac\n' > "$d/walteur-kit/hooks/$id.sh"
      else
        printf '#!/usr/bin/env bash\nexit 0\n' > "$d/walteur-kit/hooks/$id.sh"
      fi
    done
    # a shared underscore library with no --help arm — must NEVER be flagged
    printf '#!/usr/bin/env bash\n# shared lib, sourced only\nprobe_proves_something() { return 0; }\n' > "$d/walteur-kit/hooks/_probe-proof.sh"
  }

  # 1. no registry / no REMEDIATION.md -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/remediatio.XXXXXX")"; mkdir -p "$t/src"; ck "no kit files -> NOT_APPLICABLE" 0 "$(run "$t")"; rm -rf "$t"

  # 2. GOOD: every id anchored, every hook has --help -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/remediatio.XXXXXX")"; mkfixture "$t" "alpha-gate,beta-gate,gamma-gate" "all"
  ck "full coverage (anchors + help arms) -> PASS" 0 "$(run "$t")"
  rm -rf "$t"

  # 3. NEGATIVE CONTROL A: a registry id has no matching '## <id>' anchor -> FAIL exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/remediatio.XXXXXX")"; mkfixture "$t" "alpha-gate,beta-gate" "all"
  # remove beta-gate's anchor from REMEDIATION.md (blank it, keep alpha's)
  awk '/^## beta-gate$/{skip=1} /^## alpha-gate$/{skip=0} !skip' "$t/walteur-kit/REMEDIATION.md" > "$t/walteur-kit/REMEDIATION.md.tmp"
  mv "$t/walteur-kit/REMEDIATION.md.tmp" "$t/walteur-kit/REMEDIATION.md"
  rc="$(run "$t")"
  ck "NEGATIVE CONTROL: missing anchor for registered gate -> FAIL" 2 "$rc"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  grep -q '"missing_anchor"' "$t/walteur-kit/remediation-coverage-report.json" 2>/dev/null \
    && { echo "  ok   - report names missing_anchor finding"; pass=$((pass+1)); } \
    || { echo "  FAIL - report does not name missing_anchor finding"; fail=$((fail+1)); }
  rm -rf "$t"

  # 4. NEGATIVE CONTROL B: every anchor present, but a hook has no --help arm -> FAIL exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/remediatio.XXXXXX")"; mkfixture "$t" "alpha-gate,beta-gate" "none"
  rc="$(run "$t")"
  ck "NEGATIVE CONTROL: hook missing --help arm -> FAIL" 2 "$rc"
  WALTEUR_ROOT="$t" bash "$SELF" >/dev/null 2>&1
  grep -q '"missing_help_arm"' "$t/walteur-kit/remediation-coverage-report.json" 2>/dev/null \
    && { echo "  ok   - report names missing_help_arm finding"; pass=$((pass+1)); } \
    || { echo "  FAIL - report does not name missing_help_arm finding"; fail=$((fail+1)); }
  # confirm the underscore shared lib was NOT flagged (it has no --help arm by design)
  grep -q '_probe-proof.sh' "$t/walteur-kit/remediation-coverage-report.json" 2>/dev/null \
    && { echo "  FAIL - underscore shared lib was wrongly flagged"; fail=$((fail+1)); } \
    || { echo "  ok   - underscore shared lib correctly excluded"; pass=$((pass+1)); }
  rm -rf "$t"

  # 5. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/remediatio.XXXXXX")"; mkfixture "$t" "alpha-gate" "all"
  WALTEUR_ROOT="$t" WALTEUR_REMEDIATION_COVERAGE=off bash "$SELF" >/dev/null 2>&1
  ck "bypass -> exit 0" 0 "$?"
  touch "$t/walteur-kit/PAUSED"
  ck "PAUSED -> exit 2" 2 "$(run "$t")"
  rm -rf "$t"

  # 6. help-arm pattern recognizes BOTH idioms in live use (case-arm AND elif-string-compare)
  t="$(mktemp -d "${TMPDIR:-/tmp}/remediatio.XXXXXX")"; mkfixture "$t" "alpha-gate" "all"
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then echo help; exit 0; fi\nexit 0\n' > "$t/walteur-kit/hooks/alpha-gate.sh"
  ck "elif-string-compare --help idiom recognized -> PASS" 0 "$(run "$t")"
  rm -rf "$t"

  echo "remediation-coverage-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  -h|--help)  sed -n '1,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")         main ;;
  *)          echo "remediation-coverage-gate: unknown arg '$1' (try --selftest, --help, or no-arg normal run)." >&2; exit 1 ;;
esac
