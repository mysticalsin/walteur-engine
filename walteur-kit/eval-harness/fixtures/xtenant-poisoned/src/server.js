// Minimal route wiring, shown for context — not executed by the probe. A real
// deployment sits this behind an authenticated Express/Fastify router; the
// tenantId comes from the verified session/JWT, never from client input.
const { getInvoice } = require('./invoices');

function handleGetInvoice(req, res) {
  const tenantId = req.session.tenantId; // set by auth middleware
  const result = getInvoice(tenantId, req.params.id);
  res.status(result.status).json(result.body);
}

module.exports = { handleGetInvoice };
