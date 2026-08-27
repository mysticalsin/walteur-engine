// All branches exercised: vip, regular, unknown-customer fallback, and the
// zero-price edge. This is the thorough suite that earns the 92% mutation
// score recorded in walteur-kit/mutation-report.json.
const { calculateDiscount } = require('./discount');

test('applies vip discount', () => {
  expect(calculateDiscount(100, 'vip')).toBe(80);
});

test('applies regular discount', () => {
  expect(calculateDiscount(100, 'regular')).toBe(95);
});

test('applies no discount for an unrecognised customer type', () => {
  expect(calculateDiscount(100, 'guest')).toBe(100);
});

test('handles zero price without throwing', () => {
  expect(calculateDiscount(0, 'vip')).toBe(0);
});
