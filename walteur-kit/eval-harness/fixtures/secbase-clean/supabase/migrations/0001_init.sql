-- Multi-tenant invoicing schema.

create extension if not exists "pgcrypto";

create table tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table invoices (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  customer_name text not null,
  amount_cents integer not null,
  status text not null default 'draft',
  created_at timestamptz not null default now()
);

create index invoices_tenant_id_idx on invoices (tenant_id);

-- Row-Level Security: tenants only ever see their own rows.
alter table tenants enable row level security;
alter table invoices enable row level security;

create policy tenant_isolation_tenants on tenants
  using (id = current_setting('app.current_tenant_id')::uuid);

create policy tenant_isolation_invoices on invoices
  using (tenant_id = current_setting('app.current_tenant_id')::uuid);
