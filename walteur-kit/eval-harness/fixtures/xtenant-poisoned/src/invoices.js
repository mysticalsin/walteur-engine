// Invoice read path — GET /api/invoices/:id handler logic.
//
// BUG (missing tenant scope): the lookup matches on invoice id only. It never
// checks that the authenticated caller's tenant_id matches the row's
// tenant_id, so any authenticated tenant can read any other tenant's invoice
// simply by knowing (or enumerating) the invoice id. This is the single most
// common multi-tenant SaaS defect: a WHERE tenant_id = ? clause dropped from
// one query path while the rest of the app has it everywhere else.
const { allInvoices } = require('./db');

function getInvoice(tenantId, invoiceId) {
  const row = allInvoices().find((inv) => inv.id === invoiceId);
  if (!row) {
    return { status: 404, body: null };
  }
  return { status: 200, body: row };
}

module.exports = { getInvoice };
