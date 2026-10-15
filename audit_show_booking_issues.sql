-- Read-only: shows the booking with no readable date and the double-booked slot
-- found by the live check, so reception can look at them in Admin → Bookings.
select 'No readable date' as issue, b.brand, b.date_label, b.time_label, b.status, b.client_name, b.service_name, b.created_at
  from public.bookings b
 where b.date_iso is null and coalesce(b.date_label,'') not in ('','TBD')
union all
select 'Same slot booked twice', b.brand, b.date_label, b.time_label, b.status, b.client_name, b.service_name, b.created_at
  from public.bookings b
  join (select brand, date_iso, time_label from public.bookings
         where status <> 'Cancelled' and date_iso is not null and coalesce(time_label,'') <> ''
         group by 1,2,3 having count(*) > 1) d
    on d.brand = b.brand and d.date_iso = b.date_iso and d.time_label = b.time_label
 where b.status <> 'Cancelled'
order by 1, 3, 4;
