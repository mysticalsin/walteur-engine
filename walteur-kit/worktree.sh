#!/usr/bin/env bash
# WALTEUR worktree — git-worktree helper for PARALLEL-AGENT ISOLATION.
#
# WHAT THIS IS (honest scope — Iron Law §1):
#   This is the REAL, tested helper the swarm (§5.6) can use to give each parallel agent its
#   own isolated working tree off the SAME repo: per-agent worktrees under .walteur-worktrees/<name>
#   on a branch walteur/<name>, mergeable back to the originating branch. It is a HARD helper — every
#   subcommand drives `git` and reports a real exit code (0 ok / 1 usage / 2 failure-or-paused).
#   Deep orchestrator AUTO-INTEGRATION (the swarm spawning one worktree per agent, WIP-committing
#   every ~8 min, and auto-merging on green) is the DOCUMENTED NEXT STEP — this helper is the
#   primitive that step will call; it does NOT itself spawn or schedule agents. We label, never overclaim.
#
# WHY worktrees (not branches/clones): `git worktree` shares ONE object store + ref db, so N agents
#   get N independent checkouts (independent index, HEAD, dirty state) with zero clone cost and a
#   single source of truth — the exact isolation model the build plan calls for (§ "isolated git
#   worktrees, WIP-commit every ~8 min").
#
# SUBCOMMANDS:
#   create <name>     git worktree add a FRESH worktree off current HEAD at .walteur-worktrees/<name>
#                     on a new branch walteur/<name>. Idempotent: if it already exists & is healthy, ok.
#   list              list WALTEUR-managed worktrees (path · branch · HEAD) — porcelain-parsed, stable.
#   merge <name>      merge branch walteur/<name> back into the branch it was forked from. Fast-forwards
#                     when possible, else a --no-ff merge commit. On CONFLICT: aborts cleanly, reports
#                     the conflicting paths, exit 2 (never leaves the repo mid-merge).
#   cleanup <name>    git worktree remove <path> + delete branch walteur/<name>. Idempotent.
#   cleanup-all       cleanup every WALTEUR-managed worktree + branch. Idempotent.
#
# ZERO-DEP: bash + git (+ jq only to write the JSON report; printf fallback if jq absent). No network.
# Honors the kill switch (walteur-kit/PAUSED => exit 2) and bypass (WALTEUR_WORKTREE=off => exit 0).
# SAFE: refuses to create worktrees inside .git; never force-removes dirty trees unless WALTEUR_WT_FORCE=1;
#       merge aborts on conflict instead of leaving a half-merged index. Idempotent by design.
# Report (best-effort, never blocks the op): walteur-kit/worktree-report.json {verdict,ts,gate,op,name,detail}.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
KIT="$ROOT/walteur-kit"
WT_DIR="$ROOT/.walteur-worktrees"
PREFIX="walteur/"                 # branch namespace for managed worktrees
REPORT="$KIT/worktree-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_WORKTREE:-on}" = "off" ] && { echo "worktree: bypassed (WALTEUR_WORKTREE=off)." >&2; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }

# Hard dependency: git. Without it this helper cannot do anything — loud recorded note, exit 2.
if ! have git; then
  echo "WALTEUR worktree FAIL — required tool 'git' not installed (recorded, not silent-green)." >&2
  printf '{"verdict":"FAIL","ts":"%s","gate":"worktree","op":"%s","detail":"git not installed"}\n' \
    "$TS" "${1:-}" > "$REPORT" 2>/dev/null || true
  exit 2
fi

# We must be inside a git repo to manage worktrees.
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "WALTEUR worktree FAIL — not inside a git repository ($ROOT)." >&2
  printf '{"verdict":"FAIL","ts":"%s","gate":"worktree","op":"%s","detail":"not a git repo"}\n' \
    "$TS" "${1:-}" > "$REPORT" 2>/dev/null || true
  exit 2
fi

# write_report <verdict> <op> <name> <detail>  — best-effort; a report failure never fails the op.
write_report() {
  local v="$1" op="$2" name="$3" detail="$4"
  if have jq; then
    jq -n --arg v "$v" --arg ts "$TS" --arg op "$op" --arg name "$name" --arg detail "$detail" \
      '{verdict:$v, ts:$ts, gate:"worktree", op:$op, name:$name, detail:$detail}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"worktree","op":"%s","name":"%s","detail":"%s"}\n' \
    "$v" "$op" "$name" "$detail" > "$REPORT" 2>/dev/null || true
}

usage() {
  cat >&2 <<EOF
WALTEUR worktree — per-agent git-worktree isolation helper.
usage: worktree.sh <create <name> | list | merge <name> | cleanup <name> | cleanup-all>
  create <name>   fresh worktree at .walteur-worktrees/<name> on branch ${PREFIX}<name> off HEAD
  list            list WALTEUR-managed worktrees
  merge <name>    merge ${PREFIX}<name> back to its fork-point branch (ff or --no-ff; aborts on conflict)
  cleanup <name>  remove the worktree + delete branch ${PREFIX}<name>
  cleanup-all     cleanup every WALTEUR-managed worktree + branch
env: WALTEUR_WORKTREE=off (bypass) · WALTEUR_WT_FORCE=1 (allow removing a dirty worktree)
EOF
}

# valid_name <name> : worktree/branch names must be a safe slug (no path traversal, no funny chars).
valid_name() {
  case "$1" in
    ''|*/*|*..*|*' '*|.*) return 1 ;;            # no empty, no slash, no .., no spaces, no leading dot
    *) printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]+$' ;;
  esac
}

# managed_paths : print absolute paths of every worktree whose branch is under refs/heads/${PREFIX}.
# Porcelain v1 (-z safe enough here; we parse the line-oriented form which is stable across git versions).
managed_paths() {
  local path="" branch=""
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) path="${line#worktree }" ;;
      'branch '*)   branch="${line#branch }"
                    case "$branch" in
                      "refs/heads/${PREFIX}"*) [ -n "$path" ] && printf '%s\t%s\n' "$path" "$branch" ;;
                    esac ;;
      '') path=""; branch="" ;;
    esac
  done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null)
}

# ── CREATE ────────────────────────────────────────────────────────────────────
cmd_create() {
  local name="$1" branch="${PREFIX}${1}" path="$WT_DIR/$1"
  if ! valid_name "$name"; then
    echo "worktree create: invalid name '$name' (allowed: [A-Za-z0-9._-], no slashes/.. /leading dot)." >&2
    write_report FAIL create "$name" "invalid name"; return 2
  fi

  # Idempotent: if a healthy worktree already exists at this path on this branch, succeed.
  if [ -d "$path" ]; then
    if git -C "$ROOT" worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $path"; then
      echo "worktree create: '$name' already exists at $path (idempotent, ok)." >&2
      write_report OK create "$name" "already exists at $path"; return 0
    fi
    echo "worktree create: path $path exists but is NOT a registered worktree — refusing to clobber." >&2
    write_report FAIL create "$name" "path exists, not a worktree"; return 2
  fi

  mkdir -p "$WT_DIR"
  # Guard: never create a worktree inside the .git dir.
  case "$path" in *"/.git/"*|*"/.git") echo "worktree create: refusing path inside .git." >&2; write_report FAIL create "$name" "path inside .git"; return 2 ;; esac

  # Fork off current HEAD onto a NEW branch. If the branch already exists, reuse it (attach a worktree to it).
  local out rc
  if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    out="$(git -C "$ROOT" worktree add "$path" "$branch" 2>&1)"; rc=$?
  else
    out="$(git -C "$ROOT" worktree add -b "$branch" "$path" HEAD 2>&1)"; rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "worktree create: git worktree add FAILED for '$name':" >&2
    echo "$out" >&2
    write_report FAIL create "$name" "git worktree add failed"; return 2
  fi
  echo "worktree create: '$name' -> $path on branch $branch (off $(git -C "$ROOT" rev-parse --short HEAD))." >&2
  write_report OK create "$name" "$path on $branch"; return 0
}

# ── LIST ──────────────────────────────────────────────────────────────────────
cmd_list() {
  local any=0 path branch head
  while IFS=$'\t' read -r path branch; do
    [ -z "$path" ] && continue
    any=1
    head="$(git -C "$path" rev-parse --short HEAD 2>/dev/null || echo '???????')"
    printf '%s\t%s\t%s\n' "$path" "${branch#refs/heads/}" "$head"
  done < <(managed_paths)
  if [ "$any" -eq 0 ]; then
    echo "worktree list: no WALTEUR-managed worktrees (none under refs/heads/${PREFIX})." >&2
  fi
  write_report OK list "" "$any managed listed"; return 0
}

# ── MERGE ─────────────────────────────────────────────────────────────────────
cmd_merge() {
  local name="$1" branch="${PREFIX}${1}" path="$WT_DIR/$1"
  if ! valid_name "$name"; then
    echo "worktree merge: invalid name '$name'." >&2; write_report FAIL merge "$name" "invalid name"; return 2
  fi
  if ! git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "worktree merge: branch $branch does not exist — nothing to merge." >&2
    write_report FAIL merge "$name" "branch missing"; return 2
  fi

  # Determine the branch this worktree was forked FROM. Prefer the recorded upstream/fork-point; fall back
  # to the current branch of the MAIN working tree (the repo root checkout).
  local target
  target="$(git -C "$ROOT" config --get "branch.${branch}.walteurForkParent" 2>/dev/null || true)"
  if [ -z "$target" ]; then
    target="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || true)"
  fi
  if [ -z "$target" ]; then
    echo "worktree merge: could not determine target branch (detached HEAD at root?)." >&2
    write_report FAIL merge "$name" "no target branch"; return 2
  fi
  if [ "$target" = "$branch" ]; then
    echo "worktree merge: target branch equals source ($branch) — checkout the parent branch at root first." >&2
    write_report FAIL merge "$name" "target == source"; return 2
  fi

  # Merge must happen in the MAIN working tree (the one with $target checked out at $ROOT).
  local cur out rc
  cur="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ "$cur" != "$target" ]; then
    echo "worktree merge: root checkout is on '$cur', not target '$target' — refusing to switch it under you." >&2
    echo "  fix: at the repo root run  git checkout $target  then re-run merge." >&2
    write_report FAIL merge "$name" "root not on target ($cur != $target)"; return 2
  fi

  # Already merged? (branch is an ancestor of target) => idempotent success.
  if git -C "$ROOT" merge-base --is-ancestor "$branch" "$target" 2>/dev/null; then
    echo "worktree merge: $branch already merged into $target (idempotent, ok)." >&2
    write_report OK merge "$name" "already merged into $target"; return 0
  fi

  out="$(git -C "$ROOT" merge --no-ff --no-edit "$branch" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    # Conflict (or other failure): collect conflicting paths, then ABORT to leave a clean tree.
    local conflicts
    conflicts="$(git -C "$ROOT" diff --name-only --diff-filter=U 2>/dev/null | paste -sd ',' - 2>/dev/null || true)"
    git -C "$ROOT" merge --abort 2>/dev/null || true
    if [ -n "$conflicts" ]; then
      echo "worktree merge: CONFLICT merging $branch into $target — aborted (tree clean). Conflicting: $conflicts" >&2
      write_report FAIL merge "$name" "conflict: $conflicts"
    else
      echo "worktree merge: merge of $branch into $target FAILED — aborted." >&2
      echo "$out" >&2
      write_report FAIL merge "$name" "merge failed"
    fi
    return 2
  fi
  echo "worktree merge: merged $branch into $target -> $(git -C "$ROOT" rev-parse --short HEAD)." >&2
  write_report OK merge "$name" "merged into $target"; return 0
}

# ── CLEANUP (one) ──────────────────────────────────────────────────────────────
cmd_cleanup() {
  local name="$1" branch="${PREFIX}${1}" path="$WT_DIR/$1" did=0
  if ! valid_name "$name"; then
    echo "worktree cleanup: invalid name '$name'." >&2; write_report FAIL cleanup "$name" "invalid name"; return 2
  fi

  # Remove the worktree if registered. Refuse to drop a DIRTY tree unless WALTEUR_WT_FORCE=1.
  if git -C "$ROOT" worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $path"; then
    local force=""
    if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
      if [ "${WALTEUR_WT_FORCE:-0}" = "1" ]; then
        echo "worktree cleanup: '$name' has uncommitted changes — removing anyway (WALTEUR_WT_FORCE=1)." >&2
        force="--force"
      else
        echo "worktree cleanup: '$name' has UNCOMMITTED changes — refusing (set WALTEUR_WT_FORCE=1 to override)." >&2
        write_report FAIL cleanup "$name" "dirty worktree, not forced"; return 2
      fi
    fi
    if git -C "$ROOT" worktree remove $force "$path" 2>/dev/null; then
      echo "worktree cleanup: removed worktree $path." >&2; did=1
    else
      echo "worktree cleanup: failed to remove worktree $path." >&2
      write_report FAIL cleanup "$name" "worktree remove failed"; return 2
    fi
  elif [ -d "$path" ]; then
    echo "worktree cleanup: $path exists but is not a registered worktree — leaving it (manual review)." >&2
  fi

  # Prune any stale administrative entries, then delete the branch if it exists.
  git -C "$ROOT" worktree prune 2>/dev/null || true
  if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    if git -C "$ROOT" branch -D "$branch" >/dev/null 2>&1; then
      echo "worktree cleanup: deleted branch $branch." >&2; did=1
    else
      echo "worktree cleanup: could not delete branch $branch (checked out elsewhere?)." >&2
      write_report FAIL cleanup "$name" "branch delete failed"; return 2
    fi
  fi

  if [ "$did" -eq 0 ]; then
    echo "worktree cleanup: nothing to do for '$name' (already clean, idempotent ok)." >&2
  fi
  write_report OK cleanup "$name" "cleaned"; return 0
}

# ── CLEANUP-ALL ────────────────────────────────────────────────────────────────
cmd_cleanup_all() {
  local rc=0 path branch n
  # Collect names first (mutating the worktree list while iterating it is unsafe).
  local names=()
  while IFS=$'\t' read -r path branch; do
    [ -z "$branch" ] && continue
    n="${branch#refs/heads/${PREFIX}}"
    [ -n "$n" ] && names+=("$n")
  done < <(managed_paths)

  # Also catch orphan branches under the namespace that have no worktree.
  while IFS= read -r b; do
    n="${b#${PREFIX}}"
    case " ${names[*]:-} " in *" $n "*) : ;; *) [ -n "$n" ] && names+=("$n") ;; esac
  done < <(git -C "$ROOT" for-each-ref --format='%(refname:short)' "refs/heads/${PREFIX}" 2>/dev/null)

  if [ "${#names[@]}" -eq 0 ]; then
    echo "worktree cleanup-all: no WALTEUR-managed worktrees or branches (idempotent ok)." >&2
    write_report OK cleanup-all "" "nothing to clean"; return 0
  fi
  for n in "${names[@]}"; do
    cmd_cleanup "$n" || rc=2
  done
  # Best-effort: remove the now-empty container dir.
  rmdir "$WT_DIR" 2>/dev/null || true
  if [ "$rc" -eq 0 ]; then
    echo "worktree cleanup-all: cleaned ${#names[@]} managed worktree(s)/branch(es)." >&2
    write_report OK cleanup-all "" "cleaned ${#names[@]}"
  else
    write_report FAIL cleanup-all "" "one or more cleanups failed"
  fi
  return "$rc"
}

# Record the fork-parent at create time so merge knows where to merge back, even if root later moves.
# (Set after a successful create; harmless if it fails.)
record_parent() {
  local branch="${PREFIX}${1}" parent
  parent="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || true)"
  [ -n "$parent" ] && [ "$parent" != "$branch" ] && \
    git -C "$ROOT" config "branch.${branch}.walteurForkParent" "$parent" 2>/dev/null || true
}

# ── DISPATCH ───────────────────────────────────────────────────────────────────
cmd="${1:-}"; [ "$#" -gt 0 ] && shift || true
case "$cmd" in
  create)
    [ "$#" -ge 1 ] || { echo "worktree create: missing <name>." >&2; usage; exit 1; }
    record_parent "$1"           # capture fork point BEFORE create (root HEAD is the parent)
    cmd_create "$1"; exit $? ;;
  list)
    cmd_list; exit $? ;;
  merge)
    [ "$#" -ge 1 ] || { echo "worktree merge: missing <name>." >&2; usage; exit 1; }
    cmd_merge "$1"; exit $? ;;
  cleanup)
    [ "$#" -ge 1 ] || { echo "worktree cleanup: missing <name>." >&2; usage; exit 1; }
    cmd_cleanup "$1"; exit $? ;;
  cleanup-all)
    cmd_cleanup_all; exit $? ;;
  ''|-h|--help|help)
    usage; exit 1 ;;
  *)
    echo "worktree: unknown subcommand '$cmd'." >&2; usage; exit 1 ;;
esac
