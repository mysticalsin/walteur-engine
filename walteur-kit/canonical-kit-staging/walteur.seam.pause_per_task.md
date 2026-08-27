# Seam: pause_per_task — per-BUILD-sub-task HITL (salvaged from ai-dev-tasks; the lone delta over walteur-discover+PLAN)
# Targets the BUILD sub-task loop in walteur-starter/.claude/workflows/walteur.js (the /goal orchestrator).
# REUSES the existing machinery 1:1 — APPROVAL-REQUEST.json + APPROVED + STATE.json crash-recovery (SKILL.md:141-143).
# ~15 lines of shell. Zero new files. OFF unless autonomy_policy == "pause_per_task".
#
# WHERE: inside BUILD, the orchestrator runs PLAN.md's tasks one at a time (ACT->TEST->...->COMMIT per task).
# After EACH sub-task's gates go green and BEFORE starting the next, insert this check:
#
#   POLICY="$(jq -r '.autonomy_policy // "full_autopilot"' walteur-kit/autopilot/STATE.json)"
#   if [ "$POLICY" = "pause_per_task" ]; then
#     REQ=walteur-kit/APPROVAL-REQUEST.json; OK=walteur-kit/APPROVED
#     # resume path: a prior APPROVED, newer than the request, clears this pause and is consumed.
#     if [ -f "$OK" ] && [ -f "$REQ" ] && [ "$OK" -nt "$REQ" ]; then
#       rm -f "$OK" "$REQ"                       # consumed on read — exactly like seams 1 & 2
#     else
#       jq -nc --arg t "$TASK_ID" --arg s "$TASK_SUMMARY" --arg n "$NEXT_TASK_ID" \
#         '{seam:"task", task:$t, summary:$s, next_phase:"BUILD", next_task:$n}' > "$REQ"
#       # persist position so re-running /goal resumes at THIS sub-task (STATE crash-recovery already reads STATE+BATON+gates)
#       tmp=$(mktemp walteur-kit/autopilot/.state.XXXXXX); \
#         jq --arg t "$TASK_ID" '.phase="BUILD" | .last_task=$t' walteur-kit/autopilot/STATE.json > "$tmp" && mv "$tmp" walteur-kit/autopilot/STATE.json
#       echo "PAUSED after task $TASK_ID — review the diff, then: write walteur-kit/APPROVED and re-run /goal to continue."
#       exit 0                                    # halt-and-resume; NOT a live block (identical contract to seams 1 & 2)
#     fi
#   fi
#
# NOTES
# - full_autopilot and pause_at_plan_and_audit are UNAFFECTED (the if-guard is the only entry).
# - No new phase: BUILD stays atomic in STATE._phases; the pause is a sub-loop boundary, so crash-recovery 'resume at BUILD' still holds.
# - STEP-1 Q5 in goal.md should offer the third option: "...or pause after EACH build task for sign-off (pause_per_task)".
