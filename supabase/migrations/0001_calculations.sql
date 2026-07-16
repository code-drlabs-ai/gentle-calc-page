-- Per-user calculation history.
--
-- Identity model: authentication is Auth0, not Supabase Auth. Supabase is configured to
-- trust the Auth0 tenant as a third-party OIDC issuer (see PIPELINE-SETUP.md, Part 7) and
-- validates each request's bearer token against Auth0's JWKS. The caller's identity is
-- therefore the Auth0 subject, read as `auth.jwt() ->> 'sub'`.
--
-- Why not auth.uid(): auth.uid() casts the `sub` claim to uuid. Auth0 subjects look like
-- `auth0|65f...` or `google-oauth2|1027...`, which are not uuids, so auth.uid() errors or
-- returns null. The subject is stored as text and compared as text throughout.
--
-- PREREQUISITE: the Auth0 access token must carry `role: authenticated`, added by a Login
-- Action in the Auth0 tenant. Without it Supabase treats the caller as `anon`, every policy
-- below fails closed, and the app sees empty history rather than someone else's data.

create extension if not exists "pgcrypto";

create table if not exists public.calculations (
  id uuid primary key default gen_random_uuid(),
  -- Defaulted from the verified token, never from client input. An INSERT that omits
  -- user_id is attributed to the caller; one that forges it is rejected by the WITH CHECK
  -- on the insert policy below.
  user_id text not null default (auth.jwt() ->> 'sub'),
  expression text not null,
  result text not null,
  created_at timestamptz not null default now(),

  -- Bound the columns so a compromised or buggy client cannot write unbounded blobs.
  constraint calculations_expression_length check (char_length(expression) between 1 and 200),
  constraint calculations_result_length check (char_length(result) between 1 and 100),
  constraint calculations_user_id_not_blank check (char_length(user_id) > 0)
);

-- History is read newest-first, scoped to one user.
create index if not exists calculations_user_id_created_at_idx
  on public.calculations (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
-- The anon key is embedded in a public browser bundle, so RLS is the ONLY thing standing
-- between the internet and this table. Default deny: enabling RLS with no matching policy
-- rejects every row.
alter table public.calculations enable row level security;

-- FORCE applies RLS to the table owner too, so a future SECURITY DEFINER function or an
-- owner-context connection cannot accidentally bypass these policies.
alter table public.calculations force row level security;

-- Start from zero: revoke the blanket grants PostgREST roles inherit from the public schema.
revoke all on public.calculations from anon, authenticated;

-- Signed-in users may read and append; no UPDATE or DELETE grant is issued, which makes the
-- history append-only at the privilege level as well as the policy level.
grant select, insert on public.calculations to authenticated;

-- `anon` (a request with no valid Auth0 token) gets nothing at all.

drop policy if exists "calculations_select_own" on public.calculations;
create policy "calculations_select_own"
  on public.calculations
  for select
  to authenticated
  using (user_id = auth.jwt() ->> 'sub');

drop policy if exists "calculations_insert_own" on public.calculations;
create policy "calculations_insert_own"
  on public.calculations
  for insert
  to authenticated
  -- Re-checks the defaulted value, so an explicit user_id in the request body cannot
  -- attribute a row to another subject.
  with check (user_id = auth.jwt() ->> 'sub');

-- No UPDATE or DELETE policies are defined. With RLS enabled and no policy, those
-- statements match zero rows regardless of the grants above.
