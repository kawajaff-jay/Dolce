-- ============================================================================
--  Dolce+  —  CLIENTS CHOOSE: LOG IN WITH WHATSAPP OR EMAIL (one account)
--  Run this whole file once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
--  (It replaces supabase_migration_whatsapp_one_account.sql — you do not
--  need to run that one as well. Running both does no harm.)
-- ============================================================================
--  What it does
--  * One client record can now have TWO ways in: a WhatsApp number and an
--    email address. Both open the same name, points, bookings and history.
--  * Logging in with WhatsApp continues an existing account that has the same
--    phone number (reception record, or an account first made by email).
--  * Logging in by email and typing a number that already has an account
--    does NOT create a duplicate. The app asks for a WhatsApp code to that
--    number first; once both are proven on the same phone, the email is
--    added to the existing account.
--  * Tidies up empty duplicates already made (0 points, no bookings, no
--    points history, and an older account with the same number exists).
--
--  Safety rules kept
--  * A typed (unproven) phone number never opens anyone's account.
--  * An email login only joins an account after a WhatsApp code to that
--    account's number was entered on the same phone within 20 minutes.
-- ============================================================================

-- ---- Extra logins for a client record ---------------------------------------
create table if not exists public.client_logins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  client_id  text not null,
  created_at timestamptz not null default now()
);
alter table public.client_logins enable row level security;
revoke all on public.client_logins from anon, authenticated;

-- Short-lived proof that an email login asked to join a phone's account.
create table if not exists public.link_tickets (
  ticket     text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.link_tickets enable row level security;
revoke all on public.link_tickets from anon, authenticated;

-- ---- Which client records belong to the person logged in --------------------
create or replace function public.my_client_ids()
returns text[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(distinct x.id), '{}'::text[]) from (
    select c.id::text as id from public.clients c
     where auth.uid() is not null and c.user_id = auth.uid()
    union
    select l.client_id from public.client_logins l
     where auth.uid() is not null and l.user_id = auth.uid()
  ) x;
$$;
revoke all on function public.my_client_ids() from public;
grant execute on function public.my_client_ids() to authenticated;

drop policy if exists clients_self_read on public.clients;
create policy clients_self_read on public.clients for select to authenticated
  using (id::text = any(public.my_client_ids()));

-- ---- Email login: ask to join the account of a phone number -----------------
create or replace function public.create_link_ticket()
returns text
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  uid uuid := auth.uid();
  t   text;
begin
  if uid is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if public.is_staff() then
    raise exception 'This is a staff login' using errcode = '42501';
  end if;
  -- Only a login proven by an emailed code, with no account of its own yet.
  if not exists (select 1 from auth.users u where u.id = uid and u.email_confirmed_at is not null)
     or not exists (select 1 from jsonb_array_elements(coalesce(auth.jwt()->'amr', '[]'::jsonb)) a
                     where a->>'method' in ('otp', 'magiclink', 'email/signup')) then
    raise exception 'Email not verified' using errcode = '42501';
  end if;
  if exists (select 1 from public.clients c where c.id::text = any(public.my_client_ids())) then
    raise exception 'Already has an account' using errcode = '42501';
  end if;
  delete from public.link_tickets where user_id = uid or created_at < now() - interval '1 day';
  t := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.link_tickets (ticket, user_id) values (t, uid);
  return t;
end;
$$;
revoke all on function public.create_link_ticket() from public;
grant execute on function public.create_link_ticket() to authenticated;

-- ---- Log in: find (or create) the client record ------------------------------
drop function if exists public.claim_my_client_account(text);
drop function if exists public.claim_my_client_account(text, text);
drop function if exists public.claim_my_client_account(text, text, date);

create or replace function public.claim_my_client_account(
  p_name text default null, p_phone text default null, p_birth date default null, p_ticket text default null)
returns setof public.clients
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  uid      uuid := auth.uid();
  ph       text;   -- verified phone (WhatsApp login), digits only
  em       text;   -- verified email (email login), lower case
  given    text := left(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 15);
  nm       text := left(nullif(btrim(coalesce(p_name, '')), ''), 80);
  bd       date := case when p_birth between date '1910-01-01' and current_date then p_birth end;
  found_id text;
  owner    uuid;
  t_user   uuid;   -- email login that asked (on this phone) to join this account
  mode     text;
begin
  if uid is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if public.is_staff() then
    raise exception 'This is a staff login' using errcode = '42501';
  end if;

  select regexp_replace(coalesce(u.phone, ''), '\D', '', 'g') into ph
    from auth.users u where u.id = uid and u.phone_confirmed_at is not null;
  -- Only an email proven by a login code counts (see "amr" in the token).
  select lower(btrim(coalesce(u.email, ''))) into em
    from auth.users u where u.id = uid and u.email_confirmed_at is not null
     and exists (select 1 from jsonb_array_elements(coalesce(auth.jwt()->'amr', '[]'::jsonb)) a
                  where a->>'method' in ('otp', 'magiclink', 'email/signup'));
  ph := coalesce(ph, ''); em := coalesce(em, '');
  if length(given) < 8 then given := ''; end if;
  if length(ph) < 8 and em = '' then
    raise exception 'No verified phone number or email' using errcode = '42501';
  end if;
  select trim(both '"' from s.value::text) into mode from public.settings s where s.key = 'client_login';

  -- A link ticket only counts for a WhatsApp login, once, within 20 minutes.
  if p_ticket is not null and length(ph) >= 8 then
    select lt.user_id into t_user from public.link_tickets lt
     where lt.ticket = p_ticket and lt.created_at > now() - interval '20 minutes';
    delete from public.link_tickets where ticket = p_ticket;
    if t_user = uid then t_user := null; end if;
  end if;

  -- 1. Already linked to this login?
  select c.id::text into found_id from public.clients c where c.user_id = uid limit 1;
  if found_id is null then
    select l.client_id into found_id from public.client_logins l
     where l.user_id = uid and exists (select 1 from public.clients c where c.id::text = l.client_id);
  end if;
  if found_id is not null then
    update public.clients set
        name  = case when coalesce(btrim(name), '') = '' and nm is not null then nm else name end,
        contact_phone = case when given <> '' then given else contact_phone end,
        email = case when coalesce(btrim(email), '') = '' and em <> '' then em else email end,
        birth_date = coalesce(birth_date, bd)
     where id::text = found_id;

  elsif length(ph) >= 8 then
    -- 2. WhatsApp: a record reception already added with this number?
    select c.id::text into found_id from public.clients c
     where c.user_id is null
       and right(regexp_replace(coalesce(c.phone::text, ''), '\D', '', 'g'), 10) = right(ph, 10)
     limit 1
     for update;
    if found_id is not null then
      update public.clients set user_id = uid, birth_date = coalesce(birth_date, bd)
       where id::text = found_id;
    else
      -- 3. WhatsApp: an account first made by EMAIL with this number.
      --    WhatsApp proves the number, so this login takes the account over.
      --    The email login keeps access only if it proved itself on this
      --    phone (ticket); otherwise it is removed from the account.
      select c.id::text, c.user_id into found_id, owner from public.clients c
        join auth.users o on o.id = c.user_id
       where c.user_id <> uid
         and o.phone_confirmed_at is null
         and (right(regexp_replace(coalesce(c.phone::text, ''), '\D', '', 'g'), 10) = right(ph, 10)
              or right(regexp_replace(coalesce(c.contact_phone, ''), '\D', '', 'g'), 10) = right(ph, 10))
       order by c.points desc nulls last, c.created_at desc nulls last
       limit 1
       for update of c;
      if found_id is not null then
        if t_user is not null and t_user = owner then
          insert into public.client_logins (user_id, client_id) values (owner, found_id)
            on conflict (user_id) do update set client_id = excluded.client_id;
        else
          delete from public.client_logins l
           where l.client_id = found_id
             and l.user_id in (select u.id from auth.users u where u.phone_confirmed_at is null);
          update public.clients set email = '' where id::text = found_id;
        end if;
        update public.clients c set user_id = uid,
               phone = case when c.phone is null
                             and not exists (select 1 from public.clients x where x.phone::text = ph and x.id::text <> found_id)
                            then ph else c.phone end,
               birth_date = coalesce(c.birth_date, bd)
         where c.id::text = found_id;
      end if;
    end if;
  end if;

  -- 4. Brand-new client: needs a name first (and, by email, a phone number).
  if found_id is null then
    if nm is null then return; end if;
    if length(ph) < 8 and given = '' then return; end if;
    -- Email login typing a number that already has an account: no duplicate.
    -- The app then confirms the number with a WhatsApp code.
    if length(ph) < 8 and mode = 'both' and exists (
         select 1 from public.clients c
          where right(regexp_replace(coalesce(c.phone::text, ''), '\D', '', 'g'), 10) = right(given, 10)
             or right(regexp_replace(coalesce(c.contact_phone, ''), '\D', '', 'g'), 10) = right(given, 10)) then
      raise exception 'PHONE_IN_USE' using errcode = 'P0001';
    end if;
    execute format(
      'insert into public.clients (id, phone, name, points, user_id, email, contact_phone, birth_date) values (%L, %L, %L, 0, %L, %L, %L, %L) returning id::text',
      gen_random_uuid()::text, nullif(ph, ''), nm, uid, em, given, bd)
    into found_id;
  end if;

  -- 5. The email login that asked on this phone joins the account.
  if t_user is not null and found_id is not null
     and not exists (select 1 from public.clients c where c.user_id = t_user) then
    insert into public.client_logins (user_id, client_id) values (t_user, found_id)
      on conflict (user_id) do update set client_id = excluded.client_id;
    update public.clients set email = coalesce(nullif(btrim(email), ''),
             (select lower(btrim(coalesce(u.email, ''))) from auth.users u where u.id = t_user))
     where id::text = found_id;
  end if;

  return query select * from public.clients where id::text = found_id;
end;
$$;
revoke all on function public.claim_my_client_account(text, text, date, text) from public;
grant execute on function public.claim_my_client_account(text, text, date, text) to authenticated;

-- ---- Change my name / delete my account (cover every way in) ----------------
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
  update public.clients set name = nm where id::text = any(public.my_client_ids());
end;
$$;

-- Removes the client record and EVERY login attached to it (WhatsApp and
-- email). Past bookings stay in the diary but are no longer linked.
create or replace function public.delete_my_client_account()
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  uid uuid := auth.uid();
  ids text[];
  logins uuid[];
begin
  if uid is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if public.is_staff() then
    raise exception 'Staff logins are removed by the owner' using errcode = '42501';
  end if;
  ids := public.my_client_ids();
  select coalesce(array_agg(distinct x), '{}') into logins from (
    select uid as x
    union select c.user_id from public.clients c where c.id::text = any(ids) and c.user_id is not null
    union select l.user_id from public.client_logins l where l.client_id = any(ids)
  ) s;
  update public.bookings set client_id = null where client_id::text = any(ids);
  delete from public.client_logins where client_id = any(ids) or user_id = any(logins);
  delete from public.clients where id::text = any(ids);
  delete from auth.users u where u.id = any(logins)
     and not exists (select 1 from public.profiles p where p.id = u.id);
end;
$$;
revoke all on function public.update_my_client_name(text) from public;
revoke all on function public.delete_my_client_account() from public;
grant execute on function public.update_my_client_name(text) to authenticated;
grant execute on function public.delete_my_client_account() to authenticated;

-- ---- Tidy up empty duplicates already created --------------------------------
delete from public.clients y
 using auth.users u
 where u.id = y.user_id
   and u.phone_confirmed_at is not null
   and coalesce(y.points, 0) = 0
   and not exists (select 1 from public.bookings b where b.client_id::text = y.id::text)
   and not exists (select 1 from public.point_transactions p where p.client_id = y.id::text)
   and exists (
     select 1 from public.clients x
       join auth.users o on o.id = x.user_id
      where x.id::text <> y.id::text
        and o.phone_confirmed_at is null
        and (right(regexp_replace(coalesce(x.phone::text, ''), '\D', '', 'g'), 10) = right(regexp_replace(u.phone, '\D', '', 'g'), 10)
             or right(regexp_replace(coalesce(x.contact_phone, ''), '\D', '', 'g'), 10) = right(regexp_replace(u.phone, '\D', '', 'g'), 10)));

notify pgrst, 'reload schema';
