// test/dom-a11y-contract.test.js — the a11y CONTRACT for the DOM layer (Task 4).
//
// The DOM layer (index.html + src/app.js + src/styles.css) is deliberately NOT
// exercised through a DOM (no jsdom — that would add a dependency and break the
// zero-dep Definition of Done). Instead this suite makes STATIC assertions over the
// shipped source text: the structural + wiring invariants that the manual keyboard
// pass and the T6 a11y review depend on. These checks are cheap, deterministic, and
// catch the regressions that are easy to introduce here — a second role=status
// region, a stray innerHTML sink, window.localStorage read in two places, a missing
// tabindex="-1" delete-focus anchor, etc.
//
// TDD note: written BEFORE index.html / src/app.js / src/styles.css exist. It must
// FAIL (ENOENT) on a clean checkout, then PASS once the DOM layer is shipped.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..');

const read = (rel) => readFileSync(join(root, rel), 'utf8');

// Strip HTML comments so structural/positional assertions measure the real markup, not
// explanatory prose inside <!-- --> blocks (which may legitimately name <ul>, tabindex, etc.).
const stripHtmlComments = (html) => html.replace(/<!--[\s\S]*?-->/g, ' ');

// Count non-overlapping matches of a global regex.
const countMatches = (src, re) => (src.match(re) || []).length;

// Strip JS comments (block + line) so a wiring assertion measures EXECUTABLE code, not
// documentation prose that legitimately names an API in a JSDoc block. String literals are
// KEPT (a setAttribute('role', …) check needs the literal), unless the caller also strips
// strings for identifier-level checks.
const stripComments = (src) =>
  src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');

// Additionally strip string literals — for checks that count identifier references
// (e.g. window.localStorage) where a same-named substring inside a string is not a use.
const stripCommentsAndStrings = (src) =>
  stripComments(src).replace(/(['"`])(?:\\.|(?!\1)[^\\])*\1/g, ' ');

test('dom: the three owned files exist and are non-empty', () => {
  for (const rel of ['index.html', 'src/app.js', 'src/styles.css']) {
    const src = read(rel);
    assert.ok(src.trim().length > 0, `${rel} must be non-empty`);
  }
});

test('dom: index.html is a semantic, module-wired document', () => {
  const html = read('index.html');
  assert.match(html, /<!doctype html>/i, 'must declare a doctype');
  assert.match(html, /<html[^>]*\blang=/i, 'html element must carry a lang attribute');
  assert.match(html, /<h1[\s>]/i, 'must have an <h1> app title');
  assert.match(html, /<form[\s>]/i, 'must have a <form> for adding todos');
  // The form control must be labelled — a <label for> or an aria-label on the input.
  assert.ok(
    /<label\b[^>]*\bfor=/i.test(html) || /<input\b[^>]*\baria-label=/i.test(html),
    'the add input must be labelled (via <label for> or aria-label)',
  );
  // ES-module script wiring, no build step.
  assert.match(
    html,
    /<script\b[^>]*\btype=["']module["'][^>]*\bsrc=["']\.?\/?src\/app\.js["']/i,
    'must load src/app.js as type=module',
  );
  // The stylesheet is linked (relative, no CDN — must work from file://).
  assert.match(html, /<link\b[^>]*\bhref=["']\.?\/?src\/styles\.css["']/i, 'must link src/styles.css');
  // No external/CDN asset — everything is same-origin/relative for file:// support.
  assert.ok(!/https?:\/\//i.test(html.replace(/<!--[\s\S]*?-->/g, '')), 'no absolute http(s) asset URLs');
});

test('dom: exactly one persistent role=status live region, present at load', () => {
  const html = stripHtmlComments(read('index.html'));
  // Exactly one role="status" element authored in the static markup.
  assert.equal(
    countMatches(html, /role=["']status["']/gi),
    1,
    'there must be exactly ONE role=status region, authored in the HTML (never JS-created)',
  );
  // It is a <p id="status"> per the brief, and it must be empty at load (single text
  // node is added/overwritten by JS — the element itself ships with no nested markup).
  const statusEl = /<p\b[^>]*\bid=["']status["'][^>]*>([\s\S]*?)<\/p>/i.exec(html);
  assert.ok(statusEl, 'the status region must be a <p id="status"> element');
  assert.equal(
    statusEl[1].trim(),
    '',
    'the status region must be empty at load (JS overwrites its single text node)',
  );
  // app.js must NEVER create a status region — it only overwrites textContent on the
  // existing node. Guard, over comment-stripped code, against setting a role attribute via
  // setAttribute or authoring role="status"/role:'status' literally. JSDoc mentions are exempt.
  const appSrc = read('src/app.js');
  const appNoComments = stripComments(appSrc);
  assert.ok(
    !/\bsetAttribute\(\s*['"]role['"]/i.test(appNoComments),
    'app.js must not set a role attribute — the persistent role=status region lives in index.html',
  );
  assert.ok(
    !/\brole\s*[:=]\s*['"]status['"]/i.test(appNoComments),
    'app.js must not author a role=status region — the persistent one lives in index.html',
  );
});

test('dom: the delete-focus anchor is a tabindex="-1" heading above the list', () => {
  const html = stripHtmlComments(read('index.html'));
  assert.match(
    html,
    /tabindex=["']-1["']/i,
    'a tabindex="-1" focus anchor must exist for the delete-focus redirect',
  );
  // The anchor must appear textually BEFORE the <ul> list (it lives above the list).
  const anchorIdx = html.search(/tabindex=["']-1["']/i);
  const listIdx = html.search(/<ul\b/i);
  assert.ok(anchorIdx !== -1 && listIdx !== -1, 'both the anchor and the <ul> must exist');
  assert.ok(anchorIdx < listIdx, 'the tabindex="-1" anchor must come ABOVE the <ul> list');
});

test('dom: task list is a defensive role=list <ul>', () => {
  const html = stripHtmlComments(read('index.html'));
  assert.match(
    html,
    /<ul\b[^>]*\brole=["']list["']/i,
    'the <ul> must carry role="list" (defensive — Safari drops list semantics with list-style:none)',
  );
});

test('dom: three filter buttons with aria-pressed toggle semantics (ADR 2)', () => {
  const html = stripHtmlComments(read('index.html'));
  // Native <button> controls (free keyboard activation) carrying aria-pressed.
  const pressedButtons = countMatches(html, /<button\b[^>]*\baria-pressed=/gi);
  assert.ok(pressedButtons >= 3, 'there must be at least three aria-pressed filter buttons');
  // Exactly one filter starts pressed (aria-pressed="true").
  assert.equal(
    countMatches(html, /aria-pressed=["']true["']/gi),
    1,
    'exactly one filter button starts aria-pressed="true"',
  );
});

test('dom: app.js wires state.js + storage.js and passes window.localStorage in ONE place', () => {
  const app = read('src/app.js');
  // Imports the pure state layer and the storage adapter layer by relative path.
  assert.match(app, /import[\s\S]*?from\s+["']\.\/state\.js["']/, 'must import from ./state.js');
  assert.match(app, /import[\s\S]*?from\s+["']\.\/storage\.js["']/, 'must import from ./storage.js');
  // window.localStorage referenced in EXACTLY ONE place of EXECUTABLE code — the single
  // adapter injection. Comments/JSDoc that name the API for documentation don't count.
  const code = stripCommentsAndStrings(app);
  assert.equal(
    countMatches(code, /window\.localStorage/g),
    1,
    'window.localStorage must be referenced exactly once in code (the single adapter injection)',
  );
  // load() runs on start and save() runs on mutation — both must be called in code.
  assert.match(code, /\bload\s*\(/, 'app.js must call load() on start');
  assert.match(code, /\bsave\s*\(/, 'app.js must call save() on mutation');
});

test('dom: app.js renders user text safely (no innerHTML sink for todo text)', () => {
  const app = read('src/app.js');
  // Self-XSS guard (AGENTS.md §5): todo text is inserted via textContent, never
  // innerHTML. Assignment to .innerHTML is forbidden anywhere in app.js.
  assert.ok(
    !/\.innerHTML\s*=/.test(app),
    'app.js must not assign to innerHTML (use textContent to avoid self-XSS from pasted todo text)',
  );
  assert.match(app, /\.textContent\s*=/, 'app.js must set textContent (the safe text sink)');
});

test('dom: app.js implements the edit-cancel guard flag (no spurious blur save)', () => {
  const app = read('src/app.js');
  // Escape-during-edit restores text + refocuses the trigger, guarded by a cancelling
  // flag so the ensuing blur does not fire a spurious save.
  assert.match(
    app,
    /isCancelling|cancelling/i,
    'app.js must use an isCancelling guard so Escape-cancel does not trigger a blur save',
  );
  assert.match(app, /setSelectionRange/, 'edit entry must place the caret via setSelectionRange');
});

test('dom: app.js keeps aria-labels unique per item (Edit/Delete {title})', () => {
  const app = read('src/app.js');
  // The per-item action buttons carry unique, title-bearing aria-labels.
  assert.match(app, /aria-label/i, 'per-item buttons must set aria-label');
  assert.ok(
    /Edit /.test(app) && /Delete /.test(app),
    'aria-labels must be the "Edit {title}" / "Delete {title}" form',
  );
});

test('dom: styles.css ships visible focus, list-style:none, and reduced-motion honor', () => {
  const css = read('src/styles.css');
  // Visible focus ring — :focus-visible styled, and no naked `outline: none` that
  // strips the ring without a replacement.
  assert.match(css, /:focus-visible/, 'must style :focus-visible for a visible focus ring');
  assert.match(css, /list-style\s*:\s*none/, 'the list must drop native bullets (role=list is the defense)');
  assert.match(
    css,
    /prefers-reduced-motion/,
    'must honor prefers-reduced-motion',
  );
  // :has() and native nesting are the 2026 vanilla-CSS idiom for this stack.
  assert.match(css, /:has\(/, 'should use :has() (native, zero-dep — the 2026 idiom)');
});
