// app.js — minimal, accessible fetch() client for the multi-tenant webhook-subscription console.
//
// Endpoints (exactly what server.mjs exposes — verified by curl + test/api.test.mjs):
//   GET    /subscriptions                  list the caller-tenant's subscriptions
//   POST   /subscriptions  {url,eventType} create a subscription           -> 201 (secret shown ONCE)
//   PUT    /subscriptions/:id  {active,…}  update a subscription           -> 200
//   POST   /subscriptions/:id/rotate-secret rotate the signing secret      -> 200 (secret shown ONCE)
//   DELETE /subscriptions/:id              remove a subscription           -> 204
//   POST   /admin/erase                    DSAR erase the caller tenant
// Auth: TWO headers on every request — X-Tenant: <tenant> AND Authorization: Bearer <token>.
//
// The token lives only in the password input; it is NEVER persisted and NEVER hardcoded here. A
// 401/403/404 is surfaced as a plain "denied" — the UI never falls back to, or displays, another
// tenant's data. The raw signing secret returned on create/rotate is shown once and never stored.

const $ = (id) => document.getElementById(id);
const listEl = $('list');
const statusEl = $('status');
const secretBox = $('secret-box');
const secretValue = $('secret-value');

function setStatus(msg, kind) {
  statusEl.textContent = msg;
  statusEl.className = kind || '';
}

// Reveal the one-time signing secret (after create/rotate). The server never returns it again.
function showSecret(secret) {
  if (!secret) return;
  secretValue.textContent = secret;
  secretBox.classList.add('show');
}
function hideSecret() {
  secretValue.textContent = '';
  secretBox.classList.remove('show');
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

function render(subs) {
  listEl.replaceChildren();
  if (!subs || subs.length === 0) {
    const li = document.createElement('li');
    li.className = 'empty';
    li.textContent = 'No subscriptions.';
    listEl.appendChild(li);
    return;
  }
  for (const s of subs) {
    const li = document.createElement('li');
    if (s.active === false) li.classList.add('inactive');

    const url = document.createElement('span');
    url.className = 'url';
    url.textContent = s.url;

    const ev = document.createElement('span');
    ev.className = 'ev';
    ev.textContent = s.eventType;

    const badge = document.createElement('span');
    badge.className = 'badge';
    badge.textContent = s.active === false ? 'inactive' : 'active';

    const fp = document.createElement('span');
    fp.className = 'fp';
    fp.textContent = `${s.secretFingerprint ? s.secretFingerprint.slice(0, 14) + '…' : ''} ·${s.secretLast4 || ''}`;

    const rotate = document.createElement('button');
    rotate.type = 'button';
    rotate.className = 'ghost';
    rotate.textContent = 'Rotate secret';
    rotate.setAttribute('aria-label', `Rotate signing secret for ${s.url}`);
    rotate.addEventListener('click', () => rotateSecret(s.id));

    const toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.className = 'ghost';
    toggle.textContent = s.active === false ? 'Enable' : 'Disable';
    toggle.setAttribute('aria-label', `${s.active === false ? 'Enable' : 'Disable'} ${s.url}`);
    toggle.addEventListener('click', () => setActive(s.id, s.active === false));

    const del = document.createElement('button');
    del.type = 'button';
    del.className = 'ghost';
    del.textContent = 'Delete';
    del.setAttribute('aria-label', `Delete subscription: ${s.url}`);
    del.addEventListener('click', () => deleteSub(s.id));

    li.append(url, ev, badge, fp, toggle, rotate, del);
    listEl.appendChild(li);
  }
}

async function loadSubs() {
  const { tenant, token } = creds();
  if (!tenant || !token) { setStatus('Enter a tenant id and token.', 'err'); $('tenant').focus(); return; }
  listEl.setAttribute('aria-busy', 'true');
  const r = await api('GET', '/subscriptions');
  listEl.setAttribute('aria-busy', 'false');
  if (r.denied) { render([]); setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not load subscriptions.', 'err'); return; }
  render(r.data || []);
  const n = (r.data || []).length;
  setStatus(`Loaded ${n} subscription${n === 1 ? '' : 's'}.`, 'ok');
}

async function createSub() {
  hideSecret();
  const url = $('url').value.trim();
  const eventType = $('eventType').value;
  if (!url) { setStatus('Delivery URL required.', 'err'); $('url').focus(); return; }
  const r = await api('POST', '/subscriptions', { url, eventType });
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus(r.data && r.data.error ? `Rejected: ${r.data.error}` : 'Could not create subscription.', 'err'); return; }
  $('url').value = '';
  showSecret(r.data && r.data.secret);
  setStatus('Subscription created — copy the signing secret above (shown once).', 'ok');
  await loadSubs();
}

async function setActive(id, active) {
  const r = await api('PUT', `/subscriptions/${encodeURIComponent(id)}`, { active });
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not update subscription.', 'err'); return; }
  await loadSubs();
}

async function rotateSecret(id) {
  hideSecret();
  const r = await api('POST', `/subscriptions/${encodeURIComponent(id)}/rotate-secret`);
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not rotate secret.', 'err'); return; }
  showSecret(r.data && r.data.secret);
  setStatus('Secret rotated — copy the new signing secret above (shown once).', 'ok');
  await loadSubs();
}

async function deleteSub(id) {
  const r = await api('DELETE', `/subscriptions/${encodeURIComponent(id)}`);
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not delete subscription.', 'err'); return; }
  await loadSubs();
}

// Forms drive everything: submit (Enter or button) is prevented from navigating, then handled.
$('creds-form').addEventListener('submit', (e) => { e.preventDefault(); hideSecret(); loadSubs(); });
$('create-form').addEventListener('submit', (e) => { e.preventDefault(); createSub(); });
