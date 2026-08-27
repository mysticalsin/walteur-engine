// multitenant-tasks — core domain logic with DENY-BY-DEFAULT tenant isolation.
// Every read/write is scoped to the caller's tenantId; a cross-tenant access is denied, never leaked.
// Pure, dependency-free, deterministic — so the authz invariant is provable by an actually-running test.

export function createStore() {
  /** @type {{id:number, tenantId:string, title:string, done:boolean}[]} */
  const tasks = [];
  let nextId = 1;
  // agent-native discipline: AUTO-AUDIT every MUTATION (who/what/when/surface); reads are not audited.
  // The audit trail is runtime evidence — provable by an actually-running test, not a shape-read claim.
  /** @type {{ts:number, tenantId:string, action:string, taskId:number}[]} */
  const auditLog = [];
  let clock = 0; // deterministic monotonic clock (no Date — keeps the test reproducible)
  function audit(tenantId, action, taskId) {
    auditLog.push({ ts: ++clock, tenantId, action, taskId });
  }

  // Deny-by-default lookup: returns the row ONLY if it belongs to tenantId, else null.
  // This is the single chokepoint every tenant-scoped operation goes through.
  function owned(tenantId, id) {
    const t = tasks.find((x) => x.id === id);
    if (!t) return null;
    if (t.tenantId !== tenantId) return null; // cross-tenant => denied (no leak of existence/content)
    return t;
  }

  return {
    add(tenantId, title) {
      if (!tenantId) throw new Error('tenantId required');
      if (!title || !String(title).trim()) throw new Error('title required');
      const t = { id: nextId++, tenantId, title: String(title), done: false };
      tasks.push(t);
      audit(tenantId, 'add', t.id);
      return { ...t };
    },

    // Tenant-scoped audit trail (also deny-by-default — a tenant only ever sees its own audit rows).
    auditTrail(tenantId) {
      if (!tenantId) throw new Error('tenantId required');
      return auditLog.filter((e) => e.tenantId === tenantId).map((e) => ({ ...e }));
    },

    list(tenantId) {
      if (!tenantId) throw new Error('tenantId required');
      return tasks.filter((t) => t.tenantId === tenantId).map((t) => ({ ...t }));
    },

    // Returns null on cross-tenant access (deny-by-default READ) — never the other tenant's data.
    get(tenantId, id) {
      const t = owned(tenantId, id);
      return t ? { ...t } : null;
    },

    // Throws 'forbidden' on cross-tenant access (deny-by-default WRITE).
    complete(tenantId, id) {
      const t = owned(tenantId, id);
      if (!t) throw new Error('forbidden');
      t.done = true;
      audit(tenantId, 'complete', t.id);
      return { ...t };
    },

    remove(tenantId, id) {
      const t = owned(tenantId, id);
      if (!t) throw new Error('forbidden');
      const idx = tasks.indexOf(t);
      tasks.splice(idx, 1);
      audit(tenantId, 'remove', id);
      return true;
    },

    // GDPR right-to-erasure (DSAR): a tenant erases ALL of its own data — tasks AND audit rows — and
    // nothing belonging to any other tenant. Returns the count erased. Deny-by-default: only the caller's
    // own tenant is touched; there is no cross-tenant erase path.
    eraseTenant(tenantId) {
      if (!tenantId) throw new Error('tenantId required');
      let erased = 0;
      for (let i = tasks.length - 1; i >= 0; i--) {
        if (tasks[i].tenantId === tenantId) { tasks.splice(i, 1); erased++; }
      }
      for (let i = auditLog.length - 1; i >= 0; i--) {
        if (auditLog[i].tenantId === tenantId) { auditLog.splice(i, 1); erased++; }
      }
      return erased;
    },
  };
}
