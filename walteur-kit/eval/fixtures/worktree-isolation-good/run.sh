#!/usr/bin/env bash
set -euo pipefail

T="$(mktemp -d "${TMPDIR:-/tmp}/walteur-worktree-good.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/repo"
WT_A="$T/agent-a"
WT_B="$T/agent-b"

git init -q "$REPO"
git -C "$REPO" config user.email "walteur@example.invalid"
git -C "$REPO" config user.name "WALTEUR Selftest"
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "init"

git -C "$REPO" worktree add -q -b agent-a "$WT_A" HEAD
git -C "$REPO" worktree add -q -b agent-b "$WT_B" HEAD

printf 'agent-a owns this file\n' > "$WT_A/agent-a.txt"
git -C "$WT_A" add agent-a.txt
git -C "$WT_A" commit -q -m "agent a isolated change"

printf 'agent-b owns this file\n' > "$WT_B/agent-b.txt"
git -C "$WT_B" add agent-b.txt
git -C "$WT_B" commit -q -m "agent b isolated change"

git -C "$REPO" merge -q --no-ff agent-a -m "merge agent a"
git -C "$REPO" merge -q --no-ff agent-b -m "merge agent b"

test -f "$REPO/agent-a.txt"
test -f "$REPO/agent-b.txt"
test -z "$(git -C "$REPO" status --porcelain)"

git -C "$REPO" worktree remove -f "$WT_A"
git -C "$REPO" worktree remove -f "$WT_B"
git -C "$REPO" worktree prune
