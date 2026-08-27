#!/usr/bin/env bash
# ops/ci.sh — the real CI entrypoint for the documents-api field build.
#
# Runs the node:test suite (core unit tests + the HTTP integration tests under test/) and EXITS WITH THE
# TEST RUNNER'S EXIT CODE, so a failing test fails CI (deny-by-default: green only when the suite is
# observed green).
#
# Node-version note (honest, load-bearing): the bare directory spec `node --test test/` does NOT work on
# Node >=20/24 — the runner resolves `test/` as a single module path and throws MODULE_NOT_FOUND (exit 1).
# The documented way to run every test file in a directory is the glob form `test/**/*.test.mjs`. That glob
# is the runnable equivalent of "run the suite under test/", and it is what this script and the gate proof
# files declare and execute. We expand the glob in the shell (bash globstar) and pass the explicit file
# list to node, which is portable across Node versions and shells (Git-Bash on Windows included). The core
# unit suite (core.test.mjs) is included alongside so CI proves BOTH layers.
#
# No secret VALUES live here. The suite injects its own short, low-entropy tenant tokens from env inside the
# test files; this script sets nothing secret.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "ci: root=$ROOT"
echo "ci: node=$(node --version)"
echo

shopt -s globstar nullglob
files=( core.test.mjs test/**/*.test.mjs )
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
  echo "ci: FAIL — no test files matched under $ROOT" >&2
  exit 2
fi

echo "ci: running ${#files[@]} test file(s):"
printf '  - %s\n' "${files[@]}"
echo

node --test "${files[@]}"
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "ci: PASS — node --test exited 0"
else
  echo "ci: FAIL — node --test exited $rc"
fi
exit "$rc"
