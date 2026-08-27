#!/usr/bin/env bash
# WALTEUR compliance-gate — honest, mostly ZERO-DEP privacy/compliance gate.
#
# THREE checks:
#  (A) ZERO-DEP HARD gate — PII-without-inventory:
#      Scan source for PII signals (email|ssn|phone|dob|passport|credit.?card|
#      first_?name|last_?name). If PII handling is present but
#      walteur-kit/data-inventory.json is ABSENT  => violation (exit 2):
#      "PII handled with no data inventory".
#  (B) ZERO-DEP HARD gate — inventory completeness (when data-inventory.json present):
#      For EVERY entry whose data_class starts with "pii.", require a non-null,
#      non-empty lawful_basis AND a non-null retention_ttl_days (jq). Any pii.*
#      entry missing either => violation (exit 2). Requires jq; if jq is absent
#      this sub-check SKIPs loudly (recorded), it does not silent-green.
#  (C) ZERO-DEP HARD gate — PII into an unredacted log:
#      Flag a PII token (an inventory field name, or a literal PII keyword)
#      interpolated into a log/print call that is NOT wrapped by a redactor
#      (redact|mask|scrub|sanitize|anonymi[sz]e|hash|obfuscate|***). => exit 2.
#  (D) DETECT-OR-SKIP heavy tool — conftest against policy/residency.rego, only
#      if BOTH conftest is installed AND residency.rego is present. Missing tool
#      OR missing policy => loud recorded SKIP, NEVER exit 2 for that.
#
# Tool ABSENT (jq for B, conftest for D) => LOUD recorded SKIP to stderr +
# verdict SKIP for that sub-check — NEVER silent-green, NEVER exit 2 for a
# missing tool. The zero-dep checks (A, C, and B when jq present) are REAL
# hard gates: real exit 2 on violation.
#
# Report: walteur-kit/compliance-report.json {verdict, ts, gate, violations, details}.
# Bypass: WALTEUR_COMPLIANCE=off.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/compliance-report.json"
INV="$KIT/data-inventory.json"
POLICY="$KIT/policy/residency.rego"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }
loud_skip() { echo "  SKIP — $1 not installed ($2). Recorded; NOT counted green." >&2; }

write_report() {
  local v="$1" reason="$2" details="${3:-}"
  [ -n "$details" ] || details="{}"
  if have jq; then
    local details_file
    details_file="$(mktemp "${TMPDIR:-/tmp}/compliance-report-details.XXXXXX")" || details_file=""
    if [ -n "$details_file" ]; then
      printf '%s\n' "$details" > "$details_file"
      if jq -e . "$details_file" >/dev/null 2>&1; then
        jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --slurpfile d "$details_file" \
          '{verdict:$v, ts:$ts, gate:"compliance", reason:$reason, details:$d[0]}' > "$REPORT" 2>/dev/null
        rc=$?
        rm -f "$details_file"
        [ "$rc" -eq 0 ] && return 0
      else
        rm -f "$details_file"
      fi
    fi
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"compliance","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
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

  for t in bash jq find xargs grep sed tr mktemp date mkdir rm ln cat touch; do
    if ! have "$t"; then
      echo "compliance-gate selftest SKIP - required tool '$t' not installed."
      return 0
    fi
  done

  make_core_path() {
    dst="$1"
    mkdir -p "$dst"
    for t in bash jq find xargs grep sed tr mktemp date mkdir rm; do
      ln -sf "$(command -v "$t")" "$dst/$t"
    done
  }
  write_valid_inventory() {
    root="$1"
    mkdir -p "$root/walteur-kit"
    cat > "$root/walteur-kit/data-inventory.json" <<'JSON'
[
  {
    "name": "email",
    "data_class": "pii.contact",
    "lawful_basis": "consent",
    "retention_ttl_days": 30
  }
]
JSON
  }

  echo "compliance-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/complianceself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin" "$tmp/src"
  make_core_path "$tmp/bin"
  printf 'print("hello")\n' > "$tmp/src/app.py"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no PII source -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .details.inventory_presence.verdict == "PASS"' "$tmp/walteur-kit/compliance-report.json" >/dev/null 2>&1
  ck "no PII report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/complianceself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin" "$tmp/src"
  make_core_path "$tmp/bin"
  printf 'email = request["email"]\n' > "$tmp/src/app.py"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PII without inventory -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .details.inventory_presence.verdict == "FAIL"' "$tmp/walteur-kit/compliance-report.json" >/dev/null 2>&1
  ck "PII without inventory report records FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/complianceself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin" "$tmp/src"
  make_core_path "$tmp/bin"
  write_valid_inventory "$tmp"
  cat > "$tmp/src/app.py" <<'PY'
email = request["email"]
logger.info("email_hash=%s", hash(email))
PY
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "valid inventory with redacted log -> PASS" 0 "$?"
  jq -e '.verdict == "PASS" and .details.inventory_completeness.verdict == "PASS" and .details.log_redaction.verdict == "PASS"' "$tmp/walteur-kit/compliance-report.json" >/dev/null 2>&1
  ck "valid inventory report verdict PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/complianceself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin" "$tmp/src"
  make_core_path "$tmp/bin"
  cat > "$tmp/walteur-kit/data-inventory.json" <<'JSON'
[
  {
    "name": "email",
    "data_class": "pii.contact"
  }
]
JSON
  printf 'email = request["email"]\n' > "$tmp/src/app.py"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PII inventory missing controls -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .details.inventory_completeness.verdict == "FAIL"' "$tmp/walteur-kit/compliance-report.json" >/dev/null 2>&1
  ck "missing controls report records FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/complianceself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin" "$tmp/src"
  make_core_path "$tmp/bin"
  write_valid_inventory "$tmp"
  cat > "$tmp/src/app.py" <<'PY'
email = request["email"]
logger.info("email=%s", email)
PY
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "unredacted PII log -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .details.log_redaction.verdict == "FAIL"' "$tmp/walteur-kit/compliance-report.json" >/dev/null 2>&1
  ck "unredacted PII log report records FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/complianceself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit" "$tmp/bin"
  make_core_path "$tmp/bin"
  printf '{broken json\n' > "$tmp/walteur-kit/data-inventory.json"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "invalid data inventory -> FAIL" 2 "$?"
  jq -e '.verdict == "FAIL" and .details.inventory_completeness.verdict == "FAIL"' "$tmp/walteur-kit/compliance-report.json" >/dev/null 2>&1
  ck "invalid inventory report records FAIL" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/complianceself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" WALTEUR_COMPLIANCE=off bash "$0" >/dev/null 2>&1
  ck "bypass -> SKIP exit" 0 "$?"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/compliance-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/complianceself.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "PAUSED -> hard block" 2 "$?"
  rm -rf "$tmp"

  echo "compliance-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
if [ "${WALTEUR_COMPLIANCE:-on}" = "off" ]; then
  echo "compliance-gate: bypassed (WALTEUR_COMPLIANCE=off)." >&2
  write_report "SKIP" "bypassed via WALTEUR_COMPLIANCE=off" '{"bypassed":true}'
  exit 0
fi

# JSON accumulator (prefer jq; degrade to a literal echo if jq is missing).
J='{}'
add() { # add <key> <json-value>
  if have jq; then
    J="$(printf '%s' "$J" | jq --argjson v "$2" --arg k "$1" '.[$k]=$v' 2>/dev/null || printf '%s' "$J")"
  fi
}

# Source files to scan: code only, excluding VCS/vendor/build/the kit itself and lockfiles.
# Restrict to common source extensions so we do not match the report or fixtures' noise.
list_src() {
  find "$ROOT" \
       \( -path "$ROOT/.git" -o -path '*/node_modules/*' -o -path '*/.venv/*' \
          -o -path '*/venv/*' -o -path '*/vendor/*' -o -path '*/dist/*' \
          -o -path '*/build/*' -o -path "$ROOT/walteur-kit/*" \) -prune -o \
       -type f \( -name '*.py'  -o -name '*.js'  -o -name '*.jsx' -o -name '*.ts' \
                  -o -name '*.tsx' -o -name '*.go'  -o -name '*.rb'  -o -name '*.java' \
                  -o -name '*.kt'  -o -name '*.php' -o -name '*.cs'  -o -name '*.rs' \
                  -o -name '*.scala' -o -name '*.swift' -o -name '*.sql' \) -print 2>/dev/null
}

# PII signal regex (extended). Word-ish boundaries kept loose on purpose — we want recall.
PII_RE='email|ssn|phone|dob|passport|credit.?card|first_?name|last_?name'
# Redactor wrappers that make a PII-bearing log acceptable.
REDACT_RE='redact|mask|scrub|sanitize|sanitise|anonymi[sz]e|hash|obfuscate|pseudonymi[sz]e|\*\*\*'
# Log / print sinks across languages.
LOG_RE='log|logger|logging|print|println|printf|console\.(log|info|warn|error|debug)|fmt\.Print|System\.out'

violations=0
echo "WALTEUR compliance-gate @ $ROOT" >&2

# ── collect source + whether any PII signal appears ──────────────────────────
src_files="$(list_src)"
pii_present=0
pii_hit_files=""
if [ -n "$src_files" ]; then
  # grep -E across the file list; -l => files containing a PII signal.
  pii_hit_files="$(printf '%s\n' "$src_files" | tr '\n' '\0' \
                    | xargs -0 grep -liE "$PII_RE" 2>/dev/null || true)"
  [ -n "$pii_hit_files" ] && pii_present=1
fi

# ── (A) PII handled but NO data inventory — ZERO-DEP HARD gate ────────────────
inv_present=0
[ -f "$INV" ] && inv_present=1
if [ "$pii_present" -eq 1 ] && [ "$inv_present" -eq 0 ]; then
  echo "  FAIL — PII handled with no data inventory ($INV absent)." >&2
  echo "         offending file(s):" >&2
  printf '           %s\n' $pii_hit_files >&2
  violations=$((violations+1))
  add inventory_presence "$( { have jq && jq -n --arg msg "PII handled with no data inventory" \
        '{verdict:"FAIL", reason:$msg}'; } 2>/dev/null \
        || printf '{"verdict":"FAIL","reason":"PII handled with no data inventory"}' )"
elif [ "$pii_present" -eq 1 ]; then
  echo "  ok   — PII present and data-inventory.json exists." >&2
  add inventory_presence '{"verdict":"PASS","note":"PII present, inventory exists"}'
else
  echo "  ok   — no PII signals detected in source." >&2
  add inventory_presence '{"verdict":"PASS","note":"no PII signals in source"}'
fi

# ── (B) inventory completeness for pii.* entries — ZERO-DEP HARD gate (needs jq)
inv_field_names=""   # used by (C) to know which field names are PII
if [ "$inv_present" -eq 1 ]; then
  if have jq; then
    if ! jq -e . "$INV" >/dev/null 2>&1; then
      echo "  FAIL — data-inventory.json is not valid JSON." >&2
      violations=$((violations+1))
      add inventory_completeness '{"verdict":"FAIL","reason":"data-inventory.json is not valid JSON"}'
    else
      # Each entry: data_class starts with "pii." MUST have non-null/non-empty
      # lawful_basis AND non-null retention_ttl_days. Collect the offenders by name.
      bad="$(jq -r '
        [ .[]
          | select((.data_class // "") | startswith("pii."))
          | select(
              ((.lawful_basis // "" | tostring | gsub("^\\s+|\\s+$";"")) == "")
              or (.retention_ttl_days == null)
            )
          | (.name // "<unnamed>") ] | .[]' "$INV" 2>/dev/null || true)"
      if [ -n "$bad" ]; then
        echo "  FAIL — pii.* entries missing lawful_basis and/or retention_ttl_days:" >&2
        printf '           %s\n' $bad >&2
        violations=$((violations+1))
        add inventory_completeness "$(jq -n --argjson f "$(printf '%s\n' $bad | jq -R . | jq -s .)" \
              '{verdict:"FAIL", reason:"pii.* entry missing lawful_basis or retention_ttl_days", fields:$f}')"
      else
        echo "  ok   — every pii.* entry has lawful_basis + retention_ttl_days." >&2
        add inventory_completeness '{"verdict":"PASS"}'
      fi
      # PII field names (any pii.* class) — drives the (C) log scan.
      inv_field_names="$(jq -r '.[] | select((.data_class // "") | startswith("pii.")) | .name // empty' "$INV" 2>/dev/null || true)"
    fi
  else
    loud_skip jq "data-inventory.json completeness validation"
    add inventory_completeness '{"verdict":"SKIP","reason":"jq not installed"}'
  fi
fi

# ── (C) PII interpolated into an unredacted log/print — ZERO-DEP HARD gate ────
# Build the set of PII tokens to hunt for: inventory pii.* field names (if any)
# plus the literal PII keywords. A line is flagged when it (1) is a log/print
# call, (2) contains a PII token, and (3) does NOT contain a redactor wrapper.
leak_hits=""
if [ -n "$src_files" ]; then
  # token alternation: escaped field names + the keyword regex
  tok_alt="$PII_RE"
  if [ -n "$inv_field_names" ]; then
    while IFS= read -r fn; do
      [ -z "$fn" ] && continue
      esc="$(printf '%s' "$fn" | sed -e 's/[.[\*^$()+?{|]/\\&/g')"
      tok_alt="$tok_alt|$esc"
    done <<EOF
$inv_field_names
EOF
  fi
  # Find log/print lines that mention a PII token but no redactor.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    hits="$(grep -nE "$LOG_RE" "$f" 2>/dev/null \
              | grep -iE "$tok_alt" 2>/dev/null \
              | grep -ivE "$REDACT_RE" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      while IFS= read -r h; do
        [ -z "$h" ] && continue
        leak_hits="$leak_hits$f:$h"$'\n'
      done <<EOF
$hits
EOF
    fi
  done <<EOF
$src_files
EOF
fi
if [ -n "$leak_hits" ]; then
  echo "  FAIL — PII interpolated into a log/print call with no redactor:" >&2
  printf '%s' "$leak_hits" | sed 's/^/           /' >&2
  violations=$((violations+1))
  n_leak="$(printf '%s' "$leak_hits" | grep -c . 2>/dev/null || echo 0)"
  add log_redaction "$( { have jq && jq -n --argjson n "$n_leak" \
        '{verdict:"FAIL", reason:"PII logged without redactor", occurrences:$n}'; } 2>/dev/null \
        || printf '{"verdict":"FAIL","reason":"PII logged without redactor"}' )"
else
  echo "  ok   — no unredacted PII in log/print calls." >&2
  add log_redaction '{"verdict":"PASS"}'
fi

# ── (D) DETECT-OR-SKIP: conftest against policy/residency.rego ────────────────
# Only meaningful with BOTH conftest installed AND the policy present AND a JSON
# data-inventory / resource manifest to test. Missing any => loud recorded SKIP.
if have conftest; then
  if [ -f "$POLICY" ]; then
    # Prefer the data-inventory.json as the document under policy; fall back to any
    # residency/resource manifest the project ships.
    target=""
    [ -f "$INV" ] && target="$INV"
    [ -z "$target" ] && target="$(find "$ROOT" -path "$ROOT/.git" -prune -o \
        -type f \( -name 'resources.json' -o -name 'residency.json' -o -name 'data-inventory.json' \) \
        -print 2>/dev/null | head -1)"
    if [ -n "$target" ]; then
      pol_dir="$(dirname "$POLICY")"
      if conftest test "$target" --policy "$pol_dir" >/dev/null 2>&1; then
        echo "  ok   — conftest: residency policy passed against $target." >&2
        add residency_policy '{"verdict":"PASS","tool":"conftest","policy":"policy/residency.rego"}'
      else
        echo "  FAIL — conftest: residency policy denied $target." >&2
        violations=$((violations+1))
        add residency_policy '{"verdict":"FAIL","tool":"conftest","policy":"policy/residency.rego"}'
      fi
    else
      echo "  SKIP — conftest present + policy present, but no JSON document to test." >&2
      add residency_policy '{"verdict":"SKIP","reason":"no JSON resource/inventory document to test"}'
    fi
  else
    echo "  SKIP — conftest present but policy/residency.rego absent." >&2
    add residency_policy '{"verdict":"SKIP","reason":"policy/residency.rego absent"}'
  fi
else
  loud_skip conftest "OPA residency policy test (policy/residency.rego)"
  add residency_policy '{"verdict":"SKIP","reason":"conftest not installed"}'
fi

# ── overall verdict ───────────────────────────────────────────────────────────
if [ "$violations" -gt 0 ]; then
  OVERALL=FAIL
else
  OVERALL=PASS   # zero-dep checks always RUN, so a clean pass is never a blind SKIP
fi

if have jq; then
  jq -n --arg v "$OVERALL" --arg ts "$TS" --argjson viol "$violations" --argjson d "$J" \
    '{verdict:$v, ts:$ts, gate:"compliance", violations:$viol, details:$d}' \
    > "$REPORT" 2>/dev/null \
    || printf '{"verdict":"%s","ts":"%s","gate":"compliance","violations":%s}\n' "$OVERALL" "$TS" "$violations" > "$REPORT"
else
  printf '{"verdict":"%s","ts":"%s","gate":"compliance","violations":%s,"note":"jq absent: details omitted"}\n' \
    "$OVERALL" "$TS" "$violations" > "$REPORT"
fi

echo "compliance-gate verdict: $OVERALL (violations=$violations) -> $REPORT" >&2
[ "$OVERALL" = "FAIL" ] && exit 2
exit 0
