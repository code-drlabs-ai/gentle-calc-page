-- =============================================================================
-- 000_bootstrap.sql — run ONCE, by hand, against each Azure Postgres Flexible
-- Server (SIT / UAT / Production) before any migration is applied.
-- =============================================================================
--
-- Azure Flexible Server is NOT the supabase/postgres image, so the Supabase roles
-- and the `auth.*` helper functions that PostgREST + RLS rely on do not exist. This
-- file creates them.
--
-- IMPORTANT — this is the Auth0 variant, not the GoTrue one:
--   * There is NO GoTrue in this architecture. Auth0 is the identity provider; it
--     issues the JWTs. PostgREST validates them against Auth0's JWKS.
--   * There is therefore NO `auth.users` table. Do not reference it in policies.
--   * An Auth0 subject ("sub") looks like `auth0|65f...` or `google-oauth2|10...`.
--     It is NOT a UUID. `auth.uid()` is intentionally omitted; use `auth.jwt_sub()`
--     (text) for ownership. A uuid-returning auth.uid() would throw on every request.
--
-- Deny-by-default is achieved BY OMISSION: we never run the `alter default
-- privileges ... grant all ... to anon, authenticated` that supabase/postgres ships.
-- A new table is therefore inert until a migration explicitly grants it. That is the
-- review gate (see README and PIPELINE-SETUP.md, "RLS is the gate").
--
-- Parameters (pass with `psql -v`):
--   authenticator_pw  — password for the login role PostgREST connects as.
-- Example:
--   psql "$ADMIN_DB_URL" -v ON_ERROR_STOP=1 \
--        -v authenticator_pw="$(openssl rand -base64 24)" \
--        -f db/bootstrap/000_bootstrap.sql
-- =============================================================================

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------
-- anon           : an unauthenticated request. Gets nothing (see grants below).
-- authenticated  : a request carrying a valid Auth0 token with role=authenticated.
-- service_role   : bypasses RLS. MUST NOT be deployed to any request-path container
--                  in Phase 1. Created here only so migrations can reference it.
-- authenticator  : the ONLY login role; PostgREST connects as it and SET ROLEs to
--                  one of the three above based on the request's JWT `role` claim.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit;
  end if;
end $$;

-- Set/rotate the authenticator login password. This MUST live OUTSIDE the do $$ ... $$ block
-- above: psql interpolates :'authenticator_pw' in ordinary statements but NEVER inside a
-- dollar-quoted string, so keeping it here is what makes the password actually substitute.
-- Idempotent (safe to re-run to rotate). :'authenticator_pw' already emits a correctly quoted
-- literal, so no format()/%L is needed.
alter role authenticator password :'authenticator_pw';

-- authenticator may become anon or authenticated based on the request's JWT role claim.
-- It is DELIBERATELY NOT granted service_role: in Phase 1 nothing on the request path may
-- reach a BYPASSRLS role, so even a (rejected-by-signature, but belt-and-braces) token
-- claiming role=service_role could not escalate. service_role exists only so migrations can
-- reference it; grant it to authenticator later, consciously, when edge functions arrive.
grant anon, authenticated to authenticator;

-- ---------------------------------------------------------------------------
-- Schemas
-- ---------------------------------------------------------------------------
create schema if not exists auth;
-- `private` is NEVER listed in PGRST_DB_SCHEMAS, so PostgREST cannot see it. Sensitive
-- columns live here where no policy can be wrong about them (PIPELINE-SETUP.md, move #3).
create schema if not exists private;

-- ---------------------------------------------------------------------------
-- JWT claim helpers
-- ---------------------------------------------------------------------------
-- PostgREST puts the validated JWT payload into the `request.jwt.claims` GUC for the
-- duration of each request. These helpers read it. `stable` (not `immutable`) because
-- the value changes per request; marked so the planner can still cache within a query.

create or replace function auth.jwt() returns jsonb
  language sql stable
  as $$
    select coalesce(
      nullif(current_setting('request.jwt.claims', true), ''),
      '{}'
    )::jsonb
  $$;

-- Ownership key. TEXT, because an Auth0 sub is not a uuid. Use this everywhere a row
-- is scoped to a user.
create or replace function auth.jwt_sub() returns text
  language sql stable
  as $$
    select nullif(auth.jwt() ->> 'sub', '')
  $$;

create or replace function auth.role() returns text
  language sql stable
  as $$
    select coalesce(nullif(auth.jwt() ->> 'role', ''), 'anon')
  $$;

-- Lock the helper functions down: they must not be a back door.
revoke all on function auth.jwt() from public;
revoke all on function auth.jwt_sub() from public;
revoke all on function auth.role() from public;
grant execute on function auth.jwt() to anon, authenticated;
grant execute on function auth.jwt_sub() to anon, authenticated;
grant execute on function auth.role() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Deny-by-default privileges
-- ---------------------------------------------------------------------------
-- PostgREST needs USAGE on the schema to resolve names, but that alone exposes no data
-- (every table is revoked + RLS-guarded). The unauthenticated role gets nothing.
grant usage on schema public to authenticated;
revoke all on schema public from anon;
revoke all on schema public from public;  -- drop the implicit PUBLIC grant too

-- Auth helpers live in `auth`; expose only USAGE, never table privileges.
grant usage on schema auth to anon, authenticated;

-- The rows below are DELIBERATELY NOT PRESENT. This is the supabase/postgres default we
-- are rejecting; leaving it out is what makes new tables inert until granted:
--   alter default privileges in schema public grant all on tables to anon, authenticated;
--   alter default privileges in schema public grant all on sequences to anon, authenticated;

-- Sanity: no request-path role may bypass RLS.
do $$
begin
  if exists (
    select 1 from pg_roles
    where rolname in ('anon', 'authenticated', 'authenticator') and rolbypassrls
  ) then
    raise exception 'A request-path role has BYPASSRLS; refusing to leave bootstrap in an unsafe state.';
  end if;
end $$;
