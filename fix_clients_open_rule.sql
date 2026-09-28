-- Dolce+ security fix: close the old "staff manage clients" rule.
-- It let ANY logged-in account (not only staff) read, change and delete the
-- client list. Staff keep full access through the newer staff-only rules.
-- Safe to run more than once.

drop policy if exists "staff manage clients" on public.clients;

-- Deleting a client record: owner only (staff can still add and edit).
drop policy if exists clients_owner_delete on public.clients;
create policy clients_owner_delete on public.clients for delete to authenticated
  using (public.is_owner());

notify pgrst, 'reload schema';

-- Check: this should now list only the staff-only rules and the client's own rule.
select policyname, cmd from pg_policies
 where schemaname = 'public' and tablename = 'clients'
 order by policyname;
