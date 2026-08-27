// Scaffold contract test — asserts package.json declares the exact zero-dependency
// shape this project requires: ESM module type, a single node:test script, an
// engines floor, and NO dependency entries of any kind (empty tree).
//
// TDD note: this test is written BEFORE package.json exists. It must FAIL
// (ENOENT reading package.json) on a clean checkout, then PASS once the
// scaffold task creates package.json with the required shape.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const packageJsonPath = join(__dirname, '..', 'package.json');

function readPackageJson() {
  const raw = readFileSync(packageJsonPath, 'utf8');
  return JSON.parse(raw);
}

test('scaffold: package.json exists and is valid JSON', () => {
  assert.doesNotThrow(() => readPackageJson());
});

test('scaffold: package.json declares type "module"', () => {
  const pkg = readPackageJson();
  assert.equal(pkg.type, 'module');
});

test('scaffold: package.json declares the single node --test script', () => {
  const pkg = readPackageJson();
  assert.ok(pkg.scripts, 'scripts field must exist');
  assert.equal(pkg.scripts.test, 'node --test');
  // Exactly one script — no extra script entries smuggled in.
  assert.equal(
    Object.keys(pkg.scripts).length,
    1,
    'scripts must contain exactly one entry: test',
  );
});

test('scaffold: package.json declares engines.node >=22 floor', () => {
  const pkg = readPackageJson();
  assert.ok(pkg.engines, 'engines field must exist');
  assert.equal(pkg.engines.node, '>=22');
});

test('scaffold: package.json has no dependencies key with any entries', () => {
  const pkg = readPackageJson();
  if (Object.prototype.hasOwnProperty.call(pkg, 'dependencies')) {
    assert.equal(
      Object.keys(pkg.dependencies).length,
      0,
      'dependencies must contain no keys (empty tree)',
    );
  }
});

test('scaffold: package.json has no devDependencies key with any entries', () => {
  const pkg = readPackageJson();
  if (Object.prototype.hasOwnProperty.call(pkg, 'devDependencies')) {
    assert.equal(
      Object.keys(pkg.devDependencies).length,
      0,
      'devDependencies must contain no keys (empty tree)',
    );
  }
});

test('scaffold: package.json declares required identity fields', () => {
  const pkg = readPackageJson();
  assert.ok(typeof pkg.name === 'string' && pkg.name.length > 0, 'name must be a non-empty string');
  assert.equal(pkg.private, true);
  assert.equal(pkg.version, '1.0.0');
});
