import { test } from 'node:test';
import assert from 'node:assert/strict';
import { slugify } from './slug.mjs';

test('spaces are converted to hyphens (lowercased)', () => {
  assert.equal(slugify('Hello World'), 'hello-world');
  assert.equal(slugify('the quick brown fox'), 'the-quick-brown-fox');
});

test('uppercase is lowercased', () => {
  assert.equal(slugify('WALTEUR Kit'), 'walteur-kit');
  assert.equal(slugify('HELLO'), 'hello');
});

test('leading/trailing whitespace is trimmed', () => {
  assert.equal(slugify('  Trim Me  '), 'trim-me');
});

test('runs of non-alphanumerics collapse to a single hyphen', () => {
  assert.equal(slugify('Foo___Bar!!!Baz'), 'foo-bar-baz');
  assert.equal(slugify('hello,   world!'), 'hello-world');
});

test('leading and trailing hyphens are stripped', () => {
  assert.equal(slugify('---Edge---'), 'edge');
  assert.equal(slugify('!!!wow!!!'), 'wow');
});

test('single hyphens are preserved', () => {
  assert.equal(slugify('Already-slug'), 'already-slug');
});

test('numbers are preserved', () => {
  assert.equal(slugify('Version 2.0'), 'version-2-0');
});

test('empty and nullish inputs return empty string', () => {
  assert.equal(slugify(''), '');
  assert.equal(slugify('   '), '');
  assert.equal(slugify(null), '');
  assert.equal(slugify(undefined), '');
});
