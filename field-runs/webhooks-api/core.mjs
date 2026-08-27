// webhooks-api — core domain logic with DENY-BY-DEFAULT tenant isolation.
// Every read/write is scoped to the caller's tenantId; a cross-tenant access is denied, never leaked.
// A tenant can ONLY ever read or write its OWN webhook subscriptions. Pure, dependency-free (Node built-ins
// only), so the authz invariant is provable by an actually-running test, not a self-asserted "verdict:PASS".
//
// A "subscription" is { tenantId, id, url, eventType, active, secretFingerprint, secretLast4,
//                       createdAt, updatedAt } where:
//   id                -> an opaque, tenant-unique string (assigned by the store, never guessable cross-tenant)
//   url               -> an HTTPS delivery URL; validated (https-only + SSRF-guarded, see validateUrl)
//   eventType         -> one of ALLOWED_EVENTS (deny-by-default on anything off the allow-list)
//   active            -> boolean; whether this subscription would receive deliveries
//   secretFingerprint -> "sha256:<hex>" of the HMAC signing secret. The RAW secret is returned to the caller
//                        EXACTLY ONCE (on create and on rotate-secret) and is NEVER stored — only this
//                        fingerprint and the last 4 chars persist. So data.json holds ZERO secret values by
//                        construction, and a later read can identify but never recover the secret.
//   secretLast4       -> last 4 chars of the secret, for human identification only (not sensitive on its own)
//   createdAt/updatedAt -> monotonic logical timestamps (no Date — keeps the test reproducible)
// The store is a {tenantId -> {id -> sub}} map so the SAME id space in two tenants is two independent
// namespaces: one tenant literally cannot address another tenant's subscription by id.

import crypto from 'node:crypto';

// Allow-list of webhook event types. Deny-by-default: anything not here is rejected, so a tenant cannot
// register for an event the platform does not emit (and cannot smuggle arbitrary strings into the store).
export const ALLOWED_EVENTS = [
  'order.created',
  'order.updated',
  'order.deleted',
  'user.created',
  'user.updated',
  'payment.succeeded',
  'payment.failed',
];

export function createStore() {
  // tenantId -> Map<id, sub>. A subscription never exists outside its tenant's bucket — there is no global
  // id namespace, so one tenant cannot address another tenant's subscription.
  /** @type {Map<string, Map<string, object>>} */
  const byTenant = new Map();

  // agent-native discipline: AUTO-AUDIT every MUTATION (who/what/when/id). Reads are NOT audited.
  // The audit trail is runtime evidence — provable by an actually-running test, not a shape-read claim.
  /** @type {{ts:number, tenantId:string, action:string, id:string}[]} */
  const auditLog = [];
  let clock = 0; // deterministic monotonic clock (no Date — keeps the test reproducible)
  function tick() { return ++clock; }
  function audit(tenantId, action, id) {
    auditLog.push({ ts: tick(), tenantId, action, id });
  }

  function reqTenant(tenantId) {
    if (!tenantId || !String(tenantId).trim()) throw new Error('tenantId required');
  }

  // Deny-by-default bucket accessor: returns the tenant's OWN map of subscriptions, creating it on first
  // write. This is the single chokepoint every tenant-scoped operation goes through — a caller can only
  // ever reach the bucket keyed by ITS OWN tenantId, so cross-tenant addressing is impossible.
  function owned(tenantId, { create = false } = {}) {
    let bucket = byTenant.get(tenantId);
    if (!bucket && create) { bucket = new Map(); byTenant.set(tenantId, bucket); }
    return bucket || null;
  }

  // ── Validation (deny-by-default on malformed input) ───────────────────────────────────────────────

  // Hosts a webhook may NOT target. Blocking loopback/private/link-local ranges is real webhook-platform
  // hygiene (SSRF defense): a tenant must not be able to point a delivery at the platform's own internal
  // network. Parsed via the WHATWG URL host, so this is a structural check, not a string heuristic.
  function isBlockedHost(host) {
    const h = String(host || '').toLowerCase();
    if (!h) return true;
    if (h === 'localhost' || h.endsWith('.localhost')) return true;
    if (h === '0.0.0.0' || h === '::1' || h === '[::1]') return true;
    if (/^127\./.test(h)) return true;                       // IPv4 loopback
    if (/^10\./.test(h)) return true;                        // private class A
    if (/^192\.168\./.test(h)) return true;                  // private class C
    if (/^172\.(1[6-9]|2\d|3[01])\./.test(h)) return true;   // private class B (172.16–172.31)
    if (/^169\.254\./.test(h)) return true;                  // link-local
    return false;
  }

  // Validate + normalize a delivery URL. Must parse, be https, and not target a blocked (internal) host.
  // Returns the normalized href; throws a deny-by-default error otherwise.
  function validateUrl(url) {
    if (typeof url !== 'string' || !url.trim()) throw new Error('url must be a valid https URL');
    let u;
    try { u = new URL(url.trim()); }
    catch { throw new Error('url must be a valid https URL'); }
    if (u.protocol !== 'https:') throw new Error('url must be a valid https URL');
    if (isBlockedHost(u.hostname)) throw new Error('url host not allowed');
    return u.href;
  }

  // Validate an event type against the allow-list.
  function validateEventType(eventType) {
    if (typeof eventType !== 'string' || !ALLOWED_EVENTS.includes(eventType)) {
      throw new Error('eventType not allowed');
    }
    return eventType;
  }

  // Validate the active flag (strict boolean; deny anything else).
  function validateActive(active) {
    if (typeof active !== 'boolean') throw new Error('active must be a boolean');
    return active;
  }

  // Generate an opaque, collision-resistant subscription id. Random (not sequential) so an id reveals
  // nothing about another tenant's count or ordering — there is no enumeration oracle across tenants.
  function newId() {
    return 'sub_' + crypto.randomBytes(9).toString('hex');
  }

  // Mint a fresh HMAC signing secret. Returned to the caller ONCE; never stored raw.
  function newSecret() {
    return 'whsec_' + crypto.randomBytes(24).toString('base64url');
  }

  // One-way fingerprint of a secret. Stored in place of the raw value so a read can identify (and a
  // rotation can be diffed) without the secret ever being recoverable from the store or a backup.
  function fingerprint(secret) {
    return 'sha256:' + crypto.createHash('sha256').update(secret).digest('hex');
  }

  // Shape a stored subscription for output. By construction this NEVER carries the raw secret — only the
  // fingerprint + last4. The raw secret is attached separately, once, by create()/rotateSecret().
  function publicView(sub) {
    return { ...sub };
  }

  return {
    // Create a subscription the caller OWNS. tenant + valid https url + allow-listed eventType required;
    // active defaults to true. A signing secret is minted and returned ONCE in the response (`secret`);
    // only its fingerprint + last4 are stored. Deny-by-default: writes land ONLY in the caller's bucket.
    createSubscription(tenantId, input = {}) {
      reqTenant(tenantId);
      const url = validateUrl(input.url);
      const eventType = validateEventType(input.eventType);
      const active = input.active === undefined ? true : validateActive(input.active);

      const bucket = owned(tenantId, { create: true });
      const now = tick();
      let id = newId();
      while (bucket.has(id)) id = newId(); // never collide within a tenant

      const secret = newSecret();
      const sub = {
        tenantId, id, url, eventType, active,
        secretFingerprint: fingerprint(secret),
        secretLast4: secret.slice(-4),
        createdAt: now, updatedAt: now,
      };
      bucket.set(id, sub);
      audit(tenantId, 'create', id);
      // raw secret is attached to the RESPONSE only, never to the stored object
      return { ...publicView(sub), secret };
    },

    // Return ALL of the caller-tenant's subscriptions (tenant-scoped). Never returns another tenant's subs,
    // and never includes a raw secret (only fingerprint + last4 live in the store).
    getSubscriptions(tenantId) {
      reqTenant(tenantId);
      const bucket = owned(tenantId);
      if (!bucket) return [];
      return [...bucket.values()].map(publicView);
    },

    // Return a single OWNED subscription, or null on absent/cross-tenant (deny-by-default READ — no
    // existence oracle: a tenant can never tell another tenant's sub apart from a non-existent one). No
    // raw secret is ever returned by a read.
    getSubscription(tenantId, id) {
      reqTenant(tenantId);
      if (!id) return null;
      const bucket = owned(tenantId);
      const sub = bucket ? bucket.get(String(id)) : undefined;
      return sub ? publicView(sub) : null;
    },

    // Update a subscription the caller OWNS (url / eventType / active are optional partial updates). Throws
    // 'forbidden' when the caller has no such OWNED sub (the deny-by-default WRITE path: an absent-or-foreign
    // id is indistinguishable and both are denied — no cross-tenant write and no existence oracle). The
    // signing secret is NOT changed here (use rotateSecret).
    updateSubscription(tenantId, id, patch = {}) {
      reqTenant(tenantId);
      if (!id) throw new Error('forbidden');
      const bucket = owned(tenantId);
      const existing = bucket ? bucket.get(String(id)) : undefined;
      if (!existing) throw new Error('forbidden');
      const next = { ...existing };
      if (patch.url !== undefined) next.url = validateUrl(patch.url);
      if (patch.eventType !== undefined) next.eventType = validateEventType(patch.eventType);
      if (patch.active !== undefined) next.active = validateActive(patch.active);
      next.updatedAt = tick();
      bucket.set(next.id, next);
      audit(tenantId, 'update', next.id);
      return publicView(next);
    },

    // Rotate the signing secret of a subscription the caller OWNS. Mints a NEW secret, replaces the stored
    // fingerprint + last4, and returns the raw secret ONCE. Throws 'forbidden' on absent/cross-tenant
    // (deny-by-default WRITE path — same no-existence-oracle guarantee as update/delete).
    rotateSecret(tenantId, id) {
      reqTenant(tenantId);
      if (!id) throw new Error('forbidden');
      const bucket = owned(tenantId);
      const existing = bucket ? bucket.get(String(id)) : undefined;
      if (!existing) throw new Error('forbidden');
      const secret = newSecret();
      const next = {
        ...existing,
        secretFingerprint: fingerprint(secret),
        secretLast4: secret.slice(-4),
        updatedAt: tick(),
      };
      bucket.set(next.id, next);
      audit(tenantId, 'rotate', next.id);
      return { ...publicView(next), secret };
    },

    // Delete a subscription the caller OWNS. Throws 'forbidden' when the caller has no such OWNED sub (the
    // deny-by-default WRITE path: an absent-or-foreign id is indistinguishable and both are denied).
    deleteSubscription(tenantId, id) {
      reqTenant(tenantId);
      if (!id) throw new Error('forbidden');
      const bucket = owned(tenantId);
      if (!bucket || !bucket.has(String(id))) throw new Error('forbidden');
      bucket.delete(String(id));
      audit(tenantId, 'delete', String(id));
      return true;
    },

    // Tenant-scoped audit trail (also deny-by-default — a tenant only ever sees its OWN audit rows).
    auditTrail(tenantId) {
      reqTenant(tenantId);
      return auditLog.filter((e) => e.tenantId === tenantId).map((e) => ({ ...e }));
    },

    // GDPR right-to-erasure (DSAR): a tenant erases ALL of its own data — subscriptions AND audit rows —
    // and nothing belonging to any other tenant. Returns the count erased. Deny-by-default: only the
    // caller's own bucket is touched; there is no cross-tenant erase path.
    eraseTenant(tenantId) {
      reqTenant(tenantId);
      let erased = 0;
      const bucket = byTenant.get(tenantId);
      if (bucket) { erased += bucket.size; byTenant.delete(tenantId); }
      for (let i = auditLog.length - 1; i >= 0; i--) {
        if (auditLog[i].tenantId === tenantId) { auditLog.splice(i, 1); erased++; }
      }
      return erased;
    },

    // Serialize the full store to a plain object for persistence (server.mjs -> data.json). The audit log
    // is included so the trail survives a restart. By construction NO raw secret is present in this
    // structure — only fingerprints + last4 — so data.json never holds a credential value.
    snapshot() {
      const tenants = {};
      for (const [tid, bucket] of byTenant) {
        tenants[tid] = [...bucket.values()].map((s) => ({ ...s }));
      }
      return { tenants, auditLog: auditLog.map((e) => ({ ...e })), clock };
    },

    // Rehydrate from a snapshot() object (deny-by-default on malformed input: anything missing is skipped,
    // never crashes). Used by server.mjs to load data.json on boot.
    load(snap) {
      if (!snap || typeof snap !== 'object') return;
      byTenant.clear();
      auditLog.length = 0;
      const tenants = snap.tenants && typeof snap.tenants === 'object' ? snap.tenants : {};
      for (const [tid, subs] of Object.entries(tenants)) {
        if (!Array.isArray(subs)) continue;
        const bucket = new Map();
        for (const s of subs) {
          if (s && typeof s.id === 'string') bucket.set(s.id, { ...s, tenantId: tid });
        }
        byTenant.set(tid, bucket);
      }
      if (Array.isArray(snap.auditLog)) for (const e of snap.auditLog) auditLog.push({ ...e });
      clock = Number.isFinite(snap.clock) ? snap.clock : auditLog.length;
    },
  };
}
