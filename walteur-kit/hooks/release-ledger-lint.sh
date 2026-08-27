#!/usr/bin/env bash
# WALTEUR release-ledger-lint - validates the distribution release truth ledger.
#
# Contract:
#   - release-ledger.json absent => NOT_APPLICABLE, exit 0.
#   - jq absent                  => SKIP, exit 0, recorded loudly.
#   - malformed ledger           => FAIL, exit 2.
#   - stale docs/mirrors/manifests/registry => FAIL, exit 2.
#   - stale aggregate proof/source-count prose => FAIL, exit 2.
#   - strict report mode verifies selftest-report counts after aggregate proof.
#   - walteur-kit/PAUSED         => exit 2.
#
# Report:
#   walteur-kit/release-ledger-report.json
#
# Bypass:
#   WALTEUR_RELEASE_LEDGER=off
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "release-ledger-lint - validates the distribution release truth ledger."
  printf '%s\n' "usage: bash release-ledger-lint.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/release-ledger-report.json - fix recipes: walteur-kit/REMEDIATION.md (## release-ledger-lint)"
  printf '%s\n' "bypass: WALTEUR_RELEASE_LEDGER=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
LEDGER="${WALTEUR_RELEASE_LEDGER_FILE:-$KIT/release-ledger.json}"
SCHEMA="${WALTEUR_RELEASE_LEDGER_SCHEMA:-$KIT/schemas/release-ledger.schema.json}"
REPORT="$KIT/release-ledger-report.json"
STRICT_REPORT="${WALTEUR_RELEASE_LEDGER_STRICT_REPORT:-0}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

# Windows/Git-Bash jq writes CRLF to stdout. `$(...)` strips the trailing CR but `read` does NOT,
# so every value read out of a `while read ... done < <(jq -r ...)` kept a trailing \r and every
# comparison against it failed (paths "not found", strings "not contained", `expected` != identical
# `actual`). Route ALL value-producing jq -r reads through jqr so both paths behave the same.
jqr() { jq -r "$@" | tr -d '\r'; }

write_report() {
  verdict="$1"
  reason="$2"
  findings="${3:-[]}"
  if have jq; then
    jq -n --arg v "$verdict" --arg ts "$TS" --arg r "$reason" \
      --arg ledger "${LEDGER#"$ROOT"/}" --argjson f "$findings" \
      '{verdict:$v, ts:$ts, gate:"release-ledger", ledger_file:$ledger, reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"release-ledger","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

validate_ledger_shape() {
  jq -e '
    def root_keys: ["schema_version","ledger_id","updated_at","policy","current_version","aggregate_proof","aggregate_history","source_manifest","scaffold_proof","registry","required_strings","mirrored_pairs","proof_claim_paths","source_claim_paths","component_manifests"];
    def aggregate_keys: ["report_path","expected_passed","expected_failed","expected_skipped"];
    def history_keys: ["version","expected_passed","expected_failed","expected_skipped"];
    def source_manifest_keys: ["path","expected_source_count","required_source_id"];
    def scaffold_keys: ["selftest_label","expected_passed"];
    def registry_keys: ["path","expected_gate_count","required_gate_id"];
    def string_keys: ["path","contains"];
    def mirror_keys: ["left","right"];
    def manifest_keys: ["path","field","expected"];
    def nonempty_string($k): (.[$k] | type == "string" and length > 0);
    type == "object"
    and (([keys_unsorted[]] - root_keys) | length == 0)
    and (.schema_version == 1)
    and nonempty_string("ledger_id")
    and (.updated_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (.policy | type == "string" and length >= 30)
    and (.current_version | type == "string" and test("^[0-9]+\\.[0-9]+$"))
    and (.aggregate_proof | type == "object")
    and ((.aggregate_proof | [keys_unsorted[]] - aggregate_keys) | length == 0)
    and (.aggregate_proof.report_path | type == "string" and length > 0)
    and (.aggregate_proof.expected_passed | type == "number" and . >= 1 and floor == .)
    and (.aggregate_proof.expected_failed == 0)
    and (.aggregate_proof.expected_skipped == 0)
    and (.aggregate_history | type == "array" and length >= 1)
    and all(.aggregate_history[];
      type == "object"
      and (([keys_unsorted[]] - history_keys) | length == 0)
      and (.version | type == "string" and test("^[0-9]+\\.[0-9]+$"))
      and (.expected_passed | type == "number" and . >= 1 and floor == .)
      and (.expected_failed == 0)
      and (.expected_skipped == 0)
    )
    and (([.aggregate_history[] | .version] | length) == ([.aggregate_history[] | .version] | unique | length))
    and (. as $root | any(.aggregate_history[];
      .version == $root.current_version
      and .expected_passed == $root.aggregate_proof.expected_passed
      and .expected_failed == $root.aggregate_proof.expected_failed
      and .expected_skipped == $root.aggregate_proof.expected_skipped
    ))
    and (.source_manifest | type == "object")
    and ((.source_manifest | [keys_unsorted[]] - source_manifest_keys) | length == 0)
    and (.source_manifest.path | type == "string" and length > 0)
    and (.source_manifest.expected_source_count | type == "number" and . >= 1 and floor == .)
    and (.source_manifest.required_source_id | type == "string" and test("^[a-z0-9][a-z0-9._-]*$"))
    and (.scaffold_proof | type == "object")
    and ((.scaffold_proof | [keys_unsorted[]] - scaffold_keys) | length == 0)
    and (.scaffold_proof.selftest_label | type == "string" and test("^[0-9]+/[0-9]+$"))
    and (.scaffold_proof.expected_passed | type == "number" and . >= 1 and floor == .)
    and (.registry | type == "object")
    and ((.registry | [keys_unsorted[]] - registry_keys) | length == 0)
    and (.registry.path | type == "string" and length > 0)
    and (.registry.expected_gate_count | type == "number" and . >= 1 and floor == .)
    and (.registry.required_gate_id | type == "string" and length > 0)
    and (.required_strings | type == "array" and length >= 1)
    and all(.required_strings[];
      type == "object"
      and (([keys_unsorted[]] - string_keys) | length == 0)
      and (.path | type == "string" and length > 0)
      and (.contains | type == "string" and length > 0)
    )
    and (([.required_strings[] | .path + "\t" + .contains] | length) == ([.required_strings[] | .path + "\t" + .contains] | unique | length))
    and (.mirrored_pairs | type == "array" and length >= 1)
    and all(.mirrored_pairs[];
      type == "object"
      and (([keys_unsorted[]] - mirror_keys) | length == 0)
      and (.left | type == "string" and length > 0)
      and (.right | type == "string" and length > 0)
    )
    and (([.mirrored_pairs[] | .left + "\t" + .right] | length) == ([.mirrored_pairs[] | .left + "\t" + .right] | unique | length))
    and (.proof_claim_paths | type == "array" and length >= 1)
    and all(.proof_claim_paths[]; type == "string" and length > 0)
    and ((.proof_claim_paths | length) == (.proof_claim_paths | unique | length))
    and (.source_claim_paths | type == "array" and length >= 1)
    and all(.source_claim_paths[]; type == "string" and length > 0)
    and ((.source_claim_paths | length) == (.source_claim_paths | unique | length))
    and (.component_manifests | type == "array" and length >= 1)
    and all(.component_manifests[];
      type == "object"
      and (([keys_unsorted[]] - manifest_keys) | length == 0)
      and (.path | type == "string" and length > 0)
      and (.field | type == "string" and test("^[A-Za-z0-9_-]+$"))
      and (.expected | type == "string" and length > 0)
    )
    and (([.component_manifests[] | .path + "\t" + .field] | length) == ([.component_manifests[] | .path + "\t" + .field] | unique | length))
  ' "$LEDGER" >/dev/null
}

validate_proof_claims() {
  # Ledger constants, hoisted out of the per-line loop: re-deriving them inside it cost one jq exec
  # per claim line, and re-read aggregate_history (54 rows here) for every line of a 1200-line doc.
  current_expected="$(jqr '.aggregate_proof.expected_passed' "$LEDGER")"
  history_tsv="$(jqr '.aggregate_history[] | [.version, .expected_passed, .expected_failed, .expected_skipped] | @tsv' "$LEDGER")"

  while IFS= read -r claim_path; do
    [ -n "$claim_path" ] || continue
    claim_file="$ROOT/$claim_path"
    if [ ! -f "$claim_file" ]; then
      add_finding "proof-claim" "missing proof claim file: $claim_path"
      continue
    fi

    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no+1))
      # Builtin pre-filter: the regex below cannot match without this exact literal, so skipping
      # non-claim lines here is behaviour-identical and saves one grep exec per line of the doc.
      case "$line" in
        *" passed, 0 failed, 0 skipped"*) ;;
        *) continue ;;
      esac
      claims="$(printf '%s\n' "$line" | grep -Eo '[0-9]+ passed, 0 failed, 0 skipped' || true)"
      [ -n "$claims" ] || continue

      case "$line" in
        *"current proof is"*)
        while IFS= read -r claim; do
          [ -n "$claim" ] || continue
          claim_passed="${claim%% passed,*}"
          if [ "$claim_passed" != "$current_expected" ]; then
            add_finding "proof-claim" "$claim_path:$line_no current proof says $claim_passed passed, expected $current_expected"
          fi
        done <<EOF
$claims
EOF
        ;;
      esac

      while IFS=$'\t' read -r version expected_passed expected_failed expected_skipped; do
        [ -n "$version" ] || continue
        case "$line" in
          *"v$version"*)
          while IFS= read -r claim; do
            [ -n "$claim" ] || continue
            claim_passed="${claim%% passed,*}"
            if [ "$claim_passed" != "$expected_passed" ] || [ "$expected_failed" != "0" ] || [ "$expected_skipped" != "0" ]; then
              add_finding "proof-claim" "$claim_path:$line_no v$version proof says $claim_passed passed, expected $expected_passed"
            fi
          done <<EOF
$claims
EOF
          ;;
        esac
      done <<EOF
$history_tsv
EOF
    done < "$claim_file"
  done < <(jqr '.proof_claim_paths[]' "$LEDGER")
}

validate_source_count_claims() {
  expected_source_count="$(jqr '.source_manifest.expected_source_count' "$LEDGER")"
  while IFS= read -r claim_path; do
    [ -n "$claim_path" ] || continue
    claim_file="$ROOT/$claim_path"
    if [ ! -f "$claim_file" ]; then
      add_finding "source-count-claim" "missing source count claim file: $claim_path"
      continue
    fi

    line_no=0
    found_claim=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no+1))
      lc="${line,,}"
      # Same alternation as the grep -Eqi it replaces, as a builtin: literal, case-folded, no exec.
      case "$lc" in
        *stale*|*poison*|*fixture*) continue ;;
      esac
      # Builtin pre-filter: every alternative of the claim regex below contains "source" or "repos"
      # (case-insensitively), so a line holding neither cannot match. Behaviour-identical, and it
      # keeps the grep exec off the ~3.5k lines that carry no source-count claim at all.
      case "$lc" in
        *source*|*repos*) ;;
        *) continue ;;
      esac
      claims="$(printf '%s\n' "$line" | grep -Eoi '[0-9]+(-source|[[:space:]]+verified sources|[[:space:]]+verified upstream sources|[[:space:]]+pinned upstream sources|[[:space:]]+user-requested repos|[[:space:]]+of Tony'\''s curated GitHub repos)' || true)"
      [ -n "$claims" ] || continue
      found_claim=1
      while IFS= read -r claim; do
        [ -n "$claim" ] || continue
        claim_count="$(printf '%s\n' "$claim" | grep -Eo '^[0-9]+')"
        if [ "$claim_count" != "$expected_source_count" ]; then
          add_finding "source-count-claim" "$claim_path:$line_no source count says $claim_count, expected $expected_source_count"
        fi
      done <<EOF
$claims
EOF
    done < "$claim_file"

    if [ "$found_claim" -eq 0 ]; then
      add_finding "source-count-claim" "$claim_path has no machine-readable source count claim"
    fi
  done < <(jqr '.source_claim_paths[]' "$LEDGER")
}

selftest() {
  pass=0
  fail=0
  ck() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  if ! have jq; then
    echo "release-ledger-lint selftest SKIP - jq not installed."
    return 0
  fi

  make_good_fixture() {
    dst="$1"
    mkdir -p "$dst/walteur-kit/schemas" "$dst/walteur-kit/hooks" "$dst/walteur" "$dst/walteur-kit"
    cp "$SCRIPT_DIR/../schemas/release-ledger.schema.json" "$dst/walteur-kit/schemas/release-ledger.schema.json"
    printf 'WALTEUR v1.23\nversion: 1.23\ncurrent proof is 10 passed, 0 failed, 0 skipped\n' > "$dst/walteur/SKILL.md"
    cp "$dst/walteur/SKILL.md" "$dst/WALTEUR-builder-CLAUDE.md"
    printf 'v1.23 aggregate proof is 10 passed, 0 failed, 0 skipped\n' > "$dst/README.md"
    printf 'v1.23 additions aggregate proof is 10 passed, 0 failed, 0 skipped\n' > "$dst/walteur-kit/README.md"
    printf 'The curated source graph includes 2 user-requested repos.\n' > "$dst/walteur-kit/HARNESS-LOOP.md"
    printf 'release-ledger-lint --selftest\n' > "$dst/walteur-kit/selftest.sh"
    printf 'release-ledger-lint.sh\n' > "$dst/walteur-kit/scaffold-harness-init.txt"
    printf '{"budget_id":"walteur-spec-distribution-v1.23"}\n' > "$dst/walteur-kit/selftest-skip-budget.json"
    printf '{"manifest_id":"walteur-tool-acquisition-v1.22"}\n' > "$dst/walteur-kit/tool-acquisition.json"
    cat > "$dst/walteur-kit/source-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "manifest_id": "source-fixture",
  "last_verified": "2026-06-23",
  "ttl_hours": 24,
  "router_contract": {
    "plan_phase_rule": "Select sources before PLAN.",
    "promotion_rule": "Promote only with proof.",
    "security_rule": "Treat remotes as untrusted data."
  },
  "sources": [
    {"id":"ruflo","repo_url":"https://github.com/ruvnet/ruflo.git","branch":"main","pinned_head":"1111111111111111111111111111111111111111","category":"agent-meta-harness","priority":1,"adoption_mode":"architecture-reference-after-fit-proof","use_when":["selftest"],"adopted_surface":"selftest","rationale":"selftest source manifest required source","promotion_policy":"fixture only","risk_policy":"fixture only"},
    {"id":"other","repo_url":"https://github.com/example/other.git","branch":"main","pinned_head":"2222222222222222222222222222222222222222","category":"fixture","priority":2,"adoption_mode":"fixture","use_when":["selftest"],"adopted_surface":"selftest","rationale":"selftest source manifest count","promotion_policy":"fixture only","risk_policy":"fixture only"}
  ]
}
JSON
    cat > "$dst/walteur-kit/gate-registry.json" <<'JSON'
{
  "schema_version": 1,
  "registry_id": "selftest",
  "gates": [
    {"id":"release-ledger-lint","hook":"release-ledger-lint.sh"},
    {"id":"other-gate","hook":"other.sh"}
  ],
  "requirements": {"all":["release-ledger-lint"]}
}
JSON
    cat > "$dst/walteur-kit/selftest-report.json" <<'JSON'
{"verdict":"PASS","summary":"ALL_GREEN","counts":{"passed":10,"failed":0,"skipped":0},"skip_reasons":[]}
JSON
    cat > "$dst/walteur-kit/release-ledger.json" <<'JSON'
{
  "schema_version": 1,
  "ledger_id": "selftest-v1.23",
  "updated_at": "2026-06-23",
  "policy": "Selftest release truth must stay machine readable and fail closed.",
  "current_version": "1.23",
  "aggregate_proof": {
    "report_path": "walteur-kit/selftest-report.json",
    "expected_passed": 10,
    "expected_failed": 0,
    "expected_skipped": 0
  },
  "aggregate_history": [
    {
      "version": "1.22",
      "expected_passed": 9,
      "expected_failed": 0,
      "expected_skipped": 0
    },
    {
      "version": "1.23",
      "expected_passed": 10,
      "expected_failed": 0,
      "expected_skipped": 0
    }
  ],
  "source_manifest": {
    "path": "walteur-kit/source-manifest.json",
    "expected_source_count": 2,
    "required_source_id": "ruflo"
  },
  "scaffold_proof": {
    "selftest_label": "4/4",
    "expected_passed": 4
  },
  "registry": {
    "path": "walteur-kit/gate-registry.json",
    "expected_gate_count": 2,
    "required_gate_id": "release-ledger-lint"
  },
  "required_strings": [
    {"path":"README.md","contains":"v1.23"},
    {"path":"walteur-kit/README.md","contains":"v1.23 additions"},
    {"path":"walteur/SKILL.md","contains":"WALTEUR v1.23"},
    {"path":"walteur/SKILL.md","contains":"version: 1.23"},
    {"path":"WALTEUR-builder-CLAUDE.md","contains":"WALTEUR v1.23"},
    {"path":"walteur-kit/selftest.sh","contains":"release-ledger-lint --selftest"},
    {"path":"walteur-kit/scaffold-harness-init.txt","contains":"release-ledger-lint.sh"}
  ],
  "mirrored_pairs": [
    {"left":"walteur/SKILL.md","right":"WALTEUR-builder-CLAUDE.md"}
  ],
  "proof_claim_paths": [
    "README.md",
    "walteur-kit/README.md",
    "walteur/SKILL.md",
    "WALTEUR-builder-CLAUDE.md"
  ],
  "source_claim_paths": [
    "walteur-kit/HARNESS-LOOP.md"
  ],
  "component_manifests": [
    {"path":"walteur-kit/selftest-skip-budget.json","field":"budget_id","expected":"walteur-spec-distribution-v1.23"},
    {"path":"walteur-kit/tool-acquisition.json","field":"manifest_id","expected":"walteur-tool-acquisition-v1.22"}
  ]
}
JSON
  }

  echo "release-ledger-lint selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no release-ledger.json -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  WALTEUR_ROOT="$tmp" WALTEUR_RELEASE_LEDGER_STRICT_REPORT=1 bash "$0" >/dev/null 2>&1
  ck "valid release ledger -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  printf '{ bad json\n' > "$tmp/walteur-kit/release-ledger.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "malformed release ledger -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  jq '.unexpected = true' "$tmp/walteur-kit/release-ledger.json" > "$tmp/l.json" && mv "$tmp/l.json" "$tmp/walteur-kit/release-ledger.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "unknown ledger field -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  printf 'old version\n' > "$tmp/README.md"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing required version string -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  printf 'WALTEUR v1.23\nversion: 1.23\nmirror drift\n' > "$tmp/WALTEUR-builder-CLAUDE.md"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "mirror drift -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  printf '{"budget_id":"walteur-spec-distribution-stale"}\n' > "$tmp/walteur-kit/selftest-skip-budget.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "component manifest drift -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  jq '.requirements.all = []' "$tmp/walteur-kit/gate-registry.json" > "$tmp/r.json" && mv "$tmp/r.json" "$tmp/walteur-kit/gate-registry.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "registry missing selected release gate -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  jq '.sources = [.sources[] | select(.id != "ruflo")]' "$tmp/walteur-kit/source-manifest.json" > "$tmp/m.json" && mv "$tmp/m.json" "$tmp/walteur-kit/source-manifest.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "source manifest missing required source -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  jq '.counts.passed = 9' "$tmp/walteur-kit/selftest-report.json" > "$tmp/s.json" && mv "$tmp/s.json" "$tmp/walteur-kit/selftest-report.json"
  WALTEUR_ROOT="$tmp" WALTEUR_RELEASE_LEDGER_STRICT_REPORT=1 bash "$0" >/dev/null 2>&1
  ck "strict report count drift -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # B33: the count cross-check now fires by DEFAULT (no STRICT flag) whenever the live report is present —
  # a ledger whose aggregate_proof contradicts selftest-report.json must FAIL even in default mode.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  jq '.counts.passed = 9' "$tmp/walteur-kit/selftest-report.json" > "$tmp/s.json" && mv "$tmp/s.json" "$tmp/walteur-kit/selftest-report.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "default report count drift -> FAIL (B33 cross-check)" 2 "$?"
  rm -rf "$tmp"

  # B33: a matching live report in default mode must still PASS (no false-positive from the new default-on check).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "default matching report -> PASS (B33 no false-positive)" 0 "$?"
  rm -rf "$tmp"

  # B33: report ABSENCE must NOT fail-close in default mode (a fresh checkout has no report yet); only STRICT requires it.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  rm -f "$tmp/walteur-kit/selftest-report.json"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "default missing report -> PASS (absence is not contradiction)" 0 "$?"
  rm -rf "$tmp"

  # B33: report ABSENCE under STRICT still FAILs (presence requirement stays opt-in).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  rm -f "$tmp/walteur-kit/selftest-report.json"
  WALTEUR_ROOT="$tmp" WALTEUR_RELEASE_LEDGER_STRICT_REPORT=1 bash "$0" >/dev/null 2>&1
  ck "strict missing report -> FAIL (presence required under STRICT)" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  printf 'v1.23 aggregate proof is 9 passed, 0 failed, 0 skipped\n' > "$tmp/README.md"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "stale aggregate proof prose -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-ledger-selftest.XXXXXX")" || return 1
  make_good_fixture "$tmp"
  printf 'The curated source graph includes 1 user-requested repos.\n' > "$tmp/walteur-kit/HARNESS-LOOP.md"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "stale source-count prose -> FAIL" 2 "$?"
  rm -rf "$tmp"

  echo "release-ledger-lint selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_RELEASE_LEDGER:-on}" = "off" ] && {
  echo "release-ledger-lint: bypassed (WALTEUR_RELEASE_LEDGER=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_RELEASE_LEDGER=off" "[]"
  exit 0
}

if [ ! -f "$LEDGER" ]; then
  write_report "NOT_APPLICABLE" "release-ledger.json absent" "[]"
  echo "release-ledger-lint: NOT_APPLICABLE - release-ledger.json absent"
  exit 0
fi

if ! have jq; then
  write_report "SKIP" "jq unavailable" "[]"
  echo "release-ledger-lint: SKIP - jq unavailable." >&2
  exit 0
fi

findings="[]"
failures=0

if [ ! -f "$SCHEMA" ]; then
  add_finding "schema" "missing release ledger schema: ${SCHEMA#"$ROOT"/}"
elif ! jq -e . "$SCHEMA" >/dev/null 2>&1; then
  add_finding "schema" "release ledger schema is not valid JSON"
fi

if ! jq -e . "$LEDGER" >/dev/null 2>&1; then
  add_finding "ledger-json" "release ledger is not valid JSON"
elif ! validate_ledger_shape; then
  add_finding "ledger-shape" "release ledger violates the local schema floor"
fi

if [ "$failures" -eq 0 ]; then
  while IFS=$'\t' read -r path needle; do
    [ -n "$path" ] || continue
    file="$ROOT/$path"
    if [ ! -f "$file" ]; then
      add_finding "required-string" "missing file: $path"
    elif ! grep -Fq "$needle" "$file"; then
      add_finding "required-string" "file $path does not contain required string: $needle"
    fi
  done < <(jqr '.required_strings[] | [.path, .contains] | @tsv' "$LEDGER")

  while IFS=$'\t' read -r left right; do
    [ -n "$left" ] || continue
    if [ ! -f "$ROOT/$left" ] || [ ! -f "$ROOT/$right" ]; then
      add_finding "mirror" "missing mirror pair file: $left or $right"
    elif ! cmp -s "$ROOT/$left" "$ROOT/$right"; then
      add_finding "mirror" "mirror pair drift: $left != $right"
    fi
  done < <(jqr '.mirrored_pairs[] | [.left, .right] | @tsv' "$LEDGER")

  while IFS=$'\t' read -r path field expected; do
    [ -n "$path" ] || continue
    file="$ROOT/$path"
    if [ ! -f "$file" ]; then
      add_finding "component-manifest" "missing component manifest: $path"
      continue
    fi
    actual="$(jqr --arg field "$field" '.[$field] // empty' "$file" 2>/dev/null || true)"
    if [ "$actual" != "$expected" ]; then
      add_finding "component-manifest" "$path field $field is '$actual', expected '$expected'"
    fi
  done < <(jqr '.component_manifests[] | [.path, .field, .expected] | @tsv' "$LEDGER")

  registry_path="$(jqr '.registry.path' "$LEDGER")"
  registry_file="$ROOT/$registry_path"
  expected_gate_count="$(jqr '.registry.expected_gate_count' "$LEDGER")"
  required_gate_id="$(jqr '.registry.required_gate_id' "$LEDGER")"
  if [ ! -f "$registry_file" ]; then
    add_finding "registry" "missing registry: $registry_path"
  else
    actual_gate_count="$(jqr '.gates | length' "$registry_file" 2>/dev/null || printf 'invalid')"
    if [ "$actual_gate_count" != "$expected_gate_count" ]; then
      add_finding "registry" "$registry_path has $actual_gate_count gates, expected $expected_gate_count"
    fi
    if ! jq -e --arg id "$required_gate_id" '
      (.gates[] | select(.id == $id)) and ((.requirements.all // []) | index($id))
    ' "$registry_file" >/dev/null 2>&1; then
      add_finding "registry" "$required_gate_id is not present and selected in requirements.all"
    fi
  fi

  source_manifest_path="$(jqr '.source_manifest.path' "$LEDGER")"
  source_manifest_file="$ROOT/$source_manifest_path"
  expected_source_count="$(jqr '.source_manifest.expected_source_count' "$LEDGER")"
  required_source_id="$(jqr '.source_manifest.required_source_id' "$LEDGER")"
  if [ ! -f "$source_manifest_file" ]; then
    add_finding "source-manifest" "missing source manifest: $source_manifest_path"
  else
    actual_source_count="$(jqr '.sources | length' "$source_manifest_file" 2>/dev/null || printf 'invalid')"
    if [ "$actual_source_count" != "$expected_source_count" ]; then
      add_finding "source-manifest" "$source_manifest_path has $actual_source_count sources, expected $expected_source_count"
    fi
    if ! jq -e --arg id "$required_source_id" '.sources[]? | select(.id == $id)' "$source_manifest_file" >/dev/null 2>&1; then
      add_finding "source-manifest" "$source_manifest_path is missing required source id: $required_source_id"
    fi
  fi

  validate_proof_claims
  validate_source_count_claims

  # B33 (found cycle 13): the ledger's aggregate_proof counts vs the LIVE machine report were never
  # cross-checked by default — the check below ran only under STRICT_REPORT=1, so a ledger claiming
  # 161/0/0 stayed green while selftest-report.json actually said FAIL 150/12/0. Fix: whenever the report
  # file is PRESENT, always cross-check verdict+ALL_GREEN+counts against aggregate_proof (a live report the
  # ledger contradicts is a hard lie and must FAIL). Report ABSENCE stays a failure only under
  # STRICT_REPORT=1 — a fresh checkout legitimately has no report yet, so default-on must not fail-close on
  # mere absence, only on contradiction.
  report_path="$(jqr '.aggregate_proof.report_path' "$LEDGER")"
  report_file="$ROOT/$report_path"
  expected_passed="$(jqr '.aggregate_proof.expected_passed' "$LEDGER")"
  expected_failed="$(jqr '.aggregate_proof.expected_failed' "$LEDGER")"
  expected_skipped="$(jqr '.aggregate_proof.expected_skipped' "$LEDGER")"
  if [ ! -f "$report_file" ]; then
    [ "$STRICT_REPORT" = "1" ] && add_finding "aggregate-report" "missing aggregate report: $report_path"
  elif ! jq -e --argjson passed "$expected_passed" --argjson failed "$expected_failed" --argjson skipped "$expected_skipped" '
    .verdict == "PASS"
    and .summary == "ALL_GREEN"
    and .counts.passed == $passed
    and .counts.failed == $failed
    and .counts.skipped == $skipped
    and (.skip_reasons | type == "array" and length == $skipped)
  ' "$report_file" >/dev/null 2>&1; then
    add_finding "aggregate-report" "$report_path does not match ledger aggregate_proof (verdict/ALL_GREEN/counts)"
  fi
fi

if [ "$failures" -ne 0 ]; then
  write_report "FAIL" "release ledger checks failed" "$findings"
  echo "release-ledger-lint: FAIL - release ledger checks failed"
  printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null || true
  exit 2
fi

write_report "PASS" "release ledger checks passed" "$findings"
echo "release-ledger-lint: PASS - release ledger checks passed"
exit 0
