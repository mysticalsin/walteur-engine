#!/usr/bin/env bash
# WALTEUR skill-frontmatter-gate — THIN SHIM (single source of truth).
#
# The ONE real implementation lives at  <repo>/walteur-kit/hooks/skill-frontmatter-gate.sh  and is what
# .claude/hooks/ship-gate.sh already runs (it resolves every gate as "$KIT/hooks/$name"). This
# file used to be a FORKED COPY that nothing invoked and no check compared against its twin, so
# it drifted silently. It is now a shim: there is exactly ONE implementation, and this entrypoint
# cannot diverge from it. --help, --selftest and every other argument are forwarded verbatim, so
# the help text, the report path and the selftest all come from the canonical.
#
# Delegation logic (repo resolution, arg forwarding, fail-closed-if-canonical-absent) lives once
# in .claude/hooks/_delegate.sh and is covered by `bash .claude/hooks/_delegate.sh --selftest`.
set -uo pipefail
_WD_ARG0="$0"
. "$(dirname "$0")/_delegate.sh"
_walteur_delegate_exec "$@"
