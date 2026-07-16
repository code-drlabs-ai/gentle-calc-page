# Pipeline & Hosting Setup

How this project goes from a Lovable edit to a secured Azure deployment, and every manual
step you must perform once to make the automation work.

If you only read one thing: **secured environments (SIT/UAT/Production) cannot build or run
without a full Auth0 + Supabase configuration.** The build fails closed
(`vite.config.ts` → `src/lib/env.contract.ts`). Lovable's preview stays open and
unauthenticated so the citizen developer keeps full freedom to ideate.

---

## 1. The flow at a glance

```
Lovable editor
   │  (syncs commits)
   ▼
develop branch ──► promote.yml opens/updates a PR: develop ➜ main
                        │
                        ├─ CodeQL Security Scan            (required check)
                        └─ Claude Security Review          (required check, blocks on High/Critical)
                        │
                        ▼  auto-merge only when all required checks are green
                     main branch
                        │
                        ▼  deploy-azure-swa.yml
              SIT  ──►  UAT (approval)  ──►  Production (approval)
        (Azure Static Web Apps, one resource per environment)
```

- **Lovable** builds with its own Cloudflare preset inside its sandbox; nothing here changes
  that. Our Azure retarget only applies **outside** the sandbox (see `vite.config.ts`).
- **Auth**: Auth0 Authorization Code + PKCE (public SPA client, no client secret in the bundle).
- **Data**: Supabase (Postgres) with Row Level Security; Auth0 is the identity provider via
  Supabase Third-Party Auth.

---

## 2. One-time GitHub repository setup

### 2.1 Branch protection on `main`
Settings → Branches → Add rule for `main`:
- ✅ Require a pull request before merging.
- ✅ Require status checks to pass. Add these once they have run at least once so GitHub lists them:
  - `Analyze (javascript-typescript)` (CodeQL)
  - `Claude semantic security review`
- ✅ Require branches to be up to date before merging.
- ✅ Do not allow bypassing the above settings.

> Without adding the checks here, `promote.yml`'s auto-merge would merge before the scans finish.

### 2.2 Secrets and variables (repository level)
Settings → Secrets and variables → Actions:

| Name | Kind | Used by | Notes |
|------|------|---------|-------|
| `AUTOMATION_TOKEN` | secret | `promote.yml` | Fine-grained PAT, `contents:rw` + `pull_requests:rw` on this repo only. Needed so the PR triggers the scan workflows (the built-in `GITHUB_TOKEN` does not — anti-recursion). |
| `CLAUDE_API_KEY` | secret | `claude-security-review.yml` | Anthropic Console key, enabled for **Claude API** and **Claude Code**. Set a spend cap. |

Environment-scoped values live in the environments below, not here.

### 2.3 GitHub Environments (this is where deploy approvals live)
Settings → Environments. Create **`sit`**, **`uat`**, **`production`**. For each:

- **Environment secrets**
  - `AZURE_STATIC_WEB_APPS_API_TOKEN` — the deployment token of that environment's SWA resource (§5).
- **Environment variables** (these compile into a public bundle — none are secret)
  - `VITE_AUTH0_DOMAIN`, `VITE_AUTH0_CLIENT_ID`, `VITE_AUTH0_AUDIENCE`
  - `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`
- **Protection rules** for `uat` and `production`:
  - ✅ Required reviewers (the people allowed to approve a promotion).
  - Optional: a wait timer; restrict deployments to the `main` branch.

`sit` needs no reviewers — a merge to `main` deploys there automatically, then pauses for
approval before `uat` and again before `production`.

---

## 3. Environment model & the build-time security gate

`VITE_APP_ENV` selects the environment. `local` (developer machine **and** the Lovable
sandbox) leaves Auth0/Supabase optional. `sit`/`uat`/`production` are **secured**: the build
refuses to start unless all of these are present and non-empty:

```
VITE_AUTH0_DOMAIN  VITE_AUTH0_CLIENT_ID  VITE_AUTH0_AUDIENCE
VITE_SUPABASE_URL  VITE_SUPABASE_ANON_KEY
```

The rule lives in `src/lib/env.contract.ts` and is enforced twice: at build time
(`vite.config.ts` plugin, so a misconfigured secured build never produces output) and at
runtime (`src/lib/env.ts`, so a hand-edited bundle refuses to boot rather than render
unauthenticated). There is no runtime flag that turns auth off in a secured environment.

To run the real auth flow locally, copy `.env.example` to `.env` and fill it in. Leaving
Auth0 blank with `VITE_APP_ENV=local` runs the calculator with no login — this is the
Lovable ideation mode.

---

## 4. Why `promote.yml` uses a PAT

GitHub does not start new workflow runs from events created by the built-in `GITHUB_TOKEN`
(loop protection). A PR opened with `GITHUB_TOKEN` would therefore never trigger CodeQL or
the Claude review, and auto-merge would sail through with no scans. Opening the PR with
`AUTOMATION_TOKEN` (a PAT) makes the required checks actually run. Keep the PAT fine-grained
and scoped to this repository.

---

## 5. Azure Static Web Apps

Create **three** Static Web App resources (SIT, UAT, Production). Recommended: SKU Standard
(needed for custom auth headers and custom domains at scale), region near your users.

For a manual/CLI create per environment:
```bash
az staticwebapp create \
  --name swa-gentlecalc-sit \
  --resource-group rg-gentlecalc \
  --location westeurope \
  --sku Standard
# Do NOT connect it to the GitHub repo through this command — our own workflow deploys.
```
Then read the deployment token and store it as the `AZURE_STATIC_WEB_APPS_API_TOKEN`
**environment secret** for the matching GitHub Environment:
```bash
az staticwebapp secrets list --name swa-gentlecalc-sit --query "properties.apiKey" -o tsv
```

Notes:
- The workflow builds the app itself and deploys with `skip_app_build: true`, so Azure's
  Oryx build never runs. This is deliberate: Oryx would build without our environment gate.
- `staticwebapp.config.json` is **generated per build** into `dist/client` by
  `scripts/generate-swa-config.mjs`. It sets the CSP (with per-environment Auth0/Supabase
  origins and per-build inline-script hashes), HSTS, `frame-ancestors 'none'`, `nosniff`,
  Referrer-Policy, Permissions-Policy, and the SPA navigation fallback to `/_shell.html`.
  Do not hand-edit a committed copy — there isn't one.

### CodeQL gating note
The repo uses CodeQL **default setup**, which is why `codeql.yml` keeps `upload: false`
(advanced-config uploads are rejected while default setup is on). To make CodeQL actually
block a merge:
1. Settings → Code security → Code scanning → **Check Failures** → set to **High or higher**.
2. Add the CodeQL check to `main` branch protection (§2.1).
For a throwaway TEST setup you can point this at a public repo, where CodeQL is free.

---

## 6. Auth0 tenant setup (PKCE)

Do this once per environment (or one tenant with three Applications).

1. **Application** → type **Single Page Application**. This yields a public client that uses
   Authorization Code + PKCE and has **no client secret** — correct for a browser app.
2. **Allowed Callback URLs / Logout URLs / Web Origins**: the environment's site origin,
   e.g. `https://sit.gentlecalc.example.com`. Add `http://localhost:8080` for local dev.
3. **Refresh Token Rotation**: enable it (Application → Settings → Refresh Token Rotation).
   The app requests refresh tokens and keeps them **in memory only** (`cacheLocation:
   "memory"` in `src/lib/auth.tsx`), so an XSS bug cannot lift a long-lived token from
   storage. The tradeoff: a page reload silently re-authenticates.
4. **Custom domain** (Auth0 → Branding → Custom Domains): **required** for SIT/UAT/Prod.
   Without it, silent re-authentication is a cross-site request that modern browsers block,
   so users get bounced to the login page on every reload. Put `VITE_AUTH0_DOMAIN` = the
   custom domain.
5. **API**: create an Auth0 API; its **Identifier** is `VITE_AUTH0_AUDIENCE`. This is also
   the audience Supabase validates (§7).
6. **Login Action** (Auth0 → Actions → Flows → Login) — add the `authenticated` role claim
   Supabase expects, and (optionally) the Supabase-required claims:
   ```js
   exports.onExecutePostLogin = async (event, api) => {
     // Supabase's Postgres RLS runs requests as the `authenticated` role only when the
     // access token carries this claim. Without it every RLS policy fails closed.
     api.accessToken.setCustomClaim("role", "authenticated");
   };
   ```

---

## 7. Supabase setup

1. Create a project per environment (or per environment schema). Put the project URL and the
   **anon** key into the GitHub Environment variables. **Never** put the `service_role` key
   anywhere near a `VITE_*` variable — it bypasses RLS entirely.
2. **Apply the schema**: run `supabase/migrations/0001_calculations.sql` (via the Supabase
   SQL editor or `supabase db push`). It creates the `calculations` table, enables **and
   forces** RLS, revokes blanket grants, and defines owner-scoped select/insert policies.
   There are no update/delete policies — history is append-only.
3. **Third-Party Auth (trust Auth0)**: Supabase → Authentication → Third-Party Auth → add a
   provider with:
   - **Issuer**: your Auth0 (custom) domain, e.g. `https://login.example.com/`.
   - **Audience**: the Auth0 API identifier = `VITE_AUTH0_AUDIENCE`.
   Supabase then validates each request's Auth0 access token against Auth0's JWKS. The token
   *is* the database credential; RLS reads the caller as `auth.jwt() ->> 'sub'`. No shared
   JWT secret, no custom server.
4. **Verify the trust boundary** (do this before go-live):
   - Signed in, you can read/insert only your own rows.
   - A request with no token (anon) returns nothing and can insert nothing.
   - An insert that sets `user_id` to another subject is rejected by the policy's `WITH CHECK`.

---

## 8. Deployment promotion & approvals

`deploy-azure-swa.yml` runs on push to `main` (post-merge) and chains three jobs:
`deploy-sit` → `deploy-uat` → `deploy-production`. Each job:
- builds the SPA with **that** environment's config compiled in,
- generates the environment's `staticwebapp.config.json`,
- publishes to that environment's SWA resource.

`uat` and `production` do not start until their GitHub Environment's required reviewers
approve (§2.3). Actions are pinned to commit SHAs; a moving tag could be repointed at
malicious code.

**OIDC hardening (recommended upgrade):** the deployment token is a long-lived secret. To
remove it, switch the deploy step to `azure/login@<sha>` with a federated credential
(workload identity) scoped to each GitHub Environment, then deploy via the SWA CLI
(`swa deploy`) using the OIDC token instead of `AZURE_STATIC_WEB_APPS_API_TOKEN`. This keeps
no standing Azure credential in GitHub.

---

## 9. Security checklist (verify before go-live)

- [ ] `main` branch protection requires both scan checks and blocks bypass (§2.1).
- [ ] Claude review **blocks** on High/Critical (it does by default now — see the hard-gate
      step in `claude-security-review.yml`).
- [ ] CodeQL check failure threshold set and the check is required on `main` (§5).
- [ ] `AUTOMATION_TOKEN` is fine-grained and repo-scoped; `CLAUDE_API_KEY` has a spend cap.
- [ ] Each GitHub Environment has its SWA token as a **secret** and its VITE_* config as
      **variables**; `uat`/`production` have required reviewers.
- [ ] Auth0 apps are SPA type (no secret); custom domain set for SIT/UAT/Prod; callback/logout
      URLs match each site origin; refresh token rotation on.
- [ ] Auth0 Login Action sets `role: authenticated`.
- [ ] Supabase RLS is enabled AND forced on every table; `service_role` key is nowhere in the
      frontend or in any `VITE_*` variable.
- [ ] Supabase Third-Party Auth issuer/audience match the Auth0 tenant.
- [ ] A production build with missing Auth0/Supabase config **fails** (try it:
      `VITE_APP_ENV=production npm run build` with the vars unset).
- [ ] `.env` is gitignored; only `.env.example` is committed.
