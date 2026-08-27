// apikeys-vault — core domain logic for a DENY-BY-DEFAULT, multi-tenant API-KEY vault.
//
// Every read/write is scoped to the caller's tenantId; a cross-tenant access is denied, never leaked. A
// tenant can ONLY ever read or rotate or revoke its OWN keys. Pure, dependency-free, deterministic in its
// control flow (the only nondeterminism is crypto.randomBytes for the secret material) — so the isolation,
// rotation, and erasure invariants are provable by an actually-running test, not a self-asserted verdict.
//
// THE CARDINAL RULE OF THIS DOMAIN: the RAW key is a write-once secret. createKey/rotateKey return the raw
// key exactly ONCE at issue time; from then on the store holds ONLY a sha256 HASH of it plus a non-secret
// last4 + timestamps. The raw key is NEVER persisted, NEVER returned by listKeys/getKey, and NEVER written
// to the audit trail. There is no code path that can read a raw key back out of the store after issue.
//
// A "key record" is { tenantId, id, label, hash, last4, status, createdAt, rotatedAt, revokedAt } where:
//   id        -> an opaque, tenant-unique string (assigned by the store, never guessable across tenants)
//   label     -> a human name for the key (non-empty string)
//   hash      -> sha256(rawKey) hex — the ONLY representation of the secret kept at rest
//   last4     -> the last 4 chars of the raw key (non-secret display aid; 4 chars reveal ~no entropy)
//   status    -> 'active' | 'revoked'
//   createdAt -> monotonic logical timestamp at issue
//   rotatedAt -> monotonic logical timestamp at last rotation (== createdAt until first rotate)
//   revokedAt -> monotonic logical timestamp at revoke, else null
// The store is a {tenantId -> {id -> record}} map so the SAME id space in two tenants is two independent
// namespaces: one tenant literally cannot address another tenant's key by id.

import crypto from 'node:crypto';

// sha256(raw) hex — the one-way function the store keeps INSTEAD of the raw key. Exported so a test can
// independently recompute the hash of an issued raw key and assert the stored hash matches (proving the
// store really hashes, and that rotate changes the hash).
export function hashKey(raw) {
  return crypto.createHash('sha256').update(String(raw), 'utf8').digest('hex');
}

// Mint a fresh raw API key: a high-entropy, url-safe secret with a stable, recognizable prefix. The prefix
// is NOT secret; the 32 random bytes are. Returned to the caller exactly once, then only its hash is kept.
function mintRawKey() {
  // 32 bytes = 256 bits of entropy, base64url so it is copy-paste safe and carries no '+', '/', or '='.
  return 'wk_' + crypto.randomBytes(32).toString('base64url');
}

export function createStore() {
  // tenantId -> Map<id, record>. A record never exists outside its tenant's bucket — there is no global id
  // namespace, so one tenant cannot address another tenant's key.
  /** @type {Map<string, Map<string, {tenantId:string,id:string,label:string,hash:string,last4:string,status:string,createdAt:number,rotatedAt:number,revokedAt:number|null}>>} */
  const byTenant = new Map();

  // agent-native discipline: AUTO-AUDIT every MUTATION (who/what/when/which key id). Reads are NOT audited.
  // The audit trail is runtime evidence — provable by an actually-running test. It records ONLY the key id
  // and action, NEVER the raw key or even its hash.
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
  function reqLabel(label) {
    if (typeof label !== 'string' || !label.trim()) throw new Error('label required');
  }

  // Deny-by-default bucket accessor: returns the tenant's OWN map of key records, creating it on first
  // write. This is the single chokepoint every tenant-scoped operation goes through — a caller can only
  // ever reach the bucket keyed by ITS OWN tenantId, so cross-tenant addressing is impossible.
  function owned(tenantId, { create = false } = {}) {
    let bucket = byTenant.get(tenantId);
    if (!bucket && create) { bucket = new Map(); byTenant.set(tenantId, bucket); }
    return bucket || null;
  }

  // Generate an opaque, collision-resistant key id. Random (not sequential) so an id reveals nothing about
  // another tenant's count or ordering — there is no enumeration oracle across tenants.
  function newId() {
    return 'key_' + crypto.randomBytes(9).toString('hex');
  }

  // Project a stored record to its PUBLIC metadata shape. This is the ONLY view list/get ever expose — it
  // carries the hash/last4/timestamps but, by construction, can never carry a raw key (the store has none).
  function meta(rec) {
    return {
      tenantId: rec.tenantId, id: rec.id, label: rec.label,
      last4: rec.last4, status: rec.status,
      createdAt: rec.createdAt, rotatedAt: rec.rotatedAt, revokedAt: rec.revokedAt,
      // hash is surfaced so an operator can verify a presented key matches WITHOUT the store holding the
      // raw value; it is a one-way digest, not the secret.
      hash: rec.hash,
    };
  }

  return {
    // Issue a brand-new API key the caller OWNS. tenant + label required. Mints a fresh raw key, stores ONLY
    // its sha256 hash + last4 + timestamps, and returns { ...metadata, key } where `key` is the raw secret
    // shown EXACTLY ONCE. After this returns, the raw key is unrecoverable from the store.
    createKey(tenantId, label) {
      reqTenant(tenantId);
      reqLabel(label);
      const bucket = owned(tenantId, { create: true });
      const now = tick();
      let id = newId();
      while (bucket.has(id)) id = newId(); // never collide within a tenant
      const raw = mintRawKey();
      const rec = {
        tenantId, id, label: String(label),
        hash: hashKey(raw), last4: raw.slice(-4),
        status: 'active', createdAt: now, rotatedAt: now, revokedAt: null,
      };
      bucket.set(id, rec);
      audit(tenantId, 'create', id);
      // The raw key leaves here ONCE. It is never written to bucket, auditLog, or any snapshot.
      return { ...meta(rec), key: raw };
    },

    // List ALL of the caller-tenant's key records as METADATA ONLY (never a raw key — the store holds none).
    // Tenant-scoped: never returns another tenant's keys.
    listKeys(tenantId) {
      reqTenant(tenantId);
      const bucket = owned(tenantId);
      if (!bucket) return [];
      return [...bucket.values()].map(meta);
    },

    // Return a single OWNED key's METADATA, or null on absent/cross-tenant (deny-by-default READ — no
    // existence oracle: a tenant can never tell another tenant's key apart from a non-existent one). Never
    // returns a raw key.
    getKey(tenantId, id) {
      reqTenant(tenantId);
      if (!id) return null;
      const bucket = owned(tenantId);
      const rec = bucket ? bucket.get(String(id)) : undefined;
      return rec ? meta(rec) : null;
    },

    // Rotate a key the caller OWNS: mint a NEW raw secret, replace the stored hash + last4, bump rotatedAt,
    // and return { ...metadata, key } with the new raw secret shown ONCE. The OLD secret's hash is gone, so
    // the old raw key no longer validates — rotation genuinely invalidates the prior credential. Throws
    // 'forbidden' when the caller has no such OWNED key (absent-or-foreign id is indistinguishable; both
    // denied — no cross-tenant rotate, no existence oracle). A revoked key cannot be rotated back to life.
    rotateKey(tenantId, id) {
      reqTenant(tenantId);
      if (!id) throw new Error('forbidden');
      const bucket = owned(tenantId);
      const rec = bucket ? bucket.get(String(id)) : undefined;
      if (!rec) throw new Error('forbidden');
      if (rec.status === 'revoked') throw new Error('revoked');
      const raw = mintRawKey();
      rec.hash = hashKey(raw);
      rec.last4 = raw.slice(-4);
      rec.rotatedAt = tick();
      bucket.set(rec.id, rec);
      audit(tenantId, 'rotate', rec.id);
      return { ...meta(rec), key: raw };
    },

    // Revoke a key the caller OWNS: flip status to 'revoked' and stamp revokedAt. The record is kept (for
    // audit/history) but the credential is dead. Throws 'forbidden' on absent/cross-tenant. Idempotent-safe:
    // revoking an already-revoked OWNED key is a no-op success.
    revokeKey(tenantId, id) {
      reqTenant(tenantId);
      if (!id) throw new Error('forbidden');
      const bucket = owned(tenantId);
      const rec = bucket ? bucket.get(String(id)) : undefined;
      if (!rec) throw new Error('forbidden');
      if (rec.status !== 'revoked') {
        rec.status = 'revoked';
        rec.revokedAt = tick();
        bucket.set(rec.id, rec);
        audit(tenantId, 'revoke', rec.id);
      }
      return meta(rec);
    },

    // Verify a presented raw key against the caller-tenant's ACTIVE keys WITHOUT the store ever holding the
    // raw value: hash the presented key and constant-time compare against each active record's stored hash.
    // Returns the matching key id, or null. Tenant-scoped (deny-by-default): a key only validates inside its
    // own tenant. A revoked key never matches. This is how an issued key is checked after the one-time view.
    verifyKey(tenantId, presentedRaw) {
      reqTenant(tenantId);
      if (typeof presentedRaw !== 'string' || !presentedRaw) return null;
      const bucket = owned(tenantId);
      if (!bucket) return null;
      const presentedHash = hashKey(presentedRaw);
      const pBuf = Buffer.from(presentedHash, 'utf8');
      let match = null;
      for (const rec of bucket.values()) {
        if (rec.status !== 'active') continue;
        const sBuf = Buffer.from(rec.hash, 'utf8');
        // equal-length hex digests, so timingSafeEqual is always defined; scan ALL to avoid early-exit
        // timing leaks about which key matched.
        if (pBuf.length === sBuf.length && crypto.timingSafeEqual(pBuf, sBuf)) match = rec.id;
      }
      return match;
    },

    // Tenant-scoped audit trail (also deny-by-default — a tenant only ever sees its OWN audit rows). Carries
    // only {ts, tenantId, action, id}; never a raw key or hash.
    auditTrail(tenantId) {
      reqTenant(tenantId);
      return auditLog.filter((e) => e.tenantId === tenantId).map((e) => ({ ...e }));
    },

    // GDPR right-to-erasure (DSAR): a tenant erases ALL of its own data — key records AND audit rows — and
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

    // Serialize the full store to a plain object for persistence (server.mjs -> data.json). HASHES ONLY: by
    // construction the records contain no raw key, so a snapshot can never leak one. The audit log is
    // included so the trail survives a restart.
    snapshot() {
      const tenants = {};
      for (const [tid, bucket] of byTenant) {
        tenants[tid] = [...bucket.values()].map((r) => ({ ...r }));
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
      for (const [tid, recs] of Object.entries(tenants)) {
        if (!Array.isArray(recs)) continue;
        const bucket = new Map();
        for (const r of recs) {
          if (r && typeof r.id === 'string' && typeof r.hash === 'string') {
            bucket.set(r.id, {
              tenantId: tid, id: r.id, label: String(r.label || ''),
              hash: r.hash, last4: String(r.last4 || ''),
              status: r.status === 'revoked' ? 'revoked' : 'active',
              createdAt: Number(r.createdAt) || 0,
              rotatedAt: Number(r.rotatedAt) || Number(r.createdAt) || 0,
              revokedAt: r.revokedAt == null ? null : Number(r.revokedAt),
            });
          }
        }
        byTenant.set(tid, bucket);
      }
      if (Array.isArray(snap.auditLog)) for (const e of snap.auditLog) auditLog.push({ ...e });
      clock = Number.isFinite(snap.clock) ? snap.clock : auditLog.length;
    },
  };
}
