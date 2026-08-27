#!/usr/bin/env bash
set -euo pipefail

T="$(mktemp -d "${TMPDIR:-/tmp}/walteur-worktree-poison.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/repo"
WT_A="$T/agent-a"
WT_B="$T/agent-b"

git init -q "$REPO"
git -C "$REPO" config user.email "walteur@example.invalid"
git -C "$REPO" config user.name "WALTEUR Selftest"
printf 'base\n' > "$REPO/shared.txt"
git -C "$REPO" add shared.txt
git -C "$REPO" commit -q -m "init"

git -C "$REPO" worktree add -q -b agent-a "$WT_A" HEAD
git -C "$REPO" worktree add -q -b agent-b "$WT_B" HEAD

printf 'agent-a conflicting line\n' > "$WT_A/shared.txt"
git -C "$WT_A" add shared.txt
git -C "$WT_A" commit -q -m "agent a conflicting change"

printf 'agent-b conflicting line\n' > "$WT_B/shared.txt"
git -C "$WT_B" add shared.txt
git -C "$WT_B" commit -q -m "agent b conflicting change"

git -C "$REPO" merge -q --no-ff agent-a -m "merge agent a"

if git -C "$REPO" merge -q --no-ff agent-b -m "merge agent b" >/dev/null 2>&1; then
  echo "poison fixture failed: conflicting worktree branch merged cleanly" >&2
  exit 1
fi

if ! git -C "$REPO" status --porcelain | grep -q '^UU shared.txt'; then
  echo "poison fixture failed: expected shared.txt conflict marker in git status" >&2
  exit 1
fi

git -C "$REPO" merge --abort >/dev/null 2>&1 || true
test -z "$(git -C "$REPO" status --porcelain)"

git -C "$REPO" worktree remove -f "$WT_A"
git -C "$REPO" worktree remove -f "$WT_B"
git -C "$REPO" worktree prune

exit 2
