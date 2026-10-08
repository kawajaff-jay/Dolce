-- ============================================================================
--  Dolce+  —  CLIENT LOGIN BY EMAIL (interim, while WhatsApp waits for Meta)
--  Run this whole file once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Nothing is deleted.
--  Needs supabase_migration_client_whatsapp_login.sql to have been run first
--  (it was, in September).
-- ============================================================================
--
--  What changes
--  * A client can now log in with a 6-digit code sent to their EMAIL, as well
--    as (later) with a WhatsApp code.
--  * Email clients give a phone number for their appointments. That number is
--    NOT verified, so it is only stored on their record — it never links them
--    to a record reception made, and never shows them bookings made under
--    that number. (Only a verified WhatsApp login can do that.)
--  * Each client record can hold the email address they log in with.
-- ============================================================================

alter table public.clients add column if not exists email text not null default '';
-- The number an email client gave for their appointments (not verified).
alter table public.clients add column if not exists contact_phone text not null default '';
-- An email client's record has no verified "phone": the number they typed is
-- kept in contact_phone only. (Two people may type the same number, and a
-- reception record may already use it — "phone" must stay unique.)
alter table public.clients alter column phone drop not null;

-- The old one-argument version is replaced by this two-argument one. Apps that
-- still call it with only a name keep working (the phone has a default).
drop function if exists public.claim_my_client_account(text);

create or replace function public.claim_my_client_account(p_name text default null, p_phone text default null)
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
  -- Only an email proven by a login code counts. An account made with a
  -- password (possible because "Confirm email" stays off for staff logins)
  -- never proves the address, so it cannot become a client account.
  select lower(btrim(coalesce(u.email, ''))) into em
    from auth.users u where u.id = uid and u.email_confirmed_at is not null
     and coalesce(u.encrypted_password, '') = '';
  ph := coalesce(ph, ''); em := coalesce(em, '');
  if length(given) < 8 then given := ''; end if;

  if length(ph) < 8 and em = '' then
    raise exception 'No verified phone number or email' using errcode = '42501';
  end if;

  -- Already linked?
  select c.id::text into found_id from public.clients c where c.user_id = uid limit 1;
  if found_id is not null then
    update public.clients set
        name  = case when coalesce(btrim(name), '') = '' and nm is not null then nm else name end,
        contact_phone = case when given <> '' then given else contact_phone end,
        email = case when coalesce(btrim(email), '') = '' and em <> '' then em else email end
     where id::text = found_id;
    return query select * from public.clients where id::text = found_id;
    return;
  end if;

  -- Verified WhatsApp number that reception already added? (Email logins
  -- never take this path: their phone number is not verified.)
  if length(ph) >= 8 then
    select c.id::text into found_id from public.clients c
     where c.user_id is null
       and right(regexp_replace(coalesce(c.phone::text, ''), '\D', '', 'g'), 10) = right(ph, 10)
     limit 1
     for update;
    if found_id is not null then
      update public.clients set user_id = uid,
             email = case when coalesce(btrim(email), '') = '' and em <> '' then em else email end
       where id::text = found_id;
      return query select * from public.clients where id::text = found_id;
      return;
    end if;
  end if;

  -- Brand-new client: needs a name first (and, by email, a phone number).
  if nm is null then
    return;
  end if;
  if length(ph) < 8 and given = '' then
    return;
  end if;
  execute format(
    'insert into public.clients (id, phone, name, points, user_id, email, contact_phone) values (%L, %L, %L, 0, %L, %L, %L) returning id::text',
    gen_random_uuid()::text, nullif(ph, ''), nm, uid, em, given)
  into found_id;
  return query select * from public.clients where id::text = found_id;
end;
$$;

revoke all on function public.claim_my_client_account(text, text) from public;
grant execute on function public.claim_my_client_account(text, text) to authenticated;

notify pgrst, 'reload schema';

-- ---- Quick check (optional) ------------------------------------------------
-- select pg_get_function_arguments('public.claim_my_client_account'::regproc);
-- → should show: p_name text DEFAULT NULL::text, p_phone text DEFAULT NULL::text
