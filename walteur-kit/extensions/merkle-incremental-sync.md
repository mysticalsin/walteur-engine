# graphify EXTENSION — incremental change-detector (shell twin)

> **One brain.** graphify stays the single retrieval brain — this is NOT a second index/store/KG.

**Use graphify's NATIVE path first.** graphify already ships incremental detection — `detect_incremental`,
a content-hash manifest, `--watch`, and a `graphify hook install` post-commit re-extractor. For 99% of cases
that IS the answer; add nothing.

**This shell twin is justified ONLY when** graphify's Python path can't run: a venv-free **CI delta** you can
read without importing graphify, or a **manifest-drift cross-check**. It computes `{added,removed,modified}`
vs a snapshot and hands graphify the set — it re-ingests NOTHING itself.

**Honesty (§1):** before claiming "we re-graph incrementally," prove a graphify ingestion hook is wired
(`graphify hook status`); this sketch only computes the delta. Lifted as a PATTERN from claude-context (MIT),
re-platformed to WALTEUR's zero-dep, detect-or-LOUD-SKIP idiom (no Milvus, no vector store, no standing infra).

```bash
#!/usr/bin/env bash
# graphify EXTENSION — Merkle incremental change-detector. Prints {added,removed,modified} vs the last
# snapshot; re-ingestion is graphify's job (see §3). detect-or-LOUD-SKIP; HARD diff, PROTOCOL completeness.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SNAP="$KIT/.merkle-snapshot.tsv"          # last state: "<sha>\t<path>" per tracked file, sorted by path
mkdir -p "$KIT"

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_MERKLE:-on}" = "off" ] && { echo "merkle-sync SKIP — bypass WALTEUR_MERKLE=off (recorded)." >&2; exit 0; }

# ── detect-or-LOUD-SKIP: pick a sha256 tool; absence is recorded, never silent-green ──
if command -v sha256sum >/dev/null 2>&1; then
  hash_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  hash_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
else
  echo "merkle-sync SKIP — no sha256sum/shasum (recorded, not silent-green)." >&2; exit 0
fi
command -v git >/dev/null 2>&1 || { echo "merkle-sync SKIP — git absent; cannot enumerate corpus (recorded)." >&2; exit 0; }

# ── build CURRENT leaf set: "<sha>\t<path>" for every tracked, non-deleted file, sorted by path ──
NOW="$(mktemp "${TMPDIR:-/tmp}/merkle-now.XXXXXX")" || { echo "merkle-sync SKIP — mktemp failed (recorded)." >&2; exit 0; }
trap 'rm -f "$NOW"' EXIT
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  [ -f "$ROOT/$rel" ] || continue
  printf '%s\t%s\n' "$(hash_of "$ROOT/$rel")" "$rel"
done < <(cd "$ROOT" && git ls-files) | sort -t"$(printf '\t')" -k2,2 > "$NOW"

# ── root hash: fold of the sorted leaf lines (corpus-wide short-circuit) ──
ROOT_HASH="$(hash_of "$NOW")"

# ── first run: no snapshot => EVERYTHING is "added", then persist ──
if [ ! -f "$SNAP" ]; then
  echo "merkle-sync: no prior snapshot — full ingest (all $(wc -l < "$NOW" | tr -d ' ') files are added)." >&2
  awk -F'\t' '{print "added\t" $2}' "$NOW"
  cp "$NOW" "$SNAP"
  exit 0
fi

# ── root-hash short-circuit: nothing changed => no delta, exit clean ──
OLD_ROOT="$(hash_of "$SNAP")"
if [ "$ROOT_HASH" = "$OLD_ROOT" ]; then
  echo "merkle-sync: root hash unchanged — corpus identical, nothing to re-ingest." >&2
  exit 0
fi

# ── snapshot-diff -> {added, removed, modified} (path-keyed, content-hash compared) ──
# added:    path in NOW, absent from SNAP
# removed:  path in SNAP, absent from NOW
# modified: path in both, sha differs
join -t"$(printf '\t')" -1 2 -2 2 -a1 -a2 -e '_' \
     -o '0,1.1,2.1' \
     <(sort -t"$(printf '\t')" -k2,2 "$SNAP") \
     <(sort -t"$(printf '\t')" -k2,2 "$NOW") \
| awk -F'\t' '
    $2=="_" && $3!="_" { print "added\t"    $1; next }
    $2!="_" && $3=="_" { print "removed\t"  $1; next }
    $2!=$3             { print "modified\t" $1; next }
  '

# ── persist new snapshot so the NEXT run diffs against today, not the stale baseline ──
cp "$NOW" "$SNAP"
```
