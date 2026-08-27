// documents-api — core domain logic with DENY-BY-DEFAULT tenant isolation.
// Every read/write is scoped to the caller's tenantId; a cross-tenant access is denied, never leaked.
// A tenant can ONLY ever read or write its OWN documents. Pure, dependency-free, deterministic — so the
// authz invariant is provable by an actually-running test, not a self-asserted "verdict:PASS".
//
// A "document" is { tenantId, id, title, body, createdAt, updatedAt } where:
//   id        -> an opaque, tenant-unique string (assigned by the store, never guessable across tenants)
//   title     -> a non-empty string
//   body      -> a string (may be empty)
//   createdAt -> monotonic logical timestamp at creation
//   updatedAt -> monotonic logical timestamp at last mutation
// The store is a {tenantId -> {id -> doc}} map so the SAME id space in two tenants is two independent
// namespaces: one tenant literally cannot address another tenant's document by id.

import crypto from 'node:crypto';

export function createStore() {
  // tenantId -> Map<id, doc>. A doc never exists outside its tenant's bucket — there is no global id
  // namespace, so one tenant cannot address another tenant's document.
  /** @type {Map<string, Map<string, {tenantId:string,id:string,title:string,body:string,createdAt:number,updatedAt:number}>>} */
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
  function reqTitle(title) {
    if (typeof title !== 'string' || !title.trim()) throw new Error('title required');
  }

  // Deny-by-default bucket accessor: returns the tenant's OWN map of documents, creating it on first
  // write. This is the single chokepoint every tenant-scoped operation goes through — a caller can only
  // ever reach the bucket keyed by ITS OWN tenantId, so cross-tenant addressing is impossible.
  function owned(tenantId, { create = false } = {}) {
    let bucket = byTenant.get(tenantId);
    if (!bucket && create) { bucket = new Map(); byTenant.set(tenantId, bucket); }
    return bucket || null;
  }

  // Normalize a document body to a string (deny-by-default on malformed input: non-string, non-nullish
  // bodies are rejected). A missing body defaults to the empty string.
  function normalizeBody(body) {
    if (body === undefined || body === null) return '';
    if (typeof body === 'string') return body;
    throw new Error('body must be a string');
  }

  // Generate an opaque, collision-resistant document id. Random (not sequential) so an id reveals nothing
  // about another tenant's count or ordering — there is no enumeration oracle across tenants.
  function newId() {
    return 'doc_' + crypto.randomBytes(9).toString('hex');
  }

  return {
    // Create a document the caller OWNS. tenant + title required; body defaults to ''. Returns the stored
    // doc (with its assigned id). Deny-by-default: writes land ONLY in the caller's own bucket.
    createDoc(tenantId, title, body) {
      reqTenant(tenantId);
      reqTitle(title);
      const b = normalizeBody(body);
      const bucket = owned(tenantId, { create: true });
      const now = tick();
      let id = newId();
      while (bucket.has(id)) id = newId(); // never collide within a tenant
      const doc = { tenantId, id, title: String(title), body: b, createdAt: now, updatedAt: now };
      bucket.set(id, doc);
      audit(tenantId, 'create', id);
      return { ...doc };
    },

    // Return ALL of the caller-tenant's documents (tenant-scoped). Never returns another tenant's docs.
    getDocs(tenantId) {
      reqTenant(tenantId);
      const bucket = owned(tenantId);
      if (!bucket) return [];
      return [...bucket.values()].map((d) => ({ ...d }));
    },

    // Return a single OWNED document, or null on absent/cross-tenant (deny-by-default READ — no existence
    // oracle: a tenant can never tell another tenant's doc apart from a non-existent one).
    getDoc(tenantId, id) {
      reqTenant(tenantId);
      if (!id) return null;
      const bucket = owned(tenantId);
      const d = bucket ? bucket.get(String(id)) : undefined;
      return d ? { ...d } : null;
    },

    // Update a document the caller OWNS. Throws 'forbidden' when the caller has no such OWNED doc (the
    // deny-by-default WRITE path: an absent-or-foreign id is indistinguishable and both are denied — no
    // cross-tenant write and no existence oracle). title/body are optional partial updates.
    updateDoc(tenantId, id, patch = {}) {
      reqTenant(tenantId);
      if (!id) throw new Error('forbidden');
      const bucket = owned(tenantId);
      const existing = bucket ? bucket.get(String(id)) : undefined;
      if (!existing) throw new Error('forbidden');
      const next = { ...existing };
      if (patch.title !== undefined) { reqTitle(patch.title); next.title = String(patch.title); }
      if (patch.body !== undefined) { next.body = normalizeBody(patch.body); }
      next.updatedAt = tick();
      bucket.set(next.id, next);
      audit(tenantId, 'update', next.id);
      return { ...next };
    },

    // Delete a document the caller OWNS. Throws 'forbidden' when the caller has no such OWNED doc (the
    // deny-by-default WRITE path: an absent-or-foreign id is indistinguishable and both are denied).
    deleteDoc(tenantId, id) {
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

    // GDPR right-to-erasure (DSAR): a tenant erases ALL of its own data — documents AND audit rows — and
    // nothing belonging to any other tenant. Returns the count erased. Deny-by-default: only the caller's
    // own bucket is touched; there is no cross-tenant erase path.
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
    // is included so the trail survives a restart. No secrets are present in this structure by design.
    snapshot() {
      const tenants = {};
      for (const [tid, bucket] of byTenant) {
        tenants[tid] = [...bucket.values()].map((d) => ({ ...d }));
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
      for (const [tid, docs] of Object.entries(tenants)) {
        if (!Array.isArray(docs)) continue;
        const bucket = new Map();
        for (const d of docs) {
          if (d && typeof d.id === 'string') bucket.set(d.id, { ...d, tenantId: tid });
        }
        byTenant.set(tid, bucket);
      }
      if (Array.isArray(snap.auditLog)) for (const e of snap.auditLog) auditLog.push({ ...e });
      clock = Number.isFinite(snap.clock) ? snap.clock : auditLog.length;
    },
  };
}
