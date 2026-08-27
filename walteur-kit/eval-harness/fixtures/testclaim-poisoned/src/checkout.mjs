// Order checkout — sums line items, applies a percentage discount, then tax.

export function applyDiscount(total, discountPercent) {
  // BUG: subtracts the raw percent value instead of a percentage of the total.
  // applyDiscount(200, 10) should be 180 (10% off 200); this returns 190.
  return total - discountPercent;
}

export function calculateTotal(items, taxRate) {
  const subtotal = items.reduce((sum, item) => sum + item.price * item.qty, 0);
  return Number((subtotal + subtotal * taxRate).toFixed(2));
}
