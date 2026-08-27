#!/usr/bin/env bash
# WALTEUR apple-grade-design-gate — HARD gate (Tony's standing bar: "build it like Apple built it"). Beyond
# anti-slop-ui / design-gate / design-depth, this enforces the MEASURABLE hallmarks of Apple-grade craft on a
# UI build: a TIGHT TYPE SCALE (not a dozen ad-hoc font sizes), a 4/8pt SPACING GRID (no arbitrary off-grid
# padding/margin/gap), SEMANTIC TOKENS over raw hex, SNAPPY MOTION (transitions present, <=200ms via anti-slop-
# ui), and a DECLARED DESIGN SYSTEM (DESIGN.md craft intent). Clutter, inconsistency, and "good enough" fail.
#
# Applies when has_ui/is_user_facing AND style files exist. CONTRACT (S033: fail-closed for ANY user-facing
# build — preflight-signals/build-contract is_user_facing==true OR has_ui==true, OR risk_tier high/regulated
# as before; advisory ONLY for internal/non-user-facing surfaces): loose type scale / off-grid spacing / no
# design system => FAIL exit 2 · no UI => NOT_APPLICABLE · PAUSED => exit 2 · bypass WALTEUR_APPLE=off ·
# per-line override /* apple-ok */ · tunables WALTEUR_APPLE_TYPESTEPS (default 8) WALTEUR_APPLE_OFFGRID
# (default 8) WALTEUR_APPLE_ACCENTS (default 5) WALTEUR_APPLE_OK_MAX (default 8).
# Report: walteur-kit/apple-grade-report.json
#
# PANEL #12: checks 1-5 are all CEILINGS ("<=8 sizes", "<=6 hex", "a transition exists", "DESIGN.md
# exists") and a ceiling with no floor certifies mediocrity — a fixture with ONE 16px size for every
# element, all-caps body copy at max-width:none, nine competing accent hues and 4px tap targets passed all
# five as "Apple-grade craft floors met". Checks 6-10 add the FLOOR and measure hierarchy directly:
#   6  type-hierarchy   the ramp must span >=1.5x end to end, or carry >=2 weights (>=3 declarations)
#   7  legibility-caps  no text-transform:uppercase on a body-text selector
#   8  measure          a bounded 45-80ch reading measure must exist; max-width:none on text fails
#   9  tap-target       interactive selectors need >=32px vertical extent (HIG bar is 44pt)
#   10 accent-restraint <=5 distinct saturated hue families, counted from token definitions too
# Plus: /* apple-ok */ suppressions are counted, reported as debt and BUDGETED, and WALTEUR_APPLE=off is
# recorded as bypassed:true + a debt string instead of looking like a clean result.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "apple-grade-design-gate - HARD gate (Tonys standing bar: build it like Apple built it). Beyond"
  printf '%s\n' "usage: bash apple-grade-design-gate.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/apple-grade-report.json - fix recipes: walteur-kit/REMEDIATION.md (## apple-grade-design-gate)"
  printf '%s\n' "bypass: WALTEUR_APPLE=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

case "$0" in
  /*|?:[\\/]*) SELF="$0" ;;
  *) if command -v realpath >/dev/null 2>&1; then SELF="$(realpath "$0" 2>/dev/null || echo "$0")"
     else SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"; fi ;;
esac

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
SIGNALS="$KIT/preflight-signals.json"
CONTRACT="$KIT/build-contract.json"
REPORT="$KIT/apple-grade-report.json"
MAX_TYPE="${WALTEUR_APPLE_TYPESTEPS:-8}"
MAX_OFFGRID="${WALTEUR_APPLE_OFFGRID:-8}"
# Panel #12: the per-line /* apple-ok */ override was UNLIMITED and unrecorded, so a build could suppress
# every craft floor line by line and still read "Apple-grade craft floors met". Overrides are now counted,
# reported as debt, and BUDGETED — past the budget they stop being free and become their own finding.
MAX_OK="${WALTEUR_APPLE_OK_MAX:-8}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$KIT"
have() { command -v "$1" >/dev/null 2>&1; }

findings='[]'; failures=0
add_finding() { findings="$(printf '%s' "$findings" | { have jq && jq --arg c "$1" --arg m "$2" '. + [{check:$c, message:$m}]' || cat; } 2>/dev/null || printf '%s' "$findings")"; failures=$((failures+1)); }
OKCOUNT=0; BYPASS=false
write_report() { v="$1"; r="$2"; if have jq; then jq -n --arg v "$v" --arg ts "$TS" --arg r "$r" --argjson f "$findings" \
  --argjson ok "${OKCOUNT:-0}" --arg okmax "$MAX_OK" --argjson byp "$BYPASS" \
  '{verdict:$v, ts:$ts, gate:"apple-grade-design", reason:$r, findings:$f,
    apple_ok_overrides:$ok, apple_ok_budget:($okmax|tonumber), bypassed:$byp}
   + (if $byp then {debt:"WALTEUR_APPLE=off — Apple-grade craft floors UNVERIFIED, not met"} else {} end)
   + (if $ok > 0 then {override_debt:"\($ok) per-line /* apple-ok */ suppression(s) in the shipped styles"} else {} end)' \
  > "$REPORT" 2>/dev/null && return 0; fi; printf '{"verdict":"%s","reason":"%s"}\n' "$v" "$r" > "$REPORT" 2>/dev/null || true; }
risk() { [ -f "$CONTRACT" ] && have jq && jq -r '.risk_tier // "medium"' "$CONTRACT" 2>/dev/null || echo medium; }

has_ui() { [ -f "$SIGNALS" ] && have jq && jq -e '(.has_ui==true) or (.is_user_facing==true)' "$SIGNALS" >/dev/null 2>&1; }

# S033 candidate C4: user-facing builds get the FAIL-CLOSED floor regardless of risk_tier — Tony's "build
# it like Apple built it" bar cannot be advisory on the common (medium-risk) path. is_user_facing is an
# EXPLICIT signal (preflight-signals.is_user_facing, or a build-contract "ui" interface / is_user_facing
# flag) distinct from the coarser has_ui() applicability check above — a has_ui:true internal tool
# (is_user_facing explicitly false or absent) stays on the advisory path unless risk_tier forces it.
is_user_facing() {
  { [ -f "$SIGNALS" ] && have jq && jq -e '.is_user_facing==true' "$SIGNALS" >/dev/null 2>&1; } && return 0
  { [ -f "$CONTRACT" ] && have jq && jq -e '(.is_user_facing==true) or ([.interfaces[]? | select(.type=="ui")] | length > 0)' "$CONTRACT" >/dev/null 2>&1; } && return 0
  return 1
}
style_files() {
  command -v find >/dev/null 2>&1 || return 0
  find "$ROOT" -type d \( -name node_modules -o -name .git -o -name walteur-kit -o -name dist -o -name build -o -name .next \) -prune -o \
    -type f \( -name '*.css' -o -name '*.scss' -o -name '*.sass' -o -name '*.less' -o -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' \) -print 2>/dev/null
}
applies() { has_ui && [ -n "$(style_files | head -1)" ]; }

main() {
  [ -f "$KIT/PAUSED" ] && { add_finding paused "PAUSED present"; write_report FAIL paused; echo "apple-grade-design-gate: PAUSED -> exit 2"; exit 2; }
  # The bypass still wins (a build must be able to ship), but it is RECORDED as debt in the report rather
  # than looking like a clean result: verdict SKIP, bypassed:true, and an explicit debt string the release
  # ledger can pick up. "UNVERIFIED" is not "met".
  [ "${WALTEUR_APPLE:-}" = "off" ] && { BYPASS=true; write_report SKIP "bypassed via WALTEUR_APPLE=off — craft floors UNVERIFIED (recorded as debt, not a pass)"; echo "apple-grade-design-gate: bypassed (recorded as debt: craft floors UNVERIFIED)"; exit 0; }
  if ! have jq || ! have perl; then write_report SKIP "need jq+perl"; echo "apple-grade-design-gate: SKIP"; exit 0; fi
  if ! applies; then write_report NOT_APPLICABLE "no UI surface (need has_ui/is_user_facing + style files)"; echo "apple-grade-design-gate: NOT_APPLICABLE"; exit 0; fi

  local files; files="$(style_files | sort -u)"
  # 1. TYPE SCALE — count distinct font-size values across the UI. Apple uses a tight, intentional scale.
  local typesteps
  typesteps="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 cat 2>/dev/null | perl -ne '
    while (/font-size\s*:\s*([0-9]+(?:\.[0-9]+)?)(px|rem|em)/gi) { print lc("$1$2\n"); }
    while (/text-(xs|sm|base|lg|xl|2xl|3xl|4xl|5xl|6xl|7xl|8xl|9xl)\b/gi) { print lc("tw-$1\n"); }
  ' 2>/dev/null | sort -u | grep -c . )"
  [ "${typesteps:-0}" -gt "$MAX_TYPE" ] && add_finding type-scale "$typesteps distinct font sizes — Apple uses a tight type scale (<=$MAX_TYPE). Collapse to an intentional scale (e.g. 12/14/16/20/24/32/48)."

  # 2. SPACING GRID — padding/margin/gap px values must sit on a 4pt grid. Off-grid = ad-hoc, un-Apple.
  local offgrid
  offgrid="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 cat 2>/dev/null | perl -ne '
    next if /apple-ok/i;
    while (/(?:padding|margin|gap|row-gap|column-gap)[a-z-]*\s*:\s*([^;{}]+)/gi) {
      my $v=$1; while ($v=~/(\d+)px/g) { my $n=$1; print "$n\n" if $n>2 && ($n%4)!=0; }
    }
  ' 2>/dev/null | grep -c . )"
  [ "${offgrid:-0}" -gt "$MAX_OFFGRID" ] && add_finding spacing-grid "$offgrid off-grid spacing value(s) (px not a multiple of 4) — Apple snaps spacing to a 4/8pt grid for visual rhythm. Use grid steps (4/8/12/16/24/32)."

  # 3. SEMANTIC TOKENS over raw hex (reinforce design-gate at the Apple bar)
  local rawhex
  rawhex="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 perl -ne 'next if /apple-ok/i; print "$&\n" while /(?:color|background|border|fill|stroke)[a-z-]*\s*:\s*#[0-9a-fA-F]{3,8}\b/gi' 2>/dev/null | grep -c . )"
  [ "${rawhex:-0}" -gt 6 ] && add_finding tokens "$rawhex raw hex color(s) in styles — Apple-grade UIs use a semantic token system (CSS vars / theme tokens), not scattered literals."

  # 4. MOTION present (a static UI feels cheap; Apple interfaces move). Snappiness is enforced by anti-slop-ui.
  local hasmotion
  hasmotion="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -lIiE 'transition|animation|@keyframes|framer-motion|animate-' 2>/dev/null | head -1)"
  [ -z "$hasmotion" ] && add_finding motion "no transitions/animation found in any UI file — Apple interfaces have intentional, snappy motion (<=200ms). Add purposeful transitions on state changes."

  # 5. DECLARED DESIGN SYSTEM — DESIGN.md (or a tokens file) states the craft intent before pixels.
  { [ -f "$ROOT/DESIGN.md" ] || [ -f "$KIT/DESIGN.md" ] || ls "$ROOT"/**/tokens* >/dev/null 2>&1 || [ -n "$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -liE '(--[a-z-]+-(color|space|radius|font)|theme\.|tokens)' 2>/dev/null | head -n1)" ]; } \
    || add_finding design-system "no DESIGN.md / design-token system found — Apple-grade work declares the system (type · color · spacing · motion) before building."

  # ══ PANEL #12 REFUTATION FIX — checks 6-10 measure HIERARCHY AND LEGIBILITY, not the absence of tells ══
  # Checks 1-5 above are all ONE-SIDED CEILINGS: "<=8 distinct font sizes", "<=6 raw hex", "the string
  # transition appears somewhere", "DESIGN.md exists". A ceiling with no floor certifies mediocrity — a
  # fixture with ONE 16px size for h1/h2/h3/p/span/label/td, all-caps body copy at max-width:none, nine
  # competing accent hues and 4px tap targets satisfied every one of the five and earned the message
  # "Apple-grade craft floors met (type scale · 4pt grid · tokens · motion · design system)". A single size
  # passes the type-scale check MORE easily than a good 7-step ramp. These five checks add the missing floor
  # and are pinned by the mediocre() negative-control fixture in the selftest.
  local blob
  blob="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 cat 2>/dev/null)"

  # OVERRIDE BUDGET — every check above and below honours a per-line /* apple-ok */. Unlimited, that hatch
  # is the gate: nine suppressions rescued a build from the spacing floor with no record anywhere. Count
  # them, report them as debt, and fail past the budget so suppression has a ceiling.
  OKCOUNT="$(printf '%s\n' "$blob" | grep -ciE 'apple-ok' || true)"
  [ "${OKCOUNT:-0}" -gt "$MAX_OK" ] && add_finding override-budget "$OKCOUNT per-line /* apple-ok */ suppression(s) exceed the budget of $MAX_OK — a craft floor suppressed line by line is not a craft floor. Fix the styles or raise the budget deliberately via WALTEUR_APPLE_OK_MAX (recorded)."

  # 6. TYPE HIERARCHY (the FLOOR, inverse of check 1). A type ramp must have real contrast between its
  #    ends, or be carried by weight. One size for every element is the ABSENCE of hierarchy, not restraint.
  local tprobe steps smin smax weights tdecls
  tprobe="$(printf '%s\n' "$blob" | perl -ne '
    next if /apple-ok/i;
    while (/font-size\s*:\s*([0-9]*\.?[0-9]+)\s*(px|rem|em|pt)/gi) {
      my ($n,$u)=($1,lc $2); $D++;
      $n=$n*16 if $u eq "rem" || $u eq "em"; $n=$n*4/3 if $u eq "pt";
      $S{sprintf("%.1f",$n)}=1 if $n>0;
    }
    while (/\btext-(xs|sm|base|lg|xl|[2-9]xl)\b/gi) {
      my %tw=(xs=>12,sm=>14,base=>16,lg=>18,xl=>20,"2xl"=>24,"3xl"=>30,"4xl"=>36,"5xl"=>48,"6xl"=>60,"7xl"=>72,"8xl"=>96,"9xl"=>128);
      my $k=lc $1; if (exists $tw{$k}) { $D++; $S{sprintf("%.1f",$tw{$k})}=1; }
    }
    while (/font-weight\s*:\s*([0-9]{3}|bold|bolder|semibold|medium|normal|light)/gi) { $W{lc $1}=1 }
    while (/\bfont-(thin|extralight|light|normal|medium|semibold|bold|extrabold|black)\b/gi) { $W{lc $1}=1 }
    END { my @k = sort { $a <=> $b } keys %S;
          printf "%d %s %s %d %d\n", scalar(@k), (@k?$k[0]:0), (@k?$k[-1]:0), scalar(keys %W), ($D||0); }
  ' 2>/dev/null)"
  steps="$(printf '%s' "$tprobe" | awk '{print $1+0}')"; smin="$(printf '%s' "$tprobe" | awk '{print $2+0}')"
  smax="$(printf '%s' "$tprobe" | awk '{print $3+0}')"; weights="$(printf '%s' "$tprobe" | awk '{print $4+0}')"
  tdecls="$(printf '%s' "$tprobe" | awk '{print $5+0}')"
  # Only judge a ramp when there is enough evidence to judge (>=3 size declarations); a Tailwind app that
  # declares none is not silently failed here, it simply has nothing for this check to measure.
  if [ "${tdecls:-0}" -ge 3 ] && [ "$(awk -v s="${steps:-0}" -v a="${smax:-0}" -v b="${smin:-0}" -v w="${weights:-0}" \
       'BEGIN{print (s<2 || (b>0 && a/b < 1.5 && w < 2)) ? 1 : 0}')" = "1" ]; then
    add_finding type-hierarchy "type ramp has NO hierarchy: ${steps} distinct size(s) spanning ${smin}px..${smax}px with ${weights} distinct weight(s) across ${tdecls} declaration(s) — Apple-grade type needs a real ramp (largest/smallest >= 1.5x, or >=2 weights). One size for every element is not restraint, it is missing hierarchy."
  fi

  # 7-9. Rule-walker: all-caps body copy, unbounded reading measure, sub-minimum tap targets.
  local rprobe caps unbound tapbad tapworst textsel measure
  rprobe="$(printf '%s\n' "$blob" | perl -0777 -ne '
    my $c=$_; $c =~ s{/\*.*?\*/}{}gs;
    my ($textsel,$measure)=(0,0);
    for my $chunk (split /\}/, $c) {
      next unless $chunk =~ /^(.*?)\{(.*)$/s;
      my ($sel,$body)=($1,$2);
      $sel =~ s/.*\{//s; $sel =~ s/\A\s+|\s+\z//g; $sel =~ s/\s+/ /g;
      next if $sel eq "" || $sel =~ /^\@/ || $sel eq ":root";
      next if $body =~ /apple-ok/i || $sel =~ /apple-ok/i;
      my $is_text = ($sel =~ /(^|[\s,>+~])(body|p|li|dd|td|article|blockquote|main|section)(\s|,|:|$)/i)
                 || ($sel =~ /\.(body|prose|copy|text|paragraph|content|measure)\b/i);
      my $is_tap  = ($sel =~ /(button|\bbtn\b|\btap\b|\binput\b|\bselect\b|textarea|role="?button|\bicon-btn\b|\bchip\b|\bpill\b|\btab\b)/i);
      $textsel = 1 if $is_text && $body =~ /font-size|line-height|text-transform/i;
      if ($body =~ /max-width\s*:\s*([^;]+)/i) {
        my $mw=$1;
        if ($mw =~ /\bnone\b/i) { print "UNBOUND $sel\n" if $is_text }
        elsif ($mw =~ /[0-9]/) { $measure=1 }
      }
      print "CAPS $sel\n" if $is_text && $body =~ /text-transform\s*:\s*uppercase/i;
      if ($is_tap) {
        my $h;
        while ($body =~ /(?:min-height|height|min-block-size)\s*:\s*([^;]+)/gi) {
          my $v=$1; if ($v =~ /([0-9]*\.?[0-9]+)\s*px/) { my $x=$1; $h=$x if !defined $h || $x>$h } }
        if (!defined $h) {
          my ($t,$b);
          if ($body =~ /(?:^|[\s;])padding(?:-block)?\s*:\s*([^;]+)/i) {
            my @v = ($1 =~ /(-?[0-9]*\.?[0-9]+)\s*px/g);
            if (@v==1 || @v==2) { ($t,$b)=($v[0],$v[0]) } elsif (@v>=3) { ($t,$b)=($v[0],$v[2]) } }
          if ($body =~ /padding-top\s*:\s*([0-9]*\.?[0-9]+)\s*px/i) { $t=$1 }
          if ($body =~ /padding-bottom\s*:\s*([0-9]*\.?[0-9]+)\s*px/i) { $b=$1 }
          $h = $t + $b + 20 if defined $t && defined $b;   # +20 for a 16px line box
        }
        printf("TAP %s %.0f\n",$sel,$h) if defined $h;
      }
    }
    # A measure bound can also come from utility classes or a token, not only a CSS rule.
    $measure=1 if $c =~ /\bmax-w-(prose|screen-|xs|sm|md|lg|xl|[2-7]xl|\[)/ || $c =~ /max-width\s*:\s*[^;]*\bch\b/ || $c =~ /--[a-z-]*measure/i;
    print "TEXTSEL\n" if $textsel; print "MEASURE\n" if $measure;
  ' 2>/dev/null)"
  caps="$(printf '%s\n' "$rprobe" | grep -c '^CAPS ' || true)"
  unbound="$(printf '%s\n' "$rprobe" | grep -c '^UNBOUND ' || true)"
  tapbad="$(printf '%s\n' "$rprobe" | awk '$1=="TAP" && $3+0 < 32 {c++} END{print c+0}')"
  tapworst="$(printf '%s\n' "$rprobe" | awk '$1=="TAP" && $3+0 < 32 {print $2" ("$3"px)"}' | head -3 | tr '\n' ' ')"
  textsel="$(printf '%s\n' "$rprobe" | grep -c '^TEXTSEL$' || true)"
  measure="$(printf '%s\n' "$rprobe" | grep -c '^MEASURE$' || true)"

  # 7. ALL-CAPS BODY COPY — uppercase destroys word shape and slows reading. Apple sets body copy in
  #    sentence case; all-caps is for a caption or a single control label, never a paragraph.
  [ "${caps:-0}" -gt 0 ] && add_finding legibility-caps "$caps body-text selector(s) set text-transform:uppercase — all-caps body copy removes word-shape cues and is unreadable at length. Reserve caps for short labels; set paragraphs in sentence case."

  # 8. BOUNDED READING MEASURE — a line longer than ~80 characters loses the reader on the return sweep.
  if [ "${unbound:-0}" -gt 0 ]; then
    add_finding measure "$unbound text selector(s) declare max-width:none — an unbounded measure means full-viewport line lengths. Bound body copy to a 45-80ch measure."
  elif [ "${textsel:-0}" -gt 0 ] && [ "${measure:-0}" -eq 0 ]; then
    add_finding measure "body text is styled but NO reading measure is bounded anywhere (no max-width / max-w-* / ch measure token) — lines will run the full viewport width. Bound body copy to 45-80ch."
  fi

  # 9. TAP TARGETS — Apple's HIG minimum is 44x44pt. The hard floor here is 32px of vertical extent
  #    (declared height/min-height, else vertical padding + a 20px line box); below that the control is
  #    unmissably too small to hit. 32 rather than 44 keeps the fail-closed floor free of false positives
  #    on the common 36px control height, while the message states the real 44pt bar.
  [ "${tapbad:-0}" -gt 0 ] && add_finding tap-target "$tapbad interactive selector(s) below a 32px vertical extent: ${tapworst}— Apple's HIG minimum is 44x44pt. Raise padding or set min-height:44px on controls."

  # 10. ACCENT RESTRAINT — count distinct SATURATED HUE FAMILIES (30-degree buckets) across every color
  #     literal, including custom-property definitions that check 3's property-anchored grep cannot see
  #     (--c1:#2563eb has no color: prefix). Apple-grade means one accent plus neutrals; a rainbow of
  #     competing accents is the absence of a decision.
  local hues MAX_HUES; MAX_HUES="${WALTEUR_APPLE_ACCENTS:-5}"
  hues="$(printf '%s\n' "$blob" | perl -ne '
    sub bkt { my ($r,$g,$b)=@_;
      my $mx=$r; $mx=$g if $g>$mx; $mx=$b if $b>$mx;
      my $mn=$r; $mn=$g if $g<$mn; $mn=$b if $b<$mn;
      my $c=$mx-$mn; return if $c<40;
      my $t; if ($mx==$r){$t=($g-$b)/$c} elsif($mx==$g){$t=(($b-$r)/$c)+2} else {$t=(($r-$g)/$c)+4}
      $t+=6 while $t<0; $t-=6 while $t>=6; $H{int($t*2)}=1; }
    next if /apple-ok/i;
    while (/#([0-9a-fA-F]{6})\b/g) { my $x=$1; bkt(hex(substr($x,0,2)),hex(substr($x,2,2)),hex(substr($x,4,2))); }
    while (/#([0-9a-fA-F]{3})\b/g) { my $x=$1; bkt(17*hex(substr($x,0,1)),17*hex(substr($x,1,1)),17*hex(substr($x,2,1))); }
    while (/\brgba?\(\s*([0-9]{1,3})[,\s]+([0-9]{1,3})[,\s]+([0-9]{1,3})/gi) { bkt($1,$2,$3); }
    while (/\bhsla?\(\s*([0-9]*\.?[0-9]+)(?:deg)?[,\s]+([0-9]*\.?[0-9]+)%/gi) {
      my ($h,$s)=($1,$2); next if $s<25; $h+=360 while $h<0; $h-=360 while $h>=360; $H{int($h/30)}=1; }
    END { printf "%d\n", scalar(keys %H); }
  ' 2>/dev/null)"
  [ "${hues:-0}" -gt "$MAX_HUES" ] && add_finding accent-restraint "${hues} distinct saturated hue families in the palette (max $MAX_HUES) — Apple-grade UIs use ONE accent plus neutrals. Competing accents mean nothing reads as primary; collapse to a single accent and a neutral ramp."

  local rt uf; rt="$(risk)"; uf="no"; is_user_facing && uf="yes"
  if [ "$failures" -gt 0 ]; then
    if [ "$rt" = "high" ] || [ "$rt" = "regulated" ] || [ "${WALTEUR_APPLE_STRICT:-}" = "on" ] || [ "$uf" = "yes" ]; then
      write_report FAIL "$failures Apple-grade craft floor(s) unmet (risk=$rt, user_facing=$uf)"
      echo "apple-grade-design-gate: FAIL ($failures craft floors unmet, risk=$rt, user_facing=$uf) -> exit 2"
      printf '%s\n' "$findings" | jq -r '.[] | "  - " + .check + ": " + .message' 2>/dev/null | head -10 || true
      exit 2
    fi
    write_report PASS "advisory: $failures craft note(s) at risk=$rt, non-user-facing (raise with WALTEUR_APPLE_STRICT=on)"
    echo "apple-grade-design-gate: PASS (advisory — $failures craft note(s), risk=$rt, non-user-facing)"
    printf '%s\n' "$findings" | jq -r '.[] | "  ~ " + .check + ": " + .message' 2>/dev/null | head -10 || true
    exit 0
  fi
  write_report PASS "Apple-grade craft floors met (type scale · 4pt grid · tokens · motion · design system)"
  echo "apple-grade-design-gate: PASS (Apple-grade craft floors met)"
  exit 0
}

selftest() {
  pass=0; fail=0
  if ! have jq || ! have perl; then echo "apple-grade selftest SKIP - need jq+perl."; return 0; fi
  echo "apple-grade-design-gate selftest:"
  ck() { if [ "$2" = "$3" ]; then echo "  ok   - $1 (rc=$3)"; pass=$((pass+1)); else echo "  FAIL - $1 (want $2 got $3)"; fail=$((fail+1)); fi; }
  run() { WALTEUR_ROOT="$1" bash "$SELF" >/dev/null 2>&1; echo $?; }   # rc captured directly, never after a pipe
  seed() { mkdir -p "$1/walteur-kit" "$1/src"; printf '{"risk_tier":"%s"}\n' "${2:-high}" > "$1/walteur-kit/build-contract.json"; printf '{"has_ui":true,"is_user_facing":true}\n' > "$1/walteur-kit/preflight-signals.json"; }
  # S033: non-user-facing fixture — has_ui true (so `applies()` still runs the craft checks: has_ui() OR'd
  # with is_user_facing at line 38) but is_user_facing explicitly false AND build-contract carries no ui
  # interface either, so is_user_facing() returns false and the FAIL-CLOSED escalation does not fire.
  seed_internal() { mkdir -p "$1/walteur-kit" "$1/src"; printf '{"risk_tier":"%s"}\n' "${2:-medium}" > "$1/walteur-kit/build-contract.json"; printf '{"has_ui":true,"is_user_facing":false}\n' > "$1/walteur-kit/preflight-signals.json"; }
  cleancss() { cat > "$1/src/app.css" <<'CSS'
:root{ --color-bg: hsl(0 0% 100%); --color-fg: hsl(222 47% 11%); --space-2: 8px; --radius: 12px; }
body{ font-size:16px; color:var(--color-fg); background:var(--color-bg); }
h1{ font-size:32px; } h2{ font-size:24px; } small{ font-size:14px; }
.btn{ padding:8px 16px; margin:16px; gap:8px; border-radius:var(--radius); transition: background .15s ease; }
.card{ padding:24px; gap:12px; }
.prose p{ max-width:68ch; }
CSS
    printf '# Design\nType scale, semantic tokens, 8pt grid, snappy motion.\n' > "$1/DESIGN.md"; }

  # ── NEGATIVE CONTROL (Panel #12): TASTELESS BUT TELL-FREE. No gradient text, no purple glow, no lorem,
  # no emoji, no slop signature of any kind — and no design either: ONE 16px size for h1/h2/h3/p/span/label/
  # td, all-caps body copy at max-width:none, nine competing accent hues held in tokens (so the raw-hex grep
  # cannot see them), 4px tap targets, four nested cards. This fixture passed all five original checks with
  # "Apple-grade craft floors met". It is now a permanent selftest case: every craft floor below must bite it.
  mediocre() { cat > "$1/src/app.css" <<'CSS'
:root{
  --c1:#2563eb; --c2:#dc2626; --c3:#16a34a; --c4:#f59e0b; --c5:#7c3aed;
  --c6:#0891b2; --c7:#db2777; --c8:#65a30d; --c9:#ea580c; --space-1:4px; --space-2:8px;
}
body{ font-size:16px; color:#a9a9a9; text-transform:uppercase; }
h1{ font-size:16px; text-transform:uppercase; }
h2{ font-size:16px; }
h3{ font-size:16px; }
p{ font-size:16px; text-transform:uppercase; max-width:none; }
span{ font-size:16px; } label{ font-size:16px; } td{ font-size:16px; }
.card{ padding:12px; border-radius:3px; background:var(--c2); }
.card .card{ padding:8px; border-radius:11px; background:var(--c3); }
.card .card .card{ padding:16px; border-radius:7px; background:var(--c4); }
.card .card .card .card{ padding:24px; border-radius:19px; background:var(--c5); }
.btn{ padding:4px; gap:4px; color:var(--c6); transition: opacity 400ms linear; }
.tap{ padding:4px; min-height:16px; color:var(--c7); }
.link{ color:var(--c8); } .badge{ color:var(--c9); }
CSS
    printf '# Design\nType: single size 16px uppercase everywhere.\nColor: nine accents.\nDonts: none.\n' > "$1/DESIGN.md"; }

  # 1. no UI -> NA
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; mkdir -p "$t/walteur-kit"; printf '{"has_ui":false}\n' > "$t/walteur-kit/preflight-signals.json"; ck "no UI -> NA" 0 "$(run "$t")"; rm -rf "$t"
  # 2. clean Apple-grade CSS -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed "$t"; cleancss "$t"; ck "clean Apple-grade UI -> PASS" 0 "$(run "$t")"; rm -rf "$t"
  # 3. G1 loose type scale (>8 distinct sizes) -> FAIL (high risk)
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed "$t" high; cleancss "$t"; { for s in 9 10 11 13 15 17 19 21 27 33 41; do echo ".f$s{font-size:${s}px;}"; done; } >> "$t/src/app.css"; ck "G1 loose type scale -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 4. G2 off-grid spacing -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed "$t" high; cleancss "$t"; { for s in 3 7 13 17 23 27 33 37 41; do echo ".p$s{padding:${s}px;}"; done; } >> "$t/src/app.css"; ck "G2 off-grid spacing -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 5. G3 no DESIGN.md + raw hex + no motion -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed "$t" high; printf 'h1{font-size:32px;}\n.a{color:#ff0055;}.b{background:#1a1a2e;}.c{border-color:#16213e;}.d{color:#0f3460;}.e{color:#e94560;}.f{color:#222;}.g{color:#333;}\n' > "$t/src/app.css"; ck "G3 no design system + raw hex + no motion -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 6. FP guard: clean UI, NON-user-facing (internal tool), LOW risk, one craft note -> PASS (advisory)
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed_internal "$t" low; cleancss "$t"; rm -f "$t/DESIGN.md"; ck "G4 non-user-facing low-risk one-note -> PASS (advisory)" 0 "$(run "$t")"; rm -rf "$t"
  # 7. FP guard: apple-ok override on off-grid spacing -> PASS. Panel #12: the override is now BUDGETED
  #    (WALTEUR_APPLE_OK_MAX, default 8), so this case demonstrates a rescue WITHIN budget — three
  #    suppressions against a deliberately tightened off-grid threshold. Case 15 below pins the ceiling.
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed "$t" high; cleancss "$t"; { for s in 3 7 13; do echo ".p$s{padding:${s}px;} /* apple-ok */"; done; } >> "$t/src/app.css"; ck "G5 apple-ok override (3, within budget) -> PASS" 0 "$(WALTEUR_APPLE_OFFGRID=2 run "$t")"; rm -rf "$t"
  # 8. bypass + PAUSED
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed "$t" high; printf 'h1{font-size:1px;}\n' > "$t/src/app.css"; WALTEUR_ROOT="$t" WALTEUR_APPLE=off bash "$SELF" >/dev/null 2>&1; ck "bypass -> exit 0" 0 "$?"; rm -rf "$t"
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed "$t" high; cleancss "$t"; touch "$t/walteur-kit/PAUSED"; ck "PAUSED -> exit 2" 2 "$(run "$t")"; rm -rf "$t"

  # ── S033 candidate C4: escalate craft floors to fail-closed for user-facing builds ──
  # 9. BEFORE/AFTER flip: medium-risk + is_user_facing:true + loose type scale -> FAIL (was advisory PASS pre-S033)
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed_internal "$t" medium; printf '{"has_ui":true,"is_user_facing":true}\n' > "$t/walteur-kit/preflight-signals.json"; cleancss "$t"; { for s in 9 10 11 13 15 17 19 21 27 33 41; do echo ".f$s{font-size:${s}px;}"; done; } >> "$t/src/app.css"; ck "C4 medium-risk + is_user_facing:true + loose type scale -> FAIL (fail-closed flip)" 2 "$(run "$t")"; rm -rf "$t"
  # 10. FP guard (negative control for the flip): same CSS, medium-risk, NON-user-facing -> PASS (advisory)
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed_internal "$t" medium; cleancss "$t"; { for s in 9 10 11 13 15 17 19 21 27 33 41; do echo ".f$s{font-size:${s}px;}"; done; } >> "$t/src/app.css"; ck "C4 medium-risk + non-user-facing + same loose type scale -> PASS (advisory, FP guard)" 0 "$(run "$t")"; rm -rf "$t"
  # 11. LOW risk + is_user_facing:true still escalates (not just medium) -> FAIL
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed_internal "$t" low; printf '{"has_ui":true,"is_user_facing":true}\n' > "$t/walteur-kit/preflight-signals.json"; printf 'h1{font-size:32px;}\n.a{color:#ff0055;}.b{background:#1a1a2e;}.c{border-color:#16213e;}.d{color:#0f3460;}.e{color:#e94560;}.f{color:#222;}.g{color:#333;}\n' > "$t/src/app.css"; ck "C4 low-risk + is_user_facing:true + no design system -> FAIL" 2 "$(run "$t")"; rm -rf "$t"
  # 12. apple-ok override still rescues a user-facing build (escape hatch preserved) -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed_internal "$t" medium; printf '{"has_ui":true,"is_user_facing":true}\n' > "$t/walteur-kit/preflight-signals.json"; cleancss "$t"; { for s in 3 7 13; do echo ".p$s{padding:${s}px;} /* apple-ok */"; done; } >> "$t/src/app.css"; ck "C4 user-facing + apple-ok override (within budget) -> PASS (escape hatch preserved)" 0 "$(WALTEUR_APPLE_OFFGRID=2 run "$t")"; rm -rf "$t"
  # 13. WALTEUR_APPLE=off bypass still wins over is_user_facing escalation -> PASS
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed_internal "$t" medium; printf '{"has_ui":true,"is_user_facing":true}\n' > "$t/walteur-kit/preflight-signals.json"; printf 'h1{font-size:1px;}\n' > "$t/src/app.css"; WALTEUR_ROOT="$t" WALTEUR_APPLE=off bash "$SELF" >/dev/null 2>&1; ck "C4 user-facing + WALTEUR_APPLE=off -> PASS (bypass still wins)" 0 "$?"; rm -rf "$t"

  # ── Panel #12 refutation regression: the tell-free mediocre fixture. BEFORE checks 6-10 this returned
  # rc=0 with verdict PASS / "Apple-grade craft floors met" and findings:[]. Each sub-assertion pins ONE
  # craft floor so a future edit that guts any single check fails loudly instead of quietly re-certifying.
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed "$t" medium; mediocre "$t"
  ck "NEGATIVE CONTROL: tasteless-but-tell-free UI -> FAIL (was PASS pre-panel-12)" 2 "$(run "$t")"
  # NO PIPE into grep -q here. `grep -q` exits on the FIRST match, which SIGPIPEs the producer; under
  # `set -o pipefail` that non-zero producer status becomes the pipeline's status and the assertion reads
  # FALSE even though grep matched. It bit exactly one check — the one whose name is the first line of
  # output — which is how a real harness bug hides. Read into a variable, match with a herestring.
  chk_finding() { local L; L="$(jq -r '.findings[].check' "$t/walteur-kit/apple-grade-report.json" 2>/dev/null)"
    if grep -q "^$1\$" <<<"$L"; then echo "  ok   - mediocre fixture trips the $1 floor"; pass=$((pass+1));
    else echo "  FAIL - mediocre fixture does NOT trip the $1 floor"; fail=$((fail+1)); fi; }
  chk_finding type-hierarchy      # one 16px size for every element
  chk_finding legibility-caps     # all-caps body copy
  chk_finding measure             # max-width:none on <p>
  chk_finding tap-target          # 4px padding / 16px min-height controls
  chk_finding accent-restraint    # nine competing accent hues, hidden in custom properties
  rm -rf "$t"
  # 15. OVERRIDE BUDGET (panel #12): the same nine per-line suppressions that used to rescue a user-facing
  #     build for free now blow the budget and become their own finding. The hatch still exists; it is no
  #     longer unlimited, and the count is recorded in the report either way.
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed "$t" high; cleancss "$t"
  { for s in 3 7 13 17 23 27 33 37 41; do echo ".p$s{padding:${s}px;} /* apple-ok */"; done; } >> "$t/src/app.css"
  ck "9 apple-ok suppressions exceed the budget -> FAIL (was a free PASS pre-panel-12)" 2 "$(run "$t")"
  ck "the report records the override count as debt" 9 "$(jq -r '.apple_ok_overrides' "$t/walteur-kit/apple-grade-report.json" 2>/dev/null)"
  ck "raising the budget deliberately is allowed and recorded -> PASS" 0 "$(WALTEUR_APPLE_OK_MAX=12 run "$t")"
  rm -rf "$t"
  # 16. WALTEUR_APPLE=off is recorded as DEBT, not as a clean result.
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed "$t" high; printf 'h1{font-size:1px;}\n' > "$t/src/app.css"
  WALTEUR_ROOT="$t" WALTEUR_APPLE=off bash "$SELF" >/dev/null 2>&1
  ck "bypass report carries bypassed:true" "true" "$(jq -r '.bypassed' "$t/walteur-kit/apple-grade-report.json" 2>/dev/null)"
  ck "bypass report carries an explicit debt string" 0 "$(jq -e '.debt|test("UNVERIFIED")' "$t/walteur-kit/apple-grade-report.json" >/dev/null 2>&1; echo $?)"
  rm -rf "$t"
  # FP guard for the new floors: a GOOD ramp with only two sizes but two weights is hierarchy, not slop.
  t="$(mktemp -d "${TMPDIR:-/tmp}/applegrade.XXXXXX")"; seed "$t" high; cleancss "$t"
  printf 'body{font-weight:400;} h1{font-weight:600;} h2{font-weight:600;}\n.big{min-height:44px;padding:12px 20px;}\n' >> "$t/src/app.css"
  ck "FP guard: real ramp + weights + 44px control -> PASS" 0 "$(run "$t")"; rm -rf "$t"

  echo "apple-grade-design-gate selftest: $((pass))/$((pass+fail)) passed"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) main "$@" ;;
esac
