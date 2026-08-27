#!/usr/bin/env bash
# WALTEUR design-contrast-gate (B64) — WCAG 2.1 computed relative-luminance contrast checker.
# Built + adversarially verified via workflow wf_db09db51-fb9 (2 independent impls -> known-answer judge:
# 21.00 / 1.00 / 4.48 / 4.54 / 8.59 all exact; #949494=3.03 exact, judge caught the 3.00 reference was loose).
# Pure bash + awk (jq for manifest parsing). No python/node/bc.
# `pipefail` matters here: this gate reads manifests through jq|awk pipelines, and without it
# a failing producer (bad jq exit) is masked by a successful consumer and the gate reads green
# on data it never actually parsed. 178 of the other hooks already set it; this is the norm.
set -uo pipefail

WALTEUR_ROOT="${WALTEUR_ROOT:-$(pwd)}"
MANIFEST_REL="walteur-kit/contrast-pairs.json"
REPORT_REL="walteur-kit/design-contrast-report.json"

# color_to_rgb (B65): parse a CSS color in hex (#rgb/#rrggbb), hsl(H S% L% | H,S%,L%), or
# rgb(R G B | R,G,B) into "R G B" (0-255). hsl->rgb math verified against Python colorsys (16/16, all
# hue sectors + grays + Cadence tokens, +-1 rounding). Returns 1 on an unparseable color.
color_to_rgb() {
  local c; c="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:]]}"}"
  case "$c" in
    '#'*)
      local h="${c#\#}"
      if [[ "$h" =~ ^[0-9a-f]{3}$ ]]; then h="${h:0:1}${h:0:1}${h:1:1}${h:1:1}${h:2:1}${h:2:1}"; fi
      [[ "$h" =~ ^[0-9a-f]{6}$ ]] || return 1
      printf '%d %d %d' "$((16#${h:0:2}))" "$((16#${h:2:2}))" "$((16#${h:4:2}))" ;;
    hsl\(*)
      local body="${c#hsl(}"; body="${body%)}"; body="${body//,/ }"; body="${body//%/ }"
      set -- $body; [ -n "${3:-}" ] || return 1
      awk -v h="$1" -v s="$2" -v l="$3" 'BEGIN{
        s/=100; l/=100;
        cc=(1-(2*l-1<0?-(2*l-1):(2*l-1)))*s; hp=h/60; mod=hp-2*int(hp/2);
        x=cc*(1-(mod-1<0?-(mod-1):(mod-1))); m=l-cc/2;
        if(hp<1){r=cc;g=x;b=0}else if(hp<2){r=x;g=cc;b=0}else if(hp<3){r=0;g=cc;b=x}
        else if(hp<4){r=0;g=x;b=cc}else if(hp<5){r=x;g=0;b=cc}else{r=cc;g=0;b=x}
        printf "%d %d %d", int((r+m)*255+0.5),int((g+m)*255+0.5),int((b+m)*255+0.5) }' ;;
    rgb\(*)
      local body="${c#rgb(}"; body="${body%)}"; body="${body//,/ }"; set -- $body
      [ -n "${3:-}" ] || return 1; printf '%d %d %d' "$1" "$2" "$3" ;;
    *) return 1 ;;
  esac
}

contrast_ratio() {
  local fg bg
  fg="$(color_to_rgb "$1")" || return 1
  bg="$(color_to_rgb "$2")" || return 1
  set -- $fg
  local fr=$1 fgn=$2 fb=$3
  set -- $bg
  local br=$1 bgn=$2 bb=$3
  awk -v fr="$fr" -v fg="$fgn" -v fb="$fb" -v br="$br" -v bg="$bgn" -v bb="$bb" 'BEGIN{
    print sprintf("%.2f", ratio(lum(fr,fg,fb), lum(br,bg,bb)));
  }
  function chan(c,   cs){ cs=c/255.0; if(cs<=0.03928){return cs/12.92} return ((cs+0.055)/1.055)^2.4 }
  function lum(r,g,b){ return 0.2126*chan(r)+0.7152*chan(g)+0.0722*chan(b) }
  function ratio(l1,l2,   hi,lo){ hi=(l1>l2)?l1:l2; lo=(l1>l2)?l2:l1; return (hi+0.05)/(lo+0.05) }'
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# B70 - manifest<->CSS drift guard (panel-10 evidence-integrity gap): every declared color must ACTUALLY appear
# in the project CSS, so a manifest cannot claim fake passing colors while the stylesheet ships failing ones.
# Uses the SAME color_to_rgb, RGB-normalized with +-1 tolerance (hsl/hex/shorthand differences do not false-FAIL).
# Only active when CSS files exist (a manifest-only project skips it - honest, nothing to cross-check).
css_rgbset() {
  local root="$1"
  local files; files="$(find "$root" \( -path '*/node_modules/*' -o -path '*/walteur-kit/*' -o -path '*/dist/*' -o -path '*/build/*' \) -prune -o \( -name '*.css' -o -name '*.scss' -o -name '*.sass' \) -print 2>/dev/null)"
  [ -z "$files" ] && return 0
  printf '%s\n' "$files" | while IFS= read -r f; do
    [ -f "$f" ] && grep -hoiE '#[0-9a-fA-F]{3,8}|hsl\([^)]*\)|rgb\([^)]*\)' "$f" 2>/dev/null
  done | while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    local rgb; rgb="$(color_to_rgb "$tok" 2>/dev/null)" && [ -n "$rgb" ] && printf '%s\n' "$rgb"
  done | sort -u
}
rgb_in_set() {
  local r g b; read -r r g b <<<"$1"; [ -z "${b:-}" ] && return 1
  local cr cg cb
  while IFS=' ' read -r cr cg cb; do
    [ -n "${cb:-}" ] || continue
    local dr=$(( r>cr ? r-cr : cr-r )) dg=$(( g>cg ? g-cg : cg-g )) db=$(( b>cb ? b-cb : cb-b ))
    [ "$dr" -le 1 ] && [ "$dg" -le 1 ] && [ "$db" -le 1 ] && return 0
  done <<<"$2"
  return 1
}

# ── PANEL #12 REFUTATION FIX: judge the SHIPPED numbers, not only the declared ones ────────────────────
# Until now this gate read pairs exclusively from walteur-kit/contrast-pairs.json. On a fixture whose CSS
# shipped `body{color:#a9a9a9;background:var(--c1)}` the gate returned FAIL for "ui-source-without-manifest"
# — it never looked at, let alone computed, the sub-threshold gray it was staring at. A contrast gate whose
# input is a hand-written manifest measures the author's honesty, not the interface.
#
# derive_pairs emits one TAB-separated "selector<TAB>fg<TAB>bg<TAB>large" line per pair the stylesheet
# ACTUALLY declares: same-rule color+background (highest confidence), else a text selector against the
# page background declared on html/body/:root. var(--token) references resolve through the custom
# properties (up to 4 hops) so a token indirection cannot hide a color. Rules that WCAG exempts
# (:disabled, ::placeholder, .disabled, aria-disabled) are skipped; gradients, transparent, currentColor
# and inherit are unresolvable and therefore not guessed at.
derive_pairs() {
  local root="$1" files
  files="$(find "$root" \( -path '*/node_modules/*' -o -path '*/walteur-kit/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/.git/*' \) -prune -o \( -name '*.css' -o -name '*.scss' -o -name '*.sass' \) -print 2>/dev/null)"
  [ -z "$files" ] && return 0
  printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 cat 2>/dev/null | perl -0777 -ne '
    my $c = $_; $c =~ s{/\*.*?\*/}{}gs;
    my %V;
    while ($c =~ /(--[A-Za-z0-9_-]+)\s*:\s*([^;{}]+)/g) {
      my ($k,$v)=($1,$2); $v =~ s/\A\s+|\s+\z//g; $V{$k}=$v unless exists $V{$k}; }
    sub resolve { my $v=shift;
      for (1..4) { last unless $v =~ /var\(\s*(--[A-Za-z0-9_-]+)/; my $k=$1;
        return undef unless exists $V{$k}; my $r=$V{$k};
        $v =~ s/var\(\s*\Q$k\E\s*(?:,[^)]*)?\)/$r/; }
      $v =~ s/\A\s+|\s+\z//g;
      return ($v =~ /^(?:\#[0-9a-fA-F]{3,8}|rgba?\([^)]*\)|hsla?\([^)]*\))$/) ? $v : undef; }
    my ($pagebg, @rules);
    for my $chunk (split /\}/, $c) {
      next unless $chunk =~ /^(.*?)\{(.*)$/s;
      my ($sel,$body)=($1,$2); $sel =~ s/.*\{//s; $sel =~ s/\A\s+|\s+\z//g; $sel =~ s/\s+/ /g;
      next if $sel eq "" || $sel =~ /^\@/;
      my ($fg,$bg);
      $fg = $1 if $body =~ /(?:^|[\s;])color\s*:\s*([^;]+)/i;
      $bg = $1 if $body =~ /(?:^|[\s;])background(?:-color)?\s*:\s*([^;]+)/i;
      $fg = defined $fg ? resolve($fg) : undef;
      $bg = defined $bg ? resolve($bg) : undef;
      $pagebg = $bg if defined $bg && ($sel =~ /(^|[\s,])(html|body)(\s|,|$)/i || $sel eq ":root");
      my $fs; $fs = $1 if $body =~ /font-size\s*:\s*([0-9]*\.?[0-9]+)\s*px/i;
      my $fw; $fw = $1 if $body =~ /font-weight\s*:\s*([0-9]{3}|bold)/i;
      push @rules, [$sel,$fg,$bg,$fs,$fw];
    }
    for my $r (@rules) {
      my ($sel,$fg,$bg,$fs,$fw) = @$r;
      next unless defined $fg;
      next if $sel =~ /:disabled|::placeholder|\.disabled|aria-disabled/i;
      my $b = defined $bg ? $bg : $pagebg;
      next unless defined $b;
      $fw = 400 unless defined $fw; $fw = 700 if $fw eq "bold";
      my $large = (defined $fs && ($fs >= 24 || ($fs >= 18.66 && $fw >= 700))) ? "true" : "false";
      print "$sel\t$fg\t$b\t$large\n";
    }
  ' 2>/dev/null | sort -u
  # sort -u: the same (selector, fg, bg) triple declared in two stylesheets (e.g. a source file and its
  # built copy) is ONE defect, and counting it twice would overstate the finding. Nothing is hidden —
  # a distinct selector or a distinct color pair is a distinct line.
}

# Echo "<n_failing>|<json-array-of-failing-pairs>" for the CSS-derived arm. Never guesses: a pair whose
# colors this gate cannot parse is simply not emitted by derive_pairs.
derived_failures() {
  local root="$1" n=0 json="" sel fg bg large floor ratio
  while IFS="$(printf '\t')" read -r sel fg bg large; do
    [ -n "${sel:-}" ] && [ -n "${bg:-}" ] || continue
    if [ "$large" = "true" ]; then floor="3.0"; else floor="4.5"; fi
    ratio="$(contrast_ratio "$fg" "$bg" 2>/dev/null)" || continue
    [ -n "$ratio" ] || continue
    if ! awk -v r="$ratio" -v f="$floor" 'BEGIN{exit !(r+0 >= f+0)}'; then
      n=$((n+1))
      json+="${json:+,}{\"selector\":\"$(json_escape "$sel")\",\"fg\":\"$(json_escape "$fg")\",\"bg\":\"$(json_escape "$bg")\",\"ratio\":$ratio,\"floor\":$floor,\"source\":\"css-derived\"}"
    fi
  done <<EOF
$(derive_pairs "$root")
EOF
  printf '%s|[%s]\n' "$n" "$json"
}

run_gate() {
  local root="$1"
  local manifest="$root/$MANIFEST_REL"
  local report="$root/$REPORT_REL"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -f "$root/walteur-kit/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED)." >&2; exit 2; }
  if [ "${WALTEUR_DESIGN_CONTRAST:-on}" = "off" ]; then
    printf '{"verdict":"SKIP","ts":"%s","gate":"design-contrast","pairs":[],"reason":"WALTEUR_DESIGN_CONTRAST=off"}\n' "$ts" > "$report"
    echo "design-contrast: bypassed (WALTEUR_DESIGN_CONTRAST=off)."; exit 0
  fi

  if [[ ! -f "$manifest" ]]; then
    local hit
    hit="$(find "$root" \( -name '*.css' -o -name '*.scss' -o -name '*.sass' \) -print -quit 2>/dev/null)"
    if [[ -z "$hit" ]]; then
      mkdir -p "$(dirname "$report")"
      printf '{"verdict":"NOT_APPLICABLE","ts":"%s","gate":"design-contrast","pairs":[]}\n' "$ts" > "$report"
      echo "design-contrast: NOT_APPLICABLE (no manifest, no CSS/UI source)"
      return 0
    fi
    # Still no manifest -> still FAIL. But report the SHIPPED numbers too: "no manifest" was the only thing
    # this branch ever said, which is how a 2.3:1 body gray sat in the CSS unremarked. The derived arm names
    # the actual offending selectors so the failure is fixable rather than merely procedural.
    mkdir -p "$(dirname "$report")"
    local dres dn dj
    dres="$(derived_failures "$root")"; dn="${dres%%|*}"; dj="${dres#*|}"
    printf '{"verdict":"FAIL","ts":"%s","gate":"design-contrast","pairs":%s,"reason":"ui-source-without-manifest","css_derived_failures":%s}\n' \
      "$ts" "$dj" "${dn:-0}" > "$report"
    echo "design-contrast: FAIL (UI/CSS source present but no $MANIFEST_REL manifest; ${dn:-0} CSS-derived pair(s) below the WCAG floor)"
    [ "${dn:-0}" -gt 0 ] && printf '%s' "$dj" | { command -v jq >/dev/null 2>&1 && jq -r '.[]|"  css-derived "+.selector+": "+(.ratio|tostring)+":1 (floor "+(.floor|tostring)+", BELOW) fg="+.fg+" bg="+.bg' || cat; } 2>/dev/null
    return 2
  fi

  if ! command -v jq >/dev/null 2>&1; then
    if [[ "${WALTEUR_TOOLGATE_STRICT:-0}" == "1" ]]; then
      echo "design-contrast: FAIL (jq missing, STRICT/ship fail-closed)"
      return 2
    fi
    echo "design-contrast: SKIP (jq missing, off-ship loud-skip — contrast UNVERIFIED)"
    return 0
  fi

  if ! jq -e 'type=="object" and (.pairs|type=="array")' "$manifest" >/dev/null 2>&1; then
    printf '{"verdict":"FAIL","ts":"%s","gate":"design-contrast","pairs":[],"reason":"malformed-manifest"}\n' "$ts" > "$report"
    echo "design-contrast: FAIL (malformed manifest)"
    return 2
  fi

  local css_set; css_set="$(css_rgbset "$root")"
  local n; n="$(jq '.pairs|length' "$manifest")"
  local i verdict="PASS" rc=0
  local pairs_json=""
  for ((i=0; i<n; i++)); do
    local name fg bg large floor ratio pass
    name="$(jq -r ".pairs[$i].name // \"pair-$i\"" "$manifest")"
    fg="$(jq -r ".pairs[$i].fg // empty" "$manifest")"
    bg="$(jq -r ".pairs[$i].bg // empty" "$manifest")"
    large="$(jq -r ".pairs[$i].large // false" "$manifest")"
    if [[ -z "$fg" || -z "$bg" ]]; then
      printf '{"verdict":"FAIL","ts":"%s","gate":"design-contrast","pairs":[],"reason":"pair-missing-color"}\n' "$ts" > "$report"
      echo "design-contrast: FAIL (pair '$name' missing fg/bg)"
      return 2
    fi
    if [[ -n "$css_set" ]]; then
      local fgr bgr
      fgr="$(color_to_rgb "$fg" 2>/dev/null)"; bgr="$(color_to_rgb "$bg" 2>/dev/null)"
      if [[ -n "$fgr" ]] && ! rgb_in_set "$fgr" "$css_set"; then
        printf '{"verdict":"FAIL","ts":"%s","gate":"design-contrast","pairs":[],"reason":"manifest-css-drift","detail":"pair %s fg %s absent from project CSS"}\n' "$ts" "$name" "$fg" > "$report"
        echo "design-contrast: FAIL (pair '$name' fg $fg not present in CSS - decoupled/stale manifest)"
        return 2
      fi
      if [[ -n "$bgr" ]] && ! rgb_in_set "$bgr" "$css_set"; then
        printf '{"verdict":"FAIL","ts":"%s","gate":"design-contrast","pairs":[],"reason":"manifest-css-drift","detail":"pair %s bg %s absent from project CSS"}\n' "$ts" "$name" "$bg" > "$report"
        echo "design-contrast: FAIL (pair '$name' bg $bg not present in CSS - decoupled/stale manifest)"
        return 2
      fi
    fi
    if [[ "$large" == "true" ]]; then floor="3.0"; else floor="4.5"; fi
    if ! ratio="$(contrast_ratio "$fg" "$bg")"; then
      printf '{"verdict":"FAIL","ts":"%s","gate":"design-contrast","pairs":[],"reason":"bad-color"}\n' "$ts" > "$report"
      echo "design-contrast: FAIL (pair '$name' bad color: fg=$fg bg=$bg)"
      return 2
    fi
    if awk -v r="$ratio" -v f="$floor" 'BEGIN{exit !(r+0 >= f+0)}'; then
      pass="true"
    else
      pass="false"; verdict="FAIL"; rc=2
    fi
    local esc; esc="$(json_escape "$name")"
    pairs_json+="${pairs_json:+,}{\"name\":\"$esc\",\"ratio\":$ratio,\"floor\":$floor,\"pass\":$pass}"
    echo "  $name: ${ratio}:1 (floor ${floor}, $([ "$pass" = true ] && echo OK || echo BELOW))"
  done

  # CSS-DERIVED ARM (panel #12): a manifest that declares only its good pairs cannot buy a PASS while the
  # stylesheet ships failing ones. The manifest is what the author claims; this is what the browser renders.
  local dres dn dj
  dres="$(derived_failures "$root")"; dn="${dres%%|*}"; dj="${dres#*|}"
  if [ "${dn:-0}" -gt 0 ]; then
    verdict="FAIL"; rc=2
    echo "design-contrast: $dn CSS-derived pair(s) below the WCAG floor (the manifest did not declare them):"
    printf '%s' "$dj" | jq -r '.[]|"  css-derived "+.selector+": "+(.ratio|tostring)+":1 (floor "+(.floor|tostring)+", BELOW) fg="+.fg+" bg="+.bg' 2>/dev/null || true
    pairs_json="${pairs_json:+$pairs_json,}$(printf '%s' "$dj" | sed 's/^\[//; s/\]$//')"
  fi

  mkdir -p "$(dirname "$report")"
  printf '{"verdict":"%s","ts":"%s","gate":"design-contrast","pairs":[%s],"css_derived_failures":%s}\n' "$verdict" "$ts" "$pairs_json" "${dn:-0}" > "$report"
  echo "design-contrast: $verdict"
  return $rc
}

selftest() {
  local pass=0 total=0
  check() {
    total=$((total+1))
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "  ok: $1 ($3)";
    else echo "  FAIL: $1 (expected $2 got $3)"; fi
  }
  within() {
    total=$((total+1))
    if awk -v e="$2" -v a="$3" -v t="$4" 'BEGIN{d=e-a; if(d<0)d=-d; exit !(d<=t)}'; then
      pass=$((pass+1)); echo "  ok: $1 (=$3, expect $2)";
    else echo "  FAIL: $1 (expected ~$2 got $3)"; fi
  }

  within "#000000 vs #ffffff = 21.00"  21.00 "$(contrast_ratio '#000000' '#ffffff')" 0.02
  within "#ffffff vs #ffffff = 1.00"    1.00 "$(contrast_ratio '#ffffff' '#ffffff')" 0.02
  within "#777777 vs #ffffff ~ 4.48"    4.48 "$(contrast_ratio '#777777' '#ffffff')" 0.02
  within "#767676 vs #ffffff ~ 4.54"    4.54 "$(contrast_ratio '#767676' '#ffffff')" 0.02
  # WCAG-exact = 3.03 (148/255 through the exact pipeline); published tables round to ~3.00.
  # Assert against the exact value; tolerance covers the 0.03 reference-table gap.
  within "#949494 vs #ffffff ~ 3.00 (exact 3.03)" 3.03 "$(contrast_ratio '#949494' '#ffffff')" 0.02
  within "#0000ff vs #ffffff ~ 8.59"    8.59 "$(contrast_ratio '#0000ff' '#ffffff')" 0.02

  within "#000 vs #fff = 21.00 (3-digit)" 21.00 "$(contrast_ratio '#000' '#fff')" 0.02
  # B65 — hsl()/rgb() parsing (verified vs Python colorsys): same known answers via CSS-native formats.
  within "hsl black vs white = 21.00" 21.00 "$(contrast_ratio 'hsl(0 0% 0%)' 'hsl(0 0% 100%)')" 0.02
  within "rgb black vs white = 21.00" 21.00 "$(contrast_ratio 'rgb(0 0 0)' 'rgb(255,255,255)')" 0.02
  within "hsl gray(49%) vs white ~ 4.6 (Cadence subtle)" 4.60 "$(contrast_ratio 'hsl(240 8% 49%)' '#ffffff')" 0.05

  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/ctst.XXXXXX")"

  mkdir -p "$d/good/walteur-kit"
  cat > "$d/good/walteur-kit/contrast-pairs.json" <<'EOF'
{"schema_version":1,"pairs":[
  {"name":"body text","fg":"#111827","bg":"#ffffff","large":false},
  {"name":"muted large","fg":"#949494","bg":"#ffffff","large":true}
]}
EOF
  ( run_gate "$d/good" >/dev/null 2>&1 ); check "good manifest -> PASS(0)" 0 $?

  # B70 drift-guard: a manifest color ABSENT from the project CSS -> FAIL (cannot declare fake passing colors).
  mkdir -p "$d/drift/walteur-kit" "$d/drift/src"
  printf '%s\n' ':root{--fg:hsl(240 8% 49%);--bg:hsl(0 0% 100%)}' > "$d/drift/src/styles.css"
  printf '%s\n' '{"pairs":[{"name":"fake","fg":"#000000","bg":"#ffffff","large":false}]}' > "$d/drift/walteur-kit/contrast-pairs.json"
  ( run_gate "$d/drift" >/dev/null 2>&1 ); check "B70 manifest color absent from CSS -> FAIL(2) drift" 2 $?
  # B70 no-false-positive: manifest colors PRESENT in the CSS (verbatim) -> PASS (drift guard must not over-fire).
  mkdir -p "$d/nodrift/walteur-kit" "$d/nodrift/src"
  printf '%s\n' ':root{--fg:hsl(240 8% 49%);--bg:hsl(0 0% 100%)}' > "$d/nodrift/src/styles.css"
  printf '%s\n' '{"pairs":[{"name":"real","fg":"hsl(240 8% 49%)","bg":"hsl(0 0% 100%)","large":false}]}' > "$d/nodrift/walteur-kit/contrast-pairs.json"
  ( run_gate "$d/nodrift" >/dev/null 2>&1 ); check "B70 manifest colors present in CSS -> PASS(0) no-FP" 0 $?

  mkdir -p "$d/low/walteur-kit"
  cat > "$d/low/walteur-kit/contrast-pairs.json" <<'EOF'
{"schema_version":1,"pairs":[{"name":"faint","fg":"#999999","bg":"#ffffff","large":false}]}
EOF
  ( run_gate "$d/low" >/dev/null 2>&1 ); check "low-contrast manifest -> FAIL(2)" 2 $?
  within "#999999 vs #ffffff ~ 2.85" 2.85 "$(contrast_ratio '#999999' '#ffffff')" 0.02

  mkdir -p "$d/empty"
  ( run_gate "$d/empty" >/dev/null 2>&1 ); check "no manifest + no CSS -> NOT_APPLICABLE(0)" 0 $?
  local v; v="$(jq -r '.verdict' "$d/empty/walteur-kit/design-contrast-report.json" 2>/dev/null)"
  check "empty verdict == NOT_APPLICABLE" "NOT_APPLICABLE" "$v"

  # ── PANEL #12: CSS-DERIVED ARM. Before this, the gate judged only what the manifest declared, so a
  # manifest listing one good pair bought a clean PASS while the stylesheet shipped a 2.32:1 gray. Both
  # fixtures below carry a VALID, PASSING, drift-clean manifest — the only difference is the CSS.
  mkdir -p "$d/derived/walteur-kit" "$d/derived/src"
  cat > "$d/derived/src/styles.css" <<'EOF'
:root{ --muted:#a9a9a9; --bg:#ffffff; }
body{ color:#111827; background:#ffffff; }
.hint{ color:var(--muted); background:var(--bg); }
EOF
  printf '%s\n' '{"pairs":[{"name":"body","fg":"#111827","bg":"#ffffff","large":false}]}' > "$d/derived/walteur-kit/contrast-pairs.json"
  ( run_gate "$d/derived" >/dev/null 2>&1 ); check "passing manifest + failing SHIPPED css pair -> FAIL(2) (was PASS pre-panel-12)" 2 $?
  local dn; dn="$(jq -r '.css_derived_failures' "$d/derived/walteur-kit/design-contrast-report.json" 2>/dev/null)"
  check "the report counts the css-derived failure" 1 "$dn"
  local dsel; dsel="$(jq -r '[.pairs[]|select(.source=="css-derived")|.selector]|join(",")' "$d/derived/walteur-kit/design-contrast-report.json" 2>/dev/null)"
  check "the derived failure names the offending selector (var(--muted) resolved)" ".hint" "$dsel"
  within "the shipped gray really is below the floor" 2.35 "$(contrast_ratio '#a9a9a9' '#ffffff')" 0.02

  # FP guard: identical manifest, and CSS whose every derived pair clears the floor -> PASS. The derived arm
  # must not turn every project red; it must turn the ones with unreadable text red.
  mkdir -p "$d/derived-ok/walteur-kit" "$d/derived-ok/src"
  cat > "$d/derived-ok/src/styles.css" <<'EOF'
:root{ --muted:#595959; --bg:#ffffff; }
button:disabled{ color:#cccccc; background:#ffffff; }
input::placeholder{ color:#d0d0d0; }
body{ color:#111827; background:#ffffff; }
.hint{ color:var(--muted); background:var(--bg); }
.hero{ color:#767676; background:#ffffff; font-size:32px; }
.grad{ color:currentColor; background:linear-gradient(90deg,#000,#fff); }
EOF
  printf '%s\n' '{"pairs":[{"name":"body","fg":"#111827","bg":"#ffffff","large":false}]}' > "$d/derived-ok/walteur-kit/contrast-pairs.json"
  ( run_gate "$d/derived-ok" >/dev/null 2>&1 ); check "FP guard: readable css + WCAG-exempt states + large text + gradient -> PASS(0)" 0 $?

  mkdir -p "$d/bad/walteur-kit"
  printf '{ this is not json ]' > "$d/bad/walteur-kit/contrast-pairs.json"
  ( run_gate "$d/bad" >/dev/null 2>&1 ); check "malformed manifest -> FAIL(2)" 2 $?

  rm -rf "$d"

  echo "contrast-gate selftest: $pass/$total passed"
  [[ "$pass" == "$total" ]]
}

main() {
  case "${1:-}" in
    -h|--help)
      printf '%s\n' \
        "design-contrast - WCAG 2.1 computed relative-luminance contrast gate (B64)." \
        "usage: bash design-contrast-gate.sh [--selftest|--ratio <fg> <bg>|--help|<default run>]" \
        "manifest: walteur-kit/contrast-pairs.json {pairs:[{name,fg,bg,large}]} (absent + UI/CSS present -> FAIL; absent + no CSS -> NOT_APPLICABLE)" \
        "report: walteur-kit/design-contrast-report.json - fix: walteur-kit/REMEDIATION.md (## design-contrast-gate)" \
        "bypass: WALTEUR_DESIGN_CONTRAST=off (recorded, not free); strict-at-ship via WALTEUR_TOOLGATE_STRICT=1"
      exit 0 ;;
    --selftest) selftest ;;
    --ratio)    contrast_ratio "$2" "$3" ;;
    *)          run_gate "$WALTEUR_ROOT" ;;
  esac
}
main "$@"
