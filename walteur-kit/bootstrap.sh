#!/usr/bin/env bash
# WALTEUR bootstrap — idempotent environment preparer for the pillar tools.
#
# It PREPARES, it does NOT gate: it NEVER exits non-zero. The gating is tool-readiness.sh (fail-closed,
# exit 2). Run this once to satisfy that gate; re-running is safe (already-present tools are skipped).
#
# Detects the platform package manager (macOS brew | Linux apt/dnf), installs the pillar tools that are
# MISSING (jq, gitleaks, and best-effort codeburn via npm), then prints a present / installed / failed
# table. A failed install is reported, never fatal — fix it by hand and re-run.
#
# Zero-dep (bash + command -v + the platform's own package manager). No jq dependency: bootstrap must run
# even when jq itself is the thing being installed.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
KIT="$ROOT/walteur-kit"

echo "WALTEUR bootstrap @ $ROOT" >&2

have() { command -v "$1" >/dev/null 2>&1; }

# ── detect platform / package manager ────────────────────────────────────────
OS="$(uname -s 2>/dev/null || echo unknown)"
PM=""           # the install command prefix (without the package name)
PM_NAME="none"
IS_WINDOWS=0
if [ "$OS" = "Darwin" ]; then
  if have brew; then PM="brew install"; PM_NAME="brew"
  else echo "  note — macOS detected but Homebrew is absent. Install brew: https://brew.sh, then re-run." >&2; fi
elif [ "$OS" = "Linux" ]; then
  if have apt-get; then
    PM_NAME="apt"
    if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then PM="apt-get install -y"; else PM="sudo apt-get install -y"; fi
  elif have dnf; then
    PM_NAME="dnf"
    if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then PM="dnf install -y"; else PM="sudo dnf install -y"; fi
  else echo "  note — Linux detected but neither apt-get nor dnf found. Install jq/gitleaks by hand, then re-run." >&2; fi
else
  case "$OS" in
    MINGW*|MSYS*|CYGWIN*)
      IS_WINDOWS=1; PM_NAME="winget (+ jq CRLF shim)"
      have winget || echo "  note — Windows detected but winget absent; install jq by hand: winget install jqlang.jq" >&2 ;;
    *) echo "  note — unrecognised platform '$OS'. Install the pillar tools by hand, then re-run." >&2 ;;
  esac
fi
echo "  platform: $OS | package manager: $PM_NAME" >&2

# ── result accumulators (plain strings — no jq dependency) ───────────────────
present_list=""
installed_list=""
failed_list=""

# ensure_tool <tool> <pkg-for-pm> <fallback-cmd-or-empty>
# Idempotent: present => recorded present, no action. Missing => try $PM, then the fallback installer.
ensure_tool() {
  local tool="$1" pkg="$2" fallback="${3:-}"
  if have "$tool"; then
    echo "  ok   — $tool already present (skip)." >&2
    present_list="$present_list $tool"
    return 0
  fi
  local done=1
  if [ -n "$PM" ]; then
    echo "  ..   — installing $tool via: $PM $pkg" >&2
    $PM "$pkg" >/dev/null 2>&1 && done=0 || done=1
  fi
  if [ "$done" -ne 0 ] && [ -n "$fallback" ]; then
    echo "  ..   — falling back: $fallback" >&2
    eval "$fallback" >/dev/null 2>&1 && done=0 || done=1
  fi
  if [ "$done" -eq 0 ] && have "$tool"; then
    echo "  +    — installed $tool." >&2
    installed_list="$installed_list $tool"
  else
    echo "  x    — could NOT install $tool (do it by hand, then re-run; this is not fatal)." >&2
    failed_list="$failed_list $tool"
  fi
}

# ── Windows jq + CRLF shim ───────────────────────────────────────────────────
# Windows jq.exe emits CRLF on stdout, which corrupts every gate `jq | while read` loop. Install
# jq via winget if missing, then write a CR-stripping shim on PATH (~/bin/jq) that finds the real
# jq.exe wherever winget/choco placed it — so the gates work on native Windows bash.
ensure_windows_jq() {
  if ! command -v jq.exe >/dev/null 2>&1 && ! ls "$HOME/AppData/Local/Microsoft/WinGet/Packages"/jqlang.jq_*/jq.exe >/dev/null 2>&1; then
    if have winget; then
      echo "  ..   — installing jq via winget" >&2
      winget install --id jqlang.jq -e --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity >/dev/null 2>&1 || true
    fi
  fi
  mkdir -p "$HOME/bin" 2>/dev/null || true
  cat > "$HOME/bin/jq" <<'SHIM'
#!/usr/bin/env bash
# WALTEUR jq shim — Windows jq.exe emits CRLF on stdout, breaking gate `jq | while read` loops.
# Strip CR, preserve jq's exit code. Finds the real jq.exe wherever winget/choco placed it.
for c in "$HOME/AppData/Local/Microsoft/WinGet/Packages"/jqlang.jq_*/jq.exe /c/ProgramData/chocolatey/bin/jq.exe "$(command -v jq.exe 2>/dev/null)"; do
  [ -n "$c" ] && [ -x "$c" ] && { "$c" "$@" | tr -d '\r'; exit "${PIPESTATUS[0]}"; }
done
echo "WALTEUR jq shim: no jq.exe found (run: winget install jqlang.jq)" >&2; exit 127
SHIM
  chmod +x "$HOME/bin/jq" 2>/dev/null || true
  if printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$HOME/bin"; then
    echo "  +    — CR-stripping jq shim at ~/bin/jq (on PATH)." >&2; present_list="$present_list jq(shim)"
  else
    echo "  !    — jq shim at ~/bin/jq but ~/bin is NOT on PATH. Add: export PATH=\"\$HOME/bin:\$PATH\"" >&2; present_list="$present_list jq(shim,PATH?)"
  fi
}

# ── the pillar tools ─────────────────────────────────────────────────────────
if [ "$IS_WINDOWS" = "1" ]; then ensure_windows_jq; else ensure_tool jq jq ""; fi
ensure_tool gitleaks gitleaks ""
# codeburn ships on npm; best-effort only (npm may be absent — that's a recorded failure, never fatal).
if have npm; then
  ensure_tool codeburn codeburn "npm i -g codeburn"
else
  if have codeburn; then
    echo "  ok   — codeburn already present (skip)." >&2; present_list="$present_list codeburn"
  else
    echo "  x    — codeburn skipped: npm not on PATH (install Node/npm, then: npm i -g codeburn)." >&2
    failed_list="$failed_list codeburn"
  fi
fi

# ── codex CLI (cross-model Integrator lane, SKILL §5.5b) — REPORT ONLY ──────
# bootstrap never installs or authenticates codex: install is a product decision (npm i -g @openai/codex)
# and login is interactive (codex login). integrator-audit-gate.sh carries the honest DEGRADED path when
# codex is down — this line just tells you NOW instead of at ship.
if have codex; then
  if codex login status </dev/null >/dev/null 2>&1; then
    echo "  ok   — codex CLI present + logged in (Integrator lane §5.5b ready)." >&2
    present_list="$present_list codex"
  else
    echo "  !    — codex CLI present but NOT logged in (run interactively: codex login). Integrator lane degraded until then." >&2
    present_list="$present_list codex(auth?)"
  fi
else
  echo "  x    — codex CLI absent (Integrator lane §5.5b needs it: npm i -g @openai/codex, then codex login). Report-only, never fatal." >&2
  failed_list="$failed_list codex(report-only)"
fi

# ── present / installed / failed table ───────────────────────────────────────
fmt() { local s="${1# }"; [ -n "$s" ] && printf '%s' "$s" || printf -- '-'; }
echo "  ----------------------------------------" >&2
printf '  present   : %s\n' "$(fmt "$present_list")"   >&2
printf '  installed : %s\n' "$(fmt "$installed_list")" >&2
printf '  failed    : %s\n' "$(fmt "$failed_list")"    >&2
echo "  ----------------------------------------" >&2
echo "  bootstrap done. Gate readiness with: bash walteur-kit/hooks/tool-readiness.sh" >&2

# Prepares, never gates — always succeed.
exit 0
