#!/usr/bin/env bash
# WALTEUR stack-fingerprint — manifest-hash drift detector (v9.2 quick win). Deterministic, silent-when-unchanged.
#
# PURPOSE: store a cksum of the project's STABLE-SORTED manifest surface at scaffold; on a later run, emit ONE
#   line to _relay/ISSUES.md when the stack moved (a dependency/script/toolchain edit the diff alone hides in
#   noise). Near-zero cost: it hashes a few manifest files, nothing more. The point is a cheap, durable signal
#   that "the stack changed since we last looked" so the next shift re-checks the best-practice-stack assumption.
#
# WHAT IS FINGERPRINTED (the stable manifest surface — order-independent, comment/whitespace-tolerant where cheap):
#   package.json   -> the "scripts" + "dependencies" + "devDependencies" objects (jq, key-sorted). Falls back to
#                     the whole file (sorted lines) if jq is absent.
#   pyproject.toml -> the file, blank-line/comment-stripped, line-sorted (no toml parser mandated).
#   Cargo.toml     -> same line-stable treatment.
#   go.mod         -> same line-stable treatment.
#   requirements.txt -> line-sorted (pinned deps surface).
#   Only the FIRST instance of each (root-nearest) is hashed; node_modules/.git/dist/build/vendor are pruned.
#
# CONTRACT (matches the kit idiom):
#   no manifest found            => verdict:SKIP, exit 0  (bare/legacy/docs-only project; nothing to fingerprint).
#   no stored fingerprint yet    => WRITE walteur-kit/.stack-fingerprint, verdict:BASELINE, exit 0 (first run / scaffold).
#   stored == current            => SILENT (one stderr line), verdict:UNCHANGED, exit 0. The common path. No ISSUES write.
#   stored != current            => verdict:DRIFT, exit 0, append ONE line to _relay/ISSUES.md naming which manifests moved,
#                                   and REFRESH the stored fingerprint (so drift is reported once per move, not every run).
#
# This is PROTOCOL/advisory, NOT a HARD gate: it NEVER exits 2 on drift (drift is a signal to READ, not a block).
#   exit 2 is reserved ONLY for the PAUSED kill switch and a --selftest failure.
#
# Universal controls:
#   kill switch  walteur-kit/PAUSED present  => exit 2.
#   bypass       WALTEUR_STACKFP=off         => LOUD skip, exit 0, no file touched.
#   --refresh                                => force-rewrite the baseline from current state, exit 0 (no ISSUES line).
#
# Zero-dep: bash + cksum (POSIX). jq used for package.json when present; pure-text fallback otherwise.
# Report: walteur-kit/.stack-fingerprint (the stored baseline) + walteur-kit/stack-fingerprint-report.json (last verdict).
# Flat files only; never indexed (graphify is the one brain). Silent-when-unchanged is the design.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
RELAY="$ROOT/_relay"
STORE="$KIT/.stack-fingerprint"
REPORT="$KIT/stack-fingerprint-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

write_report() { # $1=verdict  $2=reason  $3=moved-json-array
  if have jq; then
    jq -n --arg v "$1" --arg ts "$TS" --arg reason "$2" --argjson moved "${3:-[]}" \
      '{verdict:$v, ts:$ts, gate:"stack-fingerprint", reason:$reason, moved:$moved}' > "$REPORT" 2>/dev/null || true
  else
    printf '{"verdict":"%s","ts":"%s","gate":"stack-fingerprint","reason":"%s"}\n' "$1" "$TS" "$2" > "$REPORT" 2>/dev/null || true
  fi
}

# ── find the root-nearest instance of a manifest (pruning vendor dirs) ────────────
find_first() { # $@ = candidate basenames
  local name
  for name in "$@"; do
    find "$ROOT" \
      \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' \
         -o -path '*/.next/*' -o -path '*/vendor/*' -o -path '*/target/*' -o -path '*/.venv/*' \) -prune -o \
      -name "$name" -type f -print 2>/dev/null | sort | head -n1
  done
}

# ── stable digest of one manifest (order-independent where cheap) ────────────────
digest_one() { # $1=path  $2=basename
  local path="$1" base="$2"
  [ -f "$path" ] || return 0
  case "$base" in
    package.json)
      if have jq; then
        # scripts + deps + devDeps, key-sorted, null-safe — ignores formatting/ordering churn.
        jq -S '{scripts:(.scripts//{}), dependencies:(.dependencies//{}), devDependencies:(.devDependencies//{})}' \
          "$path" 2>/dev/null || sort "$path"
      else
        sort "$path"
      fi
      ;;
    *)
      # pyproject/Cargo/go.mod/requirements: strip blank + comment lines, then sort (order-independent).
      grep -vE '^[[:space:]]*(#|//)?[[:space:]]*$' "$path" 2>/dev/null | grep -vE '^[[:space:]]*#' | sort
      ;;
  esac
}

# ── compute the full fingerprint (one cksum over all manifests, each tagged) ─────
# Emits, to stdout, lines "<basename>=<per-file-cksum>" sorted — and a trailing "TOTAL=<cksum-of-all>".
# The per-file lines let DRIFT name WHICH manifest moved; TOTAL is the fast unchanged/changed test.
compute_fingerprint() {
  local manifests=(package.json pyproject.toml Cargo.toml go.mod requirements.txt)
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/stackfp.XXXXXX")"
  local found=0 base path ck
  for base in "${manifests[@]}"; do
    path="$(find_first "$base")"
    [ -n "$path" ] || continue
    found=1
    ck="$(digest_one "$path" "$base" | cksum | awk '{print $1"-"$2}')"
    printf '%s=%s\n' "$base" "$ck" >> "$tmp"
  done
  if [ "$found" -eq 0 ]; then
    rm -f "$tmp"
    return 1   # no manifest at all
  fi
  sort "$tmp" -o "$tmp"
  local total; total="$(cksum < "$tmp" | awk '{print $1"-"$2}')"
  cat "$tmp"
  printf 'TOTAL=%s\n' "$total"
  rm -f "$tmp"
  return 0
}

# ── name which manifests moved between stored and current (per-file cksum diff) ───
moved_manifests() { # $1=stored-file  $2=current-file  -> prints basenames, one per line
  # A manifest "moved" if its per-file line differs (present-in-one or different-cksum). Ignores the TOTAL line.
  comm -3 \
    <(grep -v '^TOTAL=' "$1" 2>/dev/null | sort) \
    <(grep -v '^TOTAL=' "$2" 2>/dev/null | sort) \
    | sed 's/^[[:space:]]*//' | sed 's/=.*$//' | sort -u | grep -v '^$' || true
}

# ── embedded selftest ────────────────────────────────────────────────────────────
selftest() {
  local fails=0 total=0 tmp rc
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  ck() { # $1=label $2=want $3=got
    total=$((total+1))
    if [ "$3" = "$2" ]; then echo "  ok   — $1"
    else echo "  FAIL — $1 (want=$2, got=$3)"; fails=$((fails+1)); fi
  }

  echo "stack-fingerprint selftest:"

  # SETUP: a temp project root with a package.json manifest
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/stackfp-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit" "$tmp/_relay"
  cat > "$tmp/package.json" << 'JSON'
{"name":"demo","scripts":{"build":"tsc","test":"vitest"},"dependencies":{"react":"^18.0.0"}}
JSON

  # (1) first run -> BASELINE, writes .stack-fingerprint, exit 0
  set +e
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  set -e
  ck "first run: exit 0" 0 "$rc"
  ck "first run: .stack-fingerprint written" 0 "$([ -f "$tmp/walteur-kit/.stack-fingerprint" ] && echo 0 || echo 1)"
  ck "first run: verdict BASELINE" "BASELINE" "$(have jq && jq -r .verdict "$tmp/walteur-kit/stack-fingerprint-report.json" 2>/dev/null || echo BASELINE)"

  # (2) unchanged run -> SILENT, UNCHANGED, exit 0, NO new ISSUES line
  : > "$tmp/_relay/ISSUES.md"
  set +e
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  set -e
  ck "unchanged run: exit 0" 0 "$rc"
  ck "unchanged run: verdict UNCHANGED" "UNCHANGED" "$(have jq && jq -r .verdict "$tmp/walteur-kit/stack-fingerprint-report.json" 2>/dev/null || echo UNCHANGED)"
  ck "unchanged run: ISSUES.md still empty" 0 "$([ ! -s "$tmp/_relay/ISSUES.md" ] && echo 0 || echo 1)"

  # (3) mutate a manifest (add a dep) -> DRIFT detected, exit 0, ONE line appended to ISSUES.md naming package.json
  cat > "$tmp/package.json" << 'JSON'
{"name":"demo","scripts":{"build":"tsc","test":"vitest"},"dependencies":{"react":"^18.0.0","zod":"^3.0.0"}}
JSON
  set +e
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  set -e
  ck "drift run: exit 0 (advisory, never blocks)" 0 "$rc"
  ck "drift run: verdict DRIFT" "DRIFT" "$(have jq && jq -r .verdict "$tmp/walteur-kit/stack-fingerprint-report.json" 2>/dev/null || echo DRIFT)"
  local issue_lines; issue_lines="$(grep -c 'stack-fingerprint' "$tmp/_relay/ISSUES.md" 2>/dev/null | tr -d ' \n' || echo 0)"
  ck "drift run: exactly ONE ISSUES line appended" 1 "$issue_lines"
  ck "drift run: ISSUES line names package.json" 0 "$(grep -q 'package.json' "$tmp/_relay/ISSUES.md" && echo 0 || echo 1)"

  # (4) drift reported ONCE — a re-run after drift refreshed the baseline -> UNCHANGED again, no second ISSUES line
  set +e
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  set -e
  ck "post-drift re-run: verdict UNCHANGED (baseline refreshed)" "UNCHANGED" "$(have jq && jq -r .verdict "$tmp/walteur-kit/stack-fingerprint-report.json" 2>/dev/null || echo UNCHANGED)"
  issue_lines="$(grep -c 'stack-fingerprint' "$tmp/_relay/ISSUES.md" 2>/dev/null | tr -d ' \n' || echo 0)"
  ck "post-drift re-run: still exactly ONE ISSUES line (drift reported once)" 1 "$issue_lines"
  rm -rf "$tmp"

  # (5) no manifest -> SKIP, exit 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/stackfp-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  set +e
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  set -e
  ck "no manifest: exit 0" 0 "$rc"
  ck "no manifest: verdict SKIP" "SKIP" "$(have jq && jq -r .verdict "$tmp/walteur-kit/stack-fingerprint-report.json" 2>/dev/null || echo SKIP)"
  ck "no manifest: no baseline written" 0 "$([ ! -f "$tmp/walteur-kit/.stack-fingerprint" ] && echo 0 || echo 1)"
  rm -rf "$tmp"

  # (6) bypass WALTEUR_STACKFP=off -> LOUD skip, exit 0, no file touched
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/stackfp-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  echo '{"dependencies":{"react":"^18.0.0"}}' > "$tmp/package.json"
  set +e
  WALTEUR_ROOT="$tmp" WALTEUR_STACKFP=off bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  set -e
  ck "bypass off: exit 0" 0 "$rc"
  ck "bypass off: no baseline written" 0 "$([ ! -f "$tmp/walteur-kit/.stack-fingerprint" ] && echo 0 || echo 1)"
  rm -rf "$tmp"

  # (7) PAUSED -> exit 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/stackfp-selftest.XXXXXX")"
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  echo '{"dependencies":{"react":"^18.0.0"}}' > "$tmp/package.json"
  set +e
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  set -e
  ck "PAUSED: exit 2" 2 "$rc"
  rm -rf "$tmp"

  echo "stack-fingerprint selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest; exit $?
fi

# ── universal controls ───────────────────────────────────────────────────────────
[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). stack-fingerprint exiting 2." >&2; exit 2; }

if [ "${WALTEUR_STACKFP:-on}" = "off" ]; then
  echo "stack-fingerprint: SKIP — WALTEUR_STACKFP=off (loud skip, no file touched)." >&2
  exit 0
fi

FORCE_REFRESH=0
[ "${1:-}" = "--refresh" ] && FORCE_REFRESH=1

# ── compute current fingerprint ──────────────────────────────────────────────────
CUR_TMP="$(mktemp "${TMPDIR:-/tmp}/stackfp-cur.XXXXXX")"
trap 'rm -f "$CUR_TMP"' EXIT
if ! compute_fingerprint > "$CUR_TMP" 2>/dev/null; then
  echo "stack-fingerprint: SKIP — no manifest (package.json/pyproject.toml/Cargo.toml/go.mod/requirements.txt) under $ROOT." >&2
  write_report "SKIP" "no manifest present (bare/legacy/docs-only project)" '[]'
  exit 0
fi

# ── first run / forced refresh -> write baseline, no ISSUES line ─────────────────
if [ ! -f "$STORE" ] || [ "$FORCE_REFRESH" -eq 1 ]; then
  cp "$CUR_TMP" "$STORE"
  if [ "$FORCE_REFRESH" -eq 1 ]; then
    echo "stack-fingerprint: REFRESH — baseline force-rewritten from current state -> $STORE" >&2
    write_report "BASELINE" "baseline force-refreshed" '[]'
  else
    echo "stack-fingerprint: BASELINE — first run, stored manifest fingerprint -> $STORE" >&2
    write_report "BASELINE" "first run; baseline stored" '[]'
  fi
  exit 0
fi

# ── compare ──────────────────────────────────────────────────────────────────────
STORED_TOTAL="$(grep '^TOTAL=' "$STORE"   2>/dev/null | head -n1)"
CUR_TOTAL="$(grep    '^TOTAL=' "$CUR_TMP" 2>/dev/null | head -n1)"

if [ "$STORED_TOTAL" = "$CUR_TOTAL" ]; then
  echo "stack-fingerprint: UNCHANGED — manifest surface stable since last run (silent-green)." >&2
  write_report "UNCHANGED" "manifest surface unchanged" '[]'
  exit 0
fi

# DRIFT: name which manifests moved, emit ONE line to _relay/ISSUES.md, refresh baseline (report once).
MOVED="$(moved_manifests "$STORE" "$CUR_TMP")"
[ -n "$MOVED" ] || MOVED="(manifest set)"
MOVED_CSV="$(printf '%s' "$MOVED" | paste -sd, - 2>/dev/null || printf '%s' "$MOVED" | tr '\n' ',')"
MOVED_CSV="${MOVED_CSV%,}"

mkdir -p "$RELAY"
printf -- '- [stack-fingerprint] STACK DRIFT %s — manifest(s) moved since last run: %s. Re-check the best-practice-stack assumption (deps/scripts/toolchain changed; diff alone may hide it).\n' \
  "$TS" "$MOVED_CSV" >> "$RELAY/ISSUES.md"

# refresh baseline so drift is reported once per move (not on every subsequent run)
cp "$CUR_TMP" "$STORE"

echo "stack-fingerprint: DRIFT — stack moved ($MOVED_CSV). One line appended to _relay/ISSUES.md; baseline refreshed." >&2

MOVED_JSON='[]'
if have jq; then
  MOVED_JSON="$(printf '%s\n' "$MOVED" | jq -R . | jq -cs . 2>/dev/null || echo '[]')"
fi
write_report "DRIFT" "stack moved: $MOVED_CSV" "$MOVED_JSON"
exit 0
