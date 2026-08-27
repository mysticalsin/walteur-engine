# Design contract (selftest baseline)
<!-- SELFTEST BASELINE FIXTURE — this is the framework repo's own design contract, NOT a product's.
     It looks like a stub. It is load-bearing: 12 hooks read this file by name —
     design-gate.sh · design-depth-gate.sh · apple-grade-design-gate.sh · anti-slop-ui.sh ·
     product-standard-gate.sh · enterprise-blueprint-gate.sh · ship-gate.sh · scoreboard-gate.sh ·
     qa-contract-gate.sh · outcome-eval-gate.sh · audit-contract-gate.sh · self-improvement-gate.sh
     (re-list them with: grep -rl 'DESIGN\.md' walteur-kit/hooks/*.sh).
     REPRODUCED: with a UI file present and this file removed, `design-gate.sh <dir>` exits 2
     ("1 UI file(s) but NO design contract"); restoring it exits 0. Do not delete, empty, or strip the
     colors/typography keys — design-gate rejects a `touch`-stub.
     There is NO walteur-kit/ copy of this file: it is root-only (unlike PLAN.md, which has a
     walteur-kit/PLAN.md body mirror). Real product design systems live in each
     field-runs/<app>/DESIGN.md.
     Kept as an HTML comment so no gate's line/key parsing is disturbed. -->
colors:
  primary: "#5e6ad2"
  canvas: "#010102"
typography:
  body: Inter 16/24
components:
  button-primary: "{colors.primary}"
layout: 4px spacing scale
elevation: flat
donts: no purple gradients
