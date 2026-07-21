# Azure Setup — Step by Step

A hands-on runbook to stand up the Azure side of this app. Written for someone comfortable
with backends and CLIs but **not** with the React/JS build (the pipeline handles that for you).

**Assumptions (already done):** Lovable ↔ GitHub sync, GitHub code scanning. You have an Azure
subscription and will create resource groups.

**Strategy: do SIT first, end to end.** Get one environment fully working, then repeat the
short version for UAT and Production (§9). Don't provision all three up front.

**Time:** ~2–3 hours for the first environment.

---

## Stage 0 — Set your variables once

Run everything below in a Bash shell (Git Bash on Windows is fine) **from the repo root**.
Set these once; every later command reuses them.

```bash
export APP=gentlecalc                      # app slug used in resource names
export ENVN=sit                            # sit | uat | prod
export LOCATION=eastus                     # your Azure region
export SUB_ID=<your-subscription-id>
export GH_ORG=<your-github-org-or-user>
export GH_REPO=gentle-calc-page
export RG=rg-$APP-$ENVN

# Auth0 (fill after Stage 1)
export AUTH0_TENANT=<your-tenant>.eu.auth0.com     # default tenant domain for now
export AUTH0_AUDIENCE=https://api.$APP.example.com # the API identifier you'll create

# Generate DB passwords now and SAVE THEM in your password manager / Key Vault.
# The authenticator password MUST be identical in the Bicep deploy (Stage 3) and the
# database bootstrap (Stage 4), or PostgREST can't log in.
export PG_ADMIN_PASSWORD="$(openssl rand -base64 24)"
export PG_AUTHENTICATOR_PASSWORD="$(openssl rand -base64 24)"
echo "SAVE THESE:"; echo "admin=$PG_ADMIN_PASSWORD"; echo "authenticator=$PG_AUTHENTICATOR_PASSWORD"
```

Log in and select the subscription (run the login yourself in the terminal — type
`! az login` here, or run it in your own shell):

```bash
az account set --subscription "$SUB_ID"
az account show --query name -o tsv          # sanity check
```

---

## Stage 1 — Auth0 (identity provider)

Auth0 is the login system. ~30 min, all in the Auth0 dashboard.

1. **Create/choose a tenant.** A dedicated tenant per environment is cleanest, but you can use
   one tenant with three Applications. Note the tenant domain, e.g. `your-tenant.eu.auth0.com`.
2. **Create an Application** → type **Single Page Application**. This gives a **public** client
   (PKCE, no client secret — correct for a browser app). Note the **Client ID**.
3. **Application → Settings**, set (you'll refine the URLs in Stage 5 once you have the site
   host — for now put a placeholder like `http://localhost:8080`):
   - Allowed Callback URLs, Allowed Logout URLs, Allowed Web Origins.
   - **Refresh Token Rotation: ON** (Settings → Refresh Token Rotation).
4. **Create an API** (Applications → APIs → Create). Set its **Identifier** to your audience,
   e.g. `https://api.gentlecalc.example.com`. This value is `AUTH0_AUDIENCE` and also what
   PostgREST validates. It does not need to resolve to anything — it's just an identifier.
5. **Add a Login Action** (Actions → Triggers → post-login) so the token carries the DB role:
   ```js
   exports.onExecutePostLogin = async (event, api) => {
     api.accessToken.setCustomClaim("role", "authenticated");
   };
   ```
   Deploy the action and drag it into the Login flow. **Without this, every DB query is denied.**
6. **Custom domain** (Branding → Custom Domains): needed for a smooth session on page reload in
   real environments. **You can skip this for initial testing** (you'll just re-login on reload)
   and add it before go-live. When you add it, set `AUTH0_TENANT` to the custom domain.
7. **Grab the JWKS** (PostgREST verifies tokens against it):
   ```bash
   export AUTH0_JWKS="$(curl -s https://$AUTH0_TENANT/.well-known/jwks.json)"
   echo "$AUTH0_JWKS" | head -c 120; echo    # should start with {"keys":[...
   ```

Checkpoint: you now have `Client ID`, `AUTH0_TENANT`, `AUTH0_AUDIENCE`, `AUTH0_JWKS`.

---

## Stage 2 — Azure foundation: resource group + GitHub OIDC

~20 min.

```bash
# Resource group
az group create -n "$RG" -l "$LOCATION"
```

**GitHub OIDC** lets the pipeline deploy without a stored Azure secret. Create an app
registration with a federated credential scoped to this repo + environment:

```bash
az ad app create --display-name "gh-oidc-$APP-$ENVN"
export APP_ID="$(az ad app list --display-name "gh-oidc-$APP-$ENVN" --query '[0].appId' -o tsv)"
az ad sp create --id "$APP_ID"

az ad app federated-credential create --id "$APP_ID" --parameters "{
  \"name\": \"gh-$ENVN\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:$GH_ORG/$GH_REPO:environment:$ENVN\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"

# Let it deploy into this resource group
az role assignment create --assignee "$APP_ID" --role Contributor \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG"

export TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "AZURE_CLIENT_ID=$APP_ID"; echo "AZURE_TENANT_ID=$TENANT_ID"; echo "AZURE_SUBSCRIPTION_ID=$SUB_ID"
```

You'll put those three `AZURE_*` values into the GitHub Environment in Stage 5.

---

## Stage 3 — Provision the infrastructure (Bicep)

We run Bicep **locally the first time** — easier to debug than through Actions. ~30 min
(Front Door + Postgres take a while).

```bash
# Secrets the .bicepparam reads from the environment (already exported above, plus these):
export AUTH0_AUDIENCE="$AUTH0_AUDIENCE"
export AUTH0_JWKS="$AUTH0_JWKS"

# Preview first
az deployment group what-if \
  --resource-group "$RG" --name "$APP-$ENVN" \
  --parameters "infra/bicep/env/$ENVN.bicepparam"

# Then create
az deployment group create \
  --resource-group "$RG" --name "$APP-$ENVN" \
  --parameters "infra/bicep/env/$ENVN.bicepparam"
```

> Note: with a `.bicepparam` file you pass only `--parameters` — the template comes from its
> `using` line. Do not also pass `--template-file`.

Read the outputs you'll need next:

```bash
az deployment group show -g "$RG" -n "$APP-$ENVN" --query properties.outputs -o json
# → frontDoorHostname, swaName, postgresServerName

export FRONTDOOR_HOST="$(az deployment group show -g $RG -n $APP-$ENVN --query 'properties.outputs.frontDoorHostname.value' -o tsv)"
export SWA_NAME="$(az deployment group show -g $RG -n $APP-$ENVN --query 'properties.outputs.swaName.value' -o tsv)"
export PG_SERVER="$(az deployment group show -g $RG -n $APP-$ENVN --query 'properties.outputs.postgresServerName.value' -o tsv)"

# Static Web App deployment token (for the frontend deploy)
export SWA_TOKEN="$(az staticwebapp secrets list --name "$SWA_NAME" --query 'properties.apiKey' -o tsv)"
echo "FRONTDOOR_HOST=$FRONTDOOR_HOST"
```

Checkpoint: VNet, private Postgres, Container Apps + PostgREST, SWA, and Front Door + WAF now
exist. The app won't work yet — the database has no schema and the frontend isn't deployed.

---

## Stage 4 — Bootstrap and migrate the database

The Postgres server is **private (no public access)** by design, and — importantly — a
VNet-integrated Flexible Server **cannot** be switched to public access afterward (that's a
create-time decision). So you reach it from **inside the VNet**, once, via a temporary jump VM.
~30 min.

```bash
# 4.1 A tiny subnet + jump VM (SSH restricted to your current IP)
export MYIP="$(curl -s ifconfig.me)"
az network vnet subnet create -g "$RG" --vnet-name "vnet-$APP-$ENVN" \
  -n snet-jump --address-prefixes 10.10.3.0/28     # use 10.20.3.0/28 for uat, 10.30.3.0/28 for prod

az vm create -g "$RG" -n "vm-jump-$ENVN" \
  --image Ubuntu2204 --size Standard_B1s \
  --vnet-name "vnet-$APP-$ENVN" --subnet snet-jump \
  --admin-username azureuser --generate-ssh-keys \
  --public-ip-sku Standard --nsg-rule NONE

# Lock SSH to your IP only
az network nsg rule create -g "$RG" --nsg-name "vm-jump-${ENVN}NSG" \
  -n allow-ssh-myip --priority 100 --access Allow --protocol Tcp \
  --destination-port-ranges 22 --source-address-prefixes "$MYIP"

export JUMP_IP="$(az vm show -d -g $RG -n vm-jump-$ENVN --query publicIps -o tsv)"

# 4.2 Copy the SQL up and install psql on the jump box
scp -o StrictHostKeyChecking=no -r db supabase azureuser@$JUMP_IP:~/
ssh -o StrictHostKeyChecking=no azureuser@$JUMP_IP \
  'sudo apt-get update -qq && sudo apt-get install -y postgresql-client'
```

Now SSH in and run the SQL (paste your saved passwords when prompted / export them on the box):

```bash
ssh azureuser@$JUMP_IP
# ---- on the jump box ----
export PGHOST=<postgresServerName>.postgres.database.azure.com     # from Stage 3
export PGUSER=pgadmin
export PGDATABASE=appdb
export PGSSLMODE=require
export PGPASSWORD='<PG_ADMIN_PASSWORD you saved>'

# One-time bootstrap: roles, auth.* helpers, deny-by-default. Pass the AUTHENTICATOR password.
psql -v ON_ERROR_STOP=1 \
     -v authenticator_pw='<PG_AUTHENTICATOR_PASSWORD you saved>' \
     -f db/bootstrap/000_bootstrap.sql

# Apply migrations in order
for f in $(ls supabase/migrations/*.sql | sort); do echo "applying $f"; psql -v ON_ERROR_STOP=1 -f "$f"; done

# Prove RLS is watertight — this must print "rls_gate: OK"
psql -v ON_ERROR_STOP=1 -f db/checks/rls_gate.sql
exit
```

Checkpoint: schema + RLS are in place and the gate passed. **Leave the jump box for now** —
you'll want it if you change the schema. Delete it in Stage 8 (or stop it to save cost:
`az vm deallocate -g $RG -n vm-jump-$ENVN`).

---

## Stage 4 (Alt-A, POC) — Bootstrap without a jump box (keep the VNet private)

Use this **instead of** Stage 4 when you don't want to stand up a jump VM yet (quick POC, test
data only). It keeps the VNet and private Postgres unchanged — a **one-shot Azure Container
Instance** runs the SQL from inside the VNet, then you delete it. No VM, no SSH. ~15 min.

Why this works: the DB is only reachable inside the VNet, and ACI can be injected into the VNet.
It resolves the same private Postgres FQDN that PostgREST already uses, via the linked private
DNS zone. The repo SQL is handed to it through a temporary Azure File share.

```bash
# 4A.1 Temporary storage + file share holding the repo SQL (db/ and supabase/)
export STG="stg${APP}${ENVN}$RANDOM"          # must be globally unique, lowercase, <=24 chars
az storage account create -g "$RG" -n "$STG" -l "$LOCATION" --sku Standard_LRS
export STG_KEY="$(az storage account keys list -g "$RG" -n "$STG" --query '[0].value' -o tsv)"
az storage share create --account-name "$STG" --account-key "$STG_KEY" -n sqlbundle

az storage file upload-batch --account-name "$STG" --account-key "$STG_KEY" \
  --destination sqlbundle --source db --destination-path db
az storage file upload-batch --account-name "$STG" --account-key "$STG_KEY" \
  --destination sqlbundle --source supabase --destination-path supabase

# 4A.2 A tiny subnet delegated to Container Instances (reuses the range Stage 4 reserved)
az network vnet subnet create -g "$RG" --vnet-name "vnet-$APP-$ENVN" \
  -n snet-aci --address-prefixes 10.10.3.0/28 \
  --delegations Microsoft.ContainerInstance/containerGroups   # 10.20.3.0/28 uat, 10.30.3.0/28 prod
export ACI_SUBNET_ID="$(az network vnet subnet show -g "$RG" \
  --vnet-name "vnet-$APP-$ENVN" -n snet-aci --query id -o tsv)"

# 4A.3 Run the bootstrap + migrations + rls_gate in one throwaway container.
#      PGHOST is the same server FQDN PostgREST connects to (from Stage 3).
export PGHOST="$PG_SERVER.postgres.database.azure.com"
az container create -g "$RG" -n "aci-dbmigrate-$ENVN" \
  --image postgres:16 --restart-policy Never --subnet "$ACI_SUBNET_ID" \
  --azure-file-volume-account-name "$STG" --azure-file-volume-account-key "$STG_KEY" \
  --azure-file-volume-share-name sqlbundle --azure-file-volume-mount-path /sql \
  --environment-variables PGHOST="$PGHOST" PGUSER=pgadmin PGDATABASE=appdb PGSSLMODE=require \
  --secure-environment-variables \
      PGPASSWORD="$PG_ADMIN_PASSWORD" AUTHPW="$PG_AUTHENTICATOR_PASSWORD" \
  --command-line "sh -c 'set -e; \
    psql -v ON_ERROR_STOP=1 -v authenticator_pw=\"\$AUTHPW\" -f /sql/db/bootstrap/000_bootstrap.sql; \
    for f in \$(ls /sql/supabase/migrations/*.sql | sort); do echo applying \$f; psql -v ON_ERROR_STOP=1 -f \"\$f\"; done; \
    psql -v ON_ERROR_STOP=1 -f /sql/db/checks/rls_gate.sql'"

# 4A.4 Read the result — must show the migrations applying and "rls_gate: OK"
az container logs -g "$RG" -n "aci-dbmigrate-$ENVN"
```

Then tear down everything this alt path created (nothing persistent should remain):

```bash
az container delete -g "$RG" -n "aci-dbmigrate-$ENVN" --yes
az storage account delete -g "$RG" -n "$STG" --yes
az network vnet subnet delete -g "$RG" --vnet-name "vnet-$APP-$ENVN" -n snet-aci
```

Checkpoint: same as Stage 4 — schema + RLS in place, gate passed — but no jump box exists.
Skip Stage 8's jump-box deletion (there's nothing to delete). For **ongoing schema changes**
(Stage 10) without a jump box, re-run 4A.1–4A.4 with the new migration; when you build the real
production system, set up the jump box (Stage 4) or the self-hosted runner instead.

> Note: this leaves no in-VNet migration path standing between runs. That's the tradeoff for
> not keeping a jump box — fine for a POC, but for production prefer Stage 4 / Stage 10's runner.

---

## Stage 4 (Alt-B, POC) — Public Postgres to test the Lovable → migration pipeline

Use this when the thing you actually want to exercise is the **continuous migration loop**:
change schema in Lovable → it syncs to GitHub → a push applies the migration to Postgres. With a
**public** database, a normal GitHub-hosted runner can reach it, so `db-migrate.yml` runs with no
jump box and no self-hosted runner. Making the DB private again is **step 2** (just repoint the
pipeline at the Stage 3 private server and revert the two workflow edits below).

The Stage 3 server can't be flipped to public (it's VNet-integrated, fixed at create time), so
this stands up a **separate throwaway public server** and leaves your private infra untouched.
Test data only — it's internet-reachable (TLS required, strong password), so don't put anything
real in it.

```bash
# 4B.1 A standalone PUBLIC Flexible Server, outside the VNet. One command, fully reversible.
export PG_PUBLIC="psql-$APP-$ENVN-pub"
az postgres flexible-server create \
  -g "$RG" -n "$PG_PUBLIC" -l "$LOCATION" \
  --admin-user pgadmin --admin-password "$PG_ADMIN_PASSWORD" \
  --version 16 --tier Burstable --sku-name Standard_B1ms \
  --storage-size 32 \
  --public-access Enabled --yes
  # --version 16 matches Stage 3's server (postgres.bicep); keep them equal so migrations
  # behave identically. Azure now offers newer majors — don't bump this one in isolation.
  # Use `Enabled` (public mode, no rules yet), NOT `None` — `None` can come out with public
  # access DISABLED, which then rejects the firewall-rule create below.

# Create the app database. On single-server create, `--database-name` is rejected (it now only
# applies to elastic clusters with --node-count), so make appdb as its own step.
az postgres flexible-server db create -g "$RG" -s "$PG_PUBLIC" -d appdb
az postgres flexible-server parameter set -g "$RG" -s "$PG_PUBLIC" \
  --name require_secure_transport --value on

# Let GitHub-hosted runners (dynamic, non-Azure IPs) in. POC-wide open; tighten or delete for prod.
# Note: for firewall-rule create, --name is the RULE name and the server is --server-name.
# If this errors "not supported for a server without public access enabled", the server came up
# with public access off — run: az postgres flexible-server update -g "$RG" -n "$PG_PUBLIC" \
#   --public-access Enabled   ...then retry this command.
az postgres flexible-server firewall-rule create -g "$RG" --server-name "$PG_PUBLIC" \
  --name poc-allow-all --start-ip-address 0.0.0.0 --end-ip-address 255.255.255.255

export PGHOST="$PG_PUBLIC.postgres.database.azure.com"

# 4B.2 One-time bootstrap — now runnable straight from your laptop (the DB is public).
# Needs the psql client locally (the jump-box path installed it via apt; on Windows do it once):
#   winget install -e --id PostgreSQL.PostgreSQL.16
#   export PATH="$PATH:/c/Program Files/PostgreSQL/16/bin"   # add to the current shell
# (or run this single file from Azure Cloud Shell, which already has psql). Match the client
# major version to the server (16). db-migrate.yml does NOT run bootstrap — this step is manual.
export PGUSER=pgadmin PGDATABASE=appdb PGSSLMODE=require
export PGPASSWORD="$PG_ADMIN_PASSWORD"
psql -v ON_ERROR_STOP=1 \
     -v authenticator_pw="$PG_AUTHENTICATOR_PASSWORD" \
     -f db/bootstrap/000_bootstrap.sql
```

**4B.3 Point the pipeline at the public server.** In GitHub → Settings → Environments → `sit`,
add the connection string the workflow reads (URL-encode any `+ / =` in the password, or
regenerate an alphanumeric one to avoid the hassle):

```
ADMIN_DB_URL = postgresql://pgadmin:<url-encoded-pw>@<PG_PUBLIC>.postgres.database.azure.com:5432/appdb?sslmode=require
```

Then make two edits to `.github/workflows/db-migrate.yml` (revert both for the private step 2):

```yaml
# (a) run on a GitHub-hosted runner instead of the in-VNet self-hosted one
jobs:
  migrate:
    runs-on: ubuntu-latest        # was: [self-hosted, vnet, "${{ inputs.environment }}"]

# (b) fire automatically when Lovable's synced migrations land, not just on manual dispatch
on:
  push:
    branches: [main]                       # the branch Lovable syncs into
    paths: ["supabase/migrations/**"]
  workflow_dispatch:
    inputs:
      environment: { description: "Target environment", required: true, type: choice, options: ["sit","uat","prod"] }
```

Because a `push` event has no `inputs.environment`, default the target for that path — e.g. set
`environment.name` and the `-${{ inputs.environment || 'sit' }}` concurrency group to fall back
to `sit`. (During the POC you're only testing SIT.)

**4B.4 Run the loop.** Change a table in Lovable → let it sync a new file into
`supabase/migrations/` on GitHub → the push triggers **Apply DB migrations + RLS gate** on a
GitHub-hosted runner → watch it apply the migration and print `rls_gate: OK` in the Actions log.
Confirm from your laptop: `psql "$ADMIN_DB_URL" -c '\dt'` shows the new table.

Checkpoint: the Lovable → GitHub → Postgres migration pipeline runs end to end against a public
DB, no jump box or self-hosted runner. **Step 2 (go private):** repoint `ADMIN_DB_URL` at the
Stage 3 private server, revert the two workflow edits, run migrations via Stage 4 / 4A / a
self-hosted runner, and `az postgres flexible-server delete -g $RG -n $PG_PUBLIC --yes`.

> Security note: `poc-allow-all` opens the server to the whole internet. Acceptable only for
> throwaway test data behind TLS + a strong password. Delete the rule and the server before this
> environment holds anything you care about.

---

## Stage 5 — Wire the configuration back

Now that you have the Front Door hostname and SWA token, finish the config. ~15 min.

**5.1 GitHub Environment.** In GitHub → Settings → Environments → create **`sit`**. Add:

Variables (public):
- `VITE_APP_ENV` = `sit`
- `VITE_AUTH0_DOMAIN` = your `$AUTH0_TENANT`
- `VITE_AUTH0_CLIENT_ID` = the SPA Client ID
- `VITE_AUTH0_AUDIENCE` = your `$AUTH0_AUDIENCE`
- `VITE_SUPABASE_URL` = `https://<FRONTDOOR_HOST>`
- `VITE_SUPABASE_ANON_KEY` = `placeholder` (PostgREST ignores it)
- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (from Stage 2)

Secrets:
- `AZURE_STATIC_WEB_APPS_API_TOKEN` = your `$SWA_TOKEN`
- `PG_ADMIN_PASSWORD`, `PG_AUTHENTICATOR_PASSWORD`, `AUTH0_JWKS` (for future infra runs via Actions)

**5.2 Update Auth0 URLs** now that you know the site origin (`https://<FRONTDOOR_HOST>`): set
Allowed Callback URLs, Logout URLs, and Web Origins to that origin (keep `http://localhost:8080`
for local dev).

---

## Stage 6 — Deploy the frontend

Two options. Do the quick manual deploy first to smoke-test, then rely on the pipeline.

**6.1 Quick manual deploy (fastest first check):**
```bash
npm ci
VITE_APP_ENV=sit \
VITE_AUTH0_DOMAIN=$AUTH0_TENANT \
VITE_AUTH0_CLIENT_ID=<client-id> \
VITE_AUTH0_AUDIENCE=$AUTH0_AUDIENCE \
VITE_SUPABASE_URL=https://$FRONTDOOR_HOST \
VITE_SUPABASE_ANON_KEY=placeholder \
npm run build:swa

npx @azure/static-web-apps-cli deploy dist/client \
  --deployment-token "$SWA_TOKEN" --env production
```

**6.2 The real path (automated):** the `deploy-azure-swa.yml` workflow builds and deploys on
every push to `main`, promoting SIT → UAT → Prod. Once your GitHub Environment (5.1) is set,
merging to `main` deploys SIT automatically.

Browse to `https://<FRONTDOOR_HOST>` → you should be redirected to Auth0 to sign in, then land
on the app.

---

## Stage 7 — Verify (the checks that catch silent failures)

```bash
# 1. No token → no data (expect 401 or empty array, NOT rows)
curl -s "https://$FRONTDOOR_HOST/rest/v1/calculations" -i | head -n 1

# 2. Signed in as user A, you only ever see your own rows (test in the app UI).

# 3. Add a table via Lovable, let it sync, and run Stage 4's rls_gate.sql → it must FAIL
#    until you add an explicit grant. If it passes, your gate isn't protecting you.

# 4. Only service_role may bypass RLS (run on the jump box):
#    psql -c "select rolname from pg_roles where rolbypassrls;"  → only service_role
```

Also confirm a production-style build refuses to run without config:
`VITE_APP_ENV=sit npm run build` with the Auth0 vars unset → build fails. That's the safety net.

---

## Stage 8 — Lock down / clean up

```bash
# Delete the jump box + its subnet when you're done bootstrapping (recreate later if needed):
az vm delete -g "$RG" -n "vm-jump-$ENVN" --yes
az network nic delete -g "$RG" --name "vm-jump-${ENVN}VMNic" 2>/dev/null || true
az network public-ip delete -g "$RG" --name "vm-jump-${ENVN}PublicIP" 2>/dev/null || true
az network vnet subnet delete -g "$RG" --vnet-name "vnet-$APP-$ENVN" -n snet-jump 2>/dev/null || true
```

Confirm the database is private: `az postgres flexible-server show -g $RG -n $PG_SERVER --query network`.

---

## 9 — Replicate for UAT and Production

Repeat Stages 2–8 with `ENVN=uat` then `ENVN=prod`. Differences:
- Change the jump subnet prefix (`10.20.3.0/28`, `10.30.3.0/28`).
- Production uses a bigger Postgres SKU + zone-redundant HA + geo backup (already in
  `prod.bicepparam`).
- Set **required reviewers** on the `uat` and `production` GitHub Environments so deploys pause
  for approval.
- Use a per-environment Auth0 Application (and, before go-live, a custom domain each).

---

## 10 — Ongoing schema changes (after first setup)

Migrations must run from inside the VNet. Two options:
- **Simple:** start the jump VM (`az vm start …`), apply the new migration + rls_gate, stop it.
- **Automated:** register a **self-hosted GitHub runner inside the VNet** and use
  `db-migrate.yml` (its `runs-on` already targets a `[self-hosted, vnet, <env>]` label). A
  GitHub-hosted runner cannot reach the private database.

**Rule:** the Azure schema changes ONLY by applying repo migrations. Never hand-edit via a SQL
editor, or Lovable's synced migrations and Azure will drift.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| App loads but every data call is 401/empty | Auth0 Login Action not setting `role: authenticated`; or token audience ≠ `PGRST_JWT_AUD`. |
| Login redirect loops / "callback mismatch" | Auth0 Allowed Callback/Web Origin URLs don't include `https://<FRONTDOOR_HOST>`. |
| Login fails only in the deployed site (works locally) | CSP blocking the Auth0 blob worker — confirm `worker-src 'self' blob:` is in the generated CSP. |
| Re-login on every page refresh | Expected without an Auth0 custom domain (in-memory tokens). Add the custom domain. |
| `psql` from your laptop hangs/refuses | The DB is private by design — you must use the in-VNet jump box (Stage 4). |
| Bicep deploy fails on HA | `zoneRedundantHa` needs a General Purpose SKU (Burstable won't do). Only `prod.bicepparam` enables it. |
| PostgREST 500 / can't connect to DB | `PG_AUTHENTICATOR_PASSWORD` used in Stage 3 ≠ the one set in the Stage 4 bootstrap. They must match. |
| `az deployment` error about template + params | Don't pass `--template-file` with a `.bicepparam`; pass only `--parameters`. |

---

*Companion docs: `PIPELINE-SETUP.md` (reference), `LOVABLE-TO-AZURE-REFERENCE.md` (portable
architecture), `phase1-lovable-cloud-to-azure.md` (origin note).*
