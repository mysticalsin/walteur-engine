#!/usr/bin/env bash
# WALTEUR ci-hardening-gate — HARD gate (ULTIMATE R3). CI/CD is the #1 actively-exploited supply-chain surface
# of 2026 (tj-actions: 23k+ repos; Megalodon: 5,718 malicious commits across 5,561 repos in 6 hours). A
# WALTEUR-built pipeline must be default-secure. zizmor-style static checks on .github/workflows: third-party
# actions pinned to a mutable tag (not a 40-char SHA), long-lived cloud keys instead of OIDC, missing top-level
# permissions, bare pull_request_target, and checkout without persist-credentials:false.
#
# Applies when .github/workflows/*.yml|*.yaml is present.
# CONTRACT: insecure pipeline => FAIL exit 2 (fail-closed at high/regulated; advisory below) · no workflows =>
# NOT_APPLICABLE · PAUSED => exit 2 · bypass WALTEUR_CIHARDEN=off.
# Report: walteur-kit/ci-hardening-report.json
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "ci-hardening-gate - HARD gate (ULTIMATE R3). CI/CD is the #1 actively-exploited supply-chain surface"
  printf '%s\n' "usage: bash ci-hardening-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/ci-hardening-report.json - fix recipes: walteur-kit/REMEDIATION.md (## ci-hardening-gate)"
  printf '%s\n' "bypass: WALTEUR_CIHARDEN=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
CONTRACT="$KIT/build-contract.json"
REPORT="$KIT/ci-hardening-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

# A syntactically-valid 40-hex string that is not a real commit SHA: all-zeros (the classic decoy, e.g.
# 0000000000000000000000000000000000000000) or all-same-char (aaaa...a, ffff...f, etc). Real git SHA-1
# hashes are effectively never a single repeated character across all 40 positions.
is_placeholder_sha() {
  local s="$1" first
  [ ${#s} -eq 40 ] || return 1
  first="${s%"${s#?}"}"
  case "$s" in
    "$(printf "%40s" | tr ' ' "$first")") return 0 ;;
  esac
  return 1
}

# Structural workflow parser (indent-based). GitHub Actions YAML is whitespace-significant; a whole-file
# substring grep cannot tell WHICH step/job a match belongs to. This emits scoped records so the checks can
# require a match in the RIGHT place (the checkout step's own with:, the cloud job's own permissions:) and
# can SEE flow-style mappings (`- { uses: x }`) that a line-anchored `- uses:` regex misses.
#   USES\t<job>\t<step_idx>\t<ref>
#   CHECKOUT_PC\t<job>\t<step_idx>\t<true|false|none>   (persist-credentials on that checkout step)
#   JOB_HASOIDC\t<job>\t<0|1>           (id-token: write inside that job's body)
#   JOB_HASSTATICKEY\t<job>\t<0|1>      (static cloud key string inside that job's body)
#   FILE_HASSTATICKEY\t<0|1>            (static cloud key string anywhere in file)
parse_wf() {
  have perl || return 1
  perl -e '
use strict; use warnings;
my @lines=<STDIN>; chomp @lines;
sub strip_comment { my $s=shift; my $o=""; my $q=""; my $i=0;
  while($i<length $s){ my $c=substr($s,$i,1);
    if($q){$o.=$c; $q="" if $c eq $q;}
    elsif($c eq q{"} || $c eq q{'"'"'}){$q=$c;$o.=$c;}
    elsif($c eq "#"){last;}
    else{$o.=$c;} $i++; }
  $o=~s/\s+$//; return $o; }
sub indent { my $s=shift; $s=~/^(\s*)/; return length($1); }
my $STATIC=qr/aws-access-key-id|AWS_SECRET_ACCESS_KEY|secrets\.AWS_|secrets\.GCP_SA_KEY|GOOGLE_CREDENTIALS/;
my $n=@lines;
my $file_static=0;
for my $i (0..$n-1){ my $l=strip_comment($lines[$i]); $file_static=1 if $l=~$STATIC; }
print "FILE_HASSTATICKEY\t$file_static\n";
my ($jobs_indent,$jobs_line)=(-1,-1);
for my $i (0..$n-1){ my $l=strip_comment($lines[$i]); next if $l=~/^\s*$/;
  if($l=~/^(\s*)jobs:\s*$/){ $jobs_indent=length($1); $jobs_line=$i; last; } }
exit 0 if $jobs_line<0;
my $jni=-1;
for my $i ($jobs_line+1..$n-1){ my $l=strip_comment($lines[$i]); next if $l=~/^\s*$/;
  my $ind=indent($l); if($ind>$jobs_indent){$jni=$ind; last;} else {last;} }
exit 0 if $jni<0;
my @js=();
for my $i ($jobs_line+1..$n-1){ my $l=strip_comment($lines[$i]); next if $l=~/^\s*$/;
  my $ind=indent($l); last if $ind<=$jobs_indent;
  if($ind==$jni && $l=~/^\s*([A-Za-z0-9_.\-]+):\s*$/){ push @js,[$1,$i]; } }
push @js,["__END__",$n];
for my $j (0..$#js-1){
  my ($jn,$js)=@{$js[$j]}; my $je=$js[$j+1][1];
  my ($oidc,$static,$sl,$si)=(0,0,-1,-1);
  for my $i ($js+1..$je-1){ my $l=strip_comment($lines[$i]); next if $l=~/^\s*$/;
    my $ind=indent($l); next if $ind<=$jni;
    $oidc=1 if $l=~/id-token:\s*['"'"'"]?write['"'"'"]?\s*(?:[,}].*)?$/;
    $static=1 if $l=~$STATIC;
    if($l=~/^(\s*)steps:\s*$/ && $sl<0){ $sl=$i; $si=length($1); } }
  print "JOB_HASOIDC\t$jn\t$oidc\n";
  print "JOB_HASSTATICKEY\t$jn\t$static\n";
  next if $sl<0;
  my $sii=-1;
  for my $i ($sl+1..$je-1){ my $l=strip_comment($lines[$i]); next if $l=~/^\s*$/;
    my $ind=indent($l); last if $ind<=$si;
    if($l=~/^\s*-(\s|$)/){ $sii=$ind; last; } }
  next if $sii<0;
  my @ss=();
  for my $i ($sl+1..$je-1){ my $l=strip_comment($lines[$i]); next if $l=~/^\s*$/;
    my $ind=indent($l); last if $ind<=$si;
    if($ind==$sii && $l=~/^\s*-(\s|$)/){ push @ss,$i; } }
  push @ss,$je;
  for my $s (0..$#ss-1){
    my @body=grep { !/^\s*$/ } map { strip_comment($lines[$_]) } ($ss[$s]..$ss[$s+1]-1);
    my $joined=join("\n",@body); my $ref=""; my $co=0;
    if($joined=~/\{/){ my $flat=$joined; $flat=~s/\n/ /g;
      if($flat=~/\buses:\s*([^,}\s]+)/){ $ref=$1; $ref=~s/^['"'"'"]|['"'"'"]$//g; }
      $co=1 if $ref=~m{actions/checkout};
      print "USES\t$jn\t$s\t$ref\n" if $ref ne "";
      if($co){ my $pc="none"; if($flat=~/persist-credentials:\s*([A-Za-z0-9'"'"'"]+)/){ my $v=$1; $v=~s/['"'"'"]//g; $pc=lc($v); }
        print "CHECKOUT_PC\t$jn\t$s\t$pc\n"; }
      next; }
    for my $b (@body){ if($b=~/^\s*-?\s*uses:\s*(\S+)/){ $ref=$1; $ref=~s/^['"'"'"]|['"'"'"]$//g; last; } }
    $co=1 if $ref=~m{actions/checkout};
    print "USES\t$jn\t$s\t$ref\n" if $ref ne "";
    if($co){ my $pc="none";
      for my $b (@body){ if($b=~/persist-credentials:\s*([A-Za-z0-9'"'"'"]+)/){ my $v=$1; $v=~s/['"'"'"]//g; $pc=lc($v); last; } }
      print "CHECKOUT_PC\t$jn\t$s\t$pc\n"; }
  }
}
'
}

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" '{verdict:$v, ts:$ts, gate:"ci-hardening", reason:$r, findings:$f}' > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","ts":"%s","gate":"ci-hardening","reason":"%s"}\n' "$v" "$TS" "$r" > "$REPORT" 2>/dev/null || true; }
risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }
wfdir() { printf '%s' "$ROOT/.github/workflows"; }
workflows() { local d; d="$(wfdir)"; [ -d "$d" ] && find "$d" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null; }

scan_one() {
  local f="$1" rel; rel="$(printf '%s' "$f" | sed "s#$ROOT/##")"
  local P; P="$(parse_wf < "$f" 2>/dev/null)"
  local parsed=1; [ -n "$P" ] && have perl || parsed=0

  # (1) mutable-tag third-party actions — require a 40-char SHA (local ./ and docker@sha256: exempt).
  # Source the action refs from the structural parser so flow-style mappings (`- { uses: x }`) are seen,
  # not just block-style `- uses:` lines. Fail-closed fallback to a non-anchored grep if perl is absent.
  if [ "$parsed" -eq 1 ]; then
    while IFS=$'\t' read -r tag job idx ref; do
      [ "$tag" = "USES" ] || continue
      [ -n "$ref" ] || continue
      case "$ref" in
        ./*|'') continue ;;                                  # local action
        docker://*@sha256:*) continue ;;                     # digest-pinned docker
      esac
      after="${ref##*@}"
      if printf '%s' "$ref" | grep -q '@'; then
        if printf '%s' "$after" | grep -Eq '^[0-9a-f]{40}$'; then
          is_placeholder_sha "$after" && add_finding "$rel" "action '$ref' is pinned to a PLACEHOLDER SHA ('$after') — all-zeros or all-same-char 40-hex is not a real commit; resolve and pin the actual release SHA"
        else
          add_finding "$rel" "action '$ref' is pinned to a MUTABLE tag/branch ('$after') — pin to a 40-char commit SHA (the tj-actions attack hijacked a mutable tag)"
        fi
      else
        add_finding "$rel" "action '$ref' has no version pin — pin to a 40-char commit SHA"
      fi
    done < <(printf '%s\n' "$P")
  else
    # fail-closed fallback: match uses: anywhere on a line (covers flow-style), strip comments
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      ref="$(printf '%s' "$line" | sed -E 's/#.*$//; s/.*uses:[[:space:]]*//; s/[],}].*$//; s/[[:space:]].*$//; s/["'\'']//g')"
      case "$ref" in ./*|'') continue ;; docker://*@sha256:*) continue ;; esac
      after="${ref##*@}"
      if printf '%s' "$ref" | grep -q '@'; then
        if printf '%s' "$after" | grep -Eq '^[0-9a-f]{40}$'; then
          is_placeholder_sha "$after" && add_finding "$rel" "action '$ref' is pinned to a PLACEHOLDER SHA ('$after') — all-zeros or all-same-char 40-hex is not a real commit; resolve and pin the actual release SHA"
        else
          add_finding "$rel" "action '$ref' is pinned to a MUTABLE tag/branch ('$after') — pin to a 40-char commit SHA (the tj-actions attack hijacked a mutable tag)"
        fi
      else
        add_finding "$rel" "action '$ref' has no version pin — pin to a 40-char commit SHA"
      fi
    done < <(grep -nE 'uses:[[:space:]]*[^.]' "$f" 2>/dev/null)
  fi

  # (2) long-lived cloud keys instead of OIDC — JOB-SCOPED. A vacuous `id-token: write` on an unrelated
  # no-op job does NOT mitigate static keys in the deploy job; require the SAME job that carries the static
  # cloud key to also carry id-token: write. Static keys at workflow level (attributed to no job) fail-closed.
  if [ "$parsed" -eq 1 ]; then
    local file_static=0 oidc_job static_job
    while IFS=$'\t' read -r tag a b; do
      case "$tag" in
        FILE_HASSTATICKEY) file_static="$a" ;;
      esac
    done < <(printf '%s\n' "$P")
    if [ "$file_static" = "1" ]; then
      # build per-job oidc/static maps via a single awk pass; flag any static job lacking same-job OIDC
      local bad_oidc; bad_oidc="$(printf '%s\n' "$P" | awk -F'\t' '
        $1=="JOB_HASOIDC"{oidc[$2]=$3}
        $1=="JOB_HASSTATICKEY"{static[$2]=$3; if($3=="1") order[++k]=$2}
        END{ any=0; for(i=1;i<=k;i++){j=order[i]; if(oidc[j]!="1"){any=1}}; print any }')"
      # also: a static key present in file but no job claimed it (workflow-level env) => no same-job OIDC possible
      local any_static_job; any_static_job="$(printf '%s\n' "$P" | awk -F'\t' '$1=="JOB_HASSTATICKEY" && $3=="1"{c++} END{print c+0}')"
      if [ "$bad_oidc" = "1" ] || [ "$any_static_job" = "0" ]; then
        add_finding "$rel" "long-lived cloud credentials in CI without same-job OIDC — the job using static AWS/GCP keys must itself set 'permissions: id-token: write' + a cloud OIDC role (a decoy id-token:write on an unrelated job does not count)"
      fi
    fi
  else
    if grep -Eq 'aws-access-key-id|AWS_SECRET_ACCESS_KEY|secrets\.AWS_|secrets\.GCP_SA_KEY|GOOGLE_CREDENTIALS' "$f" 2>/dev/null; then
      grep -Eq 'id-token:[[:space:]]*write' "$f" 2>/dev/null || add_finding "$rel" "long-lived cloud credentials in CI without OIDC — use 'permissions: id-token: write' + a cloud OIDC role instead of static AWS/GCP keys"
    fi
  fi

  # (3) missing permissions block (default GITHUB_TOKEN is over-broad)
  grep -Eq '^[[:space:]]*permissions:' "$f" 2>/dev/null || add_finding "$rel" "no 'permissions:' block — the default GITHUB_TOKEN is over-privileged; set top-level 'permissions: {}' with job-level minimums"

  # (4) bare pull_request_target (runs with write token + secrets on untrusted PRs) — ignore comments
  if grep -Eq '^[[:space:]]*[^#]*pull_request_target' "$f" 2>/dev/null; then
    add_finding "$rel" "uses 'pull_request_target' — dangerous: it runs with a write token + secrets against untrusted PR code; avoid or never checkout the PR head"
  fi

  # (5) checkout without persist-credentials:false (token left on disk) — STEP-SCOPED. Require the override
  # on the checkout step's OWN with: block; a sibling `persist-credentials: false` at job/workflow env: (or
  # any other unrelated location) is inert — actions/checkout never reads it.
  if [ "$parsed" -eq 1 ]; then
    while IFS=$'\t' read -r tag job idx pc; do
      [ "$tag" = "CHECKOUT_PC" ] || continue
      [ "$pc" = "false" ] && continue
      add_finding "$rel" "actions/checkout (job '$job') without 'persist-credentials: false' on its own with: block — leaves the GITHUB_TOKEN on disk for later steps to exfiltrate (found: persist-credentials=$pc)"
    done < <(printf '%s\n' "$P")
  else
    if grep -Eq 'uses:[[:space:]]*[^[:space:]]*actions/checkout' "$f" 2>/dev/null; then
      grep -Eq 'persist-credentials:[[:space:]]*false' "$f" 2>/dev/null || add_finding "$rel" "actions/checkout without 'persist-credentials: false' — leaves the GITHUB_TOKEN on disk for later steps to exfiltrate"
    fi
  fi
}

selftest() {
  pass=0; fail=0
  local SELF; case "$0" in /*|?:[\/]*) SELF="$0" ;; *) SELF="$(pwd)/$0" ;; esac   # make $0 absolute before any cd
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  echo "ci-hardening-gate selftest:"
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }
  wf() { mkdir -p "$1/.github/workflows" "$1/walteur-kit"; printf '{"risk_tier":"%s"}\n' "${3:-high}" > "$1/walteur-kit/build-contract.json"; printf '%s\n' "$2" > "$1/.github/workflows/ci.yml"; }
  SHA="a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
  clean="name: ci
on: push
permissions: {}
jobs:
  b:
    permissions: { contents: read }
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$SHA
        with:
          persist-credentials: false"

  # 1. no workflows -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"risk_tier":"high"}\n' > "$t/walteur-kit/build-contract.json"; ck "no workflows -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. clean SHA-pinned + permissions + persist-creds -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$clean"; ck "clean hardened workflow -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. mutable tag @v4 -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$(printf '%s' "$clean" | sed "s/checkout@$SHA/checkout@v4/")"; ck "mutable tag @v4 -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. @main -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$(printf '%s' "$clean" | sed "s/checkout@$SHA/checkout@main/")"; ck "branch @main -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4b. NEGATIVE CONTROL: all-zeros 40-hex placeholder SHA -> FAIL (was a false-PASS before this fix)
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$(printf '%s' "$clean" | sed "s/checkout@$SHA/checkout@0000000000000000000000000000000000000000/")"; ck "all-zeros placeholder SHA -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4c. NEGATIVE CONTROL: all-same-char 40-hex placeholder SHA -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$(printf '%s' "$clean" | sed "s/checkout@$SHA/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/")"; ck "all-same-char placeholder SHA -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4d. real-looking 40-hex SHA (mixed chars, not all-zero/all-same) must still PASS (no over-flagging)
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$(printf '%s' "$clean" | sed "s/checkout@$SHA/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd/")"; ck "real mixed-char SHA -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 5. long-lived AWS key without OIDC -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$clean
        env:
          AWS_SECRET_ACCESS_KEY: \${{ secrets.AWS_SECRET_ACCESS_KEY }}"; ck "AWS key no OIDC -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. missing permissions block -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$(printf '%s' "$clean" | grep -v 'permissions')"; ck "no permissions block -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 7. pull_request_target -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$(printf '%s' "$clean" | sed 's/on: push/on: pull_request_target/')"; ck "pull_request_target -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 8. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$(printf '%s' "$clean" | sed "s/checkout@$SHA/checkout@v4/")"; WALTEUR_ROOT="$t" WALTEUR_CIHARDEN=off bash "$0" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$clean"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ---- regression cases for 3 proven false-negatives (gauntlet) ----
  # G10. persist-credentials:false placed at JOB env: (decoy), NOT on the checkout step's with: -> FAIL
  g10="name: ci
on: push
permissions: {}
jobs:
  build:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    env:
      persist-credentials: false
    steps:
      - uses: actions/checkout@$SHA
        with:
          fetch-depth: 0"
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$g10"; ck "G10 env-level persist-credentials decoy -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G11. mutable-tag action hidden in YAML flow-style mapping (- { uses: ... }) -> FAIL
  g11="name: deploy
on: push
permissions: {}
jobs:
  build:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$SHA
        with:
          persist-credentials: false
      - { uses: tj-actions/changed-files@v44, id: changed }
      - run: echo done"
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$g11"; ck "G11 flow-style mutable tag -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # G12. vacuous id-token:write on an unrelated no-op job; REAL deploy job uses static AWS keys -> FAIL
  g12="name: ci
on: push
permissions: {}
jobs:
  noop-oidc:
    permissions:
      id-token: write
      contents: read
    runs-on: ubuntu-latest
    steps:
      - run: echo no-cloud
  deploy:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    env:
      AWS_ACCESS_KEY_ID: \${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: \${{ secrets.AWS_SECRET_ACCESS_KEY }}
    steps:
      - uses: actions/checkout@$SHA
        with:
          persist-credentials: false
      - run: aws s3 sync ./dist s3://prod --delete"
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$g12"; ck "G12 vacuous OIDC on no-op job, static keys in deploy -> FAIL" 2 "$(run "$t")"; rm -rf "$t"

  # ---- false-positive guards: legitimate shapes must still PASS ----
  # G13. SAME-job OIDC: the job carrying static-key string also sets id-token: write -> PASS
  g13="name: ci
on: push
permissions: {}
jobs:
  deploy:
    permissions:
      id-token: write
      contents: read
    runs-on: ubuntu-latest
    env:
      AWS_SECRET_ACCESS_KEY: \${{ secrets.AWS_SECRET_ACCESS_KEY }}
    steps:
      - uses: actions/checkout@$SHA
        with:
          persist-credentials: false"
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$g13"; ck "G13 static key WITH same-job OIDC -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # G14. flow-style but SHA-pinned + persist-credentials:false on the step -> PASS (no over-flagging)
  g14="name: ci
on: push
permissions: {}
jobs:
  b:
    permissions: { contents: read }
    runs-on: ubuntu-latest
    steps:
      - { uses: actions/checkout@$SHA, with: { persist-credentials: false } }"
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$g14"; ck "G14 flow-style SHA-pinned + persist-creds:false -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # G15. pull_request_target mentioned only in a comment must NOT trip check #4 (still PASS)
  g15="name: ci
# note: do not use pull_request_target here
on: push
permissions: {}
jobs:
  b:
    permissions: { contents: read }
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$SHA
        with:
          persist-credentials: false"
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$g15"; ck "G15 pull_request_target only in comment -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  # G16. SAME-job OIDC declared FLOW-STYLE alongside a static key -> PASS (regex must accept id-token:write,)
  g16="name: ci
on: push
permissions: {}
jobs:
  deploy:
    permissions: { id-token: write, contents: read }
    runs-on: ubuntu-latest
    env:
      AWS_SECRET_ACCESS_KEY: \${{ secrets.AWS_SECRET_ACCESS_KEY }}
    steps:
      - uses: actions/checkout@$SHA
        with:
          persist-credentials: false"
  t="$(mktemp -d "${TMPDIR:-/tmp}/cihardenin.XXXXXX")"; wf "$t" "$g16"; ck "G16 flow-style same-job OIDC + static key -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "ci-hardening-gate selftest: $pass/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

[ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
[ "${WALTEUR_CIHARDEN:-on}" = "off" ] && { write_report "SKIP" "bypassed via WALTEUR_CIHARDEN=off"; echo "ci-hardening-gate: bypassed." >&2; exit 0; }

if [ -z "$(workflows)" ]; then write_report "NOT_APPLICABLE" "no .github/workflows"; echo "ci-hardening-gate: NOT_APPLICABLE"; exit 0; fi
RISK="$(risk)"
while IFS= read -r f; do [ -n "$f" ] && scan_one "$f"; done < <(workflows)

if [ "$failures" -ne 0 ]; then
  case "$RISK" in
    high|regulated)
      write_report "FAIL" "$failures CI-hardening violation(s)"
      echo "ci-hardening-gate: FAIL - $failures violation(s)" >&2
      printf '%s\n' "$findings" | { have jq && jq -r '.[] | "  - " + .check + ": " + .message' || cat; } 2>/dev/null || true
      exit 2 ;;
    *)
      write_report "ADVISORY" "$failures CI-hardening issue(s) (advisory below high risk)"
      echo "ci-hardening-gate: ADVISORY - $failures issue(s) (risk=$RISK, not blocking)" >&2
      exit 0 ;;
  esac
fi
write_report "PASS" "actions SHA-pinned · OIDC not static keys · permissions scoped · no pull_request_target footgun"
echo "ci-hardening-gate: PASS" >&2
exit 0
