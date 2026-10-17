-- ============================================================================
--  Dolce+  —  CORE CLASSES FROM MINDBODY (read-only connection)
--  FOR REVIEW. Run once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Deletes no data; changes no bookings.
-- ============================================================================
--  mindbody_cache — the last schedule fetched from Mindbody (kept 15 minutes,
--  so clients opening the app do not each cost a paid Mindbody API call).
--  Only the server function "mindbody-classes" reads or writes it.
--
--  Settings key 'mindbody' (owner, Admin → Classes; not secret):
--     {"enabled":false,"site_id":"","booking_url":""}
--  enabled     show CORE's classes from Mindbody in the client app
--  site_id     CORE's public Mindbody Site ID (also used for the booking link)
--  booking_url CORE's own Mindbody booking page, if it has a preferred one
--  The API key never goes here — it is a server secret.
-- ============================================================================
create table if not exists public.mindbody_cache (
  id         text primary key,
  payload    jsonb not null default '[]'::jsonb,
  fetched_at timestamptz not null default now()
);
alter table public.mindbody_cache enable row level security;
revoke all on public.mindbody_cache from anon, authenticated;
grant all on public.mindbody_cache to service_role;

-- While CORE classes come from Mindbody, Dolce+'s own group-class timetable
-- stays off for clients (one source of truth). Nothing is deleted.
update public.settings set value = to_jsonb('{"enabled":false}'::text)
 where key = 'core_classes' and public.setting_json('core_classes')->>'enabled' = 'true'
   and not exists (select 1 from public.class_reservations);

notify pgrst, 'reload schema';
