#!/usr/bin/env bash
# WALTEUR ontology-lint — ADVISORY (warning-first, exit 0 ALWAYS) lint of PRD/PLAN/ADR domain nouns
# against walteur-kit/ontology.json — a FILE-SCALE TYPED ENTITY GLOSSARY.
#
# WHAT THIS IS — AND IS NOT (load-bearing, do not erode):
#   * ontology.json is a TYPED GLOSSARY the gates LINT against: {entities:[{name,type,aka:[],definition}]}.
#     Its only job is a SHARED, TYPED VOCABULARY so domain nouns mean the same thing across PRD/PLAN/ADR/briefs.
#   * It is NOT a second retrieval index. graphify stays the ONE retrieval brain (CLAUDE.md mandated nav order;
#     one-brain law). This hook does ZERO semantic lookup — it reads the glossary flat and string-matches names.
#     No daemon, no embedding, no collector. A capitalized domain noun referenced but UNDEFINED => advisory WARN.
#
# Applicability (detect-or-SKIP — pure CLIs NEVER see this gate):
#   ARMS only when EITHER
#     (a) a brownfield glossary is present: walteur-kit/ontology.json (or ontology.json at root/<dir>), OR
#     (b) a PRD on record names MORE THAN N domain entities (default N=8; WALTEUR_ONTOLOGY_MIN_ENTITIES).
#   NEITHER => NOT_APPLICABLE (exit 0, loud). A typo / pure-backend-CLI / glossary-less small build never arms.
#
# Verdicts (ALL exit 0 — advisory only, never blocks a build or a commit):
#   NOT_APPLICABLE  no glossary AND PRD entity-count <= N (or no PRD).
#   PASS            armed + glossary present + every referenced domain noun resolves to an entity name/aka.
#   WARN            armed + >=1 referenced capitalized domain noun is UNDEFINED in the glossary  (advisory), OR
#                   armed-by-PRD-entity-count but NO glossary exists yet (advisory: author one).
#   SKIP            required tool absent / bypass / no dir arg (recorded, never silent-green).
#
# Bypass: WALTEUR_ONTOLOGY=off => SKIP report, exit 0.   Kill switch: walteur-kit/PAUSED present => exit 2.
# Knobs:  WALTEUR_ONTOLOGY_MIN_ENTITIES (default 8)  ·  WALTEUR_ONTOLOGY=off
# Zero-dep: bash + grep + awk + sed + jq + find only. ADVISORY: exit 0 on every verdict except PAUSED.
# HONESTY: a missing tool => recorded SKIP, not silent-green. An undefined noun = NOT-FOUND in glossary
#          (a real advisory finding), never a claim the noun is WRONG — naming is judgment (PROTOCOL, §panel/QA).
# Self-test: bash walteur-kit/hooks/ontology-lint.sh --selftest   (good=all defined -> clean; poisoned=undefined -> WARN)
# Report: walteur-kit/ontology-lint-report.json {verdict, ts, gate, armed_by, glossary, undefined_terms, details}.
# --help: self-documentation BEFORE any side effect (S033 usability contract)
case "${1:-}" in
  -h|--help)
  printf '%s\n' "ontology-lint - ADVISORY (warning-first, exit 0 ALWAYS) lint of PRD/PLAN/ADR domain nouns"
  printf '%s\n' "usage: bash ontology-lint.sh [--selftest|--help|<default run>]"
  printf '%s\n' "report: walteur-kit/ontology-lint-report.json - fix recipes: walteur-kit/REMEDIATION.md (## ontology-lint)"
  printf '%s\n' "bypass: WALTEUR_ONTOLOGY=off (recorded, not free)"
  exit 0 ;;
esac

set -uo pipefail

ROOT="${WALTEUR_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KIT="$ROOT/walteur-kit"
mkdir -p "$KIT"
REPORT="$KIT/ontology-lint-report.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MIN_ENTITIES="${WALTEUR_ONTOLOGY_MIN_ENTITIES:-8}"

write_report() { # $1=verdict $2=armed_by $3=glossary-rel $4=reason $5=undefined-json-array $6=details-json
  jq -n \
    --arg v "$1" --arg ts "$TS" --arg armed "$2" --arg gloss "${3:-}" --arg reason "$4" \
    --argjson undef "${5:-[]}" --argjson details "${6:-[]}" \
    '{verdict:$v, ts:$ts, gate:"ontology-lint", advisory:true, armed_by:$armed, glossary:$gloss,
      reason:$reason, undefined_terms:$undef, details:$details,
      note:"glossary lint, NOT a retrieval index — graphify is the one brain"}' > "$REPORT"
}

run_gate() { # $1 = dir to scan for PRD/PLAN/ADR + product/glossary signal
  DIR="${1:-}"

  # ── kill switch (the ONE non-zero exit) ───────────────────────────────────────
  [ -f "$KIT/PAUSED" ] && { echo "WALTEUR PAUSED (walteur-kit/PAUSED). Resume: rm walteur-kit/PAUSED" >&2; exit 2; }

  # ── tool guard ────────────────────────────────────────────────────────────────
  for t in grep awk sed jq find; do
    if ! command -v "$t" >/dev/null 2>&1; then
      echo "WALTEUR ontology-lint SKIP — required tool '$t' not installed (recorded, not silent-green)." >&2
      write_report "SKIP" "tool-missing" "" "$t not installed" '[]' '[]'; exit 0
    fi
  done

  # ── bypass ────────────────────────────────────────────────────────────────────
  if [ "${WALTEUR_ONTOLOGY:-on}" = "off" ]; then
    echo "WALTEUR ontology-lint SKIP — bypass WALTEUR_ONTOLOGY=off (recorded, not silent-green)." >&2
    write_report "SKIP" "bypass" "" "bypass WALTEUR_ONTOLOGY=off" '[]' '[]'; exit 0
  fi

  if [ -z "$DIR" ]; then DIR="$ROOT"; fi
  if [ ! -d "$DIR" ]; then
    echo "WALTEUR ontology-lint SKIP — '$DIR' is not a directory (nothing to scan)." >&2
    write_report "SKIP" "bad-arg" "" "not a directory: $DIR" '[]' '[]'; exit 0
  fi

  # ── locate the glossary (brownfield-glossary arming signal) ───────────────────
  GLOSS=""
  for cand in "$KIT/ontology.json" "$ROOT/ontology.json" "$DIR/ontology.json"; do
    [ -f "$cand" ] && { GLOSS="$cand"; break; }
  done
  GLOSS_REL="${GLOSS#"$ROOT"/}"

  # ── locate a PRD + count its domain entities (PRD-entity-count arming signal) ─
  PRD=""
  for cand in "$KIT/PRD.md" "$ROOT/PRD.md" "$DIR/PRD.md"; do
    [ -f "$cand" ] && { PRD="$cand"; break; }
  done
  # PRD entity count: prefer a structured prd entity list if present, else a cheap proxy = distinct
  # capitalized/Camel domain nouns in the PRD (the same token shape we later lint). Proxy only feeds ARMING.
  PRD_ENTITY_COUNT=0
  if [ -n "$PRD" ]; then
    PRD_ENTITY_COUNT="$(extract_domain_nouns "$PRD" | sort -u | grep -c . || true)"
    PRD_ENTITY_COUNT="${PRD_ENTITY_COUNT:-0}"
  fi

  # ── ARM or NOT_APPLICABLE ─────────────────────────────────────────────────────
  ARMED_BY=""
  if [ -n "$GLOSS" ]; then
    ARMED_BY="glossary"
  elif [ -n "$PRD" ] && [ "$PRD_ENTITY_COUNT" -gt "$MIN_ENTITIES" ]; then
    ARMED_BY="prd-entity-count"
  fi

  if [ -z "$ARMED_BY" ]; then
    echo "WALTEUR ontology-lint NOT_APPLICABLE — no glossary (walteur-kit/ontology.json) and PRD names <= $MIN_ENTITIES domain entities (count=$PRD_ENTITY_COUNT). Pure-CLI / small build tier." >&2
    write_report "NOT_APPLICABLE" "none" "$GLOSS_REL" \
      "no glossary and PRD entity-count ($PRD_ENTITY_COUNT) <= threshold ($MIN_ENTITIES)" '[]' '[]'
    exit 0
  fi

  # ── armed-by-PRD-count but NO glossary yet => advise authoring one (still exit 0) ─
  if [ -z "$GLOSS" ]; then
    echo "WALTEUR ontology-lint WARN (advisory) — PRD names $PRD_ENTITY_COUNT domain entities (> $MIN_ENTITIES) but no walteur-kit/ontology.json glossary exists." >&2
    echo "  Suggest: author walteur-kit/ontology.json so PRD/PLAN/ADR share ONE typed vocabulary. (Glossary, not an index — graphify stays the brain.)" >&2
    write_report "WARN" "prd-entity-count" "" \
      "PRD names $PRD_ENTITY_COUNT domain entities (> $MIN_ENTITIES) but no glossary — author walteur-kit/ontology.json (schema: schemas/ontology.schema.json)" \
      '["<no glossary — author one>"]' \
      '[{"rule":"missing-glossary","message":"A multi-entity PRD warrants a shared typed glossary. Copy the entity shape from schemas/ontology.schema.json. Advisory only — never blocks."}]'
    exit 0
  fi

  # ── glossary present + valid? (advisory shape check; malformed => SKIP, recorded) ─
  if ! jq -e '.entities and (.entities|type=="array") and (.entities|length>0)' "$GLOSS" >/dev/null 2>&1; then
    echo "WALTEUR ontology-lint SKIP — glossary '$GLOSS_REL' is missing/empty/invalid .entities[] (recorded, not silent-green)." >&2
    write_report "SKIP" "$ARMED_BY" "$GLOSS_REL" "glossary has no valid .entities[] array" '[]' '[]'
    exit 0
  fi

  # ── build the DEFINED set: every name + every aka, lowercased, one per line ───
  DEFINED="$(jq -r '.entities[] | (.name, (.aka[]? // empty))' "$GLOSS" 2>/dev/null | awk 'NF' | tr '[:upper:]' '[:lower:]' | sort -u)"

  # ── collect the docs to lint: PRD.md, PLAN.md, and any ADR files ──────────────
  DOCS=()
  [ -n "$PRD" ] && DOCS+=("$PRD")
  for cand in "$KIT/PLAN.md" "$ROOT/PLAN.md" "$DIR/PLAN.md"; do
    [ -f "$cand" ] && { DOCS+=("$cand"); break; }
  done
  # ADRs: common locations + name shapes (ADR-*.md, adr/*.md, decisions/*.md, docs/adr/*.md).
  PRUNE=( \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*' -o -path '*/walteur-kit/*' \) -prune -o )
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    DOCS+=("$f")
  done < <(find "$DIR" "${PRUNE[@]}" -type f \
    \( -iname 'ADR-*.md' -o -iname '*-adr.md' -o -ipath '*/adr/*.md' -o -ipath '*/decisions/*.md' -o -ipath '*/docs/adr/*.md' \) -print 2>/dev/null | sort -u)

  if [ "${#DOCS[@]}" -eq 0 ]; then
    echo "WALTEUR ontology-lint PASS — glossary '$GLOSS_REL' present; no PRD/PLAN/ADR doc found to lint (nothing to check)." >&2
    write_report "PASS" "$ARMED_BY" "$GLOSS_REL" "glossary present; no PRD/PLAN/ADR docs to lint" '[]' '[]'
    exit 0
  fi

  # ── lint: for each doc, find referenced domain nouns NOT in DEFINED ───────────
  # NB: bash 3.2 (macOS default /bin/bash) has NO associative arrays — track "seen" undefined
  # terms in a newline-delimited string with a case-membership test, not `declare -A`.
  declare -a FINDINGS_JSON=()
  declare -a UNDEF_LIST=()
  SEEN_UNDEF=$'\n'
  for doc in "${DOCS[@]}"; do
    doc_rel="${doc#"$ROOT"/}"
    while IFS=$'\t' read -r ln term; do
      [ -z "$term" ] && continue
      tl="$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]')"
      # defined? exact line match in DEFINED set (names + akas, lowercased)
      if printf '%s\n' "$DEFINED" | grep -qxF "$tl"; then continue; fi
      # first time we see this (lowercased) undefined term? -> record it once
      case "$SEEN_UNDEF" in
        *$'\n'"$tl"$'\n'*) : ;;                       # already seen
        *) SEEN_UNDEF="${SEEN_UNDEF}${tl}"$'\n'; UNDEF_LIST+=("$term") ;;
      esac
      FINDINGS_JSON+=("$(jq -n --arg t "$term" --arg f "$doc_rel" --argjson l "$ln" \
        '{term:$t, file:$f, line:$l, message:("domain noun \""+$t+"\" referenced but not defined in the glossary (advisory — add an entity or an aka, or it is a false positive to ignore)")}')")
    done < <(extract_domain_nouns_with_lines "$doc")
  done

  if [ "${#UNDEF_LIST[@]}" -eq 0 ]; then
    echo "WALTEUR ontology-lint PASS — every referenced domain noun resolves to a glossary entity ($GLOSS_REL; ${#DOCS[@]} doc(s))." >&2
    write_report "PASS" "$ARMED_BY" "$GLOSS_REL" "all referenced domain nouns are defined (${#DOCS[@]} docs linted)" '[]' '[]'
    exit 0
  fi

  UNDEF_JSON="$(printf '%s\n' "${UNDEF_LIST[@]}" | jq -R . | jq -s 'unique')"
  FIND_JSON="$(printf '%s\n' "${FINDINGS_JSON[@]}" | jq -s '.')"
  write_report "WARN" "$ARMED_BY" "$GLOSS_REL" \
    "$(printf '%s undefined domain noun(s) referenced: %s' "${#UNDEF_LIST[@]}" "$(printf '%s, ' "${UNDEF_LIST[@]}" | sed 's/, $//')")" \
    "$UNDEF_JSON" "$FIND_JSON"
  echo "WALTEUR ontology-lint: WARN (advisory) — ${#UNDEF_LIST[@]} domain noun(s) referenced but UNDEFINED in $GLOSS_REL:" >&2
  for f in "${FINDINGS_JSON[@]}"; do
    t="$(printf '%s' "$f" | jq -r '.term')"; fl="$(printf '%s' "$f" | jq -r '.file')"; l="$(printf '%s' "$f" | jq -r '.line')"
    echo "  $fl:$l  $t" >&2
  done
  echo "  Fix: add each as an entity (or as an 'aka' of an existing one) in $GLOSS_REL — or ignore (advisory, never blocks)." >&2
  exit 0
}

# ── domain-noun extractor ──────────────────────────────────────────────────────
# A "domain noun" candidate = a CamelCase token (>=2 words, e.g. OrderLine) OR a TitleCase token NOT at the
# start of a sentence and NOT a common English word. Deliberately conservative to keep false positives low:
#   * Markdown structure stripped (headings #, list markers, code fences/inline code, link/url chrome, frontmatter).
#   * CamelCase (an internal capital) is almost always a domain entity -> always a candidate.
#   * A single TitleCase word is a candidate ONLY if it is NOT sentence-initial and NOT in the stopword set.
# Output of *_with_lines: "<line>\t<term>"  ·  Output of plain: "<term>" (used only for the arming proxy).
ONTOLOGY_STOPWORDS=" the a an and or but of to in on at for with by from as is are was were be been being this that these those it its we you they i he she them us our your their if then else when while given where what which who how why not no yes do does did has have had will would shall should can could may might must page section see note also e.g i.e etc todo tbd given when then summary background objective scope tasks goals out plan prd adr api ui ux http https json yaml md sql get post put patch delete head http v1 v2 readme license changelog "

extract_domain_nouns_with_lines() { # $1=file ; emits "<line>\t<term>"
  awk '
    BEGIN { incode=0 }
    {
      line=$0
      # frontmatter / fenced code blocks: toggle on ``` ; skip code lines entirely
      if (line ~ /^[[:space:]]*```/) { incode = !incode; next }
      if (incode) next
      if (line ~ /^[[:space:]]*---[[:space:]]*$/ && NR<=3) next   # leading YAML fence (cheap)
      # strip markdown chrome that is not prose: heading hashes, list bullets, blockquote, inline code, links/urls
      gsub(/`[^`]*`/, " ", line)                 # inline code spans
      gsub(/\]\([^)]*\)/, "] ", line)            # markdown link targets (keep the [text])
      gsub(/https?:\/\/[^[:space:]]+/, " ", line)# bare urls
      gsub(/^[[:space:]]*#{1,6}[[:space:]]*/, " ", line)  # heading markers
      gsub(/^[[:space:]]*[-*+>][[:space:]]+/, " ", line)  # list / quote markers
      gsub(/[][(){}",;:|]/, " ", line)           # punctuation -> spaces (keep . and - and _ for now)

      n = split(line, w, /[[:space:]]+/)
      content_idx = 0          # running index among NON-EMPTY tokens on this (chrome-stripped) line
      prev_ended_sentence = 1  # the FIRST content word of a line is always a sentence start
      for (k=1; k<=n; k++) {
        raw = w[k]
        if (raw == "") continue          # split artefacts from collapsed markers -> not a real position
        content_idx++
        # is THIS token a sentence start? (first content word, or the prior content word ended in .!?)
        is_sentence_start = prev_ended_sentence
        # remember whether THIS raw token ends a sentence, for the NEXT content word
        prev_ended_sentence = (raw ~ /[.!?]+$/) ? 1 : 0
        tok = raw
        gsub(/[.!?]+$/, "", tok)         # trim trailing sentence punctuation off the term itself
        if (tok == "") continue
        # CamelCase: has an internal uppercase after a lowercase (OrderLine, runTrace, walteurKit)
        is_camel = (tok ~ /[a-z][A-Z]/)
        # TitleCase single word: starts uppercase, has at least one lowercase, all letters
        is_title = (tok ~ /^[A-Z][a-z]+$/)
        if (!is_camel && !is_title) continue
        # sentence-initial gate applies to plain TitleCase words only; CamelCase is kept regardless.
        print NR "\t" tok "\t" (is_camel?"camel":"title") "\t" (is_sentence_start?"start":"mid")
      }
    }
  ' "$1" | _ontology_filter
}

# plain (no line numbers) — used ONLY for the arming entity-count proxy on the PRD.
extract_domain_nouns() { # $1=file ; emits "<term>"
  extract_domain_nouns_with_lines "$1" | cut -f2
}

# filter: drop stopwords (case-insensitive) and sentence-initial plain-TitleCase words. CamelCase always kept.
_ontology_filter() {
  awk -v sw="$ONTOLOGY_STOPWORDS" '
    {
      term=$2; kind=$3; pos=$4
      low=tolower(term)
      # sentence-initial single TitleCase word: ambiguous (could be a normal sentence start) -> drop.
      if (kind=="title" && pos=="start") next
      # stopword (only meaningful for title words; camel never is one)
      if (index(sw, " " low " ") > 0) next
      # very short title words (<=2 chars) -> drop noise
      if (kind=="title" && length(term) <= 2) next
      print $1 "\t" term
    }
  '
}

# ── embedded self-test (good + poisoned + not-applicable twins; hermetic temp project) ──
selftest() {
  local fails=0 total=0 tmp rc verdict
  local SELF; SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  command -v jq >/dev/null 2>&1 || { echo "ontology-lint selftest SKIP — jq not installed."; return 0; }

  run_one() { # $1=label $2=want-rc $3=want-verdict(or "") $4=setup-fn
    total=$((total+1))
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ontology-lint-selftest.XXXXXX")" || {
      echo "  FAIL — $1 (mktemp)"; fails=$((fails+1)); return; }
    mkdir -p "$tmp/walteur-kit" "$tmp/src"
    "$4" "$tmp"
    set +e
    WALTEUR_ROOT="$tmp" WALTEUR_ONTOLOGY=on bash "$SELF" "$tmp" >/dev/null 2>&1; rc=$?
    set -e
    verdict="$(jq -r '.verdict' "$tmp/walteur-kit/ontology-lint-report.json" 2>/dev/null || echo "NO-REPORT")"
    local okrc=1 okv=1
    [ "$rc" -eq "$2" ] || okrc=0
    if [ -n "$3" ] && [ "$verdict" != "$3" ]; then okv=0; fi
    if [ "$okrc" -eq 1 ] && [ "$okv" -eq 1 ]; then
      echo "  ok   — $1 (rc=$rc verdict=$verdict)"
    else
      echo "  FAIL — $1 (rc=$rc want $2; verdict=$verdict want ${3:-any})"; fails=$((fails+1))
    fi
    rm -rf "$tmp"
  }

  # shared glossary used by the good/poisoned twins
  write_glossary() {
    cat > "$1/walteur-kit/ontology.json" <<'JSON'
{ "ontology_version": 1,
  "note": "glossary, not an index",
  "entities": [
    { "name": "Tenant", "type": "Actor", "aka": ["tenants","TenantOrg"], "definition": "an isolated customer org." },
    { "name": "OrderLine", "type": "Resource", "aka": ["order line"], "definition": "one line of an order." },
    { "name": "Invoice", "type": "Artifact", "aka": [], "definition": "a billing document." }
  ] }
JSON
  }

  # GOOD twin — glossary present; every domain noun resolves -> PASS (clean), exit 0.
  # Deliberately heading/bullet-HEAVY with sentence-initial TitleCase leaders (Goals, Render,
  # Acceptance, Success) — these must NOT be flagged. If the sentence-start logic regresses, this
  # twin flips to WARN and the selftest fails (regression guard for the markdown-chrome false positive).
  good_setup() {
    write_glossary "$1"
    cat > "$1/walteur-kit/PLAN.md" <<'MD'
# Plan — billing

Each Tenant owns many OrderLine rows. We render an Invoice per Tenant.
The TenantOrg alias and an order line both resolve to known entities.

## Goals

- Render one Invoice per Tenant from its OrderLine rows.

## Acceptance criteria

- Given a Tenant When the run executes Then one Invoice is produced.

## Success metric

- Billing latency target p95 <= 3 min.
MD
  }
  # POISONED twin — glossary present; PLAN references "Subscription" (UNDEFINED) -> WARN, still exit 0.
  poisoned_setup() {
    write_glossary "$1"
    cat > "$1/walteur-kit/PLAN.md" <<'MD'
# Plan — billing

Each Tenant owns many OrderLine rows. A Subscription drives the Invoice cadence.
MD
  }
  # NOT_APPLICABLE twin — no glossary, tiny PRD (few entities) -> NOT_APPLICABLE, exit 0.
  na_setup() {
    cat > "$1/walteur-kit/PRD.md" <<'MD'
# PRD — cli tool
A small command line tool. Background: scripts need it.
MD
  }
  # ARMED-by-PRD-count, NO glossary -> WARN (advise authoring a glossary), exit 0.
  prdcount_setup() {
    cat > "$1/walteur-kit/PRD.md" <<'MD'
# PRD — platform

The Tenant uses OrderLine, Invoice, Subscription, PaymentMethod, Refund, Dispute,
Webhook, ApiKey and a Ledger. The OrderLine and Invoice flow through the Ledger.
MD
  }

  echo "ontology-lint selftest:"
  run_one "good twin: all nouns defined -> PASS"                 0 "PASS"            good_setup
  run_one "poisoned twin: undefined noun referenced -> WARN"     0 "WARN"            poisoned_setup
  run_one "no glossary + tiny PRD -> NOT_APPLICABLE"             0 "NOT_APPLICABLE"  na_setup
  run_one "multi-entity PRD, no glossary -> WARN (author one)"   0 "WARN"            prdcount_setup
  echo "ontology-lint selftest: $((total-fails))/$total passed"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest; exit $?
fi
run_gate "${1:-}"
