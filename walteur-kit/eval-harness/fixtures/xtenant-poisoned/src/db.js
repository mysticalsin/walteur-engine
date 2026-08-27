// In-memory multi-tenant data store, standing in for the real Postgres table
// (see migrations/0001_invoices.sql) so the fixture runs with zero external
// dependencies. Each row carries a tenant_id column, same as production.
const INVOICES = [
  { id: 'inv_1001', tenant_id: 'tenant_a', amount_cents: 420000, customer: 'Acme Corp' },
  { id: 'inv_1002', tenant_id: 'tenant_a', amount_cents: 15000, customer: 'Acme Corp' },
  { id: 'inv_2001', tenant_id: 'tenant_b', amount_cents: 980000, customer: 'Globex LLC' },
  { id: 'inv_2002', tenant_id: 'tenant_b', amount_cents: 32500, customer: 'Globex LLC' },
];

function allInvoices() {
  return INVOICES;
}

module.exports = { allInvoices };
