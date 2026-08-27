#!/usr/bin/env bash
# WALTEUR loop-workspace-gate - validates the shared loop workspace substrate.
#
# Contract:
#   - No WALTEUR control surface              => NOT_APPLICABLE, exit 0.
#   - WALTEUR_LOOP_WORKSPACE=off              => SKIP, exit 0.
#   - Initialized project missing workspace   => FAIL, exit 2.
#   - Workspace files with required anchors    => PASS, exit 0.
#
# Report:
#   walteur-kit/loop-workspace-report.json
set -uo pipefail

input_dir="${1:-}"
if [ -n "${WALTEUR_ROOT:-}" ] && [ -d "$WALTEUR_ROOT" ]; then
  ROOT="$(cd "$WALTEUR_ROOT" && pwd)"
elif [ -n "$input_dir" ] && [ -d "$input_dir" ]; then
  ROOT="$(cd "$input_dir" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

KIT="$ROOT/walteur-kit"
REPORT="$KIT/loop-workspace-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"

have() { command -v "$1" >/dev/null 2>&1; }

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_report() {
  verdict="$1"
  reason="$2"
  findings_json="${3:-[]}"
  if have jq; then
    jq -n \
      --arg v "$verdict" \
      --arg ts "$TS" \
      --arg r "$reason" \
      --argjson f "$findings_json" \
      '{verdict:$v, ts:$ts, gate:"loop-workspace-gate", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0
  fi
  printf '{"verdict":"%s","ts":"%s","gate":"loop-workspace-gate","reason":"%s"}\n' \
    "$(json_escape "$verdict")" "$(json_escape "$TS")" "$(json_escape "$reason")" > "$REPORT" 2>/dev/null || true
}

add_finding() {
  findings="$(printf '%s' "$findings" | jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]')"
  failures=$((failures+1))
}

require_file() {
  rel="$1"
  path="$ROOT/$rel"
  if [ ! -f "$path" ]; then
    add_finding "file.$rel" "$rel is required for loop workspace memory"
    return 1
  fi
  if [ ! -s "$path" ]; then
    add_finding "file.nonempty.$rel" "$rel must not be empty"
    return 1
  fi
  return 0
}

require_anchor() {
  rel="$1"
  pattern="$2"
  message="$3"
  path="$ROOT/$rel"
  grep -q -- "$pattern" "$path" 2>/dev/null || add_finding "anchor.$rel" "$message"
}

write_good_workspace() {
  root="$1"
  mkdir -p "$root/walteur-kit" "$root/signals" "$root/docs" "$root/domains"
  cat > "$root/LOG.md" <<'EOF'
# Work Log

## Entry Grammar

```text
## YYYY-MM-DD - Short title - #tag
What: Outcome first.
Refs: [artifact](path)
```
EOF
  cat > "$root/signals/README.md" <<'EOF'
# signals/ - Evidence

```yaml
---
kind: signal
frequency: 1
domain: []
status: open | triaged | actioned | closed
---
```

## Timeline
EOF
  cat > "$root/docs/README.md" <<'EOF'
# docs/ - Durable Knowledge

```yaml
---
kind: doc
status: draft | adopted | superseded
links: []
---
```

## Timeline
EOF
  cat > "$root/domains/README.md" <<'EOF'
# domains/ - Loops

```yaml
---
kind: domain
cadence: manual | daily | weekly | cron
---
```

## Backlog

## Timeline
EOF
  printf '{"schema_version":1}\n' > "$root/walteur-kit/build-contract.json"
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
    echo "loop-workspace-gate selftest SKIP - jq not installed."
    return 0
  fi

  echo "loop-workspace-gate selftest:"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/loop-workspace-gate.XXXXXX")" || return 1
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "no WALTEUR control surface -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/loop-workspace-gate.XXXXXX")" || return 1
  write_good_workspace "$tmp"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "complete workspace -> PASS" 0 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/loop-workspace-gate.XXXXXX")" || return 1
  write_good_workspace "$tmp"
  rm "$tmp/LOG.md"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing LOG.md -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/loop-workspace-gate.XXXXXX")" || return 1
  write_good_workspace "$tmp"
  perl -0pi -e 's/kind: signal/kind: note/' "$tmp/signals/README.md"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing signal schema anchor -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/loop-workspace-gate.XXXXXX")" || return 1
  write_good_workspace "$tmp"
  perl -0pi -e 's/## Backlog/## Queue/' "$tmp/domains/README.md"
  WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "missing domain backlog anchor -> FAIL" 2 "$?"
  rm -rf "$tmp"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/loop-workspace-gate.XXXXXX")" || return 1
  write_good_workspace "$tmp"
  WALTEUR_LOOP_WORKSPACE=off WALTEUR_ROOT="$tmp" bash "$0" >/dev/null 2>&1
  ck "env off -> SKIP" 0 "$?"
  rm -rf "$tmp"

  echo "loop-workspace-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

if [ "${WALTEUR_LOOP_WORKSPACE:-}" = "off" ]; then
  write_report "SKIP" "WALTEUR_LOOP_WORKSPACE=off" "[]"
  echo "loop-workspace-gate verdict: SKIP - WALTEUR_LOOP_WORKSPACE=off -> ${REPORT#"$ROOT"/}" >&2
  exit 0
fi

if ! have jq; then
  write_report "SKIP" "jq not installed" "[]"
  echo "loop-workspace-gate SKIP - jq not installed (recorded, not silent-green)." >&2
  exit 0
fi

if [ ! -e "$KIT/build-contract.json" ] && [ ! -e "$KIT/autopilot/STATE.json" ]; then
  write_report "NOT_APPLICABLE" "WALTEUR control surface absent" "[]"
  echo "loop-workspace-gate: no WALTEUR control surface found - gate not applicable." >&2
  exit 0
fi

findings='[]'
failures=0

require_file "LOG.md"
require_file "signals/README.md"
require_file "docs/README.md"
require_file "domains/README.md"

if [ "$failures" -eq 0 ]; then
  require_anchor "LOG.md" '^## Entry Grammar' "LOG.md must define the work-log entry grammar"
  require_anchor "LOG.md" '^Refs:' "LOG.md must require evidence references"
  require_anchor "signals/README.md" '^kind: signal' "signals/README.md must define kind: signal"
  require_anchor "signals/README.md" '^frequency:' "signals/README.md must define frequency"
  require_anchor "signals/README.md" '^domain: \[\]' "signals/README.md must keep domain as a list field"
  require_anchor "signals/README.md" '^## Timeline' "signals/README.md must define append-only Timeline"
  require_anchor "docs/README.md" '^kind: doc' "docs/README.md must define kind: doc"
  require_anchor "docs/README.md" '^links:' "docs/README.md must define links"
  require_anchor "docs/README.md" '^## Timeline' "docs/README.md must define append-only Timeline"
  require_anchor "domains/README.md" '^kind: domain' "domains/README.md must define kind: domain"
  require_anchor "domains/README.md" '^cadence:' "domains/README.md must define cadence"
  require_anchor "domains/README.md" '^## Backlog' "domains/README.md must define backlog"
  require_anchor "domains/README.md" '^## Timeline' "domains/README.md must define run Timeline"
fi

if [ "$failures" -gt 0 ]; then
  write_report "FAIL" "$failures loop workspace issue(s)" "$findings"
  echo "loop-workspace-gate verdict: FAIL - $failures issue(s) -> ${REPORT#"$ROOT"/}" >&2
  exit 2
fi

write_report "PASS" "loop workspace substrate present and checkable" "[]"
echo "loop-workspace-gate verdict: PASS - loop workspace substrate present -> ${REPORT#"$ROOT"/}" >&2
exit 0

