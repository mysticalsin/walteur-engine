// test/host-fallback.test.js
//
// Regression: a genuinely absent Host header (raw HTTP/1.0, which node:http will not
// emit — so we drive a raw socket) must NOT produce "http://undefined/<code>" in the
// returned shortUrl. buildShortUrl (src/server.js) now falls back to 'localhost', so
// the 201 body carries a valid, parseable URL instead of a malformed one.
import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { once } from 'node:events';
import { createServer } from '../src/server.js';

test('absent Host header -> shortUrl falls back to localhost, never http://undefined', async (t) => {
  const server = createServer();
  server.listen(0);
  await once(server, 'listening');
  const { port } = server.address();
  t.after(() => new Promise((r) => server.close(r)));

  const body = JSON.stringify({ url: 'https://example.com/some/path' });
  // Raw HTTP/1.0 request with NO Host header (HTTP/1.0 does not mandate it).
  const raw =
    'POST /shorten HTTP/1.0\r\n' +
    'Content-Type: application/json\r\n' +
    `Content-Length: ${Buffer.byteLength(body)}\r\n` +
    'Connection: close\r\n' +
    '\r\n' +
    body;

  const sock = net.connect(port, '127.0.0.1');
  await once(sock, 'connect');
  sock.write(raw);
  const chunks = [];
  sock.on('data', (c) => chunks.push(c));
  await once(sock, 'end');
  const resp = Buffer.concat(chunks).toString('utf8');

  const jsonStart = resp.indexOf('{');
  assert.ok(jsonStart >= 0, `expected a JSON body, got:\n${resp}`);
  const parsed = JSON.parse(resp.slice(jsonStart));
  assert.ok(parsed.shortUrl, 'response has a shortUrl');
  assert.ok(!parsed.shortUrl.includes('undefined'), `shortUrl must not contain "undefined": ${parsed.shortUrl}`);
  // The fallback origin is localhost; the code is still appended.
  assert.match(parsed.shortUrl, /^https?:\/\/localhost\/[A-Za-z0-9_-]+$/, `shortUrl should use the localhost fallback: ${parsed.shortUrl}`);
});
