# Lovable → Azure: Secure Hosting Technical Reference

**Purpose.** A reusable, self-contained technical playbook for taking a Lovable-authored web
app from the Lovable editor, through a security-gated GitHub pipeline, into a hardened Azure
deployment — **without** taking away the citizen developer's freedom to keep ideating in
Lovable. It is written so that another instance of Claude, pointed at a *different* Lovable
app, can apply the same approaches by following it.

**How to use this document (for Claude on a new app).**
1. Read §2 "Applicability" first — confirm the target app fits, or note where it diverges.
2. Read §3 "Architecture" and §4 "Decisions" to load the mental model.
3. Apply sections §6–§13 in order; each is a self-contained implementation unit with the
   load-bearing code and the reasoning.
4. Use §14 (secrets inventory), §15 (runbook), §16 (verification) to stand up an environment.
5. Read §18 "Gotchas" *before* writing code — several are non-obvious and expensive to
   rediscover.
6. Use §20 "Adaptation guide" to know exactly what changes per app.

> This reference was extracted from a working implementation (a Lovable calculator app,
> `tanstack_start_ts` template). File paths in `monospace` refer to that reference
> implementation; reproduce the *pattern*, not necessarily the exact path.

---

## 1. Glossary

| Term | Meaning |
|------|---------|
| Lovable sandbox | The environment Lovable runs your build in (detected via env vars). It force-pins some build settings. |
| Citizen developer | The non-engineer who keeps editing the app in Lovable chat. Must never be blocked. |
| Secured environment | SIT / UAT / Production. Real users, real data, auth mandatory. |
| PostgREST | Turns a Postgres database into a REST API. The public backend in this design. |
| GoTrue | Supabase's auth server. **Not used here** — Auth0 replaces it. |
| PKCE | Proof Key for Code Exchange — the OAuth flow for public clients with no secret. |
| RLS | Row-Level Security — Postgres per-row access policies. In this design it is *the* security boundary. |
| Front Door | Azure's global edge/CDN + WAF; the single public entry point. |
| Flex | Azure Database for PostgreSQL Flexible Server. |

---

## 2. Applicability & preconditions

**This reference fits an app that:**
- Is authored in Lovable and syncs to GitHub (a branch like `develop`).
- Is a browser SPA (React/Vite; here TanStack Start). No server-rendered secrets required.
- Needs real authentication in higher environments (Auth0 PKCE).
- Stores per-user data in Postgres, reachable from the browser via a REST layer.
- Has a compliance/isolation reason to keep the **database private inside Azure** while the
  query surface is public.

**Divergences to watch for on a new app:**
- If the app genuinely needs server-side secrets or server-decided values (payment amounts,
  eligibility, approvals), that logic **cannot** live in this Phase-1 design — see §17.
- If the app already uses Supabase GoTrue and you want to keep it, the auth section (§8) and
  the bootstrap (§10) change substantially — GoTrue-based `auth.uid()` returns a uuid, whereas
  the Auth0 variant here uses a **text** subject.
- If "database internal to Azure" is not a requirement, managed Supabase (`supabase.co`) is a
  far smaller footprint; keep §6–§9, drop the self-hosted backend in §9/§12.

**Tooling assumed:** Node 22, npm (CI + Windows dev), Azure CLI + Bicep CLI, GitHub Actions,
an Auth0 tenant, an Azure subscription. Lovable uses `bun` internally (see §18.2).

---

## 3. Architecture

```
                         Front Door + WAF   (single public entry; TLS; rate limit; headers at edge)
                         │
         ┌───────────────┴────────────────┐
         │  /*                             │  /rest/v1/*   (prefix stripped before origin)
         ▼                                 ▼
   Static Web App                    Container Apps: PostgREST
   (React SPA, public)               (verifies Auth0 RS256 JWT via JWKS; NO GoTrue)
         │                                 │
   Auth0 PKCE (external IdP)               │ private endpoint, VNet-integrated
                                           ▼
                          Azure Database for PostgreSQL Flexible Server
                          (publicNetworkAccess Disabled; PITR; managed backups)
```

**Component roles**

| Component | Role | Public? |
|-----------|------|---------|
| Auth0 tenant | Identity provider; issues RS256 access tokens via PKCE. | Yes (Auth0-hosted) |
| Static Web App | Serves the built React SPA. | Behind Front Door |
| PostgREST (Container Apps) | REST over Postgres; validates Auth0 tokens; applies RLS. | Behind Front Door |
| Postgres Flexible Server | Data. Roles + `auth.*` helpers bootstrapped by hand. | **No** (VNet-only) |
| Front Door + WAF | Edge entry, TLS, WAF managed rules, rate limit on the API path. | Yes |

**Request/identity flow**
1. Browser runs Auth0 PKCE → receives an access token (audience = your Auth0 API id, with a
   `role: authenticated` claim added by an Auth0 Login Action).
2. `supabase-js` (used purely as a typed PostgREST client) calls
   `https://<frontdoor>/rest/v1/<table>` with `Authorization: Bearer <token>`.
3. Front Door WAF filters, strips `/rest/v1`, forwards to PostgREST.
4. PostgREST verifies the token signature against Auth0's JWKS, checks `aud`/`exp`, sets the
   DB role from the `role` claim, and sets `request.jwt.claims`.
5. Postgres runs the query under RLS; policies read the caller via `auth.jwt_sub()`.

---

## 4. Key design decisions & rationale

| Decision | Chosen | Why | Alternative & when |
|----------|--------|-----|--------------------|
| Frontend hosting | Static SPA on Azure Static Web Apps | SWA serves static assets only; Auth0 PKCE + REST are browser-side, so no request-time server is needed. Smallest attack surface. | Keep SSR via a Nitro Azure preset / Container App if the app truly needs SSR. |
| Auth | **Auth0 PKCE** (public client) | Requested; external IdP, no secret in bundle, MFA/social/enterprise for free. | Supabase GoTrue if you want auth co-located with data and Lovable's `auth.uid()` SQL to run unchanged. |
| Backend | **Self-hosted PostgREST only** (no GoTrue) | Auth0 is the IdP, so GoTrue is redundant. One container, not two. DB stays private in Azure. | Managed Supabase if "DB internal" isn't required. |
| Identity in DB | `auth.jwt_sub()` (**text**) | An Auth0 `sub` (`auth0|…`, `google-oauth2|…`) is **not** a uuid; `auth.uid()` would throw every request. | GoTrue's uuid `auth.uid()` if using GoTrue. |
| Security model | **RLS is the gate** | The PostgREST query surface is public; RLS is the only thing between the internet and the data. | N/A — non-negotiable in this design. |
| Env promotion | SIT → UAT → Prod, approvals | Standard progressive delivery. | Single "dev" env for a true Phase-1 pilot. |
| IaC | Bicep | Azure-native, matches `az` tooling, no state backend. | Terraform if the org standardizes on it. |
| Cloud auth in CI | OIDC federated credentials | No standing Azure secret in GitHub. | Deployment tokens where OIDC isn't supported (SWA frontend deploy still uses a token). |

**The auth-vs-backend coupling to understand:** "Auth0 + self-hosted" means **drop GoTrue
entirely**. PostgREST validates Auth0 tokens directly against Auth0's JWKS. This is simpler
than the common two-container (postgrest + gotrue) Supabase self-host, and it is why the
identity key is text, not uuid.

---

## 5. Repository layout (reference implementation)

```
vite.config.ts                         # build seam: static SPA outside Lovable, cloudflare inside
src/lib/env.contract.ts                # shared env schema (build + runtime)
src/lib/env.ts                         # runtime env load + derived auth flags
src/lib/auth.tsx                       # Auth0 PKCE provider + useAuth abstraction
src/components/auth-gate.tsx           # login wall (secured envs only)
src/lib/supabase.ts                    # typed PostgREST client (Auth0 token as bearer)
src/hooks/use-supabase.ts              # stable client bound to the session
src/hooks/use-calculation-history.ts   # example data hook (per-user, RLS-scoped)
scripts/generate-swa-config.mjs        # generates staticwebapp.config.json (CSP + headers)
db/bootstrap/000_bootstrap.sql         # ONE-TIME: roles, auth.* helpers, deny-by-default
db/checks/rls_gate.sql                 # CI gate: fails on any unguarded table
supabase/migrations/*.sql              # schema + RLS (append-only, column-scoped)
postgrest/README.md                    # PostgREST env-var config (Auth0 JWKS)
infra/bicep/main.bicep                 # orchestrates the whole per-env stack
infra/bicep/modules/*.bicep            # network, postgres, containerapp, swa, frontdoor
infra/bicep/env/{sit,uat,prod}.bicepparam
.github/workflows/promote.yml          # develop → main PR + auto-merge (gated)
.github/workflows/codeql.yml           # SAST
.github/workflows/claude-security-review.yml  # semantic review, hard-gates High/Critical
.github/workflows/deploy-azure-swa.yml # frontend deploy, SIT→UAT→Prod
.github/actions/build-and-deploy-swa/  # composite: config-check, leak-check, build, deploy
.github/workflows/deploy-infra.yml     # Bicep provisioning (OIDC)
.github/workflows/db-migrate.yml       # migrations + RLS gate (in-VNet runner)
PIPELINE-SETUP.md                      # repo-specific setup runbook
```

---

## 6. Frontend: retarget the build to a static SPA

**Problem.** Lovable's `@lovable.dev/vite-tanstack-config` wraps Vite and, by default, builds
with Nitro targeting `cloudflare-module`. It **force-pins** Cloudflare *inside the Lovable
sandbox*. You must produce plain static output in CI **without** breaking Lovable's own build.

**The seam.** The wrapper detects the sandbox via env vars and, critically, evaluates
`shouldRunNitro = options.nitro !== false && command === 'build'` **before** the sandbox
branch. So an unconditional `nitro: false` would also kill Lovable's build. Gate it on the
same sandbox detection the wrapper uses.

```ts
// vite.config.ts
import { defineConfig } from "@lovable.dev/vite-tanstack-config";
import { loadEnv, type Plugin } from "vite";
import { envSchema, formatEnvIssues, readEnvSource } from "./src/lib/env.contract";

// Mirrors isSandboxEnvironment() in the wrapper.
const isLovableSandbox =
  process.env.LOVABLE_SANDBOX === "1" || !!process.env.DEV_SERVER__PROJECT_PATH;

export default defineConfig({
  plugins: [validateEnvironmentPlugin()],           // §7
  tanstackStart: {
    server: { entry: "server" },
    spa: { enabled: true },                          // prerendered shell + client bundle
    prerender: { enabled: true },
  },
  // Skip Nitro ONLY outside the sandbox → static output for SWA. Inside Lovable, undefined
  // lets the wrapper keep its Cloudflare build.
  nitro: isLovableSandbox ? undefined : false,
});
```

**Output shape (important).** SPA mode emits `dist/client/_shell.html` and **no**
`index.html`. Every route must fall back to `_shell.html` (see §11 navigationFallback). The
SWA `app_location` is `dist/client`.

**Build script.**
```json
// package.json
"build:swa": "vite build && node scripts/generate-swa-config.mjs"
```

> If the app is a different framework (plain Vite React, Next static export, etc.), the
> principle is identical: produce static output in CI, find and respect whatever build seam
> the Lovable wrapper imposes, and know exactly which HTML file is the SPA fallback.

---

## 7. Environment configuration & the build-time security gate

**Principle.** "Auth off for Lovable" must be **impossible to ship** to a secured environment.
Enforce it at **build time**, not behind a runtime flag. One shared contract feeds both the
Vite build gate and the runtime loader so they cannot drift.

```ts
// src/lib/env.contract.ts  (no import.meta / process.env access — callers supply the source)
import { z } from "zod";

export const APP_ENVIRONMENTS = ["local", "sit", "uat", "production"] as const;
export type AppEnvironment = (typeof APP_ENVIRONMENTS)[number];

// "local" == developer machine AND Lovable sandbox (auth optional there).
export const SECURED_ENVIRONMENTS = ["sit", "uat", "production"] as const;

export const SECURED_ENV_REQUIRED_KEYS = [
  "VITE_AUTH0_DOMAIN", "VITE_AUTH0_CLIENT_ID", "VITE_AUTH0_AUDIENCE",
  "VITE_SUPABASE_URL", "VITE_SUPABASE_ANON_KEY",
] as const;

export function isSecuredEnvironment(v: unknown): v is (typeof SECURED_ENVIRONMENTS)[number] {
  return (SECURED_ENVIRONMENTS as readonly string[]).includes(v as string);
}

// Treat "" as unset — CI exports empty strings for undefined secrets.
const optionalNonEmpty = z.string().trim().min(1).optional().catch(undefined);

const base = z.object({
  VITE_APP_ENV: z.enum(APP_ENVIRONMENTS).default("local"),
  VITE_AUTH0_DOMAIN: optionalNonEmpty,
  VITE_AUTH0_CLIENT_ID: optionalNonEmpty,
  VITE_AUTH0_AUDIENCE: optionalNonEmpty,
  VITE_SUPABASE_URL: z.string().url().optional().catch(undefined),
  VITE_SUPABASE_ANON_KEY: optionalNonEmpty,
});

// FAIL CLOSED: secured envs require every key.
export const envSchema = base.superRefine((val, ctx) => {
  if (!isSecuredEnvironment(val.VITE_APP_ENV)) return;
  for (const key of SECURED_ENV_REQUIRED_KEYS) {
    if (!val[key]) ctx.addIssue({ code: z.ZodIssueCode.custom, path: [key],
      message: `${key} is required when VITE_APP_ENV="${val.VITE_APP_ENV}".` });
  }
});
```

**Build gate** — a Vite plugin that runs the schema at `config()` and throws:
```ts
function validateEnvironmentPlugin(): Plugin {
  return {
    name: "app:validate-environment",
    enforce: "pre",
    config(_c, { mode }) {
      const source = { ...loadEnv(mode, process.cwd(), "VITE_"), ...process.env };
      const r = envSchema.safeParse(readEnvSource(source));
      if (!r.success) throw new Error(`[env] Refusing to build:\n${formatEnvIssues(r.error)}`);
    },
  };
}
```

**Runtime loader** (`src/lib/env.ts`) parses `import.meta.env` with the same schema, throws on
failure (fail closed), and derives:
- `authRequired = isSecuredEnvironment(VITE_APP_ENV)`
- `auth0Config` — present iff domain+clientId set
- `supabaseConfig` — present iff url+anon key set
- and throws if `authRequired && !auth0Config`.

**Verification (must pass):** `VITE_APP_ENV=production npm run build` with the vars unset →
build fails with the five missing-key errors.

---

## 8. Auth: Auth0 Authorization Code + PKCE

**Package:** `@auth0/auth0-react`. Public SPA client, no secret in the bundle.

```tsx
// src/lib/auth.tsx (essentials)
import { Auth0Provider, useAuth0 } from "@auth0/auth0-react";
import { auth0Config, authRequired } from "./env";

export function AuthProvider({ children }) {
  if (!auth0Config) return <>{children}</>;            // local/Lovable: no tenant needed
  return (
    <Auth0Provider
      domain={auth0Config.domain}
      clientId={auth0Config.clientId}
      authorizationParams={{
        redirect_uri: typeof window === "undefined" ? undefined : window.location.origin, // prerender-safe
        audience: auth0Config.audience,
      }}
      useRefreshTokens                     // rotation: each refresh single-use
      useRefreshTokensFallback={false}     // no iframe/3rd-party-cookie fallback
      cacheLocation="memory"               // tokens NEVER in localStorage → XSS can't exfiltrate a long-lived token
      onRedirectCallback={() => window.history.replaceState({}, document.title, window.location.pathname)}
    >
      {children}
    </Auth0Provider>
  );
}
```

- `useAuth()` wraps `useAuth0()` and returns a stable shape
  (`isLoading/isAuthenticated/user/login/logout/getAccessToken`). When `auth0Config` is
  absent it returns an unauthenticated, non-blocking session so the app renders in Lovable.
- `AuthGate` (component) blocks the app in secured envs until authenticated; passes through
  when `authRequired` is false. Because `authRequired` is compiled from `VITE_APP_ENV` and the
  build refuses a secured bundle without Auth0 config, the gate cannot be disabled at runtime.

**Non-obvious requirements:**
1. **Custom domain is mandatory for SIT/UAT/Prod.** In-memory tokens mean a page reload has
   no local session and must silently re-authenticate. Without an Auth0 custom domain that
   silent call is cross-site and gets blocked → users bounced to login on every reload. Set
   `VITE_AUTH0_DOMAIN` to the custom domain.
2. **CSP must allow a blob Web Worker** — `auth0-spa-js` runs its refresh-token exchange in a
   worker created from a `blob:` URL (`worker-src 'self' blob:`). Miss this and login fails in
   production only, with an opaque CSP violation.
3. **Login Action adds the DB role claim** (Auth0 → Actions → Login):
   ```js
   exports.onExecutePostLogin = async (event, api) => {
     api.accessToken.setCustomClaim("role", "authenticated");
   };
   ```
   Without it PostgREST runs the request as `anon` and every policy fails closed.

---

## 9. Backend: PostgREST verifying Auth0 tokens

Image: upstream `postgrest/postgrest` (pin by digest in prod). All config via env vars on the
Container App. **No GoTrue.**

| Variable | Value | Why |
|----------|-------|-----|
| `PGRST_DB_URI` | `postgres://authenticator:<pw>@<flex-private-fqdn>:5432/appdb?sslmode=require` | Connects as the **authenticator** login role over the private endpoint. Never the admin. |
| `PGRST_DB_SCHEMAS` | `public` | Only schema exposed. `private` is unreachable (see §10 move #3). |
| `PGRST_DB_ANON_ROLE` | `anon` | Role for tokenless requests. `anon` holds nothing. |
| `PGRST_JWT_SECRET` | Auth0 **JWKS** JSON | Verifies RS256 against Auth0's public keys — no symmetric secret to leak. |
| `PGRST_JWT_AUD` | `VITE_AUTH0_AUDIENCE` | Rejects tokens for another audience. |
| `PGRST_JWT_ROLE_CLAIM_KEY` | `.role` | Maps the token `role` claim → DB role. |
| `PGRST_DB_MAX_ROWS` | `1000` | Caps enumeration if a policy is too loose. |
| `PGRST_DB_PLAN_ENABLED` | `false` | Don't expose query plans. |
| `PGRST_OPENAPI_MODE` | `disabled` | Don't publish the schema. |
| `PGRST_DB_POOL` | `10` | Small; Flex connection budgets are finite. |
| `PGRST_SERVER_PORT` | `3000` | Ingress target. |

**Client side** (`src/lib/supabase.ts`): `supabase-js` is used only as a typed PostgREST
client. `VITE_SUPABASE_URL` = the Front Door hostname (supabase-js calls `<url>/rest/v1/<t>`).
The `accessToken` hook attaches the Auth0 token:

```ts
createClient<Database>(cfg.url, cfg.anonKey, {
  accessToken: async () => (await getAuth0Token()) ?? null,   // Auth0 token becomes the bearer
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
});
```
`VITE_SUPABASE_ANON_KEY` is a **placeholder** — PostgREST ignores the `apikey` header and
authorizes on the bearer alone. The Postgres `service_role` must never be in the bundle.

Bind the client through a ref so token refreshes are picked up without rebuilding the client
(`use-supabase.ts`), and gate data hooks on `isAuthenticated` (`use-calculation-history.ts`).

---

## 10. Database: bootstrap, roles, and "RLS is the gate"

Flex is not the `supabase/postgres` image, so create the Supabase-style roles and `auth.*`
helpers **once, by hand, per server**, before any migration.

### 10.1 Bootstrap (`db/bootstrap/000_bootstrap.sql`) — run once, as admin
```sql
-- Roles. authenticator is the ONLY login role; PostgREST SET ROLEs to anon/authenticated
-- based on the JWT role claim.
create role anon            nologin noinherit;
create role authenticated   nologin noinherit;
create role service_role    nologin noinherit bypassrls;         -- created, but see below
create role authenticator   login   noinherit password :'authenticator_pw';
-- DO NOT grant service_role to authenticator: nothing on the request path may bypass RLS.
grant anon, authenticated to authenticator;

create schema if not exists auth;
create schema if not exists private;     -- never in PGRST_DB_SCHEMAS

-- Claim helpers read PostgREST's request.jwt.claims GUC. sub is TEXT (Auth0 sub ≠ uuid).
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create or replace function auth.jwt_sub() returns text language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '') $$;
create or replace function auth.role() returns text language sql stable as $$
  select coalesce(nullif(auth.jwt() ->> 'role', ''), 'anon') $$;
grant execute on function auth.jwt(), auth.jwt_sub(), auth.role() to anon, authenticated;

-- DENY BY DEFAULT — the whole control. We do NOT run supabase/postgres's
-- `alter default privileges ... grant all ... to anon, authenticated`. A new table is inert
-- until a migration grants it explicitly.
grant usage on schema public to authenticated;
revoke all on schema public from anon, public;
grant usage on schema auth to anon, authenticated;
```

### 10.2 The six RLS hardening moves (all enforced)
1. **Deny by default** — grants are explicit and per-table; a new Lovable table is **inert in
   Azure** until a migration adds `grant … to authenticated`. That one line, in a PR, is the
   review gate (~30s/table). Fails loudly in CI, never silently in prod.
2. **RLS enabled AND forced** — `force` matters; without it the owner connection bypasses RLS
   and fails *open*. `rls_gate.sql` fails CI if any public table isn't both.
3. **Sensitive columns leave `public`** — put PII in the `private` schema, which is not in
   `PGRST_DB_SCHEMAS`. No policy can be wrong about a table PostgREST can't see.
4. **Column-level grants** — grant `insert (col_a, col_b)`, not table-wide, so a loose policy
   still can't let a client set `user_id`/`is_admin`/`balance`.
5. **Server-authoritative ownership** — `user_id` **defaults** from `auth.jwt_sub()` and the
   `WITH CHECK` re-verifies it; a forged `user_id` in the body is rejected.
6. **Blast-radius caps** — `PGRST_DB_MAX_ROWS`, plan+OpenAPI disabled, Front Door rate limit
   on `/rest/v1/*`, `service_role` kept off the request path.

### 10.3 Table + RLS pattern (`supabase/migrations/0001_*.sql`)
```sql
create table if not exists public.calculations (
  id uuid primary key default gen_random_uuid(),
  user_id text not null default auth.jwt_sub(),        -- #5 server-authoritative
  expression text not null, result text not null,
  created_at timestamptz not null default now(),
  constraint expr_len check (char_length(expression) between 1 and 200)
);
alter table public.calculations enable row level security;   -- #2
alter table public.calculations force  row level security;   -- #2 (fails open without this)

revoke all on public.calculations from anon, authenticated, public;   -- #1
grant select on public.calculations to authenticated;                 -- #1
grant insert (expression, result) on public.calculations to authenticated;  -- #4

create policy sel_own on public.calculations for select to authenticated
  using (user_id = auth.jwt_sub());
create policy ins_own on public.calculations for insert to authenticated
  with check (user_id = auth.jwt_sub());
-- No UPDATE/DELETE grant or policy → append-only.
```

### 10.4 RLS gate (`db/checks/rls_gate.sql`) — run in CI, before the app deploys
Raises (fails the pipeline) if any of: a public table lacks enabled+forced RLS; a table
granted to `authenticated` (including via column grants) has zero policies; a request-path
role has `BYPASSRLS`; `anon` holds any table privilege; or the `private` schema is reachable
by a request-path role.

---

## 11. Security headers & CSP (generated per build)

`scripts/generate-swa-config.mjs` writes `dist/client/staticwebapp.config.json` after each
build. It is **generated, not committed**, because (a) the CSP must name the exact Auth0 +
Front Door origins, which differ per environment, and (b) the framework emits inline
`<script>` blocks that must be allow-listed by **SHA-256 hash**, and those hashes change per
build. Reading them off the actual output keeps the policy honest; a stale hand-maintained
hash fails closed in production only.

Key behaviors:
- Hash every inline (no-`src`) `<script>` body → `script-src 'self' 'sha256-…'`. **Fail closed
  if zero found** (the shell format changed — refuse rather than emit a policy that blocks a
  script you missed).
- CSP: `default-src 'self'`; `script-src 'self' <hashes>`; `style-src 'self' 'unsafe-inline'`
  (React style attrs / Tailwind tag — cannot execute code); `img-src 'self' data: https:`;
  `connect-src 'self' <auth0-origin> <frontdoor-origin>`; `worker-src 'self' blob:` (Auth0
  worker); `object-src 'none'`; `base-uri 'self'`; `form-action 'self'`;
  `frame-ancestors 'none'`; `upgrade-insecure-requests`.
- Global headers: `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload`,
  `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
  `Referrer-Policy: strict-origin-when-cross-origin`,
  `Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()`,
  `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Resource-Policy: same-origin`.
- `navigationFallback.rewrite = /_shell.html` (exclude `/assets/*`, favicon, static
  extensions); `/assets/*` cached `immutable`, `_shell.html` `no-cache`; `responseOverrides`
  404 → `/_shell.html` status 200.

**Verify** the hashes independently (a wrong hash breaks prod only) — the reference build was
cross-checked with a separate Python SHA-256 of the same inline scripts.

---

## 12. Infrastructure as Code (Bicep)

One resource group per environment; `main.bicep` orchestrates modules; per-env `.bicepparam`
files carry sizing and **non-overlapping** VNet ranges. Secrets come from
`readEnvironmentVariable(...)` at deploy (never committed). All modules compile under
`az bicep build`.

| Module | Creates | Non-obvious points |
|--------|---------|--------------------|
| `network.bicep` | VNet; `snet-infra`; `snet-postgres` **delegated** to `Microsoft.DBforPostgreSQL/flexibleServers`; private DNS zone `privatelink.postgres.database.azure.com` + vnet link. | Postgres subnet must be delegated; DNS zone is what resolves the Flex private FQDN. |
| `postgres.bicep` | Flexible Server with `network.publicNetworkAccess: 'Disabled'`, `delegatedSubnetResourceId`, `privateDnsZoneArmResourceId`; `require_secure_transport=on`; `appdb`. | `zoneRedundantHa` requires a **General Purpose** SKU (not Burstable) — kept a separate param from geo-backup so you can't form an invalid combo. |
| `containerapp.bicep` | Managed env (`internal: true`, infra subnet, Log Analytics); PostgREST container; secrets `pgrst-db-uri`, `pgrst-jwt-jwks`; the §9 env vars. | Env is internal; Front Door reaches it. `service_role`/admin creds never present. |
| `swa.bicep` | Static Web App (Standard); `skipGithubActionWorkflowGeneration: true`. | Built by CI (`skip_app_build`), not Oryx. |
| `frontdoor.bicep` | Front Door Premium profile + endpoint; origin groups for SWA (`/*`) and PostgREST (`/rest/v1/*`); URL-rewrite rule stripping `/rest/v1/`; WAF policy (`Microsoft_DefaultRuleSet 2.1` Block + `BotManagerRuleSet`) + custom **rate-limit** rule on `/rest/v1/`; security-policy association. | The API route is more specific and is matched first; the rewrite makes PostgREST see `/…` not `/rest/v1/…`. |

`main.bicep` also provisions Log Analytics and composes the PostgREST DB URI from the
authenticator password + Flex FQDN. Per-env defaults in the reference: SIT `10.10/16`
(Burstable), UAT `10.20/16` (GP small), Prod `10.30/16` (GP + zone-redundant HA + geo backup).

Deploy: `az deployment group create -g rg-<app>-<env> -f infra/bicep/main.bicep -p infra/bicep/env/<env>.bicepparam`.

---

## 13. CI/CD pipeline

**Promotion (`promote.yml`).** On push to `develop`, ensure an open PR `develop → main` and
enable auto-merge. Uses a **PAT (`AUTOMATION_TOKEN`)**, not the built-in token: GitHub does not
trigger workflow runs from `GITHUB_TOKEN`-created events, so a PR opened with it would never
start the scans. Auto-merge completes only when required checks are green.

**Gates as required checks on `main`:**
- `codeql.yml` — SAST. Repo uses CodeQL **default setup**, so it keeps `upload: false`
  (advanced-config uploads are rejected under default setup). Real gating = set Code scanning
  → Check Failures to High+ **and** add the check to branch protection.
- `claude-security-review.yml` — semantic review on the PR. **Hard-gates**: fails the check on
  any High/Critical finding, and **fails closed** if no results file is produced.

**Frontend deploy (`deploy-azure-swa.yml` + composite `build-and-deploy-swa`).** On push to
`main`: SIT (auto) → UAT (approval) → Prod (approval) via GitHub **Environments**. The
composite action, per environment:
1. asserts all required inputs/secrets present;
2. **leak-check** — fails if `supabase.co`/`lovableproject.com`/`lovable.app` is hard-coded in
   `src/` (Lovable periodically rewrites client config back to its Cloud);
3. `npm ci`; `npm run build:swa` with the env's `VITE_*` compiled in;
4. `Azure/static-web-apps-deploy` with `skip_app_build: true`, `app_location: dist/client`
   (never let Oryx rebuild — it would bypass the env gate).

**Infra (`deploy-infra.yml`).** `workflow_dispatch` with an env choice. **OIDC**
(`azure/login` federated credential — no standing Azure secret), `what-if` preview, then
`az deployment group create`. Env approval gates it.

**Migrations (`db-migrate.yml`).** `workflow_dispatch`. **The Postgres server has no public
access, so a GitHub-hosted runner cannot reach it.** This job targets a **self-hosted runner
in the VNet** (`runs-on: [self-hosted, vnet, <env>]`) — or run migrations as an
`az containerapp job`. It applies `supabase/migrations/*.sql` in order, then runs
`rls_gate.sql`. Run it **before** the app deploy and gate the deploy on it. The §10 bootstrap
is separate and precedes the first migration.

**Action pinning.** All third-party and first-party actions are pinned to a **full commit
SHA** (a moving tag can be repointed at malicious code). Resolve annotated tags to the
underlying commit before pinning. Reference SHAs at time of writing:
`actions/checkout@93cb6efe…` (v5), `actions/setup-node@49933ea5…` (v4),
`Azure/login@a457da9e…` (v2, dereferenced from the annotated tag),
`Azure/static-web-apps-deploy@1a947af9…` (v1). **Re-resolve these for a new repo — don't trust
a copied SHA blindly.**

---

## 14. Secrets & configuration inventory

**Never** put anything secret in a `VITE_*` variable — they compile into the public bundle.
Auth0 PKCE has no client secret; the Supabase anon key is a placeholder; the Postgres
`service_role` appears nowhere client-side.

| Name | Scope | Kind | Consumed by |
|------|-------|------|-------------|
| `AUTOMATION_TOKEN` | repo | secret | promote.yml (PR + auto-merge) |
| `CLAUDE_API_KEY` | repo | secret | claude-security-review.yml |
| `VITE_AUTH0_DOMAIN` / `_CLIENT_ID` / `_AUDIENCE` | env | var (public) | frontend build |
| `VITE_SUPABASE_URL` (Front Door host) / `VITE_SUPABASE_ANON_KEY` (placeholder) | env | var (public) | frontend build |
| `AZURE_CLIENT_ID` / `_TENANT_ID` / `_SUBSCRIPTION_ID` | env | var | deploy-infra OIDC |
| `AZURE_STATIC_WEB_APPS_API_TOKEN` | env | secret | frontend deploy |
| `PG_ADMIN_PASSWORD` / `PG_AUTHENTICATOR_PASSWORD` | env | secret | Bicep deploy |
| `AUTH0_JWKS` | env | secret | Bicep (PostgREST JWT config) |
| `ADMIN_DB_URL` | env | secret | db-migrate |

---

## 15. Setup runbook (new environment, ordered)

1. **GitHub**: branch-protect `main` (require CodeQL + Claude checks, no bypass). Add repo
   secrets `AUTOMATION_TOKEN`, `CLAUDE_API_KEY`. Create Environments `sit`/`uat`/`production`
   with the §14 vars/secrets; require reviewers on `uat`/`production`.
2. **Azure OIDC**: per env, an app registration / UAMI with a federated credential scoped to
   `repo:<org>/<repo>:environment:<env>`, `Contributor` on the env's resource group.
3. **Auth0**: SPA application (PKCE); callbacks/logout/web-origins = the site origin + custom
   domain; refresh-token rotation on; custom domain configured; an API whose identifier =
   `VITE_AUTH0_AUDIENCE`; Login Action sets `role: authenticated`; store JWKS as `AUTH0_JWKS`.
4. **Provision infra**: run `deploy-infra.yml` for the env (creates the RG first). Note the
   Front Door hostname → set `VITE_SUPABASE_URL`.
5. **Bootstrap DB** (once/server, in-VNet, as admin): run `000_bootstrap.sql` with a generated
   `authenticator_pw` (= `PG_AUTHENTICATOR_PASSWORD`).
6. **Migrate**: run `db-migrate.yml` (in-VNet runner) → applies migrations + RLS gate.
7. **Deploy frontend**: merge to `main` → `deploy-azure-swa.yml` promotes to the env.
8. **Verify** (§16). **Sync `bun.lock`** if deps changed (§18.2).

---

## 16. Verification & go-live checklist

Behavioral tests (run 3 and 4 in CI — they catch failures that are silent in prod):
1. `curl <frontdoor>/rest/v1/<table>` with no `Authorization` → empty/401, not rows.
2. Sign in as user A, request B's rows → zero rows.
3. `psql` as `authenticated` with no JWT context, `select *` → zero rows (else `force` didn't take).
4. Ask Lovable to add a table, let it flow → migrate/RLS gate **fails** until you add the grant.
5. `select rolname from pg_roles where rolbypassrls` → only `service_role` (not on the path).
6. Grep built `dist/` for `supabase.co` → nothing (leak-check enforces).
7. `VITE_APP_ENV=production npm run build` with Auth0 vars unset → build fails.

Checklist: branch protection + both scans required; Claude hard-gate on; CodeQL Check Failures
High+ and required; PAT fine-grained + Claude key spend-capped; per-env vars/secrets + UAT/Prod
reviewers; Azure OIDC (no standing secret); Auth0 SPA + custom domain + rotation + Login Action
+ JWKS stored; bootstrap applied + authenticator password matches PostgREST; Postgres
`publicNetworkAccess` Disabled; `service_role` not granted to `authenticator`; `rls_gate.sql`
gates the deploy; migrations the only way schema changes; `.env` gitignored (only
`.env.example` committed).

---

## 17. Known limitation & the Phase 2 boundary

RLS answers **"which rows,"** never **"is this value legitimate."** A user with a valid session
can insert a row that is validly *theirs* but carries a nonsense value (`amount = 1`). Anything
where the **server must decide** a value — payment amounts, rate locks, eligibility, approvals,
anything a regulator would ask you to reconstruct — cannot be solved in this Phase-1 design.

Phase 2 adds a real API (e.g. .NET) in front, takes PostgREST down for those paths, and flips a
lint rule to forbid direct DB writes for server-decided data. **Nothing in Phase 1 is
throwaway** — all six RLS moves remain as defense-in-depth. Write this boundary down early so
the decision to add the API later is already made, not re-litigated.

---

## 18. Gotchas & lessons learned (read before coding)

1. **Lovable build seam / Nitro ordering (§6).** `nitro !== false` is checked before the
   sandbox branch; an unconditional `nitro: false` breaks Lovable's own build. Gate it.
2. **Two lockfiles.** Lovable uses `bun` (`bun.lock`, with a 24h supply-chain guard in
   `bunfig.toml`); CI/Windows use `npm` (`package-lock.json`). Adding deps updates only
   `package-lock.json`; since app code imports deps at module top level, Lovable's
   `bun install` must resolve them too. Run `bun install` to sync `bun.lock`, or Lovable's
   preview build can break.
3. **CRLF lint noise.** With `git config core.autocrlf=true` on Windows, ESLint's
   `prettier/prettier` reports thousands of `Delete ␍` errors locally that **do not exist on
   Linux CI** (LF checkout). Don't "fix" by reformatting every file — verify against an
   untouched file, and only format the files you actually changed.
4. **Private endpoint ⇒ migrations need an in-VNet runner (§13).** GitHub-hosted runners can't
   reach a `publicNetworkAccess: Disabled` database. Don't ship a workflow that silently fails;
   target a self-hosted VNet runner or `az containerapp job`.
5. **Auth0 sub is not a uuid.** Use `auth.jwt_sub()` (text), never `auth.uid()` (uuid cast),
   or every request throws.
6. **In-memory tokens ⇒ Auth0 custom domain required** for silent re-auth on reload (§8).
7. **Auth0 blob worker ⇒ `worker-src 'self' blob:`** in CSP (§8/§11), or login fails in prod
   only.
8. **`service_role` not granted to `authenticator`** — create the role for reference, but keep
   it off the request path in Phase 1.
9. **SPA build emits `_shell.html`, not `index.html`** — the SWA `navigationFallback` and 404
   override must point at `_shell.html`.
10. **Inline-script CSP hashes are per-build** — generate them from the actual shell each
    build and fail closed on zero (§11).
11. **`force row level security`** — without it the owner bypasses RLS and fails *open*. The
    single most common self-hosted footgun.
12. **Pin action SHAs, deref annotated tags** — `Azure/login@v2` is an annotated tag; resolve
    to the commit before pinning.

---

## 19. Adaptation guide — applying this to a different Lovable app

**Mechanical renames:** `gentlecalc`/`gentle-calc-page` → the new app slug across Bicep names,
resource groups (`rg-<app>-<env>`), workflow comments.

**Per-app values to set:** Auth0 tenant/app/API identifiers and custom domains; Front Door
hostnames (→ `VITE_SUPABASE_URL`); non-overlapping VNet ranges per env; Postgres SKUs; WAF
rate limits; the app's own OG/social metadata.

**What changes structurally:**
- **Data model.** Replace `supabase/migrations/0001_calculations.sql` and the example hooks
  with the app's real tables — but keep the **pattern**: text `user_id` defaulted from
  `auth.jwt_sub()`, enable+force RLS, revoke-then-explicit-grant, column-scoped writes,
  owner-scoped policies, PII in `private`. Re-run `rls_gate.sql` mentally against every table.
- **Additional backend needs.** If the app uses file uploads or realtime, you add
  `storage-api`/`realtime` containers (and their CSP/`connect-src` origins) — the reference
  deliberately runs the minimal `postgrest`-only set.
- **Framework.** If not TanStack Start, redo §6 for that build tool, but keep: static output
  in CI, respect the Lovable wrapper's seam, know the SPA fallback file, generate the CSP with
  real inline-script hashes.

**What stays identical (copy as-is):** the env-contract build gate (§7), the Auth0 provider
pattern and its three non-obvious requirements (§8), the PostgREST env config (§9), the
bootstrap + six RLS moves + gate (§10), the CSP/header generator (§11), the Bicep module
topology (§12), the whole CI/CD structure incl. leak-check, OIDC infra, SHA pinning, and the
in-VNet migration constraint (§13), and every gotcha in §18.

**Decision points to re-confirm with the human (don't assume):** Auth0 vs GoTrue; self-hosted
vs managed backend; single-env pilot vs full SIT/UAT/Prod; Bicep vs Terraform; and whether any
data needs server-decided values (which forces Phase 2 now — §17).

---

*Companion documents in this repo: `PIPELINE-SETUP.md` (repo-specific setup runbook) and
`phase1-lovable-cloud-to-azure.md` (the originating design note). This file is the portable,
app-agnostic technical reference.*
