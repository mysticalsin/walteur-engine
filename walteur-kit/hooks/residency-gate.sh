#!/usr/bin/env bash
# WALTEUR residency-gate — HARD gate (enterprise backlog rank 6). Data residency (EU-only / US-only across
# storage + processing + backups + subprocessors) is a hard MSA commitment for enterprise; wrong-region
# data is a breach with clawback blast radius. Requires walteur-kit/residency.json (required_regions +
# per-store region) AND actively scans IaC for region literals outside the allowed set.
#
# Applies when data_classification is regulated/restricted/confidential, or residency.json exists.
# CONTRACT: out-of-region / missing manifest => FAIL exit 2 · no residency requirement => NOT_APPLICABLE ·
# jq absent => SKIP · PAUSED => exit 2 · bypass WALTEUR_RESIDENCY=off.
# Report: walteur-kit/residency-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "residency-gate - HARD gate (enterprise backlog rank 6). Data residency (EU-only / US-only across"
  printf '%s\n' "usage: bash residency-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/residency-report.json - fix recipes: walteur-kit/REMEDIATION.md (## residency-gate)"
  printf '%s\n' "bypass: WALTEUR_RESIDENCY=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
CONTRACT="$KIT/build-contract.json"
MANIFEST="${WALTEUR_RESIDENCY_FILE:-$KIT/residency.json}"
REPORT="$KIT/residency-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
X="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit"

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"residency", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"residency","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

dc() { [ -f "$CONTRACT" ] && have jq && jq -r '.data_classification // ""' "$CONTRACT" 2>/dev/null || echo ""; }
applies() { [ -f "$MANIFEST" ] && return 0; case "$(dc)" in regulated|restricted|confidential) return 0;; esac; return 1; }

# region R is allowed if any required token is a substring of R (case-insensitive). e.g. required "eu-"
# allows "eu-west-1"; "us-east-1" is rejected.
region_allowed() { local r; r="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"; local tok; while IFS= read -r tok; do [ -n "$tok" ] || continue; tok="$(printf '%s' "$tok" | tr 'A-Z' 'a-z')"; case "$r" in *"$tok"*) return 0;; esac; [ "${#r}" -ge 2 ] && case "$tok" in *"$r"*) return 0;; esac; done <<< "$REQ"; return 1; }

selftest() {
  pass=0; fail=0
  # absolutize $0 BEFORE anything could cd, so `bash "$SELF"` resolves regardless of cwd (Windows-safe).
  case "$0" in /*|?:[\/]*) SELF="$0";; *) SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")";; esac
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  if ! have jq; then echo "residency selftest SKIP - jq not installed."; return 0; fi
  echo "residency-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  reg() { mkdir -p "$1/walteur-kit"; printf '{"data_classification":"regulated"}\n' > "$1/walteur-kit/build-contract.json"; }
  goodman() { jq -n '{required_regions:["eu-","europe"],stores:[{name:"primary-db",region:"eu-west-1"},{name:"backups",region:"eu-central-1"}],subprocessors:[{name:"stripe",region:"eu"}]}' > "$1/walteur-kit/residency.json"; }

  # 1. no residency requirement -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"data_classification":"internal"}\n' > "$t/walteur-kit/build-contract.json"; ck "no requirement -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. regulated + manifest all in-region + IaC eu -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"; goodman "$t"; mkdir -p "$t/infra"; printf 'provider "aws" { region = "eu-west-1" }\n' > "$t/infra/main.tf"; ck "all in-region -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. regulated + manifest ABSENT -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"; ck "regulated, no manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. a store region OUTSIDE required -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"; goodman "$t"; jq '.stores[0].region="us-east-1"' "$t/walteur-kit/residency.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/residency.json"; ck "store out-of-region -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. IaC region literal OUTSIDE required -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"; goodman "$t"; mkdir -p "$t/infra"; printf 'provider "aws" { region = "us-east-1" }\nresource x { availability_zone = "us-east-1a" }\n' > "$t/infra/main.tf"; ck "IaC out-of-region -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. required_regions empty -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"; goodman "$t"; jq '.required_regions=[]' "$t/walteur-kit/residency.json" > "$t/m" && mv "$t/m" "$t/walteur-kit/residency.json"; ck "no required_regions -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. bypass -> exit 0
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"; WALTEUR_ROOT="$t" WALTEUR_RESIDENCY=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  # 8. PAUSED -> exit 2
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ── G# regressions: PROVEN red-team false-negatives (each must now exit 2) ───────────────────────────
  # G1. TYPE/ENCODING evasion — out-of-region store hidden under a differently-cased key ("Region").
  #     Case-sensitive jq `.region` returned null; empty region was silently skipped. Now any-cased
  #     region/location key is read and the US store is caught.
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"
  printf '%s\n' '{"required_regions":["eu-","europe"],"stores":[{"name":"primary-db","Region":"us-east-1"},{"name":"backups","region":"eu-central-1"}],"subprocessors":[{"name":"stripe","region":"eu"}]}' > "$t/walteur-kit/residency.json"
  ck "G1 capital-Region-key out-of-region store -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G2. SHAPE/STRUCTURE evasion — out-of-region backup parked under sibling top-level key .backups[]
  #     (selector only read .stores/.subprocessors) AND IaC literal hidden in a *.tfvars file (not in
  #     the include allowlist). Now .backups[] is read and *.tfvars is scanned.
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"; mkdir -p "$t/infra"
  printf '%s\n' '{"required_regions":["eu-","europe"],"stores":[{"name":"primary-db","region":"eu-west-1"}],"subprocessors":[{"name":"stripe","region":"eu"}],"backups":[{"name":"nightly-snapshot","region":"us-east-1","store":"S3 Glacier us-east-1"}]}' > "$t/walteur-kit/residency.json"
  printf 'provider "aws" { region = "eu-west-1" }\n' > "$t/infra/main.tf"
  printf 'backup_region = "us-east-1"\n' > "$t/infra/backup.tfvars"
  ck "G2 .backups[] sibling-key + .tfvars IaC out-of-region -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G3. SEMANTIC evasion — uppercase IaC region literals (US-EAST-1 / US-WEST-2) dodged the
  #     case-sensitive outer grep. Now extraction is case-insensitive + lowercased before the check.
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"; goodman "$t"; mkdir -p "$t/infra"
  printf 'provider "aws" {\n  region = "US-EAST-1"\n}\nresource "aws_db_instance" "primary" {\n  availability_zone = "US-EAST-1A"\n}\nresource "aws_s3_bucket" "backups" {\n  region = "US-WEST-2"\n}\n' > "$t/infra/main.tf"
  ck "G3 uppercase IaC region literal -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G4. store declared with NO region at all -> FAIL (residency cannot be proven for an undeclared location).
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"
  printf '%s\n' '{"required_regions":["eu-","europe"],"stores":[{"name":"mystery-db"}],"subprocessors":[{"name":"stripe","region":"eu"}]}' > "$t/walteur-kit/residency.json"
  ck "G4 store with no region key -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G5. malformed / multi-document manifest -> FAIL (cannot be proven clean; must not silently skip).
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"
  printf '%s\n%s\n' '{"required_regions":["eu-"],"stores":[{"name":"a","region":"eu-west-1"}]}' '{"required_regions":["eu-"]}' > "$t/walteur-kit/residency.json"
  ck "G5 multi-document manifest -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G6 (false-positive guard). Clean build whose .backups[] is in-region, regions UPPERCASE-required,
  #     and a *.tfvars carries an in-region literal -> must still PASS (no over-blocking from the new scans).
  t="$(mktemp -d "${TMPDIR:-/tmp}/residencyg.XXXXXX")"; reg "$t"; mkdir -p "$t/infra"
  printf '%s\n' '{"required_regions":["EU-","EUROPE"],"stores":[{"name":"primary-db","Region":"eu-west-1"}],"subprocessors":[{"name":"stripe","region":"eu"}],"backups":[{"name":"nightly","region":"eu-central-1"}]}' > "$t/walteur-kit/residency.json"
  printf 'provider "aws" { region = "EU-WEST-1" }\n' > "$t/infra/main.tf"
  printf 'backup_region = "eu-central-1"\n' > "$t/infra/backup.tfvars"
  ck "G6 clean in-region (mixed-case keys/values/.tfvars/.backups) -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "residency-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_RESIDENCY:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_RESIDENCY=off"; echo "residency-gate: bypassed." >&2; exit 0; }

if ! applies; then write_report "NOT_APPLICABLE" "no data-residency requirement (data_classification not regulated/restricted/confidential, no residency.json)"; echo "residency-gate: NOT_APPLICABLE"; exit 0; fi
if ! have jq; then write_report "SKIP" "jq unavailable"; echo "residency-gate: SKIP." >&2; exit 0; fi

if [ ! -s "$MANIFEST" ]; then
  add_finding "manifest" "regulated/restricted data but walteur-kit/residency.json absent — residency is a hard MSA commitment and must be declared + proven"
  write_report "FAIL" "residency manifest absent"; echo "residency-gate: FAIL - manifest absent" >&2; exit 2
fi
# fail-closed on a malformed / multi-document / duplicate-keyed manifest: a residency manifest that does not
# parse to exactly ONE well-formed JSON object cannot be PROVEN clean, so it must FAIL (not silently skip).
if ! jq -e -s 'length==1 and (.[0]|type=="object")' "$MANIFEST" >/dev/null 2>&1; then
  add_finding "manifest" "walteur-kit/residency.json is not a single well-formed JSON object (malformed / empty / multi-document) — residency cannot be proven"
  write_report "FAIL" "residency manifest malformed"; echo "residency-gate: FAIL - manifest malformed" >&2; exit 2
fi
REQ="$(jq -r '.required_regions[]? // empty' "$MANIFEST" 2>/dev/null)"
[ -n "$REQ" ] || add_finding "required_regions" "residency.json.required_regions is empty — declare the allowed region(s) (e.g. eu-, europe)"

if [ -n "$REQ" ]; then
  # declared store / backup / subprocessor regions.
  #   - reads .stores[], .backups[] AND .subprocessors[] (backups are part of the residency contract).
  #   - the region is pulled from ANY case-variant key ("region"/"Region"/"REGION", "location") so a value
  #     hidden under a differently-cased sibling key cannot evade the check.
  #   - a declared store with NO discernible region is FAIL-CLOSED: residency cannot be proven for a store
  #     whose location is undeclared, so it is a finding (not silently skipped).
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    nm="${line%%	*}"; rg="${line#*	}"
    if [ -z "$rg" ]; then
      add_finding "store_region" "'$nm' declares no region (no region/location key) — residency cannot be proven"
    else
      region_allowed "$rg" || add_finding "store_region" "'$nm' is in region '$rg' — outside required_regions"
    fi
  done < <(jq -r '
      (.stores[]?, .backups[]?, .subprocessors[]?)
      | . as $o
      | ([ $o | to_entries[] | select((.key|ascii_downcase)=="region" or (.key|ascii_downcase)=="location") | .value ]
         | map(select(type=="string")) | (.[0] // "")) as $rg
      | ([ $o | to_entries[] | select((.key|ascii_downcase)=="name") | .value ] | map(select(type=="string")) | (.[0] // "store")) as $nm
      | [$nm, ($rg|ascii_downcase)] | @tsv
    ' "$MANIFEST" 2>/dev/null)
  # active IaC scan: region/location literals outside the allowed set.
  #   - widened globs: *.tfvars / *.tfvars.json (Terraform vars), *.json/*.hcl, k8s/helm yaml, plus *.tf.
  #   - CASE-INSENSITIVE extraction (-i) + tolower normalization so an uppercase literal ("US-EAST-1")
  #     cannot dodge the region-allowed check.
  if command -v grep >/dev/null 2>&1; then
    while IFS= read -r rg; do
      [ -n "$rg" ] || continue
      region_allowed "$rg" || { add_finding "iac_region" "IaC pins region '$rg' — outside required_regions"; break; }
    done < <(grep -rhoIE -i \
                --include='*.tf' --include='*.tfvars' --include='*.tfvars.json' \
                --include='*.yaml' --include='*.yml' --include='*.json' --include='*.hcl' \
                $X '(region|location|availability_zone)[[:space:]]*[:=][[:space:]]*"?[a-z]{2,}-[a-z]+[0-9-]*[0-9a-z]?' "$ROOT" 2>/dev/null \
             | grep -oiE '[a-z]{2,}-[a-z]+[0-9-]*[0-9a-z]?' | tr 'A-Z' 'a-z' | sort -u)
  fi
fi

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "$failures residency violation(s)"
  echo "residency-gate: FAIL - $failures violation(s)" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "all stores/backups/subprocessors and IaC regions are within required_regions"
echo "residency-gate: PASS" >&2
exit 0
