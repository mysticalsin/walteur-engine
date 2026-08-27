/**
 * @file test/helpers/memory-storage.js — PROJECT-OWNED in-memory storage stubs.
 *
 * The zero-dependency Definition-of-Done forbids any third-party mock (`sinon`,
 * `jest.mock`, etc.) — see .claude/rules/testing.md §2. These ~5-line stubs are the
 * project's own, structurally satisfying the narrow `StorageAdapter` port from
 * `src/storage.js` ({@link import('../../src/storage.js')}): the two synchronous Web
 * Storage methods `getItem(key)` and `setItem(key, value)`.
 *
 * Three shapes, each modelling exactly one adapter contract the storage suite must prove:
 *   - {@link MemoryStorage}        — the happy-path Map-backed store (getItem/setItem work).
 *   - {@link QuotaExceededStorage} — setItem ALWAYS throws a QuotaExceededError (the
 *                                     canonical `localStorage` full DOMException), and
 *                                     getItem returns a caller-supplied RAW string so a
 *                                     save-failure test can still control what a read sees.
 *   - {@link ThrowingStorage}      — getItem ALWAYS throws (storage disabled / blocked,
 *                                     e.g. Safari private mode) to prove load() totality.
 *
 * None of these is a partial/placeholder: each is the full, real behaviour of its edge.
 */

/**
 * The narrowed Web Storage surface the app depends on. Mirrors
 * `import('../../src/storage.js').StorageAdapter` without importing it (keeps the helper
 * a leaf with no source coupling beyond the shape).
 *
 * @typedef {Object} StorageAdapter
 * @property {(key: string) => (string | null)} getItem
 * @property {(key: string, value: string) => void} setItem
 */

/**
 * MemoryStorage — the happy-path in-memory adapter. A thin `Map` wrapper whose `getItem`
 * returns the stored string or `null` when the key is absent (matching the real
 * `localStorage` contract, which `deserialize` relies on to distinguish absent-key from a
 * stored empty string), and whose `setItem` records the value.
 *
 * @implements {StorageAdapter}
 */
export class MemoryStorage {
  /** @param {Record<string, string>} [initial] Seed entries (key -> raw stored string). */
  constructor(initial = {}) {
    /** @type {Map<string, string>} @readonly */
    this.map = new Map(Object.entries(initial));
  }

  /**
   * @param {string} key
   * @returns {string | null} The stored raw string, or `null` when the key is absent.
   */
  getItem(key) {
    return this.map.has(key) ? /** @type {string} */ (this.map.get(key)) : null;
  }

  /**
   * @param {string} key
   * @param {string} value
   * @returns {void}
   */
  setItem(key, value) {
    this.map.set(key, value);
  }
}

/**
 * QuotaExceededStorage — the write-failure adapter. `setItem` ALWAYS throws a
 * `QuotaExceededError` (a plain `Error` whose `.name` is set to the browser DOMException
 * name, reproduced WITHOUT a browser — `save()`'s contract keys on `e.name`, so this is
 * behaviourally identical to the real quota exception for the code under test). `getItem`
 * returns a caller-supplied RAW string (or `null` when none was supplied) so a test can
 * still drive what a read observes even while writes are guaranteed to fail.
 *
 * @implements {StorageAdapter}
 */
export class QuotaExceededStorage {
  /**
   * @param {string | null} [raw=null] The raw string every `getItem` returns (regardless
   *   of key). `null` models an absent key.
   */
  constructor(raw = null) {
    /** @type {string | null} @readonly */
    this.raw = raw;
  }

  /**
   * @param {string} _key Ignored — this stub returns the fixed caller-supplied raw string.
   * @returns {string | null}
   */
  getItem(_key) {
    return this.raw;
  }

  /**
   * @param {string} _key
   * @param {string} _value
   * @returns {never} Always throws a `QuotaExceededError`.
   */
  setItem(_key, _value) {
    const err = new Error('The quota has been exceeded.');
    err.name = 'QuotaExceededError';
    throw err;
  }
}

/**
 * ThrowingStorage — the read-failure adapter. `getItem` ALWAYS throws (storage disabled or
 * blocked by a privacy setting — e.g. Safari private mode raises on access). Proves
 * `load()` is total across an adapter that itself throws, resolving to `[]` rather than
 * letting the error escape into the UI. `setItem` is a no-op so the shape stays complete.
 *
 * @implements {StorageAdapter}
 */
export class ThrowingStorage {
  /**
   * @param {string} [message='storage disabled (e.g. Safari private mode)'] The thrown
   *   error's message.
   */
  constructor(message = 'storage disabled (e.g. Safari private mode)') {
    /** @type {string} @readonly */
    this.message = message;
  }

  /**
   * @param {string} _key
   * @returns {never} Always throws.
   */
  getItem(_key) {
    throw new Error(this.message);
  }

  /**
   * @param {string} _key
   * @param {string} _value
   * @returns {void}
   */
  setItem(_key, _value) {
    /* no-op: reads fail before any write path is exercised */
  }
}
