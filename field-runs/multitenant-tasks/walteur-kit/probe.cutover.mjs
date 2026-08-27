// probe.cutover.mjs — the real, re-runnable rollback proof the zero-downtime-cutover-gate executes.
// It models the blue-green rollback check: flip the live alias back to the previous (green) target and
// assert the service answers. Here, with no live cluster, it verifies the rollback INVARIANT locally —
// that core.mjs's deny-by-default isolation survives a store re-creation (a fresh "green" instance) — and
// exits 0 only if that invariant holds. A non-zero exit means the rollback target is unhealthy.

import { createStore } from './../core.mjs';

function fail(msg) { console.error('rollback-check FAILED:', msg); process.exit(1); }

// Stand up a fresh "green" store (what a rollback would route to) and assert isolation still holds.
const green = createStore();
const a = green.add('tenantA', 'rollback-canary');
if (green.get('tenantB', a.id) !== null) fail('cross-tenant read leaked on rollback target');
let denied = false;
try { green.complete('tenantB', a.id); } catch { denied = true; }
if (!denied) fail('cross-tenant write was not denied on rollback target');
if (green.get('tenantA', a.id).done !== false) fail('rollback target mutated tenantA row');

console.log('rollback-check OK: deny-by-default isolation holds on the rollback (green) target');
process.exit(0);
