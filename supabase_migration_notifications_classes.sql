-- ============================================================================
--  Dolce+  —  AUTOMATIC MESSAGES, REMINDERS, ADMIN RESCHEDULE, CORE CLASSES
--  FOR REVIEW. Run once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Deletes no data and sends nothing by itself:
--  everything new starts SWITCHED OFF until the owner fills in the settings.
-- ============================================================================
--  1. Fix: two guests / clients could book the same slot again (the slot check
--     was skipped since the launch-decisions update). Restored.
--  2. notifications — one row per automatic message (cancellation, new time,
--     reminder). Status: scheduled → sending → sent / failed, or cancelled /
--     skipped. One message per event (unique key), reminders are cancelled or
--     re-planned when a booking is cancelled or moved. Messages are written
--     by the database in the same step as the change, so a cancellation
--     message only exists once the cancellation is saved.
--     The sending itself is done by the Edge Function "notify-dispatch",
--     started every few minutes by the database (supabase_cron_notifications.sql).
--  3. staff_reschedule_booking() — admin "change time" checked on the server:
--     service length, opening hours, overlapping bookings. Nothing changes if
--     the check fails; who changed it and old/new times are logged.
--  4. Core weekly group classes: class_schedules (the weekly timetable),
--     class_sessions (dated classes, Erbil time), class_reservations (places).
--     Capacity and "one place per client" are enforced by the database.
--  Settings (Admin → Settings, owner only; all OFF / empty until filled in):
--     notifications   {"enabled":false,"channel":"whatsapp|push|both",
--                      "reminders_min":[],"cancel":true,"moved":true,
--                      "wa_templates":{"cancel":"","moved":"","reminder":""},
--                      "wa_langs":"en"}
--     core_classes    {"enabled":false}
-- ============================================================================

create extension if not exists pgcrypto;

-- The role of the request (anon / authenticated / service_role, or 'none' in
-- the SQL editor). Unlike current_user it is not changed inside
-- "security definer" functions.
create or replace function public.request_role()
returns text language sql stable as $$
  select coalesce(nullif(current_setting('role', true), ''), 'none');
$$;

-- ---- 1. Restore the one-booking-per-slot check for client / guest bookings ----
create or replace function public.booking_request_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- Staff, the SQL editor and the server decide for themselves.
  if public.is_staff() or public.request_role() not in ('anon', 'authenticated') then
    return new;
  end if;
  new.status := 'Requested';
  new.reminders := '{}'::jsonb;
  if coalesce(new.time_label, '') = '' then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtext('booking-slot:' || coalesce(new.brand, '') || ':' ||
           coalesce(new.date_iso::text, new.date_label, '') || ':' || new.time_label));
  if exists (
    select 1 from public.bookings b
     where b.id <> new.id
       and b.brand = new.brand
       and b.status not in ('Cancelled', 'No-show')
       and (b.time_label = new.time_label or (new.time_of_day is not null and b.time_of_day = new.time_of_day))
       and (case when new.date_iso is not null and b.date_iso is not null
                 then b.date_iso = new.date_iso
                 else b.date_label = new.date_label end)
  ) then
    raise exception 'SLOT_TAKEN' using errcode = '23P01',
      hint = 'That time was just booked by someone else.';
  end if;
  return new;
end; $$;

-- ============================================================================
--  2. AUTOMATIC MESSAGES
-- ============================================================================
create table if not exists public.notifications (
  id            uuid primary key default gen_random_uuid(),
  ref_type      text not null check (ref_type in ('booking', 'class')),
  ref_id        text not null,                 -- booking id, or class reservation id
  brand         text not null,
  kind          text not null check (kind in ('cancel', 'moved', 'reminder')),
  offset_min    int,                           -- reminders: minutes before the start
  to_phone      text not null default '',
  client_id     text,
  lang          text not null default '',
  payload       jsonb not null default '{}'::jsonb,   -- name, service, date, time, start_at, old_*
  scheduled_at  timestamptz not null default now(),
  status        text not null default 'scheduled'
                check (status in ('scheduled', 'sending', 'sent', 'failed', 'cancelled', 'skipped')),
  attempts      int not null default 0,
  last_error    text not null default '',
  sent_via      text not null default '',     -- whatsapp / push / manual
  provider_ref  text not null default '',
  sent_at       timestamptz,
  dedupe_key    text not null unique,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists notifications_due_idx on public.notifications (status, scheduled_at);
create index if not exists notifications_ref_idx on public.notifications (ref_type, ref_id);
alter table public.notifications enable row level security;
drop policy if exists notifications_staff_read on public.notifications;
create policy notifications_staff_read on public.notifications for select to authenticated
  using (public.is_staff() and public.can_brand(brand)
         and (public.has_tab('bookings') or (ref_type = 'class' and public.has_tab('classes'))));
-- No direct writes: rows are made by the database and changed through the
-- functions below.

-- Phones registered for push notifications (installed app only).
create table if not exists public.push_devices (
  token      text primary key,
  platform   text not null default 'ios' check (platform in ('ios', 'android')),
  user_id    uuid,
  client_id  text,
  lang       text not null default '',
  created_at timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);
create index if not exists push_devices_client_idx on public.push_devices (client_id);
alter table public.push_devices enable row level security;
-- No policies: only register_push_device() and the server touch this table.

create or replace function public.register_push_device(p_token text, p_platform text default 'ios', p_lang text default '')
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare cid text;
begin
  if auth.uid() is null or public.is_staff() then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if coalesce(length(p_token), 0) not between 20 and 400 then raise exception 'BAD_TOKEN' using errcode = '22023'; end if;
  select c.id::text into cid from public.clients c where c.user_id = auth.uid() limit 1;
  if cid is null then cid := (public.my_client_ids())[1]; end if;
  insert into public.push_devices (token, platform, user_id, client_id, lang)
  values (p_token, case when p_platform = 'android' then 'android' else 'ios' end, auth.uid(), cid, left(coalesce(p_lang, ''), 5))
  on conflict (token) do update set user_id = excluded.user_id, client_id = excluded.client_id,
     lang = excluded.lang, platform = excluded.platform, last_seen = now();
end; $$;
revoke all on function public.register_push_device(text, text, text) from public;
grant execute on function public.register_push_device(text, text, text) to authenticated;

create or replace function public.notif_cfg()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select public.setting_json('notifications');
$$;
create or replace function public.notif_on()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((public.notif_cfg()->>'enabled')::boolean, false)
     and coalesce(public.notif_cfg()->>'channel', '') in ('whatsapp', 'push', 'both');
$$;

-- Minutes from text like "50 min", "1 hr", "1h 30m", "45". null when unreadable.
create or replace function public.duration_minutes(t text)
returns int language plpgsql immutable as $$
declare s text := lower(coalesce(t, '')); h numeric := 0; m numeric := 0; x text[];
begin
  x := regexp_match(s, '(\d+(?:\.\d+)?)\s*(h|hr|hrs|hour|hours)\y');
  if x is not null then h := x[1]::numeric; end if;
  x := regexp_match(s, '(\d+)\s*(m|min|mins|minute|minutes)\y');
  if x is not null then m := x[1]::numeric; end if;
  if h = 0 and m = 0 then
    x := regexp_match(s, '^\s*(\d{1,3})\s*$');
    if x is not null then m := x[1]::numeric; end if;
  end if;
  if h * 60 + m between 5 and 600 then return (h * 60 + m)::int; end if;
  return null;
end; $$;

create or replace function public.queue_notification(
  p_ref_type text, p_ref_id text, p_brand text, p_kind text, p_offset int, p_at timestamptz,
  p_phone text, p_client text, p_lang text, p_payload jsonb, p_key text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.notifications (ref_type, ref_id, brand, kind, offset_min, scheduled_at, to_phone,
                                    client_id, lang, payload, dedupe_key)
  values (p_ref_type, p_ref_id, p_brand, p_kind, p_offset, p_at, coalesce(p_phone, ''), p_client,
          coalesce(p_lang, ''), coalesce(p_payload, '{}'::jsonb), p_key)
  on conflict (dedupe_key) do update
     set status = 'scheduled', attempts = 0, last_error = '', scheduled_at = excluded.scheduled_at,
         payload = excluded.payload, to_phone = excluded.to_phone, lang = excluded.lang, updated_at = now()
   where public.notifications.status = 'cancelled';   -- a reminder brought back; never a second send
end; $$;
revoke all on function public.queue_notification(text, text, text, text, int, timestamptz, text, text, text, jsonb, text) from public;

create or replace function public.cancel_reminders(p_ref_type text, p_ref_id text, p_why text)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.notifications set status = 'cancelled', last_error = p_why, updated_at = now()
   where ref_type = p_ref_type and ref_id = p_ref_id and kind = 'reminder' and status = 'scheduled';
$$;
revoke all on function public.cancel_reminders(text, text, text) from public;

-- Phone and client of a booking (typed number first, else the client record).
create or replace function public.booking_phone(b public.bookings)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(nullif(regexp_replace(coalesce(b.client_phone, ''), '\D', '', 'g'), ''),
                  (select regexp_replace(coalesce(nullif(c.phone, ''), c.contact_phone, ''), '\D', '', 'g')
                     from public.clients c where c.id::text = b.client_id::text), '');
$$;

create or replace function public.booking_payload(b public.bookings)
returns jsonb language sql stable as $$
  select jsonb_build_object('name', split_part(btrim(coalesce(b.client_name, '')), ' ', 1),
           'service', coalesce(b.service_name, ''), 'date', coalesce(b.date_label, ''),
           'time', coalesce(b.time_label, ''), 'start_at', b.start_at);
$$;

create or replace function public.schedule_booking_reminders(b public.bookings)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare m int; at timestamptz; ph text := public.booking_phone(b);
begin
  if b.status <> 'Confirmed' or b.start_at is null or b.start_at <= now() then return; end if;
  for m in select (jsonb_array_elements_text(coalesce(public.notif_cfg()->'reminders_min', '[]'::jsonb)))::int loop
    at := b.start_at - make_interval(mins => m);
    if m > 0 and at > now() then
      perform public.queue_notification('booking', b.id, b.brand, 'reminder', m, at, ph, b.client_id::text, b.lang,
        public.booking_payload(b), 'reminder:booking:' || b.id || ':' || extract(epoch from b.start_at)::bigint || ':' || m);
    end if;
  end loop;
end; $$;
revoke all on function public.schedule_booking_reminders(public.bookings) from public;

create or replace function public.booking_notifications()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare cfg jsonb; moves int;
begin
  -- Reminders always stop when a booking is no longer going ahead, even if
  -- automatic messages were switched off in the meantime.
  if tg_op = 'UPDATE' and (new.status in ('Cancelled', 'Completed', 'No-show')
                           or new.start_at is distinct from old.start_at) then
    perform public.cancel_reminders('booking', new.id,
      case when new.status = 'Cancelled' then 'booking cancelled'
           when new.status in ('Completed', 'No-show') then 'booking ' || lower(new.status)
           else 'booking moved' end);
  end if;
  if not public.notif_on() then return null; end if;
  cfg := public.notif_cfg();

  -- Cancellation message: only once the cancellation itself is saved (this
  -- runs after the update, in the same transaction).
  if tg_op = 'UPDATE' and new.status = 'Cancelled' and old.status in ('Requested', 'Confirmed')
     and coalesce((cfg->>'cancel')::boolean, true) then
    perform public.queue_notification('booking', new.id, new.brand, 'cancel', null, now(),
      public.booking_phone(new), new.client_id::text, new.lang, public.booking_payload(old),
      'cancel:booking:' || new.id || ':' || coalesce(extract(epoch from old.start_at)::bigint::text, old.date_label || old.time_label));
    return null;
  end if;

  -- New time for a confirmed appointment.
  if tg_op = 'UPDATE' and new.status = 'Confirmed' and old.start_at is not null and new.start_at is not null
     and new.start_at <> old.start_at and new.start_at > now() and coalesce((cfg->>'moved')::boolean, true) then
    moves := jsonb_array_length(coalesce(new.reschedule_log, '[]'::jsonb));
    perform public.queue_notification('booking', new.id, new.brand, 'moved', null, now(),
      public.booking_phone(new), new.client_id::text, new.lang,
      public.booking_payload(new) || jsonb_build_object('old_date', old.date_label, 'old_time', old.time_label),
      'moved:booking:' || new.id || ':' || extract(epoch from new.start_at)::bigint || ':' || moves);
  end if;

  if new.status = 'Confirmed' then perform public.schedule_booking_reminders(new); end if;
  return null;
end; $$;
drop trigger if exists bookings_notifications on public.bookings;
create trigger bookings_notifications after insert or update on public.bookings
  for each row execute function public.booking_notifications();

-- After the owner switches messages on or changes the reminder timings:
-- plan reminders for every upcoming confirmed booking and class place.
create or replace function public.notifications_resync()
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; r record; n int := 0;
begin
  if not public.is_owner() and public.request_role() in ('anon', 'authenticated') then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  -- Timings may have changed: future reminders not matching them are dropped.
  update public.notifications set status = 'cancelled', last_error = 'reminder timings changed', updated_at = now()
   where kind = 'reminder' and status = 'scheduled'
     and (not public.notif_on()
          or not (offset_min::text in (select jsonb_array_elements_text(coalesce(public.notif_cfg()->'reminders_min', '[]'::jsonb)))));
  if not public.notif_on() then return 0; end if;
  for b in select * from public.bookings where status = 'Confirmed' and start_at > now() loop
    perform public.schedule_booking_reminders(b); n := n + 1;
  end loop;
  for r in select x.id from public.class_reservations x join public.class_sessions s on s.id = x.session_id
            where x.status = 'booked' and s.status = 'scheduled' and s.starts_at > now() loop
    perform public.schedule_class_reminders(r.id); n := n + 1;
  end loop;
  return n;
end; $$;

-- ---- Used by the sending server only (service role) --------------------------
create or replace function public.claim_notifications(p_limit int default 25)
returns setof public.notifications language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public.request_role() in ('anon', 'authenticated') then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  -- A send that never reported back is NOT retried (it may have arrived):
  -- it is marked failed so staff can check by hand.
  update public.notifications set status = 'failed', last_error = 'no answer from the sender — check before resending',
         updated_at = now()
   where status = 'sending' and updated_at < now() - interval '15 minutes';
  -- Reminders whose moment has clearly passed are not sent late.
  update public.notifications set status = 'skipped', last_error = 'too late to send', updated_at = now()
   where status = 'scheduled' and kind = 'reminder' and scheduled_at < now() - interval '30 minutes';
  -- Last check that a reminder still matches the appointment.
  update public.notifications n set status = 'cancelled', last_error = 'appointment changed', updated_at = now()
    from public.bookings b
   where n.status = 'scheduled' and n.kind = 'reminder' and n.ref_type = 'booking' and b.id = n.ref_id
     and (b.status <> 'Confirmed' or b.start_at is distinct from (n.payload->>'start_at')::timestamptz);
  update public.notifications n set status = 'cancelled', last_error = 'class changed', updated_at = now()
    from public.class_reservations x join public.class_sessions s on s.id = x.session_id
   where n.status = 'scheduled' and n.kind = 'reminder' and n.ref_type = 'class' and x.id::text = n.ref_id
     and (x.status <> 'booked' or s.status <> 'scheduled' or s.starts_at is distinct from (n.payload->>'start_at')::timestamptz);
  if not public.notif_on() then return; end if;
  return query
    update public.notifications set status = 'sending', attempts = attempts + 1, updated_at = now()
     where id in (select id from public.notifications
                   where status = 'scheduled' and scheduled_at <= now()
                   order by scheduled_at limit greatest(1, least(p_limit, 100))
                   for update skip locked)
    returning *;
end; $$;

create or replace function public.finish_notification(p_id uuid, p_ok boolean, p_via text, p_ref text, p_error text, p_retry boolean)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public.request_role() in ('anon', 'authenticated') then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  update public.notifications set
     status = case when p_ok then 'sent' when p_retry and attempts < 3 then 'scheduled' else 'failed' end,
     scheduled_at = case when not p_ok and p_retry and attempts < 3 then now() + make_interval(mins => 10 * attempts) else scheduled_at end,
     sent_via = coalesce(p_via, ''), provider_ref = left(coalesce(p_ref, ''), 200),
     last_error = case when p_ok then '' else left(coalesce(p_error, ''), 500) end,
     sent_at = case when p_ok then now() else sent_at end, updated_at = now()
   where id = p_id and status = 'sending';
end; $$;
revoke all on function public.claim_notifications(int) from public, anon, authenticated;
revoke all on function public.finish_notification(uuid, boolean, text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.claim_notifications(int) to service_role;
grant execute on function public.finish_notification(uuid, boolean, text, text, text, boolean) to service_role;

-- ---- Staff: retry a failed message, or note it was handled by hand ------------
create or replace function public.staff_notification_action(p_id uuid, p_action text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare n public.notifications;
begin
  select * into n from public.notifications where id = p_id;
  if not found or not (public.is_staff() and public.can_brand(n.brand)
         and (public.has_tab('bookings') or (n.ref_type = 'class' and public.has_tab('classes')))) then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  if p_action = 'retry' then
    if n.status <> 'failed' then raise exception 'NOT_FAILED' using errcode = 'P0001'; end if;
    if n.kind = 'reminder' and (n.payload->>'start_at')::timestamptz <= now() then
      raise exception 'TOO_LATE' using errcode = 'P0001';
    end if;
    update public.notifications set status = 'scheduled', scheduled_at = now(), attempts = 0, updated_at = now() where id = p_id;
  elsif p_action = 'manual' then
    -- Opening WhatsApp by hand is recorded as such — never as delivered.
    if n.status not in ('failed', 'scheduled') then raise exception 'BAD_STATUS' using errcode = 'P0001'; end if;
    update public.notifications set status = 'skipped', sent_via = 'manual',
           last_error = 'opened in WhatsApp by ' || coalesce((select name from public.profiles where id = auth.uid()), 'staff')
                        || ' — delivery not confirmed', updated_at = now()
     where id = p_id;
  else
    raise exception 'BAD_ACTION' using errcode = '22023';
  end if;
end; $$;
revoke all on function public.staff_notification_action(uuid, text) from public;
grant execute on function public.staff_notification_action(uuid, text) to authenticated;

-- ============================================================================
--  3. ADMIN: CHANGE THE TIME OF AN APPOINTMENT (checked on the server)
-- ============================================================================
create or replace function public.staff_reschedule_booking(p_id text, p_date date, p_time text, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; t time; st timestamptz; en timestamptz; dur int; step int;
        hrs jsonb; dh jsonb; o time; c time; problems jsonb := '[]'::jsonb; x record; who text;
begin
  select * into b from public.bookings where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not (public.is_staff() and public.can_write('bookings', b.brand)) then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  if b.status not in ('Requested', 'Confirmed') then raise exception 'BAD_STATUS' using errcode = 'P0001'; end if;
  begin
    t := case when upper(btrim(p_time)) ~ '(AM|PM)$' then to_timestamp(upper(btrim(p_time)), 'HH12:MI AM')::time
              else btrim(p_time)::time end;
  exception when others then raise exception 'BAD_TIME' using errcode = '22023'; end;
  st := (p_date + t) at time zone 'Asia/Baghdad';
  if st <= now() then raise exception 'IN_PAST' using errcode = 'P0001'; end if;
  if st = b.start_at then raise exception 'SAME_TIME' using errcode = 'P0001'; end if;

  hrs := public.setting_json('hours') -> b.brand;
  step := coalesce(nullif(hrs->>'step', '')::int, 60);
  dur := coalesce(public.duration_minutes((select s.duration from public.services s where s.id = b.service_id)), step);
  en := st + make_interval(mins => dur);

  -- Opening hours (Admin → Overview → Opening hours; default 10:00–18:00).
  if coalesce(hrs->'closed', '[]'::jsonb) ? p_date::text then
    problems := problems || jsonb_build_object('type', 'closed', 'text', 'Closed that day (day off)');
  else
    dh := coalesce(hrs->'days'->(extract(dow from p_date)::int::text), '{}'::jsonb);
    if coalesce((dh->>'off')::boolean, false) then
      problems := problems || jsonb_build_object('type', 'closed', 'text', 'Closed on that weekday');
    else
      o := coalesce(nullif(dh->>'o', ''), '10:00')::time; c := coalesce(nullif(dh->>'c', ''), '18:00')::time;
      if t < o or (p_date + t + make_interval(mins => dur))::time > c or (p_date + t + make_interval(mins => dur))::date > p_date then
        problems := problems || jsonb_build_object('type', 'hours',
          'text', 'Outside opening hours (' || to_char(o, 'FMHH12:MI AM') || '–' || to_char(c, 'FMHH12:MI AM')
                  || '; this service takes ' || dur || ' min)');
      end if;
    end if;
  end if;

  -- Overlapping appointments of the same brand, using each service's length.
  -- (There is no staff / room list yet, so each brand counts as one diary.)
  perform pg_advisory_xact_lock(hashtext('booking-day:' || b.brand || ':' || p_date::text));
  for x in select o2.client_name, o2.time_label, o2.service_name
             from public.bookings o2
             left join public.services s2 on s2.id = o2.service_id
            where o2.id <> b.id and o2.brand = b.brand and o2.status in ('Requested', 'Confirmed')
              and o2.start_at is not null and o2.date_iso = p_date
              and o2.start_at < en
              and o2.start_at + make_interval(mins => coalesce(public.duration_minutes(s2.duration), step)) > st loop
    problems := problems || jsonb_build_object('type', 'overlap',
      'text', coalesce(nullif(x.client_name, ''), 'Another client') || ' is booked at ' || x.time_label || ' (' || coalesce(x.service_name, '') || ')');
  end loop;

  if jsonb_array_length(problems) > 0 and not coalesce(p_force, false) then
    return jsonb_build_object('ok', false, 'problems', problems, 'duration', dur);
  end if;

  who := coalesce((select name from public.profiles where id = auth.uid()), 'staff');
  update public.bookings set
         date_iso = p_date, date_label = to_char(p_date, 'Mon FMDD, YYYY'), time_label = to_char(t, 'FMHH12:MI AM'),
         reminders = '{}'::jsonb,
         reschedule_log = coalesce(reschedule_log, '[]'::jsonb) || jsonb_build_object(
           'at', now(), 'by', who, 'by_id', auth.uid(),
           'from', jsonb_build_object('date', b.date_label, 'time', b.time_label),
           'to', jsonb_build_object('date', to_char(p_date, 'Mon FMDD, YYYY'), 'time', to_char(t, 'FMHH12:MI AM')),
           'forced', (jsonb_array_length(problems) > 0), 'problems', problems)
   where id = b.id;
  select * into b from public.bookings where id = p_id;
  return jsonb_build_object('ok', true, 'problems', problems, 'duration', dur,
    'date', b.date_label, 'time', b.time_label, 'date_iso', b.date_iso, 'log', b.reschedule_log);
end; $$;
revoke all on function public.staff_reschedule_booking(text, date, text, boolean) from public;
grant execute on function public.staff_reschedule_booking(text, date, text, boolean) to authenticated;

-- ============================================================================
--  4. CORE WEEKLY GROUP CLASSES
-- ============================================================================
create table if not exists public.class_schedules (
  id             uuid primary key default gen_random_uuid(),
  brand          text not null default 'core',
  class_type     text not null check (class_type in ('reformer', 'mat', 'yoga')),
  title          text not null default '',
  service_id     text,                        -- optional: price / description from Services
  weekday        smallint not null check (weekday between 0 and 6),   -- 0 = Sunday
  start_time     time not null,
  duration_min   int not null check (duration_min between 10 and 300),
  instructor     text not null default '',
  capacity       int not null check (capacity between 1 and 100),
  effective_from date not null,
  effective_to   date,
  active         boolean not null default true,
  updated_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from)
);

create table if not exists public.class_sessions (
  id            uuid primary key default gen_random_uuid(),
  brand         text not null default 'core',
  schedule_id   uuid references public.class_schedules(id) on delete set null,
  session_date  date not null,                -- Erbil date
  origin_date   date,                         -- the timetable date it was made for (kept if moved)
  class_type    text not null check (class_type in ('reformer', 'mat', 'yoga')),
  title         text not null default '',
  service_id    text,
  starts_at     timestamptz not null,
  duration_min  int not null check (duration_min between 10 and 300),
  instructor    text not null default '',
  capacity      int not null check (capacity between 1 and 100),
  status        text not null default 'scheduled' check (status in ('scheduled', 'cancelled')),
  is_exception  boolean not null default false, -- changed on its own: the weekly schedule no longer updates it
  conflict      text not null default '',       -- set when a schedule change could not be applied
  note          text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index if not exists class_sessions_sched_day on public.class_sessions (schedule_id, origin_date)
  where schedule_id is not null;
create index if not exists class_sessions_start_idx on public.class_sessions (starts_at);

create table if not exists public.class_reservations (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references public.class_sessions(id) on delete restrict,
  client_id    text,
  client_name  text not null default '',
  client_phone text not null default '',
  lang         text not null default '',
  status       text not null default 'booked'
               check (status in ('booked', 'cancelled', 'session_cancelled', 'attended', 'no_show')),
  source       text not null default 'app',
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  log          jsonb not null default '[]'::jsonb
);
-- One active place per client per class.
create unique index if not exists class_res_one_per_client on public.class_reservations (session_id, client_id)
  where status = 'booked' and client_id is not null;
create unique index if not exists class_res_one_per_phone on public.class_reservations (session_id, right(client_phone, 10))
  where status = 'booked' and client_id is null and client_phone <> '';

alter table public.class_schedules    enable row level security;
alter table public.class_sessions     enable row level security;
alter table public.class_reservations enable row level security;

create or replace function public.classes_on()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((public.setting_json('core_classes')->>'enabled')::boolean, false);
$$;
create or replace function public.can_classes()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_staff() and public.has_tab('classes') and public.can_brand('core');
$$;

drop policy if exists class_schedules_staff on public.class_schedules;
create policy class_schedules_staff on public.class_schedules for all to authenticated
  using (public.can_classes()) with check (public.can_classes() and brand = 'core');
drop policy if exists class_sessions_staff_read on public.class_sessions;
create policy class_sessions_staff_read on public.class_sessions for select to authenticated using (public.can_classes());
drop policy if exists class_res_staff_read on public.class_reservations;
create policy class_res_staff_read on public.class_reservations for select to authenticated using (public.can_classes());
drop policy if exists class_res_client_read on public.class_reservations;
create policy class_res_client_read on public.class_reservations for select to authenticated
  using (client_id = any(public.my_client_ids()));
-- Sessions and places change only through the functions below.

-- Dated classes from the weekly schedule. Existing classes (and ones changed
-- on their own) are never touched here.
create or replace function public.generate_class_sessions(p_from date, p_to date)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  if not public.can_classes() and public.request_role() in ('anon', 'authenticated') then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  if p_to < p_from or p_to > p_from + 120 then raise exception 'BAD_RANGE' using errcode = '22023'; end if;
  insert into public.class_sessions (brand, schedule_id, session_date, origin_date, class_type, title, service_id,
                                     starts_at, duration_min, instructor, capacity)
  select 'core', s.id, d::date, d::date, s.class_type, s.title, s.service_id,
         (d::date + s.start_time) at time zone 'Asia/Baghdad', s.duration_min, s.instructor, s.capacity
    from public.class_schedules s
    cross join generate_series(greatest(p_from, s.effective_from), least(p_to, coalesce(s.effective_to, p_to)), interval '1 day') d
   where s.active and extract(dow from d)::int = s.weekday
     and ((d::date + s.start_time) at time zone 'Asia/Baghdad') > now()
  on conflict (schedule_id, origin_date) where schedule_id is not null do nothing;
  get diagnostics n = row_count;
  return n;
end; $$;
revoke all on function public.generate_class_sessions(date, date) from public;
grant execute on function public.generate_class_sessions(date, date) to authenticated;

-- Apply a changed weekly class to its future classes, from a chosen date.
-- Classes with places booked are never moved, shrunk or removed: they are
-- flagged ("conflict") for staff to sort out with the clients.
create or replace function public.apply_class_schedule(p_schedule uuid, p_from date)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.class_schedules; x record; booked int; upd int := 0; gone int := 0; flagged jsonb := '[]'::jsonb; want_start timestamptz;
begin
  if not public.can_classes() then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  select * into s from public.class_schedules where id = p_schedule;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  for x in select * from public.class_sessions
            where schedule_id = s.id and session_date >= greatest(p_from, current_date)
              and status = 'scheduled' and not is_exception and starts_at > now()
            for update loop
    select count(*) into booked from public.class_reservations where session_id = x.id and status = 'booked';
    want_start := (x.session_date + s.start_time) at time zone 'Asia/Baghdad';
    if not s.active or extract(dow from x.session_date)::int <> s.weekday
       or x.session_date < s.effective_from or (s.effective_to is not null and x.session_date > s.effective_to) then
      if booked = 0 then
        update public.class_sessions set status = 'cancelled', note = 'removed by a timetable change', updated_at = now() where id = x.id;
        gone := gone + 1;
      else
        update public.class_sessions set conflict = 'No longer in the weekly timetable, but ' || booked || ' booked — kept. Cancel or keep it yourself.', updated_at = now() where id = x.id;
        flagged := flagged || jsonb_build_object('id', x.id, 'date', x.session_date, 'booked', booked);
      end if;
    elsif booked > 0 and (want_start <> x.starts_at or s.capacity < booked) then
      update public.class_sessions set conflict = case when want_start <> x.starts_at
               then 'Timetable now says ' || to_char(s.start_time, 'FMHH12:MI AM') || ', but ' || booked || ' booked at the old time — kept at the old time.'
               else 'New capacity ' || s.capacity || ' is below the ' || booked || ' already booked — capacity kept.' end,
             instructor = s.instructor, title = s.title, service_id = s.service_id, updated_at = now()
       where id = x.id;
      flagged := flagged || jsonb_build_object('id', x.id, 'date', x.session_date, 'booked', booked);
    else
      update public.class_sessions set starts_at = want_start, duration_min = s.duration_min, instructor = s.instructor,
             capacity = s.capacity, title = s.title, class_type = s.class_type, service_id = s.service_id,
             conflict = '', updated_at = now()
       where id = x.id;
      upd := upd + 1;
    end if;
  end loop;
  return jsonb_build_object('updated', upd, 'removed_empty', gone, 'flagged', flagged,
    'added', public.generate_class_sessions(greatest(p_from, current_date), greatest(p_from, current_date) + 56));
end; $$;
revoke all on function public.apply_class_schedule(uuid, date) from public;
grant execute on function public.apply_class_schedule(uuid, date) to authenticated;

-- Change ONE class (the weekly timetable is not changed).
create or replace function public.update_class_session(p_id uuid, p_date date, p_time text, p_duration int,
                                                       p_instructor text, p_capacity int, p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.class_sessions; booked int; t time;
begin
  if not public.can_classes() then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  select * into x from public.class_sessions where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if x.status <> 'scheduled' then raise exception 'BAD_STATUS' using errcode = 'P0001'; end if;
  select count(*) into booked from public.class_reservations where session_id = x.id and status = 'booked';
  if p_capacity < booked then raise exception 'CAPACITY_BELOW_BOOKED:%', booked using errcode = 'P0001'; end if;
  begin t := btrim(p_time)::time; exception when others then raise exception 'BAD_TIME' using errcode = '22023'; end;
  if ((p_date + t) at time zone 'Asia/Baghdad') <= now() then raise exception 'IN_PAST' using errcode = 'P0001'; end if;
  update public.class_sessions set session_date = p_date, starts_at = (p_date + t) at time zone 'Asia/Baghdad',
         duration_min = p_duration, instructor = coalesce(p_instructor, ''), capacity = p_capacity,
         note = coalesce(p_note, note), is_exception = true, conflict = '', updated_at = now()
   where id = x.id;
end; $$;
revoke all on function public.update_class_session(uuid, date, text, int, text, int, text) from public;
grant execute on function public.update_class_session(uuid, date, text, int, text, int, text) to authenticated;

-- Cancel ONE class. With places booked, staff must confirm; the clients'
-- places are marked "class cancelled" (kept, not deleted) and they are told.
create or replace function public.cancel_class_session(p_id uuid, p_confirm boolean default false)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare booked int;
begin
  if not public.can_classes() then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  perform 1 from public.class_sessions where id = p_id and status = 'scheduled' for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select count(*) into booked from public.class_reservations where session_id = p_id and status = 'booked';
  if booked > 0 and not coalesce(p_confirm, false) then raise exception 'HAS_RESERVATIONS:%', booked using errcode = 'P0001'; end if;
  update public.class_sessions set status = 'cancelled', is_exception = true, conflict = '', updated_at = now() where id = p_id;
  update public.class_reservations set status = 'session_cancelled', updated_at = now(),
         log = log || jsonb_build_object('at', now(), 'by', coalesce((select name from public.profiles where id = auth.uid()), 'staff'), 'action', 'class cancelled')
   where session_id = p_id and status = 'booked';
  return booked;
end; $$;
revoke all on function public.cancel_class_session(uuid, boolean) from public;
grant execute on function public.cancel_class_session(uuid, boolean) to authenticated;

create or replace function public.clear_class_conflict(p_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.can_classes() then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  update public.class_sessions set conflict = '', is_exception = true, updated_at = now() where id = p_id;
end; $$;
revoke all on function public.clear_class_conflict(uuid) from public;
grant execute on function public.clear_class_conflict(uuid) to authenticated;

-- One place, checked under a lock on the class so two people pressing "Book"
-- for the last place at the same moment cannot both get it.
create or replace function public.reserve_class_place(p_session uuid, p_client text, p_name text, p_phone text,
                                                      p_lang text, p_source text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.class_sessions; booked int; rid uuid; ph text := left(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 15);
begin
  select * into x from public.class_sessions where id = p_session for update;
  if not found or x.status <> 'scheduled' then raise exception 'CLASS_UNAVAILABLE' using errcode = 'P0001'; end if;
  if x.starts_at <= now() then raise exception 'CLASS_STARTED' using errcode = 'P0001'; end if;
  if exists (select 1 from public.class_reservations r where r.session_id = x.id and r.status = 'booked'
              and ((p_client is not null and r.client_id = p_client)
                   or (ph <> '' and public.digits10(r.client_phone) = public.digits10(ph)))) then
    raise exception 'ALREADY_BOOKED' using errcode = '23505';
  end if;
  select count(*) into booked from public.class_reservations where session_id = x.id and status = 'booked';
  if booked >= x.capacity then raise exception 'CLASS_FULL' using errcode = 'P0001'; end if;
  insert into public.class_reservations (session_id, client_id, client_name, client_phone, lang, source, created_by)
  values (x.id, p_client, left(coalesce(p_name, ''), 80), ph, left(coalesce(p_lang, ''), 5), p_source, auth.uid())
  returning id into rid;
  return rid;
end; $$;
revoke all on function public.reserve_class_place(uuid, text, text, text, text, text) from public, anon, authenticated;

-- Client (signed in) books a place.
create or replace function public.book_class(p_session uuid, p_lang text default '')
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.clients;
begin
  if auth.uid() is null or public.is_staff() then raise exception 'SIGN_IN_REQUIRED' using errcode = '42501'; end if;
  if not public.classes_on() then raise exception 'CLASSES_OFF' using errcode = 'P0001'; end if;
  select * into c from public.clients where id::text = any(public.my_client_ids())
   order by (user_id = auth.uid()) desc nulls last, created_at desc limit 1;
  if not found then raise exception 'NO_CLIENT_RECORD' using errcode = 'P0001'; end if;
  -- the same person under another of their records counts too
  if exists (select 1 from public.class_reservations r where r.session_id = p_session and r.status = 'booked'
              and r.client_id = any(public.my_client_ids())) then
    raise exception 'ALREADY_BOOKED' using errcode = '23505';
  end if;
  return public.reserve_class_place(p_session, c.id::text, c.name, coalesce(nullif(c.phone, ''), c.contact_phone), p_lang, 'app');
end; $$;
revoke all on function public.book_class(uuid, text) from public;
grant execute on function public.book_class(uuid, text) to authenticated;

-- Staff add a client (or a walk-in name + phone) to a class.
create or replace function public.staff_book_class(p_session uuid, p_client text, p_name text, p_phone text, p_lang text default '')
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.can_classes() then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if coalesce(p_client, '') = '' and coalesce(btrim(p_name), '') = '' then raise exception 'NAME_REQUIRED' using errcode = '22023'; end if;
  return public.reserve_class_place(p_session, nullif(p_client, ''), p_name, p_phone, p_lang, 'staff');
end; $$;
revoke all on function public.staff_book_class(uuid, text, text, text, text) from public;
grant execute on function public.staff_book_class(uuid, text, text, text, text) to authenticated;

-- Cancel a place: staff (any time) or the client (only when the owner has
-- switched on client changes, before that deadline — same rule as appointments).
create or replace function public.cancel_class_place(p_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.class_reservations; x public.class_sessions; cfg jsonb := public.setting_json('client_booking_changes'); who text;
begin
  select * into r from public.class_reservations where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select * into x from public.class_sessions where id = r.session_id;
  if r.status <> 'booked' then raise exception 'BAD_STATUS' using errcode = 'P0001'; end if;
  if public.can_classes() then
    who := coalesce((select name from public.profiles where id = auth.uid()), 'staff');
  elsif auth.uid() is not null and r.client_id = any(public.my_client_ids()) then
    if coalesce((cfg->>'enabled')::boolean, false) is not true or (cfg->>'cutoff_hours') is null then
      raise exception 'CLIENT_CHANGES_DISABLED' using errcode = 'P0001';
    end if;
    if x.starts_at < now() + make_interval(mins => ((cfg->>'cutoff_hours')::numeric * 60)::int) then
      raise exception 'TOO_LATE' using errcode = 'P0001';
    end if;
    who := 'client';
  else
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  update public.class_reservations set status = 'cancelled', updated_at = now(),
         log = log || jsonb_build_object('at', now(), 'by', who, 'action', 'cancel')
   where id = r.id;
end; $$;
revoke all on function public.cancel_class_place(uuid) from public;
grant execute on function public.cancel_class_place(uuid) to authenticated;

create or replace function public.mark_class_place(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.can_classes() then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if p_status not in ('attended', 'no_show', 'booked') then raise exception 'BAD_STATUS' using errcode = '22023'; end if;
  update public.class_reservations set status = p_status, updated_at = now(),
         log = log || jsonb_build_object('at', now(), 'by', coalesce((select name from public.profiles where id = auth.uid()), 'staff'), 'action', p_status)
   where id = p_id and status in ('booked', 'attended', 'no_show');
end; $$;
revoke all on function public.mark_class_place(uuid, text) from public;
grant execute on function public.mark_class_place(uuid, text) to authenticated;

-- The timetable for the client app: places left, no names or numbers.
create or replace function public.class_timetable(p_from date, p_to date)
returns table (id uuid, class_type text, title text, service_id text, starts_at timestamptz, session_date date,
               duration_min int, instructor text, capacity int, booked int, places_left int, mine boolean, mine_id uuid)
language sql stable security definer set search_path = public, pg_temp as $$
  select s.id, s.class_type, s.title, s.service_id, s.starts_at, s.session_date, s.duration_min, s.instructor, s.capacity,
         b.n::int, greatest(0, s.capacity - b.n)::int,
         m.id is not null, m.id
    from public.class_sessions s
    cross join lateral (select count(*) n from public.class_reservations r where r.session_id = s.id and r.status = 'booked') b
    left join lateral (select r.id from public.class_reservations r where r.session_id = s.id and r.status = 'booked'
                         and auth.uid() is not null and r.client_id = any(public.my_client_ids()) limit 1) m on true
   where (public.classes_on() or public.can_classes())
     and s.status = 'scheduled' and s.starts_at > now()
     and s.session_date between p_from and least(p_to, p_from + 42)
   order by s.starts_at;
$$;
revoke all on function public.class_timetable(date, date) from public;
grant execute on function public.class_timetable(date, date) to anon, authenticated;

-- The signed-in client's own class places (for "My bookings").
create or replace function public.my_class_places()
returns table (id uuid, status text, session_id uuid, starts_at timestamptz, title text, class_type text,
               instructor text, duration_min int, session_status text)
language sql stable security definer set search_path = public, pg_temp as $$
  select r.id, r.status, s.id, s.starts_at, s.title, s.class_type, s.instructor, s.duration_min, s.status
    from public.class_reservations r join public.class_sessions s on s.id = r.session_id
   where auth.uid() is not null and r.client_id = any(public.my_client_ids())
     and s.starts_at > now() - interval '60 days'
   order by s.starts_at;
$$;
revoke all on function public.my_class_places() from public;
grant execute on function public.my_class_places() to authenticated;

-- ---- Messages for class places ------------------------------------------------
create or replace function public.class_payload(r public.class_reservations, x public.class_sessions)
returns jsonb language sql stable as $$
  select jsonb_build_object('name', split_part(btrim(coalesce(r.client_name, '')), ' ', 1),
           'service', coalesce(nullif(x.title, ''), initcap(x.class_type)),
           'date', to_char(x.starts_at at time zone 'Asia/Baghdad', 'Mon FMDD, YYYY'),
           'time', to_char(x.starts_at at time zone 'Asia/Baghdad', 'FMHH12:MI AM'),
           'start_at', x.starts_at, 'instructor', x.instructor);
$$;
create or replace function public.class_phone(r public.class_reservations)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(nullif(regexp_replace(coalesce(r.client_phone, ''), '\D', '', 'g'), ''),
                  (select regexp_replace(coalesce(nullif(c.phone, ''), c.contact_phone, ''), '\D', '', 'g')
                     from public.clients c where c.id::text = r.client_id), '');
$$;

create or replace function public.schedule_class_reminders(p_res uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.class_reservations; x public.class_sessions; m int; at timestamptz;
begin
  select * into r from public.class_reservations where id = p_res;
  select * into x from public.class_sessions where id = r.session_id;
  if r.status <> 'booked' or x.status <> 'scheduled' or x.starts_at <= now() or not public.notif_on() then return; end if;
  for m in select (jsonb_array_elements_text(coalesce(public.notif_cfg()->'reminders_min', '[]'::jsonb)))::int loop
    at := x.starts_at - make_interval(mins => m);
    if m > 0 and at > now() then
      perform public.queue_notification('class', r.id::text, 'core', 'reminder', m, at, public.class_phone(r), r.client_id,
        r.lang, public.class_payload(r, x), 'reminder:class:' || r.id || ':' || extract(epoch from x.starts_at)::bigint || ':' || m);
    end if;
  end loop;
end; $$;
revoke all on function public.schedule_class_reminders(uuid) from public;

create or replace function public.class_res_notifications()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.class_sessions;
begin
  if tg_op = 'UPDATE' and new.status <> 'booked' and old.status = 'booked' then
    perform public.cancel_reminders('class', new.id::text, 'place ' || replace(new.status, '_', ' '));
    if new.status in ('cancelled', 'session_cancelled') and public.notif_on()
       and coalesce((public.notif_cfg()->>'cancel')::boolean, true) then
      select * into x from public.class_sessions where id = new.session_id;
      perform public.queue_notification('class', new.id::text, 'core', 'cancel', null, now(), public.class_phone(new),
        new.client_id, new.lang, public.class_payload(new, x) || jsonb_build_object('by_studio', new.status = 'session_cancelled'),
        'cancel:class:' || new.id);
    end if;
  elsif new.status = 'booked' then
    perform public.schedule_class_reminders(new.id);
  end if;
  return null;
end; $$;
drop trigger if exists class_res_notifications on public.class_reservations;
create trigger class_res_notifications after insert or update on public.class_reservations
  for each row execute function public.class_res_notifications();

create or replace function public.class_session_notifications()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.class_reservations;
begin
  if new.status = 'scheduled' and new.starts_at <> old.starts_at then
    for r in select * from public.class_reservations where session_id = new.id and status = 'booked' loop
      perform public.cancel_reminders('class', r.id::text, 'class moved');
      if public.notif_on() and coalesce((public.notif_cfg()->>'moved')::boolean, true) and new.starts_at > now() then
        perform public.queue_notification('class', r.id::text, 'core', 'moved', null, now(), public.class_phone(r), r.client_id, r.lang,
          public.class_payload(r, new) || jsonb_build_object(
            'old_date', to_char(old.starts_at at time zone 'Asia/Baghdad', 'Mon FMDD, YYYY'),
            'old_time', to_char(old.starts_at at time zone 'Asia/Baghdad', 'FMHH12:MI AM')),
          'moved:class:' || r.id || ':' || extract(epoch from new.starts_at)::bigint);
      end if;
      perform public.schedule_class_reminders(r.id);
    end loop;
  end if;
  return null;
end; $$;
drop trigger if exists class_session_notifications on public.class_sessions;
create trigger class_session_notifications after update on public.class_sessions
  for each row execute function public.class_session_notifications();

-- ---- Table permissions (row rules above decide which rows) ---------------------
revoke all on public.notifications, public.push_devices, public.class_schedules,
              public.class_sessions, public.class_reservations from anon, authenticated;
grant select on public.notifications to authenticated;
grant select, insert, update, delete on public.class_schedules to authenticated;
grant select on public.class_sessions, public.class_reservations to authenticated;
grant all on public.notifications, public.push_devices, public.class_schedules,
             public.class_sessions, public.class_reservations to service_role;

notify pgrst, 'reload schema';
