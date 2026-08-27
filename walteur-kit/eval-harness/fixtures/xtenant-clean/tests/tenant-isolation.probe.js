// Cross-tenant probe (rank 2/9 contract): authenticate as tenant_a, request a
// resource that belongs to tenant_b, and require the API to deny it. Exercises
// the real handler in src/invoices.js — no mocking of the code under test.
const path = require('path');
const { getInvoice } = require(path.join(__dirname, '..', 'src', 'invoices.js'));

const ATTACKER_TENANT = 'tenant_a';
const VICTIM_INVOICE_ID = 'inv_2001'; // known to belong to tenant_b

const result = getInvoice(ATTACKER_TENANT, VICTIM_INVOICE_ID);

if (result.status === 403 || result.status === 404) {
  console.log('deny: cross-tenant invoice read correctly forbidden (status ' + result.status + ')');
  process.exit(0);
} else {
  console.error(
    'LEAK: tenant_a read tenant_b\'s invoice, status ' + result.status + ' body=' + JSON.stringify(result.body)
  );
  process.exit(1);
}
