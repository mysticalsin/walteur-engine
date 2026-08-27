# PUBLISH-RUNBOOK — the field-proven "external ship" routes

This file exists because the WALTEUR engine has a hard rule: **it never ships anything
externally on its own.** Every route below requires Tony's own hands on the keyboard
(`npm login`, `npm publish`, `gh repo create ... --push`, GitHub Pages enablement). The
engine stages everything up to the consent boundary and stops.

> CONSENT: every command in this file is run by **Tony**, never by the engine. The engine
> verified (2026-07-01) that `npm whoami` is unauthenticated (`ENEEDAUTH`) and that `gh` IS
> already authenticated as `mysticalsin` with `repo`/`workflow` scopes — meaning a public
> GitHub push needs **zero new credentials**, only Tony typing the command himself.

Current state — **THREE** publish-ready artifacts (any one of them, published, breaks the
field-proven cap; more than one is better because they span domains). Artifacts A and B were
verified on 2026-07-01 and their credential facts have **not** been re-checked since — re-run
`npm whoami` / `gh auth status` before you type a publish command. Artifact C (route 4) was
staged 2026-07-25 and is the cheapest of the three: the CI wiring already exists in this repo,
so it needs a settings toggle rather than a login.

**Artifact A — `walteur-jsonlint`** (rescued 2026-07-01):
- Package: `field-runs/jsonlint-cli/` (npm name `walteur-jsonlint`, dual bin also installs
  as `jsonlint-cli`)
- Tests: `node --test` → **247/247 pass, exit 0** (re-verified in this location 2026-07-01)
- Pack: `npm pack --dry-run` → **16 files**, ~41 kB

**Artifact B — `walteur-humansize`** (built end-to-end by the walteur.js ENGINE 2026-07-02,
then brought to genuine ship-quality):
- Package: `field-runs/engine-humansize/` (npm name `walteur-humansize`)
- Tests: `node --test` → **234/234 pass, exit 0** (independently reproduced)
- Pack: `npm pack --dry-run` → `walteur-humansize-1.0.0.tgz`, ~28 kB packed / 80.6 kB unpacked
- Zero runtime deps, MIT, ESM, `files[]` allowlist, `bin/humansize.mjs`
- The engine's own terminal audit had marked it `SHIPPABLE:false` on ONE real doc bug (the
  `HumansizeError` constructor examples in AGENTS.md/code-style.md showed `(code, input,
  message)` but the shipped constructor is `(code, message, input)`) — that is now FIXED, so
  the artifact matches its own docs and is genuinely publishable.
- To publish: `cd "field-runs/engine-humansize" && npm login && npm publish --access public`
  → `https://www.npmjs.com/package/walteur-humansize`.
- git history intact: commit `9afda16` (BOM round-trip fix + publish prep) and `65bcd30`
  (rename — `jsonlint-cli` was taken on the npm registry by an unrelated 2016 package,
  `walteur-jsonlint` confirmed 404/available)
- No git remote configured yet (`git remote -v` is empty in `field-runs/jsonlint-cli/`)
- `package.json` now carries placeholder `repository`/`homepage`/`bugs` fields pointing at
  `github.com/TODO-Tony/walteur-jsonlint` — **replace `TODO-Tony` with your real GitHub
  handle/org before or right after the repo push** (route 2 below tells you where).

**Artifact C — `design-proof-app` ("Cadence") as a GitHub Pages site** (staged 2026-07-25,
commit `a1ec274`):
- Built output committed at `docs/live/design-proof-app/` (`index.html` 688 B + `assets/`),
  built with `base=/walteur-framework/live/design-proof-app/` — the asset paths inside
  `index.html` are already absolute against that base, so the site only resolves under a repo
  named `walteur-framework`. Rename the repo and you must rebuild with a matching `base`.
- `docs/.nojekyll` present; `.github/workflows/pages.yml` publishes `docs/` via
  `actions/upload-pages-artifact` + `actions/deploy-pages` on every push to `main` that touches
  `docs/**`, and on `workflow_dispatch`.
- **Not published yet, and deliberately not claimed.** The only missing step is Tony enabling
  Pages (route 4). Nothing is written into `field-runs/SHIPPED.md` until the URL answers 200 to
  a third party — see route 4's verify step.

---

## Route 1 — npm publish (fastest path to a public package URL)

Two commands, run from `field-runs/jsonlint-cli/`:

```sh
cd "field-runs/jsonlint-cli"
npm login
npm publish --access public
```

What happens:
- `npm login` opens a browser/OTP flow for your npm account. Nothing is published by this
  step alone.
- `npm publish --access public` packs the same 16 files verified above (bin/, src/,
  README.md, LICENSE) and pushes `walteur-jsonlint@1.0.0` to the public registry.
- Expected result: `https://www.npmjs.com/package/walteur-jsonlint` goes live, installable
  via `npm install -g walteur-jsonlint` (or `npx walteur-jsonlint`), with either
  `walteur-jsonlint` or `jsonlint-cli` as the runnable command (dual `bin` entries).

Verify after publishing (anyone can run this, not just Tony):

```sh
npm view walteur-jsonlint version
npm view walteur-jsonlint dist.shasum
```

The shasum should match the one recorded in this repo's evidence trail (`70e67b5448b...` at
rescue time — re-run `npm pack --dry-run` locally to compare if the package changes before
you publish).

---

## Route 2 — GitHub public repo (needs consent only — gh is already authenticated)

`gh auth status` already shows account `mysticalsin` with `repo`+`workflow` scopes, so this
route needs **no login step at all**, just Tony's go-ahead to make it public:

```sh
cd "field-runs/jsonlint-cli"
gh repo create walteur-jsonlint --public --source . --push
```

What happens:
- Creates `github.com/mysticalsin/walteur-jsonlint` (swap `mysticalsin` for whichever
  account/org you want to own it — check `gh auth status` first if you have more than one).
- Pushes the existing local git history (including commits `9afda16` and `65bcd30`) as the
  initial push — the commit history that shows the honest BOM-bug-found-and-fixed trail
  ships with the repo.
- After the repo exists, update the placeholder `TODO-Tony` in `package.json`
  (`repository`/`homepage`/`bugs`) to the real owner/repo and commit that fix (`git commit`
  + `git push`) so the npm listing (route 1) links to a real, resolving source repo.

Verify:

```sh
gh api repos/<owner>/walteur-jsonlint --jq '.html_url,.pushed_at'
```

---

## Route 3 — GitHub Pages for `support-risk-command-center` (second public URL, different domain)

`field-runs/support-risk-command-center/` is fully client-side (`index.html`, no server, no
build step) — it can go live as a static site the moment a repo exists for it:

```sh
cd "field-runs/support-risk-command-center"
gh repo create support-risk-command-center --public --source . --push
gh api -X POST repos/<owner>/support-risk-command-center/pages \
  -f "source[branch]=main" -f "source[path]=/"
```

What happens:
- Same pattern as route 2: creates and pushes a public repo (swap `<owner>` for the real
  GitHub account, same as above).
- The second command enables GitHub Pages against the `main` branch root — no build,
  because the dashboard is already static HTML/CSS/JS.
- Expected live URL: `https://<owner>.github.io/support-risk-command-center/`

Verify (from any machine, not this box):

```sh
curl -sI "https://<owner>.github.io/support-risk-command-center/" | head -1
```
Expect `HTTP/2 200`. First load after enabling Pages can take a few minutes to propagate.

---

## Route 4 — enable Pages on THIS repo (cheapest route: no login, no new repo)

The wiring already exists (`.github/workflows/pages.yml`, `docs/.nojekyll`, built output in
`docs/live/design-proof-app/`). What is missing is one repository setting only Tony can flip:

**Settings → Pages → Build and deployment → Source: `GitHub Actions`.**

Then trigger the workflow (or push anything under `docs/`):

```sh
gh workflow run pages.yml
gh run list --workflow=pages.yml --limit 1
```

Expected live URL: `https://<owner>.github.io/walteur-framework/live/design-proof-app/`
(`<owner>` = the account that owns this repo; the built asset paths are pinned to a repo named
`walteur-framework`).

Verify — **from another machine or a phone, not this box** (a local 200 proves nothing about
third-party reachability):

```sh
curl -sI "https://<owner>.github.io/walteur-framework/live/design-proof-app/" | head -1
```

Expect `HTTP/2 200`. Only after that 200 is observed does a `field-runs/SHIPPED.md` row get
written — the FR-8 block's `Honest limits` cell says `local-only, NOT deployed to a public URL`
and it must stay that way until the URL answers.

---

## After any route: update the ledger

Once a route above is actually run, record the result in
`field-runs/SHIPPED.md` (FR-7 row or a new external-ship block) with the real URL, and — if
you want it machine-checked going forward — add a row that
`walteur-kit/hooks/field-ship-verify-gate.sh` can verify (see that gate's `--help`/header for
the exact row shape it expects). Until a route above runs, `field-runs/SHIPPED.md` should
keep saying **NO external ship**, and the gate will report `NOT_APPLICABLE` until an
external-URL row exists to check.

**State as of 2026-07-25:** still **no external ship**. Routes 1-3 are unrun; route 4 is staged
in CI but Pages has not been enabled, so no URL has been curled for a 200. Every `Live URL`
cell in `field-runs/SHIPPED.md` correctly reads local-only. Staging a route is not shipping it —
do not let a green workflow file read as a ship.
