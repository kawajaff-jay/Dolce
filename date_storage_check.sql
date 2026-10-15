-- ============================================================================
--  Dolce+  —  ARE DATES STORED AS REAL DATES? (read-only)
--  One table: each line is a check and its result. Expected results noted.
-- ============================================================================
select 'Column types (expect date / time / timestamptz)' as check_name,
       string_agg(table_name || '.' || column_name || ' = ' || data_type, '  ·  ' order by table_name, column_name) as result
  from information_schema.columns
 where table_schema = 'public'
   and ((table_name = 'bookings' and column_name in ('date_iso','time_of_day','start_at','created_at'))
     or (table_name in ('product_sales','purchases','register_closes') and column_name = 'date_iso')
     or (table_name = 'orders' and column_name in ('created_at','completed_at'))
     or (table_name = 'point_transactions' and column_name = 'created_at'))
union all
select 'Bookings with a date label but no real date (expect 0)',
       count(*)::text from public.bookings where date_iso is null and coalesce(date_label,'') not in ('','TBD')
union all
select 'Bookings with a time label but no real time (expect 0)',
       count(*)::text from public.bookings where time_of_day is null and coalesce(time_label,'') not in ('','TBD')
union all
select 'Bookings whose label does not match the real date (expect 0)',
       count(*)::text from public.bookings where date_iso is not null and date_label <> to_char(date_iso, 'Mon FMDD, YYYY')
union all
select 'Bookings with date + time but no exact moment (expect 0)',
       count(*)::text from public.bookings where date_iso is not null and time_of_day is not null and start_at is null
union all
select 'Sales / deliveries / register closes without a real date (expect 0)',
       (select count(*) from public.product_sales where date_iso is null)::text || ' / ' ||
       (select count(*) from public.purchases where date_iso is null)::text || ' / ' ||
       (select count(*) from public.register_closes where date_iso is null)::text
union all
select 'Undated bookings ("TBD") — fine, listed for information',
       count(*)::text from public.bookings where coalesce(date_label,'') in ('','TBD');
