# billing-worker

Background worker that reconciles Stripe invoices against nightly AWS S3 export batches.

## Configuration

All credentials are expected to be injected at runtime by the platform's secret manager. See
`src/config/aws.js` for the AWS client configuration and `.env.example` for the full list of
environment variables the worker reads.

## Running locally

```
cp .env.example .env
npm start
```
