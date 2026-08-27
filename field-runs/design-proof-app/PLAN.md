# PLAN — Cadence

A calm, single-page focus-session timer with a persistent log of the sessions finished today. Built with
Vite + React + TypeScript. No backend: state lives in the component tree and survives reloads via
`localStorage`. Scope is deliberately small — one screen, one job, done to an Apple-grade craft bar.

## Product surface

- A focus timer with a circular progress ring and a large tabular-figures clock.
- Duration presets (Focus 25, Deep Work 50, Short Break 5) selectable while idle.
- Start / Pause / Reset controls, plus "Finish early" once at least a minute of real work has elapsed.
- A "Today" log: each completed (or finished-early) session is recorded with its label, minutes, and time.
- A summary strip: sessions completed and total minutes focused today.

## Timing model

The countdown is anchored to a wall-clock `endAt` timestamp, not a naive decrementing counter, so it
stays accurate across tab throttling and re-renders. A 250ms interval recomputes the remaining whole
seconds from `endAt - Date.now()`; reaching zero completes the session, logs it, and returns the timer to
idle. Pausing freezes the remaining seconds; resuming re-derives a fresh `endAt`.

### Layer depth: frontend

Every state Cadence can be in ships a real, considered view — this is the frontend depth the build must
carry, not an afterthought. The timer models an explicit state machine (idle, running, paused, completed)
and each state renders distinct, purposeful controls: idle offers presets and Start; running swaps to
Pause plus Finish-early; paused offers Resume, Reset, and Finish-early. The Today log has a genuine empty
state that names the next action ("Start your first block") rather than showing a blank void, a populated
state that animates each new row in, and it never renders a bare "something went wrong". Accessibility is
a floor, not a polish pass: the interface is fully keyboard operable, every interactive target clears
44px, focus is always visible via a dedicated focus-ring token, contrast holds at WCAG 2.1 AA (at least
4.5:1) in both light and dark themes, and timer transitions are announced through a polite aria-live
status region instead of spamming assistive technology with every ticking second. Motion is feedback:
short ease-out transitions on hover, press, focus, and ring progress, all of which collapse to near-zero
under prefers-reduced-motion. Loading is instant (no network), so the design work goes into the empty and
error-adjacent states — an invalid persisted log is discarded safely rather than crashing the screen.

### Layer depth: persistence

Today's sessions serialize to `localStorage` under a single namespaced key. Reads are defensive: a
missing, malformed, or schema-mismatched payload is treated as "no sessions yet" rather than throwing, so
a corrupted store can never white-screen the app. Only sessions completed today are surfaced; the loader
filters stale entries by calendar day on read. Writes are debounced through React effect flow so the
store always reflects the rendered state.

## Non-goals

No accounts, no sync, no notifications, no sound. Those are real features but out of scope for this build,
which exists to prove the design-craft bar on a genuine, shippable React product.
