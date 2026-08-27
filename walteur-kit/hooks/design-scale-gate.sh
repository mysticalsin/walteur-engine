#!/usr/bin/env bash
# walteur-kit/hooks/design-scale-gate.sh — the SECOND computed design gate (sibling to design-contrast-gate,
# panel-9 critic's secondary lever). Where design-contrast-gate COMPUTES WCAG contrast, this COMPUTES three
# other "Apple-grade" design-token invariants from an author-declared manifest (walteur-kit/design-scale.json):
#
#   1. type-scale MONOTONICITY  — the type ramp (in intended ascending order) must be strictly increasing +
#      distinct. Catches a real token bug (--text-lg < --text-md, or two tokens equal). FP-safe: it does NOT
#      demand a constant modular ratio (a legit hybrid scale — tight UI steps + a big display jump, e.g.
#      12/13/15/17/20/28/64 — would false-positive on a naive constant-ratio check; that is the anti-slop FP trap).
#   2. spacing BASE-GRID        — every spacing token must be an integer multiple of an author-DECLARED base
#      (spacing_base_px, >=2). Catches an off-grid stray (a lone 13px on a 4px grid). Author-declared base =
#      FP-safe (a legit 5px-base system declares base:5, not judged against a hard-coded 4/8).
#   3. tap-target >=44px        — every declared interactive target's min tap size must be >= 44px (WCAG 2.5.5
#      AAA / Apple HIG minimum touch size). Catches a too-small button. Declared-size-only: elements without a
#      declared size are NOT guessed (no false-positive).
#
# Opt-in: NOT_APPLICABLE without a manifest (unlike contrast, type/spacing are not safety-critical enough to
# force on every project). jq required; jq-absent NOT_APPLICABLE off-ship but FAIL-CLOSES at ship
# (WALTEUR_TOOLGATE_STRICT=1), matching osv/container/contrast. --ratio-free: pure token arithmetic.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
MANIFEST="${WALTEUR_DESIGN_SCALE_MANIFEST:-$KIT/design-scale.json}"
REPORT="$KIT/design-scale-report.json"
STRICT="${WALTEUR_TOOLGATE_STRICT:-0}"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() {
  local verdict="$1" reason="$2" findings="${3:-[]}"
  mkdir -p "$KIT" 2>/dev/null || true
  if have jq; then
    jq -n --arg v "$verdict" --arg r "$reason" --argjson f "$findings" \
      '{verdict:$v, gate:"design-scale", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null || true
  else
    printf '{"verdict":"%s","gate":"design-scale","reason":"%s","findings":[]}\n' "$verdict" "$reason" > "$REPORT" 2>/dev/null || true
  fi
}

run_gate() {
  if [ ! -f "$MANIFEST" ]; then
    write_report "NOT_APPLICABLE" "no design-scale.json manifest (opt-in gate)"
    echo "design-scale-gate: NOT_APPLICABLE (no manifest at ${MANIFEST#"$ROOT"/})"; return 0
  fi
  if ! have jq; then
    if [ "$STRICT" = "1" ]; then
      write_report "FAIL" "jq absent - design-scale UNVERIFIABLE at ship (STRICT)"
      echo "design-scale-gate: FAIL-CLOSED - jq required to verify the manifest at ship (STRICT)." >&2; return 2
    fi
    write_report "NOT_APPLICABLE" "jq absent - manifest not verified (recorded, not silent-green)"
    echo "design-scale-gate: NOT_APPLICABLE - jq absent (install jq for enforcement)." >&2; return 0
  fi
  if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
    write_report "FAIL" "design-scale.json is not valid JSON"
    echo "design-scale-gate: FAIL - manifest is not valid JSON." >&2; return 2
  fi

  # Compute all three axes in jq; emit a findings array (empty = PASS).
  local findings
  findings="$(jq -c '
    ( .type_scale_px // [] ) as $t
    | ( .spacing_px // [] ) as $s
    | ( .spacing_base_px // 0 ) as $b
    | ( .tap_targets // [] ) as $k
    | [
        # 1. type-scale strictly increasing + distinct
        ( [ range(1; ($t|length)) | select($t[.] <= $t[.-1])
            | {axis:"type_scale", detail:("token #\(.) (\($t[.])px) is not greater than the previous (\($t[.-1])px) - scale must be strictly increasing")} ] ),
        # 2. spacing base grid: base>=2 and every token a multiple of base
        ( if ($b < 2) then [{axis:"spacing_base", detail:"spacing_base_px must be >= 2 (got \($b)) - declare a real base grid"}] else [] end ),
        ( [ $s[] | select( ($b >= 2) and ( . % $b != 0 ) )
            | {axis:"spacing_grid", detail:("spacing \(.)px is not a multiple of the \($b)px base grid")} ] ),
        # 3. tap-target >= 44px
        ( [ $k[] | select( (.min_px // 0) < 44 )
            | {axis:"tap_target", detail:("\(.selector) min tap size \(.min_px)px < 44px (WCAG 2.5.5 / HIG minimum)")} ] )
      ] | add
  ' "$MANIFEST" 2>/dev/null)"

  if [ -z "$findings" ]; then
    write_report "FAIL" "manifest present but could not be evaluated (shape error)"
    echo "design-scale-gate: FAIL - manifest evaluation failed (check type_scale_px/spacing_px/spacing_base_px/tap_targets shape)." >&2; return 2
  fi
  local n; n="$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    write_report "FAIL" "$n design-scale violation(s)" "$findings"
    echo "design-scale-gate: FAIL - $n violation(s):" >&2
    printf '%s' "$findings" | jq -r '.[] | "  - " + .axis + ": " + .detail' 2>/dev/null >&2 || true
    return 2
  fi
  write_report "PASS" "type-scale monotonic, spacing on base grid, all tap targets >= 44px"
  echo "design-scale-gate: PASS"; return 0
}

selftest() {
  local pass=0 fail=0 base t
  base="$(mktemp -d "${TMPDIR:-/tmp}/dscale.XXXXXX")" || { echo "selftest: mktemp -d failed"; return 1; }
  ck() { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $3 (want $2 got $1)"; fi; }
  runm() { # $1 = manifest json (or empty for none); echoes exit code
    local d; d="$base/$RANDOM$RANDOM"; mkdir -p "$d/walteur-kit"
    [ -n "$1" ] && printf '%s' "$1" > "$d/walteur-kit/design-scale.json"
    WALTEUR_ROOT="$d" bash "$0" >/dev/null 2>&1; echo $?
  }
  echo "design-scale-gate selftest:"
  # good manifest -> PASS
  ck "$(runm '{"type_scale_px":[12,13,15,17,20,28,64],"spacing_base_px":4,"spacing_px":[4,8,12,16,24,32,64],"tap_targets":[{"selector":".btn","min_px":48},{"selector":".preset","min_px":44}]}')" 0 "clean manifest -> PASS"
  # REFUTATION 1: non-monotonic type scale -> FAIL
  ck "$(runm '{"type_scale_px":[12,17,15,20],"spacing_base_px":4,"spacing_px":[4,8],"tap_targets":[]}')" 2 "non-monotonic type scale -> FAIL"
  # REFUTATION 2: duplicate type token -> FAIL
  ck "$(runm '{"type_scale_px":[12,13,13,17],"spacing_base_px":4,"spacing_px":[4,8],"tap_targets":[]}')" 2 "duplicate type token -> FAIL"
  # REFUTATION 3: off-grid spacing (13 on a 4px base) -> FAIL
  ck "$(runm '{"type_scale_px":[12,16],"spacing_base_px":4,"spacing_px":[4,8,13,16],"tap_targets":[]}')" 2 "off-grid spacing -> FAIL"
  # REFUTATION 4: tap-target below 44px -> FAIL
  ck "$(runm '{"type_scale_px":[12,16],"spacing_base_px":4,"spacing_px":[4,8],"tap_targets":[{"selector":".mini","min_px":32}]}')" 2 "tap target < 44 -> FAIL"
  # REFUTATION 5: base < 2 (chaotic grid) -> FAIL
  ck "$(runm '{"type_scale_px":[12,16],"spacing_base_px":1,"spacing_px":[1,3,7],"tap_targets":[]}')" 2 "base < 2 -> FAIL"
  # FP-guard: a legit HYBRID scale (tight steps + big jump) must PASS (not a constant ratio)
  ck "$(runm '{"type_scale_px":[12,13,15,17,20,28,64],"spacing_base_px":8,"spacing_px":[8,16,24,32],"tap_targets":[{"selector":".b","min_px":44}]}')" 0 "hybrid scale + 8px grid + 44 tap -> PASS (no false-positive)"
  # no manifest -> NOT_APPLICABLE (exit 0)
  ck "$(runm '')" 0 "no manifest -> NOT_APPLICABLE (exit 0)"
  # exactly 44px tap -> PASS (boundary)
  ck "$(runm '{"type_scale_px":[12,16],"spacing_base_px":4,"spacing_px":[4,8],"tap_targets":[{"selector":".edge","min_px":44}]}')" 0 "44px tap (boundary) -> PASS"
  # jq-absent + STRICT -> FAIL-CLOSED (exit 2)
  d="$base/nojq$RANDOM"; mkdir -p "$d/walteur-kit"; printf '{"type_scale_px":[12,16]}' > "$d/walteur-kit/design-scale.json"
  shimdir="$base/noshim"; mkdir -p "$shimdir"
  for b in bash sed grep cat mkdir printf rm mktemp dirname basename cd env git find head tr; do
    src="$(command -v "$b" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$shimdir/$b" 2>/dev/null
  done
  rc="$(PATH="$shimdir" WALTEUR_ROOT="$d" WALTEUR_TOOLGATE_STRICT=1 bash "$0" >/dev/null 2>&1; echo $?)"
  ck "$rc" 2 "jq-absent + STRICT -> FAIL-CLOSED (exit 2)"
  rm -rf "$base"
  echo "design-scale-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest ;;
  -h|--help) echo "design-scale-gate - COMPUTES type-scale monotonicity + spacing base-grid + tap-target>=44px from walteur-kit/design-scale.json. usage: [--selftest|--help|<run>]" ;;
  *) run_gate ;;
esac
