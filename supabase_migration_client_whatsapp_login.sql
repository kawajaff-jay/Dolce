-- ============================================================================
--  Dolce+  —  SECURITY FIX + CLIENT ACCOUNTS (WhatsApp login)
--  Run this whole file once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. It changes security rules only; no customer,
--  booking or staff data is removed.
-- ============================================================================
--
--  PART 1 — SECURITY FIX (needed today, even before WhatsApp login is live)
--
--  Until now the database treated "anyone who is logged in" as staff in a few
--  places. The app's public key (which is visible in the website's code, as
--  every Supabase app's is) can create a new login, so in principle a stranger
--  could create one and then:
--    * give themselves an owner profile            → full Admin access
--    * read the client list (names, phone numbers)
--    * change or delete photos in the media store
--  This part closes all three. "Staff" now means: has a staff profile, and
--  only the owner can create or promote a staff profile.
--
--  PART 2 — CLIENT ACCOUNTS
--
--  A client logs in with their phone number and a code sent on WhatsApp. Their
--  account can see ONLY their own client record and their own bookings
--  (bookings linked to them, or made with their verified phone number). They
--  can request a booking, change their name and delete their account. They
--  cannot see anyone else, change points, or touch anything staff use.
-- ============================================================================


-- ----------------------------------------------------------------------------
--  PART 1 — security fix
-- ----------------------------------------------------------------------------

-- Is the person logged in a member of staff? (Has a staff profile.)
create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid());
$$;
revoke all on function public.is_staff() from public;
grant execute on function public.is_staff() to anon, authenticated;

-- Only the owner can create a staff profile (the Employees tab already does
-- this while the owner is logged in, so nothing changes for you).
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert to authenticated
  with check (public.is_owner());

-- A staff member may still update their own profile row, but only the owner
-- can change who is owner, which departments and which sections someone has.
-- (Changes made from the SQL Editor are not affected.)
create or replace function public.guard_profile_permissions()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or public.is_owner() then
    return new;
  end if;
  if new.id         is distinct from old.id
  or new.is_owner   is distinct from old.is_owner
  or new.brands     is distinct from old.brands
  or new.tabs       is distinct from old.tabs
  or new.login_slug is distinct from old.login_slug then
    raise exception 'Only the owner can change staff permissions' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_guard_permissions on public.profiles;
create trigger profiles_guard_permissions before update on public.profiles
  for each row execute function public.guard_profile_permissions();

-- Client list: staff only (was: anyone logged in).
drop policy if exists clients_signup       on public.clients;
drop policy if exists clients_staff_insert on public.clients;
create policy clients_staff_insert on public.clients for insert to authenticated
  with check (public.is_staff());

drop policy if exists clients_staff_read on public.clients;
create policy clients_staff_read on public.clients for select to authenticated
  using (public.is_staff());

drop policy if exists clients_staff_write on public.clients;
create policy clients_staff_write on public.clients for update to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- The old demo login let a visitor create a client row directly. Real client
-- accounts are created by claim_my_client_account() below instead.
revoke insert on public.clients from anon;

-- Photo positions: staff only (was: anyone logged in). Other settings: owner.
drop policy if exists settings_write on public.settings;
create policy settings_write on public.settings for all to authenticated
  using ((key = 'image_focus' and public.is_staff()) or public.is_owner())
  with check ((key = 'image_focus' and public.is_staff()) or public.is_owner());

-- Photo & video store: anyone can view, only staff can add/change/delete.
drop policy if exists "media: staff upload" on storage.objects;
drop policy if exists "media: staff update" on storage.objects;
drop policy if exists "media: staff delete" on storage.objects;
create policy "media: staff upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'media' and public.is_staff());
create policy "media: staff update" on storage.objects
  for update to authenticated
  using (bucket_id = 'media' and public.is_staff())
  with check (bucket_id = 'media' and public.is_staff());
create policy "media: staff delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'media' and public.is_staff());


-- ----------------------------------------------------------------------------
--  PART 2 — client accounts
-- ----------------------------------------------------------------------------

alter table public.bookings add column if not exists client_phone text not null default '';

-- Which login owns this client record (empty for clients reception added who
-- have not logged in yet). If a login is deleted, the link is simply cleared.
alter table public.clients add column if not exists user_id uuid
  references auth.users(id) on delete set null;
create unique index if not exists clients_user_id_key on public.clients (user_id);

-- The logged-in client's VERIFIED phone number, last 10 digits (so
-- 0750 123 4567, 750 123 4567 and +964 750 123 4567 all match).
create or replace function public.my_phone10()
returns text
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select coalesce(
    (select right(regexp_replace(coalesce(u.phone, ''), '\D', '', 'g'), 10)
       from auth.users u
      where u.id = auth.uid() and u.phone_confirmed_at is not null),
    '');
$$;

create or replace function public.my_client_ids()
returns text[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(c.id), '{}'::text[]) from public.clients c
   where auth.uid() is not null and c.user_id = auth.uid();
$$;

revoke all on function public.my_phone10()    from public;
revoke all on function public.my_client_ids() from public;
grant execute on function public.my_phone10()    to authenticated;
grant execute on function public.my_client_ids() to authenticated;

-- A client can read their own client record (name, phone, points).
drop policy if exists clients_self_read on public.clients;
create policy clients_self_read on public.clients for select to authenticated
  using (user_id = auth.uid());

-- A client can read their own bookings: linked to their account, or made
-- with their verified phone number (e.g. before they had an account).
drop policy if exists bookings_client_read on public.bookings;
create policy bookings_client_read on public.bookings for select to authenticated
  using (
    client_id = any(public.my_client_ids())
    or (public.my_phone10() <> ''
        and right(regexp_replace(coalesce(client_phone, ''), '\D', '', 'g'), 10) = public.my_phone10())
  );

-- A logged-in client can REQUEST a booking for themselves (never a confirmed
-- one, never for someone else).
drop policy if exists bookings_client_request on public.bookings;
create policy bookings_client_request on public.bookings for insert to authenticated
  with check (
    not public.is_staff()
    and status = 'Requested'
    and (client_id is null or client_id = any(public.my_client_ids()))
  );

-- A visitor who is not logged in can still request a booking, but can no
-- longer attach it to somebody else's account.
drop policy if exists bookings_request on public.bookings;
create policy bookings_request on public.bookings for insert to anon
  with check (status = 'Requested' and client_id is null);


-- Called by the app right after a client logs in. Finds their client record
-- (by account, or by phone number if reception already added them) and links
-- it; creates one if they are new and gave a name. Returns the record, or an
-- empty result if a name is still needed.
create or replace function public.claim_my_client_account(p_name text default null)
returns setof public.clients
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  uid   uuid := auth.uid();
  ph    text;
  nm    text := left(nullif(btrim(coalesce(p_name, '')), ''), 80);
  found_id text;
begin
  if uid is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if public.is_staff() then
    raise exception 'This is a staff login' using errcode = '42501';
  end if;
  select regexp_replace(coalesce(u.phone, ''), '\D', '', 'g') into ph
    from auth.users u where u.id = uid and u.phone_confirmed_at is not null;
  if coalesce(length(ph), 0) < 8 then
    raise exception 'No verified phone number' using errcode = '42501';
  end if;

  -- Already linked?
  select c.id into found_id from public.clients c where c.user_id = uid limit 1;
  if found_id is not null then
    if nm is not null then
      update public.clients set name = nm, updated_at = now()
       where id = found_id and coalesce(btrim(name), '') = '';
    end if;
    return query select * from public.clients where id = found_id;
    return;
  end if;

  -- Added by reception with the same number, not linked to anyone yet?
  select c.id into found_id from public.clients c
   where c.user_id is null
     and right(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g'), 10) = right(ph, 10)
   order by c.created_at
   limit 1
   for update;
  if found_id is not null then
    update public.clients set user_id = uid, updated_at = now() where id = found_id;
    return query select * from public.clients where id = found_id;
    return;
  end if;

  -- Brand-new client: needs a name first.
  if nm is null then
    return;
  end if;
  insert into public.clients (id, phone, name, points, user_id)
  values ('cu' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 14), ph, nm, 0, uid)
  returning id into found_id;
  return query select * from public.clients where id = found_id;
end;
$$;

-- A client changing the name on their account.
create or replace function public.update_my_client_name(p_name text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare nm text := left(nullif(btrim(coalesce(p_name, '')), ''), 80);
begin
  if auth.uid() is null or nm is null then
    raise exception 'Name required' using errcode = '22023';
  end if;
  update public.clients set name = nm, updated_at = now() where user_id = auth.uid();
end;
$$;

-- "Delete my account" (required by Apple for any app with accounts).
-- Removes the client's login and their client record (name, phone, points).
-- Past bookings stay in the diary as business records but are no longer
-- linked to an account.
create or replace function public.delete_my_client_account()
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if public.is_staff() then
    raise exception 'Staff logins are removed by the owner' using errcode = '42501';
  end if;
  update public.bookings set client_id = null
   where client_id in (select id from public.clients where user_id = uid);
  delete from public.clients where user_id = uid;
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.claim_my_client_account(text) from public;
revoke all on function public.update_my_client_name(text)   from public;
revoke all on function public.delete_my_client_account()    from public;
grant execute on function public.claim_my_client_account(text) to authenticated;
grant execute on function public.update_my_client_name(text)   to authenticated;
grant execute on function public.delete_my_client_account()    to authenticated;

-- The on/off switch for client login lives in the settings table under the
-- key 'client_login' ('on' / 'off'). Owner-only to change (rule above).
insert into public.settings (key, value) values ('client_login', 'off')
  on conflict (key) do nothing;

notify pgrst, 'reload schema';

-- ---- Quick check (optional): should list the new rules --------------------
-- select tablename, policyname from pg_policies
--  where policyname in ('clients_self_read','bookings_client_read',
--                       'bookings_client_request','profiles_insert');
