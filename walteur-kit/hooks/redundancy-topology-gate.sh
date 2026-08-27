#!/usr/bin/env bash
# WALTEUR redundancy-topology-gate — HARD gate (enterprise backlog rank 5 offshoot). backup-policy proves the
# DATA survives a region loss, but nothing proves the SERVING tier does: a customer-facing service pinned to a
# single region AND a single AZ AND running <2 replicas is a guaranteed outage the first time one host or one
# availability zone fails — unacceptable for a $50-100M SaaS with an uptime SLA. This gate requires
# walteur-kit/topology.json and FAILs any customer-facing tier that is a total single-point-of-failure.
#
# Applies when a deployed/customer-facing surface is present (signal external_surface/has_api_boundary, or topology.json).
# CONTRACT: a customer-facing SPOF tier => FAIL exit 2 · no serving surface => NOT_APPLICABLE · jq absent =>
# SKIP · PAUSED => exit 2 · bypass WALTEUR_TOPOLOGY=off.
# Report: walteur-kit/redundancy-topology-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "redundancy-topology-gate - HARD gate (enterprise backlog rank 5 offshoot). backup-policy proves the"
  printf '%s\n' "usage: bash redundancy-topology-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/redundancy-topology-report.json - fix recipes: walteur-kit/REMEDIATION.md (## redundancy-topology-gate)"
  printf '%s\n' "bypass: WALTEUR_TOPOLOGY=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# Resolve an ABSOLUTE path to this script BEFORE any cd, so selftest's re-invocation always finds it
# (Git-Bash/Windows safe — $0 may be relative). Used by run() in selftest instead of bare "$0".
case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
MANIFEST="${WALTEUR_TOPOLOGY_FILE:-$KIT/topology.json}"
REPORT="$KIT/redundancy-topology-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"redundancy-topology", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"redundancy-topology","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }
serving() { [ -f "$MANIFEST" ] && return 0; [ -f "$SIGNALS" ] && have jq && jq -e '(.external_surface==true) or (.has_api_boundary==true)' "$SIGNALS" >/dev/null 2>&1; }
defer_ok() { printf '%s' "$1" | jq -e '.deferral.owner and .deferral.ticket and .deferral.review_trigger' >/dev/null 2>&1; }

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "redundancy-topology selftest SKIP - jq not installed."; return 0; fi
  echo "redundancy-topology-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  srv() { mkdir -p "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${2:-high}" > "$1/walteur-kit/build-contract.json"; printf '{"external_surface":true,"has_api_boundary":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  goodman() { jq -n '{tiers:[{name:"web",customer_facing:true,regions:["eu-west-1"],azs:["a","b","c"],replicas:3}]}' > "$1/walteur-kit/topology.json"; }
  spofman() { jq -n '{tiers:[{name:"web",customer_facing:true,regions:["eu-west-1"],azs:["a"],replicas:1}]}' > "$1/walteur-kit/topology.json"; }

  # 1. no serving surface -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"external_surface":false,"has_api_boundary":false}\n' > "$t/walteur-kit/preflight-signals.json"; ck "no serving surface -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. multi-AZ tier -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; goodman "$t"; ck "multi-AZ tier -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. high-risk + no topology -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t" high; ck "high-risk, no topology -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. customer-facing SPOF -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; spofman "$t"; ck "customer SPOF -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. SPOF region/az but replicas>=2 -> PASS (has some redundancy)
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; spofman "$t"; jq '.tiers[0].replicas=3' "$t/walteur-kit/topology.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/topology.json"; ck "single-az but replicas>=2 -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 6. SPOF signed-deferred at low risk -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t" low; spofman "$t"; jq '.tiers[0].deferral={owner:"Tony",ticket:"INFRA-1",review_trigger:"GA"}' "$t/walteur-kit/topology.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/topology.json"; ck "SPOF deferred at low risk -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 7. SPOF signed-deferred at high risk -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t" high; spofman "$t"; jq '.tiers[0].deferral={owner:"Tony",ticket:"INFRA-1",review_trigger:"GA"}' "$t/walteur-kit/topology.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/topology.json"; ck "SPOF deferred at high risk -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. non-customer-facing SPOF -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; jq -n '{tiers:[{name:"batch",customer_facing:false,regions:["eu-west-1"],azs:["a"],replicas:1}]}' > "$t/walteur-kit/topology.json"; ck "internal SPOF tier -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 9. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; spofman "$t"; WALTEUR_ROOT="$t" WALTEUR_TOPOLOGY=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # --- regression: red-team gauntlet false-negatives (TYPE/SHAPE/SEMANTIC evasions) ---
  # G1. camelCase customerFacing on a single-region/single-AZ/1-replica tier -> FAIL (was PASS: key only matched snake_case)
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; jq -n '{tiers:[{name:"checkout-api",customerFacing:true,regions:["eu-west-1"],azs:["a"],replicas:1}]}' > "$t/walteur-kit/topology.json"; ck "G1 camelCase customerFacing SPOF -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2. azs as a single STRING (one real zone) -> FAIL (was PASS: jq length on a string returned char-count)
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; jq -n '{tiers:[{name:"web",customer_facing:true,regions:["us-east-1"],azs:"us-east-1a",replicas:1}]}' > "$t/walteur-kit/topology.json"; ck "G2 azs-as-string SPOF -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3. duplicate AZs ["a","a"] = same zone twice, zero spread -> FAIL (was PASS: counted cardinality not distinct)
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; jq -n '{tiers:[{name:"web",customer_facing:true,regions:["eu-west-1"],azs:["a","a"],replicas:1}]}' > "$t/walteur-kit/topology.json"; ck "G3 duplicate-AZ SPOF -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G4. regions as a single STRING + duplicate azs -> FAIL (string-length bug also defeated .regions)
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; jq -n '{tiers:[{name:"web",customer_facing:true,regions:"us-east-1",azs:["a","a"],replicas:1}]}' > "$t/walteur-kit/topology.json"; ck "G4 regions-as-string SPOF -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G5. string-typed boolean customer_facing:"true" on a SPOF -> FAIL (coerce truthy strings)
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; jq -n '{tiers:[{name:"web",customer_facing:"true",regions:["eu-west-1"],azs:["a"],replicas:1}]}' > "$t/walteur-kit/topology.json"; ck "G5 string-bool customer_facing SPOF -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # --- false-positive guards: legitimately-redundant topologies must still PASS ---
  # G6. genuine multi-AZ spread (3 distinct) via camelCase key -> PASS (don't over-block the new key path)
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; jq -n '{tiers:[{name:"web",customerFacing:true,regions:["eu-west-1"],azs:["a","b","c"],replicas:3}]}' > "$t/walteur-kit/topology.json"; ck "G6 camelCase multi-AZ -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # G7. duplicate-padded BUT 3 distinct zones present -> PASS (distinct count = 3, real spread)
  t="$(mktemp -d "${TMPDIR:-/tmp}/redundancy.XXXXXX")"; srv "$t"; jq -n '{tiers:[{name:"web",customer_facing:true,regions:["eu-west-1"],azs:["a","a","b","c"],replicas:1}]}' > "$t/walteur-kit/topology.json"; ck "G7 padded-but-3-distinct AZ -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "redundancy-topology-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_TOPOLOGY:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_TOPOLOGY=off"; echo "redundancy-topology-gate: bypassed." >&2; exit 0; }

if ! serving; then write_report "NOT_APPLICABLE" "no deployed/customer-facing serving surface"; echo "redundancy-topology-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "redundancy-topology-gate: SKIP." >&2; exit 0; fi

RISK="$(risk)"
if [ ! -s "$MANIFEST" ]; then
  case "$RISK" in
    high|regulated) add_finding "manifest" "customer-facing surface at $RISK risk but no walteur-kit/topology.json — declare regions/azs/replicas per tier so a single-host or single-AZ failure can't take the service down"
      write_report "FAIL" "topology manifest absent at $RISK risk"; echo "redundancy-topology-gate: FAIL - manifest absent" >&2; exit 2 ;;
    *) write_report "NOT_APPLICABLE" "no topology.json and risk_tier=$RISK below the required floor"; echo "redundancy-topology-gate: NOT_APPLICABLE ($RISK risk)"; exit 0 ;;
  esac
fi
jq -e '.tiers | type=="array" and length>=1' "$MANIFEST" >/dev/null 2>&1 || add_finding "tiers" "topology.json must list >=1 tier"

while IFS= read -r tier; do
  [ -n "$tier" ] || continue
  nm="$(printf '%s' "$tier" | jq -r '.name // "tier"')"
  # customer_facing across snake_case OR camelCase OR mixed case, coercing string/bool truthiness.
  # Any sibling key whose lowercased name == "customerfacing" and whose value is true/"true"/"yes"/"1" counts.
  cf="$(printf '%s' "$tier" | jq -r '
    [ to_entries[]
      | select((.key|ascii_downcase|gsub("[_\\-]";"")) == "customerfacing")
      | (.value
         | if type=="boolean" then .
           elif type=="string" then (ascii_downcase|gsub("^\\s+|\\s+$";"")) as $v | ($v=="true" or $v=="yes" or $v=="1")
           elif type=="number" then (.!=0)
           else false end) ]
    | any // false')"
  [ "$cf" = "true" ] || continue
  # Distinct-zone/region counts. A field given as an ARRAY counts DISTINCT normalized entries
  # (so ["a","a"] => 1, not 2). A field given as a bare scalar (string/number) names exactly ONE
  # zone/region => 1. Absent/null/empty => 0. tostring|trim|lowercase normalizes before unique.
  distinct='if .==null then 0 elif type=="array" then (map(tostring|ascii_downcase|gsub("^\\s+|\\s+$";"")|select(length>0))|unique|length) elif type=="string" then (if (gsub("^\\s+|\\s+$";"")|length)>0 then 1 else 0 end) else 1 end'
  nreg="$(printf '%s' "$tier" | jq -r ".regions | ($distinct)")"
  naz="$(printf '%s' "$tier" | jq -r ".azs | ($distinct)")"
  # replicas: coerce to integer, non-numeric/absent => 0 (fail-closed, treated as <2)
  rep="$(printf '%s' "$tier" | jq -r '(.replicas | if type=="number" then floor elif (type=="string" and test("^[0-9]+$")) then tonumber else 0 end) // 0')"
  # fail-closed: any non-numeric/empty count (jq error, weird shape) collapses to 0 => treated as SPOF
  case "$nreg" in ''|*[!0-9]*) nreg=0;; esac
  case "$naz"  in ''|*[!0-9]*) naz=0;;  esac
  case "$rep"  in ''|*[!0-9]*) rep=0;;  esac
  # total SPOF: single region AND single AZ AND <2 replicas
  if [ "$nreg" -le 1 ] && [ "$naz" -le 1 ] && [ "$rep" -le 1 ]; then
    if defer_ok "$tier"; then
      case "$RISK" in high|regulated) add_finding "$nm" "customer-facing tier is a single-point-of-failure (regions=$nreg, azs=$naz, replicas=$rep) and cannot be signed-deferred at risk_tier=$RISK";; esac
    else
      add_finding "$nm" "customer-facing tier '$nm' is a total SPOF: single region ($nreg) + single AZ ($naz) + <2 replicas ($rep) — one host/AZ failure is a full outage. Add a replica, span AZs, or sign a deferral."
    fi
  fi
done < <(jq -c '.tiers[]?' "$MANIFEST" 2>/dev/null)

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures redundancy violation(s)"
  echo "redundancy-topology-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "every customer-facing tier has redundancy (multi-AZ, multi-region, or >=2 replicas)"
echo "redundancy-topology-gate: PASS" >&2
exit 0
