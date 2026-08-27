// src/errors.js
// SINGLE SOURCE OF TRUTH for typed application errors and JSON response helpers.
//
// Every error the service can raise is registered here as an UPPER_SNAKE code mapped
// to its default HTTP status (design doc §5). Downstream modules MUST throw AppError
// with one of these registered codes rather than inventing ad-hoc error shapes, and
// MUST send error responses only through `sendError` so the wire contract
// `{ error: { code, message } }` and `Content-Type: application/json` stay uniform
// everywhere (no bare strings, no stack traces ever reach the client).

/**
 * Frozen registry of every error code this service can emit, mapped to its default
 * HTTP status. Frozen so no module can accidentally (or maliciously) mutate the
 * single source of truth at runtime.
 * @type {Readonly<Record<string, number>>}
 */
export const ERRORS = Object.freeze({
  EMPTY_BODY: 400,
  INVALID_JSON: 400,
  MISSING_URL: 400,
  INVALID_TYPE: 400,
  INVALID_URL: 400,
  DISALLOWED_PROTOCOL: 400,
  PAYLOAD_TOO_LARGE: 413,
  CODE_NOT_FOUND: 404,
  NOT_FOUND: 404,
  METHOD_NOT_ALLOWED: 405,
  CODE_GEN_EXHAUSTED: 500,
  INTERNAL_ERROR: 500,
});

/**
 * Typed application error. Every throw site in this codebase should throw an
 * AppError constructed with a code from the ERRORS registry — never a bare Error,
 * never a raw string — so every catch site can uniformly read `.status` and `.code`
 * and hand them straight to `sendError` without re-deriving a status code.
 */
export class AppError extends Error {
  /**
   * @param {string} code - Must be a key already present in the frozen ERRORS registry.
   * @param {string} [message] - Human-readable detail; defaults to the code itself.
   */
  constructor(code, message) {
    if (!Object.prototype.hasOwnProperty.call(ERRORS, code)) {
      // Fail closed: an unregistered code is a programmer error, not a runtime
      // condition to paper over with a default 500. Catch this in development/tests,
      // never let it reach a client as a mislabeled error.
      throw new TypeError(
        `AppError: "${code}" is not a registered error code. ` +
          `Add it to the ERRORS registry in src/errors.js before throwing it.`
      );
    }
    super(message || code);
    this.name = 'AppError';
    this.code = code;
    this.status = ERRORS[code];
    // Preserve a proper stack trace pointing at the throw site (V8-specific, no-op
    // elsewhere). This is for server-side logging ONLY — sendError never puts the
    // stack on the wire.
    if (typeof Error.captureStackTrace === 'function') {
      Error.captureStackTrace(this, AppError);
    }
  }
}

/**
 * Write a JSON success response. Always sets Content-Type: application/json.
 * @param {import('node:http').ServerResponse} res
 * @param {number} status
 * @param {unknown} obj - JSON-serializable response body.
 */
export function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.setHeader('Content-Type', 'application/json');
  res.writeHead(status);
  res.end(body);
}

/**
 * Write a typed JSON error response. Always sets Content-Type: application/json and
 * emits the uniform `{ error: { code, message } }` envelope — never a stack trace,
 * never an ad-hoc shape. This is the ONLY sanctioned way to send an error to a client.
 * @param {import('node:http').ServerResponse} res
 * @param {number} status
 * @param {string} code
 * @param {string} message
 */
export function sendError(res, status, code, message) {
  sendJson(res, status, { error: { code, message } });
}
