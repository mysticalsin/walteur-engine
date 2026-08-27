export function listInvoices(db) {
  return db.query("select id, total from invoices")
}
