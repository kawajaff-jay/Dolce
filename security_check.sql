-- ============================================================================
--  Dolce+  —  MONTHLY SECURITY CHECK  (read-only: changes nothing)
--  Supabase → SQL Editor → New query → paste all of this → Run.
--  One table comes back. Look at the "status" column:
--     OK       nothing to do
--     CHECK    have a look — usually fine, but make sure you recognise it
--     WARNING  something is open that should not be — send it to Kawa/Claude
-- ============================================================================
with
tbls as (
  select c.relname as t, c.relrowsecurity as rls,
         (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname) as n_pol
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
),
pol as (
  select tablename, policyname, cmd, roles::text as roles,
         coalesce(qual, '') as q, coalesce(with_check, '') as wc
  from pg_policies where schemaname = 'public'
),
staff as (
  select p.id, p.name, p.is_owner, u.last_sign_in_at
  from public.profiles p left join auth.users u on u.id = p.id
),
nonstaff as (
  select u.id, u.email, u.phone, u.created_at
  from auth.users u
  where not exists (select 1 from public.profiles p where p.id = u.id)
),
checks as (

  -- 1. Every table must have its security rules switched on
  select 1 as ord, 'Database tables' as section, t as item,
         case when rls then 'OK' else 'WARNING' end as status,
         case when rls then 'Security rules on (' || n_pol || ' rules)'
              else 'Security rules are OFF — anyone with the app key could read or change this table' end as detail
  from tbls

  union all
  -- 2. What a visitor who is not logged in is allowed to CHANGE
  select 2, 'Visitor (not logged in) can change', tablename || ' · ' || policyname,
         case when tablename = 'bookings' and cmd = 'INSERT' then 'OK'
              when (q || wc) ~ '(is_staff|is_owner|can_write|has_tab|can_brand|current_profile)' then 'CHECK'
              else 'WARNING' end,
         case when tablename = 'bookings' and cmd = 'INSERT'
              then 'Expected: visitors may send a booking request (only as "Requested")'
              when (q || wc) ~ '(is_staff|is_owner|can_write|has_tab|can_brand|current_profile)'
              then 'Old-style rule written for everyone, but it only lets staff through — safe, can be tidied up later'
              else 'Visitors can ' || cmd || ' here — this should not normally be allowed' end
  from pol
  where cmd <> 'SELECT' and (roles like '%anon%' or roles like '%public%')

  union all
  -- 3. Rules that let ANY logged-in person change data without checking who they are
  select 3, 'Too-open rule', tablename || ' · ' || policyname, 'WARNING',
         'Any logged-in account (including a client) can ' || cmd || ' here'
  from pol
  where cmd <> 'SELECT'
    and (q in ('true', '(auth.uid() IS NOT NULL)') or wc in ('true', '(auth.uid() IS NOT NULL)'))
    and not (tablename = 'bookings' and cmd = 'INSERT')

  union all
  -- 3b. Private tables that any logged-in account (or a visitor) can READ
  select 3, 'Too-open reading', tablename || ' · ' || policyname, 'WARNING',
         'Anyone logged in' || case when roles like '%anon%' or roles like '%public%' then ' (or even a visitor)' else '' end
         || ' can read ALL of ' || tablename
  from pol
  where cmd in ('SELECT', 'ALL')
    and q in ('true', '(auth.uid() IS NOT NULL)')
    and tablename in ('clients', 'bookings', 'profiles', 'purchases', 'product_sales', 'register_closes')
    and not (tablename = 'bookings' and cmd = 'INSERT')

  union all
  -- 4. Photo/video storage folders that are public
  select 4, 'Photo storage', b.name,
         case when b.public then 'CHECK' else 'OK' end,
         case when b.public then 'Public folder: anyone with a link can view files here — fine for menu photos, never for private client photos'
              else 'Private folder' end
  from storage.buckets b

  union all
  -- 5. Who has owner access (full control of everything)
  select 5, 'Owners', coalesce(name, '(no name)'), 'CHECK',
         'Full control. Last login: ' || coalesce(to_char(last_sign_in_at, 'DD Mon YYYY'), 'never')
  from staff where is_owner

  union all
  -- 6. All other staff, and anyone who has not logged in for 60 days
  select 6, 'Staff', coalesce(name, '(no name)'),
         case when last_sign_in_at is null or last_sign_in_at < now() - interval '60 days' then 'CHECK' else 'OK' end,
         case when last_sign_in_at is null then 'Has never logged in — remove if this person no longer works here'
              when last_sign_in_at < now() - interval '60 days'
                then 'No login for ' || (current_date - last_sign_in_at::date) || ' days — still working here?'
              else 'Last login: ' || to_char(last_sign_in_at, 'DD Mon YYYY') end
  from staff where not is_owner

  union all
  -- 7. Logins that are not staff: clients (phone) are expected; email logins are not
  select 7, 'Other logins', 'Client accounts (WhatsApp)', 'OK',
         count(*)::text || ' client login(s)'
  from nonstaff where coalesce(email, '') = '' and coalesce(phone, '') <> ''

  union all
  select 7, 'Other logins', coalesce(email, '(no email)'), 'WARNING',
         'An email login that is not a member of staff (created ' || to_char(created_at, 'DD Mon YYYY')
         || '). It has no access to staff data, but nobody should be creating these — find out who it is, or delete it in Authentication → Users.'
  from nonstaff where coalesce(email, '') <> ''

  union all
  -- 8. Client login switch
  select 8, 'Settings', 'Client login (WhatsApp)', 'CHECK',
         'Currently: ' || coalesce((select value::text from public.settings where key = 'client_login'), 'off (not set)')
)
select section, item, status, detail
from checks
order by case status when 'WARNING' then 0 when 'CHECK' then 1 else 2 end, ord, item;
