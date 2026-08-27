import { test } from 'node:test'
import assert from 'node:assert'
import { health } from './health.mjs'
test('health ok', () => { assert.equal(health().status, 'ok') })
