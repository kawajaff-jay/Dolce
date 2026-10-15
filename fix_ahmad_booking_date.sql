-- ============================================================================
--  Dolce+  —  ONE-ROW DATE CORRECTION (Ahmad, "face full", typed as 26/9/2026)
--  Run AFTER supabase_migration_launch_decisions.sql.
--  It changes exactly one booking, and only its date/time columns:
--    date 26 September 2026, time 4:00 PM (Erbil). Status stays Completed;
--    its points history (linked by booking id) is untouched.
--  If the row is not found exactly once, it stops and changes nothing.
-- ============================================================================
do $$
declare n int; bid text;
begin
  select count(*), min(id) into n, bid from public.bookings
   where brand = 'dolce' and client_name = 'Ahmad' and service_name = 'face full'
     and date_label = '26/9/2026' and lower(replace(time_label, ' ', '')) = '4:00pm' and status = 'Completed';
  if n <> 1 then
    raise exception 'Expected exactly 1 matching booking, found %. Nothing changed.', n;
  end if;
  update public.bookings
     set date_iso = date '2026-09-26',
         date_label = 'Sep 26, 2026',
         time_label = '4:00 PM',
         reschedule_log = reschedule_log || jsonb_build_object(
           'at', now(), 'by', 'data correction',
           'note', 'Typed date "26/9/2026 4:00pm" stored as a real date',
           'from', jsonb_build_object('date', '26/9/2026', 'time', '4:00pm'))
   where id = bid;
end $$;

-- Check (one row): the corrected booking.
select id, status, date_label, time_label, date_iso, time_of_day, start_at
  from public.bookings
 where brand = 'dolce' and client_name = 'Ahmad' and service_name = 'face full';
