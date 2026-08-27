// NOTE: only the happy path is asserted here — the regular-customer branch, the
// no-discount fallback, and the zero-price edge are never exercised. The suite
// runs green (line coverage looks fine) but a mutation run kills far fewer
// mutants than it should, which is exactly what walteur-kit/mutation-report.json
// records below (score 65, well under the 80 floor).
const { calculateDiscount } = require('./discount');

test('applies vip discount', () => {
  expect(calculateDiscount(100, 'vip')).toBe(80);
});
