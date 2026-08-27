// Invoice read path — GET /api/invoices/:id handler logic.
//
// Correct tenant scoping: the lookup requires BOTH the invoice id AND the
// caller's tenant_id to match the row before returning it. A cross-tenant
// request for an id that exists (but belongs to a different tenant) is
// indistinguishable from "not found" — no leak, no oracle for enumeration.
const { allInvoices } = require('./db');

function getInvoice(tenantId, invoiceId) {
  const row = allInvoices().find((inv) => inv.id === invoiceId && inv.tenant_id === tenantId);
  if (!row) {
    return { status: 403, body: null };
  }
  return { status: 200, body: row };
}

module.exports = { getInvoice };
