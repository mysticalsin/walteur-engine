#!/usr/bin/env bash
# WALTEUR quickstart-check — DETECT-OR-SKIP. Proves the README's quickstart actually works.
#
# HEAVY path (docker present): run the README's FIRST fenced ```bash / ```sh block inside a
# clean throwaway container image and assert a 'walteur:ready' readiness marker is emitted within
# a time budget. A quickstart that does not reach 'walteur:ready' in a clean container is a broken
# onboarding promise => violation (exit 2). The block runs in a fresh container (NOT the host),
# is bind-mounted read-only, and is killed at the budget — nothing touches the real repo.
#   - The marker is an HONEST signal — it is only counted when it is genuinely PRINTED, either by
#     the quickstart block itself (`echo walteur:ready`) OR by a project-provided readiness probe
#     `walteur-kit/quickstart-ready.sh` that the runner executes AFTER the block and which is itself
#     responsible for printing the marker on success. The runner NEVER fabricates the marker from a
#     bare clean exit — a block that exits 0 but signals nothing is correctly treated as NOT ready.
#     If the block errors (set -e), the probe never runs and no marker is produced.
#
# ZERO-DEP fallback (docker absent => LOUD SKIP of the container assertion, but STILL a real check):
# the gate HARD-asserts the README is honestly onboard-able — it must have BOTH:
#   (Z1) a quickstart heading (a heading matching: quickstart | quick start | getting started |
#        ## use it | installation | setup | get started), AND
#   (Z2) at least one fenced ```bash / ```sh / ```shell block.
# Missing either is a real violation => exit 2 (the README cannot onboard anyone). This is the
# "prefer a zero-dep hard check in EVERY gate" rule: even with no docker, the gate does real work.
#
# HONESTY: docker missing/unusable => LOUD recorded SKIP of the *container* assertion (exit 0 only
# if the zero-dep README check also passes; if the zero-dep check FAILS, that is a real exit 2 and
# the SKIP of the heavy path is recorded alongside). We NEVER silent-green and NEVER exit 2 for a
# missing tool.
# Report: walteur-kit/quickstart-report.json {verdict, ts, gate, mode, readme, marker_found,
#          budget_s, zero_dep:{heading,fenced_block}, details}.
# Bypass: WALTEUR_QUICKSTART=off. Budget: WALTEUR_QS_BUDGET seconds (default 90).
# Image: WALTEUR_QS_IMAGE (default alpine:3.20 — a tiny clean image with /bin/sh + bash via apk if needed).
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/quickstart-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }
BUDGET="${WALTEUR_QS_BUDGET:-90}"
IMAGE="${WALTEUR_QS_IMAGE:-alpine:3.20}"
MARKER="walteur:ready"

selftest() {
  local pass=0 fail=0 tmp rc
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  ck() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  echo "quickstart-check selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quickstart-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" WALTEUR_QS_DOCKER=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "no README -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quickstart-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '# Project\n\n```bash\necho hello\n```\n' > "$tmp/README.md"
  WALTEUR_ROOT="$tmp" WALTEUR_QS_DOCKER=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "README missing quickstart heading -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quickstart-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '# Quickstart\n\nRun the app.\n' > "$tmp/README.md"
  WALTEUR_ROOT="$tmp" WALTEUR_QS_DOCKER=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "README missing shell block -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quickstart-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '# Quickstart\n\n```bash\necho hello\n```\n' > "$tmp/README.md"
  WALTEUR_ROOT="$tmp" WALTEUR_QS_DOCKER=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "zero-dep quickstart shape -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quickstart-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" WALTEUR_QUICKSTART=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quickstart-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "quickstart-check selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_QUICKSTART:-on}" = "off" ] && { echo "quickstart-check: bypassed (WALTEUR_QUICKSTART=off)." >&2; exit 0; }

# write_report VERDICT MODE MARKER_FOUND Z_HEADING Z_FENCE DETAILS
write_report() {
  local v="$1" mode="$2" marker="$3" zh="$4" zf="$5" det="$6"
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --arg mode "$mode" --arg readme "$README_PATH" \
          --argjson marker "$marker" --argjson zh "$zh" --argjson zf "$zf" \
          --argjson budget "$BUDGET" --arg det "$det" \
      '{verdict:$v, ts:$ts, gate:"quickstart", mode:$mode, readme:$readme,
        marker_found:$marker, budget_s:$budget,
        zero_dep:{heading:($zh==1), fenced_block:($zf==1)}, details:$det}' > "$REPORT"
  else
    printf '{"verdict":"%s","ts":"%s","gate":"quickstart","mode":"%s","readme":"%s","marker_found":%s,"budget_s":%s,"zero_dep":{"heading":%s,"fenced_block":%s},"details":"%s"}\n' \
      "$v" "$TS" "$mode" "$README_PATH" "$marker" "$BUDGET" \
      "$([ "$zh" = 1 ] && echo true || echo false)" \
      "$([ "$zf" = 1 ] && echo true || echo false)" "$det" > "$REPORT"
  fi
}

# ── locate the README ────────────────────────────────────────────────────────────
README_PATH=""
for cand in README.md README.markdown readme.md Readme.md; do
  if [ -f "$ROOT/$cand" ]; then README_PATH="$ROOT/$cand"; break; fi
done
if [ -z "$README_PATH" ]; then
  echo "quickstart-check: no README found at repo root — gate not applicable." >&2
  README_PATH=""
  write_report "NOT_APPLICABLE" "none" false 0 0 "no README.md at repo root"
  exit 0
fi

# ── ZERO-DEP hard checks (always run) ────────────────────────────────────────────
# Z1: quickstart-ish heading present.
Z_HEADING=0
if grep -qiE '^[[:space:]]*#{1,6}[[:space:]]*(qu[ -]?start|getting[ -]started|get[ -]started|use it|installation|install|setup|set[ -]up|quickstart)\b' "$README_PATH"; then
  Z_HEADING=1
fi

# Z2: at least one fenced bash/sh/shell block. Extract the FIRST such block's body for the heavy path.
FIRST_BLOCK="$(awk '
  BEGIN{inb=0; done=0}
  /^[[:space:]]*(```|~~~)[[:space:]]*(bash|sh|shell)[[:space:]]*$/ {
    if(!inb && !done){inb=1; next}
  }
  inb && /^[[:space:]]*(```|~~~)[[:space:]]*$/ { inb=0; done=1; next }
  inb { print }
' "$README_PATH")"
Z_FENCE=0
[ -n "$FIRST_BLOCK" ] && Z_FENCE=1

ZERO_DEP_FAIL=0
ZD_MSG=""
if [ "$Z_HEADING" -eq 0 ]; then
  ZERO_DEP_FAIL=1
  ZD_MSG="README has no quickstart/getting-started/install/setup heading; "
  echo "  FAIL (zero-dep) — README has no quickstart-style heading." >&2
fi
if [ "$Z_FENCE" -eq 0 ]; then
  ZERO_DEP_FAIL=1
  ZD_MSG="${ZD_MSG}README has no fenced bash/sh/shell block to run."
  echo "  FAIL (zero-dep) — README has no fenced bash/sh block." >&2
fi

# ── HEAVY path: docker present => run first block in a clean container ────────────
docker_usable=0
if [ "${WALTEUR_QS_DOCKER:-on}" = "off" ]; then
  echo "  SKIP (heavy) — WALTEUR_QS_DOCKER=off; running zero-dep README assertion only. Recorded; NOT counted green." >&2
elif have docker; then
  if docker info >/dev/null 2>&1; then
    docker_usable=1
  else
    echo "  SKIP (heavy) — docker binary present but daemon not reachable (docker info failed). Recorded; NOT counted green." >&2
  fi
else
  echo "  SKIP (heavy) — docker not installed; running zero-dep README assertion only. Recorded; NOT counted green." >&2
fi

MODE="zero-dep"
MARKER_FOUND=false
HEAVY_FAIL=0
HEAVY_MSG=""

if [ "$docker_usable" -eq 1 ] && [ "$Z_FENCE" -eq 1 ]; then
  MODE="container"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/walteur-quickstart.XXXXXX")"
  # Build the script the container runs: the README's first block (verbatim, under set -e so an
  # error aborts before any readiness signal), then — and ONLY then — an optional project readiness
  # probe. The marker is counted only if it is genuinely PRINTED: either the block echoed it, or the
  # project ships walteur-kit/quickstart-ready.sh which prints it on success. The runner does NOT
  # synthesise the marker from a bare clean exit — silence means not-ready, by design.
  {
    printf '%s\n' '#!/usr/bin/env sh'
    printf '%s\n' 'set -e'
    printf '%s\n' '# ---- README first fenced block (verbatim) ----'
    printf '%s\n' "$FIRST_BLOCK"
    printf '%s\n' '# ---- WALTEUR readiness probe (project-supplied; prints the marker itself) ----'
    printf '%s\n' 'if [ -f /repo/walteur-kit/quickstart-ready.sh ]; then sh /repo/walteur-kit/quickstart-ready.sh; fi'
  } > "$WORK/run.sh"

  # Run in a clean container: read-only repo bind mount, no network needed for the marker echo,
  # killed at BUDGET via timeout (host) AND container --stop-timeout. The container is removed (--rm).
  CID="walteur-qs-$$"
  set +e
  if have timeout; then TO="timeout ${BUDGET}s"; elif have gtimeout; then TO="gtimeout ${BUDGET}s"; else TO=""; fi
  OUT="$(
    $TO docker run --rm --name "$CID" \
      --network=none \
      -v "$ROOT:/repo:ro" \
      -v "$WORK/run.sh:/walteur-run.sh:ro" \
      -w /tmp \
      -e WALTEUR_IN_CONTAINER=1 \
      "$IMAGE" /bin/sh /walteur-run.sh 2>&1
  )"
  DRC=$?
  set -e
  # best-effort cleanup if timeout left it
  docker rm -f "$CID" >/dev/null 2>&1 || true
  rm -rf "$WORK"

  if printf '%s' "$OUT" | grep -qF "$MARKER"; then
    MARKER_FOUND=true
    echo "  ok (heavy) — quickstart reached '$MARKER' in a clean $IMAGE container (rc=$DRC)." >&2
  else
    HEAVY_FAIL=1
    if [ "$DRC" -eq 124 ]; then
      HEAVY_MSG="quickstart exceeded ${BUDGET}s budget without emitting '$MARKER'."
      echo "  FAIL (heavy) — quickstart timed out after ${BUDGET}s without '$MARKER'." >&2
    else
      HEAVY_MSG="quickstart ran (rc=$DRC) but never emitted '$MARKER' in a clean container."
      echo "  FAIL (heavy) — '$MARKER' not found in clean-container output (rc=$DRC)." >&2
      printf '%s\n' "$OUT" | tail -20 | sed 's/^/         /' >&2
    fi
  fi
fi

# ── verdict ──────────────────────────────────────────────────────────────────────
# A real exit 2 happens if EITHER the zero-dep hard check failed OR the heavy container assertion
# (when it actually ran) failed. A missing docker is a recorded SKIP of the heavy path only.
DETAILS="$ZD_MSG"
[ -n "$HEAVY_MSG" ] && DETAILS="${DETAILS}${HEAVY_MSG}"
[ -z "$DETAILS" ] && DETAILS="ok"

if [ "$ZERO_DEP_FAIL" -eq 1 ] || [ "$HEAVY_FAIL" -eq 1 ]; then
  write_report "FAIL" "$MODE" "$MARKER_FOUND" "$Z_HEADING" "$Z_FENCE" "$DETAILS"
  echo "quickstart-check verdict: FAIL ($MODE) -> $REPORT" >&2
  exit 2
fi

if [ "$MODE" = "container" ]; then
  write_report "PASS" "container" "$MARKER_FOUND" "$Z_HEADING" "$Z_FENCE" "quickstart reached $MARKER in a clean container; README onboard-able"
  echo "quickstart-check verdict: PASS (container, marker reached) -> $REPORT" >&2
else
  # zero-dep passed, heavy path skipped (docker absent/unusable). Loud SKIP recorded as verdict SKIP
  # of the heavy assertion, but the gate did its zero-dep work and found no violation -> exit 0.
  write_report "SKIP" "zero-dep" "$MARKER_FOUND" "$Z_HEADING" "$Z_FENCE" "docker unavailable: ran zero-dep README assertion only (heading+fenced block present)"
  echo "quickstart-check verdict: SKIP heavy path (docker unavailable); zero-dep README assertion PASSED -> $REPORT" >&2
fi
exit 0
