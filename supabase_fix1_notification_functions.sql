-- ============================================================================
--  Dolce+  —  SECURITY FIX 1: close the internal notification functions
--  Run once in Supabase → SQL Editor. Safe to run more than once.
--  Changes NO data. Only removes the right of visitors and ordinary logged-in
--  users to CALL six internal helper functions directly.
--
--  Why: these functions queue / cancel WhatsApp messages and look up phone
--  numbers. They are only meant to be used by the database's own triggers
--  (booking confirmed / cancelled / moved, class places). Earlier they were
--  closed only for "public"; Supabase also grants anon + authenticated
--  separately, so they stayed callable by anyone.
--  The triggers keep working: they run as the database owner, which keeps
--  the right to call these functions.
-- ============================================================================
revoke execute on function public.queue_notification(text, text, text, text, int, timestamptz, text, text, text, jsonb, text)
  from public, anon, authenticated;
revoke execute on function public.schedule_booking_reminders(public.bookings) from public, anon, authenticated;
revoke execute on function public.schedule_class_reminders(uuid)               from public, anon, authenticated;
revoke execute on function public.cancel_reminders(text, text, text)          from public, anon, authenticated;
revoke execute on function public.booking_phone(public.bookings)               from public, anon, authenticated;
revoke execute on function public.class_phone(public.class_reservations)       from public, anon, authenticated;

-- Result: every row should say visitor=false, logged_in=false.
select p.proname as function,
       has_function_privilege('anon', p.oid, 'EXECUTE')          as visitor,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as logged_in
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('queue_notification','schedule_booking_reminders','schedule_class_reminders',
                    'cancel_reminders','booking_phone','class_phone')
order by 1;
