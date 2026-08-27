# ── T4 UPGRADE (v9.x): story -> task TEXT-trace PLUS construct CODE-PROOF ──────────
# OLD T4 (lines 251-267) proved only: the STORY-id string appears in PLAN.md. That is necessary but
# weak — a story can be "covered" by a task and STILL be unbuilt. The upgrade adds a CODE arm: if a
# story's PRD acceptance-criterion PINS an enforceable construct (ast_proof), T4 now also requires that
# construct to AST-match at a real file:line. Text-trace UNCHANGED (back-compat); code-proof is ADDITIVE
# and applicability-gated (no ast_proof => only the legacy text-trace runs => identical behavior).
#
# HONESTY: the code arm proves the construct EXISTS (HARD). It does NOT prove the story is fully/correctly
# implemented (PROTOCOL — §5.4 + §5.5 LLM reconciliation). A green T4 code-arm means \"the pinned construct
# is present at file:line\", never \"the story is done\".
if [ -n "$PRD_FILE" ]; then
  PRD_STORIES="$(grep -oE "$STORY_RE" "$PRD_FILE" 2>/dev/null | LC_ALL=C sort -u || true)"
  if [ -n "$PRD_STORIES" ]; then
    HAS_PRD_STORIES=1
    PLAN_STORIES="$(grep -oE "$STORY_RE" "$PLAN" 2>/dev/null | LC_ALL=C sort -u || true)"
    while IFS= read -r st; do
      [ -z "$st" ] && continue
      # arm A (UNCHANGED): forward TEXT-trace — story must map to >=1 task in PLAN.
      if ! printf '%s\n' "$PLAN_STORIES" | grep -qxF "$st"; then
        mark_fail T4
        add_detail T4 0 "PRD story $st has no covering task in PLAN.md (author a task that delivers it, or descope the story)."
        echo "  FAIL T4 — PRD story $st has no covering task in PLAN." >&2
      fi
    done <<EOF
$PRD_STORIES
EOF
    # arm B (NEW, applicability-gated): for stories whose AC pins a construct, require the AST proof.
    # Delegate to intent-trace.sh (the existence prover) so there is ONE proof engine, not two.
    # detect-or-LOUD-SKIP: no prd.proofs.json => no construct pinned => arm B is a no-op (legacy T4 only).
    if [ -f "$KIT/prd.proofs.json" ] && have ast-grep && [ -x "$ROOT/walteur-kit/hooks/intent-trace.sh" ]; then
      if ! WALTEUR_ROOT="$ROOT" bash "$ROOT/walteur-kit/hooks/intent-trace.sh" >/dev/null 2>&1; then
        mark_fail T4
        add_detail T4 0 "PRD acceptance-criterion pins a construct that intent-trace.sh could NOT prove EXISTS in code (see audit.json intent_vs_impl[].ast_proof.matched=false). Existence-arm only — not a correctness claim."
        echo "  FAIL T4 (code-arm) — a pinned construct is NOT-FOUND in code; see walteur-kit/audit.json." >&2
      else
        echo "  T4 code-arm: all pinned constructs proven to EXIST (existence only; correctness=PROTOCOL)." >&2
      fi
    elif [ -f "$KIT/prd.proofs.json" ] && ! have ast-grep; then
      echo "  T4 code-arm SKIP — prd.proofs.json present but ast-grep absent (recorded, not silent-green)." >&2
    fi
  fi
fi
