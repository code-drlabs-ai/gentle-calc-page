-- Allow users to clear their own calculation history.
--
-- Small feature: a "Clear history" button needs DELETE access, scoped to the caller's
-- own rows only. Insert remains column-scoped; select policy is unchanged.

grant delete on public.calculations to authenticated;

drop policy if exists "calculations_delete_own" on public.calculations;
create policy "calculations_delete_own"
  on public.calculations
  for delete
  to authenticated
  using (user_id = auth.jwt_sub());
