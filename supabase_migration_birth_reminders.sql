-- ============================================================================
--  Dolce+  —  DATE OF BIRTH + WHATSAPP CONFIRMATION / REMINDERS
--  Run this whole file once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Nothing is deleted.
-- ============================================================================
--  * clients.birth_date  — asked when a client creates their account.
--  * bookings.lang       — the app language the client booked in, so the
--                          WhatsApp message can be written in the same one.
--  * bookings.reminders  — which WhatsApp messages were sent (confirmation,
--                          12-hour and 1-hour reminders), so every device agrees.
--  * claim_my_client_account() now also takes the date of birth.
-- ============================================================================

alter table public.clients  add column if not exists birth_date date;
alter table public.bookings add column if not exists lang text not null default '';
alter table public.bookings add column if not exists reminders jsonb not null default '{}'::jsonb;

drop function if exists public.claim_my_client_account(text);
drop function if exists public.claim_my_client_account(text, text);

create or replace function public.claim_my_client_account(p_name text default null, p_phone text default null, p_birth date default null)
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
  -- A believable date of birth, or nothing.
  bd       date := case when p_birth between date '1910-01-01' and current_date then p_birth end;
begin
  if uid is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if public.is_staff() then
    raise exception 'This is a staff login' using errcode = '42501';
  end if;

  select regexp_replace(coalesce(u.phone, ''), '\D', '', 'g') into ph
    from auth.users u where u.id = uid and u.phone_confirmed_at is not null;
  -- Only an email proven by a login code counts: this session must have been
  -- started with an emailed code (Supabase records how in the token's "amr").
  -- An account made with a password (possible because "Confirm email" stays
  -- off for staff logins) never proves the address.
  select lower(btrim(coalesce(u.email, ''))) into em
    from auth.users u where u.id = uid and u.email_confirmed_at is not null
     and exists (select 1 from jsonb_array_elements(coalesce(auth.jwt()->'amr', '[]'::jsonb)) a
                  where a->>'method' in ('otp', 'magiclink', 'email/signup'));
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
        email = case when coalesce(btrim(email), '') = '' and em <> '' then em else email end,
        birth_date = coalesce(birth_date, bd)
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
             email = case when coalesce(btrim(email), '') = '' and em <> '' then em else email end,
             birth_date = coalesce(birth_date, bd)
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
    'insert into public.clients (id, phone, name, points, user_id, email, contact_phone, birth_date) values (%L, %L, %L, 0, %L, %L, %L, %L) returning id::text',
    gen_random_uuid()::text, nullif(ph, ''), nm, uid, em, given, bd)
  into found_id;
  return query select * from public.clients where id::text = found_id;
end;
$$;

revoke all on function public.claim_my_client_account(text, text, date) from public;
grant execute on function public.claim_my_client_account(text, text, date) to authenticated;

notify pgrst, 'reload schema';
