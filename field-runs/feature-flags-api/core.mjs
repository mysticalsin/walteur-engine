// feature-flags-api — core domain logic with DENY-BY-DEFAULT tenant isolation.
// Every read/write is scoped to the caller's tenantId; a cross-tenant access is denied, never leaked.
// A tenant can ONLY ever read or write its OWN flags. Pure, dependency-free, deterministic — so the
// authz invariant is provable by an actually-running test, not a self-asserted "verdict:PASS".
//
// A "flag" is { tenantId, key, value, kind } where:
//   kind="boolean"  -> value is true|false
//   kind="variant"  -> value is a non-empty string (e.g. "control" | "treatment" | "blue")
// The store is a {tenantId -> {key -> flag}} map so the SAME key in two tenants is two independent flags.

export function createStore() {
  // tenantId -> Map<key, flag>. A flag never exists outside its tenant's bucket — there is no global
  // key namespace, so one tenant literally cannot address another tenant's flag.
  /** @type {Map<string, Map<string, {tenantId:string,key:string,value:boolean|string,kind:string}>>} */
  const byTenant = new Map();

  // agent-native discipline: AUTO-AUDIT every MUTATION (who/what/when/key). Reads are NOT audited.
  // The audit trail is runtime evidence — provable by an actually-running test, not a shape-read claim.
  /** @type {{ts:number, tenantId:string, action:string, key:string}[]} */
  const auditLog = [];
  let clock = 0; // deterministic monotonic clock (no Date — keeps the test reproducible)
  function audit(tenantId, action, key) {
    auditLog.push({ ts: ++clock, tenantId, action, key });
  }

  function reqTenant(tenantId) {
    if (!tenantId || !String(tenantId).trim()) throw new Error('tenantId required');
  }
  function reqKey(key) {
    if (!key || !String(key).trim()) throw new Error('key required');
  }

  // Deny-by-default bucket accessor: returns the tenant's OWN map of flags, creating it on first write.
  // This is the single chokepoint every tenant-scoped operation goes through — a caller can only ever
  // reach the bucket keyed by ITS OWN tenantId, so cross-tenant addressing is impossible by construction.
  function owned(tenantId, { create = false } = {}) {
    let bucket = byTenant.get(tenantId);
    if (!bucket && create) { bucket = new Map(); byTenant.set(tenantId, bucket); }
    return bucket || null;
  }

  // Normalize + validate a flag value. boolean kind => strict true/false; variant kind => non-empty
  // string. Anything else is rejected (deny-by-default on malformed input).
  function normalize(value) {
    if (typeof value === 'boolean') return { kind: 'boolean', value };
    if (typeof value === 'string' && value.trim()) return { kind: 'variant', value };
    throw new Error('value must be a boolean or a non-empty variant string');
  }

  return {
    // Set (create or update) a flag the caller OWNS. tenant + key are required; value is bool or variant.
    // Deny-by-default: writes land ONLY in the caller's own bucket; no path reaches another tenant's flag.
    setFlag(tenantId, key, value) {
      reqTenant(tenantId);
      reqKey(key);
      const { kind, value: v } = normalize(value);
      const bucket = owned(tenantId, { create: true });
      const flag = { tenantId, key: String(key), value: v, kind };
      bucket.set(flag.key, flag);
      audit(tenantId, 'set', flag.key);
      return { ...flag };
    },

    // Return ALL of the caller-tenant's flags (tenant-scoped). Never returns another tenant's flags.
    getFlags(tenantId) {
      reqTenant(tenantId);
      const bucket = owned(tenantId);
      if (!bucket) return [];
      return [...bucket.values()].map((f) => ({ ...f }));
    },

    // Return a single OWNED flag, or null on absent/cross-tenant (deny-by-default READ — no existence
    // oracle: a tenant can never tell another tenant's flag apart from a non-existent one).
    getFlag(tenantId, key) {
      reqTenant(tenantId);
      reqKey(key);
      const bucket = owned(tenantId);
      const f = bucket ? bucket.get(String(key)) : undefined;
      return f ? { ...f } : null;
    },

    // Delete a flag the caller OWNS. Throws 'forbidden' when the caller has no such OWNED flag (this is
    // the deny-by-default WRITE path: an absent-or-foreign key is indistinguishable and both are denied).
    deleteFlag(tenantId, key) {
      reqTenant(tenantId);
      reqKey(key);
      const bucket = owned(tenantId);
      if (!bucket || !bucket.has(String(key))) throw new Error('forbidden');
      bucket.delete(String(key));
      audit(tenantId, 'delete', String(key));
      return true;
    },

    // Tenant-scoped audit trail (also deny-by-default — a tenant only ever sees its OWN audit rows).
    auditTrail(tenantId) {
      reqTenant(tenantId);
      return auditLog.filter((e) => e.tenantId === tenantId).map((e) => ({ ...e }));
    },

    // GDPR right-to-erasure (DSAR): a tenant erases ALL of its own data — flags AND audit rows — and
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
        tenants[tid] = [...bucket.values()].map((f) => ({ ...f }));
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
      for (const [tid, flags] of Object.entries(tenants)) {
        if (!Array.isArray(flags)) continue;
        const bucket = new Map();
        for (const f of flags) {
          if (f && typeof f.key === 'string') bucket.set(f.key, { ...f, tenantId: tid });
        }
        byTenant.set(tid, bucket);
      }
      if (Array.isArray(snap.auditLog)) for (const e of snap.auditLog) auditLog.push({ ...e });
      clock = Number.isFinite(snap.clock) ? snap.clock : auditLog.length;
    },
  };
}
