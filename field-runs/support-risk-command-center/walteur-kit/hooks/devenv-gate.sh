#!/usr/bin/env bash
# WALTEUR devenv-gate — ZERO-DEP hard gate on a reproducible developer environment.
#
# APPLICABILITY (critical — checked FIRST):
#   A code stack must exist. Trigger files (any one, anywhere in the tree, dependency dirs pruned):
#     package.json | pyproject.toml | go.mod | Cargo.toml
#   If NONE exist => a bare/minimal project with no stack => NOT_APPLICABLE, exit 0.
#   exit 2 is reserved for a real violation in an applicable (code-stack) project.
#
# ZERO-DEP HARD RULE (bash + grep + find + jq only — always real exit 2 when applicable):
#   A stack that any contributor can clone must be reproducible across contributors. We require
#   THREE disciplines; a stack missing any of them is "works on my machine" => exit 2:
#     1. .editorconfig            — shared editor formatting baseline.
#     2. A task runner            — Makefile | makefile | GNUmakefile | Justfile/justfile
#                                   | Taskfile.yml/.yaml | Taskfile (Task) | OR npm "scripts" in a
#                                     package.json (a non-empty scripts object).
#     3. A toolchain pin          — .tool-versions | .nvmrc | .node-version | mise.toml/.mise.toml
#                                   | .python-version | rust-toolchain | rust-toolchain.toml
#   A stack with none of (1)+(2)+(3) is not reproducible across contributors.
#
# Exit: 2 on any real violation; 0 on clean / not-applicable.
# Report: walteur-kit/devenv-report.json {verdict, ts, gate, reason, details}.
# Bypass: WALTEUR_DEVENV=off. Pause: walteur-kit/PAUSED present.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/devenv-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

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

  echo "devenv-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/devenv-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no code stack -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/devenv-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{"scripts":{"test":"node -e true"}}\n' > "$tmp/package.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "stack missing editorconfig and toolchain pin -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/devenv-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf 'root = true\n[*]\nend_of_line = lf\n' > "$tmp/.editorconfig"
  printf '20\n' > "$tmp/.node-version"
  printf '{"scripts":{"test":"node -e true"}}\n' > "$tmp/package.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "reproducible stack -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/devenv-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  printf '{}\n' > "$tmp/package.json"
  WALTEUR_ROOT="$tmp" WALTEUR_DEVENV=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/devenv-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "devenv-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_DEVENV:-on}" = "off" ] && { echo "devenv-gate: bypassed (WALTEUR_DEVENV=off)." >&2; exit 0; }

# write_report <verdict> <reason> <details-json-object>
# Falls back to printf if jq is unavailable so a report ALWAYS lands.
write_report() {
  local v="$1" reason="$2" details="${3:-{\}}"
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --argjson d "$details" \
      '{verdict:$v, ts:$ts, gate:"devenv", reason:$reason, details:$d}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"devenv","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
}

# prune-set: never descend dependency / VCS / build dirs (avoids vendored manifests & fixtures).
PRUNE=( -path "$ROOT/.git" -o -path '*/node_modules' -o -path '*/.venv' -o -path '*/venv' \
        -o -path '*/vendor' -o -path '*/dist' -o -path '*/build' -o -path '*/target' \
        -o -path '*/.next' -o -path '*/.output' -o -path "$KIT" )

# find_first <iname...> : print the first matching file path (pruned), or empty.
find_first() {
  local args=() a
  for a in "$@"; do args+=( -iname "$a" -o ); done
  unset 'args[${#args[@]}-1]'   # drop trailing -o
  find "$ROOT" \( "${PRUNE[@]}" \) -prune -o \( "${args[@]}" \) -type f -print 2>/dev/null | head -1
}

# ── APPLICABILITY: a code stack must exist ────────────────────────────────────
STACK_FILE="$(find_first 'package.json' 'pyproject.toml' 'go.mod' 'Cargo.toml')"
if [ -z "$STACK_FILE" ]; then
  echo "devenv-gate: no code stack (no package.json/pyproject.toml/go.mod/Cargo.toml) — gate not applicable." >&2
  write_report "NOT_APPLICABLE" "no code stack present (package.json/pyproject.toml/go.mod/Cargo.toml)" \
    "$(have jq && jq -n '{stack_found:false}' || echo '{}')"
  exit 0
fi

echo "WALTEUR devenv-gate @ $ROOT — code stack: ${STACK_FILE#"$ROOT"/}" >&2

# ── ZERO-DEP HARD RULE: the three reproducibility disciplines ─────────────────
declare -a MISSING=()
EDITORCONFIG_FILE=""
TASKRUNNER_FILE=""
TOOLPIN_FILE=""

# 1. .editorconfig
EDITORCONFIG_FILE="$(find_first '.editorconfig')"
[ -z "$EDITORCONFIG_FILE" ] && MISSING+=("editorconfig:require a .editorconfig (shared editor formatting baseline)")

# 2. task runner — Makefile family / Just / Task, OR npm scripts in a package.json.
TASKRUNNER_FILE="$(find_first 'Makefile' 'makefile' 'GNUmakefile' 'Justfile' 'justfile' \
                              'Taskfile.yml' 'Taskfile.yaml' 'Taskfile')"
if [ -z "$TASKRUNNER_FILE" ] && have jq; then
  # any package.json with a non-empty "scripts" object counts as a task runner.
  while IFS= read -r pj; do
    [ -z "$pj" ] && continue
    if jq -e '(.scripts // {}) | type=="object" and (length>0)' "$pj" >/dev/null 2>&1; then
      TASKRUNNER_FILE="$pj (npm scripts)"; break
    fi
  done < <(find "$ROOT" \( "${PRUNE[@]}" \) -prune -o -name 'package.json' -type f -print 2>/dev/null)
fi
[ -z "$TASKRUNNER_FILE" ] && MISSING+=("task-runner:require a Makefile/Justfile/Taskfile.yml OR npm scripts (one-command tasks)")

# 3. toolchain pin
TOOLPIN_FILE="$(find_first '.tool-versions' '.nvmrc' '.node-version' 'mise.toml' '.mise.toml' \
                           '.python-version' 'rust-toolchain' 'rust-toolchain.toml')"
[ -z "$TOOLPIN_FILE" ] && MISSING+=("toolchain-pin:require .tool-versions/.nvmrc/.node-version/mise.toml/.python-version/rust-toolchain* (pinned versions)")

# ── verdict ───────────────────────────────────────────────────────────────────
rel() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}";; *) printf '%s' "$1";; esac; }

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "WALTEUR devenv-gate: FAIL — code stack present but NOT reproducible across contributors:" >&2
  for m in "${MISSING[@]}"; do echo "  - ${m#*:}" >&2; done
  if have jq; then
    MISS_JSON="$(printf '%s\n' "${MISSING[@]}" | jq -R 'split(":")|{check:.[0], reason:(.[1:]|join(":"))}' | jq -s '.')"
    write_report "FAIL" "${#MISSING[@]} reproducibility discipline(s) missing" \
      "$(jq -n --arg sf "$(rel "$STACK_FILE")" --argjson miss "$MISS_JSON" \
        '{stack_found:true, stack_file:$sf,
          editorconfig:false, task_runner:false, toolchain_pin:false,
          missing:$miss}')"
  else
    write_report "FAIL" "${#MISSING[@]} reproducibility discipline(s) missing" '{}'
  fi
  echo "devenv-gate verdict: FAIL (${#MISSING[@]} missing) -> $REPORT" >&2
  exit 2
fi

echo "  ok   — .editorconfig:    $(rel "$EDITORCONFIG_FILE")" >&2
echo "  ok   — task runner:      $(rel "$TASKRUNNER_FILE")" >&2
echo "  ok   — toolchain pin:    $(rel "$TOOLPIN_FILE")" >&2

if have jq; then
  write_report "PASS" "code stack is reproducible (.editorconfig + task runner + toolchain pin present)" \
    "$(jq -n --arg sf "$(rel "$STACK_FILE")" --arg ec "$(rel "$EDITORCONFIG_FILE")" \
            --arg tr "$(rel "$TASKRUNNER_FILE")" --arg tp "$(rel "$TOOLPIN_FILE")" \
      '{stack_found:true, stack_file:$sf,
        editorconfig:$ec, task_runner:$tr, toolchain_pin:$tp,
        missing:[]}')"
else
  write_report "PASS" "code stack is reproducible" '{}'
fi

echo "devenv-gate verdict: PASS -> $REPORT" >&2
exit 0
