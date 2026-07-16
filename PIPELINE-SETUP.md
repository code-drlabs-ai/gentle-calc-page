# Pipeline & Hosting Setup

How this project goes from a Lovable edit to a secured Azure deployment, and every manual
step you must perform once to make the automation work.

**Architecture chosen:** Auth0 PKCE for auth + a **self-hosted Supabase runtime in Azure**
(PostgREST only — no GoTrue, since Auth0 is the identity provider) + Azure Postgres
Flexible Server on a private endpoint. This follows the attached
`phase1-lovable-cloud-to-azure.md` approach, adapted to Auth0.

If you only read one thing: **in this design, RLS is not one of the gates — it is the gate.**
The PostgREST query surface is on the internet; the Postgres server is not. Everything in
"§7 RLS is the gate" is about making that survivable.

Secondary invariant: **secured environments (SIT/UAT/Production) cannot build or run without
a full Auth0 + backend configuration** — the Vite build fails closed
(`vite.config.ts` → `src/lib/env.contract.ts`). Lovable's preview stays open and
unauthenticated so the citizen developer keeps full freedom to ideate.

---

## 1. Architecture

```
                         Front Door + WAF  (single public entry, TLS, rate limit)
                         │
         ┌───────────────┴───────────────┐
         │  /*                            │  /rest/v1/*   (prefix stripped)
         ▼                                ▼
   Static Web App                   Container Apps: PostgREST
   (React SPA, public)              (validates Auth0 JWT via JWKS; no GoTrue)
         │                                │
   Auth0 PKCE (external IdP)              │ private endpoint, VNet-integrated
                                          ▼
                          Azure Database for PostgreSQL Flexible Server
                          (no public access, PITR, managed backups)
```

- **Auth**: Auth0 Authorization Code + PKCE (public SPA client, no client secret in the bundle).
- **Backend**: one container — `postgrest`. Auth0 issues tokens; PostgREST verifies them
  against Auth0's JWKS. No GoTrue, no `auth.users`.
- **Data**: Azure Postgres Flex, private. The Supabase roles + `auth.*` helpers are
  bootstrapped by hand (§6) because Flex is not the `supabase/postgres` image.

### Repo map

| Path | What |
|------|------|
| `vite.config.ts`, `src/lib/env.contract.ts`, `src/lib/env.ts` | Build-time + runtime env gate (auth cannot be off in secured envs). |
| `src/lib/auth.tsx`, `src/components/auth-gate.tsx` | Auth0 PKCE provider + login wall. |
| `src/lib/supabase.ts`, `src/hooks/*` | Typed PostgREST client (Auth0 token as bearer) + history hook. |
| `scripts/generate-swa-config.mjs` | Generates `staticwebapp.config.json` (CSP + headers) per build. |
| `db/bootstrap/000_bootstrap.sql` | One-time: roles, `auth.*` helpers, deny-by-default. |
| `supabase/migrations/*.sql` | Schema + RLS. Append-only, column-scoped. |
| `db/checks/rls_gate.sql` | CI gate: fails if any table is unguarded. |
| `postgrest/README.md` | PostgREST env-var config (Auth0 JWKS). |
| `infra/bicep/**` | IaC for the whole stack, per environment. |
| `.github/workflows/**` | Promotion, scans, infra, migrations, deploy. |

---

## 2. The flow at a glance

```
Lovable editor
   │  (syncs commits to develop)
   ▼
develop ──► promote.yml opens/updates PR develop ➜ main
                 ├─ CodeQL                        (required check)
                 └─ Claude Security Review        (required check; blocks on High/Critical)
                 ▼  auto-merge only when required checks are green
              main
                 ▼  deploy-azure-swa.yml (frontend)   +   deploy-infra.yml / db-migrate.yml (backend, on demand)
        SIT ──► UAT (approval) ──► Production (approval)
```

Frontend (SWA) deploys automatically on push to `main`, promoting SIT → UAT → Prod with
approvals. Backend infra and DB migrations are deliberate, on-demand workflows (§8–§9).

---

## 3. One-time GitHub setup

### 3.1 Branch protection on `main`
Require a PR; require status checks `Analyze (javascript-typescript)` (CodeQL) and
`Claude semantic security review`; require up-to-date branches; disallow bypass.

### 3.2 Repository secrets/variables
| Name | Kind | Used by |
|------|------|---------|
| `AUTOMATION_TOKEN` | secret | `promote.yml` — fine-grained PAT (contents:rw, PRs:rw), so the PR triggers the scans (the built-in token would not). |
| `CLAUDE_API_KEY` | secret | `claude-security-review.yml` — Anthropic key, Claude API + Claude Code, spend-capped. |

### 3.3 GitHub Environments — `sit`, `uat`, `production`
Approvals and per-environment config live here.

- **Variables** (public; compiled into the bundle):
  `VITE_AUTH0_DOMAIN`, `VITE_AUTH0_CLIENT_ID`, `VITE_AUTH0_AUDIENCE`,
  `VITE_SUPABASE_URL` (the env's Front Door hostname), `VITE_SUPABASE_ANON_KEY` (placeholder),
  and for infra: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.
- **Secrets**:
  `AZURE_STATIC_WEB_APPS_API_TOKEN` (frontend deploy), `PG_ADMIN_PASSWORD`,
  `PG_AUTHENTICATOR_PASSWORD`, `AUTH0_JWKS`, `ADMIN_DB_URL` (migrations).
- **Protection**: `uat` and `production` require reviewers; `sit` does not.

### 3.4 Azure OIDC (no standing cloud secret)
`deploy-infra.yml` logs in with `azure/login` via a **federated credential**. For each
environment, create an app registration / user-assigned identity with a federated credential
scoped to `repo:<org>/<repo>:environment:<env>`, grant it `Contributor` on that env's
resource group, and put its client/tenant/subscription ids in the Environment variables above.

---

## 4. Environment model & the build-time gate

`VITE_APP_ENV` = `local | sit | uat | production`. `local` (developer machine **and** Lovable
sandbox) leaves Auth0/backend optional. Secured envs require all of:
`VITE_AUTH0_DOMAIN, VITE_AUTH0_CLIENT_ID, VITE_AUTH0_AUDIENCE, VITE_SUPABASE_URL,
VITE_SUPABASE_ANON_KEY`. Enforced at build (`vite.config.ts`) and runtime (`src/lib/env.ts`);
there is no path that ships a secured bundle with auth off. Verify:
`VITE_APP_ENV=production npm run build` with vars unset → build fails.

To run the real flow locally, copy `.env.example` to `.env` and fill it in.

---

## 5. Why `promote.yml` uses a PAT

GitHub does not start workflow runs from events created by the built-in `GITHUB_TOKEN`
(loop protection), so a PR opened with it would never trigger the scans. `AUTOMATION_TOKEN`
(fine-grained, repo-scoped) makes the required checks actually run.

---

## 6. Bootstrap the database (once per server, by hand)

Flex is not `supabase/postgres`, so create the roles and `auth.*` helpers first. Run as the
admin, over a path that can reach the private server (self-hosted runner in the VNet, or a
jump host / `az containerapp exec`):

```bash
psql "$ADMIN_DB_URL" -v ON_ERROR_STOP=1 \
     -v authenticator_pw="$(openssl rand -base64 24)" \
     -f db/bootstrap/000_bootstrap.sql
```

This creates `anon` / `authenticated` / `service_role` / `authenticator`, the `auth.jwt()`
/ `auth.jwt_sub()` / `auth.role()` helpers (reading Auth0 claims — the sub is TEXT, not a
uuid), the `private` schema, and **deny-by-default** privileges. Use the same
`authenticator_pw` as `PG_AUTHENTICATOR_PASSWORD` so PostgREST can connect.

> `service_role` is created but NOT granted to `authenticator` — nothing on the request path
> can bypass RLS in Phase 1. Grant it consciously only when edge functions arrive.

---

## 7. RLS is the gate — the six moves (all wired)

The query surface is public, so RLS is the whole control. Implemented in the bootstrap +
`supabase/migrations/0001_calculations.sql` + `db/checks/rls_gate.sql`:

1. **Deny by default** — the bootstrap omits the `alter default privileges … grant all …`
   that Supabase ships. A new Lovable table is **inert in Azure until a migration grants it**.
   That one explicit `grant` line, in a PR, is your review gate (~30s per table).
2. **RLS enabled AND forced** — `force` matters; without it the owner connection bypasses RLS
   and fails *open*. `rls_gate.sql` fails CI if any public table isn't both.
3. **Sensitive columns leave `public`** — the `private` schema is not in `PGRST_DB_SCHEMAS`,
   so PostgREST cannot see it. No policy can be wrong about a table it can't reach.
4. **Column-level grants** — the client may write only `expression`/`result`, never
   `user_id`/`id`/`created_at`.
5. **Server-authoritative ownership** — `user_id` defaults from `auth.jwt_sub()` and the
   `WITH CHECK` re-verifies it; a forged `user_id` in the body is rejected.
6. **Blast-radius caps** — `PGRST_DB_MAX_ROWS=1000`, plan + OpenAPI disabled, Front Door rate
   limit on `/rest/v1/*`, and `service_role` kept off the request path entirely.

**Known limit (why Phase 2 exists):** RLS answers "which rows," never "is this value
legitimate." A user can insert a row that is validly *theirs* but has a nonsense value.
Anything the server must *decide* (amounts, eligibility, approvals) needs the API in Phase 2.
Nothing here is thrown away then — the six moves become defense-in-depth.

---

## 8. Auth0 tenant setup (PKCE)

1. **Application → Single Page Application** (public client, PKCE, no secret).
2. **Callback / Logout / Web Origins** = each env's site origin (the Front Door hostname or
   your custom domain); add `http://localhost:8080` for local.
3. **Refresh Token Rotation**: on. Tokens are kept **in memory only** (`cacheLocation:
   "memory"`, `src/lib/auth.tsx`) so XSS can't lift a long-lived token; the cost is a silent
   re-auth on reload, which needs the custom domain below.
4. **Custom domain**: required for SIT/UAT/Prod, else silent re-auth is cross-site and gets
   blocked. Set `VITE_AUTH0_DOMAIN` to it.
5. **API**: its Identifier = `VITE_AUTH0_AUDIENCE` (also `PGRST_JWT_AUD`).
6. **Login Action** — add the role claim PostgREST maps to a DB role:
   ```js
   exports.onExecutePostLogin = async (event, api) => {
     api.accessToken.setCustomClaim("role", "authenticated");
   };
   ```
   Without it, PostgREST runs the request as `anon` and every policy fails closed.
7. **JWKS**: fetch `https://<custom-domain>/.well-known/jwks.json` and store it as the
   `AUTH0_JWKS` GitHub Environment secret. PostgREST verifies RS256 tokens against it.

---

## 9. Provision infra & apply migrations

### 9.1 Infra (`deploy-infra.yml`, on demand)
Creates a resource group `rg-gentlecalc-<env>` first, then runs the Bicep. The workflow does
a `what-if` preview, then `az deployment group create` with the env param file. Secrets
(`PG_ADMIN_PASSWORD`, `PG_AUTHENTICATOR_PASSWORD`, `AUTH0_JWKS`) are injected into
`readEnvironmentVariable` at build; nothing is committed. Give each env a non-overlapping
VNet range (already set: SIT 10.10, UAT 10.20, Prod 10.30). Prod uses General Purpose
compute with zone-redundant HA + geo-redundant backup.

### 9.2 Migrations (`db-migrate.yml`, on demand) — read the network note
The Postgres server has **no public access**. A GitHub-hosted runner cannot reach it. This
workflow is written for a **self-hosted runner inside the VNet** (`runs-on: [self-hosted,
vnet, <env>]`); alternatively run migrations as an `az containerapp job` in the Container
Apps environment. It applies `supabase/migrations/*.sql` in order, then runs `rls_gate.sql`.
Run it **before** the app deploy and gate the deploy on it. The bootstrap (§6) is separate
and precedes the first migration.

**Rule with no exceptions:** the Azure schema changes only by applying repo migrations.
Nobody opens a SQL editor against Azure Postgres and types — the moment someone does, Lovable
Cloud and Azure drift and the next migration fails.

---

## 10. Frontend deploy (`deploy-azure-swa.yml`)

On push to `main`: builds the SPA with each env's config compiled in, generates
`staticwebapp.config.json` (per-env CSP naming the Auth0 + Front Door origins, per-build
inline-script hashes, HSTS, `frame-ancestors 'none'`, nosniff, Referrer-Policy,
Permissions-Policy, SPA fallback to `/_shell.html`), and publishes to the env's SWA. The
composite action also **fails the build if a `supabase.co`/`lovable` endpoint is hard-coded
in `src/`** (Lovable periodically rewrites client config back to its Cloud). SIT auto,
UAT/Prod gated by Environment approvals. Actions are pinned to commit SHAs.

### CodeQL gating note
The repo uses CodeQL **default setup**, so `codeql.yml` keeps `upload: false` (advanced-config
uploads are rejected under default setup). To make it block: set Code scanning → Check
Failures to High+, and add the CodeQL check to `main` branch protection.

---

## 11. Verify before you trust any of it

1. `curl <front-door>/rest/v1/calculations` with **no** Authorization → empty or 401, not rows.
2. Sign in as user A, request B's rows → zero rows.
3. `psql` as `authenticated` with no JWT context, `select * from calculations` → zero rows.
   (Rows here mean `force row level security` didn't take.)
4. Ask Lovable to add a table, let it flow through → the migrate/RLS gate **fails** until you
   add the explicit grant. If it deploys clean, your gate isn't wired.
5. `select rolname from pg_roles where rolbypassrls` → only `service_role` (not on the path).
6. Grep built `dist/` for `supabase.co` → nothing (the deploy leak-check enforces this).
7. `VITE_APP_ENV=production npm run build` with Auth0 vars unset → build fails.

Tests 3 and 4 catch the failures that are silent in production. Run both in CI.

---

## 12. Security checklist (go-live)

- [ ] `main` branch protection requires both scans and blocks bypass.
- [ ] Claude review blocks on High/Critical (hard gate is on by default now).
- [ ] CodeQL Check Failures set to High+ and required on `main`.
- [ ] `AUTOMATION_TOKEN` fine-grained/repo-scoped; `CLAUDE_API_KEY` spend-capped.
- [ ] Each Environment has its SWA token + DB/Auth0 secrets; UAT/Prod have reviewers.
- [ ] Azure OIDC federated credentials per env; no standing Azure secret in GitHub.
- [ ] Auth0 apps are SPA type; custom domain set; callbacks match; rotation on; Login Action
      sets `role: authenticated`; JWKS stored as `AUTH0_JWKS`.
- [ ] Bootstrap applied per server; `authenticator` password matches PostgREST's.
- [ ] Postgres `publicNetworkAccess` Disabled; reachable only in-VNet.
- [ ] `service_role` exists but is NOT granted to `authenticator`; not on any request-path container.
- [ ] `rls_gate.sql` runs in CI and gates the app deploy.
- [ ] Migrations are the ONLY way the Azure schema changes.
- [ ] `.env` gitignored; only `.env.example` committed.
