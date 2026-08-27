# Testing — engine-urlshort

## `listen(0)` is async — reading the port too early is a real race, not paranoia
`server.address()` returns `null` until the `'listening'` event fires. On this project (spike-confirmed on Node v24.13.1 per PLAN.md §2), reading the port synchronously after calling `.listen(0)` is a race that will intermittently fail, not a theoretical concern:
```js
import { once } from 'node:events';

test('round-trip shorten + redirect', async (t) => {
  const server = createServer();
  server.listen(0);
  await once(server, 'listening');          // REQUIRED before address() is valid
  const { port } = server.address();

  t.after(() => new Promise((resolve) => server.close(resolve))); // RETURN/await the close

  // ... drive requests against 127.0.0.1:${port} ...
});
```
Skipping `await once(server, 'listening')` on this project produces a flaky suite, not a clean failure — it will pass most runs and hang or throw intermittently, which is worse than a hard failure because it erodes trust in `node --test` green.

## Drain every response body, including the empty 302 body
The #1 confirmed cause of a hung `node --test` run on this project is an undrained keep-alive HTTP response. Every request helper must consume the body on every code path:
```js
function req(options, body) {
  return new Promise((resolve, reject) => {
    const r = http.request(options, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ res, body: Buffer.concat(chunks).toString() }));
      res.on('error', reject);           // REQUIRED — not optional
    });
    r.on('error', reject);
    if (body) r.write(body);
    r.end();
  });
}
```
This applies even to the 302 response, which has an empty body — `res.on('end', ...)` still must fire before the test proceeds, or the socket stays open and `node --test` will not exit cleanly. `t.after` must also return the `server.close()` promise (not just call it) so the runner blocks until the port is actually released.

## Assert both `statusCode` AND `error.code` for every typed-error path
`node:http` does not auto-follow redirects and does not parse JSON — asserting only the HTTP status code lets a wrong `error.code` (e.g. `INVALID_URL` vs `DISALLOWED_PROTOCOL`, both 400) slip through silently:
```js
const { res, body } = await req({ port, path: '/shorten', method: 'POST' }, JSON.stringify({ url: 'javascript:alert(1)' }));
assert.strictEqual(res.statusCode, 400);
assert.strictEqual(JSON.parse(body).error.code, 'DISALLOWED_PROTOCOL'); // not just "some 400"
```
Per PLAN.md's Correctness SLO, every one of the eight typed-error codes in the §5/§7 table needs its own assertion pinning both status and code — a passing suite that only checks status codes has NOT verified the taxonomy the README documents.
