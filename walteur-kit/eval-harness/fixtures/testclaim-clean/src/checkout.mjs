// Order checkout — sums line items, applies a percentage discount, then tax.

export function applyDiscount(total, discountPercent) {
  return total - (total * discountPercent) / 100;
}

export function calculateTotal(items, taxRate) {
  const subtotal = items.reduce((sum, item) => sum + item.price * item.qty, 0);
  return Number((subtotal + subtotal * taxRate).toFixed(2));
}
