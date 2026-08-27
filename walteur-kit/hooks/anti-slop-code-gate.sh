#!/usr/bin/env bash
# WALTEUR anti-slop-code-gate — HARD gate. "Pure production enterprise code, no AI slop." Scans ALL
# production source (not just UI) for the tells of incomplete, lazy, or AI-generated stub code and FAILs.
# This is the code-craftsmanship floor: a $50-100M business ships finished code, not placeholders.
#
# Catches: TODO/FIXME/HACK, NotImplemented, "placeholder", "in a real app you'd…", "for now we just…",
# "coming soon", stub credentials (your-api-key / changeme / replace-this), empty catch blocks,
# swallowed errors (catch that only logs), `as any` / `: any` escapes, @ts-ignore/@ts-nocheck,
# eslint-disable without a reason, and console.log left in server code.
#
# Excludes tests/examples/docs/scripts and node_modules. Bypass WALTEUR_ANTISLOP=off. PAUSED => exit 2.
# Tunable: WALTEUR_ANTISLOP_MAX (default 0 high-confidence hits allowed).
# Report: walteur-kit/anti-slop-code-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "anti-slop-code-gate - HARD gate. Pure production enterprise code, no AI slop. Scans ALL"
  printf '%s\n' "usage: bash anti-slop-code-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/anti-slop-code-report.json - fix recipes: walteur-kit/REMEDIATION.md (## anti-slop-code-gate)"
  printf '%s\n' "bypass: WALTEUR_ANTISLOP=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
REPORT="$KIT/anti-slop-code-report.json"
MAXHITS="${WALTEUR_ANTISLOP_MAX:-0}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }
# Production source extensions. Widened after the D4 gauntlet proved a .c/.tf/.scala/… tree evaded the scan
# entirely (and worse: has_source() reused this list, so an unrecognized tree returned the all-clear).
# D5 gauntlet: a hardcoded prod credential + TODO ship-blocker + swallowed migration error was hidden on a
# container entrypoint.sh (and the same blind spot covered YAML/TOML/Dockerfile/.env — the DOMINANT carriers
# of hardcoded prod secrets and deploy-time ship-blockers). Added shell/YAML/TOML/PowerShell/Dockerfile/env.
INC="--include=*.ts --include=*.tsx --include=*.js --include=*.jsx --include=*.mjs --include=*.cjs --include=*.py --include=*.go --include=*.rs --include=*.java --include=*.rb --include=*.php --include=*.cs --include=*.kt --include=*.swift --include=*.sql --include=*.vue --include=*.svelte --include=*.c --include=*.cc --include=*.cpp --include=*.cxx --include=*.h --include=*.hh --include=*.hpp --include=*.hxx --include=*.m --include=*.mm --include=*.scala --include=*.sc --include=*.ex --include=*.exs --include=*.clj --include=*.cljs --include=*.cljc --include=*.dart --include=*.lua --include=*.pl --include=*.pm --include=*.r --include=*.html --include=*.htm --include=*.scss --include=*.sass --include=*.less --include=*.razor --include=*.cshtml --include=*.erb --include=*.hbs --include=*.astro --include=*.sol --include=*.groovy --include=*.gradle --include=*.tf --include=*.tfvars --include=*.sh --include=*.bash --include=*.zsh --include=*.ksh --include=*.ps1 --include=*.psm1 --include=*.bat --include=*.cmd --include=*.yaml --include=*.yml --include=*.toml --include=*.env --include=.env --include=.env.* --include=*.dockerfile --include=Dockerfile --include=Dockerfile.* --include=Containerfile --include=Makefile --include=*.mk"
# Excluded dirs. scripts/ + migrations/ were REMOVED after the gauntlet planted a SUPERADMIN backdoor in a
# scripts/seedAdmin.ts deploy script that ships and runs against prod — shipping dirs must be scanned.
XD="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=walteur-kit --exclude-dir=.claude --exclude-dir=dist --exclude-dir=build --exclude-dir=.next --exclude-dir=out --exclude-dir=tests --exclude-dir=__tests__ --exclude-dir=test --exclude-dir=spec --exclude-dir=examples --exclude-dir=example --exclude-dir=fixtures --exclude-dir=vendor --exclude-dir=.terraform"
# also skip individual test/story/generated files, and TEMPLATE config files whose JOB is to hold
# placeholders (.env.example / .env.sample / .env.template / .env.dist / *.example / *.sample / *.template /
# *.dist / *.tmpl) — failing those would be a false-positive on intentional, documented placeholder files.
XF='\.(test|spec|stories|d|gen|generated|example|sample|template|tmpl|dist)\.|\.(example|sample|template|tmpl|dist)(:|$)|/\.env\.(example|sample|template|dist|local)(:|$)'

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"anti-slop-code", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"anti-slop-code","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }

has_source() { command -v grep >/dev/null 2>&1 || return 1; local _hs; _hs="$(grep -rIilE $INC $XD '.' "$ROOT" 2>/dev/null | grep -vE "$XF" | head -n1)"; [ -n "$_hs" ]; }

# count hits for a pattern (excluding test-ish files), echo "count\tfirst-file:line"
hits_for() {
  local pat="$1" out
  out="$(grep -riInE $INC $XD "$pat" "$ROOT" 2>/dev/null | grep -vE "$XF" | head -3)"
  printf '%s' "$out"
}

scan() {
  local label="$1" pat="$2" h n
  h="$(hits_for "$pat")"
  [ -z "$h" ] && return 0
  n="$(printf '%s\n' "$h" | grep -c . )"
  add_finding "$label" "$(printf '%s' "$h" | head -1 | sed "s#$ROOT/##") (and others) — $label"
}

# Case-SENSITIVE variants (no -i). The TODO/FIXME/XXX/HACK markers are conventionally UPPERCASE, so a
# case-insensitive match false-positives on legit product words ("Todo" app title, "todo list" feature) —
# panel-9 code expert + re-run. scan_cs matches only the UPPERCASE acronym forms; the lowercase marker-with-
# colon form (e.g. "todo:") is caught SEPARATELY by a colon-anchored case-insensitive scan, so detection is
# NOT weakened — only the bare product-word false positive is freed.
hits_for_cs() {
  local pat="$1" out
  out="$(grep -rInE $INC $XD "$pat" "$ROOT" 2>/dev/null | grep -vE "$XF" | head -3)"
  printf '%s' "$out"
}
scan_cs() {
  local label="$1" pat="$2" h
  h="$(hits_for_cs "$pat")"
  [ -z "$h" ] && return 0
  add_finding "$label" "$(printf '%s' "$h" | head -1 | sed "s#$ROOT/##") (and others) — $label"
}

# MULTILINE empty / swallowed catch — line-based grep can't see `catch (e) {` ... `}` split across lines, nor a
# body that is only a comment or a bare return. The D4 gauntlet defeated the single-line regex with the DEFAULT
# Prettier formatting. The D5 gauntlet defeated the FIXED-ENUMERATION return arm: the old JS arm matched only
# `return null|false|undefined|0` (so `return true` — which LIES about success — slipped through), and the old
# Python arm matched only `pass` (so `except: return None` slipped through). Both are the SAME ship-blocking
# "swallowed error that hides failures" class. The fix is semantic, not enumerated: a catch/except is a SWALLOW
# when its body is empty / comment-only / ellipsis, OR a single bare `return <expr>` whose expr does NOT
# reference the caught error variable AND does not log/raise/rethrow. A HANDLED arm (logs, re-raises, or uses
# the error in its return) is therefore NOT flagged — that's the false-positive guard (G14). Uses perl slurp
# with a balanced-brace body scan (grep -P is locale-broken in this Git-Bash, and braces nest in JS bodies).
scan_catch() {
  # perl-absence handling (B62, panel-7 fail-open): scan_catch is the ONLY detector of the multiline
  # swallowed-catch class. If perl is missing it cannot run — silently returning 0 was a FAIL-OPEN (a HARD
  # gate exiting PASS on a tree whose only defect is an empty catch). Now: at ship (WALTEUR_TOOLGATE_STRICT=1)
  # an unverifiable class FAIL-CLOSES (adds a finding -> failures>0 -> FAIL exit 2), matching osv/container
  # (B40/B41); off-ship it emits a LOUD recorded SKIP (never silent-green) and skips only this class.
  # WALTEUR_TEST_NO_PERL=1 simulates a perl-less env for the selftest; it can ONLY make the gate stricter
  # (fail-closed at ship / loud-skip off-ship), never weaken a real check.
  if [ "${WALTEUR_TEST_NO_PERL:-0}" = "1" ] || ! command -v perl >/dev/null 2>&1; then
    if [ "${WALTEUR_TOOLGATE_STRICT:-0}" = "1" ]; then
      add_finding "swallowed_catch_unverifiable_strict" "perl absent - the multiline swallowed-catch class is UNVERIFIABLE at ship (WALTEUR_TOOLGATE_STRICT=1); install perl or run non-strict"
      echo "anti-slop-code-gate: FAIL-CLOSED - perl required for the multiline swallowed-catch scan at ship (STRICT)." >&2
    else
      echo "anti-slop-code-gate: SKIP - perl absent; multiline swallowed-catch class not scanned (recorded, not silent-green). Install perl for full coverage." >&2
    fi
    return 0
  fi
  local files f
  files="$(grep -rIlE $INC $XD '.' "$ROOT" 2>/dev/null | grep -vE "$XF")"
  [ -z "$files" ] && return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if perl -0777 -ne '
      my $hit = 0;
      # ── JS/TS/Java/C#/… brace-language catch (VAR) { BODY } ─────────────────────────────────────────
      while (/catch\s*(?:\(\s*([A-Za-z_\$][\w\$]*)?[^)]*\))?\s*\{/sg) {
        my $var = $1 // "";
        my $start = pos();
        my $depth = 1; my $i = $start; my $len = length($_);
        while ($i < $len && $depth > 0) {            # balanced-brace scan to the matching close
          my $ch = substr($_, $i, 1);
          $depth++ if $ch eq "{";
          $depth-- if $ch eq "}";
          $i++;
        }
        my $b = substr($_, $start, $i - $start - 1);
        $b =~ s{//[^\n]*}{}g;                          # strip line comments
        $b =~ s{/\*.*?\*/}{}gs;                         # strip block comments
        $b =~ s/^\s+|\s+$//g;                            # trim
        if ($b eq "") { $hit=1; last; }                 # empty / comment-only swallow
        if ($b =~ /^return\b[^;{}]*;?$/s) {              # body is ONE bare return statement
          next if $var ne "" && $b =~ /\b\Q$var\E\b/;   # return USES the error -> handled, not swallow
          next if $b =~ /\b(throw|reject|log|logger|error|warn|console|Sentry|capture|raise)\b/i;
          $hit=1; last;                                  # bare return of a value that ignores the error
        }
      }
      # ── Python except [Type] [as VAR]: <inline or block body> ──────────────────────────────────────
      unless ($hit) {
        while (/^([ \t]*)except\b([^\n:]{0,80}):[ \t]*(.*)$/mg) {
          my ($indent,$head,$inline) = ($1,$2,$3);
          my $var = ($head =~ /\bas\s+([A-Za-z_]\w*)/) ? $1 : "";
          my $rest = $inline; $rest =~ s/#.*$//; $rest =~ s/^\s+|\s+$//g;
          if ($rest ne "") {                              # inline single-statement except body
            if ($rest eq "pass" || $rest eq "..." || $rest =~ /^return\b/) {
              my $expr = ($rest =~ /^return\b(.*)$/) ? $1 : "";
              next if $var ne "" && $expr =~ /\b\Q$var\E\b/;
              next if $rest =~ /\b(raise|log|logger|logging|print|warn|error|capture|reraise|sys\.exit)\b/i;
              $hit=1; last;
            }
            next;
          }
          my $tail = substr($_, pos());                   # block body: peek indented lines until dedent
          my @body; my $base = length($indent);
          for my $ln (split /\n/, $tail, -1) {
            next if $ln =~ /^\s*$/ && !@body;
            last if $ln =~ /^\s*$/;
            my ($lead) = $ln =~ /^([ \t]*)/;
            last if length($lead) <= $base;
            push @body, $ln;
          }
          my $b = join("\n", @body); $b =~ s/#.*$//mg; $b =~ s/^\s+|\s+$//g;
          next if $b eq "";
          if ($b =~ /^(pass|\.\.\.)$/) { $hit=1; last; }  # whole block is just pass / ...
          if ($b =~ /^return\b(.*)$/s) {                  # whole block is one bare return
            my $expr = $1;
            next if $var ne "" && $expr =~ /\b\Q$var\E\b/;
            next if $b =~ /\b(raise|log|logger|logging|print|warn|error|capture|reraise|sys\.exit)\b/i;
            $hit=1; last;
          }
        }
      }
      exit($hit ? 0 : 1);   # exit 0 = SWALLOW FOUND (so the `then` arm fires and records the finding)
    ' "$f" 2>/dev/null; then
      add_finding "empty_or_swallowed_catch" "$(printf '%s' "$f" | sed "s#$ROOT/##") — an empty / comment-only / bare-return catch (a swallowed error that hides failures)"
      return 0
    fi
  done <<< "$files"
}

selftest() {
  pass=0; fail=0
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  echo "anti-slop-code-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$0" >/dev/null 2>&1; echo $?; }

  # 1. no source -> NOT_APPLICABLE
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/walteur-kit"; ck "no source -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. clean production code -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'export function total(items: Item[]): number {\n  return items.reduce((s, i) => s + i.price, 0);\n}\n' > "$t/src/billing.ts"; ck "clean code -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. TODO -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'export function charge() {\n  // TODO: handle refunds\n  return true;\n}\n' > "$t/src/pay.ts"; ck "TODO -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. "in a real app you'd" -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'export function auth() {\n  // In a real app you would verify the token here\n  return {ok:true};\n}\n' > "$t/src/auth.ts"; ck "in-a-real-app slop -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. NotImplemented -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'def export_data():\n    raise NotImplementedError("later")\n' > "$t/src/dsar.py"; ck "NotImplemented -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. placeholder credential -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'const client = new Api({ key: "your-api-key-here" });\n' > "$t/src/api.ts"; ck "placeholder credential -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. empty catch -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'try { doThing(); } catch (e) {}\n' > "$t/src/x.ts"; ck "empty catch -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. as any -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'const u = getUser() as any;\nu.doWhatever();\n' > "$t/src/u.ts"; ck "as any escape -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 9. @ts-ignore -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf '// @ts-ignore\nbrokenCall();\n' > "$t/src/i.ts"; ck "@ts-ignore -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 10. TODO in a TEST file -> PASS (excluded)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src/__tests__"; printf '// TODO: add more cases\ntest("x",()=>{});\n' > "$t/src/__tests__/a.test.ts"; ck "TODO in test -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # ── B67 (panel-9 code expert) — FALSE-POSITIVE guards: the HARD gate must NOT fail LEGITIMATE code ──
  # FP-guard: prose "work to do", DOM .replaceWith(), a ": any missing" comment, and the product word "Todo"
  # (incl an HTML <title>Todo</title>) are all legitimate — the gate must PASS them (was FAIL, over-fire).
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf '// still lots of work to do\nlabel.replaceWith(input);\n// Deny-by-default: any missing scope is rejected\nexport const title = "Todo";\n' > "$t/src/app.ts"; printf '<!doctype html><title>Todo — zero-dependency</title>\n' > "$t/src/index.html"; ck "B67 legit prose/DOM/:any/Todo-title -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # TP-keep: the tightening must NOT introduce false-negatives — real slop of each tightened class still FAILs.
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'let u: any;\nu.doWhatever();\n' > "$t/src/ann.ts"; ck "B67 real : any annotation still -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'const k = "replace with your real key";\n' > "$t/src/cred.ts"; ck "B67 replace-with prose credential still -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'function f(){\n  // todo: wire the refund path\n  return 1;\n}\n' > "$t/src/lc.ts"; ck "B67 lowercase todo: marker still -> FAIL (no false-negative)" 2 "$(run "$t")"; rm -rf "$t"
  # B69b: a BARE lowercase comment marker (no colon) must FAIL - closes the residual FN B67 opened (panel-10 code expert),
  # WITHOUT re-flagging the product word "Todo" / "todo list" (those stay free - comment-anchored, space-required).
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'function g(){\n  // todo wire the refund path later\n  return 2;\n}\n' > "$t/src/bare.ts"; ck "B69b bare lowercase // todo (no colon) -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'const todos = [];\nexport const feature = "a todo list app";\n' > "$t/src/prod.ts"; ck "B69b todos identifier + \"todo list\" prose -> PASS (no new FP)" 0 "$(run "$t")"; rm -rf "$t"
  # B72 (panel-11 code expert): "changeme" matched as a SUBSTRING so legit identifiers exchangeMessage/exchangeMetadata
  # tripped the HARD stub_credential check. Leading-boundary \bchangeme frees them while still catching changeme/changeme123.
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'export const exchangeMessage = api.exchangeMetadata();\nexport const m = new ExchangeMember();\n' > "$t/src/exch.ts"; ck "B72 exchangeMessage/exchangeMetadata identifiers -> PASS (changeme substring FP freed)" 0 "$(run "$t")"; rm -rf "$t"
  # B72: a bare lowercase //todo with NO space (and no colon) is now caught (FN closed) while URLs stay free.
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'function h(){\n  //todo wire this\n  return 3;\n}\n' > "$t/src/nospace.ts"; ck "B72 //todo no-space -> FAIL (FN closed)" 2 "$(run "$t")"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'export const api = "http://todo.example.com/v1";\nexport const doc = "https://fixme.io";\n' > "$t/src/urls.ts"; ck "B72 http://todo + https://fixme URLs -> PASS (no URL false-positive)" 0 "$(run "$t")"; rm -rf "$t"
  # 11. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf '// TODO\n' > "$t/src/a.ts"; WALTEUR_ROOT="$t" WALTEUR_ANTISLOP=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/walteur-kit" "$t/src"; printf '// TODO\n' > "$t/src/a.ts"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"
  # 12. .claude/hooks/ harness scripts must NOT count as production source: their own dispatch
  # comments legitimately say "TODO/placeholder/stub" (documenting what THIS gate catches) and that
  # self-referential meta-text is not project slop.
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src" "$t/.claude/hooks"; printf 'export const ok = 1;\n' > "$t/src/ok.ts"; printf '#!/usr/bin/env bash\nrun_gate anti-slop-code-gate.sh # no TODO/placeholder/stub/`as any`/empty-catch in production source\n' > "$t/.claude/hooks/ship-gate.sh"; ck ".claude/hooks/ scripts excluded from scan -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # ── D4 gauntlet regressions (G1-G14) — each was a PROVEN false-negative; now must FAIL ──
  # G1 — slop in a .c file (extension blind spot; has_source NOT_APPLICABLE evasion)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf '/* TODO: call the acquirer before launch */\nint charge(){ return 0; /* FIXME: always success */ }\n' > "$t/src/pay.c"; ck "G1 .c TODO -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G2 — slop in a Terraform .tf file
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'resource "aws_db_instance" "x" {\n  password = "changeme123"\n}\n' > "$t/src/main.tf"; ck "G2 .tf placeholder -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G3 — multi-line empty catch (brace on next line)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'try {\n  charge();\n} catch (e) {\n}\n' > "$t/src/p.ts"; ck "G3 multiline empty catch -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G4 — swallowed catch (comment-only body)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'try {\n  charge();\n} catch (err) {\n  // swallow, do not bother the user\n}\n' > "$t/src/p.ts"; ck "G4 comment-only catch -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G5 — swallowed catch (bare return null)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'try { refund(); } catch (e) { return null; }\n' > "$t/src/p.ts"; ck "G5 return-null catch -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G6 — aliased any (type X = any)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'type Json = any;\nconst payload: Json = req.body;\n' > "$t/src/h.ts"; ck "G6 aliased any -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G7 — @ts-expect-error
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf '// @ts-expect-error signature changed, fix later\nprocessor.charge(id);\n' > "$t/src/p.ts"; ck "G7 @ts-expect-error -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G8 — as<2 spaces>any
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'const r = (client as  any).internalCharge(id);\n' > "$t/src/p.ts"; ck "G8 as<2sp>any -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G9 — console.log leak in server code
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'const token = issueSession(id);\nconsole.log(user.password);\n' > "$t/src/auth.ts"; ck "G9 console.log -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G10 — TO DO / FIX ME (broken word boundary)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf '// FIX ME: idempotency not enforced; retried webhook double-charges\nexport const x = 1;\n' > "$t/src/p.ts"; ck "G10 FIX ME -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G11 — stub synonyms ("not yet built" / "real logic goes here")
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'export function reconcile(){\n  // real logic goes here\n  throw new Error("not yet built");\n}\n' > "$t/src/p.ts"; ck "G11 stub synonyms -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G12 — placeholder credential variants (REPLACE_WITH / <paste-here> / tbd)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'const KEY = "REPLACE_WITH_YOUR_KEY";\nconst TOK = "<paste-token-here>";\nconst s = "tbd";\n' > "$t/src/p.ts"; ck "G12 cred variants -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G13 — slop in scripts/ (shipping dir no longer excluded)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/scripts" "$t/src"; printf 'export const real=1;\n' > "$t/src/ok.ts"; printf '// TODO: remove this hardcoded backdoor before GA\nconst BACKDOOR = "changeme123";\n' > "$t/scripts/seedAdmin.ts"; ck "G13 scripts/ slop -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G14 — FALSE-POSITIVE GUARD: a realistic clean file (handled catch, typed, console.error allowed) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'export async function charge(id: string, cents: number): Promise<{ok: boolean}> {\n  try {\n    const r = await gateway.capture(id, cents);\n    return { ok: r.status === "ok" };\n  } catch (err) {\n    logger.error("capture failed", { id, err });\n    throw err;\n  }\n}\n' > "$t/src/clean.ts"; ck "G14 clean handled catch -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # ── D5 gauntlet regressions (G15-G21) — each a PROVEN false-negative; now must FAIL (or PASS for guards) ──
  # G15 — JS swallow-catch returning `true` (LIES about success — worse than the null sibling the gate caught)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"
  printf 'export async function refund(id: string): Promise<boolean> {\n  try {\n    return await gateway.refund(id);\n  } catch (e) { return true; }\n}\n' > "$t/src/billing.ts"
  ck "G15 catch return true -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G16 — Python except that swallows with `return None` (the JS arm covered return-swallows; Python did not)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"
  printf 'def issue_refund(payment_id, cents):\n    try:\n        return gateway.refund(payment_id, cents)\n    except Exception:\n        # error swallowed: caller cannot tell the refund failed\n        return None\n' > "$t/src/refunds.py"
  ck "G16 except return None -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G17 — defect hidden on a container entrypoint.sh (extension was NOT in the include-set)
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"
  printf 'export const VERSION = "1.0.0";\n' > "$t/src/version.ts"
  printf '#!/usr/bin/env bash\n# TODO: rotate this before GA -- hardcoded prod DB password\nexport DATABASE_URL="postgres://admin:changeme123@db.prod.internal:5432/app"\nrun_migrations || true\nexec node server.js\n' > "$t/src/entrypoint.sh"
  ck "G17 .sh credential+TODO -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G18 — hardcoded credential + TODO in a Dockerfile
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"
  printf 'FROM node:20\n# TODO: pin digest before GA\nENV API_KEY=changeme123\n' > "$t/src/Dockerfile"
  ck "G18 Dockerfile slop -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G19 — placeholder secret in a YAML deploy manifest
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"
  printf 'database:\n  password: changeme123  # TODO rotate before launch\n' > "$t/src/values.yaml"
  ck "G19 .yaml placeholder -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G20 — Python inline `except: return` (bare) swallow
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"
  printf 'def f():\n    try:\n        x()\n    except Exception:\n        return\n' > "$t/src/p.py"
  ck "G20 except bare return -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # G21 — FALSE-POSITIVE GUARD: a `.env.example` template (its JOB is placeholders) must PASS, plus a real .sh
  #        with a HANDLED catch-equivalent and an error-translating Python except -> PASS.
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"
  printf 'API_TOKEN=your-api-key-here\nDB_PASSWORD=changeme\n' > "$t/src/.env.example"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nrun_migrations\nexec node server.js\n' > "$t/src/start.sh"
  printf 'def load(path):\n    try:\n        return open(path).read()\n    except OSError as e:\n        logging.error("read failed", exc_info=e)\n        raise\n' > "$t/src/io.py"
  printf 'export function parse(s: string): number {\n  try {\n    return JSON.parse(s).n;\n  } catch (err) {\n    logger.warn("parse failed", err);\n    throw new Error("bad input");\n  }\n}\n' > "$t/src/parse.ts"
  ck "G21 templates+handled -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # B62 — perl-absent handling (the fail-OPEN fix). WALTEUR_TEST_NO_PERL=1 simulates a perl-less env; a clean
  # tree that would PASS with perl must FAIL-CLOSED at ship (STRICT) and loud-SKIP (still PASS) off-ship.
  t="$(mktemp -d "${TMPDIR:-/tmp}/antislopco.XXXXXX")"; mkdir -p "$t/src"; printf 'export const ok = (a,b) => a + b;\n' > "$t/src/ok.ts"
  ck "B62 no-perl + STRICT -> FAIL-CLOSED" 2 "$(WALTEUR_TEST_NO_PERL=1 WALTEUR_TOOLGATE_STRICT=1 WALTEUR_ROOT="$t" bash "$0" >/dev/null 2>&1; echo $?)"
  ck "B62 no-perl + non-strict clean -> PASS (loud skip)" 0 "$(WALTEUR_TEST_NO_PERL=1 WALTEUR_ROOT="$t" bash "$0" >/dev/null 2>&1; echo $?)"
  rm -rf "$t"
  echo "anti-slop-code-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_ANTISLOP:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_ANTISLOP=off"; echo "anti-slop-code-gate: bypassed." >&2; exit 0; }
if ! has_source; then write_report "NOT_APPLICABLE" "no production source files"; echo "anti-slop-code-gate: NOT_APPLICABLE"; exit 0; fi

# Patterns broadened after the D4 gauntlet (each evasion below is a fixed regression). -i is on (hits_for).
scan_cs "todo_placeholder"   '\b(TODO|FIXME|XXX|HACK)\b|\bTO[ _-]DO\b|\bFIX[ _-]ME\b'
scan "todo_marker_lc"        '\b(todo|fixme|xxx|hack)[[:space:]]*:'
scan "todo_marker_comment"   '(^|[^:])(//|/\*|#)[[:space:]]*(todo|fixme|xxx|hack)\b'
scan "not_implemented"       'not[ _]?implemented|NotImplementedError|raise NotImplemented'
scan "ai_slop_phrase"        'placeholder (text|copy|data|value|content|image|name|here|implementation|component)|placeholder\.(com|io|net|jpg|png|svg)|<placeholder|is a placeholder|//[[:space:]]*placeholder|/\*[[:space:]]*placeholder|coming soon|in (a |an )?(real|production|actual) (app|application|implementation|world|system|environment)|in production (you|we)|for now,? (we|this|just|i)|you would (normally|typically|want)|stub(bed)? (out|implementation)|dummy (data|value|implementation)|not yet (built|done|implemented|wired|ready)|not built|wire (this |it )?up( later)?|fill (this |it |me )?in|real (logic|code|impl|implementation) goes here|to be (built|done|wired|implemented|added)|come back to (this|here|it)|incomplete:|allow everything|demo flows? (work|flow)|hardcoded (backdoor|password|secret)|real acl'
scan "stub_credential"       'your[_-]?api[_-]?key|YOUR_[A-Z_]+_(KEY|SECRET|TOKEN)|<your[- ]|\bchangeme|change[-_ ]?this|replace[-_ ]?(this|me)|replace[-_ ]with|xxxxxxxx|example\.com/api|<paste|paste[-_ ]?[a-z]*[-_ ]?here|\btbd\b|fill[-_ ]?me[-_ ]?in|sk-x{2,}|sk-[a-z]*-?(change|placeholder|test|xxx)|<insert|insert[-_ ]?[a-z]*[-_ ]?here'
scan "debug_log"             'console\.(log|debug|info)\(|\bdebugger\b|System\.out\.print|fmt\.Print(ln|f)?\(.*(password|token|secret)'
scan "type_escape"           '\bas[[:space:]]+any\b|:[[:space:]]*any[[:space:]]*([][;,)}{>=|&]|$)|@ts-(ignore|nocheck|expect-error)|type[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*any\b'
scan "lint_suppression"      'eslint-disable(-next-line)?[[:space:]]*$|# noqa[[:space:]]*$|# type: ignore[[:space:]]*$'
scan_catch                 # multiline empty / comment-only / bare-return (swallowed) catch + except: pass

if [ "$failures" -gt "$MAXHITS" ]; then
  write_report "FAIL" "$failures AI-slop / non-production code marker(s) in source"
  echo "anti-slop-code-gate: FAIL - $failures slop marker(s) — ship finished production code, not placeholders" >&2
  printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
  exit 2
fi
write_report "PASS" "no AI-slop / placeholder / stub markers in production source"
echo "anti-slop-code-gate: PASS" >&2
exit 0
