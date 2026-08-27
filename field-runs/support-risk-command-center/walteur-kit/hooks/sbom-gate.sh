#!/usr/bin/env bash
# WALTEUR sbom-gate - first-class dependency inventory / SBOM proof.
#
# APPLICABILITY: dependency or container surface exists.
#   Lockfiles, dependency manifests, project files, Dockerfile/Containerfile, or compose files
#   make this gate relevant. If none exist: NOT_APPLICABLE, exit 0.
#
# HARD CHECKS:
#   1. A persisted SBOM must be valid JSON if present.
#   2. Accepted SBOM formats must contain a non-empty inventory:
#      CycloneDX: .bomFormat == "CycloneDX" and .components length > 0.
#      SPDX:      .spdxVersion string and .packages length > 0.
#      Syft JSON: .artifacts length > 0.
#   3. A present syft binary must generate a non-empty inventory.
#
# DETECT-OR-SKIP:
#   Dependency surface with no persisted SBOM and no syft binary records SKIP. This is not green.
#
# Report: walteur-kit/sbom-report.json.
# Bypass: WALTEUR_SBOM=off or WALTEUR_SBOM_GATE=off. Pause: walteur-kit/PAUSED present.
set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/sbom-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

relpath() {
  case "$1" in
    "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

write_report() {
  local verdict="$1" reason="$2" details="${3:-{}}"
  if have jq && printf '%s\n' "$details" | jq -e . >/dev/null 2>&1; then
    jq -n \
      --arg verdict "$verdict" \
      --arg ts "$TS" \
      --arg reason "$reason" \
      --argjson details "$details" \
      '{verdict:$verdict, ts:$ts, gate:"sbom-gate", reason:$reason, details:$details}' > "$REPORT" 2>/dev/null \
      && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"sbom-gate","reason":"%s"}\n' "$verdict" "$TS" "$reason" > "$REPORT"
}

detect_dependency_signal() {
  local f pj
  f="$(find "$ROOT" \
    \( -path '*/.git/*' -o -path '*/node_modules/*' -o -path '*/dist/*' -o -path '*/build/*' \
       -o -path '*/out/*' -o -path '*/coverage/*' -o -path '*/.next/*' -o -path '*/.output/*' \
       -o -path '*/.svelte-kit/*' -o -path '*/vendor/*' \) -prune -o \
    -type f \( \
      -name 'package-lock.json' -o -name 'npm-shrinkwrap.json' -o -name 'pnpm-lock.yaml' \
      -o -name 'yarn.lock' -o -name 'bun.lock' -o -name 'bun.lockb' \
      -o -name 'requirements.txt' -o -name 'requirements*.txt' -o -name 'pyproject.toml' \
      -o -name 'poetry.lock' -o -name 'Pipfile.lock' -o -name 'uv.lock' \
      -o -name 'go.mod' -o -name 'go.sum' -o -name 'Cargo.lock' -o -name 'Cargo.toml' \
      -o -name 'pom.xml' -o -name 'build.gradle' -o -name 'build.gradle.kts' -o -name 'gradle.lockfile' \
      -o -name 'composer.lock' -o -name 'Gemfile.lock' -o -name 'mix.lock' -o -name 'pubspec.lock' \
      -o -name 'Package.resolved' -o -name 'packages.lock.json' \
      -o -name '*.csproj' -o -name '*.fsproj' -o -name '*.vbproj' \
      -o -iname 'Dockerfile' -o -iname 'Dockerfile.*' -o -iname '*.dockerfile' -o -iname 'Containerfile' \
      -o -iname 'docker-compose.yml' -o -iname 'docker-compose.yaml' \
    \) -print 2>/dev/null | head -1)"
  if [ -n "$f" ]; then
    relpath "$f"
    return 0
  fi

  if have jq; then
    while IFS= read -r pj; do
      [ -z "$pj" ] && continue
      if jq -e '((.dependencies // {}) + (.devDependencies // {}) + (.peerDependencies // {}) + (.optionalDependencies // {})) | length > 0' "$pj" >/dev/null 2>&1; then
        relpath "$pj"
        return 0
      fi
    done < <(find "$ROOT" \
      \( -path '*/.git/*' -o -path '*/node_modules/*' -o -path '*/dist/*' -o -path '*/build/*' \
         -o -path '*/out/*' -o -path '*/coverage/*' \) -prune -o \
      -name 'package.json' -type f -print 2>/dev/null)
  fi

  return 1
}

find_existing_sbom() {
  if [ -n "${WALTEUR_SBOM_FILE:-}" ]; then
    [ -f "$WALTEUR_SBOM_FILE" ] && printf '%s' "$WALTEUR_SBOM_FILE"
    return 0
  fi

  local f
  for f in \
    "$KIT/sbom.json" \
    "$KIT/sbom.cyclonedx.json" \
    "$KIT/sbom.spdx.json" \
    "$KIT/sbom.syft.json" \
    "$ROOT/sbom.json" \
    "$ROOT/bom.json" \
    "$ROOT/sbom.cyclonedx.json" \
    "$ROOT/sbom.spdx.json" \
    "$ROOT/sbom.syft.json"
  do
    if [ -f "$f" ]; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 1
}

classify_sbom() {
  local file="$1"
  jq -c '
    if (.bomFormat? == "CycloneDX") then
      {format:"CycloneDX", inventory_count:((.components // []) | length)}
    elif ((.spdxVersion? | type) == "string") then
      {format:"SPDX", inventory_count:((.packages // []) | length)}
    elif ((.artifacts? | type) == "array") then
      {format:"Syft", inventory_count:(.artifacts | length)}
    else
      {format:"unknown", inventory_count:0}
    end
  ' "$file" 2>/dev/null
}

selftest() {
  local pass=0 fail=0 tmp rc
  local SELF_PATH
  SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  ck() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
      echo "  ok   - $name (rc=$got)"
      pass=$((pass+1))
    else
      echo "  FAIL - $name (want $want got $got)"
      fail=$((fail+1))
    fi
  }

  for t in bash jq find head mktemp date mkdir rm chmod ln; do
    if ! have "$t"; then
      echo "sbom-gate selftest SKIP - required tool '$t' not installed."
      return 0
    fi
  done

  make_project() {
    local dst="$1"
    mkdir -p "$dst/walteur-kit"
    printf '{"lockfileVersion":3,"packages":{"node_modules/demo":{"version":"1.0.0"}}}\n' > "$dst/package-lock.json"
  }

  make_core_path() {
    local dst="$1" t
    mkdir -p "$dst"
    for t in bash jq find head mktemp date mkdir rm chmod; do
      ln -sf "$(command -v "$t")" "$dst/$t"
    done
  }

  write_cyclonedx() {
    cat > "$1/walteur-kit/sbom.json" <<'JSON'
{"bomFormat":"CycloneDX","specVersion":"1.5","components":[{"type":"library","name":"demo","version":"1.0.0"}]}
JSON
  }

  write_spdx() {
    cat > "$1/walteur-kit/sbom.json" <<'JSON'
{"spdxVersion":"SPDX-2.3","packages":[{"name":"demo","SPDXID":"SPDXRef-demo","versionInfo":"1.0.0"}]}
JSON
  }

  write_syft_json() {
    cat > "$1/walteur-kit/sbom.json" <<'JSON'
{"artifacts":[{"name":"demo","version":"1.0.0","type":"npm"}]}
JSON
  }

  echo "sbom-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sbom-gate-selftest.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "no dependency signal -> NOT_APPLICABLE" 0 "$rc"
  jq -e '.verdict == "NOT_APPLICABLE"' "$tmp/walteur-kit/sbom-report.json" >/dev/null 2>&1
  ck "no dependency report verdict NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sbom-gate-selftest.XXXXXX")" || return 1
  make_project "$tmp"
  write_cyclonedx "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "valid CycloneDX SBOM -> PASS" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sbom-gate-selftest.XXXXXX")" || return 1
  make_project "$tmp"
  write_spdx "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "valid SPDX SBOM -> PASS" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sbom-gate-selftest.XXXXXX")" || return 1
  make_project "$tmp"
  write_syft_json "$tmp"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "valid Syft JSON SBOM -> PASS" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sbom-gate-selftest.XXXXXX")" || return 1
  make_project "$tmp"
  make_core_path "$tmp/bin"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "dependency signal without SBOM or syft -> SKIP" 0 "$rc"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/sbom-report.json" >/dev/null 2>&1
  ck "missing tool report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sbom-gate-selftest.XXXXXX")" || return 1
  make_project "$tmp"
  printf '{ bad json\n' > "$tmp/walteur-kit/sbom.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "malformed SBOM -> FAIL" 2 "$rc"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sbom-gate-selftest.XXXXXX")" || return 1
  make_project "$tmp"
  printf '{"bomFormat":"CycloneDX","components":[]}\n' > "$tmp/walteur-kit/sbom.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "empty CycloneDX inventory -> FAIL" 2 "$rc"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sbom-gate-selftest.XXXXXX")" || return 1
  make_project "$tmp"
  make_core_path "$tmp/bin"
  cat > "$tmp/bin/syft" <<'SH'
#!/usr/bin/env bash
printf '{"bomFormat":"CycloneDX","components":[{"type":"library","name":"demo","version":"1.0.0"}]}\n'
SH
  chmod +x "$tmp/bin/syft"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "fake syft non-empty SBOM -> PASS" 0 "$rc"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sbom-gate-selftest.XXXXXX")" || return 1
  make_project "$tmp"
  make_core_path "$tmp/bin"
  cat > "$tmp/bin/syft" <<'SH'
#!/usr/bin/env bash
printf '{"bomFormat":"CycloneDX","components":[]}\n'
SH
  chmod +x "$tmp/bin/syft"
  PATH="$tmp/bin" WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "fake syft empty SBOM -> FAIL" 2 "$rc"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sbom-gate-selftest.XXXXXX")" || return 1
  make_project "$tmp"
  WALTEUR_ROOT="$tmp" WALTEUR_SBOM=off bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "bypass -> SKIP exit" 0 "$rc"
  jq -e '.verdict == "SKIP"' "$tmp/walteur-kit/sbom-report.json" >/dev/null 2>&1
  ck "bypass report verdict SKIP" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sbom-gate-selftest.XXXXXX")" || return 1
  make_project "$tmp"
  touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1; rc=$?
  ck "PAUSED -> hard block" 2 "$rc"
  rm -rf "$tmp"

  echo "sbom-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

if [ -f "$KIT/PAUSED" ]; then
  write_report "FAIL" "walteur-kit/PAUSED present" '{"paused":true}'
  echo "sbom-gate verdict: FAIL - walteur-kit/PAUSED present -> $REPORT" >&2
  exit 2
fi

if [ "${WALTEUR_SBOM:-on}" = "off" ] || [ "${WALTEUR_SBOM_GATE:-on}" = "off" ]; then
  write_report "SKIP" "bypassed via WALTEUR_SBOM=off or WALTEUR_SBOM_GATE=off" '{"bypassed":true}'
  echo "sbom-gate verdict: SKIP - bypassed -> $REPORT" >&2
  exit 0
fi

for t in find head jq mktemp date mkdir rm; do
  if ! have "$t"; then
    write_report "SKIP" "$t not installed" "$(printf '{"missing_tool":"%s"}' "$t")"
    echo "sbom-gate SKIP - required tool '$t' not installed (recorded, not silent-green)." >&2
    exit 0
  fi
done

dependency_signal=""
if dependency_signal="$(detect_dependency_signal)"; then
  :
else
  dependency_signal=""
fi

if [ -z "$dependency_signal" ]; then
  write_report "NOT_APPLICABLE" "no dependency or container signal found" '{"dependency_signal":null}'
  echo "sbom-gate verdict: NOT_APPLICABLE - no dependency or container signal -> $REPORT" >&2
  exit 0
fi

if [ -n "${WALTEUR_SBOM_FILE:-}" ] && [ ! -f "$WALTEUR_SBOM_FILE" ]; then
  details="$(jq -n --arg signal "$dependency_signal" --arg file "$WALTEUR_SBOM_FILE" '{dependency_signal:$signal, sbom_file:$file}')"
  write_report "FAIL" "WALTEUR_SBOM_FILE does not exist" "$details"
  echo "sbom-gate verdict: FAIL - WALTEUR_SBOM_FILE does not exist -> $REPORT" >&2
  exit 2
fi

sbom_file=""
sbom_file="$(find_existing_sbom || true)"
if [ -n "$sbom_file" ]; then
  sbom_rel="$(relpath "$sbom_file")"
  if ! jq -e . "$sbom_file" >/dev/null 2>&1; then
    details="$(jq -n --arg signal "$dependency_signal" --arg file "$sbom_rel" '{dependency_signal:$signal, sbom_file:$file}')"
    write_report "FAIL" "SBOM is not valid JSON" "$details"
    echo "sbom-gate verdict: FAIL - SBOM is not valid JSON ($sbom_rel) -> $REPORT" >&2
    exit 2
  fi
  summary="$(classify_sbom "$sbom_file")"
  if printf '%s\n' "$summary" | jq -e '.format != "unknown" and .inventory_count > 0' >/dev/null 2>&1; then
    details="$(jq -n --arg signal "$dependency_signal" --arg file "$sbom_rel" --argjson summary "$summary" '{dependency_signal:$signal, sbom_file:$file, source:"persisted", summary:$summary}')"
    write_report "PASS" "valid persisted SBOM with non-empty inventory" "$details"
    echo "sbom-gate verdict: PASS - valid persisted SBOM ($sbom_rel) -> $REPORT" >&2
    exit 0
  fi
  details="$(jq -n --arg signal "$dependency_signal" --arg file "$sbom_rel" --argjson summary "$summary" '{dependency_signal:$signal, sbom_file:$file, source:"persisted", summary:$summary}')"
  write_report "FAIL" "SBOM has no recognized non-empty inventory" "$details"
  echo "sbom-gate verdict: FAIL - SBOM has no recognized non-empty inventory ($sbom_rel) -> $REPORT" >&2
  exit 2
fi

if have syft; then
  tmp_sbom="$(mktemp "${TMPDIR:-/tmp}/walteur-sbom.XXXXXX.json")" || {
    write_report "FAIL" "could not allocate temporary SBOM file" "$(jq -n --arg signal "$dependency_signal" '{dependency_signal:$signal}')"
    exit 2
  }
  if syft "dir:$ROOT" -o cyclonedx-json > "$tmp_sbom" 2>/dev/null; then
    if jq -e . "$tmp_sbom" >/dev/null 2>&1; then
      summary="$(classify_sbom "$tmp_sbom")"
      rm -f "$tmp_sbom"
      if printf '%s\n' "$summary" | jq -e '.format != "unknown" and .inventory_count > 0' >/dev/null 2>&1; then
        details="$(jq -n --arg signal "$dependency_signal" --argjson summary "$summary" '{dependency_signal:$signal, source:"syft", summary:$summary}')"
        write_report "PASS" "syft generated non-empty SBOM" "$details"
        echo "sbom-gate verdict: PASS - syft generated non-empty SBOM -> $REPORT" >&2
        exit 0
      fi
      details="$(jq -n --arg signal "$dependency_signal" --argjson summary "$summary" '{dependency_signal:$signal, source:"syft", summary:$summary}')"
      write_report "FAIL" "syft generated an empty or unrecognized SBOM" "$details"
      echo "sbom-gate verdict: FAIL - syft generated an empty or unrecognized SBOM -> $REPORT" >&2
      exit 2
    fi
    rm -f "$tmp_sbom"
    write_report "FAIL" "syft output was not valid JSON" "$(jq -n --arg signal "$dependency_signal" '{dependency_signal:$signal, source:"syft"}')"
    echo "sbom-gate verdict: FAIL - syft output was not valid JSON -> $REPORT" >&2
    exit 2
  fi
  rm -f "$tmp_sbom"
  write_report "FAIL" "syft failed to generate SBOM" "$(jq -n --arg signal "$dependency_signal" '{dependency_signal:$signal, source:"syft"}')"
  echo "sbom-gate verdict: FAIL - syft failed to generate SBOM -> $REPORT" >&2
  exit 2
fi

details="$(jq -n --arg signal "$dependency_signal" '{dependency_signal:$signal, missing_tool:"syft", required_artifact:"walteur-kit/sbom.json or equivalent"}')"
write_report "SKIP" "dependency signal present but no persisted SBOM and syft is not installed" "$details"
echo "sbom-gate verdict: SKIP - dependency signal present, no SBOM proof tool -> $REPORT" >&2
exit 0
