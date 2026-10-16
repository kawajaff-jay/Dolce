-- ============================================================================
--  Dolce+  —  START THE AUTOMATIC SENDING (run only when the owner is ready)
--  Needs: supabase_migration_notifications_classes.sql already run, and the
--  Edge Function "notify-dispatch" deployed (Verify JWT OFF).
--
--  BEFORE RUNNING:
--   1. In Terminal: openssl rand -base64 32   → copy the result.
--   2. Supabase → Edge Functions → Secrets → add NOTIFY_CRON_SECRET = that value.
--   3. Paste the SAME value below where it says PASTE-THE-SECRET-HERE
--      (keep the quotes). Do not send it to anyone, not in chat either.
--  Safe to run again (it replaces the schedules; the secret is updated).
--  To stop sending: Admin → Settings → Automatic messages → off
--  (or run:  select cron.unschedule('dolce-notify-dispatch');)
-- ============================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- The shared secret lives in the database Vault (encrypted), not in this text.
do $$
declare v text := 'PASTE-THE-SECRET-HERE';
begin
  if v = 'PASTE-THE-SECRET-HERE' or length(v) < 24 then
    raise exception 'Paste the NOTIFY_CRON_SECRET value into this file first (24+ characters).';
  end if;
  if exists (select 1 from vault.secrets where name = 'notify_cron_secret') then
    perform vault.update_secret((select id from vault.secrets where name = 'notify_cron_secret'), v);
  else
    perform vault.create_secret(v, 'notify_cron_secret', 'Dolce+ notify-dispatch caller secret');
  end if;
end $$;

-- Every 2 minutes: hand due messages to the sender.
select cron.schedule('dolce-notify-dispatch', '*/2 * * * *', $job$
  select net.http_post(
    url     := 'https://rljfpxxgtuujcdxvcuow.supabase.co/functions/v1/notify-dispatch',
    headers := jsonb_build_object('Content-Type', 'application/json',
                 'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'notify_cron_secret')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000);
$job$);

-- Every night 00:15 UTC (03:15 Erbil): make the next 8 weeks of Core classes
-- from the weekly timetable (existing and changed classes are left alone).
select cron.schedule('dolce-class-sessions', '15 0 * * *', $job$
  select public.generate_class_sessions(current_date, current_date + 56);
$job$);

-- What is scheduled now:
select jobname, schedule, active from cron.job where jobname like 'dolce-%';
