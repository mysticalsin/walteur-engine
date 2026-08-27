# Code style — engine-urlshort

## ESM extensions are load-bearing, not stylistic
Node's ESM resolver (unlike CommonJS `require`) does not guess file extensions. Omitting `.js` on a relative import throws `ERR_MODULE_NOT_FOUND` at runtime, not lint time:
```js
// WRONG — throws under `"type": "module"`:
import { createStore } from './store';

// RIGHT:
import { createStore } from './store.js';
```
Removing the extension on this project breaks `node bin/server.js` immediately (no bundler/transpiler is in the stack to paper over it) — this is not a lint nicety, it's the difference between the server starting and crashing on line 1.

## Error construction always goes through `AppError`, never inline
`src/errors.js` is the single source of truth for the code→status table (AGENTS.md §5, §7). Throwing a bare `Error` or hand-building a response object bypasses that table and lets the client-facing envelope drift from what the README documents:
```js
// WRONG — bypasses the typed-error registry, leaks a raw message shape:
if (!body.url) {
  res.writeHead(400);
  res.end(JSON.stringify({ error: 'missing url' }));
  return;
}

// RIGHT — single envelope shape, status looked up from the registry:
if (!body.url) {
  throw new AppError('MISSING_URL', 400, 'url is required');
}
```
Removing this rule on this project specifically means the README's error table (which must match `src/errors.js` byte-for-byte per PLAN.md) silently goes stale the first time someone adds a new failure path inline instead of through `AppError`.

## `src/server.js` never calls `.listen()`
`createServer()` must return an **unstarted** `http.Server`. This is the seam the entire test suite depends on — tests bind `listen(0)` themselves to get an ephemeral port. If `.listen()` moves into `src/server.js`, every test that imports it will either fail to bind a second server on the same port or silently start listening on a fixed port outside the test's control:
```js
// src/server.js — RIGHT:
export function createServer() {
  return http.createServer(handler); // NOT started
}

// bin/server.js — RIGHT (the only place that starts it):
createServer().listen(process.env.PORT ?? 3000);
```
