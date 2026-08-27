#!/usr/bin/env node
// bin/server.js
//
// Production entrypoint — the ONLY place that starts the server (AGENTS.md §3,
// .claude/rules/code-style.md). It imports the unstarted server from the factory,
// binds the port, and logs the bound address on the 'listening' event as the
// readiness signal (§14 layer 12). Keeping listen() out of src/server.js is what
// lets the test suite bind its own ephemeral port per instance.
//
// Reads PORT from the environment, defaulting to 3000. `??` (not `||`) so an
// explicit PORT=0 (bind an OS-assigned ephemeral port) is honored rather than being
// coerced to the default.

import { createServer } from '../src/server.js';

const PORT = process.env.PORT ?? 3000;

const server = createServer();

server.on('error', (err) => {
  // A bind failure (port in use / EACCES) is fatal for a single-process service —
  // there is nothing to fall back to. Log a structured record to stderr and exit
  // non-zero so a supervisor/orchestrator sees the crash rather than a silent hang.
  process.stderr.write(
    `${JSON.stringify({
      level: 'fatal',
      at: new Date().toISOString(),
      msg: 'server failed to start',
      err: { name: err.name, message: err.message, code: err.code },
    })}\n`
  );
  process.exit(1);
});

server.listen(PORT, () => {
  const addr = server.address();
  // addr is an AddressInfo object for a TCP socket; reconstruct a human-readable
  // origin. When bound to 0.0.0.0 (all interfaces) report 127.0.0.1 for a clickable
  // local URL, otherwise report the actual bound address.
  const host =
    addr && typeof addr === 'object'
      ? addr.address === '0.0.0.0' || addr.address === '::'
        ? '127.0.0.1'
        : addr.address
      : String(addr);
  const port = addr && typeof addr === 'object' ? addr.port : PORT;
  process.stdout.write(
    `${JSON.stringify({
      level: 'info',
      at: new Date().toISOString(),
      msg: 'listening',
      url: `http://${host}:${port}`,
    })}\n`
  );
});
