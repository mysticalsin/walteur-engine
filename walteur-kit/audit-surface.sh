#!/usr/bin/env bash
# WALTEUR surface audit — ONE command to understand/trust the kit before adopting it.
#
# Read-only. Answers: how big is the surface, what's wired vs orphan, are the twins clean,
# and what's the proof status — so an adopter does not have to read 100KB+ of hooks/schemas.
# Run: bash walteur-kit/audit-surface.sh
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
have() { command -v "$1" >/dev/null 2>&1; }

n_hooks=$(find "$KIT/hooks" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | grep -c . || echo 0)
n_schemas=$(find "$KIT/schemas" -maxdepth 1 -type f -name '*.json' 2>/dev/null | grep -c . || echo 0)
n_selftest=$(grep -cE 'hooks/[^"]+\.sh" --selftest' "$KIT/selftest.sh" 2>/dev/null || echo 0)

echo "WALTEUR surface audit — $KIT"
echo "  hooks (hooks/*.sh):        $n_hooks"
echo "  schemas (schemas/*.json):  $n_schemas"
echo "  hook --selftests in suite: $n_selftest"

if have jq && [ -f "$KIT/gate-registry.json" ]; then
  n_gates=$(jq '.gates | length' "$KIT/gate-registry.json" 2>/dev/null || echo '?')
  n_spec=$(jq '[.gates[] | select(.availability=="spec")] | length' "$KIT/gate-registry.json" 2>/dev/null || echo '?')
  echo "  registry gates:            $n_gates ($n_spec spec)"

  # hooks present on disk but referenced by NO registry gate hook field AND not run by selftest = orphan.
  registered="$(jq -r '.gates[].hook' "$KIT/gate-registry.json" 2>/dev/null | sort -u)"
  selftested="$(grep -oE 'hooks/[^"]+\.sh" --selftest' "$KIT/selftest.sh" 2>/dev/null | sed -E 's#hooks/([^"]+)" --selftest#\1#' | sort -u)"
  orphans=""
  while IFS= read -r f; do
    b="$(basename "$f")"
    printf '%s\n' "$registered" | grep -qxF "$b" && continue
    printf '%s\n' "$selftested" | grep -qxF "$b" && continue
    orphans="${orphans}${b} "
  done < <(find "$KIT/hooks" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort)
  if [ -n "$orphans" ]; then
    echo "  orphan hooks (on disk, not in registry, not selftested):"
    echo "    $orphans"
  else
    echo "  orphan hooks:              none (every hook is registered or selftested)"
  fi
else
  echo "  registry gates:            (jq absent — install jq for the wired-vs-orphan breakdown)"
fi

# twin status (if a twin-invariant report is present)
if [ -f "$KIT/../twin-invariant-report.json" ] && have jq; then
  tv="$(jq -r '.verdict // .status // "?"' "$KIT/../twin-invariant-report.json" 2>/dev/null || echo '?')"
  echo "  twin-invariant verdict:    $tv"
fi

echo ""
echo "  PROOF — run the suite to verify it all FIRES:"
echo "      bash walteur-kit/selftest.sh        # expect: NNN passed, 0 failed, 0 skipped"
echo "  (Runs clean inside a command sandbox; ship-gate integration cases need the canonical kit or sandbox-off.)"
echo ""
echo "  HONEST STATUS: gates are proven to FIRE; the engine has no field miles yet (no real build shipped through it). See README 'Status — honest'."
