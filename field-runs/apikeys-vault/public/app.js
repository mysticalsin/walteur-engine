// app.js — minimal, accessible fetch() client for the multi-tenant API-key vault console.
//
// Endpoints (exactly what server.mjs exposes — verified by curl + test/api.test.mjs):
//   GET    /keys                list the caller-tenant's keys (METADATA ONLY — never a raw key)
//   POST   /keys  {label}       issue a key          -> 201, raw key in the body ONCE
//   POST   /keys/:id/rotate     rotate a key         -> 200, NEW raw key in the body ONCE
//   DELETE /keys/:id            revoke a key         -> 200
//   POST   /admin/erase         DSAR erase the caller tenant
// Auth: TWO headers on every request — X-Tenant: <tenant> AND Authorization: Bearer <token>.
//
// The bearer token lives only in the password input; it is NEVER persisted and NEVER hardcoded here. The
// freshly issued/rotated RAW key is shown EXACTLY ONCE in the reveal box, then dropped — the client never
// stores it and the server never returns it again (GET /keys is metadata only). A 401/403/404 is surfaced
// as a plain "denied" — the UI never falls back to, or displays, another tenant's data.

const $ = (id) => document.getElementById(id);
const listEl = $('list');
const statusEl = $('status');
const revealEl = $('reveal');
const revealKeyEl = $('reveal-key');

function setStatus(msg, kind) {
  statusEl.textContent = msg;
  statusEl.className = kind || '';
}

function creds() {
  return { tenant: $('tenant').value.trim(), token: $('token').value };
}

// Build the two required auth headers from the live form values. Empty token -> empty Authorization, which
// the server rejects with 401 (deny-by-default) rather than us guessing client-side.
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
  let data = null;
  try { data = await res.json(); } catch { /* empty body */ }
  return { ok: res.ok, status: res.status, data };
}

// Show the one-time raw key in the reveal box. This is the ONLY place the client ever holds the raw value,
// and it is cleared the moment the user dismisses it or reloads the list.
function revealKey(raw) {
  revealKeyEl.textContent = raw;
  revealEl.hidden = false;
  $('reveal-dismiss').focus();
}
function clearReveal() {
  revealKeyEl.textContent = '';
  revealEl.hidden = true;
}

function fmtFingerprint(k) {
  // a non-secret fingerprint: short hash prefix + last4. Never the full hash on its own line.
  const hp = (k.hash || '').slice(0, 12);
  return `…${k.last4}  ·  sha256:${hp}…`;
}

function render(keys) {
  listEl.replaceChildren();
  if (!keys || keys.length === 0) {
    const li = document.createElement('li');
    li.className = 'empty';
    li.textContent = 'No keys.';
    listEl.appendChild(li);
    return;
  }
  for (const k of keys) {
    const li = document.createElement('li');

    const wrap = document.createElement('div');
    wrap.className = 'key';

    const label = document.createElement('div');
    label.className = 'label';
    const badge = document.createElement('span');
    badge.className = `badge ${k.status === 'revoked' ? 'revoked' : 'active'}`;
    badge.textContent = k.status;
    label.append(document.createTextNode(`${k.label} `), badge);

    const fp = document.createElement('div');
    fp.className = 'fingerprint';
    fp.textContent = fmtFingerprint(k);

    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = `${k.id} · created ${k.createdAt} · rotated ${k.rotatedAt}${k.revokedAt ? ` · revoked ${k.revokedAt}` : ''}`;

    wrap.append(label, fp, meta);

    const actions = document.createElement('div');
    actions.className = 'actions';

    if (k.status !== 'revoked') {
      const rot = document.createElement('button');
      rot.type = 'button';
      rot.className = 'ghost';
      rot.textContent = 'Rotate';
      rot.setAttribute('aria-label', `Rotate key: ${k.label}`);
      rot.addEventListener('click', () => rotateKey(k.id));

      const rev = document.createElement('button');
      rev.type = 'button';
      rev.className = 'ghost';
      rev.textContent = 'Revoke';
      rev.setAttribute('aria-label', `Revoke key: ${k.label}`);
      rev.addEventListener('click', () => revokeKey(k.id));

      actions.append(rot, rev);
    }

    li.append(wrap, actions);
    listEl.appendChild(li);
  }
}

async function loadKeys() {
  const { tenant, token } = creds();
  if (!tenant || !token) { setStatus('Enter a tenant id and token.', 'err'); $('tenant').focus(); return; }
  clearReveal();
  listEl.setAttribute('aria-busy', 'true');
  const r = await api('GET', '/keys');
  listEl.setAttribute('aria-busy', 'false');
  if (r.denied) { render([]); setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not load keys.', 'err'); return; }
  render(r.data || []);
  const n = (r.data || []).length;
  setStatus(`Loaded ${n} key${n === 1 ? '' : 's'}.`, 'ok');
}

async function createKey() {
  const label = $('label').value.trim();
  if (!label) { setStatus('Label required.', 'err'); $('label').focus(); return; }
  const r = await api('POST', '/keys', { label });
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok || !r.data || !r.data.key) { setStatus('Could not issue key.', 'err'); return; }
  $('label').value = '';
  revealKey(r.data.key); // the one-and-only time the raw key is shown
  setStatus('Key issued. Copy it now — it will not be shown again.', 'ok');
  await refreshList();
}

async function rotateKey(id) {
  const r = await api('POST', `/keys/${encodeURIComponent(id)}/rotate`);
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok || !r.data || !r.data.key) { setStatus('Could not rotate key.', 'err'); return; }
  revealKey(r.data.key); // the rotated raw key, shown once
  setStatus('Key rotated. The previous key is now invalid. Copy the new one now.', 'ok');
  await refreshList();
}

async function revokeKey(id) {
  const r = await api('DELETE', `/keys/${encodeURIComponent(id)}`);
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not revoke key.', 'err'); return; }
  setStatus('Key revoked.', 'ok');
  await refreshList();
}

// Refresh the list WITHOUT clearing the reveal box (so an issued/rotated key stays visible to copy).
async function refreshList() {
  const r = await api('GET', '/keys');
  if (r.ok) render(r.data || []);
}

// Forms drive everything: submit (Enter or button) is prevented from navigating, then handled.
$('creds-form').addEventListener('submit', (e) => { e.preventDefault(); loadKeys(); });
$('create-form').addEventListener('submit', (e) => { e.preventDefault(); createKey(); });
$('reveal-dismiss').addEventListener('click', () => { clearReveal(); $('label').focus(); });
