/**
 * @file src/app.js — the VIEW/CONTROLLER tier (ports & adapters, PLAN.md §2/§5).
 *
 * The ONLY module that touches the DOM and the ONLY place the real `window.localStorage`
 * is passed in (exactly once, at {@link STORAGE_ADAPTER}). It imports the pure mutators
 * from `./state.js` and the parameterized persistence seam from `./storage.js`, holds the
 * single source-of-truth `todos` array + `activeFilter`, and re-renders the list on every
 * mutation. All persistence flows through `save()` on each change and `load()` once at boot.
 *
 * Accessibility contract implemented here (PLAN.md §5, WCAG 2.2 AA-oriented):
 *   - Every state renders: empty (friendly message), populated, all-filtered-out
 *     (mode-specific "nothing active/done"), and save-failed (non-blocking status).
 *   - Add keeps focus in the input; toggle moves no focus; delete redirects focus to the
 *     tabindex="-1" list heading (or the add input when the list is now empty); edit swaps
 *     the label for a text input in the same slot, caret at end, Enter commits, Escape
 *     restores + refocuses the Edit trigger (guarded so the blur does not double-save),
 *     blur commits.
 *   - Per-item Edit/Delete buttons carry UNIQUE `aria-label="Edit {title}"` /
 *     `"Delete {title}"`.
 *   - Filters are an aria-pressed toggle group (exactly one pressed).
 *   - The single persistent role="status" region (authored in index.html) is only ever
 *     overwritten via textContent — terse "state + N remaining" phrasing, debounced for
 *     bulk mutations, never appended.
 *   - Todo text is inserted via textContent only — never innerHTML — so a pasted todo
 *     string can never inject markup (self-XSS guard, AGENTS.md §5).
 *
 * No framework, no build step: this file is a browser-native ES module loaded via
 * `<script type="module">` and runs unchanged from `file://`.
 */

import { add, toggle, edit, remove, filter, activeCount } from './state.js';
import { load, save } from './storage.js';

/** @typedef {import('./state.js').Todo} Todo */
/** @typedef {'all' | 'active' | 'done'} FilterMode */

/** The single localStorage key (PLAN.md §3 — the versioned envelope lives here). */
const STORAGE_KEY = 'todos.v1';

/**
 * THE ONE injection of the real browser storage. `window.localStorage` structurally
 * satisfies `storage.js`'s `{getItem,setItem}` adapter shape. This is the single line in
 * the entire app that names `window.localStorage`; every other layer stays DOM-free and
 * unit-testable under `node:test`. Do not reference it anywhere else.
 */
const STORAGE_ADAPTER = window.localStorage;

/** Debounce window (ms) for the live-region announcement, so a burst of mutations
 * collapses into a single terse announcement instead of flooding assistive tech. */
const ANNOUNCE_DEBOUNCE_MS = 150;

/**
 * The browser-side id generator injected into `state.add`. It MUST be called with `crypto`
 * as its receiver — passing the bare `crypto.randomUUID` method as `state.add`'s default
 * throws "Illegal invocation" (a native method loses its `this` when detached), so the
 * DOM layer, which owns the runtime id source, supplies a correctly-bound factory. A tiny
 * RFC-4122 v4 fallback covers the rare browser without `crypto.randomUUID` (still using
 * `crypto.getRandomValues`, never `Math.random`).
 *
 * @returns {string} A unique id for a new todo.
 */
function newId() {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID(); // called on `crypto` — correct receiver, no illegal invocation
  }
  // Fallback: RFC-4122 v4 from crypto.getRandomValues (cryptographically strong, no bias).
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

// ─── DOM handles (queried once; the document is fully parsed because this module is
//     deferred by default as type="module") ──────────────────────────────────────────

/** @type {HTMLFormElement} */
const addForm = /** @type {HTMLFormElement} */ (mustGet('add-form'));
/** @type {HTMLInputElement} */
const addInput = /** @type {HTMLInputElement} */ (mustGet('add-input'));
/** @type {HTMLUListElement} */
const listEl = /** @type {HTMLUListElement} */ (mustGet('todo-list'));
/** @type {HTMLHeadingElement} */
const listHeading = /** @type {HTMLHeadingElement} */ (mustGet('list-heading'));
/** @type {HTMLParagraphElement} */
const emptyMessage = /** @type {HTMLParagraphElement} */ (mustGet('empty-message'));
/** @type {HTMLParagraphElement} */
const statusEl = /** @type {HTMLParagraphElement} */ (mustGet('status'));
/** @type {HTMLButtonElement[]} */
const filterButtons = /** @type {HTMLButtonElement[]} */ (
  Array.from(document.querySelectorAll('.filter'))
);

/**
 * Fetch a required element by id or fail loudly. A missing node here means index.html and
 * app.js have drifted apart — a hard programmer error, not a runtime condition to paper over.
 *
 * @param {string} id
 * @returns {HTMLElement}
 */
function mustGet(id) {
  const el = document.getElementById(id);
  if (el === null) {
    throw new Error(`app.js: required element #${id} is missing from index.html`);
  }
  return el;
}

// ─── Application state (single source of truth) ──────────────────────────────────────

/** @type {Todo[]} */
let todos = [];
/** @type {FilterMode} */
let activeFilter = 'all';
/**
 * When an edit is being cancelled via Escape, this holds the id of the item whose input
 * is being torn down. The input's `blur` handler checks it and skips the commit-on-blur so
 * Escape does not fire a spurious save that would overwrite the restored text.
 * @type {string | null}
 */
let cancellingEditId = null;
/** @type {ReturnType<typeof setTimeout> | null} */
let announceTimer = null;

// ─── Persistence wiring ──────────────────────────────────────────────────────────────

/**
 * Persist the current list and, on failure, surface a non-blocking status. `save` reports
 * the outcome as a value ({ok} / {ok:false, reason}) — it never throws — so a full quota or
 * blocked storage degrades to a visible message rather than a broken UI.
 *
 * @returns {void}
 */
function persist() {
  const result = save(STORAGE_KEY, todos, STORAGE_ADAPTER);
  if (!result.ok) {
    const detail = result.reason === 'QuotaExceededError' ? 'storage is full' : result.reason;
    // Overwrite (never append) the persistent live region with the failure. This is
    // non-blocking: the in-memory list is intact; only the durable copy failed.
    announceNow(`Couldn't save — ${detail}. Your changes may not survive a reload.`);
  }
}

// ─── Rendering ───────────────────────────────────────────────────────────────────────

/**
 * Rebuild the visible list for the active filter and reconcile every derived surface:
 * the empty / all-filtered-out message, the list visibility, and the filter buttons'
 * pressed state. Called after every mutation and once at boot.
 *
 * Rendering is full-rebuild (the list is small and this keeps the code obviously correct);
 * user text is written via `textContent` only, so a pasted `<img onerror>` is inert.
 *
 * @returns {void}
 */
function render() {
  const view = /** @type {Todo[]} */ (filter(todos, activeFilter));

  // Reconcile the list children. Clearing via replaceChildren() (not innerHTML) keeps the
  // no-innerHTML invariant and drops stale listeners with the removed nodes.
  const rows = view.map(createRow);
  listEl.replaceChildren(...rows);

  reconcileEmptyState(view.length);
  reconcileFilterButtons();
}

/**
 * Show the correct zero-item message for the current state, or hide it when items are
 * visible. There are two distinct empty states and they must read differently:
 *   - the list is genuinely empty (no todos at all) → a friendly onboarding message;
 *   - the list is non-empty but the active filter hides everything → a mode-specific
 *     "Nothing active / Nothing done" so the user knows it is a FILTER, not data loss.
 * The message slot is `hidden` (removed from the a11y tree) whenever items are visible, so
 * there is no layout shift beyond the message's own single line.
 *
 * @param {number} visibleCount  Number of items shown under the active filter.
 * @returns {void}
 */
function reconcileEmptyState(visibleCount) {
  if (visibleCount > 0) {
    emptyMessage.hidden = true;
    emptyMessage.textContent = '';
    return;
  }
  emptyMessage.hidden = false;
  if (todos.length === 0) {
    emptyMessage.textContent = 'No tasks yet. Add your first one above.';
  } else if (activeFilter === 'active') {
    emptyMessage.textContent = 'Nothing active — every task is done.';
  } else if (activeFilter === 'done') {
    emptyMessage.textContent = 'Nothing done yet.';
  } else {
    // activeFilter === 'all' with items present but none visible is unreachable, but the
    // total-function discipline demands a defined branch rather than a blank slot.
    emptyMessage.textContent = 'No tasks to show.';
  }
}

/**
 * Reflect the active filter onto the button group: exactly one `aria-pressed="true"`.
 * @returns {void}
 */
function reconcileFilterButtons() {
  for (const btn of filterButtons) {
    const isActive = btn.dataset.filter === activeFilter;
    btn.setAttribute('aria-pressed', isActive ? 'true' : 'false');
  }
}

/**
 * Build one <li> row for a todo: a native checkbox (toggle), the label text, and native
 * Edit + Delete buttons with UNIQUE, title-bearing aria-labels. All user text is set via
 * textContent. The row's id is stamped on the element via a data attribute so handlers can
 * resolve the item without closing over a stale index.
 *
 * @param {Todo} todo
 * @returns {HTMLLIElement}
 */
function createRow(todo) {
  const li = document.createElement('li');
  li.className = 'todo';
  li.dataset.id = todo.id;
  if (todo.done) li.dataset.done = 'true';

  const checkbox = document.createElement('input');
  checkbox.type = 'checkbox';
  checkbox.className = 'todo__checkbox';
  checkbox.checked = todo.done;
  // A native checkbox announces its own checked-state; give it an accessible name tied to
  // the task so screen-reader users hear "buy milk, checked" not a bare "checkbox".
  checkbox.setAttribute('aria-label', todo.text);
  checkbox.addEventListener('change', () => handleToggle(todo.id));

  const label = document.createElement('span');
  label.className = 'todo__text';
  label.textContent = todo.text; // textContent — never innerHTML (self-XSS guard)

  const editBtn = document.createElement('button');
  editBtn.type = 'button';
  editBtn.className = 'todo__edit';
  editBtn.textContent = 'Edit';
  editBtn.setAttribute('aria-label', `Edit ${todo.text}`); // unique per item
  editBtn.addEventListener('click', () => enterEdit(todo.id));

  const deleteBtn = document.createElement('button');
  deleteBtn.type = 'button';
  deleteBtn.className = 'todo__delete';
  deleteBtn.textContent = 'Delete';
  deleteBtn.setAttribute('aria-label', `Delete ${todo.text}`); // unique per item
  deleteBtn.addEventListener('click', () => handleDelete(todo.id));

  li.append(checkbox, label, editBtn, deleteBtn);
  return li;
}

// ─── Mutations ───────────────────────────────────────────────────────────────────────

/**
 * Add the current input text. Mirrors state.add's empty-text guard on the client so an
 * empty/whitespace submit is a visible no-op (never a phantom item) — client validation
 * mirrors the pure layer, it is never the only check.
 *
 * @param {SubmitEvent} event
 * @returns {void}
 */
function handleAdd(event) {
  event.preventDefault();
  const text = addInput.value.trim();
  if (!text) {
    // Client guard MIRRORS state.add (empty commit === no-op). Keep focus for retry.
    addInput.focus();
    return;
  }
  const next = add(todos, text, newId); // inject the bound id factory (see newId)
  if (next !== todos) {
    todos = next;
    persist();
    render();
    announce(`Task added, ${activeCount(todos)} remaining.`);
  }
  // Clear + keep focus in the input for rapid entry (PLAN.md §5 Add behavior).
  addInput.value = '';
  addInput.focus();
}

/**
 * Toggle a todo's done flag. No focus move — the native checkbox already has focus and
 * keeping it there is the expected behavior for a checkbox toggle.
 *
 * @param {string} id
 * @returns {void}
 */
function handleToggle(id) {
  const next = toggle(todos, id);
  if (next === todos) return; // unknown id — no-op
  todos = next;
  persist();
  render(); // re-render restores focus? No — checkbox is recreated; restore it explicitly.
  restoreFocusToCheckbox(id);
  announce(`${activeCount(todos)} remaining.`);
}

/**
 * After a toggle re-render, the checkbox node was recreated, so move focus back to the new
 * checkbox for the same item to avoid stranding focus on <body>. If the item is now hidden
 * by the active filter, fall back to the list heading (a stable, present anchor).
 *
 * @param {string} id
 * @returns {void}
 */
function restoreFocusToCheckbox(id) {
  const row = listEl.querySelector(`li[data-id="${cssEscape(id)}"]`);
  const checkbox = row?.querySelector('.todo__checkbox');
  if (checkbox instanceof HTMLElement) {
    checkbox.focus();
  } else {
    listHeading.focus(); // item filtered out of view — land on a stable anchor
  }
}

/**
 * Delete a todo and redirect focus per PLAN.md §5: to the tabindex="-1" list heading
 * (stable across renumbering), or to the add input when the list is now empty.
 *
 * @param {string} id
 * @returns {void}
 */
function handleDelete(id) {
  const next = remove(todos, id);
  if (next === todos) return; // unknown id — no-op
  todos = next;
  persist();
  render();
  if (todos.length === 0) {
    addInput.focus(); // list is empty — the only sensible next target
  } else {
    listHeading.focus(); // stable anchor above the list — never a renumbered sibling
  }
  announce(`Task deleted, ${activeCount(todos)} remaining.`);
}

/**
 * Set the active filter and re-render. The pressed state is reconciled inside render().
 *
 * @param {FilterMode} mode
 * @returns {void}
 */
function handleFilter(mode) {
  if (mode === activeFilter) return;
  activeFilter = mode;
  render();
}

// ─── Inline edit lifecycle ─────────────────────────────────────────────────────────────

/**
 * Enter edit mode for one item: swap the static label for a text <input> in the SAME slot,
 * prefilled with the current text, focused with the caret at the end (setSelectionRange).
 * Enter commits, Escape cancels (restore + refocus the Edit trigger), blur commits.
 *
 * @param {string} id
 * @returns {void}
 */
function enterEdit(id) {
  const todo = todos.find((t) => t.id === id);
  const row = listEl.querySelector(`li[data-id="${cssEscape(id)}"]`);
  const label = row?.querySelector('.todo__text');
  if (!todo || !(row instanceof HTMLElement) || !(label instanceof HTMLElement)) return;

  const input = document.createElement('input');
  input.type = 'text';
  input.className = 'todo__edit-input';
  input.value = todo.text;
  input.setAttribute('aria-label', `Edit ${todo.text}`);

  /** Commit-on-blur guard: set true while Escape tears the input down. */
  let didFinish = false;

  const commit = () => {
    if (didFinish) return;
    didFinish = true;
    const next = edit(todos, id, input.value);
    if (next !== todos) {
      todos = next;
      persist();
    }
    render();
    // After commit the row was rebuilt (or removed, if the edit emptied the text). Land
    // focus somewhere sensible: the item's Edit button if it still exists, else the heading.
    focusEditButtonOrHeading(id);
    announce(`${activeCount(todos)} remaining.`);
  };

  const cancel = () => {
    if (didFinish) return;
    didFinish = true;
    // Mark the cancel so the blur handler (which fires as we tear the input down) skips its
    // own commit — otherwise Escape would restore the text AND then a blur-save would run.
    cancellingEditId = id;
    render(); // rebuild the row from unchanged state → the original text is restored
    focusEditButtonOrHeading(id); // refocus the Edit trigger, never a stranded node
    cancellingEditId = null;
  };

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      commit();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      cancel();
    }
  });

  input.addEventListener('blur', () => {
    // Blur commits — UNLESS this blur is the side effect of an Escape cancel for THIS item.
    if (cancellingEditId === id) return;
    commit();
  });

  // Swap label → input in the same slot, then focus + caret-at-end.
  label.replaceWith(input);
  input.focus();
  const end = input.value.length;
  input.setSelectionRange(end, end);
}

/**
 * After an edit commit/cancel re-render, land focus on the item's Edit button if the item
 * still exists, otherwise on the stable list heading (the item was deleted via empty edit).
 *
 * @param {string} id
 * @returns {void}
 */
function focusEditButtonOrHeading(id) {
  const row = listEl.querySelector(`li[data-id="${cssEscape(id)}"]`);
  const editBtn = row?.querySelector('.todo__edit');
  if (editBtn instanceof HTMLElement) {
    editBtn.focus();
  } else {
    listHeading.focus();
  }
}

// ─── Live region ───────────────────────────────────────────────────────────────────────

/**
 * Announce terse state to the persistent role="status" region, debounced so a burst of
 * mutations collapses to one announcement. The region's single text node is OVERWRITTEN
 * (never appended) — assistive tech re-reads the atomic region on change.
 *
 * @param {string} message
 * @returns {void}
 */
function announce(message) {
  if (announceTimer !== null) clearTimeout(announceTimer);
  announceTimer = setTimeout(() => {
    announceTimer = null;
    statusEl.textContent = message; // overwrite, never append
  }, ANNOUNCE_DEBOUNCE_MS);
}

/**
 * Announce immediately (no debounce) — used for the save-failed status, which should not be
 * swallowed or delayed behind a pending debounce.
 *
 * @param {string} message
 * @returns {void}
 */
function announceNow(message) {
  if (announceTimer !== null) {
    clearTimeout(announceTimer);
    announceTimer = null;
  }
  statusEl.textContent = message; // overwrite, never append
}

// ─── Small DOM helpers ─────────────────────────────────────────────────────────────────

/**
 * Escape a string for safe use inside a CSS attribute selector. Prefers the native
 * `CSS.escape` (Baseline) and falls back to a conservative manual escape so a UUID
 * containing selector metacharacters can never break `querySelector`.
 *
 * @param {string} value
 * @returns {string}
 */
function cssEscape(value) {
  if (typeof CSS !== 'undefined' && typeof CSS.escape === 'function') {
    return CSS.escape(value);
  }
  return value.replace(/["\\\]]/g, '\\$&');
}

// ─── Boot ──────────────────────────────────────────────────────────────────────────────

/**
 * Wire event listeners and hydrate from storage. Runs once, synchronously, at module load.
 * The status region starts empty, so no announcement fires on the initial load.
 *
 * @returns {void}
 */
function init() {
  addForm.addEventListener('submit', handleAdd);
  for (const btn of filterButtons) {
    const mode = /** @type {FilterMode} */ (btn.dataset.filter);
    btn.addEventListener('click', () => handleFilter(mode));
  }

  // load() runs on start — total function, always a valid array even on corrupt storage.
  todos = load(STORAGE_KEY, STORAGE_ADAPTER);
  render();
}

init();
