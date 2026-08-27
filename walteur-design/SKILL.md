---
name: walteur-design
description: >-
  WALTEUR-DESIGN v1.0 — the design companion to the WALTEUR build engine. Use for ANY work that changes
  how a product looks, feels, moves, or is interacted with: designing a UI, picking a style/palette/type
  system, reviewing visual craft, fixing "it looks generic / AI-slop". Triggers: /design, /design-system,
  /ui, "make it beautiful", "design review", or WALTEUR reaching a frontend task (§14 L1). It writes the
  project's DESIGN.md contract BEFORE any UI code (design-gate.sh enforces it), runs Consultant mode
  (decisions + rationale, no code) or Craftsman mode (code to an Apple-keynote bar), and closes every UI
  task with a screenshot-verified "share-worthy?" loop. Companion skill — WALTEUR builds, this designs.
metadata:
  type: design-companion
  version: 1.0
  status: standing-companion
  pairs_with: walteur (build engine ≥ v9.0)
  sibling: walteur-discover v1.0 (the front-funnel twin — discover decides WHAT is worth building; this decides how it LOOKS; walteur builds it)
  enforcement: "design-gate.sh (HARD, detect-or-SKIP) + anti-slop-ui.sh + story-coverage.sh + senior-uiux rubric"
  synthesizes:
    - VoltAgent/awesome-design-md (DESIGN.md artifact standard — Google Stitch schema; 73 brand seeds; MIT)
    - nextlevelbuilder/ui-ux-pro-max-skill v2.5 (design-system-first gate · MASTER+overrides persistence · rule taxonomy · checklists; MIT)
    - vabole/apple-skills v1.0.11 (consultant/craftsman split · screenshot-verify loop · design pre-flight · anti-slop tables; MIT)
    - shadcn-ui/ui + storybookjs/storybook (WALTEUR P06 + P02 — the implementation floor this skill designs FOR)
    - kit-native craft engines (§1.5, S033) — the CRAFT ENGINES this companion chains, resolved against
      walteur-kit/skill-index.json (org-brand-dna · org-taste · loopkit-design-system ·
      org-uiux-discipline · org-interaction-craft · loopkit-a11y-pass ·
      loopkit-loading-empty-error-states); always run UNDER this skill's DESIGN.md contract + anti-slop
      gate, never standalone. (S033: retracted the prior Leonxlnx/taste-skill mandate — those engines were
      never installed at .agents/skills/, a dangling MUST-chain; design-gate.sh now verifies every
      MUST-fire skill this file names actually resolves in skill-index.json.)
---

# WALTEUR-DESIGN v1.0 — the design companion (Consultant + Craftsman)

> **WALTEUR builds. WALTEUR-DESIGN decides how it should look, feel, and move — in writing, before code.**
> The design counterpart of plan-before-build: **NO UI CODE WITHOUT A WRITTEN DESIGN SYSTEM.**
> Sibling companion (v9.0): **walteur-discover** decides WHAT is worth building (the validated bet + the PRD) before the plan; this skill decides how it looks. discover = the right thing · design = how it looks · walteur = how it's built.

---

## 0. THE DESIGN LAW (HARD-enforced)

**Every project with UI source ships a `DESIGN.md` at the repo root (or `design-system/MASTER.md`) BEFORE the first UI commit.**
Enforced mechanically: `walteur-kit/hooks/design-gate.sh` (dispatched by ship-gate) exit-2 blocks any ship while UI files exist without a non-stub design contract (≥10 non-empty lines + real color tokens — a `touch DESIGN.md` does not satisfy the law). Detect-or-SKIP: projects with zero UI files are untouched.

Why a file, not vibes: `AGENTS.md` tells the agent how to BUILD; `DESIGN.md` tells it how the result should LOOK AND FEEL. Without the contract every screen re-invents the palette and the output converges on generic AI-slop.

## 1. THE TWO MODES (apple-skills split — never blur them)

| Mode | Output | When |
|---|---|---|
| **CONSULTANT** | design decisions + rationale + trade-offs. **ZERO code.** | "what style?", "review this design", fork between directions, pre-PLAN advice to the senior panel |
| **CRAFTSMAN** | code to the bar, governed by DESIGN.md | implementing screens/components after the contract exists |

Consultant recommends; Tony (or the WALTEUR Chief) decides; Craftsman executes. A Craftsman who starts inventing design mid-task must stop and re-enter Consultant mode.

## 1.5 CRAFT ENGINES — the chained kit-native skills (resolved against `walteur-kit/skill-index.json`)

WALTEUR-DESIGN is the **governor** (contract · gate · modes · anti-slop law); it does not re-implement craft. CRAFTSMAN mode **chains the installed skill(s) that fit the Design Read (§2)** — these are the execution engines, always run *under* this skill's DESIGN.md contract and anti-slop gate, never standalone.

> **S033 correction:** earlier versions of this file mandated a `Leonxlnx/taste-skill` engine chain
> (`design-taste-frontend` et al.) "installed at `.agents/skills/`" — that install never happened; the
> mandate was a dangling reference (a MUST-chain skill that could never fire). It is retracted here and
> repointed at the craft skills that actually resolve in `walteur-kit/skill-index.json` today.
> `design-gate.sh --check-skills` (and the ship-path dispatch) now verifies every skill this section names
> exists in the index — a future dangling mandate fails LOUD instead of silently never firing.

**Default engine (the floor — never skipped):** for **ANY interface or UI build**, CRAFTSMAN mode MUST chain `loopkit-design-system` (kit-native, `walteur-kit/skills/loopkit-design-system.json`) as the craft engine — it is the intentional-vs-generic-frontend discipline the index carries for `has_ui` builds. A more specific engine from the table below is chosen only when it fits the Design Read better; `loopkit-design-system` is always the minimum. The DESIGN.md contract + `design-gate.sh` remain the HARD floor regardless of which engine runs.

| Need (from the Design Read) | Chain this skill |
|---|---|
| Any UI build — anti-generic default | `loopkit-design-system` |
| Brand voice / palette / identity consistency | `org-brand-dna` |
| Overall craft & polish judgment (taste pass) | `org-taste` |
| UI/UX discipline (states, flows, information architecture) | `org-uiux-discipline` |
| Interaction/motion craft (hover, transitions, feedback) | `org-interaction-craft` |
| Accessibility pass (WCAG floor) | `loopkit-a11y-pass` |
| Loading / empty / error state coverage | `loopkit-loading-empty-error-states` |

Rules of the chain (no duplication, no bypass):
- A craft skill's anti-default discipline **EXTENDS `anti-slop-ui.sh`** — it is advisory to Consultant; `design-gate.sh` + `anti-slop-ui.sh` stay the mechanical HARD floor.
- `org-brand-dna` is REQUIRED breadcrumb-fail-closed by `skill-router.mjs` on any `has_ui` build (skill-readiness enforces it at ship). The rest of this table is chosen per the Design Read, not all run every time.
- Reference-image / screenshot work still feeds the **§6 screenshot-verify loop** (generate the target board → build → diff); it never skips that loop regardless of which craft skill authored it.
- Prefer one primary engine per task (pick from the Design Read) plus `loopkit-a11y-pass` / `loopkit-loading-empty-error-states` as the state/a11y floor — WALTEUR's one-skill-per-lane / anti-bloat discipline; do not run the whole table in parallel.

## 2. DESIGN PRE-FLIGHT (before writing DESIGN.md — commit to a BOLD direction)

**First, the one-line Design Read** (this skill's own pre-flight move, §1.5-native): *"Reading this as: &lt;page kind&gt; for &lt;audience&gt;, with a &lt;vibe&gt; language, leaning toward &lt;design system / aesthetic family&gt;."* This single line picks the craft engine (§1.5) and anchors the answers below. If the brief genuinely forks, ask exactly ONE question; otherwise declare the read and proceed.

Answer in one batch, write answers into DESIGN.md's description:
1. **Purpose** — what job does this interface do, for whom?
2. **Tone** — pick 3 adjectives (e.g. calm/dense/precise vs warm/playful/loud). The palette and type follow from these.
3. **Inspiration** — name 1–2 reference products (or a style seed, §3). Steal their *discipline*, not their pixels.
4. **Differentiation** — the ONE visual move that makes this product recognizable (Linear: void-black + one indigo; Stripe: gradient mesh; Notion: ink-on-paper).
5. **Bold direction** — intentionality, not intensity. A restrained system applied ruthlessly beats a loud one applied randomly.

Skipping pre-flight = the #1 cause of generic output. `/adhd` the direction if genuinely forked; real forks → WALTEUR §5.3 debate → ADR.

## 3. THE DESIGN.md CONTRACT (Google Stitch / awesome-design-md schema)

Structure — YAML token frontmatter + 9 prose sections:

```markdown
---
version: alpha
name: <project>
description: <mood paragraph — the pre-flight answers distilled>
colors:            # semantic names → hex. ONE accent. Surface ladder. Ink tiers.
  primary: "#5e6ad2"
  canvas: "#010102"
typography:        # full hierarchy: display→mono, family/size/weight/lineHeight/letterSpacing
rounded:           # closed radius scale {0,4,6,8,12,16,9999}
spacing:           # 4px scale
components:        # per-component specs referencing tokens: "{colors.primary}" — NEVER raw hex in components
---
1. Visual Theme & Atmosphere      5. Layout Principles (grid, max-width, whitespace)
2. Color Palette & Roles          6. Depth & Elevation (numbered levels TABLE)
3. Typography Rules               7. Do's and Don'ts (explicit anti-patterns)
   + Note on Font Substitutes     8. Responsive Behavior
   (proprietary → free: Inter/Geist)  9. Agent Prompt Guide (quick tokens + ready prompts)
4. Component Stylings (with states)
```

Rules: components reference tokens via `{colors.x}` interpolation — re-themable, internally consistent. Every proprietary font gets a free substitute named. Section 7 is mandatory — guardrails reduce drift more than any positive spec.

**Persistence (ui-ux-pro-max pattern):** large projects use `design-system/MASTER.md` + `design-system/pages/<page>.md` — page files override Master, survive sessions and `/clear`. Never re-decide a token mid-project; edit the contract, then the code.

**Style seeds (MIT, fetch raw):** `https://raw.githubusercontent.com/VoltAgent/awesome-design-md/main/design-md/<brand>/DESIGN.md` — proven starting points: `linear.app` (dark precision) · `vercel.com` (mono minimal) · `stripe.com` (fintech gradient) · `notion.so` (warm document) · `claude.ai` (calm AI). Seed → adapt tokens to the pre-flight → it becomes YOURS; never ship a seed verbatim.

## 4. CRAFTSMAN BAR (what governed code must satisfy)

- **Implementation floor = WALTEUR P06 + P02:** shadcn/ui primitives (Radix), Tailwind-only, tokens from the theme layer; every component ships Default + Loading + Error stories with a play fn.
- **One accent color.** Weight-based type hierarchy. Closed token scales — if a value isn't in DESIGN.md, it doesn't exist.
- **a11y floor WCAG 2.1 AA:** contrast ≥4.5:1 (3:1 large/UI), full keyboard, visible focus, reduced-motion respected, touch targets ≥44pt.
- **Every screen: loading / empty / error states** — empty states carry a next action; error states carry a recovery affordance.
- **Motion:** spring/physics, exit faster than enter, purposeful only.
- **Dark mode first** when the contract is dark-canvas — design dark, adapt light, not the reverse.

## 5. ANTI-SLOP TABLE (instant Consultant VETO — extends anti-slop-ui.sh)

| Slop signature | Instead |
|---|---|
| purple/indigo gradient on everything | one accent from DESIGN.md, flat or ONE intentional gradient |
| emoji as icons (🚀 in a button) | icon set (lucide), consistent stroke |
| evenly distributed color | 90/9/1 — canvas/structure/accent |
| system-default type everywhere | the contract's hierarchy, real weights |
| `Something went wrong` | specific, recoverable error copy |
| lorem ipsum / Acme / John Doe | realistic domain content |
| glass/blur/shadow on everything | elevation TABLE — earn each level |
| arbitrary `w-[317px]` pixel values | closed spacing scale |
| centered-card-with-gradient hero clone | layout derived from content priority (§2 pre-flight) |
| hand-rolled Button/Dialog | shadcn primitive (P06) |

Industry guardrails: no AI-purple for banking; no playful bounce for medical; no dense data-grid defaults for consumer onboarding. Match tone to domain (pre-flight #2).

## 6. SCREENSHOT-VERIFY LOOP (closes EVERY UI task — no exceptions)

```
IMPLEMENT → CAPTURE → JUDGE → ITERATE (≤3) → EVIDENCE
```
1. **CAPTURE** — real pixels, fresh: web → playwright (`browser_take_screenshot`, plus a11y-tree snapshot for semantics); iOS → `xcrun simctl io booted screenshot`. Light AND dark if both shipped. Key states (loading/empty/error), not just happy path.
2. **JUDGE** against: ① matches DESIGN.md tokens? ② §5 slop-free? ③ §4 bar met? ④ **"Would I screenshot this to show a friend?"** — the share-worthy test. ⑤ Apple-keynote: standing ovation or polite applause?
3. **ITERATE** — fix the weakest judged element; re-capture. Cap 3 cycles, then escalate to Consultant mode (the direction, not the pixels, is wrong).
4. **EVIDENCE** — the final screenshot path goes in the task's verification record. "UI done" without a captured screenshot = an overclaim (WALTEUR §1).

## 7. PRE-DELIVERY DESIGN QA (the checklist — priority-ordered, ui-ux-pro-max taxonomy)

| Priority | Check |
|---|---|
| CRITICAL | contrast AA · keyboard path · focus visible · touch ≥44pt · all states present |
| HIGH | tokens match DESIGN.md (zero off-contract hex/spacing) · responsive at 360/768/1280 · dark+light coherent |
| MEDIUM | motion respects reduced-motion · inline validation on forms · scrim 40–60% on overlays · focus moves on route change |
| LOW | charts: direct labeling > legends · empty-state illustration tone-matched |

Run before the WALTEUR senior-uiux review — this checklist is the Craftsman's self-critique; the senior's cite-or-VETO rubric is the independent gate.

## 8. INTEGRATION MAP (how this composes with WALTEUR)

| WALTEUR piece | WALTEUR-DESIGN role |
|---|---|
| §2 confirm / §4 PLAN | Consultant pre-flight feeds the design doc; DESIGN.md is written in PLAN phase, before BUILD |
| gate-guard (plan-before-build) | design-gate.sh is its design twin (HARD, detect-or-SKIP) |
| P02 stories / P06 shadcn / anti-slop-ui.sh | the implementation floor Craftsman codes to |
| senior-uiux rubric (cite-or-VETO) | independent review of Craftsman output |
| §5.3 debate → ADR | real design forks (two surviving directions) get debated, not averaged |
| §3 VERIFY (playwright) | §6 screenshot loop is the UI half of VERIFY |
| /adhd | direction ideation when the pre-flight forks |

## 9. SCALING

| Job | Design overhead |
|---|---|
| backend/CLI only | none — design-gate SKIPs |
| 1-component tweak | obey existing DESIGN.md + §6 loop on the touched screen |
| new screens, existing product | page-override file + §6 + §7 |
| new product | full pre-flight → DESIGN.md → Consultant sign-off → Craftsman |

---

*Provenance: synthesizes VoltAgent/awesome-design-md (DESIGN.md standard, MIT), nextlevelbuilder/ui-ux-pro-max-skill v2.5 (design-system-first, persistence, taxonomy, MIT), vabole/apple-skills v1.0.11 (modes split, screenshot loop, pre-flight, anti-slop, MIT). Optional power-ups, install as plugins if wanted: `ui-ux-pro-max` (BM25 style/palette search engine, needs Python 3) · `apple-skills` (iOS 26/Liquid Glass specifics). By Tony Walteur.*
