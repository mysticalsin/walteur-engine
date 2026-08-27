#!/usr/bin/env bash
# ci.sh — the real CI entrypoint for the multitenant-tasks field build.
#
# Runs the node:test suite under test/ and EXITS WITH THE TEST RUNNER'S EXIT CODE,
# so a failing test fails CI (deny-by-default: green only when the suite is observed green).
#
# Node-version note (honest, load-bearing): the bare directory spec `node --test test/`
# does NOT work on Node >=20/24 — the runner resolves `test/` as a single module path and
# throws MODULE_NOT_FOUND (exit 1). The documented way to run every test file in a directory
# is the glob form `test/**/*.test.mjs`. That glob is the runnable equivalent of "run the suite
# under test/", and it is what this script and ops/pipeline-proof.json both declare and execute.
# We expand the glob in the shell (bash globstar) and pass the explicit file list to node, which
# is portable across Node versions and shells (Git-Bash on Windows included).
#
# No secret VALUES live here. The suite injects its own short, low-entropy tenant tokens from
# env inside the test files; this script sets nothing secret.

set -uo pipefail

# Resolve the build root from this script's location so `bash ci.sh` works from anywhere.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# The canonical suite directory and selector. Keep this string in sync with
# ops/pipeline-proof.json -> pipeline_probe.command.
SUITE_DIR="test"
SUITE_GLOB="test/**/*.test.mjs"

echo "ci: root=$ROOT"
echo "ci: node=$(node --version)"
echo "ci: suite=$SUITE_GLOB"
echo

# Expand the glob safely. globstar makes ** recurse; nullglob makes an empty match a hard error
# below instead of passing a literal '*' to node.
shopt -s globstar nullglob
files=( $SUITE_GLOB )
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
  echo "ci: FAIL — no test files matched $SUITE_GLOB under $ROOT" >&2
  exit 2
fi

echo "ci: running ${#files[@]} test file(s):"
printf '  - %s\n' "${files[@]}"
echo

# Run the real suite. Do NOT swallow node's exit code — it is the CI verdict.
node --test "${files[@]}"
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "ci: PASS — node --test exited 0"
else
  echo "ci: FAIL — node --test exited $rc"
fi
exit "$rc"
