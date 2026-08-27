# WALTEUR Terminal Audit — <project name>
**Date:** <ISO date>
**Auditor:** final-auditor (model: OPUS, non-negotiable)
**Build hash / last commit:** <git sha>

---

## VERDICT

**[ ] CERTIFIED — this build is the absolute best achievable. I stake my name on shipping it.**
**[ ] NOT YET CERTIFIED — shortfalls listed below. Re-enter REFINE.**

---

## §0 Bar — 5 binary questions (whole build)

| Question | PASS / FAIL | Evidence |
|----------|-------------|---------|
| Does it actually do what was asked? (every PLAN.md task → output) | | |
| Is it production-hardened across all 13 layers? | | |
| Is it WOW — Apple-keynote quality? Would you stake your reputation on it? | | |
| Would a staff engineer at a top-tier team approve this without a single "we should fix X"? | | |
| Is this the absolute best achievable in code AND everything else — or does a shortfall exist? | | |

---

## 8-Dimension Re-Score (independent of prior verdicts)

| Dimension | Score /10 | Best achievable? | Evidence |
|-----------|-----------|-----------------|---------|
| Design | | | |
| Infrastructure | | | |
| Security | | | |
| UX/UI | | | |
| Performance | | | |
| Features | | | |
| Data Architecture | | | |
| DevEx | | | |
| **Composite** | | | |

---

## 13-Layer Walk (§14)

| Layer | Status | Evidence / deferred reason |
|-------|--------|--------------------------|
| 1 Frontend | | |
| 2 APIs & Backend Logic | | |
| 3 Database & Storage | | |
| 4 Auth & Permissions | | |
| 5 Hosting & Deployment | | |
| 6 Cloud & Compute | | |
| 7 CI/CD & Version Control | | |
| 8 Security & RLS | | |
| 9 Rate Limiting | | |
| 10 Caching & CDN | | |
| 11 Load Balancing & Scaling | | |
| 12 Error Tracking & Logs | | |
| 13 Availability & Recovery | | |

---

## ADR Re-Check

| ADR | Original decision | Still holds? | Evidence |
|-----|------------------|--------------|---------|
| | | | |

---

## Shortfalls (what is short of absolute best — empty = CERTIFIED)

| Dimension | Gap | Fix | Severity (blocking / minor) |
|-----------|-----|-----|----------------------------|
| | | | |

---

## Known Gaps (accepted, risk owned)

<"none, verified" OR explicit list with owner and re-review trigger>

---

## Re-run Evidence

Tests re-run by the auditor independently:
- Command: `<recorded_command>`
- Exit code: <0 or fail>
- Output sha: <sha>

---

_I, the Auditor (Opus), certify this build is the absolute best achievable — OR here is exactly what isn't, with the fix cost to close it._

**Signed:** <model=opus> · <ISO timestamp>
