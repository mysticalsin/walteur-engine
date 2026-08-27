// src/store.js
//
// In-memory Map-backed store for the URL shortener, with bounded,
// collision-safe short-code generation (PLAN.md ADR 1; AGENTS.md §3, §5, §7).
//
// Design contract:
//   - createStore({ generate } = {}) returns { has(code), get(code), save(url) }
//     closed over a MODULE-INSTANCE-LOCAL Map (fresh per createStore() call —
//     no shared/global mutable state leaking across instances, e.g. across
//     independent tests or independent server instances in-process).
//   - Default `generate` draws crypto.randomBytes(6).toString('base64url'),
//     which is always exactly 8 URL-safe characters (6 bytes -> 8 base64
//     characters with no padding; base64url never emits '=' padding chars in
//     Node's implementation for a byte length that is a multiple of 3).
//   - `generate` is injectable specifically so the collision-retry path and
//     the exhaustion path are deterministically forceable in tests, without
//     relying on the astronomically-unlikely-in-practice real collision of
//     6-byte random codes.
//   - save(url) retries with a BOUNDED do/while loop, capped at
//     MAX_GENERATE_ATTEMPTS attempts. On cap-out it throws a typed
//     AppError('CODE_GEN_EXHAUSTED') (500) rather than looping unbounded —
//     an unbounded retry loop against a full/adversarial keyspace is a
//     hang/DoS vector, not just a code-quality nit.

import crypto from 'node:crypto';
import { AppError } from './errors.js';

/** Maximum number of generate() attempts save() will make before giving up. */
const MAX_GENERATE_ATTEMPTS = 8;

/**
 * Default code generator: 6 random bytes -> base64url, always exactly 8
 * URL-safe characters (no '=' padding, no '+'/'/' characters).
 * @returns {string}
 */
function defaultGenerate() {
  return crypto.randomBytes(6).toString('base64url');
}

/**
 * Create a fresh, isolated in-memory store instance.
 *
 * @param {{ generate?: () => string }} [options]
 * @param {() => string} [options.generate] - Injectable code generator, for
 *   forcing collision/exhaustion paths in tests. Defaults to defaultGenerate.
 * @returns {{
 *   has: (code: string) => boolean,
 *   get: (code: string) => string | undefined,
 *   save: (url: string) => string,
 * }}
 */
export function createStore({ generate = defaultGenerate } = {}) {
  /** @type {Map<string, string>} */
  const map = new Map();

  /**
   * @param {string} code
   * @returns {boolean}
   */
  function has(code) {
    return map.has(code);
  }

  /**
   * @param {string} code
   * @returns {string | undefined}
   */
  function get(code) {
    return map.get(code);
  }

  /**
   * Persist `url` under a freshly generated, collision-free code and return
   * that code. Retries generate() while the drawn code already exists in the
   * store, bounded at MAX_GENERATE_ATTEMPTS attempts total.
   *
   * @param {string} url - Canonical url to store (caller's responsibility to
   *   have already validated/normalized this — see src/validate.js).
   * @returns {string} the newly assigned short code
   * @throws {AppError} CODE_GEN_EXHAUSTED (500) if no collision-free code was
   *   found within MAX_GENERATE_ATTEMPTS attempts.
   */
  function save(url) {
    let code;
    let attempts = 0;

    do {
      if (attempts >= MAX_GENERATE_ATTEMPTS) {
        throw new AppError(
          'CODE_GEN_EXHAUSTED',
          `Failed to generate a unique short code after ${MAX_GENERATE_ATTEMPTS} attempts`
        );
      }
      code = generate();
      attempts += 1;
    } while (has(code));

    map.set(code, url);
    return code;
  }

  return { has, get, save };
}
