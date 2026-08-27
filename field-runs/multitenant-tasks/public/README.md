# Task console (public/) — how to open it

A minimal, accessible, framework-free UI for the multitenant task API. It is served by `server.mjs`
as static files (`GET /` → `index.html`, `GET /app.js`). Open it **through the server**, not as a
`file://` page — `fetch()` calls go to same-origin `/api/*` and only resolve when a server is serving
both the page and the API.

## 1. Start the server (credentials come from env ONLY — no secret values live in any file)

The server reads the tenant→token map from the `WALTEUR_TENANT_TOKENS` env var (a JSON string). Nothing
is committed; pick your own values at launch.

Git-Bash / macOS / Linux:

```bash
cd "field-runs/multitenant-tasks"
WALTEUR_TENANT_TOKENS='{"tenantA":"secretA","tenantB":"secretB"}' PORT=8137 node server.mjs
```

PowerShell:

```powershell
cd "field-runs/multitenant-tasks"
$env:WALTEUR_TENANT_TOKENS='{"tenantA":"secretA","tenantB":"secretB"}'; $env:PORT='8137'; node server.mjs
```

If `WALTEUR_TENANT_TOKENS` is absent or malformed, the map is empty and **every** `/api` request returns
`401` (deny-by-default). That is intentional, not a bug.

## 2. Open the UI

Browse to <http://localhost:8137/>. (If port 8137 is taken, set a different `PORT` and use that.)

## 3. Use it

1. **Tenant ID** — e.g. `tenantA`. Sent as the `X-Tenant-Id` header.
2. **Bearer token** — the matching secret, e.g. `secretA`. Sent as `Authorization: Bearer <token>`.
   It lives only in the password field, is sent per request, and is never persisted.
3. **Load tasks** — `GET /api/tasks`, scoped to your tenant. Wrong/blank token → `Access denied (HTTP 401)`.
4. **Add task** — `POST /api/tasks` with `{ "title": … }`.
5. Per row: **Complete** (`POST /api/tasks/:id/complete`) and **Delete** (`DELETE /api/tasks/:id`).

Switch the Tenant ID + token to `tenantB` / `secretB` and reload: you will see an empty list — tenant A's
tasks are never visible to tenant B. Isolation is enforced server-side in `core.mjs` (`owned()` chokepoint),
not in this UI.

## Endpoints this UI calls (the real ones `server.mjs` exposes)

| Action        | Method + path                  | Success |
|---------------|--------------------------------|---------|
| List tasks    | `GET /api/tasks`               | 200     |
| Add task      | `POST /api/tasks` `{title}`    | 201     |
| Complete task | `POST /api/tasks/:id/complete` | 200     |
| Delete task   | `DELETE /api/tasks/:id`        | 204     |

Every `/api` request carries both `X-Tenant-Id` and `Authorization: Bearer <token>`; missing/blank/wrong
credentials → `401` with an empty body (no leak of which tenant exists). A cross-tenant write → `403`.

## Accessibility notes

- Semantic landmarks: `<main>`, `<section>`, real `<form>`/`<fieldset>`/`<legend>`, `<h1>`/`<h2>`.
- Every input has a programmatic `<label for>` and an `aria-describedby` hint.
- Both forms submit on **Enter** (keyboard-only usable); focus is moved sensibly after add/validation.
- Status messages use `role="status"` + `aria-live="polite"`; the task list is an `aria-live` region with
  `aria-busy` toggled during fetch, so adds/completes/removals are announced.
- Each per-row button has a task-specific `aria-label` (e.g. "Complete task: Write the spec") so its
  purpose is clear out of visual context.
- Visible `:focus-visible` outlines; honors `prefers-reduced-motion` and `prefers-color-scheme`.
