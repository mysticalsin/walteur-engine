#!/usr/bin/env bash
# WALTEUR tool acquisition proof runner.
# Reads walteur-kit/tool-acquisition.json and runs npm-backed proof commands
# from either checked-in workspaces or isolated temp copies with declared assets.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

mode="temp"
if [ "${1:-}" = "--install-workspaces" ]; then
  mode="install"
  shift
elif [ "${1:-}" = "--prove-in-place" ]; then
  mode="in-place"
  shift
elif [ "${1:-}" = "--check-only" ]; then
  mode="check"
  shift
elif [ "${1:-}" = "--selftest" ]; then
  mode="selftest"
  shift
elif [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
usage: tool-acquisition-proof.sh [--check-only|--selftest|--install-workspaces|--prove-in-place] [repo-root]

Modes:
  default              validate the manifest, copy each tool workspace to temp, npm ci, and npm run prove
  --check-only         validate manifest/workspace/package/lockfile/proof-asset contracts without npm
  --selftest           run runner-local poison fixtures against --check-only
  --install-workspaces run npm ci inside each checked-in acquisition workspace
  --prove-in-place     run npm run prove inside each checked-in acquisition workspace
EOF
  exit 0
fi

ROOT="${1:-$(pwd)}"
if [ "$mode" = "selftest" ] && [ "${1:-}" = "" ]; then
  ROOT="$SCRIPT_ROOT"
fi
KIT="$ROOT/walteur-kit"
MANIFEST="$KIT/tool-acquisition.json"

fail() {
  echo "FAIL - $*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "missing file: ${1#"$ROOT"/}"
}

copy_path() {
  src="$1"
  dst="$2"
  [ -e "$src" ] || fail "missing proof asset: ${src#"$ROOT"/}"
  mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
}

validate_manifest_shape() {
  manifest="$1"
  jq -e '
    def root_keys: ["schema_version","manifest_id","updated_at","policy","tools"];
    def tool_keys: ["id","purpose","local_binaries","preferred_local_binary","on_demand","lockfile","fallback_policy","safety_policy"];
    def on_demand_keys: ["runner","package","version","package_spec","binary","proof_args","proof"];
    def proof_keys: ["description","config_path","expected_tests","expected_passed"];
    def lockfile_keys: ["manager","workspace","package_json_path","lockfile_path","lockfile_version","package_path","resolved","integrity","install_command","local_binary_path","prove_script","prove_command","proof_assets"];
    def nonempty_string($key): (.[$key] | type == "string" and length > 0);
    def min_string($key; $min): (.[$key] | type == "string" and length >= $min);
    type == "object"
    and (([keys_unsorted[]] - root_keys) | length == 0)
    and (.schema_version == 1)
    and nonempty_string("manifest_id")
    and (.updated_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and min_string("policy"; 20)
    and (.tools | type == "array" and length >= 1)
    and (([.tools[].id] | length) == ([.tools[].id] | unique | length))
    and all(.tools[];
      type == "object"
      and (([keys_unsorted[]] - tool_keys) | length == 0)
      and (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]*$"))
      and min_string("purpose"; 10)
      and (.local_binaries | type == "array" and length >= 1 and all(.[]; type == "string" and test("^[A-Za-z0-9._@/+:-]+$")))
      and ((.local_binaries | length) == (.local_binaries | unique | length))
      and (.preferred_local_binary | type == "string" and test("^[A-Za-z0-9._@/+:-]+$"))
      and (.preferred_local_binary as $preferred | .local_binaries | index($preferred))
      and (.on_demand | type == "object")
      and ((.on_demand | [keys_unsorted[]] - on_demand_keys) | length == 0)
      and (.on_demand.runner == "npx")
      and (.on_demand.package | type == "string" and length > 0)
      and (.on_demand.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[A-Za-z0-9._-]+)?$"))
      and (.on_demand.package_spec == (.on_demand.package + "@" + .on_demand.version))
      and (.on_demand.binary | type == "string" and test("^[A-Za-z0-9._@/+:-]+$"))
      and (.on_demand.proof_args | type == "array" and length >= 1 and all(.[]; type == "string" and length > 0))
      and ((.on_demand.proof_args | length) == (.on_demand.proof_args | unique | length))
      and (.on_demand.proof | type == "object")
      and ((.on_demand.proof | [keys_unsorted[]] - proof_keys) | length == 0)
      and (.on_demand.proof.description | type == "string" and length >= 10)
      and (.on_demand.proof.config_path | type == "string" and length > 0)
      and (.on_demand.proof.expected_tests | type == "number" and . >= 1 and floor == .)
      and (.on_demand.proof.expected_passed | type == "number" and . >= 1 and floor == .)
      and (.on_demand.proof.expected_passed <= .on_demand.proof.expected_tests)
      and (.lockfile | type == "object")
      and ((.lockfile | [keys_unsorted[]] - lockfile_keys) | length == 0)
      and (.lockfile.manager == "npm")
      and (.lockfile.workspace | type == "string" and test("^walteur-kit/tool-acquisition/[a-z0-9][a-z0-9._-]*$"))
      and (.lockfile.package_json_path == (.lockfile.workspace + "/package.json"))
      and (.lockfile.lockfile_path == (.lockfile.workspace + "/package-lock.json"))
      and (.lockfile.lockfile_version == 3)
      and (.lockfile.package_path == ("node_modules/" + .on_demand.package))
      and (.lockfile.resolved | type == "string" and test("^https://registry\\.npmjs\\.org/.+\\.tgz$"))
      and (.lockfile.integrity | type == "string" and test("^sha512-[A-Za-z0-9+/=]+$"))
      and (.lockfile.install_command == "npm ci --prefer-offline --no-audit --fund=false")
      and (.lockfile.local_binary_path == (.lockfile.workspace + "/node_modules/.bin/" + .on_demand.binary))
      and (.lockfile.prove_script | type == "string" and length > 0)
      and (.lockfile.prove_command == "npm run prove")
      and (.lockfile.proof_assets | type == "array" and length >= 1 and all(.[]; type == "string" and test("^walteur-kit/[A-Za-z0-9._@/+:-]+$")))
      and ((.lockfile.proof_assets | length) == (.lockfile.proof_assets | unique | length))
      and min_string("fallback_policy"; 20)
      and min_string("safety_policy"; 20)
    )
  ' "$manifest" >/dev/null
}

copy_selftest_fixture() {
  source_root="$1"
  fixture_root="$2"
  source_manifest="$source_root/walteur-kit/tool-acquisition.json"
  mkdir -p "$fixture_root/walteur-kit"
  cp "$source_manifest" "$fixture_root/walteur-kit/tool-acquisition.json"
  while IFS=$'\t' read -r package_json_rel lockfile_rel; do
    mkdir -p "$fixture_root/$(dirname "$package_json_rel")"
    cp "$source_root/$package_json_rel" "$fixture_root/$package_json_rel"
    cp "$source_root/$lockfile_rel" "$fixture_root/$lockfile_rel"
  done < <(jq -r '.tools[] | [.lockfile.package_json_path, .lockfile.lockfile_path] | @tsv' "$source_manifest")
  while IFS= read -r proof_asset; do
    [ -n "$proof_asset" ] || continue
    mkdir -p "$fixture_root/$(dirname "$proof_asset")"
    cp -R "$source_root/$proof_asset" "$fixture_root/$proof_asset"
  done < <(jq -r '.tools[].lockfile.proof_assets[]' "$source_manifest" | sort -u)
}

run_selftest() {
  self_root="$1"
  self_tmp="$(mktemp -d "${TMPDIR:-/tmp}/walteur-tool-acquisition-proof-selftest.XXXXXX")" || fail "mktemp failed"
  trap 'rm -rf "$self_tmp"' EXIT INT TERM
  self_pass=0
  self_fail=0

  self_accept() {
    label="$1"
    fixture="$2"
    if bash "$SCRIPT_PATH" --check-only "$fixture" >/dev/null 2>"$fixture.err"; then
      echo "ok - $label"
      self_pass=$((self_pass+1))
    else
      echo "FAIL - $label" >&2
      cat "$fixture.err" >&2
      self_fail=$((self_fail+1))
    fi
  }

  self_reject() {
    label="$1"
    fixture="$2"
    if bash "$SCRIPT_PATH" --check-only "$fixture" >/dev/null 2>"$fixture.err"; then
      echo "FAIL - $label accepted poisoned fixture" >&2
      self_fail=$((self_fail+1))
    else
      echo "ok - $label"
      self_pass=$((self_pass+1))
    fi
  }

  good="$self_tmp/good"
  copy_selftest_fixture "$self_root" "$good"
  self_accept "runner check-only accepts valid acquisition fixture" "$good"
  first_package="$(jq -r '.tools[0].on_demand.package' "$good/walteur-kit/tool-acquisition.json")"
  first_package_json_path="$(jq -r '.tools[0].lockfile.package_json_path' "$good/walteur-kit/tool-acquisition.json")"
  first_lockfile_path="$(jq -r '.tools[0].lockfile.lockfile_path' "$good/walteur-kit/tool-acquisition.json")"
  first_package_path="$(jq -r '.tools[0].lockfile.package_path' "$good/walteur-kit/tool-acquisition.json")"

  missing_asset="$self_tmp/missing-proof-asset"
  copy_selftest_fixture "$self_root" "$missing_asset"
  jq '.tools[0].lockfile.proof_assets += ["walteur-kit/missing-proof-asset"]' \
    "$missing_asset/walteur-kit/tool-acquisition.json" > "$missing_asset/tmp.json" \
    && mv "$missing_asset/tmp.json" "$missing_asset/walteur-kit/tool-acquisition.json"
  self_reject "runner check-only rejects missing proof asset" "$missing_asset"

  package_drift="$self_tmp/package-drift"
  copy_selftest_fixture "$self_root" "$package_drift"
  jq --arg package "$first_package" '.dependencies[$package] = "0.0.0"' \
    "$package_drift/$first_package_json_path" > "$package_drift/tmp.json" \
    && mv "$package_drift/tmp.json" "$package_drift/$first_package_json_path"
  self_reject "runner check-only rejects package dependency drift" "$package_drift"

  prove_drift="$self_tmp/prove-script-drift"
  copy_selftest_fixture "$self_root" "$prove_drift"
  jq '.scripts.prove = "ast-grep --version"' \
    "$prove_drift/$first_package_json_path" > "$prove_drift/tmp.json" \
    && mv "$prove_drift/tmp.json" "$prove_drift/$first_package_json_path"
  self_reject "runner check-only rejects prove-script drift" "$prove_drift"

  binary_path_drift="$self_tmp/binary-path-drift"
  copy_selftest_fixture "$self_root" "$binary_path_drift"
  jq '.tools[0].lockfile.local_binary_path = (.tools[0].lockfile.workspace + "/node_modules/.bin/walteur-poisoned-binary")' \
    "$binary_path_drift/walteur-kit/tool-acquisition.json" > "$binary_path_drift/tmp.json" \
    && mv "$binary_path_drift/tmp.json" "$binary_path_drift/walteur-kit/tool-acquisition.json"
  self_reject "runner check-only rejects manifest binary-path drift" "$binary_path_drift"

  install_drift="$self_tmp/install-command-drift"
  copy_selftest_fixture "$self_root" "$install_drift"
  jq '.tools[0].lockfile.install_command = "npm install"' \
    "$install_drift/walteur-kit/tool-acquisition.json" > "$install_drift/tmp.json" \
    && mv "$install_drift/tmp.json" "$install_drift/walteur-kit/tool-acquisition.json"
  self_reject "runner check-only rejects install-command drift" "$install_drift"

  lockfile_drift="$self_tmp/lockfile-integrity-drift"
  copy_selftest_fixture "$self_root" "$lockfile_drift"
  jq --arg pkg "$first_package_path" '.packages[$pkg].integrity = "sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' \
    "$lockfile_drift/$first_lockfile_path" > "$lockfile_drift/tmp.json" \
    && mv "$lockfile_drift/tmp.json" "$lockfile_drift/$first_lockfile_path"
  self_reject "runner check-only rejects package-lock integrity drift" "$lockfile_drift"

  duplicate_tool="$self_tmp/duplicate-tool-id"
  copy_selftest_fixture "$self_root" "$duplicate_tool"
  jq '.tools += [.tools[0]]' \
    "$duplicate_tool/walteur-kit/tool-acquisition.json" > "$duplicate_tool/tmp.json" \
    && mv "$duplicate_tool/tmp.json" "$duplicate_tool/walteur-kit/tool-acquisition.json"
  self_reject "runner check-only rejects duplicate tool id" "$duplicate_tool"

  duplicate_local_binary="$self_tmp/duplicate-local-binary"
  copy_selftest_fixture "$self_root" "$duplicate_local_binary"
  jq '.tools[0].local_binaries += [.tools[0].local_binaries[0]]' \
    "$duplicate_local_binary/walteur-kit/tool-acquisition.json" > "$duplicate_local_binary/tmp.json" \
    && mv "$duplicate_local_binary/tmp.json" "$duplicate_local_binary/walteur-kit/tool-acquisition.json"
  self_reject "runner check-only rejects duplicate local binary" "$duplicate_local_binary"

  duplicate_proof_arg="$self_tmp/duplicate-proof-arg"
  copy_selftest_fixture "$self_root" "$duplicate_proof_arg"
  jq '.tools[0].on_demand.proof_args += [.tools[0].on_demand.proof_args[0]]' \
    "$duplicate_proof_arg/walteur-kit/tool-acquisition.json" > "$duplicate_proof_arg/tmp.json" \
    && mv "$duplicate_proof_arg/tmp.json" "$duplicate_proof_arg/walteur-kit/tool-acquisition.json"
  self_reject "runner check-only rejects duplicate proof arg" "$duplicate_proof_arg"

  duplicate_asset="$self_tmp/duplicate-proof-asset"
  copy_selftest_fixture "$self_root" "$duplicate_asset"
  jq '.tools[0].lockfile.proof_assets += [.tools[0].lockfile.proof_assets[0]]' \
    "$duplicate_asset/walteur-kit/tool-acquisition.json" > "$duplicate_asset/tmp.json" \
    && mv "$duplicate_asset/tmp.json" "$duplicate_asset/walteur-kit/tool-acquisition.json"
  self_reject "runner check-only rejects duplicate proof asset" "$duplicate_asset"

  unknown_manifest_key="$self_tmp/unknown-manifest-key"
  copy_selftest_fixture "$self_root" "$unknown_manifest_key"
  jq '.unexpected_schema_key = true' \
    "$unknown_manifest_key/walteur-kit/tool-acquisition.json" > "$unknown_manifest_key/tmp.json" \
    && mv "$unknown_manifest_key/tmp.json" "$unknown_manifest_key/walteur-kit/tool-acquisition.json"
  self_reject "runner check-only rejects unknown manifest key" "$unknown_manifest_key"

  unknown_tool_key="$self_tmp/unknown-tool-key"
  copy_selftest_fixture "$self_root" "$unknown_tool_key"
  jq '.tools[0].unexpected_tool_key = true' \
    "$unknown_tool_key/walteur-kit/tool-acquisition.json" > "$unknown_tool_key/tmp.json" \
    && mv "$unknown_tool_key/tmp.json" "$unknown_tool_key/walteur-kit/tool-acquisition.json"
  self_reject "runner check-only rejects unknown tool key" "$unknown_tool_key"

  unknown_on_demand_key="$self_tmp/unknown-on-demand-key"
  copy_selftest_fixture "$self_root" "$unknown_on_demand_key"
  jq '.tools[0].on_demand.unexpected_on_demand_key = true' \
    "$unknown_on_demand_key/walteur-kit/tool-acquisition.json" > "$unknown_on_demand_key/tmp.json" \
    && mv "$unknown_on_demand_key/tmp.json" "$unknown_on_demand_key/walteur-kit/tool-acquisition.json"
  self_reject "runner check-only rejects unknown on-demand key" "$unknown_on_demand_key"

  unknown_proof_key="$self_tmp/unknown-proof-key"
  copy_selftest_fixture "$self_root" "$unknown_proof_key"
  jq '.tools[0].on_demand.proof.unexpected_proof_key = true' \
    "$unknown_proof_key/walteur-kit/tool-acquisition.json" > "$unknown_proof_key/tmp.json" \
    && mv "$unknown_proof_key/tmp.json" "$unknown_proof_key/walteur-kit/tool-acquisition.json"
  self_reject "runner check-only rejects unknown proof key" "$unknown_proof_key"

  unknown_lockfile_key="$self_tmp/unknown-lockfile-key"
  copy_selftest_fixture "$self_root" "$unknown_lockfile_key"
  jq '.tools[0].lockfile.unexpected_lockfile_key = true' \
    "$unknown_lockfile_key/walteur-kit/tool-acquisition.json" > "$unknown_lockfile_key/tmp.json" \
    && mv "$unknown_lockfile_key/tmp.json" "$unknown_lockfile_key/walteur-kit/tool-acquisition.json"
  self_reject "runner check-only rejects unknown lockfile key" "$unknown_lockfile_key"

  if [ "$self_fail" -ne 0 ]; then
    echo "tool-acquisition-proof selftest: $self_pass passed, $self_fail failed" >&2
    return 1
  fi
  echo "tool-acquisition-proof selftest: $self_pass passed, 0 failed"
  return 0
}

command -v jq >/dev/null 2>&1 || fail "jq unavailable"
require_file "$MANIFEST"
if ! validate_manifest_shape "$MANIFEST"; then
  fail "tool acquisition manifest shape invalid"
fi

if [ "$mode" = "selftest" ]; then
  run_selftest "$ROOT"
  exit $?
fi

if [ "$mode" != "check" ]; then
  command -v npm >/dev/null 2>&1 || fail "npm unavailable"
fi

tool_ids="$(jq -r '.tools[].id' "$MANIFEST")" || fail "cannot read tool acquisition manifest"
[ -n "$tool_ids" ] || fail "no acquisition tools declared"

tmp_roots=""
cleanup() {
  for dir in $tmp_roots; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT INT TERM

for tool_id in $tool_ids; do
  manager="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.manager' "$MANIFEST")"
  workspace="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.workspace' "$MANIFEST")"
  package_json_path="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.package_json_path' "$MANIFEST")"
  lockfile_path="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.lockfile_path' "$MANIFEST")"
  lockfile_version="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.lockfile_version' "$MANIFEST")"
  package_path="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.package_path' "$MANIFEST")"
  resolved="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.resolved' "$MANIFEST")"
  integrity="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.integrity' "$MANIFEST")"
  local_binary_path="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.local_binary_path' "$MANIFEST")"
  prove_script="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.prove_script' "$MANIFEST")"
  package_name="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .on_demand.package' "$MANIFEST")"
  package_version="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .on_demand.version' "$MANIFEST")"
  package_spec="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .on_demand.package_spec' "$MANIFEST")"
  binary="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .on_demand.binary' "$MANIFEST")"
  config_path="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .on_demand.proof.config_path' "$MANIFEST")"
  install_command="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.install_command' "$MANIFEST")"
  prove_command="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.prove_command' "$MANIFEST")"
  expected_tests="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .on_demand.proof.expected_tests' "$MANIFEST")"
  expected_passed="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .on_demand.proof.expected_passed' "$MANIFEST")"
  proof_asset_count="$(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | (.lockfile.proof_assets // [] | length)' "$MANIFEST")"

  [ "$manager" = "npm" ] || fail "$tool_id manager is not npm"
  [ "$package_spec" = "$package_name@$package_version" ] || fail "$tool_id package_spec drift"
  [ "$package_json_path" = "$workspace/package.json" ] || fail "$tool_id package_json_path drift"
  [ "$lockfile_path" = "$workspace/package-lock.json" ] || fail "$tool_id lockfile_path drift"
  [ "$local_binary_path" = "$workspace/node_modules/.bin/$binary" ] || fail "$tool_id local binary path drift"
  [ "$package_path" = "node_modules/$package_name" ] || fail "$tool_id package path drift"
  [ "$expected_passed" -le "$expected_tests" ] || fail "$tool_id proof count drift"
  [ "$install_command" = "npm ci --prefer-offline --no-audit --fund=false" ] || fail "$tool_id install command drift"
  [ "$prove_command" = "npm run prove" ] || fail "$tool_id prove command drift"
  [ -n "$prove_script" ] || fail "$tool_id prove script missing"
  [ "$proof_asset_count" -ge 1 ] || fail "$tool_id proof assets missing"
  require_file "$ROOT/$package_json_path"
  require_file "$ROOT/$lockfile_path"
  require_file "$ROOT/$config_path"
  if ! jq -e --arg package "$package_name" --arg version "$package_version" --arg prove_script "$prove_script" '
    .private == true
    and .scripts.prove == $prove_script
    and .dependencies[$package] == $version
  ' "$ROOT/$package_json_path" >/dev/null; then
    fail "$tool_id package.json does not match manifest contract"
  fi
  if ! jq -e --arg package "$package_name" --arg version "$package_version" --argjson lockver "$lockfile_version" --arg pkg "$package_path" --arg resolved "$resolved" --arg integrity "$integrity" --arg binary "$binary" '
    .lockfileVersion == $lockver
    and .packages[""].dependencies[$package] == $version
    and .packages[$pkg].version == $version
    and .packages[$pkg].resolved == $resolved
    and .packages[$pkg].integrity == $integrity
    and (.packages[$pkg].bin[$binary] | type == "string" and length > 0)
  ' "$ROOT/$lockfile_path" >/dev/null; then
    fail "$tool_id package-lock.json does not match manifest contract"
  fi
  while IFS= read -r asset; do
    [ -n "$asset" ] || continue
    case "$asset" in
      walteur-kit/*) ;;
      *) fail "$tool_id proof asset outside walteur-kit: $asset" ;;
    esac
    [ -e "$ROOT/$asset" ] || fail "$tool_id missing proof asset: $asset"
  done < <(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.proof_assets[]' "$MANIFEST")

  if [ "$mode" = "check" ]; then
    echo "ok - checked $tool_id $package_spec"
    continue
  fi

  if [ "$mode" = "install" ]; then
    (cd "$ROOT/$workspace" && npm ci --prefer-offline --no-audit --fund=false) || fail "$tool_id npm ci failed"
    echo "ok - installed $tool_id $package_spec"
    continue
  fi

  if [ "$mode" = "in-place" ]; then
    (cd "$ROOT/$workspace" && npm run prove) || fail "$tool_id prove command failed"
    echo "ok - proved $tool_id $package_spec ($expected_passed/$expected_tests)"
    continue
  fi

  proof_root="$(mktemp -d "${TMPDIR:-/tmp}/walteur-tool-acquisition-${tool_id}.XXXXXX")" || fail "mktemp failed"
  tmp_roots="$tmp_roots $proof_root"
  mkdir -p "$proof_root/$(dirname "$workspace")"
  cp -R "$ROOT/$workspace" "$proof_root/$workspace"
  rm -rf "$proof_root/$workspace/node_modules"

  while IFS= read -r asset; do
    [ -n "$asset" ] || continue
    case "$asset" in
      walteur-kit/*) ;;
      *) fail "$tool_id proof asset outside walteur-kit: $asset" ;;
    esac
    copy_path "$ROOT/$asset" "$proof_root/$asset"
  done < <(jq -r --arg id "$tool_id" '.tools[] | select(.id == $id) | .lockfile.proof_assets[]' "$MANIFEST")

  (
    cd "$proof_root/$workspace" \
      && npm ci --prefer-offline --no-audit --fund=false \
      && npm run prove
  ) || fail "$tool_id temp prove command failed"
  echo "ok - proved $tool_id $package_spec from temp workspace ($expected_passed/$expected_tests)"
done
