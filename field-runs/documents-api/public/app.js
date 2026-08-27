// app.js — minimal, accessible fetch() client for the multi-tenant documents console.
//
// Endpoints (exactly what server.mjs exposes — verified by curl + test/api.test.mjs):
//   GET    /docs                  list the caller-tenant's documents
//   POST   /docs  {title,body}    create a document          -> 201
//   PUT    /docs/:id {title,body} update a document          -> 200
//   DELETE /docs/:id              remove a document          -> 204
//   POST   /admin/erase           DSAR erase the caller tenant
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

function render(docs) {
  listEl.replaceChildren();
  if (!docs || docs.length === 0) {
    const li = document.createElement('li');
    li.className = 'empty';
    li.textContent = 'No documents.';
    listEl.appendChild(li);
    return;
  }
  for (const d of docs) {
    const li = document.createElement('li');

    const wrap = document.createElement('div');
    wrap.className = 'doc';

    const title = document.createElement('div');
    title.className = 'title';
    title.textContent = d.title;

    const body = document.createElement('div');
    body.className = 'body';
    body.textContent = d.body || '';

    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = `${d.id} · created ${d.createdAt} · updated ${d.updatedAt}`;

    wrap.append(title, body, meta);

    const del = document.createElement('button');
    del.type = 'button';
    del.className = 'ghost';
    del.textContent = 'Delete';
    del.setAttribute('aria-label', `Delete document: ${d.title}`);
    del.addEventListener('click', () => deleteDoc(d.id));

    li.append(wrap, del);
    listEl.appendChild(li);
  }
}

async function loadDocs() {
  const { tenant, token } = creds();
  if (!tenant || !token) { setStatus('Enter a tenant id and token.', 'err'); $('tenant').focus(); return; }
  listEl.setAttribute('aria-busy', 'true');
  const r = await api('GET', '/docs');
  listEl.setAttribute('aria-busy', 'false');
  if (r.denied) { render([]); setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not load documents.', 'err'); return; }
  render(r.data || []);
  const n = (r.data || []).length;
  setStatus(`Loaded ${n} document${n === 1 ? '' : 's'}.`, 'ok');
}

async function createDoc() {
  const title = $('title').value.trim();
  if (!title) { setStatus('Title required.', 'err'); $('title').focus(); return; }
  const body = $('body').value;
  const r = await api('POST', '/docs', { title, body });
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not create document.', 'err'); return; }
  $('title').value = '';
  $('body').value = '';
  $('title').focus();
  await loadDocs();
}

async function deleteDoc(id) {
  const r = await api('DELETE', `/docs/${encodeURIComponent(id)}`);
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not delete document.', 'err'); return; }
  await loadDocs();
}

// Forms drive everything: submit (Enter or button) is prevented from navigating, then handled.
$('creds-form').addEventListener('submit', (e) => { e.preventDefault(); loadDocs(); });
$('create-form').addEventListener('submit', (e) => { e.preventDefault(); createDoc(); });
