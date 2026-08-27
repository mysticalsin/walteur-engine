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
