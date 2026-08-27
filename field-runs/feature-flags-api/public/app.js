// app.js — minimal, accessible fetch() client for the multi-tenant feature-flags console.
//
// Endpoints (exactly what server.mjs exposes — verified by curl + test/api.test.mjs):
//   GET    /flags                list the caller-tenant's flags
//   POST   /flags  {key,value}   create/update a flag   -> 201
//   DELETE /flags/:key           remove a flag          -> 204
//   POST   /admin/erase          DSAR erase the caller tenant
// Auth: TWO headers on every request — X-Tenant: <tenant> AND Authorization: Bearer <token>.
//
// The token lives only in the password input; it is NEVER persisted and NEVER hardcoded here. A
// 401/403/404 is surfaced as a plain "denied" — the UI never falls back to, or displays, another
// tenant's data.

const $ = (id) => document.getElementById(id);
const listEl = $('list');
const statusEl = $('status');

function setStatus(msg, kind) {
  statusEl.textContent = msg;
  statusEl.className = kind || '';
}

function creds() {
  return { tenant: $('tenant').value.trim(), token: $('token').value };
}

// Build the two required auth headers from the live form values. Empty token -> empty Authorization,
// which the server rejects with 401 (deny-by-default) rather than us guessing client-side.
function authHeaders() {
  const { tenant, token } = creds();
  return { 'X-Tenant': tenant, 'Authorization': token ? `Bearer ${token}` : '' };
}

// Wrap fetch: on 401/403/404 we report "denied" and render nothing — we never show stale/foreign data.
async function api(method, path, body) {
  const headers = authHeaders();
  const opts = { method, headers };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(path, opts);
  if (res.status === 401 || res.status === 403 || res.status === 404) {
    return { denied: true, status: res.status };
  }
  if (res.status === 204) return { ok: true, data: null };
  let data = null;
  try { data = await res.json(); } catch { /* empty body */ }
  return { ok: res.ok, status: res.status, data };
}

function render(flags) {
  listEl.replaceChildren();
  if (!flags || flags.length === 0) {
    const li = document.createElement('li');
    li.className = 'empty';
    li.textContent = 'No flags.';
    listEl.appendChild(li);
    return;
  }
  for (const f of flags) {
    const li = document.createElement('li');
    const isOff = f.kind === 'boolean' && f.value === false;
    if (isOff) li.classList.add('off');

    const key = document.createElement('span');
    key.className = 'key';
    key.textContent = f.key;

    const val = document.createElement('span');
    val.className = 'val';
    val.textContent = f.kind === 'boolean' ? (f.value ? 'on' : 'off') : String(f.value);

    const badge = document.createElement('span');
    badge.className = 'badge';
    badge.textContent = f.kind;

    const del = document.createElement('button');
    del.type = 'button';
    del.className = 'ghost';
    del.textContent = 'Delete';
    del.setAttribute('aria-label', `Delete flag: ${f.key}`);
    del.addEventListener('click', () => deleteFlag(f.key));

    li.append(key, val, badge, del);
    listEl.appendChild(li);
  }
}

async function loadFlags() {
  const { tenant, token } = creds();
  if (!tenant || !token) { setStatus('Enter a tenant id and token.', 'err'); $('tenant').focus(); return; }
  listEl.setAttribute('aria-busy', 'true');
  const r = await api('GET', '/flags');
  listEl.setAttribute('aria-busy', 'false');
  if (r.denied) { render([]); setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not load flags.', 'err'); return; }
  render(r.data || []);
  const n = (r.data || []).length;
  setStatus(`Loaded ${n} flag${n === 1 ? '' : 's'}.`, 'ok');
}

// Read the value from whichever control the selected kind exposes.
function readValue() {
  const kind = $('kind').value;
  if (kind === 'boolean') return $('value-bool').value === 'true';
  return $('value-variant').value.trim();
}

async function setFlag() {
  const key = $('key').value.trim();
  if (!key) { setStatus('Key required.', 'err'); $('key').focus(); return; }
  const value = readValue();
  if ($('kind').value === 'variant' && !value) { setStatus('Variant value required.', 'err'); $('value-variant').focus(); return; }
  const r = await api('POST', '/flags', { key, value });
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not set flag.', 'err'); return; }
  $('key').value = '';
  $('key').focus();
  await loadFlags();
}

async function deleteFlag(key) {
  const r = await api('DELETE', `/flags/${encodeURIComponent(key)}`);
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not delete flag.', 'err'); return; }
  await loadFlags();
}

// Toggle the value control to match the selected kind (boolean dropdown vs variant text input).
function syncValueControl() {
  const variant = $('kind').value === 'variant';
  $('value-bool').hidden = variant;
  $('value-variant').hidden = !variant;
  $('value-bool').disabled = variant;
  $('value-variant').disabled = !variant;
}

// Forms drive everything: submit (Enter or button) is prevented from navigating, then handled.
$('creds-form').addEventListener('submit', (e) => { e.preventDefault(); loadFlags(); });
$('set-form').addEventListener('submit', (e) => { e.preventDefault(); setFlag(); });
$('kind').addEventListener('change', syncValueControl);
syncValueControl();
