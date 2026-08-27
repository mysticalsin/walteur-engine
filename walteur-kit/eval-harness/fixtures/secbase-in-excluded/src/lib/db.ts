import { createClient } from "@supabase/supabase-js";

// Server-side Supabase client. URL/key come from the deployment environment,
// never hardcoded here.
export const db = createClient(
  process.env.SUPABASE_URL as string,
  process.env.SUPABASE_SERVICE_ROLE_KEY as string
);

export async function listInvoicesForTenant(tenantId: string) {
  const { data, error } = await db
    .from("invoices")
    .select("id, customer_name, amount_cents, status, created_at")
    .eq("tenant_id", tenantId);
  if (error) throw error;
  return data;
}
