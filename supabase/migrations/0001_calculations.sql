-- Per-user calculation history.
--
-- Identity is Auth0 (PKCE). PostgREST validates each request's Auth0 access token against
-- Auth0's JWKS and exposes the claims via the helpers created in db/bootstrap/000_bootstrap.sql.
-- The caller is `auth.jwt_sub()` (the Auth0 subject, TEXT — an Auth0 sub is not a uuid).
--
-- This migration follows the six hardening moves in PIPELINE-SETUP.md:
--   #1 deny-by-default (grants are explicit and minimal, below)
--   #2 RLS enabled AND forced
--   #4 column-level grants (client may write only expression/result)
--   #5 server-authoritative ownership (user_id defaults from the token, re-checked)
-- History is append-only: no UPDATE or DELETE grant, and no UPDATE/DELETE policy.

create extension if not exists "pgcrypto";

create table if not exists public.calculations (
  id uuid primary key default gen_random_uuid(),
  -- Defaulted from the verified token, never from client input.
  user_id text not null default auth.jwt_sub(),
  expression text not null,
  result text not null,
  created_at timestamptz not null default now(),

  constraint calculations_expression_length check (char_length(expression) between 1 and 200),
  constraint calculations_result_length check (char_length(result) between 1 and 100),
  constraint calculations_user_id_not_blank check (char_length(user_id) > 0)
);

create index if not exists calculations_user_id_created_at_idx
  on public.calculations (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- #2 RLS: enable AND force. `force` matters — without it the table owner bypasses
-- RLS, which is the self-hosted footgun that fails OPEN. rls_gate.sql checks for it.
-- ---------------------------------------------------------------------------
alter table public.calculations enable row level security;
alter table public.calculations force row level security;

-- ---------------------------------------------------------------------------
-- #1 + #4 Grants: explicit, minimal, column-scoped. anon gets nothing.
-- The table is inert until these lines run — that is the review gate.
-- ---------------------------------------------------------------------------
revoke all on public.calculations from anon, authenticated, public;

-- Read is row-scoped by the policy below. Write is restricted to two columns, so even a
-- careless future policy cannot let a client set user_id/created_at/id directly.
grant select on public.calculations to authenticated;
grant insert (expression, result) on public.calculations to authenticated;

-- ---------------------------------------------------------------------------
-- Policies. #5 ownership is server-authoritative on both read and write.
-- ---------------------------------------------------------------------------
drop policy if exists "calculations_select_own" on public.calculations;
create policy "calculations_select_own"
  on public.calculations
  for select
  to authenticated
  using (user_id = auth.jwt_sub());

drop policy if exists "calculations_insert_own" on public.calculations;
create policy "calculations_insert_own"
  on public.calculations
  for insert
  to authenticated
  -- Re-checks the token-defaulted value; an explicit user_id in the body can't forge it
  -- (and the missing INSERT grant on user_id blocks setting it at all).
  with check (user_id = auth.jwt_sub());

-- No UPDATE/DELETE policy and no UPDATE/DELETE grant: history is append-only.
