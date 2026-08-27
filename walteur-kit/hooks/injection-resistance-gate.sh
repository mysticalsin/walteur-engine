#!/usr/bin/env bash
# WALTEUR injection-resistance-gate - an EXECUTED adversarial probe for any project that
# processes untrusted input. Not a posture-claim: it actually RUNS a declared target against a
# hostile corpus and asserts the target survives (bounded termination, no signal-crash, no
# secret/canary leak, no traversal-content leak). Closes the panel-repeated gap "security is a
# source-read, there is no executed injection eval".
#
# APPLICABILITY:
#   A project opts in by declaring walteur-kit/injection-probes.json. Absent -> NOT_APPLICABLE (exit 0):
#   the gate cannot probe what is not declared, and honestly says so.
#
# HARD CHECK (when the manifest exists):
#   Manifest shape: {target:{cmd:[..],cwd?}, canary:str, timeout_ms:int>0, cases:[{name,...}>=1]}.
#   For each case the gate builds the (optionally generated) hostile input, EXECUTES the target under
#   a hard per-case timeout (portable perl alarm wrapper), and FAILs the build if ANY case:
#     - times out (exit 124)  -> the input hung the target (DoS)               => FAIL
#     - dies by signal (exit >=128, e.g. 139 SIGSEGV) -> crash                 => FAIL
#     - exits above the case max_exit (unexpected non-contract exit)           => FAIL
#     - emits the canary (a secret exported into the target env) in its output => FAIL (leak)
#     - emits any case must_not_contain[] marker (e.g. /etc/passwd content)    => FAIL (traversal leak)
#   All cases clean -> PASS with probe_executed:true. A manifest that runs zero cases is NOT proof.
#
# STRICT (ship-time): ship-gate exports WALTEUR_TOOLGATE_STRICT=1. Under STRICT, a manifest present but
# unrunnable (perl/jq missing, target unresolved) fail-closes (exit 2) instead of loud-SKIP. A per-gate
# WALTEUR_INJECTION=off bypass is checked BEFORE strict (explicit human override still wins, recorded).
#
# Report: walteur-kit/injection-resistance-report.json. Bypass: WALTEUR_INJECTION=off. Pause: walteur-kit/PAUSED.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "injection-resistance-gate - EXECUTED adversarial probe for untrusted-input projects."
  printf '%s\n' "usage: bash injection-resistance-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "manifest: walteur-kit/injection-probes.json (absent -> NOT_APPLICABLE)"
  printf '%s\n' "report: walteur-kit/injection-resistance-report.json - fix recipes: walteur-kit/REMEDIATION.md (## injection-resistance-gate)"
  printf '%s\n' "bypass: WALTEUR_INJECTION=off (recorded, not free); strict-at-ship via WALTEUR_TOOLGATE_STRICT=1"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
KIT="$ROOT/walteur-kit"
MANIFEST="$KIT/injection-probes.json"
REPORT="$KIT/injection-resistance-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STRICT="${WALTEUR_TOOLGATE_STRICT:-0}"
mkdir -p "$KIT"

write_report() { # $1=verdict $2=reason $3=extra-json(default {})
  local v="$1" reason="$2" extra="${3-}"
  [ -n "$extra" ] || extra='{}'
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg v "$v" --arg ts "$TS" --arg reason "$reason" --argjson extra "$extra" \
      '{verdict:$v, ts:$ts, gate:"injection-resistance-gate", reason:$reason} + $extra' > "$REPORT" 2>/dev/null \
      || printf '{"verdict":"%s","ts":"%s","gate":"injection-resistance-gate","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
  else
    printf '{"verdict":"%s","ts":"%s","gate":"injection-resistance-gate","reason":"%s"}\n' "$v" "$TS" "$reason" > "$REPORT"
  fi
}

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_INJECTION:-on}" = "off" ] && { write_report "SKIP" "WALTEUR_INJECTION=off"; echo "injection-resistance-gate: bypassed (WALTEUR_INJECTION=off)." >&2; exit 0; }

# ---- portable timeout: run "$@" but kill it after $1 seconds. Exit 124 on timeout, 128+sig on
# child signal-death, else the child's real exit code. Requires perl (fork/alarm) -- POSIX-portable.
run_timeout() { # $1=timeout_secs  $2..=argv
  local secs="$1"; shift
  perl -e '
    my $t = shift @ARGV;
    my $pid = fork();
    die "fork failed\n" unless defined $pid;
    if ($pid == 0) { exec @ARGV or exit 127; }
    my $timed_out = 0;
    $SIG{ALRM} = sub { $timed_out = 1; kill "KILL", $pid; };
    alarm $t;
    waitpid($pid, 0);
    my $st = $?;
    alarm 0;
    if ($timed_out) { exit 124; }
    if ($st & 127) { exit 128 + ($st & 127); }
    exit($st >> 8);
  ' "$secs" "$@"
}

# A native Windows jq.exe writes stdout in TEXT mode, appending a CR to every line; a POSIX jq does not.
# DETECT which one we have, once -- never strip unconditionally. An unconditional strip eats a payload's
# OWN trailing CR under POSIX jq, silently disarming the CR-terminated header-injection / response-splitting
# cases this gate exists to probe. `jq -r` on a 1-char string yields "x\n" (2 bytes) or "x\r\n" (3).
JQ_ADDS_CR=0
[ "$(printf '{"a":"x"}' | jq -r '.a' | wc -c | tr -d ' ')" = "3" ] && JQ_ADDS_CR=1

# ---- the executed probe: runs every manifest case against the target, returns 0 if all clean.
# Sets globals: CASES_RUN, CASES_PASS, FAILS_JSON (a JSON array string of failure objects).
run_probe() {
  local cwd cmd_json canary timeout_ms tsecs
  cwd="$(jq -r '.target.cwd // "."' "$MANIFEST")"
  canary="$(jq -r '.canary // ""' "$MANIFEST")"
  timeout_ms="$(jq -r '.timeout_ms // 8000' "$MANIFEST")"
  tsecs=$(( (timeout_ms + 999) / 1000 )); [ "$tsecs" -ge 1 ] || tsecs=1
  local target_dir="$ROOT/$cwd"
  [ -d "$target_dir" ] || { echo "injection-resistance-gate: target.cwd not found: $cwd" >&2; return 3; }

  # target.cmd is an array of argv tokens
  local -a base_cmd=()
  # NOTE: a native Windows jq.exe writes stdout in text mode (CRLF). `read -r` strips only the \n,
  # so every token would keep a trailing \r -- corrupting argv and silently voiding marker matches.
  # Strip into the variable FIRST: bash does not apply $'..' quoting inside an array-append pattern.
  while IFS= read -r tok; do if [ "$JQ_ADDS_CR" = "1" ]; then tok="${tok%$'\r'}"; fi; base_cmd+=("$tok"); done < <(jq -r '.target.cmd[]?' "$MANIFEST")
  [ "${#base_cmd[@]}" -ge 1 ] || { echo "injection-resistance-gate: target.cmd is empty" >&2; return 3; }

  local n; n="$(jq '.cases | length' "$MANIFEST")"
  CASES_RUN=0; CASES_PASS=0; FAILS_JSON="[]"
  local i
  for (( i=0; i<n; i++ )); do
    local name inp gen_unit gen_times gen_prefix gen_suffix max_exit append_input
    name="$(jq -r ".cases[$i].name // \"case-$i\"" "$MANIFEST")"
    inp="$(jq -r ".cases[$i].input // empty" "$MANIFEST")"
    gen_unit="$(jq -r ".cases[$i].gen.unit // empty" "$MANIFEST")"
    gen_times="$(jq -r ".cases[$i].gen.times // empty" "$MANIFEST")"
    gen_prefix="$(jq -r ".cases[$i].gen.prefix // empty" "$MANIFEST")"
    gen_suffix="$(jq -r ".cases[$i].gen.suffix // empty" "$MANIFEST")"
    max_exit="$(jq -r ".cases[$i].max_exit // 2" "$MANIFEST")"

    # extra argv for this case
    local -a xargv=()
    while IFS= read -r tok; do if [ "$JQ_ADDS_CR" = "1" ]; then tok="${tok%$'\r'}"; fi; xargv+=("$tok"); done < <(jq -r ".cases[$i].argv[]?" "$MANIFEST")

    # build input file if literal or generated input is declared
    local infile="" have_input=0
    if [ -n "$inp" ]; then
      infile="$(mktemp "${TMPDIR:-/tmp}/inj-in.XXXXXX")" || return 3
      printf '%s' "$inp" > "$infile"; have_input=1
    elif [ -n "$gen_unit" ] && [ -n "$gen_times" ]; then
      infile="$(mktemp "${TMPDIR:-/tmp}/inj-in.XXXXXX")" || return 3
      { [ -n "$gen_prefix" ] && printf '%s' "$gen_prefix"
        perl -e 'print $ARGV[0] x $ARGV[1]' "$gen_unit" "$gen_times"
        [ -n "$gen_suffix" ] && printf '%s' "$gen_suffix"; } > "$infile"
      have_input=1
    fi
    append_input="$(jq -r ".cases[$i].append_input_file // (if (.cases[$i].input // .cases[$i].gen) then true else false end)" "$MANIFEST")"

    # assemble argv: target.cmd + case.argv + (input file if present and append_input)
    local -a argv=("${base_cmd[@]}")
    [ "${#xargv[@]}" -gt 0 ] && argv+=("${xargv[@]}")
    [ "$have_input" = "1" ] && [ "$append_input" = "true" ] && argv+=("$infile")

    # execute under timeout, with the canary planted in the environment (a target that leaks env fails)
    local out ex
    out="$( cd "$target_dir" && INJECTION_CANARY="$canary" run_timeout "$tsecs" "${argv[@]}" 2>&1 )"
    ex=$?
    CASES_RUN=$((CASES_RUN+1))

    # gather must_not_contain markers (+ the canary always)
    local -a markers=()
    [ -n "$canary" ] && markers+=("$canary")
    while IFS= read -r m; do if [ "$JQ_ADDS_CR" = "1" ]; then m="${m%$'\r'}"; fi; [ -n "$m" ] && markers+=("$m"); done < <(jq -r ".cases[$i].must_not_contain[]?" "$MANIFEST")

    local why=""
    if [ "$ex" -eq 124 ]; then why="timed out (>${timeout_ms}ms) - input hung the target (DoS)"
    elif [ "$ex" -ge 128 ]; then why="died by signal (exit $ex) - crash under hostile input"
    elif [ "$ex" -gt "$max_exit" ]; then why="exit $ex exceeds max_exit $max_exit"
    else
      local mk
      for mk in "${markers[@]}"; do
        if printf '%s' "$out" | grep -Fq -- "$mk"; then
          why="leaked forbidden marker in output: $mk"; break
        fi
      done
    fi

    if [ -z "$why" ]; then
      CASES_PASS=$((CASES_PASS+1))
    else
      echo "injection-resistance-gate: FAIL case '$name' -> $why" >&2
      FAILS_JSON="$(printf '%s' "$FAILS_JSON" | jq --arg n "$name" --arg w "$why" --argjson ex "$ex" '. + [{name:$n, why:$w, exit:$ex}]')"
    fi
    [ -n "$infile" ] && rm -f "$infile"
  done
  [ "$CASES_PASS" -eq "$CASES_RUN" ] && [ "$CASES_RUN" -ge 1 ]
}

# ===================== SELFTEST =====================
selftest() {
  local pass=0 fail=0 tmp
  local SELF_PATH; SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  ck() { local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "  ok   - $name (rc=$got)"; pass=$((pass+1))
    else echo "  FAIL - $name (want $want got $got)"; fail=$((fail+1)); fi; }

  # fixture targets: a SAFE echo, a LEAKY canary-printer, a HANG, a CRASH (SIGSEGV via kill)
  make_targets() { local d="$1"; mkdir -p "$d"
    printf '%s\n' '#!/usr/bin/env bash' 'cat "$1" >/dev/null 2>&1 || true' 'echo "processed ok"; exit 0' > "$d/safe.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "here is the secret: $INJECTION_CANARY"; exit 0' > "$d/leak.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'while true; do :; done' > "$d/hang.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'kill -SEGV $$' > "$d/crash.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'cat /etc/hostname 2>/dev/null; echo "root:x:0:0 leaked"; exit 0' > "$d/traversal.sh"
    # leaks ONLY on a byte-exact argv match -- turns "was the payload delivered verbatim?" into a
    # leak the gate can already detect, so argv corruption (e.g. a stray CR) cannot pass silently.
    printf '%s\n' '#!/usr/bin/env bash' '[ "$1" = "../../../../etc/passwd" ] && echo "root:x:0:0 leaked"' 'exit 0' > "$d/argvexact.sh"
    chmod +x "$d"/*.sh
  }
  mk_manifest() { # $1=dir $2=target-script $3=extra-case-json(default deep-nest survive)
    local d="$1" tgt="$2" extra="${3:-}"
    local cases='[{"name":"deep-nest","gen":{"unit":"[","times":2000},"max_exit":2}]'
    [ -n "$extra" ] && cases="$extra"
    cat > "$d/walteur-kit/injection-probes.json" <<JSON
{ "schema_version":1,
  "target":{"cmd":["bash","$tgt"],"cwd":"."},
  "canary":"wlt-canary-SELFTEST-do-not-emit",
  "timeout_ms":3000,
  "cases":$cases }
JSON
  }

  echo "injection-resistance-gate selftest:"

  # 1. no manifest -> NOT_APPLICABLE (exit 0)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/inj-self.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "no manifest -> NOT_APPLICABLE" 0 "$?"
  rm -rf "$tmp"

  # 2. invalid manifest JSON -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/inj-self.XXXXXX")" || return 1
  mkdir -p "$tmp/walteur-kit"; printf '{ bad json' > "$tmp/walteur-kit/injection-probes.json"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "invalid manifest -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 3. manifest with zero cases -> FAIL (vacuous, not proof)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/inj-self.XXXXXX")" || return 1
  make_targets "$tmp"; mkdir -p "$tmp/walteur-kit"
  mk_manifest "$tmp" "safe.sh" '[]'
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "zero cases -> FAIL (vacuous)" 2 "$?"
  rm -rf "$tmp"

  # 4. SAFE target survives the hostile corpus -> PASS
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/inj-self.XXXXXX")" || return 1
  make_targets "$tmp"; mkdir -p "$tmp/walteur-kit"; mk_manifest "$tmp" "safe.sh"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "safe target -> PASS" 0 "$?"
  # probe_executed marker true
  ck "safe target -> probe_executed:true" "true" "$(jq -r '.probe_executed' "$tmp/walteur-kit/injection-resistance-report.json" 2>/dev/null)"
  rm -rf "$tmp"

  # 5. LEAKY target (prints the env canary) -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/inj-self.XXXXXX")" || return 1
  make_targets "$tmp"; mkdir -p "$tmp/walteur-kit"; mk_manifest "$tmp" "leak.sh"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "canary-leaking target -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 6. HANG target (infinite loop) -> FAIL via timeout
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/inj-self.XXXXXX")" || return 1
  make_targets "$tmp"; mkdir -p "$tmp/walteur-kit"; mk_manifest "$tmp" "hang.sh"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "hanging target -> FAIL (timeout)" 2 "$?"
  rm -rf "$tmp"

  # 7. CRASH target (SIGSEGV) -> FAIL via signal-death
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/inj-self.XXXXXX")" || return 1
  make_targets "$tmp"; mkdir -p "$tmp/walteur-kit"; mk_manifest "$tmp" "crash.sh"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "crashing target -> FAIL (signal)" 2 "$?"
  rm -rf "$tmp"

  # 8. TRAVERSAL leak: target emits /etc/passwd-style content; must_not_contain catches it -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/inj-self.XXXXXX")" || return 1
  make_targets "$tmp"; mkdir -p "$tmp/walteur-kit"
  mk_manifest "$tmp" "traversal.sh" '[{"name":"traversal","argv":["../../../../etc/passwd"],"append_input_file":false,"max_exit":2,"must_not_contain":["root:x:0"]}]'
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "traversal-content leak -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 8b. argv fidelity: the declared payload must reach the target byte-exact. A target that leaks only
  # on an exact match must still be caught -- if argv were corrupted the leak would vanish and the gate
  # would report a false PASS (fail-open: the hostile case was never really delivered).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/inj-self.XXXXXX")" || return 1
  make_targets "$tmp"; mkdir -p "$tmp/walteur-kit"
  mk_manifest "$tmp" "argvexact.sh" '[{"name":"argv-verbatim","argv":["../../../../etc/passwd"],"append_input_file":false,"max_exit":2,"must_not_contain":["root:x:0"]}]'
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "argv delivered verbatim -> leak caught" 2 "$?"
  rm -rf "$tmp"

  # 9. bypass -> SKIP/PASS (exit 0)
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/inj-self.XXXXXX")" || return 1
  make_targets "$tmp"; mkdir -p "$tmp/walteur-kit"; mk_manifest "$tmp" "leak.sh"
  WALTEUR_ROOT="$tmp" WALTEUR_INJECTION=off bash "$SELF_PATH" >/dev/null 2>&1
  ck "bypass -> exit 0" 0 "$?"
  rm -rf "$tmp"

  # 10. PAUSED -> FAIL
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/inj-self.XXXXXX")" || return 1
  make_targets "$tmp"; mkdir -p "$tmp/walteur-kit"; mk_manifest "$tmp" "safe.sh"; touch "$tmp/walteur-kit/PAUSED"
  WALTEUR_ROOT="$tmp" bash "$SELF_PATH" >/dev/null 2>&1
  ck "PAUSED -> FAIL" 2 "$?"
  rm -rf "$tmp"

  # 11. STRICT + missing perl (shadowed) -> fail-closed, not loud-skip
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/inj-self.XXXXXX")" || return 1
  make_targets "$tmp"; mkdir -p "$tmp/walteur-kit"; mk_manifest "$tmp" "safe.sh"
  local noperl="$tmp/noperl"; mkdir -p "$noperl"
  for b in bash jq mktemp date dirname basename cat grep rm chmod env; do
    src="$(command -v "$b" 2>/dev/null)"
    # only shim real binaries: shell builtins resolve to a bare name and cannot be linked
    case "$src" in /*) ln -sf "$src" "$noperl/$b" 2>/dev/null ;; esac
  done
  # Invoke the REAL bash by absolute path. On Git-Bash/MSYS `ln -s` copies rather than links, and a
  # copied bash.exe cannot load msys-2.0.dll once PATH is shadowed -- it dies 127 before the gate
  # ever runs, which would mask the verdict under test. PATH stays shadowed so `command -v perl`
  # genuinely fails inside the gate, which is the condition this case asserts on.
  local real_bash; real_bash="$(command -v bash)"
  PATH="$noperl" WALTEUR_ROOT="$tmp" WALTEUR_TOOLGATE_STRICT=1 "$real_bash" "$SELF_PATH" >/dev/null 2>&1
  ck "STRICT + no perl -> fail-closed" 2 "$?"
  rm -rf "$tmp"

  echo "injection-resistance-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

# ---- default run ----
if [ ! -f "$MANIFEST" ]; then
  echo "injection-resistance-gate: no walteur-kit/injection-probes.json - gate not applicable." >&2
  write_report "NOT_APPLICABLE" "no injection-probes.json manifest present"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  if [ "$STRICT" = "1" ]; then echo "injection-resistance-gate: FAIL - jq required at ship (STRICT)." >&2; write_report "FAIL" "jq required at ship (strict)"; exit 2; fi
  echo "injection-resistance-gate: SKIP - jq not installed." >&2; write_report "SKIP" "jq not installed"; exit 0
fi

if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
  echo "injection-resistance-gate: FAIL - injection-probes.json is not valid JSON." >&2
  write_report "FAIL" "manifest is not valid JSON"; exit 2
fi

shape_err="$(jq -r '
  def err(c;m): if c then m else empty end;
  [ err((.target.cmd|type)!="array" or ((.target.cmd|length)<1); "target.cmd must be a non-empty array")
  , err((.canary|type)!="string" or ((.canary|length)<8); "canary must be a string of length >= 8")
  , err((.timeout_ms|type)!="number" or (.timeout_ms<1); "timeout_ms must be a number >= 1")
  , err((.cases|type)!="array" or ((.cases|length)<1); "cases must be a non-empty array (a manifest that runs zero cases is not proof)")
  ] | map(select(.!=null)) | .[]' "$MANIFEST" 2>/dev/null)"
if [ -n "$shape_err" ]; then
  echo "injection-resistance-gate: FAIL - manifest shape:" >&2
  printf '%s\n' "$shape_err" | sed 's/^/  - /' >&2
  write_report "FAIL" "manifest fails required shape" "$(printf '%s\n' "$shape_err" | jq -R . | jq -s '{findings:.}')"
  exit 2
fi

if ! command -v perl >/dev/null 2>&1; then
  if [ "$STRICT" = "1" ]; then echo "injection-resistance-gate: FAIL - perl required for the executed probe timeout at ship (STRICT)." >&2; write_report "FAIL" "perl required at ship (strict)"; exit 2; fi
  echo "injection-resistance-gate: SKIP - perl not installed (needed for the timeout-bounded probe)." >&2
  write_report "SKIP" "perl not installed - cannot run the timeout-bounded probe"; exit 0
fi

CASES_RUN=0; CASES_PASS=0; FAILS_JSON="[]"
run_probe; probe_rc=$?
if [ "$probe_rc" -eq 3 ]; then
  echo "injection-resistance-gate: FAIL - probe could not execute (target unresolved)." >&2
  write_report "FAIL" "probe could not execute (target unresolved)" "$(jq -n --argjson cr "${CASES_RUN:-0}" '{probe_executed:($cr>0), cases_run:$cr}')"
  exit 2
fi

extra="$(jq -n --argjson run "$CASES_RUN" --argjson pass "$CASES_PASS" --argjson fails "$FAILS_JSON" \
  '{probe_executed:($run>0), cases_run:$run, cases_passed:$pass, failures:$fails}')"
if [ "$probe_rc" -ne 0 ]; then
  echo "injection-resistance-gate verdict: FAIL ($CASES_PASS/$CASES_RUN cases survived) -> $REPORT" >&2
  write_report "FAIL" "$((CASES_RUN-CASES_PASS)) of $CASES_RUN adversarial case(s) breached the target" "$extra"
  exit 2
fi
echo "injection-resistance-gate verdict: PASS (all $CASES_RUN adversarial cases survived, probe executed) -> $REPORT" >&2
write_report "PASS" "target survived all $CASES_RUN executed adversarial cases" "$extra"
exit 0
