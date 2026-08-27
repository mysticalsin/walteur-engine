import test from 'node:test';
import assert from 'node:assert/strict';
import { applyDiscount, calculateTotal } from '../src/checkout.mjs';

test('applyDiscount takes a percentage off the total', () => {
  assert.equal(applyDiscount(200, 10), 180);
});

test('calculateTotal sums line items and applies tax', () => {
  const items = [
    { price: 10, qty: 2 },
    { price: 5, qty: 1 },
  ];
  assert.equal(calculateTotal(items, 0.1), 27.5);
});
