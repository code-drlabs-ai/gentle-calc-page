-- =============================================================================
-- rls_gate.sql — CI gate. Run with `psql -v ON_ERROR_STOP=1` against each Azure
-- Postgres BEFORE deploying the app. Any raised exception fails the pipeline.
--
-- This is worth more than any by-hand policy review: it makes "Lovable added a
-- table and RLS was forgotten" fail loudly in CI instead of silently in prod.
-- =============================================================================

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- 1. Every exposed base table must have RLS enabled AND forced.
--    (force matters: without it the owner connection bypasses RLS — fails open.)
-- ---------------------------------------------------------------------------
do $$
declare bad text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'r'
    and (not c.relrowsecurity or not c.relforcerowsecurity);
  if bad is not null then
    raise exception 'RLS not enabled AND forced on public table(s): %', bad;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Any table readable/writable by `authenticated` must carry at least one policy.
--    A grant with zero policies + forced RLS returns nothing, but it signals a
--    half-configured table, so we reject it rather than ship ambiguity.
--    Column-level grants count: has_table_privilege is table-wide, so we also probe
--    per-column INSERT/UPDATE via pg_attribute to catch column-only grants.
-- ---------------------------------------------------------------------------
do $$
declare bad text;
begin
  select string_agg(t.relname, ', ' order by t.relname) into bad
  from pg_class t
  join pg_namespace n on n.oid = t.relnamespace
  left join pg_policy p on p.polrelid = t.oid
  where n.nspname = 'public'
    and t.relkind = 'r'
    and (
      has_table_privilege('authenticated', t.oid, 'SELECT')
      or has_table_privilege('authenticated', t.oid, 'INSERT')
      or has_table_privilege('authenticated', t.oid, 'UPDATE')
      or has_table_privilege('authenticated', t.oid, 'DELETE')
      or exists (
        select 1 from pg_attribute a
        where a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
          and (
            has_column_privilege('authenticated', t.oid, a.attname, 'INSERT')
            or has_column_privilege('authenticated', t.oid, a.attname, 'UPDATE')
          )
      )
    )
  group by t.relname
  having count(p.oid) = 0;
  if bad is not null then
    raise exception 'Granted to authenticated but NO policy defined: %', bad;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. No request-path role may bypass RLS.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (
    select 1 from pg_roles
    where rolname in ('anon', 'authenticated', 'authenticator') and rolbypassrls
  ) then
    raise exception 'A request-path role has BYPASSRLS.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. anon must not hold table privileges anywhere in public.
-- ---------------------------------------------------------------------------
do $$
declare bad text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'r'
    and (
      has_table_privilege('anon', c.oid, 'SELECT')
      or has_table_privilege('anon', c.oid, 'INSERT')
      or has_table_privilege('anon', c.oid, 'UPDATE')
      or has_table_privilege('anon', c.oid, 'DELETE')
    );
  if bad is not null then
    raise exception 'anon holds privileges on public table(s): %', bad;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. The `private` schema must never be reachable by request-path roles.
-- ---------------------------------------------------------------------------
do $$
begin
  if has_schema_privilege('anon', 'private', 'USAGE')
     or has_schema_privilege('authenticated', 'private', 'USAGE') then
    raise exception 'private schema is reachable by a request-path role.';
  end if;
end $$;

\echo 'rls_gate: OK'
