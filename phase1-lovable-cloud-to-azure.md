Sorry# Phase 1: Lovable Cloud → GitHub → Azure. No API.

## The one correction you need before anything else

> "I can make the database internal, only the React app becomes exposed."

Not quite, and the gap matters.

A browser cannot talk to Azure Database for PostgreSQL. Postgres speaks a binary wire protocol on
TCP 5432. `supabase-js` speaks HTTP/REST. The thing that translates between them is **PostgREST**,
and in Lovable Cloud today it's running inside Lovable's infrastructure. If you move the database
to Azure and delete the API, something still has to answer HTTP from the browser.

So Phase 1 is really: **you deploy the Supabase runtime into Azure.** Two things end up public:

- the Static Web App (React), and
- a PostgREST/GoTrue endpoint.

The *Postgres server itself* goes on a private endpoint and is genuinely internal — only your
containers reach it. That's a real gain over Lovable Cloud. But the query surface is still on the
internet, because that's what the browser is talking to.

**Which means: in Phase 1, RLS is not "one of the gates." It is the gate.** That's the honest
framing, and everything below is about making that survivable rather than pretending otherwise.

---

## Architecture

```
                    Front Door + WAF
                    │
        ┌───────────┴────────────┐
        │                        │
   Static Web App           Container Apps
   (React, public)          ├─ postgrest     ← public via Front Door
                            └─ gotrue (auth) ← public via Front Door
                                   │
                                   │ private endpoint, VNet-integrated
                                   ▼
                    Azure Database for PostgreSQL Flexible Server
                    (no public access, PITR, Defender, managed backups)
```

**Container set — keep it minimal.** You need `postgrest` and `gotrue`. Skip Kong (Container Apps
ingress does path routing: `/rest/v1/*` → postgrest, `/auth/v1/*` → gotrue). Skip `storage-api`
and `realtime` unless the app actually uses file uploads or live subscriptions. Two containers,
not nine.

Postgres is Azure Flex, **not** the `supabase/postgres` container. You keep PITR, private
endpoints, Defender for Cloud, and you're not the DBA for a container holding loan data.

---

## The two environments

| | Lovable preview | Azure dev |
|---|---|---|
| Backend | Lovable Cloud | Your PostgREST + Azure Postgres |
| Data | Synthetic. Always. | Whatever you seed |
| Who touches it | Citizen dev | You |
| Schema source | Lovable chat | `supabase/migrations/` from the repo |

Same schema, different data, different backend. The citizen dev never sees real records — they're
looking at Lovable Cloud the whole time they're building.

---

## What Lovable Cloud actually gives you

Confirmed, and this is the part that makes Phase 1 work:

- Lovable Cloud **does** sync `supabase/migrations/*.sql` to GitHub, and **RLS policies live inside
  those migration files** as SQL. Frontend code, migrations, and edge functions all travel.
- What does **not** travel: table data, auth users, storage files, and secrets. Fine — you don't
  want Lovable's fake data anyway.
- Lovable Cloud does **not** expose a direct database URL or service-role key. You cannot `pg_dump`
  it on demand. (There's now an official Export button under Cloud → Overview → Advanced settings
  if you ever need the data, but Phase 1 doesn't.)

**One thing to know going in:** connecting a project to Lovable Cloud is not reversible — Lovable's
own docs say you can't disconnect a project from Cloud. That's fine for this design, since Cloud
stays as the citizen dev's sandbox permanently. Just don't plan around undoing it.

### The nice surprise

Because you're running the real Supabase runtime in Azure, Lovable's generated SQL is **portable
as-is**. `auth.uid()`, `auth.users`, `grant to authenticated` — they all resolve, because GoTrue and
the Supabase roles exist on your side. No translation step. (This is the main thing that gets
simpler versus putting a .NET API in the middle.)

The cost: you have to bootstrap the Supabase roles and `auth` schema onto Azure Flex once by hand,
because Azure Flex isn't the `supabase/postgres` image. That's §"Bootstrap" below — roughly 60
lines, written once.

---

## The environment swap

Your instinct was right, with one wrinkle. Known issue: **Lovable periodically rewrites the client
config back to Lovable Cloud settings** when you edit in chat. So do not swap env vars by editing
`.env` in the repo — Lovable will silently undo it and you'll ship a build pointing at Lovable Cloud.

Do it in CI, where Lovable can't reach:

```yaml
# .github/workflows/deploy-dev.yml
name: deploy-dev
on:
  push:
    branches: [dev]

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20', cache: 'npm' }
      - run: npm ci

      # Overwrite whatever Lovable committed. Every build. No exceptions.
      - name: Point client at Azure backend
        run: |
          cat > src/integrations/supabase/client.ts <<'EOF'
          import { createClient } from '@supabase/supabase-js';
          export const supabase = createClient(
            import.meta.env.VITE_SUPABASE_URL,
            import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
          );
          EOF

      - name: Fail if a Lovable Cloud URL survived
        run: |
          if grep -rIn --exclude-dir=node_modules -e 'supabase.co' -e 'lovable' src/ ; then
            echo "::error::Lovable Cloud endpoint leaked into the build."
            exit 1
          fi

      - run: npm run build
        env:
          VITE_SUPABASE_URL: ${{ vars.AZURE_SUPABASE_URL }}
          VITE_SUPABASE_PUBLISHABLE_KEY: ${{ secrets.AZURE_ANON_KEY }}

      - uses: Azure/static-web-apps-deploy@v1
        with:
          azure_static_web_apps_api_token: ${{ secrets.SWA_TOKEN }}
          app_location: "dist"
          skip_app_build: true
```

The anon key is just a JWT with `role: anon`, signed with your `PGRST_JWT_SECRET`. You mint your
own — Lovable's key is meaningless against your backend, which is a quiet security property worth
noticing.

### Migrations

```yaml
  migrate:
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - uses: supabase/setup-cli@v1
      - run: supabase db push --db-url "${{ secrets.AZURE_DB_URL }}"
      - name: RLS gate
        run: psql "${{ secrets.AZURE_DB_URL }}" -v ON_ERROR_STOP=1 -f db/checks/rls_gate.sql
```

Run this **before** the app deploy. Gate the app on it.

**Rule with no exceptions:** the Azure schema changes only by applying repo migrations. Nobody
opens a SQL editor against Azure Postgres and types. The moment someone does, Lovable Cloud and
Azure drift, and the next migration fails at 4pm on a Friday.

---

## Making RLS safer — the actual answer

Six moves, roughly in order of leverage.

### 1. Deny by default (this is the big one)

`supabase/postgres` ships with default privileges that auto-grant every new table in `public` to
`anon` and `authenticated`. That's why "Lovable created a table and forgot RLS" is catastrophic
rather than annoying — no RLS + a standing grant = world-readable.

You're bootstrapping Azure Flex yourself, so **just don't add those grants.** Deny-by-default for
free, by omission:

```sql
-- 000_bootstrap.sql — run ONCE against Azure Flex.
create role anon             nologin noinherit;
create role authenticated    nologin noinherit;
create role service_role     nologin noinherit bypassrls;
create role authenticator    login   noinherit password :'authenticator_pw';
grant anon, authenticated, service_role to authenticator;

create schema if not exists auth;
create schema if not exists private;   -- never exposed. See #3.

create or replace function auth.uid() returns uuid
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )
$$;

-- The unauthenticated role gets nothing at all.
revoke all on schema public from anon;
grant usage on schema public to authenticated;

-- DELIBERATELY NOT RUN — this is what Supabase ships and what we're rejecting:
--   alter default privileges in schema public grant all on tables to anon, authenticated;
```

**The consequence is intentional and it's your review gate:** a new Lovable table works in Lovable
Cloud and is inert in Azure until you add one explicit line:

```sql
grant select, insert on public.payment to authenticated;
```

One line per table, from you, in a PR. It fails loudly in dev, never silently in prod. That is the
whole control, and it costs about thirty seconds per table.

### 2. Force RLS, and prove it in CI

```sql
alter table public.payment enable row level security;
alter table public.payment force  row level security;
```

`force` matters: without it, if the connection is the table owner, RLS is silently skipped. It is
the single most common self-hosted footgun and it fails *open*.

`db/checks/rls_gate.sql` — fails the pipeline, so nobody has to remember:

```sql
-- Any exposed table without RLS enabled AND forced?
do $$
declare bad text;
begin
  select string_agg(c.relname, ', ') into bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
    and (not c.relrowsecurity or not c.relforcerowsecurity);
  if bad is not null then
    raise exception 'RLS not enabled/forced on: %', bad;
  end if;
end $$;

-- Any table granted to authenticated but carrying zero policies?
do $$
declare bad text;
begin
  select string_agg(t.relname, ', ') into bad
  from pg_class t
  join pg_namespace n on n.oid = t.relnamespace
  left join pg_policy p on p.polrelid = t.oid
  where n.nspname = 'public' and t.relkind = 'r'
    and has_table_privilege('authenticated', t.oid, 'SELECT')
  group by t.relname
  having count(p.oid) = 0;
  if bad is not null then
    raise exception 'Granted but no policy: %', bad;
  end if;
end $$;

-- Nothing the API touches may bypass RLS.
do $$
begin
  if exists (select 1 from pg_roles
             where rolname in ('anon','authenticated','authenticator')
               and rolbypassrls) then
    raise exception 'A request-path role has BYPASSRLS.';
  end if;
end $$;
```

This one file is worth more than every policy review you'll ever do by hand.

### 3. Sensitive columns leave `public` entirely

PostgREST only exposes schemas listed in `PGRST_DB_SCHEMAS`. Set it to `public` and put anything
you'd have to report a breach over in `private`:

```sql
create table private.borrower_pii (
  borrower_id uuid primary key references public.app_user(id),
  ssn_encrypted bytea not null,
  dob date not null
);
```

No policy is required, because **no policy can be wrong about a table PostgREST cannot see.** This
is the only control on the list that's immune to a bad policy, so use it aggressively. SSN, DOB,
full account numbers, internal risk scores — none of it belongs in `public`.

### 4. Column-level grants

Row policies answer "which rows." They say nothing about which *columns* a user may write:

```sql
grant select                        on public.profile to authenticated;
grant update (display_name, phone)  on public.profile to authenticated;
```

Now a sloppy `using (true)` on update still can't let someone set their own `is_admin` or `balance`.
This is the cheapest defense-in-depth available in an RLS-only world.

### 5. Server-authoritative ownership

Never let the client assert who it is:

```sql
alter table public.payment
  alter column borrower_id set default auth.uid();

create policy payment_insert_self on public.payment
  for insert to authenticated
  with check (borrower_id = auth.uid());
```

Same idea for `created_at` (`default now()`, no update grant) and `status` (no update grant at all).

**Be clear-eyed about the limit here.** RLS answers "which rows?" It never answers "is this number
legitimate?" A borrower with a valid session can still `insert` a `payment` row with
`amount_cents = 1`, and no policy stops that — the row *is* theirs. Anything where the server must
decide a value, not just filter rows, cannot be solved in Phase 1. That's the argument for Phase 2,
and it's worth writing down now so the decision to add the API later is already made rather than
re-litigated.

### 6. Blast-radius caps

```
PGRST_DB_SCHEMAS=public
PGRST_DB_ANON_ROLE=anon
PGRST_DB_MAX_ROWS=1000        # caps enumeration on a leaky policy
PGRST_DB_PLAN_ENABLED=false
PGRST_OPENAPI_MODE=disabled   # stop publishing your schema
PGRST_LOG_LEVEL=info
```

Plus a Front Door rate limit on `/rest/v1/*`. A bad policy leaks slowly instead of all at once.

**And keep `service_role` out of Azure entirely in Phase 1.** It has `bypassrls`. If no container
holds it, no container can leak it. You only need it once edge functions arrive — which is Phase 2.

---

## Verify before you trust any of it

1. `curl` `/rest/v1/payment` with no `Authorization` → **empty or 401.** Not rows.
2. Log in as borrower A, request B's rows → **zero rows.**
3. `psql` as `authenticated` with no JWT context set, `select * from payment` → **zero rows.** If
   you get rows, `force row level security` didn't take.
4. Ask Lovable to add a table, let it flow through → **Azure deploy fails on the RLS gate** until
   you add the grant. If it deploys clean, your gate isn't wired up.
5. `select rolname from pg_roles where rolbypassrls` → **only `service_role`,** which isn't deployed.
6. Grep the built `dist/` for `supabase.co` → **nothing.**

Test 3 is the one that catches the footgun that fails open. Test 4 is the one that proves the
citizen dev can't outrun you. Run both in CI.

---

## What Phase 2 buys, when you get there

Phase 1 is defensible for read-mostly, borrower-scoped, low-consequence data — dashboards,
documents, status pages, preferences. The seam where it stops holding is **anything where a value
must be server-decided**: payment amounts, rate locks, eligibility, approvals, anything a regulator
would ask you to reconstruct.

Note that Phase 2 doesn't undo Phase 1. The .NET API goes in front, PostgREST comes down, the lint
rule flips on, and every one of the six hardening moves above stays exactly as-is — they just stop
being load-bearing and start being defense-in-depth. Nothing here is throwaway.
