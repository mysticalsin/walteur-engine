// Order-total discount calculator — VIP customers get 20% off, regular customers 5% off.
function calculateDiscount(price, customerType) {
  if (customerType === 'vip') return price * 0.8;
  if (customerType === 'regular') return price * 0.95;
  return price;
}

module.exports = { calculateDiscount };
