# Invoicer API

Multi-tenant invoicing backend. Each tenant's invoices live in the shared
`invoices` table, discriminated by `tenant_id`. Postgres schema lives in
`supabase/migrations/`; the app talks to it through `src/lib/db.ts`.

## Data model

- `tenants` — one row per customer organization.
- `invoices` — one row per invoice, scoped to a tenant via `tenant_id`.

## Local dev

```
npm install
npm run migrate
npm test
```
