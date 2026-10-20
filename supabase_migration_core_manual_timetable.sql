-- ============================================================================
--  Dolce+  —  CORE weekly timetable typed in by hand (shown until Mindbody's
--  live schedule is connected). Booking stays on Mindbody.
--  Run once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Deletes no data; changes no bookings.
-- ============================================================================
--  Lets the client app READ the weekly classes the owner typed in Admin →
--  Classes, but only while settings 'mindbody' has "manual": true (the owner's
--  switch). It returns times, class, length and instructor only — no places,
--  no client data — and it cannot book anything: places are booked on Mindbody.
--  Dolce+'s own class booking stays OFF (settings 'core_classes' is unchanged).
-- ============================================================================
create or replace function public.core_timetable_public(p_from date, p_to date)
returns table (id text, class_type text, title text, starts_at timestamptz, session_date date,
               duration_min int, instructor text)
language sql stable security definer set search_path = public, pg_temp as $$
  with on_ as (select coalesce((public.setting_json('mindbody')->>'manual')::boolean, false) as ok),
  rng as (select greatest(p_from, current_date) as a,
                 least(p_to, greatest(p_from, current_date) + 42) as b),
  gen as (   -- weekly classes on days that have no dated class yet
    select s.id::text || ':' || d::date as id, s.id as sid, d::date as dd, s.class_type, s.title,
           ((d::date + s.start_time) at time zone 'Asia/Baghdad') as st, s.duration_min, s.instructor
      from public.class_schedules s, rng
      cross join lateral generate_series(greatest(rng.a, s.effective_from),
                                         least(rng.b, coalesce(s.effective_to, rng.b)), interval '1 day') d
     where s.active and s.brand = 'core' and extract(dow from d)::int = s.weekday)
  select g.id, g.class_type, g.title, g.st, g.dd, g.duration_min, g.instructor
    from gen g
   where (select ok from on_) and g.st > now()
     and not exists (select 1 from public.class_sessions x where x.schedule_id = g.sid and x.origin_date = g.dd)
  union all  -- dated classes (moved or changed one by one; cancelled ones are left out)
  select x.id::text, x.class_type, x.title, x.starts_at, x.session_date, x.duration_min, x.instructor
    from public.class_sessions x, rng
   where (select ok from on_) and x.brand = 'core' and x.status = 'scheduled'
     and x.session_date between rng.a and rng.b and x.starts_at > now()
  order by 4;
$$;
revoke all on function public.core_timetable_public(date, date) from public;
grant execute on function public.core_timetable_public(date, date) to anon, authenticated;

notify pgrst, 'reload schema';
