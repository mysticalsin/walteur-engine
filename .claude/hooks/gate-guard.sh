#!/usr/bin/env bash
# PLAN-before-build gate. Blocks the first Write/Edit if no approved PLAN.md exists.
# Override: WALTEUR_GATE=off. Honors the kill switch.
#
# v9.2 boundaries (WARNING-FIRST): also reads a `<boundaries>` DO-NOT-CHANGE protected-paths block from
# PLAN.md (see PLAN.template.additions.md, Block (c)) and checks the edited file's path against it.
#   - default  : a match -> a LOUD WARN on stderr, exit 0 (DOES NOT block — behavior-preserving).
#   - WALTEUR_BOUNDARIES=hard : a match -> exit 2 (HARD block) for high-stakes sessions.
#   - WALTEUR_BOUNDARIES=off  : skip the boundaries check entirely.
# Distinct from disjoint-file-ownership: this is a declarative no-touch list, not a work partition.
# The boundaries check is purely ADDITIVE — when no PLAN.md / no <boundaries> block / jq absent, it is a
# silent no-op and the gate behaves exactly as before.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "gate-guard - PLAN-before-build gate. Blocks the first Write/Edit if no approved PLAN.md exists."
  printf '%s\n' "usage: bash gate-guard.sh [--help|<PreToolUse run: tool JSON on stdin>]   (no --selftest: this hook has none)"
  printf '%s\n' "report: see hook header - fix recipes: walteur-kit/REMEDIATION.md (## gate-guard)"
  printf '%s\n' "bypass: WALTEUR_GATE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

# Argument guard. --help above advertised a --selftest this hook does not implement, and no case arm
# handled it, so `gate-guard.sh --selftest` fell through and ran as a LIVE PreToolUse gate — it
# printed "GATE: PLAN before build" and exited 2. An operator asking to verify the hook got a
# real gate block instead, indistinguishable from a genuine failure. Unsupported flags now say so.
case "${1:-}" in
  -*) printf '%s\n' "gate-guard: unrecognized option '$1' — this hook implements --help only and has no selftest." >&2
      printf '%s\n' "usage: bash gate-guard.sh [--help|<PreToolUse run: tool JSON on stdin>]" >&2
      exit 2 ;;
esac

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -f "$ROOT/walteur-kit/PAUSED" ] && { echo "WALTEUR PAUSED." >&2; exit 2; }
[ "${WALTEUR_GATE:-on}" = "off" ] && exit 0

# ── PLAN-before-build (unchanged) ─────────────────────────────────────────────
if [ ! -s "$ROOT/PLAN.md" ]; then
  echo "GATE: PLAN before build. Create PLAN.md (design + numbered tasks + Definition of Done) and get sign-off first. (bypass: WALTEUR_GATE=off)" >&2
  exit 2
fi

# ── boundaries (WARNING-FIRST; additive) ──────────────────────────────────────
# Read the tool payload (PreToolUse passes tool JSON on stdin). Safe when stdin is empty/absent.
if [ "${WALTEUR_BOUNDARIES:-hard}" != "off" ] && command -v jq >/dev/null 2>&1; then
  payload="$(cat 2>/dev/null || true)"
  path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)"
  if [ -n "$path" ]; then
    # Extract the protected globs from PLAN.md's `<boundaries>` section: bullets between the boundaries
    # heading and the next markdown heading. Strip the bullet marker, the inline-code backticks, and any
    # trailing " — reason" annotation. Skip the placeholder "<add ...>" line.
    globs="$(awk '
      BEGIN{insec=0}
      /^[[:space:]]*#{1,6}.*<?boundaries>?/ {            # boundaries heading (with or without <>)
        if (tolower($0) ~ /boundaries/) { insec=1; next }
      }
      insec && /^[[:space:]]*#{1,6}[[:space:]]/ { insec=0 }   # next heading ends the section
      insec {
        line=$0
        if (line !~ /^[[:space:]]*[-*+][[:space:]]/) next     # bullets only
        sub(/^[[:space:]]*[-*+][[:space:]]+/, "", line)       # strip bullet
        sub(/[[:space:]]*(—|--).*$/, "", line)                # strip " — reason"
        gsub(/`/, "", line)                                   # strip code backticks
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)         # trim
        if (line == "" || line ~ /^</) next                   # skip placeholder "<add ...>"
        print line
      }
    ' "$ROOT/PLAN.md" 2>/dev/null)"

    if [ -n "$globs" ]; then
      # Normalize the edited path to repo-relative for matching.
      rel="${path#"$ROOT"/}"
      matched=""
      # glob -> ERE: escape regex specials, expand {a,b}->（a|b), ?->[^/], **/ -> (.*/)?, ** -> .*,
      # * -> [^/]* . Match the full path; for a slash-free glob also try the basename.
      glob2ere() {
        printf '%s' "$1" | sed -E '
          s/[.]/\\./g; s/[+]/\\+/g; s/[(]/\\(/g; s/[)]/\\)/g;
          s/\{/(/g; s/\}/)/g; s/,/|/g;
          s/\?/[^\/]/g;
          s/\*\*\//\x02/g; s/\*\*/\x01/g; s/\*/[^\/]*/g;
          s/\x01/.*/g; s|\x02|(.*/)?|g;'
      }
      while IFS= read -r g; do
        [ -z "$g" ] && continue
        re="$(glob2ere "$g")"
        if printf '%s\n' "$rel" | grep -qE "^${re}$"; then matched="$g"; break; fi
        case "$g" in */*) : ;; *)
          if printf '%s\n' "$(basename "$rel")" | grep -qE "^${re}$"; then matched="$g"; break; fi ;;
        esac
      done <<EOF
$globs
EOF
      # The second half of the inertness the panel named: if PLAN.md carries NO <boundaries> block, this
      # control has nothing to enforce and previously said nothing at all — indistinguishable from a repo
      # that is fully protected. Announce it once so "no boundaries" is a visible state, not a silent one.
      if [ -z "$globs" ] && [ "${WALTEUR_BOUNDARIES:-hard}" != "off" ]; then
        echo "BOUNDARIES: no <boundaries> block found in PLAN.md — NO protected paths are being enforced. This control is inert until that list exists (this is a notice, not a block)." >&2
      fi
      if [ -n "$matched" ]; then
        # 2026-07-25 — default flipped warn -> hard on Tony's explicit authorization. Panel #12: "the
        # path-denylist / protected-paths control is inert twice over: no <boundaries> block exists to
        # enforce, and the default mode is WARN-then-exit-0 rather than block." A protected-path control
        # whose default is to allow the edit and print a line protects nothing. Bypass is unchanged and
        # still recorded: WALTEUR_BOUNDARIES=warn for the old behaviour, =off to disable entirely.
        if [ "${WALTEUR_BOUNDARIES:-hard}" = "hard" ]; then
          echo "BOUNDARIES (HARD): '$rel' matches a DO-NOT-CHANGE protected path in PLAN.md <boundaries> ('$matched'). Amend the <boundaries> list first (state why in Key Decisions). (bypass: WALTEUR_BOUNDARIES=off)" >&2
          exit 2
        fi
        echo "BOUNDARIES (WARN): '$rel' matches a DO-NOT-CHANGE protected path in PLAN.md <boundaries> ('$matched'). This edit is allowed (WARNING-FIRST). To block such edits: WALTEUR_BOUNDARIES=hard. To intentionally change it: amend the <boundaries> list + note why in Key Decisions." >&2
      fi
    fi
  fi
fi

exit 0
