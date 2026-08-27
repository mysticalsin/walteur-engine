#!/usr/bin/env bash
# WALTEUR fitness-gate — architecture fitness functions: forbid cyclic dependencies and
# cross-bounded-context imports. Honest detect-or-loud-SKIP for the heavy tools, PLUS a
# zero-dep architecture check that is a HARD gate (real exit 2) so the gate does real work
# even when no heavy tool is installed.
#
#   ZERO-DEP (always runs, HARD):
#     If walteur-kit/layers.json exists and declares {"layers":{...},"forbidden":[["a","b"],...]}
#     (a is forbidden from importing b), a directed-graph cycle check on the declared layer
#     edges + the forbidden-edge declaration is validated for self-consistency, and any
#     declared dependency cycle among layers is a violation. No source parsing, no tools.
#
#   DETECT-OR-SKIP (heavy tools, run the one(s) present):
#     dependency-cruiser (depcruise) — if a .dependency-cruiser.{js,cjs,json} config exists,
#         run it; a reported error/violation => fail. JS/TS bounded-context + cycle rules.
#     import-linter (lint-imports)    — if an importlinter contract file exists
#         (.importlinter / setup.cfg [importlinter] / pyproject.toml [tool.importlinter]),
#         run it; a broken contract => fail. Python layered-architecture + independence.
#     deptrac                         — if a deptrac.yaml/deptrac.yml/depfile.yaml exists,
#         run `deptrac analyse`; a violation => fail. PHP/layer ruleset.
#
# Tool ABSENT => SKIP that sub-check (loud, recorded) — NEVER silent-green, NEVER exit 2 for a
# missing tool. A tiny project with no fitness rules at all => clean (exit 0).
# A present tool reporting a REAL architecture violation => exit 2.
# Report: walteur-kit/fitness-report.json with per-check {verdict|SKIP} + the zero-dep result.
# Bypass: WALTEUR_FITNESS=off.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/fitness-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }
TMP="$(mktemp "${TMPDIR:-/tmp}/walteur.XXXXXX")"; trap 'rm -f "$TMP"' EXIT

write_simple_report() {
  verdict="$1"
  reason="$2"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" \
      '{verdict:$v, ts:$ts, gate:"fitness", reason:$r, heavy_checks_ran:0, zero_dep_checks_ran:0, violations:0, details:{}}' \
      > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"fitness","reason":"%s","heavy_checks_ran":0,"zero_dep_checks_ran":0,"violations":0,"details":{}}\n' \
    "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

selftest() {
  pass=0
  fail=0

  ck() {
    name="$1"
    want="$2"
    got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  run_gate() {
    root="$1"
    shift
    WALTEUR_ROOT="$root" "$@" bash "$0" >/dev/null 2>&1
  }

  verdict() {
    jq -r '.verdict // "MISSING"' "$1/walteur-kit/fitness-report.json" 2>/dev/null || echo "MISSING"
  }

  make_root() {
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/fitness-gate-selftest.XXXXXX")" || return 1
    mkdir -p "$tmp/walteur-kit"
    printf '%s\n' "$tmp"
  }

  write_layers() {
    dst="$1"
    cat > "$dst/walteur-kit/layers.json" <<'JSON'
{
  "layers": {
    "domain": ["src/domain"],
    "app": ["src/app"],
    "infra": ["src/infra"]
  },
  "edges": [["app", "domain"], ["infra", "app"]],
  "forbidden": [["domain", "app"], ["domain", "infra"], ["app", "infra"]]
}
JSON
  }

  if ! have jq; then
    echo "fitness-gate selftest SKIP - jq not installed."
    return 0
  fi

  echo "fitness-gate selftest:"

  tmp="$(make_root)"
  run_gate "$tmp"
  rc=$?
  [ "$(verdict "$tmp")" = "SKIP" ] || rc=99
  ck "no architecture rules -> SKIP" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_layers "$tmp"
  run_gate "$tmp"
  rc=$?
  [ "$(verdict "$tmp")" = "PASS" ] || rc=99
  ck "valid acyclic layers -> PASS" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(make_root)"
  printf '{ bad json\n' > "$tmp/walteur-kit/layers.json"
  run_gate "$tmp"
  ck "invalid layers JSON -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_layers "$tmp"
  jq '.edges += [["domain","infra"],["infra","domain"]]' "$tmp/walteur-kit/layers.json" > "$tmp/layers.json" && mv "$tmp/layers.json" "$tmp/walteur-kit/layers.json"
  run_gate "$tmp"
  ck "declared dependency cycle -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_layers "$tmp"
  jq '.edges += [["domain","app"]]' "$tmp/walteur-kit/layers.json" > "$tmp/layers.json" && mv "$tmp/layers.json" "$tmp/walteur-kit/layers.json"
  run_gate "$tmp"
  ck "edge also declared forbidden -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_layers "$tmp"
  jq '.forbidden += [["infra","domain"]]' "$tmp/walteur-kit/layers.json" > "$tmp/layers.json" && mv "$tmp/layers.json" "$tmp/walteur-kit/layers.json"
  run_gate "$tmp"
  ck "forbidden transitive dependency -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_layers "$tmp"
  printf 'module.exports = {};\n' > "$tmp/.dependency-cruiser.js"
  mkdir -p "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/depcruise"
  chmod +x "$tmp/bin/depcruise"
  PATH="$tmp/bin:$PATH" run_gate "$tmp" env
  rc=$?
  [ "$(jq -r '.details.dependency_cruiser.verdict // "MISSING"' "$tmp/walteur-kit/fitness-report.json")" = "PASS" ] || rc=99
  ck "dependency-cruiser config with passing tool -> PASS" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_layers "$tmp"
  printf 'module.exports = {};\n' > "$tmp/.dependency-cruiser.js"
  mkdir -p "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/depcruise"
  chmod +x "$tmp/bin/depcruise"
  PATH="$tmp/bin:$PATH" run_gate "$tmp" env
  ck "dependency-cruiser config with failing tool -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_layers "$tmp"
  WALTEUR_FITNESS=off run_gate "$tmp" env
  rc=$?
  [ "$(verdict "$tmp")" = "SKIP" ] || rc=99
  ck "bypass writes SKIP report -> PASS" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(make_root)"
  write_layers "$tmp"
  touch "$tmp/walteur-kit/PAUSED"
  run_gate "$tmp"
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "fitness-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_FITNESS:-on}" = "off" ] && {
  echo "fitness-gate: bypassed (WALTEUR_FITNESS=off)." >&2
  write_simple_report "SKIP" "bypassed via WALTEUR_FITNESS=off"
  exit 0
}

violations=0      # real architecture violations
ran=0             # heavy sub-checks that actually executed
zero_ran=0        # zero-dep checks that actually executed
J='{}'
add() { J="$(printf '%s' "$J" | jq --argjson v "$2" --arg k "$1" '.[$k]=$v' 2>/dev/null || printf '%s' "$J")"; }
loud_skip() { echo "  SKIP — $1 ($2). Recorded; NOT counted green." >&2; }

echo "WALTEUR fitness-gate @ $ROOT" >&2

# ── ZERO-DEP: layer-cycle + forbidden-edge consistency on walteur-kit/layers.json ────────────
# layers.json shape (all optional; absent file => zero-dep check is SKIP, not a failure):
#   {
#     "layers":    { "domain": ["src/domain"], "app": ["src/app"], "infra": ["src/infra"] },
#     "edges":     [["app","domain"], ["infra","app"]],   # declared allowed dependency edges
#     "forbidden": [["domain","infra"], ["domain","app"]] # a MUST NOT depend on b
#   }
# HARD checks (exit 2 on any):
#   Z1  A cycle in the declared `edges` directed graph (architecture must be acyclic).
#   Z2  A declared `edges` entry that is also declared `forbidden` (self-contradictory ruleset).
#   Z3  A `forbidden` pair [a,b] that is nonetheless reachable in `edges` (a transitively
#       depends on b despite being forbidden) — the declared architecture violates its own rule.
LAYERS="$KIT/layers.json"
if [ -f "$LAYERS" ]; then
  if ! jq -e . "$LAYERS" >/dev/null 2>&1; then
    echo "  FAIL — layers.json is not valid JSON." >&2
    violations=$((violations+1)); zero_ran=$((zero_ran+1))
    add zero_dep '{"verdict":"FAIL","check":"layers.json","reason":"invalid JSON"}'
  else
    zero_ran=$((zero_ran+1))
    # jq does ALL graph reasoning deterministically: cycle detection via DFS over `edges`,
    # contradiction (Z2) and forbidden-but-reachable (Z3) via transitive closure.
    zres="$(jq -c '
      def nodes:
        ((.layers // {} | keys)
         + ((.edges // []) | map(.[0], .[1]))
         + ((.forbidden // []) | map(.[0], .[1]))) | unique;
      ( .edges // [] )                                as $E
      | ( .forbidden // [] | map(map(tostring)) )     as $F
      | ( $E | map(map(tostring)) )                   as $Es
      # adjacency: node -> [direct deps]
      | ( reduce $Es[] as $e ({}; .[$e[0]] += [$e[1]]) ) as $adj
      # transitive reachability from a node (iterate to fixpoint)
      | def reach($start):
          { seen: [], front: ($adj[$start] // []) }
          | until( (.front | length) == 0;
              .front[0] as $n
              | .front = (.front[1:])
              | if (.seen | index($n)) then .
                else .seen += [$n] | .front += ($adj[$n] // []) end )
          | .seen ;
      # Z1: cycle iff some node reaches itself. Bind the node ($n0) so `index` tests the
      # node against the reach-set, not the reach-set against itself.
      ( [ (nodes[]) | . as $n0 | select( reach($n0) | index($n0) ) ] ) as $cyc
      # Z2: an edge that is also forbidden
      | ( [ $Es[] | select( . as $x | $F | index($x) ) ] ) as $contra
      # Z3: a forbidden [a,b] where b is reachable from a
      | ( [ $F[] | select( . as $p | (reach($p[0]) | index($p[1])) ) ] ) as $viol
      | { cyclic_nodes:$cyc, contradictions:$contra, forbidden_but_reachable:$viol,
          ok: (($cyc|length)==0 and ($contra|length)==0 and ($viol|length)==0) }
    ' "$LAYERS" 2>/dev/null || echo '{"ok":false,"error":"jq-failed"}')"
    zok="$(printf '%s' "$zres" | jq -r '.ok // false' 2>/dev/null || echo false)"
    if [ "$zok" = "true" ]; then
      echo "  ok   — layers.json: acyclic, no self-contradiction, no forbidden-but-reachable edge." >&2
      add zero_dep "$(jq -n --argjson r "$zres" '{verdict:"PASS",check:"layers.json",result:$r}')"
    else
      echo "  FAIL — layers.json: declared architecture violates a fitness rule:" >&2
      printf '%s' "$zres" | jq -r '
        (if (.cyclic_nodes|length)>0 then "    cycle through layer(s): "+(.cyclic_nodes|join(", ")) else empty end),
        (if (.contradictions|length)>0 then "    edge also declared forbidden: "+( .contradictions|map(join("->"))|join(", ")) else empty end),
        (if (.forbidden_but_reachable|length)>0 then "    forbidden but reachable: "+( .forbidden_but_reachable|map(join("->"))|join(", ")) else empty end)
      ' 2>/dev/null >&2 || true
      violations=$((violations+1))
      add zero_dep "$(jq -n --argjson r "$zres" '{verdict:"FAIL",check:"layers.json",result:$r}')"
    fi
  fi
else
  echo "  SKIP — zero-dep layer check: no walteur-kit/layers.json (no declared architecture rules)." >&2
  add zero_dep '{"verdict":"SKIP","check":"layers.json","reason":"no walteur-kit/layers.json present"}'
fi

# ── DETECT-OR-SKIP: dependency-cruiser ───────────────────────────────────────────────────────
dc_cfg=""
for c in .dependency-cruiser.js .dependency-cruiser.cjs .dependency-cruiser.json .dependency-cruiser.mjs; do
  [ -f "$ROOT/$c" ] && { dc_cfg="$ROOT/$c"; break; }
done
if [ -n "$dc_cfg" ]; then
  if have depcruise; then
    ran=$((ran+1))
    # Source roots to scan: prefer src/lib/app/packages if present, else the repo root.
    dc_targets=""
    for d in src lib app packages; do [ -d "$ROOT/$d" ] && dc_targets="$dc_targets $d"; done
    [ -z "$dc_targets" ] && dc_targets="."
    # shellcheck disable=SC2086
    if ( cd "$ROOT" && depcruise --config "$dc_cfg" --no-progress $dc_targets ) >"$TMP" 2>&1; then
      echo "  ok   — dependency-cruiser: no rule violations." >&2
      add dependency_cruiser "$(jq -n --arg c "$dc_cfg" '{verdict:"PASS",tool:"dependency-cruiser",config:$c}')"
    else
      echo "  FAIL — dependency-cruiser: rule violation(s) (cycle / forbidden import)." >&2
      violations=$((violations+1))
      add dependency_cruiser "$(jq -n --arg c "$dc_cfg" '{verdict:"FAIL",tool:"dependency-cruiser",config:$c}')"
    fi
  else
    loud_skip depcruise "dependency-cruiser config present but binary not installed"
    add dependency_cruiser '{"verdict":"SKIP","reason":"depcruise not installed (config present)"}'
  fi
else
  add dependency_cruiser '{"verdict":"SKIP","reason":"no .dependency-cruiser config present"}'
fi

# ── DETECT-OR-SKIP: import-linter (Python) ───────────────────────────────────────────────────
il_cfg=""
[ -f "$ROOT/.importlinter" ] && il_cfg="$ROOT/.importlinter"
[ -z "$il_cfg" ] && grep -lqE '^\[importlinter' "$ROOT/setup.cfg" 2>/dev/null && il_cfg="$ROOT/setup.cfg"
[ -z "$il_cfg" ] && grep -lqE '^\[tool\.importlinter' "$ROOT/pyproject.toml" 2>/dev/null && il_cfg="$ROOT/pyproject.toml"
if [ -n "$il_cfg" ]; then
  if have lint-imports; then
    ran=$((ran+1))
    if ( cd "$ROOT" && lint-imports ) >"$TMP" 2>&1; then
      echo "  ok   — import-linter: all contracts kept." >&2
      add import_linter "$(jq -n --arg c "$il_cfg" '{verdict:"PASS",tool:"import-linter",config:$c}')"
    else
      echo "  FAIL — import-linter: a contract is broken (cycle / forbidden cross-context import)." >&2
      violations=$((violations+1))
      add import_linter "$(jq -n --arg c "$il_cfg" '{verdict:"FAIL",tool:"import-linter",config:$c}')"
    fi
  else
    loud_skip lint-imports "import-linter contract present but binary not installed"
    add import_linter '{"verdict":"SKIP","reason":"lint-imports not installed (contract present)"}'
  fi
else
  add import_linter '{"verdict":"SKIP","reason":"no import-linter contract present"}'
fi

# ── DETECT-OR-SKIP: deptrac (PHP / layer ruleset) ────────────────────────────────────────────
dt_cfg=""
for c in deptrac.yaml deptrac.yml depfile.yaml depfile.yml; do
  [ -f "$ROOT/$c" ] && { dt_cfg="$ROOT/$c"; break; }
done
if [ -n "$dt_cfg" ]; then
  if have deptrac; then
    ran=$((ran+1))
    if ( cd "$ROOT" && deptrac analyse --config-file "$dt_cfg" --no-progress --fail-on-uncovered ) >"$TMP" 2>&1; then
      echo "  ok   — deptrac: no layer violations." >&2
      add deptrac "$(jq -n --arg c "$dt_cfg" '{verdict:"PASS",tool:"deptrac",config:$c}')"
    else
      echo "  FAIL — deptrac: layer dependency violation(s)." >&2
      violations=$((violations+1))
      add deptrac "$(jq -n --arg c "$dt_cfg" '{verdict:"FAIL",tool:"deptrac",config:$c}')"
    fi
  else
    loud_skip deptrac "deptrac config present but binary not installed"
    add deptrac '{"verdict":"SKIP","reason":"deptrac not installed (config present)"}'
  fi
else
  add deptrac '{"verdict":"SKIP","reason":"no deptrac config present"}'
fi

# ── verdict ──────────────────────────────────────────────────────────────────────────────────
# FAIL if any real violation. Otherwise PASS if any check (zero-dep or heavy) actually ran.
# Otherwise SKIP: nothing applicable was present to check (tiny project, no rules) — clean exit 0.
total_ran=$((ran + zero_ran))
if [ "$violations" -gt 0 ]; then
  OVERALL=FAIL
elif [ "$total_ran" -gt 0 ]; then
  OVERALL=PASS
else
  OVERALL=SKIP
fi

jq -n --arg v "$OVERALL" --arg ts "$TS" --argjson ran "$ran" --argjson zran "$zero_ran" \
      --argjson viol "$violations" --argjson checks "$J" \
  '{verdict:$v, ts:$ts, gate:"fitness", heavy_checks_ran:$ran, zero_dep_checks_ran:$zran,
    violations:$viol, details:$checks}' \
  > "$REPORT" 2>/dev/null \
  || printf '{"verdict":"%s","ts":"%s","gate":"fitness","heavy_checks_ran":%s,"zero_dep_checks_ran":%s,"violations":%s}\n' \
       "$OVERALL" "$TS" "$ran" "$zero_ran" "$violations" > "$REPORT"

echo "fitness-gate verdict: $OVERALL (heavy_ran=$ran, zero_dep_ran=$zero_ran, violations=$violations) -> $REPORT" >&2
[ "$OVERALL" = "FAIL" ] && exit 2
exit 0
