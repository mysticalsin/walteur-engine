#!/usr/bin/env bash
# WALTEUR skill-index-build (wrapper) — generate walteur-kit/skill-index.json from a
# Org-style skills library. Maintenance tool, run ONCE per skills-library change.
#
# Usage:
#   bash skill-index-build.sh <skills-root> [out.json] [YYYY-MM-DD]
#
# Delegates parsing to skill-index-build.mjs (node — already a WALTEUR dependency via
# the walteur.js orchestrator). NOT a runtime ship gate; the drift guard is
# skill-index-lint.sh.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "skill-index-build - build a skill-index.json from a Org-style skills library."
  printf '%s\n' "usage: bash skill-index-build.sh <skills-root> [out.json] [YYYY-MM-DD]"
  printf '%s\n' "       bash skill-index-build.sh --selftest | --help"
  printf '%s\n' "report: writes <out.json> (default skill-index.json) - fix recipes: walteur-kit/REMEDIATION.md (## skill-index-build)"
  exit 0 ;;
esac

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --selftest: advertised in --help above, so it MUST be handled here. Without this case the
# flag fell through to `exec node skill-index-build.mjs --selftest`, which treated it as the
# <skills-root> argument and died with a raw node ENOENT stack trace (exit 1).
# Builds a throwaway 2-skill fixture library in TMPDIR and asserts the generated index.
selftest() {
  pass=0; fail=0
  ck() {
    if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1));
    else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi
  }
  for t in node jq mktemp mkdir rm; do
    if ! command -v "$t" >/dev/null 2>&1; then
      echo "skill-index-build selftest SKIP - required tool '$t' not installed (recorded, not silent-green)."
      return 0
    fi
  done
  [ -f "$DIR/skill-index-build.mjs" ] || { echo "skill-index-build selftest FAIL - skill-index-build.mjs missing next to the wrapper."; return 1; }

  echo "skill-index-build selftest:"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sibself.XXXXXX")" || return 1
  mkdir -p "$tmp/lib/04-engineering/api-design" "$tmp/lib/13-legal/nda-builder"
  cat > "$tmp/lib/04-engineering/api-design/SKILL.md" <<'MD'
---
name: api-design
description: Use on every REST and GraphQL contract review. HARD GATE before ship.
---
# api-design
Writes its pass stamp to walteur-kit/api-design.json with a "verdict" key.
MD
  cat > "$tmp/lib/13-legal/nda-builder/SKILL.md" <<'MD'
---
name: nda-builder
description: Draft a mutual nondisclosure agreement from a counterparty brief.
---
# nda-builder
MD
  out="$tmp/skill-index.json"

  bash "$0" "$tmp/lib" "$out" 2026-01-02 >/dev/null 2>&1
  ck "build from fixture library exits 0" 0 "$?"
  jq -e '.schema_version == 1 and .skill_count == 2 and (.skills|length) == 2' "$out" >/dev/null 2>&1
  ck "index reports schema_version 1 and both fixture skills" 0 "$?"
  jq -e '.generated_at == "2026-01-02"' "$out" >/dev/null 2>&1
  ck "stamp date argument is honoured (not today)" 0 "$?"
  jq -e '[.skills[]|select(.skill=="api-design")][0].discipline == "engineering"' "$out" >/dev/null 2>&1
  ck "numbered parent folder 04-* maps to discipline engineering" 0 "$?"
  jq -e '[.skills[]|select(.skill=="nda-builder")][0].discipline == "legal"' "$out" >/dev/null 2>&1
  ck "numbered parent folder 13-* maps to discipline legal" 0 "$?"
  # hard_gate must DISCRIMINATE: true for the skill that declares one, false for the one that does not.
  jq -e '[.skills[]|select(.skill=="api-design")][0].hard_gate == true and [.skills[]|select(.skill=="nda-builder")][0].hard_gate == false' "$out" >/dev/null 2>&1
  ck "hard_gate discriminates declared vs undeclared" 0 "$?"
  jq -e '[.skills[]|select(.skill=="api-design")][0].breadcrumb == "walteur-kit/api-design.json"' "$out" >/dev/null 2>&1
  ck "declared in-body breadcrumb wins over the conventional path" 0 "$?"
  jq -e '[.skills[]|select(.skill=="nda-builder")][0].breadcrumb == "walteur-kit/skills/nda-builder.json"' "$out" >/dev/null 2>&1
  ck "undeclared breadcrumb falls back to the conventional path" 0 "$?"
  rm -rf "$tmp"

  bash "$0" >/dev/null 2>&1
  ck "missing <skills-root> is a loud usage failure" 2 "$?"
  bash "$0" --help >/dev/null 2>&1
  ck "--help exits 0 before any side effect" 0 "$?"
  # Interface contract: a dash-led token the case statements do not implement must be a clean
  # usage error, never a raw node ENOENT stack trace (which exited 1 and named node internals).
  guard_out="$(bash "$0" --no-such-flag 2>&1)"; guard_rc=$?
  ck "unrecognized option exits 2 (usage, not a crash)" 2 "$guard_rc"
  case "$guard_out" in
    *node:fs*|*readdirSync*) ck "unrecognized option output is usage, not a node stack trace" clean "stack-trace" ;;
    *"unrecognized option"*) ck "unrecognized option output is usage, not a node stack trace" clean clean ;;
    *) ck "unrecognized option output is usage, not a node stack trace" clean "unexpected: $guard_out" ;;
  esac

  echo "skill-index-build selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

# Argument guard. The default run takes a POSITIONAL <skills-root>; anything dash-led that
# is not -h/--help/--selftest is an interface error. Without this guard the token was handed
# straight to `exec node` as the directory to scan and surfaced as a raw ENOENT stack trace
# with exit 1 — an operator typo read as an internal crash. Fail loudly with usage, exit 2.
case "${1:-}" in
  -*) printf '%s\n' "skill-index-build: unrecognized option '$1'" >&2
      printf '%s\n' "usage: bash skill-index-build.sh <skills-root> [out.json] [YYYY-MM-DD]" >&2
      printf '%s\n' "       bash skill-index-build.sh --selftest | --help" >&2
      exit 2 ;;
esac

if ! command -v node >/dev/null 2>&1; then
  echo "skill-index-build: node is required to parse the skills library" >&2
  exit 2
fi
exec node "$DIR/skill-index-build.mjs" "$@"
