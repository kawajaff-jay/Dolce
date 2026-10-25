-- ============================================================================
--  Dolce+  —  CHECK FOR SECURITY FIX 1  (leaves NOTHING behind)
--  Run in Supabase → SQL Editor AFTER supabase_fix1_notification_functions.sql.
--  Everything below happens inside one transaction that is cancelled at the
--  end on purpose: the "ERROR: AUDIT RESULT ..." message IS the result.
--  No test booking, no message and no setting is kept.
-- ============================================================================
do $$
declare
  owner_id uuid; bid text := 'audit-fix1-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');
  r_anon text; r_auth text; r_phone text; n_rem int; n_cancel int; n_remc int;
begin
  -- 1. A visitor tries to queue a WhatsApp message directly → must be refused
  perform set_config('role', 'anon', true);
  begin
    perform public.queue_notification('booking','x','dolce','reminder',60,now(),'9647500000000',null,'en','{}'::jsonb,'audit-x');
    r_anon := 'ALLOWED (BAD)';
  exception when insufficient_privilege then r_anon := 'refused (good)'; end;
  begin
    perform public.cancel_reminders('booking','x','audit');
    r_anon := r_anon || ' / cancel ALLOWED (BAD)';
  exception when insufficient_privilege then r_anon := r_anon || ' / cancel refused (good)'; end;
  reset role;

  -- 2. An ordinary logged-in user (no staff profile) tries the same → must be refused
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  begin
    perform public.queue_notification('booking','x','dolce','reminder',60,now(),'9647500000000',null,'en','{}'::jsonb,'audit-y');
    r_auth := 'ALLOWED (BAD)';
  exception when insufficient_privilege then r_auth := 'refused (good)'; end;
  begin
    r_phone := public.booking_phone(null::public.bookings);
    r_auth := r_auth || ' / phone lookup ALLOWED (BAD)';
  exception when insufficient_privilege then r_auth := r_auth || ' / phone lookup refused (good)'; end;
  reset role;

  -- 3. Allowed path: the OWNER confirms then cancels a test booking in the app's
  --    way; the database itself must still queue the reminder and the
  --    cancellation message. Automatic messages are switched on ONLY inside
  --    this cancelled transaction.
  select id into owner_id from public.profiles where is_owner order by name limit 1;
  insert into public.settings (key, value)
    values ('notifications', to_jsonb('{"enabled":true,"channel":"whatsapp","reminders_min":[60],"cancel":true,"moved":true}'::text))
    on conflict (key) do update set value = excluded.value;
  perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  insert into public.bookings (id, brand, service_name, date_label, time_label, status, client_name, client_phone, lang)
    values (bid, 'dolce', 'AUDIT TEST', to_char(current_date + 3, 'Mon FMDD, YYYY'), '11:00 AM', 'Confirmed',
            'Audit Test', '9647500000000', 'en');
  reset role;
  select count(*) into n_rem from public.notifications where ref_id = bid and kind = 'reminder' and status = 'scheduled';

  perform set_config('role', 'authenticated', true);
  update public.bookings set status = 'Cancelled' where id = bid;
  reset role;
  select count(*) into n_cancel from public.notifications where ref_id = bid and kind = 'cancel';
  select count(*) into n_remc   from public.notifications where ref_id = bid and kind = 'reminder' and status = 'cancelled';

  raise exception 'AUDIT RESULT (everything rolled back) | visitor: % | logged-in non-staff: % | owner confirm -> reminders queued: % (expect 1) | owner cancel -> reminder cancelled: % (expect 1), cancel message queued: % (expect 1)',
    r_anon, r_auth, n_rem, n_remc, n_cancel;
end $$;
