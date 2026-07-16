# PostgREST configuration (Auth0 variant)

PostgREST is the **only** public backend container in this design. There is **no GoTrue** —
Auth0 issues the JWTs and PostgREST verifies them against Auth0's public keys.

The container image is the upstream `postgrest/postgrest`. All configuration is via
environment variables, set on the Container App (see `infra/bicep/modules/containerapp.bicep`).
This file is the source of truth for what each variable must be and why.

## Environment variables

| Variable | Value | Why |
|----------|-------|-----|
| `PGRST_DB_URI` | `postgres://authenticator:<pw>@<flex-private-fqdn>:5432/appdb?sslmode=require` | Connects as the **authenticator** login role over the private endpoint. Never the admin role. |
| `PGRST_DB_SCHEMAS` | `public` | The ONLY schema PostgREST exposes. `private` is unreachable — no policy can be wrong about a table PostgREST can't see. |
| `PGRST_DB_ANON_ROLE` | `anon` | Role used for requests with no valid token. `anon` holds no privileges (bootstrap), so unauthenticated = nothing. |
| `PGRST_JWT_SECRET` | Auth0 JWKS JSON (the contents of `https://<tenant>/.well-known/jwks.json`) | Verifies Auth0's **RS256** tokens against Auth0's public keys. A JWKS value (not a shared secret) means there is no symmetric key to leak. |
| `PGRST_JWT_AUD` | `VITE_AUTH0_AUDIENCE` (the Auth0 API identifier) | Rejects tokens minted for a different audience. |
| `PGRST_JWT_ROLE_CLAIM_KEY` | `.role` | PostgREST reads the DB role from the token's `role` claim, which the Auth0 Login Action sets to `authenticated`. |
| `PGRST_DB_MAX_ROWS` | `1000` | Caps enumeration if a policy is ever too loose — a leak drips, not floods. |
| `PGRST_DB_PLAN_ENABLED` | `false` | Do not expose query plans. |
| `PGRST_OPENAPI_MODE` | `disabled` | Do not publish the schema as an OpenAPI document. |
| `PGRST_DB_POOL` | `10` | Small pool; Flexible Server connection budgets are finite. |
| `PGRST_SERVER_PORT` | `3000` | Container ingress target. |
| `PGRST_LOG_LEVEL` | `info` | |

> `PGRST_JWT_SECRET` as a JWKS: PostgREST accepts a JWK Set for asymmetric verification.
> Fetch Auth0's JWKS once per environment and store it as the Container App secret
> `pgrst-jwt-jwks`. Rotate it if Auth0 rotates signing keys (rare; Auth0 publishes new keys
> ahead of rotation, so keeping the full set current avoids downtime).

## What PostgREST does NOT get

- **No `service_role` / admin credentials.** The container connects only as `authenticator`,
  which cannot bypass RLS (it is not granted `service_role` — see the bootstrap).
- **No write to `private`.** Not in `PGRST_DB_SCHEMAS`.
- **No GoTrue endpoints.** `/auth/v1/*` does not exist here; auth is entirely Auth0.

## Request flow

```
Browser (supabase-js, Authorization: Bearer <Auth0 access token>)
  → Front Door + WAF   (rate limit on /rest/v1/*)
  → Container App: PostgREST
      → verifies token signature against Auth0 JWKS, checks aud + exp
      → SET ROLE authenticated; SET request.jwt.claims = <payload>
      → runs the SQL under RLS, which reads auth.jwt_sub() / auth.role()
  → Azure Postgres Flexible Server (private endpoint)
```

`supabase-js` is used only as a typed REST client here; its `accessToken` hook
(`src/lib/supabase.ts`) attaches the Auth0 token. No Supabase-managed service is involved.
