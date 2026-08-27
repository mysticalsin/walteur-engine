# Cadence — Design System

The design contract for Cadence, a calm single-purpose focus timer. Every screen is built from the
tokens below. If a value is not in this file, it does not belong in the product. The north star is
Apple-grade restraint: one job, done with air, rhythm, and quiet confidence — never decorated.

## Principles

- One primary action on screen at any moment. The timer is the hero; everything else recedes.
- Calm over clever. No gradients-as-decoration, no emoji, no marketing verbs. Content is the interface.
- Motion is feedback, not spectacle: short, ease-out, and it always explains a state change.
- Light and dark are first-class, driven by the viewer's system preference.

## Color tokens (semantic, HSL — never raw hex in components)

All color lives in CSS custom properties on `:root`, redefined under `prefers-color-scheme: dark`.
Components reference `var(--color-*)` only.

- `--color-bg` — app canvas.
- `--color-surface`, `--color-surface-2` — cards and raised wells.
- `--color-border`, `--color-border-strong` — hairlines and dividers.
- `--color-fg`, `--color-fg-muted`, `--color-fg-subtle` — text hierarchy (primary / secondary / tertiary).
- `--color-accent`, `--color-accent-fg`, `--color-accent-weak` — the single brand blue, its on-color, and its tint.
- `--color-track` — the timer ring's unfilled arc.
- `--color-success`, `--color-danger` — completion and destructive affordances only.
- `--color-focus` — the keyboard focus ring, tuned for contrast in both themes.

## Typography — tight type scale

System font stack (`-apple-system, "SF Pro"...`). Seven intentional steps, exposed as tokens and never
ad-hoc: `--text-xs 12px`, `--text-sm 13px`, `--text-base 15px`, `--text-md 17px`, `--text-lg 20px`,
`--text-xl 28px`, `--text-display 64px`. Weights are limited to 400 / 500 / 600. The mono clock uses
tabular figures so digits never shift width as they tick.

## Spacing — 4 / 8pt grid

Spacing is exposed as `--space-*` tokens, every value a multiple of 4: 4, 8, 12, 16, 20, 24, 32, 40,
48, 64. Nothing sits off-grid; the vertical rhythm of the whole page is a stack of these steps.

## Radius & elevation

Radii: `--radius-sm 8px`, `--radius-md 12px`, `--radius-lg 20px`, `--radius-full`. Elevation is soft and
sparse — two shadow tokens (`--shadow-sm`, `--shadow-md`) built from low-alpha HSL, used only on the
timer card and floating controls. Surfaces are separated by hairline borders first, shadow second.

## Motion

Durations are tokens: `--dur-fast 120ms`, `--dur-base 180ms`, `--dur-slow 260ms`, all on
`--ease-out cubic-bezier(0.22, 0.61, 0.36, 1)`. Transitions run on hover, press, focus, and the ring's
progress. New session rows animate in with a 180ms fade-and-rise. Everything collapses to near-zero
under `prefers-reduced-motion: reduce`.

## Accessibility floor

WCAG 2.1 AA: body text holds at least 4.5:1 contrast in both themes; the app is fully keyboard-operable
with a visible `--color-focus` ring; touch targets are at least 44px. Timer state changes are announced
through a polite `aria-live` status line rather than by spamming every ticking second to assistive tech.

## Don'ts

- No purple/indigo decorative gradients, no gradient text, no glassmorphism blur stacks.
- No emoji in buttons or copy; use crisp inline SVG icons that inherit `currentColor`.
- No raw hex or inline layout styles in components — tokens only.
- No sluggish fades; interaction motion stays under 300ms.
- No fake data, no "Something went wrong", no placeholder lorem.
