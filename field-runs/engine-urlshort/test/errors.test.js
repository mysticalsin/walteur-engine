// test/errors.test.js
// TDD: written BEFORE src/errors.js exists. Must fail (module not found), then pass
// once src/errors.js is implemented. Exercises the single-source-of-truth error
// registry + AppError + the sendError/sendJson HTTP response helpers.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppError, ERRORS, sendError, sendJson } from '../src/errors.js';

// Full expected registry per design §5 — every code the rest of the system will throw.
const EXPECTED_REGISTRY = {
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
};

test('ERRORS registry has exactly the expected codes, no missing / no extra', () => {
  const expectedCodes = Object.keys(EXPECTED_REGISTRY).sort();
  const actualCodes = Object.keys(ERRORS).sort();
  assert.deepStrictEqual(
    actualCodes,
    expectedCodes,
    'ERRORS registry must map exactly the designed set of UPPER_SNAKE codes'
  );
});

test('ERRORS registry maps every code to its correct default status', () => {
  for (const [code, status] of Object.entries(EXPECTED_REGISTRY)) {
    assert.strictEqual(
      ERRORS[code],
      status,
      `expected ERRORS.${code} === ${status}, got ${ERRORS[code]}`
    );
  }
});

test('ERRORS registry has no duplicate status collisions hiding a copy-paste bug', () => {
  // Not "no two codes share a status" (that's expected — many are 400) but a structural
  // guard: registry values must all be small positive integers in the valid HTTP range,
  // and there must be no accidental duplicate KEYS (impossible in object literals, but
  // guard the key set is exactly array length to catch generation bugs upstream).
  const keys = Object.keys(ERRORS);
  const uniqueKeys = new Set(keys);
  assert.strictEqual(uniqueKeys.size, keys.length, 'ERRORS must not have duplicate codes');
  for (const [code, status] of Object.entries(ERRORS)) {
    assert.ok(
      Number.isInteger(status) && status >= 400 && status < 600,
      `ERRORS.${code} must be a valid 4xx/5xx integer status, got ${status}`
    );
  }
});

test('ERRORS registry object is frozen (single source of truth cannot be mutated)', () => {
  assert.ok(Object.isFrozen(ERRORS), 'ERRORS registry must be Object.frozen');
  assert.throws(() => {
    'use strict';
    ERRORS.NEW_CODE = 400;
  });
});

test('AppError carries the right status for a sampled known code (INVALID_URL)', () => {
  const err = new AppError('INVALID_URL', 'not a valid http(s) url');
  assert.ok(err instanceof Error, 'AppError must extend Error');
  assert.ok(err instanceof AppError);
  assert.strictEqual(err.code, 'INVALID_URL');
  assert.strictEqual(err.status, ERRORS.INVALID_URL);
  assert.strictEqual(err.status, 400);
  assert.strictEqual(err.message, 'not a valid http(s) url');
  assert.strictEqual(err.name, 'AppError');
});

test('AppError carries the right status for a sampled known code (CODE_GEN_EXHAUSTED)', () => {
  const err = new AppError('CODE_GEN_EXHAUSTED', 'exhausted retry budget');
  assert.strictEqual(err.code, 'CODE_GEN_EXHAUSTED');
  assert.strictEqual(err.status, 500);
});

test('AppError carries the right status for a sampled known code (METHOD_NOT_ALLOWED)', () => {
  const err = new AppError('METHOD_NOT_ALLOWED', 'PUT not allowed');
  assert.strictEqual(err.code, 'METHOD_NOT_ALLOWED');
  assert.strictEqual(err.status, 405);
});

test('AppError defaults message to the code when no message is supplied', () => {
  const err = new AppError('NOT_FOUND');
  assert.strictEqual(err.code, 'NOT_FOUND');
  assert.strictEqual(err.status, 404);
  assert.ok(typeof err.message === 'string' && err.message.length > 0);
});

test('AppError throws a TypeError for an unknown/unregistered code (fail closed, no silent 500 default with unknown code label)', () => {
  assert.throws(
    () => new AppError('TOTALLY_MADE_UP_CODE', 'x'),
    TypeError,
    'constructing AppError with an unregistered code must throw, not silently accept it'
  );
});

test('AppError.captureStackTrace-style stack is present but toJSON/serialization never leaks it via the wire helpers', () => {
  const err = new AppError('INTERNAL_ERROR', 'boom');
  assert.ok(typeof err.stack === 'string' && err.stack.length > 0);
});

// ---- sendJson / sendError: fake `res` objects (node:http ServerResponse shape) ----

function makeFakeRes() {
  const state = {
    headers: {},
    statusCode: undefined,
    ended: false,
    body: undefined,
  };
  const res = {
    setHeader(name, value) {
      state.headers[name.toLowerCase()] = value;
    },
    writeHead(status, headers) {
      state.statusCode = status;
      if (headers) {
        for (const [k, v] of Object.entries(headers)) {
          state.headers[k.toLowerCase()] = v;
        }
      }
    },
    end(chunk) {
      state.ended = true;
      state.body = chunk;
    },
  };
  return { res, state };
}

test('sendJson always sets Content-Type: application/json and writes the given status + body', () => {
  const { res, state } = makeFakeRes();
  sendJson(res, 201, { code: 'abc123', shortUrl: 'http://localhost/abc123' });
  assert.strictEqual(state.statusCode, 201);
  assert.strictEqual(state.headers['content-type'], 'application/json');
  assert.ok(state.ended);
  const parsed = JSON.parse(state.body);
  assert.deepStrictEqual(parsed, { code: 'abc123', shortUrl: 'http://localhost/abc123' });
});

test('sendJson serializes an empty object body correctly', () => {
  const { res, state } = makeFakeRes();
  sendJson(res, 200, {});
  assert.strictEqual(JSON.parse(state.body).constructor, Object);
  assert.deepStrictEqual(JSON.parse(state.body), {});
});

test('sendError always sets Content-Type: application/json and emits {error:{code,message}}', () => {
  const { res, state } = makeFakeRes();
  sendError(res, 400, 'MISSING_URL', 'url is required');
  assert.strictEqual(state.statusCode, 400);
  assert.strictEqual(state.headers['content-type'], 'application/json');
  const parsed = JSON.parse(state.body);
  assert.deepStrictEqual(parsed, { error: { code: 'MISSING_URL', message: 'url is required' } });
});

test('sendError never leaks a stack trace onto the wire', () => {
  const { res, state } = makeFakeRes();
  sendError(res, 500, 'INTERNAL_ERROR', 'unexpected failure');
  const raw = state.body;
  assert.ok(!raw.includes('    at '), 'response body must not contain a stack-trace frame');
  const parsed = JSON.parse(raw);
  assert.strictEqual(Object.keys(parsed).length, 1);
  assert.deepStrictEqual(Object.keys(parsed.error).sort(), ['code', 'message']);
});

test('sendError works directly from a thrown AppError (status/code/message passthrough)', () => {
  const { res, state } = makeFakeRes();
  try {
    throw new AppError('DISALLOWED_PROTOCOL', 'only http/https allowed');
  } catch (err) {
    sendError(res, err.status, err.code, err.message);
  }
  assert.strictEqual(state.statusCode, 400);
  assert.deepStrictEqual(JSON.parse(state.body), {
    error: { code: 'DISALLOWED_PROTOCOL', message: 'only http/https allowed' },
  });
});
