-- ============================================================================
--  Dolce+  —  LIVE HEALTH CHECK (read-only: changes nothing)
--  Supabase → SQL Editor → New query → paste → Run. One table of results.
--  Send a screenshot of the result to Claude.
-- ============================================================================
select 'Bookings with no real date (booked from an Arabic/Kurdish-language phone?)' as check_name,
       count(*)::text as result
  from public.bookings where date_iso is null and coalesce(date_label,'') not in ('','TBD')
union all
select 'Time slots with 2+ active bookings (same brand, date, time)',
       count(*)::text from (
         select brand, date_iso, time_label from public.bookings
          where status <> 'Cancelled' and date_iso is not null and coalesce(time_label,'') <> ''
          group by 1,2,3 having count(*) > 1) d
union all
select 'Client records sharing a phone number (last 10 digits)',
       count(*)::text from (
         select right(regexp_replace(coalesce(phone::text, contact_phone, ''), '\D', '', 'g'), 10) k
           from public.clients
          where length(regexp_replace(coalesce(phone::text, contact_phone, ''), '\D', '', 'g')) >= 8
          group by 1 having count(*) > 1) d
union all
select 'Clients whose balance differs from their points history',
       count(*)::text from public.clients c
 where c.points <> coalesce((select sum(p.points) from public.point_transactions p where p.client_id = c.id::text), 0)
union all
select 'Total rows: clients / bookings / point history',
       (select count(*) from public.clients)::text || ' / ' || (select count(*) from public.bookings)::text
       || ' / ' || (select count(*) from public.point_transactions)::text
union all
select 'Staff PINs shorter than 6 digits are not visible here — check Employees tab', '—'
union all
select 'Policy: ' || tablename || ' · ' || policyname || ' · ' || cmd,
       coalesce(qual, '') || case when with_check is not null then '  CHECK ' || with_check else '' end
  from pg_policies
 where schemaname = 'public'
   and tablename in ('clients','bookings','point_transactions','products','product_sales','purchases','register_closes','profiles','settings','media')
union all
select 'Trigger present: ' || t.tgname, c.relname
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
 where not t.tgisinternal
   and t.tgname in ('pt_apply','clients_guard_points','bookings_request_guard','product_sales_stock','purchases_stock','profiles_guard_permissions');
