// app.js — minimal, accessible fetch() client for the multitenant task console.
//
// Endpoints (exactly what server.mjs exposes — verified by curl + test/api.test.mjs):
//   GET    /api/tasks                  list the caller-tenant's tasks
//   POST   /api/tasks       { title }  create a task          -> 201
//   POST   /api/tasks/:id/complete     mark done              -> 200
//   DELETE /api/tasks/:id              remove                 -> 204
// Auth: TWO headers on every /api request — X-Tenant-Id: <tenant> AND Authorization: Bearer <token>.
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
  const tenant = $('tenant').value.trim();
  const token = $('token').value;
  return { tenant, token };
}

// Build the two required auth headers from the live form values. Empty token -> empty Authorization,
// which the server rejects with 401 (deny-by-default) rather than us guessing client-side.
function authHeaders() {
  const { tenant, token } = creds();
  return {
    'X-Tenant-Id': tenant,
    'Authorization': token ? `Bearer ${token}` : '',
  };
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

function render(tasks) {
  listEl.replaceChildren();
  if (!tasks || tasks.length === 0) {
    const li = document.createElement('li');
    li.className = 'empty';
    li.textContent = 'No tasks.';
    listEl.appendChild(li);
    return;
  }
  for (const t of tasks) {
    const li = document.createElement('li');
    if (t.done) li.classList.add('done');

    const title = document.createElement('span');
    title.className = 'title';
    title.textContent = t.title;

    const complete = document.createElement('button');
    complete.type = 'button';
    complete.className = 'ghost';
    complete.textContent = t.done ? 'Done' : 'Complete';
    complete.disabled = t.done;
    // Per-task accessible name so a screen reader hears "Complete task: Write the spec", not bare "Complete".
    complete.setAttribute('aria-label', t.done ? `Completed: ${t.title}` : `Complete task: ${t.title}`);
    complete.addEventListener('click', () => completeTask(t.id));

    const del = document.createElement('button');
    del.type = 'button';
    del.className = 'ghost';
    del.textContent = 'Delete';
    del.setAttribute('aria-label', `Delete task: ${t.title}`);
    del.addEventListener('click', () => deleteTask(t.id));

    li.append(title, complete, del);
    listEl.appendChild(li);
  }
}

async function loadTasks() {
  const { tenant, token } = creds();
  if (!tenant || !token) { setStatus('Enter a tenant id and token.', 'err'); $('tenant').focus(); return; }
  listEl.setAttribute('aria-busy', 'true');
  const r = await api('GET', '/api/tasks');
  listEl.setAttribute('aria-busy', 'false');
  if (r.denied) { render([]); setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not load tasks.', 'err'); return; }
  render(r.data || []);
  const n = (r.data || []).length;
  setStatus(`Loaded ${n} task${n === 1 ? '' : 's'}.`, 'ok');
}

async function addTask() {
  const title = $('title').value.trim();
  if (!title) { setStatus('Title required.', 'err'); $('title').focus(); return; }
  const r = await api('POST', '/api/tasks', { title });
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not add task.', 'err'); return; }
  $('title').value = '';
  $('title').focus();
  await loadTasks();
}

async function completeTask(id) {
  const r = await api('POST', `/api/tasks/${id}/complete`);
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not complete task.', 'err'); return; }
  await loadTasks();
}

async function deleteTask(id) {
  const r = await api('DELETE', `/api/tasks/${id}`);
  if (r.denied) { setStatus(`Access denied (HTTP ${r.status}).`, 'err'); return; }
  if (!r.ok) { setStatus('Could not delete task.', 'err'); return; }
  await loadTasks();
}

// Forms drive everything: submit (Enter or button) is prevented from navigating, then handled.
$('creds-form').addEventListener('submit', (e) => { e.preventDefault(); loadTasks(); });
$('add-form').addEventListener('submit', (e) => { e.preventDefault(); addTask(); });
